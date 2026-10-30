// Device acquisition/takedown through the LegacyMetal bridge.
#include "MetalCompat/Device.hpp"
#include "../Backends/LegacyMetal/metal_bridge.h"

namespace mc {

Error createDefaultDevice(Device& out) noexcept {
    out = Device{};
    int rc = mcmtl_probeDefaultDevice(&out.caps);
    if (rc == 1) return Error{ErrorCode::BridgeFailure, "", "MTLCreateSystemDefaultDevice returned nil"};
    if (rc != 0) return Error{ErrorCode::BridgeFailure, "", "bridge probe failed"};
    if (out.caps.deviceName.empty())
        return Error{ErrorCode::BridgeFailure, "", "device probe produced no name"};
    out.handle = mcmtl_deviceHandle();
    return Error{};
}

void destroyDevice(Device& d) noexcept {
    mcmtl_releaseDevice();
    d.handle = nullptr;
}

} // namespace mc
