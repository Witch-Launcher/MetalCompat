// MetalCompat — Device.hpp
// Public device/token type for the compatibility runtime. PIMPL toward the
// backend (LegacyMetal) so core headers stay free of Apple includes.
#pragma once
#include "Errors.hpp"
#include "Capabilities.hpp"

namespace mc {

struct Device {
    using Handle = void*; // Opaque backend handle (id<MTLDevice> on Apple).

    Handle handle = nullptr;      ///< owned by backend; never null on success
    DeviceCaps caps{};            ///< immutable snapshot; cache everything (SPEC 4.3)
    std::string backendName {"LegacyMetal"};
};

/// Acquire the default MTLDevice and snapshot capabilities via the bridge.
/// Returns error Device if no device, or bridge failure details otherwise.
Error createDefaultDevice(Device& out) noexcept;

/// Free backend resources for a previously created device.
void destroyDevice(Device& d) noexcept;

} // namespace mc
