# Limits ledger — every `VkPhysicalDeviceLimits` field the CTS found below the minimum (CTS-0, 2026-10-14)

Source of the findings: `dEQP-VK.info.device_properties` in run `cts0-2026-10-14`
(`.cache/apu-guest/out-cts0-r3/cts-TestResults.qpa`), 39 validations against the
Vulkan 1.0/1.1 minima (`vktApiFeatureInfo.cpp` `validateLimits`). Rule (CTS-P1): a value is
raised in `vn_device_profile.toml` only together with the mechanism that makes it true and a
check that would fail if it were not; "profile-only" below means the mechanism already
exists and the TOML simply under-reports it — each still needs its verification vector
before the edit. Minima are the 1.0 table unless noted; 1.4 minima are listed where they
differ because the release profile must meet them.

| limit | actual | min (1.0/1.1) | 1.4 min | mechanism / owner | class |
|---|---:|---:|---:|---|---|
| `maxImageDimension1D` | 0 | 4096 | 4096 | 1D views (G3d, TEX-L1/IMG-L1) | mechanism |
| `maxImageDimension3D` | 0 | 256 | 256 | 3D layouts + sampling (G3d) | mechanism |
| `maxImageDimensionCube` | 0 | 4096 | 4096 | cube layouts + seamless sampling (G3d) | mechanism |
| `maxTexelBufferElements` | 0 | 65536 | 65536 | texel buffers (API-L3 / TEXELBUF) | mechanism |
| `maxStorageBufferRange` | 16 MiB | 128 MiB | 128 MiB | LSU record size/address width (W3) — likely profile-only once the record `size` field width is confirmed ≥ 2²⁷ | verify |
| `maxMemoryAllocationCount` | 64 | 4096 | 4096 | ObjTab-V (§5a, G3b) | mechanism |
| `maxSamplerAllocationCount` | 64 | 4000 | 4000 | ObjTab-V (G3b) | mechanism |
| `bufferImageGranularity` | 0 | ≥ 1 (power of two, ≤ 131072) | same | profile-only: report the real granularity (page 4096 or 1) | profile-only |
| `maxPerStageDescriptorInputAttachments` | 0 | 4 | 4 | input attachments (RP-L2) | mechanism |
| `maxPerStageResources` | 16 | 128 | 128 | binding rows / records (BM-X2, G3b) | mechanism |
| `maxDescriptorSetSamplers` | 16 | 96 | 96 | descriptor pool/records (G3b) | mechanism |
| `maxDescriptorSetUniformBuffers` | 16 | 72 | 72 | G3b | mechanism |
| `maxDescriptorSetSampledImages` | 16 | 96 | 96 | G3b | mechanism |
| `maxDescriptorSetInputAttachments` | 0 | 4 | 4 | RP-L2 | mechanism |
| `maxVertexInputAttributes` | 8 | 16 | 16 | rast attribute gather (DRAW-L1, G3c) | mechanism |
| `maxVertexInputBindings` | 4 | 16 | 16 | DRAW-L1 (G3c) | mechanism |
| `maxVertexOutputComponents` | 32 | 64 | 64 | VS-out record (8 varying slots = 32 comps) → record stride parameter (W4.1/CLIP-L2) | mechanism |
| `maxFragmentInputComponents` | 32 | 64 | 64 | same record | mechanism |
| `maxFragmentCombinedOutputResources` | 0 | 4 | 16 | profile-only: colour attachments + storage buffers/images per FS already ≥ 4 | profile-only (verify) |
| `maxComputeWorkGroupCount[0..2]` | 0 | 65535 | 65535 | cmdexec dispatch count field width — profile-only if the fields are ≥ 16 bits (they carry the 32-bit Venus words; verify the wave scheduler's counters) | verify |
| `maxComputeWorkGroupInvocations` | 64 | 128 | 256 | `MaxWaves`/lanes per workgroup (COMPUTE-H3, W3.3 RF banking) | mechanism |
| `maxComputeWorkGroupSize[0]/[1]` | 64 | 128 | 256 | same | mechanism |
| `minTexelBufferOffsetAlignment` | 0 | ≤ 256 (power of two ≥ 1) | same | profile-only with texel buffers (16 or 256) | profile-only |
| `minTexelOffset` / `maxTexelOffset` | 0 / 0 | ≤ −8 / ≥ 7 | same | ConstOffset in the sampler (G3a-ii gather offsets, G3d) — mechanism then profile | mechanism |
| `framebufferColorSampleCounts` | 1 | 1\|4 | 1\|4 | MSAA 4× (RAST-L4/PIPE-L4, G3c) | mechanism |
| `framebufferDepthSampleCounts` | 0 | 1\|4 | 1\|4 | profile-only for `1` now (depth attachments exist), `4` with MSAA | split |
| `framebufferStencilSampleCounts` | 0 | 1\|4 | 1\|4 | stencil (PIPE-L2) then MSAA | mechanism |
| `framebufferNoAttachmentsSampleCounts` | 0 | 1\|4 | 1\|4 | no-attachment render passes (RP-L1: a pass with zero attachments must rasterize for side effects) — verify, then profile `1`; `4` with MSAA | verify |
| `sampledImageColorSampleCounts` | 0 | 1 | 1 | profile-only (`1`: single-sample images are sampled today) | profile-only |
| `sampledImageIntegerSampleCounts` | 0 | 1 | 1 | profile-only (`1`) once integer formats are sampled (format table) | verify |
| `sampledImageDepthSampleCounts` | 0 | 1 | 1 | profile `1` with G3a-ii's D16/D32 sampling | profile-only (after G3a-ii) |
| `sampledImageStencilSampleCounts` | 0 | 1 | 1 | stencil sampling (PIPE-L2/IMG-L4) | mechanism |
| `storageImageSampleCounts` | 0 | 1 | 1 | profile-only (`1`: storage images exist) | profile-only |
| `maxSampleMaskWords` | 0 | 1 | 1 | SampleMask builtin (slot 8 word 2 is already reserved) — verify the FS path writes/reads it, then `1` | verify |
| `discreteQueuePriorities` | 0 | 2 | 2 | profile-only (one queue; priorities are accepted at device creation — verify the decoder KEEPs `pQueuePriorities`) | profile-only (verify) |

Not flagged by the CTS at 1.1 but owed by the plan/Zink/UE pins (`cts-binding-model.md`
BM-X2, `cts-compute.md`): `maxBoundDescriptorSets` 4 → 7 (1.4 min; UE RT wants ≥ 9),
`maxPushConstantsSize` 128 → 256 (1.4), `maxPerStageDescriptorSamplers/UniformBuffers/
StorageBuffers/SampledImages/StorageImages` (16/12/4/16/4 minima — ours are 16-row tables,
verify each), `maxColorAttachments` ≥ 4 (ours is 4 — at the floor; 8 is desktop
practice), `maxViewports` 1 → 16 with `multiViewport` (Zink GL 4.1), `maxFramebufferLayers`
1 → 256 (multiview/layered, MV-L1), `maxImageArrayLayers` ≥ 256, `maxSamplerAnisotropy`,
`timestampPeriod` (audit finding; QP-L2), `maxDrawIndirectCount` (advertised 1 but
unexecuted — DRAW-L1).

Procedure per row: (1) the mechanism card lands (or the verify step proves the existing
mechanism covers the minimum with a vector that exercises the maximum value), (2) the TOML
value changes in the same commit, (3) `info.device_properties` and the row's CTS family are
rerun, (4) the row's `class` becomes `done <run tag>`.
