// MetalCompat — Errors.hpp
// Typed, exception-free error model (no Apple headers in core).
#pragma once
#include <string>

namespace mc {

enum class ErrorCode {
    None,
    Unsupported,          // feature has no safe implementation (SPEC 7.1)
    UnavailableOs,        // OS floor above the deployment runtime
    InsufficientHardware, // device doesn't expose required capability
    InvalidRegistry,      // registry malformed / contradicts policy
    PlanUnsupported,
    BridgeFailure,
    InvalidArgument,
};

struct Error {
    ErrorCode code = ErrorCode::None;
    std::string featureId;
    std::string message;

    explicit operator bool() const noexcept { return code != ErrorCode::None; }
};

constexpr const char* toString(ErrorCode c) noexcept {
    switch (c) {
        case ErrorCode::None: return "None";
        case ErrorCode::Unsupported: return "Unsupported";
        case ErrorCode::UnavailableOs: return "UnavailableOs";
        case ErrorCode::InsufficientHardware: return "InsufficientHardware";
        case ErrorCode::InvalidRegistry: return "InvalidRegistry";
        case ErrorCode::PlanUnsupported: return "PlanUnsupported";
        case ErrorCode::BridgeFailure: return "BridgeFailure";
        case ErrorCode::InvalidArgument: return "InvalidArgument";
    }
    return "?";
}

inline std::string describe(const Error& e) {
    return std::string(toString(e.code)) + (e.featureId.empty() ? "" : " [" + e.featureId + "]") +
           (e.message.empty() ? "" : ": " + e.message);
}

} // namespace mc
