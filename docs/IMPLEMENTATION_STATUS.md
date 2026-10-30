# MetalCompat — IMPLEMENTATION STATUS (v0.2.0, 2026-10-30)

Honest states per SPEC §14.4 vocabulary: `implemented / compiled / unit-tested /
host-tested / physical-device-tested`. Nothing below claims physical-device
testing on A9 — there is no A9 in the current environment.

## Verified facts (M0) — implemented

- GPU family model + A9↔Apple3 mapping: verified vs iOS SDK 26.2 headers and
  Apple docs (2026-10-30). See `docs/RESEARCH.md`, `registry/*.json`.
- Metal 4 = iOS 26 floor; legacy/Metal4 backend split enforced by planner
  (`mtl4.*` records → `UnavailableOs`/`PlanUnsupported` on iOS 14 runtime).

## Runtime (M1 core) — implemented, host-tested

| Component | Files | State |
|---|---|---|
| Typed error model (no exceptions across API) | `include/MetalCompat/Errors.hpp` | implemented |
| Compatibility states vocabulary | `Compatibility.hpp` | implemented |
| Device acquisition + capability snapshot caching | `Core/Device.cpp`, `Backends/LegacyMetal/metal_bridge.mm` | host-tested (Mac2 device) |
| Capability probe (supportsFamily 16 families, limits, tiers) | bridge | host-tested; Apple columns pending physical |
| Registry loader/validator (strict JSON, verified-block policy) | `Registry/*` | unit-tested (47 checks) |
| Execution planner (OS column-aware, hardware gates, refusals) | `Planner/*` | unit-tested |
| Diagnostics ring (opt-in) | `CPU/Diagnostics/*` | unit-tested |
| LegacyMetal backend (device + pipeline) | backend + `examples/BasicRender` | host-tested |

## Vertical slice (M3 scope) — implemented, host-tested

`examples/BasicRender`: device → registry → planner → LegacyMetal pipeline →
deterministic 64×64 frame → reference match (100%), PPM output, timings.
Pipeline creation via `MTLCompileOptions` (MSL 2.3 ceiling documented for iOS 14).

## Build & test results (2026-10-30)

| Item | Result |
|---|---|
| macOS Ninja build (x86_64 host) | 0 errors, 0 warnings |
| `ctest` | 2/2 pass (unit + render_vertical_slice) |
| Unit tests | 47/47 checks pass |
| iOS cross-build (arm64, iphoneos SDK 26.2, deployment **14.0**) | 0 errors, 0 warnings; all targets compile |
| Real-device run | **Not possible in this environment** |

## Availability corrections discovered during implementation (recorded)

- `MTLResourceStorageModeManaged` / `synchronizeResource:` are
  `API_UNAVAILABLE(ios)` (verified `MTLResource.h`, `MTLBlitCommandEncoder.h`);
  slice handles unified vs managed per `hasUnifiedMemory` (macOS 10.15+).
- `resetToThreadlessPolicy`-style unrelated APIs are not quoted anywhere —
  symbol hygiene kept by registry + validator.

## Known limitations (honest)

1. No Apple-family GPU exists on this host; every Apple-family runtime number
   (families beyond the boolean `supportsFamily` mechanism, tiers, etc.) is
   SDK/registry-derived and stays `UNKNOWN` per D-005/D-006 until probed.
2. `GPUEndTime-GPUStartTime` came back 0.000 ms on the host — instrumentation
   marked unverified, see PERFORMANCE.md.
3. Legacy mesh (`pipe.mesh.legacy`) row is `UNKNOWN` (SDK 26.2 ships only the
   Metal4 mesh pipeline header).
4. Examples' complete code path (particularly the shared-storage buffers) is
   host-tested; on-device behavior identical in code but unproven.

## Next smallest tasks (in order)

1. Run validator + tests in CI (GitHub Actions macOS runner) — repo remote now
   available (`Witch-Launcher/MetalCompat`).
2. A9 half-day validation session (device matrix PRO/§12.1): fills `UNKNOWN`s
   R-1..R-5 and pins the registry rows that are currently OS-verified only.
3. M4 core legacy op coverage (buffers/textures hazards, frames-in-flight tests).
4. M5 first translation record (choose one feature, write the §2 record first).
