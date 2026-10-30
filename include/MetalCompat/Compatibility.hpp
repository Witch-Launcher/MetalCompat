// MetalCompat — Compatibility.hpp
// SPEC 7.1 states vocabulary. Exactly these; nothing else.
#pragma once
#include <string>
#include <string_view>

namespace mc {

enum class CompatibilityState {
    Native,
    Fallback,
    Emulated,
    Approximated,
    Partial,
    Unsupported,
    Unknown,
};

constexpr std::string_view toString(CompatibilityState s) noexcept {
    switch (s) {
        case CompatibilityState::Native: return "NATIVE";
        case CompatibilityState::Fallback: return "FALLBACK";
        case CompatibilityState::Emulated: return "EMULATED";
        case CompatibilityState::Approximated: return "APPROXIMATED";
        case CompatibilityState::Partial: return "PARTIAL";
        case CompatibilityState::Unsupported: return "UNSUPPORTED";
        case CompatibilityState::Unknown: return "UNKNOWN";
    }
    return "UNKNOWN";
}

// Fails unknown strings — used by registry validation.
inline bool stateFromString(std::string_view s, CompatibilityState& out) noexcept {
    if (s == "NATIVE") out = CompatibilityState::Native;
    else if (s == "FALLBACK") out = CompatibilityState::Fallback;
    else if (s == "EMULATED") out = CompatibilityState::Emulated;
    else if (s == "APPROXIMATED") out = CompatibilityState::Approximated;
    else if (s == "PARTIAL") out = CompatibilityState::Partial;
    else if (s == "UNSUPPORTED") out = CompatibilityState::Unsupported;
    else if (s == "UNKNOWN") out = CompatibilityState::Unknown;
    else return false;
    return true;
}

} // namespace mc
