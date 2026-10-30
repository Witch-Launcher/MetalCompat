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
#import <Metal/Metal.h>
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

// RT probe (MSL 2.4 — Apple6+/A14 hardware): BLAS+TLAS then ray queries.
// 3 rays, all origin (0, 0.25, 2); quarter 1 hits the triangle plane z=-0.5
// at t=2.5 (exact dyadic), rays 2/3 go away (distance=inf, instance=none).
static const char kRtProbeMsl[] = R"MSL(
#include <metal_stdlib>
#include <metal_raytracing>
using namespace metal;
using namespace metal::raytracing;

struct RtHit { float dist; uint iid; };

kernel void rt_probe(device const float3* ro [[buffer(0)]],
                     device const float3* rd [[buffer(1)]],
                     acceleration_structure<instancing> as [[buffer(2)]],
                     device RtHit* out [[buffer(3)]],
                     uint tid [[thread_position_in_grid]]) {
    intersector<float, instancing> i;
    auto h = i.intersect(as, ray(ro[tid], rd[tid]));
    RtHit o;
    o.dist = h.distance;
    o.iid = h.instance_id;
    out[tid] = o;
}
)MSL";

// ---------------------------------------------------------------------------
// [RT-VIEW] Real on-device ray-traced scene v1.3 — follows the official Apple
// sample "Accelerating ray tracing using Metal" patterns (BLAS/TLAS build via
// accelerationStructureCommandEncoder, per-instance descriptors packed as
// MTLPackedFloat4x3 columns, fullscreen-quad copy pass with tonemapping,
// compute->texture->drawable in one command buffer — verified against that
// sample's Shaders.metal + Renderer.mm), adapted into a deterministic
// animated Whitted scene: two point lights with real shadow rays, mirror
// reflections, emissive lamp, listening into a CAMetalLayer every frame.
// Hardware facts (Metal Feature Set Tables + Apple Tech Talks): the Metal RT
// API is available on Apple6+ (A13 = iPhone 11 and later) and runs in
// SOFTWARE there; hardware-accelerated ray tracing starts at Apple9
// (A17 Pro / M3 / M4). A11 = Apple4 has NO ray tracing at all.
//
// Scene layout (TLAS instance_id, fixed):
//   0 floor checker quad | 1 mirror sphere | 2 red diffuse
//   3 blue glossy        | 4 emissive lamp sphere
// All five objects share ONE vertex+normal pool (packed_float3, 12 B/vertex);
// VB_BASE per instance lets the kernel fetch its triangle sub-range.
static const int kSphStacks = 22, kSphRings = 12;
static const int kSphVerts = (kSphStacks + 1) * (kSphRings + 1);  // 299
static const int kSphTris = 2 * kSphStacks * kSphRings;           // 528
// Vertex pool: 6 floor verts + 4 spheres; spheres' vBase derived from that.
static const int kMirrorVBase = 6;
static const int kRedVBase = 6 + 1 * kSphVerts;
static const int kBlueVBase = 6 + 2 * kSphVerts;
static const int kLampVBase = 6 + 3 * kSphVerts;

static constexpr float kRTSceneCenter[3] = {0.0f, 0.7f, 0.0f};
static constexpr float kRTFloorHalf = 7.0f;

static int rtVertexCount() { return 6 + 4 * kSphVerts; }
static int rtTriangleCount() { return 2 + 4 * kSphTris; }

// CPU-side uniform struct; MUST byte-match MSL `struct U` below (verified by
// static_assert), because uniforms ride on one shared storage buffer.
struct RTUniforms {
    float camPos[4], camRight[4], camUp[4], camFwd[4];
    uint32_t res[2];
    float time, pad;
    float lightPos[2][4], lightCol[2][4];
};
static_assert(sizeof(RTUniforms) == 144, "MSL struct U layout mismatch");

// MSL 2.4 source for the whole RT view (scene kernel + fullscreen-quad copy
// pass). The vertex-pool base offsets are baked per instance so the kernel can
// fetch its triangles deterministically.
static std::string rtBuildShadeSource() {
    char src[8192];
    snprintf(src, sizeof(src), R"MSL(
#include <metal_stdlib>
#include <metal_raytracing>
using namespace metal;
using namespace metal::raytracing;

struct U {
    float4 camPos; float4 camRight; float4 camUp; float4 camFwd;
    uint2 res; float time; float pad;
    float4 lightPos[2]; float4 lightCol[2];
};

// Vertex-pool base per TLAS instance_id (0 floor, 1 mirror, 2 red, 3 blue,
// 4 lamp). Floor quad occupies vertices 0..5.
constant uint VB_BASE[5] = {%d, %d, %d, %d, %d};

kernel void rt_shade(constant U& u [[buffer(0)]],
                     acceleration_structure<instancing> as [[buffer(1)]],
                     device const packed_float3* vb [[buffer(2)]],
                     device const packed_float3* nb [[buffer(3)]],
                     texture2d<float, access::write> dst [[texture(0)]],
                     uint2 tid [[thread_position_in_grid]]) {
    if (tid.x >= u.res.x || tid.y >= u.res.y) return;

    const float2 uv = (float2(tid) + 0.5f) / float2(u.res);
    const float2 ndc = uv * 2.0f - 1.0f;

    const float tanf = 0.47f;  // ~51-degree vertical FOV
    const float3 dir = normalize(u.camFwd.xyz +
                                 u.camRight.xyz * (ndc.x * tanf) +
                                 u.camUp.xyz   * (ndc.y * tanf));

    intersector<float, instancing> rt;
    rt.assume_geometry_type(geometry_type::triangle);
    rt.force_opacity(forced_opacity::opaque);

    ray r;
    r.origin = u.camPos.xyz;
    r.direction = dir;
    r.max_distance = 1e30f;

    float3 col = float3(0.0f);
    float3 atten = float3(1.0f);

    for (int b = 0; b < 3; ++b) {
        const auto h = rt.intersect(r, as);
        if (h.type == intersection_type::none) {
            col += atten * float3(0.015f, 0.02f, 0.035f);
            break;
        }

        const uint iid = h.instance_id;
        const uint ti  = h.primitive_id;
        const float3 p = r.origin + r.direction * h.distance;
        const float2 bc = h.triangle_barycentric_coord;

        const uint base = VB_BASE[iid] + ti * 3;
        const float3 n0 = float3(nb[base].x, nb[base].y, nb[base].z);
        const float3 n1 = float3(nb[base+1].x, nb[base+1].y, nb[base+1].z);
        const float3 n2 = float3(nb[base+2].x, nb[base+2].y, nb[base+2].z);
        float3 n = normalize((1.0f - bc.x - bc.y) * n0 + bc.x * n1 + bc.y * n2);
        if (dot(n, r.direction) > 0.0f) n = -n;  // two-sided

        if (iid == 4) {  // emissive lamp
            col += atten * float3(3.2f, 2.5f, 1.6f);
            break;
        }

        float3 alb;
        float refl;
        if (iid == 0) {
            // Checker floor (world-space diagnostic pattern).
            const int ci = int(floor(p.x * 0.5f)) + int(floor(p.z * 0.5f));
            alb = (ci & 1) ? float3(0.62f, 0.61f, 0.59f)
                           : float3(0.14f, 0.145f, 0.155f);
            refl = 0.0f;
        } else if (iid == 1) {
            alb = float3(0.07f, 0.07f, 0.085f);
            refl = 0.9f;
        } else if (iid == 2) {
            alb = float3(0.85f, 0.17f, 0.13f);
            refl = 0.0f;
        } else {
            alb = float3(0.16f, 0.38f, 0.92f);
            refl = 0.36f;
        }

        // Direct lighting: two point lights with real shadow rays.
        const float3 sp = p + n * 1e-3f;
        for (int li = 0; li < 2; ++li) {
            const float3 Ld = u.lightPos[li].xyz - sp;
            const float d2 = dot(Ld, Ld);
            const float dist = sqrt(d2);
            const float3 L = Ld / max(dist, 1e-6f);
            const float ndl = dot(n, L);
            if (ndl <= 0.0f) continue;
            ray sr;
            sr.origin = sp;
            sr.direction = L;
            sr.max_distance = dist - 2e-3f;
            rt.accept_any_intersection(true);
            if (rt.intersect(sr, as).type == intersection_type::none) {
                col += atten * alb * u.lightCol[li].xyz *
                       (ndl / max(d2, 0.15f));
            }
        }
        col += atten * alb * float3(0.05f, 0.055f, 0.065f);

        if (refl <= 0.0f || b == 2) break;
        atten *= (iid == 1) ? float3(0.92f) : float3(0.36f);
        r.origin = p + n * 1e-3f;
        r.direction = normalize(reflect(r.direction, n));
    }
    dst.write(float4(col, 1.0f), tid);
}

constant float2 quadVerts[] = {
    float2(-1, -1), float2(-1, 1), float2(1, 1),
    float2(-1, -1), float2(1, 1),  float2(1, -1)
};
struct QOut { float4 pos [[position]]; float2 uv; };
vertex QOut quadVert(unsigned vid [[vertex_id]]) {
    QOut o;
    o.pos = float4(quadVerts[vid], 0.0, 1.0);
    o.uv = quadVerts[vid] * 0.5f + 0.5f;
    return o;
}
fragment float4 quadFrag(QOut in [[stage_in]], texture2d<float> tex) {
    constexpr sampler s(min_filter::linear, mag_filter::linear);
    float3 c = tex.sample(s, in.uv).rgb;
    c = c / (1.0f + c);          // Reinhard
    c = pow(c, float3(1.0f / 2.2f));  // gamma
    return float4(c, 1.0f);
}
)MSL",
        0 /* floor quad base */ + 0,
        6,
        6 + kSphVerts,
        6 + 2 * kSphVerts,
        6 + 3 * kSphVerts);
    return src;
}

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
// [RT-VIEW] live scene camera. Scene sphere table (TLAS instance order
// 1 mirror / 2 red / 3 blue / 4 lamp): {cx, cy, cz, radius, reflectivity}.
static const float kSceneSpheres[4][5] = {
    {-1.15f, 0.85f, 0.0f,   0.85f, 0.90f},
    { 0.95f, 0.68f, -0.55f, 0.68f, 0.0f },
    { 0.35f, 0.58f, 0.95f,  0.58f, 0.36f},
    { 0.10f, 2.45f, -1.25f, 0.26f, 0.0f },
};

// ---------------------------------------------------------------------------
// CAMetalLayer-backed view for the live RT viewport.
@interface RtLayerView : UIView
@end
@implementation RtLayerView
+ (Class)layerClass {
    return [CAMetalLayer class];
}
@end

// Full engine interface declared here; implementation lives below the test
// blocks (needs the check()/log() harness which is defined later in the file).
@interface RtEngine : NSObject
- (void)attachLayer:(CAMetalLayer*)layer overlay:(UILabel*)overlay;
- (void)start;
- (void)pause;
- (void)resume;
@end

// ---------------------------------------------------------------------------
// Run screen: top = live ray-traced viewport ([RT-VIEW]), bottom = test log.
@interface RunScreen : UIViewController
@end
@implementation RunScreen {
    UITextView* _logView;
    UIButton* _rerun;
    UIButton* _share;
    RtLayerView* _rtView;
    UILabel* _rtOverlay;
    RtEngine* _rtEngine;
    bool _rtStarted;
}
- (void)loadView {
    [super loadView];
    self.view.backgroundColor = [UIColor blackColor];
    _logView = [[UITextView alloc] initWithFrame:self.view.bounds];
    _logView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    _logView.textColor = [UIColor whiteColor];
    _logView.backgroundColor = [UIColor blackColor];
    _logView.editable = NO;
    _logView.autocorrectionType = UITextAutocorrectionTypeNo;
    _logView.spellCheckingType = UITextSpellCheckingTypeNo;
    _logView.layoutManager.allowsNonContiguousLayout = NO;
    _logView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_logView];

    _rtView = [[RtLayerView alloc] initWithFrame:CGRectMake(0, 0, 100, 100)];
    _rtView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                               UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_rtView];

    _rtOverlay = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, 100, 100)];
    _rtOverlay.textColor = [UIColor systemOrangeColor];
    _rtOverlay.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium];
    _rtOverlay.numberOfLines = 0;
    _rtOverlay.textAlignment = NSTextAlignmentCenter;
    _rtOverlay.hidden = YES;
    _rtOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                  UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_rtOverlay];

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
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_rtStarted) return;
    _rtStarted = true;
    _rtEngine = [[RtEngine alloc] init];
    [_rtEngine attachLayer:(CAMetalLayer*)_rtView.layer overlay:_rtOverlay];
    [_rtEngine start];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_rtEngine pause];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [_rtEngine resume];
}
- (void)dealloc {
    [_rtEngine pause];
    // ARC on; ivars released automatically.
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
    const CGFloat rtH = (h - top - bot - 58) * 0.44f;
    const CGFloat rtY = top + 56;
    _rtView.frame = CGRectMake(0, rtY, w, rtH);
    _rtOverlay.frame = CGRectMake(10, rtY + 14, w - 20, rtH - 28);
    _logView.frame = CGRectMake(4, rtY + rtH + 10, w - 8,
                                h - (rtY + rtH + 10) - bot - 6);
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

    auto renderAndVerify = [&](void* pipeHandle, const char* tag, int* outRc) {
        MCLayeredRenderParams p = rp;
        p.pipeline = pipeHandle;
        const int rc = mcops_renderLayeredNative(dev, &p);
        *outRc = rc;
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

    int nativeRc = -1;
    renderAndVerify(pipeN, "native", &nativeRc);
    if (nativeRc == 0) {
        log("  native layer selection WORKS (renderTargetArrayLength=" +
            std::to_string(S) + ")");
    } else if (nativeRc == 6) {
        log("  native path unavailable on this hardware (rc=6): per-slice");
        log("  fallback translation carries the session (Apple<5 iOS device).");
    }
    if (gate == 1 && nativeRc != 0) check(false, "gate reports 1 but native op refused");

    {
        MCLayeredRenderParams p = rp;
        p.pipeline = pipeF;
        const int rcF = mcops_renderLayeredFallback(dev, &p);
        if (rcF != 0) {
            check(false, "fallback render rc=" + std::to_string(rcF));
        } else {
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

static void testRtBlock(void* dev, const mc::DeviceCaps& caps) {
    log("== [R] ray tracing: BLAS+TLAS + ray query (gate Apple6+/A14) ==");
    id<MTLDevice> devc = (__bridge id<MTLDevice>)dev;
    const bool rtSel = [devc supportsRaytracing] == YES;
    const bool f6 = mc::supportsFamily(caps, mc::family::Apple6);
    const bool f7 = mc::supportsFamily(caps, mc::family::Apple7) ||
                    mc::supportsFamily(caps, mc::family::Apple8) ||
                    mc::supportsFamily(caps, mc::family::Apple9) ||
                    mc::supportsFamily(caps, mc::family::Apple10);
    log("  supportsRaytracing=" + std::to_string(rtSel) + " apple6=" + std::to_string(f6) +
        " apple7+=" + std::to_string(f7));
    check(rtSel == (f6 || f7),
          "supportsRaytracing agrees with the Apple6+/A14-family gate");

    void* lib = nullptr;
    char err[512] = {0};
    int rc = mcops_compileLibraryEx(dev, kRtProbeMsl, 240, err, sizeof(err), &lib);
    if (!rtSel) {
        // Non-RT hardware (Apple4/A11...): the compiler MUST refuse the kernel.
        if (lib) mcops_freeLibrary(lib);
        check(lib == nullptr,
              "intersector kernel correctly REFUSED on non-RT hardware (rc=" +
              std::to_string(rc) + ")");
        log("  compiler diagnostics: " + std::string(err));
        return;
    }
    if (rc != 0 || !lib) {
        check(false, std::string("intersector kernel compiled on RT hardware: ") + err);
        return;
    }
    check(true, "MSL 2.4 intersector kernel compiled");
    id<MTLLibrary> rtLib = (__bridge_transfer id<MTLLibrary>)lib;
    id<MTLFunction> fn = [rtLib newFunctionWithName:@"rt_probe"];
    if (!fn) { check(false, "rt_probe function found"); return; }
    check(true, "rt_probe function found");

    // Vertex buffer: one triangle A(0,-0.5,-0.5) B(0.6,0.5,-0.5) C(-0.6,0.5,-0.5).
    MCOpBuffer vt{}, ro{}, rd{}, hits{}, inst{};
    bool bufOk = mcops_newBuffer(dev, 3 * 3 * 4, MCOP_STORAGE_AUTO, &vt) == 0 &&
                 mcops_newBuffer(dev, 32 * 3 * 4, MCOP_STORAGE_AUTO, &ro) == 0 &&
                 mcops_newBuffer(dev, 32 * 3 * 4, MCOP_STORAGE_AUTO, &rd) == 0 &&
                 mcops_newBuffer(dev, 32 * 8, MCOP_STORAGE_AUTO, &hits) == 0 &&
                 mcops_newBuffer(dev, sizeof(MTLAccelerationStructureInstanceDescriptor),
                                 MCOP_STORAGE_AUTO, &inst) == 0;
    if (!bufOk) { check(false, "rt buffers created"); return; }
    const float verts[9] = {0.0f, -0.5f, -0.5f,   0.6f, 0.5f, -0.5f,  -0.6f, 0.5f, -0.5f};
    const float roBase[3] = {0.0f, 0.25f, 2.0f};
    const float dirs[3][3] = {{0.0f, 0.0f, -1.0f},   // hit t=2.5
                              {1.0f, 0.0f, -0.001f}, // miss
                              {0.0f, 1.0f, 0.0f}};   // miss (upward)
    float ro_data[32 * 3];
    float rd_data[32 * 3];
    for (uint32_t t = 0; t < 32; ++t) {
        const uint32_t sky = t % 3;
        for (int i = 0; i < 3; ++i) {
            ro_data[t * 3 + i] = roBase[i];
            rd_data[t * 3 + i] = dirs[sky][i];
        }
    }
    mcops_writeBufferHost(&vt, verts, sizeof verts);
    mcops_writeBufferHost(&ro, ro_data, sizeof ro_data);
    mcops_writeBufferHost(&rd, rd_data, sizeof rd_data);

    // BLAS: one triangle.
    MTLAccelerationStructureTriangleGeometryDescriptor* g =
        [MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
    g.vertexBuffer = (__bridge id<MTLBuffer>)vt.handle;
    g.vertexStride = 12;
    g.triangleCount = 1;
    MTLPrimitiveAccelerationStructureDescriptor* blasDesc =
        [MTLPrimitiveAccelerationStructureDescriptor descriptor];
    blasDesc.geometryDescriptors = @[ g ];

    // TLAS: one instance (identity transform) of that BLAS.
    MTLAccelerationStructureInstanceDescriptor* idp =
        (MTLAccelerationStructureInstanceDescriptor*)inst.cpuAddress;
    MTLPackedFloat4x3 ident(MTLPackedFloat3(1, 0, 0), MTLPackedFloat3(0, 1, 0),
                            MTLPackedFloat3(0, 0, 1), MTLPackedFloat3(0, 0, 0));
    idp->transformationMatrix = ident;
    idp->options = 0;
    idp->mask = 1;
    idp->intersectionFunctionTableOffset = 0;
    idp->accelerationStructureIndex = 0;

    MTLInstanceAccelerationStructureDescriptor* tlasDesc =
        [MTLInstanceAccelerationStructureDescriptor descriptor];
    tlasDesc.instanceDescriptorBuffer = (__bridge id<MTLBuffer>)inst.handle;
    tlasDesc.instanceDescriptorStride = sizeof(MTLAccelerationStructureInstanceDescriptor);
    tlasDesc.instanceCount = 1;
    if (@available(ios 15.0, *)) {
        tlasDesc.instanceDescriptorType =
            MTLAccelerationStructureInstanceDescriptorTypeDefault;
    }

    // Sizes + allocations
    MTLAccelerationStructureSizes bs = [devc accelerationStructureSizesWithDescriptor:blasDesc];
    MTLAccelerationStructureSizes ts = [devc accelerationStructureSizesWithDescriptor:tlasDesc];
    id<MTLAccelerationStructure> blas = [devc newAccelerationStructureWithSize:bs.accelerationStructureSize];
    id<MTLAccelerationStructure> tlas = [devc newAccelerationStructureWithSize:ts.accelerationStructureSize];
    id<MTLBuffer> scratchB = [devc newBufferWithLength:bs.buildScratchBufferSize
                                              options:MTLResourceStorageModePrivate];
    id<MTLBuffer> scratchT = [devc newBufferWithLength:ts.buildScratchBufferSize
                                              options:MTLResourceStorageModePrivate];
    if (!blas || !tlas || !scratchB || !scratchT) { check(false, "rt allocations"); return; }
    check(true, "BLAS+TLAS allocations obtained");

    MTLAccelerationStructureInstanceDescriptor instCopy = *idp;
    tlasDesc.instancedAccelerationStructures = @[ blas ];

    id<MTLCommandQueue> q = [devc newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLAccelerationStructureCommandEncoder> ase = [cb accelerationStructureCommandEncoder];
    [ase buildAccelerationStructure:blas descriptor:blasDesc scratchBuffer:scratchB scratchBufferOffset:0];
    [ase buildAccelerationStructure:tlas descriptor:tlasDesc scratchBuffer:scratchT scratchBufferOffset:0];
    [ase endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    check(cb.status == MTLCommandBufferStatusCompleted,
          "acceleration structures built on-device");

    id<MTLComputePipelineState> ps = [devc newComputePipelineStateWithFunction:fn error:nil];
    if (!ps) { check(false, "rt compute pipeline"); return; }
    const NSUInteger tgs = [ps maxTotalThreadsPerThreadgroup];
    const NSUInteger nt = tgs < 32 ? tgs : 32;
    id<MTLCommandQueue> q2 = [devc newCommandQueue];
    id<MTLCommandBuffer> cb2 = [q2 commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb2 computeCommandEncoder];
    [ce setComputePipelineState:ps];
    [ce setBuffer:(__bridge id<MTLBuffer>)ro.handle offset:0 atIndex:0];
    [ce setBuffer:(__bridge id<MTLBuffer>)rd.handle offset:0 atIndex:1];
    [ce setBuffer:(__bridge id<MTLBuffer>)hits.handle offset:0 atIndex:3];
    [ce setAccelerationStructure:tlas atBufferIndex:2];
    [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(nt, 1, 1)];
    [ce endEncoding];
    [cb2 commit];
    [cb2 waitUntilCompleted];
    check(cb2.status == MTLCommandBufferStatusCompleted, "ray-query dispatch completed");

    struct RtHit { float dist; uint iid; };
    RtHit outv[32];
    mcops_readBufferHost(&hits, outv, sizeof outv);
    check(outv[0].dist > 2.4999f && outv[0].dist < 2.5001f,
          "hit ray t=2.5 exact (got " + std::to_string(outv[0].dist) + ")");
    check(outv[0].iid == 0, "hit instance_id == 0");
    check(outv[1].dist > 1e30f && outv[2].dist > 1e30f, "miss rays report +inf distance");

    mcops_freeBuffer(&vt);
    mcops_freeBuffer(&ro);
    mcops_freeBuffer(&rd);
    mcops_freeBuffer(&hits);
    mcops_freeBuffer(&inst);
}

// ---------------------------------------------------------------------------
// [X] MSL cross-version matrix (Metal 1.1 .. 4.0): compile the SAME canonical
// kernel at every published language version and verify the executed results
// are byte-identical to a CPU reference and to each other. Honest states:
// versions the device/OS refuses are logged with the compiler's diagnostics;
// accepted versions must produce identical bytes.
static const char kXFillMsl[] = R"MSL(
#include <metal_stdlib>
using namespace metal;
kernel void xfill(device const float* a [[buffer(0)]],
                  device float* out [[buffer(1)]],
                  constant uint2& dims [[buffer(2)]],
                  uint tid [[thread_position_in_grid]]) {
    if (tid >= dims.x) return;
    out[tid] = a[tid] * 2.0f + float(dims.y);
}
)MSL";

static void testCrossVersionBlock(void* dev, const mc::DeviceCaps& caps) {
    const int vers[] = {110, 120, 200, 210, 220, 230, 240, 300, 310, 320, 400};
    log("== [X] MSL cross-version matrix (Metal 1.1 ../ 4.0) ==");
    log("  os=" + caps.osVersion + " baseline cedar MSL2.3=230; MSL4=400 needs iOS26");
    constexpr uint32_t N = 64;
    MCOpBuffer ab{}, ob{};
    bool bufs = mcops_newBuffer(dev, N * 4, MCOP_STORAGE_AUTO, &ab) == 0 &&
                mcops_newBuffer(dev, N * 4, MCOP_STORAGE_AUTO, &ob) == 0;
    if (!bufs) { check(false, "[X] buffers"); return; }
    float in[N], want[N];
    for (uint32_t i = 0; i < N; ++i) in[i] = (float)i - 8.0f;
    constexpr float kK = 7.0f;
    for (uint32_t i = 0; i < N; ++i) want[i] = in[i] * 2.0f + kK;
    mcops_writeBufferHost(&ab, in, sizeof in);

    int okN = 0;
    std::string okList, refusList;
    bool haveRef = false;
    float refOut[N];
    for (int v : vers) {
        char err[512] = {0};
        void* lib = nullptr;
        const std::string tag = "[" + std::to_string(v) + "]";
        const int rc = mcops_compileLibraryEx(dev, kXFillMsl, v, err,
                                              sizeof(err), &lib);
        if (rc != 0 || !lib) {
            log("  " + tag + " REFUSED rc=" + std::to_string(rc) + "  " + err);
            refusList += " " + std::to_string(v);
            continue;
        }
        id<MTLLibrary> msl = (__bridge_transfer id<MTLLibrary>)lib;
        id<MTLFunction> fn = [msl newFunctionWithName:@"xfill"];
        id<MTLDevice> dv = (__bridge id<MTLDevice>)dev;
        id<MTLComputePipelineState> ps =
            fn ? [dv newComputePipelineStateWithFunction:fn error:nil] : nil;
        if (!ps) {
            log("  " + tag + " pipeline create FAIL");
            refusList += " " + std::to_string(v);
            continue;
        }
        const uint32_t dims[2] = {N, (uint32_t)kK};
        id<MTLBuffer> dimB = [dv newBufferWithBytes:dims length:8 options:0];
        id<MTLCommandQueue> q = [dv newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:ps];
        [ce setBuffer:(__bridge id<MTLBuffer>)ab.handle offset:0 atIndex:0];
        [ce setBuffer:(__bridge id<MTLBuffer>)ob.handle offset:0 atIndex:1];
        [ce setBuffer:dimB offset:0 atIndex:2];
        [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1)
             threadsPerThreadgroup:MTLSizeMake(N, 1, 1)];
        [ce endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) {
            log("  " + tag + " dispatch FAIL");
            refusList += " " + std::to_string(v);
            continue;
        }
        float got[N];
        mcops_readBufferHost(&ob, got, sizeof got);
        const bool exact = std::memcmp(got, want, sizeof got) == 0;
        const bool cross = haveRef && std::memcmp(got, refOut, sizeof got) == 0;
        if (!haveRef) { haveRef = true; memcpy(refOut, got, sizeof got); }
        log("  " + tag + " OK bytes exact=" + std::to_string(exact ? 1 : 0) +
            " identical-to-first=" + std::to_string(cross ? 1 : 0));
        if (exact) { ++okN; okList += " " + std::to_string(v); }
        else check(false, "[X] " + tag + " byte exact vs CPU reference");
    }
    if (okN > 0) {
        check(true, "[X] " + std::to_string(okN) +
                        " MSL versions compiled and produced CPU-exact, "
                        "mutually-identical results (versions:" + okList + ")");
    } else {
        check(false, "[X] no MSL language accepted on this device");
    }
    if (!refusList.empty())
        log("  refused-on-this-device:[" + refusList + " ]");
    mcops_freeBuffer(&ab);
    mcops_freeBuffer(&ob);
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

// ---------------------------------------------------------------------------
// [RT-VIEW] Live ray-traced viewport engine (v1.3). Renderer structure follows
// the official Apple sample "Accelerating ray tracing using Metal":
//   compute kernel -> RGBA32F private texture -> fullscreen quad copy pass
//   (tonemap in fragment) -> CAMetalLayer drawable, all in one command buffer;
//   acceleration structures built once via accelerationStructureCommandEncoder;
//   per-instance MTLPackedFloat4x3 column-major descriptor packing.
// Scene: checker floor, mirror sphere, red diffuse, blue glossy, emissive
// lamp (whitted, 2 bounces max), two point lights (one orbits) + shadow rays.
// Animation: slow orbiting camera + orbiting light => live moving shadows.
@implementation RtEngine {
    CAMetalLayer* _layer;
    UILabel* _overlay;
    id<MTLDevice> _dev;
    id<MTLCommandQueue> _q;
    id<MTLComputePipelineState> _rtPS;
    id<MTLRenderPipelineState> _copyPS;
    id<MTLAccelerationStructure> _tlas;
    id<MTLAccelerationStructure> _blasArr[5];
    id<MTLBuffer> _vbuf;
    id<MTLBuffer> _nbuf;
    id<MTLBuffer> _uBuf[3];
    id<MTLTexture> _rtTex;
    CADisplayLink* _link;
    dispatch_semaphore_t _sem;
    bool _supported;
    int _ring;
    int _frames;
    int _fpsFrames;
    double _fpsT0;
    uint32_t _rtW, _rtH;
}
- (void)attachLayer:(CAMetalLayer*)layer overlay:(UILabel*)overlay {
    _layer = layer;
    _overlay = overlay;
    _dev = (__bridge id<MTLDevice>)(mcmtl_deviceHandle());
    _supported = [_dev supportsRaytracing] == YES && _dev != nil;
    if (!_supported) {
        NSString* fam = @"Apple4-class Mac GPU";
        if (@available(iOS 11.0, *)) {
        }
        _overlay.hidden = NO;
        _overlay.text =
            @"Ray tracing is NOT available on this hardware.\n"
            @"The Metal RT API needs Apple6+ (A13 / iPhone 11 or later; runs in\n"
            @"software on those GPUs). Hardware RT acceleration = Apple9\n"
            @"(A17 Pro, M3, M4). Viewport shows the test log instead.";
#ifndef NDEBUG
        log(std::string("[RT-VIEW] unavailable: supportsRaytracing=NO (") +
            std::string(_dev ? [fam UTF8String] : "no device") + ")");
#endif
        return;
    }
}
- (void)fail:(const std::string&)why {
    check(false, "[RT-VIEW] " + why);
    if (_link) { [_link invalidate]; _link = nil; }
    _supported = false;
    if (_overlay) {
        _overlay.hidden = NO;
        _overlay.text = [NSString stringWithFormat:@"[RT-VIEW] FAIL: %s",
                                                  why.c_str()];
    }
}
- (bool)setupOnce {
    if (_q) return true;
    if (!_dev) return false;
    _q = [_dev newCommandQueue];
    if (!_q) { [self fail:"command queue create failed"]; return false; }
    _sem = dispatch_semaphore_create(3);

    char errs[512] = {0};
    void* lib = nullptr;
    const std::string src = rtBuildShadeSource();
    // Honest fallback chain, newest MSL first: on RT hardware each refused
    // language produces the compiler's reason in the log; accepted versions
    // compile the same scene body identically.
    static const int kRtLangs[] = {240, 300, 310, 320, 400};
    int rc = 1;
    int usedLang = 0;
    std::string probeLog;
    for (int v : kRtLangs) {
        rc = mcops_compileLibraryEx((__bridge void*)_dev, src.c_str(), v,
                                    errs, sizeof(errs), &lib);
        probeLog += " v" + std::to_string(v) + "=" +
                    (rc == 0 && lib ? "ok" : ("refus(" + std::string(errs, 0, 120) + ")"));
        if (rc == 0 && lib) { usedLang = v; break; }
    }
    if (usedLang == 0) {
        [self fail:"MSL RT kernel refused at every version:" + probeLog];
        return false;
    }
    log("[RT-VIEW] scene kernel compiled at MSL " + std::to_string(usedLang / 100) +
        "." + std::to_string(usedLang % 100) + "; chain:" + probeLog);
    id<MTLLibrary> msl = (__bridge_transfer id<MTLLibrary>)lib;
    id<MTLFunction> fn = [msl newFunctionWithName:@"rt_shade"];
    id<MTLFunction> vf = [msl newFunctionWithName:@"quadVert"];
    id<MTLFunction> ff = [msl newFunctionWithName:@"quadFrag"];
    if (!fn || !vf || !ff) {
        [self fail:"rt_shade/quadVert/quadFrag functions not found"];
        return false;
    }
    _rtPS = [_dev newComputePipelineStateWithFunction:fn error:nil];
    MTLRenderPipelineDescriptor* rpd =
        [MTLRenderPipelineDescriptor new];
    rpd.vertexFunction = vf;
    rpd.fragmentFunction = ff;
    rpd.colorAttachments[0].pixelFormat = _layer.pixelFormat;
    if (_layer.pixelFormat == MTLPixelFormatInvalid)
        _layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    rpd.colorAttachments[0].pixelFormat = _layer.pixelFormat;
    _copyPS = [_dev newRenderPipelineStateWithDescriptor:rpd error:nil];
    if (!_rtPS || !_copyPS) {
        [self fail:"pipeline create failed"];
        return false;
    }
    check(true, "[RT-VIEW] MSL 2.4 kernel + copy pipelines compiled/created");

    // ---- Scene geometry (single shared pool; one BLAS per object). ----
    const int nV = rtVertexCount();
    _vbuf = [_dev newBufferWithLength:nV * 12
                              options:MTLResourceStorageModeShared];
    _nbuf = [_dev newBufferWithLength:nV * 12
                              options:MTLResourceStorageModeShared];
    if (!_vbuf || !_nbuf) { [self fail:"vertex buffers"]; return false; }
    auto* V = (float*)_vbuf.contents;
    auto* N = (float*)_nbuf.contents;
    int pv = 0;
    // Floor quad (two triangles, CCW seen from +Y).
    const float h = kRTFloorHalf;
    const float fv[6][3] = {
        {-h, 0, -h}, {h, 0, -h}, {h, 0, h},
        {-h, 0, -h}, {h, 0, h},  {-h, 0, h},
    };
    for (int i = 0; i < 6; ++i) {
        V[pv*3+0] = fv[i][0]; V[pv*3+1] = fv[i][1]; V[pv*3+2] = fv[i][2];
        N[pv*3+0] = 0; N[pv*3+1] = 1; N[pv*3+2] = 0;
        ++pv;
    }
    static const int vBases[4] = {6, 6 + 1 * kSphVerts, 6 + 2 * kSphVerts,
                                  6 + 3 * kSphVerts};
    for (int s = 0; s < 4; ++s) {
        const float cx = kSceneSpheres[s][0];
        const float cy = kSceneSpheres[s][1];
        const float cz = kSceneSpheres[s][2];
        const float r = kSceneSpheres[s][3];
        for (int st = 0; st <= kSphStacks; ++st) {
            const float th = float(st) / float(kSphStacks) * 3.14159265f;
            for (int gp = 0; gp <= kSphRings; ++gp) {
                const float ph =
                    float(gp) / float(kSphRings) * 6.28318531f;
                const float dx = sinf(th) * cosf(ph);
                const float dy = cosf(th);
                const float dz = sinf(th) * sinf(ph);
                V[pv*3+0] = cx + r * dx;
                V[pv*3+1] = cy + r * dy;
                V[pv*3+2] = cz + r * dz;
                N[pv*3+0] = dx; N[pv*3+1] = dy; N[pv*3+2] = dz;
                ++pv;
            }
        }
    }
    check(pv == nV, "[RT-VIEW] vertex pool filled exactly");

    // ---- BLAS per object; all reference the same shared vb/nb with offsets.
    MTLAccelerationStructureTriangleGeometryDescriptor* g[5] = {
        [MTLAccelerationStructureTriangleGeometryDescriptor descriptor],
        [MTLAccelerationStructureTriangleGeometryDescriptor descriptor],
        [MTLAccelerationStructureTriangleGeometryDescriptor descriptor],
        [MTLAccelerationStructureTriangleGeometryDescriptor descriptor],
        [MTLAccelerationStructureTriangleGeometryDescriptor descriptor],
    };
    MTLPrimitiveAccelerationStructureDescriptor* bdesc[5] = {
        [MTLPrimitiveAccelerationStructureDescriptor descriptor],
        [MTLPrimitiveAccelerationStructureDescriptor descriptor],
        [MTLPrimitiveAccelerationStructureDescriptor descriptor],
        [MTLPrimitiveAccelerationStructureDescriptor descriptor],
        [MTLPrimitiveAccelerationStructureDescriptor descriptor],
    };
    // Geometry 0 = floor: vertices 0..5 (2 triangles, 12 B each).
    g[0].vertexBuffer = _vbuf;  g[0].vertexBufferOffset = 0;
    g[0].vertexStride = 12;     g[0].triangleCount = 2;
    const int sTris = kSphTris;
    for (int s = 0; s < 4; ++s) {
        const int gi = s + 1;
        g[gi].vertexBuffer = _vbuf;
        g[gi].vertexBufferOffset = (NSUInteger)vBases[s] * 12;
        g[gi].vertexStride = 12;
        g[gi].triangleCount = sTris;
    }
    for (int i = 0; i < 5; ++i) {
        bdesc[i].geometryDescriptors = @[ g[i] ];
        MTLAccelerationStructureSizes bs =
            [_dev accelerationStructureSizesWithDescriptor:bdesc[i]];
        _blasArr[i] = [_dev newAccelerationStructureWithSize:
                                bs.accelerationStructureSize];
        if (!_blasArr[i]) { [self fail:"BLAS create"]; return false; }
        id<MTLBuffer> dB = [_dev newBufferWithLength:bs.buildScratchBufferSize
                                            options:MTLResourceStorageModePrivate];
        id<MTLCommandBuffer> cbb = [_q commandBuffer];
        id<MTLAccelerationStructureCommandEncoder> ab =
            [cbb accelerationStructureCommandEncoder];
        [ab buildAccelerationStructure:_blasArr[i]
                             descriptor:bdesc[i]
                          scratchBuffer:dB
                    scratchBufferOffset:0];
        [ab endEncoding];
        [cbb commit];
        [cbb waitUntilCompleted];
        if (cbb.status != MTLCommandBufferStatusCompleted) {
            [self fail:"BLAS encode failed"]; return false;
        }
    }
    log("[RT-VIEW] 5 BLAS built on-device");

    // ---- TLAS with 5 identity instances (opaque, mask 1). ----
    id<MTLBuffer> instB = [_dev newBufferWithLength:
                                    sizeof(MTLAccelerationStructureInstanceDescriptor) * 5
                                    options:MTLResourceStorageModeShared];
    MTLAccelerationStructureInstanceDescriptor* idp =
        (MTLAccelerationStructureInstanceDescriptor*)instB.contents;
    const MTLPackedFloat4x3 ident(
        MTLPackedFloat3(1, 0, 0), MTLPackedFloat3(0, 1, 0),
        MTLPackedFloat3(0, 0, 1), MTLPackedFloat3(0, 0, 0));
    for (int i = 0; i < 5; ++i) {
        idp[i].transformationMatrix = ident;
        idp[i].options = MTLAccelerationStructureInstanceOptionOpaque;
        idp[i].mask = 1;
        idp[i].intersectionFunctionTableOffset = 0;
        idp[i].accelerationStructureIndex = (uint32_t)i;
    }
    MTLInstanceAccelerationStructureDescriptor* tdesc =
        [MTLInstanceAccelerationStructureDescriptor descriptor];
    NSMutableArray* bl = [NSMutableArray array];
    for (int i = 0; i < 5; ++i) [bl addObject:_blasArr[i]];
    tdesc.instancedAccelerationStructures = bl;
    tdesc.instanceDescriptorBuffer = instB;
    tdesc.instanceDescriptorStride =
        sizeof(MTLAccelerationStructureInstanceDescriptor);
    tdesc.instanceCount = 5;
    if (@available(ios 15.0, *)) {
        tdesc.instanceDescriptorType =
            MTLAccelerationStructureInstanceDescriptorTypeDefault;
    }
    MTLAccelerationStructureSizes ts =
        [_dev accelerationStructureSizesWithDescriptor:tdesc];
    _tlas = [_dev newAccelerationStructureWithSize:ts.accelerationStructureSize];
    if (!_tlas) { [self fail:"TLAS create"]; return false; }
    id<MTLBuffer> scratch = [_dev newBufferWithLength:ts.buildScratchBufferSize
                                             options:MTLResourceStorageModePrivate];
    id<MTLCommandBuffer> cbt = [_q commandBuffer];
    id<MTLAccelerationStructureCommandEncoder> at =
        [cbt accelerationStructureCommandEncoder];
    [at buildAccelerationStructure:_tlas descriptor:tdesc
                     scratchBuffer:scratch scratchBufferOffset:0];
    [at endEncoding];
    [cbt commit];
    [cbt waitUntilCompleted];
    if (cbt.status != MTLCommandBufferStatusCompleted) {
        [self fail:"TLAS build failed"]; return false;
    }
    check(true, "[RT-VIEW] TLAS built (5 instances, camera-ready)");

    for (int i = 0; i < 3; ++i) {
        _uBuf[i] = [_dev newBufferWithLength:sizeof(RTUniforms)
                                     options:MTLResourceStorageModeShared];
        if (!_uBuf[i]) { [self fail:"uniform buffers"]; return false; }
    }
    _rtW = _rtH = 0;
    _ring = 0;
    return true;
}
- (void)ensureTarget {
    // Keep the RT target at roughly half of the layer's drawable resolution,
    // capped at 1024 pixels per side.
    CGSize ds = _layer.drawableSize;
    if (ds.width < 4 || ds.height < 4) return;
    uint32_t w = (uint32_t)(ds.width * 0.5);
    uint32_t hh = (uint32_t)(ds.height * 0.5);
    if (w > 1024) w = 1024;
    if (hh > 1024) hh = 1024;
    if (w == _rtW && hh == _rtH) return;
    _rtW = w;
    _rtH = hh;
    MTLTextureDescriptor* td = [MTLTextureDescriptor new];
    td.pixelFormat = MTLPixelFormatRGBA32Float;
    td.textureType = MTLTextureType2D;
    td.width = w;
    td.height = hh;
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    _rtTex = [_dev newTextureWithDescriptor:td];
}
- (void)tick:(CADisplayLink*)dl {
    (void)dl;
    if (!_supported || !_q) return;
    @try {
        if (!_sem) return;
        if (dispatch_semaphore_wait(_sem, DISPATCH_TIME_NOW) != 0) return;

        [self ensureTarget];
        if (!_rtTex) { dispatch_semaphore_signal(_sem); return; }

        // Camera + animated lights.
        double t = fmod(dl.timestamp, 1e6);
        RTUniforms u;
        memset(&u, 0, sizeof(u));
        const float cx = kRTSceneCenter[0];
        const float cy = kRTSceneCenter[1];
        const float cz = kRTSceneCenter[2];
        float angA = (float)(t * 0.05);  // camera orbit (~1 rev per 2 min)
        const float camR = 5.6f;
        float px = cx + cosf(angA) * camR;
        float py = 2.35f + sinf(angA * 2.3f) * 0.28f;
        float pz = cz + sinf(angA) * camR;
        float fx = cx - px, fy = cy - py, fz = cz - pz;
        float flen = sqrtf(fx*fx + fy*fy + fz*fz);
        fx /= flen; fy /= flen; fz /= flen;
        float upx = 0, upy = 1, upz = 0;
        float rxx = upy*fz - upz*fy;      // right = normalize(cross(up, fwd))
        float ryy = upz*fx - upx*fz;
        float rzz = upx*fy - upy*fx;
        float rln = sqrtf(rxx*rxx + ryy*ryy + rzz*rzz);
        rxx /= rln; ryy /= rln; rzz /= rln;
        float uxx = ryy*fz - rzz*fy;
        float uyy = rzz*fx - rxx*fz;
        float uzz = rxx*fy - ryy*fx;
        u.camPos[0] = px; u.camPos[1] = py; u.camPos[2] = pz;
        u.camFwd[0] = fx; u.camFwd[1] = fy; u.camFwd[2] = fz;
        u.camRight[0] = rxx; u.camRight[1] = ryy; u.camRight[2] = rzz;
        u.camUp[0] = uxx; u.camUp[1] = uyy; u.camUp[2] = uzz;
        float la = (float)(t * 0.19) + 0.6f;   // light orbit
        u.lightPos[0][0] = cx + cosf(la) * 3.4f;
        u.lightPos[0][1] = 4.2f;
        u.lightPos[0][2] = cz + sinf(la) * 3.4f;
        u.lightCol[0][0] = 1.0f; u.lightCol[0][1] = 0.96f; u.lightCol[0][2] = 0.88f; u.lightCol[0][3] = 3.4f;
        u.lightPos[1][0] = -4.4f; u.lightPos[1][1] = 3.4f; u.lightPos[1][2] = 2.6f;
        u.lightCol[1][0] = 0.30f; u.lightCol[1][1] = 0.44f; u.lightCol[1][2] = 1.0f; u.lightCol[1][3] = 2.6f;
        u.res[0] = _rtW; u.res[1] = _rtH;
        u.time = (float)t;
        const int idx = _ring;
        _ring = (_ring + 1) % 3;
        memcpy(_uBuf[idx].contents, &u, sizeof(u));

        id<MTLCommandBuffer> cb = [_q commandBuffer];
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            dispatch_semaphore_signal(self->_sem);
        }];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:_rtPS];
        [ce setBuffer:_uBuf[idx] offset:0 atIndex:0];
        [ce setAccelerationStructure:_tlas atBufferIndex:1];
        [ce setBuffer:_vbuf offset:0 atIndex:2];
        [ce setBuffer:_nbuf offset:0 atIndex:3];
        [ce setTexture:_rtTex atIndex:0];
        [ce useResource:_tlas usage:MTLResourceUsageRead];
        [ce useResource:_vbuf usage:MTLResourceUsageRead];
        [ce useResource:_nbuf usage:MTLResourceUsageRead];
        for (int i = 0; i < 5; ++i) [ce useResource:_blasArr[i] usage:MTLResourceUsageRead];
        const NSUInteger wq = [_rtPS maxTotalThreadsPerThreadgroup] < 64
                                  ? [_rtPS maxTotalThreadsPerThreadgroup]
                                  : 64;
        MTLSize tpg = MTLSizeMake(_rtW >= 8 ? 8 : _rtW,
                                  _rtH >= 8 ? 8 : _rtH, 1);
        if (wq >= 64) tpg = MTLSizeMake(8, 8, 1);
        MTLSize cgrid =
            MTLSizeMake((NSUInteger)(_rtW + tpg.width - 1) / tpg.width,
                        (NSUInteger)(_rtH + tpg.height - 1) / tpg.height, 1);
        (void)wq;
        [ce dispatchThreadgroups:cgrid threadsPerThreadgroup:tpg];
        [ce endEncoding];

        id<MTLRenderCommandEncoder> re = nil;
        id<CAMetalDrawable> drawable = [_layer nextDrawable];
        if (drawable) {
            MTLRenderPassDescriptor* rpd =
                [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = drawable.texture;
            rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
            rpd.colorAttachments[0].clearColor =
                MTLClearColorMake(0.02, 0.03, 0.05, 1.0);
            re = [cb renderCommandEncoderWithDescriptor:rpd];
            [re setRenderPipelineState:_copyPS];
            [re setFragmentTexture:_rtTex atIndex:0];
            [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [re endEncoding];
            [cb presentDrawable:drawable];
        }
        [cb commit];

        if (cb.error) {
            [self fail:std::string("frame submit error: ") +
                           cb.error.localizedDescription.UTF8String];
        } else {
            ++_frames;
            ++_fpsFrames;
            if (_fpsFrames == 1) {
                check(true, "live ray-traced scene is rendering on-screen "
                            "(whitted: shadows + mirror reflections + emissive lamp)");
            }
            const double now = CACurrentMediaTime();
            if (now - _fpsT0 >= 4.0) {
                const double fps = _fpsFrames / (now - _fpsT0);
                log("[RT-VIEW] alive: frame=" + std::to_string(_frames) +
                    " fps~" + std::to_string((int)(fps + 0.5)) +
                    "  " + std::to_string((int)_rtW) + "x" +
                    std::to_string((int)_rtH));
                _fpsT0 = now;
                _fpsFrames = 0;
            }
        }
    } @catch (NSException* ex) {
        log(std::string("[RT-VIEW] exception: ") +
            (ex.reason ? ex.reason.UTF8String : "unknown"));
        if (_link) { [_link invalidate]; _link = nil; }
    }
}
- (void)start {
    if (!_supported) return;
    if (![self setupOnce]) return;
    if (_link) return;
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    _link.preferredFramesPerSecond = 30;
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    _fpsT0 = CACurrentMediaTime();
    log("[RT-VIEW] start: live scene rendering (30 fps target)");
}
- (void)pause {
    if (_link) { [_link invalidate]; _link = nil; }
}
- (void)resume {
    if (_supported && _q && !_link) [self start];
}
@end

// Exposed so the Rerun button can schedule it again.
extern "C" void MCRunTestSession(void);

void MCRunTestSession(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        const auto g0 = std::chrono::steady_clock::now();
        openLogFile();
        log("MCRenderTest session v1.3 (built " __DATE__ " " __TIME__ ")");
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
        runBlock("[R] ray-tracing", [&] { testRtBlock(dev, caps); });
        runBlock("[X] msl-cross-version", [&] { testCrossVersionBlock(dev, caps); });
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
