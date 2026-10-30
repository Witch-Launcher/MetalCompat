// Shader variant subsystem core implementation (M6). See Shader.hpp contract.
#include "MetalCompat/Shader.hpp"

#include <algorithm>
#include <list>
#include <mutex>
#include <unordered_map>

namespace mc {

std::uint64_t variantHash(std::string_view s) noexcept {
    std::uint64_t h = 1469598103934665603ull; // FNV-1a64 basis
    for (const char c : s) {
        h ^= static_cast<unsigned char>(c);
        h *= 1099511628211ull; // FNV-1a64 prime
    }
    return h;
}

namespace {

bool validDefineName(const std::string& n) {
    if (n.empty()) return false;
    const auto idc = [](char c) {
        return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' || (c >= '0' && c <= '9');
    };
    if (!((n[0] >= 'A' && n[0] <= 'Z') || (n[0] >= 'a' && n[0] <= 'z') || n[0] == '_')) return false;
    for (const char c : n)
        if (!idc(c)) return false;
    return true;
}

constexpr std::size_t kMaxDefineNameLen = 128;
constexpr std::size_t kMaxDefineValueLen = 256;

} // namespace

Error validateDefine(const std::string& name, const std::string& value) noexcept {
    if (name.size() > kMaxDefineNameLen || value.size() > kMaxDefineValueLen)
        return Error{ErrorCode::InvalidArgument, "", "define name/value over bound"};
    if (!validDefineName(name))
        return Error{ErrorCode::InvalidArgument, "", "define name must match [A-Za-z_][A-Za-z0-9_]*"};
    for (const char c : value) {
        if (static_cast<unsigned char>(c) < 0x20 && c != '\t')
            return Error{ErrorCode::InvalidArgument, "", "define value contains control characters"};
        if (c == '\\')
            return Error{ErrorCode::InvalidArgument, "", "define value may not continue lines"};
    }
    return Error{};
}

Error canonicalizeDefines(std::vector<VariantDefine>& defines) noexcept {
    for (std::size_t i = 0; i < defines.size(); ++i) {
        Error e = validateDefine(defines[i].name, defines[i].value);
        if (e) return e;
    }
    std::sort(defines.begin(), defines.end(),
              [](const VariantDefine& a, const VariantDefine& b) { return a.name < b.name; });
    for (std::size_t i = 1; i < defines.size(); ++i)
        if (defines[i].name == defines[i - 1].name)
            return Error{ErrorCode::InvalidArgument, defines[i].name, "duplicate define"};
    return Error{};
}

std::string emitVariantSource(std::string_view body, const std::vector<VariantDefine>& defines,
                              std::uint32_t mslLanguageVersion, std::string& outKeyText) noexcept {
    // canonical key text: exactly what identifies this variant
    outKeyText.clear();
    outKeyText.reserve(body.size() / 4 + 64 + defines.size() * 24);
    outKeyText += "mcvariant-v1;hash=" + std::to_string(variantHash(body));
    outKeyText += ";msl=" + std::to_string(mslLanguageVersion);
    for (const auto& d : defines) {
        outKeyText += ";d=";
        outKeyText += d.name;
        if (!d.value.empty()) {
            outKeyText += '=';
            outKeyText += d.value;
        }
    }

    std::string src;
    src.reserve(body.size() + 128 + defines.size() * 24);
    src += "// MetalCompat variant [";
    src += outKeyText;
    src += "]\n";
    for (const auto& d : defines) {
        src += "#define ";
        src += d.name;
        if (!d.value.empty()) {
            src += ' ';
            src += d.value;
        }
        src += '\n';
    }
    // Reset line numbering so compiler diagnostics address the ORIGINAL body
    // lines (1:1) even though the preamble occupies earlier lines.
    src += "#line 1\n";
    src += body;
    if (!src.empty() && src.back() != '\n') src += '\n';
    return src;
}

// ---------------------------------------------------------------------------
// ShaderVariantLibrary
// ---------------------------------------------------------------------------
struct ShaderVariantLibrary::Entry {
    std::string keyText;
    void* library = nullptr;
    std::size_t refs = 0; // outstanding getVariant() references
    ~Entry() noexcept {
        if (library) destroyFn(library);
    }
    void (*destroyFn)(void*) noexcept = nullptr;
};

ShaderVariantLibrary::ShaderVariantLibrary(VariantCompileFn compileFn,
                                           void (*destroyFn)(void*) noexcept,
                                           std::size_t capacity) noexcept
    : compileFn_(std::move(compileFn)), destroyFn_(destroyFn), capacity_(capacity ? capacity : 1) {
    lock_ = new std::mutex();
}

ShaderVariantLibrary::~ShaderVariantLibrary() {
    // Entries release their libraries via destroyFn in ~Entry.
    {
        std::lock_guard<std::mutex> g(*static_cast<std::mutex*>(lock_));
        for (auto& kv : map_) {
            delete kv.second;
            kv.second = nullptr;
        }
        map_.clear();
        order_.clear();
    }
    delete static_cast<std::mutex*>(lock_);
    lock_ = nullptr;
}

ShaderVariantLibrary::Entry* ShaderVariantLibrary::findLocked_(const std::string& keyText) noexcept {
    for (auto& kv : map_)
        if (kv.first == keyText) {
            // move entry to front (MRU)
            for (auto it = order_.begin(); it != order_.end(); ++it)
                if (*it == kv.second) {
                    order_.erase(it);
                    break;
                }
            order_.insert(order_.begin(), kv.second);
            return kv.second;
        }
    return nullptr;
}

void ShaderVariantLibrary::evictIfNeededLocked_() noexcept {
    // Evict LRU entries that hold no outstanding reference. Pinned entries are
    // never destroyed while referenced, so returned pointers stay valid.
    while (order_.size() > capacity_) {
        Entry* victim = nullptr;
        for (auto it = order_.rbegin(); it != order_.rend(); ++it)
            if ((*it)->refs == 0) {
                victim = *it;
                order_.erase(std::next(it).base());
                break;
            }
        if (!victim) return; // all pinned: unbounded until release; growth documented
        for (auto it = map_.begin(); it != map_.end(); ++it)
            if (it->second == victim) {
                map_.erase(it);
                break;
            }
        delete victim;
        ++st_.evictions;
    }
}

Error ShaderVariantLibrary::getVariant(std::string_view body,
                                       const std::vector<VariantDefine>& defines,
                                       std::uint32_t mslLanguageVersion,
                                       CompiledVariant& out) noexcept {
    out = CompiledVariant{};
    if (!compileFn_ || !lock_) return Error{ErrorCode::InvalidArgument, "", "library not initialized"};

    std::lock_guard<std::mutex> g(*static_cast<std::mutex*>(lock_));

    std::string keyText;
    const std::string src = emitVariantSource(body, defines, mslLanguageVersion, keyText);

    if (Entry* hit = findLocked_(keyText); hit) {
        ++st_.hits;
        ++hit->refs;
        out.key = variantHash(keyText);
        out.keyText = keyText;
        out.library = hit->library;
        out.cookie = hit;
        return Error{};
    }
    ++st_.misses;

    void* lib = nullptr;
    std::string err;
    Error e = compileFn_(src, keyText, &lib, err);
    if (e) return e;
    if (!lib) return Error{ErrorCode::BridgeFailure, "", "compiler returned no library"};

    Entry* ent = new Entry();
    ent->keyText = keyText;
    ent->library = lib;
    ent->refs = 1;
    ent->destroyFn = destroyFn_;
    map_.emplace_back(keyText, ent);
    order_.insert(order_.begin(), ent);
    evictIfNeededLocked_();
    out.key = variantHash(keyText);
    out.keyText = keyText;
    out.library = lib;
    out.cookie = ent;
    st_.size = order_.size();
    return Error{};
}

void ShaderVariantLibrary::releaseVariant(void* cookie) noexcept {
    if (!cookie || !lock_) return;
    std::lock_guard<std::mutex> g(*static_cast<std::mutex*>(lock_));
    for (auto& kv : map_) {
        if (kv.second == cookie) {
            Entry* ent = kv.second;
            if (ent->refs > 0) {
                --ent->refs;
                evictIfNeededLocked_();
            }
            return;
        }
    }
}

ShaderVariantLibrary::Stats ShaderVariantLibrary::stats() const noexcept {
    std::lock_guard<std::mutex> g(*static_cast<std::mutex*>(lock_));
    Stats s = st_;
    std::size_t pinned = 0;
    for (const Entry* e : order_)
        if (e->refs) ++pinned;
    s.pinned = pinned;
    s.size = order_.size();
    return s;
}

} // namespace mc
