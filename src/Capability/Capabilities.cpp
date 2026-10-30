// Capability mapping helpers (core side; no Apple headers).
#include "MetalCompat/Capabilities.hpp"

namespace mc {

const char* familyName(std::int32_t v) noexcept {
    switch (v) {
        case family::Apple1: return "Apple1";
        case family::Apple2: return "Apple2";
        case family::Apple3: return "Apple3";
        case family::Apple4: return "Apple4";
        case family::Apple5: return "Apple5";
        case family::Apple6: return "Apple6";
        case family::Apple7: return "Apple7";
        case family::Apple8: return "Apple8";
        case family::Apple9: return "Apple9";
        case family::Apple10: return "Apple10";
        case family::Mac2: return "Mac2";
        case family::Common1: return "Common1";
        case family::Common2: return "Common2";
        case family::Common3: return "Common3";
        case family::Metal3: return "Metal3";
        case family::Metal4: return "Metal4";
    }
    return "Unknown";
}

// Snapshot index layout: Apple1..Apple10 (10), Mac2, Common1..3, Metal3, Metal4.
static int familyIndex(std::int32_t v) noexcept {
    switch (v) {
        case family::Apple1: return 0;
        case family::Apple2: return 1;
        case family::Apple3: return 2;
        case family::Apple4: return 3;
        case family::Apple5: return 4;
        case family::Apple6: return 5;
        case family::Apple7: return 6;
        case family::Apple8: return 7;
        case family::Apple9: return 8;
        case family::Apple10: return 9;
        case family::Mac2: return 10;
        case family::Common1: return 11;
        case family::Common2: return 12;
        case family::Common3: return 13;
        case family::Metal3: return 14;
        case family::Metal4: return 15;
    }
    return -1;
}

bool supportsFamily(const DeviceCaps& c, std::int32_t familyRawValue) noexcept {
    int i = familyIndex(familyRawValue);
    return i >= 0 && c.familySupport[static_cast<size_t>(i)] != 0;
}

bool isApple3OrBetterWithOS14Baseline(const DeviceCaps& c) noexcept {
    return c.platform == PlatformKind::Ios && supportsFamily(c, family::Apple3);
}

} // namespace mc
