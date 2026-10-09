# APU implementation interplays

**Lens:** arborescence of module handoffs, written with PascalCase pseudo-names.
**Status:** living heuristic map of `corev_apu/apu`. Refresh it when a leaf, grant bit, or SoC instantiate changes.
**Law:** `AGENTS.md` §0, `AGENTS-corev-apu.md`, `architecture/uncore/apu-graphics.md`. This file does not grant `FeatureVirgl`, wire private leaves into `g6lc_apu_sys`, or close gate A5.

Aliases live on `apu_cfg_t` (`g6lc_apu_cfg_pkg.sv`), on `apu_vgpu_*_t` / status / completion types (`g6lc_apu_pkg.sv`), and above each `module g6lc_apu_vgpu_*`. This page is the *call graph* of those names.

---

## 0. How to read

RTL has no software `call()`. A “function call” here is one of:

| Glyph | Meaning in this tree |
|---|---|
| `A --> B` | `A` **instantiates** `B` (structural child). |
| `A <-> B` | `B` takes `A`’s record as a port (`apu_vgpu_a_t a_i`) and handshake (`req_valid` / `cpl_valid`). Ready/valid is the call/return. |
| `A ==> B` | AXI, mailbox, or virtio beat: address+data, not a typed predecessor record. |
| `A --? B` | Beside, not a child: same story, separate module, **not** instantiated together. |

A private leaf is written `PseudoName (id)` and maps to `g6lc_apu_vgpu_id` (or `g6lc_apu_cover` / `g6lc_apu_frag` / `g6lc_apu_rsurf` / `g6lc_apu_exec` / `g6lc_apu_spirv` / `g6lc_apu_chain` / `g6lc_apu_cdma` / `g6lc_apu_hvis` / `g6lc_apu_vncs` / `g6lc_apu_vcap` / `g6lc_apu_vnring` / `g6lc_apu_tdma` / `g6lc_apu_vnenc` / `g6lc_apu_vnp` / `g6lc_apu_avn` / `g6lc_apu_avu` / `g6lc_apu_uir` / `g6lc_apu_cms` / `g6lc_apu_prs` / `g6lc_apu_qdn` / `g6lc_apu_gcs` / `g6lc_apu_vnd` / `g6lc_apu_gnh` / `g6lc_apu_hdp` / `g6lc_apu_hph` / `g6lc_apu_hrn` / `g6lc_apu_rdn` / `g6lc_apu_qrn` / `g6lc_apu_qcm` / `g6lc_apu_qty` / `g6lc_apu_vct` / `g6lc_apu_qpu` / `g6lc_apu_ntk` / `g6lc_apu_vqt` / `g6lc_apu_vax` / `g6lc_apu_vac` / `g6lc_apu_hal` / `g6lc_apu_aru` / `g6lc_apu_qal` / `g6lc_apu_qta` / `g6lc_apu_vca` / `g6lc_apu_qpa` / `g6lc_apu_nta` / `g6lc_apu_vqa` / `g6lc_apu_vaa` / `g6lc_apu_vbg` / `g6lc_apu_bal` / `g6lc_apu_bru` / `g6lc_apu_qbn` / `g6lc_apu_qtb` / `g6lc_apu_vcb` / `g6lc_apu_qpb` / `g6lc_apu_ntb` / `g6lc_apu_vqb` / `g6lc_apu_vab` / `g6lc_apu_ven` / `g6lc_apu_eal` / `g6lc_apu_vxv` / `g6lc_apu_vsm` / `g6lc_apu_vrp` / `g6lc_apu_vgp` / `g6lc_apu_vfb` / `g6lc_apu_vrb` / `g6lc_apu_vdw` / `g6lc_apu_vre` / `g6lc_apu_vvb` / `g6lc_apu_vib` / `g6lc_apu_vdi` / `g6lc_apu_vvp` / `g6lc_apu_vsi` / `g6lc_apu_vpb` / `g6lc_apu_vns` / `g6lc_apu_vdf` / `g6lc_apu_vdx` / `g6lc_apu_vdk` / `g6lc_apu_vdr` / `g6lc_apu_vdb` / `g6lc_apu_vdg` / `g6lc_apu_vfe` / `g6lc_apu_vdm` / `g6lc_apu_vdp` / `g6lc_apu_vdy` / `g6lc_apu_vdt` / `g6lc_apu_vdq` / `g6lc_apu_vfs` / `g6lc_apu_vrc` / `g6lc_apu_vfc` / `g6lc_apu_vdd` / `g6lc_apu_vpc` / `g6lc_apu_vdc` / `g6lc_apu_vdn` / `g6lc_apu_vgf` / `g6lc_apu_vip` / `g6lc_apu_vxe` / `g6lc_apu_vrd` / `g6lc_apu_vie` / `g6lc_apu_vwl` / `g6lc_apu_vsl` / `g6lc_apu_vrg` / `g6lc_apu_vlw` / `g6lc_apu_vzb` / `g6lc_apu_vbc` / `g6lc_apu_vbo` / `g6lc_apu_vcm` / `g6lc_apu_vwm` / `g6lc_apu_vrf` / `g6lc_apu_vcc` / `g6lc_apu_vcy` / `g6lc_apu_vbl` / `g6lc_apu_vbt` / `g6lc_apu_vic` / `g6lc_apu_vub` / `g6lc_apu_vfl` / `g6lc_apu_vcl` / `g6lc_apu_vio` / `g6lc_apu_vix` / `g6lc_apu_vds` / `g6lc_apu_vat` / `g6lc_apu_vin` / `g6lc_apu_vrs` / `g6lc_apu_vgs` / `g6lc_apu_vwf` / `g6lc_apu_vfr` / `g6lc_apu_vfn`). The ready/valid call looks like:

```text
GuestNextWalk (gnw)(sny)
    ==> guest beats at NXC_DESC / NXC_LAST / NXC_AVAIL
    <-> GuestNextKeep (gnk)(gnw, sny)
        <-> GuestNextCheck (gnx)(gnk, gnw, sny)
```

Identity fan-in (a later reader that restates `fet`, `cxr`, `qdr`, …) is a **legalize check**, not a new data edge. The trees below keep the primary predecessor. Extra ports are listed only when they change the story.

---

## 1. Heuristics for keeping this file true

Apply these when adding or renaming a leaf. They are ordered by how much stale-map cost each one removes.

| Id | Heuristic | Do this |
|---|---|---|
| **H0** | Glyphs before graph | `-->` instantiate, `<->` record handshake, `==>` beat, `--?` beside. Section 0 is part of this set. |
| **H1** | Alias before graph | A new `XxxEn` gets `PseudoName (id):` on the grant bit, the `apu_vgpu_xxx_t` trio, and the module line *before* it is drawn here. |
| **H2** | One primary predecessor | The first suite-local `*_i` record is the `<->` parent. Census ports (`fet_i`, `cxr_i`, `qdr_i`, …) stay identity unless they *are* the story. |
| **H3** | Trio is one node | Actor / Keep / Check (`w`/`r`, `k`, `x`/`y`) collapse to one bullet in the tree; expand only when a reader needs the keep/check split. |
| **H4** | Plane split is structural | SoC box (`-->`) never grows a `g6lc_apu_vgpu_*` child until `g6lc_apu_sys` is *meant* to instantiate it. Private leaves stay `--?` the SoC. |
| **H5** | Named path is one spine | The guest-rung G0 story is section 5. A new virtqueue clone extends that spine or starts a labeled fork. It does not silently duplicate an older `q*` / `s*` / `r*` row. |
| **H6** | Beats name addresses | A walker/reader that issues `rd_*` / `wr_*` documents the stand-in address in the same bullet (`==>`). |
| **H7** | Open gates stay visible | `AvailDescriptor (avail)` still faults `NEXT`. Compiler `TEX` still returns `-26`. `FeatureVirgl` stays illegal. HDMI and `ai_island` stay other devices. |

A leaf that only names another texel of the clear word does not get a new tree; it hangs under the existing readback census.

---

## 2. Two planes (the root split)

> **Frozen 2026-10-05 (commits 133327577 / 755776ae0).** The `g6lc_apu_vgpu_*` /
> `bru`/`qbn`/`qtb` forest below is diagnostic/vector material; it is not
> instantiated and will not grow. The live engine arborescence is §16.

```text
guest Mesa / BIOS virtio-gpu
    ==> gpu@0x40001000  PLIC 9     control@0x40002000     fwram@0x90000000
            |
            v
     TestharnessAttach (g6lc_apu_attach) --? ai_island@0x40000000 PLIC 8
            |
            --> TrustedGrant (g6lc_apu_grant)
            --> ApuSys (g6lc_apu_sys)          [ApuOff: no vgpu_* children]
                    |
                    +-- private g6lc_apu_vgpu_* leaves
                            elaborated only by their own TBs
                            --? ApuSys   (not instantiated)
                    +-- SpirvSubset (spirv)
                            --? ApuSys   (not instantiated)
                    +-- NextChain (chain)
                            --? AvailDescriptor (avail)
                            --? GuestNextWalk (gnw)
                            --? ApuSys   (not instantiated)
                    +-- ChainDma (cdma)
                            --> NextChain (chain)
                            --> DmaRead ==> AXI
                            --? ApuSys   (not instantiated)
                    +-- HostVisible (hvis)
                            --? HostVisibleShm (shm)   virtio-mmio SHM id 1
                            --? ApuSys   (not instantiated)
                    +-- VenusCs (vncs)
                            --> SpirvSubset (spirv)
                            --? HostVisible (hvis)
                            --? ApuSys   (not instantiated)
                    +-- VenusCapset (vcap)
                            --? CapsetGet (cap)        virgl id 1 still refused
                            --? ApuSys   (not instantiated)
                    +-- VenusRing (vnring)
                            --? VenusCs (vncs)         diagnostic CS
                            --? ApuSys   (not instantiated)
                    +-- TestharnessDma (tdma)
                            --? ApuSys   (not instantiated)
                            ==> testharness xbar slave[2] under G6LC_APU
                    +-- VenusEncode (vnenc)
                            --? VenusRing (vnring)
                            --? VenusCs (vncs)         diagnostic CREATE/DISPATCH
                            --? ApuSys   (not instantiated)
                    +-- VenusPath (vnp)
                            --> VenusEncode (vnenc)
                            --> SpirvSubset (spirv)
                            --? VenusRing (vnring)
                            --? ApuSys   (not instantiated)
                    +-- AvailNext (avn)
                            --> NextChain (chain)
                            --? AvailDescriptor (avail)
                            --? ApuSys   (not instantiated)
                    +-- AvailUsed (avu)
                            --> AvailNext (avn)
                            ==> virtq_used elem then idx
                            --? ApuSys   (not instantiated)
                    +-- UsedIrq (uir)
                            --> AvailUsed (avu)
                            ==> ISR bit 0
                            --? ApuSys   (not instantiated)
                    +-- CmdSnap (cms)
                            --> AvailNext (avn)
                            ==> first payload SRAM
                            --? ApuSys   (not instantiated)
                    +-- PayResp (prs)
                            --> AvailNext (avn)
                            ==> WRITE payload
                            --? ApuSys   (not instantiated)
                    +-- QueueDone (qdn)
                            --> AvailNext (avn)
                            ==> WRITE then used then ISR
                            --? ApuSys   (not instantiated)
                    +-- GrantCapset (gcs)
                            --> AvailNext (avn)
                            --> VenusCapset (vcap)
                            ==> WRITE capset then used then ISR
                            --? ApuSys   (not instantiated)
                    +-- VenusDispatch (vnd)
                            --? VenusEncode (vnenc)
                            --? VenusPath (vnp)
                            --? ApuSys   (not instantiated)
                    +-- GenHandle (gnh)
                            --? HostVisible (hvis)
                            --? VenusPath (vnp)
                            --? ApuSys   (not instantiated)
                    +-- VenusAlloc (vac)
                            --> GenHandle (gnh)
                            --? VenusDispatch (vnd)
                            --? ApuSys   (not instantiated)
                    +-- HandleAlloc (hal)
                            --> GenHandle (gnh)
                            --> VenusDispatch (vnd)
                            --? VenusAlloc (vac)
                            --? ApuSys   (not instantiated)
                    +-- AllocRun (aru)
                            --> VenusEncode (vnenc)
                            --> GenHandle (gnh)
                            --> VenusDispatch (vnd)
                            --> SpirvSubset (spirv)
                            --? HandleAlloc (hal)
                            --? ApuSys   (not instantiated)
                    +-- HandleDispatch (hdp)
                            --> GenHandle (gnh)
                            --> VenusDispatch (vnd)
                            --? ApuSys   (not instantiated)
                    +-- HandlePath (hph)
                            --> VenusEncode (vnenc)
                            --> GenHandle (gnh)
                            --> VenusDispatch (vnd)
                            --? ApuSys   (not instantiated)
                    +-- HandleRun (hrn)
                            --> VenusEncode (vnenc)
                            --> GenHandle (gnh)
                            --> VenusDispatch (vnd)
                            --> SpirvSubset (spirv)
                            --? ApuSys   (not instantiated)
                    +-- RunDone (rdn)
                            --> HandleRun (hrn)
                            ==> WRITE result then used then ISR
                            --? ApuSys   (not instantiated)
                    +-- QueueRun (qrn)
                            --> AvailNext (avn)
                            --> RunDone (rdn)
                            ==> first payload CS then WRITE/used/ISR
                            --? ApuSys   (not instantiated)
                    +-- QueueAlloc (qal)
                            --> AvailNext (avn)
                            --> AllocRun (aru)
                            ==> first payload CS then WRITE/used/ISR
                            --? QueueRun (qrn)
                            --? ApuSys   (not instantiated)
                    +-- QueueTypeAlloc (qta)
                            --> AvailNext (avn)
                            --> GrantCapset (gcs)
                            --> QueueAlloc (qal)
                            --? QueueType (qty)
                            --? ApuSys   (not instantiated)
                    +-- VenusCtrlAlloc (vca)
                            --> VenusCapset (vcap)
                            --> QueueTypeAlloc (qta)
                            --? VenusCtrl (vct)
                            --? ApuSys   (not instantiated)
                    +-- QueuePumpAlloc (qpa)
                            --> VenusCtrlAlloc (vca)
                            --? QueuePump (qpu)
                            --? ApuSys   (not instantiated)
                    +-- NotifyTakeAlloc (nta)
                            --> QueuePumpAlloc (qpa)
                            --? NotifyTake (ntk)
                            --? ApuSys   (not instantiated)
                    +-- VqTakeAlloc (vqa)
                            --> NotifyTakeAlloc (nta)
                            --? VqTake (vqt)
                            --? ApuSys   (not instantiated)
                    +-- VqAxiAlloc (vaa)
                            --> VqTakeAlloc (vqa)
                            ==> AXI SIZE=2 (4B) / SIZE=3 INCR
                            --? VqAxi (vax)
                            --? TestharnessDma (tdma)
                            --? ApuSys   (not instantiated)
                    +-- VenusBegin (vbg)
                            --? VenusAlloc (vac)
                            --? VenusDispatch (vnd)
                            --? ApuSys   (not instantiated)
                    +-- BeginAlloc (bal)
                            --> GenHandle (gnh)
                            --> VenusBegin (vbg)
                            --? VenusAlloc (vac)
                            --? ApuSys   (not instantiated)
                    +-- BeginRun (bru)
                            --> VenusCreateInstance (vci)
                            --> VenusEnumeratePhys (vep)
                            --> VenusPhysFeatures (vpf)
                            --> VenusPhysProps (vpp)
                            --> VenusPhysMemory (vmp)
                            --> VenusAllocMemory (vam)
                            --> VenusCreateBuffer (vxb)
                            --> VenusBindBuffer (vbb)
                            --> VenusMapMemory (vmm)
                            --> VenusUnmapMemory (vum)
                            --> VenusBufReq (vbm)
                            --> VenusFlushMap (vfm)
                            --> VenusInvalidateMap (vim)
                            --> VenusMemCommit (vmc)
                            --> VenusDescLayout (vdl)
                            --> VenusPipeLayout (vpl)
                            --> VenusComputePipe (vcp)
                            --> VenusDescAlloc (vda)
                            --> VenusUpdateDesc (vud)
                            --> VenusBindPipe (vbp)
                            --> VenusBindDesc (vbd)
                            --> VenusDescPool (vpo)
                            --> VenusCreateImage (vxi)
                            --> VenusBindImage (vbi)
                            --> VenusImageReq (vmi)
                            --> VenusImageView (vxv)
                            --> VenusSampler (vsm)
                            --> VenusRenderPass (vrp)
                            --> VenusGraphicsPipe (vgp)
                            --> VenusFramebuffer (vfb)
                            --> VenusRenderBegin (vrb)
                            --> VenusDraw (vdw)
                            --> VenusRenderEnd (vre)
                            --> VenusBindVtx (vvb)
                            --> VenusBindIdx (vib)
                            --> VenusDrawIdx (vdi)
                            --> VenusSetViewport (vvp)
                            --> VenusSetScissor (vsi)
                            --> VenusBarrier (vpb)
                            --> VenusNextSubpass (vns)
                            --> VenusDestroyFbuf (vdf)
                            --> VenusDestroyView (vdx)
                            --> VenusDestroySampler (vdk)
                            --> VenusDestroyRpass (vdr)
                            --> VenusDestroyBuf (vdb)
                            --> VenusDestroyImg (vdg)
                            --> VenusFreeMemory (vfe)
                            --> VenusDestroyModule (vdm)
                            --> VenusDestroyPipe (vdp)
                            --> VenusDestroyPlayout (vdy)
                            --> VenusDestroyDsl (vdt)
                            --> VenusDestroyPool (vdq)
                            --> VenusFreeDescset (vfs)
                            --> VenusResetCmdbuf (vrc)
                            --> VenusFreeCmdbuf (vfc)
                            --> VenusDestroyDevice (vdd)
                            --> VenusResetCmdPool (vpc)
                            --> VenusDestroyCmdPool (vdc)
                            --> VenusDestroyInstance (vdn)
                            --> VenusFormatProps (vgf)
                            --> VenusImageFormat (vip)
                            --> VenusDeviceExt (vxe)
                            --> VenusResetDescPool (vrd)
                            --> VenusInstanceExt (vie)
                            --> VenusDeviceWait (vwl)
                            --> VenusSubresourceLayout (vsl)
                            --> VenusRenderGranularity (vrg)
                            --> VenusSetLineWidth (vlw)
                            --> VenusSetDepthBias (vzb)
                            --> VenusSetBlendConst (vbc)
                            --> VenusSetDepthBounds (vbo)
                            --> VenusSetStencilCompare (vcm)
                            --> VenusSetStencilWrite (vwm)
                            --> VenusSetStencilRef (vrf)
                            --> VenusCopyBuffer (vcc)
                            --> VenusCopyImage (vcy)
                            --> VenusBlitImage (vbl)
                            --> VenusCopyBufToImg (vbt)
                            --> VenusCopyImgToBuf (vic)
                            --> VenusUpdateBuffer (vub)
                            --> VenusFillBuffer (vfl)
                            --> VenusClearColor (vcl)
                            --> VenusDrawIndirect (vio)
                            --> VenusDrawIdxIndirect (vix)
                            --> VenusClearDepth (vds)
                            --> VenusClearAttach (vat)
                            --> VenusDispatchIndirect (vin)
                            --> VenusResolveImage (vrs)
                            --> VenusGetFenceStatus (vgs)
                            --> VenusWaitForFences (vwf)
                            --> VenusResetFences (vfr)
                            --> VenusDestroyFence (vfn)
                            --> VenusQueueFamily (vqf)
                            --> VenusCreateDevice (vcd)
                            --> VenusGetQueue (vgq)
                            --> VenusEncode (vnenc)
                            --> GenHandle (gnh)
                            --> VenusBegin (vbg)
                            --> VenusEnd (ven)
                            --> VenusSubmit (vqs)
                            --> VenusWaitIdle (vwi)
                            --> VenusDispatch (vnd)
                            --> SpirvSubset (spirv)
                            --? BeginAlloc (bal)
                            --? AllocRun (aru)
                            --? ApuSys   (not instantiated)
                    +-- VenusGetQueue (vgq)
                            --? VenusSubmit (vqs)
                            --? VenusCreateDevice (vcd)
                            --? GenHandle (gnh)
                            --? ApuSys   (not instantiated)
                    +-- VenusCreateDevice (vcd)
                            --? VenusGetQueue (vgq)
                            --? VenusCreateInstance (vci)
                            --? GenHandle (gnh)
                            --? ApuSys   (not instantiated)
                    +-- VenusCreateInstance (vci)
                            --? VenusCreateDevice (vcd)
                            --? VenusEnumeratePhys (vep)
                            --? GenHandle (gnh)
                            --? ApuSys   (not instantiated)
                    +-- VenusEnumeratePhys (vep)
                            --? VenusCreateInstance (vci)
                            --? VenusCreateDevice (vcd)
                            --? VenusQueueFamily (vqf)
                            --? GenHandle (gnh)
                            --? ApuSys   (not instantiated)
                    +-- VenusQueueFamily (vqf)
                            --? VenusEnumeratePhys (vep)
                            --? VenusCreateDevice (vcd)
                            --? GenHandle (gnh)
                            --? ApuSys   (not instantiated)
                    +-- VenusPhysFeatures (vpf)
                            --? VenusEnumeratePhys (vep)
                            --? VenusCreateDevice (vcd)
                            --? GenHandle (gnh)
                            --? ApuSys   (not instantiated)
                    +-- VenusPhysProps (vpp)
                            --? VenusEnumeratePhys (vep)
                            --? VenusCreateDevice (vcd)
                            --? GenHandle (gnh)
                            --? ApuSys   (not instantiated)
                    +-- VenusPhysMemory (vmp)
                            --? VenusEnumeratePhys (vep)
                            --? VenusCreateDevice (vcd)
                            --? GenHandle (gnh)
                            --? ApuSys   (not instantiated)
                    +-- VenusAllocMemory (vam)
                            --? VenusCreateDevice (vcd)
                            --? VenusPhysMemory (vmp)
                            --? GenHandle (gnh)
                            --? ApuSys   (not instantiated)
                    +-- VenusCreateBuffer (vxb)
                            --? VenusCreateDevice (vcd)
                            --? VenusAllocMemory (vam)
                            --? GenHandle (gnh)
                            --? ApuSys   (not instantiated)
                    +-- VenusBindBuffer (vbb)
                            --? VenusCreateBuffer (vxb)
                            --? VenusAllocMemory (vam)
                            --? GenHandle (gnh)
                            --? ApuSys   (not instantiated)
                    +-- VenusMapMemory (vmm)
                            --? VenusAllocMemory (vam)
                            --? VenusBindBuffer (vbb)
                            --? GenHandle (gnh)
                            --? ApuSys   (not instantiated)
                    +-- VenusUnmapMemory (vum)
                            --? VenusMapMemory (vmm)
                            --? VenusAllocMemory (vam)
                            --? GenHandle (gnh)
                            --? ApuSys   (not instantiated)
                    +-- VenusBufReq (vbm)
                            --? VenusCreateBuffer (vxb)
                            --? GenHandle (gnh)
                            --? ApuSys   (not instantiated)
                    +-- VenusFlushMap (vfm)
                            --? VenusMapMemory (vmm)
                            --? VenusAllocMemory (vam)
                            --? GenHandle (gnh)
                            --? ApuSys   (not instantiated)
                    +-- VenusInvalidateMap (vim)
                            --? VenusMapMemory (vmm)
                            --? VenusAllocMemory (vam)
                            --? GenHandle (gnh)
                            --? ApuSys   (not instantiated)
                    +-- VenusMemCommit (vmc)
                            --? VenusAllocMemory (vam)
                            --? GenHandle (gnh)
                            --? ApuSys   (not instantiated)
                    +-- QueueBegin (qbn)
                            --> AvailNext (avn)
                            --> BeginRun (bru)
                            ==> WRITE then used then ISR
                            --? QueueAlloc (qal)
                            --? ApuSys   (not instantiated)
                    +-- QueueTypeBegin (qtb)
                            --> AvailNext (avn)
                            --> GrantCapset (gcs)
                            --> QueueBegin (qbn)
                            --? QueueTypeAlloc (qta)
                            --? ApuSys   (not instantiated)
                    +-- VenusCtrlBegin (vcb)
                            --> VenusCapset (vcap)
                            --> QueueTypeBegin (qtb)
                            --? VenusCtrlAlloc (vca)
                            --? ApuSys   (not instantiated)
                    +-- QueuePumpBegin (qpb)
                            --> VenusCtrlBegin (vcb)
                            --? QueuePumpAlloc (qpa)
                            --? ApuSys   (not instantiated)
                    +-- NotifyTakeBegin (ntb)
                            --> QueuePumpBegin (qpb)
                            --? NotifyTakeAlloc (nta)
                            --? ApuSys   (not instantiated)
                    +-- VqTakeBegin (vqb)
                            --> NotifyTakeBegin (ntb)
                            --? VqTakeAlloc (vqa)
                            --? ApuSys   (not instantiated)
                    +-- VqAxiBegin (vab)
                            --> VqTakeBegin (vqb)
                            ==> AXI SIZE=2 (4B) / SIZE=3 INCR
                            --? VqAxiAlloc (vaa)
                            --? TestharnessDma (tdma)
                            --? ApuSys   (not instantiated)
                    +-- QueueCmd (qcm)
                            --> GrantCapset (gcs)
                            --> QueueRun (qrn)
                            --? ApuSys   (not instantiated)
                    +-- QueueType (qty)
                            --> AvailNext (avn)
                            --> QueueCmd (qcm)
                            --? ApuSys   (not instantiated)
                    +-- VenusCtrl (vct)
                            --> VenusCapset (vcap)
                            --> QueueType (qty)
                            --? ApuSys   (not instantiated)
                    +-- QueuePump (qpu)
                            --> VenusCtrl (vct)
                            --? ApuSys   (not instantiated)
                    +-- NotifyTake (ntk)
                            --> QueuePump (qpu)
                            --? ApuSys   (not instantiated)
                    +-- VqTake (vqt)
                            --> NotifyTake (ntk)
                            --? ApuSys   (not instantiated)
                    +-- VqAxi (vax)
                            --> VqTake (vqt)
                            ==> AXI SIZE=2 (4B) / SIZE=3 INCR
                            --? TestharnessDma (tdma)
                            --? ApuSys   (not instantiated)
```

`ApuOff` and `ApuHarness` leave every graphics `XxxEn` at 0. Turning a bit on does not publish virgl and does not add the leaf to `g6lc_apu_sys`.

---

## 3. SoC box arborescence (`-->` instantiate)

```text
TestharnessLoad (g6lc_apu_th_load)
    ==> TestharnessDma (tdma)                  2:1 join onto xbar slave[2]
    --> FwRam (g6lc_apu_fwram)                 ==> 0x90000000 / 256 KiB
    --> ApuXbar (g6lc_apu_xbar)                opt-in +define+G6LC_APU
        --> TestharnessAttach (g6lc_apu_th)
            --> Axi4LiteAdapter (g6lc_apu_axi4_lite)
            --> TestharnessAttach (g6lc_apu_attach)
                --> ApuSoc (g6lc_apu_soc)
                    --> TrustedGrant (g6lc_apu_grant)
                    --> ApuSys (g6lc_apu_sys)
                        --> AxiLiteTransport (g6lc_apu_axi_lite)
                            --> VirtioTop (g6lc_apu_top)
                                --> VirtioMmio (g6lc_apu_virtio_mmio)
                                    ==> QueueNotify / queue PFN / ISR
                            --> ApuControl (g6lc_apu_control)
                        --> Mailbox (g6lc_apu_mbox)          [mem-only or exec-only]
                        --> ApuSched (g6lc_apu_sched)        [both-clients]
                            --> Mailbox (g6lc_apu_mbox)
                            --> ApuMem (g6lc_apu_mem)
                            --> ExecBind (g6lc_apu_exec_bind)
                        --> ApuMem (g6lc_apu_mem)            [mem-only]
                            --> Storage (g6lc_apu_storage)
                            --> ScatterGather (g6lc_apu_sg)
                                --> DmaRead (g6lc_apu_dma_read)
                            --> DmaRead (g6lc_apu_dma_read)
                            --> DmaWrite (g6lc_apu_dma_write)
                            --> UsedQueue (g6lc_apu_queue)
                                --> DmaWrite (g6lc_apu_dma_write)
                        --> ExecBind (g6lc_apu_exec_bind)    [exec-only]
                            --> ExecCluster (exec)
                                ==> one FPnew FMA + integer ALU
```

**Sched call rule:** one mailbox op is presented to **either** `ApuMem` **or** `ExecBind`. The other stays idle until completion. Exec does not read the resource map.

**Firmware sibling:** `g6lc_apu_fw` instantiates `AxiLiteTransport --> Mailbox --> ExecBind` for the resident image path. It is a second composition of the same three, not a second GPU.

---

## 4. Private-leaf grammar

Almost every `g6lc_apu_vgpu_*` suite is a ready/valid **trio**:

```text
Actor (id)     <-> Keep (idk)     <-> Check (idx or idy)
```

The Actor writes or walks. Keep stores the proven fields. Check is the Enable=0 fixture’s sibling and the legalize predicate. A second store of Keep/Check faults until `pulse_reset` on one-shot leaves.

Two spines feed the early versus late command readers:

| Spine record | Produced by | Consumed as |
|---|---|---|
| `buf` ExecBufferRead | `Submit3dChain (sub) <-> ExecBufferRead (buf)` | CREATE/BIND stream (`sh`, `vsb`, `iw`, …) |
| `fet` SceneFetch | `SceneChain (chn) <-> SceneFetch (fet)` | fetched-draw census (`drd`, `qdr`, `vwx`, `cxr`, …) |

`buf_i` means “the 960-byte execbuffer is named.” `fet_i` means “that buffer has been fetched.” Later identity ports repeat the census so a clone cannot silently drop a proven field.

---

## 5. Guest-named G0 spine (the live story)

This is the path the private TBs currently *name*, from QueueNotify through a guest-rung `NEXT` walk. It is **not** the SoC avail walker and **not** Mesa `glReadPixels`.

```text
AvailDescriptor (avail)
    --? SceneChain (chn)                         posted NEXT, no guest memory
    --? SceneChainGuestRead (nxc)                guest beats, does not consume
    --? GuestNextWalk (gnw)                      consumes device_idx 1

TransferBox (tfb) <-> TransferAttach (rab) <-> TransferFence (rfw)
    <-> TransferUsed (tuw) <-> TransferIrq (tiw) <-> TransferAck (taw)
    <-> TransferChain (txc)
        <-> TransferNextWalk (tnw)               posted NEXT, avail idx 2
            <-> TransferQueueNotify (qnt)        ==> 64'h880D0200
                <-> TransferAvailIdx (qav)       ==> 64'h880D0100
                    <-> TransferAvailRing (qrg)
                        <-> TransferDesc0 (qhd)  attach NEXT 1
                            <-> TransferDesc1 (qfd)
                                <-> TransferDesc2 (qwd)  WRITE response
                                    <-> TransferOkNodata (qok)
                                        <-> TransferUsedWrite (quw)
                                            <-> TransferUsedIrq (qiw)
                                                <-> TransferUsedAck (qaw)
                                                    <-> SceneAvailIdx (qsv)
                                                        … scene table qsr/qsd/qed/qrs
                                                        <-> SceneOkNodata (qso)
                                                            <-> SceneUsedWrite (qsu)
                                                                <-> SceneUsedIrq (qsi)
                                                                    <-> SceneUsedAck (qga)
                                                                        <-> SceneNextWalk (snw)
                                                                            <-> SceneQueueNotify (snt)  ==> 64'h8800E220
                                                                                <-> SceneAvailAfterNotify (sav) …
                                                                                    <-> SceneAckAfterNotify (sga)
                                                                                        <-> TransferNextAfterAck (rnw)
                                                                                            … rnt/rav/rrg/rhd/rfd/rwd
                                                                                            <-> TransferOkAfterAck (rok)
                                                                                                <-> TransferUsedAfterAck (ruw)
                                                                                                    <-> TransferIrqAfterAck (riw)
                                                                                                        <-> TransferAckAfterAck (rga)
                                                                                                            <-> TexAfterAck (gtx)
                                                                                                                <-> GuestTransferTexWrite (hcw)  ==> 64'h88070000 beat 0
                                                                                                                    <-> CoveredTexSample (wld)
                                                                                                                        <-> TexSampleChannels (cyr)
                                                                                                            SceneQueueNotifyCheck (sny)
                                                                                                                <-> GuestNextWalk (gnw)(sny)
                                                                                                                    ==> 64'h8800E100 / E120 / E200
                                                                                                                    <-> GuestNextKeep (gnk)
                                                                                                                        <-> GuestNextCheck (gnx)
```

`AvailDescriptor (avail)` still faults `NEXT` / `WRITE` / `INDIRECT`. `GuestNextWalk (gnw)` reads guest stand-in memory and consumes device index 1. Those two modules sit `--?` each other. Closing G0 item 2 is a walker the **SoC** avail path accepts, inside `g6lc_apu_sys`.

---

## 6. Command-decode arborescence (`buf` spine)

Frozen `gles2-min` CREATE/BIND as ready/valid calls on `ExecBufferRead (buf)`:

```text
Submit3dChain (sub)
    <-> ExecBufferRead (buf)
        <-> FirstCommandDecode (dec)
        <-> ContextCreate (ctx)
            <-> ResourceCreate3d (c3d)
                <-> ContextAttach (att)
                    <-> SceneResponse (rsp)
        <-> CapsetInfo (nfo) <-> CapsetGet (cap)          answer is refused
        <-> ScanoutSet (scn) <-> ResourceFlush (flu)      record, no present
        <-> SurfaceCreate / VertexShaderCreate (sh)
            <-> FragShaderCreate (fs)
                <-> VertexElementsCreate (ve)
                    <-> SamplerViewCreate (sv)
                        <-> SamplerStateCreate (ss)
                            <-> BlendCreate (bl)
                                <-> DepthStencilCreate (ds)
                                    <-> RasterizerCreate (rz)
                                        <-> BlendBind (bb)
                                            <-> DepthStencilBind (db)
                                                <-> RasterizerBind (rb)
                                                    <-> VertexShaderBind (vsb)
                                                        <-> FragShaderBind (fsb)
                                                            <-> VertexElementsBind (veb)
                                                                <-> SamplerStateBind (ssb)
                                                                    <-> SamplerViewSet (svb)
                                                                        <-> ResourceInlineWrite (iw)
                                                                            <-> VertexBuffersSet (vb)
                                                                                <-> ScissorSet (sci)
                                                                                    <-> ViewportSet (vp)
                                                                                        <-> FramebufferSet (fbo)
                                                                                            <-> ClearSet (clr)
                                                                                                <-> DrawVbo (drw)
        <-> ScanCreate2d (s2d)
            <-> ScanBacking (sbk)
                <-> ScanBandTransfer (sxf)                 copies no bytes
                    <-> ScanScanout (ssc) <-> ScanBandFlush (sfl)
```

`VertexShaderBind (vsb)(buf, rb)` is the BIND_SHADER of handle 2, stage 0. TGSI text stays in the execbuffer.

---

## 7. Fetched-draw census (`fet` spine)

```text
SceneChain (chn)
    <-> SceneFetch (fet)
        <-> DrawVboRead (drd)
            <-> NdcFloatsRead (qdr)
                <-> ViewportRead (vwx)
                    <-> ScissorRead (cxr)
                        <-> ClearColorRead (cwr)
                            <-> FramebufferRead (fbr)
                                <-> VertexBufferRead (vbf)
                                    <-> InlineWriteRead (iwr)
                                        <-> SamplerViewRead (svr) <-> SamplerStateRead (ssr)
                                            <-> … binds/objects through SurfaceObjectRead (sfc)
    <-> SceneChainGuestRead (nxc)                          guest table 64'h8800E100
        <-> OpcodeList (ols)                               count 0, capset id 0
            <-> ClearWindowWrite (gpw)                     ==> 64'h88020000
                <-> SceneComplete (gcw) <-> UsedIrq (viw) <-> UsedAck (vaw)
                    <-> ClearWindowScan (wfr)
                        <-> ReadbackCopy (gbw)             ==> 64'h88030000
                            <-> ReadbackRect (gbd)
                                <-> ClearChannels (byr)    LE 0D 0D 1A FF
```

Row-0 beat readers (`ReadbackBeat1 (b1r)` … `ReadbackBeat7 (b7r)`, corners, row 1) hang under `ReadbackRect (gbd)`. They do not start a new spine.

---

## 8. Sample / TEX arborescence

```text
CoverSample (cover) --? FragStore (frag) --? ResourceSurface (surf)
        lab triangle / RGBA8 byte memory / one packed-image sample
        --? ApuSys

ScanBandTransfer (sxf) <-> BandCopy (bcp)                  5120 beats, image not stored
    <-> ClampEdgeTap (tap) <-> CeilingOriginTexel (pxc)
        <-> LinearBlend (lin)                              32'hA5000000 / 32'hD2008000
            <-> SpanBlend (spn) <-> VerticalBlend (vln) <-> Row2Blend (y2b)
                <-> CeilingSampler (smp)
                    --> instantiated inside CeilingBeatWrite (rbf) when Enable=1
                        <-> CeilingBeatWrite (rbf)         ==> 32'h88040000
                            <-> CeilingBeatRead (rdr)

TexBind (tbn) <-> TexSample (ftx)                          refused 0, lab pair
    <-> LinearPairWrite (acw)                              ==> 64'h88050000
        <-> ColorWindowCopy (csw)                          ==> 64'h88060000
            <-> TransferDestCopy (rpw)                     ==> 64'h88070000
                <-> GuestReadpixelsRect (grd)
                    <-> TransferBox (tfb) … (section 5)

TexAfterAck (gtx)(ftk, rgx)
    <-> GuestTransferTexWrite (hcw)
        <-> CoveredTexSample (wld)
            <-> TexSampleChannels (cyr)                    00 00 00 A5 / 00 80 00 D2
```

Compiler `TEX` in `g6lc_apu_tgsi_compile` still returns `-26`. These sample leaves read proven backing words; they do not run the shader as a compiler `TEX`.

---

## 9. Open joints (keep visible)

```text
AvailDescriptor (avail)           NEXT is a fault
GuestNextWalk (gnw)               --? avail; not in ApuSys
CapsetInfo (nfo) / CapsetGet (cap) / OpcodeList (ols)
                                  still refused / count 0
ExecCluster (exec)                FPnew lane; no virgl grant
FeatureVirgl                      published only under VenusEn (ApuVenus); capset 1 refused; NumCapsets = 1
HdmiScanout                       other device, HdmiEn, 0x8ef00000
ai_island                         other device, MatrixEn, PLIC 8
```

Gate A5 remains one Mesa `glReadPixels(0,0,64,64)` whose bytes come from this GPU and match `DISPLAY.md` section 7.

---

## 10. Refresh checklist (when the RTL moves)

1. Add or rename the PascalCase alias at the three declaration sites (grant, type, module).
2. Draw **one** `<->` (or `-->` / `==>` / `--?`) under the tree it actually extends.
3. If the leaf is a keep/check of an existing actor, update the trio in place (H3). Do not add a fourth tree.
4. If the leaf is a virtqueue clone after scene ack, hang it on section 5 (`r*` / `gtx` / `gnw`), not on section 6.
5. Leave section 9 honest: `avail` `NEXT`, compiler `TEX`, `FeatureVirgl`, HDMI, island.
6. Point new spine comments at this file (`Interplay: … See AGENTS-impl-interplays.md.`).

Primary predecessor for a new leaf is the suite-local record on `*_i`, which is the return value of the previous call.

---

## 11. Firmware mailbox calls (`==>` then `-->`)

The control window is a register file. A write of `wdata[3:0]` selects `apu_mem_op_e`. `ApuSched` presents that op to **either** `ApuMem` **or** `ExecBind`.

```text
firmware hart ==> ApuControl ==> Mailbox (g6lc_apu_mbox)
    op = wdata[3:0]
    --> ApuMem                                if !apu_op_is_exec(op)
        APU_MEM_MAP_INSERT / LOOKUP / INVAL
        APU_MEM_SG_LOAD / SG_XFER
        APU_MEM_CMD_DMA / CMD_RELEASE
        APU_MEM_USED
    --> ExecBind --> ExecCluster (exec)       if apu_op_is_exec(op)
        APU_MEM_EXEC_IMEM / POKE / PEEK
        APU_MEM_EXEC_RUN / DPEEK
```

`APU_MEM_NONE` is idle. Exec does not read the resource map. TGSI compile (`g6lc_apu_tgsi_compile`) is a host/firmware program; compiler `TEX` still returns `-26`.

---

## 12. Virtio-mmio doorbell (`==>`)

`VirtioMmio` is the guest-facing register file inside `ApuSys`. Private `qnt` / `snt` / `rnt` stand in for the same doorbell at lab addresses.

```text
guest ==> VREG_MAGIC / VERSION / DEVICE_ID=16 / VENDOR
      ==> VREG_DEVICE_FEATURES / DRIVER_FEATURES     VERSION_1 + RING_RESET
      ==> VREG_QUEUE_SEL / NUM / READY / DESC / AVAIL / USED
      ==> VREG_QUEUE_NOTIFY                          doorbell for queue 0 or 1
      ==> VREG_INTERRUPT_STATUS / ACK
      ==> VREG_STATUS                                0 is device reset
            |
            --? TransferQueueNotify (qnt)   lab 64'h880D0200
            --? SceneQueueNotify (snt)      lab 64'h8800E220
            --? AvailDescriptor (avail)     NEXT still a fault
            --? GuestNextWalk (gnw)         after sny, consumes device_idx 1
```

The production used-ring into `VirtioMmio` is the `used_*` ports on `g6lc_apu_sys`. Private `UsedPublish (used)` / `UsedGuestWrite (uwr)` / `UsedIndexStore (uidx)` are `--?` that path.

---

## 13. Neighbor devices

```text
HdmiScanout                         HdmiEn, not an apu_cfg_t bit
    --> scanner --> line buffer --> TMDS --> shifter
    ==> simple-framebuffer 0x8ef00000   640×480 r5g6b5
    --? ApuSys                          no shared instantiate

ai_island                           AiCfg.MatrixEn
    ==> MMIO 0x40000000  PLIC 8
    --> tiled GEMM + gated FP path; not a shader engine
    --? gpu@0x40001000  PLIC 9
```

G1/G2 may later feed scanout from a resource this GPU writes. That join is not a G0 edge.

---

## 14. Guest-rung fetch (G0.2 integration)

```text
GuestNextCheck (gnx)
    <-> GuestExecFetch (gef)(gnx)
        ==> 64'h8800A000 header + 30 beats at 64'h8800B000
        <-> GuestExecKeep (gek)
            <-> GuestExecCheck (gex)          cmd0 = CREATE_OBJECT 32'h00050801
```

`SceneFetch (fet)` still hangs off `SceneChain (chn)`. `gef` is the same bytes after the **guest-rung** walk consumed device index 1. `avail` still faults `NEXT`. The 960 bytes are not kept.

---

## 15. What “full picture” still waits on hardware

The earlier NEXT/capset/readback headline was necessary but insufficient. A list
of completed opcodes is not a valid virgl or Venus capset. This section owns the
structural blockers; the acceptance sequence remains A0–A7/P0–P5/G0–G4 in
`plan-5ddc97674e5bf9b0.md`, with current source/runtime requirements in
`architecture/uncore/apu-graphics.md`.

**Consolidation (2026-10-03).** The per-command `g6lc_apu_v??` leaves and the
`bru`/`qbn`/`qtb` fold are classified as fixed-shape diagnostics (one accepted
shape per command, flags instead of recorded command buffers, 564 config fields,
~246 k cells for `bru`). The engine structure that replaces them is
`architecture/uncore/apu-vulkan-engine.md`: `VnDec` (generated from the pinned
venus-protocol vk.xml, one decoder for the whole command set) `-->` `ObjTab`
(`tc_sram` generational objects keyed by driver ids) `-->` `CmdRec` (recorded
`vkCmd*`) `-->` `cmdexec` `-->` `ShaderCore`/`Raster`/`Xfer` `==>` reply bytes
`==>` used elem `==>` `used.idx` `==>` ISR. The existing walker/ring/publication
leaves (`chain`, `cdma`, `avn`, `vnring`, `avu`, `uir`, `qdn`, `hvis`, `vcap`,
`tdma`) are the reusable primitives those engines sit between. Catalog leaves
stay as frozen vector sources; nothing here is instantiated in `g6lc_apu_sys` yet.

**Consolidation committed (2026-10-05).** The consolidation is now on the tree:
`32668990c` (3c-i: apu_mp word ports, `apmem`, `vqwalk`, `vgsys`) and
`7822b1672` (3c-ii: `ApuCfg.VenusEn` attach inside `g6lc_apu_sys` — the §16
arborescence below is instantiated RTL). The controlling sequence is
`architecture/uncore/apu-vulkan-engine.md` §12; the catalog census above and
this inventory remain the frozen record.

### Source-review inventory, 2026-10-01

These are working-tree Git blob identities (`git hash-object`), not simulation
results or a complete session-wide evidence manifest. Paths are repo-relative.
Historical PASS logs remain historical until their source/tool/artifact identity
is reconciled and the affected configuration is rerun.

| Source | State at review | Blob identity | Evidence class / limit |
|---|---|---|---|
| `corev_apu/apu/g6lc_apu_vgpu_gnw.sv` | untracked | `ba9efb521cd810f082b1c811a13a27ff9ec1258c` | Fixed-scene diagnostic: programmed queue addresses/arbitrary heads are not used; admission/commit require index 1, head 0 and frozen addresses (`120–179`). |
| `corev_apu/apu/g6lc_apu_vgpu_gef.sv` | untracked | `fc18bda58b5b6a74833a9a0349d0829b56bd91dd` | Fixed-scene fetch diagnostic: reads 30 payload beats but retains only selected fields/cmd0, not immutable shader bytes (`116–162`). |
| `corev_apu/apu/g6lc_apu_spirv.sv` | untracked | `1c465d083ef5a28e6fcf7502696903198bed064d` | Bounded SPIR-V-subset prototype: 128-word immutable store, GLCompute IAdd/IMul, bytes+IRQ TB client. Not Venus, not in `g6lc_apu_sys`. Remote 2026-10-01 8/15/348, Enable=1 35938 cells / 5365 FFs. |
| `corev_apu/apu/g6lc_apu_chain.sv` | untracked | `eb8c30aa8d626519420d8b2f8a776b4a1da2af58` | Reusable NEXT walker: programmed table base/head, bounded chain, INDIRECT/loop/OOB/overlong/misaligned fault with no stray DMA. Not `avail`, not `gnw`. Remote 2026-10-01 9/27/73, Enable=1 1917 cells / 503 FFs. |
| `corev_apu/apu/g6lc_apu_cdma.sv` | untracked | `f4598277bc955ae02b0b1d04d42f122898f8ec6e` | NextChain joined to checked DmaRead: 16-byte mapping-window AXI reads. INDIRECT one AR; OOB/invalid mapping none. Not in `g6lc_apu_sys`. Remote 2026-10-01 7/20/153, Enable=1 8471 cells / 1150 FFs. |
| `corev_apu/apu/g6lc_apu_vgpu_ftx.sv` | untracked | `35e5afe09fcde087ad45f008c6bac63a3b6fd4fc` | Fixed-sample validator: compares expected resource/view/sampler and sample values (`62–70`); not general shader TEX. |
| `corev_apu/apu/g6lc_apu_th_load.sv` | tracked, modified | `a103f1919a987b378602e0968eec36a861c33dee` | Diagnostic integration: synthesis-ready constant and constant backend idle/reset-done (`97`, `127`), not service/drain proof. |
| `corev_apu/apu/g6lc_apu_virtio_mmio.sv` | tracked, modified | `490c7528a810af9b7a6903998bc40bb697b56970` | SHM id 1 returns `64'h82000000` / 1 MiB when `ShmEn`; other ids and `ShmEn=0` stay all-ones. P1 TB still PASS. `RESOURCE_BLOB`/`CONTEXT_INIT` not in `APU_IMPL_FEATURES`. |
| `corev_apu/apu/g6lc_apu_hvis.sv` | untracked | `440bab823ffb772d80f9ddf85820849a2aec18f2` | HOST_VISIBLE blob map + Venus `context_init` 4. Virgl capset 1 faults. Remote 2026-10-01 7/18/51, Enable=1 1386 cells / 197 FFs. |
| `corev_apu/apu/g6lc_apu_vncs.sv` | untracked | `9175f034c147b477676b25060fb6c9c6432a37de` | Diagnostic Venus CS: CREATE_MODULE/DISPATCH ring into SpirvSubset. Not Mesa vn_protocol. Remote 2026-10-01 4/10/341, Enable=1 74601 cells / 9601 FFs. |
| `corev_apu/apu/g6lc_apu_vcap.sv` | untracked | `7c7b80b5ffc68ae9cc7e3b9252df8119a39a3ae9` | Venus GET_CAPSET_INFO/GET_CAPSET id 4, 160-byte virgl_renderer_capset_venus. Virgl id 1 faults. NumCapsets stays 0. Remote 2026-10-01 5/56/28, Enable=1 222 cells / 4 FFs. |
| `corev_apu/apu/g6lc_apu_vnring.sv` | untracked | `92ba1242e4f308b494ecbf56d13a74efa13f50ab` | Mesa vn_ring_layout walker: head 0, tail 64, status 128, buffer 192, 256B. Stock geometry, not vk* encode. Remote 2026-10-01 6/13/59, Enable=1 13443 cells / 4228 FFs. |
| `corev_apu/apu/g6lc_apu_tdma.sv` | untracked | `860d7ba0f738bc93db96de2892b2e61a3cfd017a` | 2:1 AXI join, APU wins over AI. Remote 2026-10-01 4/10/18, Enable=1 321 cells / 4 FFs. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vnenc.sv` | untracked | `677e40d3a20acda483f66916c96c657b945c4a33` | Mesa vn_protocol vkCreateShaderModule CS (type 59, 192-word CS). Remote 2026-10-01 6/13/302, Enable=1 36136 cells / 6437 FFs. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vnp.sv` | untracked | `3ce8ce1e07eb358389b5e6284a8b47abebeaee3a` | vn_ring buffer_size 512 feeds vnenc into SpirvSubset. Remote 2026-10-01 6/11/768, Enable=1 100179 cells / 20112 FFs. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_avn.sv` | untracked | `a4525eac06badac8b1b94bf3f09988c312bd3ab8` | virtq_avail.idx + ring[head] feeds NextChain. NEXT accepted. Remote 2026-10-01 7/13/97, Enable=1 3521 cells / 988 FFs. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_avu.sv` | untracked | `f3539702658cd8c625ce61f41e58c1f23815058a` | AvailNext then virtq_used elem + used.idx. Remote 2026-10-01 5/9/82, Enable=1 4754 cells / 1438 FFs. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_uir.sv` | untracked | `d375dd473a3ea3743d2c837450e415ae76c5fa7c` | AvailUsed then virtio used-buffer ISR bit 0. Remote 2026-10-01 4/9/63, Enable=1 3947 cells / 1141 FFs. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_cms.sv` | untracked | `e609107989ff070a98f86e8d20a6149fb1804f55` | AvailNext first-payload snapshot survives guest mutation. Remote 2026-10-01 4/10/45, Enable=1 4227 cells / 1201 FFs. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_prs.sv` | untracked | `96d13d0829f0bd6a6f26b0ae085088aeb7f4e1e5` | AvailNext WRITE-window programmed response (OK_NODATA, not pixels). Remote 2026-10-01 4/8/71, Enable=1 3833 cells / 1234 FFs. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_qdn.sv` | untracked | `d15a483b5b8b14cba6d6252a08bbc5ee762ea55b` | One AvailNext then WRITE, used.idx, ISR. Remote 2026-10-01 3/8/52, Enable=1 5140 cells / 1453 FFs. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_gcs.sv` | untracked | `4fbc888fcc482093bbd387cf6019fcdb758ddf8b` | AvailNext GET_CAPSET/INFO Venus blob WRITE, used.idx, ISR. Virgl id 1 faults. NumCapsets stays 0. Remote 2026-10-01 5/12/116, Enable=1 9379 cells / 1813 FFs. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vnd.sv` | untracked | `bc9518862a29fee611c958908a897642643e5cbb` | Mesa vn_protocol vkCmdDispatch CS (type 110). Remote 2026-10-01 7/12/145, Enable=1 1729 cells / 741 FFs. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_gnh.sv` | untracked | `ea5855a9b70758ecb21b3f2bb6362e82eb1fbfa6` | 32-slot generational table, 5-bit kinds, handle `{gen[31:16], 11'd0, slot[4:0]}`. Remote 2026-10-02 6/49/242, Enable=1 10853 cells / 2080 FFs. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_hdp.sv` | untracked | `56f75ca3b84c4d1051434d5c86b604cfe735088a` | GenHandle lookup of vkCmdDispatch commandBuffer as live CMDBUF. Remote 2026-10-01 6/11/146, Enable=1 5979 cells / 1491 FFs. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_hph.sv` | untracked | `7bbb81e76e8f9887012d0798680db4e5a5bbd08f` | vkCreateShaderModule publishes MODULE; vkCmdDispatch looks up CMDBUF. Remote 2026-10-01 6/11/207, Enable=1 41062 cells / 7481 FFs. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_hrn.sv` | untracked | `ff1979bde32d16b6659c6e24f01829f72542a7b4` | HandlePath create/dispatch then SpirvSubset kick 2+3=5 then 4+5=9. Remote 2026-10-01 6/11/720, Enable=1 77619 cells / 13025 FFs. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_rdn.sv` | untracked | `e0086a9819b5c34223fdfe4c859882f304ba03fe` | HandleRun dispatch WRITE result, used.idx, ISR. Remote 2026-10-01 4/10/403, Enable=1 77606 cells / 13138 FFs. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_qrn.sv` | untracked | `79b69d1e6c3c78a56c43de3a3ebe536ab4b15c93` | AvailNext fetches CS into RunDone CREATE/DISPATCH. Remote 2026-10-01 3/9/315, Enable=1 84956 cells / 15231 FFs. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_qcm.sv` | untracked | `ea115c683bbf6d3c51535db2443bdac368b3c70b` | GrantCapset or QueueRun on one request. Remote 2026-10-01 6/16/436, Enable=1 95709 cells / 17523 FFs. NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_qty.sv` | untracked | `2d0a66ca792a542c65c86c066b72c9e690a530a1` | AvailNext type word selects GrantCapset or QueueRun. Remote 2026-10-01 6/16/516, Enable=1 100577 cells / 19138 FFs. NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vct.sv` | untracked | `7f8f502ed9a3436092a8fd7cb439da0f943a47e8` | Private Venus num_capsets=1 and QueueNotify into QueueType. Remote 2026-10-01 9/22/566, Enable=1 101726 cells / 19670 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_qpu.sv` | untracked | `3c4d5c69cda4db3ea58751e5350dc0fb960ad920` | QueueNotify drains AvailNext until EMPTY. Remote 2026-10-01 10/24/735, Enable=1 103215 cells / 20298 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_ntk.sv` | untracked | `7e1f87647d7adc37daf9476c92172350c2d10ad7` | virtio notify_pending[0] consumes QueuePump. Remote 2026-10-01 6/12/160, Enable=1 105435 cells / 21314 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vqt.sv` | untracked | `53433ebd12ef1c9b53d8fc6f574f78d1e3c1c53f` | virtio vq_state[0] arms NotifyTake on notify_pending[0]. Remote 2026-10-01 6/11/163, Enable=1 108797 cells / 22150 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vax.sv` | untracked | `765524d4a7c089c1f9392563362bc63edf2664b7` | VqTake guest beats on 64-bit AXI. Remote 2026-10-01 6/11/287, Enable=1 111519 cells / 22766 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vac.sv` | untracked | `9f57062cf290912ca1f7961df77cee8c64accf6b` | Mesa vkAllocateCommandBuffers ALLOC CMDBUF. Remote 2026-10-01 12/18/1016, Enable=1 4931 cells / 1569 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_hal.sv` | untracked | `993148e8a1e4bf0819e88a4ef8bd12fb3a400729` | ALLOC CMDBUF then vkCmdDispatch LOOKUP on one table. Remote 2026-10-01 8/15/479, Enable=1 9178 cells / 2262 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_aru.sv` | untracked | `b9651bfd98b9d309f136978b16cc48aea0ee51b7` | ALLOC CMDBUF, CREATE MODULE, DISPATCH SpirvSubset on one table. Remote 2026-10-01 7/13/914, Enable=1 81337 cells / 13796 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_qal.sv` | untracked | `259b7ecd5941878d57a2e01d22781a2105da73bf` | AvailNext CS into AllocRun ALLOC/CREATE/DISPATCH. Remote 2026-10-01 4/11/377, Enable=1 86349 cells / 15155 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_qta.sv` | untracked | `595acc12eb6acfc5b00d83aa062dc8341ad54331` | Type word selects GrantCapset or QueueAlloc. Idle holds `capset_q` except `gnh_only`. Remote 2026-10-01 6/16/547, Enable=1 100760 cells / 18263 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vca.sv` | untracked | `062b1d14124c7ccedee29598ab5b57f722da4c24` | Private num_capsets=1 and QueueNotify into QueueTypeAlloc. Remote 2026-10-01 9/22/597, Enable=1 101912 cells / 18796 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_qpa.sv` | untracked | `89cc46e92abb131dea47a703078d820b4fae924f` | QueueNotify drains QueueTypeAlloc until EMPTY. Type 88 ALLOC rides GET_CAPSET. Remote 2026-10-01 10/24/770, Enable=1 103410 cells / 19425 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_nta.sv` | untracked | `bff651eb3a65b54fc752db9b4707242c55211182` | virtio notify_pending[0] consumes QueuePumpAlloc. Type 88 ALLOC rides the doorbell. Remote 2026-10-01 7/13/241, Enable=1 105632 cells / 20442 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vqa.sv` | untracked | `084a8881599d36791200260ba1155906bdd170b6` | virtio vq_state[0] arms NotifyTakeAlloc. Type 88 ALLOC rides the doorbell. Remote 2026-10-01 7/12/243, Enable=1 108997 cells / 21279 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vaa.sv` | untracked | `a46222cd12debc20ce5fcf7282c11fcbd89fc96b` | VqTakeAlloc guest beats on 64-bit AXI. Type 88 ALLOC rides the doorbell. Remote 2026-10-01 7/12/426, Enable=1 111719 cells / 21895 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vbg.sv` | untracked | `4595d4b85875068f6017ca626df1fb2e50c36842` | Mesa vn_protocol vkBeginCommandBuffer CS (type 90, sType 42). Remote 2026-10-01 11/17/350, Enable=1 1947 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_bal.sv` | untracked | `c73c5b687d7784b6ee4fd19d0c9c734631755452` | ALLOC CMDBUF then vkBeginCommandBuffer LOOKUP on one table. Remote 2026-10-01 8/17/554, Enable=1 9018 cells / 2134 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_bru.sv` | untracked | `bbdebbb558b1d87af96f32dd96822103cd5f8e48` | ALLOC then RETIRE through DEVICE/INSTANCE; GetFenceStatus/WaitForFences/ResetFences/DestroyFence LOOKUP DEVICE, no FENCE kind. op 7-bit, FSM 8-bit. Remote 2026-10-02 12/240/10017, Enable=1 246341 cells / 59751 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_qbn.sv` | untracked | `9c50b7f5a012b8a4f55af1625a210609e9020191` | AvailNext CS; WRITE publishes used.idx/ISR including types 36/37/38/39. Remote 2026-10-02 7/115/5376, Enable=1 234882 cells / 59694 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_qtb.sv` | untracked | `5bb60e3d98325a9a0a99b6c3cfd10ca3c9296c8d` | Type word selects GrantCapset or QueueBegin. Types 36/37/38/39 ride GET_CAPSET. Remote 2026-10-02 6/115/6933, Enable=1 249033 cells / 62799 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vcb.sv` | untracked | `f3ce23d3be022f1180cb862f3b1a636dcdebf093` | Private num_capsets=1 and QueueNotify into QueueTypeBegin. Remote 2026-10-01 9/23/654, Enable=1 103161 cells / 19254 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_qpb.sv` | untracked | `64dfe3cbe502c5de18dba90fcb997873dd8f294e` | QueueNotify drains QueueTypeBegin until EMPTY. Remote 2026-10-01 10/25/837, Enable=1 104658 cells / 19884 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_ntb.sv` | untracked | `1531f3e2c623f144b7eb28b6a1d7cc672384bf51` | virtio notify_pending[0] consumes QueuePumpBegin. Remote 2026-10-01 7/14/317, Enable=1 106882 cells / 20902 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vqb.sv` | untracked | `3189bbb5b8f315386a390ab39f94b737407a97bc` | virtio vq_state[0] arms NotifyTakeBegin on notify_pending[0]. Remote 2026-10-01 7/13/318, Enable=1 110250 cells / 21740 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vab.sv` | untracked | `8ad2dc1d5df866390a2e0ff567b1e41e65d6a2ad` | VqTakeBegin guest beats on 64-bit AXI. Remote 2026-10-01 7/13/553, Enable=1 112972 cells / 22356 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_ven.sv` | untracked | `267496e055d29fdf7cb4639e88d76c583f51697f` | Mesa vn_protocol vkEndCommandBuffer CS (type 91). Remote 2026-10-01 10/16/165, Enable=1 1590 cells / 644 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_eal.sv` | untracked | `2e1d9b13d84c4c0b8cfc567c0bb3848bcba764d6` | ALLOC CMDBUF then BEGIN LOOKUP then END LOOKUP on one table. Remote 2026-10-01 10/22/778, Enable=1 10853 cells / 2749 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vqs.sv` | untracked | `65be7d65205ee3e769cef45c322b2cd4c1e66bb8` | Mesa vn_protocol vkQueueSubmit CS (type 18, sType 4). Remote 2026-10-01 9/15/992, Enable=1 3534 cells / 1252 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vwi.sv` | untracked | `6469a814af979f77aa0f7435f11d7fb8c62204d3` | Mesa vn_protocol vkQueueWaitIdle CS (type 19). Remote 2026-10-01 6/12/89, Enable=1 1588 cells / 644 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vgq.sv` | untracked | `c137b70da8e5d10da2395460aaa796198ba98bfd` | Mesa vn_protocol vkGetDeviceQueue CS (type 17, family 0, index 0). Remote 2026-10-01 7/13/134, Enable=1 1781 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vcd.sv` | untracked | `370e96a1aa84b6e691da96b0e00b15513b0bcd92` | Mesa vn_protocol vkCreateDevice CS (type 11, sType 3, one family-0 queue). Remote 2026-10-01 7/13/926, Enable=1 4215 cells / 1412 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vci.sv` | untracked | `7d84150a48222ce363164adf6376b9d42ab23ecd` | Mesa vn_protocol vkCreateInstance CS (type 0, sType 1). Remote 2026-10-02 7/13/566, Enable=1 2646 cells / 900 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vep.sv` | untracked | `55d2ea3f01165314a7b99ebb68375f3caff1adb8` | Mesa vn_protocol vkEnumeratePhysicalDevices CS (type 2, count 1). Remote 2026-10-02 7/13/388, Enable=1 1814 cells / 644 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vqf.sv` | untracked | `77c28c53cb2665b7875dfb0af19747dc3a45e3d5` | Mesa vn_protocol vkGetPhysicalDeviceQueueFamilyProperties CS (type 7, count 1). Remote 2026-10-02 7/13/388, Enable=1 1816 cells / 644 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vpf.sv` | untracked | `8f788b5790ac2fe9dba466bc13cded9de29349b9` | Mesa vn_protocol vkGetPhysicalDeviceFeatures CS (type 3). Remote 2026-10-02 7/13/326, Enable=1 1651 cells / 644 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vpp.sv` | untracked | `371bcdb330c44d903538f409df3c0b7cd4e645d4` | Mesa vn_protocol vkGetPhysicalDeviceProperties CS (type 6). Remote 2026-10-02 7/13/326, Enable=1 1651 cells / 644 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vmp.sv` | untracked | `dfa3745550551b1a51994fd5dfe86ed1b754ccd8` | Mesa vn_protocol vkGetPhysicalDeviceMemoryProperties CS (type 8). Remote 2026-10-02 7/13/326, Enable=1 1650 cells / 644 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vam.sv` | untracked | `b1c354049cc8f7010a97706f3bdc8902a118a56a` | Mesa vn_protocol vkAllocateMemory CS (type 21, sType 5). Remote 2026-10-02 8/14/631, Enable=1 2791 cells / 964 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vxb.sv` | untracked | `e9f24fdbd75147ee1ecad9791850a3af79ec8186` | Mesa vn_protocol vkCreateBuffer CS (type 50, sType 12, usage STORAGE_BUFFER). Remote 2026-10-02 8/14/815, Enable=1 3339 cells / 1220 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vbb.sv` | untracked | `e3974d07728657afddbc6bea54b33823b3f09dfd` | Mesa vn_protocol vkBindBufferMemory CS (type 28, offset 0). Remote 2026-10-02 8/14/435, Enable=1 2039 cells / 772 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vmm.sv` | untracked | `e8cb8646bbadc91b12ce75ab3a7600c55339c019` | Mesa vn_protocol vkMapMemory CS (type 23, offset 0). Remote 2026-10-02 9/15/548, Enable=1 2137 cells / 772 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vum.sv` | untracked | `a90cdbd17d5e0162c767a028173fc0be553cd231` | Mesa vn_protocol vkUnmapMemory CS (type 24, void). Remote 2026-10-02 6/12/268, Enable=1 1715 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vbm.sv` | untracked | `564783e5745f8fe7748b45c99c7e5787e5b8efe9` | Mesa vn_protocol vkGetBufferMemoryRequirements CS (type 30, void). Remote 2026-10-02 7/13/349, Enable=1 1781 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vfm.sv` | untracked | `4423ada2f55bc67e18e1fbf460226ce3210faa44` | Mesa vn_protocol vkFlushMappedMemoryRanges CS (type 25, sType 6). Remote 2026-10-02 8/14/633, Enable=1 2674 cells / 964 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vim.sv` | untracked | `d314504e8b428905b529af926ef0ce37ea3be7fd` | Mesa vn_protocol vkInvalidateMappedMemoryRanges CS (type 26, sType 6). Remote 2026-10-02 8/14/633, Enable=1 2674 cells / 964 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vmc.sv` | untracked | `11debca06814fee1735f551bd1a0243d54dd1421` | Mesa vn_protocol vkGetDeviceMemoryCommitment CS (type 27, void). Remote 2026-10-02 7/13/349, Enable=1 1781 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vdl.sv` | untracked | `d3049baeb4a61dc82eb114bc54b77ade042a3af6` | Mesa vn_protocol vkCreateDescriptorSetLayout CS (type 72, sType 32). Remote 2026-10-02 7/13/564, Enable=1 2745 cells / 964 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vpl.sv` | untracked | `dd12fc36a389db987a2d619b03e8da4c8b8b126d` | Mesa vn_protocol vkCreatePipelineLayout CS (type 68, sType 30). Remote 2026-10-02 7/13/552, Enable=1 2837 cells / 1028 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vcp.sv` | untracked | `6acf4fb3634306cf10246dfbf0e764dbfc35a201` | Mesa vn_protocol vkCreateComputePipelines CS (type 66, sType 29). Remote 2026-10-02 7/13/698, Enable=1 3595 cells / 1348 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vda.sv` | untracked | `cdf7a732a040060e76cc8249b73204174892477b` | Mesa vn_protocol vkAllocateDescriptorSets CS (type 77, sType 34). Pool field LOOKUPed. Remote 2026-10-02 7/13/542, Enable=1 2803 cells / 1028 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vud.sv` | untracked | `dc40c81932e27346d2018e7a7d5f0fd127a48347` | Mesa vn_protocol vkUpdateDescriptorSets CS (type 79, sType 35). Remote 2026-10-02 7/11/682, Enable=1 3437 cells / 1284 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vbp.sv` | untracked | `348be535caab6e9c5e2c6160c8d856b5d178a22a` | Mesa vn_protocol vkCmdBindPipeline CS (type 93, compute). Remote 2026-10-02 7/11/336, Enable=1 1817 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vbd.sv` | untracked | `0bf22e7f0a74f983881bee7038267332679d0be2` | Mesa vn_protocol vkCmdBindDescriptorSets CS (type 103). Remote 2026-10-02 7/11/492, Enable=1 2676 cells / 1028 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vpo.sv` | untracked | `dc17c8d5d801c06f74ba9ca0538292f035cdebf8` | Mesa vn_protocol vkCreateDescriptorPool CS (type 74, sType 33). Remote 2026-10-02 7/12/588, Enable=1 2811 cells / 964 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vxi.sv` | untracked | `0445946148ecc855f1ed308da38ce263b8ce8f5c` | Mesa vn_protocol vkCreateImage CS (type 54, sType 14). Remote 2026-10-02 7/12/792, Enable=1 3616 cells / 1220 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vbi.sv` | untracked | `c0d7fa58e44996bae2de25e79b15537417dac6be` | Mesa vn_protocol vkBindImageMemory CS (type 29). Remote 2026-10-02 7/12/374, Enable=1 2040 cells / 772 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vmi.sv` | untracked | `7a264abb49abf152d13aa349037ba7f0b148dbbb` | Mesa vn_protocol vkGetImageMemoryRequirements CS (type 31). Remote 2026-10-02 7/12/350, Enable=1 1847 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vxv.sv` | untracked | `c3559e88d49cd049385eb8dd01eb1e0cdaded7b5` | Mesa vn_protocol vkCreateImageView CS (type 57, sType 15). Remote 2026-10-02 7/12/766, Enable=1 3674 cells / 1284 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vsm.sv` | untracked | `8c7c97fdd22c50f7051933e401b184dfe3920700` | Mesa vn_protocol vkCreateSampler CS (type 70, sType 31). Remote 2026-10-02 7/12/588, Enable=1 2813 cells / 964 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vrp.sv` | untracked | `eebeaa94e343529b3a0133f05dac410ed739e681` | Mesa vn_protocol vkCreateRenderPass CS (type 82, sType 38). Remote 2026-10-02 7/12/588, Enable=1 2814 cells / 964 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vgp.sv` | untracked | `76b53911ef3355abbe5fc3ad0f8e26d448f64d69` | Mesa vn_protocol vkCreateGraphicsPipelines CS (type 65, sType 28). Remote 2026-10-02 7/12/730, Enable=1 3820 cells / 1412 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vfb.sv` | untracked | `92158d64977025c82648edb58d46a4eda36e466c` | Mesa vn_protocol vkCreateFramebuffer CS (type 80, sType 37). Remote 2026-10-02 7/12/610, Enable=1 3131 cells / 1092 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vrb.sv` | untracked | `9b66d3572f7a83f4af3951065fb4ff5caea4edc2` | Mesa vn_protocol vkCmdBeginRenderPass CS (type 133, sType 43). Remote 2026-10-02 7/12/574, Enable=1 2907 cells / 1028 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vdw.sv` | untracked | `b71873ab9da731fde1a516498444e02fabbcb227` | Mesa vn_protocol vkCmdDraw CS (type 106). Remote 2026-10-02 7/12/350, Enable=1 1788 cells / 676 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vre.sv` | untracked | `5ff63074945e945ea81a8538154a39c7b8c9500b` | Mesa vn_protocol vkCmdEndRenderPass CS (type 135). Remote 2026-10-02 7/12/302, Enable=1 1589 cells / 644 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vvb.sv` | untracked | `7a417e231c2c7cabe77431c96257f518faca660e` | Mesa vn_protocol vkCmdBindVertexBuffers CS (type 105). Remote 2026-10-02 7/12/372, Enable=1 1914 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vib.sv` | untracked | `6c73e4ee0d88e086c86a9804d3f33f87de21e4cf` | Mesa vn_protocol vkCmdBindIndexBuffer CS (type 104). Remote 2026-10-02 7/12/360, Enable=1 1879 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vdi.sv` | untracked | `d0577bae2845a885aab2797ad49648ec5c12f2f1` | Mesa vn_protocol vkCmdDrawIndexed CS (type 107). Remote 2026-10-02 7/12/362, Enable=1 1822 cells / 676 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vvp.sv` | untracked | `b2abb2f844661e7f25702aab9c1a830cc3fc4e82` | Mesa vn_protocol vkCmdSetViewport CS (type 94). Remote 2026-10-02 7/12/422, Enable=1 1932 cells / 676 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vsi.sv` | untracked | `8cd8ae4290e9d14cdf03f21d671e63b09710cdb7` | Mesa vn_protocol vkCmdSetScissor CS (type 95). Remote 2026-10-02 7/12/398, Enable=1 1856 cells / 676 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vpb.sv` | untracked | `56c1fc160de445e63e6bd65dcc1c5370e7c29d80` | Mesa vn_protocol vkCmdPipelineBarrier CS (type 126). Remote 2026-10-02 7/12/374, Enable=1 1855 cells / 676 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vns.sv` | untracked | `8b0e3730a6ff470febc98d2fe116a3d4c1ac5a78` | Mesa vn_protocol vkCmdNextSubpass CS (type 134). Remote 2026-10-02 7/12/314, Enable=1 1685 cells / 676 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vdf.sv` | untracked | `15e683d2bafabbe34d03c8e447c38eec550b5c19` | Mesa vn_protocol vkDestroyFramebuffer CS (type 81). Remote 2026-10-02 7/12/350, Enable=1 1846 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vdx.sv` | untracked | `5d177dded33d199f3535b2f571fbb2a614bf049f` | Mesa vn_protocol vkDestroyImageView CS (type 58). Remote 2026-10-02 7/12/350, Enable=1 1847 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vdk.sv` | untracked | `830eb941610a7305f7621ccaa6b5c99b91a9f39a` | Mesa vn_protocol vkDestroySampler CS (type 71). Remote 2026-10-02 7/12/350, Enable=1 1847 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vdr.sv` | untracked | `6fa85a23f5e9ad51b470a850995166d664484685` | Mesa vn_protocol vkDestroyRenderPass CS (type 83). Remote 2026-10-02 7/12/350, Enable=1 1847 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vdb.sv` | untracked | `c4cfd14a1dd83a61041c8ce8f2db5047ed3825e7` | Mesa vn_protocol vkDestroyBuffer CS (type 51). Remote 2026-10-02 7/12/350, Enable=1 1847 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vdg.sv` | untracked | `a393b071ebdf1bf06fcc2ad929512152f0b4bb8e` | Mesa vn_protocol vkDestroyImage CS (type 55). Remote 2026-10-02 7/12/350, Enable=1 1848 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vfe.sv` | untracked | `914c9c92092730d46155f1534706751fdd4e40fd` | Mesa vn_protocol vkFreeMemory CS (type 22). Remote 2026-10-02 7/12/350, Enable=1 1846 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vdm.sv` | untracked | `150673d38be486cf6dbaa0682f31ddb292cf4096` | Mesa vn_protocol vkDestroyShaderModule CS (type 60). Remote 2026-10-02 7/12/350, Enable=1 1847 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vdp.sv` | untracked | `a0e7a56bcb3ff14f7f78f638d0c2ea13a821f7a7` | Mesa vn_protocol vkDestroyPipeline CS (type 67). Remote 2026-10-02 7/12/350, Enable=1 1846 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vdy.sv` | untracked | `e53dfa404545ce470ad8cfeccf0e881314b33891` | Mesa vn_protocol vkDestroyPipelineLayout CS (type 69). Remote 2026-10-02 7/12/350, Enable=1 1846 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vdt.sv` | untracked | `1785730b667ca76c6ce71bb71176a0f1dfb23420` | Mesa vn_protocol vkDestroyDescriptorSetLayout CS (type 73). Remote 2026-10-02 7/12/350, Enable=1 1846 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vdq.sv` | untracked | `9244c56b3e95f8457c99d3fcca536bb9dacf5cd5` | Mesa vn_protocol vkDestroyDescriptorPool CS (type 75). Remote 2026-10-02 7/12/350, Enable=1 1847 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vfs.sv` | untracked | `72b842f1c1040031e847faab742335531c66c9e0` | Mesa vn_protocol vkFreeDescriptorSets CS (type 78). Remote 2026-10-02 7/12/372, Enable=1 2043 cells / 772 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vrc.sv` | untracked | `e0af93d7c4ad994c4b6fde367cc058bccb388129` | Mesa vn_protocol vkResetCommandBuffer CS (type 92). Remote 2026-10-02 7/12/314, Enable=1 1622 cells / 644 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vfc.sv` | untracked | `82e5a7de17249008e446328267109b28faf21822` | Mesa vn_protocol vkFreeCommandBuffers CS (type 89). Remote 2026-10-02 7/12/372, Enable=1 2043 cells / 772 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vdd.sv` | untracked | `a8dfdbdb95c42f6a52763a2b227e24482f4cf8dd` | Mesa vn_protocol vkDestroyDevice CS (type 12). Remote 2026-10-02 7/12/328, Enable=1 1652 cells / 644 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vpc.sv` | untracked | `746ff3614e4903a63253d86e3b4145c593b7ba29` | Mesa vn_protocol vkResetCommandPool CS (type 87). Remote 2026-10-02 7/12/336, Enable=1 1816 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vdc.sv` | untracked | `a16f4b5477fabb38997971cbc42f779a10acb74d` | Mesa vn_protocol vkDestroyCommandPool CS (type 86). Remote 2026-10-02 7/12/350, Enable=1 1847 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vdn.sv` | untracked | `401cfe324903e9aeaf8ec211d1bda8c3eed94a18` | Mesa vn_protocol vkDestroyInstance CS (type 1). Remote 2026-10-02 7/12/328, Enable=1 1651 cells / 644 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vgf.sv` | untracked | `069b14a2490fc866c40c70b300f06100696cd1a0` | Mesa vn_protocol vkGetPhysicalDeviceFormatProperties CS (type 4). Remote 2026-10-02 7/12/340, Enable=1 1750 cells / 676 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vip.sv` | untracked | `b122f2dd7fce98702bfbf6c63e0609f91309cdb7` | Mesa vn_protocol vkGetPhysicalDeviceImageFormatProperties CS (type 5). Remote 2026-10-02 7/12/388, Enable=1 1885 cells / 676 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vxe.sv` | untracked | `15c83146b081e097f942742f7abcf64aeb94b9f5` | Mesa vn_protocol vkEnumerateDeviceExtensionProperties CS (type 14). Remote 2026-10-02 7/12/366, Enable=1 1750 cells / 644 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vrd.sv` | untracked | `965fc020c57e1e623cc443d6ac88c3b1eba5b0ce` | Mesa vn_protocol vkResetDescriptorPool CS (type 76). Remote 2026-10-02 7/12/336, Enable=1 1814 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vie.sv` | untracked | `026946d2b6449bc7ad0532ecb60908f14b67fbc5` | Mesa vn_protocol vkEnumerateInstanceExtensionProperties CS (type 13). Remote 2026-10-02 7/12/344, Enable=1 1557 cells / 580 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vwl.sv` | untracked | `bd5b40db78ea2c733ed4b4971012fe3530b78d93` | Mesa vn_protocol vkDeviceWaitIdle CS (type 20). Remote 2026-10-02 7/12/300, Enable=1 1587 cells / 644 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vsl.sv` | untracked | `8dd5355999295e367e4bff75897f8a47e879d880` | Mesa vn_protocol vkGetImageSubresourceLayout CS (type 56). Remote 2026-10-02 7/12/388, Enable=1 1945 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vrg.sv` | untracked | `8d08ce29779f70e30d0d33f1d53cfbdf921cbecc` | Mesa vn_protocol vkGetRenderAreaGranularity CS (type 84). Remote 2026-10-02 7/12/350, Enable=1 1845 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vlw.sv` | untracked | `34c62c1e84d74538cc2363521c5aec55fc0af2d6` | Mesa vn_protocol vkCmdSetLineWidth CS (type 96). Remote 2026-10-02 7/12/312, Enable=1 1627 cells / 644 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vzb.sv` | untracked | `7aded6c06207faccf59d38ac83e4147d4c4dcd2a` | Mesa vn_protocol vkCmdSetDepthBias CS (type 97). Remote 2026-10-02 7/12/336, Enable=1 1687 cells / 644 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vbc.sv` | untracked | `6cc455cc231c23800abff09797d42d762933864b` | Mesa vn_protocol vkCmdSetBlendConstants CS (type 98). Remote 2026-10-02 7/12/348, Enable=1 1720 cells / 644 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vbo.sv` | untracked | `aecfe7a7aec42ff76fabbedc1aedd5dc4bdbc07a` | Mesa vn_protocol vkCmdSetDepthBounds CS (type 99). Remote 2026-10-02 7/12/324, Enable=1 1662 cells / 644 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vcm.sv` | untracked | `2c933c3841f638a8420d097072124f414949f3e1` | Mesa vn_protocol vkCmdSetStencilCompareMask CS (type 100). Remote 2026-10-02 7/12/324, Enable=1 1688 cells / 644 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vwm.sv` | untracked | `92a475fc7bfd09e86920f93e039d4ddea6da98e0` | Mesa vn_protocol vkCmdSetStencilWriteMask CS (type 101). Remote 2026-10-02 7/12/324, Enable=1 1689 cells / 644 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vrf.sv` | untracked | `b0dfec49bd83effd3280e6fc6df9d879fde5d9fa` | Mesa vn_protocol vkCmdSetStencilReference CS (type 102). Remote 2026-10-02 7/12/324, Enable=1 1657 cells / 644 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vcc.sv` | untracked | `8e786dc4cecdba818d382e81d4b95a8af2883754` | Mesa vn_protocol vkCmdCopyBuffer CS (type 112). Remote 2026-10-02 8/13/505, Enable=1 2205 cells / 772 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vcy.sv` | untracked | `a2e479475feec16ec9fdc74131c2560ffbcb6f76` | Mesa vn_protocol vkCmdCopyImage CS (type 113). Remote 2026-10-02 8/13/785, Enable=1 3714 cells / 1284 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vbl.sv` | untracked | `3ff865c1ab7239de2c9a9a9c29b3bb524da7ef63` | Mesa vn_protocol vkCmdBlitImage CS (type 114). Remote 2026-10-02 8/13/839, Enable=1 3849 cells / 1284 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vbt.sv` | untracked | `529ee0cdcfac361c0e3d5dc4a6a19da36c259eeb` | Mesa vn_protocol vkCmdCopyBufferToImage CS (type 115). Remote 2026-10-02 8/13/727, Enable=1 3577 cells / 1284 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vic.sv` | untracked | `b154d2ffe3000d4fff7a534c18c209105602b599` | Mesa vn_protocol vkCmdCopyImageToBuffer CS (type 116). Remote 2026-10-02 8/13/727, Enable=1 3575 cells / 1284 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vub.sv` | untracked | `e14980f5081d1134d1de9ccc1e9ef9f013817740` | Mesa vn_protocol vkCmdUpdateBuffer CS (type 117). Remote 2026-10-02 8/13/421, Enable=1 1947 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vfl.sv` | untracked | `ff3c50ea3bf3d6696efd00e095fcc32d445a7897` | Mesa vn_protocol vkCmdFillBuffer CS (type 118). Remote 2026-10-02 8/13/419, Enable=1 1947 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vcl.sv` | untracked | `5551bed1111e5b7addd4ba28d73c8999fd020bbb` | Mesa vn_protocol vkCmdClearColorImage CS (type 119). Remote 2026-10-02 8/13/671, Enable=1 3219 cells / 1220 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vio.sv` | untracked | `2bc971fbf04b1edf3358d79ed0d9d0d8d6b0ac48` | Mesa vn_protocol vkCmdDrawIndirect CS (type 108). Remote 2026-10-02 8/13/405, Enable=1 1915 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vix.sv` | untracked | `f1ccda74f4aa1473213405c109558369c28e3231` | Mesa vn_protocol vkCmdDrawIndexedIndirect CS (type 109). Remote 2026-10-02 8/13/405, Enable=1 1917 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vds.sv` | untracked | `d546e37f9154c7d0d543026c098359d7aac5cb6c` | Mesa vn_protocol vkCmdClearDepthStencilImage CS (type 120). Remote 2026-10-02 8/13/685, Enable=1 3158 cells / 1220 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vat.sv` | untracked | `217035e74078ae29e1382e166288b7d2c923a482` | Mesa vn_protocol vkCmdClearAttachments CS (type 121). Remote 2026-10-02 8/13/659, Enable=1 3123 cells / 1156 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vin.sv` | untracked | `3a373baaa11d9fe33787ccc005ac6f4be3a9d4d7` | Mesa vn_protocol vkCmdDispatchIndirect CS (type 111). Remote 2026-10-02 8/13/379, Enable=1 1849 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vrs.sv` | untracked | `c73f8143f6c7a873d3670f6176205a3d6340a7ca` | Mesa vn_protocol vkCmdResolveImage CS (type 122). Remote 2026-10-02 8/13/783, Enable=1 3715 cells / 1284 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vgs.sv` | untracked | `c556f7dfe057c42079bd5cf667c04897c367bbc8` | Mesa vn_protocol vkGetFenceStatus CS (type 38). Remote 2026-10-02 8/13/377, Enable=1 1781 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vwf.sv` | untracked | `0e2f548deb6826bfb21d3932b812517048dc204f` | Mesa vn_protocol vkWaitForFences CS (type 39). Remote 2026-10-02 8/13/405, Enable=1 1915 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vfr.sv` | untracked | `dd1cef9d5fbafdb94de32ed4ff6ccd7739b76451` | Mesa vn_protocol vkResetFences CS (type 37). Remote 2026-10-02 8/13/391, Enable=1 1815 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/apu/g6lc_apu_vfn.sv` | untracked | `d1ef9ef56517986ffbca04ea4e1d520ec99e9e85` | Mesa vn_protocol vkDestroyFence CS (type 36). Remote 2026-10-02 8/13/379, Enable=1 1845 cells / 708 FFs. ApuCfg.NumCapsets stays 0. Not in `g6lc_apu_sys`. |
| `corev_apu/tb/ariane_testharness.sv` | tracked, modified | `7c423c22acabe3426a0343c2619344fc169cec3a` | Under `G6LC_APU`, compositor DMA joins AI onto `slave[2]` (`NrSlaves` stays 3). `ApuHarness.DmaReadEn=0`. |

Checked DMA/storage/lease mechanisms are reuse candidates, not automatically
qualified on the current fabric. Coverage/interpolation/sampling experiments
are generalizable prototypes only where changed inputs demonstrably drive the
result. Expected-pixel logic belongs in an independent test oracle. Remaining
leaf families and missing/unverifiable historical artifacts still need inventory;
no blanket production classification or session-wide audit closure is claimed.

### Missing end-to-end edges

```text
stock client -> negotiated queue -> checked descriptor/command DMA
  -> immutable program + generational context/resource tables
  -> protected shader LSU + hardware draw/compute scheduler
  -> vertex/coverage/interpolation/sample/fragment/depth/blend
  -> common memory-backed surface + visibility/fence completion
  -> response bytes -> used element -> used index -> interrupt
```

This is a REQUIRED path, not an existing instantiate graph. Queue relocation,
legal NEXT chains, index wrap/batching and repeated submissions must work without
fixed heads/addresses. Objects and backing stay pinned until child work drains;
reset cannot publish stale work or release live DMA. Real cache visibility and
hardware-off/fault negative controls are required before G0/A5.

For the stock Venus candidate, add genuine blob/host-visible mapping, context
initialization, protocol replies, synchronization and runtime shader semantics.
No custom resident service, compiler firmware, embedded CPU or bridge daemon can
be required by the strict final endpoint. Hardware Venus/SPIR-V remains a
feasibility candidate, not a selected/proven architecture. The bounded prototype
must receive a runtime-selected module from a stock client, retain and execute
it with independent input mutations, and expose controller/storage costs.

The retained 64×64 GLES2 readback is one regression, not the product ceiling.
`DISPLAY.md`'s named “API-neutral APU: P0 wire audit” and “Reduced P0 device
contract (empirical freeze)” are the source anchors; the old “section 7” pointer
is not valid. Reconcile the exact probe variant/capture with the BIOS 960-byte
stream before selecting golden pixels. No new image or stock-client test ran.

### Stock Venus handshake (required device-side behaviors)

These are kernel/UAPI observations, not a boot test. Guest Mesa Venus
(`libvulkan_virtio.so`) additionally serializes `vk*` onto a host-visible
blob ring; SPIR-V arrives as `vkCreateShaderModule` `pCode`.

```text
stock Mesa Venus ICD
  -> GET_PARAM: 3D_FEATURES, CAPSET_QUERY_FIX(=1 in driver),
     RESOURCE_BLOB, HOST_VISIBLE, CONTEXT_INIT, capset_id_mask bit 4
  -> GET_CAPSET_INFO / GET_CAPSET  id=VIRTIO_GPU_CAPSET_VENUS (4)
  -> CTX_CREATE with context_init capset-id 4
  -> RESOURCE_CREATE_BLOB + MAP into SHM id 1 (length != ~0)
  -> vn_ring in that blob: producer/consumer indices, encoded vk*
  -> SUBMIT_3D / notify; used-ring response + fence_id after work
  -> immutable SPIR-V + generational Vk* objects in hardware
```

Missing on this RTL: DISPLAY.md identity and advertised capsets.
Private `g6lc_apu_gcs` grants Venus GET_CAPSET/INFO on the queue path;
`NumCapsets` stays 0. Private `g6lc_apu_qdn` publishes WRITE response,
`used.idx`, and ISR after one AvailNext walk.
`FeatureVirgl` stays illegal
until a truthful 3D datapath exists; kernel 3D_FEATURES is that same
virtio bit (`virtgpu_kms.c:162–164`). Do not advertise it for a parser.

### Bounded SPIR-V-subset prototype (P0, 2026-10-01)

```text
diagnostic TB client
    ==> program bytes + two integer inputs + IRQ
        --> SpirvSubset (spirv)     128-word immutable store, GLCompute IAdd/IMul
            --? ApuSys             not instantiated
            --? ExecCluster (exec) native APU_EX, 16-word IMEM, not SPIR-V
```

`SpirvEn` defaults to 0. Enable=0 is quiet. A second program store after
commit faults until reset. The same committed module mutates its output when
the two inputs change (2+3=5, then 4+5=9; after reset 4×5=20). Remote
2026-10-01 `tb_g6lc_apu_spirv` 8 cases / 15 checks / 348 cycles, errors=0.
Enable=0: 16 ports / 0 cells. Enable=1: 35938 cells / 5365 flip-flops, no
latches. **Residual-runtime ledger:** this TB is a diagnostic client on the
test transport. It is not a Mesa ICD, not virglrenderer `vkr`, not firmware,
not a hidden hart, and not a stock guest. Product still requires unchanged
Ubuntu kernel/Mesa/Vulkan loader. `FeatureVirgl` stays illegal.

### Reusable NEXT chain walker (P0, 2026-10-01)

```text
diagnostic TB client
    ==> programmed desc_base / head / queue_size / max_chain
        --> NextChain (chain)      16-byte virtq_desc, bounded NEXT
            ==> rd 16B at base+idx*16
            --? AvailDescriptor (avail)   still faults NEXT
            --? GuestNextWalk (gnw)       frozen scene table
            --? ApuSys
```

`ChainEn` defaults to 0. Relocating the table base and starting at head 2
changes the first/last payload windows. INDIRECT, a self-loop, OOB next,
overlong chain, and a misaligned base fault; a fault issues no further
read. Remote 2026-10-01 `tb_g6lc_apu_chain` 9 cases / 27 checks / 73
cycles, errors=0. Enable=0: 19 ports / 0 cells. Enable=1: 1917 cells /
503 flip-flops, no latches. `g6lc_apu_vgpu_avail` was not edited.
`FeatureVirgl` stays illegal.

### ChainDma join (P0, 2026-10-01)

```text
diagnostic TB client
    ==> programmed desc_base / mapping
        --> ChainDma (cdma)
            --> NextChain (chain)
            --> DmaRead ==> AXI AR/R of 16-byte virtq_desc
            --? ApuSys
            --? TestharnessAttach   dma_req still unconnected
```

`CdmaEn` defaults to 0. Relocating the table and starting at head 2 still
changes the first/last payload windows. INDIRECT is one AR; an address
outside the mapping or an invalid mapping issues none. Remote 2026-10-01
`tb_g6lc_apu_cdma` 7 cases / 20 checks / 153 cycles, errors=0. Enable=0:
14 ports / 0 cells. Enable=1: 8471 cells / 1150 flip-flops, no latches.
`g6lc_apu_vgpu_avail` was not edited. `FeatureVirgl` stays illegal.

### HOST_VISIBLE SHM, blob, CONTEXT_INIT (P0, 2026-10-01)

```text
guest virtio-mmio
    ==> SHM_SEL / SHM_LEN / SHM_BASE
        --> HostVisibleShm (shm)     id 1 at 64'h82000000 / 1 MiB when ShmEn
diagnostic TB client
    ==> blob create / map / CTX_CREATE context_init
        --> HostVisible (hvis)
            --? HostVisibleShm (shm)
            --? ApuSys
```

`ShmEn`/`HvisEn` default to 0. Other SHM ids stay all-ones. Virgl capset 1
faults. `RESOURCE_BLOB` and `CONTEXT_INIT` stay outside `APU_IMPL_FEATURES`.
Remote 2026-10-01 `tb_g6lc_apu_hvis` 7 cases / 18 checks / 51 cycles,
errors=0. Enable=0: 9 ports / 0 cells. Enable=1: 1386 cells / 197
flip-flops. P1 `tb_g6lc_apu_virtio_mmio` 4240 checks still PASS.
`FeatureVirgl` stays illegal.

### Hardware Venus CS prototype (P0, 2026-10-01)

```text
diagnostic TB client
    ==> HOST_VISIBLE ring producer/consumer
        --> VenusCs (vncs)
            --> SpirvSubset (spirv)     CREATE_MODULE + DISPATCH
            --? HostVisible (hvis)
            --? ApuSys
```

`VncsEn` defaults to 0. CREATE_MODULE loads SPIR-V; DISPATCH runs it and
stores the integer result in the ring. The same committed module mutates
2+3=5 then 4+5=9. Unknown opcode faults. This ring is a diagnostic
transport, not Mesa `vn_protocol`. Remote 2026-10-01 `tb_g6lc_apu_vncs`
4 cases / 10 checks / 341 cycles, errors=0. Enable=0: 13 ports / 0 cells.
Enable=1: 74601 cells / 9601 flip-flops. `FeatureVirgl` stays illegal.

### Venus capset wire (P0, 2026-10-01)

```text
diagnostic TB client
    ==> GET_CAPSET_INFO / GET_CAPSET id=4
        --> VenusCapset (vcap)     160-byte virgl_renderer_capset_venus
            --? CapsetGet (cap)    virgl id 1 still refused
            --? ApuSys
```

`VcapEn` defaults to 0. INFO returns max_version 1 and max_size 160.
GET returns wire format 1, VK 1.1 XML, a valid empty extension mask, and
`use_guest_vram=1`. Virgl id 1 faults. `NumCapsets` stays 0.
Remote 2026-10-01 `tb_g6lc_apu_vcap` 5 cases / 56 checks / 28 cycles,
errors=0. Enable=0: 11 ports / 0 cells. Enable=1: 222 cells / 4
flip-flops. `FeatureVirgl` stays illegal.

### Stock vn_ring layout (P0, 2026-10-01)

```text
diagnostic TB client
    ==> Mesa vn_ring_layout SHM
        --> VenusRing (vnring)     head@0 tail@64 status@128 buf@192
            --? VenusCs (vncs)     diagnostic CREATE/DISPATCH
            --? ApuSys
```

`VnringEn` defaults to 0. head/tail are byte seqnos; consume advances
tail and writes idle status. Wrap, empty, unaligned, and oversize are
covered. This is stock ring geometry, not `vn_protocol` vk* encode.
Remote 2026-10-01 `tb_g6lc_apu_vnring` 6 cases / 13 checks / 59 cycles,
errors=0. Enable=0: 12 ports / 0 cells. Enable=1: 13443 cells / 4228
flip-flops. `FeatureVirgl` stays illegal.

### Testharness DMA fabric join (P0, 2026-10-01)

```text
TestharnessLoad dma_req_o
    ==> TestharnessDma (tdma)     APU A wins over AI B
        ==> xbar slave[2]
            --? ApuSys
```

`TdmaEn` defaults to 0. Testharness instantiates the join with Enable=1
under `+define+G6LC_APU` so AI still reaches `slave[2]`.
`ApuHarness.DmaReadEn=0` keeps the APU side idle. `NrSlaves` stays 3.
Island-port builds give APU `slave[2]` alone. Not in `g6lc_apu_sys`.
Remote 2026-10-01 `tb_g6lc_apu_tdma` 4 cases / 10 checks / 18 cycles,
errors=0. Enable=0: 8 ports / 0 cells. Enable=1: 321 cells / 4
flip-flops. `FeatureVirgl` stays illegal.

### Mesa vn_protocol vkCreateShaderModule (P0, 2026-10-01)

```text
diagnostic TB client
    ==> Mesa vn_encode_vkCreateShaderModule CS
        --> VenusEncode (vnenc)     type 59, sType 16, pCode, module id
            --? VenusRing (vnring)
            --? VenusCs (vncs)
            --? ApuSys
```

`VnencEn` defaults to 0. GENERATE_REPLY writes type + VK_SUCCESS +
handle. vkCreateInstance, null info, and empty pCode fault. Remote
2026-10-01 `tb_g6lc_apu_vnenc` 6 cases / 13 checks / 302 cycles,
errors=0. Enable=0: 12 ports / 0 cells. Enable=1: 36136 cells / 6437
flip-flops. `FeatureVirgl` stays illegal.

### VenusPath vn_ring into SpirvSubset (P0, 2026-10-01)

```text
diagnostic TB client
    ==> Mesa vn_ring_layout buffer_size 512
        --> VenusPath (vnp)
            --> VenusEncode (vnenc)     vkCreateShaderModule
            --> SpirvSubset (spirv)     retain + mutate 2+3=5, 4+5=9
            --? VenusRing (vnring)
            --? ApuSys
```

`VnpEn` defaults to 0. Empty ring is quiet. vkCreateInstance and
unaligned head fault. Remote 2026-10-01 `tb_g6lc_apu_vnp` 6 cases /
11 checks / 768 cycles, errors=0. Enable=0: 16 ports / 0 cells.
Enable=1: 100179 cells / 20112 flip-flops. `FeatureVirgl` stays illegal.

### AvailNext virtq_avail into NextChain (P0, 2026-10-01)

```text
diagnostic TB client
    ==> virtq_avail.idx + ring[device_idx]
        --> AvailNext (avn)
            --> NextChain (chain)     NEXT followed
            --? AvailDescriptor (avail)
            --? ApuSys
```

`AvnEn` defaults to 0. Empty when idx equals the device index. 16-bit
wrap and two-index batching. INDIRECT and unaligned avail base fault.
Remote 2026-10-01 `tb_g6lc_apu_avn` 7 cases / 13 checks / 97 cycles,
errors=0. Enable=0: 19 ports / 0 cells. Enable=1: 3521 cells / 988
flip-flops. `FeatureVirgl` stays illegal.

### AvailUsed virtq_used publication (P0, 2026-10-01)

```text
diagnostic TB client
    ==> virtq_avail then virtq_used
        --> AvailUsed (avu)
            --> AvailNext (avn)
            ==> used elem then used.idx
            --? ApuSys
```

`AvuEn` defaults to 0. EMPTY writes nothing. INDIRECT issues no used
store. Remote 2026-10-01 `tb_g6lc_apu_avu` 5 cases / 9 checks / 82
cycles, errors=0. Enable=0: 27 ports / 0 cells. Enable=1: 4754 cells /
1438 flip-flops. `FeatureVirgl` stays illegal.

### UsedIrq virtio used-buffer ISR (P0, 2026-10-01)

```text
diagnostic TB client
    ==> AvailUsed consume
        --> UsedIrq (uir)
            --> AvailUsed (avu)
            ==> ISR bit 0, ack lowers irq
            --? ApuSys
```

`UirEn` defaults to 0. EMPTY and INDIRECT raise no IRQ. Remote
2026-10-01 `tb_g6lc_apu_uir` 4 cases / 9 checks / 63 cycles,
errors=0. Enable=0: 31 ports / 0 cells. Enable=1: 3947 cells / 1141
flip-flops. `FeatureVirgl` stays illegal.

### CmdSnap immutable first-payload window (P0, 2026-10-01)

```text
diagnostic TB client
    ==> AvailNext then first payload read
        --> CmdSnap (cms)
            --> AvailNext (avn)
            ==> 8-word SRAM, survives mutation
            --? ApuSys
```

`CmsEn` defaults to 0. A second snapshot faults until reset. EMPTY
stores nothing. Remote 2026-10-01 `tb_g6lc_apu_cms` 4 cases / 10
checks / 45 cycles, errors=0. Enable=0: 21 ports / 0 cells. Enable=1:
4227 cells / 1201 flip-flops. `FeatureVirgl` stays illegal.

### PayResp WRITE-window response (P0, 2026-10-01)

```text
diagnostic TB client
    ==> programmed OK_NODATA bytes
        --> PayResp (prs)
            --> AvailNext (avn)
            ==> WRITE last_addr
            --? ApuSys
```

`PrsEn` defaults to 0. EMPTY writes nothing. Length mismatch faults.
Remote 2026-10-01 `tb_g6lc_apu_prs` 4 cases / 8 checks / 71 cycles,
errors=0. Enable=0: 31 ports / 0 cells. Enable=1: 3833 cells / 1234
flip-flops. `FeatureVirgl` stays illegal.

### QueueDone response then used.idx then ISR (P0, 2026-10-01)

```text
diagnostic TB client
    ==> one AvailNext
        --> QueueDone (qdn)
            --> AvailNext (avn)
            ==> WRITE, used elem, used.idx, ISR bit 0
            --? ApuSys
```

`QdnEn` defaults to 0. EMPTY writes nothing. Remote 2026-10-01
`tb_g6lc_apu_qdn` 3 cases / 8 checks / 52 cycles, errors=0. Enable=0:
35 ports / 0 cells. Enable=1: 5140 cells / 1453 flip-flops.
`FeatureVirgl` stays illegal.

### GrantCapset Venus GET_CAPSET on the queue (P0, 2026-10-01)

```text
diagnostic TB client
    ==> GET_CAPSET_INFO / GET_CAPSET on AvailNext
        --> GrantCapset (gcs)
            --> AvailNext (avn)
            --> VenusCapset (vcap)
            ==> WRITE capset, used elem, used.idx, ISR bit 0
            --? ApuSys
```

`GcsEn` defaults to 0. Virgl id 1 faults. EMPTY writes nothing.
`NumCapsets` stays 0. Remote 2026-10-01 `tb_g6lc_apu_gcs` 5 cases /
12 checks / 116 cycles, errors=0. Enable=0: 31 ports / 0 cells.
Enable=1: 9379 cells / 1813 flip-flops. `FeatureVirgl` stays illegal.

### VenusDispatch Mesa vn_protocol vkCmdDispatch (P0, 2026-10-01)

```text
diagnostic TB client
    ==> vkCmdDispatch CS type 110
        --> VenusDispatch (vnd)
            --? VenusEncode (vnenc)
            --? VenusPath (vnp)
            --? ApuSys
```

`VndEn` defaults to 0. GENERATE_REPLY writes the command type.
vkCreateShaderModule, vkCreateInstance, a null command buffer, and
`vkCmdDispatchIndirect` fault. Remote 2026-10-01 `tb_g6lc_apu_vnd`
7 cases / 12 checks / 145 cycles, errors=0. Enable=0: 12 ports /
0 cells. Enable=1: 1729 cells / 741 flip-flops. `FeatureVirgl`
stays illegal.

### GenHandle generational object table (P0, 2026-10-01)

```text
diagnostic TB client
    ==> alloc / lookup / pin / unpin / retire
        --> GenHandle (gnh)
            --? HostVisible (hvis)
            --? VenusPath (vnp)
            --? ApuSys
```

`GnhEn` defaults to 0. Stale generation after retire-and-realloc
faults. Remote 2026-10-01 `tb_g6lc_apu_gnh` 6 cases / 25 checks /
122 cycles, errors=0. Enable=0: 9 ports / 0 cells. Enable=1: 3737
cells / 565 flip-flops. `FeatureVirgl` stays illegal.

### HandleDispatch published cmdbuf on vkCmdDispatch (P0, 2026-10-01)

```text
diagnostic TB client
    ==> alloc CMDBUF, then vkCmdDispatch CS
        --> HandleDispatch (hdp)
            --> GenHandle (gnh)
            --> VenusDispatch (vnd)
            --? ApuSys
```

`HdpEn` defaults to 0. Stale generation, wrong kind, and
vkCreateInstance fault. Remote 2026-10-01 `tb_g6lc_apu_hdp` 6 cases
/ 11 checks / 146 cycles, errors=0. Enable=0: 13 ports / 0 cells.
Enable=1: 5979 cells / 1491 flip-flops. `FeatureVirgl` stays illegal.

### HandlePath MODULE publish and CMDBUF dispatch (P0, 2026-10-01)

```text
diagnostic TB client
    ==> vkCreateShaderModule CS, then vkCmdDispatch CS
        --> HandlePath (hph)
            --> VenusEncode (vnenc)
            --> GenHandle (gnh)
            --> VenusDispatch (vnd)
            --? ApuSys
```

`HphEn` defaults to 0. Duplicate live module ids, a MODULE used as
a command buffer, and vkCreateInstance fault. Remote 2026-10-01
`tb_g6lc_apu_hph` 6 cases / 11 checks / 207 cycles, errors=0.
Enable=0: 13 ports / 0 cells. Enable=1: 41062 cells / 7481
flip-flops. `FeatureVirgl` stays illegal.

### HandleRun SpirvSubset kick on published handles (P0, 2026-10-01)

```text
diagnostic TB client
    ==> vkCreateShaderModule CS, then vkCmdDispatch CS + in_a/in_b
        --> HandleRun (hrn)
            --> VenusEncode (vnenc)
            --> GenHandle (gnh)
            --> VenusDispatch (vnd)
            --> SpirvSubset (spirv)
            --? ApuSys
```

`HrnEn` defaults to 0. Dispatch before create, a MODULE used as a
command buffer, and vkCreateInstance fault. Remote 2026-10-01
`tb_g6lc_apu_hrn` 6 cases / 11 checks / 720 cycles, errors=0.
Enable=0: 17 ports / 0 cells. Enable=1: 77619 cells / 13025
flip-flops. `FeatureVirgl` stays illegal.

### RunDone result WRITE then used.idx then ISR (P0, 2026-10-01)

```text
diagnostic TB client
    ==> HandleRun dispatch, then used ring
        --> RunDone (rdn)
            --> HandleRun (hrn)
            ==> WRITE result, used elem, used.idx, ISR bit 0
            --? ApuSys
```

`RdnEn` defaults to 0. Create writes nothing. Remote 2026-10-01
`tb_g6lc_apu_rdn` 4 cases / 10 checks / 403 cycles, errors=0.
Enable=0: 27 ports / 0 cells. Enable=1: 77606 cells / 13138
flip-flops. `FeatureVirgl` stays illegal.

### QueueRun AvailNext CS into RunDone (P0, 2026-10-01)

```text
diagnostic TB client
    ==> virtq_avail + payload CS
        --> QueueRun (qrn)
            --> AvailNext (avn)
            --> RunDone (rdn)
            ==> WRITE result, used.idx, ISR
            --? ApuSys
```

`QrnEn` defaults to 0. CREATE writes nothing. EMPTY fetches nothing.
Remote 2026-10-01 `tb_g6lc_apu_qrn` 3 cases / 9 checks / 315 cycles,
errors=0. Enable=0: 33 ports / 0 cells. Enable=1: 84956 cells /
15231 flip-flops. `FeatureVirgl` stays illegal.

### QueueCmd GrantCapset or QueueRun (P0, 2026-10-01)

```text
diagnostic TB client
    ==> virtq_avail + GET_CAPSET/INFO or CREATE/DISPATCH
        --> QueueCmd (qcm)
            --> GrantCapset (gcs)
            --> QueueRun (qrn)
            --? ApuSys
```

`QcmEn` defaults to 0. `capset=1` writes the Venus blob then used.idx
and ISR. `capset=0` CREATE writes nothing; DISPATCH writes the SPIR-V
result then used.idx and ISR. Virgl id 1 faults. EMPTY fetches
nothing. `NumCapsets` stays 0. Remote 2026-10-01 `tb_g6lc_apu_qcm`
6 cases / 16 checks / 436 cycles, errors=0. Enable=0: 33 ports / 0
cells. Enable=1: 95709 cells / 17523 flip-flops. `FeatureVirgl`
stays illegal.

### QueueType AvailNext type word (P0, 2026-10-01)

```text
diagnostic TB client
    ==> virtq_avail + first command word
        --> QueueType (qty)
            --> AvailNext (avn)
            --> QueueCmd (qcm)
            --? ApuSys
```

`QtyEn` defaults to 0. GET_CAPSET/INFO selects GrantCapset.
CREATE/DISPATCH selects QueueRun. `gnh_only` skips the peek. EMPTY
fetches nothing. `NumCapsets` stays 0. Remote 2026-10-01
`tb_g6lc_apu_qty` 6 cases / 16 checks / 516 cycles, errors=0.
Enable=0: 33 ports / 0 cells. Enable=1: 100577 cells / 19138
flip-flops. `FeatureVirgl` stays illegal.

### VenusCtrl private config and QueueNotify (P0, 2026-10-01)

```text
diagnostic TB client
    ==> virtio_gpu_config.num_capsets / GET_CAPSET_INFO index 0
    ==> QueueNotify queue 0
        --> VenusCtrl (vct)
            --> VenusCapset (vcap)
            --> QueueType (qty)
            --? ApuSys
```

`VctEn` defaults to 0. Private face reads `num_capsets=1`. INFO
index 0 is Venus id 4. QueueNotify of control queue 0 fires
QueueType. Cursor queue 1 faults. `ApuCfg.NumCapsets` stays 0.
Remote 2026-10-01 `tb_g6lc_apu_vct` 9 cases / 22 checks / 566
cycles, errors=0. Enable=0: 33 ports / 0 cells. Enable=1: 101726
cells / 19670 flip-flops. `FeatureVirgl` stays illegal.

### QueuePump drain until EMPTY (P0, 2026-10-01)

```text
diagnostic TB client
    ==> QueueNotify queue 0 with two pending descriptors
        --> QueuePump (qpu)
            --> VenusCtrl (vct)
            --? ApuSys
```

`QpuEn` defaults to 0. QueueNotify drains until EMPTY. Two
GET_CAPSET_INFO descriptors publish twice. CFG and INFO pass through
once. `ApuCfg.NumCapsets` stays 0. Remote 2026-10-01
`tb_g6lc_apu_qpu` 10 cases / 24 checks / 735 cycles, errors=0.
Enable=0: 33 ports / 0 cells. Enable=1: 103215 cells / 20298
flip-flops. `FeatureVirgl` stays illegal.

### NotifyTake consume notify_pending (P0, 2026-10-01)

```text
virtio-mmio notify_pending[0]
    --> NotifyTake (ntk)
        --> QueuePump (qpu)
        ==> notify_clear[0]
        --? ApuSys
```

`NtkEn` defaults to 0. `arm` latches control-queue bases. A doorbell
before `arm` faults and still clears. Cursor `notify_pending[1]`
faults. `ApuCfg.NumCapsets` stays 0. Remote 2026-10-01
`tb_g6lc_apu_ntk` 6 cases / 12 checks / 160 cycles, errors=0.
Enable=0: 35 ports / 0 cells. Enable=1: 105435 cells / 21314
flip-flops. `FeatureVirgl` stays illegal.

### VqTake vq_state arms NotifyTake (P0, 2026-10-01)

```text
virtio-mmio vq_state[0] + notify_pending[0]
    --> VqTake (vqt)
        --> NotifyTake (ntk)
        ==> notify_clear[0]
        --? ApuSys
```

`VqtEn` defaults to 0. `vq_state[0]` supplies desc/avail/used/num.
A doorbell with `ready=0` faults and still clears. Cursor
`notify_pending[1]` faults. `ApuCfg.NumCapsets` stays 0. Remote
2026-10-01 `tb_g6lc_apu_vqt` 6 cases / 11 checks / 163 cycles,
errors=0. Enable=0: 37 ports / 0 cells. Enable=1: 108797 cells /
22150 flip-flops. `FeatureVirgl` stays illegal.

### VqAxi guest beats on 64-bit AXI (P0, 2026-10-01)

```text
VqAxi (vax)
    --> VqTake (vqt)
    ==> AXI SIZE=2 (4B) / SIZE=3 INCR
    --? TestharnessDma (tdma)
    --? ApuSys
```

`VaxEn` defaults to 0. 4-byte windows use SIZE=2; longer windows
use SIZE=3 INCR. The converter does not use `dma_read`. A doorbell
with `ready=0` faults and still clears. Cursor `notify_pending[1]`
faults. `ApuCfg.NumCapsets` stays 0. Remote 2026-10-01
`tb_g6lc_apu_vax` 6 cases / 11 checks / 287 cycles, errors=0.
Enable=0: 21 ports / 0 cells. Enable=1: 111519 cells / 22766
flip-flops. `FeatureVirgl` stays illegal.

### VenusAlloc vkAllocateCommandBuffers ALLOC CMDBUF (P0, 2026-10-01)

```text
VenusAlloc (vac)
    --> GenHandle (gnh)
    --? VenusDispatch (vnd)
    --? ApuSys
```

`VacEn` defaults to 0. Command type 88, sType 40, count 1, PRIMARY
level. GENERATE_REPLY writes type + VK_SUCCESS + the published
CMDBUF handle. Duplicate live object ids, `vkCreateShaderModule`,
`vkCreateInstance`, `vkCmdDispatch`, secondary level, a null info
pointer, a zero guest id, and a high-half handle fault.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-01 `tb_g6lc_apu_vac`
12 cases / 18 checks / 1016 cycles, errors=0. Enable=0: 12 ports /
0 cells. Enable=1: 4931 cells / 1569 flip-flops. `FeatureVirgl`
stays illegal.

### HandleAlloc ALLOC then dispatch LOOKUP (P0, 2026-10-01)

```text
HandleAlloc (hal)
    --> GenHandle (gnh)
    --> VenusDispatch (vnd)
    --? VenusAlloc (vac)
    --? ApuSys
```

`HalEn` defaults to 0. `vkAllocateCommandBuffers` ALLOCs CMDBUF on
the same table `vkCmdDispatch` looks up. Dispatch before allocate,
a MODULE handle, `vkCreateInstance`, and a duplicate live object id
fault. `ApuCfg.NumCapsets` stays 0. Remote 2026-10-01
`tb_g6lc_apu_hal` 8 cases / 15 checks / 479 cycles, errors=0.
Enable=0: 13 ports / 0 cells. Enable=1: 9178 cells / 2262
flip-flops. `FeatureVirgl` stays illegal.

### AllocRun ALLOC then CREATE then DISPATCH (P0, 2026-10-01)

```text
AllocRun (aru)
    --> VenusEncode (vnenc)
    --> GenHandle (gnh)
    --> VenusDispatch (vnd)
    --> SpirvSubset (spirv)
    --? HandleAlloc (hal)
    --? ApuSys
```

`AruEn` defaults to 0. `vkAllocateCommandBuffers` ALLOCs CMDBUF;
CREATE commits SPIR-V; DISPATCH kicks 2+3=5 then 4+5=9 on that
CMDBUF. Dispatch before create, dispatch after allocate with no
module, a MODULE handle as cmdbuf, and `vkCreateInstance` fault.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-01 `tb_g6lc_apu_aru`
7 cases / 13 checks / 914 cycles, errors=0. Enable=0: 17 ports /
0 cells. Enable=1: 81337 cells / 13796 flip-flops. `FeatureVirgl`
stays illegal.

### QueueAlloc AvailNext into AllocRun (P0, 2026-10-01)

```text
QueueAlloc (qal)
    --> AvailNext (avn)
    --> AllocRun (aru)
    ==> WRITE result then used then ISR
    --? QueueRun (qrn)
    --? ApuSys
```

`QalEn` defaults to 0. Guest CS ALLOC/CREATE/DISPATCH on one table.
DISPATCH writes the SPIR-V result, `used.idx`, and ISR. ALLOC and
CREATE write nothing. EMPTY fetches nothing. Dispatch before create
faults. `ApuCfg.NumCapsets` stays 0. Remote 2026-10-01
`tb_g6lc_apu_qal` 4 cases / 11 checks / 377 cycles, errors=0.
Enable=0: 33 ports / 0 cells. Enable=1: 86349 cells / 15155
flip-flops. `FeatureVirgl` stays illegal.

### QueueTypeAlloc type word selects GrantCapset or QueueAlloc (P0, 2026-10-01)

```text
QueueTypeAlloc (qta)
    --> AvailNext (avn)
    --> GrantCapset (gcs)
    --> QueueAlloc (qal)
    --? QueueType (qty)
    --? ApuSys
```

`QtaEn` defaults to 0. GET_CAPSET/INFO select Venus;
ALLOC/CREATE/DISPATCH select QueueAlloc. `ApuCfg.NumCapsets` stays
0. Remote 2026-10-01 `tb_g6lc_apu_qta` 6 cases / 16 checks / 547
cycles, errors=0. Enable=0: 33 ports / 0 cells. Enable=1: 100760
cells / 18263 flip-flops. `FeatureVirgl` stays illegal.

### VenusCtrlAlloc private CFG and QueueNotify into QueueTypeAlloc (P0, 2026-10-01)

```text
VenusCtrlAlloc (vca)
    --> VenusCapset (vcap)
    --> QueueTypeAlloc (qta)
    --? VenusCtrl (vct)
    --? ApuSys
```

`VcaEn` defaults to 0. Private `num_capsets` reads as 1. QueueNotify
of queue 0 fires QueueTypeAlloc. Cursor queue 1 faults.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-01 `tb_g6lc_apu_vca`
9 cases / 22 checks / 597 cycles, errors=0. Enable=0: 33 ports /
0 cells. Enable=1: 101912 cells / 18796 flip-flops. `FeatureVirgl`
stays illegal.

### QueuePumpAlloc drain until EMPTY (P0, 2026-10-01)

```text
diagnostic TB client
    ==> QueueNotify queue 0 with two pending descriptors
        --> QueuePumpAlloc (qpa)
            --> VenusCtrlAlloc (vca)
            --? QueuePump (qpu)
            --? ApuSys
```

`QpaEn` defaults to 0. QueueNotify drains until EMPTY. Type 88 ALLOC
rides the same drain as GET_CAPSET. Two GET_CAPSET_INFO descriptors
publish twice. CFG and INFO pass through once. QueueTypeAlloc holds
`capset_q` across Idle except `gnh_only` so a pump EMPTY peek keeps
the GrantCapset ISR. `ApuCfg.NumCapsets` stays 0. Remote 2026-10-01
`tb_g6lc_apu_qpa` 10 cases / 24 checks / 770 cycles, errors=0.
Enable=0: 33 ports / 0 cells. Enable=1: 103410 cells / 19425
flip-flops. `FeatureVirgl` stays illegal.

### NotifyTakeAlloc consume notify_pending (P0, 2026-10-01)

```text
virtio-mmio notify_pending[0]
    --> NotifyTakeAlloc (nta)
        --> QueuePumpAlloc (qpa)
        ==> notify_clear[0]
        --? NotifyTake (ntk)
        --? ApuSys
```

`NtaEn` defaults to 0. `arm` latches control-queue bases. A doorbell
before `arm` faults and still clears. Cursor `notify_pending[1]`
faults. Type 88 ALLOC rides the doorbell. `ApuCfg.NumCapsets` stays
0. Remote 2026-10-01 `tb_g6lc_apu_nta` 7 cases / 13 checks / 241
cycles, errors=0. Enable=0: 35 ports / 0 cells. Enable=1: 105632
cells / 20442 flip-flops. `FeatureVirgl` stays illegal.

### VqTakeAlloc vq_state arms NotifyTakeAlloc (P0, 2026-10-01)

```text
virtio-mmio vq_state[0] + notify_pending[0]
    --> VqTakeAlloc (vqa)
        --> NotifyTakeAlloc (nta)
        ==> notify_clear[0]
        --? VqTake (vqt)
        --? ApuSys
```

`VqaEn` defaults to 0. `vq_state[0]` supplies desc/avail/used/num.
A doorbell with `ready=0` faults and still clears. Cursor
`notify_pending[1]` faults. Type 88 ALLOC rides the doorbell.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-01 `tb_g6lc_apu_vqa`
7 cases / 12 checks / 243 cycles, errors=0. Enable=0: 37 ports /
0 cells. Enable=1: 108997 cells / 21279 flip-flops. `FeatureVirgl`
stays illegal.

### VqAxiAlloc guest beats on 64-bit AXI (P0, 2026-10-01)

```text
VqAxiAlloc (vaa)
    --> VqTakeAlloc (vqa)
    ==> AXI SIZE=2 (4B) / SIZE=3 INCR
    --? VqAxi (vax)
    --? TestharnessDma (tdma)
    --? ApuSys
```

`VaaEn` defaults to 0. 4-byte windows use SIZE=2; longer windows
use SIZE=3 INCR. Type 88 ALLOC rides the doorbell. Converter does
not use `dma_read`. `ApuCfg.NumCapsets` stays 0. Remote 2026-10-01
`tb_g6lc_apu_vaa` 7 cases / 12 checks / 426 cycles, errors=0.
Enable=0: 21 ports / 0 cells. Enable=1: 111719 cells / 21895
flip-flops. `FeatureVirgl` stays illegal.

### VenusBegin Mesa vn_protocol vkBeginCommandBuffer (P0, 2026-10-01)

```text
diagnostic TB client
    ==> CS type 90 / sType 42 / LP64 commandBuffer
        --> VenusBegin (vbg)
        --? VenusAlloc (vac)
        --? VenusDispatch (vnd)
        --? ApuSys
```

`VbgEn` defaults to 0. PRIMARY has a null inheritance pointer.
GENERATE_REPLY writes type + VK_SUCCESS. `ApuCfg.NumCapsets` stays
0. Remote 2026-10-01 `tb_g6lc_apu_vbg` 11 cases / 17 checks / 350
cycles, errors=0. Enable=0: 12 ports / 0 cells. Enable=1: 1947
cells / 708 flip-flops. `FeatureVirgl` stays illegal.

### BeginAlloc ALLOC CMDBUF then BEGIN LOOKUP (P0, 2026-10-01)

```text
diagnostic TB client
    ==> CS type 88 ALLOC then type 90 / sType 42
        --> BeginAlloc (bal)
            --> GenHandle (gnh)
            --> VenusBegin (vbg)
            --? VenusAlloc (vac)
            --? ApuSys
```

`BalEn` defaults to 0. Begin before allocate, MODULE-as-cmdbuf,
duplicate live object ids, and `vkCreateInstance` fault. The
record field is `begin_cmd`. `ApuCfg.NumCapsets` stays 0. Remote
2026-10-01 `tb_g6lc_apu_bal` 8 cases / 17 checks / 554 cycles,
errors=0. Enable=0: 13 ports / 0 cells. Enable=1: 9018 cells /
2134 flip-flops. `FeatureVirgl` stays illegal.

### BeginRun ALLOC BEGIN CREATE DISPATCH END (P0, 2026-10-01)

```text
diagnostic TB client
    ==> CS type 0 INSTANCE / 2 ENUM / 3 FEAT / 6 PROPS / 8 MEM / 7 QFAM / 11 DEVICE / 17 QUEUE / 21 VKMEM / 50 BUFFER / 28 BIND / 23 MAP / 24 UNMAP / 72 DSLAYOUT / 68 PLAYOUT / 66 CPIPE / 77 DESCSET / 79 UPDATE / 93 BINDPIPE / 103 BINDDESC / 88 ALLOC / 90 BEGIN / 59 CREATE / 110 DISPATCH / 91 END / 18 SUBMIT / 19 WAIT
        --> BeginRun (bru)
            --> VenusCreateInstance (vci)
            --> VenusEnumeratePhys (vep)
            --> VenusPhysFeatures (vpf)
            --> VenusPhysProps (vpp)
            --> VenusPhysMemory (vmp)
            --> VenusAllocMemory (vam)
            --> VenusCreateBuffer (vxb)
            --> VenusBindBuffer (vbb)
            --> VenusMapMemory (vmm)
            --> VenusUnmapMemory (vum)
            --> VenusBufReq (vbm)
            --> VenusFlushMap (vfm)
            --> VenusInvalidateMap (vim)
            --> VenusMemCommit (vmc)
            --> VenusDescLayout (vdl)
            --> VenusPipeLayout (vpl)
            --> VenusComputePipe (vcp)
            --> VenusDescAlloc (vda)
            --> VenusUpdateDesc (vud)
            --> VenusBindPipe (vbp)
            --> VenusBindDesc (vbd)
            --> VenusDescPool (vpo)
            --> VenusCreateImage (vxi)
            --> VenusBindImage (vbi)
            --> VenusImageReq (vmi)
            --> VenusImageView (vxv)
            --> VenusSampler (vsm)
            --> VenusRenderPass (vrp)
            --> VenusGraphicsPipe (vgp)
            --> VenusFramebuffer (vfb)
            --> VenusRenderBegin (vrb)
            --> VenusDraw (vdw)
            --> VenusRenderEnd (vre)
            --> VenusBindVtx (vvb)
            --> VenusBindIdx (vib)
            --> VenusDrawIdx (vdi)
            --> VenusSetViewport (vvp)
            --> VenusSetScissor (vsi)
            --> VenusBarrier (vpb)
            --> VenusNextSubpass (vns)
            --> VenusDestroyFbuf (vdf)
            --> VenusDestroyView (vdx)
            --> VenusDestroySampler (vdk)
            --> VenusDestroyRpass (vdr)
            --> VenusDestroyBuf (vdb)
            --> VenusDestroyImg (vdg)
            --> VenusFreeMemory (vfe)
            --> VenusDestroyModule (vdm)
            --> VenusDestroyPipe (vdp)
            --> VenusDestroyPlayout (vdy)
            --> VenusDestroyDsl (vdt)
            --> VenusDestroyPool (vdq)
            --> VenusFreeDescset (vfs)
            --> VenusResetCmdbuf (vrc)
            --> VenusFreeCmdbuf (vfc)
            --> VenusDestroyDevice (vdd)
            --> VenusResetCmdPool (vpc)
            --> VenusDestroyCmdPool (vdc)
            --> VenusDestroyInstance (vdn)
            --> VenusFormatProps (vgf)
            --> VenusImageFormat (vip)
            --> VenusDeviceExt (vxe)
            --> VenusResetDescPool (vrd)
            --> VenusInstanceExt (vie)
            --> VenusDeviceWait (vwl)
            --> VenusSubresourceLayout (vsl)
            --> VenusRenderGranularity (vrg)
            --> VenusSetLineWidth (vlw)
            --> VenusSetDepthBias (vzb)
            --> VenusSetBlendConst (vbc)
            --> VenusSetDepthBounds (vbo)
            --> VenusSetStencilCompare (vcm)
            --> VenusSetStencilWrite (vwm)
            --> VenusSetStencilRef (vrf)
            --> VenusCopyBuffer (vcc)
            --> VenusCopyImage (vcy)
            --> VenusBlitImage (vbl)
            --> VenusCopyBufToImg (vbt)
            --> VenusCopyImgToBuf (vic)
            --> VenusUpdateBuffer (vub)
            --> VenusFillBuffer (vfl)
            --> VenusClearColor (vcl)
            --> VenusDrawIndirect (vio)
            --> VenusDrawIdxIndirect (vix)
            --> VenusClearDepth (vds)
            --> VenusClearAttach (vat)
            --> VenusDispatchIndirect (vin)
            --> VenusResolveImage (vrs)
            --> VenusGetFenceStatus (vgs)
            --> VenusWaitForFences (vwf)
            --> VenusResetFences (vfr)
            --> VenusDestroyFence (vfn)
            --> VenusQueueFamily (vqf)
            --> VenusCreateDevice (vcd)
            --> VenusGetQueue (vgq)
            --> VenusEncode (vnenc)
            --> GenHandle (gnh)
            --> VenusBegin (vbg)
            --> VenusEnd (ven)
            --> VenusSubmit (vqs)
            --> VenusWaitIdle (vwi)
            --> VenusDispatch (vnd)
            --> SpirvSubset (spirv)
            --? BeginAlloc (bal)
            --? EndAlloc (eal)
            --? ApuSys
```

`BruEn` defaults to 0. DISPATCH requires a begun CMDBUF, a
loaded module, a bound compute pipeline, and a bound descriptor
set. END LOOKUPs the begun handle and clears recording.
INSTANCE ALLOCs `APU_GNH_INSTANCE`. ENUM LOOKUPs that INSTANCE then
ALLOCs `APU_GNH_PHYS`. FEAT, PROPS, and MEM LOOKUP PHYS. QFAM LOOKUPs that
PHYS. DEVICE LOOKUPs PHYS then ALLOCs `APU_GNH_DEVICE` after FEAT,
PROPS, MEM, and QFAM. QUEUE LOOKUPs DEVICE then
ALLOCs `APU_GNH_QUEUE`. BUFFER LOOKUPs DEVICE then ALLOCs
`APU_GNH_BUFFER` from the guest pBuffer id. BIND LOOKUPs BUFFER then LOOKUPs MEMORY. MAP LOOKUPs MEMORY and
publishes `APU_SHM_BASE`. UNMAP requires that map, LOOKUPs MEMORY,
then clears map_ok. BUFREQ LOOKUPs BUFFER and publishes size 4096.
FLUSH and INVAL require a prior map and LOOKUP MEMORY. MEMC LOOKUPs
MEMORY and publishes committed size 4096. DESCSET LOOKUPs DEVICE then
ALLOCs DESCSET. UPDATE LOOKUPs DESCSET then LOOKUPs BUFFER. BINDPIPE
LOOKUPs PIPELINE after BEGIN. BINDDESC LOOKUPs DESCSET after BEGIN.
SUBMIT and WAIT require that published
queue. `ApuCfg.NumCapsets` stays 0. Remote 2026-10-02
`tb_g6lc_apu_bru` 12 cases / 105 checks / 5308 cycles, errors=0.
Enable=0: 17 ports / 0 cells. Enable=1: 138433 cells / 31541
flip-flops. `FeatureVirgl` stays illegal.

### QueueBegin AvailNext into BeginRun (P0, 2026-10-01)

```text
diagnostic TB client
    ==> virtq_avail / first payload CS
        --> QueueBegin (qbn)
            --> AvailNext (avn)
            --> BeginRun (bru)
            ==> WRITE result then used.idx then ISR
            --? QueueAlloc (qal)
            --? ApuSys
```

`QbnEn` defaults to 0. Types 90 BEGIN, 91 END, 18 SUBMIT, 19 WAIT,
17 QUEUE, 11 DEVICE, 21 VKMEM, 50 BUFFER, 28 BIND, 23 MAP, 24 UNMAP, 30 BUFREQ,
25 FLUSH, 26 INVAL, 27 MEMC, 72 DSLAYOUT, 68 PLAYOUT, 66 CPIPE,
77 DESCSET, 79 UPDATE, 93 BINDPIPE, 103 BINDDESC, 0 INSTANCE,
2 ENUM, 3 FEAT, 6 PROPS, 8 MEM, and 7 QFAM ride the same CS walk as
ALLOC/CREATE/DISPATCH. A WRITE last descriptor publishes handle,
SPIR-V, family count, fragment stores, descriptor-set limit, memory
type count, mapped address, buffer size, committed size, or VK_SUCCESS then used.idx and ISR.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-02 `tb_g6lc_apu_qbn`
7 cases / 48 checks / 2175 cycles, errors=0. Enable=0: 33 ports /
0 cells. Enable=1: 135281 cells / 31536 flip-flops. `FeatureVirgl`
stays illegal.

### QueueTypeBegin type word mux (P0, 2026-10-01)

```text
diagnostic TB client
    ==> virtq_avail first-word peek
        --> QueueTypeBegin (qtb)
            --> AvailNext (avn)
            --> GrantCapset (gcs)
            --> QueueBegin (qbn)
            --? QueueTypeAlloc (qta)
            --? ApuSys
```

`QtbEn` defaults to 0. GET_CAPSET/INFO select Venus; type
88/90/59/110/91/18/19/17/11/0/2/3/6/7/8/21/50/28/23/24/30/25/26/27/72/68/66/77/79/93/103 select QueueBegin. Idle holds
`capset_q` except `gnh_only`. `ApuCfg.NumCapsets` stays 0. Remote
2026-10-02 `tb_g6lc_apu_qtb` 6 cases / 48 checks / 2660 cycles,
errors=0. Enable=0: 33 ports / 0 cells. Enable=1: 149588 cells /
34640 flip-flops. `FeatureVirgl` stays illegal.

### VenusCtrlBegin private CFG and QueueNotify (P0, 2026-10-01)

```text
diagnostic TB client
    ==> CFG num_capsets / INFO index 0 / QueueNotify q0
        --> VenusCtrlBegin (vcb)
            --> VenusCapset (vcap)
            --> QueueTypeBegin (qtb)
            --? VenusCtrlAlloc (vca)
            --? ApuSys
```

`VcbEn` defaults to 0. Private `num_capsets` reads as 1. Cursor
queue 1 faults. `ApuCfg.NumCapsets` stays 0. Remote 2026-10-01
`tb_g6lc_apu_vcb` 9 cases / 23 checks / 654 cycles, errors=0.
Enable=0: 33 ports / 0 cells. Enable=1: 103161 cells / 19254
flip-flops. `FeatureVirgl` stays illegal.

### QueuePumpBegin drain until EMPTY (P0, 2026-10-01)

```text
diagnostic TB client
    ==> QueueNotify until EMPTY
        --> QueuePumpBegin (qpb)
            --> VenusCtrlBegin (vcb)
            --? QueuePumpAlloc (qpa)
            --? ApuSys
```

`QpbEn` defaults to 0. Type 90 BEGIN rides the same drain as
GET_CAPSET. EMPTY copies the prior record including IRQ.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-01 `tb_g6lc_apu_qpb`
10 cases / 25 checks / 837 cycles, errors=0. Enable=0: 33 ports /
0 cells. Enable=1: 104658 cells / 19884 flip-flops. `FeatureVirgl`
stays illegal.

### NotifyTakeBegin doorbell into QueuePumpBegin (P0, 2026-10-01)

```text
diagnostic TB client
    ==> notify_pending[0] after arm
        --> NotifyTakeBegin (ntb)
            --> QueuePumpBegin (qpb)
            --? NotifyTakeAlloc (nta)
            --? ApuSys
```

`NtbEn` defaults to 0. Type 88 ALLOC and type 90 BEGIN ride the
doorbell. Cursor `notify_pending[1]` faults. `ApuCfg.NumCapsets`
stays 0. Remote 2026-10-01 `tb_g6lc_apu_ntb` 7 cases / 14 checks /
317 cycles, errors=0. Enable=0: 35 ports / 0 cells. Enable=1:
106882 cells / 20902 flip-flops. `FeatureVirgl` stays illegal.

### VqTakeBegin vq_state arm (P0, 2026-10-01)

```text
diagnostic TB client
    ==> vq_state[0] + notify_pending[0]
        --> VqTakeBegin (vqb)
            --> NotifyTakeBegin (ntb)
            --? VqTakeAlloc (vqa)
            --? ApuSys
```

`VqbEn` defaults to 0. Ports are `vq0_i`/`vq1_i`. Type 88 ALLOC
and type 90 BEGIN ride the doorbell. A doorbell with `ready=0`
faults and still clears. `ApuCfg.NumCapsets` stays 0. Remote
2026-10-01 `tb_g6lc_apu_vqb` 7 cases / 13 checks / 318 cycles,
errors=0. Enable=0: 37 ports / 0 cells. Enable=1: 110250 cells /
21740 flip-flops. `FeatureVirgl` stays illegal.

### VqAxiBegin guest beats on 64-bit AXI (P0, 2026-10-01)

```text
VqAxiBegin (vab)
    --> VqTakeBegin (vqb)
    ==> AXI SIZE=2 (4B) / SIZE=3 INCR
    --? VqAxiAlloc (vaa)
    --? TestharnessDma (tdma)
    --? ApuSys
```

`VabEn` defaults to 0. Type 88 ALLOC and type 90 BEGIN ride the
doorbell. Converter does not use `dma_read`. `ApuCfg.NumCapsets`
stays 0. Remote 2026-10-01 `tb_g6lc_apu_vab` 7 cases / 13 checks /
553 cycles, errors=0. Enable=0: 21 ports / 0 cells. Enable=1:
112972 cells / 22356 flip-flops. `FeatureVirgl` stays illegal.

### VenusEnd Mesa vn_protocol vkEndCommandBuffer (P0, 2026-10-01)

```text
diagnostic TB client
    ==> CS type 91 / LP64 commandBuffer
        --> VenusEnd (ven)
        --? VenusBegin (vbg)
        --? VenusAlloc (vac)
        --? ApuSys
```

`VenEn` defaults to 0. GENERATE_REPLY writes type + `VK_SUCCESS`.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-01 `tb_g6lc_apu_ven`
10 cases / 16 checks / 165 cycles, errors=0. Enable=0: 12 ports /
0 cells. Enable=1: 1590 cells / 644 flip-flops. `FeatureVirgl`
stays illegal.

### EndAlloc ALLOC then BEGIN LOOKUP then END LOOKUP (P0, 2026-10-01)

```text
diagnostic TB client
    ==> CS type 88 ALLOC then type 90 BEGIN then type 91 END
        --> EndAlloc (eal)
            --> GenHandle (gnh)
            --> VenusBegin (vbg)
            --> VenusEnd (ven)
            --? VenusAlloc (vac)
            --? ApuSys
```

`EalEn` defaults to 0. End before allocate or begin,
MODULE-as-cmdbuf, a second end, and `vkCreateInstance` fault. The
record field is `end_cmd`. `ApuCfg.NumCapsets` stays 0. Remote
2026-10-01 `tb_g6lc_apu_eal` 10 cases / 22 checks / 778 cycles,
errors=0. Enable=0: 13 ports / 0 cells. Enable=1: 10853 cells /
2749 flip-flops. `FeatureVirgl` stays illegal.

### VenusGetQueue Mesa vn_protocol vkGetDeviceQueue (P0, 2026-10-01)

```text
diagnostic TB client
    ==> CS type 17 / LP64 device / family 0 / index 0
        --> VenusGetQueue (vgq)
        --? VenusSubmit (vqs)
        --? GenHandle (gnh)
        --? ApuSys
```

`VgqEn` defaults to 0. GENERATE_REPLY writes type. BeginRun LOOKUPs
the published DEVICE handle then ALLOCs `APU_GNH_QUEUE`. GetQueue
before CreateDevice faults. `ApuCfg.NumCapsets` stays 0. Remote
2026-10-01 `tb_g6lc_apu_vgq` 7 cases / 13 checks / 134 cycles,
errors=0. Enable=0: 12 ports / 0 cells. Enable=1: 1781 cells / 708
flip-flops. `FeatureVirgl` stays illegal.

### VenusCreateDevice Mesa vn_protocol vkCreateDevice (P0, 2026-10-01)

```text
diagnostic TB client
    ==> CS type 11 / LP64 physicalDevice / sType 3 / one family-0 queue
        --> VenusCreateDevice (vcd)
        --? VenusGetQueue (vgq)
        --? GenHandle (gnh)
        --? ApuSys
```

`VcdEn` defaults to 0. GENERATE_REPLY writes type + `VK_SUCCESS`.
BeginRun ALLOCs `APU_GNH_DEVICE` from `physicalDevice[31:0]` after
a live INSTANCE. CreateDevice before CreateInstance faults.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-01 `tb_g6lc_apu_vcd`
7 cases / 13 checks / 926 cycles, errors=0. Enable=0: 12 ports /
0 cells. Enable=1: 4215 cells / 1412 flip-flops. `FeatureVirgl`
stays illegal.

### VenusCreateInstance Mesa vn_protocol vkCreateInstance (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 0 / pCreateInfo / sType 1 / no layers
        --> VenusCreateInstance (vci)
        --? VenusCreateDevice (vcd)
        --? GenHandle (gnh)
        --? ApuSys
```

`VciEn` defaults to 0. GENERATE_REPLY writes type + `VK_SUCCESS`.
BeginRun ALLOCs `APU_GNH_INSTANCE` from `info[31:0]`.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-02 `tb_g6lc_apu_vci`
7 cases / 13 checks / 566 cycles, errors=0. Enable=0: 12 ports /
0 cells. Enable=1: 2646 cells / 900 flip-flops. `FeatureVirgl`
stays illegal.

### VenusEnumeratePhys Mesa vn_protocol vkEnumeratePhysicalDevices (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 2 / LP64 instance / count 1
        --> VenusEnumeratePhys (vep)
        --? VenusCreateInstance (vci)
        --? VenusCreateDevice (vcd)
        --? GenHandle (gnh)
        --? ApuSys
```

`VepEn` defaults to 0. GENERATE_REPLY writes type + `VK_SUCCESS`.
BeginRun LOOKUPs the published INSTANCE then ALLOCs `APU_GNH_PHYS`.
Enumerate before CreateInstance faults. `ApuCfg.NumCapsets` stays 0.
Remote 2026-10-02 `tb_g6lc_apu_vep` 7 cases / 13 checks / 388
cycles, errors=0. Enable=0: 12 ports / 0 cells. Enable=1: 1814
cells / 644 flip-flops. `FeatureVirgl` stays illegal.

### VenusQueueFamily Mesa vn_protocol vkGetPhysicalDeviceQueueFamilyProperties (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 7 / LP64 physicalDevice / count 1 / GRAPHICS|COMPUTE
        --> VenusQueueFamily (vqf)
        --? VenusEnumeratePhys (vep)
        --? VenusCreateDevice (vcd)
        --? GenHandle (gnh)
        --? ApuSys
```

`VqfEn` defaults to 0. LOOKUP PHYS; no new GenHandle kind.
CreateDevice requires that query. GENERATE_REPLY writes type then
family count and GRAPHICS|COMPUTE flags. `ApuCfg.NumCapsets` stays 0.
Remote 2026-10-02 `tb_g6lc_apu_vqf` 7 cases / 13 checks / 388
cycles, errors=0. Enable=0: 12 ports / 0 cells. Enable=1: 1816
cells / 644 flip-flops. `FeatureVirgl` stays illegal.

### VenusPhysFeatures Mesa vn_protocol vkGetPhysicalDeviceFeatures (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 3 / LP64 physicalDevice / pFeatures
        --> VenusPhysFeatures (vpf)
        --? VenusEnumeratePhys (vep)
        --? VenusCreateDevice (vcd)
        --? GenHandle (gnh)
        --? ApuSys
```

`VpfEn` defaults to 0. LOOKUP PHYS; no new GenHandle kind.
CreateDevice requires that query. Compact GENERATE_REPLY publishes
`fragmentStoresAndAtomics`. `ApuCfg.NumCapsets` stays 0. Remote
2026-10-02 `tb_g6lc_apu_vpf` 7 cases / 13 checks / 326 cycles,
errors=0. Enable=0: 12 ports / 0 cells. Enable=1: 1651 cells /
644 flip-flops. `FeatureVirgl` stays illegal.

### VenusPhysProps Mesa vn_protocol vkGetPhysicalDeviceProperties (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 6 / LP64 physicalDevice / pProperties
        --> VenusPhysProps (vpp)
        --? VenusEnumeratePhys (vep)
        --? VenusCreateDevice (vcd)
        --? GenHandle (gnh)
        --? ApuSys
```

`VppEn` defaults to 0. LOOKUP PHYS; no new GenHandle kind.
CreateDevice requires that query. Compact GENERATE_REPLY publishes
Vulkan 1.1 `apiVersion` `32'h00401000` and
`maxBoundDescriptorSets=4`. `ApuCfg.NumCapsets` stays 0. Remote
2026-10-02 `tb_g6lc_apu_vpp` 7 cases / 13 checks / 326 cycles,
errors=0. Enable=0: 12 ports / 0 cells. Enable=1: 1651 cells /
644 flip-flops. `FeatureVirgl` stays illegal.

### VenusPhysMemory Mesa vn_protocol vkGetPhysicalDeviceMemoryProperties (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 8 / LP64 physicalDevice / pMemoryProperties
        --> VenusPhysMemory (vmp)
        --? VenusEnumeratePhys (vep)
        --? VenusCreateDevice (vcd)
        --? GenHandle (gnh)
        --? ApuSys
```

`VmpEn` defaults to 0. LOOKUP PHYS; no new GenHandle kind.
CreateDevice requires that query. Compact GENERATE_REPLY publishes
two memory types (`DEVICE_LOCAL` and `HOST_VISIBLE|HOST_COHERENT`)
and one heap. `ApuCfg.NumCapsets` stays 0. Remote 2026-10-02
`tb_g6lc_apu_vmp` 7 cases / 13 checks / 326 cycles, errors=0.
Enable=0: 12 ports / 0 cells. Enable=1: 1650 cells / 644
flip-flops. `FeatureVirgl` stays illegal.

### VenusAllocMemory Mesa vn_protocol vkAllocateMemory (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 21 / sType 5 / LP64 device / pMemory
        --> VenusAllocMemory (vam)
        --? VenusCreateDevice (vcd)
        --? VenusPhysMemory (vmp)
        --? GenHandle (gnh)
        --? ApuSys
```

`VamEn` defaults to 0. LOOKUP DEVICE then ALLOC `APU_GNH_MEMORY`.
Requires the memory-properties query. GENERATE_REPLY writes type +
`VK_SUCCESS` then the MEMORY handle. `ApuCfg.NumCapsets` stays 0.
Remote 2026-10-02 `tb_g6lc_apu_vam` 8 cases / 14 checks / 631
cycles, errors=0. Enable=0: 12 ports / 0 cells. Enable=1: 2791
cells / 964 flip-flops. `FeatureVirgl` stays illegal.

### VenusCreateBuffer Mesa vn_protocol vkCreateBuffer (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 50 / sType 12 / usage STORAGE_BUFFER / LP64 device / pBuffer
        --> VenusCreateBuffer (vxb)
        --? VenusCreateDevice (vcd)
        --? VenusAllocMemory (vam)
        --? GenHandle (gnh)
        --? ApuSys
```

`VxbEn` defaults to 0. LOOKUP DEVICE then ALLOC `APU_GNH_BUFFER`.
GENERATE_REPLY writes type + `VK_SUCCESS` then the BUFFER handle.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-02 `tb_g6lc_apu_vxb`
8 cases / 14 checks / 815 cycles, errors=0. Enable=0: 12 ports /
0 cells. Enable=1: 3339 cells / 1220 flip-flops. `FeatureVirgl`
stays illegal.

### VenusBindBuffer Mesa vn_protocol vkBindBufferMemory (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 28 / LP64 device / buffer / memory / offset 0
        --> VenusBindBuffer (vbb)
        --? VenusCreateBuffer (vxb)
        --? VenusAllocMemory (vam)
        --? GenHandle (gnh)
        --? ApuSys
```

`VbbEn` defaults to 0. LOOKUP BUFFER then LOOKUP MEMORY. No new
GenHandle slot. GENERATE_REPLY writes type + `VK_SUCCESS`.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-02 `tb_g6lc_apu_vbb`
8 cases / 14 checks / 435 cycles, errors=0. Enable=0: 12 ports /
0 cells. Enable=1: 2039 cells / 772 flip-flops. `FeatureVirgl`
stays illegal.

### VenusMapMemory Mesa vn_protocol vkMapMemory (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 23 / LP64 device / memory / offset 0 / ppData
        --> VenusMapMemory (vmm)
        --? VenusAllocMemory (vam)
        --? VenusBindBuffer (vbb)
        --? GenHandle (gnh)
        --? ApuSys
```

`VmmEn` defaults to 0. LOOKUP MEMORY. No new GenHandle slot.
GENERATE_REPLY writes type + `VK_SUCCESS` then `APU_SHM_BASE`.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-02 `tb_g6lc_apu_vmm`
9 cases / 15 checks / 548 cycles, errors=0. Enable=0: 12 ports /
0 cells. Enable=1: 2137 cells / 772 flip-flops. `FeatureVirgl`
stays illegal.

### VenusUnmapMemory Mesa vn_protocol vkUnmapMemory (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 24 / LP64 device / memory
        --> VenusUnmapMemory (vum)
        --? VenusMapMemory (vmm)
        --? VenusAllocMemory (vam)
        --? GenHandle (gnh)
        --? ApuSys
```

`VumEn` defaults to 0. Requires a prior map. LOOKUP MEMORY then
clears map_ok. GENERATE_REPLY writes type. `ApuCfg.NumCapsets`
stays 0. Remote 2026-10-02 `tb_g6lc_apu_vum` 6 cases / 12 checks /
268 cycles, errors=0. Enable=0: 12 ports / 0 cells. Enable=1:
1715 cells / 708 flip-flops. `FeatureVirgl` stays illegal.

### VenusBufReq Mesa vn_protocol vkGetBufferMemoryRequirements (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 30 / LP64 device / buffer / pMemoryRequirements
        --> VenusBufReq (vbm)
        --? VenusCreateBuffer (vxb)
        --? GenHandle (gnh)
        --? ApuSys
```

`VbmEn` defaults to 0. LOOKUP BUFFER. Compact GENERATE_REPLY
publishes size 4096, alignment 256, memoryTypeBits 3 at words
128–133. `ApuCfg.NumCapsets` stays 0. Remote 2026-10-02
`tb_g6lc_apu_vbm` 7 cases / 13 checks / 349 cycles, errors=0.
Enable=0: 12 ports / 0 cells. Enable=1: 1781 cells / 708
flip-flops. `FeatureVirgl` stays illegal.

### VenusFlushMap Mesa vn_protocol vkFlushMappedMemoryRanges (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 25 / LP64 device / one VkMappedMemoryRange
        --> VenusFlushMap (vfm)
        --? VenusMapMemory (vmm)
        --? VenusAllocMemory (vam)
        --? GenHandle (gnh)
        --? ApuSys
```

`VfmEn` defaults to 0. Requires a prior map. LOOKUP MEMORY.
GENERATE_REPLY writes type + VK_SUCCESS at words 136–141.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-02 `tb_g6lc_apu_vfm`
8 cases / 14 checks / 633 cycles, errors=0. Enable=0: 12 ports /
0 cells. Enable=1: 2674 cells / 964 flip-flops. `FeatureVirgl`
stays illegal.

### VenusInvalidateMap Mesa vn_protocol vkInvalidateMappedMemoryRanges (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 26 / LP64 device / one VkMappedMemoryRange
        --> VenusInvalidateMap (vim)
        --? VenusMapMemory (vmm)
        --? VenusAllocMemory (vam)
        --? GenHandle (gnh)
        --? ApuSys
```

`VimEn` defaults to 0. Requires a prior map. LOOKUP MEMORY.
GENERATE_REPLY writes type + VK_SUCCESS at words 144–149.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-02 `tb_g6lc_apu_vim`
8 cases / 14 checks / 633 cycles, errors=0. Enable=0: 12 ports /
0 cells. Enable=1: 2674 cells / 964 flip-flops. `FeatureVirgl`
stays illegal.

### VenusMemCommit Mesa vn_protocol vkGetDeviceMemoryCommitment (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 27 / LP64 device / memory / pCommitted
        --> VenusMemCommit (vmc)
        --? VenusAllocMemory (vam)
        --? GenHandle (gnh)
        --? ApuSys
```

`VmcEn` defaults to 0. LOOKUP MEMORY. Compact GENERATE_REPLY
publishes committed size 4096 at words 152–157. `ApuCfg.NumCapsets`
stays 0. Remote 2026-10-02 `tb_g6lc_apu_vmc` 7 cases / 13 checks /
349 cycles, errors=0. Enable=0: 12 ports / 0 cells. Enable=1:
1781 cells / 708 flip-flops. `FeatureVirgl` stays illegal.

### VenusDescLayout Mesa vn_protocol vkCreateDescriptorSetLayout (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 72 / sType 32 / one STORAGE_BUFFER compute binding
        --> VenusDescLayout (vdl)
        --? VenusCreateDevice (vcd)
        --? GenHandle (gnh)
        --? ApuSys
```

`VdlEn` defaults to 0. LOOKUP DEVICE then ALLOC DSLAYOUT.
GENERATE_REPLY writes type + VK_SUCCESS then the published handle
at words 160–165. `ApuCfg.NumCapsets` stays 0. Remote 2026-10-02
`tb_g6lc_apu_vdl` 7 cases / 13 checks / 564 cycles, errors=0.
Enable=1: 2745 cells / 964 flip-flops. `FeatureVirgl` stays illegal.

### VenusPipeLayout Mesa vn_protocol vkCreatePipelineLayout (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 68 / sType 30 / one set layout
        --> VenusPipeLayout (vpl)
        --? VenusDescLayout (vdl)
        --? GenHandle (gnh)
        --? ApuSys
```

`VplEn` defaults to 0. Requires dsl_ok. LOOKUP DEVICE then ALLOC
PLAYOUT. GENERATE_REPLY at words 168–173. `ApuCfg.NumCapsets`
stays 0. Remote 2026-10-02 `tb_g6lc_apu_vpl` 7 cases / 13 checks /
552 cycles, errors=0. Enable=1: 2837 cells / 1028 flip-flops.
`FeatureVirgl` stays illegal.

### VenusComputePipe Mesa vn_protocol vkCreateComputePipelines (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 66 / sType 29 / compute stage / shader / layout
        --> VenusComputePipe (vcp)
        --? VenusPipeLayout (vpl)
        --? GenHandle (gnh)
        --? ApuSys
```

`VcpEn` defaults to 0. Packed field is `shader`. Requires pl_ok
and a loaded MODULE. LOOKUP DEVICE then ALLOC PIPELINE.
GENERATE_REPLY at words 176–181. `ApuCfg.NumCapsets` stays 0.
Remote 2026-10-02 `tb_g6lc_apu_vcp` 7 cases / 13 checks / 698
cycles, errors=0. Enable=1: 3595 cells / 1348 flip-flops.
`FeatureVirgl` stays illegal.

### VenusDescAlloc Mesa vn_protocol vkAllocateDescriptorSets (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 77 / sType 34 / dummy pool / one layout / pDescriptorSets
        --> VenusDescAlloc (vda)
        --? VenusDescLayout (vdl)
        --? GenHandle (gnh)
        --? ApuSys
```

`VdaEn` defaults to 0. Requires dsl_ok. LOOKUP DEVICE then ALLOC
DESCSET. GENERATE_REPLY at words 184–189. Pool pointer is
decode-only. `ApuCfg.NumCapsets` stays 0. Remote 2026-10-02
`tb_g6lc_apu_vda` 7 cases / 13 checks / 542 cycles, errors=0.
Enable=0: 12 ports / 0 cells. Enable=1: 2803 cells / 1028
flip-flops. `FeatureVirgl` stays illegal.

### VenusUpdateDesc Mesa vn_protocol vkUpdateDescriptorSets (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 79 / sType 35 / STORAGE_BUFFER write / offset 0
        --> VenusUpdateDesc (vud)
        --? VenusDescAlloc (vda)
        --? VenusCreateBuffer (vxb)
        --? GenHandle (gnh)
        --? ApuSys
```

`VudEn` defaults to 0. Requires dset_ok. LOOKUP DESCSET then
LOOKUP BUFFER. No new GenHandle slot. GENERATE_REPLY at words
192–197. `ApuCfg.NumCapsets` stays 0. Remote 2026-10-02
`tb_g6lc_apu_vud` 7 cases / 11 checks / 682 cycles, errors=0.
Enable=0: 12 ports / 0 cells. Enable=1: 3437 cells / 1284
flip-flops. `FeatureVirgl` stays illegal.

### VenusBindPipe Mesa vn_protocol vkCmdBindPipeline (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 93 / compute bind point / command buffer / pipeline
        --> VenusBindPipe (vbp)
        --? VenusComputePipe (vcp)
        --? VenusBegin (vbg)
        --? GenHandle (gnh)
        --? ApuSys
```

`VbpEn` defaults to 0. Requires a begun CMDBUF. LOOKUP PIPELINE
then sets pipe_bound. GENERATE_REPLY at words 200–205.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-02 `tb_g6lc_apu_vbp`
7 cases / 11 checks / 336 cycles, errors=0. Enable=0: 12 ports /
0 cells. Enable=1: 1817 cells / 708 flip-flops. `FeatureVirgl`
stays illegal.

### VenusBindDesc Mesa vn_protocol vkCmdBindDescriptorSets (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 103 / compute bind point / layout / one set
        --> VenusBindDesc (vbd)
        --? VenusDescAlloc (vda)
        --? VenusBegin (vbg)
        --? GenHandle (gnh)
        --? ApuSys
```

`VbdEn` defaults to 0. Requires a begun CMDBUF and dset_ok.
LOOKUP DESCSET then sets desc_bound. GENERATE_REPLY at words
208–213. DISPATCH requires pipe_bound and desc_bound.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-02 `tb_g6lc_apu_vbd`
7 cases / 11 checks / 492 cycles, errors=0. Enable=0: 12 ports /
0 cells. Enable=1: 2676 cells / 1028 flip-flops. `FeatureVirgl`
stays illegal.

### VenusDescPool Mesa vn_protocol vkCreateDescriptorPool (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 74 / sType 33 / one STORAGE_BUFFER size / pDescriptorPool
        --> VenusDescPool (vpo)
        --? VenusCreateDevice (vcd)
        --? GenHandle (gnh)
        --? ApuSys
```

`VpoEn` defaults to 0. LOOKUP DEVICE then ALLOC POOL. GENERATE_REPLY
at words 216–221. AllocateDescriptorSets LOOKUPs that POOL.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-02 `tb_g6lc_apu_vpo`
7 cases / 12 checks / 588 cycles, errors=0. Enable=0: 12 ports /
0 cells. Enable=1: 2811 cells / 964 flip-flops. `FeatureVirgl`
stays illegal.

### VenusCreateImage Mesa vn_protocol vkCreateImage (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 54 / sType 14 / 64x64 2D STORAGE linear R8G8B8A8
        --> VenusCreateImage (vxi)
        --? VenusCreateDevice (vcd)
        --? GenHandle (gnh)
        --? ApuSys
```

`VxiEn` defaults to 0. LOOKUP DEVICE then ALLOC IMAGE.
GENERATE_REPLY at words 224–229. `ApuCfg.NumCapsets` stays 0.
Remote 2026-10-02 `tb_g6lc_apu_vxi` 7 cases / 12 checks / 792
cycles, errors=0. Enable=0: 12 ports / 0 cells. Enable=1: 3616
cells / 1220 flip-flops. `FeatureVirgl` stays illegal.

### VenusImageReq Mesa vn_protocol vkGetImageMemoryRequirements (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 31 / LP64 device / image / pMemoryRequirements
        --> VenusImageReq (vmi)
        --? VenusCreateImage (vxi)
        --? GenHandle (gnh)
        --? ApuSys
```

`VmiEn` defaults to 0. LOOKUP IMAGE. Compact GENERATE_REPLY
publishes size 16384 at words 240–245. `ApuCfg.NumCapsets` stays 0.
Remote 2026-10-02 `tb_g6lc_apu_vmi` 7 cases / 12 checks / 350
cycles, errors=0. Enable=0: 12 ports / 0 cells. Enable=1: 1847
cells / 708 flip-flops. `FeatureVirgl` stays illegal.

### VenusBindImage Mesa vn_protocol vkBindImageMemory (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 29 / LP64 device / image / memory / offset 0
        --> VenusBindImage (vbi)
        --? VenusCreateImage (vxi)
        --? VenusAllocMemory (vam)
        --? GenHandle (gnh)
        --? ApuSys
```

`VbiEn` defaults to 0. LOOKUP IMAGE then LOOKUP MEMORY. No new
GenHandle slot. GENERATE_REPLY at words 232–237.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-02 `tb_g6lc_apu_vbi`
7 cases / 12 checks / 374 cycles, errors=0. Enable=0: 12 ports /
0 cells. Enable=1: 2040 cells / 772 flip-flops. `FeatureVirgl`
stays illegal.

### VenusImageView Mesa vn_protocol vkCreateImageView (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 57 / sType 15 / 2D COLOR R8G8B8A8 identity swizzle
        --> VenusImageView (vxv)
        --? VenusCreateImage (vxi)
        --? GenHandle (gnh)
        --? ApuSys
```

`VxvEn` defaults to 0. LOOKUP IMAGE then ALLOC VIEW. GENERATE_REPLY
shares CS mux slot 31 at `APU_BRU_TAIL_REPLY=248`.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-02 `tb_g6lc_apu_vxv`
7 cases / 12 checks / 766 cycles, errors=0. Enable=0: 12 ports /
0 cells. Enable=1: 3674 cells / 1284 flip-flops. `FeatureVirgl`
stays illegal.

### VenusSampler Mesa vn_protocol vkCreateSampler (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 70 / sType 31 / linear mag/min/mip / repeat U/V/W
        --> VenusSampler (vsm)
        --? VenusCreateDevice (vcd)
        --? GenHandle (gnh)
        --? ApuSys
```

`VsmEn` defaults to 0. LOOKUP DEVICE then ALLOC SAMPLER.
GENERATE_REPLY shares CS mux slot 31. `ApuCfg.NumCapsets` stays 0.
Remote 2026-10-02 `tb_g6lc_apu_vsm` 7 cases / 12 checks / 588
cycles, errors=0. Enable=0: 12 ports / 0 cells. Enable=1: 2813
cells / 964 flip-flops. `FeatureVirgl` stays illegal.

### VenusRenderPass Mesa vn_protocol vkCreateRenderPass (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 82 / sType 38 / one color attachment format 37
        --> VenusRenderPass (vrp)
        --? VenusCreateDevice (vcd)
        --? GenHandle (gnh)
        --? ApuSys
```

`VrpEn` defaults to 0. LOOKUP DEVICE then ALLOC RPASS.
GENERATE_REPLY shares CS mux slot 31. `ApuCfg.NumCapsets` stays 0.
Remote 2026-10-02 `tb_g6lc_apu_vrp` 7 cases / 12 checks / 588
cycles, errors=0. Enable=0: 12 ports / 0 cells. Enable=1: 2814
cells / 964 flip-flops. `FeatureVirgl` stays illegal.

### VenusGraphicsPipe Mesa vn_protocol vkCreateGraphicsPipelines (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 65 / sType 28 / one VERTEX stage / layout / rpass
        --> VenusGraphicsPipe (vgp)
        --? VenusRenderPass (vrp)
        --? VenusPipeLayout (vpl)
        --? GenHandle (gnh)
        --? ApuSys
```

`VgpEn` defaults to 0. Requires rp_ok, pl_ok, and loaded MODULE.
LOOKUP DEVICE then ALLOC PIPELINE (kind 12, guest object `BD`).
GENERATE_REPLY shares CS mux slot 31. `ApuCfg.NumCapsets` stays 0.
Remote 2026-10-02 `tb_g6lc_apu_vgp` 7 cases / 12 checks / 730
cycles, errors=0. Enable=0: 12 ports / 0 cells. Enable=1: 3820
cells / 1412 flip-flops. `FeatureVirgl` stays illegal.

### VenusFramebuffer Mesa vn_protocol vkCreateFramebuffer (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 80 / sType 37 / one 64x64 color view
        --> VenusFramebuffer (vfb)
        --? VenusRenderPass (vrp)
        --? VenusImageView (vxv)
        --? GenHandle (gnh)
        --? ApuSys
```

`VfbEn` defaults to 0. Requires rp_ok. LOOKUP DEVICE then ALLOC FBUF
(kind 19). GENERATE_REPLY shares CS mux slot 31.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-02 `tb_g6lc_apu_vfb`
7 cases / 12 checks / 610 cycles, errors=0. Enable=0: 12 ports /
0 cells. Enable=1: 3131 cells / 1092 flip-flops. `FeatureVirgl`
stays illegal.

### VenusRenderBegin Mesa vn_protocol vkCmdBeginRenderPass (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 133 / sType 43 / 64x64 INLINE
        --> VenusRenderBegin (vrb)
        --? VenusFramebuffer (vfb)
        --? VenusBegin (vbg)
        --? GenHandle (gnh)
        --? ApuSys
```

`VrbEn` defaults to 0. Requires begun CMDBUF, fbuf_ok, and rp_ok.
LOOKUP CMDBUF matching the begun handle. GENERATE_REPLY shares CS mux
slot 31. `ApuCfg.NumCapsets` stays 0. Remote 2026-10-02
`tb_g6lc_apu_vrb` 7 cases / 12 checks / 574 cycles, errors=0.
Enable=0: 12 ports / 0 cells. Enable=1: 2907 cells / 1028 flip-flops.
`FeatureVirgl` stays illegal.

### VenusDraw Mesa vn_protocol vkCmdDraw (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 106 / three vertices / one instance
        --> VenusDraw (vdw)
        --? VenusRenderBegin (vrb)
        --? VenusBindPipe (vbp)
        --? GenHandle (gnh)
        --? ApuSys
```

`VdwEn` defaults to 0. Requires begun, in_rp, and pipe_bound. LOOKUP
CMDBUF. GENERATE_REPLY shares CS mux slot 31. `ApuCfg.NumCapsets`
stays 0. Remote 2026-10-02 `tb_g6lc_apu_vdw` 7 cases / 12 checks /
350 cycles, errors=0. Enable=0: 12 ports / 0 cells. Enable=1: 1788
cells / 676 flip-flops. `FeatureVirgl` stays illegal.

### VenusRenderEnd Mesa vn_protocol vkCmdEndRenderPass (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 135 / LP64 command buffer
        --> VenusRenderEnd (vre)
        --? VenusRenderBegin (vrb)
        --? VenusBegin (vbg)
        --? GenHandle (gnh)
        --? ApuSys
```

`VreEn` defaults to 0. Requires in_rp. LOOKUP CMDBUF, then clears
in_rp. GENERATE_REPLY shares CS mux slot 31. `ApuCfg.NumCapsets`
stays 0. Remote 2026-10-02 `tb_g6lc_apu_vre` 7 cases / 12 checks /
302 cycles, errors=0. Enable=0: 12 ports / 0 cells. Enable=1: 1589
cells / 644 flip-flops. `FeatureVirgl` stays illegal.

### VenusBindVtx Mesa vn_protocol vkCmdBindVertexBuffers (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 105 / one binding / offset 0
        --> VenusBindVtx (vvb)
        --? VenusCreateBuffer (vxb)
        --? VenusBegin (vbg)
        --? GenHandle (gnh)
        --? ApuSys
```

`VvbEn` defaults to 0. Requires begun CMDBUF. LOOKUP CMDBUF then
LOOKUP BUFFER. Sets vtx_bound. GENERATE_REPLY shares CS mux slot 31.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-02 `tb_g6lc_apu_vvb`
7 cases / 12 checks / 372 cycles, errors=0. Enable=0: 12 ports /
0 cells. Enable=1: 1914 cells / 708 flip-flops. `FeatureVirgl`
stays illegal.

### VenusBindIdx Mesa vn_protocol vkCmdBindIndexBuffer (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 104 / UINT16 / offset 0
        --> VenusBindIdx (vib)
        --? VenusCreateBuffer (vxb)
        --? VenusBegin (vbg)
        --? GenHandle (gnh)
        --? ApuSys
```

`VibEn` defaults to 0. Requires begun CMDBUF. LOOKUP CMDBUF then
LOOKUP BUFFER. Sets idx_bound. GENERATE_REPLY shares CS mux slot 31.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-02 `tb_g6lc_apu_vib`
7 cases / 12 checks / 360 cycles, errors=0. Enable=0: 12 ports /
0 cells. Enable=1: 1879 cells / 708 flip-flops. `FeatureVirgl`
stays illegal.

### VenusDrawIdx Mesa vn_protocol vkCmdDrawIndexed (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 107 / three indices / one instance
        --> VenusDrawIdx (vdi)
        --? VenusBindVtx (vvb)
        --? VenusBindIdx (vib)
        --? VenusRenderBegin (vrb)
        --? GenHandle (gnh)
        --? ApuSys
```

`VdiEn` defaults to 0. Requires begun, in_rp, pipe_bound, vtx_bound,
and idx_bound. LOOKUP CMDBUF. GENERATE_REPLY shares CS mux slot 31.
`ApuCfg.NumCapsets` stays 0. Remote 2026-10-02 `tb_g6lc_apu_vdi`
7 cases / 12 checks / 362 cycles, errors=0. Enable=0: 12 ports /
0 cells. Enable=1: 1822 cells / 676 flip-flops. `FeatureVirgl`
stays illegal.

### VenusSetViewport Mesa vn_protocol vkCmdSetViewport (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 94 / one 64x64 viewport
        --> VenusSetViewport (vvp)
        --? VenusBegin (vbg)
        --? GenHandle (gnh)
        --? ApuSys
```

`VvpEn` defaults to 0. Requires begun CMDBUF. LOOKUP CMDBUF.
GENERATE_REPLY shares CS mux slot 31. `ApuCfg.NumCapsets` stays 0.
Remote 2026-10-02 `tb_g6lc_apu_vvp` 7 cases / 12 checks / 422 cycles,
errors=0. Enable=0: 12 ports / 0 cells. Enable=1: 1932 cells / 676
flip-flops. `FeatureVirgl` stays illegal.

### VenusSetScissor Mesa vn_protocol vkCmdSetScissor (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 95 / one 64x64 scissor
        --> VenusSetScissor (vsi)
        --? VenusBegin (vbg)
        --? GenHandle (gnh)
        --? ApuSys
```

`VsiEn` defaults to 0. Requires begun CMDBUF. LOOKUP CMDBUF.
GENERATE_REPLY shares CS mux slot 31. `ApuCfg.NumCapsets` stays 0.
Remote 2026-10-02 `tb_g6lc_apu_vsi` 7 cases / 12 checks / 398 cycles,
errors=0. Enable=0: 12 ports / 0 cells. Enable=1: 1856 cells / 676
flip-flops. `FeatureVirgl` stays illegal.

### VenusBarrier Mesa vn_protocol vkCmdPipelineBarrier (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 126 / TOP_OF_PIPE / zero barriers
        --> VenusBarrier (vpb)
        --? VenusBegin (vbg)
        --? GenHandle (gnh)
        --? ApuSys
```

`VpbEn` defaults to 0. Requires begun CMDBUF. LOOKUP CMDBUF.
GENERATE_REPLY shares CS mux slot 31. `ApuCfg.NumCapsets` stays 0.
Remote 2026-10-02 `tb_g6lc_apu_vpb` 7 cases / 12 checks / 374 cycles,
errors=0. Enable=0: 12 ports / 0 cells. Enable=1: 1855 cells / 676
flip-flops. `FeatureVirgl` stays illegal.

### VenusNextSubpass Mesa vn_protocol vkCmdNextSubpass (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 134 / INLINE
        --> VenusNextSubpass (vns)
        --? VenusRenderBegin (vrb)
        --? GenHandle (gnh)
        --? ApuSys
```

`VnsEn` defaults to 0. Decoder accepts INLINE. BeginRun FAULTS because
the compact render pass has one subpass. GENERATE_REPLY shares CS mux
slot 31. `ApuCfg.NumCapsets` stays 0. Remote 2026-10-02
`tb_g6lc_apu_vns` 7 cases / 12 checks / 314 cycles, errors=0.
Enable=0: 12 ports / 0 cells. Enable=1: 1685 cells / 676 flip-flops.
`FeatureVirgl` stays illegal.

### VenusDestroyFbuf Mesa vn_protocol vkDestroyFramebuffer (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 81 / null allocator
        --> VenusDestroyFbuf (vdf)
        --? VenusFramebuffer (vfb)
        --> GenHandle (gnh) RETIRE
        --? ApuSys
```

`VdfEn` defaults to 0. LOOKUP FBUF then `APU_GNH_RETIRE`. Clears
`fbuf_ok`. GENERATE_REPLY shares CS mux slot 31. `ApuCfg.NumCapsets`
stays 0. Remote 2026-10-02 `tb_g6lc_apu_vdf` 7 cases / 12 checks /
350 cycles, errors=0. Enable=0: 12 ports / 0 cells. Enable=1: 1846
cells / 708 flip-flops. `FeatureVirgl` stays illegal.

### VenusDestroyView Mesa vn_protocol vkDestroyImageView (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 58 / null allocator
        --> VenusDestroyView (vdx)
        --? VenusImageView (vxv)
        --> GenHandle (gnh) RETIRE
        --? ApuSys
```

`VdxEn` defaults to 0. LOOKUP VIEW then RETIRE. GENERATE_REPLY shares
CS mux slot 31. `ApuCfg.NumCapsets` stays 0. Remote 2026-10-02
`tb_g6lc_apu_vdx` 7 cases / 12 checks / 350 cycles, errors=0.
Enable=0: 12 ports / 0 cells. Enable=1: 1847 cells / 708 flip-flops.
`FeatureVirgl` stays illegal.

### VenusDestroySampler Mesa vn_protocol vkDestroySampler (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 71 / null allocator
        --> VenusDestroySampler (vdk)
        --? VenusSampler (vsm)
        --> GenHandle (gnh) RETIRE
        --? ApuSys
```

`VdkEn` defaults to 0. LOOKUP SAMPLER then RETIRE. GENERATE_REPLY
shares CS mux slot 31. `ApuCfg.NumCapsets` stays 0. Remote 2026-10-02
`tb_g6lc_apu_vdk` 7 cases / 12 checks / 350 cycles, errors=0.
Enable=0: 12 ports / 0 cells. Enable=1: 1847 cells / 708 flip-flops.
`FeatureVirgl` stays illegal.

### VenusDestroyRpass Mesa vn_protocol vkDestroyRenderPass (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 83 / null allocator
        --> VenusDestroyRpass (vdr)
        --? VenusRenderPass (vrp)
        --> GenHandle (gnh) RETIRE
        --? ApuSys
```

`VdrEn` defaults to 0. LOOKUP RPASS then RETIRE. Clears `rp_ok`.
Compact gpipe does not pin rpass. GENERATE_REPLY shares CS mux slot
31. `ApuCfg.NumCapsets` stays 0. Remote 2026-10-02 `tb_g6lc_apu_vdr`
7 cases / 12 checks / 350 cycles, errors=0. Enable=0: 12 ports / 0
cells. Enable=1: 1847 cells / 708 flip-flops. `FeatureVirgl` stays
illegal.

### VenusDestroyBuf Mesa vn_protocol vkDestroyBuffer (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 51 / null allocator
        --> VenusDestroyBuf (vdb)
        --? VenusCreateBuffer (vxb)
        --> GenHandle (gnh) RETIRE
        --? ApuSys
```

`VdbEn` defaults to 0. LOOKUP BUFFER then `APU_GNH_RETIRE`.
GENERATE_REPLY shares CS mux slot 31. Remote 2026-10-02
`tb_g6lc_apu_vdb` 7 cases / 12 checks / 350 cycles, errors=0.
Enable=1: 1847 cells / 708 flip-flops. `FeatureVirgl` stays illegal.

### VenusDestroyImg Mesa vn_protocol vkDestroyImage (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 55 / null allocator
        --> VenusDestroyImg (vdg)
        --? VenusCreateImage (vxi)
        --> GenHandle (gnh) RETIRE
        --? ApuSys
```

`VdgEn` defaults to 0. LOOKUP IMAGE then RETIRE. Remote 2026-10-02
`tb_g6lc_apu_vdg` 7 cases / 12 checks / 350 cycles, errors=0.
Enable=1: 1848 cells / 708 flip-flops. `FeatureVirgl` stays illegal.

### VenusFreeMemory Mesa vn_protocol vkFreeMemory (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 22 / null allocator
        --> VenusFreeMemory (vfe)
        --? VenusAllocMemory (vam)
        --> GenHandle (gnh) RETIRE
        --? ApuSys
```

`VfeEn` defaults to 0. LOOKUP MEMORY then RETIRE after buffer and
image are retired. Remote 2026-10-02 `tb_g6lc_apu_vfe` 7 cases / 12
checks / 350 cycles, errors=0. Enable=1: 1846 cells / 708 flip-flops.
`FeatureVirgl` stays illegal.

### VenusDestroyModule Mesa vn_protocol vkDestroyShaderModule (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 60 / null allocator
        --> VenusDestroyModule (vdm)
        --? VenusEncode (vnenc)
        --> GenHandle (gnh) RETIRE
        --? ApuSys
```

`VdmEn` defaults to 0. LOOKUP MODULE then RETIRE; clears `loaded_q`.
Remote 2026-10-02 `tb_g6lc_apu_vdm` 7 cases / 12 checks / 350 cycles,
errors=0. Enable=1: 1847 cells / 708 flip-flops. `FeatureVirgl` stays
illegal.

### VenusDestroyPipe Mesa vn_protocol vkDestroyPipeline (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 67 / null allocator
        --> VenusDestroyPipe (vdp)
        --? VenusComputePipe (vcp)
        --? VenusGraphicsPipe (vgp)
        --> GenHandle (gnh) RETIRE
        --? ApuSys
```

`VdpEn` defaults to 0. LOOKUP PIPELINE then RETIRE; clears
`pipe_bound`. Happy path retires graphics then compute pipeline.
Remote 2026-10-02 `tb_g6lc_apu_vdp` 7/12/350, Enable=1 1846/708.
`FeatureVirgl` stays illegal.

### VenusDestroyPlayout Mesa vn_protocol vkDestroyPipelineLayout (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 69 / null allocator
        --> VenusDestroyPlayout (vdy)
        --? VenusPipeLayout (vpl)
        --> GenHandle (gnh) RETIRE
        --? ApuSys
```

`VdyEn` defaults to 0. LOOKUP PLAYOUT then RETIRE; clears `pl_ok`.
Remote 2026-10-02 `tb_g6lc_apu_vdy` 7/12/350, Enable=1 1846/708.
`FeatureVirgl` stays illegal.

### VenusDestroyDsl Mesa vn_protocol vkDestroyDescriptorSetLayout (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 73 / null allocator
        --> VenusDestroyDsl (vdt)
        --? VenusDescLayout (vdl)
        --> GenHandle (gnh) RETIRE
        --? ApuSys
```

`VdtEn` defaults to 0. LOOKUP DSLAYOUT then RETIRE; clears `dsl_ok`.
Remote 2026-10-02 `tb_g6lc_apu_vdt` 7/12/350, Enable=1 1846/708.
`FeatureVirgl` stays illegal.

### VenusDestroyPool Mesa vn_protocol vkDestroyDescriptorPool (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 75 / null allocator
        --> VenusDestroyPool (vdq)
        --? VenusDescPool (vpo)
        --> GenHandle (gnh) RETIRE
        --? ApuSys
```

`VdqEn` defaults to 0. LOOKUP POOL then RETIRE; clears `pool_ok`.
Remote 2026-10-02 `tb_g6lc_apu_vdq` 7/12/350, Enable=1 1847/708.
bru FSM state enum is 8 bits. `FeatureVirgl` stays illegal.

### VenusFreeDescset Mesa vn_protocol vkFreeDescriptorSets (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 78 / count 1 / pool not LOOKed up
        --> VenusFreeDescset (vfs)
        --? VenusDescAlloc (vda)
        --? VenusDestroyPool (vdq)
        --> GenHandle (gnh) RETIRE
        --? ApuSys
```

`VfsEn` defaults to 0. LOOKUP DESCSET then RETIRE; clears `dset_ok`.
Remote 2026-10-02 `tb_g6lc_apu_vfs` 7/12/372, Enable=1 2043/772.
`FeatureVirgl` stays illegal.

### VenusResetCmdbuf Mesa vn_protocol vkResetCommandBuffer (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 92 / reset flags 0
        --> VenusResetCmdbuf (vrc)
        --? VenusAlloc (vac)
        --> GenHandle (gnh) LOOKUP
        --? ApuSys
```

`VrcEn` defaults to 0. LOOKUP CMDBUF; no RETIRE.
Remote 2026-10-02 `tb_g6lc_apu_vrc` 7/12/314, Enable=1 1622/644.
`FeatureVirgl` stays illegal.

### VenusFreeCmdbuf Mesa vn_protocol vkFreeCommandBuffers (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 89 / count 1 / vac pool not LOOKed up
        --> VenusFreeCmdbuf (vfc)
        --? VenusAlloc (vac)
        --> GenHandle (gnh) RETIRE
        --? ApuSys
```

`VfcEn` defaults to 0. LOOKUP CMDBUF then RETIRE.
Remote 2026-10-02 `tb_g6lc_apu_vfc` 7/12/372, Enable=1 2043/772.
`FeatureVirgl` stays illegal.

### VenusDestroyDevice Mesa vn_protocol vkDestroyDevice (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 12 / null allocator
        --> VenusDestroyDevice (vdd)
        --? VenusCreateDevice (vcd)
        --> GenHandle (gnh) RETIRE
        --? ApuSys
```

`VddEn` defaults to 0. LOOKUP DEVICE then RETIRE. `apu_bru_op_e` is 7 bits.
Remote 2026-10-02 `tb_g6lc_apu_vdd` 7/12/328, Enable=1 1652/644.
`FeatureVirgl` stays illegal.

### VenusResetCmdPool Mesa vn_protocol vkResetCommandPool (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 87 / reset flags 0 / pool not LOOKed up
        --> VenusResetCmdPool (vpc)
        --? VenusAlloc (vac)
        --> GenHandle (gnh) LOOKUP DEVICE
        --? ApuSys
```

`VpcEn` defaults to 0. LOOKUP DEVICE; no RETIRE.
Remote 2026-10-02 `tb_g6lc_apu_vpc` 7/12/336, Enable=1 1816/708.
`FeatureVirgl` stays illegal.

### VenusDestroyCmdPool Mesa vn_protocol vkDestroyCommandPool (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 86 / null allocator / pool not LOOKed up
        --> VenusDestroyCmdPool (vdc)
        --? VenusAlloc (vac)
        --> GenHandle (gnh) LOOKUP DEVICE
        --? ApuSys
```

`VdcEn` defaults to 0. LOOKUP DEVICE; no RETIRE.
Remote 2026-10-02 `tb_g6lc_apu_vdc` 7/12/350, Enable=1 1847/708.
`FeatureVirgl` stays illegal.

### VenusDestroyInstance Mesa vn_protocol vkDestroyInstance (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 1 / null allocator
        --> VenusDestroyInstance (vdn)
        --? VenusCreateInstance (vci)
        --> GenHandle (gnh) RETIRE
        --? ApuSys
```

`VdnEn` defaults to 0. LOOKUP INSTANCE then RETIRE; clears `instanced_q`.
Remote 2026-10-02 `tb_g6lc_apu_vdn` 7/12/328, Enable=1 1651/644.
`FeatureVirgl` stays illegal.

### VenusFormatProps Mesa vn_protocol vkGetPhysicalDeviceFormatProperties (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 4 / format 37
        --> VenusFormatProps (vgf)
        --? VenusEnumeratePhys (vep)
        --> GenHandle (gnh) LOOKUP PHYS
        --? ApuSys
```

`VgfEn` defaults to 0. LOOKUP PHYS. Compact FEATURES `32'h00006083`.
Remote 2026-10-02 `tb_g6lc_apu_vgf` 7/12/340, Enable=1 1750/676.
`FeatureVirgl` stays illegal.

### VenusImageFormat Mesa vn_protocol vkGetPhysicalDeviceImageFormatProperties (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 5 / 2D linear STORAGE format 37
        --> VenusImageFormat (vip)
        --? VenusEnumeratePhys (vep)
        --? VenusCreateImage (vxi)
        --> GenHandle (gnh) LOOKUP PHYS
        --? ApuSys
```

`VipEn` defaults to 0. LOOKUP PHYS. Compact maxExtent 64.
Remote 2026-10-02 `tb_g6lc_apu_vip` 7/12/388, Enable=1 1885/676.
`FeatureVirgl` stays illegal.

### VenusDeviceExt Mesa vn_protocol vkEnumerateDeviceExtensionProperties (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 14 / count 0
        --> VenusDeviceExt (vxe)
        --? VenusEnumeratePhys (vep)
        --? VenusCreateDevice (vcd)
        --> GenHandle (gnh) LOOKUP PHYS
        --? ApuSys
```

`VxeEn` defaults to 0. LOOKUP PHYS. Compact count 0.
Remote 2026-10-02 `tb_g6lc_apu_vxe` 7/12/366, Enable=1 1750/644.
`FeatureVirgl` stays illegal.

### VenusResetDescPool Mesa vn_protocol vkResetDescriptorPool (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 76 / reset flags 0
        --> VenusResetDescPool (vrd)
        --? VenusDescPool (vpo)
        --> GenHandle (gnh) LOOKUP POOL
        --? ApuSys
```

`VrdEn` defaults to 0. LOOKUP POOL; no RETIRE; extra `!pool_ok`; clears `desc_bound`.
Remote 2026-10-02 `tb_g6lc_apu_vrd` 7/12/336, Enable=1 1814/708.
`FeatureVirgl` stays illegal.

### VenusInstanceExt Mesa vn_protocol vkEnumerateInstanceExtensionProperties (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 13 / count 0
        --> VenusInstanceExt (vie)
        --? VenusCreateInstance (vci)
        --? ApuSys
```

`VieEn` defaults to 0. Compact count 0; no GenHandle LOOKUP.
Remote 2026-10-02 `tb_g6lc_apu_vie` 7/12/344, Enable=1 1557/580.
`FeatureVirgl` stays illegal.

### VenusDeviceWait Mesa vn_protocol vkDeviceWaitIdle (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 20 / device
        --> VenusDeviceWait (vwl)
        --? VenusCreateDevice (vcd)
        --? VenusWaitIdle (vwi)
        --> GenHandle (gnh) LOOKUP DEVICE
        --? ApuSys
```

`VwlEn` defaults to 0. LOOKUP DEVICE; extra `!submitted_q`.
Remote 2026-10-02 `tb_g6lc_apu_vwl` 7/12/300, Enable=1 1587/644.
`FeatureVirgl` stays illegal.

### VenusSubresourceLayout Mesa vn_protocol vkGetImageSubresourceLayout (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 56 / COLOR mip 0 layer 0
        --> VenusSubresourceLayout (vsl)
        --? VenusCreateImage (vxi)
        --> GenHandle (gnh) LOOKUP IMAGE
        --? ApuSys
```

`VslEn` defaults to 0. LOOKUP IMAGE. Compact rowPitch 256 / size 16384.
Remote 2026-10-02 `tb_g6lc_apu_vsl` 7/12/388, Enable=1 1945/708.
`FeatureVirgl` stays illegal.

### VenusRenderGranularity Mesa vn_protocol vkGetRenderAreaGranularity (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 84 / 1x1
        --> VenusRenderGranularity (vrg)
        --? VenusRenderPass (vrp)
        --> GenHandle (gnh) LOOKUP RPASS
        --? ApuSys
```

`VrgEn` defaults to 0. LOOKUP RPASS; extra `!rp_ok`. Compact 1×1.
Remote 2026-10-02 `tb_g6lc_apu_vrg` 7/12/350, Enable=1 1845/708.
`FeatureVirgl` stays illegal.

### VenusSetLineWidth Mesa vn_protocol vkCmdSetLineWidth (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 96 / width 1.0
        --> VenusSetLineWidth (vlw)
        --? VenusBegin (vbg)
        --> GenHandle (gnh) LOOKUP CMDBUF
        --? ApuSys
```

`VlwEn` defaults to 0. LOOKUP CMDBUF; extra `!begun`. Compact width 1.0.
Remote 2026-10-02 `tb_g6lc_apu_vlw` 7/12/312, Enable=1 1627/644.
`FeatureVirgl` stays illegal.

### VenusSetDepthBias Mesa vn_protocol vkCmdSetDepthBias (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 97 / factors 0
        --> VenusSetDepthBias (vzb)
        --? VenusBegin (vbg)
        --> GenHandle (gnh) LOOKUP CMDBUF
        --? ApuSys
```

`VzbEn` defaults to 0. LOOKUP CMDBUF; extra `!begun`. Compact factors 0.
Remote 2026-10-02 `tb_g6lc_apu_vzb` 7/12/336, Enable=1 1687/644.
`FeatureVirgl` stays illegal.

### VenusSetBlendConst Mesa vn_protocol vkCmdSetBlendConstants (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 98 / zeros
        --> VenusSetBlendConst (vbc)
        --? VenusBegin (vbg)
        --> GenHandle (gnh) LOOKUP CMDBUF
        --? ApuSys
```

`VbcEn` defaults to 0. LOOKUP CMDBUF; extra `!begun`. Compact zeros.
Remote 2026-10-02 `tb_g6lc_apu_vbc` 7/12/348, Enable=1 1720/644.
`FeatureVirgl` stays illegal.

### VenusSetDepthBounds Mesa vn_protocol vkCmdSetDepthBounds (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 99 / min 0 max 1.0
        --> VenusSetDepthBounds (vbo)
        --? VenusBegin (vbg)
        --> GenHandle (gnh) LOOKUP CMDBUF
        --? ApuSys
```

`VboEn` defaults to 0. LOOKUP CMDBUF; extra `!begun`. Compact min 0 max 1.0.
Remote 2026-10-02 `tb_g6lc_apu_vbo` 7/12/324, Enable=1 1662/644.
`FeatureVirgl` stays illegal.

### VenusSetStencilCompare Mesa vn_protocol vkCmdSetStencilCompareMask (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 100 / FRONT_AND_BACK mask all-ones
        --> VenusSetStencilCompare (vcm)
        --? VenusBegin (vbg)
        --> GenHandle (gnh) LOOKUP CMDBUF
        --? ApuSys
```

`VcmEn` defaults to 0. LOOKUP CMDBUF; extra `!begun`. Compact FRONT_AND_BACK mask all-ones.
Remote 2026-10-02 `tb_g6lc_apu_vcm` 7/12/324, Enable=1 1688/644.
`FeatureVirgl` stays illegal.

### VenusSetStencilWrite Mesa vn_protocol vkCmdSetStencilWriteMask (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 101 / FRONT_AND_BACK mask all-ones
        --> VenusSetStencilWrite (vwm)
        --? VenusBegin (vbg)
        --> GenHandle (gnh) LOOKUP CMDBUF
        --? ApuSys
```

`VwmEn` defaults to 0. LOOKUP CMDBUF; extra `!begun`. Compact FRONT_AND_BACK mask all-ones.
Remote 2026-10-02 `tb_g6lc_apu_vwm` 7/12/324, Enable=1 1689/644.
`FeatureVirgl` stays illegal.

### VenusSetStencilRef Mesa vn_protocol vkCmdSetStencilReference (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 102 / FRONT_AND_BACK ref 0
        --> VenusSetStencilRef (vrf)
        --? VenusBegin (vbg)
        --> GenHandle (gnh) LOOKUP CMDBUF
        --? ApuSys
```

`VrfEn` defaults to 0. LOOKUP CMDBUF; extra `!begun`. Compact FRONT_AND_BACK ref 0.
Remote 2026-10-02 `tb_g6lc_apu_vrf` 7/12/324, Enable=1 1657/644.
`FeatureVirgl` stays illegal.

### VenusCopyBuffer Mesa vn_protocol vkCmdCopyBuffer (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 112 / one 2048-byte non-overlapping region
        --> VenusCopyBuffer (vcc)
        --? VenusBegin (vbg)
        --> GenHandle (gnh) LOOKUP CMDBUF then BUFFER src then BUFFER dst
        --? ApuSys
```

`VccEn` defaults to 0. LOOKUP CMDBUF then src/dst BUFFER; extra `!begun` / `in_rp`. Compact srcOff 0, dstOff 2048, size 2048.
Remote 2026-10-02 `tb_g6lc_apu_vcc` 8/13/505, Enable=1 2205/772.
`FeatureVirgl` stays illegal.

### VenusCopyImage Mesa vn_protocol vkCmdCopyImage (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 113 / TRANSFER layouts, 32x64 half-window
        --> VenusCopyImage (vcy)
        --? VenusBegin (vbg)
        --> GenHandle (gnh) LOOKUP CMDBUF then IMAGE src then IMAGE dst
        --? ApuSys
```

`VcyEn` defaults to 0. LOOKUP CMDBUF then src/dst IMAGE; extra `!begun` / `in_rp`. Compact dst x=32, extent 32x64x1.
Remote 2026-10-02 `tb_g6lc_apu_vcy` 8/13/785, Enable=1 3714/1284.
`FeatureVirgl` stays illegal.

### VenusBlitImage Mesa vn_protocol vkCmdBlitImage (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 114 / NEAREST 32x64 blit
        --> VenusBlitImage (vbl)
        --? VenusBegin (vbg)
        --> GenHandle (gnh) LOOKUP CMDBUF then IMAGE src then IMAGE dst
        --? ApuSys
```

`VblEn` defaults to 0. LOOKUP CMDBUF then src/dst IMAGE; extra `!begun` / `in_rp`. Compact NEAREST filter 0.
Remote 2026-10-02 `tb_g6lc_apu_vbl` 8/13/839, Enable=1 3849/1284.
`FeatureVirgl` stays illegal.

### VenusCopyBufToImg Mesa vn_protocol vkCmdCopyBufferToImage (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 115 / TRANSFER_DST, 32x32 color window
        --> VenusCopyBufToImg (vbt)
        --? VenusBegin (vbg)
        --> GenHandle (gnh) LOOKUP CMDBUF then BUFFER src then IMAGE dst
        --? ApuSys
```

`VbtEn` defaults to 0. LOOKUP CMDBUF then BUFFER src then IMAGE dst; extra `!begun` / `in_rp`. Compact 32x32 extent (4096 bytes).
Remote 2026-10-02 `tb_g6lc_apu_vbt` 8/13/727, Enable=1 3577/1284.
`FeatureVirgl` stays illegal.

### VenusCopyImgToBuf Mesa vn_protocol vkCmdCopyImageToBuffer (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 116 / TRANSFER_SRC, 32x32 color window
        --> VenusCopyImgToBuf (vic)
        --? VenusBegin (vbg)
        --> GenHandle (gnh) LOOKUP CMDBUF then IMAGE src then BUFFER dst
        --? ApuSys
```

`VicEn` defaults to 0. LOOKUP CMDBUF then IMAGE src then BUFFER dst; extra `!begun` / `in_rp`. Compact 32x32 (4096 bytes).
Remote 2026-10-02 `tb_g6lc_apu_vic` 8/13/727, Enable=1 3575/1284.
`FeatureVirgl` stays illegal.

### VenusUpdateBuffer Mesa vn_protocol vkCmdUpdateBuffer (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 117 / offset 0 size 4 data 0
        --> VenusUpdateBuffer (vub)
        --? VenusBegin (vbg)
        --> GenHandle (gnh) LOOKUP CMDBUF then BUFFER
        --? ApuSys
```

`VubEn` defaults to 0. LOOKUP CMDBUF then BUFFER; extra `!begun` / `in_rp`. Compact 4-byte zero word.
Remote 2026-10-02 `tb_g6lc_apu_vub` 8/13/421, Enable=1 1947/708.
`FeatureVirgl` stays illegal.

### VenusFillBuffer Mesa vn_protocol vkCmdFillBuffer (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 118 / offset 0 size 4096 data 0
        --> VenusFillBuffer (vfl)
        --? VenusBegin (vbg)
        --> GenHandle (gnh) LOOKUP CMDBUF then BUFFER
        --? ApuSys
```

`VflEn` defaults to 0. LOOKUP CMDBUF then BUFFER; extra `!begun` / `in_rp`. Compact size 4096 data 0.
Remote 2026-10-02 `tb_g6lc_apu_vfl` 8/13/419, Enable=1 1947/708.
`FeatureVirgl` stays illegal.

### VenusClearColor Mesa vn_protocol vkCmdClearColorImage (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 119 / TRANSFER_DST, zero color, one COLOR range
        --> VenusClearColor (vcl)
        --? VenusBegin (vbg)
        --> GenHandle (gnh) LOOKUP CMDBUF then IMAGE
        --? ApuSys
```

`VclEn` defaults to 0. LOOKUP CMDBUF then IMAGE; extra `!begun` / `in_rp`. Compact TRANSFER_DST zeros.
Remote 2026-10-02 `tb_g6lc_apu_vcl` 8/13/671, Enable=1 3219/1220.
`FeatureVirgl` stays illegal.

### VenusDrawIndirect Mesa vn_protocol vkCmdDrawIndirect (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 108 / drawCount 1 stride 16
        --> VenusDrawIndirect (vio)
        --? VenusBegin (vbg)
        --> GenHandle (gnh) LOOKUP CMDBUF then BUFFER
        --? ApuSys
```

`VioEn` defaults to 0. LOOKUP CMDBUF then BUFFER; extra `begun` / `in_rp` / `pipe_bound`. Compact drawCount 1 stride 16. `APU_DRI_*` (DestroyInstance keeps `APU_DIN_*`).
Remote 2026-10-02 `tb_g6lc_apu_vio` 8/13/405, Enable=1 1915/708.
`FeatureVirgl` stays illegal.

### VenusDrawIdxIndirect Mesa vn_protocol vkCmdDrawIndexedIndirect (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 109 / drawCount 1 stride 20
        --> VenusDrawIdxIndirect (vix)
        --? VenusBegin (vbg)
        --> GenHandle (gnh) LOOKUP CMDBUF then BUFFER
        --? ApuSys
```

`VixEn` defaults to 0. LOOKUP CMDBUF then BUFFER; extra `begun` / `in_rp` / `pipe_bound` / `vtx_bound` / `idx_bound`. Compact drawCount 1 stride 20.
Remote 2026-10-02 `tb_g6lc_apu_vix` 8/13/405, Enable=1 1917/708.
`FeatureVirgl` stays illegal.

### VenusClearDepth Mesa vn_protocol vkCmdClearDepthStencilImage (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 120 / TRANSFER_DST depth 1.0 ASPECT_DEPTH
        --> VenusClearDepth (vds)
        --? VenusBegin (vbg)
        --> GenHandle (gnh) LOOKUP CMDBUF then IMAGE
        --? ApuSys
```

`VdsEn` defaults to 0. LOOKUP CMDBUF then IMAGE; extra `!begun` / `in_rp`. Compact depth 1.0 stencil 0.
Remote 2026-10-02 `tb_g6lc_apu_vds` 8/13/685, Enable=1 3158/1220.
`FeatureVirgl` stays illegal.

### VenusClearAttach Mesa vn_protocol vkCmdClearAttachments (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 121 / one COLOR attach 64x64 rect
        --> VenusClearAttach (vat)
        --? VenusBegin (vbg)
        --> GenHandle (gnh) LOOKUP CMDBUF
        --? ApuSys
```

`VatEn` defaults to 0. LOOKUP CMDBUF; extra `begun` / `in_rp`. Compact one COLOR attachment, 64x64 rect, zero color.
Remote 2026-10-02 `tb_g6lc_apu_vat` 8/13/659, Enable=1 3123/1156.
`FeatureVirgl` stays illegal.

### VenusDispatchIndirect Mesa vn_protocol vkCmdDispatchIndirect (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 111 / offset 0
        --> VenusDispatchIndirect (vin)
        --? VenusBegin (vbg)
        --> GenHandle (gnh) LOOKUP CMDBUF then BUFFER
        --? ApuSys
```

`VinEn` defaults to 0. LOOKUP CMDBUF then BUFFER; extra `begun` / `!in_rp` / `pipe_bound` / `desc_bound` / `loaded`. Compact offset 0. Does not Kick the compute add; VenusDispatch (vnd) still faults type 111.
Remote 2026-10-02 `tb_g6lc_apu_vin` 8/13/379, Enable=1 1849/708.
`FeatureVirgl` stays illegal.

### VenusResolveImage Mesa vn_protocol vkCmdResolveImage (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 122 / TRANSFER layouts, 32x32 half-window
        --> VenusResolveImage (vrs)
        --? VenusBegin (vbg)
        --> GenHandle (gnh) LOOKUP CMDBUF then IMAGE src then IMAGE dst
        --? ApuSys
```

`VrsEn` defaults to 0. LOOKUP CMDBUF then IMAGE src/dst; extra `!begun` / `in_rp`. Compact dst x=32 extent 32x32.
Remote 2026-10-02 `tb_g6lc_apu_vrs` 8/13/783, Enable=1 3715/1284.
`FeatureVirgl` stays illegal.

### VenusGetFenceStatus Mesa vn_protocol vkGetFenceStatus (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 38 / compact VK_SUCCESS
        --> VenusGetFenceStatus (vgs)
        --? VenusCreateDevice (vcd)
        --> GenHandle (gnh) LOOKUP DEVICE
        --? ApuSys
```

`VgsEn` defaults to 0. LOOKUP DEVICE; compact signaled VK_SUCCESS. No FENCE kind. CreateFence=35 skipped.
Remote 2026-10-02 `tb_g6lc_apu_vgs` 8/13/377, Enable=1 1781/708.
`FeatureVirgl` stays illegal.

### VenusWaitForFences Mesa vn_protocol vkWaitForFences (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 39 / count 1 waitAll timeout 0
        --> VenusWaitForFences (vwf)
        --? VenusCreateDevice (vcd)
        --> GenHandle (gnh) LOOKUP DEVICE
        --? ApuSys
```

`VwfEn` defaults to 0. LOOKUP DEVICE; extra `submitted_q`. Compact count 1 waitAll timeout 0.
Remote 2026-10-02 `tb_g6lc_apu_vwf` 8/13/405, Enable=1 1915/708.
`FeatureVirgl` stays illegal.

### VenusResetFences Mesa vn_protocol vkResetFences (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 37 / count 1
        --> VenusResetFences (vfr)
        --? VenusCreateDevice (vcd)
        --> GenHandle (gnh) LOOKUP DEVICE
        --? ApuSys
```

`VfrEn` defaults to 0. LOOKUP DEVICE; compact count 1. No FENCE kind.
Remote 2026-10-02 `tb_g6lc_apu_vfr` 8/13/391, Enable=1 1815/708.
`FeatureVirgl` stays illegal.

### VenusDestroyFence Mesa vn_protocol vkDestroyFence (P0, 2026-10-02)

```text
diagnostic TB client
    ==> CS type 36 / device plus fence plus null allocator
        --> VenusDestroyFence (vfn)
        --? VenusCreateDevice (vcd)
        --> GenHandle (gnh) LOOKUP DEVICE
        --? ApuSys
```

`VfnEn` defaults to 0. LOOKUP DEVICE; no RETIRE. No FENCE kind.
Remote 2026-10-02 `tb_g6lc_apu_vfn` 8/13/379, Enable=1 1845/708.
`FeatureVirgl` stays illegal.

AI storage, arithmetic, residency and completion mechanisms may be reused only
behind graphics-owned interfaces and explicit coherence/precision tests; no
mandatory MatrixEn, custom descriptors, UIO daemon or game plugin. HDMI remains
a separate consumer of a completed common surface. `ApuOff`, all graphics gates
and `FeatureVirgl` legality are unchanged by this source-review increment.

## 16. Engine arborescence (live, 3c-ii + 5a xfer + F5 descriptors + 3d-c roll-up)

```text
ApuSys (g6lc_apu_sys)                       [VenusEn: gen_venus]
    --> AxiLiteTransport (g6lc_apu_axi_lite)
        --> VirtioTop --> VirtioMmio      ==> notify levels out / used event + ISR in
        [VenusEn: no ApuControl; be_* seam]
    --> VenusSystem (g6lc_apu_vgsys)
        --> VirtqueueWalker (vqwalk)      ==> avail/desc/used beats (dom 0)
            <-> VenusTop (vgtop)          chain_* in, cpl held handshake back
        --> VenusTop (vgtop)
            --> ControlQueue (vgctl)      <-> ObjTab, vgpages          mp CTL
            --> RingPump (vnpump)                                        mp PUMP
                --> Front (vnfront)
                    --> Decoder (vndec)  --> ReplyBuilder (vnrep)
                    <-> ObjTab (objtab) <-> ObjPay (objpay) <-> CmdRec (cmdrec)
                <-> CmdExec (cmdexec)    work port
                    --> ShaderCore (shcore) --> ModuleScanner (shmod) --> WaveEngine (shwave)   mp SH
                    --> Xfer (xfer)        --> DmaRead/DmaWrite checked pair ==> AXI master (xfer)
            --> PageAllocator (vgpages)
        --> MemoryPort (apmem)            5 x apu_mp fixed priority ==> tdma 2:1 join (a=apmem, b=xfer)
                                          ==> one AXI4 master (dma_req_o)
    ==> guest RAM window {DmaWindowBase, DmaWindowBytes} / aperture {APU_SHM_BASE, APU_SHM_BYTES}

Descriptor-memory path (F5): pool/set backing pages vgpages ALLOC_PRIV ->
vnfront bump-allocates set tables and writes 32-byte records through
RingPump's mp PUMP port; CmdExec sideband = set_base/dyn_off/boff per bound
set (layout rows read from ObjPay at dispatch; set/pool lifecycle =
RETIRE_KIDS sweep, DSL compatibility = FNV-1a content hash in the DSL
entry's state word); WaveEngine's LSU fetches
records on mp SH (8-entry {set,binding,idx} cache, invalidated per
dispatch) -> aperture.  Aperture split (guest-allocator collision fix): the
32 MiB window is 24 MiB guest-visible (APU_VG_GUEST_BYTES, advertised as
SHM_LEN) + 8 MiB device-private tail; guest-kernel MAP_BLOB extents are
ALLOC_AT inside the guest span only, while device-internal allocations
(descriptor pools) take ALLOC_PRIV in the tail.  vgpages' free bitmap is
hierarchical: a tc_sram Pages/64 x 64b word array plus a flop summary
(empty/full) per word, so first-fit skips 64 pages at a time and the
same code scales to 256 MiB (65536 pages) — worst-case ALLOC measured
2050 cycles at Pages=65536.  Two memory heaps (memory-model
truthfulness, §12.3 C): heap0 = the private arena (type 0
DEVICE_LOCAL, eager ALLOC_PRIV at vkAllocateMemory) and heap1 = the
guest span (type 1 DEVICE_LOCAL|HOST_VISIBLE|HOST_COHERENT, LAZY — no
backing until MAP_BLOB ALLOC_ATs the kernel-chosen extent; UNMAP_BLOB
frees it and drops the blob to bind_offset 0 — there is no
re-privatization for memory-backed blobs).  Engine use of an
unbacked type-1 memory fails truthfully (poison/DEVICE_LOST);
blob-owned CREATE_BLOB backing is lazy too (Mesa's 8 MiB cs shmem pool
cannot fit an 8 MiB private arena even empty).  vnpump paces ring
tail polls with an exponential gap (1..256, doubling while a live
non-idle ring round finds no new tail; reset on work/NotifyRing/
doorbell) — 16 aperture reads per 4096 idle-but-live cycles vs 580
unpaced.
```

### What §16 still waits on (§12.3 phases B–D)

| Waiting on | Phase | Exit |
|---|---|---|
| Full-SoC Linux (3d-a bare-metal probe and 3d-b stock-stack RTL-in-the-loop landed: §11 rows 3d-a/3d-b, `architecture/uncore/apu-venus-command-trace.md`) | B | stock Ubuntu on the Variane testharness itself (R3b program): same `vulkaninfo`/dispatch under real caches and the non-coherent DMA contract (`zicbom`/`svpbmt`, no `dma-coherent`) |
| Sampler / raster (Xfer landed: `g6lc_apu_xfer`, §11 row 5a) | C | images/formats/sampler with memory-resident descriptors (F5), `vkCmdCopyImage`/blits, TBDR raster + ROP into `tc_sram` tiles; G0/A5 via Zink |
| ~~Memory-resident descriptors~~ (F5 **landed** — §11 row F5: records in aperture memory, LSU dynamic-index fetch + 8-entry cache; the descriptor-memory path is in the tree above) | C | images/sampler arrays on the reserved record half (`vkCmdCopyImage`/blits), `tc_sram` descriptor cache beyond 8 entries |
| `shwave` 1 IPC + `ShaderCores` | D | per-wave throughput 1 IPC; multi-core dispatch via the cluster pattern; `DramChannels` by profile |
| virtio-pci endpoint function (F4) | D | five virtio-pci capabilities + shared-memory capability over a BAR into the aperture |
| Scanout / WSI | D | `RESOURCE_UUID`/dma-buf export (G2) |
