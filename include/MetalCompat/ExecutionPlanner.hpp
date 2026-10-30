// MetalCompat — ExecutionPlanner.hpp / CommandPlan.hpp
// Least-expensive-valid-path decision (SPEC §3.2 E / D-003).
// Native decisions require no plan; typed plans exist only where translation /
// emulation is selected. This header is the merged home for both today.
#pragma once
#include "Capabilities.hpp"
#include "Compatibility.hpp"
#include "Device.hpp"
#include "Errors.hpp"
#include "FeatureRegistry.hpp"

#include <string>

namespace mc {

enum class PlanOp : std::uint8_t {
    Native,
    FallbackTranslation,
    GpuEmulation,
    CpuFallback,
    Approximation,
    Unsupported,
};

struct Decision {
    PlanOp op = PlanOp::Unsupported;
    CompatibilityState state = CompatibilityState::Unsupported;
    const char* reason = ""; ///< static, no allocation on hot path
};

/// Validation strictness (SPEC 4.2.1).
enum class ValidationLevel : std::uint8_t {
    Production,  ///< only safety-critical checks
    Diagnostic,  ///< + non-fatal diagnostic notes
    Development, ///< strictest
};

class ExecutionPlanner {
public:
    ExecutionPlanner(const FeatureRegistry& registry, const DeviceCaps& caps,
                     ValidationLevel level = ValidationLevel::Development) noexcept
        : registry_(registry), caps_(caps), level_(level) {}

    Error plan(const std::string& featureId, Decision& out) const noexcept;

private:
    const FeatureRegistry& registry_;
    const DeviceCaps caps_;
    [[maybe_unused]] ValidationLevel level_;
};

} // namespace mc
