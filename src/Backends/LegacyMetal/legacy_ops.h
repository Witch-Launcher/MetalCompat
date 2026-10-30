// LegacyMetal ops — M4 core: buffers/textures/sampler/compute + bounded
// lifetime. All symbols verified in the current SDK headers (docs/RESEARCH.md).
// Every op is self-contained (device → queue → CB → commit → wait) so tests are
// deterministic; batching is a later, measured M8 concern (SPEC §6.2).
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum MCOpStorageKind : int {
    MCOP_STORAGE_AUTO = 0, ///< Shared on unified-memory devices, Managed otherwise
    MCOP_STORAGE_PRIVATE = 1,
};

typedef struct MCOpBuffer {
    void* handle;   ///< id<MTLBuffer>
    uint64_t length;
    void* cpuAddress; ///< valid for host-visible buffers only (else null)
} MCOpBuffer;

/// 0 on success. AUTO storage picks the platform-correct host-visible mode.
int mcops_newBuffer(void* device, uint64_t lengthBytes, int storage,
                    MCOpBuffer* out) noexcept;
void mcops_freeBuffer(MCOpBuffer* b) noexcept;
/// Host-visible write (+ didModifyRange sync hint on managed macOS buffers).
int mcops_writeBufferHost(MCOpBuffer* b, const void* data, uint64_t len) noexcept;
/// Host-visible read (valid after completion of ops that wrote it).
int mcops_readBufferHost(const MCOpBuffer* b, void* outData, uint64_t len) noexcept;

/// GPU buffer→buffer copy through its own command buffer (blit encoder).
int mcops_copyBuffer(void* device, uint64_t srcOffset, uint64_t dstOffset,
                     void* srcBufferHandle, void* dstBufferHandle,
                     uint64_t lengthBytes) noexcept;

enum MCOpTextureFormat : int { MCOP_TEX_RGBA8_UNORM = 0, MCOP_TEX_R32_UINT = 1 };

/// Private render/compute target (upload/download goes through blit staging).
int mcops_newTexture(void* device, uint32_t w, uint32_t h, int format,
                     void** outTexHandle) noexcept;
void mcops_freeTexture(void* texHandle) noexcept;
/// Staged upload: staging buffer contents → texture (blit copyFromBuffer:toTexture:).
int mcops_uploadTexture(void* device, const MCOpBuffer* staging,
                        void* texHandle, uint32_t w, uint32_t h,
                        uint64_t bytesPerRow) noexcept;
/// Staged download: texture → staging buffer contents (blit copyFromTexture:toBuffer:).
int mcops_downloadTexture(void* device, void* texHandle, uint32_t w, uint32_t h,
                          uint64_t bytesPerRow, const MCOpBuffer* staging) noexcept;

/// Sampler creation (nearest=0, linear=1). Public API since iOS 8-era.
int mcops_newSampler(void* device, int linear, void** outSamplerHandle) noexcept;
void mcops_freeSampler(void* samplerHandle) noexcept;

/// Runtime MSL strings → MTLLibrary (language version auto-floored per OS).
int mcops_compileLibrary(void* device, const char* mslSource,
                         void** outLibraryHandle) noexcept;
void mcops_freeLibrary(void* libraryHandle) noexcept;

/// Compute pipeline from a compiled library.
int mcops_newComputePipeline(void* device, const void* libraryHandle,
                             const char* functionName,
                             void** outPipelineHandle) noexcept;
void mcops_freeComputePipeline(void* pipelineHandle) noexcept;

/// 1-D thread grid: gridCount threads, threadgroupCount threads per group.
/// GPU buffer→buffer copies use the same narrow primitive (blit) for staging.
int mcops_dispatchCompute(void* device, const void* pipelineHandle,
                          uint32_t gridCount, uint32_t threadgroupCount,
                          const void* const* bufferHandles, uint32_t bufferCount) noexcept;

#ifdef __cplusplus
} // extern "C"
#endif
