# MetalCompat — GPU Capability Matrix (M0 draft)

> Device↔capabilities matrix, v0.2.0. Machine-readable: `registry/gpu_capabilities.json`.
> Verified against iOS SDK 26.2 headers + Apple docs 2026-10-30 (RESEARCH §8).
> **No Apple-family device has been probed at runtime yet** — Apple columns contain
> availability-derived facts and explicit `UNKNOWN` marks, never unverified inference.

## 1. Device ↔ GPU family mapping (official Apple docs, 2026-10-30)

| GPU family | SoCs | OS floor used by MetalCompat baseline |
|---|---|---|
| Apple1 | A7 | n/a |
| Apple2 | A8 | n/a |
| **Apple3** | **A9, A10** | **iOS 14 (primary target)** |
| Apple4 | A11 | iOS 14 |
| Apple5 | A12 | iOS 14 |
| Apple6 | A13 | iOS 14 |
| Apple7 | A14 / M1 | iOS 14 |
| Apple8 | A15 / A16 / M2 | iOS 14–17 |
| Apple9 | A17 / M3 / M4 | iOS 17+ |
| Apple10 / Apple11 | newer generations | iOS 26-era tools |
| Mac2 | Intel Macs | macOS |
| Metal3 (5001) | Apple7+ class devices | iOS 16+ / macOS 13+ |
| Metal4 (5002) | MTL4-class devices | iOS 26+ / macOS 26+ |

Source: Apple `MTLGPUFamily` documentation page (RESEARCH §8).

## 2. Feature availability by OS (verified availability macros, SDK 26.2)

| Feature | iOS 10 | iOS 12 | iOS 14 (baseline) | iOS 16 | iOS 18 | iOS 26 |
|---|---|---|---|---|---|---|
| Core buffers/textures/pipelines/encoders | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| Heaps (`MTLHeap`) | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| Fences | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| Events | — | ✔ | ✔ | ✔ | ✔ | ✔ |
| Indirect command buffers | — | ✔ | ✔ | ✔ | ✔ | ✔ |
| `supportsFamily:` | — | — | ✔ | ✔ | ✔ | ✔ |
| Acceleration structure API (`MTLAccelerationStructure`) | — | — | ✔ | ✔ | ✔ | ✔ |
| Argument buffer tier query | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| MetalFX (MTLFX*) | — | — | — | ✔ | ✔ | ✔ |
| Residency sets | — | — | — | — | ✔ | ✔ |
| Metal 3 (`MTLGPUFamilyMetal3`) | — | — | — | ✔ (family 5001) | ✔ | ✔ |
| Metal 4 (`MTL4*`, family 5002) | — | — | — | — | — | ✔ |

## 3. Hardware-gated features — Apple-family expectations

These are **hypotheses marked UNKNOWN until probed**, except where Apple
documentation states the map (family↔docs mapping above). The Capability Engine
(M2) must resolve each by runtime query on real hardware:

| Feature | Apple3 (A9/A10) | Apple4 (A11) | Apple5 (A12) | Apple6 (A13) | Apple7 (A14/M1) | Evidence basis |
|---|---|---|---|---|---|---|
| Imageblocks / tile shaders | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | YES (docs-adjacent; to probe) | docs M7 task |
| Mesh shading | UNKNOWN (R-2) | UNKNOWN | UNKNOWN | UNKNOWN | YES (docs-adjacent) | legacy path research |
| Ray tracing (`MTLAccelerationStructure`) | UNKNOWN→expected NO (R-1 probes) | UNKNOWN→expected NO | UNKNOWN→expected NO | YES-expected (A13 family docs association) | YES-expected | OS API available iOS 14; hardware support must be probed |
| Tessellation | UNKNOWN (R-1) | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | registry R-1 |
| Read-write texture tier 2 | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | runtime query |
| Argument buffers Tier 2 | UNKNOWN (expect Tier 1) | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | R-3 |
| `MTLCommandBuffer_TYPE_RAY_TRACING` encoders | NO-expected | NO-expected | NO-expected | YES-expected | YES-expected | docs/runtime |

Rule (SPEC D-005/D-006): a cell stays `UNKNOWN` until the real device query has
run. No inference from generation names replaces the probe.

## 4. Per-device limits (runtime queries, not doc-derived)

The registry stores limit *slots* to fill per device at runtime during M2/M3:

- `maxBufferLength`
- `maxThreadgroupMemoryLength` (and `maxTotalThreadgroupMemoryLength`)
- `maxThreadsPerThreadgroup` (x/y/z)
- `recommendedMaxWorkingSetSize`
- `currentAllocatedSize` ceilings per heap
- texture stack depth, per-color attachments (maxColorRenderTargets by OS)
- `MTLReadWriteTextureTier`, `MTLArgumentBuffersTier`
- `maximumSamplerCount`, `maxTessellationFactorAmplification`

These queries are all iOS ≤14 era public `MTLDevice` properties (verified
availability in RESEARCH §4); values differ per device and are recorded at
runtime in the capability report — **never hard-coded per SoC**.

## 5. Host development environment capability (measured 2026-10-30)

| Item | Value |
|---|---|
| Host device | Intel UHD Graphics 630 (iMac20,1), system-reported “Metal 3” support |
| Family expectation | `MTLGPUFamilyMac2` (runtime probe in M2 will confirm) |
| Value for the project | Can compile/run all CPU-only tests + render vertical slice (non-Apple GPU); can NOT validate any Apple-family-specific behavior |

## 6. A9 validation status

| Claim | Status |
|---|---|
| A9 reports `supportsFamily(MTLGPUFamilyApple3)` | **PENDING** (docs-supported, runtime proof required on hardware) |
| A9 cannot report `MTLGPUFamilyMetal4` | PENDING (OS/family gates make it logically impossible, but device test still required before PHYSICAL-VALIDATED status) |
| Deterministic frame render on A9 | **PENDING** (`docs/TESTING.md` device matrix) |
