# MetalCompat — Architecture (v0.2.0 implementation map)

This document maps SPEC §3 (layered runtime) onto concrete modules and files
that exist or are staged in this repository. Data flow is exactly SPEC §3.1.

## 1. Module map (current state)

| SPEC layer | Repo location | Completed | Status |
|---|---|---|---|
| Public API | `include/MetalCompat/*.hpp` | `Device.hpp`, `Capabilities.hpp`, `FeatureRegistry.hpp`, `Errors.hpp`, `Compatibility.hpp`, `ExecutionPlanner.hpp`, `CommandPlan.hpp` | M1 core |
| API & Semantic layer | `src/API/` + headers | argument validation helpers staged with planner | M1 core (partial), grows in M4 |
| Capability Engine | `src/Capability/CapabilityEngine.cpp`, bridge: `src/Backends/LegacyMetal/metal_bridge.{h,mm}` | yes (family + limits + tiers via real queries) | M2 core |
| API Registry | `src/Registry/FeatureRegistry.cpp` + `registry/*.json` + `tools/APIRegistryValidator` | yes (load/validate/query) | M0/M1 |
| Execution Planner | `src/Planner/ExecutionPlanner.cpp` | decision table for slice features | M1 core (minimal) |
| CPU Runtime | `src/CPU/` (`Diagnostics/`) | opt-in trace ring buffer | partial (M1) |
| GPU Runtime | `src/GPU/`, `shaders/` | vertical-slice pipeline support | slice-stage |
| Backend: LegacyMetal | `src/Backends/LegacyMetal/` | device acquisition, family probe, pipeline selection | slice-stage |
| Backend: Metal4 | `src/Backends/Metal4/` | intentionally empty; staged directory + `@available` rules documented | not started (by design, D-008) |

## 2. Data flow (implementation contract)

```text
Caller (test/example)
  → mc::Device (device.hpp)            : owns MTLDevice*, mode selection
  → mc::CapabilityEngine               : immutable per-device snapshot
  → mc::FeatureRegistry (JSON)         : feature metadata + verified facts
  → mc::ExecutionPlanner               : feature id → mc::PlanOp decision
  → mc::Backend (LegacyMetal)          : MTL* calls; MTL4 path refused with typed error
  → MTLRenderPipelineState / MTLCommandBuffer (Apple Metal)
```

Rules inherited from SPEC:

- D-002: planner returns `PlanOp::Native` and the backend calls Metal directly —
  no intermediate IR for native features.
- D-003: typed plan (`CommandPlan.hpp`) only exists for features needing
  translation/emulation (currently none implemented; structure present).
- D-006: every decision carries a `CompatibilityState`; planner emits
  `UNSUPPORTED` with typed `mc::Error` instead of silently no-op-ing.
- D-008: LegacyMetal backend is the only complete backend; Metal4 adapter is
  compile-time gated (`iOS 26` availability) and runtime-gated
  (`MTLGPUFamilyMetal4`).

## 3. Error model (`Errors.hpp`)

`mc::ErrorCode` ∈ {None, Unsupported, UnavailableOs, InsufficientHardware,
InvalidRegistry, PlanUnsupported, BridgeFailure, InvalidArgument}.
Everything surfaces as typed `mc::Error{code, featureId, message}`; no exceptions
cross the public API (bridge and tests convert to return codes).

## 4. Registry contract

- `registry/metal_api_registry.json` — array of feature records (API_INVENTORY §A
  schema). Loader (`src/Registry`) validates: unique non-empty `id`, known
  `category`, `compatibilityState` ∈ SPEC §7.1 states, `verified` block present
  unless `compatibilityState == UNKNOWN`.
- `registry/gpu_capabilities.json` — family table + OS-floor facts from docs;
  validator cross-checks `Apple3 → SoC list contains A9` to pin the primary
  target invariant (D-001/D-008 reinforcement).
- The validator tool exits non-zero on any violation and prints the offending
  record — used in CI and unit tests.

## 5. Build system

- CMake ≥ 3.24, C++20, Ninja (host) and `CMAKE_SYSTEM_NAME=iOS` cross-build.
- Objective-C++ files visible only when compiling for Apple platforms; core
  C++ files must build/parse without Apple headers (`Device.hpp` bridges via
  explicit `[[MTLDevice]]` forward typedef in the backend, not in core headers).
- Static library `MetalCompatCore` + examples + tests; rendering executable
  links `Metal`, `Foundation` frameworks (macOS run / iOS build).

## 6. Extension policy (change protocol)

Only add a backend/type when a feature record demands it (SPEC §0 protocol).
New features follow: registry entry → capability gate → planner decision →
backend implementation → tests → docs update (IMPLEMENTATION_STATUS.md).
