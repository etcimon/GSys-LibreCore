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
    // Native execution cluster: one physical FP32/integer lane, lockstep
    // fragment-quad contexts. Default-off; FeatureVirgl stays illegal.
    logic        ExecEn;
    int unsigned ExecQuadThreads;
    int unsigned ExecRegs;
    int unsigned ExecMemWords;
    // One-sample triangle coverage. Default-off. Does not paint, sample,
    // or advertise virgl.
    logic        CoverEn;
    // Interpolated RGBA8 store of one covered sample. Default-off.
    logic        FragEn;
    // One unfiltered RGBA8 texel at (0,0). Default-off. Not a sampler.
    logic        TexelEn;
    // Virtio-gpu command payload decode. Default-off. Not a virtqueue walk.
    logic        ProtoEn;
    // Local used-element publication and its interrupt. Default-off.
    logic        UsedEn;
    // One avail-ring descriptor. Default-off. Not a descriptor chain.
    logic        AvailEn;
    // One guest backing entry for an existing resource. Default-off.
    // Not a guest-memory read and not a descriptor chain.
    logic        BackEn;
    // One read of that stored entry into the resource. Default-off.
    // Not a guest write and not a descriptor chain.
    logic        XferEn;
    // One guest write of the local used element. Default-off.
    // Not used.idx and not a descriptor chain.
    logic        UwrEn;
    // One guest store of used.idx. Default-off. Not a second element
    // and not a descriptor chain.
    logic        UidxEn;
    // One covered sample from the resource image. Default-off.
    // Not a draw command and not the HDMI buffer.
    logic        SurfEn;
    // One guest readback of the fragment surface. Default-off.
    // Not a draw, not a descriptor chain, and not the HDMI buffer.
    logic        RdbEn;
    // One SUBMIT_3D three-descriptor chain. Default-off. Reads the
    // 32-byte header only. Not the execbuffer and not a draw.
    logic        SubEn;
    // One read of the execbuffer named by that submit. Default-off.
    // Not a command decode and not a draw.
    logic        BufEn;
    // One decode of the first command in that buffer. Default-off.
    // Not the rest of the stream and not a draw.
    logic        DecEn;
    // The shader create that follows that surface. Default-off.
    // The TGSI text stays in the buffer.
    logic        ShEn;
    // The fragment shader create that follows the vertex shader.
    // Default-off. The TGSI text stays in the buffer.
    logic        FsEn;
    // The vertex-elements object that follows the fragment shader.
    // Default-off. Two attributes, position then uv.
    logic        VeEn;
    // The sampler view that follows the vertex elements. Default-off.
    // Not a texture sample.
    logic        SvEn;
    // The sampler state that follows the sampler view. Default-off.
    // Not a texture sample.
    logic        SsEn;
    // The blend object that follows the sampler state. Default-off.
    // Not a draw.
    logic        BlEn;
    // The depth-stencil object that follows the blend object.
    // Default-off. Depth and stencil stay off.
    logic        DsEn;
    // The rasterizer object that follows the depth-stencil object.
    // Default-off. Not a triangle walk.
    logic        RzEn;
    // The blend bind that follows the rasterizer object. Default-off.
    // Not a draw.
    logic        BbEn;
    // The depth-stencil bind that follows the blend bind. Default-off.
    // Depth and stencil stay off.
    logic        DbEn;
    // The rasterizer bind that follows the depth-stencil bind.
    // Default-off. Not a triangle walk.
    logic        RbEn;
    // The vertex-shader bind that follows the rasterizer bind.
    // Default-off. The TGSI text stays in the buffer.
    logic        VsbEn;
    // The fragment-shader bind that follows the vertex-shader bind.
    // Default-off. The TGSI text stays in the buffer.
    logic        FsbEn;
    // The vertex-elements bind that follows the fragment-shader bind.
    // Default-off.
    logic        VebEn;
    // The sampler-state bind that follows the vertex-elements bind.
    // Default-off. Not a texture sample.
    logic        SsbEn;
    // The sampler-view set that follows the sampler-state bind.
    // Default-off. Not a texture sample.
    logic        SvbEn;
    // The vertex inline write that follows the sampler-view set.
    // Default-off. The floats stay in the buffer.
    logic        IwEn;
    // The vertex-buffer set that follows the inline write.
    // Default-off. Not a vertex fetch.
    logic        VbEn;
    // The scissor that follows the vertex-buffer set.
    // Default-off. The box is 640 by 480.
    logic        SciEn;
    // The viewport that follows the scissor. Default-off.
    logic        VpEn;
    // The framebuffer state that follows the viewport. Default-off.
    logic        FboEn;
    // The clear that follows the framebuffer state. Default-off.
    logic        ClrEn;
    // The draw that follows the clear. Default-off. Not a raster walk.
    logic        DrwEn;
    // CTX_CREATE for context 1. Default-off. Not an OS context.
    logic        CtxEn;
    // The two RESOURCE_CREATE_3D records. Default-off. Not an allocation.
    logic        C3dEn;
    // The three CTX_ATTACH records. Default-off. Not a guest mapping.
    logic        AttEn;
    // The scene submit response. Default-off. Not a pixel store.
    logic        RspEn;
    // GET_CAPSET_INFO. Default-off. The answer is no capset.
    logic        NfoEn;
    // GET_CAPSET. Default-off. No capset blob.
    logic        CapEn;
    // SET_SCANOUT of resource 4. Default-off. Not a HDMI mode.
    logic        ScnEn;
    // RESOURCE_FLUSH of that scanout. Default-off. Not a present.
    logic        FluEn;
    // The scene submit's three-descriptor chain. Default-off.
    // Not the one-descriptor avail walker.
    logic        ChnEn;
    // The chain matches the recorded submit and response. Default-off.
    logic        CmxEn;
    // The local used element for that chain. Default-off. Not a guest store.
    logic        SunEn;
    // Guest store of that element. Default-off. Not the CREATE_2D element.
    logic        SuwEn;
    // Guest store of that used.idx. Default-off.
    logic        SuxEn;
    // Clear floats to RGBA8 bytes. Default-off. Not a general converter.
    logic        U8En;
    // Four corner samples of that clear. Default-off. Not a triangle walk.
    logic        PixEn;
    // Read of one stored corner. Default-off.
    logic        PxrEn;
    // The clear word covers the 64 by 64 ceiling. Default-off.
    logic        FilEn;
    // Read of one sample in that ceiling. Default-off. Not a triangle walk.
    logic        FrdEn;
    // The 24 vertex floats of the fullscreen strip. Default-off.
    logic        QdEn;
    // That strip covers the ceiling. Default-off. The color stays the clear.
    logic        CvEn;
    // One covered sample. Default-off. Not a shaded pixel.
    logic        CvrEn;
    // Vertex-shader TGSI text. Default-off. Not a translate.
    logic        VstEn;
    // Fragment-shader TGSI text. Default-off. TEX is not executed.
    logic        FstEn;
    // One covered sample held at the clear. Default-off. Not a shaded pixel.
    logic        HldEn;
    // TEX bound to the sampler view and sampler state. Default-off.
    logic        TbnEn;
    // That sample is refused. Default-off. No texel image.
    logic        DenEn;
    // One refused sample. Default-off. The color stays the clear.
    logic        DnrEn;
    // VioScan CREATE_2D for resource 1. Default-off. Not the 64 by 64 create.
    logic        S2dEn;
    // Backing entry for that resource. Default-off. Not a guest read.
    logic        SbkEn;
    // The 64-row transfer of that resource. Default-off. No bytes are copied.
    logic        SxfEn;
    // SET_SCANOUT of resource 1. Default-off. Does not present.
    logic        SscEn;
    // RESOURCE_FLUSH of the scan band. Default-off. Does not present.
    logic        SflEn;
    // One sample while that scanout is unpresented. Default-off.
    logic        SprEn;
    // Band copy of resource 1. Default-off. Does not store the image.
    logic        BcpEn;
    // One copied word beside the clear. Default-off. TEX is not executed.
    logic        BcrEn;
    // One clamp-edge texel from the copied band. Default-off.
    logic        TapEn;
    // Ceiling (0,0) takes that texel. Default-off. Other samples stay clear.
    logic        PxcEn;
    // One ceiling read after that corner. Default-off.
    logic        PxqEn;
    // Horizontal blend of two taps in the first beat. Default-off.
    logic        LinEn;
    // Origin texel and the blended neighbor. Default-off.
    logic        LnrEn;
    // Blend that spans the first two beats. Default-off.
    logic        SpnEn;
    // The spanned sample at x = 8. Default-off.
    logic        SpxEn;
    // Vertical blend of row 0 and row 1. Default-off.
    logic        VlnEn;
    // The y = 1 samples at x = 0 and x = 1. Default-off.
    logic        VlrEn;
    // y = 1 blend for x = 0..7, both row beats. Default-off.
    logic        VbxEn;
    // The y = 1 sample at x = 2. Default-off.
    logic        VbrEn;
    // y = 1 blend for x = 0..15, including the beat span. Default-off.
    logic        VspEn;
    // The y = 1 sample at x = 8. Default-off.
    logic        VsxEn;
    // y = 2 blend for x = 0..7, row 1 and row 2. Default-off.
    logic        Y2bEn;
    // The y = 2 samples at x = 0 and x = 1. Default-off.
    logic        Y2rEn;
    // Any 64 by 64 ceiling sample from the copied band. Default-off.
    logic        SmpEn;
    // The ceiling sample at (0,3). Default-off.
    logic        SmxEn;
    // Write the 64 by 64 ceiling as 512 beats. Default-off.
    logic        RbfEn;
    // The readback record: byte count, first word, last address. Default-off.
    logic        RbkEn;
    // Read the 512 ceiling beats back. Default-off.
    logic        RdrEn;
    // The two words collected from that read. Default-off.
    logic        RdkEn;
    // Fetch the scene header and the 960-byte execbuffer. Default-off.
    logic        FetEn;
    // The submit type and the first command word. Default-off.
    logic        FekEn;
    // DRAW_VBO at byte 908 of the fetched execbuffer. Default-off.
    logic        DrdEn;
    // The vertex count and the triangle-strip primitive. Default-off.
    logic        DrkEn;
    // The 24 NDC floats of the fetched draw. Default-off.
    logic        QdrEn;
    // The first float and the last float. Default-off.
    logic        QdkEn;
    // Viewport of the fetched draw, and where ±1 lands. Default-off.
    logic        VwxEn;
    // The scales and the window edges. Default-off.
    logic        VwkEn;
    // Scissor of the fetched draw, matched to the window. Default-off.
    logic        CxrEn;
    // The scissor width and height. Default-off.
    logic        CxkEn;
    // Clear color of the fetched draw. Default-off.
    logic        CwrEn;
    // The red, the blue, and the packed word. Default-off.
    logic        CwkEn;
    // Framebuffer of the fetched draw. Default-off.
    logic        FbrEn;
    // The color-buffer count, the surface, and the clear word. Default-off.
    logic        FbkEn;
    // Vertex-buffer set of the fetched draw. Default-off.
    logic        VbfEn;
    // The stride, the offset, and the resource. Default-off.
    logic        VbkEn;
    // Inline write that holds the fetched quad. Default-off.
    logic        IwrEn;
    // The resource and the byte count. Default-off.
    logic        IwkEn;
    // Sampler view of the fetched draw. Default-off.
    logic        SvrEn;
    // The stage, the slot, and the handle. Default-off.
    logic        SvkEn;
    // Sampler state of the fetched draw. Default-off.
    logic        SsrEn;
    // The stage, the slot, and the handle. Default-off.
    logic        SskEn;
    // Vertex-element bind of the fetched draw. Default-off.
    logic        VerEn;
    // The header and the handle. Default-off.
    logic        VekEn;
    // Fragment shader bind of the fetched draw. Default-off.
    logic        FsrEn;
    // The handle and the stage. Default-off.
    logic        FskEn;
    // Vertex shader bind of the fetched draw. Default-off.
    logic        VsrEn;
    // The handle and the stage. Default-off.
    logic        VskEn;
    // Rasterizer bind of the fetched draw. Default-off.
    logic        RzrEn;
    // The header and the handle. Default-off.
    logic        RzkEn;
    // Depth-stencil bind of the fetched draw. Default-off.
    logic        DbrEn;
    // The header and the handle. Default-off.
    logic        DbkEn;
    // Blend bind of the fetched draw. Default-off.
    logic        BbrEn;
    // The header and the handle. Default-off.
    logic        BbkEn;
    // Rasterizer object of the fetched draw. Default-off.
    logic        RcrEn;
    // The header and the handle. Default-off.
    logic        RckEn;
    // Depth-stencil object of the fetched draw. Default-off.
    logic        DcrEn;
    // The header and the handle. Default-off.
    logic        DckEn;
    // Blend object of the fetched draw. Default-off.
    logic        BlrEn;
    // The header, the handle, and the color word. Default-off.
    logic        BlkEn;
    // Sampler-state object of the fetched draw. Default-off.
    logic        ScrEn;
    // The header, the handle, and the two state words. Default-off.
    logic        SckEn;
    // Sampler view of the fetched draw. Default-off.
    logic        SvcEn;
    // The header, the handle, the resource, the format, and the swizzle. Default-off.
    logic        VckEn;
    // Vertex-element object of the fetched draw. Default-off.
    logic        VecEn;
    // The header, the handle, and the two element offsets and formats. Default-off.
    logic        VceEn;
    // Fragment-shader object of the fetched draw. Default-off. The shader is not run.
    logic        FscEn;
    // The header, the handle, the stage, the length, the tokens, and text0. Default-off.
    logic        FceEn;
    // Vertex-shader object of the fetched draw. Default-off. The shader is not run.
    logic        VscEn;
    // The header, the handle, the stage, the length, the tokens, and text0. Default-off.
    logic        VseEn;
    // Surface object at the start of the fetched draw. Default-off. No pixels are stored.
    logic        SfcEn;
    // The header, the handle, the resource, and the format. Default-off.
    logic        SfeEn;
    // Guest read of the scene descriptor chain and its avail slot. Default-off.
    logic        NxcEn;
    // The head, the execbuffer, the response, and the avail index. Default-off.
    logic        NxkEn;
    // Completed-opcode list. Default-off. The list is empty.
    logic        OlsEn;
    // The zero count, capset id 0, and the response. Default-off.
    logic        OlkEn;
    // 64 by 64 guest window of the scene clear word. Default-off.
    logic        GpwEn;
    // First and last beats of that window. Default-off.
    logic        GprEn;
    // The clear word and the two beat addresses. Default-off.
    logic        GpkEn;
    // Guest response, used element, and used index after that window. Default-off.
    logic        GcwEn;
    // Those three beats read back. Default-off.
    logic        GcrEn;
    // The response type, the fence, and the used index. Default-off.
    logic        GckEn;
    // Used-buffer interrupt after that completion. Default-off.
    logic        ViwEn;
    // The interrupt reason read back. Default-off.
    logic        VirEn;
    // The reason and the used index. Default-off.
    logic        VikEn;
    // Guest ack of the used-buffer reason. Default-off.
    logic        VawEn;
    // The ack word and the cleared status read back. Default-off.
    logic        VarEn;
    // The ack, the cleared status, and the used index. Default-off.
    logic        VakEn;
    // Every beat of the 64 by 64 clear-word window. Default-off.
    logic        WfrEn;
    // The clear word at (0,0), (1,0), and (63,63). Default-off.
    logic        WfkEn;
    // One in-range point of that scan. Default-off.
    logic        WfxEn;
    // Copy of that window into the guest readback buffer. Default-off.
    logic        GbwEn;
    // First and last beats of the readback buffer. Default-off.
    logic        GbrEn;
    // The clear word, the source, and the readback address. Default-off.
    logic        GbkEn;
    // 64 by 64 readback rectangle. Default-off.
    logic        GbdEn;
    // One lane of that rectangle. Default-off.
    logic        GblEn;
    // The rectangle and the sampled lane. Default-off.
    logic        GbxEn;
    // Byte offset of one point in that rectangle. Default-off.
    logic        GofEn;
    // The lane at that offset. Default-off.
    logic        GboEn;
    // The offset and the lane. Default-off.
    logic        GbzEn;
    // Little-endian channels of the clear word in the readback. Default-off.
    logic        ByrEn;
    // The four channels. Default-off.
    logic        BykEn;
    // Byte 0 is red. Default-off.
    logic        ByxEn;
    // Row 1 of the readback starts with that red byte. Default-off.
    logic        RyrEn;
    // The row channels and the format tag. Default-off.
    logic        RykEn;
    // Byte 0 of row 1 is red, not blue. Default-off.
    logic        RyxEn;
    // Three readback points, little-endian clear channels. Default-off.
    logic        TprEn;
    // The three offsets and the channels. Default-off.
    logic        TpkEn;
    // Byte 0 of (0,63) is red, not blue. Default-off.
    logic        TpxEn;
    // (63,0) of the readback is byte 252. Default-off.
    logic        X6rEn;
    // That offset and the channels. Default-off.
    logic        X6kEn;
    // Byte 0 of (63,0) is red, not blue. Default-off.
    logic        X6xEn;
    // (63,63) of the readback is byte 16380. Default-off.
    logic        TcrEn;
    // That offset and the channels. Default-off.
    logic        TckEn;
    // Byte 0 of (63,63) is red, not blue. Default-off.
    logic        TcxEn;
    // (7,0) of the readback is byte 28. Default-off.
    logic        P7rEn;
    // That offset and the channels. Default-off.
    logic        P7kEn;
    // Byte 0 of (7,0) is red, not blue. Default-off.
    logic        P7xEn;
    // Beat 1 of row 0, bytes 32 and 60. Default-off.
    logic        B1rEn;
    // Those offsets and the channels. Default-off.
    logic        B1kEn;
    // Byte 0 of (8,0) is red, not blue. Default-off.
    logic        B1xEn;
    // (56,0) is byte 224, lane 0 of the (63,0) beat. Default-off.
    logic        B7rEn;
    // That offset and the channels. Default-off.
    logic        B7kEn;
    // Byte 0 of (56,0) is red, not blue. Default-off.
    logic        B7xEn;
    // (16,0) is byte 64, lane 0 of beat 2. (23,0) is byte 92.
    logic        B2rEn;
    // Those offsets and the channels. Default-off.
    logic        B2kEn;
    // Byte 0 of (16,0) is red, not blue. Default-off.
    logic        B2xEn;
    // (24,0) is byte 96, lane 0 of beat 3. (31,0) is byte 124.
    logic        B3rEn;
    // Those offsets and the channels. Default-off.
    logic        B3kEn;
    // Byte 0 of (24,0) is red, not blue. Default-off.
    logic        B3xEn;
    // (32,0) is byte 128, lane 0 of beat 4. (39,0) is byte 156.
    logic        B4rEn;
    // Those offsets and the channels. Default-off.
    logic        B4kEn;
    // Byte 0 of (32,0) is red, not blue. Default-off.
    logic        B4xEn;
    // (40,0) is byte 160, lane 0 of beat 5. (47,0) is byte 188.
    logic        B5rEn;
    // Those offsets and the channels. Default-off.
    logic        B5kEn;
    // Byte 0 of (40,0) is red, not blue. Default-off.
    logic        B5xEn;
    // (48,0) is byte 192, lane 0 of beat 6. (55,0) is byte 220.
    logic        B6rEn;
    // Those offsets and the channels. Default-off.
    logic        B6kEn;
    // Byte 0 of (48,0) is red, not blue. Default-off.
    logic        B6xEn;
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
      B6xEn:              1'b0
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
      B6xEn:              1'b0
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
      B6xEn:              1'b0
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
      B6xEn:              1'b0
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
      B6xEn:              1'b0
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
