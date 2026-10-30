# MetalCompat — API Inventory (extract)

> Structured public API inventory, v0.2.0. Machine-readable source of truth:
> `registry/metal_api_registry.json` (validated by `tools/APIRegistryValidator`).
> Verification basis: **iOS SDK 26.2 headers + Apple doc pages, 2026-10-30** (see RESEARCH §8).
> Availability = OS/SDK availability. Hardware = separate runtime dimension
> (SPEC D-005). `UNKNOWN` entries are deliberate and must stay until verified.

Registry record fields (JSON schema enforced by the validator):
`id, symbol, category, framework, requiredOs, osAvailability, hardwareRequirement,
runtimeGate, compatibilityState, fallbackStrategy, notes, verified (sdk, date),
references[]`.

## A. Inventory summary (extract of notable entries)

### A.1 Device / capability

| ID | Symbol | OS availability | Hardware requirement | State (A9/iOS14 target) |
|---|---|---|---|---|
| dev.supportsFamily | `-[MTLDevice supportsFamily:]` | iOS 13.0+ | family-specific runtime | NATIVE (iOS14 OK) |
| dev.gpuFamilyEnum | `MTLGPUFamily` (Apple1..Apple10) | iOS 13.0+ era | — | NATIVE (ios14 OK) |
| dev.maxBufferLength | `maxBufferLength` | iOS 12.0+ | per-device | NATIVE (ios14 OK) |
| dev.maxThreadgroupMemoryLength | `maxThreadgroupMemoryLength` | iOS 11.0+ | per-device | NATIVE (ios14 OK) |
| dev.argumentBuffersTier | `argumentBuffersSupport` | iOS 11.0+ | tier varies | NATIVE (query, value UNKNOWN per-device) |
| dev.rwTextureTier | `MTLReadWriteTextureTier` (None/1/2) | iOS 11-era | tier per family | PARTIAL (value UNKNOWN on A9) |
| dev.recommendedMaxWorkingSetSize | `recommendedMaxWorkingSetSize` | iOS 10+ era | per-device | NATIVE (query) |
| dev.residencySet | `MTLResidencySet` | **iOS 18.0+** | — | UNSUPPORTED on iOS 14 baseline (OS gate) |

### A.2 Command architecture

| ID | Symbol | OS availability | State (A9/iOS14) |
|---|---|---|---|
| cmd.queue | `MTLCommandQueue` | iOS 8.0-era | NATIVE |
| cmd.buffer | `MTLCommandBuffer` | iOS 8.0-era | NATIVE |
| cmd.encoders | `MTLRenderCommandEncoder`, `MTLComputeCommandEncoder`, `MTLBlitCommandEncoder` | iOS 8.0-era | NATIVE |
| cmd.indirectBuffer | `newIndirectCommandBufferWithDescriptor:` | iOS 12.0+ | NATIVE (runtime-verify device support) |
| cmd.event | `MTLEvent` | iOS 12.0+ | NATIVE |
| cmd.fence | `MTLFence` | iOS 10.0+ | NATIVE |
| mtl4.queue | `MTL4CommandQueue` | **iOS 26.0+** | UNSUPPORTED on A9/iOS14 (OS + family gate) |
| mtl4.compiler | `MTL4Compiler` | **iOS 26.0+** | UNSUPPORTED on A9/iOS14 |
| mtl4.commandBuffer | `MTL4CommandBuffer` | **iOS 26.0+** | UNSUPPORTED on A9/iOS14 |
| mtl4.argumentTable | `MTL4ArgumentTable` | **iOS 26.0+** | UNSUPPORTED on A9/iOS14 |
| mtl4.pipelineState | `MTL4RenderPipeline` etc. | **iOS 26.0+** | UNSUPPORTED on A9/iOS14 |
| mtl4.meshPipeline | `MTL4MeshRenderPipeline` | **iOS 26.0+** | UNSUPPORTED on A9/iOS14 |
| mtl4.mlEncoder | `MTL4MachineLearningCommandEncoder` | **iOS 26.0+** | UNSUPPORTED on A9/iOS14 |

Note: every MTL4 entry is tagged `requiredOs: iOS 26` from the SDK 26.2
availability macros (RESEARCH §3). They remain in the registry because the
copy-architecture matters for future native-backend routing, not for the iOS 14 target.

### A.3 Pipelines, resources, synchronization

| ID | Symbol | OS availability | State (A9/iOS14) |
|---|---|---|---|
| pipe.render | `MTLRenderPipelineState` + `MTLRenderPipelineDescriptor` | iOS 8.0-era | NATIVE |
| pipe.compute | `MTLComputePipelineState` + descriptor | iOS 8.0-era | NATIVE |
| pipe.depthStencil | `MTLDepthStencilState` + descriptor | iOS 8.0-era | NATIVE |
| pipe.tessellationFactor | `setTessellationFactorBuffer`, `MTLTessellationFactorFormat` | iOS 10.0+ | PARTIAL — hardware gate UNKNOWN on A9 (R-1) |
| pipe.mesh (legacy) | legacy mesh render pipeline | question-marked in SDK 26.2 | UNKNOWN (R-2) |
| res.buffer | `MTLBuffer` (`newBufferWithLength:` etc.) | iOS 8.0-era | NATIVE |
| res.heap | `newHeapWithDescriptor:` | iOS 10.0+ | NATIVE (runtime-verify Apple3 behavior) |
| res.noCopyBuffer | `newBufferWithBytesNoCopy:length:options:deallocator:` | iOS-era long-standing | NATIVE (alignment constraints at runtime) |
| res.acceleration | `MTLAccelerationStructure`, `newAccelerationStructureWithDescriptor:` | **iOS 14.0+** (macOS 11.0+) | RT hardware (Apple7 per docs) — A9 expected UNSUPPORTED, pending runtime probe |
| sync.event | `MTLEvent` | iOS 12.0+ | NATIVE |
| sync.fence | `MTLFence` | iOS 10.0+ | NATIVE |
| sync.dispatchBarrierStyle | header-defined per-command barrier styles (SDK 26.2) | newer OS | PARTIAL/UNKNOWN on iOS 14 — map to fences/events per M5 design |

### A.4 Related frameworks (tracked, not merged)

| Framework | OS availability (SDK 26.2 evidence) | Notes |
|---|---|---|
| MetalKit | iOS 9.0+ | optional; views/models — never required by core |
| MetalFX | iOS 16.0+ (MTLFX*), iOS 26.0+ (MTL4FX*, FrameInterpolator) | not in iOS 14 baseline; potential M7 approximation target |
| MetalPerformanceShaders | iOS 9+ | distinct framework (SPEC §7.4) |
| MetalPerformanceShadersGraph | iOS 13+ | distinct framework |
| MetalPerformancePrimitives | iOS 26-era (new SDK generation) | distinct framework |

## B. Full registry

The complete machine-readable inventory lives in `registry/metal_api_registry.json`.
Keep this document as a human-readable extract; regenerate summaries from the JSON
when the registry changes (validator tool prints a summary).
