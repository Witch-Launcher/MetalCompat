# MetalCompat — RESEARCH

> Version 0.2.0 · last verified **2026-10-30** (UTC) unless noted per entry.
> Verification SDK: **Xcode 26.3 Build 17C529, iOS SDK 26.2** (`iPhoneOS26.2.sdk`),
> Apple clang 17.0.0, Metal toolchain `32023.864 (metalfe-32023.864)`.
> Host used for research: macOS 15.7.7 (24G720), Intel iMac20,1 — **no Apple GPU, no A9 device**.

Research policy: `SPEC.md` §10. Every non-UNKNOWN claim below must carry a source
that is either the installed SDK headers or an official Apple documentation page.
Symbols were checked in the actual SDK headers of this machine, not from memory.

## 1. Environment baseline

| Item | Value |
|---|---|
| Xcode | 26.3 (Build 17C529) |
| iOS SDK | 26.2 (`xcrun --sdk iphoneos --show-sdk-version`) |
| macOS SDK | 26.2 |
| Host OS | macOS 15.7.7 (24G720), x86_64 |
| Host GPU | Intel UHD Graphics 630, system reports “Metal Support: Metal 3” |
| CMake / Ninja | 4.4.3 / present at `/usr/local/bin` |
| Available test Metal devices | Intel UHD 630 (host). No Apple GPU, no physical A9 → all Apple-family claims below are SDK/doc-derived, **runtime validation pending** |

## 2. GPU family model (verified)

`MTLGPUFamily` (SDK 26.2 header `MTLDevice.h`; enum present since iOS 13/macOS 10.15 era):

| Raw value | Ident | Meaning (verified vs Apple docs) |
|---|---|---|
| 1001 | `MTLGPUFamilyApple1` | A7 (docs) |
| 1002 | `MTLGPUFamilyApple2` | A8 (docs) |
| 1003 | `MTLGPUFamilyApple3` | **Apple A9 and A10 (docs — primary target family)** |
| 1004 | `MTLGPUFamilyApple4` | A11 (docs) |
| 1005 | `MTLGPUFamilyApple5` | A12 (docs) |
| 1006 | `MTLGPUFamilyApple6` | A13 (docs) |
| 1007 | `MTLGPUFamilyApple7` | A14 / M1 (docs) |
| 1008 | `MTLGPUFamilyApple8` | A15 / A16 / M2 (docs) |
| 1009 | `MTLGPUFamilyApple9` | A17 / M3 / M4 (docs) |
| 1010 | `MTLGPUFamilyApple10` | (docs lists `apple10`, and an `apple11` case in current docs; SDK 26.2 header has up to Apple10) |
| 2002 | `MTLGPUFamilyMac2` | Intel Macs (docs) |
| 3001–3003 | Common1..3 | Common families (docs) |
| 5001 | `MTLGPUFamilyMetal3` | `API_AVAILABLE(macos(13.0), ios(16.0))` (header) |
| 5002 | `MTLGPUFamilyMetal4` | `API_AVAILABLE(macos(26.0), ios(26.0))` (header) |

Device↔family source: Apple docs `MTLGPUFamily` page
(https://developer.apple.com/documentation/metal/mtlgpufamily) — fetched 2026-10-30.
Deprecated legacy query `supportsFeatureSet:` + `MTLFeatureSet_iOS_GPUFamily*`
still exists in SDK 26.2 headers (`API_DEPRECATED` since iOS 16).

Selector: `-supportsFamily:` has availability **iOS 13.0+ / macOS 10.15+**
(header `MTLDevice.h`; Apple docs page fetched 2026-10-30) → **usable on the
iOS 14 deployment baseline.** A9-class: `supportsFamily(MTLGPUFamilyApple3)`.

## 3. Metal 4 (`MTL4*`) availability rule (verified)

SDK 26.2 contains a full `MTL4*` header set (`MTL4CommandQueue.h`,
`MTL4CommandAllocator.h`, `MTL4CommandBuffer.h`, `MTL4Compiler.h`,
`MTL4ArgumentTable.h`, `MTL4RenderCommandEncoder.h`, `MTL4RenderPipeline.h`,
`MTL4MeshRenderPipeline.h`, `MTL4MachineLearningCommandEncoder.h`, …).

**Every checked `MTL4*` API carries `API_AVAILABLE(macos(26.0), ios(26.0))`.**
Therefore:

- Metal 4 native support requires **iOS 26+** (or macOS 26+).
- The iOS 14 baseline cannot compile-time include MTL4 usage without version
  guards; MetalCompat must gate all MTL4 code with `if (@available(ios 26.0, *))
  ` *and* `MTLGPUFamilyMetal4` runtime checks.
- **A9 is not a native Metal 4 device.** (Family Apple3 < Metal4 5002; iOS 14 < 26.)
  This confirms SPEC D-008 and §7.3.

## 4. Key API availability facts (SDK 26.2 headers, checked 2026-10-30)

| API / concept | Header | OS availability | Hardware note |
|---|---|---|---|
| `Metal.framework` | Metal.h | iOS 8.0+ (supportsFeatureSet era) | — |
| `-supportsFamily:` | MTLDevice.h | iOS 13.0+ / macOS 10.15+ | family-specific at runtime |
| `MTLGPUFamily` enum | MTLDevice.h | iOS 13.0+ era | includes Apple1..Apple10 in SDK 26.2 |
| `newBufferWithLength:options:` | MTLDevice.h | iOS 8.0-era | — |
| `-newHeapWithDescriptor:` | MTLDevice.h | iOS 10.0+ / macOS 10.13+ | hardware: Apple3+ family feature (runtime-verify) |
| `-newFence` (MTLFence) | MTLDevice.h | iOS 10.0+ / macOS 10.13+ | — |
| `MTLEvent` | MTLEvent.h | iOS 12.0+ / macOS 10.14+ (header `API_AVAILABLE(macos(10.14), ios(12.0))`) | — |
| `-newIndirectCommandBuffer...` | MTLDevice.h | iOS 12.0+ / macOS 10.14+ | runtime-verify per device |
| `-newAccelerationStructureWithDescriptor:` | MTLDevice.h | **iOS 14.0+** / macOS 11.0+ | ray tracing requires Apple7 (A13-family class, docs/runtime; A9 UNVERIFIED → to verify vs runtime `supportsRaytracing`) |
| `argumentBuffersSupport` (`MTLArgumentBuffersTier`) | MTLDevice.h | iOS 11.0+ / macOS 10.13+ | tier per family (runtime query) |
| `maxThreadgroupMemoryLength` | MTLDevice.h | iOS 11.0+ | per-device value |
| `maxBufferLength` | MTLDevice.h | iOS 12.0+ | per-device value |
| `MTLResidencySet` | MTLResidencySet.h | **iOS 18.0+** | not on iOS 14 baseline |
| Tessellation factor APIs (`setTessellationFactorBuffer`, `MTLTessellationFactorFormat`) | MTLRenderCommandEncoder.h / MTLRenderPipeline.h | iOS 10.0+ | hardware family requirement: **UNKNOWN** in headers → verify `supportsTextureSampleCount`-style query (registry task M2) |
| Mesh shading (legacy `mesh` stage) | (SDK 26.2: `MTL4MeshRenderPipeline.h` only; legacy mesh headers absent) | iOS 26 path only for MTL4 pipelines | legacy mesh availability on iOS 14 A9: **UNKNOWN** — research task M7 |
| `MTLFXSpatialScaler` / `MTLFXTemporalScaler` (MetalFX.framework) | MTLFX*.h | **iOS 16.0+** / macOS 13+ | not on iOS 14 baseline |
| `MTL4FX*`, `MTLFXFrameInterpolator` | MetalFX headers | **iOS 26.0+** | Metal 4 era |
| MetalPerformancePrimitives.framework | present in SDK 26.2 | iOS 26-era ML primitives | separate framework; out of scope until inventory says otherwise |

Notes:
1. “OS availability” above is the compile/runtime availability macro; “hardware
   note” is only recorded when evidence exists in headers or Apple docs.
   Anything marked “runtime-verify” must be resolved by the Capability Engine
   (M2) using documented `MTLDevice` queries on the actual device — we do not
   infer support from generation names.
2. `getGPUFamily` (the older integer family property) no longer appears in the
   SDK 26.2 `MTLDevice.h`; the supported path on iOS 14 is `supportsFamily:`.

## 5. Metal Shading Language / toolchain (verified)

- Metal shader compiler present offline: `xcrun metal --version` →
  `Apple metal version 32023.864 (metalfe-32023.864)`, target `air64-apple-darwin24.6.0`.
- Runtime library compilation via `[MTLDevice newLibraryWithSource:]` is public
  API usable at runtime on iOS/macOS (header MTLDevice.h, long-standing API;
  exact availability line verified in headers during M2). Offline `.metallib`
  generation via `xcrun metal`/`xcrun metallib` is available in this toolchain.
- MSL version per target OS/GPU: to be finalized in M2 with the actual
  `MTLLanguageVersion` enum values from the current SDK (registry item,
  verification task). Do not claim an MSL version on A9/iOS 14 without checking
  the SDK enum + Apple “MTLLanguageVersion” documentation.

## 6. Framework inventory (SDK 26.2, actual presence checked)

- `Metal.framework` — primary target.
- `MetalKit.framework` — available; optional integration (views/models), not needed for core slice.
- `MetalFX.framework` — iOS 16+/26 components; **not in the iOS 14 baseline**.
- `MetalPerformanceShaders.framework`, `MetalPerformanceShadersGraph.framework` — present in SDK; tracked separately in the registry as related-but-distinct frameworks (SPEC §7.4).
- `MetalPerformancePrimitives.framework` — new in this SDK generation (ML primitives), iOS 26-era; out of scope for now.

## 7. Open research items (marked UNKNOWN by policy)

| ID | Question | Plan |
|---|---|---|
| R-1 | Exact hardware gate for tessellation on Apple3 (A9) — does A9 support it? | M2 runtime probe (`supportsFamily` + documented pipeline checks) on real hardware |
| R-2 | Legacy mesh-shading equivalent on iOS 14 A9 | M7 isolated prototype + docs |
| R-3 | Argument-buffer tier returned by A9 (Tier 1 expected) | M2 runtime query |
| R-4 | Deterministic MSL/azal version bundle on A9+iOS 14 vs newer OS | M2 on-device report |
| R-5 | Whether `MTLCaptureManager` becomes available under test environments on device | M3 diagnostics task |
| R-6 | Apple docs pages requiring JS were fetched via `.md` variants where possible; a handful of tables (feature requirement table) still need an official citation | track in API_INVENTORY “last-verified” column |

## 8. Sources

- Installed SDK headers: `/Volumes/D/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.2.sdk/System/Library/Frameworks/Metal.framework/Headers/` (checked per-symbol, 2026-10-30).
- Apple docs `MTLGPUFamily` page (fetched 2026-10-30).
- Apple docs `supportsFamily(_:)` page (fetched 2026-10-30).
- Apple Metal Resources / Metal 4 doc links in SPEC §10 (catalogued in API_INVENTORY.md).
- `system_profiler`, `sw_vers`, `xcodebuild -version`, `xcrun --show-sdk-version` outputs on this host (2026-10-30).
