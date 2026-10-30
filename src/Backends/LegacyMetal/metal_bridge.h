// LegacyMetal backend — C-visible bridge into Objective-C/Metal (SPEC D-008).
// Every symbol used here is verified in the target SDK headers (see docs/RESEARCH).
#pragma once
#include "MetalCompat/Capabilities.hpp"

namespace mc { struct DeviceCaps; }

// Fills DeviceCaps from the default MTLDevice via real runtime queries.
// Returns 0 on success; 1 when no device exists; 2 on other bridge failures.
int mcmtl_probeDefaultDevice(mc::DeviceCaps* out) noexcept;

// Releases the bridge-held device (if any).
void mcmtl_releaseDevice() noexcept;

// Opaque id<MTLDevice> pointer for backend consumers (null if none held).
void* mcmtl_deviceHandle() noexcept;
