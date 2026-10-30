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
