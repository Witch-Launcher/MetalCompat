// BasicRender — MetalCompat first vertical slice (SPEC §15).
// Chain: Device probe → registry load/validate → planner decisions
//        → LegacyMetal backend selection → render pipeline
//        → deterministic offscreen frame → reference check → timings/diagnostics.
//
// Determinism strategy (rasterizer-independent):
//   * the triangle uses a solid interior color on all three vertices, so every
//     covered fragment must produce exactly that color without relying on
//     interpolation precision;
//   * geometric coverage of every texel center is computed on the CPU;
//   * pass iff ≥97% of texels match (interior or exterior, tolerance ±0.02)
//     and the deep-interior / deep-exterior probe texels match exactly.
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#import <mach/mach_time.h>

#include "MetalCompat/Capabilities.hpp"
#include "MetalCompat/Device.hpp"
#include "MetalCompat/Errors.hpp"
#include "MetalCompat/ExecutionPlanner.hpp"
#include "MetalCompat/FeatureRegistry.hpp"

#include "CPU/Diagnostics/Diag.hpp"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <mach-o/dyld.h>

using namespace mc;
namespace diag = mc::diag;

static constexpr int kW = 64, kH = 64;
static constexpr float kInteriorR = 0.60f, kInteriorG = 0.25f, kInteriorB = 0.75f;
static constexpr float kClearR = 0.10f, kClearG = 0.20f, kClearB = 0.30f;
static constexpr float kAx = -0.6f, kAy = -0.6f;
static constexpr float kBx = 0.7f,  kBy = -0.4f;
static constexpr float kCx = 0.0f,  kCy = 0.75f;

static const char* kMslSource = R"MSL(
#include <metal_stdlib>
using namespace metal;
struct VIn { float4 position; float4 color; };
struct VOut { float4 position [[position]]; float4 color; };
vertex VOut vs_main(const device VIn* v [[buffer(0)]], unsigned vid [[vertex_id]]) {
    VOut o;
    o.position = v[vid].position;
    o.color = v[vid].color;
    return o;
}
fragment float4 fs_main(VOut in [[stage_in]]) { return in.color; }
)MSL";

namespace {

std::string exeDir() {
    char buf[4096];
    std::uint32_t size = sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) != 0) return ".";
    std::string p(buf);
    const size_t pos = p.find_last_of('/');
    return pos == std::string::npos ? std::string(".") : p.substr(0, pos);
}

bool fileExists(const std::string& path) {
    struct stat st{};
    return ::stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

std::string findRegistryDir() {
    if (const char* env = std::getenv("MC_REGISTRY_DIR")) {
        std::string dir(env);
        if (fileExists(dir + "/metal_api_registry.json")) return dir;
    }
    const std::string exe = exeDir();
    const std::string candidates[] = {
        "registry", exe + "/registry", exe + "/../registry", exe + "/../../registry",
    };
    for (const auto& c : candidates)
        if (fileExists(c + "/metal_api_registry.json")) return c;
    return {};
}

// CPU-side geometric coverage of a texel center (same coords as the MSL frame).
bool texelInterior(int ix, int iy) {
    const float x = ((ix + 0.5f) / kW) * 2.0f - 1.0f;
    const float y = 1.0f - ((iy + 0.5f) / kH) * 2.0f;
    const float e1 = (x - kAx) * (kBy - kAy) - (y - kAy) * (kBx - kAx);
    const float e2 = (x - kBx) * (kCy - kBy) - (y - kBy) * (kCx - kBx);
    const float e3 = (x - kCx) * (kAy - kCy) - (y - kCy) * (kAx - kCx);
    const bool hasNeg = (e1 < 0) || (e2 < 0) || (e3 < 0);
    const bool hasPos = (e1 > 0) || (e2 > 0) || (e3 > 0);
    return !(hasNeg && hasPos);
}

uint64_t nowNs() {
    static mach_timebase_info_data_t tb = {0, 0};
    if (tb.denom == 0) (void)mach_timebase_info(&tb);
    return mach_absolute_time() * tb.numer / tb.denom;
}

bool nearf(float a, float b, float tol) { return (a - b) <= tol && (b - a) <= tol; }

bool writePpm(const std::string& path, const unsigned char* px, std::string& err) {
    FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) { err = "cannot open " + path; return false; }
    std::fprintf(f, "P3\n%d %d\n255\n", kW, kH);
    for (int j = 0; j < kH; ++j)
        for (int i = 0; i < kW; ++i) {
            const unsigned char* p = px + 4 * (j * kW + i);
            std::fprintf(f, "%u %u %u\n", p[0], p[1], p[2]);
        }
    std::fclose(f);
    return true;
}

} // namespace

int main() {
    int failures = 0;
    auto fail = [&](const std::string& m) { std::printf("FAIL %s\n", m.c_str()); ++failures; };
    auto ok = [&](const std::string& m) { std::printf("ok   %s\n", m.c_str()); };

    diag::global().enable();

    // ---- 1. Device + capability snapshot ----
    Device d;
    Error e = createDefaultDevice(d);
    if (e) { std::printf("ERROR device: %s\n", describe(e).c_str()); return 1; }
    ok(std::string("device: ") + d.caps.deviceName + " @ " + d.caps.osVersion);
    std::printf("     appleGpu=%s metal4=%s families:", d.caps.appleGpu ? "yes" : "no",
                d.caps.supportsMetal4 ? "yes" : "no");
    constexpr int fams[] = {family::Apple1, family::Apple2, family::Apple3, family::Apple4,
                            family::Apple5, family::Apple6, family::Apple7, family::Apple8,
                            family::Apple9, family::Apple10, family::Mac2, family::Common1,
                            family::Common2, family::Common3, family::Metal3, family::Metal4};
    {
        bool first = true;
        for (int f : fams)
            if (supportsFamily(d.caps, f)) {
                std::printf("%s%s", first ? "" : ",", familyName(f));
                first = false;
            }
        std::printf("\n");
    }
    if (!d.caps.appleGpu)
        std::printf("NOTE physical A9/Apple-family device validation pending (no Apple GPU here)\n");

    // ---- 2. Registry + architectural invariants ----
    const std::string regDir = findRegistryDir();
    FeatureRegistry reg;
    e = FeatureRegistry::load(regDir + "/metal_api_registry.json", reg);
    if (e) { std::printf("ERROR registry: %s\n", describe(e).c_str()); return 2; }
    GpuCapabilitiesTable g;
    e = FeatureRegistry::loadGpuCapabilities(regDir + "/gpu_capabilities.json", g);
    if (e) { std::printf("ERROR gpu caps: %s\n", describe(e).c_str()); return 2; }
    e = validatePrimaryTargetInvariant(g);
    if (e) { std::printf("ERROR invariant: %s\n", describe(e).c_str()); return 2; }
    ok("registry loaded: " + std::to_string(reg.features().size()) + " features");

    // ---- 3. Execution planner ----
    ExecutionPlanner planner(reg, d.caps, ValidationLevel::Diagnostic);
    Decision dec;
    Error pErr = planner.plan("pipe.render", dec);
    if (pErr || dec.op != PlanOp::Native) {
        fail("pipe.render must plan to the native legacy path (error: " + describe(pErr) + ")");
    } else {
        ok(std::string("pipe.render -> NATIVE legacy path (state=") + std::string(toString(dec.state)) + ")");
        diag::global().record(diag::EventKind::FeatureSelected, "pipe.render", dec.reason);
    }
    Error m4e = planner.plan("mtl4.queue", dec);
    if (!m4e) fail("mtl4.queue unexpectedly planned (must be refused per D-008)");
    else ok(std::string("mtl4.queue refused: ") + toString(m4e.code) + " (" +
            m4e.featureId + ")");
    diag::global().record(diag::EventKind::PlanUnsupported, "mtl4.queue", toString(m4e.code));

    // ---- 4..7 LegacyMetal backend: pipeline → deterministic frame → verify ----
    @autoreleasepool {
        id<MTLDevice> dev = (__bridge id<MTLDevice>)d.handle;
        if (!dev) { std::printf("ERROR backend handle missing\n"); return 3; }

        NSString* src = [NSString stringWithCString:kMslSource
                                          encoding:NSUTF8StringEncoding];
        id<MTLLibrary> lib = nil;
        NSError* nerr = nil;
        // MTLCompileOptions.languageVersion (public since macos 10.11 / ios 9.0);
        // 2.3 is the documented iOS 14 ceiling (docs/RESEARCH.md §4, shader.msl23).
        MTLCompileOptions* copts = [MTLCompileOptions new];
        if (@available(ios 14.0, macos 11.0, *)) {
            copts.languageVersion = MTLLanguageVersion2_3;
        } else {
            copts.languageVersion = MTLLanguageVersion2_2;
        }
        lib = [dev newLibraryWithSource:src options:copts error:&nerr];
        if (!lib) {
            std::printf("ERROR MSL compile: %s\n", nerr.description.UTF8String ?: "?");
            return 3;
        }
        id<MTLFunction> vf = [lib newFunctionWithName:@"vs_main"];
        id<MTLFunction> ff = [lib newFunctionWithName:@"fs_main"];
        if (!vf || !ff) { std::printf("ERROR functions missing\n"); return 3; }

        MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = vf;
        pd.fragmentFunction = ff;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        NSError* perr = nil;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&perr];
        if (!ps) {
            std::printf("ERROR pipeline creation: %s\n", perr.description.UTF8String ?: "?");
            return 3;
        }
        ok("render pipeline created");

        struct Vertex { float x, y, z, w; float r, g, b, a; };
        const Vertex verts[3] = {
            {kAx, kAy, 0.0f, 1.0f, kInteriorR, kInteriorG, kInteriorB, 1.0f},
            {kBx, kBy, 0.0f, 1.0f, kInteriorR, kInteriorG, kInteriorB, 1.0f},
            {kCx, kCy, 0.0f, 1.0f, kInteriorR, kInteriorG, kInteriorB, 1.0f},
        };
        // Buffer storage: Shared on unified-memory systems; Managed exists on
        // macOS only (API_UNAVAILABLE(ios), verified MTLResource.h:177).
#if TARGET_OS_OSX
        bool unified = true;
        if (@available(macos 10.15, *)) unified = dev.hasUnifiedMemory ? true : false;
        const MTLResourceOptions bufOpts = unified ? MTLResourceStorageModeShared
                                                  : MTLResourceStorageModeManaged;
#else
        constexpr bool unified [[maybe_unused]] = true; // iOS-family is unified-memory
        const MTLResourceOptions bufOpts = MTLResourceStorageModeShared;
#endif
        id<MTLBuffer> vbuf = [dev newBufferWithLength:sizeof(verts) options:bufOpts];
        if (!vbuf) { std::printf("ERROR vertex buffer\n"); return 3; }
        std::memcpy(vbuf.contents, verts, sizeof(verts));
#if TARGET_OS_OSX
        if (!unified) [vbuf didModifyRange:NSMakeRange(0, sizeof(verts))];
#endif

        id<MTLBuffer> readBuf = [dev newBufferWithLength:(kW * kH * 4) options:bufOpts];
        if (!readBuf) { std::printf("ERROR readback buffer\n"); return 3; }

        MTLTextureDescriptor* td = [MTLTextureDescriptor new];
        td.textureType = MTLTextureType2D;
        td.width = kW; td.height = kH;
        td.pixelFormat = MTLPixelFormatRGBA8Unorm;
        // Private render target on every platform; readback goes through a blit
        // into a host-visible staging buffer (Shared when unified, Managed else).
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
        if (!tex) { std::printf("ERROR texture\n"); return 3; }

        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        if (!cb) { std::printf("ERROR command buffer\n"); return 3; }

        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = tex;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(kClearR, kClearG, kClearB, 1.0);

        const uint64_t encodeStart = nowNs();
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:ps];
        [enc setVertexBuffer:vbuf offset:0 atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        // Texture → staging buffer (correct narrow dependency; on Managed hosts
        // this also advances the buffer version so the CPU can read GPU output).
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromTexture:tex sourceSlice:0 sourceLevel:0
                  sourceOrigin:MTLOriginMake(0, 0, 0)
                    sourceSize:MTLSizeMake(kW, kH, 1)
                     toBuffer:readBuf destinationOffset:0
        destinationBytesPerRow:kW * 4 destinationBytesPerImage:0];
#if TARGET_OS_OSX
        // Managed (non-unified) macs require an explicit sync before CPU read;
        // synchronizeResource: is API_UNAVAILABLE(ios) — unified-memory systems
        // don't need it (contents are valid after waitUntilCompleted).
        if (!unified) [blit synchronizeResource:readBuf];
#endif
        [blit endEncoding];
        const uint64_t encodeUs = (nowNs() - encodeStart) / 1000;

        [cb commit];
        [cb waitUntilCompleted];

        const double gpuMs = (double)(cb.GPUEndTime - cb.GPUStartTime) / 1.0e6;

        // ---- 6. Readback + deterministic verification (one-time test readback) ----
        unsigned char px[kW * kH * 4];
        std::memcpy(px, readBuf.contents, kW * kH * 4);

        int total = kW * kH, matched = 0, interiorProbeBad = 0, exteriorProbeBad = 0;
        int interiorCount = 0, exteriorCount = 0;
        for (int j = 0; j < kH; ++j) {
            for (int i = 0; i < kW; ++i) {
                const bool interiorGeo = texelInterior(i, j);
                const unsigned char* v = px + 4 * (j * kW + i);
                const float r = v[0] / 255.0f, gch = v[1] / 255.0f, bch = v[2] / 255.0f;
                if (interiorGeo) {
                    ++interiorCount;
                    if (nearf(r, kInteriorR, 0.02f) && nearf(gch, kInteriorG, 0.02f) &&
                        nearf(bch, kInteriorB, 0.02f)) ++matched;
                    if (i == kW / 2 && j == kH / 2) {
                        if (!(nearf(r, kInteriorR, 0.01f) && nearf(gch, kInteriorG, 0.01f) &&
                              nearf(bch, kInteriorB, 0.01f))) ++interiorProbeBad;
                    }
                } else {
                    ++exteriorCount;
                    if (nearf(r, kClearR, 0.02f) && nearf(gch, kClearG, 0.02f) &&
                        nearf(bch, kClearB, 0.02f)) ++matched;
                    if (i == 1 && j == 1) {
                        if (!(nearf(r, kClearR, 0.01f) && nearf(gch, kClearG, 0.01f) &&
                              nearf(bch, kClearB, 0.01f))) ++exteriorProbeBad;
                    }
                }
            }
        }
        const double pct = 100.0 * matched / total;
        std::printf("     coverage: interior=%d exterior=%d matched=%d/%d (%.2f%%)\n",
                    interiorCount, exteriorCount, matched, total, pct);
        std::printf("     timings : cpuEncode~%llu us, gpuExec=%.3f ms\n",
                    (unsigned long long)encodeUs, gpuMs);

        const std::string ppmPath = exeDir() + "/vertical_slice.ppm";
        std::string ppmErr;
        if (writePpm(ppmPath, px, ppmErr))
            std::printf("     wrote   : %s\n", ppmPath.c_str());
        else
            std::printf("     PPM     : %s\n", ppmErr.c_str());

        if (pct < 97.0) fail("deterministic frame mismatch (<97% matched)");
        else ok("deterministic frame matches reference");
        if (interiorProbeBad) fail("screen-center probe texel is not the interior color");
        if (exteriorProbeBad) fail("texel (1,1) is not the clear color");

        std::printf("     diag    : %zu events recorded\n", diag::global().populatedCount());
        diag::global().record(diag::EventKind::PipelineCacheMiss, "vs_main", "runtime compile");
    }

    destroyDevice(d);
    std::printf("%s vertical slice (%d failures)\n", failures ? "FAILED" : "PASSED", failures);
    return failures ? 1 : 0;
}
