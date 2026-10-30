// LegacyMetal backend — shared internal helpers for the op modules.
// Backend-private; never exported. All ObjC selectors used here are verified
// against the current SDK headers (docs/RESEARCH.md).
#pragma once
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <stdint.h>

/// Bridge an opaque device handle to id<MTLDevice>.
inline id<MTLDevice> devOf(void* opaque) { return (__bridge id<MTLDevice>)opaque; }

/// Host-visible storage: Shared on unified memory; Managed only on non-unified
/// macOS (Managed is API_UNAVAILABLE(ios), verified MTLResource.h:177).
inline MTLResourceOptions hostVisibleOptions(id<MTLDevice> dev) {
#if TARGET_OS_OSX
    bool unified = true;
    if (@available(macos 10.15, *)) unified = dev.hasUnifiedMemory ? YES : NO;
    return unified ? MTLResourceStorageModeShared : MTLResourceStorageModeManaged;
#else
    (void)dev;
    return MTLResourceStorageModeShared;
#endif
}

#if TARGET_OS_OSX
inline bool needsManagedSync(id<MTLDevice> dev) {
    bool unified = true;
    if (@available(macos 10.15, *)) unified = dev.hasUnifiedMemory ? YES : NO;
    return !unified;
}
#endif

/// Queue → command buffer → build → commit → waitUntilCompleted → status check.
/// 0 on success; 2 no queue; 3 no cb; 4 cb did not complete (visit cb.error).
inline int runAndWait(id<MTLDevice> dev, void (^build)(id<MTLCommandBuffer>)) {
    id<MTLCommandQueue> q = [dev newCommandQueue];
    if (!q) return 2;
    id<MTLCommandBuffer> cb = [q commandBuffer];
    if (!cb) return 3;
    build(cb);
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) return 4;
    return 0;
}
