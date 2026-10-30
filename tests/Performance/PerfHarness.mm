// MetalCompat M8 performance harness — measured numbers for PERFORMANCE.md.
// Not registered in ctest (perf plumbing, non-deterministic); run manually on
// a real device. Host numbers printed as stable ms-formatted prime lines.
// Run:  ./build/tests/Performance/PerfHarness
#import <Foundation/Foundation.h>

#include "Backends/LegacyMetal/metal_bridge.h"
#include "Backends/LegacyMetal/legacy_ops.h"
#include "Backends/LegacyMetal/render_layered.h"
#include "MetalCompat/Shader.hpp"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {
using Steady = std::chrono::steady_clock;
double msBetween(Steady::time_point a, Steady::time_point b) {
    return std::chrono::duration<double, std::milli>(b - a).count();
}

const char* kAddMsl = R"MSL(
#include <metal_stdlib>
using namespace metal;
kernel void vec_add(const device float* a [[buffer(0)]],
                    const device float* b [[buffer(1)]],
                    device float* sum [[buffer(2)]],
                    uint id [[thread_position_in_grid]]) {
    sum[id] = a[id] + b[id];
}
)MSL";

const char* kLayeredBody = R"MSL(
#include <metal_stdlib>
using namespace metal;
#if MC_LAYER_FROM_UNIFORM
struct VOut { float4 pos [[position]]; };
vertex VOut vs_main(uint vid [[vertex_id]], constant uint& layerId [[buffer(3)]]) {
  (void)layerId;
#else
struct VOut { float4 pos [[position]]; uint layer [[render_target_array_index]]; };
vertex VOut vs_main(uint vid [[vertex_id]], uint iid [[instance_id]]) {
#endif
  const float2 p[3] = {float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0)};
  VOut o;
  o.pos = float4(p[vid], 0.0, 1.0);
#if MC_LAYER_FROM_UNIFORM
#else
  o.layer = iid;
#endif
  return o;
}
#if MC_LAYER_FROM_UNIFORM
fragment float4 fs_main(VOut in [[stage_in]], constant uint& layerId [[buffer(4)]]) {
  const uint layer = layerId;
#else
fragment float4 fs_main(VOut in [[stage_in]]) {
  const uint layer = in.layer;
#endif
  const uint2 pix((uint)in.pos.x, (uint)in.pos.y);
  return float4((float)layer * 0.25f + (float)pix.x / 1024.0f,
                (float)pix.y / 1024.0f, 0.5f, 1.0f);
}
)MSL";
} // namespace

int main() {
    mc::DeviceCaps caps;
    if (mcmtl_probeDefaultDevice(&caps) != 0) {
        std::printf("SKIP no Metal device\n");
        return 77;
    }
    void* dev = mcmtl_deviceHandle();
    std::printf("PERF device=%s\n", caps.deviceName.c_str());
    std::printf("PERF appleGpu=%d\n", caps.appleGpu ? 1 : 0);

    // ---- workload 1: compute (vec_add) dispatch row ----
    {
        void* lib = nullptr;
        void* pipe = nullptr;
        if (mcops_compileLibrary(dev, kAddMsl, &lib) != 0) { std::printf("PERF compile-failed\n"); return 1; }
        if (mcops_newComputePipeline(dev, lib, "vec_add", &pipe) != 0) {
            std::printf("PERF pipe-failed\n"); return 1;
        }
        const uint32_t N = 1 << 20; // 1M
        MCOpBuffer a{}, b{}, s{};
        mcops_newBuffer(dev, N * 4, MCOP_STORAGE_AUTO, &a);
        mcops_newBuffer(dev, N * 4, MCOP_STORAGE_AUTO, &b);
        mcops_newBuffer(dev, N * 4, MCOP_STORAGE_AUTO, &s);
        std::vector<float> va(N, 1.0f), vb(N, 2.0f);
        mcops_writeBufferHost(&a, va.data(), N * 4);
        mcops_writeBufferHost(&b, vb.data(), N * 4);
        const void* bufs[3] = {a.handle, b.handle, s.handle};
        // warmup
        for (int i = 0; i < 5; ++i) mcops_dispatchCompute(dev, pipe, N, 256, bufs, 3);
        auto t0 = Steady::now();
        constexpr int kIters = 20;
        for (int i = 0; i < kIters; ++i) mcops_dispatchCompute(dev, pipe, N, 256, bufs, 3);
        auto t1 = Steady::now();
        std::printf("PERF compute 1M-add  per-dispatch %.3f ms\n",
                    msBetween(t0, t1) / kIters);
        mcops_freeBuffer(&a); mcops_freeBuffer(&b); mcops_freeBuffer(&s);
        mcops_freeComputePipeline(pipe);
        mcops_freeLibrary(lib);
    }

    // ---- workload 2: layer selection — native single pass vs S-pass fallback ----
    {
        mc::ShaderVariantLibrary variants(
            [](const std::string& src, const std::string&, void** outLib,
               std::string& err) -> mc::Error {
                char buf[512] = {0};
                const int rcv = mcops_compileLibraryEx(mcmtl_deviceHandle(), src.c_str(),
                                                       mc::kMslLanguage_2_3, buf, sizeof(buf), outLib);
                if (rcv != 0) err.assign(buf);
                return rcv == 0 ? mc::Error{}
                                : mc::Error{mc::ErrorCode::BridgeFailure, "", err};
            },
            +[](void* lib) noexcept { mcops_freeLibrary(lib); }, 4);
        const std::string body(kLayeredBody);
        mc::CompiledVariant vN, vF;
        if (variants.getVariant(body, {{"MC_LAYER_FROM_UNIFORM", "0"}},
                               mc::kMslLanguage_2_3, vN) ||
            variants.getVariant(body, {{"MC_LAYER_FROM_UNIFORM", "1"}},
                                mc::kMslLanguage_2_3, vF)) {
            std::printf("PERF variant-failed\n");
            return 1;
        }
        void* pipeN = nullptr, *pipeF = nullptr;
        if (mcops_newRenderPipeline(dev, vN.library, "vs_main", "fs_main", 1, &pipeN) ||
            mcops_newRenderPipeline(dev, vF.library, "vs_main", "fs_main", 0, &pipeF)) {
            std::printf("PERF render-pipe-failed\n");
            return 1;
        }
        constexpr uint32_t W = 512, H = 512, S = 4;
        void* texHandle = nullptr;
        if (mcops_newTextureArray(dev, W, H, S, &texHandle) != 0) {
            std::printf("PERF texture-failed\n");
            return 1;
        }
        MCOpBuffer mesh{}, uni{};
        mcops_newBuffer(dev, 24, MCOP_STORAGE_AUTO, &mesh);
        const float meshData[3][2] = {{-1, -1}, {3, -1}, {-1, 3}};
        mcops_writeBufferHost(&mesh, meshData, sizeof(meshData));
        mcops_newBuffer(dev, S * 32, MCOP_STORAGE_AUTO, &uni);
        uint8_t staged[S * 32] = {};
        for (uint32_t s = 0; s < S; ++s) std::memcpy(staged + s * 32, &s, 4);
        mcops_writeBufferHost(&uni, staged, sizeof(staged));

        MCLayeredRenderParams base{};
        base.colorTexture = texHandle;
        base.meshBuffer = mesh.handle;
        base.layerUniforms = uni.handle;
        base.viewportWidth = W;
        base.viewportHeight = H;
        base.sliceCount = S;
        base.clearA = 1.0f;

        const bool nativeGate = mcops_supportsLayerSelection(dev) == 1;
        if (nativeGate) {
            constexpr int kIters = 50;
            MCLayeredRenderParams p = base;
            p.pipeline = pipeN;
            for (int i = 0; i < 5; ++i) mcops_renderLayeredNative(dev, &p); // warmup
            auto t0 = Steady::now();
            for (int i = 0; i < kIters; ++i) mcops_renderLayeredNative(dev, &p);
            auto t1 = Steady::now();
            std::printf("PERF layered-native    1 pass, %u slices, %ux%u  %.3f ms/frame\n",
                        S, W, H, msBetween(t0, t1) / kIters);
        }
        // The fallback runs everywhere (also acts as the no-gate baseline).
        {
            constexpr int kIters = 50;
            MCLayeredRenderParams p = base;
            p.pipeline = pipeF;
            for (int i = 0; i < 5; ++i) mcops_renderLayeredFallback(dev, &p); // warmup
            auto t0 = Steady::now();
            for (int i = 0; i < kIters; ++i) mcops_renderLayeredFallback(dev, &p);
            auto t1 = Steady::now();
            std::printf("PERF layered-fallback  %u passes, %u slices, %ux%u  %.3f ms/frame\n",
                        S, S, W, H, msBetween(t0, t1) / kIters);
        }

        mcops_freeTexture(texHandle);
        mcops_freeBuffer(&mesh);
        mcops_freeBuffer(&uni);
        mcops_freeRenderPipeline(pipeN);
        mcops_freeRenderPipeline(pipeF);
        variants.releaseVariant(vN.cookie);
        variants.releaseVariant(vF.cookie);
    }
    return 0;
}
