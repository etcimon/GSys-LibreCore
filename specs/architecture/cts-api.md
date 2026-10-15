# `api` — object lifetime, memory requirements, command buffers, copies, clears (327,795 cases)

Source: `specs/VK-GL-CTS` @ `f6a29701` (`vulkan-cts-1.4.6.2`); must-pass
`external/vulkancts/mustpass/main/vk-default/api.txt`; tests in
`external/vulkancts/modules/vulkan/api/vktApi*.cpp`. Owner W0/W2 (lifetime, memory,
command recording) with the Xfer engine (W4) for copies/blits/clears. Gates CTS-0
(`api.smoke`, `api.device_init`, `api.object_management.single`) and CTS-1 (the rest
of the core sub-groups).

## Inventory (rendered by `cts_ledger.py tree --group api --depth 3 --min-cases 100`)

| prefix (`dEQP-VK.`…) | cases |
|---|---:|
| `api` | 327795 |
| &nbsp;&nbsp;`api.buffer` | 3076 |
| &nbsp;&nbsp;&nbsp;&nbsp;`api.buffer.dedicated_alloc` | 511 |
| &nbsp;&nbsp;&nbsp;&nbsp;`api.buffer.suballocation` | 2555 |
| &nbsp;&nbsp;`api.buffer_marker` | 156 |
| &nbsp;&nbsp;`api.buffer_memory_requirements` | 240 |
| &nbsp;&nbsp;`api.buffer_view` | 1004 |
| &nbsp;&nbsp;&nbsp;&nbsp;`api.buffer_view.access` | 268 |
| &nbsp;&nbsp;&nbsp;&nbsp;`api.buffer_view.create` | 736 |
| &nbsp;&nbsp;`api.command_buffers` | 129 |
| &nbsp;&nbsp;`api.copy_and_blit` | 264602 |
| &nbsp;&nbsp;&nbsp;&nbsp;`api.copy_and_blit.copy_commands2` | 38737 |
| &nbsp;&nbsp;&nbsp;&nbsp;`api.copy_and_blit.copy_memory_indirect` | 1573 |
| &nbsp;&nbsp;&nbsp;&nbsp;`api.copy_and_blit.core` | 189789 |
| &nbsp;&nbsp;&nbsp;&nbsp;`api.copy_and_blit.dedicated_allocation` | 31313 |
| &nbsp;&nbsp;&nbsp;&nbsp;`api.copy_and_blit.device_address` | 918 |
| &nbsp;&nbsp;&nbsp;&nbsp;`api.copy_and_blit.multiplanar_xfer` | 2216 |
| &nbsp;&nbsp;`api.debug_utils` | 3 |
| &nbsp;&nbsp;`api.descriptor_pool` | 6 |
| &nbsp;&nbsp;`api.descriptor_set` | 6 |
| &nbsp;&nbsp;`api.device_address` | 6 |
| &nbsp;&nbsp;`api.device_drm_properties` | 1 |
| &nbsp;&nbsp;`api.device_init` | 234 |
| &nbsp;&nbsp;&nbsp;&nbsp;`api.device_init.create_device_unsupported_features` | 209 |
| &nbsp;&nbsp;`api.driver_properties` | 5 |
| &nbsp;&nbsp;`api.ds_color_copy` | 1320 |
| &nbsp;&nbsp;`api.extension_duplicates` | 4 |
| &nbsp;&nbsp;`api.external` | 549 |
| &nbsp;&nbsp;&nbsp;&nbsp;`api.external.memory` | 350 |
| &nbsp;&nbsp;&nbsp;&nbsp;`api.external.semaphore` | 108 |
| &nbsp;&nbsp;`api.fill_and_update_buffer` | 83 |
| &nbsp;&nbsp;`api.format_feature_flags2` | 184 |
| &nbsp;&nbsp;`api.fragment_shader_output` | 86 |
| &nbsp;&nbsp;`api.frame_boundary` | 19 |
| &nbsp;&nbsp;`api.get_device_proc_addr` | 1 |
| &nbsp;&nbsp;`api.get_memory_commitment` | 2 |
| &nbsp;&nbsp;`api.granularity` | 650 |
| &nbsp;&nbsp;`api.image_clearing` | 45636 |
| &nbsp;&nbsp;&nbsp;&nbsp;`api.image_clearing.core` | 22818 |
| &nbsp;&nbsp;&nbsp;&nbsp;`api.image_clearing.dedicated_allocation` | 22818 |
| &nbsp;&nbsp;`api.image_compression_control` | 920 |
| &nbsp;&nbsp;`api.info` | 8177 |
| &nbsp;&nbsp;&nbsp;&nbsp;`api.info.format_properties` | 225 |
| &nbsp;&nbsp;&nbsp;&nbsp;`api.info.get_physical_device_properties2` | 2206 |
| &nbsp;&nbsp;&nbsp;&nbsp;`api.info.image_format_properties` | 1186 |
| &nbsp;&nbsp;&nbsp;&nbsp;`api.info.image_format_properties2` | 1186 |
| &nbsp;&nbsp;&nbsp;&nbsp;`api.info.sparse_image_format_properties2` | 1110 |
| &nbsp;&nbsp;&nbsp;&nbsp;`api.info.unsupported_image_usage` | 2220 |
| &nbsp;&nbsp;`api.invariance` | 3 |
| &nbsp;&nbsp;`api.maintenance3_check` | 178 |
| &nbsp;&nbsp;`api.maintenance5` | 10 |
| &nbsp;&nbsp;`api.maintenance6_check` | 1 |
| &nbsp;&nbsp;`api.maintenance7` | 2 |
| &nbsp;&nbsp;`api.null_handle` | 24 |
| &nbsp;&nbsp;`api.object_management` | 457 |
| &nbsp;&nbsp;`api.performance_counters_by_region` | 1 |
| &nbsp;&nbsp;`api.pipeline` | 9 |
| &nbsp;&nbsp;`api.smoke` | 6 |
| &nbsp;&nbsp;`api.tooling_info` | 2 |
| &nbsp;&nbsp;`api.version_check` | 3 |
| **total** | 327795 |

`api.copy_and_blit.core` splits into `blit_image` 129,193 · `image_to_image` 52,692 ·
`use_after_copy` 2,340 · `image_to_buffer`/`buffer_to_image` families ≈ 4,000 ·
`depth_stencil_msaa_copy` 432 · `resolve_image` 240 · depth/stencil ↔ buffer 264 ·
`*_indirect` ≈ 1,000 (NV indirect copies) · the rest small. `api.object_management` has
eleven patterns × ≈ 44 object kinds: `single`, `single_alloc_callbacks`,
`multiple_{unique,shared}_resources`, `max_concurrent`, `multithreaded_*` (3),
`alloc_callback_fail(_multiple)`, `private_data`.

## Architectural logic

```text
LOGIC API-L1 · Device creation honours requested features exactly
  CLAIM       vkCreateDevice succeeds for any subset of the advertised features and
              fails with VK_ERROR_FEATURE_NOT_PRESENT when a requested feature is not
              advertised; queue creation respects the enumerated families and counts.
  SOURCE      dEQP-VK.api.device_init.* (create_device_*, create_instance_*,
              create_device_unsupported_features.* = one case per feature struct
              member); vktApiDeviceInitializationTests.cpp.
  MECHANISM   Venus forwards vkCreateDevice; vnfront ALLOC(DEVICE) validates the
              pEnabledFeatures / pNext feature structs against the profile's feature
              words (generated from vn_device_profile.toml) before minting the handle.
  REQUIRES    The decoder KEEPs every feature struct Venus can chain (Vulkan11/12/13/14
              Features and the per-extension structs we advertise); an unknown pNext is
              a decode refusal, not a silent accept.
  FORBIDS     Accepting unsupported features (a "no-op success" that lets a later shader
              fault as DEVICE_LOST); ignoring pNext feature structs.
  CHECK       cts0-info-smoke.txt (device_init.*); negative: unit vector that enables a
              false feature bit and expects FEATURE_NOT_PRESENT (vn_golden session).
  COST        decode table rows only.
  FEEDS       API-X1; every feature-gated file; CTS-0.
  STATUS      not-run

LOGIC API-L2 · Every object kind has a complete lifetime at scale
  CLAIM       Each Vulkan object kind can be created, used and destroyed singly, in
              groups sharing resources, concurrently from several threads, with host
              allocation callbacks, and up to the implementation's limit, without leaks
              or handle aliasing across lifetimes.
  SOURCE      dEQP-VK.api.object_management.{single,single_alloc_callbacks,
              multiple_unique_resources,multiple_shared_resources,max_concurrent,
              multithreaded_per_thread_device,multithreaded_per_thread_resources,
              multithreaded_shared_resources,alloc_callback_fail(_multiple),
              private_data}.<kind>; vktApiObjectManagementTests.cpp.
  MECHANISM   ObjTab (generation-bearing {gen,slot} handles, 256 slots, Fibonacci-hash
              directory), ObjPay for payload objects, vgpages for backed objects,
              ShaderCore slot manager (8 module/pipeline slots), cmdrec arena (16 CBs),
              vnpump per-context rings (threads share one device → one ring per Venus
              instance; per-thread devices → several contexts).
  REQUIRES    Residency virtualization (G3b): module/pipeline bytes, command-buffer
              records and descriptor storage live in device-private memory with on-chip
              slots as caches, so the limit on live objects is the arena, not a count.
              Generation wrap and slot recycling safe against ABA (W2.3).
              **Sizing from the source (vktApiObjectManagementTests.cpp @ f6a29701):**
              `max_concurrent` creates `min(hardCountLimit, platform-safe count)` objects
              *simultaneously* and any creation failure fails the test (no OOM tolerance
              in that pattern) — hard limits `DEFAULT_MAX_CONCURRENT_OBJECTS = 16 384`
              (buffers, buffer views, images, image views, samplers, shader modules,
              pipeline layouts, descriptor set layouts, render passes, graphics and
              compute pipelines, descriptor pools and sets, framebuffers, command pools
              and buffers, device memory), `MAX_CONCURRENT_QUERY_POOLS = 8192`,
              `MAX_CONCURRENT_PIPELINE_CACHES = 128`, `MAX_CONCURRENT_SYNC_PRIMITIVES =
              100`, `MAX_CONCURRENT_DEVICES/INSTANCES = 32`; the platform-safe count on
              the Linux platform divides the host memory budget by the per-object host
              allocation (small under Venus), so the hard limits are what we must meet.
              The multithreaded patterns create `getCreateCount<Object>() = 100` per
              thread (20 for devices/instances) across `numSlots = 100` slots. Therefore
              G3b's ObjTab/ObjPay/module/command-buffer storage must hold **≥ 16 384 live
              objects of each kind at once** — a DRAM-resident object table with an SRAM
              directory/cache, not a bigger flop or SRAM table (256 slots today).
  FORBIDS     Counting a truthful VK_ERROR_OUT_OF_HOST_MEMORY on the 17th command buffer
              as "working as designed" for this group (CTS-P2); special-casing the test's
              object counts.
  CHECK       api.object_management.single.* (CTS-0), then max_concurrent.* and the
              multithreaded_* patterns (CTS-1); engine vector ue_sm5_cbfull keeps the
              refusal path honest at the arena boundary.
  COST        The private arena and the slot caches size the device: hundreds of
              pipelines and command buffers per frame for UE/CS2 — the G3b design must
              be parameterized (ShaderSlots, CbBufs, ObjTab slots) and measured.
  FEEDS       API-X2, BINDING-MODEL-L*, PIPELINE-L*; CTS-1.
  STATUS      not-run

LOGIC API-L3 · Buffers, views and memory requirements are self-consistent
  CLAIM       vkCreateBuffer accepts every advertised usage/flag combination and size;
              vkGetBufferMemoryRequirements(2) reports size/alignment/memoryTypeBits
              consistent across calls (invariance), with dedicated allocation and
              suballocation both valid; buffer views over texel-buffer formats are
              creatable and readable/writable from shaders for the formats whose
              UNIFORM/STORAGE_TEXEL_BUFFER bits are required or advertised.
  SOURCE      dEQP-VK.api.buffer.*, api.buffer_memory_requirements.*, api.buffer_view.
              {create,access}.*, api.invariance.*, api.granularity.*,
              api.maintenance3_check.*, api.get_memory_commitment.*;
              vktApiBufferTests.cpp, vktApiBufferMemoryRequirementsTests.cpp,
              vktApiBufferView{Create,Access}Tests.cpp, vktApiGranularityTests.cpp.
  MECHANISM   vnfront ALLOC(BUFFER) + QUERY fills (size rounded to 256, align 256,
              typeBits 0b11 today); texel buffers need a BUFFER_VIEW object with
              {buffer, format, offset, range} and a shwave fetch path for OpTypeImage
              Dim=Buffer (OpImageFetch/OpImageRead/OpImageWrite on a view) — not
              implemented; the sampler's format decode is reusable.
  REQUIRES    Required texel-buffer formats of the spec's format table supported;
              minTexelBufferOffsetAlignment advertised and honoured.
  FORBIDS     Reporting UNIFORM_TEXEL_BUFFER bits without the fetch path.
  CHECK       api.buffer.*, api.buffer_memory_requirements.* (CTS-1); api.buffer_view.*
              once the texel-buffer path lands (card TEXELBUF-L1 in cts-image.md).
  COST        One more descriptor kind in the 32-byte record; the fetch reuses the
              texel cache. Granularity tests touch copy sizes only.
  FEEDS       cts-image.md TEXELBUF-L1; CTS-1.
  STATUS      not-run

LOGIC API-L4 · Command buffers: pools, levels, inheritance, state machine
  CLAIM       Primary and secondary command buffers follow the lifecycle state machine
              (initial/recording/executable/pending/invalid), pools reset/trim/free,
              secondaries execute inside primaries with inheritance (render pass
              continue, occlusion query inheritance), simultaneous-use and one-time
              flags are honoured, and indirect dispatch reads its arguments at any
              4-byte offset.
  SOURCE      dEQP-VK.api.command_buffers.* (allocate_*, execute_{small,large}_primary,
              executable_to_*, bad_inheritance_info_*, indirect_compute_dispatch_
              offsets_*, record/reset/trim/simultaneous families — 129 cases);
              vktApiCommandBuffersTests.cpp.
  MECHANISM   cmdrec (16×64 16-word records in tc_sram + payload arena) and cmdexec
              (state machine, submit FIFO); secondary command buffers need an EXECUTE
              record that nests another buffer's record range (one level) with inherited
              render-pass state; vkCmdDispatchIndirect needs a cmdexec operand fetch of
              the 3 words at buffer+offset (today refused UNSUPPORTED → DEVICE_LOST).
  REQUIRES    Record capacity for "large" primaries (thousands of commands) → G3b arena
              in device memory; the EXECUTE record resolves the secondary's {gen,slot}
              at submit time.
  FORBIDS     Executing a secondary by copying its records at record time (breaks
              re-record semantics); treating DispatchIndirect as a direct dispatch of
              cached arguments.
  CHECK       api.command_buffers.* (CTS-1); engine vectors: nested EXECUTE with
              inherited render pass; DispatchIndirect at offsets 0..28.
  COST        One record kind + one operand fetch; arena virtualization is the G3b
              cost.
  FEEDS       RENDERPASSES-L*, QUERY-POOL-L*, COMPUTE-L*; CTS-1.
  STATUS      not-run

LOGIC API-L5 · Copies, blits, resolves, clears, fills — all formats, aspects, dimensions
  CLAIM       vkCmdCopy{Buffer,Image,BufferToImage,ImageToBuffer}, vkCmdBlitImage
              (scaling, mirroring, nearest/linear, format conversion between compatible
              classes), vkCmdResolveImage, vkCmdClear{Color,DepthStencil}Image,
              vkCmdClearAttachments, vkCmdFillBuffer and vkCmdUpdateBuffer produce
              exactly the spec's results for every supported format, image type (1D/2D/
              3D/array/cube), mip level, aspect (colour, depth, stencil, separately and
              combined) and layout, including depth/stencil ↔ buffer and MSAA copies.
  SOURCE      dEQP-VK.api.copy_and_blit.core.* (189,789), .dedicated_allocation.*,
              .copy_commands2.* (1.3 entry points), api.image_clearing.*, api.fill_and_
              update_buffer.*, api.ds_color_copy.*; vktApiCopiesAndBlittingTests.cpp,
              vktApiImageClearingTests.cpp, vktApiFillBufferTests.cpp.
  MECHANISM   g6lc_apu_xfer: today buffer copies, same-bpp image copies, buffer↔image,
              colour clears through the checked DMA pair. Needed: a format-conversion
              blit datapath (decode→f32→encode through the sampler's format tables, box/
              bilinear scaling), 3D/array/cube addressing, depth/stencil aspects
              (D16/D24S8/D32/S8 packing), multisample resolve (average in linear space,
              per-sample layout), ClearAttachments inside a render pass (through rast's
              ROP path, respecting the render area and layers), and the copy_commands2
              structures (same semantics, new wire).
  REQUIRES    One device image layout for every format (5b) extended to depth/stencil
              and multisample; transfer granularity advertised = what Xfer implements;
              byte-exact results (copies) and spec-rounded conversions (blits).
  FORBIDS     Blitting through a sample-and-draw path that changes rounding; clearing
              outside the render area; "fast clears" that leave metadata the copy path
              does not understand (any such scheme must be resolved before any read).
  CHECK       api.copy_and_blit.core.{buffer_to_buffer,buffer_to_image,image_to_buffer,
              image_to_image}.* first, then blit_image.*, resolve_image.*,
              depth_stencil_msaa_copy.* as the formats land; api.image_clearing.core.*;
              api.fill_and_update_buffer.* (CTS-1/CTS-2).
  COST        The largest group by count and by bytes: blits/copies are bandwidth work —
              the Xfer engine's burst length, outstanding transactions and format
              decoders are the knobs (W5.1 apmem data path); 264 k cases at TCG speed
              also size the CTS fraction plan.
  FEEDS       IMAGE-L*, RENDERPASSES (ClearAttachments), FORMATS; CTS-1, CTS-2.
  STATUS      not-run

LOGIC API-L6 · Descriptor pools and sets at the API boundary
  CLAIM       Pools allocate up to maxSets/pool sizes, reset reclaims everything, FREE_
              DESCRIPTOR_SET pools free individual sets, over-allocation returns
              VK_ERROR_OUT_OF_POOL_MEMORY (or FRAGMENTED_POOL), and sets allocated from
              a pool are usable until the pool is reset/destroyed.
  SOURCE      dEQP-VK.api.descriptor_pool.*, api.descriptor_set.*;
              vktApiDescriptorPoolTests.cpp, vktApiDescriptorSetTests.cpp.
  MECHANISM   F5/3d-c: pools with real backing (ALLOC_PRIV), bump allocation, epoch on
              reset, RETIRE_KIDS; FREE_DESCRIPTOR_SET requires a real free (G3b: a free
              list or buddy allocator over the pool's records instead of a bump).
  REQUIRES    Pool capacity accounting per descriptor type, not only total bytes.
  FORBIDS     Treating vkFreeDescriptorSets as a no-op in a FREE_DESCRIPTOR_SET pool when
              the test re-allocates to capacity.
  CHECK       api.descriptor_pool.*, api.descriptor_set.* (CTS-1); cts-binding-model.md.
  COST        small; the allocator is control logic over the pool's record range.
  FEEDS       BINDING-MODEL-L1; CTS-1.
  STATUS      not-run

LOGIC API-L7 · Pipelines and render passes outlive each other correctly; pipeline cache
  CLAIM       A pipeline remains valid after the render pass / shader modules / pipeline
              layout used to create it are destroyed; a pipeline cache can be created,
              merged, queried (possibly empty data) and used for creation.
  SOURCE      dEQP-VK.api.pipeline.* (renderpass_destroyed_*, pipeline_cache_*);
              vktApiPipelineTests.cpp.
  MECHANISM   ObjTab parent/child references: the graphics pipeline holds REFs on its
              modules (G1c) — it must also snapshot the render pass compatibility class
              (attachment formats/samples) rather than referencing the pass; a
              PIPELINE_CACHE object with empty data (1.0-legal) until W3.5 adds a real,
              correctly keyed cache.
  REQUIRES    Pipeline state fully retained in ObjPay (W4.1).
  FORBIDS     Looking the render pass up at draw time; returning garbage cache data.
  CHECK       api.pipeline.* (CTS-1).
  COST        ObjPay words.
  FEEDS       PIPELINE-L*, RENDERPASSES-L*; CTS-1.
  STATUS      not-run

LOGIC API-L8 · Null handles, versions, driver properties, duplicates, proc addresses
  CLAIM       Destroy/free of VK_NULL_HANDLE is a no-op; apiVersion/driverVersion/
              conformance version and VK_KHR_driver_properties fields are consistent;
              duplicate extension names in enumeration are absent; vkGetDeviceProcAddr
              returns NULL for unknown/instance-level names.
  SOURCE      dEQP-VK.api.null_handle.*, api.version_check.*, api.driver_properties.*,
              api.extension_duplicates.*, api.get_device_proc_addr.*,
              api.maintenance3_check.* (maxPerSetDescriptors, maxMemoryAllocationSize).
  MECHANISM   Mostly Venus/loader; the renderer contributes the profile words
              (driverID/conformanceVersion must not claim a conformance that does not
              exist — leave conformanceVersion 0.0.0.0 until a submission is accepted).
  REQUIRES    Honest driver properties.
  FORBIDS     A non-zero conformance version before Khronos acceptance.
  CHECK       the cases above (CTS-1).
  COST        none.
  FEEDS       CTS-5.
  STATUS      not-run

LOGIC API-L9 · External memory handles that are advertised must round-trip
  CLAIM       For every handle type the device reports EXPORTABLE/IMPORTABLE, export
              produces a valid handle and import creates memory aliasing the same
              contents; dedicated-only requirements are honoured; unsupported types are
              reported as neither.
  SOURCE      dEQP-VK.api.external.memory.{opaque_fd,dma_buf,...}.*,
              api.external.semaphore.*, api.external.fence.*; vktApiExternalMemoryTests.cpp.
  MECHANISM   §12.1 F9: KHR_external_memory_fd advertised as EXPORTABLE|IMPORTABLE for
              OPAQUE_FD, yet imports are refused (INVALID_EXTERNAL_HANDLE). Import of our
              own export is, in the Venus model, a RESOURCE import of a blob we already
              own — implementable as "second memory object over the same aperture
              pages" (refcounted pages, same backing, independent lifetime).
  REQUIRES    Decision at CTS-1 from the failure list: implement import (pages refcount)
              or report EXPORTABLE only. External fences/semaphores stay unadvertised
              until W2.4 implements them.
  FORBIDS     Reporting IMPORTABLE while refusing import (the current state is a CTS-P1
              violation); exporting a handle that is not the same memory.
  CHECK       api.external.memory.opaque_fd.*; negative: import of a foreign fd → error.
  COST        page refcounts in vgpages (small).
  FEEDS       MEMORY-L*, WSI (dma-buf); CTS-1.
  STATUS      not-run (known-red by design; see API-X4)
```

## Exceptions

```text
EXCEPTION API-X1 · Unsupported feature requested at device creation
  CONDITION   pEnabledFeatures / a pNext feature struct enables a feature the profile
              does not advertise.
  RESULT      VK_ERROR_FEATURE_NOT_PRESENT.
  TRUTH       The refusal is the mechanism's absence, not a policy; the 209
              create_device_unsupported_features cases enumerate exactly the bits we
              leave 0 in vn_device_profile.toml.
  MECHANISM   vnfront ALLOC(DEVICE) feature check (API-L1).
  CHECK       api.device_init.create_device_unsupported_features.*
  FORBIDS     Advertising the feature to make the case NotSupported.

EXCEPTION API-X2 · Exhaustion of device-private storage
  CONDITION   More live objects than the private arena / slot caches can hold.
  RESULT      VK_ERROR_OUT_OF_DEVICE_MEMORY (or OUT_OF_HOST_MEMORY for command buffers)
              from the creating call; never a later DEVICE_LOST.
  TRUTH       Spec-legal only when the arena is genuinely full; the CTS's max_concurrent
              pattern expects implementations to reach practical counts — a limit far
              below desktop practice is a correctness-grade architecture gap (CTS-P2),
              which is why G3b precedes CTS-1.
  MECHANISM   ObjTab FULL, vgpages FULL, cmdrec arena FULL, shcore slots FULL → the
              mapped VkResult in vnfront (the Venus async path hides the error from the
              application — that is Mesa's behaviour, not ours to fix).
  CHECK       ue_sm5_cbfull, ue_cneg_evict_full_1, ue_cneg_bind_full_1 (engine);
              api.object_management.max_concurrent.* (CTS-1).
  FORBIDS     Silently reusing a live slot; waiving max_concurrent.
  OBSERVED    CTS-0: `create_multiple_devices.basic` (5 devices) → OUT_OF_HOST_MEMORY on
              queueWaitIdle → the CTS **aborts the whole session** on a ResourceError —
              an exhaustion result is not "spec-legal and harmless" in the CTS: it ends
              the run. Contexts/devices ≥ 32 and allocation counts ≥ 4096 are therefore
              preconditions of CTS-1, not polish.

EXCEPTION API-X3 · NotSupported by truthful absence (api sub-groups)
  CONDITION   Tests of extensions/versions we do not advertise at 1.1:
              buffer_marker (AMD), copy_memory_indirect / *_indirect copies (NV),
              frame_boundary (EXT), image_compression_control (EXT),
              device_drm_properties (EXT), performance_counters_by_region (KHR
              performance_query), debug_utils (instance EXT, guest-side), private_data
              and tooling_info (1.3 core → required when we advertise 1.3),
              maintenance5/6/7, format_feature_flags2 and copy_commands2 (1.3 core →
              required at 1.3), device_address (1.2 core), multiplanar_xfer and
              sampler_ycbcr (KHR_sampler_ycbcr_conversion), external semaphore/fence,
              sparse buffers (sparseBinding), protected memory, transfer-only /
              compute-only queue families (`*_transfer_queue`, `*_compute_queue`
              variants are NotSupported when only one universal family exists).
  RESULT      NotSupported.
  TRUTH       Each absence is a profile line; the version-ladder items flip to required
              when apiVersion advances (INFO-L2) and are then LOGIC cards.
  MECHANISM   Profile ROM + Venus allow-list.
  CHECK       The ledger's not-supported column per sub-group; a rise in `fail` after a
              version bump identifies the newly required set.
  FORBIDS     Keeping 1.1 forever to avoid them; dropping a 1.0 required capability.

EXCEPTION API-X4 · External memory import advertised but refused (current state)
  CONDITION   api.external.memory.opaque_fd.* import cases on today's profile.
  RESULT      Fail (expected) — recorded, not waived.
  TRUTH       The IMPORTABLE bit was set to satisfy Mesa's vn_physical_device
              requirement (§12.1 F9); the honest fix is API-L9's choice.
  MECHANISM   vnfront vkAllocateMemory pNext policy.
  CHECK       CTS-1 run of api.external.*.
  FORBIDS     A waiver; leaving IMPORTABLE set after CTS-1 without the mechanism.
```

## Implementation-order heuristics (ordinal)

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| API-H1 Lifetime before features | `object_management.max_concurrent` fails on slot counts | precondition for CTS-1 | G3b: arena-backed modules/pipelines/CBs/descriptor storage with parameterized slot caches | the failure is the guest's allocator (RT-H1: compare with the llvmpipe control) |
| API-H2 Copies by byte class | first copy_and_blit failures | high | land same-class copies for all formats/aspects before any blit conversion | a conversion blit is needed by a render-pass resolve test first (then do resolve) |
| API-H3 Secondary CBs + DispatchIndirect | command_buffers fails | high | one EXECUTE record kind; one 3-word operand fetch | — |
| API-H4 Texel buffers | buffer_view.access fails | medium | BUFFER_VIEW descriptor kind + Dim=Buffer fetch reusing the texel cache | the required texel-buffer format list is not yet in the profile (do that first) |
| API-H5 External import decision | api.external red at CTS-1 | medium | pick refcounted-page import or EXPORTABLE-only from the failure text | Mesa's requirement contradicts EXPORTABLE-only (then import) |

## Segment card (current)

```text
SEGMENT CTS-0/api
  QUESTION        Which api sub-groups already pass on the G3a-i RTL, and which fail for
                  which mechanism class (lifetime, copies, command buffers, profile)?
  OBJECTIVE       Classified outcomes of api.smoke.*, api.device_init.*,
                  api.object_management.single.* (CTS-0); the CTS-1 caselist chosen from
                  the result.
  ENVELOPE        as cts-info.md.
  INPUTS          caselist cts0-info-smoke.txt; RTL ab296cfda.
  CONTRACT        single.* must pass for every object kind we can create at all; the
                  smoke triangles must match the reference images (api.smoke.triangle,
                  asm_triangle); create_sampler/create_shader are pure object paths.
  OBSERVATIONS    Run `cts0-2026-10-14`: api 15 run of 287 selected — 10 Pass
                  (device_init.create_instance_*, create_device.basic, …), 4 Fail
                  (`smoke.triangle`, `smoke.asm_triangle`, `smoke.asm_triangle_no_opname`,
                  `smoke.unused_resolve_attachment`: "Image comparison failed: allowed
                  position deviation (1,1,0), color threshold (0,0,0,0)"), 1
                  ResourceError (`device_init.create_multiple_devices.basic`:
                  `queueWaitIdle → VK_ERROR_OUT_OF_HOST_MEMORY` with NUM_DEVICES = 5),
                  which **aborted the session** — 272 cases (object_management.single.*,
                  the rest of device_init) never ran.
  HYPOTHESES      H1 refuted: the smoke triangles differ from the CTS reference under an
                  exact-colour / 1-pixel-shift compare although vkcmp scene 0 matched
                  llvmpipe at maxdiff 0 → the delta is in what the smoke tests do that
                  scene 0 does not (clear-then-draw into R8G8B8A8, the reference
                  rasterizer's rounding of the UNORM encode, edge rule at the shared
                  edge, the unused-resolve attachment path) — image diff pending.
                  H3 (new): the device-count abort is the context/ring count (≥ 5
                  concurrent VkDevices → per-device Venus rings/contexts) and the
                  64-allocation count — a limit, not a leak.
  DISCRIMINATOR   smoke: rerun the four cases with `--deqp-log-images=enable` (dev run,
                  not submission-shaped) and diff result vs reference per pixel; devices:
                  the ring/context counter at the fifth vkCreateDevice.
  RESULT          (2026-10-15) The image diff refuted every H1 mechanism: the result
                  image was the **clear colour everywhere** (x 64..191, y 64..190 differ
                  = the whole triangle), not an edge or encode delta. Cause: the CTS
                  `makeGraphicsPipeline` bakes a **static** `pViewportState` (populated
                  `pViewports`/`pScissors`, no `VK_DYNAMIC_STATE_*`), while the device
                  honoured only the streamed `vkCmdSetViewport/Scissor` shadows — every
                  self-authored `vkcmp` scene used dynamic viewport, so the gap was
                  invisible to the own oracle (RT-H6: a favourable proxy). Fix: the
                  pipeline create parses `pViewportState` (ARRAY keep now stages the
                  element count so a NULL `pViewports` is distinguishable from dynamic),
                  bakes `VkViewport`/`VkRect2D` into pipeline ObjPay w34..43 with
                  `w25[17:16]` static flags, and the draw assembly overrides the shadows
                  from the record (`cmdexec` StDrPayCpl). Vector `ue_gpos_statvp_1`
                  (vgsys + sys-venus) is the smoke-shaped counterexample. Post-fix dev run
                  (`.cache/cts/smokeimg-statvp2/`): `smoke.triangle`, `asm_triangle` **Pass**.
                  Session-abort stays first for `api`: contexts/devices and the allocation
                  counts (G3b, API-L2/API-X2).
  LIMITS          one guest; 15 of 287 api cases observed; the two remaining smoke
                  cases (`asm_triangle_no_opname`, `unused_resolve_attachment`) re-run
                  in CTS-1, not yet observed post-fix.
  NEXT ARTIFACT   ledger row `api` re-rendered from a post-fix run; G3b-i (§5a
                  implementation decisions) for the device-count abort.
```

## Performance / area / scalability

- **Bytes**: `copy_and_blit` and `image_clearing` are DMA work. Knobs: Xfer burst length
  and outstanding transactions (today 1 read + 1 write beat), apmem data path (W5.1),
  `DramChannels`. Correctness-preserving: any coalescing/reordering of copy beats must
  keep the spec's overlap rules (`use_after_copy`) and the per-region write-after-check
  discipline (a refused region writes nothing).
- **Objects**: `object_management` and the per-frame UE/CS2 pattern are bounded by the
  private arena and the slot caches. Knobs after G3b: arena bytes, `ShaderSlots`,
  `CbBufs`, ObjTab slots/directory size, descriptor pool page granularity. Measure the
  live-object histogram of real workloads (W1.5 counters) before fixing geometry.
- **Latency**: object creation is control-plane work on the ring; `multithreaded_*` is
  the first measurement of ring contention across contexts (vnpump park/resume).
