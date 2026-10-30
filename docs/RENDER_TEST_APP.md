# MCRenderTest — On-device Metal smoke-test app

Self-contained iOS app that runs the **real Metal render/compute battery**
through the MetalCompat LegacyMetal backend directly on an iPhone's GPU and
answers one question: *do the compat ops behave there as they did on the host?*

## What it tests (auto-runs at launch)

| Block | Content |
|-------|---------|
| `[D]` | Device probe: name, OS, Apple families, argument-buffer tier, R/W texture tier, threadgroup limits |
| `[B]` | M4 buffers: host roundtrip, GPU→GPU copy exact, samplers |
| `[T]` | M4 texture: staged upload/download roundtrip, byte-exact |
| `[C]` | M4 compute: `vec_add` MSL 2.3 compile + dispatch, results exact |
| `[F]` | M4.5: 3 frames reusing the same staging buffers (bounded reuse) |
| `[L]` | M5 layer selection: **native** `renderTargetArrayLength` vs **per-slice fallback** vs CPU reference, each slice byte-compared (tolerance ±1); on pre-Apple5 the native path is expected to be refused (rc=6) and the fallback carries the session |
| `[A]` | M7 tier-1 argument buffers prototype: classic == tier-1 outputs |
| `[S]` | Summary: `checks=N failures=M wall=Xms` |

## Reading the results on the phone

* The full log streams **on screen** while running (scrollable, `[PASS]`/`[FAIL]` markers).
* The **Share Log** button writes/shares `Documents/MC_TEST_LOG.txt`
  (`UIFileSharingEnabled` → also reachable via Files > On My iPhone > MCRenderTest,
  and in Finder under device > Files).
* Every line also goes through `NSLog` — connect in **Console.app** and filter
  `MC-LOG` to see results live from the Mac.
* **Rerun** button re-runs the whole session in-process.

## Building the .ipa (needs your Apple ID once)

The app *compiles* fine unsigned, but installing needs a **development team**
(free personal Apple ID is enough; profiles expire after 7 days and are
refreshed by re-running the script).

One-time setup: open **Xcode > Settings > Accounts > Add Apple ID**.

Then:

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
