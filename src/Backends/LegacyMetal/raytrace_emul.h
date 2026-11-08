// MetalCompat — software path-tracing emulation (EMULATED, runs on any Metal
// device including A11/Apple4 which has no hardware ray tracing).
//
// Phong cách Ray Tracing in One Weekend: diffuse (Lambert) / metal / dielectric
// (glass), anti-aliasing, multiple bounces, Schlick Fresnel, ACES tonemapping.
// Chạy hoàn toàn bằng compute BVH traversal — không cần MTLAccelerationStructure.
//
// Honesty: labelled EMULATED, never NATIVE. Caller opts in explicitly; planner
// never auto-substitutes this for a refused hardware path.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Query: always returns 1 (the emulation module is available on any Metal
/// device). Does NOT mean hardware ray tracing exists.
int mcops_rtEmulAvailable(void* device) noexcept;

/// Path-traced triangle with material (Ray Tracing in One Weekend style).
// Layout must match the MSL `PathTriangle` struct exactly (float3 = 16 bytes,
// each float3 padded to 16 bytes; struct size must be a multiple of 16).
typedef struct MCRtPathTriangle {
    float v0[3]; float v0Pad;      // 16 bytes
    float v1[3]; float v1Pad;      // 16 bytes
    float v2[3]; float v2Pad;      // 16 bytes
    uint32_t materialType;         // 0=diffuse(Lambert), 1=metal, 2=dielectric
    float albedo[3]; float albedoPad; // 16 bytes
    float fuzz;                    // metal roughness (0..1)
    float ior;                     // dielectric index of refraction
    uint32_t pad[2];               // pad to 16-byte boundary
} MCRtPathTriangle; // 112 bytes, matches MSL PathTriangle

/// Build a BVH over `triangleCount` path triangles on the CPU (deterministic
/// median split). Returns an opaque handle owning the BVH node buffer +
/// reordered triangle buffer. `*outNodeCount` = number of BVH nodes.
/// Returns 0 ok; 1 invalid args; 2 allocation/compile failure.
typedef void* RtEmulBVHHandle; // opaque, owns node+tri MTLBuffers

int mcops_rtEmulBuildBVH(void* device,
                         const MCRtPathTriangle* triangles,
                         uint32_t triangleCount,
                         RtEmulBVHHandle* outHandle,
                         uint32_t* outNodeCount) noexcept;
void mcops_rtEmulFreeBVH(RtEmulBVHHandle handle) noexcept;

/// Camera parameters for the path tracer.
// Layout must match the MSL `Camera` struct exactly.
typedef struct MCRtCamera {
    float pos[3];   float posPad;
    float fwd[3];   float fwdPad;
    float right[3]; float rightPad;
    float up[3];    float upPad;
    float tanFovY;  // includes aspect baked in by caller
    float pad[3];
} MCRtCamera; // 80 bytes

/// Render a path-traced scene into `dstTexture` (RGBA32Float).
/// `bvhHandle` comes from mcops_rtEmulBuildBVH over path triangles.
/// `camera` is caller-owned host memory. `samplesPerPixel` = AA samples per
/// pixel; `maxBounces` = max ray bounces. One dispatch covers the whole texture.
///
/// Returns 0 ok; 1 invalid args; 2 pipeline/dispatch failure.
int mcops_rtEmulPathTrace(void* device,
                          RtEmulBVHHandle bvhHandle, uint32_t bvhNodeCount,
                          const MCRtCamera* camera,
                          uint32_t samplesPerPixel, uint32_t maxBounces,
                          void* dstTextureHandle, uint32_t width, uint32_t height) noexcept;

#ifdef __cplusplus
} // extern "C"
#endif