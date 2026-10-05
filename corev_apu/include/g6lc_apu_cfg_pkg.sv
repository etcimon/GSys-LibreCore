// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// G6LC APU (API-neutral graphics) configuration package — uncore plane.
//
// The APU is deliberately not part of config_pkg::ai_cfg_t and does not consume
// a core issue port. This package owns the SoC-visible grant surface: transport,
// queue depth, firmware reservation, DMA limits and the features that may be
// advertised. The implementation mask is checked against the requested grant;
// a profile that cannot execute the promised contract must fail legality instead
// of silently dropping feature bits.
//
// P1 status: modern virtio-mmio transport/register state only. Virgl, EDID,
// indirect descriptors, event_idx and in-order completion remain unimplemented
// and are therefore rejected by apu_cfg_legal until their datapaths exist.

package g6lc_apu_cfg_pkg;

  // Guest-absolute P1 testharness placement. This is adjacent to, and not an
  // alias of, the GPIO/AI island window at 0x4000_0000..0x4000_0fff.
  localparam logic [63:0] APU_MMIO_BASE = 64'h0000_0000_4000_1000;
  localparam logic [63:0] APU_MMIO_LEN  = 64'd4096;
  localparam logic [63:0] APU_CONTROL_BASE = 64'h0000_0000_4000_2000;
  localparam logic [63:0] APU_CONTROL_LEN = 64'd4096;
  // Linux PLIC specifier (1-based) → irq_sources[N-1]. Source 8 is the AI
  // island (`irq_sources[7]`); the APU takes the next free line.
  localparam int unsigned APU_IRQ_SOURCE = 9;
  // Implemented execution file. An enabled device must name these sizes.
  // IMEM has no separate config field; its index is $clog2 of this depth.
  localparam int unsigned APU_EXEC_THREADS    = 4;
  localparam int unsigned APU_EXEC_REGS       = 8;
  localparam int unsigned APU_EXEC_IMEM_WORDS = 16;
  localparam int unsigned APU_EXEC_DMEM_WORDS = 64;

  // virtio-gpu has a control queue and a cursor queue. Keep the count explicit
  // so a future multi-queue device cannot silently reinterpret queue 0/1.
  localparam int unsigned APU_NUM_QUEUES = 2;

  // A P1 transport-only profile has no reserved resident-firmware hart. Virgl
  // profiles must name a real hart and private RAM before they are legal.
  localparam int unsigned APU_FW_HART_UNASSIGNED = 32'hffff_ffff;

  // Virtio feature numbers implemented by the current RTL. VERSION_1 is the
  // modern-device bit; RING_RESET is implemented by the queue-state block.
  localparam int unsigned VIRTIO_F_VERSION_1_BIT  = 32;
  localparam int unsigned VIRTIO_F_RING_RESET_BIT = 40;
  localparam logic [63:0] APU_IMPL_FEATURES =
      (64'd1 << VIRTIO_F_VERSION_1_BIT) |
      (64'd1 << VIRTIO_F_RING_RESET_BIT);

  typedef struct packed {
    logic        Enable;
    // Requested device features. Fields are split by semantic grant so a
    // compiler cannot accidentally set an unrelated bit in a raw mask.
    logic        FeatureVirgl;
    logic        FeatureEdid;
    logic        FeatureIndirectDesc;
    logic        FeatureEventIdx;
    logic        FeatureInOrder;
    logic        FeatureRingReset;
    int unsigned NumQueues;
    int unsigned QueueDepth;
    int unsigned MaxContexts;
    int unsigned MaxResources;
    int unsigned MaxCmdBytes;
    int unsigned MaxShaderBytes;
    int unsigned DmaMaxOutstanding;
    logic        DmaCoherent;
    logic        DmaReadEn;
    logic        DmaWriteEn;
    int unsigned DmaWriteMaxBytes;
    int unsigned DmaReadMaxBytes;
    int unsigned DmaReadBurstBeats;
    logic [63:0] DmaWindowBase;
    logic [63:0] DmaWindowBytes;
    logic        SgEn;
    int unsigned SgMaxEntries;
    int unsigned SgMaxTransferBytes;
    int unsigned NumScanouts;
    int unsigned NumCapsets;
    int unsigned FirmwareHart;
    logic [63:0] FirmwareRamBase;
    logic [63:0] FirmwareRamBytes;
    logic [63:0] MmioBase;
    logic [63:0] MmioLength;
    logic [63:0] ControlBase;
    logic [63:0] ControlLength;
    int unsigned IrqSource;
    // Local three-letter leaf ids (vsb, sny, gnw, ...) are LibreCore APU
    // names used on grant bits `XxxEn` and modules `g6lc_apu_vgpu_xxx`
    // unless the field comment names another module. The PascalCase token
    // is the human-readable alias. Module handoffs are drawn from those
    // names in corev_apu/apu/AGENTS-impl-interplays.md.
    // ExecCluster (exec): Native execution cluster: one physical FP32/integer lane, lockstep
    // fragment-quad contexts. Default-off; FeatureVirgl stays illegal.
    logic        ExecEn;
    int unsigned ExecQuadThreads;
    int unsigned ExecRegs;
    int unsigned ExecMemWords;
    // CoverSample (cover): One-sample triangle coverage. Default-off. Does not paint, sample,
    // or advertise virgl.
    logic        CoverEn;
    // FragStore (frag): Interpolated RGBA8 store of one covered sample. Default-off.
    logic        FragEn;
    // TexelOrigin (texel): One unfiltered RGBA8 texel at (0,0). Default-off. Not a sampler.
    logic        TexelEn;
    // CmdPayloadDecode (proto): Virtio-gpu command payload decode. Default-off. Not a virtqueue walk.
    logic        ProtoEn;
    // UsedPublish (used): Local used-element publication and its interrupt. Default-off.
    logic        UsedEn;
    // AvailDescriptor (avail): One avail-ring descriptor. Default-off. Not a descriptor chain.
    logic        AvailEn;
    // ResourceBacking (back): One guest backing entry for an existing resource. Default-off.
    // Not a guest-memory read and not a descriptor chain.
    logic        BackEn;
    // BackingIntoResource (xfer): One read of that stored entry into the resource. Default-off.
    // Not a guest write and not a descriptor chain.
    logic        XferEn;
    // UsedGuestWrite (uwr): One guest write of the local used element. Default-off.
    // Not used.idx and not a descriptor chain.
    logic        UwrEn;
    // UsedIndexStore (uidx): One guest store of used.idx. Default-off. Not a second element
    // and not a descriptor chain.
    logic        UidxEn;
    // ResourceSurface (surf): One covered sample from the resource image. Default-off.
    // Not a draw command and not the HDMI buffer.
    logic        SurfEn;
    // FragReadback (rdb): One guest readback of the fragment surface. Default-off.
    // Not a draw, not a descriptor chain, and not the HDMI buffer.
    logic        RdbEn;
    // Submit3dChain (sub): One SUBMIT_3D three-descriptor chain. Default-off. Reads the
    // 32-byte header only. Not the execbuffer and not a draw.
    logic        SubEn;
    // ExecBufferRead (buf): One read of the execbuffer named by that submit. Default-off.
    // Not a command decode and not a draw.
    logic        BufEn;
    // FirstCommandDecode (dec): One decode of the first command in that buffer. Default-off.
    // Not the rest of the stream and not a draw.
    logic        DecEn;
    // VertexShaderCreate (sh): The shader create that follows that surface. Default-off.
    // The TGSI text stays in the buffer.
    logic        ShEn;
    // FragShaderCreate (fs): The fragment shader create that follows the vertex shader.
    // Default-off. The TGSI text stays in the buffer.
    logic        FsEn;
    // VertexElementsCreate (ve): The vertex-elements object that follows the fragment shader.
    // Default-off. Two attributes, position then uv.
    logic        VeEn;
    // SamplerViewCreate (sv): The sampler view that follows the vertex elements. Default-off.
    // Not a texture sample.
    logic        SvEn;
    // SamplerStateCreate (ss): The sampler state that follows the sampler view. Default-off.
    // Not a texture sample.
    logic        SsEn;
    // BlendCreate (bl): The blend object that follows the sampler state. Default-off.
    // Not a draw.
    logic        BlEn;
    // DepthStencilCreate (ds): The depth-stencil object that follows the blend object.
    // Default-off. Depth and stencil stay off.
    logic        DsEn;
    // RasterizerCreate (rz): The rasterizer object that follows the depth-stencil object.
    // Default-off. Not a triangle walk.
    logic        RzEn;
    // BlendBind (bb): The blend bind that follows the rasterizer object. Default-off.
    // Not a draw.
    logic        BbEn;
    // DepthStencilBind (db): The depth-stencil bind that follows the blend bind. Default-off.
    // Depth and stencil stay off.
    logic        DbEn;
    // RasterizerBind (rb): The rasterizer bind that follows the depth-stencil bind.
    // Default-off. Not a triangle walk.
    logic        RbEn;
    // VertexShaderBind (vsb): The vertex-shader bind that follows the rasterizer bind.
    // Default-off. The TGSI text stays in the buffer.
    logic        VsbEn;
    // FragShaderBind (fsb): The fragment-shader bind that follows the vertex-shader bind.
    // Default-off. The TGSI text stays in the buffer.
    logic        FsbEn;
    // VertexElementsBind (veb): The vertex-elements bind that follows the fragment-shader bind.
    // Default-off.
    logic        VebEn;
    // SamplerStateBind (ssb): The sampler-state bind that follows the vertex-elements bind.
    // Default-off. Not a texture sample.
    logic        SsbEn;
    // SamplerViewSet (svb): The sampler-view set that follows the sampler-state bind.
    // Default-off. Not a texture sample.
    logic        SvbEn;
    // ResourceInlineWrite (iw): The vertex inline write that follows the sampler-view set.
    // Default-off. The floats stay in the buffer.
    logic        IwEn;
    // VertexBuffersSet (vb): The vertex-buffer set that follows the inline write.
    // Default-off. Not a vertex fetch.
    logic        VbEn;
    // ScissorSet (sci): The scissor that follows the vertex-buffer set.
    // Default-off. The box is 640 by 480.
    logic        SciEn;
    // ViewportSet (vp): The viewport that follows the scissor. Default-off.
    logic        VpEn;
    // FramebufferSet (fbo): The framebuffer state that follows the viewport. Default-off.
    logic        FboEn;
    // ClearSet (clr): The clear that follows the framebuffer state. Default-off.
    logic        ClrEn;
    // DrawVbo (drw): The draw that follows the clear. Default-off. Not a raster walk.
    logic        DrwEn;
    // ContextCreate (ctx): CTX_CREATE for context 1. Default-off. Not an OS context.
    logic        CtxEn;
    // ResourceCreate3d (c3d): The two RESOURCE_CREATE_3D records. Default-off. Not an allocation.
    logic        C3dEn;
    // ContextAttach (att): The three CTX_ATTACH records. Default-off. Not a guest mapping.
    logic        AttEn;
    // SceneResponse (rsp): The scene submit response. Default-off. Not a pixel store.
    logic        RspEn;
    // CapsetInfo (nfo): GET_CAPSET_INFO. Default-off. The answer is no capset.
    logic        NfoEn;
    // CapsetGet (cap): GET_CAPSET. Default-off. No capset blob.
    logic        CapEn;
    // ScanoutSet (scn): SET_SCANOUT of resource 4. Default-off. Not a HDMI mode.
    logic        ScnEn;
    // ResourceFlush (flu): RESOURCE_FLUSH of that scanout. Default-off. Not a present.
    logic        FluEn;
    // SceneChain (chn): The scene submit's three-descriptor chain. Default-off.
    // Not the one-descriptor avail walker.
    logic        ChnEn;
    // SceneChainMatch (cmx): The chain matches the recorded submit and response. Default-off.
    logic        CmxEn;
    // SceneUsedLocal (sun): The local used element for that chain. Default-off. Not a guest store.
    logic        SunEn;
    // SceneUsedWrite (suw): Guest store of that element. Default-off. Not the CREATE_2D element.
    logic        SuwEn;
    // SceneUsedIndex (sux): Guest store of that used.idx. Default-off.
    logic        SuxEn;
    // ClearToRgba8 (u8): Clear floats to RGBA8 bytes. Default-off. Not a general converter.
    logic        U8En;
    // ClearCorners (pix): Four corner samples of that clear. Default-off. Not a triangle walk.
    logic        PixEn;
    // ClearCornerRead (pxr): Read of one stored corner. Default-off.
    logic        PxrEn;
    // ClearCeilingFill (fil): The clear word covers the 64 by 64 ceiling. Default-off.
    logic        FilEn;
    // ClearCeilingRead (frd): Read of one sample in that ceiling. Default-off. Not a triangle walk.
    logic        FrdEn;
    // QuadFloats (qd): The 24 vertex floats of the fullscreen strip. Default-off.
    logic        QdEn;
    // QuadCoverage (cv): That strip covers the ceiling. Default-off. The color stays the clear.
    logic        CvEn;
    // CoveredSample (cvr): One covered sample. Default-off. Not a shaded pixel.
    logic        CvrEn;
    // VertexTgsiText (vst): Vertex-shader TGSI text. Default-off. Not a translate.
    logic        VstEn;
    // FragTgsiText (fst): Fragment-shader TGSI text. Default-off. TEX is not executed.
    logic        FstEn;
    // HeldClearSample (hld): One covered sample held at the clear. Default-off. Not a shaded pixel.
    logic        HldEn;
    // TexBind (tbn): TEX bound to the sampler view and sampler state. Default-off.
    logic        TbnEn;
    // TexRefused (den): That sample is refused. Default-off. No texel image.
    logic        DenEn;
    // TexRefusedRead (dnr): One refused sample. Default-off. The color stays the clear.
    logic        DnrEn;
    // ScanCreate2d (s2d): VioScan CREATE_2D for resource 1. Default-off. Not the 64 by 64 create.
    logic        S2dEn;
    // ScanBacking (sbk): Backing entry for that resource. Default-off. Not a guest read.
    logic        SbkEn;
    // ScanBandTransfer (sxf): The 64-row transfer of that resource. Default-off. No bytes are copied.
    logic        SxfEn;
    // ScanScanout (ssc): SET_SCANOUT of resource 1. Default-off. Does not present.
    logic        SscEn;
    // ScanBandFlush (sfl): RESOURCE_FLUSH of the scan band. Default-off. Does not present.
    logic        SflEn;
    // ScanUnpresentedSample (spr): One sample while that scanout is unpresented. Default-off.
    logic        SprEn;
    // BandCopy (bcp): Band copy of resource 1. Default-off. Does not store the image.
    logic        BcpEn;
    // BandCopiedWord (bcr): One copied word beside the clear. Default-off. TEX is not executed.
    logic        BcrEn;
    // ClampEdgeTap (tap): One clamp-edge texel from the copied band. Default-off.
    logic        TapEn;
    // CeilingOriginTexel (pxc): Ceiling (0,0) takes that texel. Default-off. Other samples stay clear.
    logic        PxcEn;
    // CeilingOriginRead (pxq): One ceiling read after that corner. Default-off.
    logic        PxqEn;
    // LinearBlend (lin): Horizontal blend of two taps in the first beat. Default-off.
    logic        LinEn;
    // LinearBlendKeep (lnr): Origin texel and the blended neighbor. Default-off.
    logic        LnrEn;
    // SpanBlend (spn): Blend that spans the first two beats. Default-off.
    logic        SpnEn;
    // SpanSample (spx): The spanned sample at x = 8. Default-off.
    logic        SpxEn;
    // VerticalBlend (vln): Vertical blend of row 0 and row 1. Default-off.
    logic        VlnEn;
    // VerticalBlendKeep (vlr): The y = 1 samples at x = 0 and x = 1. Default-off.
    logic        VlrEn;
    // VerticalBeatBlend (vbx): y = 1 blend for x = 0..7, both row beats. Default-off.
    logic        VbxEn;
    // VerticalBeatSample (vbr): The y = 1 sample at x = 2. Default-off.
    logic        VbrEn;
    // VerticalSpanBlend (vsp): y = 1 blend for x = 0..15, including the beat span. Default-off.
    logic        VspEn;
    // VerticalSpanSample (vsx): The y = 1 sample at x = 8. Default-off.
    logic        VsxEn;
    // Row2Blend (y2b): y = 2 blend for x = 0..7, row 1 and row 2. Default-off.
    logic        Y2bEn;
    // Row2BlendKeep (y2r): The y = 2 samples at x = 0 and x = 1. Default-off.
    logic        Y2rEn;
    // CeilingSampler (smp): Any 64 by 64 ceiling sample from the copied band. Default-off.
    logic        SmpEn;
    // CeilingSampleCheck (smx): The ceiling sample at (0,3). Default-off.
    logic        SmxEn;
    // CeilingBeatWrite (rbf): Write the 64 by 64 ceiling as 512 beats. Default-off.
    logic        RbfEn;
    // CeilingBeatKeep (rbk): The readback record: byte count, first word, last address. Default-off.
    logic        RbkEn;
    // CeilingBeatRead (rdr): Read the 512 ceiling beats back. Default-off.
    logic        RdrEn;
    // CeilingBeatReadKeep (rdk): The two words collected from that read. Default-off.
    logic        RdkEn;
    // SceneFetch (fet): Fetch the scene header and the 960-byte execbuffer. Default-off.
    logic        FetEn;
    // SceneFetchKeep (fek): The submit type and the first command word. Default-off.
    logic        FekEn;
    // DrawVboRead (drd): DRAW_VBO at byte 908 of the fetched execbuffer. Default-off.
    logic        DrdEn;
    // DrawVboReadKeep (drk): The vertex count and the triangle-strip primitive. Default-off.
    logic        DrkEn;
    // NdcFloatsRead (qdr): The 24 NDC floats of the fetched draw. Default-off.
    logic        QdrEn;
    // NdcFloatsKeep (qdk): The first float and the last float. Default-off.
    logic        QdkEn;
    // ViewportRead (vwx): Viewport of the fetched draw, and where ±1 lands. Default-off.
    logic        VwxEn;
    // ViewportReadKeep (vwk): The scales and the window edges. Default-off.
    logic        VwkEn;
    // ScissorRead (cxr): Scissor of the fetched draw, matched to the window. Default-off.
    logic        CxrEn;
    // ScissorReadKeep (cxk): The scissor width and height. Default-off.
    logic        CxkEn;
    // ClearColorRead (cwr): Clear color of the fetched draw. Default-off.
    logic        CwrEn;
    // ClearColorReadKeep (cwk): The red, the blue, and the packed word. Default-off.
    logic        CwkEn;
    // FramebufferRead (fbr): Framebuffer of the fetched draw. Default-off.
    logic        FbrEn;
    // FramebufferReadKeep (fbk): The color-buffer count, the surface, and the clear word. Default-off.
    logic        FbkEn;
    // VertexBufferRead (vbf): Vertex-buffer set of the fetched draw. Default-off.
    logic        VbfEn;
    // VertexBufferReadKeep (vbk): The stride, the offset, and the resource. Default-off.
    logic        VbkEn;
    // InlineWriteRead (iwr): Inline write that holds the fetched quad. Default-off.
    logic        IwrEn;
    // InlineWriteReadKeep (iwk): The resource and the byte count. Default-off.
    logic        IwkEn;
    // SamplerViewRead (svr): Sampler view of the fetched draw. Default-off.
    logic        SvrEn;
    // SamplerViewReadKeep (svk): The stage, the slot, and the handle. Default-off.
    logic        SvkEn;
    // SamplerStateRead (ssr): Sampler state of the fetched draw. Default-off.
    logic        SsrEn;
    // SamplerStateReadKeep (ssk): The stage, the slot, and the handle. Default-off.
    logic        SskEn;
    // VertexElementBindRead (ver): Vertex-element bind of the fetched draw. Default-off.
    logic        VerEn;
    // VertexElementBindReadKeep (vek): The header and the handle. Default-off.
    logic        VekEn;
    // FragShaderBindRead (fsr): Fragment shader bind of the fetched draw. Default-off.
    logic        FsrEn;
    // FragShaderBindReadKeep (fsk): The handle and the stage. Default-off.
    logic        FskEn;
    // VertexShaderBindRead (vsr): Vertex shader bind of the fetched draw. Default-off.
    logic        VsrEn;
    // VertexShaderBindReadKeep (vsk): The handle and the stage. Default-off.
    logic        VskEn;
    // RasterizerBindRead (rzr): Rasterizer bind of the fetched draw. Default-off.
    logic        RzrEn;
    // RasterizerBindReadKeep (rzk): The header and the handle. Default-off.
    logic        RzkEn;
    // DepthStencilBindRead (dbr): Depth-stencil bind of the fetched draw. Default-off.
    logic        DbrEn;
    // DepthStencilBindReadKeep (dbk): The header and the handle. Default-off.
    logic        DbkEn;
    // BlendBindRead (bbr): Blend bind of the fetched draw. Default-off.
    logic        BbrEn;
    // BlendBindReadKeep (bbk): The header and the handle. Default-off.
    logic        BbkEn;
    // RasterizerObjectRead (rcr): Rasterizer object of the fetched draw. Default-off.
    logic        RcrEn;
    // RasterizerObjectReadKeep (rck): The header and the handle. Default-off.
    logic        RckEn;
    // DepthStencilObjectRead (dcr): Depth-stencil object of the fetched draw. Default-off.
    logic        DcrEn;
    // DepthStencilObjectReadKeep (dck): The header and the handle. Default-off.
    logic        DckEn;
    // BlendObjectRead (blr): Blend object of the fetched draw. Default-off.
    logic        BlrEn;
    // BlendObjectReadKeep (blk): The header, the handle, and the color word. Default-off.
    logic        BlkEn;
    // SamplerStateObjectRead (scr): Sampler-state object of the fetched draw. Default-off.
    logic        ScrEn;
    // SamplerStateObjectReadKeep (sck): The header, the handle, and the two state words. Default-off.
    logic        SckEn;
    // SamplerViewObjectRead (svc): Sampler view of the fetched draw. Default-off.
    logic        SvcEn;
    // SamplerViewObjectReadKeep (vck): The header, the handle, the resource, the format, and the swizzle. Default-off.
    logic        VckEn;
    // VertexElementObjectRead (vec): Vertex-element object of the fetched draw. Default-off.
    logic        VecEn;
    // VertexElementObjectReadKeep (vce): The header, the handle, and the two element offsets and formats. Default-off.
    logic        VceEn;
    // FragShaderObjectRead (fsc): Fragment-shader object of the fetched draw. Default-off. The shader is not run.
    logic        FscEn;
    // FragShaderObjectReadKeep (fce): The header, the handle, the stage, the length, the tokens, and text0. Default-off.
    logic        FceEn;
    // VertexShaderObjectRead (vsc): Vertex-shader object of the fetched draw. Default-off. The shader is not run.
    logic        VscEn;
    // VertexShaderObjectReadKeep (vse): The header, the handle, the stage, the length, the tokens, and text0. Default-off.
    logic        VseEn;
    // SurfaceObjectRead (sfc): Surface object at the start of the fetched draw. Default-off. No pixels are stored.
    logic        SfcEn;
    // SurfaceObjectReadKeep (sfe): The header, the handle, the resource, and the format. Default-off.
    logic        SfeEn;
    // SceneChainGuestRead (nxc): Guest read of the scene descriptor chain and its avail slot. Default-off.
    logic        NxcEn;
    // SceneChainGuestKeep (nxk): The head, the execbuffer, the response, and the avail index. Default-off.
    logic        NxkEn;
    // OpcodeList (ols): Completed-opcode list. Default-off. The list is empty.
    logic        OlsEn;
    // OpcodeListKeep (olk): The zero count, capset id 0, and the response. Default-off.
    logic        OlkEn;
    // ClearWindowWrite (gpw): 64 by 64 guest window of the scene clear word. Default-off.
    logic        GpwEn;
    // ClearWindowRead (gpr): First and last beats of that window. Default-off.
    logic        GprEn;
    // ClearWindowKeep (gpk): The clear word and the two beat addresses. Default-off.
    logic        GpkEn;
    // SceneCompleteWrite (gcw): Guest response, used element, and used index after that window. Default-off.
    logic        GcwEn;
    // SceneCompleteRead (gcr): Those three beats read back. Default-off.
    logic        GcrEn;
    // SceneCompleteKeep (gck): The response type, the fence, and the used index. Default-off.
    logic        GckEn;
    // UsedIrqWrite (viw): Used-buffer interrupt after that completion. Default-off.
    logic        ViwEn;
    // UsedIrqRead (vir): The interrupt reason read back. Default-off.
    logic        VirEn;
    // UsedIrqKeep (vik): The reason and the used index. Default-off.
    logic        VikEn;
    // UsedAck (vaw): Guest ack of the used-buffer reason. Default-off.
    logic        VawEn;
    // UsedAckRead (var): The ack word and the cleared status read back. Default-off.
    logic        VarEn;
    // UsedAckKeep (vak): The ack, the cleared status, and the used index. Default-off.
    logic        VakEn;
    // ClearWindowScan (wfr): Every beat of the 64 by 64 clear-word window. Default-off.
    logic        WfrEn;
    // ClearWindowScanKeep (wfk): The clear word at (0,0), (1,0), and (63,63). Default-off.
    logic        WfkEn;
    // ClearWindowScanCheck (wfx): One in-range point of that scan. Default-off.
    logic        WfxEn;
    // ReadbackCopy (gbw): Copy of that window into the guest readback buffer. Default-off.
    logic        GbwEn;
    // ReadbackCopyRead (gbr): First and last beats of the readback buffer. Default-off.
    logic        GbrEn;
    // ReadbackCopyKeep (gbk): The clear word, the source, and the readback address. Default-off.
    logic        GbkEn;
    // ReadbackRect (gbd): 64 by 64 readback rectangle. Default-off.
    logic        GbdEn;
    // ReadbackRectLane (gbl): One lane of that rectangle. Default-off.
    logic        GblEn;
    // ReadbackRectCheck (gbx): The rectangle and the sampled lane. Default-off.
    logic        GbxEn;
    // ReadbackOffset (gof): Byte offset of one point in that rectangle. Default-off.
    logic        GofEn;
    // ReadbackOffsetLane (gbo): The lane at that offset. Default-off.
    logic        GboEn;
    // ReadbackOffsetCheck (gbz): The offset and the lane. Default-off.
    logic        GbzEn;
    // ClearChannels (byr): Little-endian channels of the clear word in the readback. Default-off.
    logic        ByrEn;
    // ClearChannelsKeep (byk): The four channels. Default-off.
    logic        BykEn;
    // ClearChannelsCheck (byx): Byte 0 is red. Default-off.
    logic        ByxEn;
    // ReadbackRow1 (ryr): Row 1 of the readback starts with that red byte. Default-off.
    logic        RyrEn;
    // ReadbackRow1Keep (ryk): The row channels and the format tag. Default-off.
    logic        RykEn;
    // ReadbackRow1Check (ryx): Byte 0 of row 1 is red, not blue. Default-off.
    logic        RyxEn;
    // ReadbackThreePoints (tpr): Three readback points, little-endian clear channels. Default-off.
    logic        TprEn;
    // ReadbackThreePointsKeep (tpk): The three offsets and the channels. Default-off.
    logic        TpkEn;
    // ReadbackThreePointsCheck (tpx): Byte 0 of (0,63) is red, not blue. Default-off.
    logic        TpxEn;
    // ReadbackX63 (x6r): (63,0) of the readback is byte 252. Default-off.
    logic        X6rEn;
    // ReadbackX63Keep (x6k): That offset and the channels. Default-off.
    logic        X6kEn;
    // ReadbackX63Check (x6x): Byte 0 of (63,0) is red, not blue. Default-off.
    logic        X6xEn;
    // ReadbackFarCorner (tcr): (63,63) of the readback is byte 16380. Default-off.
    logic        TcrEn;
    // ReadbackFarCornerKeep (tck): That offset and the channels. Default-off.
    logic        TckEn;
    // ReadbackFarCornerCheck (tcx): Byte 0 of (63,63) is red, not blue. Default-off.
    logic        TcxEn;
    // ReadbackX7 (p7r): (7,0) of the readback is byte 28. Default-off.
    logic        P7rEn;
    // ReadbackX7Keep (p7k): That offset and the channels. Default-off.
    logic        P7kEn;
    // ReadbackX7Check (p7x): Byte 0 of (7,0) is red, not blue. Default-off.
    logic        P7xEn;
    // ReadbackBeat1 (b1r): Beat 1 of row 0, bytes 32 and 60. Default-off.
    logic        B1rEn;
    // ReadbackBeat1Keep (b1k): Those offsets and the channels. Default-off.
    logic        B1kEn;
    // ReadbackBeat1Check (b1x): Byte 0 of (8,0) is red, not blue. Default-off.
    logic        B1xEn;
    // ReadbackBeat7 (b7r): (56,0) is byte 224, lane 0 of the (63,0) beat. Default-off.
    logic        B7rEn;
    // ReadbackBeat7Keep (b7k): That offset and the channels. Default-off.
    logic        B7kEn;
    // ReadbackBeat7Check (b7x): Byte 0 of (56,0) is red, not blue. Default-off.
    logic        B7xEn;
    // ReadbackBeat2 (b2r): (16,0) is byte 64, lane 0 of beat 2. (23,0) is byte 92.
    logic        B2rEn;
    // ReadbackBeat2Keep (b2k): Those offsets and the channels. Default-off.
    logic        B2kEn;
    // ReadbackBeat2Check (b2x): Byte 0 of (16,0) is red, not blue. Default-off.
    logic        B2xEn;
    // ReadbackBeat3 (b3r): (24,0) is byte 96, lane 0 of beat 3. (31,0) is byte 124.
    logic        B3rEn;
    // ReadbackBeat3Keep (b3k): Those offsets and the channels. Default-off.
    logic        B3kEn;
    // ReadbackBeat3Check (b3x): Byte 0 of (24,0) is red, not blue. Default-off.
    logic        B3xEn;
    // ReadbackBeat4 (b4r): (32,0) is byte 128, lane 0 of beat 4. (39,0) is byte 156.
    logic        B4rEn;
    // ReadbackBeat4Keep (b4k): Those offsets and the channels. Default-off.
    logic        B4kEn;
    // ReadbackBeat4Check (b4x): Byte 0 of (32,0) is red, not blue. Default-off.
    logic        B4xEn;
    // ReadbackBeat5 (b5r): (40,0) is byte 160, lane 0 of beat 5. (47,0) is byte 188.
    logic        B5rEn;
    // ReadbackBeat5Keep (b5k): Those offsets and the channels. Default-off.
    logic        B5kEn;
    // ReadbackBeat5Check (b5x): Byte 0 of (40,0) is red, not blue. Default-off.
    logic        B5xEn;
    // ReadbackBeat6 (b6r): (48,0) is byte 192, lane 0 of beat 6. (55,0) is byte 220.
    logic        B6rEn;
    // ReadbackBeat6Keep (b6k): Those offsets and the channels. Default-off.
    logic        B6kEn;
    // ReadbackBeat6Check (b6x): Byte 0 of (48,0) is red, not blue. Default-off.
    logic        B6xEn;
    // LinearPairWrite (acw): Linear sample pair written as fragment color. Default-off.
    logic        AcwEn;
    // LinearPairRead (acr): Those two words read back. Default-off.
    logic        AcrEn;
    // LinearPairCheck (acx): Byte 0 of (1,0) is the sample, not the clear. Default-off.
    logic        AcxEn;
    // ColorWindowCopy (csw): 64 by 64 sample copy into the color window. Default-off.
    logic        CswEn;
    // ColorWindowRead (csr): Beat 0 of that window read back. Default-off.
    logic        CsrEn;
    // ColorWindowCheck (csx): Byte 0 of (1,0) in that window is the sample. Default-off.
    logic        CsxEn;
    // ColorWindowRect (crd): 64 by 64 sample rectangle at the color window. Default-off.
    logic        CrdEn;
    // ColorWindowRectLane (crl): (1,0) in that rectangle is the half blend. Default-off.
    logic        CrlEn;
    // ColorWindowRectCheck (crx): Byte 0 of that point is the sample, not the clear. Default-off.
    logic        CrxEn;
    // ColorWindowOffset (cof): Byte offset in the sample rectangle. Default-off.
    logic        CofEn;
    // ColorWindowOffsetOrigin (cor): (0,0) in that rectangle is the clamp texel. Default-off.
    logic        CorEn;
    // ColorWindowOffsetCheck (cox): Byte 0 of (0,0) is the sample, not the clear. Default-off.
    logic        CoxEn;
    // TransferDestCopy (rpw): Guest 64 by 64 TRANSFER_FROM_HOST_3D of the sample rectangle. Default-off.
    logic        RpwEn;
    // TransferDestRead (rpr): Beat 0 of that guest buffer read back. Default-off.
    logic        RprEn;
    // TransferDestCheck (rpx): Byte 0 of (1,0) in that buffer is the sample. Default-off.
    logic        RpxEn;
    // GuestReadpixelsRect (grd): 64 by 64 guest readpixels rectangle. Default-off.
    logic        GrdEn;
    // GuestReadpixelsLane (grl): (1,0) in that rectangle is the half blend. Default-off.
    logic        GrlEn;
    // GuestReadpixelsCheck (grx): Byte 0 of that point is the sample, not the clear. Default-off.
    logic        GrxEn;
    // GuestReadpixelsOffset (rof): Byte offset in the guest readpixels rectangle. Default-off.
    logic        RofEn;
    // GuestReadpixelsOffsetOrigin (ror): (0,0) in that guest rectangle is the clamp texel. Default-off.
    logic        RorEn;
    // GuestReadpixelsOffsetCheck (rox): Byte 0 of (0,0) is the sample, not the clear. Default-off.
    logic        RoxEn;
    // TransferBox (tfb): TRANSFER_FROM_HOST_3D box (0,0,64,64) of the 640 by 480 target. Default-off.
    logic        TfbEn;
    // TransferBoxRead (tfr): Guest command beats of that transfer. Default-off.
    logic        TfrEn;
    // TransferBoxCheck (tfx): Packed stride 256 of that box, not the 640-wide resource row. Default-off.
    logic        TfxEn;
    // TransferAttach (rab): RESOURCE_ATTACH_BACKING of the 64 by 64 readpixels buffer. Default-off.
    logic        RabEn;
    // TransferAttachRead (rar): Guest command beats of that attach. Default-off.
    logic        RarEn;
    // TransferAttachCheck (rax): Length 16384, not the 640 by 480 backing. Default-off.
    logic        RaxEn;
    // TransferFence (rfw): virtio OK_NODATA fence response of the 64 by 64 transfer. Default-off.
    logic        RfwEn;
    // TransferFenceRead (rfr): Guest read of that response. Default-off.
    logic        RfrEn;
    // TransferFenceCheck (rfx): Fence 2, not the scene fence. Default-off.
    logic        RfxEn;
    // TransferUsed (tuw): Used element of the 64 by 64 transfer. Default-off.
    logic        TuwEn;
    // TransferUsedRead (tur): Guest read of that used element and index. Default-off.
    logic        TurEn;
    // TransferUsedCheck (tux): used.idx 2, not the scene index 1. Default-off.
    logic        TuxEn;
    // TransferIrq (tiw): Used-buffer interrupt of the 64 by 64 transfer. Default-off.
    logic        TiwEn;
    // TransferIrqRead (tir): Guest read of that interrupt reason. Default-off.
    logic        TirEn;
    // TransferIrqCheck (tix): Reason 32'h1 at 64'h880C0000, not the scene status word. Default-off.
    logic        TixEn;
    // TransferAck (taw): Guest ack of the 64 by 64 transfer interrupt. Default-off.
    logic        TawEn;
    // TransferAckRead (tar): Guest read of that ack and the cleared status. Default-off.
    logic        TarEn;
    // TransferAckCheck (tax): Ack 32'h1 and remain 0 with used.idx 2. Default-off.
    logic        TaxEn;
    // TransferChain (txc): Guest descriptor chain of the 64 by 64 transfer. Default-off.
    logic        TxcEn;
    // TransferChainKeep (txk): Keep that chain. Default-off.
    logic        TxkEn;
    // TransferChainCheck (txx): Avail index 2, not the scene index 1. Default-off.
    logic        TxxEn;
    // TexSample (ftx): TEX of sampler view 5 returns the backing samples. Default-off.
    logic        FtxEn;
    // TexSampleKeep (ftr): Keep that TEX result. Default-off.
    logic        FtrEn;
    // TexSampleCheck (ftk): refused is 0 and the word is not the clear color. Default-off.
    logic        FtkEn;
    // SceneWindowTexWrite (ocw): TEX pair written into the 64 by 64 scene window. Default-off.
    logic        OcwEn;
    // SceneWindowTexRead (ocr): Guest read of that beat. Default-off.
    logic        OcrEn;
    // SceneWindowTexCheck (ocx): (0,0) is the clamp texel, not the clear word. Default-off.
    logic        OcxEn;
    // ReadbackTexWrite (pbw): TEX pair written into the guest readback. Default-off.
    logic        PbwEn;
    // ReadbackTexRead (pbr): Guest read of that readback beat. Default-off.
    logic        PbrEn;
    // ReadbackTexCheck (pbx): (0,0) in the readback is the clamp texel. Default-off.
    logic        PbxEn;
    // TransferNextWalk (tnw): Posted NEXT walker of the 64 by 64 transfer chain. Default-off.
    logic        TnwEn;
    // TransferNextKeep (tnk): Keep that walked chain. Default-off.
    logic        TnkEn;
    // TransferNextCheck (tnx): Avail index 2, NEXT accepted. Default-off.
    logic        TnxEn;
    // TransferQueueNotify (qnt): Guest QueueNotify of the 64 by 64 transfer. Default-off.
    logic        QntEn;
    // TransferQueueNotifyRead (qnr): Guest read of that notify word. Default-off.
    logic        QnrEn;
    // TransferQueueNotifyCheck (qnx): Control queue 0 after avail index 2. Default-off.
    logic        QnxEn;
    // TransferAvailIdx (qav): Guest avail.idx after that QueueNotify. Default-off.
    logic        QavEn;
    // TransferAvailIdxKeep (qak): Keep that avail.idx. Default-off.
    logic        QakEn;
    // TransferAvailIdxCheck (qax): Avail index 2 at 64'h880D0100. Default-off.
    logic        QaxEn;
    // TransferAvailRing (qrg): Guest avail ring[0] after that idx. Default-off.
    logic        QrgEn;
    // TransferAvailRingKeep (qrk): Keep that ring name. Default-off.
    logic        QrkEn;
    // TransferAvailRingCheck (qrx): Ring[0] names descriptor 0. Default-off.
    logic        QrxEn;
    // TransferDesc0 (qhd): Guest descriptor 0 after that ring name. Default-off.
    logic        QhdEn;
    // TransferDesc0Keep (qhk): Keep that descriptor. Default-off.
    logic        QhkEn;
    // TransferDesc0Check (qhx): Descriptor 0 is the attach, NEXT to 1. Default-off.
    logic        QhxEn;
    // TransferDesc1 (qfd): Guest descriptor 1 after that NEXT. Default-off.
    logic        QfdEn;
    // TransferDesc1Keep (qfk): Keep that transfer descriptor. Default-off.
    logic        QfkEn;
    // TransferDesc1Check (qfx): Descriptor 1 is the transfer, NEXT to 2. Default-off.
    logic        QfxEn;
    // TransferDesc2 (qwd): Guest descriptor 2 after that NEXT. Default-off.
    logic        QwdEn;
    // TransferDesc2Keep (qwk): Keep that WRITE descriptor. Default-off.
    logic        QwkEn;
    // TransferDesc2Check (qwx): Descriptor 2 is the response WRITE. Default-off.
    logic        QwxEn;
    // TransferOkNodata (qok): Guest OK_NODATA WRITE after that descriptor. Default-off.
    logic        QokEn;
    // TransferOkNodataRead (qol): Guest read of that response. Default-off.
    logic        QolEn;
    // TransferOkNodataCheck (qox): Fence 2 OK_NODATA at 64'h880A0000. Default-off.
    logic        QoxEn;
    // TransferUsedWrite (quw): Guest used element after that OK_NODATA. Default-off.
    logic        QuwEn;
    // TransferUsedWriteRead (qul): Guest read of that used element. Default-off.
    logic        QulEn;
    // TransferUsedWriteCheck (qux): used.idx 2 after the guest WRITE. Default-off.
    logic        QuxEn;
    // TransferUsedIrq (qiw): Guest used-buffer interrupt after that index. Default-off.
    logic        QiwEn;
    // TransferUsedIrqRead (qir): Guest read of that interrupt reason. Default-off.
    logic        QirEn;
    // TransferUsedIrqCheck (qix): Reason 32'h1 after the guest used ring. Default-off.
    logic        QixEn;
    // TransferUsedAck (qaw): Guest ack of that interrupt. Default-off.
    logic        QawEn;
    // TransferUsedAckRead (qar): Guest read of that ack and remain. Default-off.
    logic        QarEn;
    // TransferUsedAckCheck (qay): Ack 32'h1 and remain 0 after the guest used ring. Default-off.
    logic        QayEn;
    // SceneAvailIdx (qsv): Scene virtq_avail.idx 1 after that ack. Default-off.
    logic        QsvEn;
    // SceneAvailIdxKeep (qsk): Guest keep of that scene index. Default-off.
    logic        QskEn;
    // SceneAvailIdxCheck (qsx): Scene index 1 at 64'h8800E200. Default-off.
    logic        QsxEn;
    // SceneAvailRing (qsr): Scene virtq_avail.ring[0] after that index. Default-off.
    logic        QsrEn;
    // SceneAvailRingKeep (qsl): Guest keep of that scene ring name. Default-off.
    logic        QslEn;
    // SceneAvailRingCheck (qsy): Descriptor 0 at 64'h8800E204. Default-off.
    logic        QsyEn;
    // SceneDesc0 (qsd): Scene virtq_desc 0 after that ring name. Default-off.
    logic        QsdEn;
    // SceneDesc0Keep (qse): Guest keep of that scene header descriptor. Default-off.
    logic        QseEn;
    // SceneDesc0Check (qsf): Header at 64'h8800A000 with NEXT to 1. Default-off.
    logic        QsfEn;
    // SceneDesc1 (qed): Scene virtq_desc 1 after that NEXT. Default-off.
    logic        QedEn;
    // SceneDesc1Keep (qek): Guest keep of that execbuffer descriptor. Default-off.
    logic        QekEn;
    // SceneDesc1Check (qex): Execbuffer at 64'h8800B000 with NEXT to 2. Default-off.
    logic        QexEn;
    // SceneDesc2 (qrs): Scene virtq_desc 2 WRITE after that NEXT. Default-off.
    logic        QrsEn;
    // SceneDesc2Keep (qrt): Guest keep of that scene response descriptor. Default-off.
    logic        QrtEn;
    // SceneDesc2Check (qru): WRITE of the 24-byte scene response at 64'h8800A800. Default-off.
    logic        QruEn;
    // SceneOkNodata (qso): Scene OK_NODATA WRITE after that descriptor. Default-off.
    logic        QsoEn;
    // SceneOkNodataRead (qsp): Guest read of that scene response. Default-off.
    logic        QspEn;
    // SceneOkNodataCheck (qsq): Scene fence OK_NODATA at 64'h8800A800. Default-off.
    logic        QsqEn;
    // SceneUsedWrite (qsu): Scene used element after that OK_NODATA. Default-off.
    logic        QsuEn;
    // SceneUsedWriteRead (qst): Guest read of that scene used element. Default-off.
    logic        QstEn;
    // SceneUsedWriteCheck (qsz): used.idx 1 at 64'h8800E480. Default-off.
    logic        QszEn;
    // SceneUsedIrq (qsi): Scene used-buffer interrupt after that index. Default-off.
    logic        QsiEn;
    // SceneUsedIrqRead (qsn): Guest read of that scene interrupt reason. Default-off.
    logic        QsnEn;
    // SceneUsedIrqCheck (qsm): Reason 32'h1 at 64'h8800E500. Default-off.
    logic        QsmEn;
    // SceneUsedAck (qga): Scene guest ack after that interrupt. Default-off.
    logic        QgaEn;
    // SceneUsedAckKeep (qgk): Guest read of that scene ack and remain. Default-off.
    logic        QgkEn;
    // SceneUsedAckCheck (qgx): Ack 32'h1 and remain 0 at 64'h8800E510. Default-off.
    logic        QgxEn;
    // SceneNextWalk (snw): Posted NEXT walker of the scene chain. Default-off.
    logic        SnwEn;
    // SceneNextKeep (snk): Guest keep of that walked scene chain. Default-off.
    logic        SnkEn;
    // SceneNextCheck (snx): Avail index 1 with NEXT accepted. Default-off.
    logic        SnxEn;
    // SceneQueueNotify (snt): Scene QueueNotify after that walker. Default-off.
    logic        SntEn;
    // SceneQueueNotifyRead (snr): Guest read of that scene notify word. Default-off.
    logic        SnrEn;
    // SceneQueueNotifyCheck (sny): Control queue 0 after avail index 1. Default-off.
    logic        SnyEn;
    // SceneAvailAfterNotify (sav): Scene virtq_avail.idx after that notify. Default-off.
    logic        SavEn;
    // SceneAvailAfterNotifyKeep (sak): Guest keep of that scene avail index. Default-off.
    logic        SakEn;
    // SceneAvailAfterNotifyCheck (sax): Avail index 1 at 64'h8800E200 after notify. Default-off.
    logic        SaxEn;
    // SceneRingAfterNotify (srg): Scene virtq_avail.ring[0] after that index. Default-off.
    logic        SrgEn;
    // SceneRingAfterNotifyKeep (srk): Guest keep of that scene ring name. Default-off.
    logic        SrkEn;
    // SceneRingAfterNotifyCheck (srx): Descriptor 0 at 64'h8800E204 after notify. Default-off.
    logic        SrxEn;
    // SceneHeaderAfterNotify (shd): Scene virtq_desc 0 after that ring name. Default-off.
    logic        ShdEn;
    // SceneHeaderAfterNotifyKeep (shk): Guest keep of that scene header descriptor. Default-off.
    logic        ShkEn;
    // SceneHeaderAfterNotifyCheck (shx): Header at 64'h8800A000 with NEXT to 1. Default-off.
    logic        ShxEn;
    // SceneExecAfterNotify (sfd): Scene virtq_desc 1 after that NEXT. Default-off.
    logic        SfdEn;
    // SceneExecAfterNotifyKeep (sfk): Guest keep of that scene execbuffer descriptor. Default-off.
    logic        SfkEn;
    // SceneExecAfterNotifyCheck (sfx): Execbuffer at 64'h8800B000 with NEXT to 2. Default-off.
    logic        SfxEn;
    // SceneWriteAfterNotify (swd): Scene virtq_desc 2 WRITE after that NEXT. Default-off.
    logic        SwdEn;
    // SceneWriteAfterNotifyKeep (swk): Guest keep of that scene WRITE descriptor. Default-off.
    logic        SwkEn;
    // SceneWriteAfterNotifyCheck (swx): WRITE of the 24-byte response at 64'h8800A800. Default-off.
    logic        SwxEn;
    // SceneOkAfterNotify (sok): Scene OK_NODATA after that WRITE. Default-off.
    logic        SokEn;
    // SceneOkAfterNotifyKeep (sol): Guest keep of that scene OK_NODATA. Default-off.
    logic        SolEn;
    // SceneOkAfterNotifyCheck (sox): Scene fence OK_NODATA at 64'h8800A800. Default-off.
    logic        SoxEn;
    // SceneUsedAfterNotify (slw): Scene used element after that OK_NODATA. Default-off.
    logic        SlwEn;
    // SceneUsedAfterNotifyKeep (sll): Guest keep of that scene used element. Default-off.
    logic        SllEn;
    // SceneUsedAfterNotifyCheck (slx): used.idx 1 after scene OK_NODATA. Default-off.
    logic        SlxEn;
    // SceneIrqAfterNotify (siw): Scene used-buffer interrupt after used.idx 1 after QueueNotify. Default-off.
    logic        SiwEn;
    // SceneIrqAfterNotifyKeep (sir): Guest keep of that scene interrupt reason. Default-off.
    logic        SirEn;
    // SceneIrqAfterNotifyCheck (six): Reason 32'h1 at 64'h8800E500 after scene used after notify. Default-off.
    logic        SixEn;
    // SceneAckAfterNotify (sga): Scene guest ack after used-buffer interrupt after QueueNotify. Default-off.
    logic        SgaEn;
    // SceneAckAfterNotifyKeep (sgk): Guest keep of that scene ack and remain. Default-off.
    logic        SgkEn;
    // SceneAckAfterNotifyCheck (sgx): Ack 32'h1 and remain 0 after scene interrupt after notify. Default-off.
    logic        SgxEn;
    // TransferNextAfterAckWalk (rnw): Posted NEXT walker of the transfer chain after scene guest ack. Default-off.
    logic        RnwEn;
    // TransferNextAfterAckKeep (rnk): Guest keep of that walked transfer chain. Default-off.
    logic        RnkEn;
    // TransferNextAfterAckCheck (rnx): Avail index 2 with NEXT after scene guest ack. Default-off.
    logic        RnxEn;
    // TransferNotifyAfterAck (rnt): QueueNotify of control queue 0 after that walker. Default-off.
    logic        RntEn;
    // TransferNotifyAfterAckKeep (rnr): Guest keep of that notify word. Default-off.
    logic        RnrEn;
    // TransferNotifyAfterAckCheck (rny): Control queue 0 after avail index 2 after scene guest ack. Default-off.
    logic        RnyEn;
    // TransferAvailAfterAck (rav): virtq_avail.idx 2 after that QueueNotify after scene guest ack. Default-off.
    logic        RavEn;
    // TransferAvailAfterAckKeep (rak): Guest keep of that avail index. Default-off.
    logic        RakEn;
    // TransferAvailAfterAckCheck (ray): Avail index 2 at 64'h880D0100 after scene guest ack. Default-off.
    logic        RayEn;
    // TransferRingAfterAck (rrg): virtq_avail.ring[0] names descriptor 0 after that index after scene guest ack. Default-off.
    logic        RrgEn;
    // TransferRingAfterAckKeep (rrk): Guest keep of that ring name. Default-off.
    logic        RrkEn;
    // TransferRingAfterAckCheck (rrx): Descriptor 0 at 64'h880D0104 after scene guest ack. Default-off.
    logic        RrxEn;
    // TransferDesc0AfterAck (rhd): virtq_desc 0 attach NEXT to 1 after that ring name after scene guest ack. Default-off.
    logic        RhdEn;
    // TransferDesc0AfterAckKeep (rhk): Guest keep of that attach descriptor. Default-off.
    logic        RhkEn;
    // TransferDesc0AfterAckCheck (rhx): Attach at 64'h88090000 with NEXT to 1 after scene guest ack. Default-off.
    logic        RhxEn;
    // TransferDesc1AfterAck (rfd): virtq_desc 1 transfer NEXT to 2 after that attach after scene guest ack. Default-off.
    logic        RfdEn;
    // TransferDesc1AfterAckKeep (rfk): Guest keep of that transfer descriptor. Default-off.
    logic        RfkEn;
    // TransferDesc1AfterAckCheck (rfy): Transfer at 64'h88080000 with NEXT to 2 after scene guest ack. Default-off.
    logic        RfyEn;
    // TransferDesc2AfterAck (rwd): virtq_desc 2 WRITE of the 24-byte response after that transfer after scene guest ack. Default-off.
    logic        RwdEn;
    // TransferDesc2AfterAckKeep (rwk): Guest keep of that WRITE descriptor. Default-off.
    logic        RwkEn;
    // TransferDesc2AfterAckCheck (rwx): WRITE at 64'h880A0000 after scene guest ack. Default-off.
    logic        RwxEn;
    // TransferOkAfterAck (rok): Guest OK_NODATA WRITE after that named WRITE after scene guest ack. Default-off.
    logic        RokEn;
    // TransferOkAfterAckKeep (rol): Guest keep of that OK_NODATA. Default-off.
    logic        RolEn;
    // TransferOkAfterAckCheck (roy): Fence 2 OK_NODATA at 64'h880A0000 after scene guest ack. Default-off.
    logic        RoyEn;
    // TransferUsedAfterAck (ruw): Guest used element after that OK_NODATA after scene guest ack. Default-off.
    logic        RuwEn;
    // TransferUsedAfterAckKeep (rul): Guest keep of that used element. Default-off.
    logic        RulEn;
    // TransferUsedAfterAckCheck (rux): used.idx 2 after that OK_NODATA after scene guest ack. Default-off.
    logic        RuxEn;
    // TransferIrqAfterAck (riw): Guest used-buffer interrupt after that index after scene guest ack. Default-off.
    logic        RiwEn;
    // TransferIrqAfterAckKeep (rir): Guest keep of that interrupt reason. Default-off.
    logic        RirEn;
    // TransferIrqAfterAckCheck (rix): Reason 32'h1 at 64'h880C0000 after scene guest ack. Default-off.
    logic        RixEn;
    // TransferAckAfterAck (rga): Guest ack of that used-buffer interrupt after scene guest ack. Default-off.
    logic        RgaEn;
    // TransferAckAfterAckKeep (rgk): Guest keep of that ack and remain. Default-off.
    logic        RgkEn;
    // TransferAckAfterAckCheck (rgx): Ack 32'h1 and remain 0 after scene guest ack. Default-off.
    logic        RgxEn;
    // TexAfterAck (gtx): TEX of sampler view 5 after that guest ack after scene guest ack. Default-off.
    logic        GtxEn;
    // TexAfterAckKeep (gtr): Guest keep of that TEX result. Default-off.
    logic        GtrEn;
    // TexAfterAckCheck (gtk): refused 0 origin clamp texel after that guest ack. Default-off.
    logic        GtkEn;
    // GuestTransferTexWrite (hcw): TEX pair in beat 0 of the guest transfer buffer after that ack. Default-off.
    logic        HcwEn;
    // GuestTransferTexRead (hcr): Guest keep of that guest-buffer beat. Default-off.
    logic        HcrEn;
    // GuestTransferTexCheck (hcx): Byte 0 of (0,0) in that guest buffer is sample red. Default-off.
    logic        HcxEn;
    // CoveredTexSample (wld): Covered TEX sample (0,0)/(1,0) after that guest-buffer beat. Default-off.
    logic        WldEn;
    // CoveredTexSampleKeep (wlr): Guest keep of that covered TEX sample. Default-off.
    logic        WlrEn;
    // CoveredTexSampleCheck (wlk): refused 0 held word is clamp or half blend. Default-off.
    logic        WlkEn;
    // TexSampleChannels (cyr): Four channels of that covered TEX sample. Default-off.
    logic        CyrEn;
    // TexSampleChannelsKeep (cyk): Guest keep of those TEX channels. Default-off.
    logic        CykEn;
    // TexSampleChannelsCheck (cyx): Byte 0 of the held TEX sample is red 8'h00. Default-off.
    logic        CyxEn;
    // GuestNextWalk (gnw): Guest-rung walk of the scene NEXT chain after QueueNotify. Default-off.
    logic        GnwEn;
    // GuestNextKeep (gnk): Guest keep of that guest-rung chain. Default-off.
    logic        GnkEn;
    // GuestNextCheck (gnx): Avail index 1 with consumed device index 1. Default-off.
    logic        GnxEn;
    // GuestExecFetch (gef): Fetch the execbuffer after that guest-rung walk. Default-off.
    logic        GefEn;
    // GuestExecKeep (gek): Guest keep of that fetched submit word. Default-off.
    logic        GekEn;
    // GuestExecCheck (gex): cmd0 is CREATE_OBJECT after consumed device index 1. Default-off.
    logic        GexEn;
    // SpirvSubset (spirv): Bounded SPIR-V-subset interpreter, immutable program store. Default-off. Bytes+IRQ diagnostic transport; FeatureVirgl stays illegal.
    logic        SpirvEn;
    // NextChain (chain): Reusable virtq_desc NEXT walker with programmed table base and head. Default-off. FeatureVirgl stays illegal.
    logic        ChainEn;
    // ChainDma (cdma): NextChain joined to checked DmaRead. Default-off. FeatureVirgl stays illegal.
    logic        CdmaEn;
    // HostVisibleShm (shm): virtio-mmio SHM id 1 HOST_VISIBLE region. Default-off. FeatureVirgl stays illegal.
    logic        ShmEn;
    // HostVisible (hvis): RESOURCE_CREATE_BLOB map into that SHM and CTX_CREATE context_init Venus. Default-off. FeatureVirgl stays illegal.
    logic        HvisEn;
    // VenusCs (vncs): HOST_VISIBLE ring CREATE_MODULE/DISPATCH into SpirvSubset. Default-off. FeatureVirgl stays illegal.
    logic        VncsEn;
    // VenusCapset (vcap): GET_CAPSET_INFO/GET_CAPSET for Venus id 4. Default-off. FeatureVirgl stays illegal.
    logic        VcapEn;
    // VenusRing (vnring): Mesa vn_ring_layout head/tail/status/buffer walker. Default-off. FeatureVirgl stays illegal.
    logic        VnringEn;
    // TestharnessDma (tdma): 2:1 AXI join of APU DMA onto the testharness slave[2] path. Default-off. FeatureVirgl stays illegal.
    logic        TdmaEn;
    // VenusEncode (vnenc): Mesa vn_protocol vkCreateShaderModule CS. Default-off. FeatureVirgl stays illegal.
    logic        VnencEn;
    // VenusPath (vnp): vn_ring buffer feeds vnenc into SpirvSubset. Default-off. FeatureVirgl stays illegal.
    logic        VnpEn;
    // AvailNext (avn): virtq_avail.idx + ring[head] feeds NextChain. Default-off. FeatureVirgl stays illegal.
    logic        AvnEn;
    // AvailUsed (avu): AvailNext then virtq_used elem and used.idx. Default-off. FeatureVirgl stays illegal.
    logic        AvuEn;
    // UsedIrq (uir): AvailUsed then virtio used-buffer ISR. Default-off. FeatureVirgl stays illegal.
    logic        UirEn;
    // CmdSnap (cms): AvailNext first-payload snapshot that survives guest mutation. Default-off. FeatureVirgl stays illegal.
    logic        CmsEn;
    // PayResp (prs): AvailNext WRITE-window response store. Default-off. FeatureVirgl stays illegal.
    logic        PrsEn;
    // QueueDone (qdn): one AvailNext then response, used.idx, and ISR. Default-off. FeatureVirgl stays illegal.
    logic        QdnEn;
    // GrantCapset (gcs): AvailNext GET_CAPSET/INFO Venus blob on the WRITE window, then used.idx and ISR. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        GcsEn;
    // VenusDispatch (vnd): Mesa vn_protocol vkCmdDispatch CS. Default-off. FeatureVirgl stays illegal.
    logic        VndEn;
    // GenHandle (gnh): generational context/resource/program table with pin/retire. Default-off. FeatureVirgl stays illegal.
    logic        GnhEn;
    // HandleDispatch (hdp): GenHandle lookup of vkCmdDispatch commandBuffer. Default-off. FeatureVirgl stays illegal.
    logic        HdpEn;
    // HandlePath (hph): vkCreateShaderModule publishes MODULE, vkCmdDispatch looks up CMDBUF. Default-off. FeatureVirgl stays illegal.
    logic        HphEn;
    // HandleRun (hrn): HandlePath create/dispatch then SpirvSubset kick. Default-off. FeatureVirgl stays illegal.
    logic        HrnEn;
    // RunDone (rdn): HandleRun dispatch then WRITE result, used.idx, and ISR. Default-off. FeatureVirgl stays illegal.
    logic        RdnEn;
    // QueueRun (qrn): AvailNext fetches CS into RunDone CREATE or DISPATCH. Default-off. FeatureVirgl stays illegal.
    logic        QrnEn;
    // QueueCmd (qcm): GrantCapset or QueueRun on one request port. Default-off. FeatureVirgl stays illegal.
    logic        QcmEn;
    // QueueType (qty): AvailNext type word selects GrantCapset or QueueRun. Default-off. FeatureVirgl stays illegal.
    logic        QtyEn;
    // VenusCtrl (vct): Private Venus num_capsets=1 and QueueNotify into QueueType. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VctEn;
    // QueuePump (qpu): QueueNotify drains AvailNext until EMPTY. Default-off. FeatureVirgl stays illegal.
    logic        QpuEn;
    // NotifyTake (ntk): virtio notify_pending[0] consumes QueuePump. Default-off. FeatureVirgl stays illegal.
    logic        NtkEn;
    // VqTake (vqt): virtio vq_state[0] arms NotifyTake on notify_pending[0]. Default-off. FeatureVirgl stays illegal.
    logic        VqtEn;
    // VqAxi (vax): VqTake guest beats on 64-bit AXI. Default-off. FeatureVirgl stays illegal.
    logic        VaxEn;
    // VenusAlloc (vac): Mesa vn_protocol vkAllocateCommandBuffers ALLOC CMDBUF. Default-off. FeatureVirgl stays illegal.
    logic        VacEn;
    // HandleAlloc (hal): vkAllocateCommandBuffers ALLOC CMDBUF then vkCmdDispatch LOOKUP on one table. Default-off. FeatureVirgl stays illegal.
    logic        HalEn;
    // AllocRun (aru): ALLOC CMDBUF, CREATE MODULE, then DISPATCH SpirvSubset on one table. Default-off. FeatureVirgl stays illegal.
    logic        AruEn;
    // QueueAlloc (qal): AvailNext CS into AllocRun ALLOC/CREATE/DISPATCH. Default-off. FeatureVirgl stays illegal.
    logic        QalEn;
    // QueueTypeAlloc (qta): AvailNext type word selects GrantCapset or QueueAlloc. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        QtaEn;
    // VenusCtrlAlloc (vca): Private Venus num_capsets=1 and QueueNotify into QueueTypeAlloc. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VcaEn;
    // QueuePumpAlloc (qpa): QueueNotify drains QueueTypeAlloc until EMPTY. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        QpaEn;
    // NotifyTakeAlloc (nta): virtio notify_pending[0] consumes QueuePumpAlloc. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        NtaEn;
    // VqTakeAlloc (vqa): virtio vq_state[0] arms NotifyTakeAlloc on notify_pending[0]. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VqaEn;
    // VqAxiAlloc (vaa): VqTakeAlloc guest beats on 64-bit AXI. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VaaEn;
    // VenusBegin (vbg): Mesa vn_protocol vkBeginCommandBuffer CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VbgEn;
    // BeginAlloc (bal): vkAllocateCommandBuffers ALLOC CMDBUF then vkBeginCommandBuffer LOOKUP on one table. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        BalEn;
    // BeginRun (bru): ALLOC CMDBUF, BEGIN LOOKUP, CREATE MODULE, then DISPATCH SpirvSubset on one table. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        BruEn;
    // QueueBegin (qbn): AvailNext CS into BeginRun ALLOC/BEGIN/CREATE/DISPATCH. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        QbnEn;
    // QueueTypeBegin (qtb): AvailNext type word selects GrantCapset or QueueBegin. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        QtbEn;
    // VenusCtrlBegin (vcb): Private Venus num_capsets=1 and QueueNotify into QueueTypeBegin. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VcbEn;
    // QueuePumpBegin (qpb): QueueNotify drains QueueTypeBegin until EMPTY. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        QpbEn;
    // NotifyTakeBegin (ntb): virtio notify_pending[0] consumes QueuePumpBegin. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        NtbEn;
    // VqTakeBegin (vqb): virtio vq_state[0] arms NotifyTakeBegin on notify_pending[0]. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VqbEn;
    // VqAxiBegin (vab): VqTakeBegin guest beats on 64-bit AXI. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VabEn;
    // VenusEnd (ven): Mesa vn_protocol vkEndCommandBuffer CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VenEn;
    // EndAlloc (eal): vkAllocateCommandBuffers ALLOC CMDBUF, vkBeginCommandBuffer LOOKUP, then vkEndCommandBuffer LOOKUP on one table. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        EalEn;
    // VenusSubmit (vqs): Mesa vn_protocol vkQueueSubmit CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VqsEn;
    // VenusWaitIdle (vwi): Mesa vn_protocol vkQueueWaitIdle CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VwiEn;
    // VenusGetQueue (vgq): Mesa vn_protocol vkGetDeviceQueue CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VgqEn;
    // VenusCreateDevice (vcd): Mesa vn_protocol vkCreateDevice CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VcdEn;
    // VenusCreateInstance (vci): Mesa vn_protocol vkCreateInstance CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VciEn;
    // VenusEnumeratePhys (vep): Mesa vn_protocol vkEnumeratePhysicalDevices CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VepEn;
    // VenusQueueFamily (vqf): Mesa vn_protocol vkGetPhysicalDeviceQueueFamilyProperties CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VqfEn;
    // VenusPhysFeatures (vpf): Mesa vn_protocol vkGetPhysicalDeviceFeatures CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VpfEn;
    // VenusPhysProps (vpp): Mesa vn_protocol vkGetPhysicalDeviceProperties CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VppEn;
    // VenusPhysMemory (vmp): Mesa vn_protocol vkGetPhysicalDeviceMemoryProperties CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VmpEn;
    // VenusAllocMemory (vam): Mesa vn_protocol vkAllocateMemory CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VamEn;
    // VenusCreateBuffer (vxb): Mesa vn_protocol vkCreateBuffer CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VxbEn;
    // VenusBindBuffer (vbb): Mesa vn_protocol vkBindBufferMemory CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VbbEn;
    // VenusMapMemory (vmm): Mesa vn_protocol vkMapMemory CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VmmEn;
    // VenusUnmapMemory (vum): Mesa vn_protocol vkUnmapMemory CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VumEn;
    // VenusBufReq (vbm): Mesa vn_protocol vkGetBufferMemoryRequirements CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VbmEn;
    // VenusFlushMap (vfm): Mesa vn_protocol vkFlushMappedMemoryRanges CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VfmEn;
    // VenusInvalidateMap (vim): Mesa vn_protocol vkInvalidateMappedMemoryRanges CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VimEn;
    // VenusMemCommit (vmc): Mesa vn_protocol vkGetDeviceMemoryCommitment CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VmcEn;
    // VenusDescLayout (vdl): Mesa vn_protocol vkCreateDescriptorSetLayout CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VdlEn;
    // VenusPipeLayout (vpl): Mesa vn_protocol vkCreatePipelineLayout CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VplEn;
    // VenusComputePipe (vcp): Mesa vn_protocol vkCreateComputePipelines CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VcpEn;
    // VenusDescAlloc (vda): Mesa vn_protocol vkAllocateDescriptorSets CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VdaEn;
    // VenusUpdateDesc (vud): Mesa vn_protocol vkUpdateDescriptorSets CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VudEn;
    // VenusBindPipe (vbp): Mesa vn_protocol vkCmdBindPipeline CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VbpEn;
    // VenusBindDesc (vbd): Mesa vn_protocol vkCmdBindDescriptorSets CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VbdEn;
    // VenusDescPool (vpo): Mesa vn_protocol vkCreateDescriptorPool CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VpoEn;
    // VenusCreateImage (vxi): Mesa vn_protocol vkCreateImage CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VxiEn;
    // VenusBindImage (vbi): Mesa vn_protocol vkBindImageMemory CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VbiEn;
    // VenusImageReq (vmi): Mesa vn_protocol vkGetImageMemoryRequirements CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VmiEn;
    // VenusImageView (vxv): Mesa vn_protocol vkCreateImageView CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VxvEn;
    // VenusSampler (vsm): Mesa vn_protocol vkCreateSampler CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VsmEn;
    // VenusRenderPass (vrp): Mesa vn_protocol vkCreateRenderPass CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VrpEn;
    // VenusGraphicsPipe (vgp): Mesa vn_protocol vkCreateGraphicsPipelines CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VgpEn;
    // VenusFramebuffer (vfb): Mesa vn_protocol vkCreateFramebuffer CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VfbEn;
    // VenusRenderBegin (vrb): Mesa vn_protocol vkCmdBeginRenderPass CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VrbEn;
    // VenusDraw (vdw): Mesa vn_protocol vkCmdDraw CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VdwEn;
    // VenusRenderEnd (vre): Mesa vn_protocol vkCmdEndRenderPass CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VreEn;
    // VenusBindVtx (vvb): Mesa vn_protocol vkCmdBindVertexBuffers CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VvbEn;
    // VenusBindIdx (vib): Mesa vn_protocol vkCmdBindIndexBuffer CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VibEn;
    // VenusDrawIdx (vdi): Mesa vn_protocol vkCmdDrawIndexed CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VdiEn;
    // VenusSetViewport (vvp): Mesa vn_protocol vkCmdSetViewport CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VvpEn;
    // VenusSetScissor (vsi): Mesa vn_protocol vkCmdSetScissor CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VsiEn;
    // VenusBarrier (vpb): Mesa vn_protocol vkCmdPipelineBarrier CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VpbEn;
    // VenusNextSubpass (vns): Mesa vn_protocol vkCmdNextSubpass CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VnsEn;
    // VenusDestroyFbuf (vdf): Mesa vn_protocol vkDestroyFramebuffer CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VdfEn;
    // VenusDestroyView (vdx): Mesa vn_protocol vkDestroyImageView CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VdxEn;
    // VenusDestroySampler (vdk): Mesa vn_protocol vkDestroySampler CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VdkEn;
    // VenusDestroyRpass (vdr): Mesa vn_protocol vkDestroyRenderPass CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VdrEn;
    // VenusDestroyBuf (vdb): Mesa vn_protocol vkDestroyBuffer CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VdbEn;
    // VenusDestroyImg (vdg): Mesa vn_protocol vkDestroyImage CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VdgEn;
    // VenusFreeMemory (vfe): Mesa vn_protocol vkFreeMemory CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VfeEn;
    // VenusDestroyModule (vdm): Mesa vn_protocol vkDestroyShaderModule CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VdmEn;
    // VenusDestroyPipe (vdp): Mesa vn_protocol vkDestroyPipeline CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VdpEn;
    // VenusDestroyPlayout (vdy): Mesa vn_protocol vkDestroyPipelineLayout CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VdyEn;
    // VenusDestroyDsl (vdt): Mesa vn_protocol vkDestroyDescriptorSetLayout CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VdtEn;
    // VenusDestroyPool (vdq): Mesa vn_protocol vkDestroyDescriptorPool CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VdqEn;
    // VenusFreeDescset (vfs): Mesa vn_protocol vkFreeDescriptorSets CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VfsEn;
    // VenusResetCmdbuf (vrc): Mesa vn_protocol vkResetCommandBuffer CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VrcEn;
    // VenusFreeCmdbuf (vfc): Mesa vn_protocol vkFreeCommandBuffers CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VfcEn;
    // VenusDestroyDevice (vdd): Mesa vn_protocol vkDestroyDevice CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VddEn;
    // VenusResetCmdPool (vpc): Mesa vn_protocol vkResetCommandPool CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VpcEn;
    // VenusDestroyCmdPool (vdc): Mesa vn_protocol vkDestroyCommandPool CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VdcEn;
    // VenusDestroyInstance (vdn): Mesa vn_protocol vkDestroyInstance CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VdnEn;
    // VenusFormatProps (vgf): Mesa vn_protocol vkGetPhysicalDeviceFormatProperties CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VgfEn;
    // VenusImageFormat (vip): Mesa vn_protocol vkGetPhysicalDeviceImageFormatProperties CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VipEn;
    // VenusDeviceExt (vxe): Mesa vn_protocol vkEnumerateDeviceExtensionProperties CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VxeEn;
    // VenusResetDescPool (vrd): Mesa vn_protocol vkResetDescriptorPool CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VrdEn;
    // VenusInstanceExt (vie): Mesa vn_protocol vkEnumerateInstanceExtensionProperties CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VieEn;
    // VenusDeviceWait (vwl): Mesa vn_protocol vkDeviceWaitIdle CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VwlEn;
    // VenusSubresourceLayout (vsl): Mesa vn_protocol vkGetImageSubresourceLayout CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VslEn;
    // VenusRenderGranularity (vrg): Mesa vn_protocol vkGetRenderAreaGranularity CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VrgEn;
    // VenusSetLineWidth (vlw): Mesa vn_protocol vkCmdSetLineWidth CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VlwEn;
    // VenusSetDepthBias (vzb): Mesa vn_protocol vkCmdSetDepthBias CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VzbEn;
    // VenusSetBlendConst (vbc): Mesa vn_protocol vkCmdSetBlendConstants CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VbcEn;
    // VenusSetDepthBounds (vbo): Mesa vn_protocol vkCmdSetDepthBounds CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VboEn;
    // VenusSetStencilCompare (vcm): Mesa vn_protocol vkCmdSetStencilCompareMask CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VcmEn;
    // VenusSetStencilWrite (vwm): Mesa vn_protocol vkCmdSetStencilWriteMask CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VwmEn;
    // VenusSetStencilRef (vrf): Mesa vn_protocol vkCmdSetStencilReference CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VrfEn;
    // VenusCopyBuffer (vcc): Mesa vn_protocol vkCmdCopyBuffer CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VccEn;
    // VenusCopyImage (vcy): Mesa vn_protocol vkCmdCopyImage CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VcyEn;
    // VenusBlitImage (vbl): Mesa vn_protocol vkCmdBlitImage CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VblEn;
    // VenusCopyBufToImg (vbt): Mesa vn_protocol vkCmdCopyBufferToImage CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VbtEn;
    // VenusCopyImgToBuf (vic): Mesa vn_protocol vkCmdCopyImageToBuffer CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VicEn;
    // VenusUpdateBuffer (vub): Mesa vn_protocol vkCmdUpdateBuffer CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VubEn;
    // VenusFillBuffer (vfl): Mesa vn_protocol vkCmdFillBuffer CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VflEn;
    // VenusClearColor (vcl): Mesa vn_protocol vkCmdClearColorImage CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VclEn;
    // VenusDrawIndirect (vio): Mesa vn_protocol vkCmdDrawIndirect CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VioEn;
    // VenusDrawIdxIndirect (vix): Mesa vn_protocol vkCmdDrawIndexedIndirect CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VixEn;
    // VenusClearDepth (vds): Mesa vn_protocol vkCmdClearDepthStencilImage CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VdsEn;
    // VenusClearAttach (vat): Mesa vn_protocol vkCmdClearAttachments CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VatEn;
    // VenusDispatchIndirect (vin): Mesa vn_protocol vkCmdDispatchIndirect CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VinEn;
    // VenusResolveImage (vrs): Mesa vn_protocol vkCmdResolveImage CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0.
    logic        VrsEn;
    // VenusGetFenceStatus (vgs): Mesa vn_protocol vkGetFenceStatus CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0. No FENCE kind.
    logic        VgsEn;
    // VenusWaitForFences (vwf): Mesa vn_protocol vkWaitForFences CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0. No FENCE kind.
    logic        VwfEn;
    // VenusResetFences (vfr): Mesa vn_protocol vkResetFences CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0. No FENCE kind.
    logic        VfrEn;
    // VenusDestroyFence (vfn): Mesa vn_protocol vkDestroyFence CS. Default-off. FeatureVirgl stays illegal. NumCapsets stays 0. No FENCE kind.
    logic        VfnEn;
  } apu_cfg_t;

  localparam apu_cfg_t ApuOff = '{
      Enable:             1'b0,
      FeatureVirgl:       1'b0,
      FeatureEdid:        1'b0,
      FeatureIndirectDesc:1'b0,
      FeatureEventIdx:    1'b0,
      FeatureInOrder:     1'b0,
      FeatureRingReset:   1'b0,
      NumQueues:          unsigned'(APU_NUM_QUEUES),
      QueueDepth:         unsigned'(64),
      MaxContexts:        unsigned'(0),
      MaxResources:       unsigned'(0),
      MaxCmdBytes:        unsigned'(0),
      MaxShaderBytes:     unsigned'(0),
      DmaMaxOutstanding:  unsigned'(1),
      DmaCoherent:        1'b0,
      DmaReadEn:          1'b0,
      DmaWriteEn:         1'b0,
      DmaWriteMaxBytes:   unsigned'(65536),
      DmaReadMaxBytes:    unsigned'(65536),
      DmaReadBurstBeats:  unsigned'(16),
      DmaWindowBase:      64'h0,
      DmaWindowBytes:     64'h0,
      SgEn:               1'b0,
      SgMaxEntries:       unsigned'(64),
      SgMaxTransferBytes: unsigned'(1048576),
      NumScanouts:        unsigned'(0),
      NumCapsets:         unsigned'(0),
      FirmwareHart:       unsigned'(APU_FW_HART_UNASSIGNED),
      FirmwareRamBase:    64'h0,
      FirmwareRamBytes:   64'h0,
      MmioBase:           APU_MMIO_BASE,
      MmioLength:         APU_MMIO_LEN,
      ControlBase:        APU_CONTROL_BASE,
      ControlLength:      APU_CONTROL_LEN,
      IrqSource:          unsigned'(APU_IRQ_SOURCE),
      ExecEn:             1'b0,
      ExecQuadThreads:    unsigned'(APU_EXEC_THREADS),
      ExecRegs:           unsigned'(APU_EXEC_REGS),
      ExecMemWords:       unsigned'(APU_EXEC_DMEM_WORDS),
      CoverEn:            1'b0,
      FragEn:             1'b0,
      TexelEn:            1'b0,
      ProtoEn:            1'b0,
      UsedEn:             1'b0,
      AvailEn:            1'b0,
      BackEn:             1'b0,
      XferEn:             1'b0,
      UwrEn:              1'b0,
      UidxEn:             1'b0,
      SurfEn:             1'b0,
      RdbEn:              1'b0,
      SubEn:              1'b0,
      BufEn:              1'b0,
      DecEn:              1'b0,
      ShEn:               1'b0,
      FsEn:               1'b0,
      VeEn:               1'b0,
      SvEn:               1'b0,
      SsEn:               1'b0,
      BlEn:               1'b0,
      DsEn:               1'b0,
      RzEn:               1'b0,
      BbEn:               1'b0,
      DbEn:               1'b0,
      RbEn:               1'b0,
      VsbEn:              1'b0,
      FsbEn:              1'b0,
      VebEn:              1'b0,
      SsbEn:              1'b0,
      SvbEn:              1'b0,
      IwEn:               1'b0,
      VbEn:               1'b0,
      SciEn:              1'b0,
      VpEn:               1'b0,
      FboEn:              1'b0,
      ClrEn:              1'b0,
      DrwEn:              1'b0,
      CtxEn:              1'b0,
      C3dEn:              1'b0,
      AttEn:              1'b0,
      RspEn:              1'b0,
      NfoEn:              1'b0,
      CapEn:              1'b0,
      ScnEn:              1'b0,
      FluEn:              1'b0,
      ChnEn:              1'b0,
      CmxEn:              1'b0,
      SunEn:              1'b0,
      SuwEn:              1'b0,
      SuxEn:              1'b0,
      U8En:               1'b0,
      PixEn:              1'b0,
      PxrEn:              1'b0,
      FilEn:              1'b0,
      FrdEn:              1'b0,
      QdEn:               1'b0,
      CvEn:               1'b0,
      CvrEn:              1'b0,
      VstEn:              1'b0,
      FstEn:              1'b0,
      HldEn:              1'b0,
      TbnEn:              1'b0,
      DenEn:              1'b0,
      DnrEn:              1'b0,
      S2dEn:              1'b0,
      SbkEn:              1'b0,
      SxfEn:              1'b0,
      SscEn:              1'b0,
      SflEn:              1'b0,
      SprEn:              1'b0,
      BcpEn:              1'b0,
      BcrEn:              1'b0,
      TapEn:              1'b0,
      PxcEn:              1'b0,
      PxqEn:              1'b0,
      LinEn:              1'b0,
      LnrEn:              1'b0,
      SpnEn:              1'b0,
      SpxEn:              1'b0,
      VlnEn:              1'b0,
      VlrEn:              1'b0,
      VbxEn:              1'b0,
      VbrEn:              1'b0,
      VspEn:              1'b0,
      VsxEn:              1'b0,
      Y2bEn:              1'b0,
      Y2rEn:              1'b0,
      SmpEn:              1'b0,
      SmxEn:              1'b0,
      RbfEn:              1'b0,
      RbkEn:              1'b0,
      RdrEn:              1'b0,
      RdkEn:              1'b0,
      FetEn:              1'b0,
      FekEn:              1'b0,
      DrdEn:              1'b0,
      DrkEn:              1'b0,
      QdrEn:              1'b0,
      QdkEn:              1'b0,
      VwxEn:              1'b0,
      VwkEn:              1'b0,
      CxrEn:              1'b0,
      CxkEn:              1'b0,
      CwrEn:              1'b0,
      CwkEn:              1'b0,
      FbrEn:              1'b0,
      FbkEn:              1'b0,
      VbfEn:              1'b0,
      VbkEn:              1'b0,
      IwrEn:              1'b0,
      IwkEn:              1'b0,
      SvrEn:              1'b0,
      SvkEn:              1'b0,
      SsrEn:              1'b0,
      SskEn:              1'b0,
      VerEn:              1'b0,
      VekEn:              1'b0,
      FsrEn:              1'b0,
      FskEn:              1'b0,
      VsrEn:              1'b0,
      VskEn:              1'b0,
      RzrEn:              1'b0,
      RzkEn:              1'b0,
      DbrEn:              1'b0,
      DbkEn:              1'b0,
      BbrEn:              1'b0,
      BbkEn:              1'b0,
      RcrEn:              1'b0,
      RckEn:              1'b0,
      DcrEn:              1'b0,
      DckEn:              1'b0,
      BlrEn:              1'b0,
      BlkEn:              1'b0,
      ScrEn:              1'b0,
      SckEn:              1'b0,
      SvcEn:              1'b0,
      VckEn:              1'b0,
      VecEn:              1'b0,
      VceEn:              1'b0,
      FscEn:              1'b0,
      FceEn:              1'b0,
      VscEn:              1'b0,
      VseEn:              1'b0,
      SfcEn:              1'b0,
      SfeEn:              1'b0,
      NxcEn:              1'b0,
      NxkEn:              1'b0,
      OlsEn:              1'b0,
      OlkEn:              1'b0,
      GpwEn:              1'b0,
      GprEn:              1'b0,
      GpkEn:              1'b0,
      GcwEn:              1'b0,
      GcrEn:              1'b0,
      GckEn:              1'b0,
      ViwEn:              1'b0,
      VirEn:              1'b0,
      VikEn:              1'b0,
      VawEn:              1'b0,
      VarEn:              1'b0,
      VakEn:              1'b0,
      WfrEn:              1'b0,
      WfkEn:              1'b0,
      WfxEn:              1'b0,
      GbwEn:              1'b0,
      GbrEn:              1'b0,
      GbkEn:              1'b0,
      GbdEn:              1'b0,
      GblEn:              1'b0,
      GbxEn:              1'b0,
      GofEn:              1'b0,
      GboEn:              1'b0,
      GbzEn:              1'b0,
      ByrEn:              1'b0,
      BykEn:              1'b0,
      ByxEn:              1'b0,
      RyrEn:              1'b0,
      RykEn:              1'b0,
      RyxEn:              1'b0,
      TprEn:              1'b0,
      TpkEn:              1'b0,
      TpxEn:              1'b0,
      X6rEn:              1'b0,
      X6kEn:              1'b0,
      X6xEn:              1'b0,
      TcrEn:              1'b0,
      TckEn:              1'b0,
      TcxEn:              1'b0,
      P7rEn:              1'b0,
      P7kEn:              1'b0,
      P7xEn:              1'b0,
      B1rEn:              1'b0,
      B1kEn:              1'b0,
      B1xEn:              1'b0,
      B7rEn:              1'b0,
      B7kEn:              1'b0,
      B7xEn:              1'b0,
      B2rEn:              1'b0,
      B2kEn:              1'b0,
      B2xEn:              1'b0,
      B3rEn:              1'b0,
      B3kEn:              1'b0,
      B3xEn:              1'b0,
      B4rEn:              1'b0,
      B4kEn:              1'b0,
      B4xEn:              1'b0,
      B5rEn:              1'b0,
      B5kEn:              1'b0,
      B5xEn:              1'b0,
      B6rEn:              1'b0,
      B6kEn:              1'b0,
      B6xEn:              1'b0,
      AcwEn:              1'b0,
      AcrEn:              1'b0,
      AcxEn:              1'b0,
      CswEn:              1'b0,
      CsrEn:              1'b0,
      CsxEn:              1'b0,
      CrdEn:              1'b0,
      CrlEn:              1'b0,
      CrxEn:              1'b0,
      CofEn:              1'b0,
      CorEn:              1'b0,
      CoxEn:              1'b0,
      RpwEn:              1'b0,
      RprEn:              1'b0,
      RpxEn:              1'b0,
      GrdEn:              1'b0,
      GrlEn:              1'b0,
      GrxEn:              1'b0,
      RofEn:              1'b0,
      RorEn:              1'b0,
      RoxEn:              1'b0,
      TfbEn:              1'b0,
      TfrEn:              1'b0,
      TfxEn:              1'b0,
      RabEn:              1'b0,
      RarEn:              1'b0,
      RaxEn:              1'b0,
      RfwEn:              1'b0,
      RfrEn:              1'b0,
      RfxEn:              1'b0,
      TuwEn:              1'b0,
      TurEn:              1'b0,
      TuxEn:              1'b0,
      TiwEn:              1'b0,
      TirEn:              1'b0,
      TixEn:              1'b0,
      TawEn:              1'b0,
      TarEn:              1'b0,
      TaxEn:              1'b0,
      TxcEn:              1'b0,
      TxkEn:              1'b0,
      TxxEn:              1'b0,
      FtxEn:              1'b0,
      FtrEn:              1'b0,
      FtkEn:              1'b0,
      OcwEn:              1'b0,
      OcrEn:              1'b0,
      OcxEn:              1'b0,
      PbwEn:              1'b0,
      PbrEn:              1'b0,
      PbxEn:              1'b0,
      TnwEn:              1'b0,
      TnkEn:              1'b0,
      TnxEn:              1'b0,
      QntEn:              1'b0,
      QnrEn:              1'b0,
      QnxEn:              1'b0,
      QavEn:              1'b0,
      QakEn:              1'b0,
      QaxEn:              1'b0,
      QrgEn:              1'b0,
      QrkEn:              1'b0,
      QrxEn:              1'b0,
      QhdEn:              1'b0,
      QhkEn:              1'b0,
      QhxEn:              1'b0,
      QfdEn:              1'b0,
      QfkEn:              1'b0,
      QfxEn:              1'b0,
      QwdEn:              1'b0,
      QwkEn:              1'b0,
      QwxEn:              1'b0,
      QokEn:              1'b0,
      QolEn:              1'b0,
      QoxEn:              1'b0,
      QuwEn:              1'b0,
      QulEn:              1'b0,
      QuxEn:              1'b0,
      QiwEn:              1'b0,
      QirEn:              1'b0,
      QixEn:              1'b0,
      QawEn:              1'b0,
      QarEn:              1'b0,
      QayEn:              1'b0,
      QsvEn:              1'b0,
      QskEn:              1'b0,
      QsxEn:              1'b0,
      QsrEn:              1'b0,
      QslEn:              1'b0,
      QsyEn:              1'b0,
      QsdEn:              1'b0,
      QseEn:              1'b0,
      QsfEn:              1'b0,
      QedEn:              1'b0,
      QekEn:              1'b0,
      QexEn:              1'b0,
      QrsEn:              1'b0,
      QrtEn:              1'b0,
      QruEn:              1'b0,
      QsoEn:              1'b0,
      QspEn:              1'b0,
      QsqEn:              1'b0,
      QsuEn:              1'b0,
      QstEn:              1'b0,
      QszEn:              1'b0,
      QsiEn:              1'b0,
      QsnEn:              1'b0,
      QsmEn:              1'b0,
      QgaEn:              1'b0,
      QgkEn:              1'b0,
      QgxEn:              1'b0,
      SnwEn:              1'b0,
      SnkEn:              1'b0,
      SnxEn:              1'b0,
      SntEn:              1'b0,
      SnrEn:              1'b0,
      SnyEn:              1'b0,
      SavEn:              1'b0,
      SakEn:              1'b0,
      SaxEn:              1'b0,
      SrgEn:              1'b0,
      SrkEn:              1'b0,
      SrxEn:              1'b0,
      ShdEn:              1'b0,
      ShkEn:              1'b0,
      ShxEn:              1'b0,
      SfdEn:              1'b0,
      SfkEn:              1'b0,
      SfxEn:              1'b0,
      SwdEn:              1'b0,
      SwkEn:              1'b0,
      SwxEn:              1'b0,
      SokEn:              1'b0,
      SolEn:              1'b0,
      SoxEn:              1'b0,
      SlwEn:              1'b0,
      SllEn:              1'b0,
      SlxEn:              1'b0,
      SiwEn:              1'b0,
      SirEn:              1'b0,
      SixEn:              1'b0,
      SgaEn:              1'b0,
      SgkEn:              1'b0,
      SgxEn:              1'b0,
      RnwEn:              1'b0,
      RnkEn:              1'b0,
      RnxEn:              1'b0,
      RntEn:              1'b0,
      RnrEn:              1'b0,
      RnyEn:              1'b0,
      RavEn:              1'b0,
      RakEn:              1'b0,
      RayEn:              1'b0,
      RrgEn:              1'b0,
      RrkEn:              1'b0,
      RrxEn:              1'b0,
      RhdEn:              1'b0,
      RhkEn:              1'b0,
      RhxEn:              1'b0,
      RfdEn:              1'b0,
      RfkEn:              1'b0,
      RfyEn:              1'b0,
      RwdEn:              1'b0,
      RwkEn:              1'b0,
      RwxEn:              1'b0,
      RokEn:              1'b0,
      RolEn:              1'b0,
      RoyEn:              1'b0,
      RuwEn:              1'b0,
      RulEn:              1'b0,
      RuxEn:              1'b0,
      RiwEn:              1'b0,
      RirEn:              1'b0,
      RixEn:              1'b0,
      RgaEn:              1'b0,
      RgkEn:              1'b0,
      RgxEn:              1'b0,
      GtxEn:              1'b0,
      GtrEn:              1'b0,
      GtkEn:              1'b0,
      HcwEn:              1'b0,
      HcrEn:              1'b0,
      HcxEn:              1'b0,
      WldEn:              1'b0,
      WlrEn:              1'b0,
      WlkEn:              1'b0,
      CyrEn:              1'b0,
      CykEn:              1'b0,
      CyxEn:              1'b0,
      GnwEn:              1'b0,
      GnkEn:              1'b0,
      GnxEn:              1'b0,
      GefEn:              1'b0,
      GekEn:              1'b0,
      GexEn:              1'b0,
      SpirvEn:            1'b0,
      ChainEn:            1'b0,
      CdmaEn:             1'b0,
      ShmEn:              1'b0,
      HvisEn:             1'b0,
      VncsEn:             1'b0,
      VcapEn:             1'b0,
      VnringEn:           1'b0,
      TdmaEn:             1'b0,
      VnencEn:            1'b0,
      VnpEn:              1'b0,
      AvnEn:              1'b0,
      AvuEn:              1'b0,
      UirEn:              1'b0,
      CmsEn:              1'b0,
      PrsEn:              1'b0,
      QdnEn:              1'b0,
      GcsEn:              1'b0,
      VndEn:              1'b0,
      GnhEn:              1'b0,
      HdpEn:              1'b0,
      HphEn:              1'b0,
      HrnEn:              1'b0,
      RdnEn:              1'b0,
      QrnEn:              1'b0,
      QcmEn:              1'b0,
      QtyEn:              1'b0,
      VctEn:              1'b0,
      QpuEn:              1'b0,
      NtkEn:              1'b0,
      VqtEn:              1'b0,
      VaxEn:              1'b0,
      VacEn:              1'b0,
      HalEn:              1'b0,
      AruEn:              1'b0,
      QalEn:              1'b0,
      QtaEn:              1'b0,
      VcaEn:              1'b0,
      QpaEn:              1'b0,
      NtaEn:              1'b0,
      VqaEn:              1'b0,
      VaaEn:              1'b0,
      VbgEn:              1'b0,
      BalEn:              1'b0,
      BruEn:              1'b0,
      QbnEn:              1'b0,
      QtbEn:              1'b0,
      VcbEn:              1'b0,
      QpbEn:              1'b0,
      NtbEn:              1'b0,
      VqbEn:              1'b0,
      VabEn:              1'b0,
      VenEn:              1'b0,
      EalEn:              1'b0,
      VqsEn:              1'b0,
      VwiEn:              1'b0,
      VgqEn:              1'b0,
      VcdEn:              1'b0,
      VciEn:              1'b0,
      VepEn:              1'b0,
      VqfEn:              1'b0,
      VpfEn:              1'b0,
      VppEn:              1'b0,
      VmpEn:              1'b0,
      VamEn:              1'b0,
      VxbEn:              1'b0,
      VbbEn:              1'b0,
      VmmEn:              1'b0,
      VumEn:              1'b0,
      VbmEn:              1'b0,
      VfmEn:              1'b0,
      VimEn:              1'b0,
      VmcEn:              1'b0,
      VdlEn:              1'b0,
      VplEn:              1'b0,
      VcpEn:              1'b0,
      VdaEn:              1'b0,
      VudEn:              1'b0,
      VbpEn:              1'b0,
      VbdEn:              1'b0,
      VpoEn:              1'b0,
      VxiEn:              1'b0,
      VbiEn:              1'b0,
      VmiEn:              1'b0,
      VxvEn:              1'b0,
      VsmEn:              1'b0,
      VrpEn:              1'b0,
      VgpEn:              1'b0,
      VfbEn:              1'b0,
      VrbEn:              1'b0,
      VdwEn:              1'b0,
      VreEn:              1'b0,
      VvbEn:              1'b0,
      VibEn:              1'b0,
      VdiEn:              1'b0,
      VvpEn:              1'b0,
      VsiEn:              1'b0,
      VpbEn:              1'b0,
      VnsEn:              1'b0,
      VdfEn:              1'b0,
      VdxEn:              1'b0,
      VdkEn:              1'b0,
      VdrEn:              1'b0,
      VdbEn:              1'b0,
      VdgEn:              1'b0,
      VfeEn:              1'b0,
      VdmEn:              1'b0,
      VdpEn:              1'b0,
      VdyEn:              1'b0,
      VdtEn:              1'b0,
      VdqEn:              1'b0,
      VfsEn:              1'b0,
      VrcEn:              1'b0,
      VfcEn:              1'b0,
      VddEn:              1'b0,
      VpcEn:              1'b0,
      VdcEn:              1'b0,
      VdnEn:              1'b0,
      VgfEn:              1'b0,
      VipEn:              1'b0,
      VxeEn:              1'b0,
      VrdEn:              1'b0,
      VieEn:              1'b0,
      VwlEn:              1'b0,
      VslEn:              1'b0,
      VrgEn:              1'b0,
      VlwEn:              1'b0,
      VzbEn:              1'b0,
      VbcEn:              1'b0,
      VboEn:              1'b0,
      VcmEn:              1'b0,
      VwmEn:              1'b0,
      VrfEn:              1'b0,
      VccEn:              1'b0,
      VcyEn:              1'b0,
      VblEn:              1'b0,
      VbtEn:              1'b0,
      VicEn:              1'b0,
      VubEn:              1'b0,
      VflEn:              1'b0,
      VclEn:              1'b0,
      VioEn:              1'b0,
      VixEn:              1'b0,
      VdsEn:              1'b0,
      VatEn:              1'b0,
      VinEn:              1'b0,
      VrsEn:              1'b0,
      VgsEn:              1'b0,
      VwfEn:              1'b0,
      VfrEn:              1'b0,
      VfnEn:              1'b0
  };

  // P1 transport bring-up profile: modern virtio-mmio, control/cursor queue
  // state, feature negotiation, reset and interrupt plumbing. No virgl capset,
  // scanout, or command execution is advertised yet.
  localparam apu_cfg_t ApuP1Transport = '{
      Enable:             1'b1,
      FeatureVirgl:       1'b0,
      FeatureEdid:        1'b0,
      FeatureIndirectDesc:1'b0,
      FeatureEventIdx:    1'b0,
      FeatureInOrder:     1'b0,
      FeatureRingReset:   1'b1,
      NumQueues:          unsigned'(APU_NUM_QUEUES),
      QueueDepth:         unsigned'(64),
      MaxContexts:        unsigned'(0),
      MaxResources:       unsigned'(0),
      MaxCmdBytes:        unsigned'(0),
      MaxShaderBytes:     unsigned'(0),
      DmaMaxOutstanding:  unsigned'(2),
      DmaCoherent:        1'b0,
      DmaReadEn:          1'b0,
      DmaWriteEn:         1'b0,
      DmaWriteMaxBytes:   unsigned'(65536),
      DmaReadMaxBytes:    unsigned'(65536),
      DmaReadBurstBeats:  unsigned'(16),
      DmaWindowBase:      64'h0,
      DmaWindowBytes:     64'h0,
      SgEn:               1'b0,
      SgMaxEntries:       unsigned'(64),
      SgMaxTransferBytes: unsigned'(1048576),
      NumScanouts:        unsigned'(0),
      NumCapsets:         unsigned'(0),
      FirmwareHart:       unsigned'(APU_FW_HART_UNASSIGNED),
      FirmwareRamBase:    64'h0,
      FirmwareRamBytes:   64'h0,
      MmioBase:           APU_MMIO_BASE,
      MmioLength:         APU_MMIO_LEN,
      ControlBase:        APU_CONTROL_BASE,
      ControlLength:      APU_CONTROL_LEN,
      IrqSource:          unsigned'(APU_IRQ_SOURCE),
      ExecEn:             1'b0,
      ExecQuadThreads:    unsigned'(APU_EXEC_THREADS),
      ExecRegs:           unsigned'(APU_EXEC_REGS),
      ExecMemWords:       unsigned'(APU_EXEC_DMEM_WORDS),
      CoverEn:            1'b0,
      FragEn:             1'b0,
      TexelEn:            1'b0,
      ProtoEn:            1'b0,
      UsedEn:             1'b0,
      AvailEn:            1'b0,
      BackEn:             1'b0,
      XferEn:             1'b0,
      UwrEn:              1'b0,
      UidxEn:             1'b0,
      SurfEn:             1'b0,
      RdbEn:              1'b0,
      SubEn:              1'b0,
      BufEn:              1'b0,
      DecEn:              1'b0,
      ShEn:               1'b0,
      FsEn:               1'b0,
      VeEn:               1'b0,
      SvEn:               1'b0,
      SsEn:               1'b0,
      BlEn:               1'b0,
      DsEn:               1'b0,
      RzEn:               1'b0,
      BbEn:               1'b0,
      DbEn:               1'b0,
      RbEn:               1'b0,
      VsbEn:              1'b0,
      FsbEn:              1'b0,
      VebEn:              1'b0,
      SsbEn:              1'b0,
      SvbEn:              1'b0,
      IwEn:               1'b0,
      VbEn:               1'b0,
      SciEn:              1'b0,
      VpEn:               1'b0,
      FboEn:              1'b0,
      ClrEn:              1'b0,
      DrwEn:              1'b0,
      CtxEn:              1'b0,
      C3dEn:              1'b0,
      AttEn:              1'b0,
      RspEn:              1'b0,
      NfoEn:              1'b0,
      CapEn:              1'b0,
      ScnEn:              1'b0,
      FluEn:              1'b0,
      ChnEn:              1'b0,
      CmxEn:              1'b0,
      SunEn:              1'b0,
      SuwEn:              1'b0,
      SuxEn:              1'b0,
      U8En:               1'b0,
      PixEn:              1'b0,
      PxrEn:              1'b0,
      FilEn:              1'b0,
      FrdEn:              1'b0,
      QdEn:               1'b0,
      CvEn:               1'b0,
      CvrEn:              1'b0,
      VstEn:              1'b0,
      FstEn:              1'b0,
      HldEn:              1'b0,
      TbnEn:              1'b0,
      DenEn:              1'b0,
      DnrEn:              1'b0,
      S2dEn:              1'b0,
      SbkEn:              1'b0,
      SxfEn:              1'b0,
      SscEn:              1'b0,
      SflEn:              1'b0,
      SprEn:              1'b0,
      BcpEn:              1'b0,
      BcrEn:              1'b0,
      TapEn:              1'b0,
      PxcEn:              1'b0,
      PxqEn:              1'b0,
      LinEn:              1'b0,
      LnrEn:              1'b0,
      SpnEn:              1'b0,
      SpxEn:              1'b0,
      VlnEn:              1'b0,
      VlrEn:              1'b0,
      VbxEn:              1'b0,
      VbrEn:              1'b0,
      VspEn:              1'b0,
      VsxEn:              1'b0,
      Y2bEn:              1'b0,
      Y2rEn:              1'b0,
      SmpEn:              1'b0,
      SmxEn:              1'b0,
      RbfEn:              1'b0,
      RbkEn:              1'b0,
      RdrEn:              1'b0,
      RdkEn:              1'b0,
      FetEn:              1'b0,
      FekEn:              1'b0,
      DrdEn:              1'b0,
      DrkEn:              1'b0,
      QdrEn:              1'b0,
      QdkEn:              1'b0,
      VwxEn:              1'b0,
      VwkEn:              1'b0,
      CxrEn:              1'b0,
      CxkEn:              1'b0,
      CwrEn:              1'b0,
      CwkEn:              1'b0,
      FbrEn:              1'b0,
      FbkEn:              1'b0,
      VbfEn:              1'b0,
      VbkEn:              1'b0,
      IwrEn:              1'b0,
      IwkEn:              1'b0,
      SvrEn:              1'b0,
      SvkEn:              1'b0,
      SsrEn:              1'b0,
      SskEn:              1'b0,
      VerEn:              1'b0,
      VekEn:              1'b0,
      FsrEn:              1'b0,
      FskEn:              1'b0,
      VsrEn:              1'b0,
      VskEn:              1'b0,
      RzrEn:              1'b0,
      RzkEn:              1'b0,
      DbrEn:              1'b0,
      DbkEn:              1'b0,
      BbrEn:              1'b0,
      BbkEn:              1'b0,
      RcrEn:              1'b0,
      RckEn:              1'b0,
      DcrEn:              1'b0,
      DckEn:              1'b0,
      BlrEn:              1'b0,
      BlkEn:              1'b0,
      ScrEn:              1'b0,
      SckEn:              1'b0,
      SvcEn:              1'b0,
      VckEn:              1'b0,
      VecEn:              1'b0,
      VceEn:              1'b0,
      FscEn:              1'b0,
      FceEn:              1'b0,
      VscEn:              1'b0,
      VseEn:              1'b0,
      SfcEn:              1'b0,
      SfeEn:              1'b0,
      NxcEn:              1'b0,
      NxkEn:              1'b0,
      OlsEn:              1'b0,
      OlkEn:              1'b0,
      GpwEn:              1'b0,
      GprEn:              1'b0,
      GpkEn:              1'b0,
      GcwEn:              1'b0,
      GcrEn:              1'b0,
      GckEn:              1'b0,
      ViwEn:              1'b0,
      VirEn:              1'b0,
      VikEn:              1'b0,
      VawEn:              1'b0,
      VarEn:              1'b0,
      VakEn:              1'b0,
      WfrEn:              1'b0,
      WfkEn:              1'b0,
      WfxEn:              1'b0,
      GbwEn:              1'b0,
      GbrEn:              1'b0,
      GbkEn:              1'b0,
      GbdEn:              1'b0,
      GblEn:              1'b0,
      GbxEn:              1'b0,
      GofEn:              1'b0,
      GboEn:              1'b0,
      GbzEn:              1'b0,
      ByrEn:              1'b0,
      BykEn:              1'b0,
      ByxEn:              1'b0,
      RyrEn:              1'b0,
      RykEn:              1'b0,
      RyxEn:              1'b0,
      TprEn:              1'b0,
      TpkEn:              1'b0,
      TpxEn:              1'b0,
      X6rEn:              1'b0,
      X6kEn:              1'b0,
      X6xEn:              1'b0,
      TcrEn:              1'b0,
      TckEn:              1'b0,
      TcxEn:              1'b0,
      P7rEn:              1'b0,
      P7kEn:              1'b0,
      P7xEn:              1'b0,
      B1rEn:              1'b0,
      B1kEn:              1'b0,
      B1xEn:              1'b0,
      B7rEn:              1'b0,
      B7kEn:              1'b0,
      B7xEn:              1'b0,
      B2rEn:              1'b0,
      B2kEn:              1'b0,
      B2xEn:              1'b0,
      B3rEn:              1'b0,
      B3kEn:              1'b0,
      B3xEn:              1'b0,
      B4rEn:              1'b0,
      B4kEn:              1'b0,
      B4xEn:              1'b0,
      B5rEn:              1'b0,
      B5kEn:              1'b0,
      B5xEn:              1'b0,
      B6rEn:              1'b0,
      B6kEn:              1'b0,
      B6xEn:              1'b0,
      AcwEn:              1'b0,
      AcrEn:              1'b0,
      AcxEn:              1'b0,
      CswEn:              1'b0,
      CsrEn:              1'b0,
      CsxEn:              1'b0,
      CrdEn:              1'b0,
      CrlEn:              1'b0,
      CrxEn:              1'b0,
      CofEn:              1'b0,
      CorEn:              1'b0,
      CoxEn:              1'b0,
      RpwEn:              1'b0,
      RprEn:              1'b0,
      RpxEn:              1'b0,
      GrdEn:              1'b0,
      GrlEn:              1'b0,
      GrxEn:              1'b0,
      RofEn:              1'b0,
      RorEn:              1'b0,
      RoxEn:              1'b0,
      TfbEn:              1'b0,
      TfrEn:              1'b0,
      TfxEn:              1'b0,
      RabEn:              1'b0,
      RarEn:              1'b0,
      RaxEn:              1'b0,
      RfwEn:              1'b0,
      RfrEn:              1'b0,
      RfxEn:              1'b0,
      TuwEn:              1'b0,
      TurEn:              1'b0,
      TuxEn:              1'b0,
      TiwEn:              1'b0,
      TirEn:              1'b0,
      TixEn:              1'b0,
      TawEn:              1'b0,
      TarEn:              1'b0,
      TaxEn:              1'b0,
      TxcEn:              1'b0,
      TxkEn:              1'b0,
      TxxEn:              1'b0,
      FtxEn:              1'b0,
      FtrEn:              1'b0,
      FtkEn:              1'b0,
      OcwEn:              1'b0,
      OcrEn:              1'b0,
      OcxEn:              1'b0,
      PbwEn:              1'b0,
      PbrEn:              1'b0,
      PbxEn:              1'b0,
      TnwEn:              1'b0,
      TnkEn:              1'b0,
      TnxEn:              1'b0,
      QntEn:              1'b0,
      QnrEn:              1'b0,
      QnxEn:              1'b0,
      QavEn:              1'b0,
      QakEn:              1'b0,
      QaxEn:              1'b0,
      QrgEn:              1'b0,
      QrkEn:              1'b0,
      QrxEn:              1'b0,
      QhdEn:              1'b0,
      QhkEn:              1'b0,
      QhxEn:              1'b0,
      QfdEn:              1'b0,
      QfkEn:              1'b0,
      QfxEn:              1'b0,
      QwdEn:              1'b0,
      QwkEn:              1'b0,
      QwxEn:              1'b0,
      QokEn:              1'b0,
      QolEn:              1'b0,
      QoxEn:              1'b0,
      QuwEn:              1'b0,
      QulEn:              1'b0,
      QuxEn:              1'b0,
      QiwEn:              1'b0,
      QirEn:              1'b0,
      QixEn:              1'b0,
      QawEn:              1'b0,
      QarEn:              1'b0,
      QayEn:              1'b0,
      QsvEn:              1'b0,
      QskEn:              1'b0,
      QsxEn:              1'b0,
      QsrEn:              1'b0,
      QslEn:              1'b0,
      QsyEn:              1'b0,
      QsdEn:              1'b0,
      QseEn:              1'b0,
      QsfEn:              1'b0,
      QedEn:              1'b0,
      QekEn:              1'b0,
      QexEn:              1'b0,
      QrsEn:              1'b0,
      QrtEn:              1'b0,
      QruEn:              1'b0,
      QsoEn:              1'b0,
      QspEn:              1'b0,
      QsqEn:              1'b0,
      QsuEn:              1'b0,
      QstEn:              1'b0,
      QszEn:              1'b0,
      QsiEn:              1'b0,
      QsnEn:              1'b0,
      QsmEn:              1'b0,
      QgaEn:              1'b0,
      QgkEn:              1'b0,
      QgxEn:              1'b0,
      SnwEn:              1'b0,
      SnkEn:              1'b0,
      SnxEn:              1'b0,
      SntEn:              1'b0,
      SnrEn:              1'b0,
      SnyEn:              1'b0,
      SavEn:              1'b0,
      SakEn:              1'b0,
      SaxEn:              1'b0,
      SrgEn:              1'b0,
      SrkEn:              1'b0,
      SrxEn:              1'b0,
      ShdEn:              1'b0,
      ShkEn:              1'b0,
      ShxEn:              1'b0,
      SfdEn:              1'b0,
      SfkEn:              1'b0,
      SfxEn:              1'b0,
      SwdEn:              1'b0,
      SwkEn:              1'b0,
      SwxEn:              1'b0,
      SokEn:              1'b0,
      SolEn:              1'b0,
      SoxEn:              1'b0,
      SlwEn:              1'b0,
      SllEn:              1'b0,
      SlxEn:              1'b0,
      SiwEn:              1'b0,
      SirEn:              1'b0,
      SixEn:              1'b0,
      SgaEn:              1'b0,
      SgkEn:              1'b0,
      SgxEn:              1'b0,
      RnwEn:              1'b0,
      RnkEn:              1'b0,
      RnxEn:              1'b0,
      RntEn:              1'b0,
      RnrEn:              1'b0,
      RnyEn:              1'b0,
      RavEn:              1'b0,
      RakEn:              1'b0,
      RayEn:              1'b0,
      RrgEn:              1'b0,
      RrkEn:              1'b0,
      RrxEn:              1'b0,
      RhdEn:              1'b0,
      RhkEn:              1'b0,
      RhxEn:              1'b0,
      RfdEn:              1'b0,
      RfkEn:              1'b0,
      RfyEn:              1'b0,
      RwdEn:              1'b0,
      RwkEn:              1'b0,
      RwxEn:              1'b0,
      RokEn:              1'b0,
      RolEn:              1'b0,
      RoyEn:              1'b0,
      RuwEn:              1'b0,
      RulEn:              1'b0,
      RuxEn:              1'b0,
      RiwEn:              1'b0,
      RirEn:              1'b0,
      RixEn:              1'b0,
      RgaEn:              1'b0,
      RgkEn:              1'b0,
      RgxEn:              1'b0,
      GtxEn:              1'b0,
      GtrEn:              1'b0,
      GtkEn:              1'b0,
      HcwEn:              1'b0,
      HcrEn:              1'b0,
      HcxEn:              1'b0,
      WldEn:              1'b0,
      WlrEn:              1'b0,
      WlkEn:              1'b0,
      CyrEn:              1'b0,
      CykEn:              1'b0,
      CyxEn:              1'b0,
      GnwEn:              1'b0,
      GnkEn:              1'b0,
      GnxEn:              1'b0,
      GefEn:              1'b0,
      GekEn:              1'b0,
      GexEn:              1'b0,
      SpirvEn:            1'b0,
      ChainEn:            1'b0,
      CdmaEn:             1'b0,
      ShmEn:              1'b0,
      HvisEn:             1'b0,
      VncsEn:             1'b0,
      VcapEn:             1'b0,
      VnringEn:           1'b0,
      TdmaEn:             1'b0,
      VnencEn:            1'b0,
      VnpEn:              1'b0,
      AvnEn:              1'b0,
      AvuEn:              1'b0,
      UirEn:              1'b0,
      CmsEn:              1'b0,
      PrsEn:              1'b0,
      QdnEn:              1'b0,
      GcsEn:              1'b0,
      VndEn:              1'b0,
      GnhEn:              1'b0,
      HdpEn:              1'b0,
      HphEn:              1'b0,
      HrnEn:              1'b0,
      RdnEn:              1'b0,
      QrnEn:              1'b0,
      QcmEn:              1'b0,
      QtyEn:              1'b0,
      VctEn:              1'b0,
      QpuEn:              1'b0,
      NtkEn:              1'b0,
      VqtEn:              1'b0,
      VaxEn:              1'b0,
      VacEn:              1'b0,
      HalEn:              1'b0,
      AruEn:              1'b0,
      QalEn:              1'b0,
      QtaEn:              1'b0,
      VcaEn:              1'b0,
      QpaEn:              1'b0,
      NtaEn:              1'b0,
      VqaEn:              1'b0,
      VaaEn:              1'b0,
      VbgEn:              1'b0,
      BalEn:              1'b0,
      BruEn:              1'b0,
      QbnEn:              1'b0,
      QtbEn:              1'b0,
      VcbEn:              1'b0,
      QpbEn:              1'b0,
      NtbEn:              1'b0,
      VqbEn:              1'b0,
      VabEn:              1'b0,
      VenEn:              1'b0,
      EalEn:              1'b0,
      VqsEn:              1'b0,
      VwiEn:              1'b0,
      VgqEn:              1'b0,
      VcdEn:              1'b0,
      VciEn:              1'b0,
      VepEn:              1'b0,
      VqfEn:              1'b0,
      VpfEn:              1'b0,
      VppEn:              1'b0,
      VmpEn:              1'b0,
      VamEn:              1'b0,
      VxbEn:              1'b0,
      VbbEn:              1'b0,
      VmmEn:              1'b0,
      VumEn:              1'b0,
      VbmEn:              1'b0,
      VfmEn:              1'b0,
      VimEn:              1'b0,
      VmcEn:              1'b0,
      VdlEn:              1'b0,
      VplEn:              1'b0,
      VcpEn:              1'b0,
      VdaEn:              1'b0,
      VudEn:              1'b0,
      VbpEn:              1'b0,
      VbdEn:              1'b0,
      VpoEn:              1'b0,
      VxiEn:              1'b0,
      VbiEn:              1'b0,
      VmiEn:              1'b0,
      VxvEn:              1'b0,
      VsmEn:              1'b0,
      VrpEn:              1'b0,
      VgpEn:              1'b0,
      VfbEn:              1'b0,
      VrbEn:              1'b0,
      VdwEn:              1'b0,
      VreEn:              1'b0,
      VvbEn:              1'b0,
      VibEn:              1'b0,
      VdiEn:              1'b0,
      VvpEn:              1'b0,
      VsiEn:              1'b0,
      VpbEn:              1'b0,
      VnsEn:              1'b0,
      VdfEn:              1'b0,
      VdxEn:              1'b0,
      VdkEn:              1'b0,
      VdrEn:              1'b0,
      VdbEn:              1'b0,
      VdgEn:              1'b0,
      VfeEn:              1'b0,
      VdmEn:              1'b0,
      VdpEn:              1'b0,
      VdyEn:              1'b0,
      VdtEn:              1'b0,
      VdqEn:              1'b0,
      VfsEn:              1'b0,
      VrcEn:              1'b0,
      VfcEn:              1'b0,
      VddEn:              1'b0,
      VpcEn:              1'b0,
      VdcEn:              1'b0,
      VdnEn:              1'b0,
      VgfEn:              1'b0,
      VipEn:              1'b0,
      VxeEn:              1'b0,
      VrdEn:              1'b0,
      VieEn:              1'b0,
      VwlEn:              1'b0,
      VslEn:              1'b0,
      VrgEn:              1'b0,
      VlwEn:              1'b0,
      VzbEn:              1'b0,
      VbcEn:              1'b0,
      VboEn:              1'b0,
      VcmEn:              1'b0,
      VwmEn:              1'b0,
      VrfEn:              1'b0,
      VccEn:              1'b0,
      VcyEn:              1'b0,
      VblEn:              1'b0,
      VbtEn:              1'b0,
      VicEn:              1'b0,
      VubEn:              1'b0,
      VflEn:              1'b0,
      VclEn:              1'b0,
      VioEn:              1'b0,
      VixEn:              1'b0,
      VdsEn:              1'b0,
      VatEn:              1'b0,
      VinEn:              1'b0,
      VrsEn:              1'b0,
      VgsEn:              1'b0,
      VwfEn:              1'b0,
      VfrEn:              1'b0,
      VfnEn:              1'b0
  };

  // Testharness bring-up: same transport grant as P1, with a reserved
  // firmware hart. Requires two physical cores and NrHarts=1 (apu_soc_legal).
  localparam apu_cfg_t ApuHarness = '{
      Enable:             1'b1,
      FeatureVirgl:       1'b0,
      FeatureEdid:        1'b0,
      FeatureIndirectDesc:1'b0,
      FeatureEventIdx:    1'b0,
      FeatureInOrder:     1'b0,
      FeatureRingReset:   1'b1,
      NumQueues:          unsigned'(APU_NUM_QUEUES),
      QueueDepth:         unsigned'(64),
      MaxContexts:        unsigned'(0),
      MaxResources:       unsigned'(0),
      MaxCmdBytes:        unsigned'(0),
      MaxShaderBytes:     unsigned'(0),
      DmaMaxOutstanding:  unsigned'(2),
      DmaCoherent:        1'b0,
      DmaReadEn:          1'b0,
      DmaWriteEn:         1'b0,
      DmaWriteMaxBytes:   unsigned'(65536),
      DmaReadMaxBytes:    unsigned'(65536),
      DmaReadBurstBeats:  unsigned'(16),
      DmaWindowBase:      64'h0,
      DmaWindowBytes:     64'h0,
      SgEn:               1'b0,
      SgMaxEntries:       unsigned'(64),
      SgMaxTransferBytes: unsigned'(1048576),
      NumScanouts:        unsigned'(0),
      NumCapsets:         unsigned'(0),
      FirmwareHart:       unsigned'(1),
      FirmwareRamBase:    64'h9000_0000,
      FirmwareRamBytes:   64'h40000,
      MmioBase:           APU_MMIO_BASE,
      MmioLength:         APU_MMIO_LEN,
      ControlBase:        APU_CONTROL_BASE,
      ControlLength:      APU_CONTROL_LEN,
      IrqSource:          unsigned'(APU_IRQ_SOURCE),
      ExecEn:             1'b0,
      ExecQuadThreads:    unsigned'(APU_EXEC_THREADS),
      ExecRegs:           unsigned'(APU_EXEC_REGS),
      ExecMemWords:       unsigned'(APU_EXEC_DMEM_WORDS),
      CoverEn:            1'b0,
      FragEn:             1'b0,
      TexelEn:            1'b0,
      ProtoEn:            1'b0,
      UsedEn:             1'b0,
      AvailEn:            1'b0,
      BackEn:             1'b0,
      XferEn:             1'b0,
      UwrEn:              1'b0,
      UidxEn:             1'b0,
      SurfEn:             1'b0,
      RdbEn:              1'b0,
      SubEn:              1'b0,
      BufEn:              1'b0,
      DecEn:              1'b0,
      ShEn:               1'b0,
      FsEn:               1'b0,
      VeEn:               1'b0,
      SvEn:               1'b0,
      SsEn:               1'b0,
      BlEn:               1'b0,
      DsEn:               1'b0,
      RzEn:               1'b0,
      BbEn:               1'b0,
      DbEn:               1'b0,
      RbEn:               1'b0,
      VsbEn:              1'b0,
      FsbEn:              1'b0,
      VebEn:              1'b0,
      SsbEn:              1'b0,
      SvbEn:              1'b0,
      IwEn:               1'b0,
      VbEn:               1'b0,
      SciEn:              1'b0,
      VpEn:               1'b0,
      FboEn:              1'b0,
      ClrEn:              1'b0,
      DrwEn:              1'b0,
      CtxEn:              1'b0,
      C3dEn:              1'b0,
      AttEn:              1'b0,
      RspEn:              1'b0,
      NfoEn:              1'b0,
      CapEn:              1'b0,
      ScnEn:              1'b0,
      FluEn:              1'b0,
      ChnEn:              1'b0,
      CmxEn:              1'b0,
      SunEn:              1'b0,
      SuwEn:              1'b0,
      SuxEn:              1'b0,
      U8En:               1'b0,
      PixEn:              1'b0,
      PxrEn:              1'b0,
      FilEn:              1'b0,
      FrdEn:              1'b0,
      QdEn:               1'b0,
      CvEn:               1'b0,
      CvrEn:              1'b0,
      VstEn:              1'b0,
      FstEn:              1'b0,
      HldEn:              1'b0,
      TbnEn:              1'b0,
      DenEn:              1'b0,
      DnrEn:              1'b0,
      S2dEn:              1'b0,
      SbkEn:              1'b0,
      SxfEn:              1'b0,
      SscEn:              1'b0,
      SflEn:              1'b0,
      SprEn:              1'b0,
      BcpEn:              1'b0,
      BcrEn:              1'b0,
      TapEn:              1'b0,
      PxcEn:              1'b0,
      PxqEn:              1'b0,
      LinEn:              1'b0,
      LnrEn:              1'b0,
      SpnEn:              1'b0,
      SpxEn:              1'b0,
      VlnEn:              1'b0,
      VlrEn:              1'b0,
      VbxEn:              1'b0,
      VbrEn:              1'b0,
      VspEn:              1'b0,
      VsxEn:              1'b0,
      Y2bEn:              1'b0,
      Y2rEn:              1'b0,
      SmpEn:              1'b0,
      SmxEn:              1'b0,
      RbfEn:              1'b0,
      RbkEn:              1'b0,
      RdrEn:              1'b0,
      RdkEn:              1'b0,
      FetEn:              1'b0,
      FekEn:              1'b0,
      DrdEn:              1'b0,
      DrkEn:              1'b0,
      QdrEn:              1'b0,
      QdkEn:              1'b0,
      VwxEn:              1'b0,
      VwkEn:              1'b0,
      CxrEn:              1'b0,
      CxkEn:              1'b0,
      CwrEn:              1'b0,
      CwkEn:              1'b0,
      FbrEn:              1'b0,
      FbkEn:              1'b0,
      VbfEn:              1'b0,
      VbkEn:              1'b0,
      IwrEn:              1'b0,
      IwkEn:              1'b0,
      SvrEn:              1'b0,
      SvkEn:              1'b0,
      SsrEn:              1'b0,
      SskEn:              1'b0,
      VerEn:              1'b0,
      VekEn:              1'b0,
      FsrEn:              1'b0,
      FskEn:              1'b0,
      VsrEn:              1'b0,
      VskEn:              1'b0,
      RzrEn:              1'b0,
      RzkEn:              1'b0,
      DbrEn:              1'b0,
      DbkEn:              1'b0,
      BbrEn:              1'b0,
      BbkEn:              1'b0,
      RcrEn:              1'b0,
      RckEn:              1'b0,
      DcrEn:              1'b0,
      DckEn:              1'b0,
      BlrEn:              1'b0,
      BlkEn:              1'b0,
      ScrEn:              1'b0,
      SckEn:              1'b0,
      SvcEn:              1'b0,
      VckEn:              1'b0,
      VecEn:              1'b0,
      VceEn:              1'b0,
      FscEn:              1'b0,
      FceEn:              1'b0,
      VscEn:              1'b0,
      VseEn:              1'b0,
      SfcEn:              1'b0,
      SfeEn:              1'b0,
      NxcEn:              1'b0,
      NxkEn:              1'b0,
      OlsEn:              1'b0,
      OlkEn:              1'b0,
      GpwEn:              1'b0,
      GprEn:              1'b0,
      GpkEn:              1'b0,
      GcwEn:              1'b0,
      GcrEn:              1'b0,
      GckEn:              1'b0,
      ViwEn:              1'b0,
      VirEn:              1'b0,
      VikEn:              1'b0,
      VawEn:              1'b0,
      VarEn:              1'b0,
      VakEn:              1'b0,
      WfrEn:              1'b0,
      WfkEn:              1'b0,
      WfxEn:              1'b0,
      GbwEn:              1'b0,
      GbrEn:              1'b0,
      GbkEn:              1'b0,
      GbdEn:              1'b0,
      GblEn:              1'b0,
      GbxEn:              1'b0,
      GofEn:              1'b0,
      GboEn:              1'b0,
      GbzEn:              1'b0,
      ByrEn:              1'b0,
      BykEn:              1'b0,
      ByxEn:              1'b0,
      RyrEn:              1'b0,
      RykEn:              1'b0,
      RyxEn:              1'b0,
      TprEn:              1'b0,
      TpkEn:              1'b0,
      TpxEn:              1'b0,
      X6rEn:              1'b0,
      X6kEn:              1'b0,
      X6xEn:              1'b0,
      TcrEn:              1'b0,
      TckEn:              1'b0,
      TcxEn:              1'b0,
      P7rEn:              1'b0,
      P7kEn:              1'b0,
      P7xEn:              1'b0,
      B1rEn:              1'b0,
      B1kEn:              1'b0,
      B1xEn:              1'b0,
      B7rEn:              1'b0,
      B7kEn:              1'b0,
      B7xEn:              1'b0,
      B2rEn:              1'b0,
      B2kEn:              1'b0,
      B2xEn:              1'b0,
      B3rEn:              1'b0,
      B3kEn:              1'b0,
      B3xEn:              1'b0,
      B4rEn:              1'b0,
      B4kEn:              1'b0,
      B4xEn:              1'b0,
      B5rEn:              1'b0,
      B5kEn:              1'b0,
      B5xEn:              1'b0,
      B6rEn:              1'b0,
      B6kEn:              1'b0,
      B6xEn:              1'b0,
      AcwEn:              1'b0,
      AcrEn:              1'b0,
      AcxEn:              1'b0,
      CswEn:              1'b0,
      CsrEn:              1'b0,
      CsxEn:              1'b0,
      CrdEn:              1'b0,
      CrlEn:              1'b0,
      CrxEn:              1'b0,
      CofEn:              1'b0,
      CorEn:              1'b0,
      CoxEn:              1'b0,
      RpwEn:              1'b0,
      RprEn:              1'b0,
      RpxEn:              1'b0,
      GrdEn:              1'b0,
      GrlEn:              1'b0,
      GrxEn:              1'b0,
      RofEn:              1'b0,
      RorEn:              1'b0,
      RoxEn:              1'b0,
      TfbEn:              1'b0,
      TfrEn:              1'b0,
      TfxEn:              1'b0,
      RabEn:              1'b0,
      RarEn:              1'b0,
      RaxEn:              1'b0,
      RfwEn:              1'b0,
      RfrEn:              1'b0,
      RfxEn:              1'b0,
      TuwEn:              1'b0,
      TurEn:              1'b0,
      TuxEn:              1'b0,
      TiwEn:              1'b0,
      TirEn:              1'b0,
      TixEn:              1'b0,
      TawEn:              1'b0,
      TarEn:              1'b0,
      TaxEn:              1'b0,
      TxcEn:              1'b0,
      TxkEn:              1'b0,
      TxxEn:              1'b0,
      FtxEn:              1'b0,
      FtrEn:              1'b0,
      FtkEn:              1'b0,
      OcwEn:              1'b0,
      OcrEn:              1'b0,
      OcxEn:              1'b0,
      PbwEn:              1'b0,
      PbrEn:              1'b0,
      PbxEn:              1'b0,
      TnwEn:              1'b0,
      TnkEn:              1'b0,
      TnxEn:              1'b0,
      QntEn:              1'b0,
      QnrEn:              1'b0,
      QnxEn:              1'b0,
      QavEn:              1'b0,
      QakEn:              1'b0,
      QaxEn:              1'b0,
      QrgEn:              1'b0,
      QrkEn:              1'b0,
      QrxEn:              1'b0,
      QhdEn:              1'b0,
      QhkEn:              1'b0,
      QhxEn:              1'b0,
      QfdEn:              1'b0,
      QfkEn:              1'b0,
      QfxEn:              1'b0,
      QwdEn:              1'b0,
      QwkEn:              1'b0,
      QwxEn:              1'b0,
      QokEn:              1'b0,
      QolEn:              1'b0,
      QoxEn:              1'b0,
      QuwEn:              1'b0,
      QulEn:              1'b0,
      QuxEn:              1'b0,
      QiwEn:              1'b0,
      QirEn:              1'b0,
      QixEn:              1'b0,
      QawEn:              1'b0,
      QarEn:              1'b0,
      QayEn:              1'b0,
      QsvEn:              1'b0,
      QskEn:              1'b0,
      QsxEn:              1'b0,
      QsrEn:              1'b0,
      QslEn:              1'b0,
      QsyEn:              1'b0,
      QsdEn:              1'b0,
      QseEn:              1'b0,
      QsfEn:              1'b0,
      QedEn:              1'b0,
      QekEn:              1'b0,
      QexEn:              1'b0,
      QrsEn:              1'b0,
      QrtEn:              1'b0,
      QruEn:              1'b0,
      QsoEn:              1'b0,
      QspEn:              1'b0,
      QsqEn:              1'b0,
      QsuEn:              1'b0,
      QstEn:              1'b0,
      QszEn:              1'b0,
      QsiEn:              1'b0,
      QsnEn:              1'b0,
      QsmEn:              1'b0,
      QgaEn:              1'b0,
      QgkEn:              1'b0,
      QgxEn:              1'b0,
      SnwEn:              1'b0,
      SnkEn:              1'b0,
      SnxEn:              1'b0,
      SntEn:              1'b0,
      SnrEn:              1'b0,
      SnyEn:              1'b0,
      SavEn:              1'b0,
      SakEn:              1'b0,
      SaxEn:              1'b0,
      SrgEn:              1'b0,
      SrkEn:              1'b0,
      SrxEn:              1'b0,
      ShdEn:              1'b0,
      ShkEn:              1'b0,
      ShxEn:              1'b0,
      SfdEn:              1'b0,
      SfkEn:              1'b0,
      SfxEn:              1'b0,
      SwdEn:              1'b0,
      SwkEn:              1'b0,
      SwxEn:              1'b0,
      SokEn:              1'b0,
      SolEn:              1'b0,
      SoxEn:              1'b0,
      SlwEn:              1'b0,
      SllEn:              1'b0,
      SlxEn:              1'b0,
      SiwEn:              1'b0,
      SirEn:              1'b0,
      SixEn:              1'b0,
      SgaEn:              1'b0,
      SgkEn:              1'b0,
      SgxEn:              1'b0,
      RnwEn:              1'b0,
      RnkEn:              1'b0,
      RnxEn:              1'b0,
      RntEn:              1'b0,
      RnrEn:              1'b0,
      RnyEn:              1'b0,
      RavEn:              1'b0,
      RakEn:              1'b0,
      RayEn:              1'b0,
      RrgEn:              1'b0,
      RrkEn:              1'b0,
      RrxEn:              1'b0,
      RhdEn:              1'b0,
      RhkEn:              1'b0,
      RhxEn:              1'b0,
      RfdEn:              1'b0,
      RfkEn:              1'b0,
      RfyEn:              1'b0,
      RwdEn:              1'b0,
      RwkEn:              1'b0,
      RwxEn:              1'b0,
      RokEn:              1'b0,
      RolEn:              1'b0,
      RoyEn:              1'b0,
      RuwEn:              1'b0,
      RulEn:              1'b0,
      RuxEn:              1'b0,
      RiwEn:              1'b0,
      RirEn:              1'b0,
      RixEn:              1'b0,
      RgaEn:              1'b0,
      RgkEn:              1'b0,
      RgxEn:              1'b0,
      GtxEn:              1'b0,
      GtrEn:              1'b0,
      GtkEn:              1'b0,
      HcwEn:              1'b0,
      HcrEn:              1'b0,
      HcxEn:              1'b0,
      WldEn:              1'b0,
      WlrEn:              1'b0,
      WlkEn:              1'b0,
      CyrEn:              1'b0,
      CykEn:              1'b0,
      CyxEn:              1'b0,
      GnwEn:              1'b0,
      GnkEn:              1'b0,
      GnxEn:              1'b0,
      GefEn:              1'b0,
      GekEn:              1'b0,
      GexEn:              1'b0,
      SpirvEn:            1'b0,
      ChainEn:            1'b0,
      CdmaEn:             1'b0,
      ShmEn:              1'b0,
      HvisEn:             1'b0,
      VncsEn:             1'b0,
      VcapEn:             1'b0,
      VnringEn:           1'b0,
      TdmaEn:             1'b0,
      VnencEn:            1'b0,
      VnpEn:              1'b0,
      AvnEn:              1'b0,
      AvuEn:              1'b0,
      UirEn:              1'b0,
      CmsEn:              1'b0,
      PrsEn:              1'b0,
      QdnEn:              1'b0,
      GcsEn:              1'b0,
      VndEn:              1'b0,
      GnhEn:              1'b0,
      HdpEn:              1'b0,
      HphEn:              1'b0,
      HrnEn:              1'b0,
      RdnEn:              1'b0,
      QrnEn:              1'b0,
      QcmEn:              1'b0,
      QtyEn:              1'b0,
      VctEn:              1'b0,
      QpuEn:              1'b0,
      NtkEn:              1'b0,
      VqtEn:              1'b0,
      VaxEn:              1'b0,
      VacEn:              1'b0,
      HalEn:              1'b0,
      AruEn:              1'b0,
      QalEn:              1'b0,
      QtaEn:              1'b0,
      VcaEn:              1'b0,
      QpaEn:              1'b0,
      NtaEn:              1'b0,
      VqaEn:              1'b0,
      VaaEn:              1'b0,
      VbgEn:              1'b0,
      BalEn:              1'b0,
      BruEn:              1'b0,
      QbnEn:              1'b0,
      QtbEn:              1'b0,
      VcbEn:              1'b0,
      QpbEn:              1'b0,
      NtbEn:              1'b0,
      VqbEn:              1'b0,
      VabEn:              1'b0,
      VenEn:              1'b0,
      EalEn:              1'b0,
      VqsEn:              1'b0,
      VwiEn:              1'b0,
      VgqEn:              1'b0,
      VcdEn:              1'b0,
      VciEn:              1'b0,
      VepEn:              1'b0,
      VqfEn:              1'b0,
      VpfEn:              1'b0,
      VppEn:              1'b0,
      VmpEn:              1'b0,
      VamEn:              1'b0,
      VxbEn:              1'b0,
      VbbEn:              1'b0,
      VmmEn:              1'b0,
      VumEn:              1'b0,
      VbmEn:              1'b0,
      VfmEn:              1'b0,
      VimEn:              1'b0,
      VmcEn:              1'b0,
      VdlEn:              1'b0,
      VplEn:              1'b0,
      VcpEn:              1'b0,
      VdaEn:              1'b0,
      VudEn:              1'b0,
      VbpEn:              1'b0,
      VbdEn:              1'b0,
      VpoEn:              1'b0,
      VxiEn:              1'b0,
      VbiEn:              1'b0,
      VmiEn:              1'b0,
      VxvEn:              1'b0,
      VsmEn:              1'b0,
      VrpEn:              1'b0,
      VgpEn:              1'b0,
      VfbEn:              1'b0,
      VrbEn:              1'b0,
      VdwEn:              1'b0,
      VreEn:              1'b0,
      VvbEn:              1'b0,
      VibEn:              1'b0,
      VdiEn:              1'b0,
      VvpEn:              1'b0,
      VsiEn:              1'b0,
      VpbEn:              1'b0,
      VnsEn:              1'b0,
      VdfEn:              1'b0,
      VdxEn:              1'b0,
      VdkEn:              1'b0,
      VdrEn:              1'b0,
      VdbEn:              1'b0,
      VdgEn:              1'b0,
      VfeEn:              1'b0,
      VdmEn:              1'b0,
      VdpEn:              1'b0,
      VdyEn:              1'b0,
      VdtEn:              1'b0,
      VdqEn:              1'b0,
      VfsEn:              1'b0,
      VrcEn:              1'b0,
      VfcEn:              1'b0,
      VddEn:              1'b0,
      VpcEn:              1'b0,
      VdcEn:              1'b0,
      VdnEn:              1'b0,
      VgfEn:              1'b0,
      VipEn:              1'b0,
      VxeEn:              1'b0,
      VrdEn:              1'b0,
      VieEn:              1'b0,
      VwlEn:              1'b0,
      VslEn:              1'b0,
      VrgEn:              1'b0,
      VlwEn:              1'b0,
      VzbEn:              1'b0,
      VbcEn:              1'b0,
      VboEn:              1'b0,
      VcmEn:              1'b0,
      VwmEn:              1'b0,
      VrfEn:              1'b0,
      VccEn:              1'b0,
      VcyEn:              1'b0,
      VblEn:              1'b0,
      VbtEn:              1'b0,
      VicEn:              1'b0,
      VubEn:              1'b0,
      VflEn:              1'b0,
      VclEn:              1'b0,
      VioEn:              1'b0,
      VixEn:              1'b0,
      VdsEn:              1'b0,
      VatEn:              1'b0,
      VinEn:              1'b0,
      VrsEn:              1'b0,
      VgsEn:              1'b0,
      VwfEn:              1'b0,
      VfrEn:              1'b0,
      VfnEn:              1'b0
  };

  // Proof profile for g6lc_apu_sched. Not the testharness boot config:
  // ApuHarness keeps ExecEn and the memory clients off.
  localparam apu_cfg_t ApuSchedBoth = '{
      Enable:             1'b1,
      FeatureVirgl:       1'b0,
      FeatureEdid:        1'b0,
      FeatureIndirectDesc:1'b0,
      FeatureEventIdx:    1'b0,
      FeatureInOrder:     1'b0,
      FeatureRingReset:   1'b1,
      NumQueues:          unsigned'(APU_NUM_QUEUES),
      QueueDepth:         unsigned'(64),
      MaxContexts:        unsigned'(0),
      MaxResources:       unsigned'(8),
      MaxCmdBytes:        unsigned'(0),
      MaxShaderBytes:     unsigned'(0),
      DmaMaxOutstanding:  unsigned'(2),
      DmaCoherent:        1'b0,
      DmaReadEn:          1'b0,
      DmaWriteEn:         1'b0,
      DmaWriteMaxBytes:   unsigned'(65536),
      DmaReadMaxBytes:    unsigned'(65536),
      DmaReadBurstBeats:  unsigned'(16),
      DmaWindowBase:      64'h8000_0000,
      DmaWindowBytes:     64'h0001_0000,
      SgEn:               1'b0,
      SgMaxEntries:       unsigned'(64),
      SgMaxTransferBytes: unsigned'(1048576),
      NumScanouts:        unsigned'(0),
      NumCapsets:         unsigned'(0),
      FirmwareHart:       unsigned'(1),
      FirmwareRamBase:    64'h9000_0000,
      FirmwareRamBytes:   64'h40000,
      MmioBase:           APU_MMIO_BASE,
      MmioLength:         APU_MMIO_LEN,
      ControlBase:        APU_CONTROL_BASE,
      ControlLength:      APU_CONTROL_LEN,
      IrqSource:          unsigned'(APU_IRQ_SOURCE),
      ExecEn:             1'b1,
      ExecQuadThreads:    unsigned'(APU_EXEC_THREADS),
      ExecRegs:           unsigned'(APU_EXEC_REGS),
      ExecMemWords:       unsigned'(APU_EXEC_DMEM_WORDS),
      CoverEn:            1'b0,
      FragEn:             1'b0,
      TexelEn:            1'b0,
      ProtoEn:            1'b0,
      UsedEn:             1'b0,
      AvailEn:            1'b0,
      BackEn:             1'b0,
      XferEn:             1'b0,
      UwrEn:              1'b0,
      UidxEn:             1'b0,
      SurfEn:             1'b0,
      RdbEn:              1'b0,
      SubEn:              1'b0,
      BufEn:              1'b0,
      DecEn:              1'b0,
      ShEn:               1'b0,
      FsEn:               1'b0,
      VeEn:               1'b0,
      SvEn:               1'b0,
      SsEn:               1'b0,
      BlEn:               1'b0,
      DsEn:               1'b0,
      RzEn:               1'b0,
      BbEn:               1'b0,
      DbEn:               1'b0,
      RbEn:               1'b0,
      VsbEn:              1'b0,
      FsbEn:              1'b0,
      VebEn:              1'b0,
      SsbEn:              1'b0,
      SvbEn:              1'b0,
      IwEn:               1'b0,
      VbEn:               1'b0,
      SciEn:              1'b0,
      VpEn:               1'b0,
      FboEn:              1'b0,
      ClrEn:              1'b0,
      DrwEn:              1'b0,
      CtxEn:              1'b0,
      C3dEn:              1'b0,
      AttEn:              1'b0,
      RspEn:              1'b0,
      NfoEn:              1'b0,
      CapEn:              1'b0,
      ScnEn:              1'b0,
      FluEn:              1'b0,
      ChnEn:              1'b0,
      CmxEn:              1'b0,
      SunEn:              1'b0,
      SuwEn:              1'b0,
      SuxEn:              1'b0,
      U8En:               1'b0,
      PixEn:              1'b0,
      PxrEn:              1'b0,
      FilEn:              1'b0,
      FrdEn:              1'b0,
      QdEn:               1'b0,
      CvEn:               1'b0,
      CvrEn:              1'b0,
      VstEn:              1'b0,
      FstEn:              1'b0,
      HldEn:              1'b0,
      TbnEn:              1'b0,
      DenEn:              1'b0,
      DnrEn:              1'b0,
      S2dEn:              1'b0,
      SbkEn:              1'b0,
      SxfEn:              1'b0,
      SscEn:              1'b0,
      SflEn:              1'b0,
      SprEn:              1'b0,
      BcpEn:              1'b0,
      BcrEn:              1'b0,
      TapEn:              1'b0,
      PxcEn:              1'b0,
      PxqEn:              1'b0,
      LinEn:              1'b0,
      LnrEn:              1'b0,
      SpnEn:              1'b0,
      SpxEn:              1'b0,
      VlnEn:              1'b0,
      VlrEn:              1'b0,
      VbxEn:              1'b0,
      VbrEn:              1'b0,
      VspEn:              1'b0,
      VsxEn:              1'b0,
      Y2bEn:              1'b0,
      Y2rEn:              1'b0,
      SmpEn:              1'b0,
      SmxEn:              1'b0,
      RbfEn:              1'b0,
      RbkEn:              1'b0,
      RdrEn:              1'b0,
      RdkEn:              1'b0,
      FetEn:              1'b0,
      FekEn:              1'b0,
      DrdEn:              1'b0,
      DrkEn:              1'b0,
      QdrEn:              1'b0,
      QdkEn:              1'b0,
      VwxEn:              1'b0,
      VwkEn:              1'b0,
      CxrEn:              1'b0,
      CxkEn:              1'b0,
      CwrEn:              1'b0,
      CwkEn:              1'b0,
      FbrEn:              1'b0,
      FbkEn:              1'b0,
      VbfEn:              1'b0,
      VbkEn:              1'b0,
      IwrEn:              1'b0,
      IwkEn:              1'b0,
      SvrEn:              1'b0,
      SvkEn:              1'b0,
      SsrEn:              1'b0,
      SskEn:              1'b0,
      VerEn:              1'b0,
      VekEn:              1'b0,
      FsrEn:              1'b0,
      FskEn:              1'b0,
      VsrEn:              1'b0,
      VskEn:              1'b0,
      RzrEn:              1'b0,
      RzkEn:              1'b0,
      DbrEn:              1'b0,
      DbkEn:              1'b0,
      BbrEn:              1'b0,
      BbkEn:              1'b0,
      RcrEn:              1'b0,
      RckEn:              1'b0,
      DcrEn:              1'b0,
      DckEn:              1'b0,
      BlrEn:              1'b0,
      BlkEn:              1'b0,
      ScrEn:              1'b0,
      SckEn:              1'b0,
      SvcEn:              1'b0,
      VckEn:              1'b0,
      VecEn:              1'b0,
      VceEn:              1'b0,
      FscEn:              1'b0,
      FceEn:              1'b0,
      VscEn:              1'b0,
      VseEn:              1'b0,
      SfcEn:              1'b0,
      SfeEn:              1'b0,
      NxcEn:              1'b0,
      NxkEn:              1'b0,
      OlsEn:              1'b0,
      OlkEn:              1'b0,
      GpwEn:              1'b0,
      GprEn:              1'b0,
      GpkEn:              1'b0,
      GcwEn:              1'b0,
      GcrEn:              1'b0,
      GckEn:              1'b0,
      ViwEn:              1'b0,
      VirEn:              1'b0,
      VikEn:              1'b0,
      VawEn:              1'b0,
      VarEn:              1'b0,
      VakEn:              1'b0,
      WfrEn:              1'b0,
      WfkEn:              1'b0,
      WfxEn:              1'b0,
      GbwEn:              1'b0,
      GbrEn:              1'b0,
      GbkEn:              1'b0,
      GbdEn:              1'b0,
      GblEn:              1'b0,
      GbxEn:              1'b0,
      GofEn:              1'b0,
      GboEn:              1'b0,
      GbzEn:              1'b0,
      ByrEn:              1'b0,
      BykEn:              1'b0,
      ByxEn:              1'b0,
      RyrEn:              1'b0,
      RykEn:              1'b0,
      RyxEn:              1'b0,
      TprEn:              1'b0,
      TpkEn:              1'b0,
      TpxEn:              1'b0,
      X6rEn:              1'b0,
      X6kEn:              1'b0,
      X6xEn:              1'b0,
      TcrEn:              1'b0,
      TckEn:              1'b0,
      TcxEn:              1'b0,
      P7rEn:              1'b0,
      P7kEn:              1'b0,
      P7xEn:              1'b0,
      B1rEn:              1'b0,
      B1kEn:              1'b0,
      B1xEn:              1'b0,
      B7rEn:              1'b0,
      B7kEn:              1'b0,
      B7xEn:              1'b0,
      B2rEn:              1'b0,
      B2kEn:              1'b0,
      B2xEn:              1'b0,
      B3rEn:              1'b0,
      B3kEn:              1'b0,
      B3xEn:              1'b0,
      B4rEn:              1'b0,
      B4kEn:              1'b0,
      B4xEn:              1'b0,
      B5rEn:              1'b0,
      B5kEn:              1'b0,
      B5xEn:              1'b0,
      B6rEn:              1'b0,
      B6kEn:              1'b0,
      B6xEn:              1'b0,
      AcwEn:              1'b0,
      AcrEn:              1'b0,
      AcxEn:              1'b0,
      CswEn:              1'b0,
      CsrEn:              1'b0,
      CsxEn:              1'b0,
      CrdEn:              1'b0,
      CrlEn:              1'b0,
      CrxEn:              1'b0,
      CofEn:              1'b0,
      CorEn:              1'b0,
      CoxEn:              1'b0,
      RpwEn:              1'b0,
      RprEn:              1'b0,
      RpxEn:              1'b0,
      GrdEn:              1'b0,
      GrlEn:              1'b0,
      GrxEn:              1'b0,
      RofEn:              1'b0,
      RorEn:              1'b0,
      RoxEn:              1'b0,
      TfbEn:              1'b0,
      TfrEn:              1'b0,
      TfxEn:              1'b0,
      RabEn:              1'b0,
      RarEn:              1'b0,
      RaxEn:              1'b0,
      RfwEn:              1'b0,
      RfrEn:              1'b0,
      RfxEn:              1'b0,
      TuwEn:              1'b0,
      TurEn:              1'b0,
      TuxEn:              1'b0,
      TiwEn:              1'b0,
      TirEn:              1'b0,
      TixEn:              1'b0,
      TawEn:              1'b0,
      TarEn:              1'b0,
      TaxEn:              1'b0,
      TxcEn:              1'b0,
      TxkEn:              1'b0,
      TxxEn:              1'b0,
      FtxEn:              1'b0,
      FtrEn:              1'b0,
      FtkEn:              1'b0,
      OcwEn:              1'b0,
      OcrEn:              1'b0,
      OcxEn:              1'b0,
      PbwEn:              1'b0,
      PbrEn:              1'b0,
      PbxEn:              1'b0,
      TnwEn:              1'b0,
      TnkEn:              1'b0,
      TnxEn:              1'b0,
      QntEn:              1'b0,
      QnrEn:              1'b0,
      QnxEn:              1'b0,
      QavEn:              1'b0,
      QakEn:              1'b0,
      QaxEn:              1'b0,
      QrgEn:              1'b0,
      QrkEn:              1'b0,
      QrxEn:              1'b0,
      QhdEn:              1'b0,
      QhkEn:              1'b0,
      QhxEn:              1'b0,
      QfdEn:              1'b0,
      QfkEn:              1'b0,
      QfxEn:              1'b0,
      QwdEn:              1'b0,
      QwkEn:              1'b0,
      QwxEn:              1'b0,
      QokEn:              1'b0,
      QolEn:              1'b0,
      QoxEn:              1'b0,
      QuwEn:              1'b0,
      QulEn:              1'b0,
      QuxEn:              1'b0,
      QiwEn:              1'b0,
      QirEn:              1'b0,
      QixEn:              1'b0,
      QawEn:              1'b0,
      QarEn:              1'b0,
      QayEn:              1'b0,
      QsvEn:              1'b0,
      QskEn:              1'b0,
      QsxEn:              1'b0,
      QsrEn:              1'b0,
      QslEn:              1'b0,
      QsyEn:              1'b0,
      QsdEn:              1'b0,
      QseEn:              1'b0,
      QsfEn:              1'b0,
      QedEn:              1'b0,
      QekEn:              1'b0,
      QexEn:              1'b0,
      QrsEn:              1'b0,
      QrtEn:              1'b0,
      QruEn:              1'b0,
      QsoEn:              1'b0,
      QspEn:              1'b0,
      QsqEn:              1'b0,
      QsuEn:              1'b0,
      QstEn:              1'b0,
      QszEn:              1'b0,
      QsiEn:              1'b0,
      QsnEn:              1'b0,
      QsmEn:              1'b0,
      QgaEn:              1'b0,
      QgkEn:              1'b0,
      QgxEn:              1'b0,
      SnwEn:              1'b0,
      SnkEn:              1'b0,
      SnxEn:              1'b0,
      SntEn:              1'b0,
      SnrEn:              1'b0,
      SnyEn:              1'b0,
      SavEn:              1'b0,
      SakEn:              1'b0,
      SaxEn:              1'b0,
      SrgEn:              1'b0,
      SrkEn:              1'b0,
      SrxEn:              1'b0,
      ShdEn:              1'b0,
      ShkEn:              1'b0,
      ShxEn:              1'b0,
      SfdEn:              1'b0,
      SfkEn:              1'b0,
      SfxEn:              1'b0,
      SwdEn:              1'b0,
      SwkEn:              1'b0,
      SwxEn:              1'b0,
      SokEn:              1'b0,
      SolEn:              1'b0,
      SoxEn:              1'b0,
      SlwEn:              1'b0,
      SllEn:              1'b0,
      SlxEn:              1'b0,
      SiwEn:              1'b0,
      SirEn:              1'b0,
      SixEn:              1'b0,
      SgaEn:              1'b0,
      SgkEn:              1'b0,
      SgxEn:              1'b0,
      RnwEn:              1'b0,
      RnkEn:              1'b0,
      RnxEn:              1'b0,
      RntEn:              1'b0,
      RnrEn:              1'b0,
      RnyEn:              1'b0,
      RavEn:              1'b0,
      RakEn:              1'b0,
      RayEn:              1'b0,
      RrgEn:              1'b0,
      RrkEn:              1'b0,
      RrxEn:              1'b0,
      RhdEn:              1'b0,
      RhkEn:              1'b0,
      RhxEn:              1'b0,
      RfdEn:              1'b0,
      RfkEn:              1'b0,
      RfyEn:              1'b0,
      RwdEn:              1'b0,
      RwkEn:              1'b0,
      RwxEn:              1'b0,
      RokEn:              1'b0,
      RolEn:              1'b0,
      RoyEn:              1'b0,
      RuwEn:              1'b0,
      RulEn:              1'b0,
      RuxEn:              1'b0,
      RiwEn:              1'b0,
      RirEn:              1'b0,
      RixEn:              1'b0,
      RgaEn:              1'b0,
      RgkEn:              1'b0,
      RgxEn:              1'b0,
      GtxEn:              1'b0,
      GtrEn:              1'b0,
      GtkEn:              1'b0,
      HcwEn:              1'b0,
      HcrEn:              1'b0,
      HcxEn:              1'b0,
      WldEn:              1'b0,
      WlrEn:              1'b0,
      WlkEn:              1'b0,
      CyrEn:              1'b0,
      CykEn:              1'b0,
      CyxEn:              1'b0,
      GnwEn:              1'b0,
      GnkEn:              1'b0,
      GnxEn:              1'b0,
      GefEn:              1'b0,
      GekEn:              1'b0,
      GexEn:              1'b0,
      SpirvEn:            1'b0,
      ChainEn:            1'b0,
      CdmaEn:             1'b0,
      ShmEn:              1'b0,
      HvisEn:             1'b0,
      VncsEn:             1'b0,
      VcapEn:             1'b0,
      VnringEn:           1'b0,
      TdmaEn:             1'b0,
      VnencEn:            1'b0,
      VnpEn:              1'b0,
      AvnEn:              1'b0,
      AvuEn:              1'b0,
      UirEn:              1'b0,
      CmsEn:              1'b0,
      PrsEn:              1'b0,
      QdnEn:              1'b0,
      GcsEn:              1'b0,
      VndEn:              1'b0,
      GnhEn:              1'b0,
      HdpEn:              1'b0,
      HphEn:              1'b0,
      HrnEn:              1'b0,
      RdnEn:              1'b0,
      QrnEn:              1'b0,
      QcmEn:              1'b0,
      QtyEn:              1'b0,
      VctEn:              1'b0,
      QpuEn:              1'b0,
      NtkEn:              1'b0,
      VqtEn:              1'b0,
      VaxEn:              1'b0,
      VacEn:              1'b0,
      HalEn:              1'b0,
      AruEn:              1'b0,
      QalEn:              1'b0,
      QtaEn:              1'b0,
      VcaEn:              1'b0,
      QpaEn:              1'b0,
      NtaEn:              1'b0,
      VqaEn:              1'b0,
      VaaEn:              1'b0,
      VbgEn:              1'b0,
      BalEn:              1'b0,
      BruEn:              1'b0,
      QbnEn:              1'b0,
      QtbEn:              1'b0,
      VcbEn:              1'b0,
      QpbEn:              1'b0,
      NtbEn:              1'b0,
      VqbEn:              1'b0,
      VabEn:              1'b0,
      VenEn:              1'b0,
      EalEn:              1'b0,
      VqsEn:              1'b0,
      VwiEn:              1'b0,
      VgqEn:              1'b0,
      VcdEn:              1'b0,
      VciEn:              1'b0,
      VepEn:              1'b0,
      VqfEn:              1'b0,
      VpfEn:              1'b0,
      VppEn:              1'b0,
      VmpEn:              1'b0,
      VamEn:              1'b0,
      VxbEn:              1'b0,
      VbbEn:              1'b0,
      VmmEn:              1'b0,
      VumEn:              1'b0,
      VbmEn:              1'b0,
      VfmEn:              1'b0,
      VimEn:              1'b0,
      VmcEn:              1'b0,
      VdlEn:              1'b0,
      VplEn:              1'b0,
      VcpEn:              1'b0,
      VdaEn:              1'b0,
      VudEn:              1'b0,
      VbpEn:              1'b0,
      VbdEn:              1'b0,
      VpoEn:              1'b0,
      VxiEn:              1'b0,
      VbiEn:              1'b0,
      VmiEn:              1'b0,
      VxvEn:              1'b0,
      VsmEn:              1'b0,
      VrpEn:              1'b0,
      VgpEn:              1'b0,
      VfbEn:              1'b0,
      VrbEn:              1'b0,
      VdwEn:              1'b0,
      VreEn:              1'b0,
      VvbEn:              1'b0,
      VibEn:              1'b0,
      VdiEn:              1'b0,
      VvpEn:              1'b0,
      VsiEn:              1'b0,
      VpbEn:              1'b0,
      VnsEn:              1'b0,
      VdfEn:              1'b0,
      VdxEn:              1'b0,
      VdkEn:              1'b0,
      VdrEn:              1'b0,
      VdbEn:              1'b0,
      VdgEn:              1'b0,
      VfeEn:              1'b0,
      VdmEn:              1'b0,
      VdpEn:              1'b0,
      VdyEn:              1'b0,
      VdtEn:              1'b0,
      VdqEn:              1'b0,
      VfsEn:              1'b0,
      VrcEn:              1'b0,
      VfcEn:              1'b0,
      VddEn:              1'b0,
      VpcEn:              1'b0,
      VdcEn:              1'b0,
      VdnEn:              1'b0,
      VgfEn:              1'b0,
      VipEn:              1'b0,
      VxeEn:              1'b0,
      VrdEn:              1'b0,
      VieEn:              1'b0,
      VwlEn:              1'b0,
      VslEn:              1'b0,
      VrgEn:              1'b0,
      VlwEn:              1'b0,
      VzbEn:              1'b0,
      VbcEn:              1'b0,
      VboEn:              1'b0,
      VcmEn:              1'b0,
      VwmEn:              1'b0,
      VrfEn:              1'b0,
      VccEn:              1'b0,
      VcyEn:              1'b0,
      VblEn:              1'b0,
      VbtEn:              1'b0,
      VicEn:              1'b0,
      VubEn:              1'b0,
      VflEn:              1'b0,
      VclEn:              1'b0,
      VioEn:              1'b0,
      VixEn:              1'b0,
      VdsEn:              1'b0,
      VatEn:              1'b0,
      VinEn:              1'b0,
      VrsEn:              1'b0,
      VgsEn:              1'b0,
      VwfEn:              1'b0,
      VfrEn:              1'b0,
      VfnEn:              1'b0
  };

  // Negative control for the grant legality check: virgl cannot be advertised
  // without resident-firmware resources and the command/resource tables.
  localparam apu_cfg_t ApuBadVirglGrant = '{
      Enable:             1'b1,
      FeatureVirgl:       1'b1,
      FeatureEdid:        1'b0,
      FeatureIndirectDesc:1'b0,
      FeatureEventIdx:    1'b0,
      FeatureInOrder:     1'b0,
      FeatureRingReset:   1'b1,
      NumQueues:          unsigned'(APU_NUM_QUEUES),
      QueueDepth:         unsigned'(64),
      MaxContexts:        unsigned'(0),
      MaxResources:       unsigned'(0),
      MaxCmdBytes:        unsigned'(0),
      MaxShaderBytes:     unsigned'(0),
      DmaMaxOutstanding:  unsigned'(2),
      DmaCoherent:        1'b0,
      DmaReadEn:          1'b0,
      DmaWriteEn:         1'b0,
      DmaWriteMaxBytes:   unsigned'(65536),
      DmaReadMaxBytes:    unsigned'(65536),
      DmaReadBurstBeats:  unsigned'(16),
      DmaWindowBase:      64'h0,
      DmaWindowBytes:     64'h0,
      SgEn:               1'b0,
      SgMaxEntries:       unsigned'(64),
      SgMaxTransferBytes: unsigned'(1048576),
      NumScanouts:        unsigned'(0),
      NumCapsets:         unsigned'(2),
      FirmwareHart:       unsigned'(APU_FW_HART_UNASSIGNED),
      FirmwareRamBase:    64'h0,
      FirmwareRamBytes:   64'h0,
      MmioBase:           APU_MMIO_BASE,
      MmioLength:         APU_MMIO_LEN,
      ControlBase:        APU_CONTROL_BASE,
      ControlLength:      APU_CONTROL_LEN,
      IrqSource:          unsigned'(APU_IRQ_SOURCE),
      ExecEn:             1'b0,
      ExecQuadThreads:    unsigned'(APU_EXEC_THREADS),
      ExecRegs:           unsigned'(APU_EXEC_REGS),
      ExecMemWords:       unsigned'(APU_EXEC_DMEM_WORDS),
      CoverEn:            1'b0,
      FragEn:             1'b0,
      TexelEn:            1'b0,
      ProtoEn:            1'b0,
      UsedEn:             1'b0,
      AvailEn:            1'b0,
      BackEn:             1'b0,
      XferEn:             1'b0,
      UwrEn:              1'b0,
      UidxEn:             1'b0,
      SurfEn:             1'b0,
      RdbEn:              1'b0,
      SubEn:              1'b0,
      BufEn:              1'b0,
      DecEn:              1'b0,
      ShEn:               1'b0,
      FsEn:               1'b0,
      VeEn:               1'b0,
      SvEn:               1'b0,
      SsEn:               1'b0,
      BlEn:               1'b0,
      DsEn:               1'b0,
      RzEn:               1'b0,
      BbEn:               1'b0,
      DbEn:               1'b0,
      RbEn:               1'b0,
      VsbEn:              1'b0,
      FsbEn:              1'b0,
      VebEn:              1'b0,
      SsbEn:              1'b0,
      SvbEn:              1'b0,
      IwEn:               1'b0,
      VbEn:               1'b0,
      SciEn:              1'b0,
      VpEn:               1'b0,
      FboEn:              1'b0,
      ClrEn:              1'b0,
      DrwEn:              1'b0,
      CtxEn:              1'b0,
      C3dEn:              1'b0,
      AttEn:              1'b0,
      RspEn:              1'b0,
      NfoEn:              1'b0,
      CapEn:              1'b0,
      ScnEn:              1'b0,
      FluEn:              1'b0,
      ChnEn:              1'b0,
      CmxEn:              1'b0,
      SunEn:              1'b0,
      SuwEn:              1'b0,
      SuxEn:              1'b0,
      U8En:               1'b0,
      PixEn:              1'b0,
      PxrEn:              1'b0,
      FilEn:              1'b0,
      FrdEn:              1'b0,
      QdEn:               1'b0,
      CvEn:               1'b0,
      CvrEn:              1'b0,
      VstEn:              1'b0,
      FstEn:              1'b0,
      HldEn:              1'b0,
      TbnEn:              1'b0,
      DenEn:              1'b0,
      DnrEn:              1'b0,
      S2dEn:              1'b0,
      SbkEn:              1'b0,
      SxfEn:              1'b0,
      SscEn:              1'b0,
      SflEn:              1'b0,
      SprEn:              1'b0,
      BcpEn:              1'b0,
      BcrEn:              1'b0,
      TapEn:              1'b0,
      PxcEn:              1'b0,
      PxqEn:              1'b0,
      LinEn:              1'b0,
      LnrEn:              1'b0,
      SpnEn:              1'b0,
      SpxEn:              1'b0,
      VlnEn:              1'b0,
      VlrEn:              1'b0,
      VbxEn:              1'b0,
      VbrEn:              1'b0,
      VspEn:              1'b0,
      VsxEn:              1'b0,
      Y2bEn:              1'b0,
      Y2rEn:              1'b0,
      SmpEn:              1'b0,
      SmxEn:              1'b0,
      RbfEn:              1'b0,
      RbkEn:              1'b0,
      RdrEn:              1'b0,
      RdkEn:              1'b0,
      FetEn:              1'b0,
      FekEn:              1'b0,
      DrdEn:              1'b0,
      DrkEn:              1'b0,
      QdrEn:              1'b0,
      QdkEn:              1'b0,
      VwxEn:              1'b0,
      VwkEn:              1'b0,
      CxrEn:              1'b0,
      CxkEn:              1'b0,
      CwrEn:              1'b0,
      CwkEn:              1'b0,
      FbrEn:              1'b0,
      FbkEn:              1'b0,
      VbfEn:              1'b0,
      VbkEn:              1'b0,
      IwrEn:              1'b0,
      IwkEn:              1'b0,
      SvrEn:              1'b0,
      SvkEn:              1'b0,
      SsrEn:              1'b0,
      SskEn:              1'b0,
      VerEn:              1'b0,
      VekEn:              1'b0,
      FsrEn:              1'b0,
      FskEn:              1'b0,
      VsrEn:              1'b0,
      VskEn:              1'b0,
      RzrEn:              1'b0,
      RzkEn:              1'b0,
      DbrEn:              1'b0,
      DbkEn:              1'b0,
      BbrEn:              1'b0,
      BbkEn:              1'b0,
      RcrEn:              1'b0,
      RckEn:              1'b0,
      DcrEn:              1'b0,
      DckEn:              1'b0,
      BlrEn:              1'b0,
      BlkEn:              1'b0,
      ScrEn:              1'b0,
      SckEn:              1'b0,
      SvcEn:              1'b0,
      VckEn:              1'b0,
      VecEn:              1'b0,
      VceEn:              1'b0,
      FscEn:              1'b0,
      FceEn:              1'b0,
      VscEn:              1'b0,
      VseEn:              1'b0,
      SfcEn:              1'b0,
      SfeEn:              1'b0,
      NxcEn:              1'b0,
      NxkEn:              1'b0,
      OlsEn:              1'b0,
      OlkEn:              1'b0,
      GpwEn:              1'b0,
      GprEn:              1'b0,
      GpkEn:              1'b0,
      GcwEn:              1'b0,
      GcrEn:              1'b0,
      GckEn:              1'b0,
      ViwEn:              1'b0,
      VirEn:              1'b0,
      VikEn:              1'b0,
      VawEn:              1'b0,
      VarEn:              1'b0,
      VakEn:              1'b0,
      WfrEn:              1'b0,
      WfkEn:              1'b0,
      WfxEn:              1'b0,
      GbwEn:              1'b0,
      GbrEn:              1'b0,
      GbkEn:              1'b0,
      GbdEn:              1'b0,
      GblEn:              1'b0,
      GbxEn:              1'b0,
      GofEn:              1'b0,
      GboEn:              1'b0,
      GbzEn:              1'b0,
      ByrEn:              1'b0,
      BykEn:              1'b0,
      ByxEn:              1'b0,
      RyrEn:              1'b0,
      RykEn:              1'b0,
      RyxEn:              1'b0,
      TprEn:              1'b0,
      TpkEn:              1'b0,
      TpxEn:              1'b0,
      X6rEn:              1'b0,
      X6kEn:              1'b0,
      X6xEn:              1'b0,
      TcrEn:              1'b0,
      TckEn:              1'b0,
      TcxEn:              1'b0,
      P7rEn:              1'b0,
      P7kEn:              1'b0,
      P7xEn:              1'b0,
      B1rEn:              1'b0,
      B1kEn:              1'b0,
      B1xEn:              1'b0,
      B7rEn:              1'b0,
      B7kEn:              1'b0,
      B7xEn:              1'b0,
      B2rEn:              1'b0,
      B2kEn:              1'b0,
      B2xEn:              1'b0,
      B3rEn:              1'b0,
      B3kEn:              1'b0,
      B3xEn:              1'b0,
      B4rEn:              1'b0,
      B4kEn:              1'b0,
      B4xEn:              1'b0,
      B5rEn:              1'b0,
      B5kEn:              1'b0,
      B5xEn:              1'b0,
      B6rEn:              1'b0,
      B6kEn:              1'b0,
      B6xEn:              1'b0,
      AcwEn:              1'b0,
      AcrEn:              1'b0,
      AcxEn:              1'b0,
      CswEn:              1'b0,
      CsrEn:              1'b0,
      CsxEn:              1'b0,
      CrdEn:              1'b0,
      CrlEn:              1'b0,
      CrxEn:              1'b0,
      CofEn:              1'b0,
      CorEn:              1'b0,
      CoxEn:              1'b0,
      RpwEn:              1'b0,
      RprEn:              1'b0,
      RpxEn:              1'b0,
      GrdEn:              1'b0,
      GrlEn:              1'b0,
      GrxEn:              1'b0,
      RofEn:              1'b0,
      RorEn:              1'b0,
      RoxEn:              1'b0,
      TfbEn:              1'b0,
      TfrEn:              1'b0,
      TfxEn:              1'b0,
      RabEn:              1'b0,
      RarEn:              1'b0,
      RaxEn:              1'b0,
      RfwEn:              1'b0,
      RfrEn:              1'b0,
      RfxEn:              1'b0,
      TuwEn:              1'b0,
      TurEn:              1'b0,
      TuxEn:              1'b0,
      TiwEn:              1'b0,
      TirEn:              1'b0,
      TixEn:              1'b0,
      TawEn:              1'b0,
      TarEn:              1'b0,
      TaxEn:              1'b0,
      TxcEn:              1'b0,
      TxkEn:              1'b0,
      TxxEn:              1'b0,
      FtxEn:              1'b0,
      FtrEn:              1'b0,
      FtkEn:              1'b0,
      OcwEn:              1'b0,
      OcrEn:              1'b0,
      OcxEn:              1'b0,
      PbwEn:              1'b0,
      PbrEn:              1'b0,
      PbxEn:              1'b0,
      TnwEn:              1'b0,
      TnkEn:              1'b0,
      TnxEn:              1'b0,
      QntEn:              1'b0,
      QnrEn:              1'b0,
      QnxEn:              1'b0,
      QavEn:              1'b0,
      QakEn:              1'b0,
      QaxEn:              1'b0,
      QrgEn:              1'b0,
      QrkEn:              1'b0,
      QrxEn:              1'b0,
      QhdEn:              1'b0,
      QhkEn:              1'b0,
      QhxEn:              1'b0,
      QfdEn:              1'b0,
      QfkEn:              1'b0,
      QfxEn:              1'b0,
      QwdEn:              1'b0,
      QwkEn:              1'b0,
      QwxEn:              1'b0,
      QokEn:              1'b0,
      QolEn:              1'b0,
      QoxEn:              1'b0,
      QuwEn:              1'b0,
      QulEn:              1'b0,
      QuxEn:              1'b0,
      QiwEn:              1'b0,
      QirEn:              1'b0,
      QixEn:              1'b0,
      QawEn:              1'b0,
      QarEn:              1'b0,
      QayEn:              1'b0,
      QsvEn:              1'b0,
      QskEn:              1'b0,
      QsxEn:              1'b0,
      QsrEn:              1'b0,
      QslEn:              1'b0,
      QsyEn:              1'b0,
      QsdEn:              1'b0,
      QseEn:              1'b0,
      QsfEn:              1'b0,
      QedEn:              1'b0,
      QekEn:              1'b0,
      QexEn:              1'b0,
      QrsEn:              1'b0,
      QrtEn:              1'b0,
      QruEn:              1'b0,
      QsoEn:              1'b0,
      QspEn:              1'b0,
      QsqEn:              1'b0,
      QsuEn:              1'b0,
      QstEn:              1'b0,
      QszEn:              1'b0,
      QsiEn:              1'b0,
      QsnEn:              1'b0,
      QsmEn:              1'b0,
      QgaEn:              1'b0,
      QgkEn:              1'b0,
      QgxEn:              1'b0,
      SnwEn:              1'b0,
      SnkEn:              1'b0,
      SnxEn:              1'b0,
      SntEn:              1'b0,
      SnrEn:              1'b0,
      SnyEn:              1'b0,
      SavEn:              1'b0,
      SakEn:              1'b0,
      SaxEn:              1'b0,
      SrgEn:              1'b0,
      SrkEn:              1'b0,
      SrxEn:              1'b0,
      ShdEn:              1'b0,
      ShkEn:              1'b0,
      ShxEn:              1'b0,
      SfdEn:              1'b0,
      SfkEn:              1'b0,
      SfxEn:              1'b0,
      SwdEn:              1'b0,
      SwkEn:              1'b0,
      SwxEn:              1'b0,
      SokEn:              1'b0,
      SolEn:              1'b0,
      SoxEn:              1'b0,
      SlwEn:              1'b0,
      SllEn:              1'b0,
      SlxEn:              1'b0,
      SiwEn:              1'b0,
      SirEn:              1'b0,
      SixEn:              1'b0,
      SgaEn:              1'b0,
      SgkEn:              1'b0,
      SgxEn:              1'b0,
      RnwEn:              1'b0,
      RnkEn:              1'b0,
      RnxEn:              1'b0,
      RntEn:              1'b0,
      RnrEn:              1'b0,
      RnyEn:              1'b0,
      RavEn:              1'b0,
      RakEn:              1'b0,
      RayEn:              1'b0,
      RrgEn:              1'b0,
      RrkEn:              1'b0,
      RrxEn:              1'b0,
      RhdEn:              1'b0,
      RhkEn:              1'b0,
      RhxEn:              1'b0,
      RfdEn:              1'b0,
      RfkEn:              1'b0,
      RfyEn:              1'b0,
      RwdEn:              1'b0,
      RwkEn:              1'b0,
      RwxEn:              1'b0,
      RokEn:              1'b0,
      RolEn:              1'b0,
      RoyEn:              1'b0,
      RuwEn:              1'b0,
      RulEn:              1'b0,
      RuxEn:              1'b0,
      RiwEn:              1'b0,
      RirEn:              1'b0,
      RixEn:              1'b0,
      RgaEn:              1'b0,
      RgkEn:              1'b0,
      RgxEn:              1'b0,
      GtxEn:              1'b0,
      GtrEn:              1'b0,
      GtkEn:              1'b0,
      HcwEn:              1'b0,
      HcrEn:              1'b0,
      HcxEn:              1'b0,
      WldEn:              1'b0,
      WlrEn:              1'b0,
      WlkEn:              1'b0,
      CyrEn:              1'b0,
      CykEn:              1'b0,
      CyxEn:              1'b0,
      GnwEn:              1'b0,
      GnkEn:              1'b0,
      GnxEn:              1'b0,
      GefEn:              1'b0,
      GekEn:              1'b0,
      GexEn:              1'b0,
      SpirvEn:            1'b0,
      ChainEn:            1'b0,
      CdmaEn:             1'b0,
      ShmEn:              1'b0,
      HvisEn:             1'b0,
      VncsEn:             1'b0,
      VcapEn:             1'b0,
      VnringEn:           1'b0,
      TdmaEn:             1'b0,
      VnencEn:            1'b0,
      VnpEn:              1'b0,
      AvnEn:              1'b0,
      AvuEn:              1'b0,
      UirEn:              1'b0,
      CmsEn:              1'b0,
      PrsEn:              1'b0,
      QdnEn:              1'b0,
      GcsEn:              1'b0,
      VndEn:              1'b0,
      GnhEn:              1'b0,
      HdpEn:              1'b0,
      HphEn:              1'b0,
      HrnEn:              1'b0,
      RdnEn:              1'b0,
      QrnEn:              1'b0,
      QcmEn:              1'b0,
      QtyEn:              1'b0,
      VctEn:              1'b0,
      QpuEn:              1'b0,
      NtkEn:              1'b0,
      VqtEn:              1'b0,
      VaxEn:              1'b0,
      VacEn:              1'b0,
      HalEn:              1'b0,
      AruEn:              1'b0,
      QalEn:              1'b0,
      QtaEn:              1'b0,
      VcaEn:              1'b0,
      QpaEn:              1'b0,
      NtaEn:              1'b0,
      VqaEn:              1'b0,
      VaaEn:              1'b0,
      VbgEn:              1'b0,
      BalEn:              1'b0,
      BruEn:              1'b0,
      QbnEn:              1'b0,
      QtbEn:              1'b0,
      VcbEn:              1'b0,
      QpbEn:              1'b0,
      NtbEn:              1'b0,
      VqbEn:              1'b0,
      VabEn:              1'b0,
      VenEn:              1'b0,
      EalEn:              1'b0,
      VqsEn:              1'b0,
      VwiEn:              1'b0,
      VgqEn:              1'b0,
      VcdEn:              1'b0,
      VciEn:              1'b0,
      VepEn:              1'b0,
      VqfEn:              1'b0,
      VpfEn:              1'b0,
      VppEn:              1'b0,
      VmpEn:              1'b0,
      VamEn:              1'b0,
      VxbEn:              1'b0,
      VbbEn:              1'b0,
      VmmEn:              1'b0,
      VumEn:              1'b0,
      VbmEn:              1'b0,
      VfmEn:              1'b0,
      VimEn:              1'b0,
      VmcEn:              1'b0,
      VdlEn:              1'b0,
      VplEn:              1'b0,
      VcpEn:              1'b0,
      VdaEn:              1'b0,
      VudEn:              1'b0,
      VbpEn:              1'b0,
      VbdEn:              1'b0,
      VpoEn:              1'b0,
      VxiEn:              1'b0,
      VbiEn:              1'b0,
      VmiEn:              1'b0,
      VxvEn:              1'b0,
      VsmEn:              1'b0,
      VrpEn:              1'b0,
      VgpEn:              1'b0,
      VfbEn:              1'b0,
      VrbEn:              1'b0,
      VdwEn:              1'b0,
      VreEn:              1'b0,
      VvbEn:              1'b0,
      VibEn:              1'b0,
      VdiEn:              1'b0,
      VvpEn:              1'b0,
      VsiEn:              1'b0,
      VpbEn:              1'b0,
      VnsEn:              1'b0,
      VdfEn:              1'b0,
      VdxEn:              1'b0,
      VdkEn:              1'b0,
      VdrEn:              1'b0,
      VdbEn:              1'b0,
      VdgEn:              1'b0,
      VfeEn:              1'b0,
      VdmEn:              1'b0,
      VdpEn:              1'b0,
      VdyEn:              1'b0,
      VdtEn:              1'b0,
      VdqEn:              1'b0,
      VfsEn:              1'b0,
      VrcEn:              1'b0,
      VfcEn:              1'b0,
      VddEn:              1'b0,
      VpcEn:              1'b0,
      VdcEn:              1'b0,
      VdnEn:              1'b0,
      VgfEn:              1'b0,
      VipEn:              1'b0,
      VxeEn:              1'b0,
      VrdEn:              1'b0,
      VieEn:              1'b0,
      VwlEn:              1'b0,
      VslEn:              1'b0,
      VrgEn:              1'b0,
      VlwEn:              1'b0,
      VzbEn:              1'b0,
      VbcEn:              1'b0,
      VboEn:              1'b0,
      VcmEn:              1'b0,
      VwmEn:              1'b0,
      VrfEn:              1'b0,
      VccEn:              1'b0,
      VcyEn:              1'b0,
      VblEn:              1'b0,
      VbtEn:              1'b0,
      VicEn:              1'b0,
      VubEn:              1'b0,
      VflEn:              1'b0,
      VclEn:              1'b0,
      VioEn:              1'b0,
      VixEn:              1'b0,
      VdsEn:              1'b0,
      VatEn:              1'b0,
      VinEn:              1'b0,
      VrsEn:              1'b0,
      VgsEn:              1'b0,
      VwfEn:              1'b0,
      VfrEn:              1'b0,
      VfnEn:              1'b0
  };

  function automatic bit pow2(input int unsigned v);
    return (v != 0) && ((v & (v - 1)) == 0);
  endfunction

  function automatic bit addr_aligned(
      input logic [63:0] base,
      input logic [63:0] length
  );
    return (length != 0) && ((length & (length - 64'd1)) == 0) &&
           ((base & (length - 64'd1)) == 0) && (base <= ~length + 64'd1);
  endfunction

  function automatic bit apu_ranges_overlap(
      input logic [63:0] base_a, length_a, base_b, length_b
  );
    if (length_a == 0 || length_b == 0) return 1'b0;
    return base_a <= base_b ? base_b - base_a < length_a : base_a - base_b < length_b;
  endfunction

  function automatic logic [63:0] apu_desired_features(input apu_cfg_t cfg);
    logic [63:0] mask;
    mask = 64'd1 << VIRTIO_F_VERSION_1_BIT;
    if (cfg.FeatureRingReset)    mask |= 64'd1 << VIRTIO_F_RING_RESET_BIT;
    if (cfg.FeatureVirgl)        mask |= 64'd1 << 0;
    if (cfg.FeatureEdid)         mask |= 64'd1 << 1;
    if (cfg.FeatureIndirectDesc) mask |= 64'd1 << 28;
    if (cfg.FeatureEventIdx)     mask |= 64'd1 << 29;
    if (cfg.FeatureInOrder)      mask |= 64'd1 << 35;
    return mask;
  endfunction

  // Features actually published in DeviceFeatures. Because cfg legality rejects
  // every desired bit outside APU_IMPL_FEATURES, this is not a silent mask.
  function automatic logic [63:0] apu_device_features(input apu_cfg_t cfg);
    return apu_desired_features(cfg) & APU_IMPL_FEATURES;
  endfunction

  // Memory and exec are clients of g6lc_apu_sched. The pair is legal.
  // Either client alone is legal. A disabled device is legal.
  function automatic bit apu_mem_exec_split(input apu_cfg_t cfg);
    bit mem_client;
    mem_client = cfg.MaxResources != 0 || cfg.MaxCmdBytes != 0 || cfg.SgEn ||
                 cfg.DmaReadEn || cfg.DmaWriteEn;
    return !cfg.Enable || !cfg.ExecEn || !mem_client ||
           (cfg.Enable && cfg.ExecEn && mem_client);
  endfunction

  // Control admits only the reserved firmware hart. An unassigned hart is
  // not a control master. AXI id and PROT are not arguments.
  function automatic bit apu_source_is_fw(
      input apu_cfg_t cfg,
      input logic [31:0] hart
  );
    if (cfg.FirmwareHart == APU_FW_HART_UNASSIGNED) return 1'b0;
    return hart == 32'(cfg.FirmwareHart);
  endfunction

  // Firmware RAM with a reserved hart admits only that hart. A window with
  // no reserved hart is not private. AXI id and PROT are not arguments.
  function automatic bit apu_ram_source_ok(
      input apu_cfg_t cfg,
      input logic [31:0] hart
  );
    if (cfg.FirmwareHart == APU_FW_HART_UNASSIGNED) return 1'b1;
    return hart == 32'(cfg.FirmwareHart);
  endfunction

  function automatic bit apu_cfg_legal(input apu_cfg_t cfg);
    logic [63:0] desired;
    desired = apu_desired_features(cfg);
    if (!cfg.Enable) return 1'b1;
    if (cfg.NumQueues != APU_NUM_QUEUES) return 1'b0;
    if (!pow2(cfg.QueueDepth) || cfg.QueueDepth < 8 || cfg.QueueDepth > 1024)
      return 1'b0;
    if (cfg.MmioLength < APU_MMIO_LEN) return 1'b0;
    if (!addr_aligned(cfg.MmioBase, cfg.MmioLength)) return 1'b0;
    if (cfg.ControlLength < APU_CONTROL_LEN ||
        !addr_aligned(cfg.ControlBase, cfg.ControlLength)) return 1'b0;
    if (apu_ranges_overlap(cfg.MmioBase, cfg.MmioLength,
                           cfg.ControlBase, cfg.ControlLength)) return 1'b0;
    if (cfg.IrqSource == 0 || cfg.IrqSource > 29) return 1'b0;
    if (cfg.DmaMaxOutstanding < 1 || cfg.DmaMaxOutstanding > 8) return 1'b0;
    if (cfg.DmaReadEn && (cfg.DmaReadMaxBytes == 0 || cfg.DmaReadMaxBytes > 1048576 ||
        cfg.DmaReadBurstBeats == 0 || cfg.DmaReadBurstBeats > 256)) return 1'b0;
    if (cfg.DmaWriteEn && (cfg.DmaWriteMaxBytes == 0 || cfg.DmaWriteMaxBytes > 1048576))
      return 1'b0;
    if (cfg.DmaReadEn || cfg.DmaWriteEn || cfg.MaxResources != 0) begin
      if (cfg.DmaCoherent) return 1'b0;
      if (!addr_aligned(cfg.DmaWindowBase, cfg.DmaWindowBytes)) return 1'b0;
      if (apu_ranges_overlap(cfg.DmaWindowBase, cfg.DmaWindowBytes,
                             cfg.MmioBase, cfg.MmioLength) ||
          apu_ranges_overlap(cfg.DmaWindowBase, cfg.DmaWindowBytes,
                             cfg.ControlBase, cfg.ControlLength) ||
          apu_ranges_overlap(cfg.DmaWindowBase, cfg.DmaWindowBytes,
                             cfg.FirmwareRamBase, cfg.FirmwareRamBytes)) return 1'b0;
    end
    if (cfg.SgEn && (!cfg.DmaReadEn || !pow2(cfg.SgMaxEntries) ||
        cfg.SgMaxEntries < 64 || cfg.SgMaxEntries > 4096 ||
        cfg.SgMaxEntries > cfg.DmaReadMaxBytes / 16 ||
        cfg.SgMaxTransferBytes == 0 || cfg.SgMaxTransferBytes > 1048576)) return 1'b0;
    if (cfg.MaxResources != 0 && (!pow2(cfg.MaxResources) ||
        cfg.MaxResources < 8 || cfg.MaxResources > 4096)) return 1'b0;
    if (cfg.MaxCmdBytes != 0 && (!pow2(cfg.MaxCmdBytes) ||
        cfg.MaxCmdBytes < 256 || cfg.MaxCmdBytes > 65536)) return 1'b0;
    if ((desired & ~APU_IMPL_FEATURES) != 64'h0) return 1'b0;
    if (cfg.NumCapsets != 0 && !cfg.FeatureVirgl) return 1'b0;
    if (cfg.NumScanouts != 0) return 1'b0;
    if (cfg.FeatureVirgl) begin
      if (cfg.FirmwareHart == APU_FW_HART_UNASSIGNED) return 1'b0;
      if (cfg.FirmwareRamBytes < 64'd262144) return 1'b0;
      if (cfg.MaxContexts == 0 || cfg.MaxResources == 0) return 1'b0;
      if (cfg.MaxCmdBytes < 256 || cfg.MaxShaderBytes == 0) return 1'b0;
      if (cfg.NumCapsets != 2) return 1'b0;
    end
    if (cfg.FeatureEdid && cfg.NumScanouts == 0) return 1'b0;
    if (cfg.FirmwareHart != APU_FW_HART_UNASSIGNED) begin
      if (cfg.FirmwareRamBytes < 64'd262144 ||
          !addr_aligned(cfg.FirmwareRamBase, cfg.FirmwareRamBytes)) return 1'b0;
      if (apu_ranges_overlap(cfg.FirmwareRamBase, cfg.FirmwareRamBytes,
                             cfg.MmioBase, cfg.MmioLength) ||
          apu_ranges_overlap(cfg.FirmwareRamBase, cfg.FirmwareRamBytes,
                             cfg.ControlBase, cfg.ControlLength)) return 1'b0;
    end
    // 4 threads, 8 registers, 64 DMEM words. IMEM depth is
    // APU_EXEC_IMEM_WORDS. The debug and job indices are exactly those widths.
    if (cfg.ExecQuadThreads != APU_EXEC_THREADS ||
        cfg.ExecRegs != APU_EXEC_REGS ||
        cfg.ExecMemWords != APU_EXEC_DMEM_WORDS) return 1'b0;
    if (!apu_mem_exec_split(cfg)) return 1'b0;
    return 1'b1;
  endfunction

  // SoC-facing check: a firmware-backed APU must reserve a real hart while at
  // least one application hart remains. A transport-only device may be hartless.
  function automatic bit apu_soc_legal(
      input apu_cfg_t cfg,
      input config_pkg::cva6_cfg_t core_cfg
  );
    logic [63:0] total_harts;
    if (!apu_cfg_legal(cfg)) return 1'b0;
    if (!cfg.Enable) return 1'b1;
    total_harts = 64'(core_cfg.NrCores) * 64'(core_cfg.NrHarts);
    if (cfg.FirmwareHart != APU_FW_HART_UNASSIGNED) begin
      if (core_cfg.NrCores < 2 || core_cfg.NrHarts != 1) return 1'b0;
      if (64'(cfg.FirmwareHart) >= total_harts) return 1'b0;
    end
    return 1'b1;
  endfunction

  // OpenSBI domain memregion order: size = 2^order, 3 <= order <= 64.
  function automatic int unsigned apu_region_order(input logic [63:0] bytes);
    if (bytes < 64'd8 || (bytes & (bytes - 64'd1)) != 0) return 0;
    return $clog2(bytes);
  endfunction

  // RISC-V PMP NAPOT address field for a naturally aligned power-of-two region.
  function automatic logic [63:0] apu_pmp_napot(
      input logic [63:0] base,
      input logic [63:0] bytes
  );
    return (base >> 2) | ((bytes >> 3) - 64'd1);
  endfunction

  // OpenSBI/PMP firmware-domain contract on top of apu_soc_legal.
  // Guest virtio is not firmware-private. Control and FirmwareRam are.
  // GPIO/AI at 0x40000000 is never an APU region.
  function automatic bit apu_domain_legal(
      input apu_cfg_t cfg,
      input config_pkg::cva6_cfg_t core_cfg
  );
    int unsigned ram_ord, guest_ord, ctrl_ord;
    if (!apu_soc_legal(cfg, core_cfg)) return 1'b0;
    if (!cfg.Enable) return 1'b1;
    guest_ord = apu_region_order(cfg.MmioLength);
    ctrl_ord = apu_region_order(cfg.ControlLength);
    if (guest_ord < 12 || ctrl_ord < 12) return 1'b0;
    if (apu_ranges_overlap(cfg.MmioBase, cfg.MmioLength,
                           64'h4000_0000, 64'h1000) ||
        apu_ranges_overlap(cfg.ControlBase, cfg.ControlLength,
                           64'h4000_0000, 64'h1000))
      return 1'b0;
    if (cfg.FirmwareHart == APU_FW_HART_UNASSIGNED) return 1'b1;
    ram_ord = apu_region_order(cfg.FirmwareRamBytes);
    if (ram_ord < 18) return 1'b0;
    if (!addr_aligned(cfg.FirmwareRamBase, cfg.FirmwareRamBytes)) return 1'b0;
    if (apu_ranges_overlap(cfg.FirmwareRamBase, cfg.FirmwareRamBytes,
                           64'h4000_0000, 64'h1000) ||
        apu_ranges_overlap(cfg.FirmwareRamBase, cfg.FirmwareRamBytes,
                           cfg.MmioBase, cfg.MmioLength) ||
        apu_ranges_overlap(cfg.FirmwareRamBase, cfg.FirmwareRamBytes,
                           cfg.ControlBase, cfg.ControlLength)) return 1'b0;
    return 1'b1;
  endfunction

  // Testharness DRAM hole. Firmware RAM must sit strictly inside DRAM so the
  // xbar can emit two DRAM fragments (lo/hi) without overlapping the SRAM
  // window. Empty fragments (RAM at DRAM start or end) are illegal: addr_decode
  // fatals when start_addr >= end_addr. Last matching rule wins, so a full
  // DRAM range listed after the RAM rule aliases 0x90000000 back to DRAM.
  function automatic bit apu_dram_contains_ram(
      input logic [63:0] ram_base, ram_bytes,
      input logic [63:0] dram_base, dram_bytes
  );
    if (ram_bytes == 0 || dram_bytes == 0) return 1'b0;
    if (ram_base < dram_base) return 1'b0;
    return (ram_base - dram_base) + ram_bytes <= dram_bytes;
  endfunction

  function automatic logic [63:0] apu_dram_lo_end(input logic [63:0] ram_base);
    return ram_base;
  endfunction

  function automatic logic [63:0] apu_dram_hi_start(
      input logic [63:0] ram_base, ram_bytes
  );
    return ram_base + ram_bytes;
  endfunction

  function automatic bit apu_dram_hole_legal(
      input logic [63:0] ram_base, ram_bytes,
      input logic [63:0] dram_base, dram_bytes
  );
    logic [63:0] ram_end, dram_end;
    if (!apu_dram_contains_ram(ram_base, ram_bytes, dram_base, dram_bytes))
      return 1'b0;
    ram_end = ram_base + ram_bytes;
    dram_end = dram_base + dram_bytes;
    if (!(dram_base < ram_base)) return 1'b0;
    if (!(ram_end < dram_end)) return 1'b0;
    return 1'b1;
  endfunction

  // Testharness boot split: application cores keep the ROM reset vector;
  // the firmware hart resets at FirmwareRamBase. Does not prove a CVA6 fetch.
  function automatic logic [63:0] apu_core_boot_addr(
      input apu_cfg_t cfg,
      input int unsigned core,
      input logic [63:0] app_boot
  );
    if (cfg.Enable && cfg.FirmwareHart != APU_FW_HART_UNASSIGNED &&
        core == cfg.FirmwareHart)
      return cfg.FirmwareRamBase;
    return app_boot;
  endfunction

  function automatic bit apu_boot_split_legal(
      input apu_cfg_t cfg,
      input config_pkg::cva6_cfg_t core_cfg,
      input logic [63:0] app_boot
  );
    int unsigned i, ncores;
    bit found_app;
    if (!apu_domain_legal(cfg, core_cfg)) return 1'b0;
    if (!cfg.Enable || cfg.FirmwareHart == APU_FW_HART_UNASSIGNED) return 1'b1;
    if (app_boot == cfg.FirmwareRamBase) return 1'b0;
    if (apu_ranges_overlap(app_boot, 64'd4, cfg.FirmwareRamBase,
                           cfg.FirmwareRamBytes))
      return 1'b0;
    if (apu_core_boot_addr(cfg, cfg.FirmwareHart, app_boot) !=
        cfg.FirmwareRamBase)
      return 1'b0;
    ncores = core_cfg.NrCores < 1 ? 1 : core_cfg.NrCores;
    found_app = 1'b0;
    for (i = 0; i < ncores; i++) begin
      if (i != cfg.FirmwareHart &&
          apu_core_boot_addr(cfg, i, app_boot) == app_boot)
        found_app = 1'b1;
    end
    return found_app;
  endfunction

endpackage
