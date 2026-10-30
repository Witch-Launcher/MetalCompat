// MetalCompat M4 integration tests — real Metal ops through the LegacyMetal
// backend, deterministic results, no invented data. Runs on any Metal device;
// A9-class behavior remains PHYSICAL-VALIDATION-PENDING.
#import <Foundation/Foundation.h>

#include "Backends/LegacyMetal/metal_bridge.h"
#include "Backends/LegacyMetal/legacy_ops.h"

#include <cstdio>
#include <cstring>
#include <cstdint>
#include <string>

namespace {
int g_checks = 0, g_failed = 0;
void check(bool cond, const char* what) {
    ++g_checks;
    if (!cond) { ++g_failed; std::printf("  CHECK FAILED: %s\n", what); }
}

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

    std::printf("%s — %d checks, %d failed (%s)\n", g_failed ? "FAILED" : "PASSED",
                g_checks, g_failed, caps.deviceName.c_str());
    return g_failed ? 1 : 0;
}
