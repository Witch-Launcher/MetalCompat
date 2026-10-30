// MetalCompat — Legacy tier-1 argument buffers prototype (see arg_table_t1.h).
//
// All selectors verified vs iPhoneOS26.2.sdk:
//   * MTLArgumentDescriptor:            ios 11.0 / macos 10.13 (MTLDevice.h:324)
//   * newArgumentEncoderWithArguments:: ios 11.0 / macos 10.13 (MTLDevice.h:877)
//   * argumentBuffersSupport:           ios 11.0 / macos 10.13 (MTLDevice.h:475)
//   * MTLDataTypePointer:               ios 11.0 (MTLDataType.h:154)
// The MSL pointer-member form (`device const T* p [[id(N)]]` inside a struct
// bound at buffer(0)) is compiled HERE on the host — empirical verification
// is part of the prototype's acceptance (no GPU dispatch asserts required).
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

#include "backend_common.h"
#include "arg_table_t1.h"

#include <cstdio>

// clang-format off
static NSString* const kArgT1Msl = @""
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct MCArgBlock {            // bound as buffer(0)\n"
"  device const uint* values [[id(0)]];  // descriptor index 0: pointer\n"
"};\n"
"uint32_t mcStep(uint v) { uint x = v ^ (v << 13u); x ^= (x >> 17u); x ^= (x << 5u); return x; }\n"
"kernel void mcArgClassic(device const uint* values [[buffer(0)]],\n"
"                         device uint* out [[buffer(1)]],\n"
"                         uint gid [[thread_position_in_grid]]) {\n"
"  out[gid] = mcStep(values[gid]);\n"
"}\n"
"kernel void mcArgT1(device const MCArgBlock& block [[buffer(0)]],\n"
"                    device uint* out [[buffer(1)]],\n"
"                    uint gid [[thread_position_in_grid]]) {\n"
"  out[gid] = mcStep(block.values[gid]);\n"
"}\n";
// clang-format on

int mcops_argT1Support(void* device) noexcept {
    if (!device) return 0;
    id<MTLDevice> dev = devOf(device);
    if (@available(ios 11.0, macos 10.13, *)) {
        return (dev.argumentBuffersSupport >= MTLArgumentBuffersTier1) ? 1 : 0;
    }
    return -1;
}

int mcops_argT1Prototype(void* device, void* srcValuesBuffer,
                         void* dstClassicBuffer, void* dstT1Buffer,
                         uint32_t count) noexcept {
    if (!device || !srcValuesBuffer || !dstClassicBuffer || !dstT1Buffer || count == 0)
        return 1;
    const int gate = mcops_argT1Support(device);
    if (gate != 1) return 2;

    id<MTLDevice> dev = devOf(device);
    id<MTLBuffer> src = (__bridge id<MTLBuffer>)srcValuesBuffer;
    id<MTLBuffer> dstC = (__bridge id<MTLBuffer>)dstClassicBuffer;
    id<MTLBuffer> dstT1 = (__bridge id<MTLBuffer>)dstT1Buffer;
    if (!src || !dstC || !dstT1) return 1;
    if (src.length < count * 4 || dstC.length < count * 4 || dstT1.length < count * 4)
        return 1;

    @autoreleasepool {
        // --- schema step 1: descriptors + encoders (MTLDevice.h:324/877) ---
        MTLArgumentDescriptor* d0 = [MTLArgumentDescriptor argumentDescriptor];
        d0.dataType = MTLDataTypePointer;
        d0.index = 0;
        d0.access = MTLBindingAccessReadOnly;
        NSArray<MTLArgumentDescriptor*>* stepDescs = @[ d0 ];

        id<MTLArgumentEncoder> enc = [dev newArgumentEncoderWithArguments:stepDescs];
        if (!enc || enc.encodedLength == 0) return 3;

        // --- schema step 2: argument buffer allocation + pointer encode ---
        id<MTLBuffer> argBuf = [dev newBufferWithLength:enc.encodedLength
                                               options:MTLResourceStorageModeShared];
        if (!argBuf) return 3;
        [enc setArgumentBuffer:argBuf offset:0];
        [enc setBuffer:src offset:0 atIndex:0]; // pointer written into argBuf

        // --- schema step 3: compile the tier-1 kernel (empirical check) ---
        NSError* err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kArgT1Msl
                                               options:nil
                                                 error:&err];
        if (!lib) {
            // Compiler diagnostics for the empirical probe (public API error).
            std::fprintf(stderr, "argt1 compile: %s\n",
                         err.localizedDescription ? err.localizedDescription.UTF8String : "?");
            return 4;
        }
        id<MTLFunction> fClassic = [lib newFunctionWithName:@"mcArgClassic"];
        id<MTLFunction> fT1 = [lib newFunctionWithName:@"mcArgT1"];
        if (!fClassic || !fT1) return 4;
        id<MTLComputePipelineState> pClassic = [dev newComputePipelineStateWithFunction:fClassic error:&err];
        id<MTLComputePipelineState> pT1 = [dev newComputePipelineStateWithFunction:fT1 error:&err];
        if (!pClassic || !pT1) return 4;

        // --- same data through both kernels (single queue, sequential) ---
        int rc = runAndWait(dev, ^(id<MTLCommandBuffer> cb) {
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            NSUInteger tgCount = (count + 63) / 64;
            [ce setComputePipelineState:pClassic];
            [ce setBuffer:src offset:0 atIndex:0];
            [ce setBuffer:dstC offset:0 atIndex:1];
            [ce dispatchThreadgroups:MTLSizeMake(tgCount, 1, 1)
               threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            [ce setComputePipelineState:pT1];
            [ce setBuffer:argBuf offset:0 atIndex:0]; // tier-1 block binding
            [ce setBuffer:dstT1 offset:0 atIndex:1];
            [ce dispatchThreadgroups:MTLSizeMake(tgCount, 1, 1)
               threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            [ce endEncoding];
        });
        if (rc != 0) return rc == 2 ? 5 : (rc == 3 ? 5 : 6);

#if TARGET_OS_OSX
        bool unified = true;
        if (@available(macos 10.15, *)) unified = (dev.hasUnifiedMemory ? true : false);
        if (!unified) {
            [dstC didModifyRange:NSMakeRange(0, dstC.length)];
            [dstT1 didModifyRange:NSMakeRange(0, dstT1.length)];
        }
#endif
        const uint32_t* hostC = (const uint32_t*)dstC.contents;
        const uint32_t* hostT1 = (const uint32_t*)dstT1.contents;
        for (uint32_t i = 0; i < count; ++i)
            if (hostC[i] != hostT1[i]) return 7;
    }
    return 0;
}
