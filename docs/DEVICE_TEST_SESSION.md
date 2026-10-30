# Device Test Session — A10/A11 (Apple3/Apple4 validation)

> Goal: turn the Apple3-family row (A9 shares this family with A10) from
> `PENDING`/`UNKNOWN` into **physical-validated** evidence, and start the
> Apple4 row. An A10 session physically validates the *family*; the separate
> A9-silicon device column stays PENDING until an A9 handset is available.

## 0. Requirements

- iPhone 7/8/X (A10/A11) running iOS 14.x or 15.x (both above the 14 baseline —
  record the exact OS version per run).
- Mac host: this repo, Xcode 26.3.
- Apple Developer account for device signing.

## 1. Prepare (done once)

```sh
cmake -S . -B build-ios-xcode -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
open build-ios-xcode/MetalCompat.xcodeproj
```

In Xcode: select each app target (MC_CapabilityReport, MC_BasicRender) →
Signing & Capabilities → check "Automatically manage signing" + your team.

## 2. Run per device (repeat for each phone)

1. Plug the phone, choose it as the run destination.
2. Select target **MC_CapabilityReport** → Run (Release for signed install also
   works with CODE_MARKETING or Development config as Xcode decides).
3. Copy the **full console output** into a file:
   `docs/testlogs/<deviceModel>_<iOSVersion>_capability.txt`.
4. Same for **MC_BasicRender** (`..._basicrender.txt`).

## 3. What we must record (per SPEC 12.1)

| Item | Where it comes from |
|---|---|
| Device model + OS build | `Settings > General > About` (+ console header line from the app) |
| SoC/GPU family evidence | app line `families: ...` (expect `Apple3,...` on A10) |
| Capability limits | app lines for maxBufferLength, threadgroups, tiers |
| Test date | filename + commit hash note |
| Result + logs | the two txt files above |

## 4. Expected console landmarks (A10, iOS 14/15)

```text
families          : Apple1,Apple2,Apple3,Common1,Common2,Common3   ← must include Apple3
metal4 (family 5002) : no
PLAN mtl4.queue   -> REFUSED UnavailableOs ...                     ← D-008 enforced on hardware
PLAN pipe.render  -> Native ...                                    ← legacy slice usable
[BASICRENDER] deterministic frame matches reference (≥97% gate)     ← M3 gate on-device
```

If any landmark differs → STOP, open an issue, do not patch the registry by
hand (change protocol §0).

## 5. After the session (agent's job, on receiving logs)

1. Update `docs/TESTING.md` device matrix: Apple3 row → `physical-validated via
   A10 (iPhone 7, iOS <ver>, date, logs)`.
2. Fill `registry/gpu_capabilities.json` `deviceMatrix.validatedPhysical`.
3. Resolve open questions that the logs answer:
   R-1 (tessellation gate — needs a follow-up tessellation probe run),
   R-3 (argumentBuffersTier value),
   R-4 (MSL version actually accepted — the BasicRender compile result shows it).
4. Re-run registry validator + unit tests; commit with the logs.

## 6. Session 2 (later, after family rows are in)

- Tessellation probe (R-1): small app creating a tessellation render pipeline
  on A10 — resolves the Apple3 hardware gate row.
- A9 handset whenever available: same two apps; moves the A9 silicon column.
