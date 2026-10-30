# MetalCompat — Compatibility Strategy (v0.2.0)

Concrete application of SPEC §7 to the features handled so far, plus the rules
for everything that comes later.

## 1. State vocabulary (SPEC §7.1 — exactly these)

`NATIVE | FALLBACK | EMULATED | APPROXIMATED | PARTIAL | UNSUPPORTED | UNKNOWN`

Current mapping policy for the whole codebase:

| State | Meaning here | Allowed to become |
|---|---|---|
| NATIVE | direct `MTL*` call, iOS-14-era API | (no change needed) |
| FALLBACK | another legacy `MTL*` op with same observable contract | only with semantic-difference list = ∅ and tests |
| EMULATED | CPU/GPU software algorithm | only with the §2 record table complete |
| APPROXIMATED | documented relaxed contract accepted by caller | only with explicit flag at call site |
| PARTIAL | subset shipped, subset documented | grows over milestones |
| UNSUPPORTED | typed error, no silent no-op | may flip to FALLBACK/EMULATED with evidence |
| UNKNOWN | unverified | must resolve to a final state before shipping |

## 2. Per-feature strategy — current inventory state

| Feature (registry id) | State on iOS 14 / A9 today | Notes |
|---|---|---|
| `cmd.buffer`, `cmd.queue`, `cmd.event`, `cmd.fence`, `cmd.indirectBuffer` | NATIVE | verified OS availability; runtime device check on first use |
| `pipe.render`, `pipe.compute`, `pipe.depthStencil`, `res.*` | NATIVE | same |
| `pipe.tessellationFactor` | PARTIAL | API exists iOS 10+; hardware gate UNKNOWN on A9 → planner refuses (typed error) until probed |
| `pipe.mesh` (legacy mesh) | UNKNOWN | SDK 26.2 carries no legacy mesh headers; research (R-2) before any claim |
| `res.acceleration` | UNSUPPORTED (planned) | iOS 14 OS-level availability but hardware expects Apple7; planner to gate on runtime `supportsFamily(Apple7)` → on A9 returns UNSUPPORTED (pending runtime proof) |
| `mtl4.*` (all) | UNSUPPORTED | OS floor iOS 26 (SDK 26.2 macros); D-008 forbids MTL4-on-A9 claims |
| `dev.residencySet` | UNSUPPORTED | iOS 18.0+ OS floor |
| `MetalFX`, `MPP*` (frameworks) | UNSUPPORTED (iOS 14 target) | M7 may study approximations; never advertised "fully compatible" |

## 3. Metal 4 rule (SPEC §7.3 enforced)

- All `MTL4*` symbols are compile-gated `API_AVAILABLE(ios(26.0))`; code paths
  additionally check `device supportsFamily: MTLGPUFamilyMetal4`.
- The legacy backend does not wrap `MTL4CommandQueue` as `MTLCommandQueue`
  (distinct types, distinct semantics). Any feature record that only has a
  Metal4 implementation reports UNSUPPORTED on the legacy backend rather than
  pretending equivalence.
- `MTL4CommandAllocator`, `MTL4ArgumentTable`, `MTL4Compiler*` are separate
  concepts in the registry, not aliased to legacy counterparts.

## 4. Translation & emulation rules (SPEC §8.3 / §5.2.2)

When a candidate FALLBACK/EMULATED feature enters scope (M5/M7), implementation
must include, **before code**:

1. reference behavior definition (observable contract);
2. mapping table: input contract → output contract, with the gap list;
3. overhead budget (CPU + GPU + memory), measured on target hardware class;
4. test set incl. hazard cases; 5. fallback acceptance criteria.

Shader transformation policy: typed parser/AST or offline variant generation
only — no regex rewriting of arbitrary source (hard prohibition §14.3).

## 5. Caller contract (SPEC §1.3)

- Integration is source-level: callers build against `include/MetalCompat`
  headers and call explicit APIs; no system-framework interception, no
  prebuilt-binary compatibility claims.
- Registered behaviors never include private APIs or undocumented driver
  behavior (SPEC §10.7).

## 6. Immediate roadmap enforced by this strategy

1. Resolve R-1..R-6 unknowns with runtime probes (needs hardware access).
2. Keep UNKNOWN/PARTIAL/UNSUPPORTED visible in every report — the capability
   report prints current states (`examples/CapabilityReport`), the validator
   fails the build on fabricated verification blocks.
3. Next compatibility features enter via the §4 record pipeline only.

## 7. Planner fallback catalog (M5 pattern, 2026-10-30)

The registry records WHAT each feature is (state + documented mapping); the
engine decides HOW to execute it. Two mechanisms, both honest by construction:

1. **Machine gate tokens** (record.pipeline `hardwareGate`):
   `[gateApple5orMac2]` resolves at runtime from the cached DeviceCaps only
   (Apple5+ family or macOS platform with Mac2+ family). A token is validated
   cross-file (`validateFeatureGatesCrossFile`): the record's gate text must
   contain the declared token verbatim and every listed native family must be
   documented in `gpu_capabilities.json.families`.

2. **Provisioned fallback catalog** (`PlannerConfig.provisionedFallbackIds`):
   a PARTIAL record with a documented fallback strategy only reaches
   `PlanOp::FallbackTranslation` when the fallback MODULE is shipped, tested
   and explicitly listed (engine knowledge, not registry data — SPEC D-006).
   When it is missing the planner refuses with InsufficientHardware. The
   first catalog entry is `render.layered` →
   `src/Backends/LegacyMetal/render_layered.mm` per-slice passes.

Contract examples (unit-tested):

- A9 (Apple3, iOS): `render.layered` + provisioned → FallbackTranslation;
  without provisioning → refusal. Mac device (macOS/Mac2) → Native.
- `res.acceleration` (Apple7-only record, no fallback): stays refused on
  Apple6-class hardware even when the catalog contains other features.
