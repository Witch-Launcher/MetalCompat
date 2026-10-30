// MetalCompat — Layered-rendering backend ops (see render_layered.h).
//
// Selector availability (verified vs iPhoneOS26.2.sdk / MacOSX26.2.sdk):
//   * MTLRenderPassDescriptor.renderTargetArrayLength: ios 12.0 / macos 10.11
//     (MTLRenderPass.h:392) — the article's layer-selection pass parameter.
//   * MTLTexture newTextureViewWithPixelFormat:textureType:levels:slices:
//     ios 9.0 / macos 10.11 (MTLTexture.h:512) — the fallback's per-slice view.
//   * MTLPrimitiveTopologyClassTriangle: any (MTLRenderPipeline.h:127).
// The macOS-family rule ("All GPUs in the macOS family support layer
// selection") is mirrored from the official Apple article, not inferred.
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

#include "backend_common.h"
#include "render_layered.h"

int mcops_supportsLayerSelection(void* device) noexcept {
    if (!device) return 0;
    id<MTLDevice> dev = devOf(device);
    // macOS family rule: every macOS device list entry supports layer
    // selection (article). Gate on MTLGPUFamilyMac2 which is the minimum
    // probed macOS family, plus Apple5+ for iOS-family devices.
    if (@available(ios 13.0, macos 10.15, *)) {
        if ([dev supportsFamily:MTLGPUFamilyApple5]) return 1;
        if ([dev supportsFamily:MTLGPUFamilyMac2]) return 1;
        return 0;
    }
    // Without the MTLGPUFamily API (pre-ios 13 / pre-macos 10.15) the gate
    // cannot be PROVEN; report unsupported so callers fall back honestly.
    return 0;
}

// Map runAndWait codes {2,3,4} to section-3 codes {3,4,5}.
static int mapWaitCode__(int rc) noexcept {
    switch (rc) {
        case 0: return 0;
        case 2: return 3;
        case 3: return 4;
        case 4: return 5;
        default: return 5;
    }
}

static int renderLayeredImpl__(void* device, MCLayeredRenderParams* p, bool native) {
    if (!p || !p->pipeline || !p->colorTexture || !p->meshBuffer || !p->layerUniforms)
        return 1;
    if (p->viewportWidth == 0 || p->viewportHeight == 0 || p->sliceCount == 0)
        return 1;
    id<MTLDevice> dev = devOf(device);
    id<MTLTexture> tex = (__bridge id<MTLTexture>)p->colorTexture;
    id<MTLBuffer> mesh = (__bridge id<MTLBuffer>)p->meshBuffer;
    id<MTLBuffer> uniforms = (__bridge id<MTLBuffer>)p->layerUniforms;
    id<MTLRenderPipelineState> ps = (__bridge id<MTLRenderPipelineState>)p->pipeline;
    if (!tex || !mesh || !uniforms || !ps) return 1;
    if (tex.textureType != MTLTextureType2DArray) return 1;
    if ((uint32_t)tex.arrayLength != p->sliceCount) return 1;
    if (uniforms.length < p->sliceCount * 32) return 1; // 32-byte aligned slice slots
    if (tex.pixelFormat != MTLPixelFormatRGBA8Unorm) return 2;

    if (native) {
        if (@available(ios 12.0, macos 10.11, *)) {
            // renderTargetArrayLength selector available (MTLRenderPass.h:392).
        } else {
            return 6; // host OS predates the selector's documented floors
        }
    }

    const MTLClearColor clear = MTLClearColorMake(p->clearR, p->clearG, p->clearB, p->clearA);
    const MTLViewport viewport = {0, 0, double(p->viewportWidth), double(p->viewportHeight), 0, 1};

    int rc = runAndWait(dev, ^(id<MTLCommandBuffer> cb) {
        if (native) {
            MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
            MTLRenderPassColorAttachmentDescriptor* ca = rp.colorAttachments[0];
            ca.texture = tex;
            ca.loadAction = MTLLoadActionClear;
            ca.storeAction = MTLStoreActionStore;
            ca.clearColor = clear;
            rp.renderTargetArrayLength = p->sliceCount; // selects all slices
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
            [enc setRenderPipelineState:ps];
            // buffer(0): clip-coord triangle; per-instance layer from instance_id.
            [enc setVertexBuffer:mesh offset:0 atIndex:0];
            [enc setViewport:viewport];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle
                    vertexStart:0 vertexCount:3 instanceCount:p->sliceCount];
            [enc endEncoding];
        } else {
            for (uint32_t s = 0; s < p->sliceCount; ++s) {
                id<MTLTexture> view =
                    [tex newTextureViewWithPixelFormat:tex.pixelFormat
                                           textureType:MTLTextureType2D
                                                levels:NSMakeRange(0, 1)
                                                slices:NSMakeRange(s, 1)];
                if (!view) return; // fail closed: nothing rendered, rc reflects tx
                MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
                MTLRenderPassColorAttachmentDescriptor* ca = rp.colorAttachments[0];
                ca.texture = view;
                ca.loadAction = MTLLoadActionClear;
                ca.storeAction = MTLStoreActionStore;
                ca.clearColor = clear;
                // Single-slice pass: renderTargetArrayLength stays 0 by default.
                id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
                [enc setRenderPipelineState:ps];
                [enc setVertexBuffer:mesh offset:0 atIndex:0];
                // buffer(3): per-slice layer id (reads uniforms[s]).
                [enc setVertexBuffer:uniforms offset:s * 32 atIndex:3]; // 32-byte alignment
                // buffer(4): same value for the fragment stage.
                [enc setFragmentBuffer:uniforms offset:s * 32 atIndex:4]; // 32-byte alignment
                [enc setViewport:viewport];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle
                        vertexStart:0 vertexCount:3 instanceCount:1];
                [enc endEncoding];
            }
        }
    });
    return mapWaitCode__(rc);
}

int mcops_renderLayeredNative(void* device, MCLayeredRenderParams* p) noexcept {
    if (mcops_supportsLayerSelection(device) != 1) return 6;
    return renderLayeredImpl__(device, p, true);
}

int mcops_renderLayeredFallback(void* device, MCLayeredRenderParams* p) noexcept {
    return renderLayeredImpl__(device, p, false);
}

int mcops_downloadTextureSlice(void* device, void* textureHandle, uint32_t slice,
                               uint32_t level, void* outBufferHandle) noexcept {
    if (!device || !textureHandle || !outBufferHandle) return 1;
    id<MTLDevice> dev = devOf(device);
    id<MTLTexture> tex = (__bridge id<MTLTexture>)textureHandle;
    id<MTLBuffer> outBuf = (__bridge id<MTLBuffer>)outBufferHandle;
    if (!tex || !outBuf) return 1;
    if (tex.textureType != MTLTextureType2DArray) return 1;
    if (level != 0) return 2;
    if (slice >= (uint32_t)tex.arrayLength) return 1;
    if (tex.pixelFormat != MTLPixelFormatRGBA8Unorm) return 2;
    const NSUInteger w = tex.width, h = tex.height;
    if (outBuf.length < w * h * 4) return 1;
    const NSUInteger rowBytes = w * 4;

#if TARGET_OS_OSX
    bool unified = true;
    if (@available(macos 10.15, *)) unified = (dev.hasUnifiedMemory ? true : false);
    if (!unified) [outBuf didModifyRange:NSMakeRange(0, outBuf.length)]; // Managed host order
#endif
    int rc = runAndWait(dev, ^(id<MTLCommandBuffer> cb) {
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        // destinationBytesPerImage = bytes of ONE full 2D image (W*H*4);
        // bytesPerRow alone is not the image stride (MTL validation enforces
        // bytesPerImage >= rows*rowBytes for slice copies).
        [be copyFromTexture:tex sourceSlice:slice sourceLevel:0
               sourceOrigin:MTLOriginMake(0, 0, 0)
                 sourceSize:MTLSizeMake(w, h, 1)
                   toBuffer:outBuf
          destinationOffset:0
      destinationBytesPerRow:rowBytes
    destinationBytesPerImage:w * h * 4];
        [be endEncoding];
    });
    return mapWaitCode__(rc);
}
