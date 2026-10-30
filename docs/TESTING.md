# MetalCompat — TESTING (v0.2.0 minimum)

Implementing SPEC §12 as far as this environment allows. The critical honesty
rule is enforced: **simulator/host results never substitute physical-device
validation.**

## 1. Device matrix (SPEC §12.1)

| Family | SoC | Physical validation | Notes |
|---|---|---|---|
| Apple3 | A9, A10 | **PENDING** | primary target; no hardware accessible in the current session |
| Apple4 (A11) … Apple7 (A14/M1) | — | PENDING | planned matrix |
| Apple8+ | — | PENDING | secondary |
| Mac2 (Intel) | host iMac20,1 (Intel UHD 630) | **TESTED (host)** | macOS 15.7.7, Xcode 26.3 / iOS SDK 26.2 |

Environment recorded 2026-10-30: macOS 15.7.7 (24G720); Xcode 26.3 (17C529);
iOS SDK 26.2; Metal toolchain 32023.864; cmake 4.4.3; ninja; Apple clang 17.

## 2. Test inventory (current)

### 2.1 Unit (CPU-only, run: `build/tests/MC_UnitTests`)
- JSON parser: valid/invalid, duplicate keys, escapes, trailing content (hermetic).
- Registry validation positive/negative families:
  duplicate ids, out-of-vocabulary state/category, schema version,
  missing verification on non-UNKNOWN records (SPEC 10.8),
  primary-target invariant (Apple3 must map A9+A10),
  Metal4 floor must be 26.0 (D-008 pinned in validator).
- Planner decision table (hermetic synthetic registry + synthetic A9-class caps):
  native paths, OS-floor refusals (iOS 16/18/26 features), hardware-gate
  refusals (Apple7-only, unverified tessellation gate), UNKNOWN refusals,
  exactly-at-floor acceptance (MSL 2.3 on iOS 14.0).
- Capability mapping (family indices/names), diagnostics ring behavior.
- **47 checks — all passing on host (2026-10-30).**

### 2.2 Integration (GPU, run: `ctest`)
- `render_vertical_slice`: BasicRender binary as a ctest test — creating a
  pipeline + deterministic offscreen frame on the runtime's actual GPU.
  **Passes on Mac2 (Intel UHD 630) with a 100% texel match.**

### 2.3 Registry/tool gate
- `MC_RegistryValidator` validates both JSON files + invariants; wired to be
  re-runnable in CI (`cmake --build build --target MC_RegistryValidator`).

## 3. Rendering correctness strategy (SPEC §12.4)

- Deterministic frame: solid-interior-color triangle (interpolation-precision
  independent), clear-color exterior.
- CPU-side geometric coverage per texel center; pass criterion ≥97% match;
  deep-interior/exterior probe texels must match within 0.01.
- Reference stored as PPM3 (`vertical_slice.ppm` next to the binary).
- Precision tolerance: ±0.02 float (±5/255) pixel-wide, ±0.01 at probes.

## 4. Pending physical-device tests (A9 gate to M3)

Required before any Apple-family claim is PHYSICAL-VALIDATED:

1. `supportsFamily(MTLGPUFamilyApple3)` returns YES on A9 + iOS 14 runtime.
2. Capability report limits (buffer/threads/tiers) recorded from the device.
3. Deterministic frame render test on-device (shared storage path).
4. MTL4 refusal path verified on-device (`mtl4.queue` → UnavailableOs).
5. R-1 (tessellation gate) and R-3 (argument tier) probes against the registry.

No simulator run is accepted as evidence for these items.
