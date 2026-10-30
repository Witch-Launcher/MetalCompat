// MetalCompat on-device render test app (MCRenderTest).
//
// Fully self-contained: runs REAL Metal render/compute through the
// MetalCompat LegacyMetal backend on the actual device GPU, streaming a
// timestamped PASS/FAIL log to (1) the on-screen text view, (2) NSLog
// (Console.app-visible) and (3) Documents/MC_TEST_LOG.txt (fetchable over
// Finder / Files app — UIFileSharingEnabled in the bundle's Info.plist).
//
// Test blocks (mirrors the host integration suite, on the real GPU):
//   [D]  device/probe/capability summary
//   [B]  buffer create/copy/roundtrip (M4)
//   [T]  texture staged upload/download roundtrip (M4)
//   [C]  compute pipeline dispatch — vec_add exact (M4)
//   [F]  3 submitted+completed frames reusing staging buffers (M4.5)
//   [L]  layer selection: native renderTargetArrayLength vs per-slice fallback
//        vs CPU reference, byte-compared per slice (M5)
//   [A]  legacy tier-1 argument buffers prototype (M7)
//   [S]  summary: checks + wall-clock time
//
// ARC mandatory. No imports from tests/ — only the public backend headers.
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include "Backends/LegacyMetal/metal_bridge.h"
#include "Backends/LegacyMetal/legacy_ops.h"
#include "Backends/LegacyMetal/render_layered.h"
#include "Backends/LegacyMetal/arg_table_t1.h"
#include "MetalCompat/Shader.hpp"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>

// ---------------------------------------------------------------------------
// Layer-selection shader body (#if-guarded dual paths, baked by the M6
// variant subsystem; MC_LAYER_FROM_UNIFORM=0 native / 1 fallback).
// NOTE: fragment pixel coords come from the stage-in payload's [[position]] —
// there is no [[pixel_coord]] builtin (verified: compiler warnings).
static const char kLayeredMslBody[] = R"MSL(
#include <metal_stdlib>
using namespace metal;
#if MC_LAYER_FROM_UNIFORM
struct VOut { float4 pos [[position]]; };
#else
struct VOut { float4 pos [[position]]; uint layer [[render_target_array_index]]; };
#endif
#if MC_LAYER_FROM_UNIFORM
vertex VOut vs_main(uint vid [[vertex_id]]) {
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
  return float4(r, g, b, 1.0f);
}
)MSL";

static const char kComputeAddMsl[] = R"MSL(
#include <metal_stdlib>
using namespace metal;
kernel void vec_add(const device float* a [[buffer(0)]],
                    const device float* b [[buffer(1)]],
                    device float* sum [[buffer(2)]],
                    uint id [[thread_position_in_grid]]) {
    sum[id] = a[id] + b[id];
}
)MSL";

// ---------------------------------------------------------------------------
// Log harness: thread-safe buffer -> screen (main thread) + NSLog + file.
static std::mutex g_logMutex;
static std::vector<std::string> g_logLines;
static int g_checks = 0, g_failed = 0;
static FILE* g_logFile = nullptr;

static std::string nowStamp() {
    using Steady = std::chrono::steady_clock;
    static const Steady::time_point t0 = Steady::now();
    const double s = std::chrono::duration<double>(Steady::now() - t0).count();
    char buf[32];
    snprintf(buf, sizeof(buf), "[%7.2fs] ", s);
    return buf;
}

static void openLogFile() {
    if (g_logFile) return;
    NSArray* dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                       NSUserDomainMask, YES);
    NSString* path = [dirs.firstObject stringByAppendingPathComponent:
                                         @"MC_TEST_LOG.txt"];
    g_logFile = fopen(path.fileSystemRepresentation, "w");
    setvbuf(g_logFile, nullptr, _IONBF, 0);
    NSLog(@"MC-LOGFILE %@", path);
}

static void log(const std::string& line) {
    const std::string stamped = nowStamp() + line;
    // Buffer first (used by screen/share), then crashes away: file+NSLog.
    {
        std::lock_guard<std::mutex> lk(g_logMutex);
        if (g_logLines.size() > 4000) g_logLines.erase(g_logLines.begin());
        g_logLines.push_back(stamped);
    }
    if (g_logFile) {
        fprintf(g_logFile, "%s\n", stamped.c_str());
        fflush(g_logFile);
    }
    NSLog(@"MC-LOG %@", [NSString stringWithUTF8String:stamped.c_str()]);
}

static std::string logTextFrozen() {
    std::lock_guard<std::mutex> lk(g_logMutex);
    std::string body;
    for (const auto& l : g_logLines) {
        body += l;
        body += '\n';
    }
    return body;
}

static std::string familyLabelOf(int raw) {
    return std::string(mc::familyName(raw));
}

// Full test session; defined near the bottom (asynchronous, background queue).
extern "C" void MCRunTestSession(void);

// Per-block safety fence: one @autoreleasepool per block (crash at its drain
// pins the responsible block) + boundary logs + ObjC-exception capture.
template <typename T>
static void runBlock(const char* name, T&& fn) {
    log(std::string("[enter] ") + name);
    @try {
        @autoreleasepool {
            fn();
        }
    } @catch (NSException* ex) {
        log(std::string("[EXC] ") + name + ": " +
            std::string(ex.reason ? ex.reason.UTF8String : "unknown reason"));
    }
    log(std::string("[leave] ") + name);
}

// ---------------------------------------------------------------------------
// Run screen: toolbar (rerun/share) + monospaced scrolling log.
@interface RunScreen : UIViewController
@end
@implementation RunScreen {
    UITextView* _logView;
    UIButton* _rerun;
    UIButton* _share;
}
- (void)loadView {
    [super loadView];
    self.view.backgroundColor = [UIColor blackColor];
    _logView = [[UITextView alloc] initWithFrame:self.view.bounds];
    _logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _logView.textColor = [UIColor whiteColor];
    _logView.backgroundColor = [UIColor blackColor];
    _logView.editable = NO;
    _logView.autocorrectionType = UITextAutocorrectionTypeNo;
    _logView.spellCheckingType = UITextSpellCheckingTypeNo;
    _logView.layoutManager.allowsNonContiguousLayout = NO;
    _logView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_logView];

    const auto make = ^UIButton*(NSString* title, SEL sel) {
        UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.backgroundColor = [UIColor systemGreenColor];
        b.layer.cornerRadius = 8;
        b.tintColor = [UIColor blackColor];
        b.titleLabel.font = [UIFont monospacedSystemFontOfSize:14
                                                     weight:UIFontWeightBold];
        [b setTitle:title forState:UIControlStateNormal];
        [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
        b.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
        [self.view addSubview:b];
        return b;
    };
    _rerun = make(@"Rerun", @selector(rerunTapped));
    _share = make(@"Share Log", @selector(shareTapped));
}
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    const CGFloat w = self.view.bounds.size.width;
    const CGFloat h = self.view.bounds.size.height;
    const CGFloat top = self.view.safeAreaInsets.top;
    const CGFloat bot = self.view.safeAreaInsets.bottom;
    const CGFloat margin = 12;
    _rerun.frame = CGRectMake(margin, top + 8, (w - margin * 3) / 2, 40);
    _share.frame =
        CGRectMake(w - margin - (w - margin * 3) / 2, top + 8, (w - margin * 3) / 2, 40);
    _logView.frame = CGRectMake(4, top + 56, w - 8, h - top - bot - 64);
    [self.view bringSubviewToFront:_rerun];
    [self.view bringSubviewToFront:_share];
}
- (void)refreshOnScreen {
    const std::string body = logTextFrozen();
    if (body.empty()) return;
    _logView.text = [NSString stringWithUTF8String:body.c_str()];
    [self->_logView scrollRangeToVisible:NSMakeRange(_logView.text.length, 0)];
}
- (void)rerunTapped {
    g_checks = 0;
    g_failed = 0;
    std::lock_guard<std::mutex> lk(g_logMutex);
    g_logLines.clear();
    _logView.text = @"";
    MCRunTestSession();
}
- (void)shareTapped {
    const std::string body = logTextFrozen() + "checks=" + std::to_string(g_checks) +
                             " failures=" + std::to_string(g_failed) + "\n";
    NSArray* dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                       NSUserDomainMask, YES);
    NSString* path = [dirs.firstObject stringByAppendingPathComponent:
                                         @"MC_TEST_LOG.txt"];
    FILE* f = fopen(path.fileSystemRepresentation, "w");
    if (f) {
        fwrite(body.data(), 1, body.size(), f);
        fclose(f);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIActivityViewController* avc =
            [[UIActivityViewController alloc]
                initWithActivityItems:@[ path ]
                              applicationActivities:nil];
        UIUserInterfaceIdiom idiom = [UIDevice currentDevice].userInterfaceIdiom;
        if (idiom == UIUserInterfaceIdiomPad) {
            avc.popoverPresentationController.sourceView = self->_share;
            avc.popoverPresentationController.sourceRect = self->_share.bounds;
        }
        [self presentViewController:avc animated:YES completion:nil];
    });
}
- (void)appendPending {
    [self refreshOnScreen];
}
@end

// ---------------------------------------------------------------------------
// Test blocks
// ---------------------------------------------------------------------------
static bool hasFamily(const mc::DeviceCaps& c, int raw) {
    return mc::supportsFamily(c, raw);
}

static void check(bool cond, const std::string& what) {
    ++g_checks;
    if (!cond) ++g_failed;
    log(std::string(cond ? "  PASS  " : "  FAIL  ") + what);
}

static void testDeviceBlock(const mc::DeviceCaps& caps) {
    log("== [D] device/capability summary ==");
    log("  name=" + caps.deviceName + " os=" + caps.osVersion + " [" +
        std::string(caps.platform == mc::PlatformKind::Ios ? "iOS" : "unknown-platform") +
        "]");
    log("  appleGpu=" + std::to_string(caps.appleGpu ? 1 : 0) +
        " metal4=" + std::to_string(caps.supportsMetal4 ? 1 : 0) +
        " argTier=" + std::to_string(caps.argumentBuffersTier) +
        " rwTier=" + std::to_string(caps.readWriteTextureTier));
    constexpr int fams[] = {mc::family::Apple1, mc::family::Apple2, mc::family::Apple3,
                            mc::family::Apple4, mc::family::Apple5, mc::family::Apple6,
                            mc::family::Apple7, mc::family::Apple8, mc::family::Apple9,
                            mc::family::Apple10, mc::family::Mac2, mc::family::Common1,
                            mc::family::Common2, mc::family::Common3,
                            mc::family::Metal3, mc::family::Metal4};
    std::string famsStr;
    for (int f : fams)
        if (hasFamily(caps, f)) {
            if (!famsStr.empty()) famsStr += ",";
            famsStr += familyLabelOf(f);
            famsStr += std::to_string(f);
        }
    log("  families=[" + famsStr + "]");
    log("  maxThreadsPerTG=" + std::to_string(caps.maxThreadsPerThreadgroup[0]) + "/" +
        std::to_string(caps.maxThreadsPerThreadgroup[1]) + "/" +
        std::to_string(caps.maxThreadsPerThreadgroup[2]) +
        "  maxBuffer=" + std::to_string((unsigned long long)caps.maxBufferLength));
    check(!caps.deviceName.empty(), "device probed with a name");
    check(caps.appleGpu, "this is an Apple GPU device");
}

static void testBufferBlock(void* dev) {
    log("== [B] buffers (M4) ==");
    MCOpBuffer buf{};
    if (mcops_newBuffer(dev, 1024, MCOP_STORAGE_AUTO, &buf) != 0 || !buf.handle) {
        check(false, "buffer create");
        return;
    }
    check(true, "buffer create (host-visible AUTO)");
    float src[256];
    for (int i = 0; i < 256; ++i) src[i] = i * 0.5f;
    check(mcops_writeBufferHost(&buf, src, sizeof(src)) == 0, "host write");
    float dst[256];
    check(mcops_readBufferHost(&buf, dst, sizeof(dst)) == 0, "host read");
    check(std::memcmp(src, dst, sizeof(src)) == 0, "host roundtrip exact");

    MCOpBuffer gpuBuf{};
    check(mcops_newBuffer(dev, 1024, MCOP_STORAGE_AUTO, &gpuBuf) == 0, "gpu dst create");
    check(mcops_copyBuffer(dev, 0, 0, buf.handle, gpuBuf.handle, sizeof(src)) == 0,
          "GPU buffer->buffer copy completed");
    float gpuDst[256];
    check(mcops_readBufferHost(&gpuBuf, gpuDst, sizeof(gpuDst)) == 0, "gpu readback");
    check(std::memcmp(src, gpuDst, sizeof(src)) == 0, "GPU copy bytes exact");

    void* sNearest = nullptr;
    void* sLinear = nullptr;
    check(mcops_newSampler(dev, 0, &sNearest) == 0 && sNearest, "nearest sampler");
    check(mcops_newSampler(dev, 1, &sLinear) == 0 && sLinear, "linear sampler");
    mcops_freeSampler(sNearest);
    mcops_freeSampler(sLinear);

    mcops_freeBuffer(&buf);
    mcops_freeBuffer(&gpuBuf);
}

static void testTextureBlock(void* dev) {
    log("== [T] texture staging roundtrip (M4) ==");
    constexpr uint32_t W = 32, H = 32;
    constexpr uint64_t rowBytes = W * 4;
    MCOpBuffer up{}, down{};
    void* tex8 = nullptr;
    if (mcops_newBuffer(dev, rowBytes * H, MCOP_STORAGE_AUTO, &up) != 0 ||
        mcops_newBuffer(dev, rowBytes * H, MCOP_STORAGE_AUTO, &down) != 0 ||
        mcops_newTexture(dev, W, H, MCOP_TEX_RGBA8_UNORM, &tex8) != 0 || !tex8) {
        check(false, "texture/staging setup");
        return;
    }
    check(true, "texture/staging setup");
    uint8_t pattern[W * H * 4];
    for (uint32_t j = 0; j < H; ++j)
        for (uint32_t i = 0; i < W; ++i) {
            uint8_t* p = pattern + 4 * (j * W + i);
            p[0] = (uint8_t)(i * 7 & 0xFF);
            p[1] = (uint8_t)(j * 11 & 0xFF);
            p[2] = (uint8_t)((i + j) * 3 & 0xFF);
            p[3] = 0xFF;
        }
    check(mcops_writeBufferHost(&up, pattern, rowBytes * H) == 0, "tex pattern staged");
    check(mcops_uploadTexture(dev, &up, tex8, W, H, rowBytes) == 0, "tex upload completed");
    std::memset(down.cpuAddress, 0xA5, rowBytes * H);
    check(mcops_downloadTexture(dev, tex8, W, H, rowBytes, &down) == 0,
          "tex download completed");
    check(std::memcmp(down.cpuAddress, pattern, rowBytes * H) == 0,
          "texture roundtrip exact");
    mcops_freeTexture(tex8);
    mcops_freeBuffer(&up);
    mcops_freeBuffer(&down);
}

static void testComputeBlock(void* dev, const mc::DeviceCaps& caps) {
    log("== [C] compute dispatch (M4) ==");
    void* lib = nullptr;
    void* pipe = nullptr;
    char err[512] = {0};
    if (mcops_compileLibraryEx(dev, kComputeAddMsl, mc::kMslLanguage_2_3, err,
                               sizeof(err), &lib) != 0 || !lib) {
        check(false, std::string("compute library compiled: ") + err);
        return;
    }
    check(true, "compute library compiled (MSL 2.3)");

    if (mcops_newComputePipeline(dev, lib, "vec_add", &pipe) != 0 || !pipe) {
        check(false, "compute pipeline created");
        mcops_freeLibrary(lib);
        return;
    }
    check(true, "compute pipeline created");

    constexpr uint32_t N = 1024;
    MCOpBuffer a{}, b{}, sum{};
    bool ok = mcops_newBuffer(dev, N * 4, MCOP_STORAGE_AUTO, &a) == 0 &&
              mcops_newBuffer(dev, N * 4, MCOP_STORAGE_AUTO, &b) == 0 &&
              mcops_newBuffer(dev, N * 4, MCOP_STORAGE_AUTO, &sum) == 0;
    check(ok, "compute buffers created");
    if (!ok) {
        mcops_freeComputePipeline(pipe);
        mcops_freeLibrary(lib);
        return;
    }
    float va[N], vb[N];
    for (uint32_t i = 0; i < N; ++i) {
        va[i] = (float)i * 0.25f;
        vb[i] = (float)(N - i) * 0.25f;
    }
    mcops_writeBufferHost(&a, va, N * 4);
    mcops_writeBufferHost(&b, vb, N * 4);
    const uint32_t tgs =
        (uint32_t)caps.maxThreadsPerThreadgroup[0] ? (uint32_t)caps.maxThreadsPerThreadgroup[0]
                                                   : 32;
    const uint32_t tpc = tgs < N ? tgs : N;
    const void* bufHandles[3] = {a.handle, b.handle, sum.handle};
    check(mcops_dispatchCompute(dev, pipe, N, tpc, bufHandles, 3) == 0,
          "dispatch completed");
    float out[N];
    check(mcops_readBufferHost(&sum, out, N * 4) == 0, "sum readback");
    bool exact = true;
    for (uint32_t i = 0; i < N; ++i)
        if (out[i] != va[i] + vb[i]) {
            exact = false;
            break;
        }
    check(exact, "vec_add results exact");

    mcops_freeBuffer(&a);
    mcops_freeBuffer(&b);
    mcops_freeBuffer(&sum);
    mcops_freeComputePipeline(pipe);
    mcops_freeLibrary(lib);
}

static void testFramesBlock(void* dev) {
    log("== [F] bounded frames-in-flight staging reuse (M4.5) ==");
    void* tex = nullptr;
    constexpr uint32_t W = 16, H = 16;
    constexpr uint64_t rowBytes = W * 4;
    MCOpBuffer up{}, down{};
    if (mcops_newTexture(dev, W, H, MCOP_TEX_RGBA8_UNORM, &tex) != 0 || !tex) {
        check(false, "frame tex created");
        return;
    }
    check(true, "frame tex created");
    if (mcops_newBuffer(dev, rowBytes * H, MCOP_STORAGE_AUTO, &up) != 0 ||
        mcops_newBuffer(dev, rowBytes * H, MCOP_STORAGE_AUTO, &down) != 0) {
        check(false, "frame buffers created");
        return;
    }
    bool allExact = true;
    for (int frame = 1; frame <= 3 && allExact; ++frame) {
        uint8_t expected[W * H * 4];
        for (size_t i = 0; i < sizeof expected; ++i)
            expected[i] = (uint8_t)(i * frame + 1);
        if (mcops_writeBufferHost(&up, expected, sizeof expected) != 0) allExact = false;
        if (allExact && mcops_uploadTexture(dev, &up, tex, W, H, rowBytes) != 0)
            allExact = false;
        if (allExact && mcops_downloadTexture(dev, tex, W, H, rowBytes, &down) != 0)
            allExact = false;
        if (allExact && std::memcmp(down.cpuAddress, expected, sizeof expected) != 0)
            allExact = false;
        log("  frame " + std::to_string(frame) +
            (allExact ? " exact" : " MISMATCH"));
    }
    check(allExact, "3 reused frames exact (bounded staging reuse)");
    mcops_freeTexture(tex);
    mcops_freeBuffer(&up);
    mcops_freeBuffer(&down);
}

static void testLayeredBlock(void* dev) {
    log("== [L] layer selection: native vs fallback vs CPU reference (M5) ==");
    const int gate = mcops_supportsLayerSelection(dev);
    log("  supportsLayerSelection=" + std::to_string(gate));
    bool refused = true;

    mc::ShaderVariantLibrary variants(
        [](const std::string& src, const std::string& key, void** outLib,
           std::string& err) -> mc::Error {
            (void)key;
            char buf[512] = {0};
            const int rc = mcops_compileLibraryEx(mcmtl_deviceHandle(), src.c_str(),
                                                  mc::kMslLanguage_2_3, buf,
                                                  sizeof(buf), outLib);
            if (rc != 0) err.assign(buf);
            return rc == 0 ? mc::Error{}
                           : mc::Error{mc::ErrorCode::BridgeFailure, "", err};
        },
        +[](void* libHandle) noexcept { mcops_freeLibrary(libHandle); }, 8);

    mc::CompiledVariant vN, vF;
    if (!variants.getVariant(kLayeredMslBody, {{"MC_LAYER_FROM_UNIFORM", "0"}},
                             mc::kMslLanguage_2_3, vN) &&
        !variants.getVariant(kLayeredMslBody, {{"MC_LAYER_FROM_UNIFORM", "1"}},
                             mc::kMslLanguage_2_3, vF)) {
        check(vN.library && vF.library && vN.library != vF.library,
              "two layer-select variants compiled into distinct libraries");
    } else
        check(false, "layered variants compiled (both guises)");

    void* pipeN = nullptr;
    void* pipeF = nullptr;
    if (mcops_newRenderPipeline(dev, vN.library, "vs_main", "fs_main", 1, &pipeN) != 0)
        log("  native pipeline UNAVAILABLE (unrelated failure below if rc!=0)");
    if (mcops_newRenderPipeline(dev, vF.library, "vs_main", "fs_main", 0, &pipeF) != 0)
        log("  fallback pipeline UNAVAILABLE");
    if (!pipeN || !pipeF) {
        check(false, "render pipelines built (native+fallback)");
        return;
    }
    check(true, "render pipelines built (native topology=Triangle)");

    constexpr uint32_t W = 64;
    constexpr uint32_t H = 64;
    constexpr uint32_t S = 4;
    constexpr uint64_t rowBytes = W * 4;
    void* tex = nullptr;
    if (mcops_newTextureArray(dev, W, H, S, &tex) != 0 || !tex) {
        check(false, "2DArray (4 slices) created");
        return;
    }
    MCOpBuffer mesh{}, uni{}, down{};
    mcops_newBuffer(dev, 24, MCOP_STORAGE_AUTO, &mesh);
    mcops_newBuffer(dev, S * 32, MCOP_STORAGE_AUTO, &uni);
    mcops_newBuffer(dev, rowBytes * H, MCOP_STORAGE_AUTO, &down);
    const float meshData[3][2] = {{-1.0f, -1.0f}, {3.0f, -1.0f}, {-1.0f, 3.0f}};
    mcops_writeBufferHost(&mesh, meshData, sizeof meshData);
    uint8_t staged[S * 32] = {};
    for (uint32_t s = 0; s < S; ++s) std::memcpy(staged + s * 32, &s, 4);
    mcops_writeBufferHost(&uni, staged, sizeof staged);

    MCLayeredRenderParams rp{};
    rp.colorTexture = tex;
    rp.meshBuffer = mesh.handle;
    rp.layerUniforms = uni.handle;
    rp.pipeline = pipeN;
    rp.viewportWidth = W;
    rp.viewportHeight = H;
    rp.sliceCount = S;
    rp.clearR = 0.0f;
    rp.clearG = 0.0f;
    rp.clearB = 0.0f;
    rp.clearA = 1.0f;

    // CPU reference: expected pixel per slice (dyadic fp32 math, exact).
    uint8_t expected[S][W * H * 4];
    for (uint32_t s = 0; s < S; ++s)
        for (uint32_t y = 0; y < H; ++y)
            for (uint32_t x = 0; x < W; ++x) {
                const float r = (float)s * 0.25f + (float)x / 1024.0f;
                const float g = (float)y / 1024.0f;
                const float ce[4] = {r, g, 0.5f, 1.0f};
                uint8_t* pe = &expected[s][((y * W) + x) * 4];
                for (int i = 0; i < 4; ++i) pe[i] = (uint8_t)(ce[i] * 255.0f + 0.5f);
            }

    auto renderAndVerify = [&](void* pipeHandle, const char* tag) {
        MCLayeredRenderParams p = rp;
        p.pipeline = pipeHandle;
        const int rc = mcops_renderLayeredNative(dev, &p);
        if (rc != 0) {
            if (rc == 6) {
                log("  native path REFUSED (rc=6), hardware gate unmet —");
                log(" Per Apple's docs layer selection is ONLY Apple5+/any macOS.");
                log(" This device must run the per-slice FALLBACK translation.");
                return;
            }
            check(false, std::string(tag) + " render rc=" + std::to_string(rc));
            return;
        }
        check(true, std::string(tag) + " rendered");
        for (uint32_t s = 0; s < S; ++s) {
            if (mcops_downloadTextureSlice(dev, tex, s, 0, down.handle) != 0) {
                check(false, "slice " + std::to_string(s) + " download");
                continue;
            }
            const uint8_t* got = (const uint8_t*)down.cpuAddress;
            bool all = true;
            int worst = 0;
            for (uint32_t i = 0; i < rowBytes * H; ++i) {
                const int d = (int)got[i] - (int)expected[s][i];
                if (std::abs(d) > 1) {
                    all = false;
                    break;
                }
                if (std::abs(d) > std::abs(worst)) worst = d;
            }
            if (!all) g_failed += 1; // avoid check() on the obvious case
            check(all, std::string(tag) + " slice " + std::to_string(s) +
                           (all ? "" : " (worst=" + std::to_string(worst) + ")") +
                           " matches CPU (tolerance 1)");
        }
    };

    renderAndVerify(pipeN, "native");
    if (g_failed == 0) {
        refused = false; // native succeeded
        log("  native layer selection WORKS (renderTargetArrayLength=" +
            std::to_string(S) + ")");
    }
    if (gate == 1 && refused) check(false, "gate reports 1 but native op refused");

    {
        MCLayeredRenderParams p = rp;
        p.pipeline = pipeF;
        const int rcF = mcops_renderLayeredFallback(dev, &p);
        if (rcF != 0) check(false, "fallback render rc=" + std::to_string(rcF));
        else {
            check(true, "fallback rendered");
            for (uint32_t s = 0; s < S; ++s) {
                if (mcops_downloadTextureSlice(dev, tex, s, 0, down.handle) != 0) {
                    check(false, "slice " + std::to_string(s) + " download (F)");
                    continue;
                }
                const uint8_t* got = (const uint8_t*)down.cpuAddress;
                bool all = true;
                for (uint32_t i = 0; i < rowBytes * H; ++i)
                    if (std::abs((int)got[i] - (int)expected[s][i]) > 1) {
                        all = false;
                        break;
                    }
                check(all, "fallback slide " + std::to_string(s) +
                               (all ? " exact" : " MISMATCH, see above"));
            }
        }
    }

    mcops_freeTexture(tex);
    mcops_freeBuffer(&mesh);
    mcops_freeBuffer(&uni);
    mcops_freeBuffer(&down);
    mcops_freeRenderPipeline(pipeN);
    mcops_freeRenderPipeline(pipeF);
    variants.releaseVariant(vN.cookie);
    variants.releaseVariant(vF.cookie);
}

static void testArgT1Block(void* dev) {
    log("== [A] tier-1 argument buffers prototype (M7) ==");
    const int gate = mcops_argT1Support(dev);
    log("  argumentBuffersSupport gate=" + std::to_string(gate) +
        " (1=Tier1+, 0=none, -1=gate unresolvable)");
    if (gate != 1) {
        log("  SKIPPED on this device/op-system combination");
        return;
    }
    constexpr uint32_t N = 256;
    MCOpBuffer src{}, dstC{}, dstT1{};
    if (mcops_newBuffer(dev, N * 4, MCOP_STORAGE_AUTO, &src) != 0 ||
        mcops_newBuffer(dev, N * 4, MCOP_STORAGE_AUTO, &dstC) != 0 ||
        mcops_newBuffer(dev, N * 4, MCOP_STORAGE_AUTO, &dstT1) != 0) {
        check(false, "argt1 buffers created");
        return;
    }
    uint32_t seed = 0x1234567u;
    uint32_t vals[N];
    for (uint32_t i = 0; i < N; ++i) {
        seed ^= seed << 13u;
        seed ^= seed >> 17u;
        seed ^= seed << 5u;
        vals[i] = seed;
    }
    mcops_writeBufferHost(&src, vals, sizeof vals);
    const int rc = mcops_argT1Prototype(dev, src.handle, dstC.handle, dstT1.handle, N);
    if (rc != 0) check(false, "tier-1 prototype rc=" + std::to_string(rc));
    else {
        check(true, "tier-1 prototype completed all steps");
        const uint32_t* a = (const uint32_t*)dstC.cpuAddress;
        const uint32_t* b = (const uint32_t*)dstT1.cpuAddress;
        bool same = true;
        for (uint32_t i = 0; i < N && same; ++i)
            if (a[i] != b[i]) same = false;
        check(same, "classic == tier-1 argument-buffer outputs");
    }
    mcops_freeBuffer(&src);
    mcops_freeBuffer(&dstC);
    mcops_freeBuffer(&dstT1);
}

// Exposed so the Rerun button can schedule it again.
extern "C" void MCRunTestSession(void);

void MCRunTestSession(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        const auto g0 = std::chrono::steady_clock::now();
        openLogFile();
        log("MCRenderTest session v1.1 (built " __DATE__ " " __TIME__ ")");
        mc::DeviceCaps caps;
        const int rc = mcmtl_probeDefaultDevice(&caps);
        if (rc != 0) {
            log("FATAL: no Metal device (rc=" + std::to_string(rc) + ")");
            return;
        }
        void* dev = mcmtl_deviceHandle();
        runBlock("[D] device-summary", [&] { testDeviceBlock(caps); });
        runBlock("[B] buffers", [&] { testBufferBlock(dev); });
        runBlock("[T] texture-staging", [&] { testTextureBlock(dev); });
        runBlock("[C] compute", [&] { testComputeBlock(dev, caps); });
        runBlock("[F] frames-reuse", [&] { testFramesBlock(dev); });
        runBlock("[L] layer-selection", [&] { testLayeredBlock(dev); });
        runBlock("[A] tier1-argbufs", [&] { testArgT1Block(dev); });
        const auto g1 = std::chrono::steady_clock::now();
        const double ms = std::chrono::duration<double, std::milli>(g1 - g0).count();
        log("== [S] summary ==");
        log("  result: checks=" + std::to_string(g_checks) + " failures=" +
            std::to_string(g_failed) + "  wall=" + std::to_string(ms) + " ms");
        log(g_failed == 0
                ? "ALL GREEN — MetalCompat ops behave identically on-device"
                : "FAILURES PRESENT — see FAIL lines above");
    });
}

// Trailing periodic refresh hook, driven by a 1s main-thread cadence.
static void MCStartUiRefreshTimer(RunScreen* vc) {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC,
                              0.2 * NSEC_PER_SEC);
    __weak RunScreen* weak = vc;
    dispatch_source_set_event_handler(timer, ^{ [weak refreshOnScreen]; });
    objc_setAssociatedObject(vc, "runTimer", timer, OBJC_ASSOCIATION_RETAIN);
}

static void MCCrashDump(int sig) {
    if (g_logFile) {
        // Diagnostics app: buffered fprintf in a dying process is acceptable.
        fprintf(g_logFile, "\n! CRASHED during the test after this line (signal=%d)\n",
                sig);
        fclose(g_logFile);
        g_logFile = nullptr;
    }
    _exit(0);
}

static void MCUncaughtHandler(NSException* ex) {
    log("[EXC-HANDLER] " +
        std::string(ex.name ? ex.name.UTF8String : "?") + ": " +
        std::string(ex.reason ? ex.reason.UTF8String : "no reason"));
    if (g_logFile) fclose(g_logFile);
    g_logFile = nullptr;
}

static void MCInstallCrashHooks() {
    signal(SIGSEGV, MCCrashDump);
    signal(SIGABRT, MCCrashDump);
    signal(SIGBUS, MCCrashDump);
    NSSetUncaughtExceptionHandler(&MCUncaughtHandler);
}

// ---------------------------------------------------------------------------
// AppDelegate
// ---------------------------------------------------------------------------
@interface MCAppDelegate : NSObject <UIApplicationDelegate>
@end
@implementation MCAppDelegate {
    UIWindow* _window;
}
- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
    (void)application;
    (void)launchOptions;
    _window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    _window.backgroundColor = [UIColor blackColor];
    RunScreen* vc = [RunScreen new];
    _window.rootViewController = vc;
    [_window makeKeyAndVisible];
    MCInstallCrashHooks();
    MCStartUiRefreshTimer(vc);
    MCRunTestSession();
    return YES;
}
@end

int main(int argc, char* argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, (char**)argv, nil,
                                 NSStringFromClass([MCAppDelegate class]));
    }
}
