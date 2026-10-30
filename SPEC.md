# MetalCompat

> **Document type:** Living project specification + coding-agent master prompt  
> **Version:** 0.2.0  
> **Status:** Architecture proposal; research and implementation not yet validated  
> **Primary target:** Apple A9 and newer  
> **Implementation language:** C++20 + Objective-C++ + Metal Shading Language  
> **Minimum OS strategy:** Investigate iOS/iPadOS 14 as the initial deployment baseline; verify every API against the actual SDK and device/OS combination.

---

## 0. How to maintain this file (read before editing)

This is a **living specification**, not a one-time prompt. Treat each numbered section as an independently maintainable module.

### Rules for future changes

1. Read this complete file before making architectural changes.
2. Identify the exact section(s) affected by the user's request.
3. Edit only the affected section(s), plus dependent sections when necessary.
4. Do not regenerate or rewrite the entire document merely to change one feature.
5. Preserve decisions that the user has not asked to change.
6. When a decision changes, update the **Decision Log** in Section 2 and the affected implementation requirements.
7. Update the version and changelog in Section 15.
8. If requirements conflict, report the conflict and propose the smallest safe correction. Do not silently discard an existing requirement.
9. Keep completed, in-progress, planned, unverified, and unsupported work clearly distinguished.
10. Never turn an unverified idea into a claimed capability.

### Change request protocol

For every requested modification, return:

- **Scope:** exact sections/files affected.
- **Impact:** architecture, API, compatibility, performance, and test consequences.
- **Patch:** focused edits, not a full rewrite.
- **Migration:** any required code/config migration.
- **Validation:** build and tests that should be run.
- **Decision Log:** update only if an architectural decision changes.

### Editable project parameters

Change these values only when explicitly requested or when research proves they are invalid.

| Parameter | Current decision |
|---|---|
| Project name | MetalCompat |
| Primary goal | Modern Metal API compatibility on legacy Apple GPUs |
| First hardware target | Apple A9 / Apple GPU Family 3 |
| Hardware scope | A9 and newer, capability-gated per feature |
| Initial OS baseline | iOS/iPadOS 14, subject to SDK validation |
| Core language | C++20 |
| Apple integration | Objective-C++ |
| Shader language | Metal Shading Language (MSL) |
| Build system | CMake + Xcode project/build integration |
| Primary backend | Legacy Metal (`MTL*`) |
| Modern backend | Native Metal 4 (`MTL4*`) only where supported |
| Execution model | Hybrid direct-native + selective translation + selective emulation |
| Primary quality goals | Correctness, stability, low overhead, measurable performance |
| TGLMT integration | Optional; MetalCompat must remain independently usable |

---

# 1. Project mission and non-goals

## 1.1 Mission

Build **MetalCompat**, a modular compatibility runtime and SDK that maximizes the usable subset of modern, publicly documented Metal functionality on legacy Apple GPUs, starting with A9.

MetalCompat must:

1. Maintain a versioned inventory of public Metal APIs and related capabilities.
2. Distinguish OS/API availability from GPU hardware capability.
3. Detect the real capabilities of the active `MTLDevice` at runtime.
4. Select native execution, a semantics-preserving fallback, a documented approximation, or an explicit unsupported result.
5. Translate selected modern operations into legacy Metal operations where a valid mapping exists.
6. Emulate selected features with GPU compute/render work or CPU algorithms only when correctness and performance justify it.
7. Preserve resource, synchronization, ordering, and lifetime semantics to the extent promised by each supported compatibility profile.
8. Minimize CPU overhead, GPU work amplification, memory traffic, synchronization stalls, and frame latency.
9. Provide deterministic tests, hardware validation, diagnostics, and performance measurements.

## 1.2 Non-goals

MetalCompat is **not**:

- A replacement GPU driver.
- A new GPU ISA or hardware feature implementation.
- A full software emulator of Apple GPU hardware.
- A CPU emulator or ARM instruction-set emulator.
- A private replacement for Apple's `Metal.framework`.
- A guarantee that every Metal 4 API can run on A9.
- A promise that every unsupported hardware feature can be reproduced in software at acceptable speed.
- A reason to route all native Metal calls through a heavyweight intermediate representation.
- A source-to-source text-replacement tool for arbitrary MSL.

## 1.3 Integration contract

The initial product is a **source-integrated compatibility SDK/runtime**. Applications must integrate and build against MetalCompat's public interface or a deliberate adapter layer.

Do not promise transparent execution of arbitrary prebuilt applications that directly link Apple's Metal framework. Do not propose unsupported framework replacement, private API hooking, jailbreak-only injection, or modification of system Metal components.

A future adapter may expose familiar concepts or provide source-level migration helpers, but it must not claim binary or ABI compatibility with Apple's Metal protocols unless that compatibility is independently proven and legally/technically supported.

---

# 2. Core architecture decisions

These decisions are the current architectural baseline. Change them only through the change request protocol in Section 0.

## D-001 — Hybrid layered runtime

Use a layered runtime with a thin public API, capability engine, execution planner, CPU runtime, GPU runtime, and backend adapters.

## D-002 — Direct-native fast path

When an operation is natively supported and its semantics match the requested contract, call the native Metal API directly. Avoid unnecessary wrappers, allocations, virtual dispatch, command reconstruction, and synchronization.

## D-003 — Selective translation, not universal translation

Use an internal typed command/operation representation only for features that need translation, validation, dependency analysis, shader variant selection, or emulation planning. Do not force every supported Metal call through a universal command graph.

## D-004 — CPU–GPU co-design, not CPU/GPU emulation

Implement CPU-side runtime behavior and GPU-side workloads as explicit subsystems. Use the existing ARM CPU and Apple GPU through public system APIs. Do not recreate either processor.

## D-005 — Capability is multidimensional

A feature is not simply "supported by Metal version X". Evaluate at least:

- SDK compile-time availability;
- runtime OS availability;
- GPU family / hardware support;
- device-specific limits and format support;
- shader language and compiler support;
- resource and synchronization constraints;
- MetalCompat implementation and validation status.

## D-006 — Honest compatibility states

Every feature must be labelled `NATIVE`, `FALLBACK`, `EMULATED`, `APPROXIMATED`, `PARTIAL`, `UNSUPPORTED`, or `UNKNOWN`. Never label an emulated or approximate feature as native.

## D-007 — Correctness before performance

No optimization may silently weaken synchronization, resource lifetime, numeric behavior, ordering, or output correctness. Performance changes require measurements.

## D-008 — Legacy-first implementation

The first working backend targets legacy `MTL*` APIs and A9-class hardware. Native Metal 4 support is a separate backend for devices and OS releases that actually expose it.

## D-009 — Optional TGLMT integration

MetalCompat may later provide services to TGLMT, but it must not depend on TGLMT and must remain independently buildable and testable.

---

# 3. Proposed architecture

## 3.1 High-level data flow

```text
Application / Game / TGLMT
          |
          v
MetalCompat Public API / Source Adapter
          |
          v
API & Semantic Layer
          |
          +------------------------------+
          |                              |
          v                              v
Capability Engine                 API Registry
          |                              |
          +---------------+--------------+
                          v
                 Execution Planner
                          |
          +---------------+----------------------+
          |               |                      |
          v               v                      v
    Native path     Translation path       Emulation path
          |               |                      |
          |          Typed operation plan         |
          |               |                      |
          +---------------+----------------------+
                          |
               CPU Runtime + GPU Runtime
                          |
                          v
                Backend Adapter Layer
                          |
              +-----------+-----------+
              |                       |
              v                       v
       Legacy Metal (`MTL*`)    Native Metal 4 (`MTL4*`)
              |                       |
              +-----------+-----------+
                          v
                    Apple GPU
```

## 3.2 Layer responsibilities

### A. Public API / Adapter Layer

- Expose stable MetalCompat concepts to applications.
- Avoid pretending to be Apple's complete Metal protocol hierarchy.
- Keep API contracts explicit and versioned.
- Support C++ APIs and optional Objective-C/Swift-facing adapters.
- Provide source migration helpers only when semantics are clear.

### B. API & Semantic Layer

- Represent the requested operation and its required semantics.
- Validate arguments and resource usage.
- Express ordering, visibility, lifetime, and synchronization requirements.
- Separate an API's observable behavior from one particular backend implementation.
- Return typed errors for unsupported semantics instead of silently dropping them.

### C. Capability Engine

- Inspect the active `MTLDevice`.
- Query GPU families and specific device capabilities through documented APIs.
- Check runtime OS availability separately from hardware support.
- Check formats, limits, shader features, resource options, and relevant synchronization facilities.
- Cache immutable capability results per device/runtime session.
- Never infer actual support from marketing name alone.

### D. API Registry

- Store machine-readable API and feature metadata.
- Track symbol, API family, introduction SDK/OS, hardware requirements, limits, fallback mapping, caveats, references, and test status.
- Generate compatibility tables and documentation from the registry.
- Include source provenance and last verification date.

### E. Execution Planner

For each operation, select the least expensive valid path:

1. Native implementation.
2. Semantics-preserving legacy translation.
3. GPU emulation using render/compute operations.
4. CPU implementation for suitable workloads.
5. Approximation only when the caller explicitly accepts its contract.
6. Unsupported error when no valid implementation exists.

The planner must account for dependencies, resource state, synchronization, workload size, data transfer, and known device performance characteristics.

### F. CPU Runtime

Own CPU-side preparation, scheduling, bookkeeping, validation, and command submission. Detailed responsibilities are defined in Section 4.

### G. GPU Runtime

Own GPU workload generation and execution through public Metal APIs. Detailed responsibilities are defined in Section 5.

### H. Backend Adapters

- Legacy Metal adapter: first priority; uses available `MTL*` APIs.
- Native Metal 4 adapter: optional and gated by OS + device support; uses `MTL4*` APIs.
- Future backend adapters may be added without changing the semantic contract.

---

# 4. CPU Runtime — behavior and responsibilities

## 4.1 Goal

Implement CPU-side behavior explicitly, but **do not emulate an ARM CPU**. MetalCompat runs on the application's existing CPU and uses it to prepare, schedule, validate, and submit GPU work.

## 4.2 CPU subsystems

### 4.2.1 API validation

- Validate descriptors, parameters, resource formats, bounds, and state transitions.
- Detect invalid combinations before command submission where feasible.
- Support configurable validation levels: development, diagnostic, and production.
- Keep expensive validation out of release hot paths unless required for safety/correctness.

### 4.2.2 Capability queries and planning

- Read cached capability information.
- Choose a valid backend path.
- Reject unsupported semantics early.
- Keep decisions inspectable through diagnostics.

### 4.2.3 Command preparation and encoding

- Encode native Metal commands directly for the fast path.
- Build typed operation plans for translated/emulated features only.
- Split work into command buffers/passes only when required by semantics or beneficial by measurement.
- Preserve explicit dependencies and submission order.

### 4.2.4 Job scheduling

- Use a small bounded worker pool where parallel CPU preparation is beneficial.
- Avoid oversubscription on A9-class devices.
- Keep thread count configurable and device-aware.
- Do not create one thread per draw call or tiny task.
- Do not parallelize operations with unresolved data dependencies.
- Measure contention and queueing delay.

### 4.2.5 Resource bookkeeping

- Track MetalCompat-owned objects and references.
- Track resource lifetime for APIs whose semantics require explicit retention.
- Reuse pools only when ownership and GPU completion are proven.
- Prevent use-after-free and premature reuse.
- Do not assume Metal 4's resource lifetime behavior is identical to legacy command-buffer behavior.

### 4.2.6 CPU fallback kernels

CPU fallback is allowed only for appropriate operations, for example:

- small input sizes;
- irregular or branch-heavy workloads;
- preprocessing that is already CPU-resident;
- operations where GPU dispatch and synchronization would cost more than the calculation;
- deterministic reference implementations for testing.

Do not use CPU fallback for large parallel workloads without benchmark evidence. Avoid unnecessary GPU-to-CPU readback.

### 4.2.7 Shader and pipeline preparation

- Select precompiled shader variants when possible.
- Perform compilation/preparation away from critical frame paths when the API permits.
- Cache pipeline states and compilation results with correct keys.
- Never assume runtime shader compilation is available or permitted in every deployment environment; verify platform and SDK constraints.

### 4.2.8 Diagnostics and telemetry

Record opt-in, low-overhead diagnostic events:

- feature selection;
- fallback selection reason;
- pipeline cache hit/miss;
- command preparation time;
- queue submission time;
- resource pool statistics;
- unsupported operation and error context.

Do not log sensitive application content or shader source by default.

## 4.3 CPU hot-path rules

- Avoid repeated dynamic allocation.
- Avoid unnecessary Objective-C message dispatch in high-frequency C++ loops.
- Avoid global locks where per-device/per-queue ownership is sufficient.
- Avoid blocking waits during frame production.
- Avoid redundant capability checks; cache immutable results.
- Avoid copying large buffers when resource sharing or direct binding is valid.
- Keep performance instrumentation optional and measurable.

---

# 5. GPU Runtime — behavior and responsibilities

## 5.1 Goal

Implement GPU-side workloads as Metal resources, render/compute passes, and MSL shaders executed by the existing Apple GPU. Do not emulate a GPU device or invent missing hardware instructions.

## 5.2 GPU subsystems

### 5.2.1 Native rendering and compute

- Use native render and compute pipeline states when supported.
- Respect device threadgroup limits and resource constraints.
- Use native texture formats and operations where available.
- Preserve render-pass load/store, blend, depth/stencil, and resource visibility semantics.

### 5.2.2 GPU emulation kernels

Selected features may be implemented through compute or render passes when a valid algorithm exists.

Each emulation implementation must document:

- mathematical/algorithmic behavior;
- supported input/output formats;
- numerical precision and tolerances;
- synchronization requirements;
- scratch memory and resource usage;
- number of dispatches/passes;
- expected workload range;
- known incompatibilities;
- measured performance on each target family.

### 5.2.3 GPU resource strategy

- Use device-supported resource storage modes.
- Minimize resource duplication and CPU/GPU transfers.
- Pool temporary resources only with safe lifetime tracking.
- Respect texture and buffer alignment/size constraints.
- Track residency and resource dependencies as required by the selected Metal API.

### 5.2.4 Shader variants

- Build variants for supported MSL language/features.
- Generate variants from structured metadata or a validated intermediate representation when transformation is necessary.
- Prefer offline-generated variants for known compatibility paths.
- Reject shader constructs that cannot be transformed safely.
- Do not apply blind text substitutions to arbitrary shader source.

### 5.2.5 GPU synchronization

- Model producer/consumer dependencies explicitly.
- Use the weakest synchronization primitive that is correct and documented.
- Avoid broad barriers when a narrower dependency is valid.
- Never remove a barrier based only on benchmark results.
- Validate cross-queue and CPU/GPU synchronization separately.

## 5.3 GPU hot-path rules

- Avoid avoidable compute dispatches.
- Avoid redundant render passes and intermediate textures.
- Avoid unnecessary CPU readbacks.
- Avoid oversynchronization.
- Avoid large scratch allocations on constrained devices.
- Measure occupancy-related choices indirectly through GPU timings and documented limits; do not invent hardware occupancy values.
- Use fallback only when it is correct and its cost is understood.

---

# 6. CPU–GPU execution policy

## 6.1 Work placement

The execution planner chooses CPU or GPU execution based on:

- input/output size;
- arithmetic intensity;
- branch divergence / irregularity;
- data residency;
- dispatch and submission overhead;
- required synchronization;
- memory transfer cost;
- latency target;
- device-specific measurements.

No universal fixed threshold should be invented. Establish thresholds through benchmarks per workload family and hardware class.

## 6.2 Scheduling rules

- Preserve API-visible ordering and data dependencies.
- Allow parallel CPU encoding only for independent work.
- Batch commands only when the reduction in submission overhead outweighs batching latency and memory cost.
- Do not add a global deferred-execution queue by default.
- Do not delay work past a point that increases input-to-display latency or violates resource lifetime.
- Use bounded frames-in-flight and resource pools.
- Make queue depth and batching policy configurable for experiments.

## 6.3 Native path must stay thin

For natively supported APIs, the compatibility layer should add as little work as practical. It must not create a command graph, copy resources, or introduce a worker-thread hop unless required by the caller's chosen API contract.

## 6.4 Performance acceptance

Compare MetalCompat against a direct native Metal baseline using identical workloads. Report:

- CPU encoding time;
- CPU submission time;
- GPU execution time;
- end-to-end latency;
- frame-time distribution and stutter;
- peak and steady-state memory;
- allocation count;
- bytes copied;
- number of command buffers/passes/dispatches;
- cache hit rate.

Report median and tail behavior (for example p95/p99) where the measurement sample is sufficient. Never report a single best run as representative.

---

# 7. Metal API compatibility model

## 7.1 Compatibility states

Use exactly these states in registry and reports:

- `NATIVE`: device, OS, and SDK provide the required feature and the implementation uses it directly.
- `FALLBACK`: another native Metal operation implements the same externally observable semantics within the documented contract.
- `EMULATED`: an alternative CPU/GPU algorithm provides the feature's behavior, with known cost and constraints.
- `APPROXIMATED`: output or behavior intentionally differs within an explicitly documented relaxed contract.
- `PARTIAL`: only a defined subset is implemented.
- `UNSUPPORTED`: no safe implementation is available.
- `UNKNOWN`: research or validation is incomplete.

Do not call an approximation "fully compatible".

## 7.2 Per-feature support record

Each feature record must include:

- stable feature ID;
- official symbol/API name(s);
- API category;
- required SDK;
- required OS;
- required GPU family or capability;
- device limits/formats;
- shader requirements;
- synchronization/lifetime requirements;
- compatibility state;
- fallback strategy;
- semantic gaps;
- performance risk;
- test cases and test status;
- official documentation/SDK source;
- last verification date.

## 7.3 Metal 4 compatibility rule

Metal 4 introduces new `MTL4*` command types that are distinct from their legacy `MTL*` counterparts. The Metal 4 backend and legacy backend must remain separate adapters.

Do not assume an `MTL4CommandQueue` can be represented by an `MTLCommandQueue` with only a renamed type. For each Metal 4 concept, determine whether it can be:

1. directly supported on the device;
2. mapped to legacy APIs with equivalent semantics;
3. emulated with a weaker documented contract;
4. partially implemented;
5. reported unsupported.

Metal 4 native support is hardware- and OS-dependent. A9 must not be reported as a native Metal 4 device.

## 7.4 Feature families to inventory

Inventory the public Metal framework and related Apple GPU frameworks in a versioned manner. At minimum investigate:

- device discovery and capability queries;
- command queues, command buffers, encoders;
- render and compute pipelines;
- buffers, textures, samplers, heaps;
- resource options, storage modes, residency;
- synchronization: fences, events, barriers;
- argument buffers and resource binding;
- indirect command buffers and indirect dispatch;
- texture formats, views, compression, sparse resources;
- shader language versions and features;
- function specialization and pipeline compilation;
- counters, timestamps, debugging/validation;
- rasterization, tessellation, tile/imageblock features;
- mesh/amplification shader capabilities;
- ray tracing and acceleration structures;
- MetalFX and related feature availability;
- machine learning / tensor-related Metal APIs;
- Metal 4 command architecture and resource model.

This list is an inventory scope, not a claim that every item can be implemented on A9. Keep Metal framework APIs distinct from related frameworks such as MetalFX, Metal Performance Shaders, and Core ML.

---

# 8. Shader compatibility subsystem

## 8.1 Research first

Use the official Metal Shading Language Specification and SDK headers as the source of truth. Inventory the language version, feature, and hardware constraints separately.

## 8.2 Responsibilities

- identify shader language requirements;
- select a compatible precompiled shader variant;
- compile or load a compatible variant where the platform permits;
- validate resource binding and data layout;
- report unsupported language constructs precisely;
- cache shader and pipeline artifacts with complete keys;
- preserve numerical and memory semantics.

## 8.3 Transformation rules

- Do not use regex or naive text substitution as the primary transformation method.
- If transformations need semantic understanding, investigate a parser/AST or a suitable intermediate representation.
- Keep transformations small, typed, and independently tested.
- Track source and generated shader hashes.
- Validate generated shaders with the actual target SDK compiler.
- Keep a non-transformed native path when available.

---

# 9. Resource, memory, and synchronization model

## 9.1 Resource model

Define explicit resource descriptors and ownership rules for buffers, textures, samplers, pipeline states, heaps, and temporary resources.

## 9.2 Lifetime

- Document who owns each object.
- Track when a resource is referenced by submitted GPU work.
- Reuse only after completion guarantees are satisfied.
- Treat retained/unretained command-buffer references correctly for each backend.
- Test resource reuse under multiple frames in flight.

## 9.3 Memory strategy

- Query real device limits and supported storage modes.
- Minimize duplicate buffers and textures.
- Avoid CPU/GPU copies unless necessary.
- Prefer bounded pools over unbounded caches.
- Provide cache eviction and memory pressure behavior.
- Measure high-water marks and transient allocations.

## 9.4 Synchronization strategy

- Maintain a dependency model for translated operations.
- Map to the narrowest correct legacy primitive.
- Handle cross-queue and CPU/GPU dependencies explicitly.
- Test write-after-read, read-after-write, and write-after-write hazards.
- Do not assume a newer barrier model is identical to older fences/events.

---

# 10. Research and official source policy

Before implementing an API, verify it against current public Apple materials and the actual installed SDK.

Primary sources:

- Apple Metal Resources: https://developer.apple.com/metal/resources/
- Metal documentation: https://developer.apple.com/documentation/metal
- Metal 4 core API: https://developer.apple.com/documentation/metal/understanding-the-metal-4-core-api
- `MTLDevice`: https://developer.apple.com/documentation/metal/mtldevice
- `supportsFamily(_:)`: https://developer.apple.com/documentation/metal/mtldevice/supportsfamily(_:)
- Metal Shading Language specification: available from Apple Metal Resources
- Apple WWDC Metal sessions: https://developer.apple.com/videos/graphics-and-games/

Research requirements:

1. Verify symbol spelling and declaration in official docs or SDK headers.
2. Verify compile-time availability and runtime availability separately.
3. Verify GPU-family requirement separately from OS availability.
4. Verify feature-specific device limits and format support.
5. Record the SDK version and date used for verification.
6. Distinguish framework availability from hardware capability.
7. Do not use private APIs or undocumented driver behavior.
8. If official evidence is unavailable, mark the entry `UNKNOWN`.
9. Recheck the latest public SDK before claiming "latest Metal API coverage".

---

# 11. Implementation roadmap

## M0 — Research and capability inventory

Deliverables:

- `docs/RESEARCH.md`
- `docs/API_INVENTORY.md`
- `docs/GPU_CAPABILITY_MATRIX.md`
- `registry/metal_api_registry.json`
- `registry/gpu_capabilities.json`
- source references and verification dates

Acceptance:

- no invented API names;
- OS and hardware requirements are separate;
- unknown entries are explicitly marked;
- A9/Apple GPU Family 3 requirements are verified against official sources and SDK evidence.

## M1 — Project foundation

Deliverables:

- buildable C++20 core;
- Objective-C++ Metal bridge;
- public headers;
- error model;
- logging;
- unit-test harness;
- architecture documentation.

Acceptance:

- project builds with the chosen Xcode/SDK toolchain;
- no undocumented API usage;
- core modules can be tested without GPU execution where appropriate.

## M2 — Device and capability inspector

Deliverables:

- default `MTLDevice` discovery;
- GPU family detection;
- OS/SDK runtime reporting;
- format and limit queries;
- capability report export;
- registry loading and validation.

Acceptance:

- unsupported queries fail safely;
- reported capability values come from real API queries or verified registry facts;
- no device-name-only inference.

## M3 — First working vertical slice

Implement:

- create a device;
- load API registry;
- inspect capabilities;
- select legacy backend;
- create a basic render pipeline;
- render a deterministic test frame;
- capture diagnostics and timing.

Acceptance:

- compile and run on a supported test device;
- rendering output matches reference within defined tolerance;
- native baseline timing is recorded;
- the test clearly reports when real A9 hardware has not been tested.

## M4 — Core legacy Metal operations

Prioritize buffers, textures, samplers, render pipeline, compute pipeline, command buffers, encoders, resource lifetime, and synchronization.

Acceptance:

- deterministic unit/integration tests;
- resource hazard tests;
- no silent fallback for unsupported operations.

## M5 — Selective modern API translation

Choose one feature at a time. For each feature, document semantic mapping and overhead before implementation.

Acceptance:

- reference behavior defined;
- translated behavior passes correctness tests;
- performance overhead measured;
- fallback selected only when beneficial or required.

## M6 — Shader compatibility

Implement validated shader variant selection and only the transformations justified by specific use cases.

Acceptance:

- target compiler validates generated shaders;
- shader tests cover edge cases;
- unsupported shader constructs produce precise diagnostics.

## M7 — Advanced emulation research

Investigate mesh-related workflows, acceleration structures/ray tracing, selected MetalFX-like functionality, and other modern features individually.

Acceptance:

- prototype is isolated;
- correctness and semantic gaps documented;
- performance measured on target devices;
- no unsupported feature is advertised as fully compatible.

## M8 — Performance and stability

Profile CPU, GPU, memory, latency, frame pacing, and thermal behavior on physical devices.

Acceptance:

- compare against direct native Metal baseline;
- report median and tail latency;
- no unbounded growth in resources/caches;
- stress tests and extended run tests pass.

## M9 — Optional TGLMT integration

Provide an optional integration adapter or module only after the standalone runtime is stable.

Acceptance:

- MetalCompat builds without TGLMT;
- integration tests are separate;
- no OpenGL-specific concept leaks into the core public API.

---

# 12. Testing and benchmarking

## 12.1 Device matrix

Test physical hardware by GPU family, beginning with:

- A9;
- A10;
- A11;
- A12;
- A13;
- A14 and newer.

Do not claim a family is validated merely because a simulator or a newer device builds the code.

For each test device, record:

- device identifier/model as appropriate for the test report;
- SoC/GPU family evidence;
- OS version/build;
- Xcode and SDK version;
- Metal device capabilities;
- test date;
- test result and logs.

## 12.2 Unit tests

- registry parsing and schema validation;
- capability selection;
- backend selection;
- API validation;
- resource ownership and lifetime;
- cache key correctness;
- command dependency planning;
- shader variant selection;
- unsupported-feature errors.

## 12.3 GPU integration tests

- buffer creation/read/write;
- texture creation and sampling;
- render pass correctness;
- compute dispatch correctness;
- indirect command behavior where available;
- synchronization and hazards;
- multiple frames in flight;
- resource pool reuse;
- device loss/error paths where testable.

## 12.4 Correctness tests

- deterministic inputs;
- reference images and numerical outputs;
- defined precision tolerances;
- edge cases and invalid parameters;
- stress and lifetime tests;
- comparison between native and fallback paths.

## 12.5 Performance tests

Measure:

- CPU command encoding;
- CPU submission;
- GPU execution;
- end-to-end operation/frame latency;
- p50/p95/p99 where sample size supports it;
- memory footprint and high-water mark;
- allocations and resource copies;
- command buffers, encoders, passes, and dispatch count;
- cache hit/miss rate;
- fallback overhead versus native baseline.

Use identical workloads and settings for direct-native and MetalCompat comparisons. Include warm-up and repeated runs. Note thermal state and measurement limitations.

---

# 13. Technology and repository structure

## 13.1 Technology choices

- C++20: portable core, capability model, planner, registry, scheduling, resource bookkeeping.
- Objective-C++: bridge to Objective-C Metal protocols and Apple platform APIs.
- Metal Shading Language: GPU shaders and selected emulation kernels.
- CMake: core build organization; integrate with Xcode for Apple platform targets.
- XCTest: Apple-platform integration tests where useful.
- C++ unit test framework: core tests.
- JSON: machine-readable registry and test metadata.

Do not introduce dependencies without explaining their necessity, license, maintenance state, and impact on iOS deployment.

## 13.2 Suggested repository layout

```text
MetalCompat/
├── CMakeLists.txt
├── README.md
├── LICENSE
├── include/MetalCompat/
│   ├── Device.hpp
│   ├── Capabilities.hpp
│   ├── FeatureRegistry.hpp
│   ├── ExecutionPlanner.hpp
│   ├── CommandPlan.hpp
│   ├── Resources.hpp
│   ├── Pipeline.hpp
│   ├── Shader.hpp
│   ├── Compatibility.hpp
│   └── Errors.hpp
├── src/
│   ├── Core/
│   ├── API/
│   ├── Capability/
│   ├── Registry/
│   ├── Planner/
│   ├── CPU/
│   │   ├── Scheduling/
│   │   ├── Validation/
│   │   ├── ResourceLifetime/
│   │   ├── Cache/
│   │   └── Diagnostics/
│   ├── GPU/
│   │   ├── Shaders/
│   │   ├── EmulationKernels/
│   │   └── ResourceStrategies/
│   └── Backends/
│       ├── LegacyMetal/
│       └── Metal4/
├── shaders/
│   ├── common/
│   ├── variants/
│   └── emulation/
├── registry/
│   ├── metal_api_registry.json
│   └── gpu_capabilities.json
├── tools/
│   ├── APIRegistryValidator/
│   ├── APIRegistryGenerator/
│   └── CapabilityInspector/
├── tests/
│   ├── Unit/
│   ├── Integration/
│   ├── Rendering/
│   └── Performance/
├── examples/
│   ├── CapabilityReport/
│   ├── BasicRendering/
│   └── Compute/
└── docs/
    ├── RESEARCH.md
    ├── API_INVENTORY.md
    ├── GPU_CAPABILITY_MATRIX.md
    ├── ARCHITECTURE.md
    ├── CPU_RUNTIME.md
    ├── GPU_RUNTIME.md
    ├── COMPATIBILITY_STRATEGY.md
    ├── IMPLEMENTATION_STATUS.md
    ├── TESTING.md
    └── PERFORMANCE.md
```

Adjust the structure only when implementation evidence justifies the change. Keep CPU, GPU, API semantics, and backend-specific code clearly separated.

---

# 14. Coding-agent operating instructions

You are acting as a principal graphics systems engineer, Apple Metal specialist, GPU software architect, compiler engineer, and performance engineer.

## 14.1 Before coding

1. Inspect the repository and current working tree.
2. Identify the host OS, Xcode version, SDK version, compiler, build tools, and available target devices.
3. Read the relevant existing source and docs before changing anything.
4. Research the exact Apple API in official docs and SDK headers.
5. Record hardware, OS, and SDK constraints.
6. Define the behavior and test before implementation.

## 14.2 During implementation

For each small task:

1. State the exact scope.
2. Research and verify symbols.
3. Implement the smallest complete unit.
4. Build immediately.
5. Run relevant tests immediately.
6. Inspect compiler warnings and runtime diagnostics.
7. Fix regressions before moving forward.
8. Measure performance when the change affects a hot path.
9. Update registry and docs.
10. Record remaining limitations.

## 14.3 Hard prohibitions

- Do not invent Metal APIs, symbols, enums, or method signatures.
- Do not use private Apple APIs.
- Do not claim A9 supports native Metal 4.
- Do not treat all modern Metal features as software-emulatable.
- Do not use regex replacement as a general MSL compiler.
- Do not add global deferred execution without latency/performance evidence.
- Do not route native fast-path calls through expensive general-purpose IR unnecessarily.
- Do not remove synchronization without proving correctness.
- Do not fabricate benchmark results or claim tests passed when not run.
- Do not hide unsupported features behind silent no-op behavior.
- Do not rewrite unrelated files or docs.

## 14.4 Reporting format

At the end of each task, report:

- What changed.
- Why the design was selected.
- Files created/modified.
- Build command and result.
- Tests run and result.
- Physical hardware tested, if any.
- Performance measurements, if relevant.
- Known limitations and next smallest task.

Clearly distinguish `implemented`, `compiled`, `unit-tested`, `simulator-tested`, and `physical-device-tested`.

---

# 15. First task for the coding agent

Start with **M0 and the M1 foundation proposal**. Do not generate the entire codebase immediately.

First inspect the environment and repository. Then produce:

1. `docs/RESEARCH.md` — verified current Metal API and hardware research.
2. `docs/API_INVENTORY.md` — structured public API inventory.
3. `docs/GPU_CAPABILITY_MATRIX.md` — GPU family, OS, SDK, feature, and limits matrix.
4. `docs/ARCHITECTURE.md` — proposed modules, dependencies, and data flow.
5. `docs/CPU_RUNTIME.md` — CPU responsibilities, threading, memory, and scheduling.
6. `docs/GPU_RUNTIME.md` — GPU responsibilities, shaders, resources, and emulation boundaries.
7. `docs/COMPATIBILITY_STRATEGY.md` — native/fallback/emulated/approximate/unsupported mapping.
8. A small buildable project skeleton and a staged implementation plan.

Then implement only the first vertical slice:

- create/get an `MTLDevice`;
- detect GPU family and basic capabilities;
- load and validate the API registry;
- select the legacy Metal backend on A9-class hardware;
- create a basic render pipeline;
- render a deterministic frame;
- report diagnostics and baseline timings.

Build and test the vertical slice before expanding the runtime.

If A9 physical hardware is unavailable, implement tests that can run in the current environment and clearly mark A9 physical validation as pending. Do not substitute a simulator result for real A9 validation.

---

# 16. Decision log and changelog

## Decision Log

| ID | Decision | Reason | Status |
|---|---|---|---|
| D-001 | Hybrid layered runtime | Balance correctness, extensibility, and low overhead | Active |
| D-002 | Direct-native fast path | Avoid overhead when native support exists | Active |
| D-003 | Selective typed command representation | Translate only where necessary; avoid universal IR overhead | Active |
| D-004 | CPU–GPU co-design, not processor emulation | Use existing Apple CPU/GPU through supported APIs | Active |
| D-005 | Multidimensional capability detection | OS, SDK, GPU, limits, and shader support differ | Active |
| D-006 | Explicit compatibility states | Prevent misleading support claims | Active |
| D-007 | Correctness before performance | Preserve observable semantics | Active |
| D-008 | Legacy-first, Metal 4 separate backend | A9 requires legacy backend; MTL4 types are distinct | Active |
| D-009 | Optional TGLMT integration | Keep core reusable and independently testable | Active |

## Changelog

### 0.2.1 — 2026-10-30

- M4 legacy ops core implemented and host-tested (buffers/texture staging/
  sampler/compute dispatch, bounded staging reuse); availability-correctness
  fixes recorded in docs/IMPLEMENTATION_STATUS.md (legacy blit selectors,
  MTLGPUFamilyMetal3 availability guards, ARC policy).
- CI added (GitHub Actions, macos-14 host + iOS cross-build, zero-warning gate).
- First physical-device session planned on iPhone 8 Plus (A11/Apple4);
  A9 silicon evidence remains REQUIRED and cannot be substituted by family
  inference (docs/DEVICE_TEST_SESSION.md).
- MoltenVK/TGLMT track documented (docs/MOLTENVK_INTEGRATION.md) per D-009;
  MetalCompat remains standalone.

### 0.2.0 — 2026-10-29

- Replaced the vague wrapper/emulator framing with a hybrid layered runtime.
- Added explicit CPU Runtime and GPU Runtime responsibilities.
- Added CPU–GPU workload placement and scheduling policy.
- Adopted a direct-native fast path and selective typed command representation.
- Clarified that MetalCompat is a source-integrated SDK/runtime, not a drop-in replacement for Apple's system Metal framework.
- Separated legacy `MTL*` and native Metal 4 `MTL4*` backends.
- Added modular maintenance rules so future edits can target individual sections.

### 0.1.0 — Initial concept

- Initial idea: modern Metal API compatibility for A9 and newer Apple GPUs.

---

# End of master specification

When this file is updated, preserve its modular structure and changelog. Prefer focused patches over full rewrites.
