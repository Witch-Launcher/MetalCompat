# MetalCompat

A modular compatibility runtime and SDK that maximizes the usable subset of modern,
publicly documented Metal functionality on legacy Apple GPUs, starting with
**Apple A9 (MTLGPUFamilyApple3)**.

MetalCompat is a **source-integrated compatibility SDK/runtime** — not a driver, not a
replacement for Apple's `Metal.framework`, and not a hardware or ISA emulator.
See `SPEC.md` and `docs/` for the full contract, architecture, and honesty rules.

## Current status (M0/M1 mid-point)

| Milestone | Status |
|---|---|
| M0 Research + capability inventory | `docs/RESEARCH.md`, `docs/API_INVENTORY.md`, `docs/GPU_CAPABILITY_MATRIX.md`, `registry/*.json` — built from SDK 26.2 header evidence; unknowns explicitly marked |
| M1 Project foundation | C++20 core, registry loader/validator, capability engine, error model, unit tests — buildable |
| M2–M3 Device/vertical slice | Objective-C++ Metal bridge + deterministic render vertical slice — implemented, **host-tested only (Intel macOS GPU)** |
| Physical A9 validation | **PENDING** — no A9 hardware available in this environment; never inferred from simulator/host |

## Requirements

- Apple platform, Xcode 14+ (verified: Xcode 26.3, iOS SDK 26.2)
- CMake >= 3.24, Ninja, Apple Clang (C++20)

## Build (macOS host)

```sh
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build
ctest --test-dir build
# registry validation
./build/tools/APIRegistryValidator/RegistryValidator registry/metal_api_registry.json registry/gpu_capabilities.json
# capability report on the host
./build/examples/CapabilityReport/MC_CapabilityReport
# deterministic render vertical slice
./build/examples/BasicRender/MC_BasicRender
```

## Build (iOS compile-check, no device required)

```sh
cmake -S . -B build-ios -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build build-ios
```

This proves the iOS 14 deployment baseline compiles; it does **not** replace
on-device A9 testing (see `docs/TESTING.md`).

## Repository layout

```text
include/MetalCompat/   public C++ headers
src/                   core, capability, registry, planner, backends
registry/              machine-readable API + GPU capability registry (JSON)
tools/                 APIRegistryValidator
tests/                 Unit + Rendering (GPU integration)
examples/              CapabilityReport, BasicRender (vertical slice)
docs/                  research, architecture, runtimes, status
```

## Honesty rules

Features are labelled `NATIVE`, `FALLBACK`, `EMULATED`, `APPROXIMATED`, `PARTIAL`,
`UNSUPPORTED`, or `UNKNOWN`. An unverified idea is never a claimed capability.
