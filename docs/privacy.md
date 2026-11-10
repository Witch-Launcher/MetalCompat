# MetalCompat — Privacy Policy

MetalCompat is a modular compatibility runtime and SDK that maximizes usable Metal functionality on legacy Apple GPUs (starting with Apple A9). It is MIT licensed.

## Data we collect

**None.** MetalCompat is a source-integrated compatibility SDK/runtime. It does not collect, store, or transmit any personal data. No analytics, no telemetry, no advertising, no user profiling.

## Local-only operation

MetalCompat runs entirely on the host device:

- Validates and plans Metal API usage against a local capability registry
- Executes rendering through Apple's Metal framework locally
- Emulates unsupported features (software BVH raytracer, sparse fallbacks) locally

No data leaves the device unless your application explicitly sends it.

## Logs

Diagnostic logs may be written via an opt-in diagnostics ring buffer. They are local only and never uploaded by the library.

## Children

MetalCompat collects no data from anyone, including children.

## Your rights

Because no data is collected, there is nothing to access, export or delete on our side. All rendering state lives in your application's process.

## Contact

Open an issue on the [MetalCompat GitHub repository](https://github.com/Witch-Launcher/MetalCompat).
