# MetalCompat — PERFORMANCE (v0.2.0 baseline record)

SPEC §6.4/§12.5 policy: identical workloads for MetalCompat vs direct native
baseline; median and tails once sample sizes justify them. Until M8, this file
records the slice numbers as raw, clearly-labelled observations.

## 1. Vertical slice timings (host, 2026-10-30)

| Metric | Value | Notes |
|---|---|---|
| CPU encode (render pass incl. buffer staging decision) | ≈197–220 µs | `mach_absolute_time` window around encoder open/close; single run, not a distribution |
| GPU execution (MTLCommandBuffer GPUStartTime→GPUEndTime) | 0.000 ms | returned delta 0 on macOS 15.7 host — **treated as UNVERIFIED instrumentation**, not as "zero GPU cost" |
| Deterministic frame verification | 100% of 4096 texels | one-time test readback only |

Limitations (recorded by policy, not hidden):

1. Host GPU is an Intel iGPU (Mac2 family) on a discrete-less iMac20,1 — numbers
   here are NOT meaningful for Apple-family performance planning.
2. GPU^-timestamp instrumentation is not yet trusted; M8 will adopt
   `MTLCounter*`-based sampling only after the counters API has a verified
   registry row.
3. No comparisons to a "direct native" version have been run yet (M8 milestone).

## 2. Planned acceptance pairs (M8)

For each workload family and hardware class:

- CPU encoding time, submission time, GPU execution time,
- end-to-end producer→consumer latency,
- frame-time p50/p95/p99, memory high-water,
- buffer/pipeline allocation counts and bytes copied,
- CB/pass/dispatch counts; cache hit rates;
- fallback-vs-native delta.

Report format: median + tails + run count + thermal state; single best runs are
never reported as representative.

## M8 update (2026-10-30) — harness + first host numbers

Harness: `tests/Performance/PerfHarness` (manual run; not in ctest because
timings are not hermetic). Use cases:

- compute ceiling      : 1M-element vec_add, 20 dispatches timed after 5 warmups
- layer selection      : 512x512 RGBA, 4 slices — the native single pass
                         (renderTargetArrayLength) vs the per-slice fallback
                         (4 sequential passes), each overlap-tested 50 frames

Host numbers (Intel i3-10105 iGPU, Mac2, Tier-1 argument buffers, macOS 15.7.7):

```
PERF compute 1M-add  per-dispatch 2.380 ms
PERF layered-native    1 pass, 4 slices, 512x512  2.008 ms/frame
PERF layered-fallback  4 passes, 4 slices, 512x512  2.535 ms/frame
```

Reading: on a Tier-1-class modern-ish device the fallback costs ~+26% here
(4 passes vs 1, uniform-hook per pass). On A9 (Apple3, reach) the native path
is documented as unsupported ("Apple5+ or any macOS-family GPU"); the ACTUAL
A9 delta is intentionally PENDING until the physical session — the harness
printout is the instrument (one command line, no inference).

Physical-device work remains REQUIRED per SPEC M8 (device session doc).
