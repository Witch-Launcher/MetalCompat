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
#include <vector>

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

/// Runtime provisioning of translated/emulated fallback modules (D-003/D-006).
/// The registry only STATES a feature's mapping; the engine must separately
/// carry the KNOWLEDGE that a fallback implementation exists (an honest,
/// provisioned module, with tests). A feature whose fallback is unprovisioned
/// is refused, never silently executed.
struct PlannerConfig {
    /// Feature ids whose FALLBACK implementation is provisioned and validated.
    std::vector<std::string> provisionedFallbackIds;
};

class ExecutionPlanner {
public:
    ExecutionPlanner(const FeatureRegistry& registry, const DeviceCaps& caps,
                     ValidationLevel level = ValidationLevel::Development,
                     const PlannerConfig& config = PlannerConfig{}) noexcept
        : registry_(registry), caps_(caps), level_(level)
        , provisioned_(config.provisionedFallbackIds) {}

    Error plan(const std::string& featureId, Decision& out) const noexcept;

    /// True when `featureId`'s fallback is provisioned in this configuration.
    bool fallbackProvisioned(const std::string& featureId) const noexcept;

private:
    /// Resolves a registry hardware gate that carries a machine token:
    ///   [gateApple5orMac2]  — layered rendering: Apple GPU family 5+, or any
    ///                         macOS-family GPU (official Apple article rule).
    /// Returns 1 when native support is confirmed, 0 when confirmed absent,
    /// -1 when the gate cannot be resolved at runtime (treated as unverified).
    int resolveGateToken_(const std::string& gate) const noexcept;

    const FeatureRegistry& registry_;
    const DeviceCaps caps_;
    [[maybe_unused]] ValidationLevel level_;
    std::vector<std::string> provisioned_; ///< fallback catalog (by id)
};

} // namespace mc
