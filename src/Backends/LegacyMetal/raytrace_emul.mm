// MetalCompat — software path-tracing emulation (EMULATED, runs on any Metal
// device including A11/Apple4 which has no hardware ray tracing).
//
// Phong cách Ray Tracing in One Weekend: diffuse (Lambert) / metal / dielectric
// (glass), anti-aliasing, multiple bounces, Schlick Fresnel, ACES tonemapping.
// Chạy hoàn toàn bằng compute BVH traversal — không cần MTLAccelerationStructure.
//
// Honesty: labelled EMULATED, never NATIVE. Caller opts in explicitly; planner
// never auto-substitutes this for a refused hardware path.
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

#include "backend_common.h"
#include "raytrace_emul.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

namespace {

// Opaque handle owning both the BVH node buffer and the reordered triangle buffer.
struct RtEmulBVHImpl {
    id<MTLBuffer> nodeBuf;
    id<MTLBuffer> triBuf;
    uint32_t nodeCount;
};

// ---- CPU-side BVH build (deterministic, median split on longest centroid axis) ----

struct CpuTri {
    float v0[3], v1[3], v2[3];
    uint32_t materialType;
    float albedo[3];
    float fuzz;
    float ior;
    uint32_t primId;   // original triangle index
};

struct CpuAABB { float min[3]; float max[3]; };

static void triAABB_(const CpuTri& t, CpuAABB& b) {
    for (int i = 0; i < 3; ++i) {
        b.min[i] = fminf(fminf(t.v0[i], t.v1[i]), t.v2[i]);
        b.max[i] = fmaxf(fmaxf(t.v0[i], t.v1[i]), t.v2[i]);
    }
}
static void aabbUnion_(const CpuAABB& a, const CpuAABB& b, CpuAABB& r) {
    for (int i = 0; i < 3; ++i) {
        r.min[i] = fminf(a.min[i], b.min[i]);
        r.max[i] = fmaxf(a.max[i], b.max[i]);
    }
}

struct CpuNode {
    float aabbMin[3];
    float aabbMax[3];
    int32_t left = -1;
    int32_t right = -1;
};

static int buildBVH_(CpuTri* tris, std::vector<uint32_t>& primList,
                     std::vector<CpuNode>& nodes, std::vector<uint32_t>& idx,
                     size_t begin, size_t end) {
    int nodeIdx = (int)nodes.size();
    nodes.emplace_back();

    CpuAABB box;
    bool first = true;
    for (size_t i = begin; i < end; ++i) {
        CpuAABB b;
        triAABB_(tris[idx[i]], b);
        if (first) { box = b; first = false; }
        else { CpuAABB r; aabbUnion_(box, b, r); box = r; }
    }
    for (int i = 0; i < 3; ++i) {
        nodes[nodeIdx].aabbMin[i] = box.min[i];
        nodes[nodeIdx].aabbMax[i] = box.max[i];
    }

    size_t count = end - begin;
    if (count <= 4u) {
        nodes[nodeIdx].left = (int32_t)primList.size();
        nodes[nodeIdx].right = (int32_t)count;
        for (size_t i = begin; i < end; ++i) primList.push_back(idx[i]);
        return nodeIdx;
    }

    float extent[3] = { box.max[0]-box.min[0], box.max[1]-box.min[1], box.max[2]-box.min[2] };
    int axis = 0;
    if (extent[1] > extent[0]) axis = 1;
    if (extent[2] > extent[0] && extent[2] > extent[1]) axis = 2;

    auto centroidComp = [&](uint32_t a, uint32_t b) {
        float ca[3], cb[3];
        for (int i = 0; i < 3; ++i) {
            ca[i] = (tris[a].v0[i] + tris[a].v1[i] + tris[a].v2[i]) / 3.0f;
            cb[i] = (tris[b].v0[i] + tris[b].v1[i] + tris[b].v2[i]) / 3.0f;
        }
        return ca[axis] < cb[axis];
    };

    std::vector<uint32_t> sortedIdx(idx.begin() + begin, idx.begin() + end);
    std::sort(sortedIdx.begin(), sortedIdx.end(), centroidComp);
    for (size_t i = 0; i < count; ++i) idx[begin + i] = sortedIdx[i];

    size_t mid = begin + count / 2;
    int leftIdx = buildBVH_(tris, primList, nodes, idx, begin, mid);
    int rightIdx = buildBVH_(tris, primList, nodes, idx, mid, end);
    nodes[nodeIdx].left = (int32_t)leftIdx;
    nodes[nodeIdx].right = (int32_t)(-(rightIdx + 1));
    return nodeIdx;
}

// ---- MSL source for the path tracer ----
static const char* kRtPathMsl = R"MSL(
#include <metal_stdlib>
using namespace metal;

struct Ray {
    float3 origin;
    float3 direction;
    float  tMin;
    float  tMax;
};

struct Hit {
    float  distance;
    uint   instanceId;
    uint   primitiveId;
    uint   primId;
    uint   hit;
    uint   pad[3];
};

struct BVHNode {
    float3  aabbMin;
    float3  aabbMax;
    int     leftOrPrimOffset;
    int     rightOrPrimCount;
};

struct PathTriangle {
    float3  v0;
    float3  v1;
    float3  v2;
    uint    materialType;   // 0 diffuse, 1 metal, 2 dielectric
    float3  albedo;
    float   fuzz;           // metal roughness (0..1)
    float   ior;            // dielectric index of refraction
};

struct Camera {
    float3 pos;
    float3 fwd;
    float3 right;
    float3 up;
    float  tanFovY;   // includes aspect baked in by caller
    float  pad[3];
};

// ---- Simple PCG32 RNG in the shader (pass-by-value, no pointers/references) ----
struct RngState {
    uint state;
    uint inc;
};

struct RngStep {
    float value;
    RngState next;
};

static RngStep pcg32_step(RngState rng) {
    uint old = rng.state;
    rng.state = old * 747796405u + rng.inc;
    uint xorshifted = ((old >> 18u) ^ old) >> 27u;
    uint rot = old >> 59u;
    uint value = (xorshifted >> rot) | (xorshifted << ((-rot) & 31u));
    return RngStep{ value / 4294967296.0f, rng };
}

static RngState makeRng(uint2 tid, uint sample, uint spp, uint frame) {
    uint seed = tid.x * 73856093u ^ tid.y * 19349663u ^ sample * 83492791u ^ frame * 5181073u;
    return RngState{ seed, 12345u };
}

static float schlick(float cosine, float refIdx) {
    float r0 = (1.0f - refIdx) / (1.0f + refIdx);
    r0 = r0 * r0;
    return r0 + (1.0f - r0) * pow(1.0f - cosine, 5.0f);
}

// ---- Ray–BVH traversal (returns closest hit) ----
static Hit trace_ray(const device BVHNode* bvhNodes,
                     const device PathTriangle* triangles,
                     Ray r) {
    Hit h;
    h.distance     = r.tMax;
    h.instanceId   = 0xFFFFFFFFu;
    h.primitiveId  = 0xFFFFFFFFu;
    h.primId       = 0xFFFFFFFFu;
    h.hit          = 0u;

    uint stack[64];
    uint sp = 0;
    stack[sp++] = 0u;

    while (sp > 0u) {
        uint nodeIdx = stack[--sp];
        const BVHNode node = bvhNodes[nodeIdx];

        float t0 = r.tMin;
        float t1 = r.tMax;
        for (int i = 0; i < 3; ++i) {
            float invD = 1.0f / r.direction[i];
            float a = (node.aabbMin[i] - r.origin[i]) * invD;
            float b = (node.aabbMax[i] - r.origin[i]) * invD;
            if (invD < 0.0f) { float tmp = a; a = b; b = tmp; }
            t0 = fmax(t0, a);
            t1 = fmin(t1, b);
            if (t1 <= t0) break;
        }

        if (t1 > t0) {
            if (node.rightOrPrimCount > 0) {
                uint base = (uint)node.leftOrPrimOffset;
                uint count = (uint)node.rightOrPrimCount;
                for (uint p = 0u; p < count; ++p) {
                    const PathTriangle tri = triangles[base + p];
                    float3 edge1 = tri.v1 - tri.v0;
                    float3 edge2 = tri.v2 - tri.v0;
                    float3 pvec  = cross(r.direction, edge2);
                    float  det   = dot(edge1, pvec);
                    if (fabs(det) < 1e-6f) continue;
                    float invDet = 1.0f / det;
                    float3 tvec = r.origin - tri.v0;
                    float  u    = dot(tvec, pvec) * invDet;
                    if (u < 0.0f || u > 1.0f) continue;
                    float3 qvec = cross(tvec, edge1);
                    float  v    = dot(r.direction, qvec) * invDet;
                    if (v < 0.0f || (u + v) > 1.0f) continue;
                    float dist = dot(edge2, qvec) * invDet;
                    if (dist > r.tMin && dist < h.distance) {
                        h.distance     = dist;
                        h.instanceId   = tri.materialType; // materialType stored here
                        h.primitiveId  = base + p;
                        h.primId       = tri.materialType; // also materialType
                        h.hit          = 1u;
                    }
                }
            } else {
                int leftIdx = node.leftOrPrimOffset;
                int rightIdx = -(node.rightOrPrimCount) - 1;
                if (sp + 2u <= 64u) {
                    stack[sp++] = (uint)leftIdx;
                    stack[sp++] = (uint)rightIdx;
                }
            }
        }
    }
    return h;
}

// ---- Path-trace one pixel (multiple samples + multiple bounces) ----
static float3 path_pixel(const device BVHNode* bvhNodes,
                         const device PathTriangle* triangles,
                         const Camera cam,
                         uint2 tid,
                         uint samplesPerPixel,
                         uint maxBounces,
                         uint frame) {
    float3 acc = float3(0.0f);

    for (uint s = 0; s < samplesPerPixel; ++s) {
        RngState rng = makeRng(tid, s, samplesPerPixel, frame);
        auto s1 = pcg32_step(rng); rng = s1.next;
        auto s2 = pcg32_step(rng); rng = s2.next;
        float2 jitter = float2(s1.value, s2.value);
        float2 ndc = (float2(tid) + jitter) * 2.0f - 1.0f;
        float3 dir = normalize(cam.fwd +
                               cam.right * (ndc.x * cam.tanFovY) +
                               cam.up   * (ndc.y * cam.tanFovY));

        Ray r;
        r.origin  = cam.pos;
        r.direction = dir;
        r.tMin    = 0.001f;
        r.tMax    = 1e30f;

        float3 throughput = float3(1.0f);
        float3 col = float3(0.0f);

        for (uint b = 0; b < maxBounces; ++b) {
            Hit h = trace_ray(bvhNodes, triangles, r);
            if (!h.hit) {
                // Background: gradient sky.
                float3 unitDir = normalize(r.direction);
                float t = 0.5f * (unitDir.y + 1.0f);
                col += throughput * (float3(1.0f, 1.0f, 1.0f) * (1.0f - t) + float3(0.5f, 0.7f, 1.0f) * t);
                break;
            }

            uint mat = h.instanceId; // materialType stored here
            const PathTriangle tri = triangles[h.primitiveId];

            float3 p = r.origin + r.direction * h.distance;
            float3 n = normalize(cross(tri.v1 - tri.v0, tri.v2 - tri.v0));
            if (dot(n, r.direction) > 0.0f) n = -n;

            if (mat == 0u) {
                // Diffuse (Lambert).
                col += throughput * tri.albedo * 0.5f;
                auto rs1 = pcg32_step(rng); rng = rs1.next;
                auto rs2 = pcg32_step(rng); rng = rs2.next;
                auto rs3 = pcg32_step(rng); rng = rs3.next;
                float3 rs = float3(rs1.value*2.0f-1.0f, rs2.value*2.0f-1.0f, rs3.value*2.0f-1.0f);
                if (dot(rs, rs) < 1.0f) {
                    float3 target = p + n + rs;
                    r.origin = p + n * 0.001f;
                    r.direction = normalize(target - p);
                    throughput *= tri.albedo;
                } else {
                    r.origin = p + n * 0.001f;
                    r.direction = normalize(n + rs);
                    throughput *= tri.albedo;
                }
            } else if (mat == 1u) {
                // Metal: reflect with fuzz.
                col += throughput * tri.albedo * 0.2f;
                float3 reflected = reflect(r.direction, n);
                r.origin = p + n * 0.001f;
                auto rs1 = pcg32_step(rng); rng = rs1.next;
                auto rs2 = pcg32_step(rng); rng = rs2.next;
                auto rs3 = pcg32_step(rng); rng = rs3.next;
                float3 rs = float3(rs1.value*2.0f-1.0f, rs2.value*2.0f-1.0f, rs3.value*2.0f-1.0f);
                r.direction = normalize(reflected + tri.fuzz * rs);
                throughput *= tri.albedo;
            } else {
                // Dielectric: Schlick + refract (manual).
                float3 outwardNormal;
                float niOverNt;
                float3 reflected = reflect(r.direction, n);
                float cosine = dot(r.direction, n);
                if (cosine > 0.0f) {
                    outwardNormal = -n;
                    niOverNt = tri.ior;
                    cosine = tri.ior * cosine / length(r.direction);
                } else {
                    outwardNormal = n;
                    niOverNt = 1.0f / tri.ior;
                    cosine = -cosine;
                }
                float reflectProb = schlick(cosine, tri.ior);
                // Manual refract: compute refracted direction, check TIR.
                float3 refracted;
                bool canRefract = true;
                float dt = dot(r.direction, outwardNormal);
                float disc = 1.0f - niOverNt * niOverNt * (1.0f - dt * dt);
                if (disc > 0.0f) {
                    refracted = niOverNt * (r.direction - outwardNormal * dt) - outwardNormal * sqrt(disc);
                } else {
                    canRefract = false;
                }
                auto rs = pcg32_step(rng); rng = rs.next;
                if (rs.value < reflectProb || !canRefract) {
                    r.origin = p + n * 0.001f;
                    r.direction = reflected;
                } else {
                    r.origin = p - n * 0.001f;
                    r.direction = refracted;
                }
                throughput *= tri.albedo;
            }

            // Russian roulette termination.
            if (b > 3u) {
                auto rs = pcg32_step(rng); rng = rs.next;
                float pRR = fmin(1.0f, fmax(fmax(throughput.x, throughput.y), throughput.z));
                if (rs.value > pRR) break;
                throughput /= pRR;
            }
        }
        acc += col;
    }
    return acc / float(samplesPerPixel);
}

// ---- ACES tonemapping (Filmic) ----
static float3 acesFilm(float3 x) {
    float a = 2.51f;
    float b = 0.03f;
    float c = 2.43f;
    float d = 0.59f;
    float e = 0.14f;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0f, 1.0f);
}

// ---- Main path-trace kernel ----
kernel void rt_path_trace(
    const device BVHNode*    bvhNodes  [[buffer(0)]],
    const device PathTriangle* triangles [[buffer(1)]],
    const device Camera&     camera    [[buffer(2)]],
    constant uint&           spp       [[buffer(3)]],
    constant uint&           maxBounces[[buffer(4)]],
    constant uint&           frame     [[buffer(5)]],
    texture2d<float, access::write> dst [[texture(0)]],
    uint2                    tid       [[thread_position_in_grid]]) {

    if (tid.x >= dst.get_width() || tid.y >= dst.get_height()) return;

    float3 col = path_pixel(bvhNodes, triangles, camera, tid, spp, maxBounces, frame);
    col = acesFilm(col);

    dst.write(float4(col, 1.0f), tid);
}
)MSL";

// ---- Helpers ----

static id<MTLLibrary> gRtLib = nil;
static id<MTLComputePipelineState> gRtPathPS = nil;

static int ensureRtPipeline_(id<MTLDevice> dev) {
    if (gRtPathPS) return 0;
    @autoreleasepool {
        NSError* err = nil;
        NSString* src = [NSString stringWithCString:kRtPathMsl
                                           encoding:NSUTF8StringEncoding];
        gRtLib = [dev newLibraryWithSource:src options:nil error:&err];
        if (!gRtLib) {
            std::fprintf(stderr, "rtPath compile: %s\n",
                         err.localizedDescription ? err.localizedDescription.UTF8String : "?");
            return 2;
        }
        id<MTLFunction> fn = [gRtLib newFunctionWithName:@"rt_path_trace"];
        if (!fn) return 2;
        gRtPathPS = [dev newComputePipelineStateWithFunction:fn error:&err];
        if (!gRtPathPS) {
            std::fprintf(stderr, "rtPath pipe: %s\n",
                         err.localizedDescription ? err.localizedDescription.UTF8String : "?");
            return 2;
        }
    }
    return 0;
}

} // namespace

int mcops_rtEmulAvailable(void* device) noexcept {
    (void)device;
    return 1;
}

int mcops_rtEmulBuildBVH(void* device,
                         const MCRtPathTriangle* triangles,
                         uint32_t triangleCount,
                         RtEmulBVHHandle* outHandle,
                         uint32_t* outNodeCount) noexcept {
    if (!device || !triangles || !outHandle || !outNodeCount || triangleCount == 0)
        return 1;
    *outHandle = nullptr;
    *outNodeCount = 0;

    id<MTLDevice> dev = devOf(device);

    std::vector<CpuTri> tris(triangleCount);
    for (uint32_t i = 0; i < triangleCount; ++i) {
        tris[i].v0[0] = triangles[i].v0[0]; tris[i].v0[1] = triangles[i].v0[1]; tris[i].v0[2] = triangles[i].v0[2];
        tris[i].v1[0] = triangles[i].v1[0]; tris[i].v1[1] = triangles[i].v1[1]; tris[i].v1[2] = triangles[i].v1[2];
        tris[i].v2[0] = triangles[i].v2[0]; tris[i].v2[1] = triangles[i].v2[1]; tris[i].v2[2] = triangles[i].v2[2];
        tris[i].materialType = triangles[i].materialType;
        tris[i].albedo[0] = triangles[i].albedo[0];
        tris[i].albedo[1] = triangles[i].albedo[1];
        tris[i].albedo[2] = triangles[i].albedo[2];
        tris[i].fuzz = triangles[i].fuzz;
        tris[i].ior = triangles[i].ior;
        tris[i].primId = i;
    }

    std::vector<uint32_t> idx(triangleCount);
    for (uint32_t i = 0; i < triangleCount; ++i) idx[i] = i;

    std::vector<uint32_t> primList;
    primList.reserve(triangleCount);
    std::vector<CpuNode> nodes;
    nodes.reserve(triangleCount * 2);
    buildBVH_(tris.data(), primList, nodes, idx, 0, triangleCount);

    std::vector<CpuTri> reorderedTris(primList.size());
    for (size_t i = 0; i < primList.size(); ++i)
        reorderedTris[i] = tris[primList[i]];

    // Metal-layout BVH nodes (48 bytes each).
    struct MetalBVHNode {
        float aabbMin[3]; float pad0;
        float aabbMax[3]; float pad1;
        int32_t leftOrPrimOffset;
        int32_t rightOrPrimCount;
        int32_t pad2[2];
    };
    std::vector<MetalBVHNode> metalNodes(nodes.size());
    for (size_t i = 0; i < nodes.size(); ++i) {
        metalNodes[i].aabbMin[0] = nodes[i].aabbMin[0];
        metalNodes[i].aabbMin[1] = nodes[i].aabbMin[1];
        metalNodes[i].aabbMin[2] = nodes[i].aabbMin[2];
        metalNodes[i].pad0 = 0.0f;
        metalNodes[i].aabbMax[0] = nodes[i].aabbMax[0];
        metalNodes[i].aabbMax[1] = nodes[i].aabbMax[1];
        metalNodes[i].aabbMax[2] = nodes[i].aabbMax[2];
        metalNodes[i].pad1 = 0.0f;
        metalNodes[i].leftOrPrimOffset = nodes[i].left;
        metalNodes[i].rightOrPrimCount = nodes[i].right;
        metalNodes[i].pad2[0] = 0;
        metalNodes[i].pad2[1] = 0;
    }

    NSUInteger nodeByteCount = (NSUInteger)(metalNodes.size() * sizeof(MetalBVHNode));
    id<MTLBuffer> nodeBuf = [dev newBufferWithLength:nodeByteCount
                                             options:MTLResourceStorageModeShared];
    if (!nodeBuf) return 2;
    memcpy(nodeBuf.contents, metalNodes.data(), nodeByteCount);

    // Metal-layout PathTriangle (match MSL exactly).
    struct MetalPathTriangle {
        float v0[3]; float pad0;
        float v1[3]; float pad1;
        float v2[3]; float pad2;
        uint32_t materialType;
        float albedo[3]; float albedoPad;
        float fuzz;
        float ior;
        uint32_t pad3[2];
    };
    std::vector<MetalPathTriangle> metalTris(reorderedTris.size());
    for (size_t i = 0; i < reorderedTris.size(); ++i) {
        metalTris[i].v0[0] = reorderedTris[i].v0[0];
        metalTris[i].v0[1] = reorderedTris[i].v0[1];
        metalTris[i].v0[2] = reorderedTris[i].v0[2];
        metalTris[i].pad0 = 0.0f;
        metalTris[i].v1[0] = reorderedTris[i].v1[0];
        metalTris[i].v1[1] = reorderedTris[i].v1[1];
        metalTris[i].v1[2] = reorderedTris[i].v1[2];
        metalTris[i].pad1 = 0.0f;
        metalTris[i].v2[0] = reorderedTris[i].v2[0];
        metalTris[i].v2[1] = reorderedTris[i].v2[1];
        metalTris[i].v2[2] = reorderedTris[i].v2[2];
        metalTris[i].pad2 = 0.0f;
        metalTris[i].materialType = reorderedTris[i].materialType;
        metalTris[i].albedo[0] = reorderedTris[i].albedo[0];
        metalTris[i].albedo[1] = reorderedTris[i].albedo[1];
        metalTris[i].albedo[2] = reorderedTris[i].albedo[2];
        metalTris[i].albedoPad = 0.0f;
        metalTris[i].fuzz = reorderedTris[i].fuzz;
        metalTris[i].ior = reorderedTris[i].ior;
        metalTris[i].pad3[0] = 0;
        metalTris[i].pad3[1] = 0;
    }

    NSUInteger triByteCount = (NSUInteger)(metalTris.size() * sizeof(MetalPathTriangle));
    id<MTLBuffer> triBuf = [dev newBufferWithLength:triByteCount
                                            options:MTLResourceStorageModeShared];
    if (!triBuf) return 2;
    memcpy(triBuf.contents, metalTris.data(), triByteCount);

    auto* impl = new RtEmulBVHImpl{nodeBuf, triBuf, (uint32_t)metalNodes.size()};
    *outHandle = impl;
    *outNodeCount = (uint32_t)metalNodes.size();
    return 0;
}

void mcops_rtEmulFreeBVH(RtEmulBVHHandle handle) noexcept {
    if (!handle) return;
    @autoreleasepool {
        auto* impl = static_cast<RtEmulBVHImpl*>(handle);
        (void)impl->nodeBuf;
        (void)impl->triBuf;
        delete impl;
    }
}

int mcops_rtEmulTrace(void* device,
                      RtEmulBVHHandle bvhHandle, uint32_t bvhNodeCount,
                      void* rayHandle, uint32_t rayCount,
                      void* hitHandle) noexcept {
    // Kept for API compatibility; path tracer is the primary path now.
    (void)device; (void)bvhHandle; (void)bvhNodeCount;
    (void)rayHandle; (void)rayCount; (void)hitHandle;
    return 2; // not implemented in this path-tracer-only build
}

int mcops_rtEmulPathTrace(void* device,
                          RtEmulBVHHandle bvhHandle, uint32_t bvhNodeCount,
                          const MCRtCamera* camera,
                          uint32_t samplesPerPixel, uint32_t maxBounces,
                          void* dstTextureHandle, uint32_t width, uint32_t height) noexcept {
    if (!device || !bvhHandle || !camera || !dstTextureHandle ||
        bvhNodeCount == 0 || samplesPerPixel == 0 || maxBounces == 0 ||
        width == 0 || height == 0)
        return 1;

    id<MTLDevice> dev = devOf(device);
    if (ensureRtPipeline_(dev) != 0) return 2;

    auto* impl = static_cast<RtEmulBVHImpl*>(bvhHandle);
    if (!impl) return 1;

    id<MTLBuffer> nodeBuf = impl->nodeBuf;
    id<MTLBuffer> triBuf = impl->triBuf;
    id<MTLTexture> dstTex = (__bridge id<MTLTexture>)dstTextureHandle;
    if (!nodeBuf || !triBuf || !dstTex) return 1;

    // Upload camera (single).
    id<MTLBuffer> camBuf = [dev newBufferWithLength:sizeof(MCRtCamera)
                                             options:MTLResourceStorageModeShared];
    if (!camBuf) return 2;
    memcpy(camBuf.contents, camera, sizeof(MCRtCamera));

    static uint32_t gFrame = 0;
    uint32_t frame = gFrame++;

    NSUInteger tgs = [gRtPathPS maxTotalThreadsPerThreadgroup];
    if (tgs == 0) tgs = 64;
    NSUInteger tgw = tgs < 16 ? tgs : 16;
    NSUInteger tgh = tgs < 16 ? tgs : 16;
    if (tgw * tgh > tgs) tgh = tgs / tgw;

    int rc = runAndWait(dev, ^(id<MTLCommandBuffer> cb) {
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:gRtPathPS];
        [ce setBuffer:nodeBuf offset:0 atIndex:0];
        [ce setBuffer:triBuf offset:0 atIndex:1];
        [ce setBuffer:camBuf offset:0 atIndex:2];
        [ce setBytes:&samplesPerPixel length:sizeof(uint32_t) atIndex:3];
        [ce setBytes:&maxBounces length:sizeof(uint32_t) atIndex:4];
        [ce setBytes:&frame length:sizeof(uint32_t) atIndex:5];
        [ce setTexture:dstTex atIndex:0];
        [ce dispatchThreads:MTLSizeMake(width, height, 1)
           threadsPerThreadgroup:MTLSizeMake(tgw, tgh, 1)];
        [ce endEncoding];
    });
    return rc;
}
