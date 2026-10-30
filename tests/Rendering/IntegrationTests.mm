// MetalCompat M4/M5/M7 integration tests — real Metal ops through the
// LegacyMetal backend, deterministic results, no invented data. Runs on any
// Metal device; A9-class behavior remains PHYSICAL-VALIDATION-PENDING.
#import <Foundation/Foundation.h>

#include "Backends/LegacyMetal/metal_bridge.h"
#include "Backends/LegacyMetal/legacy_ops.h"
#include "Backends/LegacyMetal/render_layered.h"
#include "Backends/LegacyMetal/arg_table_t1.h"
#include "MetalCompat/Shader.hpp"

#include <cstdio>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>

namespace {
int g_checks = 0, g_failed = 0;
void check(bool cond, const char* what) {
    ++g_checks;
    if (!cond) { ++g_failed; std::printf("  CHECK FAILED: %s\n", what); }
}
void check(bool cond, const std::string& what) { check(cond, what.c_str()); }

const char* kComputeAddMsl = R"MSL(
#include <metal_stdlib>
using namespace metal;
kernel void vec_add(const device float* a [[buffer(0)]],
                    const device float* b [[buffer(1)]],
                    device float* sum [[buffer(2)]],
                    uint id [[thread_position_in_grid]]) {
    sum[id] = a[id] + b[id];
}
)MSL";
} // namespace

// Layer-selection shader body with #if-guarded dual paths (compiled twice by
// the M6 variant subsystem: MC_LAYER_FROM_UNIFORM=0 native, =1 fallback).
// NOTE: the MSL builtin is fragment [[position]] on the stage-in payload —
// [[pixel_coord]] does not exist; in.pos.x/y are pixel centers (x = col+0.5).
// GPU validation requires inputPrimitiveTopology=Triangle whenever the verex
// writes [[render_target_array_index]] (native-op pipeline sets it).
static const char kLayeredMslBody[] = R"MSL(
#include <metal_stdlib>
using namespace metal;
#if MC_LAYER_FROM_UNIFORM
struct VOut { float4 pos [[position]]; };
#else
struct VOut { float4 pos [[position]]; uint layer [[render_target_array_index]]; };
#endif
#if MC_LAYER_FROM_UNIFORM
vertex VOut vs_main(uint vid [[vertex_id]], constant uint& layerId [[buffer(3)]]) {
  (void)layerId;
#else
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
  float r = (float)layer * 0.25f + (float)pix.x / 1024.0f;
  float g = (float)pix.y / 1024.0f;
  float b = 0.5f;
  float a = 1.0f;
  return float4(r, g, b, a);
}
)MSL";

namespace {
// CPU replicates the formula exactly (dyadic fp32; RGBA8 quantization shared).
void expectedPixel(uint32_t layer, uint32_t pixX, uint32_t pixY, uint8_t out[4]) {
    const float r = (float)layer * 0.25f + (float)pixX / 1024.0f;
    const float g = (float)pixY / 1024.0f;
    const float b = 0.5f;
    const float c[4] = {r, g, b, 1.0f};
    for (int i = 0; i < 4; ++i)
        out[i] = (uint8_t)(c[i] * 255.0f + 0.5f);
}

struct LayeredCtx {
    void* dev = nullptr;
    void* libNative = nullptr;
    void* libFallback = nullptr;
    void* pipeNative = nullptr;
    void* pipeFallback = nullptr;
    void* mesh = nullptr;
    void* uniforms = nullptr;
    mc::ShaderVariantLibrary* variants = nullptr;
    bool ok = false;
};

bool layeredSetup(LayeredCtx& c) {
    c.dev = mcmtl_deviceHandle();
    if (!c.variants) c.variants = new mc::ShaderVariantLibrary(
        [](const std::string& src, const std::string&, void** outLib, std::string& err) -> mc::Error {
            char buf[512] = {0};
            int rc = mcops_compileLibraryEx(mcmtl_deviceHandle(), src.c_str(), mc::kMslLanguage_2_3,
                                            buf, sizeof(buf), outLib);
            if (rc != 0) err.assign(buf);
            return rc == 0 ? mc::Error{} : mc::Error{mc::ErrorCode::BridgeFailure, "", err};
        },
        +[](void* lib) noexcept { mcops_freeLibrary(lib); },
        16);
    const std::string body(kLayeredMslBody);
    mc::CompiledVariant vNative, vFallback;
    std::vector<mc::VariantDefine> dNative = {{"MC_LAYER_FROM_UNIFORM", "0"}};
    std::vector<mc::VariantDefine> dFallback = {{"MC_LAYER_FROM_UNIFORM", "1"}};
    if (c.variants->getVariant(body, dNative, mc::kMslLanguage_2_3, vNative)) return false;
    if (c.variants->getVariant(body, dFallback, mc::kMslLanguage_2_3, vFallback)) return false;
    c.libNative = vNative.library;
    c.libFallback = vFallback.library;
    if (mcops_newRenderPipeline(c.dev, c.libNative, "vs_main", "fs_main", 1, &c.pipeNative) != 0)
        return false;
    if (mcops_newRenderPipeline(c.dev, c.libFallback, "vs_main", "fs_main", 0, &c.pipeFallback) != 0)
        return false;
    const float mesh[3][2] = {{-1.0f, -1.0f}, {3.0f, -1.0f}, {-1.0f, 3.0f}};
    MCOpBuffer mb{};
    if (mcops_newBuffer(c.dev, sizeof(mesh), MCOP_STORAGE_AUTO, &mb) != 0) return false;
    c.mesh = mb.handle;
    mcops_writeBufferHost(&mb, mesh, sizeof(mesh));
    return true;
}

void layeredTeardown(LayeredCtx& c) {
    if (c.pipeNative) mcops_freeRenderPipeline(c.pipeNative);
    if (c.pipeFallback) mcops_freeRenderPipeline(c.pipeFallback);
    MCOpBuffer mb{c.mesh, 0, nullptr};
    mcops_freeBuffer(&mb);
    delete c.variants;
}
} // namespace

// ---------------------------------------------------------------------------
int main() {
    mc::DeviceCaps caps;
    int rc = mcmtl_probeDefaultDevice(&caps);
    if (rc != 0) {
        std::printf("SKIP no Metal device (rc=%d)\n", rc);
        return 77; // skip for ctest
    }
    void* dev = mcmtl_deviceHandle();
    check(dev != nullptr, "device handle available");

    // ---- M4.1 buffer create/write/read (host path) ----
    {
        MCOpBuffer buf{};
        check(mcops_newBuffer(dev, 1024, MCOP_STORAGE_AUTO, &buf) == 0, "staging buffer created");
        float src[256];
        for (int i = 0; i < 256; ++i) src[i] = i * 0.5f;
        check(mcops_writeBufferHost(&buf, src, sizeof(src)) == 0, "write host");
        float dst[256];
        check(mcops_readBufferHost(&buf, dst, sizeof(dst)) == 0, "read host");
        check(std::memcmp(src, dst, sizeof(src)) == 0, "host buffer roundtrip exact");
        // GPU buffer->buffer copy + verify (blit path)
        MCOpBuffer gpuBuf{};
        check(mcops_newBuffer(dev, 1024, MCOP_STORAGE_AUTO, &gpuBuf) == 0, "dst buffer created");
        check(mcops_copyBuffer(dev, 0, 0, buf.handle, gpuBuf.handle, sizeof(src)) == 0,
              "gpu buffer copy completed");
        float gpuDst[256];
        check(mcops_readBufferHost(&gpuBuf, gpuDst, sizeof(gpuDst)) == 0, "read after gpu copy");
        check(std::memcmp(src, gpuDst, sizeof(src)) == 0, "GPU buffer copy exact");
        mcops_freeBuffer(&buf);
        mcops_freeBuffer(&gpuBuf);
    }

    // ---- M4.2 texture staged upload/download roundtrip (RGBA8) ----
    {
        constexpr uint32_t W = 32, H = 32;
        const uint64_t rowBytes = W * 4;
        MCOpBuffer up{};
        void* tex8 = nullptr;
        check(mcops_newBuffer(dev, rowBytes * H, MCOP_STORAGE_AUTO, &up) == 0, "tex staging buffer");
        check(mcops_newTexture(dev, W, H, MCOP_TEX_RGBA8_UNORM, &tex8) == 0, "RGBA8 texture created");
        uint8_t pattern[W * H * 4];
        for (uint32_t j = 0; j < H; ++j)
            for (uint32_t i = 0; i < W; ++i) {
                uint8_t* p = pattern + 4 * (j * W + i);
                p[0] = (uint8_t)((i * 7) & 0xFF);
                p[1] = (uint8_t)((j * 11) & 0xFF);
                p[2] = (uint8_t)(((i + j) * 3) & 0xFF);
                p[3] = 0xFF;
            }
        check(mcops_writeBufferHost(&up, pattern, rowBytes * H) == 0, "tex pattern staged");
        check(mcops_uploadTexture(dev, &up, tex8, W, H, rowBytes) == 0, "tex upload completed");
        MCOpBuffer down{};
        check(mcops_newBuffer(dev, rowBytes * H, MCOP_STORAGE_AUTO, &down) == 0, "tex down staging");
        std::memset(down.cpuAddress, 0xA5, rowBytes * H);
        check(mcops_downloadTexture(dev, tex8, W, H, rowBytes, &down) == 0, "tex download completed");
        check(std::memcmp(down.cpuAddress, pattern, rowBytes * H) == 0,
              "texture roundtrip bytes exact");
        if (tex8) mcops_freeTexture(tex8);
        mcops_freeBuffer(&up);
        mcops_freeBuffer(&down);
    }

    // ---- M4.3 sampler creation ----
    {
        void* sNearest = nullptr;
        void* sLinear = nullptr;
        check(mcops_newSampler(dev, 0, &sNearest) == 0 && sNearest, "nearest sampler");
        check(mcops_newSampler(dev, 1, &sLinear) == 0 && sLinear, "linear sampler");
        mcops_freeSampler(sNearest);
        mcops_freeSampler(sLinear);
    }

    // ---- M4.4 compute pipeline dispatch (vec_add; deterministic floats) ----
    {
        void* lib = nullptr;
        void* pipe = nullptr;
        check(mcops_compileLibrary(dev, kComputeAddMsl, &lib) == 0 && lib, "compute library compiled");
        check(mcops_newComputePipeline(dev, lib, "vec_add", &pipe) == 0 && pipe,
              "compute pipeline created");
        constexpr uint32_t N = 1024;
        MCOpBuffer a{}, b{}, sum{};
        check(mcops_newBuffer(dev, N * 4, MCOP_STORAGE_AUTO, &a) == 0, "buf a");
        check(mcops_newBuffer(dev, N * 4, MCOP_STORAGE_AUTO, &b) == 0, "buf b");
        check(mcops_newBuffer(dev, N * 4, MCOP_STORAGE_AUTO, &sum) == 0, "buf sum");
        float va[N], vb[N];
        for (uint32_t i = 0; i < N; ++i) { va[i] = (float)i * 0.25f; vb[i] = (float)(N - i) * 0.25f; }
        check(mcops_writeBufferHost(&a, va, N * 4) == 0, "a staged");
        check(mcops_writeBufferHost(&b, vb, N * 4) == 0, "b staged");
        const uint32_t tgs = (uint32_t)caps.maxThreadsPerThreadgroup[0];
        const void* bufHandles[3] = {a.handle, b.handle, sum.handle};
        check(mcops_dispatchCompute(dev, pipe, N, tgs < N ? tgs : N,
                                    bufHandles, 3) == 0, "dispatch completed");
        float out[N];
        check(mcops_readBufferHost(&sum, out, N * 4) == 0, "sum readback");
        bool exact = true;
        for (uint32_t i = 0; i < N; ++i)
            if (out[i] != va[i] + vb[i]) { exact = false; break; } // exact float adds
        check(exact, "vec_add results exact");
        mcops_freeBuffer(&a); mcops_freeBuffer(&b); mcops_freeBuffer(&sum);
        mcops_freeComputePipeline(pipe);
        mcops_freeLibrary(lib);
    }

    // ---- M4.5 bounded frames-in-flight / staging-buffer reuse ----
    {
        void* tex = nullptr;
        constexpr uint32_t W = 16, H = 16;
        const uint64_t rowBytes = W * 4;
        MCOpBuffer up{}, down{};
        check(mcops_newTexture(dev, W, H, MCOP_TEX_RGBA8_UNORM, &tex) == 0, "frame tex");
        check(mcops_newBuffer(dev, rowBytes * H, MCOP_STORAGE_AUTO, &up) == 0, "frame up");
        check(mcops_newBuffer(dev, rowBytes * H, MCOP_STORAGE_AUTO, &down) == 0, "frame down");
        // REUSE the exact same staging buffers across 3 submitted+completed
        // frames — the bounded-lifetime contract under repeat submissions.
        bool allExact = true;
        for (int frame = 1; frame <= 3 && allExact; ++frame) {
            uint8_t expected[W * H * 4];
            for (size_t i = 0; i < sizeof(expected); ++i)
                expected[i] = (uint8_t)(i * frame + 1);
            check(mcops_writeBufferHost(&up, expected, sizeof(expected)) == 0, "frame staged");
            check(mcops_uploadTexture(dev, &up, tex, W, H, rowBytes) == 0, "frame uploaded");
            check(mcops_downloadTexture(dev, tex, W, H, rowBytes, &down) == 0, "frame downloaded");
            if (std::memcmp(down.cpuAddress, expected, sizeof(expected)) != 0) allExact = false;
        }
        check(allExact, "3 reused frames exact (bounded staging reuse)");
        if (tex) mcops_freeTexture(tex);
        mcops_freeBuffer(&up); mcops_freeBuffer(&down);
    }

    // ---- M5: layer selection — native vs fallback vs CPU reference ----
    {
        LayeredCtx ctx;
        layeredSetup(ctx) ? check(true, "layered setup") : check(false, "layered setup");
        constexpr uint32_t W = 64, H = 64, S = 4;
        void* tex = nullptr;
        if (mcops_newTextureArray(ctx.dev, W, H, S, &tex) == 0 && tex) {
            MCOpBuffer uniforms{};
            check(mcops_newBuffer(ctx.dev, S * 32, MCOP_STORAGE_AUTO, &uniforms) == 0,
                  "layer uniform buffer (32-byte aligned slots)");
            uint32_t layerVals[S];
            for (uint32_t s = 0; s < S; ++s) layerVals[s] = s;
            uint8_t staged[S * 32] = {};
            for (uint32_t s = 0; s < S; ++s)
                std::memcpy(staged + s * 32, layerVals + s, 4);
            check(mcops_writeBufferHost(&uniforms, staged, sizeof(staged)) == 0,
                  "layers staged");

            MCLayeredRenderParams params{};
            params.pipeline = ctx.pipeNative;
            params.colorTexture = tex;
            params.meshBuffer = ctx.mesh;
            params.layerUniforms = uniforms.handle;
            params.viewportWidth = W;
            params.viewportHeight = H;
            params.sliceCount = S;
            params.clearR = 0.0f; params.clearG = 0.0f; params.clearB = 0.0f; params.clearA = 1.0f;

            // CPU reference: which channel must each slice/pixel hold.
            uint8_t expected[S][W * H * 4];
            for (uint32_t s = 0; s < S; ++s)
                for (uint32_t y = 0; y < H; ++y)
                    for (uint32_t x = 0; x < W; ++x)
                        expectedPixel(s, x, y, &expected[s][(y * W + x) * 4]);

            // Per-run verification against the CPU reference (±1 lb/channel).
            auto verify = [&](void* pipeline, bool native, const char* tag) {
                MCLayeredRenderParams p = params;
                p.pipeline = pipeline;
                const int rc = native ? mcops_renderLayeredNative(ctx.dev, &p)
                                      : mcops_renderLayeredFallback(ctx.dev, &p);
                if (rc != 0) { check(false, std::string(tag) + " render rc=" + std::to_string(rc)); return; }
                for (uint32_t s = 0; s < S; ++s) {
                    MCOpBuffer down{};
                    if (mcops_newBuffer(ctx.dev, W * H * 4, MCOP_STORAGE_AUTO, &down) != 0) {
                        check(false, "download staging");
                        return;
                    }
                    if (mcops_downloadTextureSlice(ctx.dev, tex, s, 0, down.handle) == 0) {
                        const uint8_t* got = (const uint8_t*)down.cpuAddress;
                        bool all = true;
                        for (uint32_t i = 0; i < W * H * 4 && all; ++i) {
                            const int d = (int)got[i] - (int)expected[s][i];
                            if (d > 1 || d < -1) { all = false; std::printf("  %s: slice %u idx %u got=%u want=%u\n", tag, s, i, got[i], expected[s][i]); }
                        }
                        check(all, std::string(tag) + " slice " + std::to_string(s) +
                                       " matches CPU reference");
                    } else
                        check(false, "slice download rc");
                    mcops_freeBuffer(&down);
                }
            };

            // NATIVE path (Apple5+/macOS only; on other hardware op returns 6).
            const int rcN = mcops_renderLayeredNative(ctx.dev, &(MCLayeredRenderParams&)params);
            check(rcN == 0 || rcN == 6, "native render ran or reported unsupported gate");
            if (rcN == 0) verify(ctx.pipeNative, true, "native");

            // FALLBACK path (S sequential per-slice passes; everywhere).
            const int rcF = mcops_renderLayeredFallback(ctx.dev, &(MCLayeredRenderParams&)params);
            check(rcF == 0, "fallback render completed (rc=" + std::to_string(rcF) + ")");
            if (rcF == 0) verify(ctx.pipeFallback, false, "fallback");

            mcops_freeBuffer(&uniforms);
            mcops_freeTexture(tex);
        }
        layeredTeardown(ctx);
    }

    // ---- M7: legacy tier-1 argument buffers prototype ----
    {
        const int gate = mcops_argT1Support(dev);
        check(gate >= 0, "tier-1 gate probe ran (resolvable on this OS)");
        if (gate == 1) {
            constexpr uint32_t N = 256;
            MCOpBuffer src{}, dstC{}, dstT1{};
            check(mcops_newBuffer(dev, N * 4, MCOP_STORAGE_AUTO, &src) == 0, "argt1 src");
            check(mcops_newBuffer(dev, N * 4, MCOP_STORAGE_AUTO, &dstC) == 0, "argt1 dst classic");
            check(mcops_newBuffer(dev, N * 4, MCOP_STORAGE_AUTO, &dstT1) == 0, "argt1 dst tier1");
            uint32_t seed = 0x1234567u;
            uint32_t vals[N];
            for (uint32_t i = 0; i < N; ++i) {
                seed ^= (seed << 13u); seed ^= (seed >> 17u); seed ^= (seed << 5u);
                vals[i] = seed;
            }
            check(mcops_writeBufferHost(&src, vals, sizeof(vals)) == 0, "argt1 src staged");
            const int rc = mcops_argT1Prototype(dev, src.handle, dstC.handle, dstT1.handle, N);
            check(rc == 0, "tier-1 prototype all steps (rc=" + std::to_string(rc) + ")");
            if (rc == 0) {
                const uint32_t* a = (const uint32_t*)dstC.cpuAddress;
                const uint32_t* b = (const uint32_t*)dstT1.cpuAddress;
                bool same = true;
                for (uint32_t i = 0; i < N && same; ++i)
                    if (a[i] != b[i]) same = false;
                check(same, "classic results == tier-1 argument-buffer results");
            }
            mcops_freeBuffer(&src); mcops_freeBuffer(&dstC); mcops_freeBuffer(&dstT1);
        } else {
            std::printf("  (tier-1 argument buffers unavailable on this device — skipped)\n");
        }
    }

    std::printf("%s — %d checks, %d failed (%s)\n", g_failed ? "FAILED" : "PASSED",
                g_checks, g_failed, caps.deviceName.c_str());
    return g_failed ? 1 : 0;
}
