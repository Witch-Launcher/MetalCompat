// MetalCompat — Legacy tier-1 argument buffers prototype (M7).
//
// Feature trans.mtl4.argtable.tier1: the documented Metal-4 argument-table
// programming model is Apple7+ ONLY; the documented iOS 11-era equivalent is
// the tier-1 argument buffer (MTLArgumentDescriptor + argument encoder, API
// ios 11.0 / macos 10.13 per MTLDevice.h:324/877). This op builds the full
// tier-1 flow so A9-class behavior can be studied and later reused for a
// translation record:
//   descriptors -> [device newArgumentEncoderWithArguments:] -> argument
//   buffer (allocatedSize, alignment) -> encoder setArgumentBuffer/setBuffer
//   -> MSL pointer-member struct bound at buffer(0).
//
// The op then runs the SAME data through a classic binding kernel and a
// tier-1 kernel and byte-compares the results. This is a PROTOTYPE: every
// schema step it touches must be re-verified against device behavior before
// being referenced as a validated translation.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 1 when dev.argumentBuffersSupport >= MTLArgumentBuffersTierTier1
/// (selector ios 11.0 / macos 10.13), else 0. -1 when the selector is
/// unavailable on the host OS (gate unresolvable).
int mcops_argT1Support(void* device) noexcept;

/// Runs the prototype end to end. Writes `count` uint32 results for each
/// mode into dstClassicBuffer / dstT1Buffer (host-visible buffers).
/// Returns 0 on success; nonzero on the step that failed:
///  1 invalid args              2 not supported (gate unmet)
///  3 descriptor/encoder step   4 kernel compile failure
///  5 classic path failure      6 tier1 path failure
///  7 result mismatch (classic must equal tier1)
int mcops_argT1Prototype(void* device, void* srcValuesBuffer,
                         void* dstClassicBuffer, void* dstT1Buffer,
                         uint32_t count) noexcept;

#ifdef __cplusplus
} // extern "C"
#endif
