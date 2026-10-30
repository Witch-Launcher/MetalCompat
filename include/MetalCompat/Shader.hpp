// MetalCompat — Shader.hpp (M6 shader compatibility subsystem)
//
// Validated shader-variant machinery (SPEC §8). Hard rules honored here:
//   * NO regex/naive text substitution of shader bodies — variant selection is
//     done exclusively by compiler-level preprocessing: `#define` injection in
//     a preamble followed by `#line 1`, so every generated variant is compiled
//     by the real Metal compiler and its diagnostics map 1:1 to the original
//     source lines (§8.2/§8.3).
//   * Variant sources must contain their own `#if`-guarded alternatives; the
//     subsystem only bakes which guard is on.
//   * Composed keys (body hash + canonical defines + MSL language version) so
//     two variants of the same body never collide and every cached artifact
//     has a complete key (§8.2).
//   * Precise rejection: define names/values are validated before emission;
//     nothing reaches the compiler that could change program meaning silently.
// Pure C++ (no Apple headers): unit-testable on any platform.
#pragma once
#include "Compatibility.hpp"
#include "Errors.hpp"

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace mc {

// One `#define NAME VALUE` instruction for a variant. Order is canonicalized
// (sorted by name); duplicates are an error.
struct VariantDefine {
    std::string name;
    std::string value;
};

using VariantCompileFn = std::function<Error(
    const std::string& variantSource,  ///< exact text given to the MSL compiler
    const std::string& variantKeyText, ///< stable key text (for logging only)
    void** outLibrary,                 ///< backend-owned library handle
    std::string& err)>;

struct CompiledVariant {
    std::uint64_t key = 0;      ///< FNV-1a64 over the full canonical key text
    std::string keyText;        ///< "bodyHash=..., defines=..., msl=..."
    void* library = nullptr;    ///< backend handle; valid until releaseVariant
    void* cookie = nullptr;     ///< one cache reference; pass to releaseVariant
};

/// Deterministic FNV-1a 64-bit (stable across builds/platforms; never used for
/// security, only cache keys — collisions still fail safe via keyText compare).
std::uint64_t variantHash(std::string_view s) noexcept;

/// Validates one define. Fails with InvalidArgument on: empty/bad identifier
/// (must match [A-Za-z_][A-Za-z0-9_]*), control characters or a trailing
/// backslash in the value, empty name, or overlong input (defensive bound).
Error validateDefine(const std::string& name, const std::string& value) noexcept;

/// Canonicalizes a define list: rejects duplicates (after trim), sorts by name.
/// `canonical` receives the sorted list; error describes the first problem.
Error canonicalizeDefines(std::vector<VariantDefine>& defines) noexcept;

/// Produces the exact variant source: comment header (key), one `#define` per
/// define, `#line 1` reset, then the untouched body. The body is never edited.
std::string emitVariantSource(std::string_view body,
                              const std::vector<VariantDefine>& defines,
                              std::uint32_t mslLanguageVersion, ///< e.g. 230 (MSL 2.3)
                              std::string& outKeyText) noexcept;

/// Bounded, deterministic LRU cache of compiled variants, keyed on the full
/// canonical key text. A getVariant() result holds ONE cache reference; call
/// releaseVariant(cookie) once the GPU-side consumer (e.g. a pipeline built
/// from the library) no longer needs the MTLLibrary. Only unreferenced
/// variants are evicted, so use-after-free is impossible by construction
/// (SPEC §9.2 lifetime rules).
class ShaderVariantLibrary {
public:
    struct Stats {
        std::size_t hits = 0;
        std::size_t misses = 0;
        std::size_t evictions = 0;
        std::size_t size = 0;
        std::size_t pinned = 0; ///< entries with outstanding references
    };

    /// `destroyFn` frees a backend library handle (e.g. mcops_freeLibrary).
    ShaderVariantLibrary(VariantCompileFn compileFn,
                         void (*destroyFn)(void*) noexcept,
                         std::size_t capacity = 64) noexcept;

    ~ShaderVariantLibrary();
    ShaderVariantLibrary(const ShaderVariantLibrary&) = delete;
    ShaderVariantLibrary& operator=(const ShaderVariantLibrary&) = delete;

    /// Get (or compile) the variant of `body` with `defines` at `mslLanguageVersion`.
    /// The same request always maps to one library; distinct requests never share.
    /// On success `out.cookie` carries one cache reference (release to free).
    Error getVariant(std::string_view body, const std::vector<VariantDefine>& defines,
                     std::uint32_t mslLanguageVersion, CompiledVariant& out) noexcept;

    /// Releases the reference taken by getVariant. Each cookie is released
    /// exactly once; the cookie is only valid while the library object lives.
    void releaseVariant(void* cookie) noexcept;

    Stats stats() const noexcept;

private:
    struct Entry;
    Entry* findLocked_(const std::string& keyText) noexcept; // moves to MRU
    void evictIfNeededLocked_() noexcept;

    VariantCompileFn compileFn_;
    void (*destroyFn_)(void*) noexcept;
    std::size_t capacity_;
    mutable void* lock_ = nullptr; // opaque std::mutex*
    std::vector<Entry*> order_;    // MRU first
    std::vector<std::pair<std::string, Entry*>> map_;
    Stats st_{};
};

constexpr std::uint32_t kMslLanguage_2_2 = 220; ///< iOS 13 / macOS 10.15 era
constexpr std::uint32_t kMslLanguage_2_3 = 230; ///< iOS 14 / macOS 11 (SPEC baseline ceiling)

// Preferred MSL language version for a deployment platform (iOS 14 baseline):
// 2.3 everywhere the baseline covers; callers on older runtimes must pass 220.
inline std::uint32_t baselineMslLanguage() noexcept { return kMslLanguage_2_3; }

} // namespace mc
