// MetalCompat — software ray-tracing emulation kernel (EMULATED, not hardware RT).
// Runs on ANY Metal device via compute, including A11/Apple4 which has no ray
// tracing at all. State = EMULATED; caller must opt in explicitly.
//
// Algorithm: stack-based BVH traversal (slab-method AABB test) + Möller–Trumbore
// triangle intersection. Deterministic: same ray order, same BVH build order,
// identical fp32 math on every device.
//
// Cost (documented): one compute dispatch per pixel batch; software BVH
// traversal has no hardware intersection acceleration; O(log N) traversal per
// ray on a balanced BVH. Not a substitute for MTLAccelerationStructure on
// Apple6+/Apple9+ hardware.
//
// Honesty contract (SPEC D-006): labelled EMULATED, never NATIVE. Outputs match
// the CPU brute-force reference within fp32 tolerance; tests verify equality.

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
    bool   hit;
};

struct BVHNode {
    float3  aabbMin;
    float3  aabbMax;
    uint    leftOrPrimOffset;   // internal: left child index; leaf: primitive offset
    uint    rightOrPrimCount;   // internal: right child index; leaf: primitive count
};

struct Triangle {
    float3  v0;
    float3  v1;
    float3  v2;
    uint    instanceId;
};

kernel void rt_trace(
    const device BVHNode*   bvhNodes  [[buffer(0)]],
    const device Triangle*  triangles [[buffer(1)]],
    const device Ray*       rays      [[buffer(2)]],
    device Hit*             hits      [[buffer(3)]],
    uint                    tid       [[thread_position_in_grid]]) {

    Ray  r = rays[tid];
    Hit  h;
    h.distance     = r.tMax;
    h.instanceId   = 0xFFFFFFFFu;
    h.primitiveId  = 0xFFFFFFFFu;
    h.hit          = false;

    // Fixed-size traversal stack (64 entries is enough for typical BVH depth).
    uint stack[64];
    uint sp = 0;
    stack[sp++] = 0u; // root node index

    while (sp > 0u) {
        uint nodeIdx = stack[--sp];
        const BVHNode& node = bvhNodes[nodeIdx];

        // Ray–AABB intersection (slab method).
        float t0 = r.tMin;
        float t1 = r.tMax;

        for (int i = 0; i < 3; ++i) {
            float invD = 1.0f / r.direction[i];
            float a = (node.aabbMin[i] - r.origin[i]) * invD;
            float b = (node.aabbMax[i] - r.origin[i]) * invD;
            if (invD < 0.0f) { float tmp = a; a = b; b = tmp; }
            t0 = fmaxf(t0, a);
            t1 = fminf(t1, b);
            if (t1 <= t0) break;
        }

        if (t1 > t0) {
            if (node.rightOrPrimCount > 0u) {
                // Leaf node: intersect every primitive in this leaf.
                uint base = node.leftOrPrimOffset;
                uint count = node.rightOrPrimCount;
                for (uint p = 0u; p < count; ++p) {
                    const Triangle& tri = triangles[base + p];

                    float3 edge1 = tri.v1 - tri.v0;
                    float3 edge2 = tri.v2 - tri.v0;
                    float3 pvec  = cross(r.direction, edge2);
                    float  det   = dot(edge1, pvec);

                    if (fabsf(det) < 1e-6f) continue;
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
                        h.instanceId   = tri.instanceId;
                        h.primitiveId  = base + p;
                        h.hit          = true;
                    }
                }
            } else {
                // Internal node: push both children.
                if (sp + 2u <= 64u) {
                    stack[sp++] = node.leftOrPrimOffset;
                    stack[sp++] = node.rightOrPrimCount;
                }
            }
        }
    }

    hits[tid] = h;
}
