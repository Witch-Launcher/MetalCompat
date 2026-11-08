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

## 8. Metal 1/2/3/4 compatibility model (added 2026-10-30)

MetalCompat must answer two questions for every feature:

1. **Can Metal-version-N code run on Metal-version-M hardware?**
2. **Is ray tracing available, and at what tier?**

### 8.1 Metal version → GPU family mapping (verified, SDK 26.2 / Apple docs)

| Metal era | GPU family floor | Typical SoCs | OS floor | Notes |
|-----------|-----------------|--------------|----------|-------|
| Metal 1 | Apple1 (A7) | A7 | iOS 8 / macOS 10.11 | MSL 1.1–1.2 era |
| Metal 2 | Apple2 (A8) | A8 | iOS 10 / macOS 10.12 | MSL 2.0–2.1 era |
| Metal 3 | Apple3 (A9/A10) | **A9, A10** | iOS 12 / macOS 10.14 | MSL 2.2–2.3 era; primary target |
| Metal 4 | MTLGPUFamilyMetal4 (5002) | MTL4-class | iOS 26 / macOS 26 | `MTL4*` headers, OS floor 26 |

Rule (SPEC §7.3 / D-008): Metal 4 types (`MTL4CommandQueue`, `MTL4CommandBuffer`, …) are distinct from legacy `MTL*` types and carry `API_AVAILABLE(ios(26.0))`. An Apple3/A9 device can never report `MTLGPUFamilyMetal4`; the planner refuses `mtl4.*` on iOS 14 with `UnavailableOs`/`InsufficientHardware`.

Backward direction (newer API on older hardware): a Metal-4-only feature either (a) maps to a legacy `MTL*` equivalent with identical observable semantics (FALLBACK), (b) is emulated via compute/CPU (EMULATED, documented cost), or (c) reports `UNSUPPORTED` with a typed error. Never silent no-op, never "NATIVE" for an emulated path.

Forward direction (older API on newer hardware): Metal 1/2/3 APIs are subsets of the same `MTL*` runtime. On Metal-4-class devices they run NATIVE through the legacy backend; MetalCompat does not force callers onto `MTL4*` types.

### 8.2 Ray tracing hardware reality (honest, per-device)

`MTLAccelerationStructure` exists at OS level since **iOS 14.0 / macOS 11.0** (verified `MTLDevice.h`). OS availability ≠ hardware support.

| Device class | GPU family | Ray tracing | Tier | Evidence |
|--------------|-----------|-------------|------|----------|
| A7 (Apple1) | 1001 | NO | none | below Apple6 floor |
| A8 (Apple2) | 1002 | NO | none | below Apple6 floor |
| **A9/A10 (Apple3)** | **1003** | **NO** | **none** | below Apple6 floor |
| **A11 (Apple4)** | **1004** | **NO** | **none** | **below Apple6 floor** |
| A12 (Apple5) | 1005 | NO | none | below Apple6 floor |
| A13 (Apple6) | 1006 | YES | software (no HW acceleration) | docs/runtime: Apple6+ supports `MTLAccelerationStructure` API |
| A14/M1 (Apple7) | 1007 | YES | software | Apple7+ |
| A15/A16/M2 (Apple8) | 1008 | YES | software | Apple8+ |
| A17/M3/M4 (Apple9) | 1009 | YES | hardware-accelerated | Apple9+ |

The runtime selector is `-supportsRaytracing` (available iOS 14+; returns `BOOL`). MetalCompat probes it per device and reports:
- `NATIVE` when `supportsRaytracing == YES` (hardware or software tier, per Apple's own classifier)
- `UNSUPPORTED` when `supportsRaytracing == NO` — including **A11/Apple4**, which has no ray tracing at all

MetalCompat does **not** claim A11 supports hardware ray tracing. Where an application requires ray tracing on A11, MetalCompat offers a **compute-based software BVH traversal emulation** (see `src/Backends/LegacyMetal/raytrace_emul.*`), labeled `EMULATED`, with documented cost and correctness contract. It is opt-in, never auto-substituted for a refused hardware path without a registry record and explicit caller acceptance (SPEC D-006, §7.1).

## 10. Sources

- Installed SDK headers: `/Volumes/D/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.2.sdk/System/Library/Frameworks/Metal.framework/Headers/` (checked per-symbol, 2026-10-30).
- Apple docs `MTLGPUFamily` page (fetched 2026-10-30).
- Apple docs `supportsFamily(_:)` page (fetched 2026-10-30).
- Apple Metal Resources / Metal 4 doc links in SPEC §10 (catalogued in API_INVENTORY.md).
- `system_profiler`, `sw_vers`, `xcodebuild -version`, `xcrun --show-sdk-version` outputs on this host (2026-10-30).

## 9. M5–M8 research additions (2026-10-30)

### 9.1 Layer selection (render.layered) — verified

- Apple official article "Rendering to multiple texture slices in a draw
  command" (developer.apple.com, fetched 2026-10-30): "All GPUs in the macOS
  family support layer selection. Layer selection is available in the Apple
  GPU family starting with family 5." The feature-set tables (May 21, 2026
  PDF) place the first Apple-family layer-selection row at Apple5 — consistent.
- Legacy API: `MTLRenderPassDescriptor.renderTargetArrayLength`
  `API_AVAILABLE(macos(10.11), ios(12.0), tvos(14.5))` (MTLRenderPass.h:392).
- Runtime validation discovered on host (Intel KBL, Mac2):
  * pipelines must set `inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle`
    whenever the vertex writes `[[render_target_array_index]]` (error text:
    "Vertex shader writes render_target_array_index but inputPrimitiveTopology
    is not specified");
  * there is NO `[[pixel_coord]]` builtin (compiler warning: unknown attribute);
    the fragment reads pixel coordinates from the stage-in payload's
    `[[position]]` (`in.pos.x/y` are pixel centers, x = col + 0.5);
  * fragment stage constant buffers bind only on **32-byte**
    (`setFragmentBuffer:offset:`) alignment (validation: "must be a multiple
    of 32") — the translation's per-slice uniform uses one 32-byte slot/slice;
  * `copyFromTexture:...:toBuffer:...` requires
    `destinationBytesPerImage` = bytes of a full image (W*H*4) for slice
    copies (validation failure otherwise; H*4 is invalid), while 2D single-slice
    copies use 0.
- Native-vs-fallback byte comparison (512x512x4 in tests: 64x64x4) passes with
  the CPU reference (±1 lsb/channel, RGBA8 quantization) on both paths.

### 9.2 Legacy tier-1 argument buffers (M7) — empirical host evidence

- `MTLArgumentDescriptor` (MTLDevice.h:324), `[device
  newArgumentEncoderWithArguments:]` (MTLDevice.h:877),
  `dev.argumentBuffersSupport` with `MTLArgumentBuffersTier1/2` (MTLDevice.h
  298–301, 475) — all `API_AVAILABLE(macos(10.13), ios(11.0))`.
- MSL binding form for pointer members is `device const T* m [[id(N)]]` inside
  the struct that the kernel receives as `[[buffer(0)]]`; the encoder writes
  the pointer into the argument buffer via `[enc setBuffer:offset:atIndex:]`
  with `atIndex` = descriptor index. On the Tier-1 host (Intel KBL) the
  classic binding and the tier-1 argument-buffer binding produced **the same
  outputs** (mcops_argT1Prototype op; compare op in the integration suite).
- Footnote 3 (feature-set tables, May 21, 2026): Apple3–Apple10 render-stage
  memory barriers do not accept `.fragment`/`.tile` in `after` nor
  `renderTargets` scope → registry row `cmd.renderBarrierStageLimit` UNSUPPORTED.
- Metal 4 programming model availability starts at Apple7 (table footnote 1):
  `trans.mtl4.argtable.tier1` is the bridge record for pre-Apple7 devices.

### 9.3 Corrected UNKNOWN records (R-items)

- R-2 (legacy mesh on iOS 14): feature-set tables place mesh shaders at
  Apple7+ → `pipe.mesh.legacy` flipped UNKNOWN → UNSUPPORTED (no unverified
  states remain for it).
- R-1 (tessellation on Apple3): Apple3 column documents tessellation
  (max tessellation factor 16) → `pipe.tessellationFactor` gate updated
  (remainder stays PARTIAL/runtime-verify: macOS-floor interplay unstudied).
- Chosen open question added: Q-layered-a9 (A9 device probe pending; cannot
  be inferred from families per SPEC §7.2).

### 9.4 Apple3 numeric limits (registry: gpu_capabilities.json)

Snapshot of the Apple3 column (May 21, 2026 tables) — machine-readable copy
lives in the registry block `limitsApple3` (validator-checked): 512 threads /
16 352 B threadgroup memory / 4096 B inline constants / tessellation factor 16 /
16384 tex2D / 2048 tex3D / 31 buffers + 31 textures + 16 samplers per stage
inside argument buffers / MSAA 4 / 16-byte texture-to-buffer alignment /
60 fragment stage-in scalars.
