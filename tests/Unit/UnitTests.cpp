// MetalCompat unit tests (M1) — hermetic: synthetic registry/capability
// fixtures are written to a temp dir; the only file dependency is the real
// registry, which is copied next to the test binary and skipped if missing.
#include "MetalCompat/Capabilities.hpp"
#include "MetalCompat/Compatibility.hpp"
#include "MetalCompat/Errors.hpp"
#include "MetalCompat/ExecutionPlanner.hpp"
#include "MetalCompat/FeatureRegistry.hpp"
#include "MetalCompat/Shader.hpp"

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
    {"id":"mtl4.commandBuffer","symbol":"MTL4CommandBuffer","category":"metal4",
     "requiredOs":"iOS 26.0","hardwareGate":"MTLGPUFamilyMetal4","compatibilityState":"UNSUPPORTED",
     "fallbackStrategy":null,"notes":"Distinct from MTLCommandBuffer by design.",
     "verification":{"source":"sdk-headers","sdkVersion":"26.2","date":"2026-10-30"},
     "references":["fixture"]},
    {"id":"mtl4.renderPipeline","symbol":"MTL4RenderPipeline","category":"metal4",
     "requiredOs":"iOS 26.0","hardwareGate":"MTLGPUFamilyMetal4","compatibilityState":"UNSUPPORTED",
     "fallbackStrategy":null,"notes":"",
     "verification":{"source":"sdk-headers","sdkVersion":"26.2","date":"2026-10-30"},
     "references":["fixture"]},
    {"id":"mtl4.meshPipeline","symbol":"MTL4MeshRenderPipeline","category":"metal4",
     "requiredOs":"iOS 26.0","hardwareGate":"MTLGPUFamilyMetal4","compatibilityState":"UNSUPPORTED",
     "fallbackStrategy":null,"notes":"",
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
     "references":["fixture"]},
    {"id":"render.layered","symbol":"renderTargetArrayLength","category":"pipeline",
     "requiredOs":"iOS 12.0","requiredOsMac":"macOS 10.11",
     "hardwareGate":"[gateApple5orMac2]","compatibilityState":"PARTIAL",
     "fallbackStrategy":"per-slice passes via single-slice texture views",
     "notes":"Apple5+ / macOS-family rule via official Apple article",
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
    check(r.features().size() == 14, "feature count");
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
    ExecutionPlanner planner(r, caps, ValidationLevel::Development); // no provisioning

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
    // render.layered: gate unmet on A9 (Apple3) and fallback NOT provisioned.
    check(planner.plan("render.layered", d).code == ErrorCode::InsufficientHardware,
          "layered refused without provisioning (D-006)");
    check(!planner.fallbackProvisioned("render.layered"), "provisioning catalog empty");

    // Apple7-class device flips the acceleration gate.
    DeviceCaps apple7 = caps;
    apple7.familySupport[6] = 1;
    ExecutionPlanner p2(r, apple7, ValidationLevel::Development);
    Error eA = p2.plan("res.acceleration", d);
    check(!eA && d.op == PlanOp::Native, "acceleration native on Apple7 device");

    // ---- Ray tracing gating (honest per-device probe) ----
    // res.acceleration on A9 (Apple3, no RT): InsufficientHardware.
    check(planner.plan("res.acceleration", d).code == ErrorCode::InsufficientHardware,
          "acceleration refused on A9 (no ray tracing)");
    check(d.op == PlanOp::Unsupported, "acceleration decision unsupported on A9");

    // mtl4.* refused on iOS 14 / non-Metal4 hardware (OS floor).
    check(planner.plan("mtl4.queue", d).code == ErrorCode::UnavailableOs,
          "mtl4.queue refused on iOS 14 baseline (UnavailableOs)");
    check(planner.plan("mtl4.commandBuffer", d).code == ErrorCode::UnavailableOs,
          "mtl4.commandBuffer refused on iOS 14 baseline");
    check(planner.plan("mtl4.renderPipeline", d).code == ErrorCode::UnavailableOs,
          "mtl4.renderPipeline refused on iOS 14 baseline");
    check(planner.plan("mtl4.meshPipeline", d).code == ErrorCode::UnavailableOs,
          "mtl4.meshPipeline refused on iOS 14 baseline");

    // DeviceCaps field sanity on synthetic A9 caps.
    check(!supportsFamily(caps, family::Metal4), "Metal4 family absent on A9");
    check(caps.metalVersion == 3, "A9 metalVersion == 3 (Metal 3 class)");
    check(caps.supportsRaytracing == 0, "A9 supportsRaytracing == 0 (no RT)");
}

void testVariantSubsystem() {
    std::printf("[shader variant subsystem]\n");
    using namespace mc;

    check(variantHash("abc") == variantHash("abc"), "hash deterministic");
    check(variantHash("abc") != variantHash("abd"), "hash distinguishes");

    Error e = validateDefine("GOOD_name2", "1");
    check(!e, "valid define accepted: " + describe(e));
    check(validateDefine("9bad", "1").code == ErrorCode::InvalidArgument, "digit-leading name rejected");
    check(validateDefine("", "1").code == ErrorCode::InvalidArgument, "empty name rejected");
    check(validateDefine("OK", "bad\\").code == ErrorCode::InvalidArgument, "trailing backslash rejected");
    check(validateDefine("OK", std::string("a\0", 2)).code == ErrorCode::InvalidArgument,
          "control char rejected");
    check(validateDefine(std::string(300, 'x'), "1").code == ErrorCode::InvalidArgument,
          "overlong name rejected");

    std::vector<VariantDefine> defs = {{"B", "2"}, {"A", "1"}, {"A", "1"}};
    e = canonicalizeDefines(defs);
    check(e.code == ErrorCode::InvalidArgument, "duplicate define rejected");
    defs = {{"B", "2"}, {"A", "1"}};
    e = canonicalizeDefines(defs);
    check(!e && defs.size() == 2 && defs[0].name == "A" && defs[1].name == "B",
          "defines sorted");

    const std::string body = "kernel void k() {}";
    std::string keyText;
    const std::string src = emitVariantSource(body, defs, kMslLanguage_2_3, keyText);
    check(src.find("kernel void k() {}") != std::string::npos, "body preserved verbatim");
    check(src.find("#define A 1") < src.find("kernel void k() {}"), "define emitted before body");
    check(!keyText.empty(), "key text produced");
    const std::string src2 = emitVariantSource(body, defs, kMslLanguage_2_2, keyText);
    check(src != src2, "different MSL version -> different source");

    // Library: stub translator compiles exact text; records what it saw.
    struct Ctx {
        std::vector<std::string> compiled;
        bool reject = false;
    } ctx;
    ShaderVariantLibrary lib(
        [&](const std::string& srcVariant, const std::string&, void** outLib, std::string&) -> Error {
            if (ctx.reject) return Error{ErrorCode::InvalidArgument, "", "stub reject"};
            ctx.compiled.push_back(srcVariant);
            *outLib = ctx.compiled.data() + (ctx.compiled.size() - 1); // dummy non-null
            return Error{};
        },
        [](void*) noexcept {},
        1);

    CompiledVariant v;
    e = lib.getVariant(body, defs, kMslLanguage_2_3, v);
    check(!e && v.library && v.cookie, "first build compiles: " + describe(e));
    check(ctx.compiled.size() == 1, "compiled once");

    CompiledVariant v2;
    e = lib.getVariant(body, defs, kMslLanguage_2_3, v2);
    check(!e && v2.library == v.library && ctx.compiled.size() == 1, "cache hit, one library");
    check(v2.cookie == v.cookie, "same cookie for same request");

    lib.releaseVariant(v2.cookie);
    lib.releaseVariant(v.cookie); // last reference; entry becomes evictable
    CompiledVariant v3;
    // Same key again after full release: still cached (capacity 1, no pressure).
    e = lib.getVariant(body, defs, kMslLanguage_2_3, v3);
    check(!e && v3.library == v.library && ctx.compiled.size() == 1, "released entry reused");

    // Distinct key + full cache: pinned entries are never evicted while used.
    CompiledVariant vOld = v3; // still pinned (refs=1)
    CompiledVariant vOther;
    e = lib.getVariant("kernel void other() {}", {}, kMslLanguage_2_3, vOther);
    check(!e && vOther.library && vOther.library != vOld.library, "second variant compiles");
    auto s = lib.stats();
    check(s.pinned == 2, "both variants pinned while referenced");

    // Release the old entry; new request now forces eviction of the LRU.
    lib.releaseVariant(vOld.cookie);
    CompiledVariant vThird;
    e = lib.getVariant("kernel void third() {}", {}, kMslLanguage_2_3, vThird);
    check(!e, "third compiles");
    s = lib.stats();
    check(s.evictions >= 1, "unpinned LRU entry evicted");
    check(lib.stats().pinned == 2, "pinned count tracks live references");

    // Release ordering is caller-owned; skipping one cookie leaves one pinned.
    lib.releaseVariant(vOther.cookie);
    lib.releaseVariant(vThird.cookie);
    check(lib.stats().pinned == 0, "all references released");

    // Double release is a no-op; failure path returns the compile error.
    lib.releaseVariant(vThird.cookie);
    check(lib.stats().pinned == 0, "double release ignored");
    ctx.reject = true;
    CompiledVariant vBad;
    e = lib.getVariant("kernel void bad() {}", {}, kMslLanguage_2_3, vBad);
    check(e.code == ErrorCode::InvalidArgument && !vBad.library, "compile failure surfaced");
}

void testPlannerFallbackProvisioning() {
    std::printf("[planner fallback provisioning]\n");
    const std::string reg = writeTemp("synth_reg3.json", synthBackend());
    FeatureRegistry r;
    Error e = FeatureRegistry::load(reg, r);
    check(!e, "synthetic registry loads");

    PlannerConfig cfg;
    cfg.provisionedFallbackIds.push_back("render.layered");
    DeviceCaps a9 = makeA9Caps(); // gate unmet (Apple3, iOS platform)
    ExecutionPlanner p(r, a9, ValidationLevel::Development, cfg);

    Decision d;
    const Error eP = p.plan("render.layered", d);
    check(!eP, "layered plans when fallback provisioned: " + describe(eP));
    check(d.op == PlanOp::FallbackTranslation, "A9 -> FallbackTranslation");
    check(d.state == CompatibilityState::Partial, "state stays PARTIAL");

    // macOS device: gate met => native even if a fallback is provisioned.
    DeviceCaps mac2 = a9;
    mac2.platform = PlatformKind::Macos;
    mac2.appleGpu = false;
    mac2.familySupport.fill(0);
    mac2.familySupport[10] = 1; // Mac2
    mac2.familySupport[12] = 1; // Common2
    ExecutionPlanner pm(r, mac2, ValidationLevel::Development, cfg);
    d = Decision{};
    check(!pm.plan("render.layered", d) && d.op == PlanOp::Native,
          "Mac2 -> Native via gate token");
    // Feature with no token and an Apple7 gate + provisioned fallback still
    // falls back on weaker hardware (Apple6 branch reuses the catalog too).
    DeviceCaps a7 = a9;
    a7.familySupport[5] = 1; // Apple6
    ExecutionPlanner pw(r, a7, ValidationLevel::Development, cfg);
    d = Decision{};
    // fx.temporal is OS-floored at iOS 16, so use acceleration instead: Apple6
    // does NOT meet "expected Apple7" -> FALLBACK would apply if the record
    // had a documented strategy; it has none, so refusal persists.
    check(pw.plan("res.acceleration", d).code == ErrorCode::InsufficientHardware,
          "no strategy, no fallback (honors D-006)"); 
    check(d.op == PlanOp::Unsupported, "decision remains unsupported");
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
    e = validateFeatureGatesCrossFile(r, g);
    check(!e, "real feature-gate cross-file check passes: " + describe(e));
    // Every feature referenced by APIs that the vertical slice plans exists
    // in the registry (IDs used by code live with records).
    for (const char* id : {"pipe.render", "cmd.buffer", "mtl4.queue", "fx.temporal",
                           "res.acceleration", "res.acceleration.emulated",
                           "metal.version.compat"})
        check(r.find(id) != nullptr, std::string("registry contains ") + id);
}

int main() {
    testJsonParser();
    testRegistryValidationPositive();
    testRegistryValidationNegative();
    testPlannerDecisionTable();
    testPlannerFallbackProvisioning();
    testVariantSubsystem();
    testCapabilitiesHelpers();
    testDiagnostics();
    testRealRegistryIfAvailable();
    std::printf("%s — %d checks, %d failed\n", g_failed ? "FAILED" : "PASSED", g_checks, g_failed);
    return g_failed ? 1 : 0;
}
