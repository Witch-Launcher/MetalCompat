# MetalCompat — CPU Runtime (v0.2.0)

Implements SPEC §4 on the current repository shape. Do not emulate a CPU
(SPEC D-004); this module prepares, validates, schedules, and submits.

## 1. Implemented now

### 1.1 API validation
- Registry schema validation at load time (unique ids, enum conformance,
  verified-block presence) — `src/Registry/FeatureRegistry.cpp`.
- Typed error returns (`mc::Error`) for: unknown feature id, wrong category,
  modified registry contradictions, invalid value payloads passed to the
  planner. Dev/diag/production validation levels are encoded as
  `mc::ValidationLevel` and honored by the planner gate.

### 1.2 Capability queries and planning
- `CapabilityEngine` caches an immutable per-device snapshot at construction
  (no repeated queries on hot paths — SPEC §4.3).
- Planner consults: registry record (`compatibilityState`, `requiredOs`),
  device capability snapshot, requested contract flags. Decision table lives in
  `src/Planner/ExecutionPlanner.cpp` and is unit-tested.

### 1.3 Command preparation
- Vertical slice: native-path only — backend encoders are called directly
  (SPEC D-002/§6.3). CommandPlan types exist but are unused for native features.

### 1.4 Job scheduling
- Bounded worker pool: **not yet implemented** (M8). Current slice is single
  submission-path; parallel encoding is a measured future step (SPEC §4.2.4).

### 1.5 Resource bookkeeping
- Slice-stage: ownership rules documented (RESEARCH/ARCHITECTURE); explicit
  CPU-side tracking of `MTLBuffer`/`MTLTexture` retention is deferred to M4
  with hazard tests.

### 1.6 CPU fallback kernels
- Deliberately nothing implemented. CPU fallback requires benchmark evidence
  (SPEC §4.2.6); the planner will only emit `EMULATED` candidates after M8
  measurements. The decision hook exists.

### 1.7 Shader/pipeline preparation
- Slice compiles an MSL string once and caches the resulting
  `MTLLibrary`/pipeline in the render example; per-app producible artifacts not
  implemented yet (M8: pipeline cache keyed by (MSL hash, entry, defines)).

### 1.8 Diagnostics / telemetry
- `src/CPU/Diagnostics/Diag.hpp/.cpp`: opt-in ring buffer events
  (`feature_selected`, `fallback_reason`, `plan_unsupported`, timings via
  `mach_absolute_time`), disabled by default, zero cost when disabled (SPEC §4.2.8).
  No shader source or app content is ever logged.

## 2. Hot-path rules in force (SPEC §4.3)

- Capability snapshot queried exactly once per device/session; planner reads
  cached PODs.
- No allocations in plan/decide paths; `mc::Error` is a 3-field aggregate.
- No Objective-C message sends in C++ decision code (bridge only at boundaries).
- No global locks in current code; backend owns its device reference.
- No readbacks in the optimizer-relevant path (slice reads back exactly once
  for deterministic verification, an explicitly allowed test path).

## 3. Not implemented / staged

| Item | Milestone | Note |
|---|---|---|
| Worker pool for parallel encoding | M8 | only with measured evidence |
| Resource lifetime tracker + pool reuse tests | M4 | test resource reuse under frames-in-flight |
| Pipeline binary cache (binary archives) | M8 | keys: MSL source hash + entry + specialization |
| Telemetry sinks (flush/print/export) | M4 | ring buffer exists |
| CPU fallback kernels | gated by M8 data | planner hook ready |
