# MoltenVK / TGLMT Integration (scoped contract)

Status: **documentation of intent — M9 not started.** MetalCompat remains
standalone (SPEC D-009: optional integration, no dependency, independently
buildable and testable).

## 1. Context (user decision, 2026-10-30)

The end-to-end validation track for this project is the user's iOS Minecraft
Java launcher (TGLMT) built on **MoltenVK**. Per the user's report, MoltenVK
locks several APIs/driver-visible limits as unsupported on low-end devices
(A9-class), which is exactly the gap MetalCompat targets. This document records
the contract so samples and docs stay aligned with SPEC D-009/M9.

## 2. What MetalCompat offers today (M0–M4, verified 2026-10-30)

| Component | Public surface | Role for a MoltenVK-based launcher |
|---|---|---|
| Capability probe | `mc_capabilities(...)` in `include/MetalCompat/Capabilities.hpp` | Facts for the device (families, limits, Metal4 gate) — no invented data (A-2) |
| Registry + planner | `mc::FeatureRegistry` + `ExecutionPlanner` | Per-feature decision table (Native/Partial/Unsupported + reason) usable for launcher-side API gating |
| Legacy ops C API | `src/Backends/LegacyMetal/legacy_ops.h` | Deterministic small op set (buffers/textures/staging/compute) — prototype surface for legacy stack tests |
| Capability report binary | `examples/CapabilityReport` | On-device evidence dump for the launcher's own capability adapter |

Everything above builds with CMake and the Xcode iOS project; tests run on host
(`ctest`) and the device runbook is `docs/DEVICE_TEST_SESSION.md`.

## 3. Explicitly NOT available (do not rely on this doc)

- No MTL4 paths (D-008: A9-class can never be Metal 4; M9 does not change this).
- No feature fabricated beyond the registry's `verified` records (A-2/A-9); if
  an API is UNKNOWN, the planner refuses.
- No OpenGL-ES-y concepts leak into the core API (M9 acceptance rule).

## 4. Integration direction (when M9 starts)

1. Launcher consumes MetalCompat as a source-integrated module (same repo
   checkout, no link-time dependency on TGLMT).
2. Launcher capability adapter is fed by `mc_capabilities()` + the registry
   planner instead of its own hardcoded device lists — single source of truth
   for what is Native/Partial/Unsupported *per device row*.
3. Integration tests live in the launcher's tree (separate target); MetalCompat
   keeps its own `ctest` suites as the stable baseline.
4. Any MoltenVK-specific behavior (e.g. unsupported-API fallbacks on A9-class)
   must be decided through registry rows + planner reasons, not device-model
   string matching. New rows go through the change protocol (SPEC §0).
