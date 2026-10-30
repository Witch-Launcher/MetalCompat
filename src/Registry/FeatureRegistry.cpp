// FeatureRegistry: load + validate the versioned API inventory (SPEC §7).
#include "MetalCompat/FeatureRegistry.hpp"

#include "JsonLite.hpp"

#include <fstream>
#include <sstream>

namespace mc {
namespace {

bool readWholeFile(const std::string& path, std::string& out, std::string& err) {
    std::ifstream f(path, std::ios::binary);
    if (!f) { err = "cannot open file: " + path; return false; }
    std::ostringstream ss;
    ss << f.rdbuf();
    out = ss.str();
    return true;
}

const json::Value* req(const json::Value* v, const char* key, std::string& err) {
    const json::Value* r = v ? v->find(key) : nullptr;
    if (!r) err += std::string(" missing '") + key + "'";
    return r;
}

std::string strOf(const json::Value* v) {
    std::string s;
    if (v) (void)v->asString(s);
    return s;
}

bool inList(const json::Value* list, const std::string& needle) {
    if (list && list->type == json::Value::Type::Array) {
        size_t n = list->size();
        for (size_t i = 0; i < n; ++i) {
            if (strOf(list->at(i)) == needle) return true;
        }
    }
    return false;
}

} // namespace

// ---------------------------------------------------------------------------
Error FeatureRegistry::load(const std::string& path, FeatureRegistry& out) noexcept {
    out = FeatureRegistry{};
    std::string contents, ioErr;
    if (!readWholeFile(path, contents, ioErr)) {
        return Error{ErrorCode::InvalidRegistry, "", ioErr};
    }
    auto parsed = json::parse(contents);
    if (!parsed.value) return Error{ErrorCode::InvalidRegistry, "", parsed.error};

    const json::Value* root = parsed.value.get();
    if (root->type != json::Value::Type::Object)
        return Error{ErrorCode::InvalidRegistry, "", "registry root must be an object"};

    std::string err;
    const json::Value* vSchema = req(root, "schemaVersion", err);
    if (!vSchema) return Error{ErrorCode::InvalidRegistry, "", "registry:" + err};
    (void)vSchema->asNumber(out.info_.schemaVersion);
    if (out.info_.schemaVersion != 1)
        return Error{ErrorCode::InvalidRegistry, "", "unsupported registry schemaVersion"};

    const json::Value* vSdk = req(root, "sdk", err);
    if (!vSdk) return Error{ErrorCode::InvalidRegistry, "", "registry:" + err};
    out.info_.sdkVersion = strOf(vSdk->find("version"));
    out.info_.verifiedOn = strOf(vSdk->find("verifiedOn"));
    if (out.info_.verifiedOn.empty())
        return Error{ErrorCode::InvalidRegistry, "", "registry sdk.verifiedOn missing"};

    const json::Value* states = req(root, "statesAllowed", err);
    const json::Value* cats = req(root, "categoriesAllowed", err);
    if (!states || !cats) return Error{ErrorCode::InvalidRegistry, "", "registry:" + err};

    const json::Value* vFeatures = req(root, "features", err);
    if (!vFeatures || vFeatures->type != json::Value::Type::Array)
        return Error{ErrorCode::InvalidRegistry, "", "registry: 'features' missing/not array"};

    const size_t n = vFeatures->size();
    bool hadUnknownState = false;
    out.records_.reserve(n);
    for (size_t i = 0; i < n; ++i) {
        const json::Value* f = vFeatures->at(i);
        if (!f || f->type != json::Value::Type::Object)
            return Error{ErrorCode::InvalidRegistry, "", "feature[" + std::to_string(i) + "] not object"};

        FeatureRecord r;
        std::string id;
        const json::Value* vId = f->find("id");
        if (!vId || !vId->asString(id) || id.empty())
            return Error{ErrorCode::InvalidRegistry, "", "feature[" + std::to_string(i) + "]: missing/empty id"};
        r.id = id;
        r.symbol = strOf(f->find("symbol"));
        r.category = strOf(f->find("category"));
        r.requiredOs = strOf(f->find("requiredOs"));
        r.requiredOsMac = strOf(f->find("requiredOsMac"));
        r.hardwareGate = strOf(f->find("hardwareGate"));
        r.fallbackStrategy = strOf(f->find("fallbackStrategy"));
        r.notes = strOf(f->find("notes"));

        std::string stateStr = strOf(f->find("compatibilityState"));
        if (!stateFromString(stateStr, r.state))
            return Error{ErrorCode::InvalidRegistry, id, "bad compatibilityState '" + stateStr + "'"};
        if (!inList(states, stateStr))
            return Error{ErrorCode::InvalidRegistry, id, "compatibilityState not in statesAllowed"};

        if (r.category.empty() || !inList(cats, r.category))
            return Error{ErrorCode::InvalidRegistry, id, "category missing or not in categoriesAllowed"};

        const json::Value* ver = f->find("verification");
        if (ver && ver->type != json::Value::Type::Null) {
            r.verified = true;
            r.verifiedSdk = strOf(ver->find("sdkVersion"));
            r.verifiedDate = strOf(ver->find("date"));
            if (r.verifiedSdk.empty() || r.verifiedDate.empty())
                return Error{ErrorCode::InvalidRegistry, id, "verification block incomplete"};
        }
        if (!r.verified && r.state != CompatibilityState::Unknown)
            return Error{ErrorCode::InvalidRegistry, id,
                         "non-UNKNOWN state requires a verification block (SPEC 10.8)"};

        const json::Value* refs = f->find("references");
        if (refs && refs->type == json::Value::Type::Array) {
            size_t m = refs->size();
            for (size_t k = 0; k < m; ++k) {
                std::string ref = strOf(refs->at(k));
                if (!ref.empty()) r.references.push_back(std::move(ref));
            }
        }
        // Fabricated-verifier guard: non-UNKNOWN records must cite SDK or doc evidence.
        if (r.verified && r.references.empty() && r.state != CompatibilityState::Unknown)
            return Error{ErrorCode::InvalidRegistry, id, "verified record without references"};

        out.records_.push_back(std::move(r));
    }

    for (size_t i = 0; i < out.records_.size(); ++i) {
        for (size_t k = i + 1; k < out.records_.size(); ++k)
            if (out.records_[i].id == out.records_[k].id)
                return Error{ErrorCode::InvalidRegistry, out.records_[i].id, "duplicate id"};
    }
    (void)hadUnknownState;
    return Error{};
}

Error FeatureRegistry::loadGpuCapabilities(const std::string& path, GpuCapabilitiesTable& out) noexcept {    out = GpuCapabilitiesTable{};
    std::string contents, ioErr;
    if (!readWholeFile(path, contents, ioErr))
        return Error{ErrorCode::InvalidRegistry, "", ioErr};
    auto parsed = json::parse(contents);
    if (!parsed.value) return Error{ErrorCode::InvalidRegistry, "", parsed.error};

    const json::Value* root = parsed.value.get();
    if (root->type != json::Value::Type::Object)
        return Error{ErrorCode::InvalidRegistry, "", "gpu caps root must be an object"};

    std::int64_t svg = 0;
    if (const json::Value* s = root->find("schemaVersion")) (void)s->asNumber(svg);
    if (svg != 1) return Error{ErrorCode::InvalidRegistry, "", "unsupported gpu caps schemaVersion"};
    out.schemaVersion = static_cast<int>(svg);
    out.verifiedOn = strOf(root->find("verifiedOn"));
    if (out.verifiedOn.empty())
        return Error{ErrorCode::InvalidRegistry, "", "gpu caps verifiedOn missing"};

    const json::Value* fams = root->find("families");
    if (!fams || fams->type != json::Value::Type::Array)
        return Error{ErrorCode::InvalidRegistry, "", "gpu caps: 'families' missing/not array"};

    size_t n = fams->size();
    for (size_t i = 0; i < n; ++i) {
        const json::Value* f = fams->at(i);
        GpuFamilyInfo g;
        g.family = strOf(f->find("family"));
        if (g.family.empty())
            return Error{ErrorCode::InvalidRegistry, "", "family[" + std::to_string(i) + "] missing name"};
        std::int64_t raw = 0;
        if (const json::Value* rv = f->find("rawValue")) (void)rv->asNumber(raw);
        if (raw <= 0)
            return Error{ErrorCode::InvalidRegistry, g.family, "rawValue invalid"};
        g.rawValue = static_cast<std::int32_t>(raw);
        g.minimumOs = strOf(f->find("minimumOs"));
        if (const json::Value* soc = f->find("soc"); soc && soc->type == json::Value::Type::Array) {
            size_t m = soc->size();
            for (size_t k = 0; k < m; ++k) {
                std::string s = strOf(soc->at(k));
                if (!s.empty()) g.soc.push_back(std::move(s));
            }
        }
        out.families.push_back(std::move(g));
    }

    // OPTIONAL blocks: machine gates + Apple3 limits (validated when present).
    if (const json::Value* gates = root->find("featureGates");
        gates && gates->type == json::Value::Type::Array) {
        for (size_t i = 0; i < gates->size(); ++i) {
            const json::Value* gt = gates->at(i);
            GpuCapabilitiesTable::FeatureGate g;
            g.feature = strOf(gt->find("feature"));
            g.gateToken = strOf(gt->find("gateToken"));
            g.basis = strOf(gt->find("basis"));
            if (g.feature.empty() || g.gateToken.empty())
                return Error{ErrorCode::InvalidRegistry, g.feature,
                             "featureGates[" + std::to_string(i) + "]: missing feature/gateToken"};
            if (g.gateToken.front() != '[' || g.gateToken.back() != ']' ||
                g.gateToken.find(' ') != std::string::npos)
                return Error{ErrorCode::InvalidRegistry, g.feature,
                             "featureGates[" + std::to_string(i) + "]: token not machine-form"};
            if (const json::Value* arr = gt->find("nativeFamilies");
                arr && arr->type == json::Value::Type::Array)
                for (size_t k = 0; k < arr->size(); ++k) {
                    std::string s1 = strOf(arr->at(k));
                    if (!s1.empty()) g.nativeFamilies.push_back(std::move(s1));
                }
            out.featureGates.push_back(std::move(g));
        }
    }
    if (const json::Value* lim = root->find("limitsApple3");
        lim && lim->type == json::Value::Type::Object) {
        for (const auto& m : lim->obj) {
            if (m.key == "verification") continue; // citation block, not a limit
            double v = 0;
            if (m.value && m.value->type == json::Value::Type::Number) v = m.value->num;
            if (v > 0) out.limitsApple3.emplace_back(m.key, v);
        }
        if (const json::Value* vfy = lim->find("verification")) {
            if (vfy->type == json::Value::Type::Object) {
                if (strOf(vfy->find("source")).empty() || strOf(vfy->find("sdkVersion")).empty()
                    || strOf(vfy->find("date")).empty())
                    return Error{ErrorCode::InvalidRegistry, "limitsApple3",
                                 "verification block must cite source + sdkVersion + date"};
            } else {
                return Error{ErrorCode::InvalidRegistry, "limitsApple3",
                             "verification must be an object"};
            }
        } else {
            return Error{ErrorCode::InvalidRegistry, "limitsApple3",
                         "limits without verification block (SPEC 10.8)"};
        }
        if (out.limitsApple3.empty())
            return Error{ErrorCode::InvalidRegistry, "limitsApple3", "limits block empty"};
    }
    return Error{};
}

const FeatureRecord* FeatureRegistry::find(const std::string& featureId) const noexcept {
    for (const auto& rec : records_)
        if (rec.id == featureId) return &rec;
    return nullptr;
}

Error validatePrimaryTargetInvariant(const GpuCapabilitiesTable& g) noexcept {
    const GpuFamilyInfo* apple3 = nullptr;
    const GpuFamilyInfo* metal3 = nullptr;
    const GpuFamilyInfo* metal4 = nullptr;
    for (const auto& f : g.families) {
        if (f.family == "Apple3") apple3 = &f;
        else if (f.family == "Metal3") metal3 = &f;
        else if (f.family == "Metal4") metal4 = &f;
    }
    if (!apple3)
        return Error{ErrorCode::InvalidRegistry, "", "primary target invariant: Apple3 family absent"};
    bool hasA9 = false, hasA10 = false;
    for (const auto& s : apple3->soc) {
        if (s == "A9") hasA9 = true;
        if (s == "A10") hasA10 = true;
    }
    if (!hasA9 || !hasA10)
        return Error{ErrorCode::InvalidRegistry, "", "Apple3 must document A9 and A10 (primary target)"};
    if (metal4 && metal4->minimumOs.find("26") == std::string::npos)
        return Error{ErrorCode::InvalidRegistry, "", "Metal4 family must be pinned to iOS/macOS 26 floor"};
    if (metal3 && metal3->minimumOs.find("16") == std::string::npos)
        return Error{ErrorCode::InvalidRegistry, "", "Metal3 family must be pinned to iOS/macOS 16 floor"};
    return Error{};
}

Error validateFeatureGatesCrossFile(const FeatureRegistry& reg,
                                    const GpuCapabilitiesTable& g) noexcept {
    for (const auto& gate : g.featureGates) {
        const FeatureRecord* rec = reg.find(gate.feature);
        if (!rec)
            return Error{ErrorCode::InvalidRegistry, gate.feature,
                         "featureGates: unknown feature id"};
        if (rec->hardwareGate.find(gate.gateToken) == std::string::npos)
            return Error{ErrorCode::InvalidRegistry, gate.feature,
                         "featureGates: token missing from record's hardwareGate"};
        for (const auto& fam : gate.nativeFamilies) {
            int idx = -1;
            for (const auto& f : g.families) {
                if (f.family == fam) {
                    idx = 0;
                    break;
                }
            }
            if (idx < 0)
                return Error{ErrorCode::InvalidRegistry, gate.feature,
                             "featureGates: native family '" + fam + "' not documented"};
        }
        if (gate.basis.empty())
            return Error{ErrorCode::InvalidRegistry, gate.feature,
                         "featureGates: basis (verification note) required"};
    }
    for (const auto& [k, v] : g.limitsApple3)
        if (!(v > 0) || v != static_cast<double>(static_cast<long long>(v)))
            return Error{ErrorCode::InvalidRegistry, k,
                         "limitsApple3: values must be positive integers"};
    return Error{};
}

} // namespace mc
