// CapabilityReport — M2-stage device/capability inspector (host-run).
// Runs the full chain: device probe → registry load/validate → planner decisions.
#include "MetalCompat/Capabilities.hpp"
#include "MetalCompat/Device.hpp"
#include "MetalCompat/Errors.hpp"
#include "MetalCompat/ExecutionPlanner.hpp"
#include "MetalCompat/FeatureRegistry.hpp"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <mach-o/dyld.h>

using namespace mc;

namespace {

std::string exeDir() {
    char buf[4096];
    std::uint32_t size = sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) != 0) return ".";
    std::string p(buf);
    const size_t pos = p.find_last_of('/');
    return pos == std::string::npos ? std::string(".") : p.substr(0, pos);
}

bool fileExists(const std::string& path) {
    struct stat st{};
    return ::stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

std::string findRegistryDir() {
    if (const char* env = std::getenv("MC_REGISTRY_DIR")) {
        std::string dir(env);
        if (fileExists(dir + "/metal_api_registry.json")) return dir;
    }
    const std::string exe = exeDir();
    const std::string candidates[] = {
        "registry", exe + "/registry", exe + "/../registry", exe + "/../../registry",
    };
    for (const auto& c : candidates)
        if (fileExists(c + "/metal_api_registry.json")) return c;
    return {};
}

const char* planOpName(PlanOp op) {
    switch (op) {
        case PlanOp::Native: return "Native";
        case PlanOp::FallbackTranslation: return "Fallback";
        case PlanOp::GpuEmulation: return "GpuEmulation";
        case PlanOp::CpuFallback: return "CpuFallback";
        case PlanOp::Approximation: return "Approximation";
        case PlanOp::Unsupported: return "Unsupported";
    }
    return "?";
}

} // namespace

int main() {
    // 1. Device acquisition + capability snapshot (cached immutable, SPEC 4.3).
    Device d;
    Error e = createDefaultDevice(d);
    if (e) {
        std::printf("ERROR device probe: %s\n", describe(e).c_str());
        return 1;
    }
    const char* plat = d.caps.platform == PlatformKind::Ios ? "iOS" :
                       d.caps.platform == PlatformKind::Macos ? "macOS" : "unknown";
    std::printf("device name             : %s\n", d.caps.deviceName.c_str());
    std::printf("platform / OS           : %s / %s\n", plat, d.caps.osVersion.c_str());
    std::printf("apple gpu               : %s\n", d.caps.appleGpu ? "yes" : "no");
    std::printf("metal4 (family 5002)    : %s\n", d.caps.supportsMetal4 ? "yes" : "no");
    std::printf("maxBufferLength         : %llu\n", (unsigned long long)d.caps.maxBufferLength);
    std::printf("maxThreadgroupMemory    : %llu\n", (unsigned long long)d.caps.maxThreadgroupMemoryLength);
    std::printf("maxThreadsPerThreadgroup: %u/%u/%u\n", d.caps.maxThreadsPerThreadgroup[0],
                d.caps.maxThreadsPerThreadgroup[1], d.caps.maxThreadsPerThreadgroup[2]);
    std::printf("argumentBuffersTier     : %u\n", d.caps.argumentBuffersTier);
    std::printf("readWriteTextureTier    : %u\n", d.caps.readWriteTextureTier);
    std::printf("recommendedMaxWorkingSet: %llu\n", (unsigned long long)d.caps.recommendedMaxWorkingSetSize);

    std::printf("families                : ");
    constexpr int fams[] = {family::Apple1, family::Apple2, family::Apple3, family::Apple4,
                            family::Apple5, family::Apple6, family::Apple7, family::Apple8,
                            family::Apple9, family::Apple10, family::Mac2, family::Common1,
                            family::Common2, family::Common3, family::Metal3, family::Metal4};
    bool first = true;
    for (int f : fams) {
        if (supportsFamily(d.caps, f)) {
            std::printf("%s%s", first ? "" : ",", familyName(f));
            first = false;
        }
    }
    std::printf("\n");

    // 2. Registry validation + architectural invariants.
    const std::string regDir = findRegistryDir();
    FeatureRegistry reg;
    e = FeatureRegistry::load(regDir + "/metal_api_registry.json", reg);
    if (e) {
        std::printf("ERROR registry: %s\n", describe(e).c_str());
        return 2;
    }
    GpuCapabilitiesTable g;
    e = FeatureRegistry::loadGpuCapabilities(regDir + "/gpu_capabilities.json", g);
    if (e) {
        std::printf("ERROR gpu caps: %s\n", describe(e).c_str());
        return 2;
    }
    e = validatePrimaryTargetInvariant(g);
    if (e) {
        std::printf("ERROR invariant: %s\n", describe(e).c_str());
        return 2;
    }
    std::printf("registry ok             : %zu features, %zu gpu families (dir: %s)\n",
                reg.features().size(), g.families.size(), regDir.c_str());

    // 3. Planner decisions across the inventory.
    ExecutionPlanner planner(reg, d.caps, ValidationLevel::Diagnostic);
    for (const auto& rec : reg.features()) {
        Decision dec;
        Error pe = planner.plan(rec.id, dec);
        if (!pe) {
            std::printf("PLAN %-26s -> %-11s state=%s reason=%s\n", rec.id.c_str(),
                        planOpName(dec.op), std::string(toString(dec.state)).c_str(), dec.reason);
        } else {
            std::printf("PLAN %-26s -> REFUSED %-18s %s\n", rec.id.c_str(),
                        toString(pe.code), pe.message.substr(0, 72).c_str());
        }
    }
    std::printf("capability report complete\n");
    destroyDevice(d);
    return 0;
}
