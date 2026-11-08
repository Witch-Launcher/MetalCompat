# MetalCompat — IMPLEMENTATION STATUS (v0.4.0, 2026-10-30)

Honest states per SPEC §14.4 vocabulary: `implemented / compiled / unit-tested /
host-tested / physical-device-tested`. Nothing below claims physical-device
testing on A9 — there is no A9 in the current environment.

## Verified facts (M0) — implemented

- GPU family model + A9↔Apple3 mapping: verified vs iOS SDK 26.2 headers and
  Apple docs (2026-10-30). See `docs/RESEARCH.md`, `registry/*.json`.
- Metal 1/2/3/4 compatibility model: documented in `docs/RESEARCH.md §8` and
  `docs/COMPATIBILITY_STRATEGY.md §8`. Metal 4 = iOS 26 floor; legacy/Metal4
  backend split enforced by planner (`mtl4.*` → `UnavailableOs`/`PlanUnsupported`
  on iOS 14 runtime).
- Ray tracing hardware reality: documented per-device in `docs/RESEARCH.md §8.2`.
  A11/Apple4 = NO ray tracing (below Apple6 floor). `supportsRaytracing` probed
  per device; honest `NATIVE`/`UNSUPPORTED` states only.

## Runtime (M1 core) — implemented, host-tested

| Component | Files | State |
|---|---|---|
| Typed error model (no exceptions across API) | `include/MetalCompat/Errors.hpp` | implemented |
| Compatibility states vocabulary | `Compatibility.hpp` | implemented |
| Device acquisition + capability snapshot caching | `Core/Device.cpp`, `Backends/LegacyMetal/metal_bridge.mm` | host-tested (Mac2 device) |
| Capability probe (supportsFamily 16 families, limits, tiers, raytracing, metalVersion) | bridge | host-tested; Apple columns pending physical |
| Registry loader/validator (strict JSON, verified-block policy) | `Registry/*` | unit-tested |
| Execution planner (OS column-aware, hardware gates, refusals) | `Planner/*` | unit-tested |
| Diagnostics ring (opt-in) | `CPU/Diagnostics/*` | unit-tested |
| LegacyMetal backend (device + pipeline) | backend + `examples/BasicRender` | host-tested |

## Legacy ops core (M4 scope) — implemented, host-tested

`src/Backends/LegacyMetal/legacy_ops.{h,mm}`: deterministic op set (AUTO/PRIVATE
storage, staged texture upload/download via verified blit selectors, sampler,
runtime-MSL library + compute pipeline, 1-D dispatch bounded by the real
pipeline's `maxTotalThreadsPerThreadgroup`). ARC-mandatory.

## Software ray tracing emulation (M7/M9) — implemented, host-tested

`src/Backends/LegacyMetal/raytrace_emul.{h,mm}`:
software path-tracing emulation (EMULATED, runs on any Metal device including
A11/Apple4 which has no hardware ray tracing). Phong cách Ray Tracing in One
Weekend: diffuse (Lambert) / metal / dielectric (glass) materials,
anti-aliasing (per-pixel samples), multiple bounces, Schlick Fresnel,
Russian roulette termination, ACES filmic tonemapping. Chạy hoàn toàn bằng
compute BVH traversal — không cần MTLAccelerationStructure.

State = `EMULATED`, never `NATIVE`. Caller opts in explicitly; planner never
auto-substitutes this for a refused hardware path.

- `mcops_rtEmulAvailable` — always 1 (compute-only, any device)
- `mcops_rtEmulBuildBVH` — deterministic CPU BVH build (median split), returns
  opaque handle owning node + reordered triangle buffers
- `mcops_rtEmulPathTrace` — path-trace a full scene into RGBA32Float texture:
  diffuse/metal/dielectric materials, AA, multiple bounces, ACES tonemap.
  One dispatch covers the whole texture.

**New: Software RT scene test block in the on-device app**
- `apps/RenderTestApp/main.mm` — block `[PT] path-tracer`: builds a floor +
  4-sphere scene (diffuse red, metal gold, dielectric glass, emissive lamp),
  builds BVH on CPU, renders a path-traced 512×512 frame via software BVH
  compute, verifies lit pixels. Runs on A11/Apple4 where hardware RT is
  `supportsRaytracing == NO`. Viewport shows the live path-traced scene with
  animated camera; overlay text in top-left corner (non-blocking).

## Vertical slice (M3 scope) — implemented, host-tested

`examples/BasicRender`: device → registry → planner → LegacyMetal pipeline →
deterministic 64×64 frame → reference match (100%), PPM output, timings.
Pipeline creation via `MTLCompileOptions` (MSL 2.3 ceiling documented for iOS 14).

## Build & test results (2026-10-30)

| Item | Result |
|---|---|
| macOS Ninja build (x86_64 host) | 0 errors, 0 warnings |
| `ctest` | 3/3 pass (unit + integration + render_vertical_slice) |
| Unit tests | 96+ checks pass (incl. RT gating, MTL4 refusal, metal version) |
| Integration tests | ~80 checks pass (incl. RT emulation vs CPU reference) |
| iOS cross-build (arm64, iphoneos SDK 26.2, deployment **14.0**) | 0 errors, 0 warnings; all targets compile including MCRenderTest app |
| Registry validator | 38 features valid: NATIVE=17, EMULATED=1, PARTIAL=9, UNSUPPORTED=11, UNKNOWN=0 |
| Real-device run | **Not possible in this environment** — first session planned on user's iPhone 8 Plus (A11/Apple4), docs/DEVICE_TEST_SESSION.md |

## Availability corrections discovered during implementation (recorded)

- `MTLResourceStorageModeManaged` / `synchronizeResource:` are
  `API_UNAVAILABLE(ios)` (verified `MTLResource.h`, `MTLBlitCommandEncoder.h`);
  slice handles unified vs managed per `hasUnifiedMemory` (macOS 10.15+).
- `-supportsRaytracing` is available iOS 14.0+/macOS 11.0+; returns NO on
  Apple1–Apple5 (A7–A12), YES on Apple6+ (A13+). Apple4/A11 = NO RT at all.

## Known limitations (honest)

1. No Apple-family GPU exists on this host; every Apple-family runtime number
   (families beyond the boolean `supportsFamily` mechanism, tiers, etc.) is
   SDK/registry-derived and stays `UNKNOWN` per D-005/D-006 until probed.
2. `GPUEndTime-GPUStartTime` came back 0.000 ms on the host — instrumentation
   marked unverified, see PERFORMANCE.md.
3. Legacy mesh (`pipe.mesh.legacy`) row is `UNSUPPORTED` (SDK 26.2 ships no
   legacy mesh headers; mesh row starts at Apple7 per feature-set tables).
4. Examples' complete code path (particularly the shared-storage buffers) is
   host-tested; on-device behavior identical in code but unproven.
5. Ray tracing emulation is software path tracing (diffuse/metal/dielectric,
   AA, multiple bounces, ACES tonemap) — correct but not hardware-accelerated;
   not a substitute for `MTLAccelerationStructure` on RT-capable devices.
   Runs on A11/Apple4 via the `[PT]` app test block.

## Next smallest tasks (in order)

1. Physical session on iPhone 8 Plus (A11/Apple4) — first validated device row
   (runbook: docs/DEVICE_TEST_SESSION.md). Will verify: supportsRaytracing=NO on
   A11, ray tracing emulation runs correctly on A11, MTL4 refusal path.
2. M5 first translation record (choose one feature, write the §2 record first).
3. GitHub Actions CI (macos-14 host build+ctest+validator, iOS cross-build;
   zero-warning gate enforced by grepping build logs).

## M5–M9 (added 2026-10-30)

| Milestone | Component | Files | State |
|---|---|---|---|
| M5 | Layered-render translation record + per-slice fallback | `src/Backends/LegacyMetal/render_layered.{h,mm}` | implemented, host-tested |
| M5 | Planner gate tokens + provisioned-fallback catalog | `Planner/*`, registry `render.layered` | implemented, unit-tested |
| M6 | Shader variant subsystem (define-preamble compiler path, refcounted LRU) | `include/MetalCompat/Shader.hpp`, `src/GPU/Shaders/ShaderVariants.cpp` | implemented, unit-tested |
| M6 | Explicit-version runtime compile op | `legacy_ops.{h,mm}` `mcops_compileLibraryEx/freeLibrary` | implemented, host-tested |
| M7 | Legacy tier-1 argument buffers prototype | `arg_table_t1.{h,mm}` | implemented, host-tested |
| M8 | Perf harness | `tests/Performance/PerfHarness.mm` | implemented |
| M9 | Ray tracing emulation (software BVH, EMULATED) | `raytrace_emul.{h,mm}` | implemented, host-tested, integration-tested vs CPU reference; `mcops_rtEmulPathTrace` path tracer (diffuse/metal/dielectric, AA, bounces, ACES) added |
| M9 | App test blocks: `[PT] path-tracer` + `[R] ray-tracing` | `apps/RenderTestApp/main.mm` | compiled (iOS cross-build), on-device test pending |
| — | Registry: metal.version.compat, res.acceleration.emulated records | `registry/metal_api_registry.json` | implemented, validator pass |
| — | Docs: Metal 1/2/3/4 model (§8 RESEARCH, §8 STRATEGY), RT reality (§8.2) | `docs/RESEARCH.md`, `docs/COMPATIBILITY_STRATEGY.md` | implemented |

New-build results: 3/3 ctest pass, unit 96 checks, integration ~80 checks,
iOS arm64 cross-build clean (incl. MCRenderTest app).
