// LegacyMetal backend — Objective-C++ implementation of the capability probe.
// Symbols verified against iPhoneOS26.2.sdk headers (docs/RESEARCH.md §4):
//   MTLCreateSystemDefaultDevice        (Metal/Metal.h)
//   -[MTLDevice name]
//   -[MTLDevice supportsFamily:]        (ios 13.0 / macos 10.15)
//   -[MTLDevice maxBufferLength]        (ios 12.0)
//   -[MTLDevice maxThreadgroupMemoryLength] (ios 11.0)
//   -[MTLDevice maxThreadsPerThreadgroup]   (ios 9.0, returns MTLSize)
//   -[MTLDevice argumentBuffersSupport]     (ios 11.0, MTLArgumentBuffersTier)
//   -[MTLDevice readWriteTextureSupport]    (ios 11.0, MTLReadWriteTextureTier)
//   -[MTLDevice recommendedMaxWorkingSetSize] (macos 10.12 / ios 16.0 — guarded)
// MTL4 is intentionally NOT referenced here (D-008).
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

#include "metal_bridge.h"

static id<MTLDevice> gDevice = nil;

int mcmtl_probeDefaultDevice(mc::DeviceCaps* out) noexcept {
    if (!out) return 2;
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (dev == nil) return 1;
        gDevice = dev;

        mc::DeviceCaps caps;
        caps.deviceName = [dev.name UTF8String] ? [dev.name UTF8String] : "";

#if TARGET_OS_IPHONE && !TARGET_OS_MACCATALYST
        caps.platform = mc::PlatformKind::Ios;
#else
        caps.platform = mc::PlatformKind::Macos;
#endif
        NSOperatingSystemVersion v = [NSProcessInfo processInfo].operatingSystemVersion;
        const char* prefix = (caps.platform == mc::PlatformKind::Ios) ? "iOS" : "macOS";
        NSString* vstr = [NSString stringWithFormat:@"%s %ld.%ld", prefix,
                          (long)v.majorVersion, (long)v.minorVersion];
        caps.osVersion = vstr.UTF8String ? vstr.UTF8String : "";

        // supportsFamily probes (values verified in registry/gpu_capabilities.json).
        caps.familySupport[0]  = [dev supportsFamily:MTLGPUFamilyApple1]  ? 1 : 0;
        caps.familySupport[1]  = [dev supportsFamily:MTLGPUFamilyApple2]  ? 1 : 0;
        caps.familySupport[2]  = [dev supportsFamily:MTLGPUFamilyApple3]  ? 1 : 0;
        caps.familySupport[3]  = [dev supportsFamily:MTLGPUFamilyApple4]  ? 1 : 0;
        caps.familySupport[4]  = [dev supportsFamily:MTLGPUFamilyApple5]  ? 1 : 0;
        caps.familySupport[5]  = [dev supportsFamily:MTLGPUFamilyApple6]  ? 1 : 0;
        caps.familySupport[6]  = [dev supportsFamily:MTLGPUFamilyApple7]  ? 1 : 0;
        caps.familySupport[7]  = [dev supportsFamily:MTLGPUFamilyApple8]  ? 1 : 0;
        caps.familySupport[8]  = [dev supportsFamily:MTLGPUFamilyApple9]  ? 1 : 0;
        caps.familySupport[9]  = [dev supportsFamily:MTLGPUFamilyApple10] ? 1 : 0;
#if TARGET_OS_IPHONE
        caps.familySupport[10] = 0;                    // Mac2 never on iPhone
        caps.familySupport[11] = [dev supportsFamily:MTLGPUFamilyCommon1] ? 1 : 0;
        caps.familySupport[12] = [dev supportsFamily:MTLGPUFamilyCommon2] ? 1 : 0;
        caps.familySupport[13] = [dev supportsFamily:MTLGPUFamilyCommon3] ? 1 : 0;
#else
        caps.familySupport[10] = [dev supportsFamily:MTLGPUFamilyMac2] ? 1 : 0;
        caps.familySupport[12] = [dev supportsFamily:MTLGPUFamilyCommon2] ? 1 : 0;
#endif
        // Metal4 gate: enum value itself is API_AVAILABLE(macos 26 / ios 26)
        // (verified in SDK 26.2 header MTLDevice.h) — guard to keep older OS
        // deployment targets clean (D-008: Metal4 stays opt-in and separate).
        caps.familySupport[14] = [dev supportsFamily:MTLGPUFamilyMetal3] ? 1 : 0;
        caps.familySupport[15] = 0;
        if (@available(macos 26.0, ios 26.0, *)) {
            caps.familySupport[15] = [dev supportsFamily:MTLGPUFamilyMetal4] ? 1 : 0;
        }

        caps.appleGpu =
            caps.familySupport[0] || caps.familySupport[1] || caps.familySupport[2] ||
            caps.familySupport[3] || caps.familySupport[4] || caps.familySupport[5] ||
            caps.familySupport[6] || caps.familySupport[7] || caps.familySupport[8] ||
            caps.familySupport[9];
        caps.supportsMetal4 = caps.familySupport[15] != 0;

        caps.maxBufferLength = dev.maxBufferLength;
        caps.maxThreadgroupMemoryLength = dev.maxThreadgroupMemoryLength;
        MTLSize t = dev.maxThreadsPerThreadgroup;
        caps.maxThreadsPerThreadgroup = {
            (std::uint32_t)t.width, (std::uint32_t)t.height, (std::uint32_t)t.depth
        };
        caps.argumentBuffersTier = (std::uint8_t)dev.argumentBuffersSupport;
        caps.readWriteTextureTier = (std::uint8_t)dev.readWriteTextureSupport;
#if TARGET_OS_IPHONE
        if (@available(ios 16.0, *)) {
            caps.recommendedMaxWorkingSetSize = dev.recommendedMaxWorkingSetSize;
        }
#else
        caps.recommendedMaxWorkingSetSize = dev.recommendedMaxWorkingSetSize;
#endif
        *out = caps;
        return 0;
    }
}

void mcmtl_releaseDevice() noexcept {
    @autoreleasepool {
        gDevice = nil;
    }
}

void* mcmtl_deviceHandle() noexcept {
    return (__bridge void*)gDevice;
}
