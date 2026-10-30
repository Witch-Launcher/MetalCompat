// MetalCompat — Layered-rendering backend ops (render.layered feature).
//
// Official Apple article "Rendering to multiple texture slices in a draw
// command": "All GPUs in the macOS family support layer selection. Layer
// selection is available in the Apple GPU family starting with family 5."
// All non-macOS devices older than Apple5 must run the documented fallback.
// This file provides BOTH paths so the compat layer can translate, and the
// integration tests can byte-compare them against each other.
//
// ABI is plain C, no vtables; all params are handle-based and defensively
// validated.getError-grade returns match the mcops_* convention:
//   0 success, 1 invalid args, 2-4 failures as documented per op.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MCLayeredRenderParams {
    void* pipeline;      ///< MTLRenderPipelineState (vs_main/fs_main names)
    void* colorTexture;  ///< MTLTexture type=MTLTextureType2DArray RGBA8Unorm
    void* meshBuffer;    ///< buffer(0): 3x float2 clip-coord triangle
    void* layerUniforms; ///< buffer(3)/(4): host-visible; layer id for slice s sits
                         ///< at byte offset 32*s (constant buffers bind only on
                         ///< 32-byte alignment; verified GPU validation message)
    uint32_t viewportWidth;
    uint32_t viewportHeight;
    uint32_t sliceCount; ///< == colorTexture.arrayLength
    float clearR, clearG, clearB, clearA;
} MCLayeredRenderParams;

/// 1 when the device can run layer selection natively (Apple5+ or macOS
/// family), 0 when it must use the per-slice fallback translation.
int mcops_supportsLayerSelection(void* device) noexcept;

/// Single-pass native path: renderTargetArrayLength = sliceCount, one
/// instanced draw (3 vertices x sliceCount instances, iid -> layer).
/// Requires a pipeline built with inputPrimitiveTopology=Triangle (article's
/// pipeline requirement for layer selection).
/// Returns 0 ok; 1 invalid args / texture type or length mismatch;
/// 2 invalid pixel format; 3 no command queue; 4 no command buffer;
/// 5 command buffer did not complete; 6 MSL api unavailable at runtime.
int mcops_renderLayeredNative(void* device, MCLayeredRenderParams* p) noexcept;

/// Fallback translation (runs everywhere, incl. A9/Apple3, before ios 12):
/// sliceCount sequential passes; pass s renders into
/// [tex newTextureViewWithPixelFormat:textureType:levels:slices:
///  (NSMakeRange(s,1))] with a per-slice uint uniform bound at buffer(3).
/// Returns codes as mcops_renderLayeredNative.
int mcops_renderLayeredFallback(void* device, MCLayeredRenderParams* p) noexcept;

/// Blit-copy one slice of a texture (2DArray) into a host-visible buffer at
/// bytesPerRow = width*4 (RGBA8Unorm), so tests can compare slices exactly.
/// outBuffer length must be >= height*bytesPerRow.
/// Returns 0 ok; 1 invalid args / texture type; 2 slice/pixel-format without
/// transfer support; 3 no queue; 4 no cb; 5 incomplete.
int mcops_downloadTextureSlice(void* device, void* textureHandle, uint32_t slice,
                               uint32_t level, void* outBufferHandle) noexcept;

#ifdef __cplusplus
} // extern "C"
#endif
