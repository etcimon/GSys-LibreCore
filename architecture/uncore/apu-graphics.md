# Graphics lane — structure and current state

## Current consolidation snapshot (2026-10-01)

This review supersedes historical ownership labels and the old single-scene-only
scope below; it does not promote any fixture result to device qualification.
Three lazy, clean, locally initialized sparse references now guide the design:

| Reference | Pin |
|---|---|
| `specs/UnrealEngine` — UE 5.8.3 | `396c9f059903aed5fec78ecd3d437a40c6415368` |
| `g6lc_qemu/linux-dist/ubuntu/kernel` — `Ubuntu-7.0.0-27.27` | `01543ba213ac86680193399096806a6e265e1cdf` |
| `g6lc_qemu/linux-dist/ubuntu/kernel-noble` — `Ubuntu-6.8.0-90.91` | `28e5daf6ca5bdc7104d1d5877c7113e578c94e9e` |

Normal submodule update skips these references (`update = none`, `shallow = true`).
No upstream source, license, build dependency or runtime driver was modified.
Ubuntu source/setup details live in `g6lc_qemu/linux-dist/ubuntu/README.md`.
The six-boundary source inventory and missing dataflow edges are in
`corev_apu/apu/AGENTS-impl-interplays.md` §15. It is a bounded source review, not
a completed audit of all leaf families or fresh simulation evidence.

### Versioned compatibility matrix — source floor, not runtime qualification

UE paths below are relative to `specs/UnrealEngine/Engine`; kernel paths are
relative to each pinned Ubuntu kernel tree. All device/runtime exits are OPEN.

| Area | Source observation | Required device/runtime exit |
|---|---|---|
| SM5 startup floor | `Source/ThirdParty/Vulkan/profiles/VP_UE_desktop_vulkan.json`: Vulkan 1.1.0, `fragmentStoresAndAtomics`, at least four bound descriptor sets | Truthful Vulkan 1.1 semantics and unchanged profile checks, not a sparse advertised subset. |
| Startup admission / loader | `Source/Runtime/VulkanRHI/Private/{VulkanRHI,VulkanGenericPlatform}.cpp` and `Linux/VulkanLinuxPlatform.cpp`: profile checks, `libvulkan.so.1`, bundled fallback | Record actual loader/ICD/package origins; no SkipVulkanProfileCheck, custom ICD, preload or library-path substitution. |
| Queues, formats, memory, pipelines | `VulkanDevice.cpp`, `VulkanTexture.cpp`, `VulkanShaders.cpp`, `VulkanSubmission.cpp`: queried capabilities and real object/submission lifetimes | Enumerate the selected project's feature/format/shader union. Implement graphics/compute, allocation, descriptor/storage access, ordering and exhaustion; the startup JSON is not this workload manifest. |
| Presentation | `Linux/VulkanLinuxPlatform.cpp`, `VulkanSwapChain.cpp`: SDL/X11/Wayland and queue surface support | Qualify offscreen output separately from visible resize/present and steady-state resource reuse; HDMI leaf results do not prove WSI. |
| CPU/platform scope | `Source/Programs/UnrealBuildTool/Platform/Linux/UEBuildLinux.cs`: x86-64 and ARM64 targets | x86-64 Ubuntu first. Native RISC-V Unreal is a separate unresolved CPU-target issue. |
| Stock virtio parameters | Both `drivers/gpu/drm/virtio/virtgpu_ioctl.c:96–115` expose 3D/blob/host-visible/context-init/capset IDs; CAPSET_QUERY_FIX is driver-provided | Verify actual negotiated features and valid capset structures. An opcode-count list or custom firmware protocol is insufficient. |
| Host-visible mapping | Both `virtgpu_kms.c` obtain the shared region; `virtgpu_vram.c` allocates aperture offsets and issues map commands. `drivers/virtio/virtio_mmio.c` implements SHM discovery | APU MMIO currently returns all-ones SHM length/base (`g6lc_apu_virtio_mmio.sv:202–203`), interpreted as absent region. Implement real mapping/lifetime/cache semantics before claiming this Venus path. This is source-level analysis, not a boot test. |
| Hardware transport | Current SoC has diagnostic virtio-mmio, not a qualified PC GPU endpoint | x86 physical use needs a proven stock-compatible transport, e.g. modern virtio-pci with BAR/MSI-X/DMA/reset; RISC-V MMIO remains independent. |
| SM6/RT and CS2 | UE has separate, substantially broader profiles; CS2 uses Source 2 | Independent later gates, never inferred from SM5 or GLES2. |

Target an unmodified packaged UE 5.8.3 SM5 raster project on stock Ubuntu 26.04.1,
then repeat on 24.04 with independent manifests. No clean image, installed kernel
configuration, Mesa/libdrm/loader package pin, packaged-project shader inventory,
CTS result or application execution was established by these source checkouts.
Required/optional/no-op/refused behavior must be classified against that actual
workload before capability advertisement; no unsupported operation may succeed
as a fabricated no-op.

**Engine structure (2026-10-03):** `apu-vulkan-engine.md` is the design of record for
the hardware-Venus route — generated vn_protocol decoder, `tc_sram` object table,
recorded command buffers, direct-SPIR-V SIMT shader core with a graphics-owned
MatHelper port onto the AI dot PEs, tile-based raster. The per-command leaf
paragraphs below (from `g6lc_apu_vnenc` onward) are a catalog census of fixed-shape
diagnostics; they are retained as wire-fact/vector sources, not as the engine.

The preferred feasibility candidate is stock virtio-gpu/Mesa Venus with hardware
protocol/object/shader semantics. It is NOT proven. Custom service/compiler
firmware remains a diagnostic/legacy lane, not compliance with the final
no-custom-runtime constraint. No CPU/host-GPU renderer, frozen shader or expected
color recognizer can supply acceptance pixels. The bounded SPIR-V-subset
prototype (`g6lc_apu_spirv`, `SpirvEn`) is that experiment: immutable 128-word
store, data-dependent add/mul, ApuOff quiet, diagnostic bytes+IRQ TB client.
It is not a Venus frontend and is not wired into `g6lc_apu_sys`. The reusable
NEXT walker (`g6lc_apu_chain`, `ChainEn`) takes a programmed table base and
head. `g6lc_apu_cdma` / `CdmaEn` joins that walker to checked DmaRead.
`ShmEn` publishes virtio-mmio SHM id 1; `g6lc_apu_hvis` / `HvisEn` maps a
HOST_VISIBLE blob and Venus `context_init`. `g6lc_apu_vncs` / `VncsEn`
runs CREATE_MODULE/DISPATCH on that ring through SpirvSubset.
`g6lc_apu_vcap` / `VcapEn` answers GET_CAPSET for Venus id 4.
`g6lc_apu_vnring` / `VnringEn` walks Mesa `vn_ring_layout`.
`g6lc_apu_tdma` / `TdmaEn` joins compositor DMA onto testharness
`slave[2]` under `G6LC_APU`. `g6lc_apu_vnenc` / `VnencEn` decodes
Mesa `vn_protocol` `vkCreateShaderModule`. `g6lc_apu_vnp` / `VnpEn`
feeds that CS from a `vn_ring` buffer into SpirvSubset.
`g6lc_apu_avn` / `AvnEn` reads `virtq_avail` and follows NEXT through
NextChain. `g6lc_apu_avu` / `AvuEn` publishes `virtq_used` elem then
`used.idx`. `g6lc_apu_uir` / `UirEn` raises virtio used-buffer ISR
after that store. `g6lc_apu_cms` / `CmsEn` snapshots the first
payload window so guest mutation does not change it. `g6lc_apu_prs` /
`PrsEn` stores a programmed WRITE-window response. `g6lc_apu_qdn` /
`QdnEn` publishes response, `used.idx`, and ISR after one walk.
`g6lc_apu_gcs` / `GcsEn` grants Venus GET_CAPSET/INFO on that
WRITE window; `NumCapsets` stays 0. `g6lc_apu_vnd` / `VndEn`
decodes Mesa `vn_protocol` `vkCmdDispatch`. `g6lc_apu_gnh` /
`GnhEn` is an eight-slot generational handle table with pin/retire.
`g6lc_apu_hdp` / `HdpEn` looks up that published CMDBUF handle on
`vkCmdDispatch`. `g6lc_apu_hph` / `HphEn` publishes a MODULE handle
from `vkCreateShaderModule` and looks up CMDBUF on dispatch.
`g6lc_apu_hrn` / `HrnEn` commits that SPIR-V and kicks SpirvSubset
on a live CMDBUF. `g6lc_apu_rdn` / `RdnEn` writes that result, then
`used.idx` and ISR. `g6lc_apu_qrn` / `QrnEn` walks AvailNext and
fetches that CS into RunDone. `g6lc_apu_qcm` / `QcmEn` muxes
GrantCapset and QueueRun on one request. `g6lc_apu_qty` / `QtyEn`
peeks the first command word and selects that path. `g6lc_apu_vct` /
`VctEn` is a private control face: `num_capsets` reads as 1 and
QueueNotify of queue 0 fires QueueType. `g6lc_apu_qpu` / `QpuEn`
drains that notify until EMPTY. `g6lc_apu_ntk` / `NtkEn` consumes
virtio `notify_pending[0]` into that pump. `g6lc_apu_vqt` / `VqtEn`
arms NotifyTake from virtio `vq_state[0]`. `g6lc_apu_vax` / `VaxEn`
runs those guest beats on 64-bit AXI. `g6lc_apu_vac` / `VacEn`
decodes Mesa `vkAllocateCommandBuffers` and ALLOCs a CMDBUF handle.
`g6lc_apu_hal` / `HalEn` ALLOCs that CMDBUF and looks it up on
`vkCmdDispatch` on one table. `g6lc_apu_aru` / `AruEn` ALLOCs that
CMDBUF, CREATE a MODULE, and DISPATCH SpirvSubset on one table.
`g6lc_apu_qal` / `QalEn` walks AvailNext into that ALLOC/CREATE/DISPATCH
path and publishes DISPATCH used.idx. `g6lc_apu_qta` / `QtaEn`
peeks the type word and selects GrantCapset or QueueAlloc.
`g6lc_apu_vca` / `VcaEn` is a private control face: `num_capsets`
reads as 1 and QueueNotify fires QueueTypeAlloc.
`g6lc_apu_qpa` / `QpaEn` drains that notify until EMPTY so type 88
ALLOC rides the same drain as GET_CAPSET. QueueTypeAlloc holds
`capset_q` across Idle except `gnh_only` so a pump EMPTY peek keeps
the GrantCapset ISR. `QPA_SYNTH=1`.
`g6lc_apu_nta` / `NtaEn` consumes virtio `notify_pending[0]` into
that ALLOC pump. `NTA_SYNTH=1`.
`g6lc_apu_vqa` / `VqaEn` arms NotifyTakeAlloc from virtio
`vq_state[0]` on `notify_pending[0]`. Ports are `vq0_i`/`vq1_i`.
`VQA_SYNTH=1`.
`g6lc_apu_vaa` / `VaaEn` runs those guest beats on 64-bit AXI.
`VAA_SYNTH=1`.
`g6lc_apu_vbg` / `VbgEn` decodes Mesa `vn_protocol`
`vkBeginCommandBuffer` (type 90, sType 42). `VBG_SYNTH=1`.
`g6lc_apu_bal` / `BalEn` ALLOCs that CMDBUF and looks it up on
`vkBeginCommandBuffer` on one table. `BAL_SYNTH=1`.
`g6lc_apu_bru` / `BruEn` ALLOCs QUEUE from `vkGetDeviceQueue`,
ALLOCs CMDBUF, BEGINs, CREATEs a MODULE, DISPATCHes SpirvSubset,
ENDs the begun CMDBUF, SUBMITs the ended handle against that
QUEUE, and WAITs the prior submit on one table. DISPATCH requires
a begun CMDBUF. END clears recording. SUBMIT and WAIT require the
published QUEUE. `BRU_SYNTH=1`.
`g6lc_apu_qbn` / `QbnEn` walks AvailNext into that
ALLOC/BEGIN/CREATE/DISPATCH/END/SUBMIT/WAIT/QUEUE path so types
90, 91, 18, 19, and 17 ride the CS payload. `QBN_SYNTH=1`.
`g6lc_apu_qtb` / `QtbEn` peeks the type word and selects
GrantCapset or QueueBegin so types 90, 91, 18, 19, and 17 ride
GET_CAPSET. `QTB_SYNTH=1`.
`g6lc_apu_vcb` / `VcbEn` is a private control face: `num_capsets`
reads as 1 and QueueNotify fires QueueTypeBegin. `VCB_SYNTH=1`.
`g6lc_apu_qpb` / `QpbEn` drains that notify until EMPTY so type 90
BEGIN rides the same drain as GET_CAPSET. `QPB_SYNTH=1`.
`g6lc_apu_ntb` / `NtbEn` consumes virtio `notify_pending[0]` into
that BEGIN pump. `NTB_SYNTH=1`.
`g6lc_apu_vqb` / `VqbEn` arms NotifyTakeBegin from virtio
`vq_state[0]` on `notify_pending[0]`. Ports are `vq0_i`/`vq1_i`.
`VQB_SYNTH=1`.
`g6lc_apu_vab` / `VabEn` runs those guest beats on 64-bit AXI.
`VAB_SYNTH=1`.
`g6lc_apu_ven` / `VenEn` decodes Mesa `vn_protocol`
`vkEndCommandBuffer` (type 91). `VEN_SYNTH=1`.
`g6lc_apu_eal` / `EalEn` ALLOCs a CMDBUF, looks it up on
`vkBeginCommandBuffer`, then looks the begun handle up on
`vkEndCommandBuffer` on one table. `EAL_SYNTH=1`.
`g6lc_apu_vqs` / `VqsEn` decodes Mesa `vn_protocol`
`vkQueueSubmit` (type 18). `VQS_SYNTH=1`.
BeginRun/QueueBegin/QueueTypeBegin fold type 18 SUBMIT of the
ended handle onto the existing BEGIN type mux. SUBMIT and type 19
WAIT publish used.idx and ISR. CREATE/ALLOC/BEGIN/END also publish
when the last descriptor is WRITE (handle or VK_SUCCESS).
`g6lc_apu_vwi` / `VwiEn` decodes `vkQueueWaitIdle`. `VWI_SYNTH=1`.
`g6lc_apu_vgq` / `VgqEn` decodes `vkGetDeviceQueue` (type 17).
`g6lc_apu_vcd` / `VcdEn` decodes `vkCreateDevice` (type 11).
`g6lc_apu_vci` / `VciEn` decodes `vkCreateInstance` (type 0).
`g6lc_apu_vep` / `VepEn` decodes `vkEnumeratePhysicalDevices` (type 2).
`g6lc_apu_vqf` / `VqfEn` decodes `vkGetPhysicalDeviceQueueFamilyProperties`
(type 7). `g6lc_apu_vpf` / `VpfEn` decodes `vkGetPhysicalDeviceFeatures`
(type 3). `g6lc_apu_vpp` / `VppEn` decodes `vkGetPhysicalDeviceProperties`
(type 6). `g6lc_apu_vmp` / `VmpEn` decodes
`vkGetPhysicalDeviceMemoryProperties` (type 8). BeginRun ALLOCs
INSTANCE, LOOKUPs it on enumerate then ALLOCs PHYS, LOOKUPs PHYS on
features, properties, memory properties, and queue-family query,
LOOKUPs PHYS on CreateDevice then ALLOCs DEVICE, LOOKUPs DEVICE on
GetDeviceQueue then ALLOCs QUEUE. CreateDevice requires features,
properties, memory properties, and the queue-family query. Compact
GENERATE_REPLY publishes fragmentStoresAndAtomics, Vulkan 1.1
apiVersion, maxBoundDescriptorSets=4, two memory types (DEVICE_LOCAL
and HOST_VISIBLE|HOST_COHERENT), and one heap. SUBMIT/WAIT require the
published QUEUE. `VGQ_SYNTH=1`. `VCD_SYNTH=1`. `VCI_SYNTH=1`.
`VEP_SYNTH=1`. `VQF_SYNTH=1`. `VPF_SYNTH=1`. `VPP_SYNTH=1`.
`VMP_SYNTH=1`. `g6lc_apu_vam` / `VamEn` decodes `vkAllocateMemory`
(type 21). BeginRun LOOKUPs DEVICE then ALLOCs MEMORY from the guest
pMemory id. Requires the memory-properties query. GENERATE_REPLY
writes type + VK_SUCCESS then the MEMORY handle. Bru op is 5 bits.
GenHandle kind is 4 bits with `APU_GNH_MEMORY=8`. `VAM_SYNTH=1`.
`g6lc_apu_vxb` / `VxbEn` decodes `vkCreateBuffer` (type 50, sType 12,
usage STORAGE_BUFFER). BeginRun LOOKUPs DEVICE then ALLOCs BUFFER
from the guest pBuffer id. GENERATE_REPLY writes type + VK_SUCCESS
then the BUFFER handle. `APU_GNH_BUFFER=9`. `APU_BRU_BUFFER=17`.
`VXB_SYNTH=1`. `g6lc_apu_vbb` / `VbbEn` decodes `vkBindBufferMemory`
(type 28, offset 0). BeginRun LOOKUPs BUFFER then LOOKUPs MEMORY.
No new GenHandle slot. GENERATE_REPLY writes type + VK_SUCCESS.
`APU_BRU_BIND=18`. `VBB_SYNTH=1`. `g6lc_apu_vmm` / `VmmEn` decodes
`vkMapMemory` (type 23, offset 0). BeginRun LOOKUPs MEMORY. Compact
GENERATE_REPLY publishes `APU_SHM_BASE`. `APU_BRU_MAP=19`.
`VMM_SYNTH=1`. `g6lc_apu_vum` / `VumEn` decodes `vkUnmapMemory`
(type 24). BeginRun requires a prior map, LOOKUPs MEMORY, then
clears map_ok. `APU_BRU_UNMAP=20`. `VUM_SYNTH=1`. `g6lc_apu_vbm` / `VbmEn` decodes
`vkGetBufferMemoryRequirements` (type 30). BeginRun LOOKUPs BUFFER
and publishes size 4096 / alignment 256 / memoryTypeBits 3.
`APU_BRU_BUFREQ=21`. `g6lc_apu_vfm` / `VfmEn` decodes
`vkFlushMappedMemoryRanges` (type 25). BeginRun requires a prior
map, LOOKUPs MEMORY. `APU_BRU_FLUSH=22`. `VBM_SYNTH=1`.
`VFM_SYNTH=1`. `g6lc_apu_vim` / `VimEn` decodes
`vkInvalidateMappedMemoryRanges` (type 26, sType 6, count 1,
offset 0). BeginRun requires a prior map, LOOKUPs MEMORY.
`APU_BRU_INVAL=23`. `VIM_SYNTH=1`. `g6lc_apu_vmc` / `VmcEn` decodes
`vkGetDeviceMemoryCommitment` (type 27). BeginRun LOOKUPs MEMORY
and publishes committed size 4096. `APU_BRU_MEMC=24`.
`VMC_SYNTH=1`. GenHandle is 16 slots, handle `{gen[31:16], 12'd0, slot[3:0]}`.
`g6lc_apu_vdl` / `VdlEn` decodes `vkCreateDescriptorSetLayout` (type 72,
sType 32, one STORAGE_BUFFER compute binding). BeginRun LOOKUPs DEVICE
then ALLOCs DSLAYOUT. `APU_BRU_DSLAYOUT=25`. `VDL_SYNTH=1`.
`g6lc_apu_vpl` / `VplEn` decodes `vkCreatePipelineLayout` (type 68,
sType 30). Requires dsl_ok. LOOKUP DEVICE then ALLOC PLAYOUT.
`APU_BRU_PLAYOUT=26`. `VPL_SYNTH=1`. `g6lc_apu_vcp` / `VcpEn` decodes
`vkCreateComputePipelines` (type 66, sType 29). Requires pl_ok and a
loaded MODULE. LOOKUP DEVICE then ALLOC PIPELINE. `APU_BRU_CPIPE=27`.
`VCP_SYNTH=1`. `g6lc_apu_vda` / `VdaEn` decodes
`vkAllocateDescriptorSets` (type 77, sType 34, one layout, dummy
pool). LOOKUP DEVICE then ALLOC DESCSET. `APU_BRU_DESCSET=28`.
`VDA_SYNTH=1`. `g6lc_apu_vud` / `VudEn` decodes
`vkUpdateDescriptorSets` (type 79, sType 35, STORAGE_BUFFER).
LOOKUP DESCSET then LOOKUP BUFFER. `APU_BRU_UPDATE=29`.
`VUD_SYNTH=1`. `g6lc_apu_vbp` / `VbpEn` decodes `vkCmdBindPipeline`
(type 93, compute bind point). LOOKUP PIPELINE after BEGIN.
`APU_BRU_BINDPIPE=30`. `VBP_SYNTH=1`. `g6lc_apu_vbd` / `VbdEn`
decodes `vkCmdBindDescriptorSets` (type 103). LOOKUP DESCSET after
BEGIN. `APU_BRU_BINDDESC=31`. `VBD_SYNTH=1`. bru op is 6 bits.
`g6lc_apu_vpo` / `VpoEn` decodes `vkCreateDescriptorPool` (type 74,
sType 33, one STORAGE_BUFFER size). LOOKUP DEVICE then ALLOC POOL.
`APU_BRU_POOL=32`. `VPO_SYNTH=1`. AllocateDescriptorSets LOOKUPs that
POOL. `g6lc_apu_vxi` / `VxiEn` decodes `vkCreateImage` (type 54,
sType 14, 64x64 2D STORAGE linear). LOOKUP DEVICE then ALLOC IMAGE.
`APU_BRU_IMAGE=33`. `VXI_SYNTH=1`. `g6lc_apu_vmi` / `VmiEn` decodes
`vkGetImageMemoryRequirements` (type 31). LOOKUP IMAGE, publishes
size 16384. `APU_BRU_IMGREQ=35`. `VMI_SYNTH=1`. `g6lc_apu_vbi` /
`VbiEn` decodes `vkBindImageMemory` (type 29, offset 0). LOOKUP
IMAGE then LOOKUP MEMORY. `APU_BRU_BINDIMG=34`. `VBI_SYNTH=1`.
GenHandle is 32 slots, 5-bit kinds. `g6lc_apu_vxv` / `VxvEn` decodes
`vkCreateImageView` (type 57, sType 15, 2D COLOR R8G8B8A8). LOOKUP
IMAGE then ALLOC VIEW. `APU_BRU_VIEW=36`. `VXV_SYNTH=1`.
`g6lc_apu_vsm` / `VsmEn` decodes `vkCreateSampler` (type 70, sType 31,
linear repeat). LOOKUP DEVICE then ALLOC SAMPLER. `APU_BRU_SAMPLER=37`.
`VSM_SYNTH=1`. `g6lc_apu_vrp` / `VrpEn` decodes `vkCreateRenderPass`
(type 82, sType 38, one color attachment). LOOKUP DEVICE then ALLOC
RPASS. `APU_BRU_RPASS=38`. `VRP_SYNTH=1`. `g6lc_apu_vgp` / `VgpEn`
decodes `vkCreateGraphicsPipelines` (type 65, sType 28, one VERTEX
stage). Requires rp_ok, pl_ok, and loaded MODULE. LOOKUP DEVICE then
ALLOC PIPELINE. `APU_BRU_GPIPE=39`. `VGP_SYNTH=1`. Four creates share
CS mux slot 31 at `APU_BRU_TAIL_REPLY=248`. `g6lc_apu_vfb` / `VfbEn`
decodes `vkCreateFramebuffer` (type 80, sType 37, one 64x64 color
view). LOOKUP DEVICE then ALLOC FBUF. `APU_BRU_FBUF=40`. `VFB_SYNTH=1`.
`g6lc_apu_vrb` / `VrbEn` decodes `vkCmdBeginRenderPass` (type 133,
sType 43, INLINE). Requires begun CMDBUF, fbuf_ok, rp_ok. LOOKUP
CMDBUF. `APU_BRU_BEGINRP=41`. `VRB_SYNTH=1`. `g6lc_apu_vdw` / `VdwEn`
decodes `vkCmdDraw` (type 106, three vertices). Requires begun, in_rp,
pipe_bound. LOOKUP CMDBUF. `APU_BRU_DRAW=42`. `VDW_SYNTH=1`.
`g6lc_apu_vre` / `VreEn` decodes `vkCmdEndRenderPass` (type 135).
Requires in_rp. LOOKUP CMDBUF. `APU_BRU_ENDRP=43`. `VRE_SYNTH=1`.
`g6lc_apu_vvb` / `VvbEn` decodes `vkCmdBindVertexBuffers` (type 105,
one binding, offset 0). Requires begun CMDBUF. LOOKUP CMDBUF then
LOOKUP BUFFER. `APU_BRU_BINDVTX=44`. `VVB_SYNTH=1`. `g6lc_apu_vib` /
`VibEn` decodes `vkCmdBindIndexBuffer` (type 104, UINT16, offset 0).
Requires begun CMDBUF. LOOKUP CMDBUF then LOOKUP BUFFER.
`APU_BRU_BINDIDX=45`. `VIB_SYNTH=1`. `g6lc_apu_vdi` / `VdiEn` decodes
`vkCmdDrawIndexed` (type 107, three indices). Requires begun, in_rp,
pipe_bound, vtx_bound, idx_bound. LOOKUP CMDBUF. `APU_BRU_DRAWIDX=46`.
`VDI_SYNTH=1`. `g6lc_apu_vvp` / `VvpEn` decodes `vkCmdSetViewport`
(type 94, one 64x64 viewport). Requires begun CMDBUF. LOOKUP CMDBUF.
`APU_BRU_SETVP=47`. `VVP_SYNTH=1`. `g6lc_apu_vsi` / `VsiEn` decodes
`vkCmdSetScissor` (type 95, one 64x64 scissor). Requires begun
CMDBUF. LOOKUP CMDBUF. `APU_BRU_SETSC=48`. `VSI_SYNTH=1`.
`g6lc_apu_vpb` / `VpbEn` decodes `vkCmdPipelineBarrier` (type 126,
TOP_OF_PIPE, zero barriers). Requires begun CMDBUF. LOOKUP CMDBUF.
`APU_BRU_BARRIER=49`. `VPB_SYNTH=1`. `g6lc_apu_vns` / `VnsEn` decodes
`vkCmdNextSubpass` (type 134, INLINE). Decoder accepts; BeginRun
FAULTS because the compact render pass has one subpass.
`APU_BRU_NEXTSP=50`. `VNS_SYNTH=1`. `g6lc_apu_vdf` / `VdfEn` decodes
`vkDestroyFramebuffer` (type 81). LOOKUP FBUF then `APU_GNH_RETIRE`;
clears `fbuf_ok`. `APU_BRU_DFB=51`. `VDF_SYNTH=1`. `g6lc_apu_vdx` /
`VdxEn` decodes `vkDestroyImageView` (type 58). LOOKUP VIEW then
RETIRE. `APU_BRU_DVW=52`. `VDX_SYNTH=1`. `g6lc_apu_vdk` / `VdkEn`
decodes `vkDestroySampler` (type 71). LOOKUP SAMPLER then RETIRE.
`APU_BRU_DSM=53`. `VDK_SYNTH=1`. `g6lc_apu_vdr` / `VdrEn` decodes
`vkDestroyRenderPass` (type 83). LOOKUP RPASS then RETIRE; clears
`rp_ok`. `APU_BRU_DRP=54`. `VDR_SYNTH=1`. `g6lc_apu_vdb` / `VdbEn`
decodes `vkDestroyBuffer` (type 51). LOOKUP BUFFER then RETIRE.
`APU_BRU_DBF=55`. `VDB_SYNTH=1`. `g6lc_apu_vdg` / `VdgEn` decodes
`vkDestroyImage` (type 55). LOOKUP IMAGE then RETIRE. `APU_BRU_DIM=56`.
`VDG_SYNTH=1`. `g6lc_apu_vfe` / `VfeEn` decodes `vkFreeMemory` (type
22). LOOKUP MEMORY then RETIRE. `APU_BRU_FME=57`. `VFE_SYNTH=1`.
`g6lc_apu_vdm` / `VdmEn` decodes `vkDestroyShaderModule` (type 60).
LOOKUP MODULE then RETIRE; clears `loaded_q`. `APU_BRU_DMD=58`.
`VDM_SYNTH=1`. `g6lc_apu_vdp` / `VdpEn` decodes `vkDestroyPipeline`
(type 67). LOOKUP PIPELINE then RETIRE; clears `pipe_bound`.
`APU_BRU_DPL=59`. `VDP_SYNTH=1`. `g6lc_apu_vdy` / `VdyEn` decodes
`vkDestroyPipelineLayout` (type 69). LOOKUP PLAYOUT then RETIRE;
clears `pl_ok`. `APU_BRU_DYO=60`. `VDY_SYNTH=1`. `g6lc_apu_vdt` /
`VdtEn` decodes `vkDestroyDescriptorSetLayout` (type 73). LOOKUP
DSLAYOUT then RETIRE; clears `dsl_ok`. `APU_BRU_DDS=61`. `VDT_SYNTH=1`.
`g6lc_apu_vdq` / `VdqEn` decodes `vkDestroyDescriptorPool` (type 75).
LOOKUP POOL then RETIRE; clears `pool_ok`. `APU_BRU_DPO=62`.
`VDQ_SYNTH=1`. `g6lc_apu_vfs` / `VfsEn` decodes `vkFreeDescriptorSets`
(type 78). LOOKUP DESCSET then RETIRE; clears `dset_ok`. Compact CS
count 1; pool is not LOOKed up. `APU_BRU_FDS=63`. `VFS_SYNTH=1`.
`g6lc_apu_vrc` / `VrcEn` decodes `vkResetCommandBuffer` (type 92).
LOOKUP CMDBUF, no RETIRE; clears begun/ended/in_rp/bind flags.
Reset flags 0. `APU_BRU_RCB=64`. `VRC_SYNTH=1`. `g6lc_apu_vfc` /
`VfcEn` decodes `vkFreeCommandBuffers` (type 89). LOOKUP CMDBUF then
RETIRE. Compact CS count 1; vac pool `64'hA1` is not LOOKed up.
`APU_BRU_FCB=65`. `VFC_SYNTH=1`. `g6lc_apu_vdd` / `VddEn` decodes
`vkDestroyDevice` (type 12). CS is (device, allocator); packed `obj`
copies device. LOOKUP DEVICE then RETIRE. `APU_BRU_DDV=66`.
`VDD_SYNTH=1`. `g6lc_apu_vpc` / `VpcEn` decodes `vkResetCommandPool`
(type 87). LOOKUP DEVICE, no RETIRE. Compact CS reset flags 0; vac
pool `64'hA1` is not LOOKed up. `APU_BRU_RCP=67`. `VPC_SYNTH=1`.
`g6lc_apu_vdc` / `VdcEn` decodes `vkDestroyCommandPool` (type 86).
LOOKUP DEVICE, no RETIRE; null allocator. `APU_BRU_DCP=68`.
`VDC_SYNTH=1`. `g6lc_apu_vdn` / `VdnEn` decodes `vkDestroyInstance`
(type 1). CS is (instance, allocator); packed `obj` copies instance.
LOOKUP INSTANCE then RETIRE; clears `instanced_q`. `APU_BRU_DIN=69`.
`VDN_SYNTH=1`. `g6lc_apu_vgf` / `VgfEn` decodes
`vkGetPhysicalDeviceFormatProperties` (type 4). LOOKUP PHYS. Compact
R8G8B8A8 FEATURES `32'h00006083`. `APU_BRU_GFP=70`. `VGF_SYNTH=1`.
`g6lc_apu_vip` / `VipEn` decodes
`vkGetPhysicalDeviceImageFormatProperties` (type 5). LOOKUP PHYS.
Compact 64×64 STORAGE linear. `APU_BRU_IFP=71`. `VIP_SYNTH=1`.
`g6lc_apu_vxe` / `VxeEn` decodes
`vkEnumerateDeviceExtensionProperties` (type 14). LOOKUP PHYS.
Compact count 0. `APU_BRU_DEX=72`. `VXE_SYNTH=1`. `g6lc_apu_vrd` /
`VrdEn` decodes `vkResetDescriptorPool` (type 76). LOOKUP POOL, no
RETIRE; extra `!pool_ok`; clears `desc_bound`. `APU_BRU_RDP=73`.
`VRD_SYNTH=1`. `g6lc_apu_vie` / `VieEn` decodes
`vkEnumerateInstanceExtensionProperties` (type 13). Compact count 0,
no GenHandle LOOKUP. `APU_BRU_IEX=74`. `VIE_SYNTH=1`. `g6lc_apu_vwl`
/ `VwlEn` decodes `vkDeviceWaitIdle` (type 20). LOOKUP DEVICE; extra
`!submitted_q`. `APU_BRU_DWI=75`. `VWL_SYNTH=1`. `g6lc_apu_vsl` /
`VslEn` decodes `vkGetImageSubresourceLayout` (type 56). LOOKUP
IMAGE. Compact rowPitch 256 / size 16384. `APU_BRU_ISL=76`.
`VSL_SYNTH=1`. `g6lc_apu_vrg` / `VrgEn` decodes
`vkGetRenderAreaGranularity` (type 84). LOOKUP RPASS; extra
`!rp_ok`. Compact 1×1. `APU_BRU_RAG=77`. `VRG_SYNTH=1`. `g6lc_apu_vlw` / `VlwEn` decodes `vkCmdSetLineWidth`
(type 96). LOOKUP CMDBUF; extra `!begun`. Compact width 1.0.
`APU_BRU_SLW=78`. `VLW_SYNTH=1`. `g6lc_apu_vzb` / `VzbEn` decodes
`vkCmdSetDepthBias` (type 97). LOOKUP CMDBUF; extra `!begun`.
Compact factors 0. `APU_BRU_SDB=79`. `VZB_SYNTH=1`. `g6lc_apu_vbc`
/ `VbcEn` decodes `vkCmdSetBlendConstants` (type 98). LOOKUP CMDBUF;
extra `!begun`. Compact zeros. `APU_BRU_SBC=80`. `VBC_SYNTH=1`.
`g6lc_apu_vbo` / `VboEn` decodes `vkCmdSetDepthBounds` (type 99).
LOOKUP CMDBUF; extra `!begun`. Compact min 0 max 1.0.
`APU_BRU_SBB=81`. `VBO_SYNTH=1`. `g6lc_apu_vcm` / `VcmEn` decodes
`vkCmdSetStencilCompareMask` (type 100). LOOKUP CMDBUF; extra
`!begun`. Compact FRONT_AND_BACK mask all-ones. `APU_BRU_SCM=82`.
`VCM_SYNTH=1`. `g6lc_apu_vwm` / `VwmEn` decodes
`vkCmdSetStencilWriteMask` (type 101). LOOKUP CMDBUF; extra
`!begun`. Compact FRONT_AND_BACK mask all-ones. `APU_BRU_SWM=83`.
`VWM_SYNTH=1`. `g6lc_apu_vrf` / `VrfEn` decodes
`vkCmdSetStencilReference` (type 102). LOOKUP CMDBUF; extra
`!begun`. Compact FRONT_AND_BACK ref 0. `APU_BRU_SRF=84`.
`VRF_SYNTH=1`. `g6lc_apu_vcc` / `VccEn` decodes
`vkCmdCopyBuffer` (type 112). LOOKUP CMDBUF then BUFFER src then
BUFFER dst; extra `!begun` / `in_rp`. Compact srcOff 0, dstOff 2048,
size 2048. `APU_BRU_CCB=85`. `VCC_SYNTH=1`. `g6lc_apu_vcy` /
`VcyEn` decodes `vkCmdCopyImage` (type 113). LOOKUP CMDBUF then
IMAGE src/dst; extra `!begun` / `in_rp`. Compact TRANSFER layouts,
32x64 half-window. `APU_BRU_CCI=86`. `VCY_SYNTH=1`. `g6lc_apu_vbl`
/ `VblEn` decodes `vkCmdBlitImage` (type 114). LOOKUP CMDBUF then
IMAGE src/dst; extra `!begun` / `in_rp`. Compact NEAREST 32x64 blit.
`APU_BRU_BLI=87`. `VBL_SYNTH=1`. `g6lc_apu_vbt` / `VbtEn` decodes
`vkCmdCopyBufferToImage` (type 115). LOOKUP CMDBUF then BUFFER src
then IMAGE dst; extra `!begun` / `in_rp`. Compact 32x32 (4096 bytes).
`APU_BRU_CBI=88`. `VBT_SYNTH=1`. `g6lc_apu_vic` / `VicEn` decodes
`vkCmdCopyImageToBuffer` (type 116). LOOKUP CMDBUF then IMAGE src
then BUFFER dst; extra `!begun` / `in_rp`. Compact 32x32 (4096 bytes).
`APU_BRU_CIB=89`. `VIC_SYNTH=1`. `g6lc_apu_vub` / `VubEn` decodes
`vkCmdUpdateBuffer` (type 117). LOOKUP CMDBUF then BUFFER; extra
`!begun` / `in_rp`. Compact offset 0 size 4 data 0. `APU_BRU_UBF=90`.
`VUB_SYNTH=1`. `g6lc_apu_vfl` / `VflEn` decodes `vkCmdFillBuffer`
(type 118). LOOKUP CMDBUF then BUFFER; extra `!begun` / `in_rp`.
Compact size 4096 data 0. `APU_BRU_FIL=91`. `VFL_SYNTH=1`.
`g6lc_apu_vcl` / `VclEn` decodes `vkCmdClearColorImage` (type 119).
LOOKUP CMDBUF then IMAGE; extra `!begun` / `in_rp`. Compact
TRANSFER_DST zeros. `APU_BRU_CCL=92`. `VCL_SYNTH=1`. `g6lc_apu_vio`
/ `VioEn` decodes `vkCmdDrawIndirect` (type 108). LOOKUP CMDBUF then
BUFFER; extra `begun` / `in_rp` / `pipe_bound`. Compact drawCount 1
stride 16. `APU_BRU_DRI=93`. `VIO_SYNTH=1`. CS prefix `APU_DRI_*`.
`g6lc_apu_vix` / `VixEn` decodes `vkCmdDrawIndexedIndirect` (type
109). LOOKUP CMDBUF then BUFFER; extra also `vtx_bound` /
`idx_bound`. Compact stride 20. `APU_BRU_DXI=94`. `VIX_SYNTH=1`.
`g6lc_apu_vds` / `VdsEn` decodes `vkCmdClearDepthStencilImage` (type
120). LOOKUP CMDBUF then IMAGE; extra `!begun` / `in_rp`. Compact
depth 1.0 ASPECT_DEPTH. `APU_BRU_CDS=95`. `VDS_SYNTH=1`.
`g6lc_apu_vat` / `VatEn` decodes `vkCmdClearAttachments` (type 121).
LOOKUP CMDBUF; extra `begun` / `in_rp`. Compact one COLOR 64x64.
`APU_BRU_CAT=96`. `VAT_SYNTH=1`. `g6lc_apu_vin` / `VinEn` decodes
`vkCmdDispatchIndirect` (type 111). LOOKUP CMDBUF then BUFFER; extra
`begun` / `!in_rp` / `pipe_bound` / `desc_bound` / `loaded`. Compact
offset 0. `APU_BRU_DSI=97`. `VIN_SYNTH=1`. Does not Kick the compute
add. `g6lc_apu_vrs` / `VrsEn` decodes `vkCmdResolveImage` (type 122).
LOOKUP CMDBUF then IMAGE src/dst; extra `!begun` / `in_rp`. Compact
TRANSFER 32x32 half-window. `APU_BRU_RSI=98`. `VRS_SYNTH=1`.
`g6lc_apu_vgs` / `VgsEn` decodes `vkGetFenceStatus` (type 38). LOOKUP
DEVICE; compact VK_SUCCESS. `APU_BRU_GFS=99`. `VGS_SYNTH=1`.
`g6lc_apu_vwf` / `VwfEn` decodes `vkWaitForFences` (type 39). LOOKUP
DEVICE after submit; compact count 1 waitAll timeout 0.
`APU_BRU_WFE=100`. `VWF_SYNTH=1`. `g6lc_apu_vfr` / `VfrEn` decodes
`vkResetFences` (type 37). LOOKUP DEVICE; compact count 1.
`APU_BRU_RFE=101`. `VFR_SYNTH=1`. `g6lc_apu_vfn` / `VfnEn` decodes
`vkDestroyFence` (type 36). LOOKUP DEVICE; no RETIRE.
`APU_BRU_DFE=102`. `VFN_SYNTH=1`. No FENCE kind. CreateFence=35
skipped. `apu_bru_op_e` is 7 bits. bru FSM state enum is 8 bits.
GENERATE_REPLY still shares CS mux slot 31; `tail_q` is 8 words.
DISPATCH requires pipe_bound and desc_bound. Next: DISPLAY.md
identity.

### Feasibility review (source-only, 2026-10-01)

Evidence class: **observed in source** unless marked inferred or unverified.
No RTL, simulation, ISO or package install ran in this review.

| Item | Observation | Class |
|---|---|---|
| Resolute virtio-gpu features | `kernel/.../virtgpu_drv.c:153–165` offers VIRGL, EDID, RESOURCE_UUID, RESOURCE_BLOB, CONTEXT_INIT. `virtgpu_kms.c:162–199` latches them; HOST_VISIBLE additionally requires a SHM region whose length is not all-ones. | observed |
| CAPSET_QUERY_FIX | `virtgpu_ioctl.c:99–100` always returns 1. Driver-provided, not a device feature bit. | observed |
| Venus kernel params | Mesa docs require 3D_FEATURES, CAPSET_QUERY_FIX, RESOURCE_BLOB, HOST_VISIBLE, CONTEXT_INIT. 3D_FEATURES is `has_virgl_3d` from `VIRTIO_GPU_F_VIRGL` (`virtgpu_ioctl.c:96–98`, `589`). | observed (Mesa docs + kernel) |
| Capset IDs | UAPI `virtio_gpu.h:310–314`: VIRGL=1, VIRGL2=2, VENUS=4. Driver rejects id 0 or >63 (`virtgpu_kms.c:91–93`). | observed |
| Fence publication | Dequeue of the control used ring runs response callbacks, then signals `fence_id` (`virtgpu_vq.c:244–263`, `virtgpu_fence.c:110–157`). Work must complete before the used element. | observed |
| Mesa package (26.04) | Launchpad resolute `mesa` **26.0.3-1ubuntu1** (release) / **26.0.8-1ubuntu0.3** (updates); `mesa-vulkan-drivers` contains `libvulkan_virtio.so`. 26.04.1 is the 26.04 archive plus SRUs, not a separate Mesa source tree. | observed (package metadata) / **unverified** on a clean image |
| Venus protocol | Guest ICD serializes `vk*` onto a host-visible blob ring (`vn_ring`); SPIR-V is `VkShaderModuleCreateInfo.pCode`; replies are optional. Host virglrenderer `vkr` is a Vulkan ICD client, not a GPU. Hardware Venus replaces `vkr`, not the guest ICD. | observed (Mesa docs, protocol headers) |
| UE SM5 floor | `VP_UE_desktop_vulkan.json:157–161` Vulkan 1.1.0; SM5 `fragmentStoresAndAtomics` and `maxBoundDescriptorSets>=4`. Profile checks default on (`VulkanGenericPlatform.cpp:191–195`). Linux prefers `libvulkan.so.1` (`VulkanLinuxPlatform.cpp:160–163`). SPIR-V is submitted via `vkCreateShaderModule` (`VulkanShaders.cpp:534–549`). | observed |
| Current APU vs Venus | `g6lc_apu_virtio_mmio.sv:202–203` SHM length/base `'1`. `APU_IMPL_FEATURES` is VERSION_1+RING_RESET only. `apu_cfg_legal` ties `FeatureVirgl` to firmware hart and `NumCapsets==2` (virgl 1+2), not Venus capset 4. | observed |
| Route | Hardware Venus remains the preferred candidate. Matching a vendor native ISA without spoofing is not selected. Firmware/compiler backends fail the strict endpoint if they remain at runtime. | inferred (architecture) |
| Prototype | Bounded SPIR-V-subset interpreter + immutable program SRAM, bytes+IRQ test transport; positive/mutation/negative (ApuOff) controls. Full Venus decode is out of prototype scope. | inferred (estimate) at review; RTL below |

### Bounded SPIR-V-subset prototype (RTL, 2026-10-01)

`g6lc_apu_spirv` / `SpirvEn` after `GexEn`. Default 0 on ApuOff, ApuP1Transport,
ApuHarness, ApuSchedBoth, and ApuBadVirglGrant. Private `Flist.apu_spirv` /
`tb_g6lc_apu_spirv` / `run-apu-spirv.sh`. Not instantiated in `g6lc_apu_sys`.
`FeatureVirgl` stays illegal. The TB is a diagnostic client on a bytes+IRQ test
transport (load, commit, start, IRQ, result). Product still requires the stock
Mesa Venus ICD. 128×32 program words are flip-flops in this estimate, later an
SRAM macro. Remote 2026-10-01: `tb_g6lc_apu_spirv` 8 cases / 15 checks / 348
cycles, errors=0. `SPIRV_SYNTH=1`, no latches. Enable=0 is **16 ports / no
cells**; Enable=1 is **35938 cells / 5365 flip-flops**. Blob identity
`corev_apu/apu/g6lc_apu_spirv.sv` `1c465d083ef5a28e6fcf7502696903198bed064d`.
Does not legalize virgl, does not advertise capset 4, and does not close G0/A5.

### Reusable NEXT chain walker (RTL, 2026-10-01)

`g6lc_apu_chain` / `ChainEn` after `SpirvEn`. Default 0 on every profile.
Private `Flist.apu_chain` / `tb_g6lc_apu_chain` / `run-apu-chain.sh`. Not
instantiated in `g6lc_apu_sys`. `g6lc_apu_vgpu_avail` still faults NEXT and
was not edited. Programmed 16-byte virtq_desc table, bounded NEXT, reject
INDIRECT/loop/OOB/overlong/misaligned with no further read. Relocating the
base and starting at head 2 changes the first/last payload windows. Remote
2026-10-01: `tb_g6lc_apu_chain` 9 cases / 27 checks / 73 cycles, errors=0.
`CHAIN_SYNTH=1`, no latches. Enable=0 is **19 ports / no cells**; Enable=1
is **1917 cells / 503 flip-flops**. Blob identity
`corev_apu/apu/g6lc_apu_chain.sv` `eb8c30aa8d626519420d8b2f8a776b4a1da2af58`.
`FeatureVirgl` stays illegal.

### ChainDma join (RTL, 2026-10-01)

`g6lc_apu_cdma` / `CdmaEn` after `ChainEn`. Default 0 on every profile.
Instantiates NextChain and checked DmaRead. 16-byte descriptor fetches are
mapping-window AXI reads. Relocating the table and starting at head 2 still
changes the payload windows. INDIRECT issues one AR; an address outside the
mapping or an invalid mapping issues none. Private `Flist.apu_cdma` /
`tb_g6lc_apu_cdma` / `run-apu-cdma.sh`. Not instantiated in `g6lc_apu_sys`.
`g6lc_apu_vgpu_avail` still faults NEXT and was not edited. Remote 2026-10-01:
`tb_g6lc_apu_cdma` 7 cases / 20 checks / 153 cycles, errors=0. `CDMA_SYNTH=1`,
no latches. Enable=0 is **14 ports / no cells**; Enable=1 is **8471 cells /
1150 flip-flops**. Blob identity `corev_apu/apu/g6lc_apu_cdma.sv`
`f4598277bc955ae02b0b1d04d42f122898f8ec6e`. `FeatureVirgl` stays illegal.

### HOST_VISIBLE SHM, blob, CONTEXT_INIT (RTL, 2026-10-01)

`ShmEn` after `CdmaEn`, default 0. With `ShmEn`, virtio-mmio `SHM_SEL=1`
returns base `64'h82000000` and length 1 MiB; selector 0 or 2 still reads
all-ones. `g6lc_apu_hvis` / `HvisEn` records a HOST3D MAPABLE blob, a map
offset in that window, and `CTX_CREATE` with `context_init` Venus (4).
Virgl capset 1 faults. Bits `VIRTIO_GPU_F_RESOURCE_BLOB` and
`VIRTIO_GPU_F_CONTEXT_INIT` stay outside `APU_IMPL_FEATURES`. Private
`Flist.apu_hvis` / `tb_g6lc_apu_hvis`. `g6lc_apu_sys` is unchanged.
Remote 2026-10-01: `tb_g6lc_apu_hvis` 7 cases / 18 checks / 51 cycles,
errors=0. `HVIS_SYNTH=1`, no latches. Enable=0 is **9 ports / no cells**;
Enable=1 is **1386 cells / 197 flip-flops**. P1 `tb_g6lc_apu_virtio_mmio`
4240 checks / 636 cycles still PASS. Blob identity `g6lc_apu_hvis.sv`
`440bab823ffb772d80f9ddf85820849a2aec18f2`. `FeatureVirgl` stays illegal.

### Hardware Venus CS prototype (RTL, 2026-10-01)

`g6lc_apu_vncs` / `VncsEn` after `HvisEn`. Default 0. Instantiates
SpirvSubset. A 128-word HOST_VISIBLE ring carries CREATE_MODULE (SPIR-V
words) and DISPATCH (two integer inputs and a result slot). The same
committed module mutates 2+3=5 then 4+5=9. Unknown opcode faults. This
is a diagnostic ring, not Mesa `vn_protocol`. Private `Flist.apu_vncs` /
`tb_g6lc_apu_vncs`. Not in `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_vncs` 4 cases / 10 checks / 341 cycles, errors=0.
`VNCS_SYNTH=1`, no latches. Enable=0 is **13 ports / no cells**; Enable=1
is **74601 cells / 9601 flip-flops**. Blob identity `g6lc_apu_vncs.sv`
`9175f034c147b477676b25060fb6c9c6432a37de`. `FeatureVirgl` stays illegal.

### Venus capset wire (RTL, 2026-10-01)

`g6lc_apu_vcap` / `VcapEn` after `VncsEn`. Default 0. GET_CAPSET_INFO and
GET_CAPSET for `VIRTIO_GPU_CAPSET_VENUS` (4) return the
`virgl_renderer_capset_venus` layout (160 bytes): wire format 1, VK 1.1
XML, valid extension mask with no extra bits, `use_guest_vram=1`. Virgl
id 1 faults. `NumCapsets` stays 0 on `virtio_gpu_config`. Private
`Flist.apu_vcap` / `tb_g6lc_apu_vcap`. Not in `g6lc_apu_sys`. Remote
2026-10-01: `tb_g6lc_apu_vcap` 5 cases / 56 checks / 28 cycles, errors=0.
`VCAP_SYNTH=1`, no latches. Enable=0 is **11 ports / no cells**; Enable=1
is **222 cells / 4 flip-flops**. Blob identity `g6lc_apu_vcap.sv`
`7c7b80b5ffc68ae9cc7e3b9252df8119a39a3ae9`. `FeatureVirgl` stays illegal.

### Stock vn_ring layout (RTL, 2026-10-01)

`g6lc_apu_vnring` / `VnringEn` after `VcapEn`. Default 0. Matches Mesa
`vn_ring_get_layout`: head at 0, tail at 64, status at 128, buffer at
192, 256-byte power-of-two buffer. head/tail are monotonically increasing
byte seqnos; the buffer index is seqno modulo 256. A consume advances
tail to head and writes idle status. Wrap, empty, unaligned, and oversize
are covered. This is stock ring geometry, not `vn_protocol` vk* encode.
Private `Flist.apu_vnring` / `tb_g6lc_apu_vnring`. Not in `g6lc_apu_sys`.
Remote 2026-10-01: `tb_g6lc_apu_vnring` 6 cases / 13 checks / 59 cycles,
errors=0. `VNRING_SYNTH=1`, no latches. Enable=0 is **12 ports / no
cells**; Enable=1 is **13443 cells / 4228 flip-flops**. Blob identity
`g6lc_apu_vnring.sv` `92ba1242e4f308b494ecbf56d13a74efa13f50ab`.
`FeatureVirgl` stays illegal.

### Testharness DMA fabric join (RTL, 2026-10-01)

`g6lc_apu_tdma` / `TdmaEn` after `VnringEn`. Default 0 on every
profile. 2:1 AXI join: APU DMA (port A) wins over AI DMA (port B).
Enable=0 is idle. Under `+define+G6LC_APU` without
`G6LC_AI_DRAM_ISLAND_PORT`, `ariane_testharness` instantiates the join
with Enable=1 onto xbar `slave[2]` (`ariane_soc::NrSlaves` stays 3) and
connects `g6lc_apu_th_load` `dma_req_o`. `ApuHarness.DmaReadEn=0` keeps
the APU side idle; join Enable=1 still forwards AI. With the 512-bit
island port, APU takes `slave[2]` alone. Private `Flist.apu_tdma` /
`tb_g6lc_apu_tdma`. On `Flist.apu_soc` for the opt-in compositor, not
instantiated in `g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_tdma`
4 cases / 10 checks / 18 cycles, errors=0. `TDMA_SYNTH=1`, no latches.
Enable=0 is **8 ports / no cells**; Enable=1 is **321 cells / 4
flip-flops**. Blob identity `g6lc_apu_tdma.sv`
`860d7ba0f738bc93db96de2892b2e61a3cfd017a`. `FeatureVirgl` stays
illegal.

### Mesa vn_protocol vkCreateShaderModule (RTL, 2026-10-01)

`g6lc_apu_vnenc` / `VnencEn` after `TdmaEn`. Default 0. Decodes the
stock Mesa CS for `VK_COMMAND_TYPE_vkCreateShaderModule_EXT` (59):
flags, LP64 device handle, uint64 pointer presence,
`VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO` (16), pCode
`array_size` in words, module id. `GENERATE_REPLY` writes command
type, `VK_SUCCESS`, and the handle at word 184. CS is 192 words,
max 128 pCode words. vkCreateInstance, a null info pointer, and
empty pCode fault. Private `Flist.apu_vnenc` / `tb_g6lc_apu_vnenc`.
Not in `g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_vnenc` 6
cases / 13 checks / 302 cycles, errors=0. `VNENC_SYNTH=1`, no
latches. Enable=0 is **12 ports / no cells**; Enable=1 is **36136
cells / 6437 flip-flops**. Blob identity `g6lc_apu_vnenc.sv`
`677e40d3a20acda483f66916c96c657b945c4a33`. `FeatureVirgl` stays
illegal.

### VenusPath vn_ring into SpirvSubset (RTL, 2026-10-01)

`g6lc_apu_vnp` / `VnpEn` after `VnencEn`. Default 0. Instantiates
VenusEncode and SpirvSubset. Mesa `vn_ring_layout` with
`buffer_size` 512 at byte 192 carries a `vkCreateShaderModule` CS;
pCode is loaded and committed. The same module mutates 2+3=5 then
4+5=9. Empty ring is quiet. vkCreateInstance and an unaligned head
fault. Private `Flist.apu_vnp` / `tb_g6lc_apu_vnp`. Not in
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_vnp` 6 cases / 11
checks / 768 cycles, errors=0. `VNP_SYNTH=1`, no latches. Enable=0
is **16 ports / no cells**; Enable=1 is **100179 cells / 20112
flip-flops**. Blob identity `g6lc_apu_vnp.sv`
`3ce8ce1e07eb358389b5e6284a8b47abebeaee3a`. `FeatureVirgl` stays
illegal.

### AvailNext virtq_avail into NextChain (RTL, 2026-10-01)

`g6lc_apu_avn` / `AvnEn` after `VnpEn`. Default 0. Instantiates
NextChain. Programmed `virtq_avail` base, descriptor table, power-of-two
queue size, and 16-bit device index. `avail.idx` equal to the device
index is EMPTY. A named head with NEXT walks first/last payload windows.
Wrap uses `device_idx=16'hFFFF`. INDIRECT and an unaligned avail base
fault. `g6lc_apu_vgpu_avail` still faults NEXT and was not edited.
Private `Flist.apu_avn` / `tb_g6lc_apu_avn`. Not in `g6lc_apu_sys`.
Remote 2026-10-01: `tb_g6lc_apu_avn` 7 cases / 13 checks / 97 cycles,
errors=0. `AVN_SYNTH=1`, no latches. Enable=0 is **19 ports / no
cells**; Enable=1 is **3521 cells / 988 flip-flops**. Blob identity
`g6lc_apu_avn.sv` `a4525eac06badac8b1b94bf3f09988c312bd3ab8`.
`FeatureVirgl` stays illegal.

### AvailUsed virtq_used publication (RTL, 2026-10-01)

`g6lc_apu_avu` / `AvuEn` after `AvnEn`. Default 0. Instantiates
AvailNext. On a successful consume, writes `virtq_used_elem` (id +
WRITE length) then `used.idx`. EMPTY writes nothing. 16-bit used-index
wrap. INDIRECT issues no used store. `g6lc_apu_vgpu_avail` still
faults NEXT and was not edited. Private `Flist.apu_avu` /
`tb_g6lc_apu_avu`. Not in `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_avu` 5 cases / 9 checks / 82 cycles, errors=0.
`AVU_SYNTH=1`, no latches. Enable=0 is **27 ports / no cells**;
Enable=1 is **4754 cells / 1438 flip-flops**. Blob identity
`g6lc_apu_avu.sv` `f3539702658cd8c625ce61f41e58c1f23815058a`.
`FeatureVirgl` stays illegal.

### UsedIrq virtio used-buffer ISR (RTL, 2026-10-01)

`g6lc_apu_uir` / `UirEn` after `AvuEn`. Default 0. Instantiates
AvailUsed. After `used.idx` publication, ISR bit 0
(`VIRTIO_MMIO_INT_VRING`) and `irq_o` rise. Guest ack of bit 0
lowers the pin. EMPTY and INDIRECT raise no IRQ.
`g6lc_apu_vgpu_avail` still faults NEXT and was not edited. Private
`Flist.apu_uir` / `tb_g6lc_apu_uir`. Not in `g6lc_apu_sys`. Remote
2026-10-01: `tb_g6lc_apu_uir` 4 cases / 9 checks / 63 cycles,
errors=0. `UIR_SYNTH=1`, no latches. Enable=0 is **31 ports / no
cells**; Enable=1 is **3947 cells / 1141 flip-flops**. Blob identity
`g6lc_apu_uir.sv` `d375dd473a3ea3743d2c837450e415ae76c5fa7c`.
`FeatureVirgl` stays illegal.

### CmdSnap immutable first-payload window (RTL, 2026-10-01)

`g6lc_apu_cms` / `CmsEn` after `UirEn`. Default 0. Instantiates
AvailNext. After a NEXT walk, reads the first payload window (≤32
bytes) into an 8-word store. Guest mutation of that address does not
change the snapshot. A second snapshot faults until reset. EMPTY
stores nothing. `g6lc_apu_vgpu_avail` still faults NEXT and was not
edited. Private `Flist.apu_cms` / `tb_g6lc_apu_cms`. Not in
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_cms` 4 cases / 10
checks / 45 cycles, errors=0. `CMS_SYNTH=1`, no latches. Enable=0 is
**21 ports / no cells**; Enable=1 is **4227 cells / 1201 flip-flops**.
Blob identity `g6lc_apu_cms.sv`
`e609107989ff070a98f86e8d20a6149fb1804f55`. `FeatureVirgl` stays
illegal.

### PayResp WRITE-window response (RTL, 2026-10-01)

`g6lc_apu_prs` / `PrsEn` after `CmsEn`. Default 0. Instantiates
AvailNext. After a NEXT walk whose last descriptor is WRITE, stores a
programmed ≤32-byte response at `last_addr`. The TB programs
`VGPU_RESP_OK_NODATA`; this is not DISPLAY.md identity. EMPTY writes
nothing. Length mismatch faults. `g6lc_apu_vgpu_avail` still faults
NEXT and was not edited. Private `Flist.apu_prs` / `tb_g6lc_apu_prs`.
Not in `g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_prs` 4 cases /
8 checks / 71 cycles, errors=0. `PRS_SYNTH=1`, no latches. Enable=0
is **31 ports / no cells**; Enable=1 is **3833 cells / 1234
flip-flops**. Blob identity `g6lc_apu_prs.sv`
`96d13d0829f0bd6a6f26b0ae085088aeb7f4e1e5`. `FeatureVirgl` stays
illegal.

### QueueDone response then used.idx then ISR (RTL, 2026-10-01)

`g6lc_apu_qdn` / `QdnEn` after `PrsEn`. Default 0. Instantiates
AvailNext. One walk, then WRITE response, `virtq_used_elem`,
`used.idx`, and virtio used-buffer ISR. EMPTY writes nothing.
`g6lc_apu_vgpu_avail` still faults NEXT and was not edited. Private
`Flist.apu_qdn` / `tb_g6lc_apu_qdn`. Not in `g6lc_apu_sys`. Remote
2026-10-01: `tb_g6lc_apu_qdn` 3 cases / 8 checks / 52 cycles,
errors=0. `QDN_SYNTH=1`, no latches. Enable=0 is **35 ports / no
cells**; Enable=1 is **5140 cells / 1453 flip-flops**. Blob identity
`g6lc_apu_qdn.sv` `d15a483b5b8b14cba6d6252a08bbc5ee762ea55b`.
`FeatureVirgl` stays illegal.

### GrantCapset Venus GET_CAPSET on the queue (RTL, 2026-10-01)

`g6lc_apu_gcs` / `GcsEn` after `QdnEn`. Default 0. Instantiates
AvailNext and VenusCapset. After a NEXT walk, snapshots the first
payload, grants Venus id 4 for `GET_CAPSET_INFO` index 0 and
`GET_CAPSET` id 4, writes `VIRTIO_GPU_RESP_OK_CAPSET_INFO` (40
bytes) or `VIRTIO_GPU_RESP_OK_CAPSET` plus the 160-byte
`virgl_renderer_capset_venus` blob, then `virtq_used_elem`,
`used.idx`, and virtio used-buffer ISR. Virgl id 1 faults. EMPTY
writes nothing. `NumCapsets` stays 0; this is not advertised
virtio GET_CAPSET. `g6lc_apu_vgpu_avail` still faults NEXT and was
not edited. Private `Flist.apu_gcs` / `tb_g6lc_apu_gcs`. Not in
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_gcs` 5 cases / 12
checks / 116 cycles, errors=0. `GCS_SYNTH=1`, no latches. Enable=0
is **31 ports / no cells**; Enable=1 is **9379 cells / 1813
flip-flops**. Blob identity `g6lc_apu_gcs.sv`
`4fbc888fcc482093bbd387cf6019fcdb758ddf8b`. `FeatureVirgl` stays
illegal.

### VenusDispatch Mesa vn_protocol vkCmdDispatch (RTL, 2026-10-01)

`g6lc_apu_vnd` / `VndEn` after `GcsEn`. Default 0. Mesa
`vn_protocol` `vkCmdDispatch` CS: command type 110, LP64
command-buffer handle, `groupCountX/Y/Z`. GENERATE_REPLY writes
the command type. vkCreateShaderModule, vkCreateInstance, a null
command buffer, and `vkCmdDispatchIndirect` fault. This is the ICD
CS, not `vncs` DISPATCH. Private `Flist.apu_vnd` / `tb_g6lc_apu_vnd`.
Not in `g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_vnd` 7 cases
/ 12 checks / 145 cycles, errors=0. `VND_SYNTH=1`, no latches.
Enable=0 is **12 ports / no cells**; Enable=1 is **1729 cells / 741
flip-flops**. Blob identity `g6lc_apu_vnd.sv`
`bc9518862a29fee611c958908a897642643e5cbb`. `FeatureVirgl` stays
illegal.

### GenHandle generational object table (RTL, 2026-10-01)

`g6lc_apu_gnh` / `GnhEn` after `VndEn`. Default 0. Eight slots for
context/resource/module/cmdbuf. Alloc publishes `{gen[31:16],
slot[2:0]}`. Lookup/pin/unpin/retire require a live matching
generation. Retire is refused while pinned. Duplicate live
`(kind, object_id)` and a full table fault. Private `Flist.apu_gnh`
/ `tb_g6lc_apu_gnh`. Not in `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_gnh` 6 cases / 25 checks / 122 cycles, errors=0.
`GNH_SYNTH=1`, no latches. Enable=0 is **9 ports / no cells**;
Enable=1 is **3737 cells / 565 flip-flops**. Blob identity
`g6lc_apu_gnh.sv` `6977d38b2a8e20973c63b7f3a6dcfe9fe195cde4`.
`FeatureVirgl` stays illegal.

### HandleDispatch published cmdbuf on vkCmdDispatch (RTL, 2026-10-01)

`g6lc_apu_hdp` / `HdpEn` after `GnhEn`. Default 0. Instantiates
GenHandle and VenusDispatch. A dispatch request decodes the Mesa
`vkCmdDispatch` CS and looks up `commandBuffer[31:0]` as a live
CMDBUF handle. Stale generation, wrong kind, and vkCreateInstance
fault. Private `Flist.apu_hdp` / `tb_g6lc_apu_hdp`. Not in
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_hdp` 6 cases / 11
checks / 146 cycles, errors=0. `HDP_SYNTH=1`, no latches. Enable=0
is **13 ports / no cells**; Enable=1 is **5979 cells / 1491
flip-flops**. Blob identity `g6lc_apu_hdp.sv`
`56f75ca3b84c4d1051434d5c86b604cfe735088a`. `FeatureVirgl` stays
illegal.

### HandlePath MODULE publish and CMDBUF dispatch (RTL, 2026-10-01)

`g6lc_apu_hph` / `HphEn` after `HdpEn`. Default 0. Instantiates
VenusEncode, GenHandle, and VenusDispatch. `vkCreateShaderModule`
allocates a MODULE handle from `module_id[31:0]`. `vkCmdDispatch`
looks up a live CMDBUF. Duplicate live module ids, a MODULE used as
a command buffer, and vkCreateInstance fault. Private
`Flist.apu_hph` / `tb_g6lc_apu_hph`. Not in `g6lc_apu_sys`. Remote
2026-10-01: `tb_g6lc_apu_hph` 6 cases / 11 checks / 207 cycles,
errors=0. `HPH_SYNTH=1`, no latches. Enable=0 is **13 ports / no
cells**; Enable=1 is **41062 cells / 7481 flip-flops**. Blob
identity `g6lc_apu_hph.sv`
`7bbb81e76e8f9887012d0798680db4e5a5bbd08f`. `FeatureVirgl` stays
illegal.

### HandleRun SpirvSubset kick on published handles (RTL, 2026-10-01)

`g6lc_apu_hrn` / `HrnEn` after `HphEn`. Default 0. Instantiates
VenusEncode, GenHandle, VenusDispatch, and SpirvSubset. Create
commits SPIR-V under a MODULE handle. Dispatch looks up a live
CMDBUF and kicks `2+3=5` then `4+5=9`. Dispatch before create, a
MODULE used as a command buffer, and vkCreateInstance fault.
Private `Flist.apu_hrn` / `tb_g6lc_apu_hrn`. Not in `g6lc_apu_sys`.
Remote 2026-10-01: `tb_g6lc_apu_hrn` 6 cases / 11 checks / 720
cycles, errors=0. `HRN_SYNTH=1`, no latches. Enable=0 is **17 ports
/ no cells**; Enable=1 is **77619 cells / 13025 flip-flops**. Blob
identity `g6lc_apu_hrn.sv`
`ff1979bde32d16b6659c6e24f01829f72542a7b4`. `FeatureVirgl` stays
illegal.

### RunDone result WRITE then used.idx then ISR (RTL, 2026-10-01)

`g6lc_apu_rdn` / `RdnEn` after `HrnEn`. Default 0. Instantiates
HandleRun. Dispatch writes the SPIR-V result (4 bytes),
`virtq_used_elem`, `used.idx`, and virtio used-buffer ISR.
Publication order is result, element, index, interrupt. Create
writes nothing. Private `Flist.apu_rdn` / `tb_g6lc_apu_rdn`. Not in
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_rdn` 4 cases / 10
checks / 403 cycles, errors=0. `RDN_SYNTH=1`, no latches. Enable=0
is **27 ports / no cells**; Enable=1 is **77606 cells / 13138
flip-flops**. Blob identity `g6lc_apu_rdn.sv`
`e0086a9819b5c34223fdfe4c859882f304ba03fe`. `FeatureVirgl` stays
illegal.

### QueueRun AvailNext CS into RunDone (RTL, 2026-10-01)

`g6lc_apu_qrn` / `QrnEn` after `RdnEn`. Default 0. Instantiates
AvailNext and RunDone. Walks the virtqueue, DMA-reads the first
payload into the CS, then CREATE or DISPATCH. DISPATCH writes the
SPIR-V result, `used.idx`, and ISR. CREATE writes nothing. EMPTY
fetches nothing. `g6lc_apu_vgpu_avail` still faults NEXT and was
not edited. Private `Flist.apu_qrn` / `tb_g6lc_apu_qrn`. Not in
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_qrn` 3 cases / 9
checks / 315 cycles, errors=0. `QRN_SYNTH=1`, no latches. Enable=0
is **33 ports / no cells**; Enable=1 is **84956 cells / 15231
flip-flops**. Blob identity `g6lc_apu_qrn.sv`
`79b69d1e6c3c78a56c43de3a3ebe536ab4b15c93`. `FeatureVirgl` stays
illegal.

### QueueCmd GrantCapset or QueueRun (RTL, 2026-10-01)

`g6lc_apu_qcm` / `QcmEn` after `QrnEn`. Default 0. Instantiates
GrantCapset and QueueRun. `capset=1` walks GET_CAPSET/INFO through
Venus; `capset=0` walks CREATE/DISPATCH through RunDone. Virgl id 1
faults. EMPTY fetches nothing. `NumCapsets` stays 0. This is not
advertised GET_CAPSET. `g6lc_apu_vgpu_avail` still faults NEXT and
was not edited. Private `Flist.apu_qcm` / `tb_g6lc_apu_qcm`. Not in
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_qcm` 6 cases / 16
checks / 436 cycles, errors=0. `QCM_SYNTH=1`, no latches. Enable=0
is **33 ports / no cells**; Enable=1 is **95709 cells / 17523
flip-flops**. Blob identity `g6lc_apu_qcm.sv`
`ea115c683bbf6d3c51535db2443bdac368b3c70b`. `FeatureVirgl` stays
illegal.

### QueueType AvailNext type word (RTL, 2026-10-01)

`g6lc_apu_qty` / `QtyEn` after `QcmEn`. Default 0. Instantiates
AvailNext and QueueCmd. Peeks the first command word:
GET_CAPSET/INFO selects GrantCapset; CREATE/DISPATCH selects
QueueRun. `gnh_only` skips the peek. EMPTY fetches nothing. Child
QueueCmd walks the same avail again. `NumCapsets` stays 0. This is
not advertised GET_CAPSET. `g6lc_apu_vgpu_avail` still faults NEXT
and was not edited. Private `Flist.apu_qty` / `tb_g6lc_apu_qty`.
Not in `g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_qty` 6 cases
/ 16 checks / 516 cycles, errors=0. `QTY_SYNTH=1`, no latches.
Enable=0 is **33 ports / no cells**; Enable=1 is **100577 cells /
19138 flip-flops**. Blob identity `g6lc_apu_qty.sv`
`2d0a66ca792a542c65c86c066b72c9e690a530a1`. `FeatureVirgl` stays
illegal.

### VenusCtrl private config and QueueNotify (RTL, 2026-10-01)

`g6lc_apu_vct` / `VctEn` after `QtyEn`. Default 0. Instantiates
VenusCapset and QueueType. Private `virtio_gpu_config.num_capsets`
reads as 1 and GET_CAPSET_INFO index 0 is Venus id 4. QueueNotify of
control queue 0 fires QueueType. Cursor queue 1 faults. Index 1
INFO faults. `ApuCfg.NumCapsets` stays 0; this is not virtio_mmio
advertisement. `g6lc_apu_vgpu_avail` still faults NEXT and was not
edited. Private `Flist.apu_vct` / `tb_g6lc_apu_vct`. Not in
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_vct` 9 cases / 22
checks / 566 cycles, errors=0. `VCT_SYNTH=1`, no latches. Enable=0
is **33 ports / no cells**; Enable=1 is **101726 cells / 19670
flip-flops**. Blob identity `g6lc_apu_vct.sv`
`7f8f502ed9a3436092a8fd7cb439da0f943a47e8`. `FeatureVirgl` stays
illegal.

### QueuePump drain until EMPTY (RTL, 2026-10-01)

`g6lc_apu_qpu` / `QpuEn` after `VctEn`. Default 0. Instantiates
VenusCtrl. QueueNotify of control queue 0 fires VenusCtrl until
AvailNext is EMPTY. Two pending GET_CAPSET_INFO descriptors publish
twice. CFG and INFO pass through once. `gnh_only` fires once. Cursor
queue 1 faults. `ApuCfg.NumCapsets` stays 0. `g6lc_apu_vgpu_avail`
still faults NEXT and was not edited. Private `Flist.apu_qpu` /
`tb_g6lc_apu_qpu`. Not in `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_qpu` 10 cases / 24 checks / 735 cycles, errors=0.
`QPU_SYNTH=1`, no latches. Enable=0 is **33 ports / no cells**;
Enable=1 is **103215 cells / 20298 flip-flops**. Blob identity
`g6lc_apu_qpu.sv` `3c4d5c69cda4db3ea58751e5350dc0fb960ad920`.
`FeatureVirgl` stays illegal.

### NotifyTake consume notify_pending (RTL, 2026-10-01)

`g6lc_apu_ntk` / `NtkEn` after `QpuEn`. Default 0. Instantiates
QueuePump. `arm` latches control-queue bases. virtio-mmio
`notify_pending[0]` drains that queue and pulses `notify_clear[0]`.
A doorbell before `arm` faults and still clears. Cursor
`notify_pending[1]` faults. CFG still passes through. `ApuCfg.NumCapsets`
stays 0. `g6lc_apu_virtio_mmio` was not edited. Private
`Flist.apu_ntk` / `tb_g6lc_apu_ntk`. Not in `g6lc_apu_sys`. Remote
2026-10-01: `tb_g6lc_apu_ntk` 6 cases / 12 checks / 160 cycles,
errors=0. `NTK_SYNTH=1`, no latches. Enable=0 is **35 ports / no
cells**; Enable=1 is **105435 cells / 21314 flip-flops**. Blob
identity `g6lc_apu_ntk.sv` `7e1f87647d7adc37daf9476c92172350c2d10ad7`.
`FeatureVirgl` stays illegal.

### VqTake vq_state arms NotifyTake (RTL, 2026-10-01)

`g6lc_apu_vqt` / `VqtEn` after `NtkEn`. Default 0. Instantiates
NotifyTake. virtio `vq_state[0]` (`desc`/`avail`/`used`/`num`/`ready`)
arms the control queue on `notify_pending[0]`. A doorbell with
`ready=0` faults and still clears. Cursor `notify_pending[1]` faults.
CFG still passes through. `ApuCfg.NumCapsets` stays 0.
`g6lc_apu_virtio_mmio` was not edited. Private `Flist.apu_vqt` /
`tb_g6lc_apu_vqt`. Not in `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_vqt` 6 cases / 11 checks / 163 cycles, errors=0.
`VQT_SYNTH=1`, no latches. Enable=0 is **37 ports / no cells**;
Enable=1 is **108797 cells / 22150 flip-flops**. Blob identity
`g6lc_apu_vqt.sv` `53433ebd12ef1c9b53d8fc6f574f78d1e3c1c53f`.
`FeatureVirgl` stays illegal.

### VqAxi guest beats on 64-bit AXI (RTL, 2026-10-01)

`g6lc_apu_vax` / `VaxEn` after `VqtEn`. Default 0. Instantiates
VqTake with Enable=1. 4-byte windows use SIZE=2; 8-byte and longer
windows use SIZE=3 INCR. Beat count is `len[7:3]` when `len>4`.
The converter is its own Enable-gated AXI master; it does not use
`dma_read` (`ApuHarness.DmaReadEn` stays 0). `ApuCfg.NumCapsets`
stays 0. `g6lc_apu_virtio_mmio` was not edited. Private
`Flist.apu_vax` / `tb_g6lc_apu_vax`. Not in `g6lc_apu_sys`. Not
wired onto testharness `slave[2]` (`tdma` already owns that join).
Remote 2026-10-01: `tb_g6lc_apu_vax` 6 cases / 11 checks / 287
cycles, errors=0. `VAX_SYNTH=1`, no latches. Enable=0 is **21 ports
/ no cells**; Enable=1 is **111519 cells / 22766 flip-flops**. Blob
identity `g6lc_apu_vax.sv` `765524d4a7c089c1f9392563362bc63edf2664b7`.
`FeatureVirgl` stays illegal.

### VenusAlloc vkAllocateCommandBuffers ALLOC CMDBUF (RTL, 2026-10-01)

`g6lc_apu_vac` / `VacEn` after `VaxEn`. Default 0. Instantiates
GenHandle. Mesa `vn_protocol` command type 88, sType 40, count 1,
PRIMARY level, then ALLOC CMDBUF. GENERATE_REPLY writes type +
VK_SUCCESS + the published handle. Duplicate live object ids,
`vkCreateShaderModule`, `vkCreateInstance`, `vkCmdDispatch`,
secondary level, a null info pointer, a zero guest id, and a
high-half handle fault. `ApuCfg.NumCapsets` stays 0. Private
`Flist.apu_vac` / `tb_g6lc_apu_vac`. Not in `g6lc_apu_sys`. Remote
2026-10-01: `tb_g6lc_apu_vac` 12 cases / 18 checks / 1016 cycles,
errors=0. `VAC_SYNTH=1`, no latches. Enable=0 is **12 ports / no
cells**; Enable=1 is **4931 cells / 1569 flip-flops**. Blob identity
`g6lc_apu_vac.sv` `9f57062cf290912ca1f7961df77cee8c64accf6b`.
`FeatureVirgl` stays illegal.

### HandleAlloc ALLOC then dispatch LOOKUP (RTL, 2026-10-01)

`g6lc_apu_hal` / `HalEn` after `VacEn`. Default 0. Instantiates
GenHandle and VenusDispatch on one table. `vkAllocateCommandBuffers`
ALLOCs CMDBUF; `vkCmdDispatch` looks up that published handle.
Dispatch before allocate, a MODULE handle, `vkCreateInstance`, and
a duplicate live object id fault. `ApuCfg.NumCapsets` stays 0.
Private `Flist.apu_hal` / `tb_g6lc_apu_hal`. Not in `g6lc_apu_sys`.
Remote 2026-10-01: `tb_g6lc_apu_hal` 8 cases / 15 checks / 479
cycles, errors=0. `HAL_SYNTH=1`, no latches. Enable=0 is **13 ports
/ no cells**; Enable=1 is **9178 cells / 2262 flip-flops**. Blob
identity `g6lc_apu_hal.sv` `993148e8a1e4bf0819e88a4ef8bd12fb3a400729`.
`FeatureVirgl` stays illegal.

### AllocRun ALLOC then CREATE then DISPATCH (RTL, 2026-10-01)

`g6lc_apu_aru` / `AruEn` after `HalEn`. Default 0. Instantiates
VenusEncode, GenHandle, VenusDispatch, and SpirvSubset on one
table. `vkAllocateCommandBuffers` ALLOCs CMDBUF;
`vkCreateShaderModule` commits SPIR-V; `vkCmdDispatch` looks up
that CMDBUF and kicks 2+3=5 then 4+5=9. Dispatch before create,
dispatch before create after allocate, a MODULE handle as cmdbuf,
and `vkCreateInstance` fault. `ApuCfg.NumCapsets` stays 0. Private
`Flist.apu_aru` / `tb_g6lc_apu_aru`. Not in `g6lc_apu_sys`. Remote
2026-10-01: `tb_g6lc_apu_aru` 7 cases / 13 checks / 914 cycles,
errors=0. `ARU_SYNTH=1`, no latches. Enable=0 is **17 ports / no
cells**; Enable=1 is **81337 cells / 13796 flip-flops**. Blob
identity `g6lc_apu_aru.sv` `b9651bfd98b9d309f136978b16cc48aea0ee51b7`.
`FeatureVirgl` stays illegal.

### QueueAlloc AvailNext into AllocRun (RTL, 2026-10-01)

`g6lc_apu_qal` / `QalEn` after `AruEn`. Default 0. Instantiates
AvailNext and AllocRun. Guest CS ALLOC/CREATE/DISPATCH on one
table. DISPATCH writes the SPIR-V result, `used.idx`, and ISR.
ALLOC and CREATE write nothing. EMPTY fetches nothing. Dispatch
before create faults. `ApuCfg.NumCapsets` stays 0. Private
`Flist.apu_qal` / `tb_g6lc_apu_qal`. Not in `g6lc_apu_sys`. Remote
2026-10-01: `tb_g6lc_apu_qal` 4 cases / 11 checks / 377 cycles,
errors=0. `QAL_SYNTH=1`, no latches. Enable=0 is **33 ports / no
cells**; Enable=1 is **86349 cells / 15155 flip-flops**. Blob
identity `g6lc_apu_qal.sv` `259b7ecd5941878d57a2e01d22781a2105da73bf`.
`FeatureVirgl` stays illegal.

### QueueTypeAlloc type word selects GrantCapset or QueueAlloc (RTL, 2026-10-01)

`g6lc_apu_qta` / `QtaEn` after `QalEn`. Default 0. Instantiates
AvailNext, GrantCapset, and QueueAlloc. GET_CAPSET/INFO select
Venus; ALLOC/CREATE/DISPATCH select QueueAlloc. `ApuCfg.NumCapsets`
stays 0. Private `Flist.apu_qta` / `tb_g6lc_apu_qta`. Not in
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_qta` 6 cases / 16
checks / 547 cycles, errors=0. `QTA_SYNTH=1`, no latches. Enable=0
is **33 ports / no cells**; Enable=1 is **100760 cells / 18263
flip-flops**. Blob identity `g6lc_apu_qta.sv`
`595acc12eb6acfc5b00d83aa062dc8341ad54331` after Idle holds
`capset_q` except `gnh_only`. `FeatureVirgl` stays illegal.

### VenusCtrlAlloc private CFG and QueueNotify into QueueTypeAlloc (RTL, 2026-10-01)

`g6lc_apu_vca` / `VcaEn` after `QtaEn`. Default 0. Instantiates
VenusCapset and QueueTypeAlloc. `virtio_gpu_config.num_capsets`
reads as 1; GET_CAPSET_INFO index 0 is Venus id 4. QueueNotify of
control queue 0 fires QueueTypeAlloc. Cursor queue 1 faults.
`ApuCfg.NumCapsets` stays 0. Private `Flist.apu_vca` /
`tb_g6lc_apu_vca`. Not in `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_vca` 9 cases / 22 checks / 597 cycles, errors=0.
`VCA_SYNTH=1`, no latches. Enable=0 is **33 ports / no cells**;
Enable=1 is **101912 cells / 18796 flip-flops**. Blob identity
`g6lc_apu_vca.sv` `062b1d14124c7ccedee29598ab5b57f722da4c24`.
`FeatureVirgl` stays illegal.

### QueuePumpAlloc drain until EMPTY (RTL, 2026-10-01)

`g6lc_apu_qpa` / `QpaEn` after `VcaEn`. Default 0. Instantiates
VenusCtrlAlloc. QueueNotify of control queue 0 fires VenusCtrlAlloc
until AvailNext is EMPTY. Two pending GET_CAPSET_INFO descriptors
publish twice. Type 88 ALLOC, CREATE, and DISPATCH ride the same
drain. CFG and INFO pass through once. `gnh_only` fires once. Cursor
queue 1 faults. QueueTypeAlloc holds `capset_q` across Idle except
`gnh_only` so a pump EMPTY peek keeps the GrantCapset ISR.
`ApuCfg.NumCapsets` stays 0. `g6lc_apu_vgpu_avail` still faults NEXT
and was not edited. Private `Flist.apu_qpa` / `tb_g6lc_apu_qpa`.
Not in `g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_qpa` 10
cases / 24 checks / 770 cycles, errors=0. `QPA_SYNTH=1`, no
latches. Enable=0 is **33 ports / no cells**; Enable=1 is **103410
cells / 19425 flip-flops**. Blob identity `g6lc_apu_qpa.sv`
`89cc46e92abb131dea47a703078d820b4fae924f`. `FeatureVirgl` stays
illegal.

### NotifyTakeAlloc consume notify_pending into QueuePumpAlloc (RTL, 2026-10-01)

`g6lc_apu_nta` / `NtaEn` after `QpaEn`. Default 0. Instantiates
QueuePumpAlloc. `arm` latches control-queue bases. virtio-mmio
`notify_pending[0]` drains that ALLOC pump and pulses
`notify_clear[0]`. A doorbell before `arm` faults and still clears.
Cursor `notify_pending[1]` faults. Type 88 ALLOC rides the doorbell.
CFG still passes through. `ApuCfg.NumCapsets` stays 0.
`g6lc_apu_virtio_mmio` was not edited. Private `Flist.apu_nta` /
`tb_g6lc_apu_nta`. Not in `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_nta` 7 cases / 13 checks / 241 cycles, errors=0.
`NTA_SYNTH=1`, no latches. Enable=0 is **35 ports / no cells**;
Enable=1 is **105632 cells / 20442 flip-flops**. Blob identity
`g6lc_apu_nta.sv` `bff651eb3a65b54fc752db9b4707242c55211182`.
`FeatureVirgl` stays illegal.

### VqTakeAlloc vq_state arms NotifyTakeAlloc (RTL, 2026-10-01)

`g6lc_apu_vqa` / `VqaEn` after `NtaEn`. Default 0. Instantiates
NotifyTakeAlloc. virtio `vq_state[0]` (desc/avail/used/num/ready)
arms on `notify_pending[0]`. Ports are `vq0_i`/`vq1_i`. A doorbell
with `ready=0` faults and still clears. Cursor `notify_pending[1]`
faults. Type 88 ALLOC rides the doorbell. CFG still passes through.
`ApuCfg.NumCapsets` stays 0. `g6lc_apu_virtio_mmio` was not edited.
Private `Flist.apu_vqa` / `tb_g6lc_apu_vqa`. Not in `g6lc_apu_sys`.
Remote 2026-10-01: `tb_g6lc_apu_vqa` 7 cases / 12 checks / 243
cycles, errors=0. `VQA_SYNTH=1`, no latches. Enable=0 is **37 ports
/ no cells**; Enable=1 is **108997 cells / 21279 flip-flops**. Blob
identity `g6lc_apu_vqa.sv` `084a8881599d36791200260ba1155906bdd170b6`.
`FeatureVirgl` stays illegal.

### VqAxiAlloc guest beats on 64-bit AXI (RTL, 2026-10-01)

`g6lc_apu_vaa` / `VaaEn` after `VqaEn`. Default 0. Instantiates
VqTakeAlloc and converts rd/wr beats to 64-bit AXI. 4-byte windows
use SIZE=2; 8-byte and longer use SIZE=3 INCR. nbeat is 1 when
`len<=4` else `3'(len[7:3])`. AXI req is `always_comb` `'0` then
field assigns. Type 88 ALLOC rides the doorbell. Converter does not
use `dma_read`. Not wired onto testharness `slave[2]`.
`ApuCfg.NumCapsets` stays 0. Private `Flist.apu_vaa` /
`tb_g6lc_apu_vaa`. `run-apu-vaa.sh` includes `apu_axi.vlt`. Not in
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_vaa` 7 cases / 12
checks / 426 cycles, errors=0. `VAA_SYNTH=1`, no latches. Enable=0
is **21 ports / no cells**; Enable=1 is **111719 cells / 21895
flip-flops**. Blob identity `g6lc_apu_vaa.sv`
`a46222cd12debc20ce5fcf7282c11fcbd89fc96b`. `FeatureVirgl` stays
illegal.

### VenusBegin Mesa vn_protocol vkBeginCommandBuffer (RTL, 2026-10-01)

`g6lc_apu_vbg` / `VbgEn` after `VaaEn`. Default 0. Mesa
`vn_protocol` `vkBeginCommandBuffer` CS: command type 90, sType 42,
LP64 command-buffer handle, PRIMARY null inheritance.
GENERATE_REPLY writes type + VK_SUCCESS at `APU_VBG_REPLY=12`.
`vkAllocateCommandBuffers` (88), `vkCreateShaderModule` (59),
`vkCreateInstance` (0), `vkCmdDispatch` (110), `vkEndCommandBuffer`
(91), a null info pointer, a null command buffer, and a non-null
inheritance pointer fault. `ApuCfg.NumCapsets` stays 0. Private
`Flist.apu_vbg` / `tb_g6lc_apu_vbg`. Not in `g6lc_apu_sys`. Remote
2026-10-01: `tb_g6lc_apu_vbg` 11 cases / 17 checks / 350 cycles,
errors=0. `VBG_SYNTH=1`, no latches. Enable=0 is **12 ports / no
cells**; Enable=1 is **1947 cells / 708 flip-flops**. Blob identity
`g6lc_apu_vbg.sv` `4595d4b85875068f6017ca626df1fb2e50c36842`.
`FeatureVirgl` stays illegal.

### BeginAlloc ALLOC CMDBUF then BEGIN LOOKUP (RTL, 2026-10-01)

`g6lc_apu_bal` / `BalEn` after `VbgEn`. Default 0. Instantiates one
GenHandle plus VenusBegin. `vkAllocateCommandBuffers` ALLOCs
CMDBUF; `vkBeginCommandBuffer` LOOKUPs that published handle.
Begin before allocate, MODULE-as-cmdbuf, duplicate live object ids,
and `vkCreateInstance` fault. Packed-struct rec writes are
whole-struct `'{ }`. The request field is `begin_cmd` (`begin` is a
Verilog keyword). `ApuCfg.NumCapsets` stays 0. Private
`Flist.apu_bal` / `tb_g6lc_apu_bal`. Not in `g6lc_apu_sys`. Remote
2026-10-01: `tb_g6lc_apu_bal` 8 cases / 17 checks / 554 cycles,
errors=0. `BAL_SYNTH=1`, no latches. Enable=0 is **13 ports / no
cells**; Enable=1 is **9018 cells / 2134 flip-flops**. Blob
identity `g6lc_apu_bal.sv` `c73c5b687d7784b6ee4fd19d0c9c734631755452`.
`FeatureVirgl` stays illegal.

### BeginRun ALLOC BEGIN CREATE DISPATCH (RTL, 2026-10-01)

`g6lc_apu_bru` / `BruEn` after `BalEn`. Default 0. Instantiates
VenusEncode, GenHandle, VenusBegin, VenusEnd, VenusDispatch, and
SpirvSubset. `vkAllocateCommandBuffers` ALLOCs CMDBUF;
`vkBeginCommandBuffer` LOOKUPs that published handle;
`vkCreateShaderModule` commits SPIR-V; `vkCmdDispatch` LOOKUPs
the begun CMDBUF and kicks 2+3=5 then 4+5=9; `vkEndCommandBuffer`
LOOKUPs the begun handle and clears recording. Begin before
allocate, dispatch before begin or create, end before begin, a
second end, dispatch after end, MODULE-as-cmdbuf,
`vkEndCommandBuffer` as begin, and `vkCreateInstance` fault.
Packed-struct rec writes are whole-struct `'{ }`. The record
field is `begin_cmd` (`begin` is a Verilog keyword).
`ApuCfg.NumCapsets` stays 0. Private `Flist.apu_bru` /
`tb_g6lc_apu_bru`. Not in `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_bru` 11 cases / 27 checks / 1275 cycles, errors=0.
`BRU_SYNTH=1`, no latches. Enable=0 is **17 ports / no cells**;
Enable=1 is **85788 cells / 15090 flip-flops**. Blob identity
`g6lc_apu_bru.sv` `8fb345838eed9da2df4358b1d6070f771d2c357a`.
`FeatureVirgl` stays illegal.

### QueueBegin AvailNext into BeginRun (RTL, 2026-10-01)

`g6lc_apu_qbn` / `QbnEn` after `BruEn`. Default 0. Instantiates
AvailNext plus BeginRun. Guest CS type 88 ALLOC, 90 BEGIN, 59
CREATE, 110 DISPATCH, 91 END. DISPATCH writes 4-byte result then
used elem then used.idx then ISR. ALLOC, BEGIN, CREATE, and END
write nothing. Dispatch before begin or create, begin before
allocate, and end before allocate fault. Packed-struct rec writes
are whole-struct `'{ }`. Record fields are `begin_cmd` and
`end_cmd`. `ApuCfg.NumCapsets` stays 0. Private `Flist.apu_qbn` /
`tb_g6lc_apu_qbn`. Not in `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_qbn` 7 cases / 18 checks / 613 cycles, errors=0.
`QBN_SYNTH=1`, no latches. Enable=0 is **33 ports / no cells**;
Enable=1 is **88324 cells / 15809 flip-flops**. Blob identity
`g6lc_apu_qbn.sv` `92ff1b04a3ca1e415f3fc8e04112e86032172c4d`.
`FeatureVirgl` stays illegal.

### QueueTypeBegin type word mux (RTL, 2026-10-01)

`g6lc_apu_qtb` / `QtbEn` after `QbnEn`. Default 0. Instantiates
AvailNext, GrantCapset, and QueueBegin. GET_CAPSET/INFO select
Venus; type 88 ALLOC, 90 BEGIN, 59 CREATE, 110 DISPATCH, 91 END
select QueueBegin. Idle holds `capset_q` except `gnh_only`. Virgl
id 1 faults. Packed-struct rec writes are whole-struct `'{ }`.
`ApuCfg.NumCapsets` stays 0. Private `Flist.apu_qtb` /
`tb_g6lc_apu_qtb`. Not in `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_qtb` 6 cases / 19 checks / 647 cycles, errors=0.
`QTB_SYNTH=1`, no latches. Enable=0 is **33 ports / no cells**;
Enable=1 is **102730 cells / 18916 flip-flops**. Blob identity
`g6lc_apu_qtb.sv` `5bb60e3d98325a9a0a99b6c3cfd10ca3c9296c8d`.
`FeatureVirgl` stays illegal.

### VenusCtrlBegin private CFG and QueueNotify (RTL, 2026-10-01)

`g6lc_apu_vcb` / `VcbEn` after `QtbEn`. Default 0. Instantiates
VenusCapset plus QueueTypeBegin. Private `num_capsets` reads as 1.
GET_CAPSET_INFO index 0 is Venus id 4. QueueNotify of queue 0
fires QueueTypeBegin so type 90 BEGIN rides GET_CAPSET. Cursor
queue 1 faults. `ApuCfg.NumCapsets` stays 0; virtio_mmio was not
edited. Private `Flist.apu_vcb` / `tb_g6lc_apu_vcb`. Not in
`g6lc_apu_sys`. Remote 2026-10-01: `tb_g6lc_apu_vcb` 9 cases /
23 checks / 654 cycles, errors=0. `VCB_SYNTH=1`, no latches.
Enable=0 is **33 ports / no cells**; Enable=1 is **103161 cells /
19254 flip-flops**. Blob identity `g6lc_apu_vcb.sv`
`f3ce23d3be022f1180cb862f3b1a636dcdebf093`. `FeatureVirgl` stays
illegal.

### QueuePumpBegin drain until EMPTY (RTL, 2026-10-01)

`g6lc_apu_qpb` / `QpbEn` after `VcbEn`. Default 0. Instantiates
VenusCtrlBegin. QueueNotify of queue 0 drains AvailNext until
EMPTY so type 90 BEGIN rides GET_CAPSET. CFG and INFO fire once.
Cursor queue 1 faults. EMPTY copies the prior record including
IRQ. Packed-struct rec writes are whole-struct `'{ }`.
`ApuCfg.NumCapsets` stays 0. Private `Flist.apu_qpb` /
`tb_g6lc_apu_qpb`. Not in `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_qpb` 10 cases / 25 checks / 837 cycles, errors=0.
`QPB_SYNTH=1`, no latches. Enable=0 is **33 ports / no cells**;
Enable=1 is **104658 cells / 19884 flip-flops**. Blob identity
`g6lc_apu_qpb.sv` `64dfe3cbe502c5de18dba90fcb997873dd8f294e`.
`FeatureVirgl` stays illegal.

### NotifyTakeBegin doorbell into QueuePumpBegin (RTL, 2026-10-01)

`g6lc_apu_ntb` / `NtbEn` after `QpbEn`. Default 0. Instantiates
QueuePumpBegin. `arm` latches bases; `notify_pending[0]` drains
the pump; type 88 ALLOC and type 90 BEGIN ride the doorbell.
Cursor `notify_pending[1]` faults. The request field is `arm`.
`ApuCfg.NumCapsets` stays 0. Private `Flist.apu_ntb` /
`tb_g6lc_apu_ntb`. Not in `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_ntb` 7 cases / 14 checks / 317 cycles, errors=0.
`NTB_SYNTH=1`, no latches. Enable=0 is **35 ports / no cells**;
Enable=1 is **106882 cells / 20902 flip-flops**. Blob identity
`g6lc_apu_ntb.sv` `1531f3e2c623f144b7eb28b6a1d7cc672384bf51`.
`FeatureVirgl` stays illegal.

### VqTakeBegin vq_state arm (RTL, 2026-10-01)

`g6lc_apu_vqb` / `VqbEn` after `NtbEn`. Default 0. Instantiates
NotifyTakeBegin. virtio `vq_state[0]` (desc/avail/used/num/ready)
arms on `notify_pending[0]`. Ports are `vq0_i`/`vq1_i`. Type 88
ALLOC and type 90 BEGIN ride the doorbell. A doorbell with
`ready=0` faults and still clears. Cursor `notify_pending[1]`
faults. `ApuCfg.NumCapsets` stays 0. Private `Flist.apu_vqb` /
`tb_g6lc_apu_vqb`. Not in `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_vqb` 7 cases / 13 checks / 318 cycles, errors=0.
`VQB_SYNTH=1`, no latches. Enable=0 is **37 ports / no cells**;
Enable=1 is **110250 cells / 21740 flip-flops**. Blob identity
`g6lc_apu_vqb.sv` `3189bbb5b8f315386a390ab39f94b737407a97bc`.
`FeatureVirgl` stays illegal.

### VqAxiBegin guest beats on 64-bit AXI (RTL, 2026-10-01)

`g6lc_apu_vab` / `VabEn` after `VqbEn`. Default 0. Instantiates
VqTakeBegin and converts guest beats onto 64-bit AXI (SIZE=2 for
4-byte, SIZE=3 INCR for longer). Type 88 ALLOC and type 90 BEGIN
ride the doorbell. Converter does not use `dma_read`.
`ApuCfg.NumCapsets` stays 0. Private `Flist.apu_vab` /
`tb_g6lc_apu_vab`. Not in `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_vab` 7 cases / 13 checks / 553 cycles, errors=0.
`VAB_SYNTH=1`, no latches. Enable=0 is **21 ports / no cells**;
Enable=1 is **112972 cells / 22356 flip-flops**. Blob identity
`g6lc_apu_vab.sv` `8ad2dc1d5df866390a2e0ff567b1e41e65d6a2ad`.
`FeatureVirgl` stays illegal.

### VenusEnd Mesa vn_protocol vkEndCommandBuffer (RTL, 2026-10-01)

`g6lc_apu_ven` / `VenEn` after `VabEn`. Default 0. Mesa
`vn_protocol` `vkEndCommandBuffer` CS decoder (command type 91,
LP64 command-buffer handle). GENERATE_REPLY writes type +
`VK_SUCCESS` at `APU_VEN_REPLY=4`. `vkBeginCommandBuffer` (90),
`vkAllocateCommandBuffers` (88), `vkCreateShaderModule` (59),
`vkCreateInstance` (0), `vkCmdDispatch` (110), a null handle, and
a high-half handle fault. `ApuCfg.NumCapsets` stays 0. Private
`Flist.apu_ven` / `tb_g6lc_apu_ven`. Not in `g6lc_apu_sys`.
Remote 2026-10-01: `tb_g6lc_apu_ven` 10 cases / 16 checks / 165
cycles, errors=0. `VEN_SYNTH=1`, no latches. Enable=0 is **12
ports / no cells**; Enable=1 is **1590 cells / 644 flip-flops**.
Blob identity `g6lc_apu_ven.sv`
`267496e055d29fdf7cb4639e88d76c583f51697f`. `FeatureVirgl` stays
illegal.

### EndAlloc ALLOC then BEGIN LOOKUP then END LOOKUP (RTL, 2026-10-01)

`g6lc_apu_eal` / `EalEn` after `VenEn`. Default 0. One GenHandle
plus VenusBegin plus VenusEnd. `vkAllocateCommandBuffers` ALLOCs
CMDBUF; `vkBeginCommandBuffer` LOOKUPs that published handle;
`vkEndCommandBuffer` LOOKUPs the begun handle. Record field is
`end_cmd` (`end` is a Verilog keyword). End before allocate or
begin, MODULE-as-cmdbuf, a second end, and `vkCreateInstance`
fault. Packed-struct rec writes are whole-struct `'{ }`.
`ApuCfg.NumCapsets` stays 0. Private `Flist.apu_eal` /
`tb_g6lc_apu_eal`. Not in `g6lc_apu_sys`. Remote 2026-10-01:
`tb_g6lc_apu_eal` 10 cases / 22 checks / 778 cycles, errors=0.
`EAL_SYNTH=1`, no latches. Enable=0 is **13 ports / no cells**;
Enable=1 is **10853 cells / 2749 flip-flops**. Blob identity
`g6lc_apu_eal.sv` `2e1d9b13d84c4c0b8cfc567c0bb3848bcba764d6`.
`FeatureVirgl` stays illegal.

### VenusDestroy catalog RETIRE (RTL, 2026-10-02)

`g6lc_apu_vdf` / `VdfEn` type 81 LOOKUP FBUF then `APU_GNH_RETIRE`.
`g6lc_apu_vdx` / `VdxEn` type 58 LOOKUP VIEW then RETIRE.
`g6lc_apu_vdk` / `VdkEn` type 71 LOOKUP SAMPLER then RETIRE.
`g6lc_apu_vdr` / `VdrEn` type 83 LOOKUP RPASS then RETIRE.
`g6lc_apu_vdb` / `VdbEn` type 51 LOOKUP BUFFER then RETIRE.
`g6lc_apu_vdg` / `VdgEn` type 55 LOOKUP IMAGE then RETIRE.
`g6lc_apu_vfe` / `VfeEn` type 22 LOOKUP MEMORY then RETIRE.
`g6lc_apu_vdm` / `VdmEn` type 60 LOOKUP MODULE then RETIRE; clears
`loaded_q`. `g6lc_apu_vdp` / `VdpEn` type 67 LOOKUP PIPELINE then
RETIRE. `g6lc_apu_vdy` / `VdyEn` type 69 LOOKUP PLAYOUT then RETIRE.
`g6lc_apu_vdt` / `VdtEn` type 73 LOOKUP DSLAYOUT then RETIRE.
`g6lc_apu_vdq` / `VdqEn` type 75 LOOKUP POOL then RETIRE.
`g6lc_apu_vfs` / `VfsEn` type 78 LOOKUP DESCSET then RETIRE.
`g6lc_apu_vrc` / `VrcEn` type 92 LOOKUP CMDBUF (no RETIRE).
`g6lc_apu_vfc` / `VfcEn` type 89 LOOKUP CMDBUF then RETIRE.
`g6lc_apu_vdd` / `VddEn` type 12 LOOKUP DEVICE then RETIRE.
`g6lc_apu_vpc` / `VpcEn` type 87 LOOKUP DEVICE (no RETIRE).
`g6lc_apu_vdc` / `VdcEn` type 86 LOOKUP DEVICE (no RETIRE).
`g6lc_apu_vdn` / `VdnEn` type 1 LOOKUP INSTANCE then RETIRE.
`g6lc_apu_vgf` / `VgfEn` type 4 LOOKUP PHYS.
`g6lc_apu_vip` / `VipEn` type 5 LOOKUP PHYS.
`g6lc_apu_vxe` / `VxeEn` type 14 LOOKUP PHYS.
`g6lc_apu_vrd` / `VrdEn` type 76 LOOKUP POOL (no RETIRE).
`g6lc_apu_vie` / `VieEn` type 13 compact count 0 (no LOOKUP).
`g6lc_apu_vwl` / `VwlEn` type 20 LOOKUP DEVICE.
`g6lc_apu_vsl` / `VslEn` type 56 LOOKUP IMAGE.
`g6lc_apu_vrg` / `VrgEn` type 84 LOOKUP RPASS.
`g6lc_apu_vlw` / `VlwEn` type 96 LOOKUP CMDBUF.
`g6lc_apu_vzb` / `VzbEn` type 97 LOOKUP CMDBUF.
`g6lc_apu_vbc` / `VbcEn` type 98 LOOKUP CMDBUF.
`g6lc_apu_vbo` / `VboEn` type 99 LOOKUP CMDBUF.
`g6lc_apu_vcm` / `VcmEn` type 100 LOOKUP CMDBUF.
`g6lc_apu_vwm` / `VwmEn` type 101 LOOKUP CMDBUF.
`g6lc_apu_vrf` / `VrfEn` type 102 LOOKUP CMDBUF.
`g6lc_apu_vcc` / `VccEn` type 112 LOOKUP CMDBUF then BUFFER src/dst.
`g6lc_apu_vcy` / `VcyEn` type 113 LOOKUP CMDBUF then IMAGE src/dst.
`g6lc_apu_vbl` / `VblEn` type 114 LOOKUP CMDBUF then IMAGE src/dst.
`g6lc_apu_vbt` / `VbtEn` type 115 LOOKUP CMDBUF then BUFFER then IMAGE.
`g6lc_apu_vic` / `VicEn` type 116 LOOKUP CMDBUF then IMAGE then BUFFER.
`g6lc_apu_vub` / `VubEn` type 117 LOOKUP CMDBUF then BUFFER.
`g6lc_apu_vfl` / `VflEn` type 118 LOOKUP CMDBUF then BUFFER.
`g6lc_apu_vcl` / `VclEn` type 119 LOOKUP CMDBUF then IMAGE.
`g6lc_apu_vio` / `VioEn` type 108 LOOKUP CMDBUF then BUFFER in-RP.
`g6lc_apu_vix` / `VixEn` type 109 LOOKUP CMDBUF then BUFFER in-RP.
`g6lc_apu_vds` / `VdsEn` type 120 LOOKUP CMDBUF then IMAGE outside RP.
`g6lc_apu_vat` / `VatEn` type 121 LOOKUP CMDBUF in-RP.
`g6lc_apu_vin` / `VinEn` type 111 LOOKUP CMDBUF then BUFFER after end-RP.
`g6lc_apu_vrs` / `VrsEn` type 122 LOOKUP CMDBUF then IMAGE src/dst outside RP.
`g6lc_apu_vgs` / `VgsEn` type 38 LOOKUP DEVICE.
`g6lc_apu_vwf` / `VwfEn` type 39 LOOKUP DEVICE after submit.
`g6lc_apu_vfr` / `VfrEn` type 37 LOOKUP DEVICE.
`g6lc_apu_vfn` / `VfnEn` type 36 LOOKUP DEVICE, no RETIRE.
`APU_BRU_DFB=51` through `APU_BRU_DFE=102`. `apu_bru_op_e` is 7 bits.
bru FSM state enum is 8 bits. GENERATE_REPLY shares CS mux slot 31.
Happy path runs fence status/wait/reset/destroy after DeviceWaitIdle.
Remote 2026-10-02: vgs 8/13/377 Enable=1 **1781 / 708**; vwf 8/13/405
**1915 / 708**; vfr 8/13/391 **1815 / 708**; vfn 8/13/379
**1845 / 708**; bru 12/240/10017 Enable=1 **246341 / 59751**; qbn
7/115/5376 Enable=1 **234882 / 59694**; qtb 6/115/6933 Enable=1
**249033 / 62799**. Not in `g6lc_apu_sys`.
`FeatureVirgl` stays illegal. `NumCapsets` stays 0.

## Historical fixture census

**Domain:** graphics uncore · **Status:** the ceiling is read back, the scene header and the 960-byte execbuffer are fetched, the DRAW_VBO at byte 908 is recognized, its 24 NDC floats are an inline write of resource 3, the vertex buffer is stride 24, the fragment sampler view at byte 632 names handle 5, the sampler state at byte 616 names handle 6, the vertex elements at byte 608 name handle 4, the fragment shader at byte 596 names handle 3, the vertex shader at byte 584 names handle 2, the rasterizer bind at byte 576 names handle 9, the depth-stencil bind at byte 568 names handle 8, the blend bind at byte 560 names handle 7, the rasterizer object at byte 520 names handle 9, the depth-stencil object at byte 496 names handle 8, the blend object at byte 448 names handle 7 and color word 32'h78020010, the sampler-state object at byte 408 names handle 6, the sampler view at byte 380 names handle 5, the vertex-element object at byte 340 names handle 4, the fragment-shader object at byte 176 names handle 3, the vertex-shader object at byte 24 names handle 2, the surface object at byte 0 names handle 1, guest descriptors at 64'h8800E100 link the header, the 960-byte execbuffer, and the 24-byte response, avail index 1 at 64'h8800E200 names descriptor 0, the completed-opcode list at 64'h8800E300 is count 0 and capset id 0, the virgl capset stays refused, a 64 by 64 guest window at 64'h88020000 is 512 beats of clear word 32'hFF1A0D0D, the guest response at 64'h8800A800 is OK_NODATA with fence 64'h1122334455667788, the used element at 64'h8800E400 is descriptor 0 and length 24, the used index at 64'h8800E480 is 1, the used-buffer interrupt reason at 64'h8800E500 is 32'h1 and ack lowers the pin, the guest ack at 64'h8800E510 is 32'h1 and the status word at 64'h8800E500 is then 32'h0, all 512 beats of the window are that clear word and are copied to 64'h88030000 as a 64 by 64 rectangle of 16384 bytes, with `(1,0)` at byte 4 and row 1 at byte 256, the clear word in memory is the bytes 0D 0D 1A FF so byte 0 is red, row 1 at 64'h88030100 starts with that red byte, (1,1) is byte 260, (2,3) is byte 776, and (0,63) is byte 16128, (63,0) is byte 252 at 64'h880300E0, (7,0) is byte 28, (8,0) is byte 32 and (15,0) is byte 60 in 64'h88030020, (56,0) is byte 224 lane 0 of 64'h880300E0 and (63,0) stays byte 252 lane 7 of that beat, (16,0) is byte 64 and (23,0) is byte 92 in 64'h88030040, (24,0) is byte 96 and (31,0) is byte 124 in 64'h88030060, (32,0) is byte 128 and (39,0) is byte 156 in 64'h88030080, (40,0) is byte 160 and (47,0) is byte 188 in 64'h880300A0, (48,0) is byte 192 and (55,0) is byte 220 in 64'h880300C0, (63,63) is byte 16380, the linear sample pair is written as fragment color at 64'h88050000 with (0,0) the clamp texel 32'hA5000000 and (1,0) the half blend 32'hD2008000, those 512 ceiling sample beats are copied to 64'h88060000 as a 64 by 64 rectangle whose (1,0) is the half blend 32'hD2008000 and (0,0) is the clamp texel 32'hA5000000, that rectangle is copied to 64'h88070000 as TRANSFER_FROM_HOST_3D of resource 4, that guest buffer is a 64 by 64 rectangle whose (1,0) is the half blend 32'hD2008000, offset in that guest rectangle is y * 256 + x * 4, (0,0) is the clamp texel 32'hA5000000, (63,63) is byte 16380 at 64'h88073FE0, the TRANSFER_FROM_HOST_3D box is (0,0,64,64) of resource 4 at 640 by 480 with packed stride 256 at 64'h88080000, RESOURCE_ATTACH_BACKING of that buffer is length 16384 at 64'h88090000, the 24-byte OK_NODATA of that transfer is at 64'h880A0000 with fence 2, the used element is at 64'h880B0000 with id 1 and used.idx 2 at 64'h880B0008, the used-buffer interrupt reason 32'h1 is at 64'h880C0000, the guest ack of that interrupt is at 64'h880C0010 and remain 0 is then written over 64'h880C0000, the guest descriptor chain of that transfer is at 64'h880D0000 with avail index 2 at 64'h880D0100, TEX of sampler view 5 at (0,0) is 32'hA5000000 and at (1,0) is 32'hD2008000 with refused 0, beat 0 of the scene window at 64'h88020000 is that pair, beat 0 of the guest readback at 64'h88030000 is that pair, a posted walker accepts NEXT for that transfer chain at avail index 2, guest QueueNotify of control queue 0 is at 64'h880D0200, guest virtq_avail.idx after that notify is 2 at 64'h880D0100, guest virtq_avail.ring[0] names descriptor 0 at 64'h880D0104, guest virtq_desc 0 is the attach at 64'h88090000 with NEXT to 1, guest virtq_desc 1 is the transfer at 64'h88080000 with NEXT to 2, guest virtq_desc 2 is the WRITE of the 24-byte response at 64'h880A0000, guest OK_NODATA after that WRITE is fence 2 at 64'h880A0000, guest used element after that OK_NODATA is id 1 / used.idx 2, guest used-buffer interrupt after that index is reason 32'h1 at 64'h880C0000, guest ack of that interrupt is 32'h1 at 64'h880C0010, scene virtq_avail.idx after that ack is 1 at 64'h8800E200, scene virtq_avail.ring[0] names descriptor 0 at 64'h8800E204, scene virtq_desc 0 is the 32-byte header at 64'h8800A000 with NEXT to 1, scene virtq_desc 1 is the 960-byte execbuffer at 64'h8800B000 with NEXT to 2, scene virtq_desc 2 is the WRITE of the 24-byte response at 64'h8800A800, scene OK_NODATA after that WRITE is the scene fence at 64'h8800A800, scene used element after that OK_NODATA is id 0 / used.idx 1 at 64'h8800E400 / 64'h8800E480, scene used-buffer interrupt after that index is reason 32'h1 at 64'h8800E500, scene guest ack of that interrupt is 32'h1 at 64'h8800E510, a posted walker accepts NEXT for the scene submit chain at avail index 1, scene QueueNotify of control queue 0 is at 64'h8800E220, scene virtq_avail.idx after that notify is 1 at 64'h8800E200, scene virtq_avail.ring[0] names descriptor 0 at 64'h8800E204 after that index, scene virtq_desc 0 is the header at 64'h8800A000 with NEXT to 1, scene virtq_desc 1 is the execbuffer at 64'h8800B000 with NEXT to 2, scene virtq_desc 2 is the WRITE of the 24-byte response at 64'h8800A800, scene OK_NODATA after that WRITE is the scene fence at 64'h8800A800, scene used element after that OK_NODATA is id 0 / used.idx 1 at 64'h8800E400 / 64'h8800E480, the viewport and scissor are the 640 by 480 rectangle, the clear color is 32'hFF1A0D0D, and one color buffer names surface 1; no blend is applied; no texture is bound; avail still rejects NEXT; screenshot gate open
**Scaffold only** (`architecture/README.md`). This page is the map. Leaf counts live in
`apu-resident-fw.md` and `AGENTS-todo.md`. Gates A0–A7 are the API-neutral plan
`plan-5ddc97674e5bf9b0.md`. The frozen scene is `g6lc_bios/architecture/DISPLAY.md`.

The historical baseline `d74010111` contains the SoC box. Later commits
`43cb9850f` and `4be7eb573` added scene-census/substrate and HDMI work respectively;
tracked and dirty/untracked fixtures now coexist. Membership in a commit or a
private flist is not integrated rendering evidence. Preserve those historical
results and use §15 of the interplay map for the current reviewed boundaries.

## 1. Intent

The device is API-neutral. EGL/GLES2 and Vulkan remain client-side APIs. The
strict endpoint is unchanged stock Linux/Mesa and ordinary applications without
an APU-specific runtime backend. The historical virgl/TGSI firmware route remains
a development lane until a compliant final architecture is demonstrated.

G0 retains a 64×64 RGBA8 glReadPixels result as raw bytes and normalized PPM, with
source, program, driver, RTL and configuration identities. A5 requires the
protection/deployment/protocol/resource-backed execution gates together; a lab
surface or llvmpipe reference image is not device evidence. The exact probe and
BIOS-stream golden still need reconciliation against DISPLAY.md's named P0 wire
contract headings, not the stale section-7 reference.

The approved scope now includes independent shader/data mutations, stock Ubuntu,
Unreal SM5 and later CS2. BIOS remains an optional sequential client with its own
boot-health lifecycle and release cycle; graphics readiness cannot confirm Linux
boot health. Rendering, presentation and AI stay independently gated. Reuse of
AI arithmetic/storage mechanisms does not turn GEMM into a shader engine or make
the graphics runtime depend on MatrixEn. HDMI qualification remains separate.


## 2. Where the code lives

| Layer | Path | What it is |
|---|---|---|
| SoC box | `corev_apu/apu/g6lc_apu_{attach,soc,sys,grant,axi_lite,top,virtio_mmio,control,sched,mbox,mem,queue,exec,exec_bind,fwram,xbar,th,th_load}.sv` | Tracked device. `Flist.apu_soc`. Default `ApuOff`. |
| Config | `corev_apu/include/g6lc_apu_cfg_pkg.sv` | `apu_cfg_t`. Graphics bits default to 0. `FeatureVirgl` is outside `APU_IMPL_FEATURES`. |
| Command and surface units | `corev_apu/apu/g6lc_apu_vgpu_*.sv`, `g6lc_apu_cover.sv`, `g6lc_apu_frag.sv`, `g6lc_apu_rsurf.sv` | Private fixtures, with tracked and working-tree changes. One private `Flist.apu_*` and `verif/tb/apu/` suite each, through the rasterizer bind. |
| Types | `corev_apu/apu/include/g6lc_apu_pkg.sv` | Virtio and virgl ids, record types, image ceiling. |
| Firmware | `software/apu-fw` | Hart-1 mailbox images and one TGSI subset compiler. |
| Scene and encoder | `g6lc_bios/architecture/DISPLAY.md`, `g6lc_bios/crates/g6b-asm/src/{encode,virgl}.rs` | Frozen P0 profile and the execbuffer the decoders match. |
| Guest probe | `g6lc_qemu/openwrt/patches/files/package/g6lc-egl-probe/src/g6lc_egl_probe.c` | The 64×64 readback the screenshot uses. |
| HDMI | `corev_apu/hdmi/`, outline `hdmi-display.md` | Separate scanout; committed leaf plus any working-tree changes. |
| This tree | `architecture/uncore/apu-*.md` | One outline per substrate seam. This file is the lane map. |

Three-letter command-unit ids such as `vsb`, `sny`, and `gnw` are local
LibreCore leaf names. The PascalCase alias and a one-line description sit
on the first declaration of each grant bit in `g6lc_apu_cfg_pkg.sv`
(`apu_cfg_t.VsbEn`, `SnyEn`, `GnwEn`, ...), on the matching
`apu_vgpu_*_t` / status / completion types in `g6lc_apu_pkg.sv`, and
above each `module g6lc_apu_vgpu_*` and its enable-0 fixture. The
arborescence of those names as ready/valid “calls” is
[`corev_apu/apu/AGENTS-impl-interplays.md`](../../corev_apu/apu/AGENTS-impl-interplays.md).

`g6lc_apu_attach` is the SoC window and PLIC splice. Virtio `RESOURCE_ATTACH_BACKING` is the
private unit `g6lc_apu_vgpu_back`. `g6lc_apu_queue`, inside `g6lc_apu_mem`, is the older DMA
used ring and still takes a raw map. The private used-ring units are `g6lc_apu_vgpu_used`,
`g6lc_apu_vgpu_uwr`, and `g6lc_apu_vgpu_uidx`.

## 3. SoC box versus private fixtures

```text
Linux Mesa / BIOS virtio client
        │  EGL and GLESv2 stay here
        ▼
guest gpu@0x40001000 / 4 KiB, PLIC 9          control 0x40002000 / 4 KiB
        │                                      firmware RAM 0x90000000 / 256 KiB
        ▼
g6lc_apu_attach
  g6lc_apu_soc                         default ApuCfg = ApuOff
    g6lc_apu_grant                     testharness passes ApuHarness
    g6lc_apu_sys
      g6lc_apu_axi_lite
        g6lc_apu_top
          g6lc_apu_virtio_mmio         transport registers
        g6lc_apu_control
      g6lc_apu_sched                   one mailbox op to memory or to exec
        g6lc_apu_mem                   storage, DMA, g6lc_apu_queue
        g6lc_apu_exec_bind
          g6lc_apu_exec                one FPnew lane, local DMEM
```

`Flist.apu_soc` is the attach list (grant, sys, exec, firmware RAM, the load compositor).
The file header says it is not on the production testharness flist. `+define+G6LC_APU` is the
diagnostic testharness composition. Module defaults are `ApuOff`. `ariane_testharness.sv`
passes `ApuHarness` into `g6lc_apu_th_load`. Both configs leave `ExecEn` and every graphics
enable at 0. The command units are not instantiated on that path, so a Linux guest there
has no MMIO path into them.

Those units are elaborated only by their own testbenches. Each proven unit has a default-off
bit on `apu_cfg_t`, a private flist, `verif/tb/apu/tb_g6lc_apu_*.sv`, and `run-apu-*.sh`.
`Enable=0` keeps the fixture at ports and no cells. `apu_cfg_legal` does not treat the bits
as `FeatureVirgl`. Turning a bit on does not publish the virgl feature and does not add the
file to `Flist.apu_soc`.

Two virtio paths exist side by side:

| Path | What it accepts | What it refuses |
|---|---|---|
| `g6lc_apu_vgpu_avail` | One local avail slot whose descriptor is a 40-byte `RESOURCE_CREATE_2D` | `NEXT`, `WRITE`, `INDIRECT`. It does not read guest memory. |
| `g6lc_apu_vgpu_chn` | The scene chain only. Descriptor 0 links to 1 (header at `64'h8800A000`), 1 links to 2 (960 bytes at `64'h8800B000`), 2 is the 24-byte write at `64'h8800A800`. The avail index may advance by one. | `INDIRECT`, a jumped index, a short execbuffer. Does not read guest memory. |
| `g6lc_apu_vgpu_sub` | One `SUBMIT_3D` chain of descriptors 0, 1, and 2. Descriptor 0 is a 32-byte header read from `64'h8800A000`. Length 960 is accepted. Ceiling is 1024. | `INDIRECT`, a broken link, a second submit. Descriptor 1 is named and not read here. The response address is recorded; `g6lc_apu_vgpu_rsp` writes the 24 bytes. |
| `g6lc_apu_vgpu_cmd` | `RESOURCE_CREATE_2D` for `R8G8B8A8_UNORM`, including 64×64. Fence id is echoed. | `SUBMIT_3D` returns `INVALID_PARAMETER` and creates no resource. |

`g6lc_apu_vgpu_buf` is the unit that reads the execbuffer named by the recorded submit,
32 bytes per beat, into a 1024-byte memory. A 960-byte buffer is 30 beats at `64'h8800B000`.

## 4. Integration seam

| Window | Address | Owner |
|---|---|---|
| Guest virtio-mmio | `0x40001000` / 4 KiB, PLIC source 9 | `g6lc_apu_attach`. Default DTB status disabled. |
| Control mailbox | `0x40002000` / 4 KiB | Firmware hart only. AXI id and PROT are not a grant. |
| Firmware RAM | `0x90000000` / 256 KiB | Same hart. Sign-extended aliases are outside the window. |
| AI island | `0x40000000`, PLIC source 8 | `AiCfg.MatrixEn`. Not a graphics window. |
| HDMI framebuffer | `0x8ef00000`, 640×480 `r5g6b5`, stride 1280 | `g6lc-simplefb.dtsi`. No board DTS includes it. `HdmiEn` is independent of `ApuOff`. |

Testbench guest addresses (`64'h88001000` and the `64'h8800A000`–`64'h8800C000` block) are
stand-ins inside the virtio suites. They are not the HDMI framebuffer and not a DRAM map
the SoC publishes.

The exec cluster is one FPnew FP32/integer lane over four lockstep invocation contexts,
local DMEM, and `LDC`. Exec `LD`/`ST` stays in that DMEM. Enabled configs name 4 threads,
8 registers, 16 IMEM words, and 64 DMEM words. Host and CVA6 call one compiler,
`g6lc_apu_tgsi_compile`. `TEX` returns `-26` on both. `IN`, `OUT`, and `CONST` still share
register numbers. The compiler is not linked into the pre-encoded mini-hart image, and TGSI
text is not merged into `apu_fw`. Cookies `0x600D000A` and `0x600D000B` show hart fetch of
those images. They are not a virtqueue and not a readback.

## 5. Config gating

Shipped literals `ApuOff`, `ApuP1Transport`, `ApuHarness`, `ApuSchedBoth`, and
`ApuBadVirglGrant` keep every graphics enable at 0. `ApuHarness.ExecEn` stays 0.
`FeatureVirgl` sets desired feature bit 0, which is outside `APU_IMPL_FEATURES`, so an
enabled config that asks for it is illegal. The implemented feature mask is virtio
`VERSION_1` and `RING_RESET`.

Each graphics unit adds one trailing `apu_cfg_t` field. Adding a field means writing it
on all five literals. The bits do not change `apu_cfg_legal` and do not make virgl legal.
`HdmiEn` is a separate knob and does not follow `ApuOff`, `ExecEn`, or `MatrixEn`.

`NrHarts` stays 1 in the internal package. The firmware hart is a second physical core.
The lane does not edit `build-opensbi-smt2.sh`.

## 6. Proven prefix and the rest of the stream

The frozen execbuffer is a sequence of virgl commands. Header dword is
`cmd[7:0] | object<<8 | body_dwords<<16`. Length is body dwords, excluding the header.
Each proven unit reads one command at the previous unit’s `next` byte. TGSI text stays
in the buffer. A bind stores the handle. It does not change the earlier create record.

| Bytes | Command | Module | `next` | What the record is |
|---|---|---|---|---|
| 0..24 | `CREATE_OBJECT` surface, handle 1, resource 4, format `B8G8R8X8` | `g6lc_apu_vgpu_dec` | 24 | First command |
| 24..176 | `CREATE_OBJECT` shader, handle 2, stage vertex, text length 125 | `g6lc_apu_vgpu_sh` | 176 | Text at byte 48 (`VERT`) |
| 176..340 | `CREATE_OBJECT` shader, handle 3, stage fragment, text length 140 | `g6lc_apu_vgpu_fs` | 340 | Text at byte 200 (`FRAG`) |
| 340..380 | `CREATE_OBJECT` vertex elements, handle 4 | `g6lc_apu_vgpu_ve` | 380 | Position at offset 0, uv at offset 16 |
| 380..408 | `CREATE_OBJECT` sampler view, handle 5, resource 1 | `g6lc_apu_vgpu_sv` | 408 | Identity swizzle. No fetch |
| 408..448 | `CREATE_OBJECT` sampler state, handle 6 | `g6lc_apu_vgpu_ss` | 448 | Clamp-to-edge, linear, `max_lod` 32.0. No fetch |
| 448..496 | `CREATE_OBJECT` blend, handle 7, color buffer 0 `32'h78020010` | `g6lc_apu_vgpu_bl` | 496 | No draw |
| 496..520 | `CREATE_OBJECT` depth-stencil, handle 8, state words 0 | `g6lc_apu_vgpu_ds` | 520 | Depth and stencil stay off |
| 520..560 | `CREATE_OBJECT` rasterizer, handle 9, state words 0 | `g6lc_apu_vgpu_rz` | 560 | Fill both faces, cull none. No walk |
| 560..568 | `BIND_OBJECT` blend, handle 7 | `g6lc_apu_vgpu_bb` | 568 | No draw |
| 568..576 | `BIND_OBJECT` depth-stencil, handle 8 | `g6lc_apu_vgpu_db` | 576 | No depth test |
| 576..584 | `BIND_OBJECT` rasterizer, handle 9 | `g6lc_apu_vgpu_rb` | 584 | No triangle walk |
| 584..596 | `BIND_SHADER` vertex, handle 2, stage 0 | `g6lc_apu_vgpu_vsb` | 596 | Text stays in the buffer |
| 596..608 | `BIND_SHADER` fragment, handle 3, stage 1 | `g6lc_apu_vgpu_fsb` | 608 | Text stays in the buffer |
| 608..616 | `BIND_OBJECT` vertex elements, handle 4 | `g6lc_apu_vgpu_veb` | 616 | No draw |
| 616..632 | `BIND_SAMPLER_STATES`, fragment slot 0, handle 6 | `g6lc_apu_vgpu_ssb` | 632 | No texture fetch |
| 632..648 | `SET_SAMPLER_VIEWS`, fragment slot 0, handle 5 | `g6lc_apu_vgpu_svb` | 648 | No texture fetch |
| 648..792 | `RESOURCE_INLINE_WRITE`, resource 3, 96 bytes | `g6lc_apu_vgpu_iw` | 792 | Floats stay in the buffer |
| 792..808 | `SET_VERTEX_BUFFERS`, stride 24, offset 0, resource 3 | `g6lc_apu_vgpu_vb` | 808 | No vertex fetch |
| 808..824 | `SET_SCISSOR`, minimum 0, box 640 by 480 | `g6lc_apu_vgpu_sci` | 824 | No draw |
| 824..856 | `SET_VIEWPORT`, scales 320 and 240 | `g6lc_apu_vgpu_vp` | 856 | No transform |
| 856..872 | `SET_FRAMEBUFFER`, one color buffer, surface 1 | `g6lc_apu_vgpu_fbo` | 872 | No memory attach |
| 872..908 | `CLEAR`, color 0, words 0.05 / 0.05 / 0.10 / 1.0 | `g6lc_apu_vgpu_clr` | 908 | No pixel write |
| 908..960 | `DRAW_VBO`, count 4, triangle strip | `g6lc_apu_vgpu_drw` | 960 | No triangle walk |

Last proven remote result, 2026-09-23: `tb_g6lc_apu_vgpu_tail` 337 cases / 955 checks /
4733 clocks, errors=0. That one run checks the viewport, the framebuffer state, the clear,
and the draw. Each `Enable=0` fixture is 12 ports and no cells. `Enable=1` is 1,898 cells /
394 flip-flops (viewport), 1,590 / 265 (framebuffer), 2,103 / 522 (clear), and 2,224 / 555
(draw), no latches. Earlier leaf counts are in `apu-resident-fw.md`.

Byte 960 is the end of this frozen 640×480 execbuffer. The four records do not transform
a vertex, attach memory, write a pixel, or walk a triangle. The reduced readback is 64×64.
The scene pixels are a later draw on this device. `g6lc_apu_vgpu_avail` still rejects
`NEXT`, `WRITE`, and `INDIRECT`. `g6lc_apu_vgpu_chn` accepts the one scene chain beside it.

The control prefix around that submit is a separate record. `CTX_CREATE` keeps context 1
named `main`. Two `RESOURCE_CREATE_3D` records keep resource 4 at 640 by 480 and resource 3
at 96 bytes. Three `CTX_ATTACH` records keep resources 4, 3, and 1. `g6lc_apu_vgpu_rsp`
then writes 24 bytes at `64'h8800A800`: `OK_NODATA`, the fence bit, fence
`64'h1122334455667788`, and context 1. Remote 2026-09-23: `tb_g6lc_apu_vgpu_ctl` 27 cases /
88 checks / 375 clocks, errors=0. Enable=0 is ports and no cells. Enable=1 is 1,828 cells /
811 flip-flops (context), 2,239 / 748 (resources), 1,310 / 331 (attaches), and 939 / 200
(response), no latches. That write does not store a pixel.

`GET_CAPSET_INFO` index 0 and `GET_CAPSET` virgl id 1 version 1 record
`INVALID_PARAMETER`. No capset id is published and no blob is stored. `SET_SCANOUT`
keeps scanout 0 on resource 4, rectangle 0,0,640,480. A 64 by 64 rectangle records
nothing. `RESOURCE_FLUSH` keeps that same rectangle. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_pre` 20 cases / 63 checks / 206 clocks, errors=0. Enable=1 is
681 cells / 265 flip-flops (info), 1,209 / 329 (capset), 1,135 / 522 (scanout), and
1,698 / 554 (flush), no latches. The scanout record is not `g6lc_hdmi_scanout`. The
flush does not present a frame.

`g6lc_apu_vgpu_chn` keeps that scene chain when the avail index advances by one onto
descriptor 0. `INDIRECT`, a jumped index, and a 32-byte execbuffer do not consume the
slot. `g6lc_apu_vgpu_cmx` links the chain to the recorded submit and the stored response.
`g6lc_apu_vgpu_sun` then stores descriptor 0, length 24, and advances a local `used.idx`
to 1 with IRQ. A cancel before that index does not publish. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_chn` 26 cases / 75 checks / 115 clocks, errors=0. Enable=1 is
1,209 cells / 585 flip-flops (chain), 642 / 5 (link), and 106 / 24 (used element), no
latches. `g6lc_apu_vgpu_suw` then writes descriptor 0 and length 24 to `64'h8800D000`.
`g6lc_apu_vgpu_sux` writes `used.idx` 1 to `64'h8800E002`. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_sunw` 11 cases / 56 checks / 61 clocks, errors=0. Enable=1 is
208 cells / 7 flip-flops (element) and 214 / 7 (index), no latches. Those addresses
are not `64'h8800_3000` and `64'h8800_4002`. `g6lc_apu_vgpu_avail` is unchanged.

The clear floats become RGBA8 `32'hFF1A0D0D` (byte 0 is red: 13, 13, 26, 255). After the
640 by 480 scissor, surface 1, and the four-vertex strip are recorded, that word is stored
at the four corners of the 64 by 64 ceiling: addresses 0, 252, 16128, and 16380. `(1,0)`
is not stored. `(64,0)` is outside the ceiling. Remote 2026-09-23: `tb_g6lc_apu_vgpu_pix`
16 cases / 60 checks / 71 clocks, errors=0. Enable=1 is 283 cells / 6 flip-flops (bytes),
328 / 38 (corners), and 518 / 50 (read), no latches. The interior is not written. The
triangle is not walked. This is not the screenshot.

That same word now stands for all 4096 samples of the ceiling. The samples are not stored
one by one. `(1,0)` reads address 4. `(2,3)` reads address 776. `(63,63)` reads 16380.
`(64,0)` records nothing. Remote 2026-09-23: `tb_g6lc_apu_vgpu_fil` 14 cases / 56 checks /
63 clocks, errors=0. Enable=1 is 234 cells / 38 flip-flops (fill) and 412 / 48 (read), no
latches. The corner reader still reports `(1,0)` as a miss of the four stored corners.
The triangle is not walked.

The 24 floats at bytes 696..791 match that NDC square: `{x, y, 0, 1, u, v}`
at `(-1,-1)`, `(1,-1)`, `(-1,1)`, and `(1,1)`. Viewport scales 320 and 240
map it onto 0..640 by 0..480, so every ceiling sample is covered. The stored
color stays `32'hFF1A0D0D`. The fragment shader is not run. This is not
`g6lc_apu_cover`. Remote 2026-09-23: `tb_g6lc_apu_vgpu_qd` 14 cases / 52
checks / 113 clocks, errors=0. Enable=1 is 697 cells / 22 flip-flops (quad),
255 / 70 (coverage), and 419 / 49 (sample), no latches. Enable=0 is 12, 11,
and 10 ports and no cells. `(1,0)` reads address 4 from the coverage record.
The corner reader still reports `(1,0)` as a miss of the four stored corners.

The vertex-shader text is 32 dwords at byte 48, length 125 including the NUL.
It is the VERT passthrough. The fragment-shader text is 35 dwords at byte 200,
length 140 including the NUL. It is the TEX program. A mismatched dword records
nothing. TEX is not executed, so a covered sample stays `32'hFF1A0D0D`. `(1,0)`
reads address 4. This is not `g6lc_apu_cover`. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_vtx` 20 cases / 75 checks / 225 clocks, errors=0. Enable=1 is
751 cells / 12 flip-flops (vertex text), 809 / 13 (fragment text), and 423 / 49
(held sample), no latches. Enable=0 is 12, 13, and 11 ports and no cells. The
corner reader still reports `(1,0)` as a miss of the four stored corners.

That TEX program is bound to sampler view 5 on resource 1 and sampler state 6,
both on fragment slot 0. The view is `B8G8R8X8`, target 2D, identity swizzle.
The sampler is clamp-to-edge and linear, with no mip filter. Resource 1 has no
texel image on this path, so the sample is refused and the word stays
`32'hFF1A0D0D`. `(1,0)` reads address 4 with the refused bit set. This does not
fetch a texel. Remote 2026-09-23: `tb_g6lc_apu_vgpu_tbn` 15 cases / 57 checks /
67 clocks, errors=0. Enable=1 is 747 cells / 101 flip-flops (binding), 310 / 102
(refusal), and 452 / 49 (sample), no latches. Enable=0 is 14, 10, and 10 ports
and no cells. The corner reader still reports `(1,0)` as a miss of the four
stored corners.

Resource 1 is also the VioScan `RESOURCE_CREATE_2D`: format `B8G8R8X8` (2),
640 by 480. Format 67 and a 64-wide image record nothing. That is
`g6lc_apu_vgpu_cmd`, which was not re-run. The backing length is 1,228,800
bytes. The test address `32'h8800F000` is a stand-in, not `__scan_fb`, and not
`32'h88001000`. The transfer rectangle is the top band, 0,0,640 by 64. A
480-high rectangle records nothing. This band is not the 64 by 64 ceiling. No
byte is copied, so the refused word stays `32'hFF1A0D0D`. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_s2d` 15 cases / 54 checks / 169 clocks, errors=0. Enable=1 is
245 cells / 11 flip-flops (create), 504 / 75 (backing), and 542 / 43 (transfer),
no latches. Enable=0 is 11, 12, and 14 ports and no cells.

`SET_SCANOUT` then names scanout 0 on resource 1 at 640 by 480. A 64 by 64
rectangle and resource 4 record nothing. `RESOURCE_FLUSH` of resource 1 keeps
the top band, 640 by 64. A 480-high flush records nothing. Neither record
presents a frame. This is not `g6lc_apu_vgpu_scn`, not `g6lc_apu_vgpu_flu`, and
not `g6lc_hdmi_scanout`. `(1,0)` still reads address 4 as `32'hFF1A0D0D`. Remote
2026-09-23: `tb_g6lc_apu_vgpu_ssc` 17 cases / 61 checks / 153 clocks, errors=0.
Enable=1 is 349 cells / 11 flip-flops (scanout), 432 / 11 (flush), and 486 / 48
(sample), no latches. Enable=0 is 12, 13, and 11 ports and no cells.

The top band is then read from the backing address. 640 by 64 is 163,840 bytes,
5,120 beats of 32. The image is not stored. Beat 0's low word is kept. The other
1,064,960 bytes of the 1,228,800-byte backing are not read. The ceiling word stays
`32'hFF1A0D0D`. TEX is not executed. Remote 2026-09-23: `tb_g6lc_apu_vgpu_bcp`
10 cases / 41 checks / 10,297 clocks, errors=0. Enable=1 is 802 cells / 118
flip-flops (copy) and 458 / 81 (report), no latches. Enable=0 is 20 and 9 ports
and no cells.

`(0,0)` of that band is then sampled. Clamp-to-edge linear at that corner uses
the one texel. `x` clamps to 639. `y` above 63 records nothing. A second tap is
not blended. Ceiling pixel `(0,0)` becomes that word, `32'hA5000000` in the
test. `(1,0)` and `(63,63)` stay `32'hFF1A0D0D`. The fill reader still returns
the clear word at `(0,0)`. TEX is not executed. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_tap` 13 cases / 51 checks / 68 clocks, errors=0. Enable=1 is
1,471 cells / 105 flip-flops (texel), 189 / 37 (corner), and 355 / 49 (read),
no latches. Enable=0 is 24, 10, and 10 ports and no cells.

Row 0 then blends two taps in the first beat. `s = x - 1/2` with `u = x/640`.
`x = 0` stays `32'hA5000000`. `x = 1` is `32'hD2008000`, the half blend of texel
0 and texel 1, round half up per byte. `x = 7` is `32'h33445566`. `x` above 7
and `y` other than 0 record nothing. The earlier ceiling reader still returns
the clear word at `(1,0)`. TEX is not executed. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_lin` 11 cases / 41 checks / 63 clocks, errors=0. Enable=1 is
2,000 cells / 84 flip-flops (blend) and 247 / 71 (pair), no latches. Enable=0
is 25 and 11 ports and no cells.

`x = 8` reads both beats. Texel 7 is `32'h55667788` and texel 8 is
`32'hAABBCCDD`. The half blend is `32'h8091A2B3`. `x = 0` stays `32'hA5000000`
and `x = 1` stays `32'hD2008000`. `x` above 15 records nothing. TEX is not
executed. Remote 2026-09-23: `tb_g6lc_apu_vgpu_spn` 11 cases / 39 checks / 68
clocks, errors=0. Enable=1 is 2,422 cells / 156 flip-flops (span) and 130 / 37
(store), no latches. Enable=0 is 25 and 10 ports and no cells.

`y = 1` mixes that row with row 1. `t = y - 1/2`, so the sample is halfway
between texel row 0 and texel row 1. `x = 0` is `32'h53010202`. `x = 1` is
`32'h6B024303`. The row-1 beat is `64'h8800FA00`. `y = 0`, `y` above 1, and
`x` above 1 record nothing. Row 0 stays `32'hA5000000` at `x = 0` and
`32'hD2008000` at `x = 1`. TEX is not executed. This is not a bilinear of the
ceiling and it is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_vln`
11 cases / 41 checks / 60 clocks, errors=0. Enable=1 is 1,517 cells / 77
flip-flops (blend) and 237 / 71 (pair), no latches. Enable=0 is 26 and 10
ports and no cells.

`y = 1` then blends `x = 0..7`. Both taps of each row sit in beat 0. `x = 0`
stays `32'h53010202` and `x = 1` stays `32'h6B024303`. `x = 2` is
`32'h42024203`. `x = 7` is `32'h1A222B33`. `x` above 7 records nothing. The
image is not stored. TEX is not executed. This is not a bilinear of the
ceiling and it is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_vbx`
12 cases / 53 checks / 78 clocks, errors=0. Enable=1 is 3,891 cells / 336
flip-flops (blend) and 129 / 37 (store), no latches. Enable=0 is 27 and 10
ports and no cells.

`y = 1` then blends through `x = 15`. `x = 8` reads beat 0 and beat 1 of
each row. Row 0 stays `32'h8091A2B3`. Row 1 texel 8 is `32'h0A0B0C0D`. The
vertical blend is `32'h434C545D`. `x = 0`, `x = 1`, and `x = 2` stay the
stored words. `x = 15` is `32'h0`. `x` above 15 records nothing. The image
is not stored. TEX is not executed. This is not a bilinear of the ceiling
and it is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_vsp`
13 cases / 63 checks / 91 clocks, errors=0. Enable=1 is 3,388 cells / 185
flip-flops (blend) and 199 / 37 (store), no latches. Enable=0 is 28 and 12
ports and no cells.

`y = 2` mixes row 1 with row 2 for `x = 0..7`. `t = y - 1/2`. `x = 0` is
`32'h79797A7A`. `x = 1` is `32'h42424343`. `x = 7` is `32'h3C3C3C3C`. Row 2
is `64'h88010400`. `y = 1` and `x` above 7 record nothing. The `y = 1`
samples stay `32'h53010202` and `32'h6B024303`. The image is not stored.
TEX is not executed. This is not a bilinear of the ceiling and it is not
the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_y2b` 12 cases / 55
checks / 73 clocks, errors=0. Enable=1 is 3,300 cells / 116 flip-flops
(blend) and 241 / 71 (pair), no latches. Enable=0 is 29 and 11 ports and
no cells.

Any point of the 64 by 64 ceiling can then be sampled from that band.
`x = 0` clamps to texel 0 and `y = 0` clamps to row 0. The stored colors
match. `(9,0)` is `32'h555E666F`. `(8,2)` is `32'h17171718`. `(0,3)` is
`32'h78787878` and is kept. `(63,63)` is `32'h0`. `x` or `y` above 63
records nothing. The image is not stored. One run checked all 4,096
points. TEX is not executed. This is not the screenshot. Remote
2026-09-23: `tb_g6lc_apu_vgpu_smp` 4,117 cases / 16,472 checks / 38,678
clocks, errors=0. Enable=1 is 4,351 cells / 221 flip-flops (sample) and
204 / 37 (store), no latches. Enable=0 is 30 and 10 ports and no cells.

That ceiling is then written to `32'h88040000`. Eight samples fill one
beat. The walk is 512 beats, 16,384 bytes, and the last beat is at
`64'h88043FE0`. Beat 0 is row 0 through `x = 7`. Beat 24 starts with
`32'h78787878`. The last beat is `32'h0`. The writer keeps the beat it
is sending, not the image. A failed sample writes nothing. This is not
`32'h8800C000`. TEX is not executed. This is not the screenshot. Remote
2026-09-23: `tb_g6lc_apu_vgpu_rbf` 7 cases / 35 checks / 39,646 clocks,
errors=0. Enable=1 is 5,129 cells / 620 flip-flops (write, including
the sampler) and 318 / 111 (record), no latches. Enable=0 is 37 and 10
ports and no cells.

Those 512 beats are then read back. Beat 0's low word is `32'hA5000000`.
Beat 24's low word is `32'h78787878`. The last beat is at `64'h88043FE0`.
The image is not kept. A failed beat stops the walk. A word that does not
match the record is refused. TEX is not executed. This is not the
screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_rdr` 7 cases / 30 checks /
1,066 clocks, errors=0. Enable=1 is 909 cells / 147 flip-flops (read) and
298 / 69 (pair), no latches. Enable=0 is 20 and 11 ports and no cells.

The accepted scene chain is then fetched from guest memory. The header
at `64'h8800A000` is `SUBMIT_3D`, context 1, size 960. The execbuffer is
30 beats at `64'h8800B000`. The first word is `32'h00050801`, the surface
`CREATE_OBJECT`. The last beat is at `64'h8800B3A0`. The 960 bytes are
not kept. The response at `64'h8800A800` is not read. `g6lc_apu_vgpu_avail`
still rejects `NEXT`. TEX is not executed. This is not the screenshot.
Remote 2026-09-23: `tb_g6lc_apu_vgpu_fet` 8 cases / 33 checks / 113 clocks,
errors=0. Enable=1 is 834 cells / 81 flip-flops (fetch) and 210 / 69
(record), no latches. Enable=0 is 19 and 10 ports and no cells.

The `DRAW_VBO` at byte 908 of that execbuffer is then read. Beat 28 at
`64'h8800B380` carries the header in bits `[127:96]`, `32'h000C0008`.
Count is 4 and the primitive is a triangle strip. Beat 29 at
`64'h8800B3A0` carries one instance and max index 3. The low twelve
bytes of beat 28 are the clear tail and are not checked. The 960 bytes
are not kept. The draw is not executed. This is not `g6lc_apu_vgpu_drw`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_drd` 13
cases / 59 checks / 81 clocks, errors=0. Enable=1 is 839 cells / 139
flip-flops (read) and 241 / 69 (record), no latches. Enable=0 is 19
and 10 ports and no cells.

The 24 NDC floats that draw names are then read from byte 696. Beat 21
at `64'h8800B2A0` holds the inline-write length and the first two
floats. Beats 22 and 23 hold the middle sixteen. Beat 24 at
`64'h8800B300` holds the last six. The corners are `(-1,-1)`, `(1,-1)`,
`(-1,1)`, and `(1,1)`. The first float is `32'hbf800000` and the last
is `32'h3f800000`. The 96 bytes are not kept. The vertex-buffer command
after the floats is not part of this read. This does not transform a
vertex and does not execute the draw. This is not `g6lc_apu_vgpu_qd`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_qdr` 14
cases / 63 checks / 97 clocks, errors=0. Enable=1 is 1,109 cells / 143
flip-flops (read) and 387 / 69 (record), no latches. Enable=0 is 20
and 11 ports and no cells.

The viewport of that draw is then read from byte 824. Beat 25 at
`64'h8800B320` carries the header `32'h00070004`. Beat 26 at
`64'h8800B340` carries scale 320 and scale 240. NDC −1 lands at 0 and
NDC +1 lands at 640 and 480. This is not a floating-point multiply and
not a rasterizer. The scissor in the low 24 bytes of beat 25 is not
part of this command. This is not `g6lc_apu_vgpu_vp`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_vwx` 13
cases / 59 checks / 80 clocks, errors=0. Enable=1 is 1,000 cells / 140
flip-flops (read) and 566 / 133 (record), no latches. Enable=0 is 21
and 12 ports and no cells.

The scissor of that draw is then read from byte 808. It shares beat 25
at `64'h8800B320` with the viewport. The header is `32'h0003000F`. The
box is `32'h01E00280`, 640 by 480, the same edges as the window. No
pixel is clipped. The vertex-buffer tail and the viewport header in
that beat are not part of this command. This is not `g6lc_apu_vgpu_sci`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_cxr` 13
cases / 59 checks / 71 clocks, errors=0. Enable=1 is 851 cells / 73
flip-flops (read) and 461 / 37 (record), no latches. Enable=0 is 22
and 13 ports and no cells.

The clear of that rectangle is then read from byte 872. Beat 27 at
`64'h8800B360` carries the header `32'h00080007` and the floats
`32'h3d4ccccd`, `32'h3d4ccccd`, `32'h3dcccccd`, and `32'h3f800000`.
Beat 28 at `64'h8800B380` carries depth `32'h3ff00000` and is also
the draw beat. The packed word is `32'hFF1A0D0D`, byte 0 red. This
does not convert a float and does not write a pixel. The framebuffer
tail and the draw header in those beats are not part of this command.
This is not `g6lc_apu_vgpu_clr`. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. TEX is not executed. This is not the screenshot. Remote
2026-09-23: `tb_g6lc_apu_vgpu_cwr` 13 cases / 59 checks / 78 clocks,
errors=0. Enable=1 is 1,185 cells / 140 flip-flops (read) and 524 /
101 (record), no latches. Enable=0 is 23 and 11 ports and no cells.

The framebuffer that clear follows is then read from byte 856. Beat 26
at `64'h8800B340` carries the header `32'h00030005` and one color
buffer. Beat 27 at `64'h8800B360` carries surface handle 1. The clear
word `32'hFF1A0D0D` stays with that surface. This does not attach
memory and does not write a pixel. The viewport body and the clear in
those beats are not part of this command. This is not
`g6lc_apu_vgpu_fbo`. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX
is not executed. This is not the screenshot. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_fbr` 13 cases / 59 checks / 78 clocks, errors=0.
Enable=1 is 1,130 cells / 171 flip-flops (read) and 452 / 101
(record), no latches. Enable=0 is 24 and 11 ports and no cells.

The vertex-buffer set that follows the floats is then read from byte
792. Beat 24 at `64'h8800B300` carries the header `32'h00030006` and
stride 24. Beat 25 at `64'h8800B320` carries offset 0 and resource 3.
This does not fetch vertices. The last quad float and the scissor in
those beats are not part of this command. This is not
`g6lc_apu_vgpu_vb`. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX
is not executed. This is not the screenshot. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_vbf` 14 cases / 63 checks / 87 clocks, errors=0.
Enable=1 is 1,246 cells / 203 flip-flops (read) and 452 / 101
(record), no latches. Enable=0 is 25 and 11 ports and no cells.

The inline write that holds those floats is then read from byte 648.
Beat 20 at `64'h8800B280` carries the header `32'h00230009` and
resource 3. Beat 21 at `64'h8800B2A0` carries the length 96 and the
first float. The 96 bytes are not kept. This does not fetch vertices.
The sampler-view handle and the second float in those beats are not
part of this check. This is not `g6lc_apu_vgpu_iw`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_iwr` 13
cases / 59 checks / 78 clocks, errors=0. Enable=1 is 1,405 cells /
139 flip-flops (read) and 449 / 69 (record), no latches. Enable=0 is
26 and 12 ports and no cells.

The sampler view that precedes that write is then read from byte 632.
Beat 19 at `64'h8800B260` carries the header `32'h0003000A` and the
fragment stage. Beat 20 at `64'h8800B280` carries slot 0 and
sampler-view handle 5. No texture is bound. The sampler-state handle
and the inline-write header in those beats are not part of this
command. This is not `g6lc_apu_vgpu_svb`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_svr` 15
cases / 67 checks / 91 clocks, errors=0. Enable=1 is 1,644 cells /
204 flip-flops (read) and 612 / 101 (record), no latches. Enable=0 is
27 and 12 ports and no cells.

The sampler state that precedes that view is then read from byte 616.
It shares beat 19 at `64'h8800B260`. The header is `32'h00030012`.
The stage is fragment, the slot is 0, and the handle is 6. No
texture is bound. The vertex-element bind and the sampler-view
header in that beat are not part of this command. This is not
`g6lc_apu_vgpu_ssb`. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX
is not executed. This is not the screenshot. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_ssr` 15 cases / 67 checks / 85 clocks, errors=0.
Enable=1 is 1,926 cells / 201 flip-flops (read) and 778 / 101
(record), no latches. Enable=0 is 28 and 13 ports and no cells.

The vertex-element bind that precedes that state is then read from
byte 608. It is the first eight bytes of beat 19 at `64'h8800B260`.
The header is `32'h00010502` and the handle is 4. No vertices are
fetched. The sampler-state words in that beat are not part of this
command. This is not `g6lc_apu_vgpu_veb`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_ver` 13
cases / 59 checks / 71 clocks, errors=0. Enable=1 is 1,965 cells /
137 flip-flops (read) and 651 / 69 (record), no latches. Enable=0 is
29 and 13 ports and no cells.

The fragment shader bind that precedes those elements is then read
from byte 596. It is the last twelve bytes of beat 18 at
`64'h8800B240`. The header is `32'h0002001F`, the handle is 3, and
the stage is fragment. The shader is not run. The vertex-shader
words in that beat are not part of this command. This is not
`g6lc_apu_vgpu_fsb`. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX
is not executed. This is not the screenshot. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_fsr` 14 cases / 63 checks / 78 clocks, errors=0.
Enable=1 is 2,141 cells / 137 flip-flops (read) and 691 / 69
(record), no latches. Enable=0 is 30 and 13 ports and no cells.

The vertex shader bind that precedes that fragment bind is then read
from byte 584. It shares beat 18 at `64'h8800B240`. The header is
`32'h0002001F`, the handle is 2, and the stage is vertex. The shader
is not run. The fragment-shader words in that beat are not part of
this command. This is not `g6lc_apu_vgpu_vsb`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_vsr` 14
cases / 63 checks / 78 clocks, errors=0. Enable=1 is 2,401 cells /
137 flip-flops (read) and 745 / 69 (record), no latches. Enable=0 is
31 and 13 ports and no cells.

The rasterizer bind that precedes that vertex shader is then read
from byte 576. It is the first eight bytes of beat 18 at
`64'h8800B240`. The header is `32'h00010202` and the handle is 9.
No triangle is walked. The vertex-shader words in that beat are not
part of this command. This is not `g6lc_apu_vgpu_rb`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_rzr` 13
cases / 59 checks / 71 clocks, errors=0. Enable=1 is 2,568 cells /
137 flip-flops (read) and 682 / 69 (record), no latches. Enable=0 is
32 and 13 ports and no cells.

The depth-stencil bind that precedes that rasterizer is then read
from byte 568. It is the last eight bytes of beat 17 at
`64'h8800B220`. The header is `32'h00010302` and the handle is 8.
No depth test is run. The blend bind in that beat is not part of
this command. This is not `g6lc_apu_vgpu_db`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_dbr` 13
cases / 59 checks / 71 clocks, errors=0. Enable=1 is 2,769 cells /
137 flip-flops (read) and 686 / 69 (record), no latches. Enable=0 is
33 and 13 ports and no cells.

The blend bind that precedes that depth-stencil bind is then read
from byte 560. It is sixteen bytes into beat 17 at `64'h8800B220`.
The header is `32'h00010102` and the handle is 7. No blend is
applied. The depth-stencil words in that beat are not part of this
command. This is not `g6lc_apu_vgpu_bb`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_bbr` 13
cases / 59 checks / 71 clocks, errors=0. Enable=1 is 2,972 cells /
137 flip-flops (read) and 687 / 69 (record), no latches. Enable=0 is
34 and 13 ports and no cells.

The rasterizer object that precedes that blend bind is then read from
byte 520. Beat 16 at `64'h8800B200` carries the header `32'h00090201`
and handle 9. Beat 17 at `64'h8800B220` carries the last four state
words. All eight state words are 0. They are not kept. No triangle is
walked. The depth-stencil tail in beat 16 and the blend bind in beat
17 are not part of this command. This is not `g6lc_apu_vgpu_rz`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_rcr` 15
cases / 67 checks / 89 clocks, errors=0. Enable=1 is 3,536 cells /
139 flip-flops (read) and 700 / 69 (record), no latches. Enable=0 is
35 and 13 ports and no cells.

The depth-stencil object that precedes that rasterizer is then read
from byte 496. Beat 15 at `64'h8800B1E0` carries the header
`32'h00050301` and handle 8. Beat 16 at `64'h8800B200` carries the
last two state words. All four state words are 0. They are not kept.
No depth test is run. The blend tail in beat 15 and the rasterizer
object in beat 16 are not part of this command. This is not
`g6lc_apu_vgpu_ds`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_dcr` 15
cases / 67 checks / 89 clocks, errors=0. Enable=1 is 3,734 cells /
140 flip-flops (read) and 700 / 69 (record), no latches. Enable=0 is
36 and 13 ports and no cells.

The blend object that precedes that depth-stencil object is then read
from byte 448. Beat 14 at `64'h8800B1C0` carries the header
`32'h000B0101`, handle 7, and color word `32'h78020010`. Beat 15 at
`64'h8800B1E0` carries the last four body words, and they are 0. Those
zero words are not kept. No blend is applied. The depth-stencil object
in beat 15 is not part of this command. This is not `g6lc_apu_vgpu_bl`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_blr` 16
cases / 71 checks / 96 clocks, errors=0. Enable=1 is 4,308 cells /
203 flip-flops (read) and 838 / 101 (record), no latches. Enable=0 is
37 and 13 ports and no cells.

The sampler-state object that precedes that blend object is then read
from byte 408. Beat 12 at `64'h8800B180` carries the header
`32'h00090701` and handle 6. Beat 13 at `64'h8800B1A0` carries wrap
word `32'h00002292` and max LOD `32'h42000000`. The other body words
are 0. They are not kept. No texture is bound. The sampler-view tail
in beat 12 is not part of this command. This is not
`g6lc_apu_vgpu_ss`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_scr` 17
cases / 75 checks / 109 clocks, errors=0. Enable=1 is 4,899 cells /
267 flip-flops (read) and 951 / 133 (record), no latches. Enable=0 is
38 and 13 ports and no cells.

The sampler view that precedes that sampler-state object is then read
from byte 380. Beat 11 at `64'h8800B160` carries the header
`32'h00060601`. Beat 12 at `64'h8800B180` carries handle 5, resource
1, format word `32'h02000002`, and swizzle `32'h00000688`. Two body
words are 0. They are not kept. No texture is bound. The
vertex-element tail in beat 11 and the sampler-state words in beat 12
are not part of this command. This is not `g6lc_apu_vgpu_sv`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_svc` 18
cases / 79 checks / 120 clocks, errors=0. Enable=1 is 5,267 cells /
332 flip-flops (read) and 1,046 / 165 (record), no latches. Enable=0
is 39 and 13 ports and no cells.

The vertex-element object that precedes that sampler view is then
read from byte 340. Beat 10 at `64'h8800B140` carries the header
`32'h00090501`, handle 4, and offset 0. Beat 11 at `64'h8800B160`
carries format 31, offset 16, and format 29. Four divisor words are
0. They are not kept. No vertices are fetched. The shader text in
beat 10 and the sampler-view header in beat 11 are not part of this
command. This is not `g6lc_apu_vgpu_ve`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_vec` 19
cases / 83 checks / 125 clocks, errors=0. Enable=1 is 5,868 cells /
395 flip-flops (read) and 1,135 / 197 (record), no latches. Enable=0
is 40 and 13 ports and no cells.

Fragment-shader, vertex-shader, and surface objects that head that
execbuffer are then read in one run. The fragment shader at byte 176
is header `32'h00280401`, handle 3, fragment stage, length 140, and
text dword `32'h47415246`. The vertex shader at byte 24 is header
`32'h00250401`, handle 2, vertex stage, length 125, and text dword
`32'h54524556`. The surface at byte 0 is header `32'h00050801`,
handle 1, resource 4, and format 2. The rest of each shader text
stays in the execbuffer. Neither shader is run. No framebuffer is
painted. No vertices are fetched. No texture is bound. This is not
`g6lc_apu_vgpu_fs` or `g6lc_apu_vgpu_sh`. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. TEX is not executed. This is not the screenshot.
Remote 2026-09-23: `tb_g6lc_apu_vgpu_obj` 53 cases / 221 checks / 317
clocks, errors=0. Enable=1 is 6,794 cells / 396 flip-flops (fragment
read), 1,140 / 197 (fragment record), 7,311 / 395 (vertex read),
1,017 / 197 (vertex record), 6,753 / 265 (surface read), and 840 /
133 (surface record), no latches. Enable=0 is 41, 13, 42, 13, 43, and
13 ports and no cells.

The same scene is then read as three guest descriptors at
`64'h8800E100` and one avail slot at `64'h8800E200`. Descriptor 0 is
the header and links to 1. Descriptor 1 is the 960-byte execbuffer and
links to 2. Descriptor 2 is the 24-byte response. Avail index 1 names
descriptor 0. INDIRECT, a broken link, and a jumped index record
nothing. This is not `g6lc_apu_vgpu_avail` and not `g6lc_apu_vgpu_chn`.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed. This
is not the screenshot. Remote 2026-09-23: `tb_g6lc_apu_vgpu_nxc` 16
cases / 71 checks / 109 clocks, errors=0. Enable=1 is 1,959 cells /
396 flip-flops (read) and 921 / 197 (record), no latches. Enable=0 is
22 and 13 ports and no cells.

The completed-opcode list is then read at `64'h8800E300`. The count
is 0 and the capset id is 0. A nonzero count or virgl id 1 records
nothing. No caps blob is stored. The answer is `OK_NODATA`. The virgl
capset request stays `INVALID_PARAMETER`. This is not
`g6lc_apu_vgpu_cap`. `FeatureVirgl` stays off. `g6lc_apu_vgpu_avail`
still rejects `NEXT`. TEX is not executed. This is not the screenshot.
Remote 2026-09-23: `tb_g6lc_apu_vgpu_ols` 13 cases / 59 checks / 71
clocks, errors=0. Enable=1 is 1,055 cells / 137 flip-flops (read) and
557 / 101 (record), no latches. Enable=0 is 24 and 13 ports and no cells.

The scene clear word is then written across a 64 by 64 guest window
at `64'h88020000`. Each beat is eight copies of `32'hFF1A0D0D`. 512
beats is 16384 bytes. The bytes are not kept in registers. A 64-high
scissor records nothing. The first beat and the last beat at
`64'h88023FE0` read back as that word. `(1,0)` is byte 4 of the first
beat. This is not `g6lc_apu_vgpu_rbf`, not `g6lc_apu_vgpu_frd`, and
not `g6lc_apu_vgpu_pxr`. The shader is not run. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not
executed. Remote 2026-09-23: `tb_g6lc_apu_vgpu_gpw` 16 cases / 73
checks / 1112 clocks, errors=0. Enable=1 is 766 cells / 18 flip-flops
(write), 1,212 / 75 (read), and 873 / 165 (record), no latches.
Enable=0 is 23, 22, and 13 ports and no cells.

The guest completion is then written. The 24-byte response at
`64'h8800A800` is `OK_NODATA`, fence `64'h1122334455667788`, and
context 1. The used element at `64'h8800E400` is descriptor 0 and
length 24. The used index at `64'h8800E480` is 1. A 64-high scissor
writes nothing. The response bytes are not kept. This is not
`g6lc_apu_vgpu_rsp`, not `g6lc_apu_vgpu_suw`, and not
`g6lc_apu_vgpu_sux`. The shader is not run. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not
executed. Remote 2026-09-23: `tb_g6lc_apu_vgpu_gcw` 22 cases / 96
checks / 127 clocks, errors=0. Enable=1 is 995 cells / 14 flip-flops
(write), 1,867 / 365 (read), and 1,318 / 181 (record), no latches.
Enable=0 is 22, 24, and 15 ports and no cells.

The used-buffer interrupt is then raised. The reason at
`64'h8800E500` is `32'h1`. Ack lowers the pin and leaves the record.
A cancel before the beat writes nothing and the pin stays low. A
64-high scissor writes nothing. This is not `g6lc_apu_vgpu_sun` and
not `g6lc_apu_vgpu_used`. The pin is not PLIC source 9. The shader
is not run. This is not the screenshot. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. TEX is not executed. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_viw` 20 cases / 89 checks / 102 clocks, errors=0.
Enable=1 is 888 cells / 24 flip-flops (write), 897 / 88 (read), and
607 / 53 (record), no latches. Enable=0 is 26, 23, and 13 ports and
no cells.

The guest then acks that reason. The word at `64'h8800E510` is
`32'h1`, and the status word at `64'h8800E500` is written as `32'h0`.
A config-only ack and a zero ack write nothing. A cancel before the
read writes nothing. This does not drive the viw pin. The shader is
not run. This is not the screenshot. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. TEX is not executed. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_vaw` 22 cases / 96 checks / 122 clocks, errors=0.
Enable=1 is 862 cells / 7 flip-flops (ack), 816 / 155 (read), and
709 / 85 (record), no latches. Enable=0 is 34, 22, and 13 ports and
no cells.

All 512 beats of the window at `64'h88020000` are then read. Each
beat is eight copies of `32'hFF1A0D0D`. `(0,0)` is the low word of
beat 0. `(1,0)` is byte 4 of that beat. `(63,63)` is the top lane of
the last beat. The image is not kept. A 64-high scissor reads
nothing. `x` or `y` of 64 records nothing. This is not
`g6lc_apu_vgpu_gpr`. The shader is not run. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not
executed. Remote 2026-09-23: `tb_g6lc_apu_vgpu_wfr` 21 cases / 86
checks / 2149 clocks, errors=0. Enable=1 is 1,660 cells / 210
flip-flops (read), 674 / 117 (record), and 299 / 51 (point), no
latches. Enable=0 is 23, 12, and 11 ports and no cells.

That window is then copied to `64'h88030000`. 512 beats are read
and written. A beat that is not the clear word stops the copy. One
beat is held between the read and the write. The image is not kept.
This is not Mesa `glReadPixels` and not the ceiling at
`32'h88040000`. The shader is not run. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed.
Remote 2026-09-23: `tb_g6lc_apu_vgpu_gbw` 19 cases / 84 checks /
2153 clocks, errors=0. Enable=1 is 2,227 cells / 412 flip-flops
(copy), 1,080 / 75 (read), and 935 / 181 (record), no latches.
Enable=0 is 33, 20, and 12 ports and no cells.

The buffer is a 64 by 64 rectangle, stride 256, format `B8G8R8X8`,
16384 bytes. A 640 by 480 request records nothing. `(1,0)` is byte
4 of the beat at `64'h88030000`. `(63,63)` is the top lane of
`64'h88033FE0`. Both are the clear word. `x` or `y` of 64 reads
nothing. This is not Mesa `glReadPixels`. The shader is not run.
This is not the screenshot. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. TEX is not executed. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_gbd` 18 cases / 78 checks / 91 clocks, errors=0.
Enable=1 is 261 cells / 6 flip-flops (rectangle), 1,363 / 102
(lane), and 829 / 115 (record), no latches. Enable=0 is 11, 22, and
11 ports and no cells.

The byte offset of a point is `y * 256 + x * 4`. Row 1 starts at
byte 256, address `64'h88030100`. `(1,0)` is byte 4. `(63,63)`
starts at byte 16380, and the next byte is 16384. The lane at each
of those offsets is the clear word. `x` or `y` of 64 records
nothing. The shader is not run. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed.
Remote 2026-09-23: `tb_g6lc_apu_vgpu_gof` 19 cases / 85 checks /
101 clocks, errors=0. Enable=1 is 406 cells / 20 flip-flops
(offset), 1,501 / 166 (lane), and 540 / 99 (record), no latches.
Enable=0 is 12, 21, and 11 ports and no cells.

The clear word `32'hFF1A0D0D` sits in that buffer as the bytes
0D 0D 1A FF. Byte 0 is red `8'h0D`. Green is `8'h0D`. Blue is
`8'h1A`. The high byte is `8'hFF`. `(0,0)` and `(1,0)` are the
low two words of the beat at `64'h88030000`. `(63,63)` is the
top lane of `64'h88033FE0`. A first byte of `8'hFF` records
nothing. The image is not kept. The shader is not run. This is
not the screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
TEX is not executed. Remote 2026-09-23: `tb_g6lc_apu_vgpu_byr`
17 cases / 71 checks / 86 clocks, errors=0. Enable=1 is 1,083
cells / 11 flip-flops (channels), 145 / 37 (record), and 125 /
45 (first byte), no latches. Enable=0 is 22, 10, and 10 ports
and no cells.

Row 1 of that buffer is the beat at `64'h88030100`. Byte 0 of
that beat is the same red `8'h0D`. The format tag is `B8G8R8X8`.
A blue first byte `8'h1A` or a high byte `8'hFF` records nothing.
A 480-high rectangle reads nothing. This is later than the
base-beat channels and it is not `g6lc_apu_vgpu_gof`. The image
is not kept. The shader is not run. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed.
Remote 2026-09-23: `tb_g6lc_apu_vgpu_ryr` 22 cases / 91 checks /
107 clocks, errors=0. Enable=1 is 877 cells / 9 flip-flops
(row), 260 / 69 (record), and 211 / 77 (first byte), no latches.
Enable=0 is 21, 10, and 10 ports and no cells.

`(1,1)` is byte 260, lane 1 of the beat at `64'h88030100`.
`(2,3)` is byte 776, lane 2 of the beat at `64'h88030300`.
`(0,63)` is byte 16128, lane 0 of the beat at `64'h88033F00`.
Each lane is the bytes 0D 0D 1A FF. A blue or high byte in the
named lane stops the read. No triangle is walked. The image is
not kept. The shader is not run. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed.
Remote 2026-09-24: `tb_g6lc_apu_vgpu_tpr` 23 cases / 95 checks /
124 clocks, errors=0. Enable=1 is 956 cells / 12 flip-flops
(points), 418 / 117 (record), and 318 / 125 (first byte), no
latches. Enable=0 is 21, 10, and 10 ports and no cells.

`(63,0)` is byte 252, lane 7 of the beat at `64'h880300E0`.
Byte 0 of that lane is red `8'h0D`. `(0,63)` stays byte 16128.
A swapped offset reads nothing. The image is not kept. The
shader is not run. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed.
Remote 2026-09-24: `tb_g6lc_apu_vgpu_x6r` 21 cases / 87 checks /
103 clocks, errors=0. Enable=1 is 971 cells / 9 flip-flops
(corner), 371 / 99 (record), and 283 / 107 (first byte), no
latches. Enable=0 is 21, 10, and 10 ports and no cells.

`(63,63)` is byte 16380, lane 7 of the beat at `64'h88033FE0`.
Byte 0 of that lane is red `8'h0D`. The next byte is 16384.
`(63,0)` stays byte 252 and `(0,63)` stays byte 16128. A swapped
offset reads nothing. The image is not kept. The shader is not
run. This is not the screenshot. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. TEX is not executed. Remote 2026-09-24:
`tb_g6lc_apu_vgpu_tcr` 22 cases / 91 checks / 107 clocks,
errors=0. Enable=1 is 1,032 cells / 9 flip-flops (corner), 380 /
99 (record), and 295 / 107 (first byte), no latches. Enable=0 is
22, 10, and 10 ports and no cells.

`(7,0)` is byte 28, lane 7 of the base beat at `64'h88030000`.
`(63,0)` is byte 252 at `64'h880300E0` and is not this point.
Putting offset 28 on `(63,0)` reads nothing. The image is not
kept. The shader is not run. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed.
Remote 2026-09-24: `tb_g6lc_apu_vgpu_p7r` 21 cases / 87 checks /
103 clocks, errors=0. Enable=1 is 1,002 cells / 9 flip-flops
(point), 369 / 99 (record), and 277 / 107 (first byte), no
latches. Enable=0 is 22, 10, and 10 ports and no cells.

`(8,0)` is byte 32, lane 0 of the beat at `64'h88030020`.
`(15,0)` is byte 60, lane 7 of that same beat. `(7,0)` stays
byte 28 in the base beat. Putting offset 32 on `(7,0)` reads
nothing. The image is not kept. The shader is not run. This is
not the screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
TEX is not executed. Remote 2026-09-24: `tb_g6lc_apu_vgpu_b1r`
21 cases / 87 checks / 103 clocks, errors=0. Enable=1 is 955
cells / 9 flip-flops (beat), 399 / 115 (record), and 313 / 123
(first byte), no latches. Enable=0 is 21, 10, and 10 ports and
no cells.

`(56,0)` is byte 224, lane 0 of the beat at `64'h880300E0`.
`(63,0)` stays byte 252, lane 7 of that same beat. Putting offset
224 on `(63,0)`, or on the beat-1 record, reads nothing. Both
lanes are the bytes 0D 0D 1A FF. The image is not kept. The
shader is not run. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed.
Remote 2026-09-24: `tb_g6lc_apu_vgpu_b7r` 21 cases / 87 checks /
103 clocks, errors=0. Enable=1 is 1,016 cells / 9 flip-flops
(beat), 421 / 115 (record), and 321 / 123 (first byte), no
latches. Enable=0 is 22, 10, and 10 ports and no cells.

`(16,0)` is byte 64, lane 0 of the beat at `64'h88030040`.
`(23,0)` is byte 92, lane 7 of that same beat. Putting offset 64
on `(56,0)` reads nothing. Both lanes are the bytes 0D 0D 1A FF.
The image is not kept. The shader is not run. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is
not executed. Remote 2026-09-24: `tb_g6lc_apu_vgpu_b2r` 21 cases /
87 checks / 103 clocks, errors=0. Enable=1 is 983 cells / 9
flip-flops (beat), 413 / 115 (record), and 313 / 123 (first
byte), no latches. Enable=0 is 21, 10, and 10 ports and no cells.

`(24,0)` is byte 96, lane 0 of the beat at `64'h88030060`.
`(31,0)` is byte 124, lane 7 of that same beat. Putting offset
96 on `(16,0)` reads nothing. Both lanes are the bytes 0D 0D 1A
FF. The image is not kept. The shader is not run. This is not
the screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX
is not executed. Remote 2026-09-24: `tb_g6lc_apu_vgpu_b3r` 21
cases / 87 checks / 103 clocks, errors=0. Enable=1 is 976 cells
/ 9 flip-flops (beat), 417 / 115 (record), and 317 / 123 (first
byte), no latches. Enable=0 is 21, 10, and 10 ports and no cells.

`(32,0)` is byte 128, lane 0 of the beat at `64'h88030080`.
`(39,0)` is byte 156, lane 7 of that same beat. Putting offset
128 on `(24,0)` reads nothing. Both lanes are the bytes 0D 0D 1A
FF. The image is not kept. The shader is not run. This is not
the screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX
is not executed. Remote 2026-09-24: `tb_g6lc_apu_vgpu_b4r` 21
cases / 87 checks / 103 clocks, errors=0. Enable=1 is 979 cells
/ 9 flip-flops (beat), 413 / 115 (record), and 313 / 123 (first
byte), no latches. Enable=0 is 21, 10, and 10 ports and no cells.

`(40,0)` is byte 160, lane 0 of the beat at `64'h880300A0`.
`(47,0)` is byte 188, lane 7 of that same beat. Putting offset
160 on `(32,0)` reads nothing. Both lanes are the bytes 0D 0D 1A
FF. The image is not kept. The shader is not run. This is not
the screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX
is not executed. Remote 2026-09-24: `tb_g6lc_apu_vgpu_b5r` 21
cases / 87 checks / 103 clocks, errors=0. Enable=1 is 976 cells
/ 9 flip-flops (beat), 417 / 115 (record), and 317 / 123 (first
byte), no latches. Enable=0 is 21, 10, and 10 ports and no cells.

`(48,0)` is byte 192, lane 0 of the beat at `64'h880300C0`.
`(55,0)` is byte 220, lane 7 of that same beat. Putting offset
192 on `(40,0)` reads nothing. Both lanes are the bytes 0D 0D 1A
FF. The image is not kept. The shader is not run. This is not
the screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX
is not executed. Remote 2026-09-24: `tb_g6lc_apu_vgpu_b6r` 21
cases / 87 checks / 103 clocks, errors=0. Enable=1 is 980 cells
/ 9 flip-flops (beat), 417 / 115 (record), and 317 / 123 (first
byte), no latches. Enable=0 is 21, 10, and 10 ports and no cells.

The linear sample pair is written as fragment color at
`64'h88050000`. `(0,0)` is the clamp texel `32'hA5000000`.
`(1,0)` is the half blend `32'hD2008000`. A 64-high scissor or a
clear-colored sample writes nothing. Byte 0 of `(1,0)` is `8'h00`.
The image is not kept. TEX is not the compiler opcode. This is not
the screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX
is not executed. Remote 2026-09-30: `tb_g6lc_apu_vgpu_acw` 25
cases / 109 checks / 125 clocks, errors=0. Enable=1 is 773 cells
/ 137 flip-flops (write), 1,093 / 137 (read), and 538 / 155
(first byte), no latches. Enable=0 is 21, 21, and 10 ports and no
cells.

The 64 by 64 ceiling samples are copied into the color window at
`64'h88060000`. Source is `64'h88040000`. Beat 0 is the linear
sample pair. A clear-colored lane stops the copy. Byte 0 of
`(1,0)` in that window is `8'h00`. The image is not kept. TEX is
not the compiler opcode. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed.
Remote 2026-09-30: `tb_g6lc_apu_vgpu_csw` 24 cases / 105 checks /
2172 clocks, errors=0. Enable=1 is 1,805 cells / 412 flip-flops
(copy), 1,114 / 137 (read), and 482 / 123 (first byte), no
latches. Enable=0 is 30, 21, and 10 ports and no cells.

That color window is a 64 by 64 rectangle at `64'h88060000`.
`(1,0)` in it is the half blend `32'hD2008000`. A 640 by 480
request records nothing. `(0,0)` or the next row records nothing.
Byte 0 of `(1,0)` is `8'h00`. The image is not kept. TEX is not
the compiler opcode. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed.
Remote 2026-09-30: `tb_g6lc_apu_vgpu_crd` 22 cases / 90 checks /
104 clocks, errors=0. Enable=1 is 608 cells / 70 flip-flops
(rectangle), 1,019 / 134 (lane), and 470 / 123 (first byte), no
latches. Enable=0 is 12, 22, and 11 ports and no cells.

Byte offset in that rectangle is `y * 256 + x * 4`. `(1,0)` is
byte 4. `(63,63)` is byte 16380 at `64'h88063FE0`. `(0,0)` is the
clamp texel `32'hA5000000`. `(1,0)` as the origin records nothing.
Byte 0 of `(0,0)` is `8'h00`. The image is not kept. TEX is not
the compiler opcode. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed.
Remote 2026-09-30: `tb_g6lc_apu_vgpu_cof` 21 cases / 89 checks /
103 clocks, errors=0. Enable=1 is 395 cells / 20 flip-flops
(offset), 973 / 106 (origin), and 492 / 75 (first byte), no
latches. Enable=0 is 12, 22, and 11 ports and no cells.

That rectangle is copied into a guest buffer at `64'h88070000`.
The command is `TRANSFER_FROM_HOST_3D` (`0x0206`) of resource 4.
Beat 0 is the linear sample pair. Byte 0 of `(1,0)` is `8'h00`.
The image is not kept. TEX is not the compiler opcode. This is
not the screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
TEX is not executed. Remote 2026-09-30: `tb_g6lc_apu_vgpu_rpw` 24
cases / 105 checks / 2172 clocks, errors=0. Enable=1 is 1,821
cells / 412 flip-flops (copy), 1,119 / 137 (read), and 482 / 123
(first byte), no latches. Enable=0 is 30, 21, and 10 ports and no
cells.

That guest buffer is a 64 by 64 rectangle at `64'h88070000`.
`(1,0)` in it is the half blend `32'hD2008000`. A 640 by 480
request records nothing. `(0,0)` or the next row records nothing.
Byte 0 of `(1,0)` is `8'h00`. The image is not kept. TEX is not
the compiler opcode. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed.
Remote 2026-09-30: `tb_g6lc_apu_vgpu_grd` 23 cases / 93 checks /
108 clocks, errors=0. Enable=1 is 710 cells / 102 flip-flops
(rectangle), 1,054 / 134 (lane), and 505 / 123 (first byte), no
latches. Enable=0 is 12, 22, and 11 ports and no cells.

Offset in that guest rectangle is `y * 256 + x * 4`. `(1,0)` is
byte 4 at `64'h88070000`. `(63,63)` is byte 16380 at
`64'h88073FE0`. `(0,0)` is the clamp texel `32'hA5000000`.
`(1,0)` as the origin records nothing. Byte 0 of `(0,0)` is
`8'h00`. The word is not the `(1,0)` blend. The image is not
kept. TEX is not the compiler opcode. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed.
Remote 2026-09-30: `tb_g6lc_apu_vgpu_rof` 21 cases / 89 checks /
103 clocks, errors=0. Enable=1 is 429 cells / 20 flip-flops
(offset), 1,008 / 106 (origin), and 529 / 75 (first byte), no
latches. Enable=0 is 12, 22, and 11 ports and no cells.

The `TRANSFER_FROM_HOST_3D` box is `(0,0,64,64)` of resource 4 at
640 by 480. A 640 by 480 box records nothing. A 64 by 64 resource
records nothing. Packed stride is 256. The 640-wide resource row
is 2560 and records nothing. The command is three guest beats at
`64'h88080000`. The image is not kept. TEX is not the compiler
opcode. This is not the screenshot. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. TEX is not executed. Remote 2026-09-30:
`tb_g6lc_apu_vgpu_tfb` 20 cases / 79 checks / 117 clocks,
errors=0. Enable=1 is 658 cells / 6 flip-flops (box), 1,368 / 331
(command), and 513 / 101 (packed stride), no latches. Enable=0 is
18, 20, and 11 ports and no cells.

`RESOURCE_ATTACH_BACKING` of that 64 by 64 buffer is length 16384
at `64'h88070000`. A 1,228,800-byte attach records nothing. The
command is two guest beats at `64'h88090000`. The image is not
kept. TEX is not the compiler opcode. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed.
Remote 2026-09-30: `tb_g6lc_apu_vgpu_rab` 19 cases / 76 checks /
107 clocks, errors=0. Enable=1 is 551 cells / 6 flip-flops
(attach), 1,358 / 331 (command), and 517 / 133 (crop length), no
latches. Enable=0 is 14, 20, and 11 ports and no cells.

The 24-byte virtio `OK_NODATA` of that transfer is at
`64'h880A0000`. The fence is 2. The scene fence
`64'h1122334455667788` is a different word. A missing fence bit
records nothing. The image is not kept. TEX is not the compiler
opcode. This is not the screenshot. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. TEX is not executed. Remote 2026-09-30:
`tb_g6lc_apu_vgpu_rfw` 15 cases / 68 checks / 88 clocks,
errors=0. Enable=1 is 447 cells / 9 flip-flops (write), 1,506 /
330 (read), and 649 / 133 (fence), no latches. Enable=0 is 20, 20,
and 10 ports and no cells.

The used element of that transfer is at `64'h880B0000` with
descriptor id 1. `used.idx` 2 is at `64'h880B0008`. The scene
element at `64'h8800E400` and index 1 record nothing. The image is
not kept. TEX is not the compiler opcode. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is
not executed. Remote 2026-09-30: `tb_g6lc_apu_vgpu_tuw` 16 cases /
72 checks / 105 clocks, errors=0. Enable=1 is 475 cells / 11
flip-flops (write), 909 / 171 (read), and 307 / 53 (index), no
latches. Enable=0 is 19, 20, and 10 ports and no cells.

The used-buffer interrupt reason `32'h1` of that transfer is at
`64'h880C0000`. The pin rises after `used.idx` 2 and falls on ack.
A cancel before the beat writes nothing. The scene status word at
`64'h8800E500` records nothing. The image is not kept. TEX is not
the compiler opcode. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is not executed.
Remote 2026-09-30: `tb_g6lc_apu_vgpu_tiw` 15 cases / 70 checks /
86 clocks, errors=0. Enable=1 is 349 cells / 8 flip-flops
(write), 617 / 88 (read), and 401 / 117 (keep), no latches.
Enable=0 is 22, 20, and 11 ports and no cells.

The guest ack of that interrupt is at `64'h880C0010`. The low
word must be `32'h1`. Remain 0 is then written over
`64'h880C0000`. A config ack or a zero ack writes nothing. The
scene ack at `64'h8800E510` records nothing. The image is not
kept. TEX is not the compiler opcode. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is
not executed. Remote 2026-09-30: `tb_g6lc_apu_vgpu_taw` 23 cases /
101 checks / 130 clocks, errors=0. Enable=1 is 489 cells / 7
flip-flops (ack), 834 / 155 (read), and 567 / 85 (keep), no
latches. Enable=0 is 29, 20, and 11 ports and no cells.

The guest descriptor chain of that transfer is at `64'h880D0000`.
Attach is `64'h88090000` with `NEXT` to the transfer at
`64'h88080000`. The 24-byte `WRITE` is at `64'h880A0000`. Avail
index 2 at `64'h880D0100` names descriptor 0. `INDIRECT`, a
broken link, and the scene index record nothing. The image is
not kept. TEX is not the compiler opcode. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. TEX is
not executed. Remote 2026-09-30: `tb_g6lc_apu_vgpu_txc` 23 cases /
98 checks / 144 clocks, errors=0. Enable=1 is 2045 cells / 523
flip-flops (chain), 848 / 261 (keep), and 471 / 101 (index), no
latches. Enable=0 is 21, 12, and 11 ports and no cells.

TEX of sampler view 5 on resource 1 at `(0,0)` is `32'hA5000000`
and at `(1,0)` is `32'hD2008000`. `refused` is 0. The clear word
records nothing. The compiler TEX opcode still returns `-26`.
The image is not kept. TEX is not the compiler opcode. This is
not the screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
Remote 2026-09-30: `tb_g6lc_apu_vgpu_ftx` 19 cases / 79 checks /
83 clocks, errors=0. Enable=1 is 523 cells / 133 flip-flops
(sample), 531 / 133 (keep), and 406 / 69 (check), no latches.
Enable=0 is 10, 11, and 11 ports and no cells.

Beat 0 of the scene window at `64'h88020000` is that TEX pair.
`(0,0)` is `32'hA5000000`. `(1,0)` is `32'hD2008000`. The other
511 beats are not stored. A 64-high scissor records nothing. The
compiler TEX opcode still returns `-26`. The image is not kept.
TEX is not the compiler opcode. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote 2026-09-30:
`tb_g6lc_apu_vgpu_ocw` 23 cases / 103 checks / 120 clocks,
errors=0. Enable=1 is 558 cells / 137 flip-flops (write), 1121 /
137 (read), and 548 / 155 (keep), no latches. Enable=0 is 19, 21,
and 10 ports and no cells.

Beat 0 of the guest readback at `64'h88030000` is that TEX pair.
`(0,0)` is `32'hA5000000`. `(1,0)` is `32'hD2008000`. The other
511 beats are not stored. A 64-high scissor records nothing. The
compiler TEX opcode still returns `-26`. The image is not kept.
TEX is not the compiler opcode. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote 2026-09-30:
`tb_g6lc_apu_vgpu_pbw` 23 cases / 103 checks / 120 clocks,
errors=0. Enable=1 is 595 cells / 137 flip-flops (write), 1117 /
137 (read), and 546 / 155 (keep), no latches. Enable=0 is 19, 21,
and 10 ports and no cells.

A posted walker accepts `NEXT` for that transfer chain. Avail
index 2 names descriptor 0. Device index starts at 1. The scene
chain at avail index 1 records nothing. `g6lc_apu_vgpu_avail`
still rejects `NEXT`. The compiler TEX opcode still returns
`-26`. The image is not kept. TEX is not the compiler opcode.
This is not the screenshot. Remote 2026-09-30:
`tb_g6lc_apu_vgpu_tnw` 29 cases / 105 checks / 123 clocks,
errors=0. Enable=1 is 1406 cells / 634 flip-flops (walk), 580 /
245 (keep), and 312 / 101 (index), no latches. Enable=0 is 12,
10, and 11 ports and no cells.

Guest QueueNotify of control queue 0 is at `64'h880D0200`. The
word is `32'd0`. The cursor queue records nothing. The compiler
TEX opcode still returns `-26`. The image is not kept. TEX is
not the compiler opcode. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote 2026-09-30:
`tb_g6lc_apu_vgpu_qnt` 17 cases / 77 checks / 93 clocks,
errors=0. Enable=1 is 310 cells / 9 flip-flops (write), 473 /
73 (read), and 293 / 53 (keep), no latches. Enable=0 is 19, 20,
and 11 ports and no cells.

Guest `virtq_avail.idx` after that QueueNotify is 2 at
`64'h880D0100`. The scene ring records nothing. The compiler TEX
opcode still returns `-26`. The image is not kept. TEX is not
the compiler opcode. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote 2026-09-30:
`tb_g6lc_apu_vgpu_qav` 17 cases / 74 checks / 87 clocks,
errors=0. Enable=1 is 357 cells / 41 flip-flops (read), 271 /
85 (keep), and 249 / 21 (index), no latches. Enable=0 is 19, 10,
and 11 ports and no cells.

Guest `virtq_avail.ring[0]` after that index names descriptor 0
at `64'h880D0104`. The scene ring records nothing. The compiler
TEX opcode still returns `-26`. The image is not kept. TEX is
not the compiler opcode. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote 2026-09-30:
`tb_g6lc_apu_vgpu_qrg` 16 cases / 70 checks / 83 clocks,
errors=0. Enable=1 is 342 cells / 41 flip-flops (read), 247 /
85 (keep), and 224 / 21 (name), no latches. Enable=0 is 19, 10,
and 11 ports and no cells.

Guest `virtq_desc` 0 after that ring name is the attach at
`64'h88090000`, length 64, `NEXT` to 1. The scene table records
nothing. The compiler TEX opcode still returns `-26`. The image
is not kept. TEX is not the compiler opcode. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote
2026-09-30: `tb_g6lc_apu_vgpu_qhd` 17 cases / 74 checks / 90
clocks, errors=0. Enable=1 is 671 cells / 233 flip-flops
(read), 309 / 117 (keep), and 438 / 85 (check), no latches.
Enable=0 is 19, 10, and 11 ports and no cells.

Guest `virtq_desc` 1 after that `NEXT` is the transfer at
`64'h88080000`, length 96, `NEXT` to 2. The attach descriptor
records nothing. The compiler TEX opcode still returns `-26`.
The image is not kept. TEX is not the compiler opcode. This is
not the screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
Remote 2026-09-30: `tb_g6lc_apu_vgpu_qfd` 17 cases / 74 checks /
90 clocks, errors=0. Enable=1 is 763 cells / 233 flip-flops
(read), 298 / 117 (keep), and 428 / 85 (check), no latches.
Enable=0 is 19, 10, and 11 ports and no cells.

Guest `virtq_desc` 2 after that `NEXT` is the `WRITE` of the
24-byte response at `64'h880A0000`. The transfer descriptor
records nothing. The compiler TEX opcode still returns `-26`.
The image is not kept. TEX is not the compiler opcode. This is
not the screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
Remote 2026-09-30: `tb_g6lc_apu_vgpu_qwd` 17 cases / 74 checks /
90 clocks, errors=0. Enable=1 is 739 cells / 201 flip-flops
(read), 263 / 101 (keep), and 420 / 69 (check), no latches.
Enable=0 is 19, 10, and 11 ports and no cells.

Guest `OK_NODATA` after that named `WRITE` is at `64'h880A0000`
with fence 2. The scene response records nothing. The compiler
TEX opcode still returns `-26`. The image is not kept. TEX is
not the compiler opcode. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote 2026-09-30:
`tb_g6lc_apu_vgpu_qok` 17 cases / 76 checks / 96 clocks,
errors=0. Enable=1 is 307 cells / 9 flip-flops (write), 1437 /
265 (read), and 687 / 101 (keep), no latches. Enable=0 is 18,
20, and 11 ports and no cells.

Guest used element after that `OK_NODATA` is id 1 at
`64'h880B0000` and `used.idx` 2 at `64'h880B0008`. The scene
index records nothing. The compiler TEX opcode still returns
`-26`. The image is not kept. TEX is not the compiler opcode.
This is not the screenshot. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. Remote 2026-09-30: `tb_g6lc_apu_vgpu_quw` 18 cases / 80
checks / 113 clocks, errors=0. Enable=1 is 383 cells / 11
flip-flops (write), 909 / 171 (read), and 374 / 53 (keep), no
latches. Enable=0 is 18, 20, and 11 ports and no cells.

Guest used-buffer interrupt after that `used.idx` 2 is reason
`32'h1` at `64'h880C0000`. The pin rises after the guest used
ring and falls on ack. The scene status word records nothing.
The compiler TEX opcode still returns `-26`. The image is not
kept. TEX is not the compiler opcode. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote 2026-09-30:
`tb_g6lc_apu_vgpu_qiw` 15 cases / 70 checks / 86 clocks,
errors=0. Enable=1 is 349 cells / 8 flip-flops (write), 617 /
88 (read), and 401 / 117 (keep), no latches. Enable=0 is 22,
20, and 11 ports and no cells.

Guest ack of that interrupt is `32'h1` at `64'h880C0010`. Remain
0 is then written over `64'h880C0000`. The scene ack records
nothing. The compiler TEX opcode still returns `-26`. The image
is not kept. TEX is not the compiler opcode. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote
2026-09-30: `tb_g6lc_apu_vgpu_qaw` 23 cases / 101 checks / 130
clocks, errors=0. Enable=1 is 489 cells / 7 flip-flops (ack),
834 / 155 (read), and 567 / 85 (keep), no latches. Enable=0 is
29, 20, and 11 ports and no cells.

Scene `virtq_avail.idx` after that ack is 1 at `64'h8800E200`.
The transfer ring records nothing. The compiler TEX opcode still
returns `-26`. The image is not kept. TEX is not the compiler
opcode. This is not the screenshot. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. Remote 2026-09-30: `tb_g6lc_apu_vgpu_qsv` 17
cases / 74 checks / 87 clocks, errors=0. Enable=1 is 442 cells /
41 flip-flops (read), 290 / 85 (keep), and 268 / 21 (check), no
latches. Enable=0 is 20, 11, and 12 ports and no cells.

Scene `virtq_avail.ring[0]` after that index names descriptor 0
at `64'h8800E204`. The transfer ring records nothing. The
compiler TEX opcode still returns `-26`. The image is not kept.
TEX is not the compiler opcode. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote 2026-09-30:
`tb_g6lc_apu_vgpu_qsr` 16 cases / 70 checks / 83 clocks,
errors=0. Enable=1 is 341 cells / 41 flip-flops (read), 247 / 85
(keep), and 224 / 21 (check), no latches. Enable=0 is 19, 10, and
11 ports and no cells.

Scene `virtq_desc` 0 after that ring name is the 32-byte header
at `64'h8800A000` with `NEXT` to 1. The transfer table records
nothing. The compiler TEX opcode still returns `-26`. The image
is not kept. TEX is not the compiler opcode. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote
2026-09-30: `tb_g6lc_apu_vgpu_qsd` 17 cases / 74 checks / 90
clocks, errors=0. Enable=1 is 670 cells / 233 flip-flops (read),
306 / 117 (keep), and 434 / 85 (check), no latches. Enable=0 is
19, 10, and 11 ports and no cells.

Scene `virtq_desc` 1 after that `NEXT` is the 960-byte execbuffer
at `64'h8800B000` with `NEXT` to 2. The transfer table records
nothing. The compiler TEX opcode still returns `-26`. The image
is not kept. TEX is not the compiler opcode. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote
2026-09-30: `tb_g6lc_apu_vgpu_qed` 17 cases / 74 checks / 90
clocks, errors=0. Enable=1 is 791 cells / 233 flip-flops (read),
306 / 117 (keep), and 431 / 85 (check), no latches. Enable=0 is
19, 10, and 11 ports and no cells.

Scene `virtq_desc` 2 after that `NEXT` is the `WRITE` of the
24-byte response at `64'h8800A800`. The transfer table records
nothing. The compiler TEX opcode still returns `-26`. The image
is not kept. TEX is not the compiler opcode. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote
2026-09-30: `tb_g6lc_apu_vgpu_qrs` 17 cases / 74 checks / 90
clocks, errors=0. Enable=1 is 761 cells / 201 flip-flops (read),
279 / 101 (keep), and 431 / 69 (check), no latches. Enable=0 is
19, 10, and 11 ports and no cells.

Scene `OK_NODATA` after that named `WRITE` is the scene fence at
`64'h8800A800`. The transfer response at `64'h880A0000` and
fence 2 record nothing. The compiler TEX opcode still returns
`-26`. The image is not kept. TEX is not the compiler opcode.
This is not the screenshot. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. Remote 2026-09-30: `tb_g6lc_apu_vgpu_qso` 17 cases / 76
checks / 96 clocks, errors=0. Enable=1 is 312 cells / 9
flip-flops (write), 1438 / 265 (read), and 688 / 101 (check), no
latches. Enable=0 is 18, 20, and 11 ports and no cells.

Scene used element after that `OK_NODATA` is id 0 at
`64'h8800E400` and `used.idx` 1 at `64'h8800E480`. The transfer
id 1 and index 2 record nothing. The compiler TEX opcode still
returns `-26`. The image is not kept. TEX is not the compiler
opcode. This is not the screenshot. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. Remote 2026-09-30: `tb_g6lc_apu_vgpu_qsu` 18
cases / 80 checks / 113 clocks, errors=0. Enable=1 is 383 cells
/ 11 flip-flops (write), 936 / 171 (read), and 398 / 53 (check),
no latches. Enable=0 is 18, 20, and 11 ports and no cells.

Scene used-buffer interrupt after that index is reason `32'h1` at
`64'h8800E500`. The transfer status at `64'h880C0000` records
nothing. The compiler TEX opcode still returns `-26`. The image
is not kept. TEX is not the compiler opcode. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote
2026-09-30: `tb_g6lc_apu_vgpu_qsi` 15 cases / 70 checks / 86
clocks, errors=0. Enable=1 is 349 cells / 8 flip-flops (write),
617 / 88 (read), and 401 / 117 (check), no latches. Enable=0 is
22, 20, and 11 ports and no cells.

Scene guest ack of that interrupt is `32'h1` at `64'h8800E510`.
Remain 0 is then written over `64'h8800E500`. The transfer ack at
`64'h880C0010` records nothing. The compiler TEX opcode still
returns `-26`. The image is not kept. TEX is not the compiler
opcode. This is not the screenshot. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. Remote 2026-09-30: `tb_g6lc_apu_vgpu_qga` 23
cases / 101 checks / 130 clocks, errors=0. Enable=1 is 489 cells
/ 7 flip-flops (ack), 837 / 155 (read), and 570 / 85 (check), no
latches. Enable=0 is 29, 20, and 11 ports and no cells.

A posted walker accepts `NEXT` for the scene submit chain at
avail index 1. The transfer chain at avail index 2 records
nothing. The compiler TEX opcode still returns `-26`. The image
is not kept. TEX is not the compiler opcode. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote
2026-09-30: `tb_g6lc_apu_vgpu_snw` 29 cases / 105 checks / 123
clocks, errors=0. Enable=1 is 1,305 cells / 633 flip-flops
(walk), 579 / 245 (keep), and 309 / 101 (check), no latches.
Enable=0 is 12, 10, and 11 ports and no cells.

Scene QueueNotify of control queue 0 is at `64'h8800E220` after
that walker. The transfer doorbell at `64'h880D0200` records
nothing. The compiler TEX opcode still returns `-26`. The image
is not kept. TEX is not the compiler opcode. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote
2026-09-30: `tb_g6lc_apu_vgpu_snt` 17 cases / 77 checks / 93
clocks, errors=0. Enable=1 is 313 cells / 9 flip-flops (write),
492 / 73 (read), and 294 / 53 (check), no latches. Enable=0 is
19, 20, and 11 ports and no cells.

Scene `virtq_avail.idx` after that QueueNotify is 1 at
`64'h8800E200`. The transfer ring at `64'h880D0100` records
nothing. The compiler TEX opcode still returns `-26`. The image
is not kept. TEX is not the compiler opcode. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote
2026-09-30: `tb_g6lc_apu_vgpu_sav` 17 cases / 74 checks / 87
clocks, errors=0. Enable=1 is 357 cells / 41 flip-flops (read),
271 / 85 (keep), and 249 / 21 (index), no latches. Enable=0 is
19, 10, and 11 ports and no cells.

Scene `virtq_avail.ring[0]` after that index names descriptor 0
at `64'h8800E204`. The transfer ring at `64'h880D0104` records
nothing. The compiler TEX opcode still returns `-26`. The image
is not kept. TEX is not the compiler opcode. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote
2026-09-30: `tb_g6lc_apu_vgpu_srg` 16 cases / 70 checks / 83
clocks, errors=0. Enable=1 is 341 cells / 41 flip-flops (read),
247 / 85 (keep), and 224 / 21 (index), no latches. Enable=0 is
19, 10, and 11 ports and no cells.

Scene `virtq_desc` 0 after that ring name is the header at
`64'h8800A000`, length 32, `NEXT` to 1. The transfer table at
`64'h880D0000` records nothing. The compiler TEX opcode still
returns `-26`. The image is not kept. TEX is not the compiler
opcode. This is not the screenshot. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. Remote 2026-09-30: `tb_g6lc_apu_vgpu_shd` 17
cases / 74 checks / 90 clocks, errors=0. Enable=1 is 670 cells /
233 flip-flops (read), 306 / 117 (keep), and 434 / 85 (check),
no latches. Enable=0 is 19, 10, and 11 ports and no cells.

Scene `virtq_desc` 1 after that `NEXT` is the execbuffer at
`64'h8800B000`, length 960, `NEXT` to 2. The transfer table
records nothing. The compiler TEX opcode still returns `-26`.
The image is not kept. TEX is not the compiler opcode. This is
not the screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
Remote 2026-09-30: `tb_g6lc_apu_vgpu_sfd` 17 cases / 74 checks /
90 clocks, errors=0. Enable=1 is 770 cells / 233 flip-flops
(read), 306 / 117 (keep), and 431 / 85 (check), no latches.
Enable=0 is 19, 10, and 11 ports and no cells.

Scene `virtq_desc` 2 after that `NEXT` is the `WRITE` of the
24-byte response at `64'h8800A800`. The transfer table records
nothing. The compiler TEX opcode still returns `-26`. The image
is not kept. TEX is not the compiler opcode. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote
2026-09-30: `tb_g6lc_apu_vgpu_swd` 17 cases / 74 checks / 90
clocks, errors=0. Enable=1 is 751 cells / 201 flip-flops
(read), 272 / 101 (keep), and 424 / 69 (check), no latches.
Enable=0 is 19, 10, and 11 ports and no cells.

Scene `OK_NODATA` after that `WRITE` is the scene fence at
`64'h8800A800`. The transfer response records nothing. The
compiler TEX opcode still returns `-26`. The image is not kept.
TEX is not the compiler opcode. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote 2026-09-30:
`tb_g6lc_apu_vgpu_sok` 17 cases / 76 checks / 96 clocks,
errors=0. Enable=1 is 312 cells / 9 flip-flops (write), 1,438 /
265 (read), and 688 / 101 (check), no latches. Enable=0 is 18,
20, and 11 ports and no cells.

Scene used element after that `OK_NODATA` is id 0 at
`64'h8800E400` and `used.idx` 1 at `64'h8800E480`. The transfer
used ring records nothing. The compiler TEX opcode still returns
`-26`. The image is not kept. TEX is not the compiler opcode.
This is not the screenshot. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. Remote 2026-09-30: `tb_g6lc_apu_vgpu_slw` 18 cases / 80
checks / 113 clocks, errors=0. Enable=1 is 383 cells / 11
flip-flops (write), 936 / 171 (read), and 398 / 53 (check), no
latches. Enable=0 is 18, 20, and 11 ports and no cells.

Scene used-buffer interrupt after that used ring after
QueueNotify is reason `32'h1` at `64'h8800E500`. The transfer
status records nothing. The compiler TEX opcode still returns
`-26`. The image is not kept. TEX is not the compiler opcode.
This is not the screenshot. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. Remote 2026-09-30: `tb_g6lc_apu_vgpu_siw` 15 cases / 70
checks / 86 clocks, errors=0. Enable=1 is 349 cells / 8
flip-flops (write), 617 / 88 (read), and 401 / 117 (check), no
latches. Enable=0 is 22, 20, and 11 ports and no cells.

Scene guest ack of that interrupt after QueueNotify is `32'h1`
at `64'h8800E510`. Remain 0 is then written over `64'h8800E500`.
The transfer ack records nothing. The compiler TEX opcode still
returns `-26`. The image is not kept. TEX is not the compiler
opcode. This is not the screenshot. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. Remote 2026-09-30: `tb_g6lc_apu_vgpu_sga` 23
cases / 101 checks / 130 clocks, errors=0. Enable=1 is 489 cells
/ 7 flip-flops (write), 837 / 155 (read), and 570 / 85 (check),
no latches. Enable=0 is 29, 20, and 11 ports and no cells.

Posted `NEXT` walker of the 64 by 64 transfer chain after that
scene guest ack. Avail index 2. Device index starts at 1. The
scene chain records nothing. This does not read guest memory.
The compiler TEX opcode still returns `-26`. The image is not
kept. TEX is not the compiler opcode. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote
2026-10-01: `tb_g6lc_apu_vgpu_rnw` 29 cases / 105 checks / 123
clocks, errors=0. Enable=1 is 1,368 cells / 634 flip-flops
(walk), 598 / 245 (keep), and 312 / 101 (check), no latches.
Enable=0 is 12, 10, and 11 ports and no cells.

QueueNotify of control queue 0 at `64'h880D0200` after that
walker. The cursor queue and the scene doorbell at
`64'h8800E220` record nothing. The compiler TEX opcode still
returns `-26`. The image is not kept. TEX is not the compiler
opcode. This is not the screenshot. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. Remote 2026-10-01: `tb_g6lc_apu_vgpu_rnt` 17
cases / 77 checks / 93 clocks, errors=0. Enable=1 is 334 cells /
9 flip-flops (write), 518 / 73 (read), and 293 / 53 (check), no
latches. Enable=0 is 19, 20, and 11 ports and no cells.

`virtq_avail.idx` 2 at `64'h880D0100` after that QueueNotify
after scene guest ack. The scene ring records nothing. The
compiler TEX opcode still returns `-26`. The image is not kept.
TEX is not the compiler opcode. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote 2026-10-01:
`tb_g6lc_apu_vgpu_rav` 17 cases / 74 checks / 87 clocks,
errors=0. Enable=1 is 357 cells / 41 flip-flops (read), 271 / 85
(keep), and 249 / 21 (check), no latches. Enable=0 is 19, 10,
and 11 ports and no cells.

`virtq_avail.ring[0]` at `64'h880D0104` after that index after
scene guest ack names descriptor 0. The scene ring records
nothing. The compiler TEX opcode still returns `-26`. The image
is not kept. TEX is not the compiler opcode. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote
2026-10-01: `tb_g6lc_apu_vgpu_rrg` 16 cases / 70 checks / 83
clocks, errors=0. Enable=1 is 342 cells / 41 flip-flops (read),
247 / 85 (keep), and 224 / 21 (check), no latches. Enable=0 is
19, 10, and 11 ports and no cells.

`virtq_desc` 0 at `64'h880D0000` after that ring name after
scene guest ack is the attach at `64'h88090000`, length 64,
`NEXT` to 1. The scene table records nothing. The compiler TEX
opcode still returns `-26`. The image is not kept. TEX is not
the compiler opcode. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote 2026-10-01:
`tb_g6lc_apu_vgpu_rhd` 17 cases / 74 checks / 90 clocks,
errors=0. Enable=1 is 671 cells / 233 flip-flops (read), 309 /
117 (keep), and 438 / 85 (check), no latches. Enable=0 is 19,
10, and 11 ports and no cells.

`virtq_desc` 1 at `64'h880D0010` after that `NEXT` after scene
guest ack is the transfer at `64'h88080000`, length 96, `NEXT`
to 2. The attach descriptor and the scene table record nothing.
The compiler TEX opcode still returns `-26`. The image is not
kept. TEX is not the compiler opcode. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote
2026-10-01: `tb_g6lc_apu_vgpu_rfd` 17 cases / 74 checks / 90
clocks, errors=0. Enable=1 is 763 cells / 233 flip-flops (read),
298 / 117 (keep), and 428 / 85 (check), no latches. Enable=0 is
19, 10, and 11 ports and no cells.

`virtq_desc` 2 at `64'h880D0020` after that `NEXT` after scene
guest ack is the `WRITE` of the 24-byte response at
`64'h880A0000`. The transfer descriptor and the scene table
record nothing. The compiler TEX opcode still returns `-26`. The
image is not kept. TEX is not the compiler opcode. This is not
the screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
Remote 2026-10-01: `tb_g6lc_apu_vgpu_rwd` 17 cases / 74 checks /
90 clocks, errors=0. Enable=1 is 739 cells / 201 flip-flops
(read), 263 / 101 (keep), and 420 / 69 (check), no latches.
Enable=0 is 19, 10, and 11 ports and no cells.

Guest `OK_NODATA` after that named `WRITE` after scene guest ack
is fence 2 at `64'h880A0000`. The scene response records
nothing. The compiler TEX opcode still returns `-26`. The image
is not kept. TEX is not the compiler opcode. This is not the
screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote
2026-10-01: `tb_g6lc_apu_vgpu_rok` 17 cases / 76 checks / 96
clocks, errors=0. Enable=1 is 307 cells / 9 flip-flops (write),
1437 / 265 (echo), and 687 / 101 (check), no latches. Enable=0
is 18, 20, and 11 ports and no cells.

Guest used element after that `OK_NODATA` after scene guest ack
is id 1 at `64'h880B0000` and `used.idx` 2 at `64'h880B0008`.
The scene used ring records nothing. The compiler TEX opcode
still returns `-26`. The image is not kept. TEX is not the
compiler opcode. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote 2026-10-01:
`tb_g6lc_apu_vgpu_ruw` 18 cases / 80 checks / 113 clocks,
errors=0. Enable=1 is 383 cells / 11 flip-flops (write), 909 /
171 (echo), and 374 / 53 (check), no latches. Enable=0 is 18,
20, and 11 ports and no cells.

Guest used-buffer interrupt after that index after scene guest
ack is reason `32'h1` at `64'h880C0000`. The scene status word
records nothing. The compiler TEX opcode still returns `-26`.
The image is not kept. TEX is not the compiler opcode. This is
not the screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
Remote 2026-10-01: `tb_g6lc_apu_vgpu_riw` 15 cases / 70 checks /
86 clocks, errors=0. Enable=1 is 349 cells / 8 flip-flops
(write), 617 / 88 (echo), and 401 / 117 (check), no latches.
Enable=0 is 22, 20, and 11 ports and no cells.

Guest ack of that used-buffer interrupt after scene guest ack is
`32'h1` at `64'h880C0010`. Remain 0 over `64'h880C0000`. The
scene ack records nothing. The compiler TEX opcode still returns
`-26`. The image is not kept. TEX is not the compiler opcode.
This is not the screenshot. `g6lc_apu_vgpu_avail` still rejects
`NEXT`. Remote 2026-10-01: `tb_g6lc_apu_vgpu_rga` 23 cases / 101
checks / 130 clocks, errors=0. Enable=1 is 489 cells / 7
flip-flops (read), 834 / 155 (echo), and 567 / 85 (check), no
latches. Enable=0 is 29, 20, and 11 ports and no cells.

TEX of sampler view 5 after that guest ack after scene guest ack
is the clamp texel `32'hA5000000` at `(0,0)` and the half blend
`32'hD2008000` at `(1,0)`. `refused` is 0. `used.idx` is 2. The
clear word records nothing. The compiler TEX opcode still
returns `-26`. The image is not kept. TEX is not the compiler
opcode. This is not the screenshot. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. Remote 2026-10-01: `tb_g6lc_apu_vgpu_gtx` 18
cases / 75 checks / 79 clocks, errors=0. Enable=1 is 415 cells /
85 flip-flops (sample), 393 / 85 (keep), and 347 / 53 (check),
no latches. Enable=0 is 10, 11, and 11 ports and no cells.

Beat 0 of the guest `TRANSFER_FROM_HOST_3D` buffer at
`64'h88070000` after that guest ack is the TEX pair. Lane 0 is
`(0,0)`, the clamp texel. Lane 1 is `(1,0)`, the half blend. The
scene window records nothing. The compiler TEX opcode still
returns `-26`. The image is not kept. TEX is not the compiler
opcode. This is not the screenshot. `g6lc_apu_vgpu_avail` still
rejects `NEXT`. Remote 2026-10-01: `tb_g6lc_apu_vgpu_hcw` 23
cases / 103 checks / 120 clocks, errors=0. Enable=1 is 594 cells
/ 137 flip-flops (write), 1132 / 137 (echo), and 547 / 155
(check), no latches. Enable=0 is 19, 21, and 10 ports and no
cells.

Covered TEX samples after that guest transfer beat are `(0,0)`
clamp `32'hA5000000` at byte 0 and `(1,0)` half blend
`32'hD2008000` at byte 4. `refused` is 0. Any other coordinate
records nothing. The compiler TEX opcode still returns `-26`.
The image is not kept. TEX is not the compiler opcode. This is
not the screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
Remote 2026-10-01: `tb_g6lc_apu_vgpu_wld` 17 cases / 71 checks /
75 clocks, errors=0. Enable=1 is 418 cells / 39 flip-flops
(sample), 291 / 65 (keep), and 349 / 51 (check), no latches.
Enable=0 is 11, 10, and 11 ports and no cells.

Four channels of that covered TEX sample: the clamp texel is the
bytes 00 00 00 A5 and the half blend is the bytes 00 80 00 D2.
Byte 0 is red `8'h00`. The clear channels record nothing. The
compiler TEX opcode still returns `-26`. The image is not kept.
TEX is not the compiler opcode. This is not the screenshot.
`g6lc_apu_vgpu_avail` still rejects `NEXT`. Remote 2026-10-01:
`tb_g6lc_apu_vgpu_cyr` 15 cases / 63 checks / 67 clocks,
errors=0. Enable=1 is 189 cells / 51 flip-flops (read), 313 / 83
(keep), and 242 / 53 (check), no latches. Enable=0 is 9, 10, and
11 ports and no cells.

After QueueNotify of control queue 0, a guest-rung walk of the
scene `NEXT` chain consumes device index 1. Avail index 1 names
descriptor 0. The transfer table records nothing. The compiler
TEX opcode still returns `-26`. The image is not kept. This is
not the screenshot. `g6lc_apu_vgpu_avail` still rejects `NEXT`.
Remote 2026-10-01: `tb_g6lc_apu_vgpu_gnw` 26 cases / 107 checks /
155 clocks, errors=0. Enable=1 is 1557 cells / 396 flip-flops
(walk), 498 / 181 (keep), and 481 / 101 (check), no latches.
Enable=0 is 19, 10, and 11 ports and no cells.

After that guest-rung walk consumed device index 1, the scene
header and the 960-byte execbuffer are fetched. The first command
word is the surface `CREATE_OBJECT`. Transfer dest records
nothing. The compiler TEX opcode still returns `-26`. The image
is not kept. This is not the screenshot. `g6lc_apu_vgpu_avail`
still rejects `NEXT`. Remote 2026-10-01: `tb_g6lc_apu_vgpu_gef`
20 cases / 81 checks / 161 clocks, errors=0. Enable=1 is 779
cells / 81 flip-flops (fetch), 295 / 70 (keep), and 274 / 38
(check), no latches. Enable=0 is 19, 10, and 11 ports and no
cells.

`tb_g6lc_apu_vgpu_cmd` was 15/62/73 after the rasterizer-bind field and was not
re-run after `VsbEn` through `GexEn`.

## 7. Lab surface, gates, verification

The lab surface is a second set of private units, also absent from `g6lc_apu_sys`.

| Unit | Role |
|---|---|
| `g6lc_apu_cover` | One sample against one triangle. Signed 16-bit edges, +x right, +y up. Color is copied through. |
| `g6lc_apu_frag` | RGBA8 byte memory. Address `y * stride + x * 4`. Byte 0 is red. Ceiling 64×64, stride 256, 16384 bytes. |
| `g6lc_apu_rsurf` | One covered sample copied out of a resource image of the same shape. |
| `g6lc_apu_vgpu_rdb` | One `TRANSFER_FROM_HOST_3D` of that image. Guest stores are 32-byte beats. The 64×64 image is 512 beats at `64'h8800C000`. |
| `g6lc_apu_vgpu_xfer` | One stored backing entry into the resource. One matching beat. Lengths above 32 are not a multi-beat copy here. |

`use_image` together with `use_texel` or a texel write is a fault. `use_prog` together with
any of those is a fault. Program color is the compiler word `32'hAA000000` plus an FP32
immediate: 0 is opaque black `32'hFF000000`, 0.5 is gray `32'hFF808080`, 1.0 is white
`32'hFFFFFFFF`. An immediate of 2.0 does not write. The lab image keeps solid
`32'hFF0000FF` at `(0,0)`, program gray at `(1,0)`, texel `32'hFF80FF40` at `(2,0)`, gray
at `(0,32)`, and white at `(63,63)`. `y = 64` does not write. Sample `(1,0)` of the 4×2
resource ramp is `32'hA7A6A5A4`. `RESOURCE_CREATE_2D` records 64×64 and rejects a 128-wide
resource. `TEX` still returns `-26`.

| Gate | Plan exit | Where this tree is |
|---|---|---|
| A0 External contract | Pinned traffic, formats, errors, truthful capsets | Reference captured. QEMU 10.0.0 / virglrenderer 1.0.0, guest OpenWrt 24.10.2 / Linux 6.6.93 / Mesa 21.3. Hardware obligations open. |
| A1 Substrate | Address, source, epoch, drain, leases, truthful geometry | Partial, in the SoC box. Outlines `apu-testharness-bus.md`, `apu-firmware-ram.md`, `apu-native-exec.md`. L2 line fills are untagged. Scatter-gather and `g6lc_apu_queue` still take raw maps. |
| A2 Persistent service | OpenSBI S-mode service, protected hart, restart | Bring-up only. Cookies and hart fetch. `apu-firmware-domain.md`, `apu-cva6-fetch.md`. |
| A3 Protocol and compiler | A virtqueue, virgl resources, the same words on host and CVA6 | Subset. One compiler. Ordinary commands in the private units (create, fence, local used element and IRQ, one avail slot, one backing entry, one backing read, used-element write, `used.idx` store). One `SUBMIT_3D` checker, one execbuffer read, and the command list through byte 960. That list does not rasterize. Context 1, the two 3D resources, the three attaches, and the 24-byte scene response are recorded. Capset info and capset get are refused. Scanout and flush of resource 4 at 640 by 480 are recorded and do not present. `g6lc_apu_vgpu_avail` still rejects a descriptor chain. A separate walker accepts the scene chain and publishes one local used element. |
| A4 Resource-backed graphics | Vertex through fragment into one surface, cache-visible | Lab samples and a 64×64 byte memory exist. They are not the scene’s vertex, coverage, sampler, and fragment path. |
| A5 First picture | Unchanged Linux/Mesa EGL/GLES2 on this RTL, pixels from the program | Open. Requires A2, A3, and A4. Private fixtures are not that guest. |
| A6 Profile | CTS/dEQP, isolation, recovery | Open. |
| A7 Presentation | HDMI and DP, each with bandwidth, CDC, DFT, and a board PHY | Scanout model only: 640×480 `r5g6b5`, line buffer, video TMDS, 10× shift. `hdmi-display.md`. A booted simpledrm guest, a connector, and a PHY are open. |

Remote suites run under WSL through `verif/regress/remote/testharness_proxy.py` on the
testharness host. Verilator is v5.008. A sync line of rc=0 is not the suite result.
The CVA6 cookies were not re-run for the command prefix or the byte-memory split.

## 8. Pointers

| Question | Read |
|---|---|
| Leaf counts and the command each unit checks | `apu-resident-fw.md`, `AGENTS-todo.md` |
| Attach, bus, RAM, firmware, exec, TGSI | the other `apu-*.md` outlines in this directory |
| Scene, command bytes, screenshot identity | `g6lc_bios/architecture/DISPLAY.md` |
| Plan gates and the screenshot objective | `plan-5ddc97674e5bf9b0.md` sections 5 and 6 |
| HDMI scanout | `hdmi-display.md` |
| Snapshot beside the other SoC planes | `architecture/current-stage.md` |
