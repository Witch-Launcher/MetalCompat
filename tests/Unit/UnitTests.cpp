// MetalCompat unit tests (M1) — hermetic: synthetic registry/capability
// fixtures are written to a temp dir; the only file dependency is the real
// registry, which is copied next to the test binary and skipped if missing.
#include "MetalCompat/Capabilities.hpp"
#include "MetalCompat/Compatibility.hpp"
#include "MetalCompat/Errors.hpp"
#include "MetalCompat/ExecutionPlanner.hpp"
#include "MetalCompat/FeatureRegistry.hpp"

#include "../../src/CPU/Diagnostics/Diag.hpp"
#include "../../src/Registry/JsonLite.hpp"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

using namespace mc;

namespace {
int g_checks = 0, g_failed = 0;
void check(bool cond, const std::string& what) {
    ++g_checks;
    if (!cond) {
        ++g_failed;
        std::printf("  CHECK FAILED: %s\n", what.c_str());
    }
}

std::string writeTemp(const std::string& name, const std::string& content) {
    const auto base = std::filesystem::temp_directory_path() / ("mc_tests_" + name);
    std::ofstream o(base, std::ios::binary | std::ios::trunc);
    o << content;
    return base.string();
}

std::string findRegistryDir() {
    if (const char* env = std::getenv("MC_REGISTRY_DIR")) {
        std::string d(env);
        std::ifstream probe(d + "/metal_api_registry.json");
        if (probe.good()) return d;
    }
    const std::string cands[] = {"registry", "../registry", "../../registry"};
    for (const auto& c : cands) {
        std::ifstream probe(c + "/metal_api_registry.json");
        if (probe.good()) return c;
    }
    return {};
}

DeviceCaps makeA9Caps() {
    DeviceCaps c;
    c.platform = PlatformKind::Ios;
    c.osVersion = "iOS 14.0";
    c.appleGpu = true;
    c.familySupport[2] = 1;  // Apple3 (A9/A10)
    c.familySupport[1] = 1;  // Apple2 (weaker families usually also reported)
    c.familySupport[0] = 1;  // Apple1
    c.maxBufferLength = 256u * 1024u * 1024u;
    return c;
}

const char* kSyntheticStates = "\"statesAllowed\":[\"NATIVE\",\"FALLBACK\",\"EMULATED\","
    "\"APPROXIMATED\",\"PARTIAL\",\"UNSUPPORTED\",\"UNKNOWN\"]";
const char* kSyntheticCategories = "\"categoriesAllowed\":[\"device\",\"command\",\"pipeline\","
    "\"resource\",\"synchronization\",\"shader\",\"metal4\",\"related-framework\",\"diagnostics\"]";

std::string synthBackend() {
    static const std::string s = std::string(R"({
  "schemaVersion": 1,
  "sdk": {"name": "iPhoneOS26.2.sdk", "version": "26.2", "verifiedOn": "2026-10-30"},
  )") + kSyntheticStates + "," +
                              kSyntheticCategories + R"(,
  "features": [
    {"id":"pipe.render","symbol":"MTLRenderPipelineState","category":"pipeline",
     "requiredOs":"iOS 8.0","hardwareGate":"none","compatibilityState":"NATIVE",
     "fallbackStrategy":null,"notes":"",
     "verification":{"source":"sdk-headers","sdkVersion":"26.2","date":"2026-10-30"},
     "references":["fixture"]},
    {"id":"dev.supportsFamily","symbol":"supportsFamily:","category":"device",
     "requiredOs":"iOS 13.0","hardwareGate":"family-specific at runtime","compatibilityState":"NATIVE",
     "fallbackStrategy":null,"notes":"",
     "verification":{"source":"sdk-headers","sdkVersion":"26.2","date":"2026-10-30"},
     "references":["fixture"]},
    {"id":"mtl4.queue","symbol":"MTL4CommandQueue","category":"metal4",
     "requiredOs":"iOS 26.0","hardwareGate":"MTLGPUFamilyMetal4","compatibilityState":"UNSUPPORTED",
     "fallbackStrategy":"separate backend","notes":"",
     "verification":{"source":"sdk-headers","sdkVersion":"26.2","date":"2026-10-30"},
     "references":["fixture"]},
    {"id":"res.acceleration","symbol":"MTLAccelerationStructure","category":"resource",
     "requiredOs":"iOS 14.0","hardwareGate":"expected Apple7; probe required","compatibilityState":"PARTIAL",
     "fallbackStrategy":null,"notes":"",
     "verification":{"source":"sdk-headers","sdkVersion":"26.2","date":"2026-10-30"},
     "references":["fixture"]},
    {"id":"pipe.mesh.legacy","symbol":"legacy mesh","category":"pipeline",
     "requiredOs":null,"hardwareGate":null,"compatibilityState":"UNKNOWN",
     "fallbackStrategy":null,"notes":"no verified record",
     "verification":null,"references":[]},
    {"id":"pipe.tessellationFactor","symbol":"tess","category":"pipeline",
     "requiredOs":"iOS 10.0","hardwareGate":"UNKNOWN on Apple3","compatibilityState":"PARTIAL",
     "fallbackStrategy":null,"notes":"",
     "verification":{"source":"sdk-headers","sdkVersion":"26.2","date":"2026-10-30"},
     "references":["fixture"]},
    {"id":"cmd.indirectBuffer","symbol":"IndirectCommandBuffer","category":"command",
     "requiredOs":"iOS 12.0","hardwareGate":"runtime-verify device support","compatibilityState":"PARTIAL",
     "fallbackStrategy":null,"notes":"",
     "verification":{"source":"sdk-headers","sdkVersion":"26.2","date":"2026-10-30"},
     "references":["fixture"]},
    {"id":"fx.temporal","symbol":"MTLFXTemporalScaler","category":"related-framework",
     "requiredOs":"iOS 16.0","hardwareGate":"docs","compatibilityState":"PARTIAL",
     "fallbackStrategy":"approx study","notes":"",
     "verification":{"source":"sdk-headers","sdkVersion":"26.2","date":"2026-10-30"},
     "references":["fixture"]},
    {"id":"dev.residencySet","symbol":"MTLResidencySet","category":"resource",
     "requiredOs":"iOS 18.0","hardwareGate":"none","compatibilityState":"UNSUPPORTED",
     "fallbackStrategy":null,"notes":"",
     "verification":{"source":"sdk-headers","sdkVersion":"26.2","date":"2026-10-30"},
     "references":["fixture"]},
    {"id":"shader.msl23.onIOS14","symbol":"MTLLanguageVersion2_3","category":"shader",
     "requiredOs":"iOS 14.0","hardwareGate":"none","compatibilityState":"NATIVE",
     "fallbackStrategy":null,"notes":"",
     "verification":{"source":"sdk-headers","sdkVersion":"26.2","date":"2026-10-30"},
     "references":["fixture"]}
  ]
})";
    return s;
}
std::string synthCapsJson(const std::string& apple3Soc = "\"A9\",\"A10\"") {
    return std::string(R"({
  "schemaVersion": 1,
  "verifiedOn": "2026-10-30",
  "sources": ["test"],
  "families": [
    {"family":"Apple1","rawValue":1001,"soc":["A7"],"minimumOs":null},
    {"family":"Apple3","rawValue":1003,"soc":[)") + apple3Soc +
                       R"(],"minimumOs":null},
    {"family":"Metal3","rawValue":5001,"soc":["Apple7-class"],"minimumOs":"iOS 16.0 / macOS 13.0"},
    {"family":"Metal4","rawValue":5002,"soc":["MTL4-class"],"minimumOs":"iOS 26.0 / macOS 26.0"}
  ],
  "apiAvailability": [],
  "openQuestions": [],
  "deviceMatrix": {"planned": ["A9"], "validatedPhysical": []}
})";
}

} // namespace

// ---------------------------------------------------------------------------
void testJsonParser() {
    std::printf("[json parser]\n");
    auto p = json::parse("{ \"a\": [1, 2], \"b\": {\"c\": \"x\\u00e9\", \"d\": true}, \"e\": null }");
    check(static_cast<bool>(p.value), "valid doc parses");
    const json::Value* arr = p.value->find("a");
    check(arr && arr->type == json::Value::Type::Array && arr->size() == 2, "array shape");
    int num = -1;
    check(arr && arr->at(0)->asNumber(num) && num == 1, "number value");
    auto bad = json::parse("{\"a\":1} trailing");
    check(!bad.value, "trailing content rejected");
    auto dup = json::parse("{\"k\":1,\"k\":2}");
    check(!dup.value, "duplicate keys rejected");
    auto esc = json::parse("{\"s\":\"\\\"q\\\"\\\\\"}");
    check(esc.value && esc.value->find("s")->str == "\"q\"\\", "escape handling");
}

void testRegistryValidationPositive() {
    std::printf("[registry validation — positive]\n");
    const std::string reg = writeTemp("synth_reg.json", synthBackend());
    FeatureRegistry r;
    Error e = FeatureRegistry::load(reg, r);
    check(!e, "synthetic registry loads: " + describe(e));
    check(r.features().size() == 10, "feature count");
    check(r.find("pipe.render") != nullptr, "lookup works");
    check(r.find("no.such") == nullptr, "unknown lookup returns null");
    GpuCapabilitiesTable g;
    e = FeatureRegistry::loadGpuCapabilities(writeTemp("synth_caps.json", synthCapsJson()), g);
    check(!e, "synthetic gpu caps load");
    e = validatePrimaryTargetInvariant(g);
    check(!e, "Apple3 contains A9+A10: " + describe(e));
}

void testRegistryValidationNegative() {
    std::printf("[registry validation — negative]\n");
    auto replaceFirst = [](std::string s, const std::string& from, const std::string& to) {
        const size_t pos = s.find(from);
        if (pos != std::string::npos) s = s.substr(0, pos) + to + s.substr(pos + from.size());
        return s;
    };
    auto appendBeforeEnd = [](std::string s, const std::string& record) {
        const size_t pos = s.rfind("]}", std::string::npos);
        if (pos != std::string::npos) s = s.substr(0, pos) + record + "]}";
        return s;
    };

    FeatureRegistry r;
    // schemaVersion not supported
    check(FeatureRegistry::load(
              writeTemp("bad1.json",
                        replaceFirst(synthBackend(), "\"schemaVersion\": 1", "\"schemaVersion\": 2")),
              r).code == ErrorCode::InvalidRegistry,
          "schemaVersion 2 rejected");

    // state outside the allowed vocabulary (JSON stays valid, semantic fails)
    check(FeatureRegistry::load(
              writeTemp("bad2.json",
                        replaceFirst(synthBackend(), "\"compatibilityState\":\"NATIVE\"",
                                     "\"compatibilityState\":\"MAYBE\"")),
              r).code == ErrorCode::InvalidRegistry,
          "bad state rejected");

    // duplicate id: another copy of pipe.render appended
    const std::string dupRecord =
        R"(,{"id":"pipe.render","symbol":"dup","category":"pipeline","requiredOs":"iOS 8.0","hardwareGate":"none","compatibilityState":"NATIVE","fallbackStrategy":null,"notes":"","verification":{"source":"s","sdkVersion":"26.2","date":"2026-10-30"},"references":["r"])";
    check(FeatureRegistry::load(writeTemp("bad3.json", appendBeforeEnd(synthBackend(), dupRecord)),
                                r).code == ErrorCode::InvalidRegistry,
          "duplicate id rejected");

    // verified block missing on a NON-UNKNOWN record (SPEC 10.8)
    const std::string unverRecord =
        R"(,{"id":"ghost.noverify","symbol":"x","category":"device","requiredOs":"iOS 8.0","hardwareGate":"none","compatibilityState":"NATIVE","fallbackStrategy":null,"notes":"","verification":null,"references":[]})";
    check(FeatureRegistry::load(
              writeTemp("bad4.json", appendBeforeEnd(synthBackend(), unverRecord)), r)
              .code == ErrorCode::InvalidRegistry,
          "unverified NON-UNKNOWN record rejected (SPEC 10.8)");

    // detected: Apple3 without A10 breaks the primary-target invariant
    GpuCapabilitiesTable g2;
    Error eIn = FeatureRegistry::loadGpuCapabilities(
        writeTemp("capsbad.json", synthCapsJson("\"A9\"")), g2);
    check(!eIn, "caps with missing A10 loads");
    check(validatePrimaryTargetInvariant(g2).code == ErrorCode::InvalidRegistry,
          "Apple3 without A10 violates primary target invariant");

    // discovered: Metal4 pinned to the wrong OS floor must be rejected (D-008)
    GpuCapabilitiesTable g3;
    const std::string floored =
        replaceFirst(synthCapsJson(), "\"iOS 26.0 / macOS 26.0\"", "\"iOS 14.0\"");
    (void)FeatureRegistry::loadGpuCapabilities(writeTemp("capsbad2.json", floored), g3);
    check(validatePrimaryTargetInvariant(g3).code == ErrorCode::InvalidRegistry,
          "Metal4 fake floor 'iOS 14.0' rejected (D-008 pinned in validator)");
}

void testPlannerDecisionTable() {
    std::printf("[planner decision table]\n");
    const std::string reg = writeTemp("synth_reg2.json", synthBackend());
    FeatureRegistry r;
    Error e = FeatureRegistry::load(reg, r);
    check(!e, "synthetic registry loads");
    DeviceCaps caps = makeA9Caps();
    ExecutionPlanner planner(r, caps, ValidationLevel::Development);

    Decision d;
    check(!planner.plan("pipe.render", d) && d.op == PlanOp::Native && d.state == CompatibilityState::Native, "pipe.render native");
    check(!planner.plan("dev.supportsFamily", d) && d.op == PlanOp::Native, "supportsFamily native");
    check(planner.plan("mtl4.queue", d).code == ErrorCode::UnavailableOs, "mtl4.queue refused (OS floor)");
    check(planner.plan("fx.temporal", d).code == ErrorCode::UnavailableOs, "fx.temporal refused (iOS 16 floor)");
    check(planner.plan("dev.residencySet", d).code == ErrorCode::UnavailableOs, "residencySet refused (iOS 18 floor)");
    check(planner.plan("res.acceleration", d).code == ErrorCode::InsufficientHardware, "acceleration refused (not Apple7)");
    check(planner.plan("pipe.mesh.legacy", d).code == ErrorCode::PlanUnsupported, "unknown-state mesh refused");
    check(planner.plan("pipe.tessellationFactor", d).code == ErrorCode::InsufficientHardware, "tessellation refused (gate UNKNOWN)");
    check(!planner.plan("cmd.indirectBuffer", d) && d.state == CompatibilityState::Partial, "indirect buffer partial-native");
    check(!planner.plan("shader.msl23.onIOS14", d) && d.op == PlanOp::Native, "msl23 native at exactly iOS 14.0");
    check(planner.plan("never.defined", d).code == ErrorCode::PlanUnsupported, "unregistered feature refused");

    // Apple7-class device flips the acceleration gate.
    DeviceCaps apple7 = caps;
    apple7.familySupport[6] = 1;
    ExecutionPlanner p2(r, apple7, ValidationLevel::Development);
    Error eA = p2.plan("res.acceleration", d);
    check(!eA && d.op == PlanOp::Native, "acceleration native on Apple7 device");
}

void testCapabilitiesHelpers() {
    std::printf("[capabilities helpers]\n");
    DeviceCaps c = makeA9Caps();
    check(supportsFamily(c, family::Apple3), "Apple3 present");
    check(!supportsFamily(c, family::Metal4), "Metal4 absent");
    check(strcmp(familyName(1003), "Apple3") == 0, "familyName(1003==Apple3");
    check(strcmp(familyName(5002), "Metal4") == 0, "familyName(5002)==Metal4");
    auto state = [](const char* s) {
        CompatibilityState st;
        return stateFromString(s, st) ? std::string(toString(st)) : std::string("parse-fail");
    };
    check(state("EMULATED") == "EMULATED" && state("bogus") == "parse-fail", "state parse round-trip");
}

void testDiagnostics() {
    std::printf("[diagnostics]\n");
    using namespace mc::diag;
    auto& di = global();
    di.clear();
    di.disable();
    di.record(EventKind::FeatureSelected, "x.test");
    check(di.populatedCount() == 0, "disabled recording drops events");
    di.enable();
    di.record(EventKind::FeatureSelected, "x.test", "reason");
    check(di.populatedCount() == 1, "enabled recording stores events");
    bool found = false;
    for (size_t i = 0; i < di.populatedCount(); ++i)
        if (const Event* ev = di.snapshot(i); ev && ev->featureId == "x.test") found = true;
    check(found, "recorded event retrievable");
    di.clear();
}

void testRealRegistryIfAvailable() {
    std::printf("[real registry — end-to-end]\n");
    const std::string dir = findRegistryDir();
    if (dir.empty()) {
        std::printf("  (registry files not staged next to the test binary — skipped)\n");
        return;
    }
    FeatureRegistry r;
    Error e = FeatureRegistry::load(dir + "/metal_api_registry.json", r);
    check(!e, "real registry loads: " + describe(e));
    GpuCapabilitiesTable g;
    e = FeatureRegistry::loadGpuCapabilities(dir + "/gpu_capabilities.json", g);
    check(!e, "real gpu caps load");
    e = validatePrimaryTargetInvariant(g);
    check(!e, "real invariant passes");
    // Every feature referenced by APIs that the vertical slice plans exists
    // in the registry (IDs used by code live with records).
    for (const char* id : {"pipe.render", "cmd.buffer", "mtl4.queue", "fx.temporal"})
        check(r.find(id) != nullptr, std::string("registry contains ") + id);
}

int main() {
    testJsonParser();
    testRegistryValidationPositive();
    testRegistryValidationNegative();
    testPlannerDecisionTable();
    testCapabilitiesHelpers();
    testDiagnostics();
    testRealRegistryIfAvailable();
    std::printf("%s — %d checks, %d failed\n", g_failed ? "FAILED" : "PASSED", g_checks, g_failed);
    return g_failed ? 1 : 0;
}
