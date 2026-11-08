// MetalCompat — Capabilities.hpp
// Multidimensional capability snapshot (SPEC D-005). Core is Apple-header-free;
// the snapshot is filled by the platform bridge (Objective-C++ side).
#pragma once
#include <array>
#include <cstdint>
#include <string>

namespace mc {

// Mirrors public MTLGPUFamily raw values (verified vs SDK 26.2 headers /
// Apple docs, see registry). Do not invent entries.
namespace family {
inline constexpr std::int32_t Apple1 = 1001, Apple2 = 1002, Apple3 = 1003, Apple4 = 1004,
    Apple5 = 1005, Apple6 = 1006, Apple7 = 1007, Apple8 = 1008, Apple9 = 1009,
    Apple10 = 1010;
inline constexpr std::int32_t Mac2 = 2002;
inline constexpr std::int32_t Common1 = 3001, Common2 = 3002, Common3 = 3003;
inline constexpr std::int32_t Metal3 = 5001; // iOS 16 / macOS 13
inline constexpr std::int32_t Metal4 = 5002; // iOS 26 / macOS 26 (SPEC D-008)
} // namespace family

// Kinds of platform the snapshot was taken on.
enum class PlatformKind { Unknown, Ios, Macos };

struct DeviceCaps {
    std::string deviceName;          // [MTLDevice name]
    PlatformKind platform = PlatformKind::Unknown;
    std::string osVersion;           // e.g. "iOS 14.0" / "macOS 26.2"
    std::string metalToolchainVersion;
    bool appleGpu = false;           // any Apple1..Apple10 family
    bool supportsMetal4 = false;     // family Metal4 (OS-checked + family-checked)

    // SupportsFamily results, indexed order: only families we care about.
    // order: Apple1..Apple10, Mac2, Common1..3, Metal3, Metal4
    std::array<std::uint8_t, 16> familySupport{}; // 0/1

    // Runtime-queried limits (values live only in the snapshot).
    std::uint64_t maxBufferLength = 0;
    std::uint64_t maxThreadgroupMemoryLength = 0;
    std::uint64_t recommendedMaxWorkingSetSize = 0;
    std::array<std::uint32_t, 3> maxThreadsPerThreadgroup{0, 0, 0};
    // MTLArgumentBuffersTier: 0 none, 1 tier1, 2 tier2
    std::uint8_t argumentBuffersTier = 0;
    // MTLReadWriteTextureTier: 0 none, 1 tier1, 2 tier2
    std::uint8_t readWriteTextureTier = 0;
    // Ray tracing: 1 when -[MTLDevice supportsRaytracing] == YES (iOS 14+ selector),
    // 0 otherwise. Honest per-device probe — Apple4/A11 reports 0 (no RT at all).
    std::uint8_t supportsRaytracing = 0;
    // Highest Metal era this device can natively speak through the legacy backend.
    // 1 = Metal 1 (Apple1/MSL1.x), 2 = Metal 2 (Apple2/MSL2.0-2.1),
    // 3 = Metal 3 (Apple3+/MSL2.2+), 4 = Metal 4 (MTLGPUFamilyMetal4, iOS 26).
    std::uint8_t metalVersion = 3;
};

bool supportsFamily(const DeviceCaps& c, std::int32_t familyRawValue) noexcept;
bool isApple3OrBetterWithOS14Baseline(const DeviceCaps& c) noexcept; // primary-target helper
const char* familyName(std::int32_t familyRawValue) noexcept;

} // namespace mc
