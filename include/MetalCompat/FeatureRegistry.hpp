// MetalCompat — FeatureRegistry.hpp
// Machine-readable versioned inventory of public Metal features (SPEC §7).
// Pure C++; the JSON reader lives in src/Registry.
#pragma once
#include "Compatibility.hpp"
#include "Errors.hpp"

#include <string>
#include <vector>

namespace mc {

struct RegistryInfo {
    int schemaVersion = 0;
    std::string sdkVersion;
    std::string verifiedOn;
};

struct FeatureRecord {
    std::string id;
    std::string symbol;
    std::string category;
    std::string requiredOs;      // "iOS 13.0" or "" when not evidenced
    std::string requiredOsMac;   // "macOS 10.15" or "" when not evidenced
    std::string hardwareGate;    // "" or descriptor; "UNKNOWN..." keeps gate open
    CompatibilityState state = CompatibilityState::Unknown;
    std::string fallbackStrategy;
    std::string notes;
    bool verified = false;       // verification block present
    std::string verifiedSdk;
    std::string verifiedDate;
    std::vector<std::string> references;
};

struct GpuFamilyInfo {
    std::string family;      // "Apple3"
    std::int32_t rawValue = 0;
    std::vector<std::string> soc;         // ["A9","A10"]
    std::string minimumOs;                // "" when not documented
};

struct GpuCapabilitiesTable {
    int schemaVersion = 0;
    std::string verifiedOn;
    std::vector<GpuFamilyInfo> families;

    /// Machine-resolvable feature gates (OPTIONAL block "featureGates").
    struct FeatureGate {
        std::string feature;   // registry feature id
        std::string gateToken; // exactly the token embedded in the record
        std::vector<std::string> nativeFamilies;
        std::string basis;     // citation / verification note
    };
    std::vector<FeatureGate> featureGates;

    /// Verified numeric limits of the primary hardware target ("limitsApple3").
    /// Long unsigned long names kept verbatim from the feature-set tables.
    using LimitsApple3 = std::vector<std::pair<std::string, double>>;
    LimitsApple3 limitsApple3;
};

class FeatureRegistry {
public:
    /// Load + validate (errors reported as mc::Error; exception-free).
    static Error load(const std::string& apiJsonPath, FeatureRegistry& out) noexcept;
    static Error loadGpuCapabilities(const std::string& path, GpuCapabilitiesTable& out) noexcept;

    const FeatureRecord* find(const std::string& featureId) const noexcept;
    const std::vector<FeatureRecord>& features() const noexcept { return records_; }
    const RegistryInfo& info() const noexcept { return info_; }

private:
    RegistryInfo info_;
    std::vector<FeatureRecord> records_;
};

// Cross-checks that pin our architectural invariants (called by validator).
Error validatePrimaryTargetInvariant(const GpuCapabilitiesTable& g) noexcept;
/// Cross-file: every declared gate token must exist in a registered record
/// with the same token; native families must be documented; limits positive.
Error validateFeatureGatesCrossFile(const FeatureRegistry& reg,
                                    const GpuCapabilitiesTable& g) noexcept;

} // namespace mc
