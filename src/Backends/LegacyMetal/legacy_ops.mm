// LegacyMetal ops — M4 core implementation (Objective-C++).
// Availability-correctness notes (verified, SDK 26.2 headers):
//   * MTLResourceStorageModeManaged / synchronizeResource: API_UNAVAILABLE(ios)
//     → AUTO selects them only on macOS non-unified-memory devices.
//   * hasUnifiedMemory: macos 10.15+ / ios 13.0+ (header MTLDevice.h).
//   * copyBufferToTexture / copyTextureToBuffer: legacy blit APIs, baseline era.
//   * MTLLanguageVersion2_3: ios 14.0 / macos 11.0 (registry row shader.msl23).
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

#include "backend_common.h"
#include "legacy_ops.h"

#include <cstdio>
#include <cstring>

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------
namespace {

void fillOut(MCOpBuffer* out, id<MTLBuffer> buf) {
    out->handle = (__bridge void*)buf;
    out->length = buf.length;
    out->cpuAddress = buf.contents; // non-nil for Shared/Managed; nil for Private
}

} // namespace

// ---------------------------------------------------------------------------
// buffers
// ---------------------------------------------------------------------------
int mcops_newBuffer(void* device, uint64_t lengthBytes, int storage,
                    MCOpBuffer* out) noexcept {
    if (!out || !device || lengthBytes == 0) return 1;
    *out = MCOpBuffer{};
    id<MTLDevice> dev = devOf(device);
    MTLResourceOptions opts = (storage == MCOP_STORAGE_PRIVATE)
                                  ? MTLResourceStorageModePrivate
                                  : hostVisibleOptions(dev);
    id<MTLBuffer> buf = [dev newBufferWithLength:(NSUInteger)lengthBytes options:opts];
    if (!buf) return 2;
    fillOut(out, buf);
    return 0;
}

void mcops_freeBuffer(MCOpBuffer* b) noexcept {
    if (!b || !b->handle) return;
    @autoreleasepool {
        id<MTLBuffer> buf = (__bridge_transfer id<MTLBuffer>)b->handle;
        (void)buf; // ARC releases
    }
    b->handle = nullptr;
    b->cpuAddress = nullptr;
    b->length = 0;
}

int mcops_writeBufferHost(MCOpBuffer* b, const void* data, uint64_t len) noexcept {
    if (!b || !b->cpuAddress || len > b->length || !data) return 1;
    std::memcpy(b->cpuAddress, data, (size_t)len);
#if TARGET_OS_OSX
    // Managed buffers on non-unified hosts need the modified-range hint before
    // the command that reads them is committed (didModifyRange, macOS-only).
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)b->handle;
    if (buf.storageMode == MTLStorageModeManaged)
        [buf didModifyRange:NSMakeRange(0, (NSUInteger)len)];
#endif
    return 0;
}

int mcops_readBufferHost(const MCOpBuffer* b, void* outData, uint64_t len) noexcept {
    if (!b || !b->cpuAddress || len > b->length || !outData) return 1;
    std::memcpy(outData, b->cpuAddress, (size_t)len);
    return 0;
}

// ---------------------------------------------------------------------------
// blit ops
// ---------------------------------------------------------------------------
int mcops_copyBuffer(void* device, uint64_t srcOffset, uint64_t dstOffset,
                     void* srcBufferHandle, void* dstBufferHandle,
                     uint64_t lengthBytes) noexcept {
    @autoreleasepool {
        id<MTLDevice> dev = devOf(device);
        if (!dev || !srcBufferHandle || !dstBufferHandle) return 1;
        id<MTLBuffer> src = (__bridge id<MTLBuffer>)srcBufferHandle;
        id<MTLBuffer> dst = (__bridge id<MTLBuffer>)dstBufferHandle;
        return runAndWait(dev, ^(id<MTLCommandBuffer> cb) {
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit copyFromBuffer:src sourceOffset:(NSUInteger)srcOffset
                        toBuffer:dst destinationOffset:(NSUInteger)dstOffset
                            size:(NSUInteger)lengthBytes];
            [blit endEncoding];
        });
    }
}

// ---------------------------------------------------------------------------
// textures (private) + staged up/down
// ---------------------------------------------------------------------------
int mcops_newTexture(void* device, uint32_t w, uint32_t h, int format,
                     void** outTexHandle) noexcept {
    if (!device || !outTexHandle || w == 0 || h == 0) return 1;
    *outTexHandle = nullptr;
    id<MTLDevice> dev = devOf(device);
    MTLTextureDescriptor* td = [MTLTextureDescriptor new];
    td.textureType = MTLTextureType2D;
    td.width = w; td.height = h;
    switch (format) {
        case MCOP_TEX_RGBA8_UNORM: td.pixelFormat = MTLPixelFormatRGBA8Unorm; break;
        case MCOP_TEX_R32_UINT:    td.pixelFormat = MTLPixelFormatR32Uint;    break;
        default: return 2;
    }
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
    if (!tex) return 3;
    *outTexHandle = (__bridge_retained void*)tex;
    return 0;
}

void mcops_freeTexture(void* texHandle) noexcept {
    if (!texHandle) return;
    @autoreleasepool {
        id<MTLTexture> tex = (__bridge_transfer id<MTLTexture>)texHandle;
        (void)tex;
    }
}

int mcops_uploadTexture(void* device, const MCOpBuffer* staging,
                        void* texHandle, uint32_t w, uint32_t h,
                        uint64_t bytesPerRow) noexcept {
    @autoreleasepool {
        id<MTLDevice> dev = devOf(device);
        if (!dev || !staging || !staging->handle || !texHandle) return 1;
        id<MTLBuffer> src = (__bridge id<MTLBuffer>)staging->handle;
        id<MTLTexture> tex = (__bridge id<MTLTexture>)texHandle;
        // Verified selector: copyFromBuffer:...:sourceSize:toTexture:...
        // (SDK 26.2 MTLBlitCommandEncoder.h:73).
        return runAndWait(dev, ^(id<MTLCommandBuffer> cb) {
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit copyFromBuffer:src sourceOffset:0
                   sourceBytesPerRow:(NSUInteger)bytesPerRow
                  sourceBytesPerImage:0
                           sourceSize:MTLSizeMake(w, h, 1)
                            toTexture:tex
                     destinationSlice:0 destinationLevel:0
                   destinationOrigin:MTLOriginMake(0, 0, 0)];
            [blit endEncoding];
        });
    }
}

int mcops_downloadTexture(void* device, void* texHandle, uint32_t w, uint32_t h,
                          uint64_t bytesPerRow, const MCOpBuffer* staging) noexcept {
    @autoreleasepool {
        id<MTLDevice> dev = devOf(device);
        if (!dev || !staging || !staging->handle || !texHandle) return 1;
        id<MTLTexture> tex = (__bridge id<MTLTexture>)texHandle;
        id<MTLBuffer> dst = (__bridge id<MTLBuffer>)staging->handle;
        // Verified selector: copyFromTexture:...:sourceSize:toBuffer:...options:
        // (SDK 26.2 MTLBlitCommandEncoder.h:92).
        return runAndWait(dev, ^(id<MTLCommandBuffer> cb) {
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit copyFromTexture:tex sourceSlice:0 sourceLevel:0
                     sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(w, h, 1)
                            toBuffer:dst destinationOffset:0
                   destinationBytesPerRow:(NSUInteger)bytesPerRow
                   destinationBytesPerImage:0
                                   options:MTLBlitOptionNone];
#if TARGET_OS_OSX
            // Managed staging on non-unified macs: explicit sync before commit.
            if (needsManagedSync(dev)) [blit synchronizeResource:dst];
#endif
            [blit endEncoding];
        });
    }
}

// ---------------------------------------------------------------------------
// sampler
// ---------------------------------------------------------------------------
int mcops_newSampler(void* device, int linear, void** outSamplerHandle) noexcept {
    if (!device || !outSamplerHandle) return 1;
    *outSamplerHandle = nullptr;
    @autoreleasepool {
        id<MTLDevice> dev = devOf(device);
        MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
        MTLSamplerMinMagFilter f = linear ? MTLSamplerMinMagFilterLinear
                                          : MTLSamplerMinMagFilterNearest;
        sd.minFilter = f;
        sd.magFilter = f;
        id<MTLSamplerState> s = [dev newSamplerStateWithDescriptor:sd];
        if (!s) return 2;
        *outSamplerHandle = (__bridge_retained void*)s;
    }
    return 0;
}

void mcops_freeSampler(void* samplerHandle) noexcept {
    if (!samplerHandle) return;
    @autoreleasepool {
        id<MTLSamplerState> s = (__bridge_transfer id<MTLSamplerState>)samplerHandle;
        (void)s;
    }
}

// ---------------------------------------------------------------------------
// library + compute pipeline
// ---------------------------------------------------------------------------
int mcops_compileLibrary(void* device, const char* mslSource,
                         void** outLibraryHandle) noexcept {
    // Default floor keeps legacy paths on the language the OS baseline allows;
    // the explicit-version variant lives in mcops_compileLibraryEx.
    int ver = 0;
    if (@available(ios 14.0, macos 11.0, *))
        ver = 230; // MTLLanguageVersion2_3 (iOS 14 ceiling, registry shader.msl23)
    else
        ver = 220; // MTLLanguageVersion2_2 (iOS 13 ceiling)
    return mcops_compileLibraryEx(device, mslSource, ver, nullptr, 0, outLibraryHandle);
}

int mcops_compileLibraryEx(void* device, const char* mslSource, int mslLangVersion,
                           char* errBuf, uint32_t errBufLen,
                           void** outLibraryHandle) noexcept {
    if (!device || !mslSource || !outLibraryHandle) return 1;
    *outLibraryHandle = nullptr;
    @autoreleasepool {
        id<MTLDevice> dev = devOf(device);
        NSString* src = [NSString stringWithCString:mslSource
                                           encoding:NSUTF8StringEncoding];
        MTLCompileOptions* opts = [MTLCompileOptions new];
        switch (mslLangVersion) {
            case 220: opts.languageVersion = MTLLanguageVersion2_2; break;
            case 230: opts.languageVersion = MTLLanguageVersion2_3; break;
            default:
                if (errBuf && errBufLen)
                    snprintf(errBuf, errBufLen, "unsupported MSL version %d", mslLangVersion);
                return 1;
        }
        NSError* err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:opts error:&err];
        if (!lib) {
            if (errBuf && errBufLen) {
                const char* msg = err.localizedDescription.UTF8String
                                      ? err.localizedDescription.UTF8String : "unknown compile error";
                // No shader text or symbol content leaves this path; the
                // diagnostics come from the compiler itself (public API error).
                snprintf(errBuf, errBufLen, "%s", msg);
            }
            return 2;
        }
        *outLibraryHandle = (__bridge_retained void*)lib;
    }
    return 0;
}

void mcops_freeLibrary(void* libraryHandle) noexcept {
    if (!libraryHandle) return;
    @autoreleasepool {
        id<MTLLibrary> lib = (__bridge_transfer id<MTLLibrary>)libraryHandle;
        (void)lib;
    }
}

int mcops_newComputePipeline(void* device, const void* libraryHandle,
                             const char* functionName,
                             void** outPipelineHandle) noexcept {
    if (!device || !libraryHandle || !functionName || !outPipelineHandle) return 1;
    *outPipelineHandle = nullptr;
    @autoreleasepool {
        id<MTLDevice> dev = devOf(device);
        id<MTLLibrary> lib = (__bridge id<MTLLibrary>)libraryHandle;
        id<MTLFunction> fn = [lib newFunctionWithName:
                                [NSString stringWithCString:functionName
                                                   encoding:NSUTF8StringEncoding]];
        if (!fn) return 2;
        NSError* err = nil;
        id<MTLComputePipelineState> ps =
            [dev newComputePipelineStateWithFunction:fn error:&err];
        if (!ps) return 3;
        *outPipelineHandle = (__bridge_retained void*)ps;
    }
    return 0;
}

void mcops_freeComputePipeline(void* pipelineHandle) noexcept {
    if (!pipelineHandle) return;
    @autoreleasepool {
        id<MTLComputePipelineState> ps =
            (__bridge_transfer id<MTLComputePipelineState>)pipelineHandle;
        (void)ps;
    }
}

int mcops_newRenderPipeline(void* device, const void* libraryHandle,
                            const char* vsName, const char* fsName,
                            int layered, void** outPipelineHandle) noexcept {
    if (!device || !libraryHandle || !vsName || !fsName || !outPipelineHandle) return 1;
    *outPipelineHandle = nullptr;
    @autoreleasepool {
        id<MTLDevice> dev = devOf(device);
        id<MTLLibrary> lib = (__bridge id<MTLLibrary>)libraryHandle;
        id<MTLFunction> vf = [lib newFunctionWithName:
                                  [NSString stringWithCString:vsName
                                                     encoding:NSUTF8StringEncoding]];
        id<MTLFunction> ff = [lib newFunctionWithName:
                                  [NSString stringWithCString:fsName
                                                     encoding:NSUTF8StringEncoding]];
        if (!vf || !ff) return 2;
        MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = vf;
        pd.fragmentFunction = ff;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        if (layered)
            pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
        NSError* err = nil;
        id<MTLRenderPipelineState> ps =
            [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!ps) return 2;
        *outPipelineHandle = (__bridge_retained void*)ps;
    }
    return 0;
}

void mcops_freeRenderPipeline(void* pipelineHandle) noexcept {
    if (!pipelineHandle) return;
    @autoreleasepool {
        id<MTLRenderPipelineState> ps =
            (__bridge_transfer id<MTLRenderPipelineState>)pipelineHandle;
        (void)ps;
    }
}

int mcops_newTextureArray(void* device, uint32_t w, uint32_t h, uint32_t layers,
                          void** outTextureHandle) noexcept {
    if (!device || !w || !h || !layers || !outTextureHandle) return 1;
    *outTextureHandle = nullptr;
    @autoreleasepool {
        id<MTLDevice> dev = devOf(device);
        MTLTextureDescriptor* td = [MTLTextureDescriptor new];
        td.textureType = MTLTextureType2DArray;
        td.width = w;
        td.height = h;
        td.arrayLength = layers;
        td.pixelFormat = MTLPixelFormatRGBA8Unorm;
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
        if (!tex) return 2;
        *outTextureHandle = (__bridge_retained void*)tex;
    }
    return 0;
}

int mcops_dispatchCompute(void* device, const void* pipelineHandle,
                          uint32_t gridCount, uint32_t threadgroupCount,
                          const void* const* bufferHandles, uint32_t bufferCount) noexcept {
    @autoreleasepool {
        id<MTLDevice> dev = devOf(device);
        if (!dev || !pipelineHandle) return 1;
        id<MTLComputePipelineState> ps =
            (__bridge id<MTLComputePipelineState>)pipelineHandle;
        // ACTUAL thread limits from the real pipeline (no invented occupancy).
        const NSUInteger maxTg = ps.maxTotalThreadsPerThreadgroup;
        if (threadgroupCount == 0 || threadgroupCount > maxTg) return 2;
        return runAndWait(dev, ^(id<MTLCommandBuffer> cb) {
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            [enc setComputePipelineState:ps];
            for (uint32_t i = 0; i < bufferCount; ++i) {
                id<MTLBuffer> b = (__bridge id<MTLBuffer>)bufferHandles[i];
                [enc setBuffer:b offset:0 atIndex:i];
            }
            [enc dispatchThreads:MTLSizeMake(gridCount, 1, 1)
                   threadsPerThreadgroup:MTLSizeMake(threadgroupCount, 1, 1)];
            [enc endEncoding];
        });
    }
}
