# MetalCompat — GPU Runtime (v0.2.0)

Implements SPEC §5: real Metal workloads on the real Apple GPU. Nothing here
invents hardware; every kernel and pass must be expressible in public MSL/`MTL*`.

## 1. Implemented now (vertical slice)

- Native compute+render execution path (SPEC D-002): the backend encodes into
  `MTLRenderCommandEncoder` directly; no IR on that path.
- Deterministic offscreen frame: 256×256 RGBA8 unorm texture, triangle drawn
  from an inline MSL vertex/fragment function, `clearColor`-based background,
  blit readback for verification, PPM output written once (test path only —
  SPEC hot path forbids routine GPU→CPU copies).
- GPU timing captured via `MTLCommandBuffer.GPUStartTime/GPUEndTime`
  (`docs/PERFORMANCE.md` recording the same numbers).

## 2. Emulation kernels — policy and status

**None implemented yet.** Per SPEC §5.2.2 + D-007, an emulation kernel requires a
documented record before implementation:

| Field | Where stored |
|---|---|
| algorithm / math behavior | registry record `notes` + `docs/COMPATIBILITY_STRATEGY.md` |
| formats in/out | registry record |
| precision/tolerance | test data in `tests/Rendering/` |
| synchronization needs | planner contract in `CommandPlan.hpp` |
| scratch/pass budget | registry `notes` (validated before M6) |
| target-family perf numbers | `docs/PERFORMANCE.md` per row, measured on hardware |

No emulation candidate has a validated record yet, so the planner may only emit
`NATIVE`, `FALLBACK` (later), or `UNSUPPORTED` today. `EMULATED`/`APPROXIMATED`
decisions are unreachable until §2 records exist (deliberate).

## 3. Resource strategy (SPEC §5.2.3, implemented portion)

- Only storage modes needed for the slice are used: private texture + shared
  staging buffer for the one-time test readback (storage-mode combos gated by
  runtime capability query, never by name-based guesses).
- No resource duplication, no pooled temporaries yet (M4 timeframe with
  lifetime tracking + frames-in-flight tests).
- Alignment: buffer/texel alignment asserted through `MTLDevice` limits at
  creation (properties verified available in RESEARCH §4).

## 4. Shader handling (SPEC §5.2.4 / §8)

- The vertical slice compiles MSL from a fixed literal once at startup and
  retains the `MTLLibrary`; hot-path pipeline creation reuses it (no
  recompilation per frame).
- No automated MSL transformation of any kind yet. The future rule set
  (typed parser → variants, no regex — SPEC §8.3) is documented in
  `COMPATIBILITY_STRATEGY.md` and will land with M6 only if a concrete feature
  record requires transformation; the slice uses only trivially-compatible MSL.

## 5. Synchronization (SPEC §5.2.5)

- Slice: single command buffer, single queue, one `commit`. Dependency model
  trivial; `MTLEvent`/`MTLFence` recorded as the narrow primitives for M4+.
- The future dependency model (producer/consumer edges in `CommandPlan`) maps
  to: pass ordering + `MTLFence` for render-GPU / `MTLEvent` for buffer-level
  GPU sync — chosen per record; never barrier-removal for performance alone
  (D-007).

## 6. Hot-path rules in force (SPEC §5.3)

- No intermediate textures beyond the single frame target.
- No CPU→GPU upload per frame (one-time vertex/constant staging).
- No dispatches beyond the one render pass.
- No invented occupancy tuning: threadgroup sizes taken from
  `maxThreadsPerThreadgroup` and the pipeline's own limits, only for tests.
