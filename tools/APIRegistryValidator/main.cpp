// APIRegistryValidator — validates registry files + primary-target invariants.
// Exit 0 = valid; 1 = any violation (prints field + record details).
#include "MetalCompat/Errors.hpp"
#include "MetalCompat/FeatureRegistry.hpp"

#include <cstdio>
#include <string>

using namespace mc;

int main(int argc, char** argv) {
    if (argc != 3) {
        std::fprintf(stderr, "usage: MC_RegistryValidator <metal_api_registry.json> <gpu_capabilities.json>\n");
        return 1;
    }
    FeatureRegistry reg;
    Error e = FeatureRegistry::load(argv[1], reg);
    if (e) {
        std::fprintf(stderr, "registry INVALID: %s\n", describe(e).c_str());
        return 1;
    }
    GpuCapabilitiesTable g;
    e = FeatureRegistry::loadGpuCapabilities(argv[2], g);
    if (e) {
        std::fprintf(stderr, "gpu-caps INVALID: %s\n", describe(e).c_str());
        return 1;
    }
    e = validatePrimaryTargetInvariant(g);
    if (e) {
        std::fprintf(stderr, "invariant VIOLATION: %s\n", describe(e).c_str());
        return 1;
    }
    e = validateFeatureGatesCrossFile(reg, g);
    if (e) {
        std::fprintf(stderr, "feature-gates INVALID: %s\n", describe(e).c_str());
        return 1;
    }
    // state distribution summary
    int counts[7] = {0};
    for (const auto& f : reg.features()) ++counts[static_cast<int>(f.state)];
    std::printf("registry valid: %zu features | NATIVE=%d FALLBACK=%d EMULATED=%d "
                "APPROXIMATED=%d PARTIAL=%d UNSUPPORTED=%d UNKNOWN=%d | families=%zu\n",
                reg.features().size(), counts[0], counts[1], counts[2], counts[3],
                counts[4], counts[5], counts[6], g.families.size());
    return 0;
}
