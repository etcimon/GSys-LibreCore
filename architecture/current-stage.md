# Current stage — SMT2, QEMU, 100 TOPS, graphics, and the broader change sets

**Scaffold only** (`architecture/README.md`). Queue: [`AGENTS-todo.md`](../AGENTS-todo.md)
**Current phase**. Emulator asks: [`g6lc_qemu/architecture/RTL_FEEDBACK.md`](../g6lc_qemu/architecture/RTL_FEEDBACK.md).
QEMU never substitutes for Variane evidence (`multi-threading/testharness-proxy.md`).

This file is the **WIP snapshot** the programs of record point at. It does not replace
`router-core-upgrade-program.md` or `remaining-upgrade-sequence.md`; it records where those
tracks actually are so 100 TOPS work is not sequenced as if the rest of the SoC were still
at U0. The graphics lane is a parallel envelope. Its map is
[`uncore/apu-graphics.md`](uncore/apu-graphics.md). A 100 TOPS pass does not advance it,
and a graphics leaf does not qualify HDMI or the island.

**Graphics override, 2026-10-01:** the long graphics rows below are historical
fixture censuses, not current qualification or authoritative tracked/untracked
labels. Pinned UE 5.8.3 and two official Ubuntu kernel references are now local,
clean and lazy. The current requirement matrix is in `uncore/apu-graphics.md`;
`corev_apu/apu/AGENTS-impl-interplays.md` §15 records six reviewed source boundaries.
The APU still lacks the connected general queue-to-shader-to-surface path
required by the proposed stock Venus backend. `ShmEn` publishes virtio-mmio
SHM id 1; `g6lc_apu_hvis` maps a HOST_VISIBLE blob and Venus
`context_init`. `g6lc_apu_vncs` runs CREATE_MODULE/DISPATCH through
SpirvSubset on a diagnostic HOST_VISIBLE ring. `g6lc_apu_vcap` answers
Venus GET_CAPSET id 4. `g6lc_apu_vnring` walks Mesa `vn_ring_layout`.
`g6lc_apu_tdma` joins compositor DMA onto testharness `slave[2]` under
`G6LC_APU` (`NrSlaves` stays 3; `ApuHarness.DmaReadEn=0`).
`g6lc_apu_vnenc` decodes Mesa `vn_protocol` `vkCreateShaderModule`.
`g6lc_apu_vnp` feeds that CS from a `vn_ring` buffer into SpirvSubset.
`g6lc_apu_avn` reads `virtq_avail` and follows NEXT through NextChain.
`g6lc_apu_avu` publishes `virtq_used` elem then `used.idx`.
`g6lc_apu_uir` raises virtio used-buffer ISR after that store.
`g6lc_apu_cms` snapshots the first payload window so guest mutation
does not change it. `g6lc_apu_prs` stores a programmed WRITE-window
response. `g6lc_apu_qdn` publishes response, `used.idx`, and ISR after
one walk. `g6lc_apu_gcs` grants Venus GET_CAPSET/INFO on that
WRITE window. `g6lc_apu_vnd` decodes Mesa `vn_protocol`
`vkCmdDispatch`. `g6lc_apu_gnh` is an eight-slot generational
handle table with pin/retire. `g6lc_apu_hdp` looks up that
published CMDBUF handle on `vkCmdDispatch`. `g6lc_apu_hph`
publishes a MODULE handle from `vkCreateShaderModule` and looks up
CMDBUF on dispatch. `g6lc_apu_hrn` commits that SPIR-V and kicks
SpirvSubset on a live CMDBUF. `g6lc_apu_rdn` writes that result,
then `used.idx` and ISR. `g6lc_apu_qrn` walks AvailNext and fetches
that CS into RunDone. `g6lc_apu_qcm` muxes GrantCapset and QueueRun
on one request. `g6lc_apu_qty` peeks the first command word and
selects that path. `g6lc_apu_vct` is a private control face:
`num_capsets` reads as 1 and QueueNotify of queue 0 fires QueueType.
`g6lc_apu_qpu` drains that notify until EMPTY.
`g6lc_apu_ntk` consumes virtio `notify_pending[0]` into that pump.
`g6lc_apu_vqt` arms NotifyTake from virtio `vq_state[0]`.
`g6lc_apu_vax` runs those guest beats on 64-bit AXI.
`g6lc_apu_vac` decodes Mesa `vkAllocateCommandBuffers` and ALLOCs
a CMDBUF handle. `g6lc_apu_hal` looks that handle up on
`vkCmdDispatch` on one table. `g6lc_apu_aru` ALLOCs that CMDBUF,
CREATE a MODULE, and DISPATCH SpirvSubset on one table.
`g6lc_apu_qal` walks AvailNext into that ALLOC/CREATE/DISPATCH path.
`g6lc_apu_qta` peeks the type word and selects GrantCapset or QueueAlloc.
`g6lc_apu_vca` is a private control face: `num_capsets` reads as 1
and QueueNotify fires QueueTypeAlloc.
`g6lc_apu_qpa` drains that notify until EMPTY so type 88 ALLOC
rides the same drain as GET_CAPSET.
`g6lc_apu_nta` consumes virtio `notify_pending[0]` into that ALLOC
pump.
`g6lc_apu_vqa` arms NotifyTakeAlloc from virtio `vq_state[0]` on
`notify_pending[0]`.
`g6lc_apu_vaa` runs those guest beats on 64-bit AXI.
`g6lc_apu_vbg` decodes Mesa `vn_protocol` `vkBeginCommandBuffer`.
`g6lc_apu_bal` ALLOCs a CMDBUF and looks it up on
`vkBeginCommandBuffer` on one table.
`g6lc_apu_bru` ALLOCs INSTANCE from `vkCreateInstance`, LOOKUPs it
on `vkEnumeratePhysicalDevices` then ALLOCs PHYS, LOOKUPs PHYS on
`vkGetPhysicalDeviceFeatures`, `vkGetPhysicalDeviceProperties`,
`vkGetPhysicalDeviceMemoryProperties`, and
`vkGetPhysicalDeviceQueueFamilyProperties`, LOOKUPs PHYS on
`vkCreateDevice` then ALLOCs DEVICE, LOOKUPs DEVICE on
`vkGetDeviceQueue` then ALLOCs QUEUE, LOOKUPs DEVICE on
`vkAllocateMemory` then ALLOCs MEMORY, LOOKUPs DEVICE on
`vkCreateBuffer` then ALLOCs BUFFER, LOOKUPs BUFFER then MEMORY on
`vkBindBufferMemory`, LOOKUPs MEMORY on `vkMapMemory`, LOOKUPs MEMORY on `vkUnmapMemory`
after a prior map, LOOKUPs BUFFER on `vkGetBufferMemoryRequirements`,
LOOKUPs MEMORY on `vkFlushMappedMemoryRanges` after a prior map,
LOOKUPs MEMORY on `vkInvalidateMappedMemoryRanges` after a prior map,
LOOKUPs MEMORY on `vkGetDeviceMemoryCommitment`,
LOOKUPs DEVICE then ALLOCs DSLAYOUT on `vkCreateDescriptorSetLayout`,
LOOKUPs DEVICE then ALLOCs PLAYOUT on `vkCreatePipelineLayout`,
LOOKUPs DEVICE then ALLOCs PIPELINE on `vkCreateComputePipelines`,
LOOKUPs DEVICE then ALLOCs POOL on `vkCreateDescriptorPool`,
LOOKUPs DEVICE then ALLOCs IMAGE on `vkCreateImage`,
LOOKUPs IMAGE on `vkGetImageMemoryRequirements`,
LOOKUPs IMAGE then MEMORY on `vkBindImageMemory`,
LOOKUPs DEVICE then ALLOCs DESCSET on `vkAllocateDescriptorSets` after LOOKUP POOL,
LOOKUPs DESCSET then BUFFER on `vkUpdateDescriptorSets`,
LOOKUPs PIPELINE on `vkCmdBindPipeline` after BEGIN,
LOOKUPs DESCSET on `vkCmdBindDescriptorSets` after BEGIN,
ALLOCs CMDBUF, BEGINs, CREATEs
a MODULE, DISPATCHes SpirvSubset, ENDs the begun CMDBUF, SUBMITs the
ended handle against that QUEUE, and WAITs the prior submit on one
table.
`g6lc_apu_qbn` walks AvailNext into that path so types 90, 91, 18,
19, 17, 11, 0, 2, 3, 6, 7, 8, 21, 50, 28, 23, 24, 30, 25, 26, 27, 29, 31, 54, 72, 68, 66, 74, 77, 79, 93, and 103 ride the CS payload.
`g6lc_apu_qtb` peeks the type word and selects GrantCapset or
QueueBegin so types 90, 91, 18, 19, 17, 11, 0, 2, 3, 6, 7, 8, 21, 50, 28, 23, 24, 30, 25, 26, 27, 29, 31, 54, 72, 68, 66, 74, 77, 79, 93, and 103 ride GET_CAPSET.
`g6lc_apu_vqs` decodes Mesa `vn_protocol` `vkQueueSubmit`.
`g6lc_apu_vwi` decodes `vkQueueWaitIdle`.
`g6lc_apu_vgq` decodes `vkGetDeviceQueue`.
`g6lc_apu_vcd` decodes `vkCreateDevice`.
`g6lc_apu_vci` decodes `vkCreateInstance`.
`g6lc_apu_vep` decodes `vkEnumeratePhysicalDevices`.
`g6lc_apu_vqf` decodes `vkGetPhysicalDeviceQueueFamilyProperties`.
`g6lc_apu_vpf` decodes `vkGetPhysicalDeviceFeatures`.
`g6lc_apu_vpp` decodes `vkGetPhysicalDeviceProperties`.
`g6lc_apu_vmp` decodes `vkGetPhysicalDeviceMemoryProperties`.
`g6lc_apu_vam` decodes `vkAllocateMemory`.
`g6lc_apu_vxb` decodes `vkCreateBuffer`.
`g6lc_apu_vbb` decodes `vkBindBufferMemory`.
`g6lc_apu_vmm` decodes `vkMapMemory`.
`g6lc_apu_vum` decodes `vkUnmapMemory`.
`g6lc_apu_vbm` decodes `vkGetBufferMemoryRequirements`.
`g6lc_apu_vfm` decodes `vkFlushMappedMemoryRanges`.
`g6lc_apu_vim` decodes `vkInvalidateMappedMemoryRanges`.
`g6lc_apu_vmc` decodes `vkGetDeviceMemoryCommitment`.
`g6lc_apu_vdl` decodes `vkCreateDescriptorSetLayout`.
`g6lc_apu_vpl` decodes `vkCreatePipelineLayout`.
`g6lc_apu_vcp` decodes `vkCreateComputePipelines`.
`g6lc_apu_vda` decodes `vkAllocateDescriptorSets`.
`g6lc_apu_vud` decodes `vkUpdateDescriptorSets`.
`g6lc_apu_vbp` decodes `vkCmdBindPipeline`.
`g6lc_apu_vbd` decodes `vkCmdBindDescriptorSets`.
`g6lc_apu_vpo` decodes `vkCreateDescriptorPool`.
`g6lc_apu_vxi` decodes `vkCreateImage`.
`g6lc_apu_vbi` decodes `vkBindImageMemory`.
`g6lc_apu_vmi` decodes `vkGetImageMemoryRequirements`.
`g6lc_apu_vxv` decodes `vkCreateImageView`.
`g6lc_apu_vsm` decodes `vkCreateSampler`.
`g6lc_apu_vrp` decodes `vkCreateRenderPass`.
`g6lc_apu_vgp` decodes `vkCreateGraphicsPipelines`.
`g6lc_apu_vfb` decodes `vkCreateFramebuffer`.
`g6lc_apu_vrb` decodes `vkCmdBeginRenderPass`.
`g6lc_apu_vdw` decodes `vkCmdDraw`.
`g6lc_apu_vre` decodes `vkCmdEndRenderPass`.
`g6lc_apu_vvb` decodes `vkCmdBindVertexBuffers`.
`g6lc_apu_vib` decodes `vkCmdBindIndexBuffer`.
`g6lc_apu_vdi` decodes `vkCmdDrawIndexed`.
`g6lc_apu_vvp` decodes `vkCmdSetViewport`.
`g6lc_apu_vsi` decodes `vkCmdSetScissor`.
`g6lc_apu_vpb` decodes `vkCmdPipelineBarrier`.
`g6lc_apu_vns` decodes `vkCmdNextSubpass`.
`g6lc_apu_vdf` decodes `vkDestroyFramebuffer`.
`g6lc_apu_vdx` decodes `vkDestroyImageView`.
`g6lc_apu_vdk` decodes `vkDestroySampler`.
`g6lc_apu_vdr` decodes `vkDestroyRenderPass`.
`g6lc_apu_vdb` decodes `vkDestroyBuffer`.
`g6lc_apu_vdg` decodes `vkDestroyImage`.
`g6lc_apu_vfe` decodes `vkFreeMemory`.
`g6lc_apu_vdm` decodes `vkDestroyShaderModule`.
`g6lc_apu_vdp` decodes `vkDestroyPipeline`.
`g6lc_apu_vdy` decodes `vkDestroyPipelineLayout`.
`g6lc_apu_vdt` decodes `vkDestroyDescriptorSetLayout`.
`g6lc_apu_vdq` decodes `vkDestroyDescriptorPool`.
`g6lc_apu_vfs` decodes `vkFreeDescriptorSets`.
`g6lc_apu_vrc` decodes `vkResetCommandBuffer`.
`g6lc_apu_vfc` decodes `vkFreeCommandBuffers`.
`g6lc_apu_vdd` decodes `vkDestroyDevice`.
`g6lc_apu_vpc` decodes `vkResetCommandPool`.
`g6lc_apu_vdc` decodes `vkDestroyCommandPool`.
`g6lc_apu_vdn` decodes `vkDestroyInstance`.
`g6lc_apu_vgf` decodes `vkGetPhysicalDeviceFormatProperties`.
`g6lc_apu_vip` decodes `vkGetPhysicalDeviceImageFormatProperties`.
`g6lc_apu_vxe` decodes `vkEnumerateDeviceExtensionProperties`.
`g6lc_apu_vrd` decodes `vkResetDescriptorPool`.
`g6lc_apu_vie` decodes `vkEnumerateInstanceExtensionProperties`.
`g6lc_apu_vwl` decodes `vkDeviceWaitIdle`.
`g6lc_apu_vsl` decodes `vkGetImageSubresourceLayout`.
`g6lc_apu_vrg` decodes `vkGetRenderAreaGranularity`.
`g6lc_apu_vlw` decodes `vkCmdSetLineWidth`.
`g6lc_apu_vzb` decodes `vkCmdSetDepthBias`.
`g6lc_apu_vbc` decodes `vkCmdSetBlendConstants`.
`g6lc_apu_vbo` decodes `vkCmdSetDepthBounds`.
`g6lc_apu_vcm` decodes `vkCmdSetStencilCompareMask`.
`g6lc_apu_vwm` decodes `vkCmdSetStencilWriteMask`.
`g6lc_apu_vrf` decodes `vkCmdSetStencilReference`.
`g6lc_apu_vcc` decodes `vkCmdCopyBuffer`.
`g6lc_apu_vcy` decodes `vkCmdCopyImage`.
`g6lc_apu_vbl` decodes `vkCmdBlitImage`.
`g6lc_apu_vbt` decodes `vkCmdCopyBufferToImage`.
`g6lc_apu_vic` decodes `vkCmdCopyImageToBuffer`.
`g6lc_apu_vub` decodes `vkCmdUpdateBuffer`.
`g6lc_apu_vfl` decodes `vkCmdFillBuffer`.
`g6lc_apu_vcl` decodes `vkCmdClearColorImage`.
`g6lc_apu_vio` decodes `vkCmdDrawIndirect`.
`g6lc_apu_vix` decodes `vkCmdDrawIndexedIndirect`.
`g6lc_apu_vds` decodes `vkCmdClearDepthStencilImage`.
`g6lc_apu_vat` decodes `vkCmdClearAttachments`.
`g6lc_apu_vin` decodes `vkCmdDispatchIndirect`.
`g6lc_apu_vrs` decodes `vkCmdResolveImage`.
`g6lc_apu_vgs` decodes `vkGetFenceStatus`.
`g6lc_apu_vwf` decodes `vkWaitForFences`.
`g6lc_apu_vfr` decodes `vkResetFences`.
`g6lc_apu_vfn` decodes `vkDestroyFence`.
QueueBegin publishes used.idx and ISR for every successful command
whose last descriptor is WRITE.
`g6lc_apu_vcb` is a private control face: `num_capsets` reads as 1
and QueueNotify fires QueueTypeBegin.
`g6lc_apu_qpb` drains that notify until EMPTY so type 90 BEGIN
rides the same drain as GET_CAPSET.
`g6lc_apu_ntb` consumes virtio `notify_pending[0]` into that BEGIN
pump.
`g6lc_apu_vqb` arms NotifyTakeBegin from virtio `vq_state[0]` on
`notify_pending[0]`.
`g6lc_apu_vab` runs those guest beats on 64-bit AXI.
`g6lc_apu_ven` decodes Mesa `vn_protocol` `vkEndCommandBuffer`.
`g6lc_apu_eal` ALLOCs a CMDBUF, looks it up on
`vkBeginCommandBuffer`, then looks the begun handle up on
`vkEndCommandBuffer` on one table.
`NumCapsets` stays 0. `RESOURCE_BLOB` and `CONTEXT_INIT` stay outside
`APU_IMPL_FEATURES`. `g6lc_apu_vgpu_avail` still faults NEXT. Those
units are not new children of `g6lc_apu_sys`. No Ubuntu boot or Unreal
run is claimed. ApuOff/graphics/AI/presentation gates remain unchanged.
`FeatureVirgl` stays illegal.

- 2026-10-05: engine route attached (`VenusEn`); controlling roadmap `uncore/apu-vulkan-engine.md` §12.

---

## 1. What is live (2026-09)

| Plane | Live state | Not yet |
|---|---|---|
| **B1 SMT2 RTL** | Fine-grain banks (PC/CSR/RF/RAS/GHR); `g6lc64_smt2` N=1 T=2; cookie SUCCESS `51b1babe` is Variane trapdump; SL-W queue landed (default `WtDcacheFixupDepth=0`); I4dp `_v` and `ooo_server` 200M `tohost=0` on proxy | SL-C topology truth; R3b Linux Image; dual-commit same cycle; `SMT2` default SKU; retire boot crutches |
| **QEMU firmware** | U1–U3 (virt + generated `g6lc-soc` OpenSBI/U-Boot/EDK2/OpenWrt/`CPUINFO-DONE`); E2–E3 EDK2 virt; linux-dist **gitlinks** (openwrt `37fc534`, edk2 `4460122`, four feeds) | E4 RTL pflash tandem; soc U3-Shell StartImage hang; `g6lc-soc` has no PCI |
| **AI island** | I1-lite panel box 1024×512×512 (MAC issue 512; VA panels 512×512, 512×256, 1024×128), peak sketch 2.048 TOPS = 512 MAC/cycle × 2 GHz nameplate; the 256³ ~83.7k cy figure is the previous 256-MAC array and was not re-timed; CPL FIFO; PLIC-8; **I3-lite** NoC nameplate 16 GB/s (64-bit × 2 GHz, still 8 bytes/cycle) + PMU/CAP; `MaxAROut=2`; Cas=0 bypass; opt-in `G6LC_AI_DRAM_TIMING` → `AiIslandDdr4TimingSim` (class 0, Cas=14, AR=8, still the 1 GHz timing struct); DRAM backend is the **SoC** `master[DRAM]` slave (cores + island share it); `DramChannels` N=1 live. **CLI:** `diag run ai` / `test --ai` / `test --ai-remote` / `test --ai --channels 4 --ai-dram 1` / `g6q --ai` (QEMU not Variane) | **I3 DRAM-class** (LiteDRAM generated, class-1 N=1/2/4 **opt-in only**; S7 N=4 two IDs/PHY + GEMM stripe directed PASS — `uncore/dram-channel-scaling.md`; 400 GB/s SKU not live); I2 clusters; I4 UPF/thermal |
| **ai-tensor / PCIe stand-in** | virt-ai-pcie TCP UIO; packed DESC/CPL/CAP join EDK2 ESP; doorbell/IRQ/QoS/qid bounds; `contracts.ai_host_transport` **unpinned** | Fused GPEX endpoint; pinned BAR/MSI/device ID; Linux UIO on live board |
| **OoO / multi-issue / multi-core** | `OoOEn` production-gated; `NrIssuePorts` 1–4 by package; `NrCores` 1–8 hub; stream8 CRT 9/9. **Issue width is not retirement:** `g6lc64_ooo_server` requests four commit ports; `scoreboard`/`commit_stage` still count/retire two. L2 RR is default-off; 8 KiB mapped + 4 KiB collect PASS; 16 KiB collect timed out. Isolated stream8 RR-on AMOCAS/stream minis and all-set L2 hot+scan (384,179 cy) match RR-off cycles (0 delta). L2 leaf A/B 4-way 31,108 vs 27,604 cy; 8-way mix 26,256 vs 26,080 (~0.7%). Keep RR off. SMT2 RR-on livelocks. Not a core performance win | Slice-OoO default off; `CVA6_MAX_SMT_HARTS=2`; merge stream×SMT packages; 4-port retirement; production-geometry mapped L2 equivalence |
| **Hypervisor** | U9.0–U9.2 + H-edge Spike+RTL 3/3 | KVM stress; G-stage soak |
| **RVV** | Ara vendored + attach + lint + DTS + directed tests | OpenSBI VRF; live Ara cosim |
| **Stream plane** | `g6lc64_stream8` promoted; orthogonal to SMT2 until FDT trusted | Do not merge with `g6lc64_smt2` DI |
| **Graphics lane** | **2026-10-05: see `uncore/apu-vulkan-engine.md` §11 rows 3c-i/3c-ii and §12 — the Venus hardware backend is attached behind `ApuCfg.VenusEn`; everything after this sentence is the frozen catalog census.** SoC box `g6lc_apu_soc` / `g6lc_apu_sys` (`Flist.apu_soc`): virtio-mmio, mailbox, memory, one FPnew lane. Default `ApuOff`; diagnostic testharness passes `ApuHarness`. Both keep graphics enables at 0. Guest `gpu@0x40001000`, PLIC 9, control `0x40002000`, firmware RAM `0x90000000`/256 KiB. Private untracked fixtures decode the frozen `gles2-min` execbuffer through the draw at byte 960 (`tb_g6lc_apu_vgpu_tail`, 2026-09-23, 337/955/4733) and store the 24-byte scene response (`tb_g6lc_apu_vgpu_ctl`, 27/88/375). Capset requests record `INVALID_PARAMETER`. Scanout 0 of resource 4 is recorded and does not present (`tb_g6lc_apu_vgpu_pre`, 20/63/206). The scene chain is accepted by `g6lc_apu_vgpu_chn` and one local used element is published (`tb_g6lc_apu_vgpu_chn`, 26/75/115). That element is stored at `64'h8800D000` and `used.idx` 1 at `64'h8800E002` (`tb_g6lc_apu_vgpu_sunw`, 11/56/61). The clear word `32'hFF1A0D0D` stands for all 4096 samples of the 64×64 ceiling (`tb_g6lc_apu_vgpu_fil`, 14/56/63). `(1,0)` reads address 4. The 24 quad floats match the NDC square and every ceiling sample is covered (`tb_g6lc_apu_vgpu_qd`, 14/52/113). The stored color stays `32'hFF1A0D0D`. The vertex text is the 32-dword VERT passthrough at byte 48 and the fragment text is the 35-dword TEX program at byte 200 (`tb_g6lc_apu_vgpu_vtx`, 20/75/225). That program is bound to sampler view 5 on resource 1 and sampler state 6. Resource 1 is a 640×480 `B8G8R8X8` image. Its transfer is the top 640×64 band and copies no bytes. Scanout 0 names that resource at 640×480 and the band flush does not present, so the word stays `32'hFF1A0D0D` (`tb_g6lc_apu_vgpu_ssc`, 17/61/153). The top band is read as 5,120 beats and the image is not stored (`tb_g6lc_apu_vgpu_bcp`, 10/41/10297). Ceiling `(0,0)` is the corner texel (`tb_g6lc_apu_vgpu_tap`, 13/51/68). `(1,0)` is the half blend `32'hD2008000` (`tb_g6lc_apu_vgpu_lin`, 11/41/63). `x = 8` spans the beat and is `32'h8091A2B3` (`tb_g6lc_apu_vgpu_spn`, 11/39/68). `y = 1`, `x = 0` is `32'h53010202` and `y = 1`, `x = 1` is `32'h6B024303` (`tb_g6lc_apu_vgpu_vln`, 11/41/60). On that row, `x = 2` is `32'h42024203` and `x = 7` is `32'h1A222B33` (`tb_g6lc_apu_vgpu_vbx`, 12/53/78). `x = 8` spans the beat and is `32'h434C545D` (`tb_g6lc_apu_vgpu_vsp`, 13/63/91). `y = 2`, `x = 0` is `32'h79797A7A` and `y = 2`, `x = 1` is `32'h42424343` (`tb_g6lc_apu_vgpu_y2b`, 12/55/73). Every point of the 64 by 64 ceiling can be sampled (`tb_g6lc_apu_vgpu_smp`, 4117/16472/38678). `(0,3)` is `32'h78787878`. The ceiling is written as 512 beats at `32'h88040000` (`tb_g6lc_apu_vgpu_rbf`, 7/35/39646) and read back (`tb_g6lc_apu_vgpu_rdr`, 7/30/1066). The scene header and the 960-byte execbuffer are fetched (`tb_g6lc_apu_vgpu_fet`, 8/33/113). The DRAW_VBO at byte 908 is recognized, count 4 and triangle strip, and is not executed (`tb_g6lc_apu_vgpu_drd`, 13/59/81). The 24 NDC floats at byte 696 are read and not transformed (`tb_g6lc_apu_vgpu_qdr`, 14/63/97). The viewport places that square on 0..640 by 0..480 (`tb_g6lc_apu_vgpu_vwx`, 13/59/80). The scissor is that same rectangle (`tb_g6lc_apu_vgpu_cxr`, 13/59/71). The clear packs to `32'hFF1A0D0D` (`tb_g6lc_apu_vgpu_cwr`, 13/59/78). One color buffer names surface 1 (`tb_g6lc_apu_vgpu_fbr`, 13/59/78). The vertex buffer is stride 24, offset 0, resource 3 (`tb_g6lc_apu_vgpu_vbf`, 14/63/87). That resource is an inline write of 96 bytes (`tb_g6lc_apu_vgpu_iwr`, 13/59/78). The sampler view at byte 632 names fragment slot 0 and handle 5 (`tb_g6lc_apu_vgpu_svr`, 15/67/91). The sampler state at byte 616 names fragment slot 0 and handle 6 (`tb_g6lc_apu_vgpu_ssr`, 15/67/85). The vertex-element bind at byte 608 names handle 4 (`tb_g6lc_apu_vgpu_ver`, 13/59/71). The fragment shader at byte 596 names handle 3 (`tb_g6lc_apu_vgpu_fsr`, 14/63/78). The vertex shader at byte 584 names handle 2 (`tb_g6lc_apu_vgpu_vsr`, 14/63/78). The rasterizer bind at byte 576 names handle 9 (`tb_g6lc_apu_vgpu_rzr`, 13/59/71). The depth-stencil bind at byte 568 names handle 8 (`tb_g6lc_apu_vgpu_dbr`, 13/59/71). The blend bind at byte 560 names handle 7 (`tb_g6lc_apu_vgpu_bbr`, 13/59/71). The rasterizer object at byte 520 names handle 9 (`tb_g6lc_apu_vgpu_rcr`, 15/67/89). Its eight state words are 0. The depth-stencil object at byte 496 names handle 8 (`tb_g6lc_apu_vgpu_dcr`, 15/67/89). Its four state words are 0. The blend object at byte 448 names handle 7 and color word `32'h78020010` (`tb_g6lc_apu_vgpu_blr`, 16/71/96). The sampler-state object at byte 408 names handle 6, wrap word `32'h00002292`, and max LOD `32'h42000000` (`tb_g6lc_apu_vgpu_scr`, 17/75/109). The sampler view at byte 380 names handle 5, resource 1, format `32'h02000002`, and swizzle `32'h00000688` (`tb_g6lc_apu_vgpu_svc`, 18/79/120). The vertex-element object at byte 340 names handle 4, with format 31 at offset 0 and format 29 at offset 16 (`tb_g6lc_apu_vgpu_vec`, 19/83/125). The fragment-shader object at byte 176 names handle 3, the vertex-shader object at byte 24 names handle 2, and the surface object at byte 0 names handle 1, resource 4, and format 2 (`tb_g6lc_apu_vgpu_obj`, 53/221/317). Guest descriptors at `64'h8800E100` link the header, the 960-byte execbuffer, and the 24-byte response. Avail index 1 at `64'h8800E200` names descriptor 0 (`tb_g6lc_apu_vgpu_nxc`, 16/71/109). The completed-opcode list at `64'h8800E300` is count 0 and capset id 0 (`tb_g6lc_apu_vgpu_ols`, 13/59/71). The virgl capset stays refused. A 64 by 64 guest window at `64'h88020000` is 512 beats of clear word `32'hFF1A0D0D` (`tb_g6lc_apu_vgpu_gpw`, 16/73/1112). The guest response at `64'h8800A800` is `OK_NODATA` with fence `64'h1122334455667788`. The used element at `64'h8800E400` is descriptor 0 and length 24. The used index at `64'h8800E480` is 1 (`tb_g6lc_apu_vgpu_gcw`, 22/96/127). The used-buffer interrupt reason at `64'h8800E500` is `32'h1`. Ack lowers the pin (`tb_g6lc_apu_vgpu_viw`, 20/89/102). The guest ack at `64'h8800E510` is `32'h1`, and the status word at `64'h8800E500` is then `32'h0` (`tb_g6lc_apu_vgpu_vaw`, 22/96/122). All 512 beats of the window are that clear word (`tb_g6lc_apu_vgpu_wfr`, 21/86/2149). That window is copied to `64'h88030000` (`tb_g6lc_apu_vgpu_gbw`, 19/84/2153), a 64 by 64 rectangle of 16384 bytes (`tb_g6lc_apu_vgpu_gbd`, 18/78/91). `(1,0)` is byte 4 and row 1 starts at byte 256 (`tb_g6lc_apu_vgpu_gof`, 19/85/101). The clear word sits in memory as the bytes 0D 0D 1A FF, so byte 0 is red (`tb_g6lc_apu_vgpu_byr`, 17/71/86). Row 1 at `64'h88030100` starts with that same red byte (`tb_g6lc_apu_vgpu_ryr`, 22/91/107). `(1,1)` is byte 260, `(2,3)` is byte 776, and `(0,63)` is byte 16128 (`tb_g6lc_apu_vgpu_tpr`, 23/95/124). `(63,0)` is byte 252 at `64'h880300E0` (`tb_g6lc_apu_vgpu_x6r`, 21/87/103). `(7,0)` is byte 28, lane 7 of `64'h88030000` (`tb_g6lc_apu_vgpu_p7r`, 21/87/103). `(8,0)` is byte 32 and `(15,0)` is byte 60, both in `64'h88030020` (`tb_g6lc_apu_vgpu_b1r`, 21/87/103). `(56,0)` is byte 224, lane 0 of `64'h880300E0`, and `(63,0)` stays byte 252, lane 7 of that beat (`tb_g6lc_apu_vgpu_b7r`, 21/87/103). `(16,0)` is byte 64 and `(23,0)` is byte 92, both in `64'h88030040` (`tb_g6lc_apu_vgpu_b2r`, 21/87/103). `(24,0)` is byte 96 and `(31,0)` is byte 124, both in `64'h88030060` (`tb_g6lc_apu_vgpu_b3r`, 21/87/103). `(32,0)` is byte 128 and `(39,0)` is byte 156, both in `64'h88030080` (`tb_g6lc_apu_vgpu_b4r`, 21/87/103). `(40,0)` is byte 160 and `(47,0)` is byte 188, both in `64'h880300A0` (`tb_g6lc_apu_vgpu_b5r`, 21/87/103). `(48,0)` is byte 192 and `(55,0)` is byte 220, both in `64'h880300C0` (`tb_g6lc_apu_vgpu_b6r`, 21/87/103). `(63,63)` is byte 16380, lane 7 of `64'h88033FE0` (`tb_g6lc_apu_vgpu_tcr`, 22/91/107). The linear sample pair is written as fragment color at `64'h88050000` (`tb_g6lc_apu_vgpu_acw`, 25/109/125). `(0,0)` is the clamp texel `32'hA5000000`. `(1,0)` is the half blend `32'hD2008000`. Those 512 ceiling sample beats are copied to `64'h88060000` (`tb_g6lc_apu_vgpu_csw`, 24/105/2172). That window is a 64 by 64 rectangle (`tb_g6lc_apu_vgpu_crd`, 22/90/104). `(1,0)` in it is the half blend `32'hD2008000`. `(0,0)` is the clamp texel `32'hA5000000` (`tb_g6lc_apu_vgpu_cof`, 21/89/103). That rectangle is copied to `64'h88070000` as `TRANSFER_FROM_HOST_3D` of resource 4 (`tb_g6lc_apu_vgpu_rpw`, 24/105/2172). That guest buffer is a 64 by 64 rectangle (`tb_g6lc_apu_vgpu_grd`, 23/93/108). Offset in that guest rectangle is `y * 256 + x * 4` (`tb_g6lc_apu_vgpu_rof`, 21/89/103). `(0,0)` is the clamp texel `32'hA5000000`. The `TRANSFER_FROM_HOST_3D` box is `(0,0,64,64)` of resource 4 at 640 by 480 (`tb_g6lc_apu_vgpu_tfb`, 20/79/117). Packed stride is 256. `RESOURCE_ATTACH_BACKING` of that buffer is length 16384 (`tb_g6lc_apu_vgpu_rab`, 19/76/107). The 24-byte virtio `OK_NODATA` of that transfer is at `64'h880A0000` with fence 2 (`tb_g6lc_apu_vgpu_rfw`, 15/68/88). The used element is at `64'h880B0000` with id 1 and `used.idx` 2 (`tb_g6lc_apu_vgpu_tuw`, 16/72/105). The used-buffer interrupt reason `32'h1` is at `64'h880C0000` (`tb_g6lc_apu_vgpu_tiw`, 15/70/86). The guest ack of that interrupt is at `64'h880C0010` (`tb_g6lc_apu_vgpu_taw`, 23/101/130). The guest descriptor chain of that transfer is at `64'h880D0000` (`tb_g6lc_apu_vgpu_txc`, 23/98/144). TEX of sampler view 5 at `(0,0)` is `32'hA5000000` (`tb_g6lc_apu_vgpu_ftx`, 19/79/83). Beat 0 of the scene window at `64'h88020000` is that pair (`tb_g6lc_apu_vgpu_ocw`, 23/103/120). Beat 0 of the guest readback at `64'h88030000` is that pair (`tb_g6lc_apu_vgpu_pbw`, 23/103/120). A posted walker accepts `NEXT` for that transfer chain at avail index 2 (`tb_g6lc_apu_vgpu_tnw`, 29/105/123). Guest QueueNotify of control queue 0 is at `64'h880D0200` (`tb_g6lc_apu_vgpu_qnt`, 17/77/93). Guest `virtq_avail.idx` after that notify is 2 at `64'h880D0100` (`tb_g6lc_apu_vgpu_qav`, 17/74/87). Guest `virtq_avail.ring[0]` names descriptor 0 at `64'h880D0104` (`tb_g6lc_apu_vgpu_qrg`, 16/70/83). Guest `virtq_desc` 0 is the attach at `64'h88090000` with `NEXT` to 1 (`tb_g6lc_apu_vgpu_qhd`, 17/74/90). Guest `virtq_desc` 1 is the transfer at `64'h88080000` with `NEXT` to 2 (`tb_g6lc_apu_vgpu_qfd`, 17/74/90). Guest `virtq_desc` 2 is the `WRITE` of the 24-byte response at `64'h880A0000` (`tb_g6lc_apu_vgpu_qwd`, 17/74/90). Guest `OK_NODATA` after that `WRITE` is fence 2 at `64'h880A0000` (`tb_g6lc_apu_vgpu_qok`, 17/76/96). Guest used element after that `OK_NODATA` is id 1 / `used.idx` 2 (`tb_g6lc_apu_vgpu_quw`, 18/80/113). Guest used-buffer interrupt after that index is reason `32'h1` at `64'h880C0000` (`tb_g6lc_apu_vgpu_qiw`, 15/70/86). Guest ack of that interrupt is `32'h1` at `64'h880C0010` (`tb_g6lc_apu_vgpu_qaw`, 23/101/130). Scene `virtq_avail.idx` after that ack is 1 at `64'h8800E200` (`tb_g6lc_apu_vgpu_qsv`, 17/74/87). Scene `virtq_avail.ring[0]` names descriptor 0 at `64'h8800E204` (`tb_g6lc_apu_vgpu_qsr`, 16/70/83). Scene `virtq_desc` 0 is the 32-byte header at `64'h8800A000` with `NEXT` to 1 (`tb_g6lc_apu_vgpu_qsd`, 17/74/90). Scene `virtq_desc` 1 is the 960-byte execbuffer at `64'h8800B000` with `NEXT` to 2 (`tb_g6lc_apu_vgpu_qed`, 17/74/90). Scene `virtq_desc` 2 is the `WRITE` of the 24-byte response at `64'h8800A800` (`tb_g6lc_apu_vgpu_qrs`, 17/74/90). Scene `OK_NODATA` after that `WRITE` is the scene fence at `64'h8800A800` (`tb_g6lc_apu_vgpu_qso`, 17/76/96). Scene used element after that `OK_NODATA` is id 0 / `used.idx` 1 (`tb_g6lc_apu_vgpu_qsu`, 18/80/113). Scene used-buffer interrupt after that index is reason `32'h1` at `64'h8800E500` (`tb_g6lc_apu_vgpu_qsi`, 15/70/86). Scene guest ack of that interrupt is `32'h1` at `64'h8800E510` (`tb_g6lc_apu_vgpu_qga`, 23/101/130). A posted walker accepts `NEXT` for the scene submit chain at avail index 1 (`tb_g6lc_apu_vgpu_snw`, 29/105/123). Scene QueueNotify of control queue 0 is at `64'h8800E220` (`tb_g6lc_apu_vgpu_snt`, 17/77/93). Scene `virtq_avail.idx` after that notify is 1 at `64'h8800E200` (`tb_g6lc_apu_vgpu_sav`, 17/74/87). Scene `virtq_avail.ring[0]` names descriptor 0 at `64'h8800E204` (`tb_g6lc_apu_vgpu_srg`, 16/70/83). Scene `virtq_desc` 0 is the header at `64'h8800A000` with `NEXT` to 1 (`tb_g6lc_apu_vgpu_shd`, 17/74/90). Scene `virtq_desc` 1 is the execbuffer at `64'h8800B000` with `NEXT` to 2 (`tb_g6lc_apu_vgpu_sfd`, 17/74/90). Scene `virtq_desc` 2 is the `WRITE` of the 24-byte response at `64'h8800A800` (`tb_g6lc_apu_vgpu_swd`, 17/74/90). Scene `OK_NODATA` after that `WRITE` is the scene fence at `64'h8800A800` (`tb_g6lc_apu_vgpu_sok`, 17/76/96). Scene used element after that `OK_NODATA` is id 0 / `used.idx` 1 (`tb_g6lc_apu_vgpu_slw`, 18/80/113). Scene used-buffer interrupt after that index is reason `32'h1` at `64'h8800E500` (`tb_g6lc_apu_vgpu_siw`, 15/70/86). Scene guest ack of that interrupt is `32'h1` at `64'h8800E510` (`tb_g6lc_apu_vgpu_sga`, 23/101/130). A posted walker accepts `NEXT` for the transfer chain at avail index 2 after that ack (`tb_g6lc_apu_vgpu_rnw`, 29/105/123). QueueNotify of control queue 0 is at `64'h880D0200` after that walker (`tb_g6lc_apu_vgpu_rnt`, 17/77/93). `virtq_avail.idx` after that notify is 2 at `64'h880D0100` (`tb_g6lc_apu_vgpu_rav`, 17/74/87). `virtq_avail.ring[0]` names descriptor 0 at `64'h880D0104` (`tb_g6lc_apu_vgpu_rrg`, 16/70/83). `virtq_desc` 0 is the attach at `64'h88090000` with `NEXT` to 1 (`tb_g6lc_apu_vgpu_rhd`, 17/74/90). `virtq_desc` 1 is the transfer at `64'h88080000` with `NEXT` to 2 (`tb_g6lc_apu_vgpu_rfd`, 17/74/90). `virtq_desc` 2 is the `WRITE` of the 24-byte response at `64'h880A0000` (`tb_g6lc_apu_vgpu_rwd`, 17/74/90). Guest `OK_NODATA` after that `WRITE` is fence 2 at `64'h880A0000` (`tb_g6lc_apu_vgpu_rok`, 17/76/96). Guest used element after that `OK_NODATA` is id 1 / `used.idx` 2 (`tb_g6lc_apu_vgpu_ruw`, 18/80/113). Guest used-buffer interrupt after that index is reason `32'h1` at `64'h880C0000` (`tb_g6lc_apu_vgpu_riw`, 15/70/86). Guest ack of that interrupt is `32'h1` at `64'h880C0010` (`tb_g6lc_apu_vgpu_rga`, 23/101/130). TEX of sampler view 5 after that ack is clamp `32'hA5000000` / half blend `32'hD2008000` with `refused` 0 (`tb_g6lc_apu_vgpu_gtx`, 18/75/79). Beat 0 of the guest transfer buffer at `64'h88070000` after that ack is that TEX pair (`tb_g6lc_apu_vgpu_hcw`, 23/103/120). Covered samples `(0,0)` / `(1,0)` of that pair are clamp / half blend with `refused` 0 (`tb_g6lc_apu_vgpu_wld`, 17/71/75). Those words are the bytes 00 00 00 A5 and 00 80 00 D2, byte 0 red (`tb_g6lc_apu_vgpu_cyr`, 15/63/67). After QueueNotify of control queue 0, a guest-rung walk of the scene NEXT chain consumes device index 1 (`tb_g6lc_apu_vgpu_gnw`, 26/107/155). After that walk the scene header and execbuffer are fetched (`tb_g6lc_apu_vgpu_gef`, 20/81/161). The shader is not run. Neither shader is run. No framebuffer is painted. No blend is applied. No depth test is run. No triangle is walked. The shader is not run. No vertices are fetched. No texture is bound. `g6lc_apu_vgpu_avail` still rejects `NEXT`. That list does not rasterize. Lab RGBA8 ceiling is 64×64. HDMI scanout is a separate `HdmiEn` leaf. Map: `uncore/apu-graphics.md` | A2 S-mode service, a virtqueue the avail walker accepts, a draw that stores the scene, then A5: a 64×64 readback whose bytes come from this RTL. `FeatureVirgl` stays outside `APU_IMPL_FEATURES`. `TEX` returns `-26`. |

100 TOPS remains the **§2 definition** (100e12 dense INT8 ops/s, 1 MAC = 2 ops, no sparsity/INT4
in the headline). The live island is a **latency SKU fixture**, not a 100-TOPS measurement.

---

## 2. Parallel change sets (do not serialise)

These are **independent envelopes**. A 100-TOPS island pass must not wait for full OoO, and an
OoO pass must not invent AI BAR sizes.

```
                    ┌─ B1 SMT2 / soft-ladder (cookie, SL-W, SL-C, R3b Image)
                    ├─ QEMU firmware ladder (virt/soc U-Boot/EDK2; E4 pflash later)
 SoC control plane ─┤─ Hypervisor KVM stress (U9 landed; soak open)
                    ├─ Stream8 vs SMT2 (orthogonal until FDT trusted)
                    └─ RVV/Ara cosim (attach landed; VRF open)

                    ┌─ I3-lite live (DramClass=0, N=1, 16 GB/s nameplate, 8 bytes/cycle, PMU→CAP)
 100 TOPS island ───┤─ I3 DRAM: LiteDRAM at shared xbar DRAM slave, DramClass=1
                    │    (cores + L2 + NrCores use the same channels; before I2)
                    ├─ F12 host tiling vs the 1024×512×512 box; F13 writeback in sizing
                    ├─ VA-Turbo exact reuse on `AiCfgVaTurboTest` only (live `VaTurboEn` stays 0; not a TOPS step)
                    └─ I2 cluster replica only after DRAM I3 (F6+F8 published)

                    ┌─ Keep RC (g6lc-virt GPEX + EDK2) and EP (virt_ai_card) separate
 PCIe / host push ──┤─ Pin contracts.ai_host_transport before any BAR/device-id
                    └─ F1 placement published (AI_CAP_BASE=0x4000_0000)

                    ┌─ SoC box: ApuOff default, testharness ApuHarness (gpu@0x40001000, PLIC 9)
 Graphics lane ─────┤─ Private virtio command list through the draw (byte 960)
                    ├─ Lab 64×64 RGBA8 surface; A5 screenshot only after A2+A3+A4
                    └─ HDMI scanout (HdmiEn) stays a separate 640×480 leaf
```

Config identity: `OoOEn=0`, `NrHarts=1`, `AiMatrixEn=0`, `VExtEn=0` remain **netlist-identity**
paths. Graphics enable bits on `apu_cfg_t` default to 0 and sit outside that set.
`FeatureVirgl` stays outside `APU_IMPL_FEATURES`. Named packages (`g6lc64_smt2`,
`g6lc64_stream8`, `g6lc64_ai`, `cv64a6_ooo_server`, `cv64a6_server_math_v`) are union-soaked,
not merged (`soft-ladder/CONTRACT.md` §8).

---

## 3. 100 TOPS next (from RTL_FEEDBACK, in order)

Emulator ingest for F1–F8 is largely **landed**; the **design asks stay open**. Do not delete a
row because QEMU packed a descriptor. Detail: `RTL_FEEDBACK.md` §2.1.

| Order | Work | Why it is next |
|---|---|---|
| 1 | **I3 DRAM class** (LiteDRAM at the **shared** xbar DRAM slave, `DramClass=1`) | Vendored + `--sim` generated. **DramChannels** 1/2/4/8 (power of two); nameplate **N×19 GB/s**. Live **1 ch**. Opt-in `G6LC_AI_DRAM_CLASS1` (1 ch) or `G6LC_AI_DRAM_CHANS_2` (2 ch / 38 GB/s). Core I$/D$/PTW/L2/`NrCores` already hit this slave — do not make channels island-private. Stability: `uncore/dram-channel-scaling.md`. |
| 2 | **I3 measured ≥80% of `min(nameplate, fabric)`** | Directed class-1 `--sim` 256-beat stream **7858 milli-GB/s (98% of 8 GB/s at the 1 GHz accounting)**. 80% gate **closed** on that stream. The live nameplate is now 16 GB/s (64-bit × 2 GHz) and the port is still 8 bytes/cycle; the stream has not been re-timed. Do not treat 16 as a new measurement, nor 8 as 400, nor 19 as measured. |
| 3 | **F12 host tiling** against MaxDim=`AI_LIVE_MACS` (512) | Directed `ai_gemm_tile_2x2_smoke` (32³ → 2×2 packed 16×16). A 4096 cube on the 1024×512×512 box is 4×8×8 descriptors. |
| 4 | **I2 clusters** only after DRAM I3 | F8 bitmap is published; growing MACs on 8 GB/s is the §11 failure. |
| 5 | **Pin `ai_host_transport`** after F1 (published) | Keep GPEX RC ≠ virt_ai_card EP. |

Published this pass / prior: F1–F15; **S1–S7 directed closed**. Native wrap **PASS** id6 **1445 cy** (eight AR + eight AW live / 9th backpressure, mixed AW+AR, L1 16 B, WRAP SLVERR). Wrap **NrArSlots/NrAwSlots** = island `MaxAROut` (CLASS1 = 8); AXI held until `init_done` (`ForceInitDone=1` in `--sim`). Testharness live cookie keeps pulp atomics (1 AR/AW). S4/CLASS1 uses `g6lc_axi_atomics_wrap` (AMO+cut+`g6lc_axi_lrsc`, eight AR/AW **50 cy**; LR/SC proven on isolated lrsc). Rebuild `ai-dt` to pick it up. Class-1 `--sim` 256-beat stream **7858 milli-GB/s (98% of fabric)** — 80% gate **closed**. Class-1 PHY N=1/2/4/8 **375/416/448/453 cy**. Class-1 GEMM N=1/2/4/8 **336/681/821/1162 cy** (MaxAROut=8). Testharness CLASS1 slave (`dram_backend`) N=1/2 **336/681 cy**. DTS↔CAP `0x38` **PASS** (live 1 ch / shift 6; one `memory@`). Nameplate guard **PASS** (refuse 400 on class 0/1). Variane S4 **`ai-dt` PASS:** `cva6-build test --ai-remote` after rebuild with `g6lc_axi_atomics_wrap` → `tohost=1` after **2899 cycles** (was 2681 on pulp 1-OT). Live `ai-dt` **vthreads=12** jobs=1 **1395 s** **40.7 Mi** (was 37.8 Mi / 1 thread); exclusive **PASS 552 cy**. Dual-core snoop wall **4890 s** ≈ 1-thread **4875 s**. Live `ai-d1` **vthreads=12** jobs=1 **1334 s** **41.7 Mi**; exclusive still **PASS 781 cy**. Live `ai-d2` **vthreads=12** **42.9 Mi**; exclusive **PASS 945 cy**. Live `ai-d4` **vthreads=12** **47.4 Mi**; exclusive **PASS 941 cy**. Live `ai-d8` **49.1 Mi** vthreads=12. CLASS1 ELF preload is LiteDRAM native (cluster held; no `gen_sim_axi.i_sram`). Variane **`ai-d1` PASS:** `S4_FLAVOUR=ai-d1` → `tohost=1` after **5363 cycles** (preload 20 native words, drain t=177). Variane **`ai-d2` PASS:** N=2 LiteDRAM stripe → `tohost=1` after **5758 cycles** (preload drain t=150). Variane **`ai-d4` PASS:** N=4 → `tohost=1` after **5762 cycles**. Variane **`ai-d8` PASS:** N=8 → `tohost=1` after **5821 cycles**. CLASS1 channel ladder {1,2,4,8} closed. S4 parks hart 1: **`ai-dt` 2620 cy** (was 2899), **`ai-d1` 4246**, **`ai-d2` 4520**, **`ai-d4` 4553**, **`ai-d8` 4582**. Dual-core stripe+occupancy **830/900/582 cy** on `ai-d2`/`ai-d8`/`ai-sc{2,4,8}`. All-N occupancy **1328/889 cy** on `ai-d8`/`ai-sc8` (CAP `0x38` N, `0x70+4*i` all nonzero). Exclusive **PASS** `ai-dt` **552** / CLASS1 `ai-d1` **781** / `ai-d2` **945** / `ai-d4` **941** / `ai-d8` **941 cy** / class-0 stripe **`ai-sc2` 620** / **`ai-sc4` 620 cy**. CLASS1 exclusive {1,2,4,8} closed. SIM_CHANS uses `g6lc_axi_atomics_wrap` + wrap AW=8 (`DRAM_EXCL_AW`); cookie pulp `dram_aw_out` stays 1. Dual-core snoop **PASS `ai-dt` 16667 cy** / CLASS1 **`ai-d1` 17137** / **`ai-d2` 17137** / **`ai-d4` 17163** / **`ai-d8` 17187 cy** / class-0 stripe **`ai-sc2` 16686** / **`ai-sc4` 16686 cy** (`H1_DELAY=4000`). CLASS1 snoop {1,2,4,8} closed. Isolated lrsc **130 cy**; wrap-stack **104 cy**. Same-hart store-between-LR/SC is wrap-TB only. Class-0 SRAM **`ai-sc{2,4,8}` PASS 582 cy** dual-core (striped `gen_sim_stripe` preload; `MaxAROut=2` so not S4). OpenSBI soak stays on the class-0 cookie path. Not 400.

Live geometry (`RTL_FEEDBACK.md` §3.1): 512 MAC/cycle × 2 GHz nameplate = **2.048 TOPS**, DRAM nameplate **16 GB/s** on the same 64-bit port. Throughput SKU
plan is 8 clusters × 4096 MAC/cycle @ 1.5 GHz ≈ **98.3 TOPS**. The 48× gap is MAC count × clock,
not a QEMU measurement. VA-turbo does not multiply the 512-MAC rate.
Exact reuse is a parallel track on `AiCfgVaTurboTest` (`va-turbo.md`,
Completion path): the live `ai_cfg` stays off, the host test schedule is
the 8-MAC 1024×512×16 tile, and a requested level at `0x0F04` is stored
with applied level 0. Live promotion still waits on a measured error bound
before any `va_turbo_level` changes a product. The host paths that share
that schedule are recorded in `ai-matrix/log-2026-09.md`.

---

## 4. Broader SoC next (not on the island critical path)

| Track | Next concrete | Must not |
|---|---|---|
| SMT2 | SL-C FDT/`cpu-map` honesty; R3b Image; keep cookie green. Cookie soak is the SMT **control**, not a candidate-on RR pairing | Treat QEMU `smp: 2 CPUs` as Variane SUCCESS; merge with stream8 |
| QEMU | Soc Shell file-path; 32 MiB pflash for E4; `results --tops` from `g6q-diag` | Cite virt as tape-out evidence; invent AI PCI IDs |
| OoO | Keep `OoOEn` gated; dual-issue SMT product closeout is U6.1 not U5; restore reliable T=1 two-wide issue before I=4 | Turn on full OoO in the router low-power SKU; claim 4-wide retirement from `ooo_server` knobs |
| Multi-core | `NrCores` scale per envelope; PLIC `S≤8`. DRAM channels stay a **slave** knob — raising N cores does not raise `DramChannels` (`uncore/dram-channel-scaling.md`). Stream8 AMOCAS minis are the cluster **control** | `NrHarts>2` until `CVA6_MAX_SMT_HARTS` + contexts; do not infer channel count from core count; promote L2 RR from leaf diagnostics |
| Hypervisor | KVM stress on server_math | Block 100 TOPS on KVM |
| Stream | Keep `g6lc64_stream8` separate | Merge with smt2 DI |
| RVV | `ara-vector-cosim` when `_v` TB + Image | Grow core tile 8×8×8 with island TOPS |
| Graphics | The ceiling is read back. The scene header and the 960-byte execbuffer are fetched. The DRAW_VBO at byte 908 is recognized and not executed. Its 24 NDC floats are read and not transformed. The viewport and the scissor are both the 640 by 480 rectangle. The clear color is `32'hFF1A0D0D` on one color buffer, surface 1. The vertex buffer is stride 24, offset 0, resource 3, from an inline write of 96 bytes. The sampler view at byte 632 names fragment slot 0 and handle 5. The sampler state at byte 616 names fragment slot 0 and handle 6. The vertex-element bind at byte 608 names handle 4. The fragment shader at byte 596 names handle 3. The vertex shader at byte 584 names handle 2. The rasterizer bind at byte 576 names handle 9. The depth-stencil bind at byte 568 names handle 8. The blend bind at byte 560 names handle 7. The rasterizer object at byte 520 names handle 9. Its eight state words are 0. The depth-stencil object at byte 496 names handle 8. Its four state words are 0. The blend object at byte 448 names handle 7 and color word `32'h78020010`. The sampler-state object at byte 408 names handle 6, wrap word `32'h00002292`, and max LOD `32'h42000000`. The sampler view at byte 380 names handle 5, resource 1, format `32'h02000002`, and swizzle `32'h00000688`. The vertex-element object at byte 340 names handle 4, with format 31 at offset 0 and format 29 at offset 16. The fragment-shader object at byte 176 names handle 3. The vertex-shader object at byte 24 names handle 2. The surface object at byte 0 names handle 1, resource 4, and format 2. Guest descriptors at `64'h8800E100` link the header, the 960-byte execbuffer, and the 24-byte response. Avail index 1 at `64'h8800E200` names descriptor 0 (`tb_g6lc_apu_vgpu_nxc`, 16/71/109). The completed-opcode list at `64'h8800E300` is count 0 and capset id 0 (`tb_g6lc_apu_vgpu_ols`, 13/59/71). The virgl capset stays refused. A 64 by 64 guest window at `64'h88020000` is 512 beats of clear word `32'hFF1A0D0D` (`tb_g6lc_apu_vgpu_gpw`, 16/73/1112). The guest response at `64'h8800A800` is `OK_NODATA` with fence `64'h1122334455667788`. The used element at `64'h8800E400` is descriptor 0 and length 24. The used index at `64'h8800E480` is 1 (`tb_g6lc_apu_vgpu_gcw`, 22/96/127). The used-buffer interrupt reason at `64'h8800E500` is `32'h1`. Ack lowers the pin (`tb_g6lc_apu_vgpu_viw`, 20/89/102). The guest ack at `64'h8800E510` is `32'h1`, and the status word at `64'h8800E500` is then `32'h0` (`tb_g6lc_apu_vgpu_vaw`, 22/96/122). All 512 beats of the window are that clear word (`tb_g6lc_apu_vgpu_wfr`, 21/86/2149). That window is copied to `64'h88030000` (`tb_g6lc_apu_vgpu_gbw`, 19/84/2153), a 64 by 64 rectangle of 16384 bytes (`tb_g6lc_apu_vgpu_gbd`, 18/78/91). `(1,0)` is byte 4 and row 1 starts at byte 256 (`tb_g6lc_apu_vgpu_gof`, 19/85/101). The clear word sits in memory as the bytes 0D 0D 1A FF, so byte 0 is red (`tb_g6lc_apu_vgpu_byr`, 17/71/86). Row 1 at `64'h88030100` starts with that same red byte (`tb_g6lc_apu_vgpu_ryr`, 22/91/107). `(1,1)` is byte 260, `(2,3)` is byte 776, and `(0,63)` is byte 16128 (`tb_g6lc_apu_vgpu_tpr`, 23/95/124). `(63,0)` is byte 252 at `64'h880300E0` (`tb_g6lc_apu_vgpu_x6r`, 21/87/103). `(7,0)` is byte 28, lane 7 of `64'h88030000` (`tb_g6lc_apu_vgpu_p7r`, 21/87/103). `(8,0)` is byte 32 and `(15,0)` is byte 60, both in `64'h88030020` (`tb_g6lc_apu_vgpu_b1r`, 21/87/103). `(56,0)` is byte 224, lane 0 of `64'h880300E0`, and `(63,0)` stays byte 252, lane 7 of that beat (`tb_g6lc_apu_vgpu_b7r`, 21/87/103). `(16,0)` is byte 64 and `(23,0)` is byte 92, both in `64'h88030040` (`tb_g6lc_apu_vgpu_b2r`, 21/87/103). `(24,0)` is byte 96 and `(31,0)` is byte 124, both in `64'h88030060` (`tb_g6lc_apu_vgpu_b3r`, 21/87/103). `(32,0)` is byte 128 and `(39,0)` is byte 156, both in `64'h88030080` (`tb_g6lc_apu_vgpu_b4r`, 21/87/103). `(40,0)` is byte 160 and `(47,0)` is byte 188, both in `64'h880300A0` (`tb_g6lc_apu_vgpu_b5r`, 21/87/103). `(48,0)` is byte 192 and `(55,0)` is byte 220, both in `64'h880300C0` (`tb_g6lc_apu_vgpu_b6r`, 21/87/103). `(63,63)` is byte 16380, lane 7 of `64'h88033FE0` (`tb_g6lc_apu_vgpu_tcr`, 22/91/107). The linear sample pair is written as fragment color at `64'h88050000` (`tb_g6lc_apu_vgpu_acw`, 25/109/125). `(0,0)` is the clamp texel `32'hA5000000`. `(1,0)` is the half blend `32'hD2008000`. Those 512 ceiling sample beats are copied to `64'h88060000` (`tb_g6lc_apu_vgpu_csw`, 24/105/2172). That window is a 64 by 64 rectangle (`tb_g6lc_apu_vgpu_crd`, 22/90/104). `(1,0)` in it is the half blend `32'hD2008000`. `(0,0)` is the clamp texel `32'hA5000000` (`tb_g6lc_apu_vgpu_cof`, 21/89/103). That rectangle is copied to `64'h88070000` as `TRANSFER_FROM_HOST_3D` of resource 4 (`tb_g6lc_apu_vgpu_rpw`, 24/105/2172). That guest buffer is a 64 by 64 rectangle (`tb_g6lc_apu_vgpu_grd`, 23/93/108). Offset in that guest rectangle is `y * 256 + x * 4` (`tb_g6lc_apu_vgpu_rof`, 21/89/103). `(0,0)` is the clamp texel `32'hA5000000`. The `TRANSFER_FROM_HOST_3D` box is `(0,0,64,64)` of resource 4 at 640 by 480 (`tb_g6lc_apu_vgpu_tfb`, 20/79/117). Packed stride is 256. `RESOURCE_ATTACH_BACKING` of that buffer is length 16384 (`tb_g6lc_apu_vgpu_rab`, 19/76/107). The 24-byte virtio `OK_NODATA` of that transfer is at `64'h880A0000` with fence 2 (`tb_g6lc_apu_vgpu_rfw`, 15/68/88). The used element is at `64'h880B0000` with id 1 and `used.idx` 2 (`tb_g6lc_apu_vgpu_tuw`, 16/72/105). The used-buffer interrupt reason `32'h1` is at `64'h880C0000` (`tb_g6lc_apu_vgpu_tiw`, 15/70/86). The guest ack of that interrupt is at `64'h880C0010` (`tb_g6lc_apu_vgpu_taw`, 23/101/130). The guest descriptor chain of that transfer is at `64'h880D0000` (`tb_g6lc_apu_vgpu_txc`, 23/98/144). TEX of sampler view 5 at `(0,0)` is `32'hA5000000` (`tb_g6lc_apu_vgpu_ftx`, 19/79/83). Beat 0 of the scene window at `64'h88020000` is that pair (`tb_g6lc_apu_vgpu_ocw`, 23/103/120). Beat 0 of the guest readback at `64'h88030000` is that pair (`tb_g6lc_apu_vgpu_pbw`, 23/103/120). A posted walker accepts `NEXT` for that transfer chain at avail index 2 (`tb_g6lc_apu_vgpu_tnw`, 29/105/123). Guest QueueNotify of control queue 0 is at `64'h880D0200` (`tb_g6lc_apu_vgpu_qnt`, 17/77/93). Guest `virtq_avail.idx` after that notify is 2 at `64'h880D0100` (`tb_g6lc_apu_vgpu_qav`, 17/74/87). Guest `virtq_avail.ring[0]` names descriptor 0 at `64'h880D0104` (`tb_g6lc_apu_vgpu_qrg`, 16/70/83). Guest `virtq_desc` 0 is the attach at `64'h88090000` with `NEXT` to 1 (`tb_g6lc_apu_vgpu_qhd`, 17/74/90). Guest `virtq_desc` 1 is the transfer at `64'h88080000` with `NEXT` to 2 (`tb_g6lc_apu_vgpu_qfd`, 17/74/90). Guest `virtq_desc` 2 is the `WRITE` of the 24-byte response at `64'h880A0000` (`tb_g6lc_apu_vgpu_qwd`, 17/74/90). Guest `OK_NODATA` after that `WRITE` is fence 2 at `64'h880A0000` (`tb_g6lc_apu_vgpu_qok`, 17/76/96). Guest used element after that `OK_NODATA` is id 1 / `used.idx` 2 (`tb_g6lc_apu_vgpu_quw`, 18/80/113). Guest used-buffer interrupt after that index is reason `32'h1` at `64'h880C0000` (`tb_g6lc_apu_vgpu_qiw`, 15/70/86). Guest ack of that interrupt is `32'h1` at `64'h880C0010` (`tb_g6lc_apu_vgpu_qaw`, 23/101/130). Scene `virtq_avail.idx` after that ack is 1 at `64'h8800E200` (`tb_g6lc_apu_vgpu_qsv`, 17/74/87). Scene `virtq_avail.ring[0]` names descriptor 0 at `64'h8800E204` (`tb_g6lc_apu_vgpu_qsr`, 16/70/83). Scene `virtq_desc` 0 is the 32-byte header at `64'h8800A000` with `NEXT` to 1 (`tb_g6lc_apu_vgpu_qsd`, 17/74/90). Scene `virtq_desc` 1 is the 960-byte execbuffer at `64'h8800B000` with `NEXT` to 2 (`tb_g6lc_apu_vgpu_qed`, 17/74/90). Scene `virtq_desc` 2 is the `WRITE` of the 24-byte response at `64'h8800A800` (`tb_g6lc_apu_vgpu_qrs`, 17/74/90). Scene `OK_NODATA` after that `WRITE` is the scene fence at `64'h8800A800` (`tb_g6lc_apu_vgpu_qso`, 17/76/96). Scene used element after that `OK_NODATA` is id 0 / `used.idx` 1 (`tb_g6lc_apu_vgpu_qsu`, 18/80/113). Scene used-buffer interrupt after that index is reason `32'h1` at `64'h8800E500` (`tb_g6lc_apu_vgpu_qsi`, 15/70/86). Scene guest ack of that interrupt is `32'h1` at `64'h8800E510` (`tb_g6lc_apu_vgpu_qga`, 23/101/130). A posted walker accepts `NEXT` for the scene submit chain at avail index 1 (`tb_g6lc_apu_vgpu_snw`, 29/105/123). Scene QueueNotify of control queue 0 is at `64'h8800E220` (`tb_g6lc_apu_vgpu_snt`, 17/77/93). Scene `virtq_avail.idx` after that notify is 1 at `64'h8800E200` (`tb_g6lc_apu_vgpu_sav`, 17/74/87). Scene `virtq_avail.ring[0]` names descriptor 0 at `64'h8800E204` (`tb_g6lc_apu_vgpu_srg`, 16/70/83). Scene `virtq_desc` 0 is the header at `64'h8800A000` with `NEXT` to 1 (`tb_g6lc_apu_vgpu_shd`, 17/74/90). Scene `virtq_desc` 1 is the execbuffer at `64'h8800B000` with `NEXT` to 2 (`tb_g6lc_apu_vgpu_sfd`, 17/74/90). Scene `virtq_desc` 2 is the `WRITE` of the 24-byte response at `64'h8800A800` (`tb_g6lc_apu_vgpu_swd`, 17/74/90). Scene `OK_NODATA` after that `WRITE` is the scene fence at `64'h8800A800` (`tb_g6lc_apu_vgpu_sok`, 17/76/96). Scene used element after that `OK_NODATA` is id 0 / `used.idx` 1 (`tb_g6lc_apu_vgpu_slw`, 18/80/113). Scene used-buffer interrupt after that index is reason `32'h1` at `64'h8800E500` (`tb_g6lc_apu_vgpu_siw`, 15/70/86). Scene guest ack of that interrupt is `32'h1` at `64'h8800E510` (`tb_g6lc_apu_vgpu_sga`, 23/101/130). A posted walker accepts `NEXT` for the transfer chain at avail index 2 after that ack (`tb_g6lc_apu_vgpu_rnw`, 29/105/123). QueueNotify of control queue 0 is at `64'h880D0200` after that walker (`tb_g6lc_apu_vgpu_rnt`, 17/77/93). `virtq_avail.idx` after that notify is 2 at `64'h880D0100` (`tb_g6lc_apu_vgpu_rav`, 17/74/87). `virtq_avail.ring[0]` names descriptor 0 at `64'h880D0104` (`tb_g6lc_apu_vgpu_rrg`, 16/70/83). `virtq_desc` 0 is the attach at `64'h88090000` with `NEXT` to 1 (`tb_g6lc_apu_vgpu_rhd`, 17/74/90). `virtq_desc` 1 is the transfer at `64'h88080000` with `NEXT` to 2 (`tb_g6lc_apu_vgpu_rfd`, 17/74/90). `virtq_desc` 2 is the `WRITE` of the 24-byte response at `64'h880A0000` (`tb_g6lc_apu_vgpu_rwd`, 17/74/90). Guest `OK_NODATA` after that `WRITE` is fence 2 at `64'h880A0000` (`tb_g6lc_apu_vgpu_rok`, 17/76/96). Guest used element after that `OK_NODATA` is id 1 / `used.idx` 2 (`tb_g6lc_apu_vgpu_ruw`, 18/80/113). Guest used-buffer interrupt after that index is reason `32'h1` at `64'h880C0000` (`tb_g6lc_apu_vgpu_riw`, 15/70/86). Guest ack of that interrupt is `32'h1` at `64'h880C0010` (`tb_g6lc_apu_vgpu_rga`, 23/101/130). TEX of sampler view 5 after that ack is clamp `32'hA5000000` / half blend `32'hD2008000` with `refused` 0 (`tb_g6lc_apu_vgpu_gtx`, 18/75/79). Beat 0 of the guest transfer buffer at `64'h88070000` after that ack is that TEX pair (`tb_g6lc_apu_vgpu_hcw`, 23/103/120). Covered samples `(0,0)` / `(1,0)` of that pair are clamp / half blend with `refused` 0 (`tb_g6lc_apu_vgpu_wld`, 17/71/75). Those words are the bytes 00 00 00 A5 and 00 80 00 D2, byte 0 red (`tb_g6lc_apu_vgpu_cyr`, 15/63/67). After QueueNotify of control queue 0, a guest-rung walk of the scene NEXT chain consumes device index 1 (`tb_g6lc_apu_vgpu_gnw`, 26/107/155). After that walk the scene header and execbuffer are fetched (`tb_g6lc_apu_vgpu_gef`, 20/81/161). The shader is not run. Neither shader is run. No framebuffer is painted. No blend is applied. No depth test is run. No triangle is walked. The shader is not run. No vertices are fetched. No texture is bound (`uncore/apu-graphics.md`). Open: the screenshot, `g6lc_apu_vgpu_avail` still rejects `NEXT`, a real scene texture | Treat the fetch, a private decoder, a QEMU frame, or the lab PPM as A5; publish `FeatureVirgl`; couple the device to `MatrixEn` or the HDMI PHY |

---

## 5. Open first

| Need | Path |
|---|---|
| This snapshot | this file |
| U1–U10 plan | `router-core-upgrade-program.md` · `remaining-upgrade-sequence.md` |
| SMT2 / ladder | `multi-threading/README.md` · `smt2-bringup.md` · `soft-ladder/` |
| QEMU stages | `g6lc-qemu/README.md` · `g6lc-qemu/staging.md` · `g6lc_qemu/AGENTS-todo.md` |
| 100 TOPS sizing | `ai-matrix/scaling-100tops.md` · `ai-matrix/hard-tests.md` · `uncore/dram-channel-scaling.md` |
| Design asks | `g6lc_qemu/architecture/RTL_FEEDBACK.md` |
| PCIe roles | `uncore/pcie-endpoint.md` · `uncore/pcie-root-complex.md` |
| Graphics lane | `uncore/apu-graphics.md` · `uncore/README.md` · `g6lc_bios/architecture/DISPLAY.md` |
| Queue | `AGENTS-todo.md` Current phase |
