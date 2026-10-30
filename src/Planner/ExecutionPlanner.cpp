// ExecutionPlanner: least-expensive-valid-path decision (SPEC §3.2 E, D-003/D-006).
#include "MetalCompat/ExecutionPlanner.hpp"

#include <cstdlib>

namespace mc {
namespace {

// "iOS 13.0" / "macOS 10.15" → {prefix, major, minor}; false when unparsable.
bool parseOsRequirement(const std::string& s, std::string& prefix, int& major, int& minor) {
    if (s.empty()) return false;
    const size_t space = s.find(' ');
    if (space == std::string::npos) return false;
    prefix = s.substr(0, space);
    std::string ver = s.substr(space + 1);
    const size_t dot = ver.find('.');
    if (dot == std::string::npos) return false;
    major = std::atoi(ver.substr(0, dot).c_str());
    minor = std::atoi(ver.c_str() + dot + 1);
    if (major < 0 || major > 1000 || minor < 0 || minor > 1000) return false;
    return true;
}

struct RuntimeOs {
    std::string prefix;
    int major = 0, minor = 0;
};

RuntimeOs fromCaps(const DeviceCaps& c) {
    RuntimeOs r;
    r.prefix = (c.platform == PlatformKind::Ios) ? "iOS" :
               (c.platform == PlatformKind::Macos ? "macOS" : "");
    size_t space = c.osVersion.find(' ');
    if (space != std::string::npos) {
        std::string ver = c.osVersion.substr(space + 1);
        size_t dot = ver.find('.');
        if (dot != std::string::npos) {
            r.major = std::atoi(ver.substr(0, dot).c_str());
            r.minor = std::atoi(ver.c_str() + dot + 1);
        }
    }
    return r;
}

} // namespace

int ExecutionPlanner::resolveGateToken_(const std::string& gate) const noexcept {
    // [gateApple5orMac2] — layer selection:
    //   "All GPUs in the macOS family support layer selection. Layer selection
    //   is available in the Apple GPU family starting with family 5."
    //   (official Apple article: Rendering to multiple texture slices in a
    //   draw command; feature-set tables May 21, 2026 list Apple5.)
    if (gate.find("[gateApple5orMac2]") != std::string::npos) {
        if (supportsFamily(caps_, family::Apple5)) return 1;
        if (caps_.platform == PlatformKind::Macos && supportsFamily(caps_, family::Mac2)) return 1;
        // macOS devices that only report mac1 are not provable with the
        // current probe set => cannot resolve here (honest UNKNOWN).
        if (caps_.platform == PlatformKind::Macos) return -1;
        return 0;
    }
    return -2; // no token present
}

bool ExecutionPlanner::fallbackProvisioned(const std::string& featureId) const noexcept {
    for (const auto& id : provisioned_)
        if (id == featureId) return true;
    return false;
}

Error ExecutionPlanner::plan(const std::string& featureId, Decision& out) const noexcept {
    out = Decision{};
    const FeatureRecord* rec = registry_.find(featureId);
    if (!rec) {
        out.reason = "unknown feature (registry has no record)";
        return Error{ErrorCode::PlanUnsupported, featureId, "unknown feature"};
    }

    // OS-gating is checked against the *documented* requirement for the active
    // platform column (iOS vs macOS), never inferred from a family name.
    if (rec->verified) {
        const std::string& requiredForPlatform =
            (caps_.platform == PlatformKind::Macos) ? rec->requiredOsMac : rec->requiredOs;
        if (!requiredForPlatform.empty()) {
            std::string prefix; int rmaj = 0, rmin = 0;
            if (parseOsRequirement(requiredForPlatform, prefix, rmaj, rmin)) {
                RuntimeOs run = fromCaps(caps_);
                if (prefix != run.prefix) {
                    out.reason = "platform mismatch";
                    return Error{ErrorCode::UnavailableOs, featureId,
                                 "requires " + requiredForPlatform + "; runtime is " + caps_.osVersion};
                }
                if (run.major < rmaj || (run.major == rmaj && run.minor < rmin)) {
                    out.reason = "OS floor not met";
                    return Error{ErrorCode::UnavailableOs, featureId,
                                 "requires " + requiredForPlatform + "; runtime is " + caps_.osVersion};
                }
            }
        } else if (caps_.platform == PlatformKind::Macos && !rec->requiredOs.empty()) {
            // Honest gap: verified only for iOS; no macOS column recorded.
            out.reason = "no verified macOS availability";
            return Error{ErrorCode::UnavailableOs, featureId,
                         "availability verified for " + rec->requiredOs + " only"};
        }
    }

    switch (rec->state) {
        case CompatibilityState::Unknown:
            out.reason = "research incomplete (UNVERIFIED) — SPEC 10.8";
            return Error{ErrorCode::PlanUnsupported, featureId,
                         "state UNKNOWN until verified on target hardware"};

        case CompatibilityState::Unsupported:
        case CompatibilityState::Approximated:
            out.reason = "registry policy";
            return Error{ErrorCode::PlanUnsupported, featureId,
                         "state " + std::string(toString(rec->state)) +
                         (rec->fallbackStrategy.empty() ? "" : ": " + rec->fallbackStrategy)};

        case CompatibilityState::Emulated:
            // No emulation records exist yet; the path stays closed (GPU_RUNTIME §2).
            out.reason = "emulation records must be validated before use";
            return Error{ErrorCode::PlanUnsupported, featureId, "EMULATED path not provisioned"};

        case CompatibilityState::Partial: {
            // Machine-token gates (new records) resolve deterministically.
            const int tok = resolveGateToken_(rec->hardwareGate);
            if (tok != -2) {
                if (tok == 1) {
                    out.op = PlanOp::Native;
                    out.state = CompatibilityState::Partial;
                    out.reason = "hardware gate confirmed at runtime";
                    return Error{};
                }
                // Gate unmet or unresolvable: a documented fallback is the only
                // honest path — and only when it is provisioned (D-006).
                if (!rec->fallbackStrategy.empty() && fallbackProvisioned(featureId)) {
                    out.op = PlanOp::FallbackTranslation;
                    out.state = CompatibilityState::Partial;
                    out.reason = tok == 0 ? "gate unmet; registry fallback"
                                          : "gate unresolved; registry fallback";
                    return Error{};
                }
                out.reason = tok == 0 ? "hardware gate unmet" : "hardware gate unverified";
                return Error{ErrorCode::InsufficientHardware, featureId, "gate: " + rec->hardwareGate};
            }

            // Legacy free-text gate handling (M1 records; unchanged behavior).
            // Partial records are usable only when a runtime-verifiable or
            // hardware-derivable gate can be resolved now (SPEC D-005).
            const std::string& gate = rec->hardwareGate;
            if (gate.find("UNKNOWN") != std::string::npos) {
                out.reason = "hardware gate unverified";
                return Error{ErrorCode::InsufficientHardware, featureId,
                             "gate: " + gate};
            }
            if (gate.find("expected Apple7") != std::string::npos ||
                gate.find("Apple7") != std::string::npos) {
                if (supportsFamily(caps_, family::Apple7)) {
                    out.op = PlanOp::Native;
                    out.state = CompatibilityState::Native;
                    out.reason = "Apple7-class device confirmed";
                    return Error{};
                }
                // Documented fallback (if any) may take over on lower hardware.
                if (!rec->fallbackStrategy.empty() && fallbackProvisioned(featureId)) {
                    out.op = PlanOp::FallbackTranslation;
                    out.state = CompatibilityState::Partial;
                    out.reason = "gate unmet; registry fallback";
                    return Error{};
                }
                out.reason = "requires Apple7-class hardware";
                return Error{ErrorCode::InsufficientHardware, featureId, "gate: " + gate};
            }
            if (gate.find("Apple6") != std::string::npos) {
                if (supportsFamily(caps_, family::Apple6)) {
                    out.op = PlanOp::Native;
                    out.state = CompatibilityState::Partial;
                    out.reason = "Apple6-class device confirmed";
                    return Error{};
                }
                if (!rec->fallbackStrategy.empty() && fallbackProvisioned(featureId)) {
                    out.op = PlanOp::FallbackTranslation;
                    out.state = CompatibilityState::Partial;
                    out.reason = "gate unmet; registry fallback";
                    return Error{};
                }
                out.reason = "requires Apple6-class hardware";
                return Error{ErrorCode::InsufficientHardware, featureId, "gate: " + gate};
            }
            // e.g. "runtime-verify device support" — usable natively with diagnostics.
            out.op = PlanOp::Native;
            out.state = CompatibilityState::Partial;
            out.reason = "runtime-verify";
            return Error{};
        }

        case CompatibilityState::Fallback:
        case CompatibilityState::Native:
            out.op = PlanOp::Native;
            out.state = rec->state;
            out.reason = rec->category == "metal4" ? "Metal4 native backend"
                                                   : "legacy native path";
            if (rec->hardwareGate.find("runtime-verify") != std::string::npos)
                out.reason = "runtime-verify";
            if (rec->symbol.find("supportsFeatureSet") != std::string::npos)
                out.reason = "deprecated selector; supportsFamily preferred";
            return Error{};
    }
    out.reason = "unreachable state";
    return Error{ErrorCode::PlanUnsupported, featureId, "unhandled registry state"};
}

} // namespace mc
