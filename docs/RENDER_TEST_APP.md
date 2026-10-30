# MCRenderTest — On-device Metal smoke-test app

Self-contained iOS app that runs the **real Metal render/compute battery**
through the MetalCompat LegacyMetal backend directly on an iPhone's GPU and
answers one question: *do the compat ops behave there as they did on the host?*

Since v1.3 the app also shows a **live ray-traced scene** streaming to the
screen — real Metal ray tracing against real BLAS/TLAS acceleration
structures, not a placeholder: see `[RT-VIEW]` below.

## What it tests (auto-runs at launch)

| Block | Content |
|-------|---------|
| `[D]` | Device probe: name, OS, Apple families, argument-buffer tier, R/W texture tier, threadgroup limits |
| `[B]` | M4 buffers: host roundtrip, GPU→GPU copy exact, samplers |
| `[T]` | M4 texture: staged upload/download roundtrip, byte-exact |
| `[C]` | M4 compute: `vec_add` MSL 2.3 compile + dispatch, results exact |
| `[F]` | M4.5: 3 frames reusing the same staging buffers (bounded reuse) |
| `[L]` | M5 layer selection: **native** `renderTargetArrayLength` vs **per-slice fallback** vs CPU reference, each slice byte-compared (tolerance ±1); on pre-Apple5 the native path is expected to be refused (rc=6) and the fallback carries the session |
| `[R]` | Metal ray tracing probe: MSL 2.4 `metal::raytracing::intersector` + BLAS/TLAS build + 32-ray exact query (t=2.5) — on non-RT hardware the kernel must be a compile REFUSAL |
| `[A]` | M7 tier-1 argument buffers prototype: classic == tier-1 outputs |
| `[S]` | Summary: `checks=N failures=M wall=Xms` |

## [RT-VIEW] — the live ray-traced viewport (v1.3)

The screen is split: the top ~44 % plays a **real-time ray-traced scene**
through a `CAMetalLayer`; the bottom half keeps the streaming test log.

* **Scene**: checkerboard floor, chrome/mirror sphere, red diffuse sphere,
  blue glossy sphere (glossy = reflective), emissive lamp sphere.
* **Lighting (real, ray-traced)**: two point lights, one orbiting —
  *real shadow rays* (`intersector` `accept_any_intersection`) so shadows
  **move**, Whitted-style **mirror/glossy reflections** (up to 2 bounces),
  Reinhard tonemap + gamma in the copy pass.
* **Pipeline** (follows Apple's official sample *Accelerating ray tracing
  using Metal* — BLAS/TLAS via `accelerationStructureCommandEncoder`,
  compute → `RGBA32Float` private texture → fullscreen-quad copy with
  tonemap → drawable, CADisplayLink 30 fps, 3 frames in flight):
  * `rt_shade` MSL 2.4 kernel — Whitted camera rays → closest-hit shading →
    shadow rays → reflected rays into the 5-object scene (2114 triangles:
    1 floor quad + 4 parametric lat-long spheres).
* **Support gate** (logged + shown in the viewport):
  * `Apple6+` (A13 = iPhone 11 or later): Metal RT **API** — runs **software**
    ray tracing (no dedicated ray units).
  * `Apple9` (A17 Pro / M3 / M4): **hardware-accelerated** ray tracing.
  * `Apple4` (A11, iPhone 8 Plus etc.): NO ray tracing at all — the viewport
    shows an explanatory overlay and the session stays in log view.
* Log lines: `[RT-VIEW] start/alive: frame=N fps≈XX WxH` plus PASS/FAIL
  checks counted into the `[S]` summary, so a broken viewport fails the
  session, not just the log.

## Reading the results on the phone

* The full log streams **on screen** while running (scrollable, `[PASS]`/`[FAIL]` markers).
* The **Share Log** button writes/shares `Documents/MC_TEST_LOG.txt`
  (`UIFileSharingEnabled` → also reachable via Files > On My iPhone > MCRenderTest,
  and in Finder under device > Files).
* Every line also goes through `NSLog` — connect in **Console.app** and filter
  `MC-LOG` to see results live from the Mac.
* **Rerun** button re-runs the whole session in-process.

## Building the .ipa

### TrollStore route (DEFAULT, no signing, no Apple ID)

The repo packed an **unsigned** ipa ready for TrollStore (TrollStore manages the
signature on-device):

```
scripts/build_ipa_unsigned.sh
```

Output: `build-ios-ipa/MCRenderTest.ipa` (Payload/MCRenderTest.app, arm64,
MinimumOSVersion 14.0, `UIFileSharingEnabled`). Move it to the phone (AirDrop,
iTunes File Sharing, iCloud, ...) and install from the TrollStore share sheet.

### Signed-development route (alternative)

Needs a signed-in Apple ID in **Xcode > Settings > Accounts** (a free personal
team is fine; profiles expire after 7 days and are refreshed by re-running):

```
scripts/build_ios_ipa.sh                 # auto-detects the team from Xcode
# or explicitly:
MC_IOS_DEV_TEAM=<teamid> scripts/build_ios_ipa.sh
```

Produces `build-ios-ipa/MCRenderTest.ipa`.

## Installing + running

Plug the iPhone in and run:

```
scripts/install_ios_device.sh [device-udid]
```

(udid optional; picks the first paired, connected iPhone. List devices with
`xcrun devicectl list devices`.) The script installs and launches the app.

### Xcode-GUI route (equivalent)

`cmake -S . -B build-ios-xcode` already generates
`build-ios-xcode/MetalCompat.xcodeproj` with an **MCRenderTest** target
(Automatic signing). Open it, pick the *MCRenderTest* scheme, set your Team in
Signing & Capabilities, select the iPhone, and press Run.

## Notes

* The built bundle lives at `build-ios-xcode/apps/Debug-iphoneos/MCRenderTest.app`
  (unsigned until xcodebuild signs during archive).
* The app is wired to the same MCP-approved op surface as the test suite:
  `mcops_*`, `render_layered.h`, `arg_table_t1.h`, `Shader.hpp` variants —
  no test-framework imports, so it remains a faithful end-user runtime probe.
* DEVICE_TEST_SESSION plan (docs/DEVICE_TEST_SESSION.md): use this app for the
  `[L]`/`[A]` legs on non-mac devices; it prints everything a session's
  runbook needs, including the hardware gate's verdict.
