// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Native APU contract package. The public guest ABI is modern virtio-mmio
// DeviceID 16; the structs below are the protected control-plane handoff into
// the resident command firmware. No virgl command semantics live in this
// register block: firmware owns protocol decode, resource lifetimes and shader
// compilation, while the APU datapath owns execution.

package g6lc_apu_pkg;

  // Three-letter vgpu leaf ids (gnw, vsb, sny, ...) are local LibreCore
  // names. Human-readable aliases are written as PseudoName (id):
  // description on apu_cfg_t grant bits, on these record/status/
  // completion types, and above each g6lc_apu_vgpu_* module.
  // Call-graph of those names: corev_apu/apu/AGENTS-impl-interplays.md.

  import g6lc_apu_cfg_pkg::*;

  localparam logic [31:0] VIRTIO_MMIO_MAGIC    = 32'h7472_6976; // "virt"
  localparam logic [31:0] VIRTIO_MMIO_VERSION2 = 32'd2;
  localparam logic [31:0] VIRTIO_DEVICE_GPU    = 32'd16;
  // Project-local virtio vendor identity. Not mvendorid and not an allocated
  // Red Hat/QEMU identifier; Linux virtio-mmio binds on DeviceID.
  localparam logic [31:0] G6LC_VIRTIO_VENDOR   = 32'h4753_4c43; // "GSLC"

  localparam int unsigned APU_VQ_CONTROL = 0;
  localparam int unsigned APU_VQ_CURSOR  = 1;

  // virtio-mmio v2 register map, byte offsets within the APU window.
  localparam logic [15:0] VREG_MAGIC             = 16'h000;
  localparam logic [15:0] VREG_VERSION           = 16'h004;
  localparam logic [15:0] VREG_DEVICE_ID         = 16'h008;
  localparam logic [15:0] VREG_VENDOR_ID         = 16'h00c;
  localparam logic [15:0] VREG_DEVICE_FEATURES   = 16'h010;
  localparam logic [15:0] VREG_DEVICE_FEAT_SEL   = 16'h014;
  localparam logic [15:0] VREG_DRIVER_FEATURES   = 16'h020;
  localparam logic [15:0] VREG_DRIVER_FEAT_SEL   = 16'h024;
  localparam logic [15:0] VREG_GUEST_PAGE_SIZE   = 16'h028;
  localparam logic [15:0] VREG_QUEUE_SEL         = 16'h030;
  localparam logic [15:0] VREG_QUEUE_NUM_MAX     = 16'h034;
  localparam logic [15:0] VREG_QUEUE_NUM         = 16'h038;
  localparam logic [15:0] VREG_QUEUE_ALIGN       = 16'h03c;
  localparam logic [15:0] VREG_QUEUE_PFN         = 16'h040;
  localparam logic [15:0] VREG_QUEUE_READY       = 16'h044;
  localparam logic [15:0] VREG_QUEUE_NOTIFY      = 16'h050;
  localparam logic [15:0] VREG_INTERRUPT_STATUS  = 16'h060;
  localparam logic [15:0] VREG_INTERRUPT_ACK     = 16'h064;
  localparam logic [15:0] VREG_STATUS            = 16'h070;
  localparam logic [15:0] VREG_QUEUE_DESC_LO     = 16'h080;
  localparam logic [15:0] VREG_QUEUE_DESC_HI     = 16'h084;
  localparam logic [15:0] VREG_QUEUE_AVAIL_LO    = 16'h090;
  localparam logic [15:0] VREG_QUEUE_AVAIL_HI    = 16'h094;
  localparam logic [15:0] VREG_QUEUE_USED_LO     = 16'h0a0;
  localparam logic [15:0] VREG_QUEUE_USED_HI     = 16'h0a4;
  localparam logic [15:0] VREG_SHM_SEL           = 16'h0ac;
  localparam logic [15:0] VREG_SHM_LEN_LO        = 16'h0b0;
  localparam logic [15:0] VREG_SHM_LEN_HI        = 16'h0b4;
  localparam logic [15:0] VREG_SHM_BASE_LO       = 16'h0b8;
  localparam logic [15:0] VREG_SHM_BASE_HI       = 16'h0bc;
  // VIRTIO_GPU_SHM_ID_HOST_VISIBLE. Length all-ones means the region is absent.
  localparam logic [31:0] APU_SHM_ID_HOST_VISIBLE = 32'd1;
  localparam logic [63:0] APU_SHM_BASE            = 64'h0000_0000_8200_0000;
  // 32 MiB host-visible aperture (SHM id 1): stock Mesa Venus needs
  // ~9.3 MiB of HOST3D blobs per instance (8 MiB cs + 1 MiB reply
  // shmem pools + the 132 KiB ring) before any buffer objects.
  localparam logic [63:0] APU_SHM_BYTES           = 64'h0000_0000_0200_0000;
  // §12.3 F5: the top 8 MiB is a device-private arena (descriptor-pool
  // record stores, APU_VGPAGES_OP_ALLOC_PRIV); the guest kernel's shm
  // drm_mm only spans the advertised SHM_LEN so internal allocations
  // can never collide with MAP_BLOB placement.  Must equal
  // g6lc_apu_vg_pkg::APU_VG_GUEST_BYTES.
  localparam logic [63:0] APU_SHM_GUEST_BYTES     = 64'h0000_0000_0180_0000;
  localparam logic [31:0] APU_BLOB_MEM_HOST3D     = 32'h0000_0002;
  localparam logic [31:0] APU_BLOB_FLAG_MAPPABLE  = 32'h0000_0001;
  localparam logic [31:0] APU_VGPU_CAPSET_VENUS   = 32'd4;
  localparam logic [31:0] VIRTIO_GPU_F_RESOURCE_BLOB = 32'd3;
  localparam logic [31:0] VIRTIO_GPU_F_CONTEXT_INIT  = 32'd4;
  localparam logic [15:0] VREG_QUEUE_RESET       = 16'h0c0;
  localparam logic [15:0] VREG_CONFIG_GENERATION = 16'h0fc;
  localparam logic [15:0] VREG_CONFIG_BASE       = 16'h100;

  // virtio device status bits.
  localparam logic [7:0] VSTATUS_ACKNOWLEDGE       = 8'h01;
  localparam logic [7:0] VSTATUS_DRIVER            = 8'h02;
  localparam logic [7:0] VSTATUS_DRIVER_OK         = 8'h04;
  localparam logic [7:0] VSTATUS_FEATURES_OK       = 8'h08;
  localparam logic [7:0] VSTATUS_DEVICE_NEEDS_RESET= 8'h40;
  localparam logic [7:0] VSTATUS_FAILED            = 8'h80;
  localparam logic [7:0] VSTATUS_DRIVER_MASK       =
      VSTATUS_ACKNOWLEDGE | VSTATUS_DRIVER | VSTATUS_DRIVER_OK |
      VSTATUS_FEATURES_OK | VSTATUS_FAILED;

  // InterruptStatus / InterruptAck bits.
  localparam logic [1:0] VIRQ_USED_BUFFER   = 2'b01;
  localparam logic [1:0] VIRQ_CONFIG_CHANGE = 2'b10;

  // virtio_gpu_config words at 0x100.
  localparam logic [15:0] VCFG_EVENTS_READ  = 16'h100;
  localparam logic [15:0] VCFG_EVENTS_CLEAR = 16'h104;
  localparam logic [15:0] VCFG_NUM_SCANOUTS = 16'h108;
  localparam logic [15:0] VCFG_NUM_CAPSETS  = 16'h10c;
  localparam logic [31:0] VGPU_EVENT_DISPLAY = 32'h1;

  localparam logic [31:0] APU_CONTROL_MAGIC = 32'h4736_4143;
  localparam logic [15:0] ACTRL_MAGIC = 16'h000;
  localparam logic [15:0] ACTRL_VERSION = 16'h004;
  localparam logic [15:0] ACTRL_STATUS = 16'h008;
  localparam logic [15:0] ACTRL_EPOCH = 16'h00c;
  localparam logic [15:0] ACTRL_QUEUE_SEL = 16'h010;
  localparam logic [15:0] ACTRL_SNAPSHOT = 16'h014;
  localparam logic [15:0] ACTRL_NOTIFY_CLEAR = 16'h018;
  localparam logic [15:0] ACTRL_RESET_ACK = 16'h01c;
  localparam logic [15:0] ACTRL_QUEUE_STOP_ACK = 16'h020;
  localparam logic [15:0] ACTRL_DEVICE_STATUS = 16'h024;
  localparam logic [15:0] ACTRL_SNAP_EPOCH = 16'h040;
  localparam logic [15:0] ACTRL_SNAP_NUM = 16'h044;
  localparam logic [15:0] ACTRL_SNAP_DESC_LO = 16'h048;
  localparam logic [15:0] ACTRL_SNAP_DESC_HI = 16'h04c;
  localparam logic [15:0] ACTRL_SNAP_AVAIL_LO = 16'h050;
  localparam logic [15:0] ACTRL_SNAP_AVAIL_HI = 16'h054;
  localparam logic [15:0] ACTRL_SNAP_USED_LO = 16'h058;
  localparam logic [15:0] ACTRL_SNAP_USED_HI = 16'h05c;
  localparam logic [15:0] ACTRL_SNAP_CPL_QID = 16'h060;
  localparam logic [15:0] ACTRL_SNAP_CPL_CONTEXT = 16'h064;
  localparam logic [15:0] ACTRL_SNAP_CPL_FENCE_LO = 16'h068;
  localparam logic [15:0] ACTRL_SNAP_CPL_FENCE_HI = 16'h06c;
  localparam logic [15:0] ACTRL_SNAP_CPL_LEN = 16'h070;
  // Firmware mailbox for the memory backend. Lives in the protected control
  // aperture at ControlBase+0x80 so guest virtio MMIO cannot reach it.
  localparam logic [15:0] ACTRL_MAIL_IDX  = 16'h080;
  localparam logic [15:0] ACTRL_MAIL_DATA = 16'h084;
  localparam logic [15:0] ACTRL_MAIL_GO   = 16'h088;
  localparam logic [15:0] ACTRL_MAIL_STAT = 16'h08c;
  localparam logic [15:0] ACTRL_MAIL_CPL0 = 16'h090;
  localparam logic [15:0] ACTRL_MAIL_CPL1 = 16'h094;
  localparam logic [15:0] ACTRL_MAIL_CPL2 = 16'h098;
  localparam logic [15:0] ACTRL_MAIL_CPL3 = 16'h09c;
  localparam logic [15:0] ACTRL_MAIL_END  = 16'h0c0;
  localparam logic [31:0] ACTRL_MAIL_BUSY = 32'h8000_0000;
  localparam logic [31:0] ACTRL_MAIL_HELD = 32'h4000_0000;
  localparam int unsigned APU_MAIL_WORDS = 24;

  typedef struct packed {
    logic [63:0] desc;
    logic [63:0] avail;
    logic [63:0] used;
    logic [15:0] num;
    logic        ready;
  } apu_vq_state_t;

  typedef struct packed {
    logic valid;
    logic [1:0] permissions;
    logic [31:0] resource_id;
    logic [31:0] context_id;
    logic [31:0] epoch;
    logic [63:0] base;
    logic [63:0] bytes;
  } apu_dma_mapping_t;

  typedef struct packed {
    logic [31:0] resource_id;
    logic [31:0] context_id;
    logic [31:0] epoch;
    logic [63:0] offset;
    logic [31:0] bytes;
    logic [63:0] tag;
  } apu_dma_read_req_t;

  typedef enum logic [3:0] {
    APU_DMA_OK = 0,
    APU_DMA_BAD_RESOURCE = 1,
    APU_DMA_PERMISSION = 2,
    APU_DMA_STALE = 3,
    APU_DMA_BOUNDS = 4,
    APU_DMA_LIMIT = 5,
    APU_DMA_BUS_ERROR = 6,
    APU_DMA_PROTOCOL = 7,
    APU_DMA_CANCELLED = 8,
    APU_DMA_STREAM = 9
  } apu_dma_status_e;

  typedef struct packed {
    logic [63:0] data;
    logic [7:0] keep;
    logic [31:0] offset;
    logic last;
  } apu_dma_read_data_t;

  typedef struct packed {
    apu_dma_status_e status;
    logic [31:0] resource_id;
    logic [31:0] context_id;
    logic [31:0] epoch;
    logic [31:0] bytes;
    logic [63:0] tag;
  } apu_dma_read_cpl_t;

  typedef apu_dma_read_req_t apu_dma_write_req_t;
  typedef apu_dma_read_data_t apu_dma_write_data_t;
  typedef apu_dma_read_cpl_t apu_dma_write_cpl_t;

  typedef struct packed {
    logic [31:0] resource_id;
    logic [31:0] context_id;
    logic [31:0] epoch;
    logic [1:0] permissions;
    logic [63:0] bytes;
    logic [31:0] entries;
    logic [63:0] list_offset;
    logic [63:0] tag;
  } apu_sg_load_t;

  typedef struct packed {
    apu_dma_read_req_t req;
    logic write_access;
  } apu_sg_query_t;

  typedef struct packed {
    apu_dma_mapping_t mapping;
    apu_dma_read_req_t req;
    logic write_access;
    logic [31:0] transfer_offset;
    logic last;
  } apu_sg_fragment_t;

  // CoverSample (cover): One sample against one triangle. +x right, +y up. Weights are the
  // integer edge functions; they sum to the signed area. Color is carried
  // through and is not computed here. This is not an SG fragment.
  typedef struct packed {
    logic signed [15:0] x;
    logic signed [15:0] y;
  } apu_cover_xy_t;

  // CoverSample (cover) request.
  typedef struct packed {
    apu_cover_xy_t v0, v1, v2;
    apu_cover_xy_t sample;
    logic [31:0] color;
  } apu_cover_req_t;

  // CoverSample (cover) fragment.
  typedef struct packed {
    logic covered;
    logic signed [47:0] w0, w1, w2, area;
    logic [31:0] color;
  } apu_cover_frag_t;

  // Shaded pixel. Weights come from coverage. RGBA8 is byte0 red through
  // byte3 alpha. use_texel copies the one stored texel at (0,0).
  // use_image copies one covered sample from a packed resource image.
  // The ceiling is the 64 by 64 scene readback.
  // This is not the HDMI scanout format and not a filtered sampler.
  localparam int unsigned APU_FRAG_MAX_W = 64;
  localparam int unsigned APU_FRAG_MAX_H = 64;
  localparam int unsigned APU_FRAG_MAX_STRIDE = 256;
  localparam int unsigned APU_FRAG_MEM_BYTES = APU_FRAG_MAX_H * APU_FRAG_MAX_STRIDE;
  localparam int unsigned APU_FRAG_ADDR_BITS = $clog2(APU_FRAG_MEM_BYTES);

  // FragStore (frag) status.
  typedef enum logic [1:0] {
    APU_FRAG_OK    = 2'd0,
    APU_FRAG_MISS  = 2'd1,
    APU_FRAG_FAULT = 2'd2
  } apu_frag_status_e;

  // FragStore (frag) request.
  typedef struct packed {
    apu_cover_frag_t frag;
    logic [31:0] c0, c1, c2;
    logic signed [15:0] x, y;
    logic [15:0] stride, width, height;
    logic use_texel;
    logic texel_write;
    logic [15:0] tu, tv;
    logic [31:0] texel;
    logic use_image;
    // One LDC-immediate program. prog0 is APU_EX_LDC_R4_WORD and prog1 is
    // the FP32 immediate. 0, 0.5, and 1 change the pixel. TEX is not this.
    logic use_prog;
    logic [31:0] prog0, prog1;
  } apu_frag_req_t;

  // FragStore (frag) completion.
  typedef struct packed {
    apu_frag_status_e status;
    logic [31:0] color;
  } apu_frag_cpl_t;

  // virtio-gpu control command words. Little-endian on the wire.
  // RESOURCE_CREATE_2D is 0x0101. This is not SUBMIT_3D and not a capset.
  localparam logic [31:0] VGPU_CMD_RESOURCE_CREATE_2D = 32'h0000_0101;
  localparam logic [31:0] VGPU_CMD_TRANSFER_TO_HOST_2D = 32'h0000_0105;
  localparam logic [31:0] VGPU_CMD_RESOURCE_ATTACH_BACKING = 32'h0000_0106;
  // VioScan resource 1. Format 2 is B8G8R8X8. The band is the top 64 rows.
  // This is not the lab CREATE_2D, which is format 67 and at most 64 wide.
  localparam logic [15:0] APU_VGPU_SCAN_W = 16'd640;
  localparam logic [15:0] APU_VGPU_SCAN_H = 16'd480;
  localparam logic [15:0] APU_VGPU_SCAN_BAND = 16'd64;
  localparam logic [31:0] APU_VGPU_SCAN_FMT = 32'd2;
  localparam logic [31:0] APU_VGPU_SCAN_BYTES = 32'd1228800;
  // Top band only. 640*64*4 bytes, 32-byte beats. The rest of the
  // 1,228,800-byte backing is not copied here.
  localparam logic [31:0] APU_VGPU_SCAN_BAND_BYTES = 32'd163840;
  // One texture row. 640 * 4. Row 1 of the band starts at this offset.
  localparam logic [31:0] APU_VGPU_SCAN_ROW_BYTES = 32'd2560;
  localparam logic [12:0] APU_VGPU_SCAN_BAND_BEATS = 13'd5120;
  // 64 by 64 ceiling readback. 16384 bytes, 512 beats of 32. Not the
  // texture at 32'h8800F000 and not the lab readback at 32'h8800C000.
  localparam logic [31:0] APU_VGPU_CEIL_RB = 32'h8804_0000;
  localparam logic [31:0] APU_VGPU_CEIL_BYTES = 32'd16384;
  localparam logic [9:0] APU_VGPU_CEIL_BEATS = 10'd512;
  localparam logic [31:0] APU_VGPU_SCAN_C2_AT = 32'd0;
  localparam logic [31:0] APU_VGPU_SCAN_BK_AT = 32'd40;
  localparam logic [31:0] APU_VGPU_SCAN_XF_AT = 32'd88;
  localparam logic [31:0] APU_VGPU_SSC_AT = 32'd0;
  localparam logic [31:0] APU_VGPU_SFL_AT = 32'd48;
  // Guest readback of a resource. Not SUBMIT_3D and not a draw.
  localparam logic [31:0] VGPU_CMD_TRANSFER_FROM_HOST_3D = 32'h0000_0206;
  localparam logic [31:0] VGPU_CMD_SUBMIT_3D = 32'h0000_0207;
  // virtio_gpu_cmd_submit is the 32-byte head of a three-descriptor chain.
  localparam logic [31:0] VGPU_SUBMIT_BYTES = 32'd32;
  // Control records that surround that submit.
  localparam logic [31:0] VGPU_CMD_CTX_CREATE = 32'h0000_0200;
  localparam logic [31:0] VGPU_CMD_CTX_ATTACH_RESOURCE = 32'h0000_0202;
  localparam logic [31:0] VGPU_CMD_RESOURCE_CREATE_3D = 32'h0000_0204;
  localparam logic [31:0] APU_VGPU_CTX_ID = 32'd1;
  localparam logic [31:0] APU_VGPU_CTX_NLEN = 32'd4;
  // Little-endian "main".
  localparam logic [31:0] APU_VGPU_CTX_NAME0 = 32'h6e69_616d;
  localparam logic [31:0] APU_VGPU_CTX_BYTES = 32'd96;
  localparam logic [31:0] APU_VGPU_C3D_BYTES = 32'd72;
  localparam logic [31:0] APU_VGPU_ATT_BYTES = 32'd32;
  localparam logic [31:0] APU_VGPU_CTL_END = 32'd336;
  localparam logic [31:0] APU_VGPU_RES_RT = 32'd4;
  localparam logic [31:0] APU_VGPU_RES_VBO = 32'd3;
  localparam logic [31:0] APU_VGPU_RES_SCAN = 32'd1;
  localparam logic [31:0] APU_VGPU_PIPE_BUFFER = 32'd0;
  localparam logic [31:0] APU_VGPU_PIPE_TEX_2D = 32'd2;
  localparam logic [31:0] APU_VGPU_BIND_RT = 32'd2;
  localparam logic [31:0] APU_VGPU_BIND_VBO = 32'd16;
  localparam logic [31:0] APU_VGPU_RT_W = 32'd640;
  localparam logic [31:0] APU_VGPU_RT_H = 32'd480;
  localparam logic [31:0] APU_VGPU_Y0_TOP = 32'd1;
  localparam logic [63:0] APU_VGPU_HDR_ADDR = 64'h0000_0000_8800_A000;
  localparam logic [63:0] APU_VGPU_RSP_ADDR = 64'h0000_0000_8800_A800;
  localparam logic [63:0] APU_VGPU_EXEC_ADDR = 64'h0000_0000_8800_B000;
  // Scene used ring. Same separation as the CREATE_2D pair at
  // 64'h8800_3000 and 64'h8800_4002, and not those addresses.
  localparam logic [63:0] APU_VGPU_SUN_ELEM = 64'h0000_0000_8800_D000;
  localparam logic [63:0] APU_VGPU_SUN_IDX = 64'h0000_0000_8800_E002;
  // Scene descriptor table and avail ring. Not the used element at
  // 64'h8800_D000 and not used.idx at 64'h8800_E002.
  localparam logic [63:0] APU_VGPU_NXC_DESC = 64'h0000_0000_8800_E100;
  localparam logic [63:0] APU_VGPU_NXC_LAST = APU_VGPU_NXC_DESC + 64'd32;
  localparam logic [63:0] APU_VGPU_NXC_AVAIL = 64'h0000_0000_8800_E200;
  // Completed-opcode list. One word, and that word is zero. Not the
  // avail ring at 64'h8800_E200 and not a virgl caps blob.
  localparam logic [63:0] APU_VGPU_OLS_ADDR = 64'h0000_0000_8800_E300;
  // 64 by 64 guest window of the scene clear word. 512 beats, 16384
  // bytes. Not the ceiling copy at 32'h88040000 and not flip-flops.
  localparam logic [63:0] APU_VGPU_GPW_ADDR = 64'h0000_0000_8802_0000;
  localparam logic [15:0] APU_VGPU_GPW_BEATS = 16'd512;
  localparam logic [8:0] APU_VGPU_GPW_LAST = 9'd511;
  localparam logic [63:0] APU_VGPU_GPW_TAIL = APU_VGPU_GPW_ADDR + (64'(APU_VGPU_GPW_LAST) << 5);
  // Guest readback of that window. Not the color target and not the
  // ceiling at 32'h88040000.
  localparam logic [63:0] APU_VGPU_GBW_ADDR = 64'h0000_0000_8803_0000;
  localparam logic [63:0] APU_VGPU_GBW_TAIL = APU_VGPU_GBW_ADDR + (64'(APU_VGPU_GPW_LAST) << 5);
  // The readback rectangle is 64 by 64, format B8G8R8X8. Not 640 by 480.
  localparam logic [15:0] APU_VGPU_GBD_W = 16'd64;
  localparam logic [15:0] APU_VGPU_GBD_H = 16'd64;
  localparam logic [15:0] APU_VGPU_GBD_STRIDE = 16'd256;
  localparam logic [31:0] APU_VGPU_GBD_BYTES = 32'd16384;
  // Byte offsets in that rectangle. (1,0) is 4. Row 1 starts at 256.
  // (63,63) starts at 16380 and ends at the byte count.
  localparam logic [15:0] APU_VGPU_GOF_AT10 = 16'd4;
  localparam logic [15:0] APU_VGPU_GOF_ROW1 = 16'd256;
  localparam logic [15:0] APU_VGPU_GOF_LAST = 16'd16380;
  localparam logic [63:0] APU_VGPU_GOF_ROW1_ADDR = 64'h0000_0000_8803_0100;
  // Three fixed points in that rectangle. (1,1) is byte 260, lane 1
  // of the row-1 beat. (2,3) is byte 776, lane 2 of 64'h88030300.
  // (0,63) is byte 16128, lane 0 of 64'h88033F00. Not the ceiling
  // at 32'h88040000. Not a walked triangle.
  localparam logic [15:0] APU_VGPU_TPR_AT11 = 16'd260;
  localparam logic [15:0] APU_VGPU_TPR_AT23 = 16'd776;
  localparam logic [15:0] APU_VGPU_TPR_AT063 = 16'd16128;
  localparam logic [63:0] APU_VGPU_TPR_AT23_ADDR = 64'h0000_0000_8803_0300;
  localparam logic [63:0] APU_VGPU_TPR_ROW63_ADDR = 64'h0000_0000_8803_3F00;
  // Guest completion after that window. The 24-byte response stays at
  // the scene response address. The used element and the used index are
  // not 64'h8800_D000 and not 64'h8800_E002.
  localparam logic [63:0] APU_VGPU_GCW_ELEM = 64'h0000_0000_8800_E400;
  localparam logic [63:0] APU_VGPU_GCW_IDX  = 64'h0000_0000_8800_E480;
  localparam logic [1:0]  APU_VGPU_GCW_LAST = 2'd2;
  // Scene used ring after the named WRITE. Id 0, used.idx 1.
  // Not the transfer used ring at 64'h880B0000.
  localparam logic [63:0] APU_VGPU_QSU_ELEM = APU_VGPU_GCW_ELEM;
  localparam logic [63:0] APU_VGPU_QSU_IDX  = APU_VGPU_GCW_IDX;
  localparam logic [31:0] APU_VGPU_QSU_ID   = 32'd0;
  localparam logic [15:0] APU_VGPU_QSU_IDXV = 16'd1;
  // Used-buffer interrupt reason after that completion. Not the
  // virtio-mmio window at 0x40001000 and not PLIC source 9.
  // Bit 0 is the queue. The config bit stays clear.
  localparam logic [63:0] APU_VGPU_VIW_ADDR = 64'h0000_0000_8800_E500;
  localparam logic [31:0] APU_VGPU_VIW_REASON = 32'h1;
  // Scene used-buffer interrupt after used.idx 1. Not the transfer
  // interrupt at 64'h880C0000.
  localparam logic [63:0] APU_VGPU_QSI_ADDR   = APU_VGPU_VIW_ADDR;
  localparam logic [31:0] APU_VGPU_QSI_REASON = APU_VGPU_VIW_REASON;
  // Guest ack of that reason. Not the status word and not 0x40001000.
  localparam logic [63:0] APU_VGPU_VAW_ADDR = 64'h0000_0000_8800_E510;
  localparam logic [31:0] APU_VGPU_VAW_CLEAR = 32'h0;
  // Scene guest ack after used.idx 1. Not the transfer ack at
  // 64'h880C0010.
  localparam logic [63:0] APU_VGPU_QGA_ADDR = APU_VGPU_VAW_ADDR;
  localparam logic [63:0] APU_VGPU_QGA_STAT = APU_VGPU_QSI_ADDR;
  // Clear color as RGBA8. Round half up of the frozen floats times 255.
  // Byte 0 is red. Not a general float converter.
  localparam logic [7:0] APU_VGPU_CLEAR_R = 8'h0D;
  localparam logic [7:0] APU_VGPU_CLEAR_G = 8'h0D;
  localparam logic [7:0] APU_VGPU_CLEAR_B = 8'h1A;
  localparam logic [7:0] APU_VGPU_CLEAR_A = 8'hFF;
  localparam logic [31:0] APU_VGPU_CLEAR_WORD = 32'hFF1A_0D0D;
  // Four corners of the 64 by 64 ceiling, stride 256. Not the interior.
  localparam logic [13:0] APU_VGPU_PIX_00 = 14'd0;
  localparam logic [13:0] APU_VGPU_PIX_X = 14'd252;
  localparam logic [13:0] APU_VGPU_PIX_Y = 14'd16128;
  localparam logic [13:0] APU_VGPU_PIX_XY = 14'd16380;
  // (63,0) in the readback is byte 252, lane 7 of beat 7 at
  // 64'h880300E0. Same offset as the ceiling corner. Not that
  // ceiling. Lane 7 of the base beat is (7,0), byte 28.
  localparam logic [15:0] APU_VGPU_X6R_AT = 16'(APU_VGPU_PIX_X);
  localparam logic [63:0] APU_VGPU_X6R_ADDR =
    APU_VGPU_GBW_ADDR + (64'(APU_VGPU_X6R_AT[13:5]) << 5);
  localparam logic [15:0] APU_VGPU_P7R_AT = 16'd28;
  localparam logic [63:0] APU_VGPU_P7R_ADDR =
    APU_VGPU_GBW_ADDR + (64'(APU_VGPU_P7R_AT[13:5]) << 5);
  // (8,0) is byte 32 and (15,0) is byte 60. Both are in the beat
  // at 64'h88030020. Not the base beat and not (63,0).
  localparam logic [15:0] APU_VGPU_B1R_AT8 = 16'd32;
  localparam logic [15:0] APU_VGPU_B1R_AT15 = 16'd60;
  localparam logic [63:0] APU_VGPU_B1R_ADDR =
    APU_VGPU_GBW_ADDR + (64'(APU_VGPU_B1R_AT8[13:5]) << 5);
  // (56,0) is byte 224, lane 0 of the beat that holds (63,0).
  // That beat is 64'h880300E0. (63,0) stays byte 252, lane 7.
  localparam logic [15:0] APU_VGPU_B7R_AT56 = 16'd224;
  localparam logic [63:0] APU_VGPU_B7R_ADDR =
    APU_VGPU_GBW_ADDR + (64'(APU_VGPU_B7R_AT56[13:5]) << 5);
  // (16,0) is byte 64, lane 0 of beat 2. (23,0) is byte 92, lane 7.
  // That beat is 64'h88030040. Not beat 1 and not the (63,0) beat.
  localparam logic [15:0] APU_VGPU_B2R_AT16 = 16'd64;
  localparam logic [15:0] APU_VGPU_B2R_AT23 = 16'd92;
  localparam logic [63:0] APU_VGPU_B2R_ADDR =
    APU_VGPU_GBW_ADDR + (64'(APU_VGPU_B2R_AT16[13:5]) << 5);
  // (24,0) is byte 96, lane 0 of beat 3. (31,0) is byte 124, lane 7.
  // That beat is 64'h88030060. Not beat 2.
  localparam logic [15:0] APU_VGPU_B3R_AT24 = 16'd96;
  localparam logic [15:0] APU_VGPU_B3R_AT31 = 16'd124;
  localparam logic [63:0] APU_VGPU_B3R_ADDR =
    APU_VGPU_GBW_ADDR + (64'(APU_VGPU_B3R_AT24[13:5]) << 5);
  // (32,0) is byte 128, lane 0 of beat 4. (39,0) is byte 156, lane 7.
  // That beat is 64'h88030080. Not beat 3.
  localparam logic [15:0] APU_VGPU_B4R_AT32 = 16'd128;
  localparam logic [15:0] APU_VGPU_B4R_AT39 = 16'd156;
  localparam logic [63:0] APU_VGPU_B4R_ADDR =
    APU_VGPU_GBW_ADDR + (64'(APU_VGPU_B4R_AT32[13:5]) << 5);
  // (40,0) is byte 160, lane 0 of beat 5. (47,0) is byte 188, lane 7.
  // That beat is 64'h880300A0. Not beat 4.
  localparam logic [15:0] APU_VGPU_B5R_AT40 = 16'd160;
  localparam logic [15:0] APU_VGPU_B5R_AT47 = 16'd188;
  localparam logic [63:0] APU_VGPU_B5R_ADDR =
    APU_VGPU_GBW_ADDR + (64'(APU_VGPU_B5R_AT40[13:5]) << 5);
  // (48,0) is byte 192, lane 0 of beat 6. (55,0) is byte 220, lane 7.
  // That beat is 64'h880300C0. Not beat 5 and not the (63,0) beat.
  localparam logic [15:0] APU_VGPU_B6R_AT48 = 16'd192;
  localparam logic [15:0] APU_VGPU_B6R_AT55 = 16'd220;
  localparam logic [63:0] APU_VGPU_B6R_ADDR =
    APU_VGPU_GBW_ADDR + (64'(APU_VGPU_B6R_AT48[13:5]) << 5);
  // Fragment color of the linear sample pair. One beat at 64'h88050000.
  // Lane 0 is (0,0), the clamp texel. Lane 1 is (1,0), the half blend.
  // Not the clear window at 64'h88020000, not the readback at
  // 64'h88030000, and not the ceiling at 32'h88040000.
  localparam logic [63:0] APU_VGPU_ACW_ADDR = 64'h0000_0000_8805_0000;
  localparam logic [15:0] APU_VGPU_ACW_AT0 = 16'd0;
  localparam logic [15:0] APU_VGPU_ACW_AT1 = 16'd4;
  // 64 by 64 color window of the ceiling samples. Source is the
  // ceiling at 32'h88040000. Destination is 64'h88060000. Not the
  // clear window, not the clear readback, and not the one-beat
  // sample at 64'h88050000.
  localparam logic [63:0] APU_VGPU_CSW_SRC = {32'h0, APU_VGPU_CEIL_RB};
  localparam logic [63:0] APU_VGPU_CSW_DST = 64'h0000_0000_8806_0000;
  localparam logic [63:0] APU_VGPU_CSW_TAIL =
    APU_VGPU_CSW_DST + (64'(APU_VGPU_GPW_LAST) << 5);
  localparam logic [63:0] APU_VGPU_CSW_SRC_TAIL =
    APU_VGPU_CSW_SRC + (64'(APU_VGPU_GPW_LAST) << 5);
  // Guest 64 by 64 TRANSFER_FROM_HOST_3D of the sample rectangle.
  // Source is the color window at 64'h88060000. Destination is
  // 64'h88070000. Not the clear window and not the one-beat sample.
  localparam logic [63:0] APU_VGPU_RPW_DST = 64'h0000_0000_8807_0000;
  localparam logic [63:0] APU_VGPU_RPW_TAIL =
    APU_VGPU_RPW_DST + (64'(APU_VGPU_GPW_LAST) << 5);
  // Guest TRANSFER_FROM_HOST_3D command of the 64 by 64 readpixels
  // box. Three beats at 64'h88080000. Not the pixel buffer.
  localparam logic [63:0] APU_VGPU_TFB_CMD = 64'h0000_0000_8808_0000;
  localparam logic [63:0] APU_VGPU_TFB_B1 = APU_VGPU_TFB_CMD + 64'd32;
  localparam logic [63:0] APU_VGPU_TFB_B2 = APU_VGPU_TFB_CMD + 64'd64;
  localparam logic [31:0] APU_VGPU_TFB_STRIDE = 32'd256;
  localparam logic [31:0] APU_VGPU_TFB_ROW = 32'd2560;
  // Guest RESOURCE_ATTACH_BACKING of the 64 by 64 readpixels buffer.
  // Two beats at 64'h88090000. Length 16384, not the 640 by 480 backing.
  localparam logic [63:0] APU_VGPU_RAB_CMD = 64'h0000_0000_8809_0000;
  localparam logic [63:0] APU_VGPU_RAB_B1 = APU_VGPU_RAB_CMD + 64'd32;
  // virtio OK_NODATA of the 64 by 64 TRANSFER_FROM_HOST_3D. Fence 2,
  // not the scene fence. Not the scene response at 64'h8800A800.
  localparam logic [63:0] APU_VGPU_RFW_ADDR = 64'h0000_0000_880A_0000;
  localparam logic [63:0] APU_VGPU_RFW_FENCE = 64'd2;
  // Used element and used.idx of that transfer. Not the scene
  // completion at 64'h8800E400 / 64'h8800E480.
  localparam logic [63:0] APU_VGPU_TUW_ELEM = 64'h0000_0000_880B_0000;
  localparam logic [63:0] APU_VGPU_TUW_IDX  = 64'h0000_0000_880B_0008;
  localparam logic [31:0] APU_VGPU_TUW_ID   = 32'd1;
  localparam logic [15:0] APU_VGPU_TUW_IDXV = 16'd2;
  // Used-buffer interrupt of that transfer. Not the scene status
  // word at 64'h8800E500.
  localparam logic [63:0] APU_VGPU_TIW_ADDR = 64'h0000_0000_880C_0000;
  localparam logic [31:0] APU_VGPU_TIW_REASON = 32'h1;
  // Guest ack of that interrupt. Not the scene ack at 64'h8800E510.
  localparam logic [63:0] APU_VGPU_TAW_ADDR = 64'h0000_0000_880C_0010;
  // Guest descriptor table of the 64 by 64 transfer. Not the scene
  // table at 64'h8800E100.
  localparam logic [63:0] APU_VGPU_TXC_DESC = 64'h0000_0000_880D_0000;
  localparam logic [63:0] APU_VGPU_TXC_LAST = APU_VGPU_TXC_DESC + 64'd32;
  localparam logic [63:0] APU_VGPU_TXC_AVAIL = 64'h0000_0000_880D_0100;
  // Guest QueueNotify of that transfer. Control queue 0. Not the
  // avail ring at 64'h880D0100.
  localparam logic [63:0] APU_VGPU_QNT_ADDR  = 64'h0000_0000_880D_0200;
  localparam logic [31:0] APU_VGPU_QNT_QUEUE = 32'd0;
  localparam logic [31:0] APU_VGPU_QNT_CURSOR = 32'd1;
  // Scene QueueNotify after avail index 1. Not the transfer doorbell.
  localparam logic [63:0] APU_VGPU_SNT_ADDR = 64'h0000_0000_8800_E220;
  // Guest virtq_avail.idx after that QueueNotify. Not the scene
  // avail ring at 64'h8800E200.
  localparam logic [63:0] APU_VGPU_QAV_ADDR  = APU_VGPU_TXC_AVAIL;
  localparam logic [31:0] APU_VGPU_QAV_WORD  = {16'd2, 16'h0};
  localparam logic [31:0] APU_VGPU_QAV_SCENE = {16'd1, 16'h0};
  // Scene virtq_avail.idx after scene QueueNotify. Not the transfer ring.
  localparam logic [63:0] APU_VGPU_SAV_ADDR = APU_VGPU_NXC_AVAIL;
  // Scene virtq_avail.idx after the guest-rung transfer ack.
  // Index 1 at 64'h8800E200. Not the transfer ring at 64'h880D0100.
  localparam logic [63:0] APU_VGPU_QSV_ADDR  = APU_VGPU_NXC_AVAIL;
  localparam logic [15:0] APU_VGPU_QSV_IDXV  = 16'd1;
  localparam logic [31:0] APU_VGPU_QSV_WORD  = APU_VGPU_QAV_SCENE;
  // Guest virtq_avail.ring[0] after that idx. Names descriptor 0.
  // Not the scene ring at 64'h8800E204. Not the idx word.
  localparam logic [63:0] APU_VGPU_QRG_ADDR  = APU_VGPU_QAV_ADDR + 64'd4;
  localparam logic [63:0] APU_VGPU_QRG_SCENE = APU_VGPU_NXC_AVAIL + 64'd4;
  // Scene virtq_avail.ring[0] after scene QueueNotify. Not the transfer ring.
  localparam logic [63:0] APU_VGPU_SRG_ADDR = APU_VGPU_QRG_SCENE;
  // Scene virtq_avail.ring[0] after scene avail.idx 1.
  // Names descriptor 0. Not the transfer ring at 64'h880D0104.
  localparam logic [63:0] APU_VGPU_QSR_ADDR  = APU_VGPU_QRG_SCENE;
  localparam logic [15:0] APU_VGPU_QRG_DESC  = 16'd0;
  localparam logic [31:0] APU_VGPU_QRG_WORD  = {16'h7, 16'd0};
  localparam logic [31:0] APU_VGPU_QRG_BAD   = {16'h7, 16'd1};
  // Guest virtq_desc 0 after ring[0] names it. Attach at RAB_CMD,
  // length 64, NEXT to 1. Not the scene table at 64'h8800E100.
  localparam logic [63:0] APU_VGPU_QHD_ADDR  = APU_VGPU_TXC_DESC;
  localparam logic [63:0] APU_VGPU_QHD_SCENE = APU_VGPU_NXC_DESC;
  // Scene virtq_desc 0 after scene ring[0] names it after notify.
  localparam logic [63:0] APU_VGPU_SHD_ADDR = APU_VGPU_QHD_SCENE;
  // Scene virtq_desc 0 after scene ring[0] names it.
  // Header at HDR_ADDR, length 32, NEXT to 1. Not the transfer table.
  localparam logic [63:0] APU_VGPU_QSD_ADDR  = APU_VGPU_NXC_DESC;
  localparam logic [31:0] APU_VGPU_QSD_LEN   = 32'd32;
  localparam logic [31:0] APU_VGPU_QHD_META  = 32'h00010001;
  localparam logic [31:0] APU_VGPU_QHD_IND   = 32'h00010005;
  localparam logic [31:0] APU_VGPU_QHD_JUMP  = 32'h00020001;
  // Guest virtq_desc 1 after NEXT from desc 0. Transfer at TFB_CMD,
  // length 96, NEXT to 2. Not desc 0 and not the scene table.
  localparam logic [63:0] APU_VGPU_QFD_ADDR  = APU_VGPU_TXC_DESC + 64'd16;
  localparam logic [63:0] APU_VGPU_QFD_SCENE = APU_VGPU_NXC_DESC + 64'd16;
  // Scene virtq_desc 1 after NEXT from desc 0 after notify.
  localparam logic [63:0] APU_VGPU_SFD_ADDR = APU_VGPU_QFD_SCENE;
  // Scene virtq_desc 1 after NEXT from the header descriptor.
  // Execbuffer at EXEC_ADDR, length 960, NEXT to 2. Not the transfer table.
  localparam logic [63:0] APU_VGPU_QED_ADDR  = APU_VGPU_QFD_SCENE;
  localparam logic [31:0] APU_VGPU_QFD_META  = 32'h00020001;
  localparam logic [31:0] APU_VGPU_QFD_IND   = 32'h00020005;
  localparam logic [31:0] APU_VGPU_QFD_WR    = 32'h00020002;
  // Guest virtq_desc 2 after NEXT from desc 1. WRITE of the
  // 24-byte response at RFW_ADDR. Not desc 1 and not the scene
  // table.
  localparam logic [63:0] APU_VGPU_QWD_ADDR  = APU_VGPU_TXC_LAST;
  localparam logic [63:0] APU_VGPU_QWD_SCENE = APU_VGPU_NXC_LAST;
  // Scene virtq_desc 2 after NEXT from desc 1 after notify.
  localparam logic [63:0] APU_VGPU_SWD_ADDR = APU_VGPU_QWD_SCENE;
  // Scene virtq_desc 2 after NEXT from the execbuffer descriptor.
  // WRITE of the 24-byte response at RSP_ADDR. Not the transfer table.
  localparam logic [63:0] APU_VGPU_QRS_ADDR  = APU_VGPU_QWD_SCENE;
  localparam logic [31:0] APU_VGPU_QWD_META  = 32'h00000002;
  localparam logic [31:0] APU_VGPU_QWD_NXT   = 32'h00000001;
  localparam logic [31:0] APU_VGPU_QWD_IND   = 32'h00000006;
  localparam logic [31:0] APU_VGPU_QWD_LEN   = 32'd24;
  localparam logic [31:0] APU_VGPU_RAB_BYTES = 32'd64;
  localparam logic [31:0] APU_VGPU_TFB_BYTES = 32'd96;
  // TEX of sampler view 5 at (0,0) / (1,0). Lab linear pair from
  // the backing, not DISPLAY.md section 7, not the clear word.
  localparam logic [31:0] APU_VGPU_FTX_ORIGIN   = 32'hA5000000;
  localparam logic [31:0] APU_VGPU_FTX_NEIGHBOR = 32'hD2008000;
  // TEX pair in beat 0 of the 64 by 64 scene window. Not the
  // fragment-color beat at 64'h88050000.
  localparam logic [63:0] APU_VGPU_OCW_ADDR = APU_VGPU_GPW_ADDR;
  // TEX pair in beat 0 of the guest readback. Not the scene window
  // at 64'h88020000.
  localparam logic [63:0] APU_VGPU_PBW_ADDR = APU_VGPU_GBW_ADDR;
  // One clear word stands for every sample of the 64 by 64 ceiling.
  localparam logic [31:0] APU_VGPU_FILL_N = 32'd4096;
  localparam logic [63:0] APU_VGPU_SCENE_FENCE = 64'h1122_3344_5566_7788;
  localparam logic [31:0] APU_VGPU_SCENE_BYTES = 32'd960;
  // 960 / 32. The fetch keeps the first command word, not the buffer.
  localparam logic [5:0] APU_VGPU_EXEC_BEATS = 6'd30;
  // DRAW_VBO starts at byte 908, twelve bytes into beat 28. The command
  // is 52 bytes, so the next byte is 960. Beat 29 is the last exec beat.
  localparam logic [5:0] APU_VGPU_DRAW_BEAT = 6'd28;
  localparam logic [63:0] APU_VGPU_DRAW_ADDR = APU_VGPU_EXEC_ADDR + (64'(APU_VGPU_DRAW_BEAT) << 5);
  localparam logic [63:0] APU_VGPU_DRAW_LAST = APU_VGPU_DRAW_ADDR + 64'd32;
  localparam logic [31:0] APU_VIRGL_DRAW_AT = (32'(APU_VGPU_DRAW_BEAT) << 5) + 32'd12;
  // SET_SAMPLER_VIEWS starts at byte 632, twenty-four bytes into beat 19.
  // The command is 16 bytes and finishes at the inline-write beat.
  localparam logic [5:0] APU_VGPU_SVB_BEAT = 6'd19;
  localparam logic [63:0] APU_VGPU_SVB_ADDR = APU_VGPU_EXEC_ADDR + (64'(APU_VGPU_SVB_BEAT) << 5);
  localparam logic [63:0] APU_VGPU_SVB_LAST = APU_VGPU_SVB_ADDR + 64'd32;
  localparam logic [31:0] APU_VIRGL_SVB_AT = (32'(APU_VGPU_SVB_BEAT) << 5) + 32'd24;
  // BIND_SAMPLER_STATES starts at byte 616, eight bytes into the same beat.
  // The command is 16 bytes and finishes at the sampler-view header.
  localparam logic [63:0] APU_VGPU_SSB_ADDR = APU_VGPU_SVB_ADDR;
  localparam logic [31:0] APU_VIRGL_SSB_AT = (32'(APU_VGPU_SVB_BEAT) << 5) + 32'd8;
  // Vertex-element BIND_OBJECT starts at byte 608, the first word of
  // beat 19. The command is 8 bytes and finishes at the sampler state.
  localparam logic [63:0] APU_VGPU_VEB_ADDR = APU_VGPU_SVB_ADDR;
  localparam logic [31:0] APU_VIRGL_VEB_AT = 32'(APU_VGPU_SVB_BEAT) << 5;
  // Fragment BIND_SHADER starts at byte 596, twenty bytes into beat 18.
  // The command is 12 bytes and finishes at the vertex-element bind.
  localparam logic [5:0] APU_VGPU_FSB_BEAT = 6'd18;
  localparam logic [63:0] APU_VGPU_FSB_ADDR = APU_VGPU_EXEC_ADDR + (64'(APU_VGPU_FSB_BEAT) << 5);
  localparam logic [31:0] APU_VIRGL_FSB_AT = (32'(APU_VGPU_FSB_BEAT) << 5) + 32'd20;
  // Vertex BIND_SHADER starts at byte 584, eight bytes into the same beat.
  // The command is 12 bytes and finishes at the fragment shader bind.
  localparam logic [63:0] APU_VGPU_VSB_ADDR = APU_VGPU_FSB_ADDR;
  localparam logic [31:0] APU_VIRGL_VSB_AT = (32'(APU_VGPU_FSB_BEAT) << 5) + 32'd8;
  // Rasterizer BIND_OBJECT starts at byte 576, the first word of beat 18.
  // The command is 8 bytes and finishes at the vertex shader bind.
  localparam logic [63:0] APU_VGPU_RB_ADDR = APU_VGPU_VSB_ADDR;
  localparam logic [31:0] APU_VIRGL_RB_AT = 32'(APU_VGPU_FSB_BEAT) << 5;
  // Depth-stencil BIND_OBJECT starts at byte 568, twenty-four bytes
  // into beat 17. The command is 8 bytes and finishes at the rasterizer.
  localparam logic [5:0] APU_VGPU_DB_BEAT = 6'd17;
  localparam logic [63:0] APU_VGPU_DB_ADDR = APU_VGPU_EXEC_ADDR + (64'(APU_VGPU_DB_BEAT) << 5);
  localparam logic [31:0] APU_VIRGL_DB_AT = (32'(APU_VGPU_DB_BEAT) << 5) + 32'd24;
  // Surface CREATE_OBJECT is the first command. It occupies bytes 0..24,
  // all inside beat 0. The vertex-shader header shares that beat.
  localparam logic [5:0] APU_VGPU_SFC_BEAT = 6'd0;
  localparam logic [63:0] APU_VGPU_SFC_ADDR = APU_VGPU_EXEC_ADDR + (64'(APU_VGPU_SFC_BEAT) << 5);
  localparam logic [31:0] APU_VIRGL_SFC_AT = 32'(APU_VGPU_SFC_BEAT) << 5;
  // Vertex-shader CREATE_OBJECT starts at byte 24, the last two words of
  // beat 0. Beat 1 carries the stage, the length, and the first text dword.
  localparam logic [5:0] APU_VGPU_VSC_BEAT = 6'd0;
  localparam logic [63:0] APU_VGPU_VSC_ADDR = APU_VGPU_EXEC_ADDR + (64'(APU_VGPU_VSC_BEAT) << 5);
  localparam logic [63:0] APU_VGPU_VSC_LAST = APU_VGPU_VSC_ADDR + 64'd32;
  localparam logic [31:0] APU_VIRGL_VSC_AT = 32'd24;
  // Fragment-shader CREATE_OBJECT starts at byte 176, sixteen bytes into
  // beat 5. Beat 6 carries the token count and the first text dword.
  localparam logic [5:0] APU_VGPU_FSC_BEAT = 6'd5;
  localparam logic [63:0] APU_VGPU_FSC_ADDR = APU_VGPU_EXEC_ADDR + (64'(APU_VGPU_FSC_BEAT) << 5);
  localparam logic [63:0] APU_VGPU_FSC_LAST = APU_VGPU_FSC_ADDR + 64'd32;
  localparam logic [31:0] APU_VIRGL_FSC_AT = (32'(APU_VGPU_FSC_BEAT) << 5) + 32'd16;
  // Vertex-element CREATE_OBJECT starts at byte 340, twenty bytes
  // into beat 10. The command is 40 bytes and finishes at the
  // sampler view.
  localparam logic [5:0] APU_VGPU_VEC_BEAT = 6'd10;
  localparam logic [63:0] APU_VGPU_VEC_ADDR = APU_VGPU_EXEC_ADDR + (64'(APU_VGPU_VEC_BEAT) << 5);
  localparam logic [63:0] APU_VGPU_VEC_LAST = APU_VGPU_VEC_ADDR + 64'd32;
  localparam logic [31:0] APU_VIRGL_VEC_AT = (32'(APU_VGPU_VEC_BEAT) << 5) + 32'd20;
  // Sampler-view CREATE_OBJECT starts at byte 380, twenty-eight
  // bytes into beat 11. The command is 28 bytes and finishes at the
  // sampler-state object.
  localparam logic [5:0] APU_VGPU_SVC_BEAT = 6'd11;
  localparam logic [63:0] APU_VGPU_SVC_ADDR = APU_VGPU_EXEC_ADDR + (64'(APU_VGPU_SVC_BEAT) << 5);
  localparam logic [63:0] APU_VGPU_SVC_LAST = APU_VGPU_SVC_ADDR + 64'd32;
  localparam logic [31:0] APU_VIRGL_SVC_AT = (32'(APU_VGPU_SVC_BEAT) << 5) + 32'd28;
  // Sampler-state CREATE_OBJECT starts at byte 408, twenty-four
  // bytes into beat 12. The command is 40 bytes and finishes at the
  // blend object.
  localparam logic [5:0] APU_VGPU_SCR_BEAT = 6'd12;
  localparam logic [63:0] APU_VGPU_SCR_ADDR = APU_VGPU_EXEC_ADDR + (64'(APU_VGPU_SCR_BEAT) << 5);
  localparam logic [63:0] APU_VGPU_SCR_LAST = APU_VGPU_SCR_ADDR + 64'd32;
  localparam logic [31:0] APU_VIRGL_SCR_AT = (32'(APU_VGPU_SCR_BEAT) << 5) + 32'd24;
  // Blend CREATE_OBJECT starts at byte 448, the first word of beat
  // 14. The command is 48 bytes and finishes at the depth-stencil
  // object.
  localparam logic [5:0] APU_VGPU_BLR_BEAT = 6'd14;
  localparam logic [63:0] APU_VGPU_BLR_ADDR = APU_VGPU_EXEC_ADDR + (64'(APU_VGPU_BLR_BEAT) << 5);
  localparam logic [63:0] APU_VGPU_BLR_LAST = APU_VGPU_BLR_ADDR + 64'd32;
  localparam logic [31:0] APU_VIRGL_BLR_AT = 32'(APU_VGPU_BLR_BEAT) << 5;
  // Depth-stencil CREATE_OBJECT starts at byte 496, sixteen bytes
  // into beat 15. The command is 24 bytes and finishes at the
  // rasterizer object.
  localparam logic [5:0] APU_VGPU_DCR_BEAT = 6'd15;
  localparam logic [63:0] APU_VGPU_DCR_ADDR = APU_VGPU_EXEC_ADDR + (64'(APU_VGPU_DCR_BEAT) << 5);
  localparam logic [63:0] APU_VGPU_DCR_LAST = APU_VGPU_DCR_ADDR + 64'd32;
  localparam logic [31:0] APU_VIRGL_DCR_AT = (32'(APU_VGPU_DCR_BEAT) << 5) + 32'd16;
  // Rasterizer CREATE_OBJECT starts at byte 520, eight bytes into
  // beat 16. The command is 40 bytes and finishes at the blend bind.
  localparam logic [5:0] APU_VGPU_RCR_BEAT = 6'd16;
  localparam logic [63:0] APU_VGPU_RCR_ADDR = APU_VGPU_EXEC_ADDR + (64'(APU_VGPU_RCR_BEAT) << 5);
  localparam logic [63:0] APU_VGPU_RCR_LAST = APU_VGPU_RCR_ADDR + 64'd32;
  localparam logic [31:0] APU_VIRGL_RCR_AT = (32'(APU_VGPU_RCR_BEAT) << 5) + 32'd8;
  // Blend BIND_OBJECT starts at byte 560, sixteen bytes into beat 17.
  // The command is 8 bytes and finishes at the depth-stencil bind.
  localparam logic [63:0] APU_VGPU_BB_ADDR = APU_VGPU_DB_ADDR;
  localparam logic [31:0] APU_VIRGL_BB_AT = (32'(APU_VGPU_DB_BEAT) << 5) + 32'd16;
  // INLINE_WRITE starts at byte 648, eight bytes into beat 20. The
  // command is 144 bytes. Its float payload starts at byte 696.
  localparam logic [5:0] APU_VGPU_IW_BEAT = 6'd20;
  localparam logic [63:0] APU_VGPU_IW_ADDR = APU_VGPU_EXEC_ADDR + (64'(APU_VGPU_IW_BEAT) << 5);
  localparam logic [63:0] APU_VGPU_IW_LAST = APU_VGPU_IW_ADDR + 64'd32;
  localparam logic [31:0] APU_VIRGL_IW_AT = (32'(APU_VGPU_IW_BEAT) << 5) + 32'd8;
  // Twenty-four NDC floats start at byte 696, eight bytes from the end of
  // beat 21. Four beats carry them. The last beat also holds the vertex-buffer
  // command, which this address does not claim.
  localparam logic [5:0] APU_VGPU_QUAD_BEAT = 6'd21;
  localparam logic [63:0] APU_VGPU_QUAD_ADDR = APU_VGPU_EXEC_ADDR + (64'(APU_VGPU_QUAD_BEAT) << 5);
  localparam logic [63:0] APU_VGPU_QUAD_LAST = APU_VGPU_QUAD_ADDR + (64'd3 << 5);
  localparam logic [31:0] APU_VIRGL_QUAD_AT = (32'(APU_VGPU_QUAD_BEAT) << 5) + 32'd24;
  // SET_VERTEX_BUFFERS starts at byte 792, eight bytes from the end of
  // beat 24. The command is 16 bytes and finishes at the scissor beat.
  localparam logic [5:0] APU_VGPU_VB_BEAT = 6'd24;
  localparam logic [63:0] APU_VGPU_VB_ADDR = APU_VGPU_EXEC_ADDR + (64'(APU_VGPU_VB_BEAT) << 5);
  localparam logic [63:0] APU_VGPU_VB_LAST = APU_VGPU_VB_ADDR + 64'd32;
  localparam logic [31:0] APU_VIRGL_VB_AT = (32'(APU_VGPU_VB_BEAT) << 5) + 32'd24;
  // SET_VIEWPORT starts at byte 824, eight bytes from the end of beat 25.
  // The command is 32 bytes, so the next byte is 856.
  localparam logic [5:0] APU_VGPU_VIEW_BEAT = 6'd25;
  localparam logic [63:0] APU_VGPU_VIEW_ADDR = APU_VGPU_EXEC_ADDR + (64'(APU_VGPU_VIEW_BEAT) << 5);
  localparam logic [63:0] APU_VGPU_VIEW_LAST = APU_VGPU_VIEW_ADDR + 64'd32;
  localparam logic [31:0] APU_VIRGL_VIEW_AT = (32'(APU_VGPU_VIEW_BEAT) << 5) + 32'd24;
  // SET_SCISSOR starts at byte 808, eight bytes into the same beat.
  // The command is 16 bytes, so the next byte is 824.
  localparam logic [63:0] APU_VGPU_SCI_ADDR = APU_VGPU_VIEW_ADDR;
  localparam logic [31:0] APU_VIRGL_SCI_AT = (32'(APU_VGPU_VIEW_BEAT) << 5) + 32'd8;
  // CLEAR starts at byte 872, eight bytes into beat 27. The command is
  // 36 bytes, so the next byte is 908. Beat 28 is also the draw beat.
  localparam logic [5:0] APU_VGPU_CLR_BEAT = 6'd27;
  localparam logic [63:0] APU_VGPU_CLR_ADDR = APU_VGPU_EXEC_ADDR + (64'(APU_VGPU_CLR_BEAT) << 5);
  localparam logic [63:0] APU_VGPU_CLR_LAST = APU_VGPU_CLR_ADDR + 64'd32;
  localparam logic [31:0] APU_VIRGL_CLR_AT = (32'(APU_VGPU_CLR_BEAT) << 5) + 32'd8;
  // SET_FRAMEBUFFER starts at byte 856, eight bytes from the end of beat 26.
  // The command is 16 bytes and finishes at the start of the clear beat.
  localparam logic [5:0] APU_VGPU_FBO_BEAT = 6'd26;
  localparam logic [63:0] APU_VGPU_FBO_ADDR = APU_VGPU_EXEC_ADDR + (64'(APU_VGPU_FBO_BEAT) << 5);
  localparam logic [63:0] APU_VGPU_FBO_LAST = APU_VGPU_FBO_ADDR + 64'd32;
  localparam logic [31:0] APU_VIRGL_FBO_AT = (32'(APU_VGPU_FBO_BEAT) << 5) + 32'd24;
  // Capset requests are recognized and refused. No capset blob is returned.
  localparam logic [31:0] VGPU_CMD_GET_CAPSET_INFO = 32'h0000_0108;
  localparam logic [31:0] VGPU_CMD_GET_CAPSET = 32'h0000_0109;
  localparam logic [31:0] APU_VGPU_CAPSET_VIRGL = 32'd1;
  localparam logic [31:0] APU_VGPU_CAPSET_VERSION = 32'd1;
  localparam logic [31:0] APU_VGPU_NFO_BYTES = 32'd32;
  localparam logic [31:0] APU_VGPU_CAP_BYTES = 32'd32;
  localparam logic [31:0] APU_VGPU_CAP_END = 32'd64;
  // Scanout and flush name resource 4 at 640 by 480. Not a HDMI mode.
  localparam logic [31:0] VGPU_CMD_SET_SCANOUT = 32'h0000_0103;
  localparam logic [31:0] VGPU_CMD_RESOURCE_FLUSH = 32'h0000_0104;
  localparam logic [31:0] APU_VGPU_SCN_BYTES = 32'd48;
  localparam logic [31:0] APU_VGPU_FLU_BYTES = 32'd48;
  localparam logic [31:0] APU_VGPU_SCN_END = 32'd96;
  // Largest unread execbuffer this chain accepts. The reduced scene fits.
  localparam logic [31:0] APU_VGPU_SUB_MAX = 32'd1024;
  localparam int unsigned APU_VGPU_BUF_ADDRW = $clog2(APU_VGPU_SUB_MAX);
  // VIRGL_CMD0: cmd in [7:0], object in [15:8], body dwords in [31:16].
  localparam logic [7:0] APU_VIRGL_CREATE_OBJECT = 8'd1;
  localparam logic [7:0] APU_VIRGL_BIND_OBJECT = 8'd2;
  localparam logic [7:0] APU_VIRGL_BIND_SHADER = 8'd31;
  // Frozen BIND_SHADER header: 2 body dwords, object 0, opcode 31.
  localparam logic [31:0] APU_VIRGL_FSB_HDR = {16'd2, 8'd0, APU_VIRGL_BIND_SHADER};
  // The vertex bind uses the same header encoding: 2 body dwords, object 0.
  localparam logic [31:0] APU_VIRGL_VSB_HDR = {16'd2, 8'd0, APU_VIRGL_BIND_SHADER};
  localparam logic [7:0] APU_VIRGL_BIND_SAMPLER_STATES = 8'd18;
  // Frozen BIND_SAMPLER_STATES header: 3 body dwords, object 0, opcode 18.
  localparam logic [31:0] APU_VIRGL_SSB_HDR = {16'd3, 8'd0, APU_VIRGL_BIND_SAMPLER_STATES};
  localparam logic [7:0] APU_VIRGL_SET_SAMPLER_VIEWS = 8'd10;
  // Frozen SET_SAMPLER_VIEWS header: 3 body dwords, object 0, opcode 10.
  localparam logic [31:0] APU_VIRGL_SVB_HDR = {16'd3, 8'd0, APU_VIRGL_SET_SAMPLER_VIEWS};
  localparam logic [7:0] APU_VIRGL_INLINE_WRITE = 8'd9;
  // Frozen INLINE_WRITE header: 35 body dwords, object 0, opcode 9.
  localparam logic [31:0] APU_VIRGL_IW_HDR = {16'd35, 8'd0, APU_VIRGL_INLINE_WRITE};
  localparam logic [7:0] APU_VIRGL_SET_VERTEX_BUFFERS = 8'd6;
  // Frozen SET_VERTEX_BUFFERS header: 3 body dwords, object 0, opcode 6.
  localparam logic [31:0] APU_VIRGL_VB_HDR = {16'd3, 8'd0, APU_VIRGL_SET_VERTEX_BUFFERS};
  localparam logic [7:0] APU_VIRGL_SET_SCISSOR = 8'd15;
  // Frozen SET_SCISSOR header: 3 body dwords, object 0, opcode 15.
  localparam logic [31:0] APU_VIRGL_SCI_HDR = {16'd3, 8'd0, APU_VIRGL_SET_SCISSOR};
  localparam logic [7:0] APU_VIRGL_SET_VIEWPORT = 8'd4;
  // Frozen SET_VIEWPORT header: 7 body dwords, object 0, opcode 4.
  localparam logic [31:0] APU_VIRGL_VIEW_HDR = {16'd7, 8'd0, APU_VIRGL_SET_VIEWPORT};
  localparam logic [7:0] APU_VIRGL_SET_FRAMEBUFFER = 8'd5;
  // Frozen SET_FRAMEBUFFER header: 3 body dwords, object 0, opcode 5.
  localparam logic [31:0] APU_VIRGL_FBO_HDR = {16'd3, 8'd0, APU_VIRGL_SET_FRAMEBUFFER};
  localparam logic [7:0] APU_VIRGL_CLEAR = 8'd7;
  // Frozen CLEAR header: 8 body dwords, object 0, opcode 7.
  localparam logic [31:0] APU_VIRGL_CLR_HDR = {16'd8, 8'd0, APU_VIRGL_CLEAR};
  localparam logic [7:0] APU_VIRGL_DRAW_VBO = 8'd8;
  localparam logic [7:0] APU_VIRGL_OBJ_SURFACE = 8'd8;
  localparam logic [15:0] APU_VIRGL_SURFACE_DWORDS = 16'd5;
  // First command of the frozen execbuffer: surface handle 1, resource 4,
  // format B8G8R8X8 (2), then two zero words.
  localparam logic [31:0] APU_VIRGL_SURFACE_HANDLE = 32'd1;
  // Frozen surface object: 5 body dwords, object 8, opcode 1.
  localparam logic [31:0] APU_VIRGL_SF_HDR = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                             APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] APU_VIRGL_SF_SPAN = (32'(APU_VIRGL_SURFACE_DWORDS) + 32'd1) << 2;
  localparam logic [31:0] APU_VIRGL_RES_RT = 32'd4;
  localparam logic [31:0] APU_VIRGL_RES_VBO = 32'd3;
  localparam logic [31:0] APU_VIRGL_VBO_BYTES = 32'd96;
  localparam logic [31:0] APU_VIRGL_VERT_STRIDE = 32'd24;
  // Frozen execbuffer box: width in [15:0], height in [31:16].
  localparam logic [31:0] APU_VIRGL_SCISSOR_BOX = {16'd480, 16'd640};
  localparam logic [31:0] APU_VIRGL_F32_ONE = 32'h3f80_0000;
  localparam logic [31:0] APU_VIRGL_F32_HALF_W = 32'h43a0_0000;
  localparam logic [31:0] APU_VIRGL_F32_HALF_H = 32'h4370_0000;
  localparam logic [31:0] APU_VIRGL_F32_P05 = 32'h3d4c_cccd;
  localparam logic [31:0] APU_VIRGL_F32_P10 = 32'h3dcc_cccd;
  localparam logic [31:0] APU_VIRGL_CLEAR_COLOR = 32'd4;
  localparam logic [31:0] APU_VIRGL_DEPTH_HI = 32'h3ff0_0000;
  localparam logic [31:0] APU_VIRGL_PRIM_STRIP = 32'd5;
  localparam logic [31:0] APU_VIRGL_VERT_COUNT = 32'd4;
  // Frozen DRAW_VBO header: 12 body dwords, object 0, opcode 8.
  localparam logic [31:0] APU_VIRGL_DRAW_HDR = {16'd12, 8'd0, APU_VIRGL_DRAW_VBO};
  localparam logic [31:0] APU_VIRGL_F32_NEG_ONE = 32'hbf80_0000;
  localparam logic [31:0] APU_VIRGL_FMT_B8G8R8X8 = 32'd2;
  localparam logic [7:0] APU_VIRGL_OBJ_SHADER = 8'd4;
  localparam logic [7:0] APU_VIRGL_SHADER_VERTEX = 8'd0;
  localparam logic [7:0] APU_VIRGL_SHADER_FRAGMENT = 8'd1;
  localparam logic [31:0] APU_VIRGL_VS_HANDLE = 32'd2;
  localparam logic [31:0] APU_VIRGL_FS_HANDLE = 32'd3;
  // Frozen TGSI text. offlen includes the trailing NUL. text0 is the
  // first dword. The remaining dwords stay in the execbuffer until checked.
  localparam logic [31:0] APU_VIRGL_VS_OFFLEN = 32'd125;
  localparam logic [31:0] APU_VIRGL_VS_TOKENS = 32'd300;
  localparam logic [31:0] APU_VIRGL_VS_TEXT_AT = 32'd48;
  localparam logic [31:0] APU_VIRGL_VS_NEXT = 32'd176;
  localparam logic [31:0] APU_VIRGL_VS_TEXT0 = 32'h5452_4556;
  localparam logic [31:0] APU_VIRGL_VS_DWORDS = (APU_VIRGL_VS_OFFLEN + 32'd3) >> 2;
  localparam logic [31:0] APU_VIRGL_VS_WORDS = 32'd5 + APU_VIRGL_VS_DWORDS;
  localparam logic [31:0] APU_VIRGL_VS_SPAN = (APU_VIRGL_VS_WORDS + 32'd1) << 2;
  localparam logic [31:0] APU_VIRGL_VS_HDR = {APU_VIRGL_VS_WORDS[15:0], APU_VIRGL_OBJ_SHADER,
                                             APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] APU_VIRGL_FS_OFFLEN = 32'd140;
  localparam logic [31:0] APU_VIRGL_FS_TOKENS = 32'd300;
  localparam logic [31:0] APU_VIRGL_FS_TEXT_AT = 32'd200;
  localparam logic [31:0] APU_VIRGL_FS_NEXT = 32'd340;
  localparam logic [31:0] APU_VIRGL_FS_TEXT0 = 32'h4741_5246;
  localparam logic [31:0] APU_VIRGL_FS_DWORDS = (APU_VIRGL_FS_OFFLEN + 32'd3) >> 2;
  localparam logic [31:0] APU_VIRGL_FS_WORDS = 32'd5 + APU_VIRGL_FS_DWORDS;
  localparam logic [31:0] APU_VIRGL_FS_SPAN = (APU_VIRGL_FS_WORDS + 32'd1) << 2;
  localparam logic [31:0] APU_VIRGL_FS_HDR = {APU_VIRGL_FS_WORDS[15:0], APU_VIRGL_OBJ_SHADER,
                                             APU_VIRGL_CREATE_OBJECT};
  localparam logic [7:0] APU_VIRGL_OBJ_VERTEX_ELEMENTS = 8'd5;
  localparam logic [31:0] APU_VIRGL_VE_HANDLE = 32'd4;
  // Frozen vertex-element bind: 1 body dword, object 5, opcode 2.
  localparam logic [31:0] APU_VIRGL_VEB_HDR = {16'd1, APU_VIRGL_OBJ_VERTEX_ELEMENTS,
                                              APU_VIRGL_BIND_OBJECT};
  // Frozen vertex-element object: 9 body dwords, object 5, opcode 1.
  localparam logic [31:0] APU_VIRGL_VE_HDR = {16'd9, APU_VIRGL_OBJ_VERTEX_ELEMENTS,
                                             APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] APU_VIRGL_FMT_R32G32B32A32_FLOAT = 32'd31;
  localparam logic [31:0] APU_VIRGL_FMT_R32G32_FLOAT = 32'd29;
  localparam logic [7:0] APU_VIRGL_OBJ_SAMPLER_VIEW = 8'd6;
  localparam logic [31:0] APU_VIRGL_SV_HANDLE = 32'd5;
  localparam logic [31:0] APU_VIRGL_RES_SCAN = 32'd1;
  localparam logic [7:0] APU_VIRGL_TARGET_2D = 8'd2;
  // X in [2:0], Y in [5:3], Z in [8:6], W in [11:9]. Identity is Y=1,Z=2,W=3.
  localparam logic [31:0] APU_VIRGL_SWIZZLE_IDENTITY = 32'h0000_0688;
  // Frozen sampler view: 6 body dwords, object 6, opcode 1.
  localparam logic [31:0] APU_VIRGL_SV_HDR = {16'd6, APU_VIRGL_OBJ_SAMPLER_VIEW,
                                             APU_VIRGL_CREATE_OBJECT};
  // Target in [31:24], format in [23:0]. B8G8R8X8 is 2 and the target is 2D.
  localparam logic [31:0] APU_VIRGL_SV_FMT = {APU_VIRGL_TARGET_2D, 24'h000002};
  localparam logic [7:0] APU_VIRGL_OBJ_SAMPLER_STATE = 8'd7;
  localparam logic [31:0] APU_VIRGL_SS_HANDLE = 32'd6;
  // Frozen sampler-state object: 9 body dwords, object 7, opcode 1.
  localparam logic [31:0] APU_VIRGL_SS_HDR = {16'd9, APU_VIRGL_OBJ_SAMPLER_STATE,
                                             APU_VIRGL_CREATE_OBJECT};
  // wrap S/T/R clamp-to-edge, min and mag linear, no mip filter.
  localparam logic [31:0] APU_VIRGL_SSTATE_S0 = 32'h0000_2292;
  // max_lod is 32.0f. lod_bias and min_lod stay 0.
  localparam logic [31:0] APU_VIRGL_SSTATE_MAX_LOD = 32'h4200_0000;
  localparam logic [31:0] APU_VIRGL_SV_NEXT = 32'd408;
  localparam logic [31:0] APU_VIRGL_SS_NEXT = 32'd448;
  localparam logic [31:0] APU_VIRGL_FSB_NEXT = 32'd608;
  localparam logic [31:0] APU_VIRGL_SSB_NEXT = 32'd632;
  localparam logic [31:0] APU_VIRGL_SVB_NEXT = 32'd648;
  localparam logic [7:0] APU_VIRGL_OBJ_BLEND = 8'd1;
  localparam logic [31:0] APU_VIRGL_BL_HANDLE = 32'd7;
  // Frozen blend bind: 1 body dword, object 1, opcode 2.
  localparam logic [31:0] APU_VIRGL_BB_HDR = {16'd1, APU_VIRGL_OBJ_BLEND,
                                             APU_VIRGL_BIND_OBJECT};
  // Frozen blend object: 11 body dwords, object 1, opcode 1.
  localparam logic [31:0] APU_VIRGL_BL_HDR = {16'd11, APU_VIRGL_OBJ_BLEND,
                                             APU_VIRGL_CREATE_OBJECT};
  // Color buffer 0: source factor ONE at bits 4 and 17, mask 0xf at bit 27.
  localparam logic [31:0] APU_VIRGL_BLEND_S2 = 32'h7802_0010;
  localparam logic [7:0] APU_VIRGL_OBJ_DSA = 8'd3;
  localparam logic [31:0] APU_VIRGL_DS_HANDLE = 32'd8;
  // Frozen depth-stencil bind: 1 body dword, object 3, opcode 2.
  localparam logic [31:0] APU_VIRGL_DB_HDR = {16'd1, APU_VIRGL_OBJ_DSA,
                                             APU_VIRGL_BIND_OBJECT};
  // Frozen depth-stencil object: 5 body dwords, object 3, opcode 1.
  localparam logic [31:0] APU_VIRGL_DS_HDR = {16'd5, APU_VIRGL_OBJ_DSA,
                                             APU_VIRGL_CREATE_OBJECT};
  localparam logic [7:0] APU_VIRGL_OBJ_RASTERIZER = 8'd2;
  localparam logic [31:0] APU_VIRGL_RZ_HANDLE = 32'd9;
  // Frozen rasterizer bind: 1 body dword, object 2, opcode 2.
  localparam logic [31:0] APU_VIRGL_RB_HDR = {16'd1, APU_VIRGL_OBJ_RASTERIZER,
                                             APU_VIRGL_BIND_OBJECT};
  // Frozen rasterizer object: 9 body dwords, object 2, opcode 1.
  localparam logic [31:0] APU_VIRGL_RZ_HDR = {16'd9, APU_VIRGL_OBJ_RASTERIZER,
                                             APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] VGPU_RESP_OK_NODATA = 32'h0000_1100;
  localparam logic [31:0] VGPU_RESP_OK_DISPLAY_INFO = 32'h0000_1101;
  localparam logic [31:0] VGPU_RESP_OK_CAPSET_INFO = 32'h0000_1102;
  localparam logic [31:0] VGPU_RESP_OK_CAPSET = 32'h0000_1103;
  localparam logic [31:0] VGPU_RESP_ERR_UNSPEC = 32'h0000_1200;
  localparam logic [31:0] VGPU_RESP_ERR_OUT_OF_MEMORY = 32'h0000_1201;
  localparam logic [31:0] VGPU_RESP_ERR_INVALID_RESOURCE_ID = 32'h0000_1203;
  localparam logic [31:0] VGPU_RESP_ERR_INVALID_PARAMETER = 32'h0000_1205;
  localparam logic [31:0] VGPU_FLAG_FENCE = 32'h1;
  localparam logic [31:0] VGPU_FORMAT_R8G8B8A8_UNORM = 32'd67;
  localparam logic [31:0] VGPU_RESP_HDR_BYTES = 32'd24;
  localparam logic [31:0] VGPU_USED_ELEM_BYTES = 32'd8;
  localparam logic [31:0] VGPU_USED_IDX_BYTES = 32'd2;
  localparam int unsigned APU_VGPU_USED_NUM = 8;
  localparam logic [15:0] VIRTQ_DESC_F_NEXT = 16'h1;
  localparam logic [15:0] VIRTQ_DESC_F_WRITE = 16'h2;
  localparam logic [15:0] VIRTQ_DESC_F_INDIRECT = 16'h4;
  localparam logic [31:0] VGPU_CMD_BYTES = 32'd40;
  localparam logic [31:0] VGPU_BACK_BYTES = 32'd48;
  localparam logic [31:0] VGPU_XFER_BYTES = 32'd56;
  localparam logic [31:0] VGPU_RDB_BYTES = 32'd72;
  localparam int unsigned APU_VGPU_IMG_BYTES = APU_FRAG_MEM_BYTES;
  // One guest beat. The 64x64 image stays in a byte memory.
  localparam int unsigned APU_VGPU_BEAT_BYTES = 32;
  localparam int unsigned APU_VGPU_RES_SLOTS = 2;

  typedef struct packed {
    logic valid;
    logic [31:0] resource_id;
    logic [31:0] format;
    logic [31:0] width;
    logic [31:0] height;
  } apu_vgpu_res_t;

  // ResourceBacking (back): One guest backing entry for an existing resource
  typedef struct packed {
    logic valid;
    logic [31:0] resource_id;
    logic [63:0] addr;
    logic [31:0] length;
  } apu_vgpu_back_t;

  typedef struct packed {
    logic valid;
    logic [31:0] resource_id;
    logic [31:0] length;
  } apu_vgpu_img_t;

  // UsedGuestWrite (uwr) status.
  typedef enum logic [1:0] {
    APU_VGPU_UWR_OK    = 2'd0,
    APU_VGPU_UWR_EMPTY = 2'd1,
    APU_VGPU_UWR_FAULT = 2'd2,
    APU_VGPU_UWR_BUS   = 2'd3
  } apu_vgpu_uwr_status_e;

  // UsedGuestWrite (uwr) completion.
  typedef struct packed {
    apu_vgpu_uwr_status_e status;
    logic [31:0] elem_id;
    logic [31:0] elem_len;
    logic [63:0] addr;
  } apu_vgpu_uwr_cpl_t;

  // UsedIndexStore (uidx) status.
  typedef enum logic [1:0] {
    APU_VGPU_UIDX_OK    = 2'd0,
    APU_VGPU_UIDX_EMPTY = 2'd1,
    APU_VGPU_UIDX_FAULT = 2'd2,
    APU_VGPU_UIDX_BUS   = 2'd3
  } apu_vgpu_uidx_status_e;

  // UsedIndexStore (uidx) completion.
  typedef struct packed {
    apu_vgpu_uidx_status_e status;
    logic [15:0] idx;
    logic [63:0] addr;
  } apu_vgpu_uidx_cpl_t;

  // ResourceSurface (surf): One covered sample copied from a packed resource image. The address
  // is y * stride + x * 4, the same rule as the fragment surface.
  // Byte 0 is red. This is not a draw and not an SG fragment.
  typedef struct packed {
    logic covered;
    logic signed [15:0] x, y;
    logic [15:0] stride, width, height;
  } apu_rsurf_req_t;

  // UsedPublish (used) request.
  typedef struct packed {
    logic [15:0] idx;
    logic [31:0] desc_id;
    logic [31:0] len;
  } apu_vgpu_used_req_t;

  // UsedPublish (used) completion.
  typedef struct packed {
    logic ok;
    logic [15:0] idx;
    logic [31:0] desc_id;
    logic [31:0] len;
  } apu_vgpu_used_cpl_t;

  // AvailDescriptor (avail) status.
  typedef enum logic [1:0] {
    APU_VGPU_AVAIL_OK    = 2'd0,
    APU_VGPU_AVAIL_EMPTY = 2'd1,
    APU_VGPU_AVAIL_FAULT = 2'd2
  } apu_vgpu_avail_status_e;

  // AvailDescriptor (avail) op.
  typedef enum logic {
    APU_VGPU_AVAIL_POST = 1'b0,
    APU_VGPU_AVAIL_WALK = 1'b1
  } apu_vgpu_avail_op_e;

  // AvailDescriptor (avail) request.
  typedef struct packed {
    apu_vgpu_avail_op_e op;
    logic [15:0] avail_idx;
    logic [15:0] desc_id;
    logic [15:0] flags;
    logic [31:0] len;
    logic [319:0] cmd;
  } apu_vgpu_avail_req_t;

  // AvailDescriptor (avail) completion.
  typedef struct packed {
    apu_vgpu_avail_status_e status;
    logic [15:0] desc_id;
    logic [15:0] device_idx;
    logic [319:0] cmd;
  } apu_vgpu_avail_cpl_t;

  // One virtq descriptor. addr is the guest pointer. next is the chain link.
  typedef struct packed {
    logic [63:0] addr;
    logic [31:0] len;
    logic [15:0] flags;
    logic [15:0] next;
  } apu_vgpu_desc_t;

  // Submit3dChain (sub): SUBMIT_3D as descriptors 0, 1, and 2. d0 is the 32-byte header,
  // d1 names the execbuffer, and d2 is the writable response.
  typedef struct packed {
    apu_vgpu_desc_t d0;
    apu_vgpu_desc_t d1;
    apu_vgpu_desc_t d2;
  } apu_vgpu_sub_req_t;

  // Submit3dChain (sub): The accepted submit. buf_addr is the execbuffer. The bytes are not stored.
  typedef struct packed {
    logic valid;
    logic [31:0] ctx_id;
    logic [31:0] size;
    logic [63:0] buf_addr;
    logic [63:0] rsp_addr;
  } apu_vgpu_sub_t;

  // ExecBufferRead (buf) status.
  typedef enum logic [1:0] {
    APU_VGPU_BUF_OK    = 2'd0,
    APU_VGPU_BUF_EMPTY = 2'd1,
    APU_VGPU_BUF_FAULT = 2'd2,
    APU_VGPU_BUF_BUS   = 2'd3
  } apu_vgpu_buf_status_e;

  // ExecBufferRead (buf) completion.
  typedef struct packed {
    apu_vgpu_buf_status_e status;
    logic [31:0] ctx_id;
    logic [31:0] size;
  } apu_vgpu_buf_cpl_t;

  // ExecBufferRead (buf): Bytes of one fetched execbuffer. valid means every beat arrived.
  typedef struct packed {
    logic valid;
    logic [31:0] ctx_id;
    logic [31:0] size;
    logic [63:0] buf_addr;
  } apu_vgpu_buf_t;

  // FirstCommandDecode (dec) status.
  typedef enum logic [1:0] {
    APU_VGPU_DEC_OK    = 2'd0,
    APU_VGPU_DEC_EMPTY = 2'd1,
    APU_VGPU_DEC_FAULT = 2'd2
  } apu_vgpu_dec_status_e;

  // FirstCommandDecode (dec) completion.
  typedef struct packed {
    apu_vgpu_dec_status_e status;
  } apu_vgpu_dec_cpl_t;

  // FirstCommandDecode (dec): The first command in a fetched execbuffer. next is the byte offset
  // of the following command. surface is the frozen CREATE_OBJECT surface.
  typedef struct packed {
    logic valid;
    logic surface;
    logic [7:0] cmd;
    logic [7:0] obj;
    logic [15:0] nbody;
    logic [31:0] handle;
    logic [31:0] resource_id;
    logic [31:0] format;
    logic [31:0] next;
  } apu_vgpu_dec_t;

  // VertexShaderCreate (sh) status.
  typedef enum logic [1:0] {
    APU_VGPU_SH_OK    = 2'd0,
    APU_VGPU_SH_EMPTY = 2'd1,
    APU_VGPU_SH_FAULT = 2'd2
  } apu_vgpu_sh_status_e;

  // VertexShaderCreate (sh) completion.
  typedef struct packed {
    apu_vgpu_sh_status_e status;
  } apu_vgpu_sh_cpl_t;

  // VertexShaderCreate (sh): The shader create after the surface. text_at is the TGSI text.
  // The text itself stays in the execbuffer.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [7:0] stage;
    logic [31:0] offlen;
    logic [31:0] tokens;
    logic [31:0] text0;
    logic [31:0] text_at;
    logic [31:0] next;
  } apu_vgpu_sh_t;

  // VertexElementsCreate (ve) status.
  typedef enum logic [1:0] {
    APU_VGPU_VE_OK    = 2'd0,
    APU_VGPU_VE_EMPTY = 2'd1,
    APU_VGPU_VE_FAULT = 2'd2
  } apu_vgpu_ve_status_e;

  // VertexElementsCreate (ve) completion.
  typedef struct packed {
    apu_vgpu_ve_status_e status;
  } apu_vgpu_ve_cpl_t;

  // VertexElementsCreate (ve): Two vertex attributes after the fragment shader. Both use buffer 0.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] off0;
    logic [31:0] fmt0;
    logic [31:0] off1;
    logic [31:0] fmt1;
    logic [31:0] next;
  } apu_vgpu_ve_t;

  // SamplerViewCreate (sv) status.
  typedef enum logic [1:0] {
    APU_VGPU_SV_OK    = 2'd0,
    APU_VGPU_SV_EMPTY = 2'd1,
    APU_VGPU_SV_FAULT = 2'd2
  } apu_vgpu_sv_status_e;

  // SamplerViewCreate (sv) completion.
  typedef struct packed {
    apu_vgpu_sv_status_e status;
  } apu_vgpu_sv_cpl_t;

  // SamplerViewCreate (sv): One sampler view over a 2D resource. This is not a texture fetch.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] resource_id;
    logic [23:0] format;
    logic [7:0] target;
    logic [31:0] swizzle;
    logic [31:0] next;
  } apu_vgpu_sv_t;

  // SamplerStateCreate (ss) status.
  typedef enum logic [1:0] {
    APU_VGPU_SS_OK    = 2'd0,
    APU_VGPU_SS_EMPTY = 2'd1,
    APU_VGPU_SS_FAULT = 2'd2
  } apu_vgpu_ss_status_e;

  // SamplerStateCreate (ss) completion.
  typedef struct packed {
    apu_vgpu_ss_status_e status;
  } apu_vgpu_ss_cpl_t;

  // SamplerStateCreate (ss): One sampler state after the sampler view. This is not a texture fetch.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] s0;
    logic [31:0] max_lod;
    logic [31:0] next;
  } apu_vgpu_ss_t;

  // BlendCreate (bl) status.
  typedef enum logic [1:0] {
    APU_VGPU_BL_OK    = 2'd0,
    APU_VGPU_BL_EMPTY = 2'd1,
    APU_VGPU_BL_FAULT = 2'd2
  } apu_vgpu_bl_status_e;

  // BlendCreate (bl) completion.
  typedef struct packed {
    apu_vgpu_bl_status_e status;
  } apu_vgpu_bl_cpl_t;

  // BlendCreate (bl): One blend object. Color buffer 0 only. This is not a draw.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] s2;
    logic [31:0] next;
  } apu_vgpu_bl_t;

  // DepthStencilCreate (ds) status.
  typedef enum logic [1:0] {
    APU_VGPU_DS_OK    = 2'd0,
    APU_VGPU_DS_EMPTY = 2'd1,
    APU_VGPU_DS_FAULT = 2'd2
  } apu_vgpu_ds_status_e;

  // DepthStencilCreate (ds) completion.
  typedef struct packed {
    apu_vgpu_ds_status_e status;
  } apu_vgpu_ds_cpl_t;

  // DepthStencilCreate (ds): One depth-stencil object. Depth and stencil are off. This is not a draw.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] next;
  } apu_vgpu_ds_t;

  // RasterizerCreate (rz) status.
  typedef enum logic [1:0] {
    APU_VGPU_RZ_OK    = 2'd0,
    APU_VGPU_RZ_EMPTY = 2'd1,
    APU_VGPU_RZ_FAULT = 2'd2
  } apu_vgpu_rz_status_e;

  // RasterizerCreate (rz) completion.
  typedef struct packed {
    apu_vgpu_rz_status_e status;
  } apu_vgpu_rz_cpl_t;

  // RasterizerCreate (rz): One rasterizer object. Fill both faces and cull none. This is not a draw.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] next;
  } apu_vgpu_rz_t;

  // BlendBind (bb) status.
  typedef enum logic [1:0] {
    APU_VGPU_BB_OK    = 2'd0,
    APU_VGPU_BB_EMPTY = 2'd1,
    APU_VGPU_BB_FAULT = 2'd2
  } apu_vgpu_bb_status_e;

  // BlendBind (bb) completion.
  typedef struct packed {
    apu_vgpu_bb_status_e status;
  } apu_vgpu_bb_cpl_t;

  // BlendBind (bb): The blend object named by BIND_OBJECT. This is not a draw.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] next;
  } apu_vgpu_bb_t;

  // DepthStencilBind (db) status.
  typedef enum logic [1:0] {
    APU_VGPU_DB_OK    = 2'd0,
    APU_VGPU_DB_EMPTY = 2'd1,
    APU_VGPU_DB_FAULT = 2'd2
  } apu_vgpu_db_status_e;

  // DepthStencilBind (db) completion.
  typedef struct packed {
    apu_vgpu_db_status_e status;
  } apu_vgpu_db_cpl_t;

  // DepthStencilBind (db): The depth-stencil object named by BIND_OBJECT. Depth stays off.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] next;
  } apu_vgpu_db_t;

  // RasterizerBind (rb) status.
  typedef enum logic [1:0] {
    APU_VGPU_RB_OK    = 2'd0,
    APU_VGPU_RB_EMPTY = 2'd1,
    APU_VGPU_RB_FAULT = 2'd2
  } apu_vgpu_rb_status_e;

  // RasterizerBind (rb) completion.
  typedef struct packed {
    apu_vgpu_rb_status_e status;
  } apu_vgpu_rb_cpl_t;

  // RasterizerBind (rb): The rasterizer object named by BIND_OBJECT. This does not walk a triangle.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] next;
  } apu_vgpu_rb_t;

  // VertexShaderBind (vsb) status.
  typedef enum logic [1:0] {
    APU_VGPU_VSB_OK    = 2'd0,
    APU_VGPU_VSB_EMPTY = 2'd1,
    APU_VGPU_VSB_FAULT = 2'd2
  } apu_vgpu_vsb_status_e;

  // VertexShaderBind (vsb) completion.
  typedef struct packed {
    apu_vgpu_vsb_status_e status;
  } apu_vgpu_vsb_cpl_t;

  // VertexShaderBind (vsb): Vertex shader named by BIND_SHADER. The text stays in the buffer.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [7:0] stage;
    logic [31:0] next;
  } apu_vgpu_vsb_t;

  // FragShaderBind (fsb) status.
  typedef enum logic [1:0] {
    APU_VGPU_FSB_OK    = 2'd0,
    APU_VGPU_FSB_EMPTY = 2'd1,
    APU_VGPU_FSB_FAULT = 2'd2
  } apu_vgpu_fsb_status_e;

  // FragShaderBind (fsb) completion.
  typedef struct packed {
    apu_vgpu_fsb_status_e status;
  } apu_vgpu_fsb_cpl_t;

  // FragShaderBind (fsb): Fragment shader named by BIND_SHADER. The text stays in the buffer.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [7:0] stage;
    logic [31:0] next;
  } apu_vgpu_fsb_t;

  // VertexElementsBind (veb) status.
  typedef enum logic [1:0] {
    APU_VGPU_VEB_OK    = 2'd0,
    APU_VGPU_VEB_EMPTY = 2'd1,
    APU_VGPU_VEB_FAULT = 2'd2
  } apu_vgpu_veb_status_e;

  // VertexElementsBind (veb) completion.
  typedef struct packed {
    apu_vgpu_veb_status_e status;
  } apu_vgpu_veb_cpl_t;

  // VertexElementsBind (veb): Vertex elements named by BIND_OBJECT. This is not a draw.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] next;
  } apu_vgpu_veb_t;

  // SamplerStateBind (ssb) status.
  typedef enum logic [1:0] {
    APU_VGPU_SSB_OK    = 2'd0,
    APU_VGPU_SSB_EMPTY = 2'd1,
    APU_VGPU_SSB_FAULT = 2'd2
  } apu_vgpu_ssb_status_e;

  // SamplerStateBind (ssb) completion.
  typedef struct packed {
    apu_vgpu_ssb_status_e status;
  } apu_vgpu_ssb_cpl_t;

  // SamplerStateBind (ssb): Sampler state bound on fragment slot 0. This is not a texture fetch.
  typedef struct packed {
    logic valid;
    logic [7:0] stage;
    logic [31:0] slot;
    logic [31:0] handle;
    logic [31:0] next;
  } apu_vgpu_ssb_t;

  // SamplerViewSet (svb) status.
  typedef enum logic [1:0] {
    APU_VGPU_SVB_OK    = 2'd0,
    APU_VGPU_SVB_EMPTY = 2'd1,
    APU_VGPU_SVB_FAULT = 2'd2
  } apu_vgpu_svb_status_e;

  // SamplerViewSet (svb) completion.
  typedef struct packed {
    apu_vgpu_svb_status_e status;
  } apu_vgpu_svb_cpl_t;

  // SamplerViewSet (svb): Sampler view set on fragment slot 0. This is not a texture fetch.
  typedef struct packed {
    logic valid;
    logic [7:0] stage;
    logic [31:0] slot;
    logic [31:0] handle;
    logic [31:0] next;
  } apu_vgpu_svb_t;

  // ResourceInlineWrite (iw) status.
  typedef enum logic [1:0] {
    APU_VGPU_IW_OK    = 2'd0,
    APU_VGPU_IW_EMPTY = 2'd1,
    APU_VGPU_IW_FAULT = 2'd2
  } apu_vgpu_iw_status_e;

  // ResourceInlineWrite (iw) completion.
  typedef struct packed {
    apu_vgpu_iw_status_e status;
  } apu_vgpu_iw_cpl_t;

  // ResourceInlineWrite (iw): Vertex inline write. The floats stay in the execbuffer.
  typedef struct packed {
    logic valid;
    logic [31:0] resource;
    logic [31:0] nbytes;
    logic [31:0] next;
  } apu_vgpu_iw_t;

  // VertexBuffersSet (vb) status.
  typedef enum logic [1:0] {
    APU_VGPU_VB_OK    = 2'd0,
    APU_VGPU_VB_EMPTY = 2'd1,
    APU_VGPU_VB_FAULT = 2'd2
  } apu_vgpu_vb_status_e;

  // VertexBuffersSet (vb) completion.
  typedef struct packed {
    apu_vgpu_vb_status_e status;
  } apu_vgpu_vb_cpl_t;

  // VertexBuffersSet (vb): Vertex buffer 0. This is not a vertex fetch.
  typedef struct packed {
    logic valid;
    logic [31:0] stride;
    logic [31:0] offset;
    logic [31:0] resource;
    logic [31:0] next;
  } apu_vgpu_vb_t;

  // ScissorSet (sci) status.
  typedef enum logic [1:0] {
    APU_VGPU_SCI_OK    = 2'd0,
    APU_VGPU_SCI_EMPTY = 2'd1,
    APU_VGPU_SCI_FAULT = 2'd2
  } apu_vgpu_sci_status_e;

  // ScissorSet (sci) completion.
  typedef struct packed {
    apu_vgpu_sci_status_e status;
  } apu_vgpu_sci_cpl_t;

  // ScissorSet (sci): Scissor of the 640 by 480 execbuffer. This is not a draw.
  typedef struct packed {
    logic valid;
    logic [15:0] width;
    logic [15:0] height;
    logic [31:0] next;
  } apu_vgpu_sci_t;

  // ViewportSet (vp) status.
  typedef enum logic [1:0] {
    APU_VGPU_VP_OK    = 2'd0,
    APU_VGPU_VP_EMPTY = 2'd1,
    APU_VGPU_VP_FAULT = 2'd2
  } apu_vgpu_vp_status_e;

  // ViewportSet (vp) completion.
  typedef struct packed {
    apu_vgpu_vp_status_e status;
  } apu_vgpu_vp_cpl_t;

  // ViewportSet (vp): Viewport scale of the 640 by 480 execbuffer. This is not a transform.
  typedef struct packed {
    logic valid;
    logic [31:0] scale_x;
    logic [31:0] scale_y;
    logic [31:0] next;
  } apu_vgpu_vp_t;

  // FramebufferSet (fbo) status.
  typedef enum logic [1:0] {
    APU_VGPU_FBO_OK    = 2'd0,
    APU_VGPU_FBO_EMPTY = 2'd1,
    APU_VGPU_FBO_FAULT = 2'd2
  } apu_vgpu_fbo_status_e;

  // FramebufferSet (fbo) completion.
  typedef struct packed {
    apu_vgpu_fbo_status_e status;
  } apu_vgpu_fbo_cpl_t;

  // FramebufferSet (fbo): Framebuffer state naming the surface. This does not attach memory.
  typedef struct packed {
    logic valid;
    logic [31:0] nr_cbufs;
    logic [31:0] surface;
    logic [31:0] next;
  } apu_vgpu_fbo_t;

  // ClearSet (clr) status.
  typedef enum logic [1:0] {
    APU_VGPU_CLR_OK    = 2'd0,
    APU_VGPU_CLR_EMPTY = 2'd1,
    APU_VGPU_CLR_FAULT = 2'd2
  } apu_vgpu_clr_status_e;

  // ClearSet (clr) completion.
  typedef struct packed {
    apu_vgpu_clr_status_e status;
  } apu_vgpu_clr_cpl_t;

  // ClearSet (clr): Clear color of the frozen execbuffer. This does not write pixels.
  typedef struct packed {
    logic valid;
    logic [31:0] buffers;
    logic [31:0] red;
    logic [31:0] green;
    logic [31:0] blue;
    logic [31:0] alpha;
    logic [31:0] next;
  } apu_vgpu_clr_t;

  // DrawVbo (drw) status.
  typedef enum logic [1:0] {
    APU_VGPU_DRW_OK    = 2'd0,
    APU_VGPU_DRW_EMPTY = 2'd1,
    APU_VGPU_DRW_FAULT = 2'd2
  } apu_vgpu_drw_status_e;

  // DrawVbo (drw) completion.
  typedef struct packed {
    apu_vgpu_drw_status_e status;
  } apu_vgpu_drw_cpl_t;

  // DrawVbo (drw): Draw of the four-vertex strip. This does not walk a triangle.
  typedef struct packed {
    logic valid;
    logic [31:0] count;
    logic [31:0] prim;
    logic [31:0] next;
  } apu_vgpu_drw_t;

  // ContextCreate (ctx) status.
  typedef enum logic [1:0] {
    APU_VGPU_CTX_OK    = 2'd0,
    APU_VGPU_CTX_EMPTY = 2'd1,
    APU_VGPU_CTX_FAULT = 2'd2
  } apu_vgpu_ctx_status_e;

  // ContextCreate (ctx) completion.
  typedef struct packed {
    apu_vgpu_ctx_status_e status;
  } apu_vgpu_ctx_cpl_t;

  // ContextCreate (ctx): CTX_CREATE for context 1, debug name "main". Not an OS context.
  typedef struct packed {
    logic valid;
    logic [31:0] ctx_id;
    logic [31:0] next;
  } apu_vgpu_ctx_t;

  // ResourceCreate3d (c3d) status.
  typedef enum logic [1:0] {
    APU_VGPU_C3D_OK    = 2'd0,
    APU_VGPU_C3D_EMPTY = 2'd1,
    APU_VGPU_C3D_FAULT = 2'd2
  } apu_vgpu_c3d_status_e;

  // ResourceCreate3d (c3d) completion.
  typedef struct packed {
    apu_vgpu_c3d_status_e status;
  } apu_vgpu_c3d_cpl_t;

  // ResourceCreate3d (c3d): RESOURCE_CREATE_3D for the render target and the vertex buffer.
  // This does not allocate memory.
  typedef struct packed {
    logic rt_valid;
    logic vbo_valid;
    logic [31:0] rt_w;
    logic [31:0] rt_h;
    logic [31:0] vbo_bytes;
    logic [31:0] next;
  } apu_vgpu_c3d_t;

  // ContextAttach (att) status.
  typedef enum logic [1:0] {
    APU_VGPU_ATT_OK    = 2'd0,
    APU_VGPU_ATT_EMPTY = 2'd1,
    APU_VGPU_ATT_FAULT = 2'd2
  } apu_vgpu_att_status_e;

  // ContextAttach (att) completion.
  typedef struct packed {
    apu_vgpu_att_status_e status;
  } apu_vgpu_att_cpl_t;

  // ContextAttach (att): CTX_ATTACH of the render target, the vertex buffer, and resource 1.
  // This does not map guest memory.
  typedef struct packed {
    logic rt;
    logic vbo;
    logic scan;
    logic [31:0] next;
  } apu_vgpu_att_t;

  // SceneResponse (rsp) status.
  typedef enum logic [1:0] {
    APU_VGPU_RSP_OK    = 2'd0,
    APU_VGPU_RSP_EMPTY = 2'd1,
    APU_VGPU_RSP_FAULT = 2'd2,
    APU_VGPU_RSP_BUS   = 2'd3
  } apu_vgpu_rsp_status_e;

  // SceneResponse (rsp) completion.
  typedef struct packed {
    apu_vgpu_rsp_status_e status;
    logic [63:0] addr;
    logic [31:0] ctx_id;
  } apu_vgpu_rsp_cpl_t;

  // SceneResponse (rsp): The 24-byte submit response. This does not store a pixel.
  typedef struct packed {
    logic valid;
    logic [63:0] addr;
    logic [31:0] ctx_id;
    logic [63:0] fence;
  } apu_vgpu_rsp_t;

  // CapsetInfo (nfo) status.
  typedef enum logic [1:0] {
    APU_VGPU_NFO_OK    = 2'd0,
    APU_VGPU_NFO_EMPTY = 2'd1,
    APU_VGPU_NFO_FAULT = 2'd2
  } apu_vgpu_nfo_status_e;

  // CapsetInfo (nfo) completion.
  typedef struct packed {
    apu_vgpu_nfo_status_e status;
  } apu_vgpu_nfo_cpl_t;

  // CapsetInfo (nfo): GET_CAPSET_INFO index 0. refused means the answer is no capset.
  typedef struct packed {
    logic refused;
    logic [31:0] resp;
    logic [31:0] next;
  } apu_vgpu_nfo_t;

  // CapsetGet (cap) status.
  typedef enum logic [1:0] {
    APU_VGPU_CAP_OK    = 2'd0,
    APU_VGPU_CAP_EMPTY = 2'd1,
    APU_VGPU_CAP_FAULT = 2'd2
  } apu_vgpu_cap_status_e;

  // CapsetGet (cap) completion.
  typedef struct packed {
    apu_vgpu_cap_status_e status;
  } apu_vgpu_cap_cpl_t;

  // CapsetGet (cap): GET_CAPSET for virgl version 1. refused means no blob is returned.
  typedef struct packed {
    logic refused;
    logic [31:0] resp;
    logic [31:0] next;
  } apu_vgpu_cap_t;

  // ScanoutSet (scn) status.
  typedef enum logic [1:0] {
    APU_VGPU_SCN_OK    = 2'd0,
    APU_VGPU_SCN_EMPTY = 2'd1,
    APU_VGPU_SCN_FAULT = 2'd2
  } apu_vgpu_scn_status_e;

  // ScanoutSet (scn) completion.
  typedef struct packed {
    apu_vgpu_scn_status_e status;
  } apu_vgpu_scn_cpl_t;

  // ScanoutSet (scn): SET_SCANOUT of resource 4 at 640 by 480. This is not a HDMI mode.
  typedef struct packed {
    logic valid;
    logic [31:0] scanout_id;
    logic [31:0] resource_id;
    logic [31:0] width;
    logic [31:0] height;
    logic [31:0] next;
  } apu_vgpu_scn_t;

  // ResourceFlush (flu) status.
  typedef enum logic [1:0] {
    APU_VGPU_FLU_OK    = 2'd0,
    APU_VGPU_FLU_EMPTY = 2'd1,
    APU_VGPU_FLU_FAULT = 2'd2
  } apu_vgpu_flu_status_e;

  // ResourceFlush (flu) completion.
  typedef struct packed {
    apu_vgpu_flu_status_e status;
  } apu_vgpu_flu_cpl_t;

  // ResourceFlush (flu): RESOURCE_FLUSH of that scanout rectangle. This does not present a frame.
  typedef struct packed {
    logic valid;
    logic [31:0] resource_id;
    logic [31:0] width;
    logic [31:0] height;
    logic [31:0] next;
  } apu_vgpu_flu_t;

  // SceneChain (chn) op.
  typedef enum logic [1:0] {
    APU_VGPU_CHN_POST  = 2'd0,
    APU_VGPU_CHN_AVAIL = 2'd1,
    APU_VGPU_CHN_WALK  = 2'd2
  } apu_vgpu_chn_op_e;

  // SceneChain (chn) request.
  typedef struct packed {
    apu_vgpu_chn_op_e op;
    logic [15:0] avail_idx;
    logic [15:0] desc_id;
    apu_vgpu_desc_t desc;
  } apu_vgpu_chn_req_t;

  // SceneChain (chn) status.
  typedef enum logic [1:0] {
    APU_VGPU_CHN_OK    = 2'd0,
    APU_VGPU_CHN_EMPTY = 2'd1,
    APU_VGPU_CHN_FAULT = 2'd2
  } apu_vgpu_chn_status_e;

  // SceneChain (chn) completion.
  typedef struct packed {
    apu_vgpu_chn_status_e status;
  } apu_vgpu_chn_cpl_t;

  // SceneChain (chn): One accepted scene chain. Head is descriptor 0. This does not read
  // guest memory and it is not g6lc_apu_vgpu_avail.
  typedef struct packed {
    logic valid;
    logic [15:0] head;
    logic [31:0] buf_len;
    logic [63:0] buf_addr;
    logic [63:0] rsp_addr;
    logic [15:0] device_idx;
  } apu_vgpu_chn_t;

  // SceneChainMatch (cmx) status.
  typedef enum logic [1:0] {
    APU_VGPU_CMX_OK    = 2'd0,
    APU_VGPU_CMX_EMPTY = 2'd1,
    APU_VGPU_CMX_FAULT = 2'd2
  } apu_vgpu_cmx_status_e;

  // SceneChainMatch (cmx) completion.
  typedef struct packed {
    apu_vgpu_cmx_status_e status;
  } apu_vgpu_cmx_cpl_t;

  // SceneChainMatch (cmx): The chain, the submit record, and the response name the same buffer.
  typedef struct packed {
    logic linked;
  } apu_vgpu_cmx_t;

  // SceneUsedLocal (sun) status.
  typedef enum logic [1:0] {
    APU_VGPU_SUN_OK    = 2'd0,
    APU_VGPU_SUN_EMPTY = 2'd1,
    APU_VGPU_SUN_FAULT = 2'd2
  } apu_vgpu_sun_status_e;

  // SceneUsedLocal (sun) completion.
  typedef struct packed {
    apu_vgpu_sun_status_e status;
  } apu_vgpu_sun_cpl_t;

  // SceneUsedLocal (sun): Local used element for descriptor 0, length 24. Not a guest store
  // and not g6lc_apu_vgpu_used.
  typedef struct packed {
    logic valid;
    logic [15:0] idx;
    logic [31:0] desc_id;
    logic [31:0] len;
  } apu_vgpu_sun_t;

  // SceneUsedWrite (suw) status.
  typedef enum logic [1:0] {
    APU_VGPU_SUW_OK    = 2'd0,
    APU_VGPU_SUW_EMPTY = 2'd1,
    APU_VGPU_SUW_FAULT = 2'd2,
    APU_VGPU_SUW_BUS   = 2'd3
  } apu_vgpu_suw_status_e;

  // SceneUsedWrite (suw) completion.
  typedef struct packed {
    apu_vgpu_suw_status_e status;
    logic [31:0] elem_id;
    logic [31:0] elem_len;
    logic [63:0] addr;
  } apu_vgpu_suw_cpl_t;

  // SceneUsedWrite (suw): Guest store of the scene used element. Not g6lc_apu_vgpu_uwr.
  typedef struct packed {
    logic wrote;
    logic [63:0] addr;
  } apu_vgpu_suw_t;

  // SceneUsedIndex (sux) status.
  typedef enum logic [1:0] {
    APU_VGPU_SUX_OK    = 2'd0,
    APU_VGPU_SUX_EMPTY = 2'd1,
    APU_VGPU_SUX_FAULT = 2'd2,
    APU_VGPU_SUX_BUS   = 2'd3
  } apu_vgpu_sux_status_e;

  // SceneUsedIndex (sux) completion.
  typedef struct packed {
    apu_vgpu_sux_status_e status;
    logic [15:0] idx;
    logic [63:0] addr;
  } apu_vgpu_sux_cpl_t;

  // SceneUsedIndex (sux): Guest store of the scene used.idx. Not g6lc_apu_vgpu_uidx.
  typedef struct packed {
    logic wrote;
    logic [15:0] idx;
    logic [63:0] addr;
  } apu_vgpu_sux_t;

  // ClearToRgba8 (u8) status.
  typedef enum logic [1:0] {
    APU_VGPU_U8_OK    = 2'd0,
    APU_VGPU_U8_EMPTY = 2'd1,
    APU_VGPU_U8_FAULT = 2'd2
  } apu_vgpu_u8_status_e;

  // ClearToRgba8 (u8) completion.
  typedef struct packed {
    apu_vgpu_u8_status_e status;
  } apu_vgpu_u8_cpl_t;

  // ClearToRgba8 (u8): RGBA8 bytes of the frozen clear. Not a stored pixel.
  typedef struct packed {
    logic valid;
    logic [7:0] red;
    logic [7:0] green;
    logic [7:0] blue;
    logic [7:0] alpha;
    logic [31:0] word;
  } apu_vgpu_u8_t;

  // ClearCorners (pix) status.
  typedef enum logic [1:0] {
    APU_VGPU_PIX_OK    = 2'd0,
    APU_VGPU_PIX_EMPTY = 2'd1,
    APU_VGPU_PIX_FAULT = 2'd2
  } apu_vgpu_pix_status_e;

  // ClearCorners (pix) completion.
  typedef struct packed {
    apu_vgpu_pix_status_e status;
  } apu_vgpu_pix_cpl_t;

  // ClearCorners (pix): Four corner samples. The interior is not written.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [13:0] a00;
    logic [13:0] ax;
    logic [13:0] ay;
    logic [13:0] axy;
  } apu_vgpu_pix_t;

  // ClearCornerRead (pxr) status.
  typedef enum logic [1:0] {
    APU_VGPU_PXR_OK    = 2'd0,
    APU_VGPU_PXR_EMPTY = 2'd1,
    APU_VGPU_PXR_MISS  = 2'd2,
    APU_VGPU_PXR_FAULT = 2'd3
  } apu_vgpu_pxr_status_e;

  // ClearCornerRead (pxr) completion.
  typedef struct packed {
    apu_vgpu_pxr_status_e status;
    logic [31:0] word;
    logic [13:0] addr;
  } apu_vgpu_pxr_cpl_t;

  // ClearCeilingFill (fil) status.
  typedef enum logic [1:0] {
    APU_VGPU_FIL_OK    = 2'd0,
    APU_VGPU_FIL_EMPTY = 2'd1,
    APU_VGPU_FIL_FAULT = 2'd2
  } apu_vgpu_fil_status_e;

  // ClearCeilingFill (fil) completion.
  typedef struct packed {
    apu_vgpu_fil_status_e status;
  } apu_vgpu_fil_cpl_t;

  // ClearCeilingFill (fil): The clear word covers the ceiling. Samples are not stored one by one.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [31:0] samples;
  } apu_vgpu_fil_t;

  // ClearCeilingRead (frd) status.
  typedef enum logic [1:0] {
    APU_VGPU_FRD_OK    = 2'd0,
    APU_VGPU_FRD_EMPTY = 2'd1,
    APU_VGPU_FRD_FAULT = 2'd2
  } apu_vgpu_frd_status_e;

  // ClearCeilingRead (frd) completion.
  typedef struct packed {
    apu_vgpu_frd_status_e status;
    logic [31:0] word;
    logic [13:0] addr;
  } apu_vgpu_frd_cpl_t;

  // QuadFloats (qd) status.
  typedef enum logic [1:0] {
    APU_VGPU_QD_OK    = 2'd0,
    APU_VGPU_QD_EMPTY = 2'd1,
    APU_VGPU_QD_FAULT = 2'd2
  } apu_vgpu_qd_status_e;

  // QuadFloats (qd) completion.
  typedef struct packed {
    apu_vgpu_qd_status_e status;
  } apu_vgpu_qd_cpl_t;

  // QuadFloats (qd): The fullscreen NDC strip. Positions were checked. Not a transform.
  typedef struct packed {
    logic valid;
  } apu_vgpu_qd_t;

  // QuadCoverage (cv) status.
  typedef enum logic [1:0] {
    APU_VGPU_CV_OK    = 2'd0,
    APU_VGPU_CV_EMPTY = 2'd1,
    APU_VGPU_CV_FAULT = 2'd2
  } apu_vgpu_cv_status_e;

  // QuadCoverage (cv) completion.
  typedef struct packed {
    apu_vgpu_cv_status_e status;
  } apu_vgpu_cv_cpl_t;

  // QuadCoverage (cv): The strip covers the ceiling. The stored color is still the clear.
  typedef struct packed {
    logic valid;
    logic covered;
    logic [31:0] word;
    logic [31:0] samples;
  } apu_vgpu_cv_t;

  // CoveredSample (cvr) status.
  typedef enum logic [1:0] {
    APU_VGPU_CVR_OK    = 2'd0,
    APU_VGPU_CVR_EMPTY = 2'd1,
    APU_VGPU_CVR_FAULT = 2'd2
  } apu_vgpu_cvr_status_e;

  // CoveredSample (cvr) completion.
  typedef struct packed {
    apu_vgpu_cvr_status_e status;
    logic covered;
    logic [31:0] word;
    logic [13:0] addr;
  } apu_vgpu_cvr_cpl_t;

  // VertexTgsiText (vst) status.
  typedef enum logic [1:0] {
    APU_VGPU_VST_OK    = 2'd0,
    APU_VGPU_VST_EMPTY = 2'd1,
    APU_VGPU_VST_FAULT = 2'd2
  } apu_vgpu_vst_status_e;

  // VertexTgsiText (vst) completion.
  typedef struct packed {
    apu_vgpu_vst_status_e status;
  } apu_vgpu_vst_cpl_t;

  // VertexTgsiText (vst): The vertex shader text matched. The text is not stored here.
  typedef struct packed {
    logic valid;
  } apu_vgpu_vst_t;

  // FragTgsiText (fst) status.
  typedef enum logic [1:0] {
    APU_VGPU_FST_OK    = 2'd0,
    APU_VGPU_FST_EMPTY = 2'd1,
    APU_VGPU_FST_FAULT = 2'd2
  } apu_vgpu_fst_status_e;

  // FragTgsiText (fst) completion.
  typedef struct packed {
    apu_vgpu_fst_status_e status;
  } apu_vgpu_fst_cpl_t;

  // FragTgsiText (fst): The fragment shader text matched. tex means that text is the TEX program.
  typedef struct packed {
    logic valid;
    logic tex;
  } apu_vgpu_fst_t;

  // HeldClearSample (hld) status.
  typedef enum logic [1:0] {
    APU_VGPU_HLD_OK    = 2'd0,
    APU_VGPU_HLD_EMPTY = 2'd1,
    APU_VGPU_HLD_FAULT = 2'd2
  } apu_vgpu_hld_status_e;

  // HeldClearSample (hld) completion.
  typedef struct packed {
    apu_vgpu_hld_status_e status;
    logic held;
    logic [31:0] word;
    logic [13:0] addr;
  } apu_vgpu_hld_cpl_t;

  // TexBind (tbn) status.
  typedef enum logic [1:0] {
    APU_VGPU_TBN_OK    = 2'd0,
    APU_VGPU_TBN_EMPTY = 2'd1,
    APU_VGPU_TBN_FAULT = 2'd2
  } apu_vgpu_tbn_status_e;

  // TexBind (tbn) completion.
  typedef struct packed {
    apu_vgpu_tbn_status_e status;
  } apu_vgpu_tbn_cpl_t;

  // TexBind (tbn): TEX names this sampler view and sampler state. Not a fetch.
  typedef struct packed {
    logic valid;
    logic [31:0] resource_id;
    logic [31:0] view;
    logic [31:0] sampler;
  } apu_vgpu_tbn_t;

  // TexRefused (den) status.
  typedef enum logic [1:0] {
    APU_VGPU_DEN_OK    = 2'd0,
    APU_VGPU_DEN_EMPTY = 2'd1,
    APU_VGPU_DEN_FAULT = 2'd2
  } apu_vgpu_den_status_e;

  // TexRefused (den) completion.
  typedef struct packed {
    apu_vgpu_den_status_e status;
  } apu_vgpu_den_cpl_t;

  // TexRefused (den): Resource 1 has no texel image here. The word stays the clear.
  typedef struct packed {
    logic valid;
    logic refused;
    logic [31:0] resource_id;
    logic [31:0] word;
    logic [31:0] samples;
  } apu_vgpu_den_t;

  // TexRefusedRead (dnr) status.
  typedef enum logic [1:0] {
    APU_VGPU_DNR_OK    = 2'd0,
    APU_VGPU_DNR_EMPTY = 2'd1,
    APU_VGPU_DNR_FAULT = 2'd2
  } apu_vgpu_dnr_status_e;

  // TexRefusedRead (dnr) completion.
  typedef struct packed {
    apu_vgpu_dnr_status_e status;
    logic refused;
    logic [31:0] word;
    logic [13:0] addr;
  } apu_vgpu_dnr_cpl_t;

  // ScanCreate2d (s2d) status.
  typedef enum logic [1:0] {
    APU_VGPU_S2D_OK    = 2'd0,
    APU_VGPU_S2D_EMPTY = 2'd1,
    APU_VGPU_S2D_FAULT = 2'd2
  } apu_vgpu_s2d_status_e;

  // ScanCreate2d (s2d) completion.
  typedef struct packed {
    apu_vgpu_s2d_status_e status;
  } apu_vgpu_s2d_cpl_t;

  // ScanCreate2d (s2d): Resource 1 exists as a 640 by 480 image. No pixels are stored.
  typedef struct packed {
    logic valid;
    logic [31:0] resource_id;
    logic [31:0] format;
    logic [15:0] width;
    logic [15:0] height;
  } apu_vgpu_s2d_t;

  // ScanBacking (sbk) status.
  typedef enum logic [1:0] {
    APU_VGPU_SBK_OK    = 2'd0,
    APU_VGPU_SBK_EMPTY = 2'd1,
    APU_VGPU_SBK_FAULT = 2'd2
  } apu_vgpu_sbk_status_e;

  // ScanBacking (sbk) completion.
  typedef struct packed {
    apu_vgpu_sbk_status_e status;
  } apu_vgpu_sbk_cpl_t;

  // ScanBacking (sbk): One backing entry for resource 1. The bytes are not read.
  typedef struct packed {
    logic valid;
    logic [31:0] resource_id;
    logic [31:0] addr;
    logic [31:0] length;
  } apu_vgpu_sbk_t;

  // ScanBandTransfer (sxf) status.
  typedef enum logic [1:0] {
    APU_VGPU_SXF_OK    = 2'd0,
    APU_VGPU_SXF_EMPTY = 2'd1,
    APU_VGPU_SXF_FAULT = 2'd2
  } apu_vgpu_sxf_status_e;

  // ScanBandTransfer (sxf) completion.
  typedef struct packed {
    apu_vgpu_sxf_status_e status;
  } apu_vgpu_sxf_cpl_t;

  // ScanBandTransfer (sxf): The top 64 rows were named. copied is 0. The color stays the clear.
  typedef struct packed {
    logic valid;
    logic copied;
    logic [15:0] width;
    logic [15:0] height;
    logic [31:0] word;
  } apu_vgpu_sxf_t;

  // ScanScanout (ssc) status.
  typedef enum logic [1:0] {
    APU_VGPU_SSC_OK    = 2'd0,
    APU_VGPU_SSC_EMPTY = 2'd1,
    APU_VGPU_SSC_FAULT = 2'd2
  } apu_vgpu_ssc_status_e;

  // ScanScanout (ssc) completion.
  typedef struct packed {
    apu_vgpu_ssc_status_e status;
  } apu_vgpu_ssc_cpl_t;

  // ScanScanout (ssc): Scanout 0 names resource 1 at 640 by 480. Nothing is presented.
  typedef struct packed {
    logic valid;
    logic shown;
    logic [31:0] scanout_id;
    logic [31:0] resource_id;
    logic [15:0] width;
    logic [15:0] height;
  } apu_vgpu_ssc_t;

  // ScanBandFlush (sfl) status.
  typedef enum logic [1:0] {
    APU_VGPU_SFL_OK    = 2'd0,
    APU_VGPU_SFL_EMPTY = 2'd1,
    APU_VGPU_SFL_FAULT = 2'd2
  } apu_vgpu_sfl_status_e;

  // ScanBandFlush (sfl) completion.
  typedef struct packed {
    apu_vgpu_sfl_status_e status;
  } apu_vgpu_sfl_cpl_t;

  // ScanBandFlush (sfl): Flush of the 640 by 64 band. Nothing is presented.
  typedef struct packed {
    logic valid;
    logic shown;
    logic [31:0] resource_id;
    logic [15:0] width;
    logic [15:0] height;
  } apu_vgpu_sfl_t;

  // ScanUnpresentedSample (spr) status.
  typedef enum logic [1:0] {
    APU_VGPU_SPR_OK    = 2'd0,
    APU_VGPU_SPR_EMPTY = 2'd1,
    APU_VGPU_SPR_FAULT = 2'd2
  } apu_vgpu_spr_status_e;

  // ScanUnpresentedSample (spr) completion.
  typedef struct packed {
    apu_vgpu_spr_status_e status;
    logic shown;
    logic [31:0] word;
    logic [13:0] addr;
  } apu_vgpu_spr_cpl_t;

  // BandCopy (bcp) status.
  typedef enum logic [1:0] {
    APU_VGPU_BCP_OK    = 2'd0,
    APU_VGPU_BCP_EMPTY = 2'd1,
    APU_VGPU_BCP_FAULT = 2'd2
  } apu_vgpu_bcp_status_e;

  // BandCopy (bcp) completion.
  typedef struct packed {
    apu_vgpu_bcp_status_e status;
  } apu_vgpu_bcp_cpl_t;

  // BandCopy (bcp): The band was read. The image is not stored. word is beat 0 only.
  typedef struct packed {
    logic valid;
    logic [12:0] beats;
    logic [31:0] bytes;
    logic [31:0] word;
  } apu_vgpu_bcp_t;

  // BandCopiedWord (bcr) status.
  typedef enum logic [1:0] {
    APU_VGPU_BCR_OK    = 2'd0,
    APU_VGPU_BCR_EMPTY = 2'd1,
    APU_VGPU_BCR_FAULT = 2'd2
  } apu_vgpu_bcr_status_e;

  // BandCopiedWord (bcr) completion.
  typedef struct packed {
    apu_vgpu_bcr_status_e status;
    logic [12:0] beats;
    logic [31:0] word;
    logic [31:0] scene;
  } apu_vgpu_bcr_cpl_t;

  // ClampEdgeTap (tap) status.
  typedef enum logic [1:0] {
    APU_VGPU_TAP_OK    = 2'd0,
    APU_VGPU_TAP_EMPTY = 2'd1,
    APU_VGPU_TAP_FAULT = 2'd2
  } apu_vgpu_tap_status_e;

  // ClampEdgeTap (tap) completion.
  typedef struct packed {
    apu_vgpu_tap_status_e status;
  } apu_vgpu_tap_cpl_t;

  // ClampEdgeTap (tap): One texel inside the copied band. x is clamped to 639.
  typedef struct packed {
    logic valid;
    logic [9:0] x;
    logic [5:0] y;
    logic [31:0] word;
  } apu_vgpu_tap_t;

  // CeilingOriginTexel (pxc) status.
  typedef enum logic [1:0] {
    APU_VGPU_PXC_OK    = 2'd0,
    APU_VGPU_PXC_EMPTY = 2'd1,
    APU_VGPU_PXC_FAULT = 2'd2
  } apu_vgpu_pxc_status_e;

  // CeilingOriginTexel (pxc) completion.
  typedef struct packed {
    apu_vgpu_pxc_status_e status;
  } apu_vgpu_pxc_cpl_t;

  // CeilingOriginTexel (pxc): Ceiling pixel (0,0) holds the corner texel.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
  } apu_vgpu_pxc_t;

  // CeilingOriginRead (pxq) status.
  typedef enum logic [1:0] {
    APU_VGPU_PXQ_OK    = 2'd0,
    APU_VGPU_PXQ_EMPTY = 2'd1,
    APU_VGPU_PXQ_FAULT = 2'd2
  } apu_vgpu_pxq_status_e;

  // CeilingOriginRead (pxq) completion.
  typedef struct packed {
    apu_vgpu_pxq_status_e status;
    logic replaced;
    logic [31:0] word;
    logic [13:0] addr;
  } apu_vgpu_pxq_cpl_t;

  // LinearBlend (lin) status.
  typedef enum logic [1:0] {
    APU_VGPU_LIN_OK    = 2'd0,
    APU_VGPU_LIN_EMPTY = 2'd1,
    APU_VGPU_LIN_FAULT = 2'd2
  } apu_vgpu_lin_status_e;

  // LinearBlend (lin) completion.
  typedef struct packed {
    apu_vgpu_lin_status_e status;
  } apu_vgpu_lin_cpl_t;

  // LinearBlend (lin): One horizontal blend on row 0. x = 0 is texel 0. x = 1..7 blends
  // texel x-1 with texel x.
  typedef struct packed {
    logic valid;
    logic [2:0] x;
    logic [31:0] word;
  } apu_vgpu_lin_t;

  // LinearBlendKeep (lnr) status.
  typedef enum logic [1:0] {
    APU_VGPU_LNR_OK    = 2'd0,
    APU_VGPU_LNR_EMPTY = 2'd1,
    APU_VGPU_LNR_FAULT = 2'd2
  } apu_vgpu_lnr_status_e;

  // LinearBlendKeep (lnr) completion.
  typedef struct packed {
    apu_vgpu_lnr_status_e status;
  } apu_vgpu_lnr_cpl_t;

  // LinearBlendKeep (lnr): The origin texel and the blended neighbor at x = 1.
  typedef struct packed {
    logic valid;
    logic [31:0] origin;
    logic [31:0] neighbor;
  } apu_vgpu_lnr_t;

  // SpanBlend (spn) status.
  typedef enum logic [1:0] {
    APU_VGPU_SPN_OK    = 2'd0,
    APU_VGPU_SPN_EMPTY = 2'd1,
    APU_VGPU_SPN_FAULT = 2'd2
  } apu_vgpu_spn_status_e;

  // SpanBlend (spn) completion.
  typedef struct packed {
    apu_vgpu_spn_status_e status;
  } apu_vgpu_spn_cpl_t;

  // SpanBlend (spn): A row-0 blend whose taps may sit in beat 0 and beat 1.
  typedef struct packed {
    logic valid;
    logic [3:0] x;
    logic [31:0] word;
  } apu_vgpu_spn_t;

  // SpanSample (spx) status.
  typedef enum logic [1:0] {
    APU_VGPU_SPX_OK    = 2'd0,
    APU_VGPU_SPX_EMPTY = 2'd1,
    APU_VGPU_SPX_FAULT = 2'd2
  } apu_vgpu_spx_status_e;

  // SpanSample (spx) completion.
  typedef struct packed {
    apu_vgpu_spx_status_e status;
  } apu_vgpu_spx_cpl_t;

  // SpanSample (spx): The x = 8 sample. (0,0) and (1,0) stay the earlier words.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
  } apu_vgpu_spx_t;

  // VerticalBlend (vln) status.
  typedef enum logic [1:0] {
    APU_VGPU_VLN_OK    = 2'd0,
    APU_VGPU_VLN_EMPTY = 2'd1,
    APU_VGPU_VLN_FAULT = 2'd2
  } apu_vgpu_vln_status_e;

  // VerticalBlend (vln) completion.
  typedef struct packed {
    apu_vgpu_vln_status_e status;
  } apu_vgpu_vln_cpl_t;

  // VerticalBlend (vln): y = 1 blends row 0 with row 1 at one half. x is 0 or 1.
  typedef struct packed {
    logic valid;
    logic [1:0] x;
    logic [31:0] word;
  } apu_vgpu_vln_t;

  // VerticalBlendKeep (vlr) status.
  typedef enum logic [1:0] {
    APU_VGPU_VLR_OK    = 2'd0,
    APU_VGPU_VLR_EMPTY = 2'd1,
    APU_VGPU_VLR_FAULT = 2'd2
  } apu_vgpu_vlr_status_e;

  // VerticalBlendKeep (vlr) completion.
  typedef struct packed {
    apu_vgpu_vlr_status_e status;
  } apu_vgpu_vlr_cpl_t;

  // VerticalBlendKeep (vlr): The two y = 1 samples. Row 0 stays the earlier words.
  typedef struct packed {
    logic valid;
    logic [31:0] at0;
    logic [31:0] at1;
  } apu_vgpu_vlr_t;

  // VerticalBeatBlend (vbx) status.
  typedef enum logic [1:0] {
    APU_VGPU_VBX_OK    = 2'd0,
    APU_VGPU_VBX_EMPTY = 2'd1,
    APU_VGPU_VBX_FAULT = 2'd2
  } apu_vgpu_vbx_status_e;

  // VerticalBeatBlend (vbx) completion.
  typedef struct packed {
    apu_vgpu_vbx_status_e status;
  } apu_vgpu_vbx_cpl_t;

  // VerticalBeatBlend (vbx): y = 1, x = 0..7. Both taps stay in beat 0 of row 0 and of row 1.
  typedef struct packed {
    logic valid;
    logic [2:0] x;
    logic [31:0] word;
  } apu_vgpu_vbx_t;

  // VerticalBeatSample (vbr) status.
  typedef enum logic [1:0] {
    APU_VGPU_VBR_OK    = 2'd0,
    APU_VGPU_VBR_EMPTY = 2'd1,
    APU_VGPU_VBR_FAULT = 2'd2
  } apu_vgpu_vbr_status_e;

  // VerticalBeatSample (vbr) completion.
  typedef struct packed {
    apu_vgpu_vbr_status_e status;
  } apu_vgpu_vbr_cpl_t;

  // VerticalBeatSample (vbr): The y = 1 sample at x = 2. The x = 0 and x = 1 pair stays put.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
  } apu_vgpu_vbr_t;

  // VerticalSpanBlend (vsp) status.
  typedef enum logic [1:0] {
    APU_VGPU_VSP_OK    = 2'd0,
    APU_VGPU_VSP_EMPTY = 2'd1,
    APU_VGPU_VSP_FAULT = 2'd2
  } apu_vgpu_vsp_status_e;

  // VerticalSpanBlend (vsp) completion.
  typedef struct packed {
    apu_vgpu_vsp_status_e status;
  } apu_vgpu_vsp_cpl_t;

  // VerticalSpanBlend (vsp): y = 1, x = 0..15. x = 8 reads beat 0 and beat 1 of each row.
  typedef struct packed {
    logic valid;
    logic [3:0] x;
    logic [31:0] word;
  } apu_vgpu_vsp_t;

  // VerticalSpanSample (vsx) status.
  typedef enum logic [1:0] {
    APU_VGPU_VSX_OK    = 2'd0,
    APU_VGPU_VSX_EMPTY = 2'd1,
    APU_VGPU_VSX_FAULT = 2'd2
  } apu_vgpu_vsx_status_e;

  // VerticalSpanSample (vsx) completion.
  typedef struct packed {
    apu_vgpu_vsx_status_e status;
  } apu_vgpu_vsx_cpl_t;

  // VerticalSpanSample (vsx): The y = 1 sample at x = 8. Earlier y = 1 words stay put.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
  } apu_vgpu_vsx_t;

  // Row2Blend (y2b) status.
  typedef enum logic [1:0] {
    APU_VGPU_Y2B_OK    = 2'd0,
    APU_VGPU_Y2B_EMPTY = 2'd1,
    APU_VGPU_Y2B_FAULT = 2'd2
  } apu_vgpu_y2b_status_e;

  // Row2Blend (y2b) completion.
  typedef struct packed {
    apu_vgpu_y2b_status_e status;
  } apu_vgpu_y2b_cpl_t;

  // Row2Blend (y2b): y = 2, x = 0..7. Halfway between row 1 and row 2, beat 0 only.
  typedef struct packed {
    logic valid;
    logic [2:0] x;
    logic [31:0] word;
  } apu_vgpu_y2b_t;

  // Row2BlendKeep (y2r) status.
  typedef enum logic [1:0] {
    APU_VGPU_Y2R_OK    = 2'd0,
    APU_VGPU_Y2R_EMPTY = 2'd1,
    APU_VGPU_Y2R_FAULT = 2'd2
  } apu_vgpu_y2r_status_e;

  // Row2BlendKeep (y2r) completion.
  typedef struct packed {
    apu_vgpu_y2r_status_e status;
  } apu_vgpu_y2r_cpl_t;

  // Row2BlendKeep (y2r): The two y = 2 samples. The y = 1 words stay put.
  typedef struct packed {
    logic valid;
    logic [31:0] at0;
    logic [31:0] at1;
  } apu_vgpu_y2r_t;

  // CeilingSampler (smp) status.
  typedef enum logic [1:0] {
    APU_VGPU_SMP_OK    = 2'd0,
    APU_VGPU_SMP_EMPTY = 2'd1,
    APU_VGPU_SMP_FAULT = 2'd2
  } apu_vgpu_smp_status_e;

  // CeilingSampler (smp) completion.
  typedef struct packed {
    apu_vgpu_smp_status_e status;
  } apu_vgpu_smp_cpl_t;

  // CeilingSampler (smp): One ceiling sample, x and y in 0..63. The image is not stored.
  typedef struct packed {
    logic valid;
    logic [5:0] x;
    logic [5:0] y;
    logic [31:0] word;
  } apu_vgpu_smp_t;

  // CeilingSampleCheck (smx) status.
  typedef enum logic [1:0] {
    APU_VGPU_SMX_OK    = 2'd0,
    APU_VGPU_SMX_EMPTY = 2'd1,
    APU_VGPU_SMX_FAULT = 2'd2
  } apu_vgpu_smx_status_e;

  // CeilingSampleCheck (smx) completion.
  typedef struct packed {
    apu_vgpu_smx_status_e status;
  } apu_vgpu_smx_cpl_t;

  // CeilingSampleCheck (smx): The ceiling sample at x = 0, y = 3.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
  } apu_vgpu_smx_t;

  // CeilingBeatWrite (rbf) status.
  typedef enum logic [1:0] {
    APU_VGPU_RBF_OK    = 2'd0,
    APU_VGPU_RBF_EMPTY = 2'd1,
    APU_VGPU_RBF_FAULT = 2'd2
  } apu_vgpu_rbf_status_e;

  // CeilingBeatWrite (rbf) completion.
  typedef struct packed {
    apu_vgpu_rbf_status_e status;
  } apu_vgpu_rbf_cpl_t;

  // CeilingBeatWrite (rbf): The 64 by 64 readback was written. The image is not kept here.
  typedef struct packed {
    logic valid;
    logic [31:0] word0;
    logic [31:0] bytes;
    logic [9:0] beats;
    logic [63:0] last_addr;
  } apu_vgpu_rbf_t;

  // CeilingBeatKeep (rbk) status.
  typedef enum logic [1:0] {
    APU_VGPU_RBK_OK    = 2'd0,
    APU_VGPU_RBK_EMPTY = 2'd1,
    APU_VGPU_RBK_FAULT = 2'd2
  } apu_vgpu_rbk_status_e;

  // CeilingBeatKeep (rbk) completion.
  typedef struct packed {
    apu_vgpu_rbk_status_e status;
  } apu_vgpu_rbk_cpl_t;

  // CeilingBeatKeep (rbk): Kept readback record. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] word0;
    logic [9:0] beats;
    logic [63:0] last_addr;
  } apu_vgpu_rbk_t;

  // CeilingBeatRead (rdr) status.
  typedef enum logic [1:0] {
    APU_VGPU_RDR_OK    = 2'd0,
    APU_VGPU_RDR_EMPTY = 2'd1,
    APU_VGPU_RDR_FAULT = 2'd2
  } apu_vgpu_rdr_status_e;

  // CeilingBeatRead (rdr) completion.
  typedef struct packed {
    apu_vgpu_rdr_status_e status;
  } apu_vgpu_rdr_cpl_t;

  // CeilingBeatRead (rdr): Collected ceiling. word0 is beat 0. at03 is beat 24. Image not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] word0;
    logic [31:0] at03;
    logic [9:0] beats;
  } apu_vgpu_rdr_t;

  // CeilingBeatReadKeep (rdk) status.
  typedef enum logic [1:0] {
    APU_VGPU_RDK_OK    = 2'd0,
    APU_VGPU_RDK_EMPTY = 2'd1,
    APU_VGPU_RDK_FAULT = 2'd2
  } apu_vgpu_rdk_status_e;

  // CeilingBeatReadKeep (rdk) completion.
  typedef struct packed {
    apu_vgpu_rdk_status_e status;
  } apu_vgpu_rdk_cpl_t;

  // CeilingBeatReadKeep (rdk): Kept pair from the ceiling read. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] word0;
    logic [31:0] at03;
  } apu_vgpu_rdk_t;

  // SceneFetch (fet) status.
  typedef enum logic [1:0] {
    APU_VGPU_FET_OK    = 2'd0,
    APU_VGPU_FET_EMPTY = 2'd1,
    APU_VGPU_FET_FAULT = 2'd2
  } apu_vgpu_fet_status_e;

  // SceneFetch (fet) completion.
  typedef struct packed {
    apu_vgpu_fet_status_e status;
  } apu_vgpu_fet_cpl_t;

  // SceneFetch (fet): Header type and the first execbuffer word. The 960 bytes are not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] kind;
    logic [31:0] cmd0;
    logic [5:0] beats;
  } apu_vgpu_fet_t;

  // SceneFetchKeep (fek) status.
  typedef enum logic [1:0] {
    APU_VGPU_FEK_OK    = 2'd0,
    APU_VGPU_FEK_EMPTY = 2'd1,
    APU_VGPU_FEK_FAULT = 2'd2
  } apu_vgpu_fek_status_e;

  // SceneFetchKeep (fek) completion.
  typedef struct packed {
    apu_vgpu_fek_status_e status;
  } apu_vgpu_fek_cpl_t;

  // SceneFetchKeep (fek): Kept submit type and first command. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] kind;
    logic [31:0] cmd0;
  } apu_vgpu_fek_t;

  // DrawVboRead (drd) status.
  typedef enum logic [1:0] {
    APU_VGPU_DRD_OK    = 2'd0,
    APU_VGPU_DRD_EMPTY = 2'd1,
    APU_VGPU_DRD_FAULT = 2'd2
  } apu_vgpu_drd_status_e;

  // DrawVboRead (drd) completion.
  typedef struct packed {
    apu_vgpu_drd_status_e status;
  } apu_vgpu_drd_cpl_t;

  // DrawVboRead (drd): Vertex count and primitive of the fetched DRAW_VBO. The draw is not executed.
  typedef struct packed {
    logic valid;
    logic [31:0] count;
    logic [31:0] prim;
  } apu_vgpu_drd_t;

  // DrawVboReadKeep (drk) status.
  typedef enum logic [1:0] {
    APU_VGPU_DRK_OK    = 2'd0,
    APU_VGPU_DRK_EMPTY = 2'd1,
    APU_VGPU_DRK_FAULT = 2'd2
  } apu_vgpu_drk_status_e;

  // DrawVboReadKeep (drk) completion.
  typedef struct packed {
    apu_vgpu_drk_status_e status;
  } apu_vgpu_drk_cpl_t;

  // DrawVboReadKeep (drk): Kept count and primitive. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] count;
    logic [31:0] prim;
  } apu_vgpu_drk_t;

  // NdcFloatsRead (qdr) status.
  typedef enum logic [1:0] {
    APU_VGPU_QDR_OK    = 2'd0,
    APU_VGPU_QDR_EMPTY = 2'd1,
    APU_VGPU_QDR_FAULT = 2'd2
  } apu_vgpu_qdr_status_e;

  // NdcFloatsRead (qdr) completion.
  typedef struct packed {
    apu_vgpu_qdr_status_e status;
  } apu_vgpu_qdr_cpl_t;

  // NdcFloatsRead (qdr): First and last float of the fetched NDC strip. The floats are not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] x0;
    logic [31:0] last;
  } apu_vgpu_qdr_t;

  // NdcFloatsKeep (qdk) status.
  typedef enum logic [1:0] {
    APU_VGPU_QDK_OK    = 2'd0,
    APU_VGPU_QDK_EMPTY = 2'd1,
    APU_VGPU_QDK_FAULT = 2'd2
  } apu_vgpu_qdk_status_e;

  // NdcFloatsKeep (qdk) completion.
  typedef struct packed {
    apu_vgpu_qdk_status_e status;
  } apu_vgpu_qdk_cpl_t;

  // NdcFloatsKeep (qdk): Kept endpoints. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] x0;
    logic [31:0] last;
  } apu_vgpu_qdk_t;

  // ViewportRead (vwx) status.
  typedef enum logic [1:0] {
    APU_VGPU_VWX_OK    = 2'd0,
    APU_VGPU_VWX_EMPTY = 2'd1,
    APU_VGPU_VWX_FAULT = 2'd2
  } apu_vgpu_vwx_status_e;

  // ViewportRead (vwx) completion.
  typedef struct packed {
    apu_vgpu_vwx_status_e status;
  } apu_vgpu_vwx_cpl_t;

  // ViewportRead (vwx): Frozen ±1 square through scales 320 and 240. Not a float multiply.
  typedef struct packed {
    logic valid;
    logic [31:0] scale_x;
    logic [31:0] scale_y;
    logic [15:0] x_neg;
    logic [15:0] y_neg;
    logic [15:0] x_pos;
    logic [15:0] y_pos;
  } apu_vgpu_vwx_t;

  // ViewportReadKeep (vwk) status.
  typedef enum logic [1:0] {
    APU_VGPU_VWK_OK    = 2'd0,
    APU_VGPU_VWK_EMPTY = 2'd1,
    APU_VGPU_VWK_FAULT = 2'd2
  } apu_vgpu_vwk_status_e;

  // ViewportReadKeep (vwk) completion.
  typedef struct packed {
    apu_vgpu_vwk_status_e status;
  } apu_vgpu_vwk_cpl_t;

  // ViewportReadKeep (vwk): Kept scales and window edges. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] scale_x;
    logic [31:0] scale_y;
    logic [15:0] x_neg;
    logic [15:0] y_neg;
    logic [15:0] x_pos;
    logic [15:0] y_pos;
  } apu_vgpu_vwk_t;

  // ScissorRead (cxr) status.
  typedef enum logic [1:0] {
    APU_VGPU_CXR_OK    = 2'd0,
    APU_VGPU_CXR_EMPTY = 2'd1,
    APU_VGPU_CXR_FAULT = 2'd2
  } apu_vgpu_cxr_status_e;

  // ScissorRead (cxr) completion.
  typedef struct packed {
    apu_vgpu_cxr_status_e status;
  } apu_vgpu_cxr_cpl_t;

  // ScissorRead (cxr): Scissor box matched to the window edges. No pixel is clipped.
  typedef struct packed {
    logic valid;
    logic [15:0] width;
    logic [15:0] height;
  } apu_vgpu_cxr_t;

  // ScissorReadKeep (cxk) status.
  typedef enum logic [1:0] {
    APU_VGPU_CXK_OK    = 2'd0,
    APU_VGPU_CXK_EMPTY = 2'd1,
    APU_VGPU_CXK_FAULT = 2'd2
  } apu_vgpu_cxk_status_e;

  // ScissorReadKeep (cxk) completion.
  typedef struct packed {
    apu_vgpu_cxk_status_e status;
  } apu_vgpu_cxk_cpl_t;

  // ScissorReadKeep (cxk): Kept scissor width and height. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [15:0] width;
    logic [15:0] height;
  } apu_vgpu_cxk_t;

  // ClearColorRead (cwr) status.
  typedef enum logic [1:0] {
    APU_VGPU_CWR_OK    = 2'd0,
    APU_VGPU_CWR_EMPTY = 2'd1,
    APU_VGPU_CWR_FAULT = 2'd2
  } apu_vgpu_cwr_status_e;

  // ClearColorRead (cwr) completion.
  typedef struct packed {
    apu_vgpu_cwr_status_e status;
  } apu_vgpu_cwr_cpl_t;

  // ClearColorRead (cwr): Clear color of the fetched command. The word is not a pixel store.
  typedef struct packed {
    logic valid;
    logic [31:0] red;
    logic [31:0] blue;
    logic [31:0] word;
  } apu_vgpu_cwr_t;

  // ClearColorReadKeep (cwk) status.
  typedef enum logic [1:0] {
    APU_VGPU_CWK_OK    = 2'd0,
    APU_VGPU_CWK_EMPTY = 2'd1,
    APU_VGPU_CWK_FAULT = 2'd2
  } apu_vgpu_cwk_status_e;

  // ClearColorReadKeep (cwk) completion.
  typedef struct packed {
    apu_vgpu_cwk_status_e status;
  } apu_vgpu_cwk_cpl_t;

  // ClearColorReadKeep (cwk): Kept red, blue, and the packed word. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] red;
    logic [31:0] blue;
    logic [31:0] word;
  } apu_vgpu_cwk_t;

  // FramebufferRead (fbr) status.
  typedef enum logic [1:0] {
    APU_VGPU_FBR_OK    = 2'd0,
    APU_VGPU_FBR_EMPTY = 2'd1,
    APU_VGPU_FBR_FAULT = 2'd2
  } apu_vgpu_fbr_status_e;

  // FramebufferRead (fbr) completion.
  typedef struct packed {
    apu_vgpu_fbr_status_e status;
  } apu_vgpu_fbr_cpl_t;

  // FramebufferRead (fbr): One color buffer, surface 1, and the accepted clear word.
  // This does not attach memory.
  typedef struct packed {
    logic valid;
    logic [31:0] nr_cbufs;
    logic [31:0] surface;
    logic [31:0] word;
  } apu_vgpu_fbr_t;

  // FramebufferReadKeep (fbk) status.
  typedef enum logic [1:0] {
    APU_VGPU_FBK_OK    = 2'd0,
    APU_VGPU_FBK_EMPTY = 2'd1,
    APU_VGPU_FBK_FAULT = 2'd2
  } apu_vgpu_fbk_status_e;

  // FramebufferReadKeep (fbk) completion.
  typedef struct packed {
    apu_vgpu_fbk_status_e status;
  } apu_vgpu_fbk_cpl_t;

  // FramebufferReadKeep (fbk): Kept buffer count, surface, and clear word. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] nr_cbufs;
    logic [31:0] surface;
    logic [31:0] word;
  } apu_vgpu_fbk_t;

  // VertexBufferRead (vbf) status.
  typedef enum logic [1:0] {
    APU_VGPU_VBF_OK    = 2'd0,
    APU_VGPU_VBF_EMPTY = 2'd1,
    APU_VGPU_VBF_FAULT = 2'd2
  } apu_vgpu_vbf_status_e;

  // VertexBufferRead (vbf) completion.
  typedef struct packed {
    apu_vgpu_vbf_status_e status;
  } apu_vgpu_vbf_cpl_t;

  // VertexBufferRead (vbf): Stride 24, offset 0, resource 3. This does not fetch vertices.
  typedef struct packed {
    logic valid;
    logic [31:0] stride;
    logic [31:0] offset;
    logic [31:0] resource;
  } apu_vgpu_vbf_t;

  // VertexBufferReadKeep (vbk) status.
  typedef enum logic [1:0] {
    APU_VGPU_VBK_OK    = 2'd0,
    APU_VGPU_VBK_EMPTY = 2'd1,
    APU_VGPU_VBK_FAULT = 2'd2
  } apu_vgpu_vbk_status_e;

  // VertexBufferReadKeep (vbk) completion.
  typedef struct packed {
    apu_vgpu_vbk_status_e status;
  } apu_vgpu_vbk_cpl_t;

  // VertexBufferReadKeep (vbk): Kept stride, offset, and resource. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] stride;
    logic [31:0] offset;
    logic [31:0] resource;
  } apu_vgpu_vbk_t;

  // InlineWriteRead (iwr) status.
  typedef enum logic [1:0] {
    APU_VGPU_IWR_OK    = 2'd0,
    APU_VGPU_IWR_EMPTY = 2'd1,
    APU_VGPU_IWR_FAULT = 2'd2
  } apu_vgpu_iwr_status_e;

  // InlineWriteRead (iwr) completion.
  typedef struct packed {
    apu_vgpu_iwr_status_e status;
  } apu_vgpu_iwr_cpl_t;

  // InlineWriteRead (iwr): Inline-write resource and byte count. The floats are not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] resource;
    logic [31:0] nbytes;
  } apu_vgpu_iwr_t;

  // InlineWriteReadKeep (iwk) status.
  typedef enum logic [1:0] {
    APU_VGPU_IWK_OK    = 2'd0,
    APU_VGPU_IWK_EMPTY = 2'd1,
    APU_VGPU_IWK_FAULT = 2'd2
  } apu_vgpu_iwk_status_e;

  // InlineWriteReadKeep (iwk) completion.
  typedef struct packed {
    apu_vgpu_iwk_status_e status;
  } apu_vgpu_iwk_cpl_t;

  // InlineWriteReadKeep (iwk): Kept resource and byte count. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] resource;
    logic [31:0] nbytes;
  } apu_vgpu_iwk_t;

  // SamplerViewRead (svr) status.
  typedef enum logic [1:0] {
    APU_VGPU_SVR_OK    = 2'd0,
    APU_VGPU_SVR_EMPTY = 2'd1,
    APU_VGPU_SVR_FAULT = 2'd2
  } apu_vgpu_svr_status_e;

  // SamplerViewRead (svr) completion.
  typedef struct packed {
    apu_vgpu_svr_status_e status;
  } apu_vgpu_svr_cpl_t;

  // SamplerViewRead (svr): Fragment stage, slot 0, sampler-view handle 5. No texture is bound.
  typedef struct packed {
    logic valid;
    logic [31:0] stage;
    logic [31:0] slot;
    logic [31:0] handle;
  } apu_vgpu_svr_t;

  // SamplerViewReadKeep (svk) status.
  typedef enum logic [1:0] {
    APU_VGPU_SVK_OK    = 2'd0,
    APU_VGPU_SVK_EMPTY = 2'd1,
    APU_VGPU_SVK_FAULT = 2'd2
  } apu_vgpu_svk_status_e;

  // SamplerViewReadKeep (svk) completion.
  typedef struct packed {
    apu_vgpu_svk_status_e status;
  } apu_vgpu_svk_cpl_t;

  // SamplerViewReadKeep (svk): Kept stage, slot, and handle. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] stage;
    logic [31:0] slot;
    logic [31:0] handle;
  } apu_vgpu_svk_t;

  // SamplerStateRead (ssr) status.
  typedef enum logic [1:0] {
    APU_VGPU_SSR_OK    = 2'd0,
    APU_VGPU_SSR_EMPTY = 2'd1,
    APU_VGPU_SSR_FAULT = 2'd2
  } apu_vgpu_ssr_status_e;

  // SamplerStateRead (ssr) completion.
  typedef struct packed {
    apu_vgpu_ssr_status_e status;
  } apu_vgpu_ssr_cpl_t;

  // SamplerStateRead (ssr): Fragment stage, slot 0, sampler-state handle 6. No texture is bound.
  typedef struct packed {
    logic valid;
    logic [31:0] stage;
    logic [31:0] slot;
    logic [31:0] handle;
  } apu_vgpu_ssr_t;

  // SamplerStateReadKeep (ssk) status.
  typedef enum logic [1:0] {
    APU_VGPU_SSK_OK    = 2'd0,
    APU_VGPU_SSK_EMPTY = 2'd1,
    APU_VGPU_SSK_FAULT = 2'd2
  } apu_vgpu_ssk_status_e;

  // SamplerStateReadKeep (ssk) completion.
  typedef struct packed {
    apu_vgpu_ssk_status_e status;
  } apu_vgpu_ssk_cpl_t;

  // SamplerStateReadKeep (ssk): Kept stage, slot, and handle. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] stage;
    logic [31:0] slot;
    logic [31:0] handle;
  } apu_vgpu_ssk_t;

  // VertexElementBindRead (ver) status.
  typedef enum logic [1:0] {
    APU_VGPU_VER_OK    = 2'd0,
    APU_VGPU_VER_EMPTY = 2'd1,
    APU_VGPU_VER_FAULT = 2'd2
  } apu_vgpu_ver_status_e;

  // VertexElementBindRead (ver) completion.
  typedef struct packed {
    apu_vgpu_ver_status_e status;
  } apu_vgpu_ver_cpl_t;

  // VertexElementBindRead (ver): Vertex-element header and handle 4. No vertices are fetched.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_ver_t;

  // VertexElementBindReadKeep (vek) status.
  typedef enum logic [1:0] {
    APU_VGPU_VEK_OK    = 2'd0,
    APU_VGPU_VEK_EMPTY = 2'd1,
    APU_VGPU_VEK_FAULT = 2'd2
  } apu_vgpu_vek_status_e;

  // VertexElementBindReadKeep (vek) completion.
  typedef struct packed {
    apu_vgpu_vek_status_e status;
  } apu_vgpu_vek_cpl_t;

  // VertexElementBindReadKeep (vek): Kept header and handle. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_vek_t;

  // FragShaderBindRead (fsr) status.
  typedef enum logic [1:0] {
    APU_VGPU_FSR_OK    = 2'd0,
    APU_VGPU_FSR_EMPTY = 2'd1,
    APU_VGPU_FSR_FAULT = 2'd2
  } apu_vgpu_fsr_status_e;

  // FragShaderBindRead (fsr) completion.
  typedef struct packed {
    apu_vgpu_fsr_status_e status;
  } apu_vgpu_fsr_cpl_t;

  // FragShaderBindRead (fsr): Fragment shader handle 3 and fragment stage. The shader is not run.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] stage;
  } apu_vgpu_fsr_t;

  // FragShaderBindReadKeep (fsk) status.
  typedef enum logic [1:0] {
    APU_VGPU_FSK_OK    = 2'd0,
    APU_VGPU_FSK_EMPTY = 2'd1,
    APU_VGPU_FSK_FAULT = 2'd2
  } apu_vgpu_fsk_status_e;

  // FragShaderBindReadKeep (fsk) completion.
  typedef struct packed {
    apu_vgpu_fsk_status_e status;
  } apu_vgpu_fsk_cpl_t;

  // FragShaderBindReadKeep (fsk): Kept handle and stage. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] stage;
  } apu_vgpu_fsk_t;

  // VertexShaderBindRead (vsr) status.
  typedef enum logic [1:0] {
    APU_VGPU_VSR_OK    = 2'd0,
    APU_VGPU_VSR_EMPTY = 2'd1,
    APU_VGPU_VSR_FAULT = 2'd2
  } apu_vgpu_vsr_status_e;

  // VertexShaderBindRead (vsr) completion.
  typedef struct packed {
    apu_vgpu_vsr_status_e status;
  } apu_vgpu_vsr_cpl_t;

  // VertexShaderBindRead (vsr): Vertex shader handle 2 and vertex stage. The shader is not run.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] stage;
  } apu_vgpu_vsr_t;

  // VertexShaderBindReadKeep (vsk) status.
  typedef enum logic [1:0] {
    APU_VGPU_VSK_OK    = 2'd0,
    APU_VGPU_VSK_EMPTY = 2'd1,
    APU_VGPU_VSK_FAULT = 2'd2
  } apu_vgpu_vsk_status_e;

  // VertexShaderBindReadKeep (vsk) completion.
  typedef struct packed {
    apu_vgpu_vsk_status_e status;
  } apu_vgpu_vsk_cpl_t;

  // VertexShaderBindReadKeep (vsk): Kept handle and stage. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] stage;
  } apu_vgpu_vsk_t;

  // RasterizerBindRead (rzr) status.
  typedef enum logic [1:0] {
    APU_VGPU_RZR_OK    = 2'd0,
    APU_VGPU_RZR_EMPTY = 2'd1,
    APU_VGPU_RZR_FAULT = 2'd2
  } apu_vgpu_rzr_status_e;

  // RasterizerBindRead (rzr) completion.
  typedef struct packed {
    apu_vgpu_rzr_status_e status;
  } apu_vgpu_rzr_cpl_t;

  // RasterizerBindRead (rzr): Rasterizer bind header and handle 9. No triangle is walked.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_rzr_t;

  // RasterizerBindReadKeep (rzk) status.
  typedef enum logic [1:0] {
    APU_VGPU_RZK_OK    = 2'd0,
    APU_VGPU_RZK_EMPTY = 2'd1,
    APU_VGPU_RZK_FAULT = 2'd2
  } apu_vgpu_rzk_status_e;

  // RasterizerBindReadKeep (rzk) completion.
  typedef struct packed {
    apu_vgpu_rzk_status_e status;
  } apu_vgpu_rzk_cpl_t;

  // RasterizerBindReadKeep (rzk): Kept header and handle. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_rzk_t;

  // DepthStencilBindRead (dbr) status.
  typedef enum logic [1:0] {
    APU_VGPU_DBR_OK    = 2'd0,
    APU_VGPU_DBR_EMPTY = 2'd1,
    APU_VGPU_DBR_FAULT = 2'd2
  } apu_vgpu_dbr_status_e;

  // DepthStencilBindRead (dbr) completion.
  typedef struct packed {
    apu_vgpu_dbr_status_e status;
  } apu_vgpu_dbr_cpl_t;

  // DepthStencilBindRead (dbr): Depth-stencil bind header and handle 8. No depth test is run.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_dbr_t;

  // DepthStencilBindReadKeep (dbk) status.
  typedef enum logic [1:0] {
    APU_VGPU_DBK_OK    = 2'd0,
    APU_VGPU_DBK_EMPTY = 2'd1,
    APU_VGPU_DBK_FAULT = 2'd2
  } apu_vgpu_dbk_status_e;

  // DepthStencilBindReadKeep (dbk) completion.
  typedef struct packed {
    apu_vgpu_dbk_status_e status;
  } apu_vgpu_dbk_cpl_t;

  // DepthStencilBindReadKeep (dbk): Kept header and handle. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_dbk_t;

  // BlendBindRead (bbr) status.
  typedef enum logic [1:0] {
    APU_VGPU_BBR_OK    = 2'd0,
    APU_VGPU_BBR_EMPTY = 2'd1,
    APU_VGPU_BBR_FAULT = 2'd2
  } apu_vgpu_bbr_status_e;

  // BlendBindRead (bbr) completion.
  typedef struct packed {
    apu_vgpu_bbr_status_e status;
  } apu_vgpu_bbr_cpl_t;

  // BlendBindRead (bbr): Blend bind header and handle 7. No blend is applied.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_bbr_t;

  // BlendBindReadKeep (bbk) status.
  typedef enum logic [1:0] {
    APU_VGPU_BBK_OK    = 2'd0,
    APU_VGPU_BBK_EMPTY = 2'd1,
    APU_VGPU_BBK_FAULT = 2'd2
  } apu_vgpu_bbk_status_e;

  // BlendBindReadKeep (bbk) completion.
  typedef struct packed {
    apu_vgpu_bbk_status_e status;
  } apu_vgpu_bbk_cpl_t;

  // BlendBindReadKeep (bbk): Kept header and handle. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_bbk_t;

  // RasterizerObjectRead (rcr) status.
  typedef enum logic [1:0] {
    APU_VGPU_RCR_OK    = 2'd0,
    APU_VGPU_RCR_EMPTY = 2'd1,
    APU_VGPU_RCR_FAULT = 2'd2
  } apu_vgpu_rcr_status_e;

  // RasterizerObjectRead (rcr) completion.
  typedef struct packed {
    apu_vgpu_rcr_status_e status;
  } apu_vgpu_rcr_cpl_t;

  // RasterizerObjectRead (rcr): Rasterizer object header and handle 9. The eight state words stay 0.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_rcr_t;

  // RasterizerObjectReadKeep (rck) status.
  typedef enum logic [1:0] {
    APU_VGPU_RCK_OK    = 2'd0,
    APU_VGPU_RCK_EMPTY = 2'd1,
    APU_VGPU_RCK_FAULT = 2'd2
  } apu_vgpu_rck_status_e;

  // RasterizerObjectReadKeep (rck) completion.
  typedef struct packed {
    apu_vgpu_rck_status_e status;
  } apu_vgpu_rck_cpl_t;

  // RasterizerObjectReadKeep (rck): Kept header and handle. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_rck_t;

  // DepthStencilObjectRead (dcr) status.
  typedef enum logic [1:0] {
    APU_VGPU_DCR_OK    = 2'd0,
    APU_VGPU_DCR_EMPTY = 2'd1,
    APU_VGPU_DCR_FAULT = 2'd2
  } apu_vgpu_dcr_status_e;

  // DepthStencilObjectRead (dcr) completion.
  typedef struct packed {
    apu_vgpu_dcr_status_e status;
  } apu_vgpu_dcr_cpl_t;

  // DepthStencilObjectRead (dcr): Depth-stencil object header and handle 8. The four state words stay 0.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_dcr_t;

  // DepthStencilObjectReadKeep (dck) status.
  typedef enum logic [1:0] {
    APU_VGPU_DCK_OK    = 2'd0,
    APU_VGPU_DCK_EMPTY = 2'd1,
    APU_VGPU_DCK_FAULT = 2'd2
  } apu_vgpu_dck_status_e;

  // DepthStencilObjectReadKeep (dck) completion.
  typedef struct packed {
    apu_vgpu_dck_status_e status;
  } apu_vgpu_dck_cpl_t;

  // DepthStencilObjectReadKeep (dck): Kept header and handle. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_dck_t;

  // BlendObjectRead (blr) status.
  typedef enum logic [1:0] {
    APU_VGPU_BLR_OK    = 2'd0,
    APU_VGPU_BLR_EMPTY = 2'd1,
    APU_VGPU_BLR_FAULT = 2'd2
  } apu_vgpu_blr_status_e;

  // BlendObjectRead (blr) completion.
  typedef struct packed {
    apu_vgpu_blr_status_e status;
  } apu_vgpu_blr_cpl_t;

  // BlendObjectRead (blr): Blend object header, handle 7, and color word. The other words stay 0.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] s2;
  } apu_vgpu_blr_t;

  // BlendObjectReadKeep (blk) status.
  typedef enum logic [1:0] {
    APU_VGPU_BLK_OK    = 2'd0,
    APU_VGPU_BLK_EMPTY = 2'd1,
    APU_VGPU_BLK_FAULT = 2'd2
  } apu_vgpu_blk_status_e;

  // BlendObjectReadKeep (blk) completion.
  typedef struct packed {
    apu_vgpu_blk_status_e status;
  } apu_vgpu_blk_cpl_t;

  // BlendObjectReadKeep (blk): Kept header, handle, and color word. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] s2;
  } apu_vgpu_blk_t;

  // SamplerStateObjectRead (scr) status.
  typedef enum logic [1:0] {
    APU_VGPU_SCR_OK    = 2'd0,
    APU_VGPU_SCR_EMPTY = 2'd1,
    APU_VGPU_SCR_FAULT = 2'd2
  } apu_vgpu_scr_status_e;

  // SamplerStateObjectRead (scr) completion.
  typedef struct packed {
    apu_vgpu_scr_status_e status;
  } apu_vgpu_scr_cpl_t;

  // SamplerStateObjectRead (scr): Sampler-state header, handle 6, wrap word, and max LOD.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] s0;
    logic [31:0] max_lod;
  } apu_vgpu_scr_t;

  // SamplerStateObjectReadKeep (sck) status.
  typedef enum logic [1:0] {
    APU_VGPU_SCK_OK    = 2'd0,
    APU_VGPU_SCK_EMPTY = 2'd1,
    APU_VGPU_SCK_FAULT = 2'd2
  } apu_vgpu_sck_status_e;

  // SamplerStateObjectReadKeep (sck) completion.
  typedef struct packed {
    apu_vgpu_sck_status_e status;
  } apu_vgpu_sck_cpl_t;

  // SamplerStateObjectReadKeep (sck): Kept header, handle, wrap word, and max LOD. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] s0;
    logic [31:0] max_lod;
  } apu_vgpu_sck_t;

  // SamplerViewObjectRead (svc) status.
  typedef enum logic [1:0] {
    APU_VGPU_SVC_OK    = 2'd0,
    APU_VGPU_SVC_EMPTY = 2'd1,
    APU_VGPU_SVC_FAULT = 2'd2
  } apu_vgpu_svc_status_e;

  // SamplerViewObjectRead (svc) completion.
  typedef struct packed {
    apu_vgpu_svc_status_e status;
  } apu_vgpu_svc_cpl_t;

  // SamplerViewObjectRead (svc): Sampler-view header, handle 5, resource, format word, and swizzle.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] resource;
    logic [31:0] format;
    logic [31:0] swizzle;
  } apu_vgpu_svc_t;

  // SamplerViewObjectReadKeep (vck) status.
  typedef enum logic [1:0] {
    APU_VGPU_VCK_OK    = 2'd0,
    APU_VGPU_VCK_EMPTY = 2'd1,
    APU_VGPU_VCK_FAULT = 2'd2
  } apu_vgpu_vck_status_e;

  // SamplerViewObjectReadKeep (vck) completion.
  typedef struct packed {
    apu_vgpu_vck_status_e status;
  } apu_vgpu_vck_cpl_t;

  // SamplerViewObjectReadKeep (vck): Kept header, handle, resource, format word, and swizzle.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] resource;
    logic [31:0] format;
    logic [31:0] swizzle;
  } apu_vgpu_vck_t;

  // VertexElementObjectRead (vec) status.
  typedef enum logic [1:0] {
    APU_VGPU_VEC_OK    = 2'd0,
    APU_VGPU_VEC_EMPTY = 2'd1,
    APU_VGPU_VEC_FAULT = 2'd2
  } apu_vgpu_vec_status_e;

  // VertexElementObjectRead (vec) completion.
  typedef struct packed {
    apu_vgpu_vec_status_e status;
  } apu_vgpu_vec_cpl_t;

  // VertexElementObjectRead (vec): Vertex-element header, handle 4, and the two element offsets and formats.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] off0;
    logic [31:0] fmt0;
    logic [31:0] off1;
    logic [31:0] fmt1;
  } apu_vgpu_vec_t;

  // VertexElementObjectReadKeep (vce) status.
  typedef enum logic [1:0] {
    APU_VGPU_VCE_OK    = 2'd0,
    APU_VGPU_VCE_EMPTY = 2'd1,
    APU_VGPU_VCE_FAULT = 2'd2
  } apu_vgpu_vce_status_e;

  // VertexElementObjectReadKeep (vce) completion.
  typedef struct packed {
    apu_vgpu_vce_status_e status;
  } apu_vgpu_vce_cpl_t;

  // VertexElementObjectReadKeep (vce): Kept header, handle, and the two element offsets and formats.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] off0;
    logic [31:0] fmt0;
    logic [31:0] off1;
    logic [31:0] fmt1;
  } apu_vgpu_vce_t;

  // FragShaderObjectRead (fsc) status.
  typedef enum logic [1:0] {
    APU_VGPU_FSC_OK    = 2'd0,
    APU_VGPU_FSC_EMPTY = 2'd1,
    APU_VGPU_FSC_FAULT = 2'd2
  } apu_vgpu_fsc_status_e;

  // FragShaderObjectRead (fsc) completion.
  typedef struct packed {
    apu_vgpu_fsc_status_e status;
  } apu_vgpu_fsc_cpl_t;

  // FragShaderObjectRead (fsc): Fragment-shader header, handle 3, stage, length, token count, and text0.
  // The rest of the text stays in the execbuffer. The shader is not run.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] stage;
    logic [31:0] offlen;
    logic [31:0] tokens;
    logic [31:0] text0;
  } apu_vgpu_fsc_t;

  // FragShaderObjectReadKeep (fce) status.
  typedef enum logic [1:0] {
    APU_VGPU_FCE_OK    = 2'd0,
    APU_VGPU_FCE_EMPTY = 2'd1,
    APU_VGPU_FCE_FAULT = 2'd2
  } apu_vgpu_fce_status_e;

  // FragShaderObjectReadKeep (fce) completion.
  typedef struct packed {
    apu_vgpu_fce_status_e status;
  } apu_vgpu_fce_cpl_t;

  // FragShaderObjectReadKeep (fce): Kept fragment-shader header, handle, stage, length, tokens, and text0.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] stage;
    logic [31:0] offlen;
    logic [31:0] tokens;
    logic [31:0] text0;
  } apu_vgpu_fce_t;

  // VertexShaderObjectRead (vsc) status.
  typedef enum logic [1:0] {
    APU_VGPU_VSC_OK    = 2'd0,
    APU_VGPU_VSC_EMPTY = 2'd1,
    APU_VGPU_VSC_FAULT = 2'd2
  } apu_vgpu_vsc_status_e;

  // VertexShaderObjectRead (vsc) completion.
  typedef struct packed {
    apu_vgpu_vsc_status_e status;
  } apu_vgpu_vsc_cpl_t;

  // VertexShaderObjectRead (vsc): Vertex-shader header, handle 2, stage, length, token count, and text0.
  // The rest of the text stays in the execbuffer. The shader is not run.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] stage;
    logic [31:0] offlen;
    logic [31:0] tokens;
    logic [31:0] text0;
  } apu_vgpu_vsc_t;

  // VertexShaderObjectReadKeep (vse) status.
  typedef enum logic [1:0] {
    APU_VGPU_VSE_OK    = 2'd0,
    APU_VGPU_VSE_EMPTY = 2'd1,
    APU_VGPU_VSE_FAULT = 2'd2
  } apu_vgpu_vse_status_e;

  // VertexShaderObjectReadKeep (vse) completion.
  typedef struct packed {
    apu_vgpu_vse_status_e status;
  } apu_vgpu_vse_cpl_t;

  // VertexShaderObjectReadKeep (vse): Kept vertex-shader header, handle, stage, length, tokens, and text0.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] stage;
    logic [31:0] offlen;
    logic [31:0] tokens;
    logic [31:0] text0;
  } apu_vgpu_vse_t;

  // SurfaceObjectRead (sfc) status.
  typedef enum logic [1:0] {
    APU_VGPU_SFC_OK    = 2'd0,
    APU_VGPU_SFC_EMPTY = 2'd1,
    APU_VGPU_SFC_FAULT = 2'd2
  } apu_vgpu_sfc_status_e;

  // SurfaceObjectRead (sfc) completion.
  typedef struct packed {
    apu_vgpu_sfc_status_e status;
  } apu_vgpu_sfc_cpl_t;

  // SurfaceObjectRead (sfc): Surface header, handle 1, resource 4, and format 2. No pixels are stored.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] resource;
    logic [31:0] format;
  } apu_vgpu_sfc_t;

  // SurfaceObjectReadKeep (sfe) status.
  typedef enum logic [1:0] {
    APU_VGPU_SFE_OK    = 2'd0,
    APU_VGPU_SFE_EMPTY = 2'd1,
    APU_VGPU_SFE_FAULT = 2'd2
  } apu_vgpu_sfe_status_e;

  // SurfaceObjectReadKeep (sfe) completion.
  typedef struct packed {
    apu_vgpu_sfe_status_e status;
  } apu_vgpu_sfe_cpl_t;

  // SurfaceObjectReadKeep (sfe): Kept surface header, handle, resource, and format.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] resource;
    logic [31:0] format;
  } apu_vgpu_sfe_t;

  // SceneChainGuestRead (nxc) status.
  typedef enum logic [1:0] {
    APU_VGPU_NXC_OK    = 2'd0,
    APU_VGPU_NXC_EMPTY = 2'd1,
    APU_VGPU_NXC_FAULT = 2'd2
  } apu_vgpu_nxc_status_e;

  // SceneChainGuestRead (nxc) completion.
  typedef struct packed {
    apu_vgpu_nxc_status_e status;
  } apu_vgpu_nxc_cpl_t;

  // SceneChainGuestRead (nxc): Head descriptor 0, the 960-byte execbuffer, the response, and avail index 1.
  // The descriptor bytes are not kept. This is not g6lc_apu_vgpu_avail.
  typedef struct packed {
    logic valid;
    logic [15:0] head;
    logic [15:0] avail_idx;
    logic [31:0] buf_len;
    logic [63:0] buf_addr;
    logic [63:0] rsp_addr;
  } apu_vgpu_nxc_t;

  // SceneChainGuestKeep (nxk) status.
  typedef enum logic [1:0] {
    APU_VGPU_NXK_OK    = 2'd0,
    APU_VGPU_NXK_EMPTY = 2'd1,
    APU_VGPU_NXK_FAULT = 2'd2
  } apu_vgpu_nxk_status_e;

  // SceneChainGuestKeep (nxk) completion.
  typedef struct packed {
    apu_vgpu_nxk_status_e status;
  } apu_vgpu_nxk_cpl_t;

  // SceneChainGuestKeep (nxk): Kept head, avail index, execbuffer, and response.
  typedef struct packed {
    logic valid;
    logic [15:0] head;
    logic [15:0] avail_idx;
    logic [31:0] buf_len;
    logic [63:0] buf_addr;
    logic [63:0] rsp_addr;
  } apu_vgpu_nxk_t;

  // OpcodeList (ols) status.
  typedef enum logic [1:0] {
    APU_VGPU_OLS_OK    = 2'd0,
    APU_VGPU_OLS_EMPTY = 2'd1,
    APU_VGPU_OLS_FAULT = 2'd2
  } apu_vgpu_ols_status_e;

  // OpcodeList (ols) completion.
  typedef struct packed {
    apu_vgpu_ols_status_e status;
  } apu_vgpu_ols_cpl_t;

  // OpcodeList (ols): Completed-opcode count, capset id, and response. The count is 0.
  // Capset id 0 is not virgl id 1. No caps blob is stored.
  typedef struct packed {
    logic valid;
    logic [31:0] count;
    logic [31:0] capset_id;
    logic [31:0] resp;
  } apu_vgpu_ols_t;

  // OpcodeListKeep (olk) status.
  typedef enum logic [1:0] {
    APU_VGPU_OLK_OK    = 2'd0,
    APU_VGPU_OLK_EMPTY = 2'd1,
    APU_VGPU_OLK_FAULT = 2'd2
  } apu_vgpu_olk_status_e;

  // OpcodeListKeep (olk) completion.
  typedef struct packed {
    apu_vgpu_olk_status_e status;
  } apu_vgpu_olk_cpl_t;

  // OpcodeListKeep (olk): Kept count, capset id, and response. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] count;
    logic [31:0] capset_id;
    logic [31:0] resp;
  } apu_vgpu_olk_t;

  // ClearWindowWrite (gpw) status.
  typedef enum logic [1:0] {
    APU_VGPU_GPW_OK    = 2'd0,
    APU_VGPU_GPW_EMPTY = 2'd1,
    APU_VGPU_GPW_FAULT = 2'd2
  } apu_vgpu_gpw_status_e;

  // ClearWindowWrite (gpw) completion.
  typedef struct packed {
    apu_vgpu_gpw_status_e status;
  } apu_vgpu_gpw_cpl_t;

  // ClearWindowWrite (gpw): 64 by 64 clear-word window. The bytes are not kept in registers.
  typedef struct packed {
    logic valid;
    logic [15:0] beats;
    logic [31:0] word;
    logic [63:0] base;
  } apu_vgpu_gpw_t;

  // ClearWindowRead (gpr) status.
  typedef enum logic [1:0] {
    APU_VGPU_GPR_OK    = 2'd0,
    APU_VGPU_GPR_EMPTY = 2'd1,
    APU_VGPU_GPR_FAULT = 2'd2
  } apu_vgpu_gpr_status_e;

  // ClearWindowRead (gpr) completion.
  typedef struct packed {
    apu_vgpu_gpr_status_e status;
  } apu_vgpu_gpr_cpl_t;

  // ClearWindowRead (gpr): First and last beat of that window. Both carry the clear word.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [63:0] first;
    logic [63:0] last;
  } apu_vgpu_gpr_t;

  // ClearWindowKeep (gpk) status.
  typedef enum logic [1:0] {
    APU_VGPU_GPK_OK    = 2'd0,
    APU_VGPU_GPK_EMPTY = 2'd1,
    APU_VGPU_GPK_FAULT = 2'd2
  } apu_vgpu_gpk_status_e;

  // ClearWindowKeep (gpk) completion.
  typedef struct packed {
    apu_vgpu_gpk_status_e status;
  } apu_vgpu_gpk_cpl_t;

  // ClearWindowKeep (gpk): Kept clear word and the two beat addresses.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [63:0] first;
    logic [63:0] last;
  } apu_vgpu_gpk_t;

  // SceneCompleteWrite (gcw) status.
  typedef enum logic [1:0] {
    APU_VGPU_GCW_OK    = 2'd0,
    APU_VGPU_GCW_EMPTY = 2'd1,
    APU_VGPU_GCW_FAULT = 2'd2
  } apu_vgpu_gcw_status_e;

  // SceneCompleteWrite (gcw) completion.
  typedef struct packed {
    apu_vgpu_gcw_status_e status;
  } apu_vgpu_gcw_cpl_t;

  // SceneCompleteWrite (gcw): Response type, fence, used element, and used index. The 24 bytes
  // are not kept. This is not g6lc_apu_vgpu_rsp.
  typedef struct packed {
    logic valid;
    logic [31:0] resp;
    logic [63:0] fence;
    logic [31:0] elem_id;
    logic [31:0] elem_len;
    logic [15:0] used_idx;
  } apu_vgpu_gcw_t;

  // SceneCompleteRead (gcr) status.
  typedef enum logic [1:0] {
    APU_VGPU_GCR_OK    = 2'd0,
    APU_VGPU_GCR_EMPTY = 2'd1,
    APU_VGPU_GCR_FAULT = 2'd2
  } apu_vgpu_gcr_status_e;

  // SceneCompleteRead (gcr) completion.
  typedef struct packed {
    apu_vgpu_gcr_status_e status;
  } apu_vgpu_gcr_cpl_t;

  // SceneCompleteRead (gcr): The same fields read back from guest memory.
  typedef struct packed {
    logic valid;
    logic [31:0] resp;
    logic [63:0] fence;
    logic [31:0] elem_id;
    logic [31:0] elem_len;
    logic [15:0] used_idx;
  } apu_vgpu_gcr_t;

  // SceneCompleteKeep (gck) status.
  typedef enum logic [1:0] {
    APU_VGPU_GCK_OK    = 2'd0,
    APU_VGPU_GCK_EMPTY = 2'd1,
    APU_VGPU_GCK_FAULT = 2'd2
  } apu_vgpu_gck_status_e;

  // SceneCompleteKeep (gck) completion.
  typedef struct packed {
    apu_vgpu_gck_status_e status;
  } apu_vgpu_gck_cpl_t;

  // SceneCompleteKeep (gck): Kept response, fence, element, and used index. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] resp;
    logic [63:0] fence;
    logic [31:0] elem_id;
    logic [31:0] elem_len;
    logic [15:0] used_idx;
  } apu_vgpu_gck_t;

  // UsedIrqWrite (viw) status.
  typedef enum logic [1:0] {
    APU_VGPU_VIW_OK    = 2'd0,
    APU_VGPU_VIW_EMPTY = 2'd1,
    APU_VGPU_VIW_FAULT = 2'd2
  } apu_vgpu_viw_status_e;

  // UsedIrqWrite (viw) completion.
  typedef struct packed {
    apu_vgpu_viw_status_e status;
  } apu_vgpu_viw_cpl_t;

  // UsedIrqWrite (viw): Used-buffer interrupt reason and the used index. The status word
  // is not kept in a register file. This is not g6lc_apu_vgpu_sun.
  typedef struct packed {
    logic valid;
    logic [31:0] reason;
    logic [15:0] used_idx;
  } apu_vgpu_viw_t;

  // UsedIrqRead (vir) status.
  typedef enum logic [1:0] {
    APU_VGPU_VIR_OK    = 2'd0,
    APU_VGPU_VIR_EMPTY = 2'd1,
    APU_VGPU_VIR_FAULT = 2'd2
  } apu_vgpu_vir_status_e;

  // UsedIrqRead (vir) completion.
  typedef struct packed {
    apu_vgpu_vir_status_e status;
  } apu_vgpu_vir_cpl_t;

  // UsedIrqRead (vir): The reason read back from the stand-in word.
  typedef struct packed {
    logic valid;
    logic [31:0] reason;
    logic [15:0] used_idx;
  } apu_vgpu_vir_t;

  // UsedIrqKeep (vik) status.
  typedef enum logic [1:0] {
    APU_VGPU_VIK_OK    = 2'd0,
    APU_VGPU_VIK_EMPTY = 2'd1,
    APU_VGPU_VIK_FAULT = 2'd2
  } apu_vgpu_vik_status_e;

  // UsedIrqKeep (vik) completion.
  typedef struct packed {
    apu_vgpu_vik_status_e status;
  } apu_vgpu_vik_cpl_t;

  // UsedIrqKeep (vik): Kept reason and used index. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] reason;
    logic [15:0] used_idx;
  } apu_vgpu_vik_t;

  // UsedAck (vaw) status.
  typedef enum logic [1:0] {
    APU_VGPU_VAW_OK    = 2'd0,
    APU_VGPU_VAW_EMPTY = 2'd1,
    APU_VGPU_VAW_FAULT = 2'd2
  } apu_vgpu_vaw_status_e;

  // UsedAck (vaw) completion.
  typedef struct packed {
    apu_vgpu_vaw_status_e status;
  } apu_vgpu_vaw_cpl_t;

  // UsedAck (vaw): Guest ack word and the cleared status. The beats are not kept.
  // This is not the viw pin.
  typedef struct packed {
    logic valid;
    logic [31:0] ack;
    logic [31:0] remain;
    logic [15:0] used_idx;
  } apu_vgpu_vaw_t;

  // UsedAckRead (var) status.
  typedef enum logic [1:0] {
    APU_VGPU_VAR_OK    = 2'd0,
    APU_VGPU_VAR_EMPTY = 2'd1,
    APU_VGPU_VAR_FAULT = 2'd2
  } apu_vgpu_var_status_e;

  // UsedAckRead (var) completion.
  typedef struct packed {
    apu_vgpu_var_status_e status;
  } apu_vgpu_var_cpl_t;

  // UsedAckRead (var): Ack word and cleared status read back.
  typedef struct packed {
    logic valid;
    logic [31:0] ack;
    logic [31:0] remain;
    logic [15:0] used_idx;
  } apu_vgpu_var_t;

  // UsedAckKeep (vak) status.
  typedef enum logic [1:0] {
    APU_VGPU_VAK_OK    = 2'd0,
    APU_VGPU_VAK_EMPTY = 2'd1,
    APU_VGPU_VAK_FAULT = 2'd2
  } apu_vgpu_vak_status_e;

  // UsedAckKeep (vak) completion.
  typedef struct packed {
    apu_vgpu_vak_status_e status;
  } apu_vgpu_vak_cpl_t;

  // UsedAckKeep (vak): Kept ack, cleared status, and used index. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] ack;
    logic [31:0] remain;
    logic [15:0] used_idx;
  } apu_vgpu_vak_t;

  // ClearWindowScan (wfr) status.
  typedef enum logic [1:0] {
    APU_VGPU_WFR_OK    = 2'd0,
    APU_VGPU_WFR_EMPTY = 2'd1,
    APU_VGPU_WFR_FAULT = 2'd2
  } apu_vgpu_wfr_status_e;

  // ClearWindowScan (wfr) completion.
  typedef struct packed {
    apu_vgpu_wfr_status_e status;
  } apu_vgpu_wfr_cpl_t;

  // ClearWindowScan (wfr): Full scan of the clear-word window. The image is not kept.
  // (1,0) is byte 4 of beat 0. (63,63) is the top lane of the last beat.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [31:0] pix10;
    logic [31:0] pix63;
    logic [15:0] beats;
    logic [63:0] base;
    logic [63:0] tail;
  } apu_vgpu_wfr_t;

  // ClearWindowScanKeep (wfk) status.
  typedef enum logic [1:0] {
    APU_VGPU_WFK_OK    = 2'd0,
    APU_VGPU_WFK_EMPTY = 2'd1,
    APU_VGPU_WFK_FAULT = 2'd2
  } apu_vgpu_wfk_status_e;

  // ClearWindowScanKeep (wfk) completion.
  typedef struct packed {
    apu_vgpu_wfk_status_e status;
  } apu_vgpu_wfk_cpl_t;

  // ClearWindowScanKeep (wfk): Kept clear word at the three sampled points.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [31:0] pix10;
    logic [31:0] pix63;
    logic [15:0] beats;
  } apu_vgpu_wfk_t;

  // ClearWindowScanCheck (wfx) status.
  typedef enum logic [1:0] {
    APU_VGPU_WFX_OK    = 2'd0,
    APU_VGPU_WFX_EMPTY = 2'd1,
    APU_VGPU_WFX_FAULT = 2'd2
  } apu_vgpu_wfx_status_e;

  // ClearWindowScanCheck (wfx) completion.
  typedef struct packed {
    apu_vgpu_wfx_status_e status;
  } apu_vgpu_wfx_cpl_t;

  // ClearWindowScanCheck (wfx): One in-range point. A coordinate past 63 records nothing.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [6:0] x;
    logic [6:0] y;
  } apu_vgpu_wfx_t;

  // ReadbackCopy (gbw) status.
  typedef enum logic [1:0] {
    APU_VGPU_GBW_OK    = 2'd0,
    APU_VGPU_GBW_EMPTY = 2'd1,
    APU_VGPU_GBW_FAULT = 2'd2
  } apu_vgpu_gbw_status_e;

  // ReadbackCopy (gbw) completion.
  typedef struct packed {
    apu_vgpu_gbw_status_e status;
  } apu_vgpu_gbw_cpl_t;

  // ReadbackCopy (gbw): Copy of the scanned window into the readback buffer. The image is
  // not kept. This is not Mesa glReadPixels.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [15:0] beats;
    logic [63:0] src;
    logic [63:0] dst;
  } apu_vgpu_gbw_t;

  // ReadbackCopyRead (gbr) status.
  typedef enum logic [1:0] {
    APU_VGPU_GBR_OK    = 2'd0,
    APU_VGPU_GBR_EMPTY = 2'd1,
    APU_VGPU_GBR_FAULT = 2'd2
  } apu_vgpu_gbr_status_e;

  // ReadbackCopyRead (gbr) completion.
  typedef struct packed {
    apu_vgpu_gbr_status_e status;
  } apu_vgpu_gbr_cpl_t;

  // ReadbackCopyRead (gbr): First and last beats of the readback buffer.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [63:0] first;
    logic [63:0] last;
  } apu_vgpu_gbr_t;

  // ReadbackCopyKeep (gbk) status.
  typedef enum logic [1:0] {
    APU_VGPU_GBK_OK    = 2'd0,
    APU_VGPU_GBK_EMPTY = 2'd1,
    APU_VGPU_GBK_FAULT = 2'd2
  } apu_vgpu_gbk_status_e;

  // ReadbackCopyKeep (gbk) completion.
  typedef struct packed {
    apu_vgpu_gbk_status_e status;
  } apu_vgpu_gbk_cpl_t;

  // ReadbackCopyKeep (gbk): Kept clear word, source, and readback address.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [15:0] beats;
    logic [63:0] src;
    logic [63:0] dst;
  } apu_vgpu_gbk_t;

  // ReadbackRect (gbd) status.
  typedef enum logic [1:0] {
    APU_VGPU_GBD_OK    = 2'd0,
    APU_VGPU_GBD_EMPTY = 2'd1,
    APU_VGPU_GBD_FAULT = 2'd2
  } apu_vgpu_gbd_status_e;

  // ReadbackRect (gbd) completion.
  typedef struct packed {
    apu_vgpu_gbd_status_e status;
  } apu_vgpu_gbd_cpl_t;

  // ReadbackRect (gbd): 64 by 64 readback rectangle. The image is not kept.
  typedef struct packed {
    logic valid;
    logic [15:0] width;
    logic [15:0] height;
    logic [15:0] stride;
    logic [31:0] bytes;
    logic [31:0] format;
    logic [63:0] base;
  } apu_vgpu_gbd_t;

  // ReadbackRectLane (gbl) status.
  typedef enum logic [1:0] {
    APU_VGPU_GBL_OK    = 2'd0,
    APU_VGPU_GBL_EMPTY = 2'd1,
    APU_VGPU_GBL_FAULT = 2'd2
  } apu_vgpu_gbl_status_e;

  // ReadbackRectLane (gbl) completion.
  typedef struct packed {
    apu_vgpu_gbl_status_e status;
  } apu_vgpu_gbl_cpl_t;

  // ReadbackRectLane (gbl): One lane of the readback buffer. A coordinate past 63 reads nothing.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [6:0] x;
    logic [6:0] y;
    logic [63:0] addr;
  } apu_vgpu_gbl_t;

  // ReadbackRectCheck (gbx) status.
  typedef enum logic [1:0] {
    APU_VGPU_GBX_OK    = 2'd0,
    APU_VGPU_GBX_EMPTY = 2'd1,
    APU_VGPU_GBX_FAULT = 2'd2
  } apu_vgpu_gbx_status_e;

  // ReadbackRectCheck (gbx) completion.
  typedef struct packed {
    apu_vgpu_gbx_status_e status;
  } apu_vgpu_gbx_cpl_t;

  // ReadbackRectCheck (gbx): Kept rectangle and the sampled lane. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [15:0] width;
    logic [15:0] height;
    logic [31:0] bytes;
    logic [31:0] word;
    logic [6:0] x;
    logic [6:0] y;
  } apu_vgpu_gbx_t;

  // ReadbackOffset (gof) status.
  typedef enum logic [1:0] {
    APU_VGPU_GOF_OK    = 2'd0,
    APU_VGPU_GOF_EMPTY = 2'd1,
    APU_VGPU_GOF_FAULT = 2'd2
  } apu_vgpu_gof_status_e;

  // ReadbackOffset (gof) completion.
  typedef struct packed {
    apu_vgpu_gof_status_e status;
  } apu_vgpu_gof_cpl_t;

  // ReadbackOffset (gof): Byte offset of one in-range point. The image is not kept.
  typedef struct packed {
    logic valid;
    logic [15:0] offset;
    logic [63:0] addr;
    logic [6:0] x;
    logic [6:0] y;
  } apu_vgpu_gof_t;

  // ReadbackOffsetLane (gbo) status.
  typedef enum logic [1:0] {
    APU_VGPU_GBO_OK    = 2'd0,
    APU_VGPU_GBO_EMPTY = 2'd1,
    APU_VGPU_GBO_FAULT = 2'd2
  } apu_vgpu_gbo_status_e;

  // ReadbackOffsetLane (gbo) completion.
  typedef struct packed {
    apu_vgpu_gbo_status_e status;
  } apu_vgpu_gbo_cpl_t;

  // ReadbackOffsetLane (gbo): The lane at that byte offset. It is the clear word.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [15:0] offset;
    logic [6:0] x;
    logic [6:0] y;
  } apu_vgpu_gbo_t;

  // ReadbackOffsetCheck (gbz) status.
  typedef enum logic [1:0] {
    APU_VGPU_GBZ_OK    = 2'd0,
    APU_VGPU_GBZ_EMPTY = 2'd1,
    APU_VGPU_GBZ_FAULT = 2'd2
  } apu_vgpu_gbz_status_e;

  // ReadbackOffsetCheck (gbz) completion.
  typedef struct packed {
    apu_vgpu_gbz_status_e status;
  } apu_vgpu_gbz_cpl_t;

  // ReadbackOffsetCheck (gbz): Kept offset and lane. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [15:0] offset;
    logic [31:0] bytes;
    logic [6:0] x;
    logic [6:0] y;
  } apu_vgpu_gbz_t;

  // ClearChannels (byr) status.
  typedef enum logic [1:0] {
    APU_VGPU_BYR_OK    = 2'd0,
    APU_VGPU_BYR_EMPTY = 2'd1,
    APU_VGPU_BYR_FAULT = 2'd2
  } apu_vgpu_byr_status_e;

  // ClearChannels (byr) completion.
  typedef struct packed {
    apu_vgpu_byr_status_e status;
  } apu_vgpu_byr_cpl_t;

  // ClearChannels (byr): Little-endian channels of the clear word. Byte 0 is red.
  // The image is not kept.
  typedef struct packed {
    logic valid;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_byr_t;

  // ClearChannelsKeep (byk) status.
  typedef enum logic [1:0] {
    APU_VGPU_BYK_OK    = 2'd0,
    APU_VGPU_BYK_EMPTY = 2'd1,
    APU_VGPU_BYK_FAULT = 2'd2
  } apu_vgpu_byk_status_e;

  // ClearChannelsKeep (byk) completion.
  typedef struct packed {
    apu_vgpu_byk_status_e status;
  } apu_vgpu_byk_cpl_t;

  // ClearChannelsKeep (byk): Kept channels. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_byk_t;

  // ClearChannelsCheck (byx) status.
  typedef enum logic [1:0] {
    APU_VGPU_BYX_OK    = 2'd0,
    APU_VGPU_BYX_EMPTY = 2'd1,
    APU_VGPU_BYX_FAULT = 2'd2
  } apu_vgpu_byx_status_e;

  // ClearChannelsCheck (byx) completion.
  typedef struct packed {
    apu_vgpu_byx_status_e status;
  } apu_vgpu_byx_cpl_t;

  // ClearChannelsCheck (byx): The first raw byte is red, not the high byte of the word.
  typedef struct packed {
    logic valid;
    logic [7:0] b0;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_byx_t;

  // ReadbackRow1 (ryr) status.
  typedef enum logic [1:0] {
    APU_VGPU_RYR_OK    = 2'd0,
    APU_VGPU_RYR_EMPTY = 2'd1,
    APU_VGPU_RYR_FAULT = 2'd2
  } apu_vgpu_ryr_status_e;

  // ReadbackRow1 (ryr) completion.
  typedef struct packed {
    apu_vgpu_ryr_status_e status;
  } apu_vgpu_ryr_cpl_t;

  // ReadbackRow1 (ryr): Row 1 of the readback, byte 0 red. The image is not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_ryr_t;

  // ReadbackRow1Keep (ryk) status.
  typedef enum logic [1:0] {
    APU_VGPU_RYK_OK    = 2'd0,
    APU_VGPU_RYK_EMPTY = 2'd1,
    APU_VGPU_RYK_FAULT = 2'd2
  } apu_vgpu_ryk_status_e;

  // ReadbackRow1Keep (ryk) completion.
  typedef struct packed {
    apu_vgpu_ryk_status_e status;
  } apu_vgpu_ryk_cpl_t;

  // ReadbackRow1Keep (ryk): Kept row channels and format tag. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_ryk_t;

  // ReadbackRow1Check (ryx) status.
  typedef enum logic [1:0] {
    APU_VGPU_RYX_OK    = 2'd0,
    APU_VGPU_RYX_EMPTY = 2'd1,
    APU_VGPU_RYX_FAULT = 2'd2
  } apu_vgpu_ryx_status_e;

  // ReadbackRow1Check (ryx) completion.
  typedef struct packed {
    apu_vgpu_ryx_status_e status;
  } apu_vgpu_ryx_cpl_t;

  // ReadbackRow1Check (ryx): Byte 0 of row 1 is red. Blue or 8'hFF records nothing.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [7:0] b0;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_ryx_t;

  // ReadbackThreePoints (tpr) status.
  typedef enum logic [1:0] {
    APU_VGPU_TPR_OK    = 2'd0,
    APU_VGPU_TPR_EMPTY = 2'd1,
    APU_VGPU_TPR_FAULT = 2'd2
  } apu_vgpu_tpr_status_e;

  // ReadbackThreePoints (tpr) completion.
  typedef struct packed {
    apu_vgpu_tpr_status_e status;
  } apu_vgpu_tpr_cpl_t;

  // ReadbackThreePoints (tpr): Three readback points. The image is not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off11;
    logic [15:0] off23;
    logic [15:0] off063;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_tpr_t;

  // ReadbackThreePointsKeep (tpk) status.
  typedef enum logic [1:0] {
    APU_VGPU_TPK_OK    = 2'd0,
    APU_VGPU_TPK_EMPTY = 2'd1,
    APU_VGPU_TPK_FAULT = 2'd2
  } apu_vgpu_tpk_status_e;

  // ReadbackThreePointsKeep (tpk) completion.
  typedef struct packed {
    apu_vgpu_tpk_status_e status;
  } apu_vgpu_tpk_cpl_t;

  // ReadbackThreePointsKeep (tpk): Kept offsets and channels. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off11;
    logic [15:0] off23;
    logic [15:0] off063;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_tpk_t;

  // ReadbackThreePointsCheck (tpx) status.
  typedef enum logic [1:0] {
    APU_VGPU_TPX_OK    = 2'd0,
    APU_VGPU_TPX_EMPTY = 2'd1,
    APU_VGPU_TPX_FAULT = 2'd2
  } apu_vgpu_tpx_status_e;

  // ReadbackThreePointsCheck (tpx) completion.
  typedef struct packed {
    apu_vgpu_tpx_status_e status;
  } apu_vgpu_tpx_cpl_t;

  // ReadbackThreePointsCheck (tpx): Byte 0 of (0,63) is red. Blue or 8'hFF records nothing.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off11;
    logic [15:0] off23;
    logic [15:0] off063;
    logic [7:0] b0;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_tpx_t;

  // ReadbackX63 (x6r) status.
  typedef enum logic [1:0] {
    APU_VGPU_X6R_OK    = 2'd0,
    APU_VGPU_X6R_EMPTY = 2'd1,
    APU_VGPU_X6R_FAULT = 2'd2
  } apu_vgpu_x6r_status_e;

  // ReadbackX63 (x6r) completion.
  typedef struct packed {
    apu_vgpu_x6r_status_e status;
  } apu_vgpu_x6r_cpl_t;

  // ReadbackX63 (x6r): (63,0) is byte 252. The image is not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] offset;
    logic [6:0] x;
    logic [6:0] y;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_x6r_t;

  // ReadbackX63Keep (x6k) status.
  typedef enum logic [1:0] {
    APU_VGPU_X6K_OK    = 2'd0,
    APU_VGPU_X6K_EMPTY = 2'd1,
    APU_VGPU_X6K_FAULT = 2'd2
  } apu_vgpu_x6k_status_e;

  // ReadbackX63Keep (x6k) completion.
  typedef struct packed {
    apu_vgpu_x6k_status_e status;
  } apu_vgpu_x6k_cpl_t;

  // ReadbackX63Keep (x6k): Kept (63,0). A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] offset;
    logic [6:0] x;
    logic [6:0] y;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_x6k_t;

  // ReadbackX63Check (x6x) status.
  typedef enum logic [1:0] {
    APU_VGPU_X6X_OK    = 2'd0,
    APU_VGPU_X6X_EMPTY = 2'd1,
    APU_VGPU_X6X_FAULT = 2'd2
  } apu_vgpu_x6x_status_e;

  // ReadbackX63Check (x6x) completion.
  typedef struct packed {
    apu_vgpu_x6x_status_e status;
  } apu_vgpu_x6x_cpl_t;

  // ReadbackX63Check (x6x): Byte 0 of (63,0) is red. Blue or 8'hFF records nothing.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] offset;
    logic [6:0] x;
    logic [6:0] y;
    logic [7:0] b0;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_x6x_t;

  // ReadbackFarCorner (tcr) status.
  typedef enum logic [1:0] {
    APU_VGPU_TCR_OK    = 2'd0,
    APU_VGPU_TCR_EMPTY = 2'd1,
    APU_VGPU_TCR_FAULT = 2'd2
  } apu_vgpu_tcr_status_e;

  // ReadbackFarCorner (tcr) completion.
  typedef struct packed {
    apu_vgpu_tcr_status_e status;
  } apu_vgpu_tcr_cpl_t;

  // ReadbackFarCorner (tcr): (63,63) is byte 16380. The image is not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] offset;
    logic [6:0] x;
    logic [6:0] y;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_tcr_t;

  // ReadbackFarCornerKeep (tck) status.
  typedef enum logic [1:0] {
    APU_VGPU_TCK_OK    = 2'd0,
    APU_VGPU_TCK_EMPTY = 2'd1,
    APU_VGPU_TCK_FAULT = 2'd2
  } apu_vgpu_tck_status_e;

  // ReadbackFarCornerKeep (tck) completion.
  typedef struct packed {
    apu_vgpu_tck_status_e status;
  } apu_vgpu_tck_cpl_t;

  // ReadbackFarCornerKeep (tck): Kept (63,63). A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] offset;
    logic [6:0] x;
    logic [6:0] y;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_tck_t;

  // ReadbackFarCornerCheck (tcx) status.
  typedef enum logic [1:0] {
    APU_VGPU_TCX_OK    = 2'd0,
    APU_VGPU_TCX_EMPTY = 2'd1,
    APU_VGPU_TCX_FAULT = 2'd2
  } apu_vgpu_tcx_status_e;

  // ReadbackFarCornerCheck (tcx) completion.
  typedef struct packed {
    apu_vgpu_tcx_status_e status;
  } apu_vgpu_tcx_cpl_t;

  // ReadbackFarCornerCheck (tcx): Byte 0 of (63,63) is red. Blue or 8'hFF records nothing.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] offset;
    logic [6:0] x;
    logic [6:0] y;
    logic [7:0] b0;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_tcx_t;

  // ReadbackX7 (p7r) status.
  typedef enum logic [1:0] {
    APU_VGPU_P7R_OK    = 2'd0,
    APU_VGPU_P7R_EMPTY = 2'd1,
    APU_VGPU_P7R_FAULT = 2'd2
  } apu_vgpu_p7r_status_e;

  // ReadbackX7 (p7r) completion.
  typedef struct packed {
    apu_vgpu_p7r_status_e status;
  } apu_vgpu_p7r_cpl_t;

  // ReadbackX7 (p7r): (7,0) is byte 28. The image is not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] offset;
    logic [6:0] x;
    logic [6:0] y;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_p7r_t;

  // ReadbackX7Keep (p7k) status.
  typedef enum logic [1:0] {
    APU_VGPU_P7K_OK    = 2'd0,
    APU_VGPU_P7K_EMPTY = 2'd1,
    APU_VGPU_P7K_FAULT = 2'd2
  } apu_vgpu_p7k_status_e;

  // ReadbackX7Keep (p7k) completion.
  typedef struct packed {
    apu_vgpu_p7k_status_e status;
  } apu_vgpu_p7k_cpl_t;

  // ReadbackX7Keep (p7k): Kept (7,0). A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] offset;
    logic [6:0] x;
    logic [6:0] y;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_p7k_t;

  // ReadbackX7Check (p7x) status.
  typedef enum logic [1:0] {
    APU_VGPU_P7X_OK    = 2'd0,
    APU_VGPU_P7X_EMPTY = 2'd1,
    APU_VGPU_P7X_FAULT = 2'd2
  } apu_vgpu_p7x_status_e;

  // ReadbackX7Check (p7x) completion.
  typedef struct packed {
    apu_vgpu_p7x_status_e status;
  } apu_vgpu_p7x_cpl_t;

  // ReadbackX7Check (p7x): Byte 0 of (7,0) is red. Blue or 8'hFF records nothing.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] offset;
    logic [6:0] x;
    logic [6:0] y;
    logic [7:0] b0;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_p7x_t;

  // ReadbackBeat1 (b1r) status.
  typedef enum logic [1:0] {
    APU_VGPU_B1R_OK    = 2'd0,
    APU_VGPU_B1R_EMPTY = 2'd1,
    APU_VGPU_B1R_FAULT = 2'd2
  } apu_vgpu_b1r_status_e;

  // ReadbackBeat1 (b1r) completion.
  typedef struct packed {
    apu_vgpu_b1r_status_e status;
  } apu_vgpu_b1r_cpl_t;

  // ReadbackBeat1 (b1r): (8,0) and (15,0) share one beat. The image is not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off8;
    logic [15:0] off15;
    logic [6:0] x8;
    logic [6:0] x15;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_b1r_t;

  // ReadbackBeat1Keep (b1k) status.
  typedef enum logic [1:0] {
    APU_VGPU_B1K_OK    = 2'd0,
    APU_VGPU_B1K_EMPTY = 2'd1,
    APU_VGPU_B1K_FAULT = 2'd2
  } apu_vgpu_b1k_status_e;

  // ReadbackBeat1Keep (b1k) completion.
  typedef struct packed {
    apu_vgpu_b1k_status_e status;
  } apu_vgpu_b1k_cpl_t;

  // ReadbackBeat1Keep (b1k): Kept beat-1 offsets. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off8;
    logic [15:0] off15;
    logic [6:0] x8;
    logic [6:0] x15;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_b1k_t;

  // ReadbackBeat1Check (b1x) status.
  typedef enum logic [1:0] {
    APU_VGPU_B1X_OK    = 2'd0,
    APU_VGPU_B1X_EMPTY = 2'd1,
    APU_VGPU_B1X_FAULT = 2'd2
  } apu_vgpu_b1x_status_e;

  // ReadbackBeat1Check (b1x) completion.
  typedef struct packed {
    apu_vgpu_b1x_status_e status;
  } apu_vgpu_b1x_cpl_t;

  // ReadbackBeat1Check (b1x): Byte 0 of (8,0) is red. Blue or 8'hFF records nothing.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off8;
    logic [15:0] off15;
    logic [6:0] x8;
    logic [6:0] x15;
    logic [7:0] b0;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_b1x_t;

  // ReadbackBeat7 (b7r) status.
  typedef enum logic [1:0] {
    APU_VGPU_B7R_OK    = 2'd0,
    APU_VGPU_B7R_EMPTY = 2'd1,
    APU_VGPU_B7R_FAULT = 2'd2
  } apu_vgpu_b7r_status_e;

  // ReadbackBeat7 (b7r) completion.
  typedef struct packed {
    apu_vgpu_b7r_status_e status;
  } apu_vgpu_b7r_cpl_t;

  // ReadbackBeat7 (b7r): (56,0) shares the beat with (63,0). The image is not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off56;
    logic [15:0] off63;
    logic [6:0] x56;
    logic [6:0] x63;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_b7r_t;

  // ReadbackBeat7Keep (b7k) status.
  typedef enum logic [1:0] {
    APU_VGPU_B7K_OK    = 2'd0,
    APU_VGPU_B7K_EMPTY = 2'd1,
    APU_VGPU_B7K_FAULT = 2'd2
  } apu_vgpu_b7k_status_e;

  // ReadbackBeat7Keep (b7k) completion.
  typedef struct packed {
    apu_vgpu_b7k_status_e status;
  } apu_vgpu_b7k_cpl_t;

  // ReadbackBeat7Keep (b7k): Kept (56,0) and (63,0). A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off56;
    logic [15:0] off63;
    logic [6:0] x56;
    logic [6:0] x63;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_b7k_t;

  // ReadbackBeat7Check (b7x) status.
  typedef enum logic [1:0] {
    APU_VGPU_B7X_OK    = 2'd0,
    APU_VGPU_B7X_EMPTY = 2'd1,
    APU_VGPU_B7X_FAULT = 2'd2
  } apu_vgpu_b7x_status_e;

  // ReadbackBeat7Check (b7x) completion.
  typedef struct packed {
    apu_vgpu_b7x_status_e status;
  } apu_vgpu_b7x_cpl_t;

  // ReadbackBeat7Check (b7x): Byte 0 of (56,0) is red. Blue or 8'hFF records nothing.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off56;
    logic [15:0] off63;
    logic [6:0] x56;
    logic [6:0] x63;
    logic [7:0] b0;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_b7x_t;

  // ReadbackBeat2 (b2r) status.
  typedef enum logic [1:0] {
    APU_VGPU_B2R_OK    = 2'd0,
    APU_VGPU_B2R_EMPTY = 2'd1,
    APU_VGPU_B2R_FAULT = 2'd2
  } apu_vgpu_b2r_status_e;

  // ReadbackBeat2 (b2r) completion.
  typedef struct packed {
    apu_vgpu_b2r_status_e status;
  } apu_vgpu_b2r_cpl_t;

  // ReadbackBeat2 (b2r): Beat 2 of row 0. (16,0) and (23,0). The image is not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off16;
    logic [15:0] off23;
    logic [6:0] x16;
    logic [6:0] x23;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_b2r_t;

  // ReadbackBeat2Keep (b2k) status.
  typedef enum logic [1:0] {
    APU_VGPU_B2K_OK    = 2'd0,
    APU_VGPU_B2K_EMPTY = 2'd1,
    APU_VGPU_B2K_FAULT = 2'd2
  } apu_vgpu_b2k_status_e;

  // ReadbackBeat2Keep (b2k) completion.
  typedef struct packed {
    apu_vgpu_b2k_status_e status;
  } apu_vgpu_b2k_cpl_t;

  // ReadbackBeat2Keep (b2k): Kept (16,0) and (23,0). A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off16;
    logic [15:0] off23;
    logic [6:0] x16;
    logic [6:0] x23;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_b2k_t;

  // ReadbackBeat2Check (b2x) status.
  typedef enum logic [1:0] {
    APU_VGPU_B2X_OK    = 2'd0,
    APU_VGPU_B2X_EMPTY = 2'd1,
    APU_VGPU_B2X_FAULT = 2'd2
  } apu_vgpu_b2x_status_e;

  // ReadbackBeat2Check (b2x) completion.
  typedef struct packed {
    apu_vgpu_b2x_status_e status;
  } apu_vgpu_b2x_cpl_t;

  // ReadbackBeat2Check (b2x): Byte 0 of (16,0) is red. Blue or 8'hFF records nothing.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off16;
    logic [15:0] off23;
    logic [6:0] x16;
    logic [6:0] x23;
    logic [7:0] b0;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_b2x_t;

  // ReadbackBeat3 (b3r) status.
  typedef enum logic [1:0] {
    APU_VGPU_B3R_OK    = 2'd0,
    APU_VGPU_B3R_EMPTY = 2'd1,
    APU_VGPU_B3R_FAULT = 2'd2
  } apu_vgpu_b3r_status_e;

  // ReadbackBeat3 (b3r) completion.
  typedef struct packed {
    apu_vgpu_b3r_status_e status;
  } apu_vgpu_b3r_cpl_t;

  // ReadbackBeat3 (b3r): Beat 3 of row 0. (24,0) and (31,0). The image is not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off24;
    logic [15:0] off31;
    logic [6:0] x24;
    logic [6:0] x31;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_b3r_t;

  // ReadbackBeat3Keep (b3k) status.
  typedef enum logic [1:0] {
    APU_VGPU_B3K_OK    = 2'd0,
    APU_VGPU_B3K_EMPTY = 2'd1,
    APU_VGPU_B3K_FAULT = 2'd2
  } apu_vgpu_b3k_status_e;

  // ReadbackBeat3Keep (b3k) completion.
  typedef struct packed {
    apu_vgpu_b3k_status_e status;
  } apu_vgpu_b3k_cpl_t;

  // ReadbackBeat3Keep (b3k): Kept (24,0) and (31,0). A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off24;
    logic [15:0] off31;
    logic [6:0] x24;
    logic [6:0] x31;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_b3k_t;

  // ReadbackBeat3Check (b3x) status.
  typedef enum logic [1:0] {
    APU_VGPU_B3X_OK    = 2'd0,
    APU_VGPU_B3X_EMPTY = 2'd1,
    APU_VGPU_B3X_FAULT = 2'd2
  } apu_vgpu_b3x_status_e;

  // ReadbackBeat3Check (b3x) completion.
  typedef struct packed {
    apu_vgpu_b3x_status_e status;
  } apu_vgpu_b3x_cpl_t;

  // ReadbackBeat3Check (b3x): Byte 0 of (24,0) is red. Blue or 8'hFF records nothing.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off24;
    logic [15:0] off31;
    logic [6:0] x24;
    logic [6:0] x31;
    logic [7:0] b0;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_b3x_t;

  // ReadbackBeat4 (b4r) status.
  typedef enum logic [1:0] {
    APU_VGPU_B4R_OK    = 2'd0,
    APU_VGPU_B4R_EMPTY = 2'd1,
    APU_VGPU_B4R_FAULT = 2'd2
  } apu_vgpu_b4r_status_e;

  // ReadbackBeat4 (b4r) completion.
  typedef struct packed {
    apu_vgpu_b4r_status_e status;
  } apu_vgpu_b4r_cpl_t;

  // ReadbackBeat4 (b4r): Beat 4 of row 0. (32,0) and (39,0). The image is not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off32;
    logic [15:0] off39;
    logic [6:0] x32;
    logic [6:0] x39;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_b4r_t;

  // ReadbackBeat4Keep (b4k) status.
  typedef enum logic [1:0] {
    APU_VGPU_B4K_OK    = 2'd0,
    APU_VGPU_B4K_EMPTY = 2'd1,
    APU_VGPU_B4K_FAULT = 2'd2
  } apu_vgpu_b4k_status_e;

  // ReadbackBeat4Keep (b4k) completion.
  typedef struct packed {
    apu_vgpu_b4k_status_e status;
  } apu_vgpu_b4k_cpl_t;

  // ReadbackBeat4Keep (b4k): Kept (32,0) and (39,0). A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off32;
    logic [15:0] off39;
    logic [6:0] x32;
    logic [6:0] x39;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_b4k_t;

  // ReadbackBeat4Check (b4x) status.
  typedef enum logic [1:0] {
    APU_VGPU_B4X_OK    = 2'd0,
    APU_VGPU_B4X_EMPTY = 2'd1,
    APU_VGPU_B4X_FAULT = 2'd2
  } apu_vgpu_b4x_status_e;

  // ReadbackBeat4Check (b4x) completion.
  typedef struct packed {
    apu_vgpu_b4x_status_e status;
  } apu_vgpu_b4x_cpl_t;

  // ReadbackBeat4Check (b4x): Byte 0 of (32,0) is red. Blue or 8'hFF records nothing.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off32;
    logic [15:0] off39;
    logic [6:0] x32;
    logic [6:0] x39;
    logic [7:0] b0;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_b4x_t;

  // ReadbackBeat5 (b5r) status.
  typedef enum logic [1:0] {
    APU_VGPU_B5R_OK    = 2'd0,
    APU_VGPU_B5R_EMPTY = 2'd1,
    APU_VGPU_B5R_FAULT = 2'd2
  } apu_vgpu_b5r_status_e;

  // ReadbackBeat5 (b5r) completion.
  typedef struct packed {
    apu_vgpu_b5r_status_e status;
  } apu_vgpu_b5r_cpl_t;

  // ReadbackBeat5 (b5r): Beat 5 of row 0. (40,0) and (47,0). The image is not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off40;
    logic [15:0] off47;
    logic [6:0] x40;
    logic [6:0] x47;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_b5r_t;

  // ReadbackBeat5Keep (b5k) status.
  typedef enum logic [1:0] {
    APU_VGPU_B5K_OK    = 2'd0,
    APU_VGPU_B5K_EMPTY = 2'd1,
    APU_VGPU_B5K_FAULT = 2'd2
  } apu_vgpu_b5k_status_e;

  // ReadbackBeat5Keep (b5k) completion.
  typedef struct packed {
    apu_vgpu_b5k_status_e status;
  } apu_vgpu_b5k_cpl_t;

  // ReadbackBeat5Keep (b5k): Kept (40,0) and (47,0). A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off40;
    logic [15:0] off47;
    logic [6:0] x40;
    logic [6:0] x47;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_b5k_t;

  // ReadbackBeat5Check (b5x) status.
  typedef enum logic [1:0] {
    APU_VGPU_B5X_OK    = 2'd0,
    APU_VGPU_B5X_EMPTY = 2'd1,
    APU_VGPU_B5X_FAULT = 2'd2
  } apu_vgpu_b5x_status_e;

  // ReadbackBeat5Check (b5x) completion.
  typedef struct packed {
    apu_vgpu_b5x_status_e status;
  } apu_vgpu_b5x_cpl_t;

  // ReadbackBeat5Check (b5x): Byte 0 of (40,0) is red. Blue or 8'hFF records nothing.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off40;
    logic [15:0] off47;
    logic [6:0] x40;
    logic [6:0] x47;
    logic [7:0] b0;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_b5x_t;

  // ReadbackBeat6 (b6r) status.
  typedef enum logic [1:0] {
    APU_VGPU_B6R_OK    = 2'd0,
    APU_VGPU_B6R_EMPTY = 2'd1,
    APU_VGPU_B6R_FAULT = 2'd2
  } apu_vgpu_b6r_status_e;

  // ReadbackBeat6 (b6r) completion.
  typedef struct packed {
    apu_vgpu_b6r_status_e status;
  } apu_vgpu_b6r_cpl_t;

  // ReadbackBeat6 (b6r): Beat 6 of row 0. (48,0) and (55,0). The image is not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off48;
    logic [15:0] off55;
    logic [6:0] x48;
    logic [6:0] x55;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_b6r_t;

  // ReadbackBeat6Keep (b6k) status.
  typedef enum logic [1:0] {
    APU_VGPU_B6K_OK    = 2'd0,
    APU_VGPU_B6K_EMPTY = 2'd1,
    APU_VGPU_B6K_FAULT = 2'd2
  } apu_vgpu_b6k_status_e;

  // ReadbackBeat6Keep (b6k) completion.
  typedef struct packed {
    apu_vgpu_b6k_status_e status;
  } apu_vgpu_b6k_cpl_t;

  // ReadbackBeat6Keep (b6k): Kept (48,0) and (55,0). A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off48;
    logic [15:0] off55;
    logic [6:0] x48;
    logic [6:0] x55;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_b6k_t;

  // ReadbackBeat6Check (b6x) status.
  typedef enum logic [1:0] {
    APU_VGPU_B6X_OK    = 2'd0,
    APU_VGPU_B6X_EMPTY = 2'd1,
    APU_VGPU_B6X_FAULT = 2'd2
  } apu_vgpu_b6x_status_e;

  // ReadbackBeat6Check (b6x) completion.
  typedef struct packed {
    apu_vgpu_b6x_status_e status;
  } apu_vgpu_b6x_cpl_t;

  // ReadbackBeat6Check (b6x): Byte 0 of (48,0) is red. Blue or 8'hFF records nothing.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off48;
    logic [15:0] off55;
    logic [6:0] x48;
    logic [6:0] x55;
    logic [7:0] b0;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_b6x_t;

  // LinearPairWrite (acw) status.
  typedef enum logic [1:0] {
    APU_VGPU_ACW_OK    = 2'd0,
    APU_VGPU_ACW_EMPTY = 2'd1,
    APU_VGPU_ACW_FAULT = 2'd2
  } apu_vgpu_acw_status_e;

  // LinearPairWrite (acw) completion.
  typedef struct packed {
    apu_vgpu_acw_status_e status;
  } apu_vgpu_acw_cpl_t;

  // LinearPairWrite (acw): Linear sample pair written as fragment color. The image is not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [63:0] base;
    logic [15:0] off0;
    logic [15:0] off1;
    logic [6:0] x0;
    logic [6:0] x1;
    logic [31:0] origin;
    logic [31:0] neighbor;
  } apu_vgpu_acw_t;

  // LinearPairRead (acr) status.
  typedef enum logic [1:0] {
    APU_VGPU_ACR_OK    = 2'd0,
    APU_VGPU_ACR_EMPTY = 2'd1,
    APU_VGPU_ACR_FAULT = 2'd2
  } apu_vgpu_acr_status_e;

  // LinearPairRead (acr) completion.
  typedef struct packed {
    apu_vgpu_acr_status_e status;
  } apu_vgpu_acr_cpl_t;

  // LinearPairRead (acr): Those two words read back. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [63:0] base;
    logic [15:0] off0;
    logic [15:0] off1;
    logic [6:0] x0;
    logic [6:0] x1;
    logic [31:0] origin;
    logic [31:0] neighbor;
  } apu_vgpu_acr_t;

  // LinearPairCheck (acx) status.
  typedef enum logic [1:0] {
    APU_VGPU_ACX_OK    = 2'd0,
    APU_VGPU_ACX_EMPTY = 2'd1,
    APU_VGPU_ACX_FAULT = 2'd2
  } apu_vgpu_acx_status_e;

  // LinearPairCheck (acx) completion.
  typedef struct packed {
    apu_vgpu_acx_status_e status;
  } apu_vgpu_acx_cpl_t;

  // LinearPairCheck (acx): Byte 0 of (1,0) is the sample red. Clear red records nothing.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off0;
    logic [15:0] off1;
    logic [6:0] x0;
    logic [6:0] x1;
    logic [7:0] b0;
    logic [31:0] origin;
    logic [31:0] neighbor;
  } apu_vgpu_acx_t;

  // ColorWindowCopy (csw) status.
  typedef enum logic [1:0] {
    APU_VGPU_CSW_OK    = 2'd0,
    APU_VGPU_CSW_EMPTY = 2'd1,
    APU_VGPU_CSW_FAULT = 2'd2
  } apu_vgpu_csw_status_e;

  // ColorWindowCopy (csw) completion.
  typedef struct packed {
    apu_vgpu_csw_status_e status;
  } apu_vgpu_csw_cpl_t;

  // ColorWindowCopy (csw): 64 by 64 copy of the ceiling samples. The image is not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] origin;
    logic [31:0] neighbor;
    logic [15:0] beats;
    logic [63:0] src;
    logic [63:0] dst;
  } apu_vgpu_csw_t;

  // ColorWindowRead (csr) status.
  typedef enum logic [1:0] {
    APU_VGPU_CSR_OK    = 2'd0,
    APU_VGPU_CSR_EMPTY = 2'd1,
    APU_VGPU_CSR_FAULT = 2'd2
  } apu_vgpu_csr_status_e;

  // ColorWindowRead (csr) completion.
  typedef struct packed {
    apu_vgpu_csr_status_e status;
  } apu_vgpu_csr_cpl_t;

  // ColorWindowRead (csr): Beat 0 of the color window. (0,0) and (1,0) are the sample pair.
  typedef struct packed {
    logic valid;
    logic [31:0] origin;
    logic [31:0] neighbor;
    logic [15:0] off0;
    logic [15:0] off1;
    logic [6:0] x0;
    logic [6:0] x1;
    logic [63:0] base;
  } apu_vgpu_csr_t;

  // ColorWindowCheck (csx) status.
  typedef enum logic [1:0] {
    APU_VGPU_CSX_OK    = 2'd0,
    APU_VGPU_CSX_EMPTY = 2'd1,
    APU_VGPU_CSX_FAULT = 2'd2
  } apu_vgpu_csx_status_e;

  // ColorWindowCheck (csx) completion.
  typedef struct packed {
    apu_vgpu_csx_status_e status;
  } apu_vgpu_csx_cpl_t;

  // ColorWindowCheck (csx): Byte 0 of (1,0) in the color window is the sample red.
  typedef struct packed {
    logic valid;
    logic [7:0] b0;
    logic [15:0] off0;
    logic [15:0] off1;
    logic [6:0] x0;
    logic [6:0] x1;
    logic [31:0] origin;
    logic [31:0] neighbor;
  } apu_vgpu_csx_t;

  // ColorWindowRect (crd) status.
  typedef enum logic [1:0] {
    APU_VGPU_CRD_OK    = 2'd0,
    APU_VGPU_CRD_EMPTY = 2'd1,
    APU_VGPU_CRD_FAULT = 2'd2
  } apu_vgpu_crd_status_e;

  // ColorWindowRect (crd) completion.
  typedef struct packed {
    apu_vgpu_crd_status_e status;
  } apu_vgpu_crd_cpl_t;

  // ColorWindowRect (crd): 64 by 64 sample rectangle at the color window. The image is not kept.
  typedef struct packed {
    logic valid;
    logic [15:0] width;
    logic [15:0] height;
    logic [15:0] stride;
    logic [31:0] bytes;
    logic [31:0] format;
    logic [63:0] base;
    logic [31:0] origin;
    logic [31:0] neighbor;
  } apu_vgpu_crd_t;

  // ColorWindowRectLane (crl) status.
  typedef enum logic [1:0] {
    APU_VGPU_CRL_OK    = 2'd0,
    APU_VGPU_CRL_EMPTY = 2'd1,
    APU_VGPU_CRL_FAULT = 2'd2
  } apu_vgpu_crl_status_e;

  // ColorWindowRectLane (crl) completion.
  typedef struct packed {
    apu_vgpu_crl_status_e status;
  } apu_vgpu_crl_cpl_t;

  // ColorWindowRectLane (crl): (1,0) in that rectangle is the half blend. The image is not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [6:0] x;
    logic [6:0] y;
    logic [63:0] addr;
  } apu_vgpu_crl_t;

  // ColorWindowRectCheck (crx) status.
  typedef enum logic [1:0] {
    APU_VGPU_CRX_OK    = 2'd0,
    APU_VGPU_CRX_EMPTY = 2'd1,
    APU_VGPU_CRX_FAULT = 2'd2
  } apu_vgpu_crx_status_e;

  // ColorWindowRectCheck (crx) completion.
  typedef struct packed {
    apu_vgpu_crx_status_e status;
  } apu_vgpu_crx_cpl_t;

  // ColorWindowRectCheck (crx): Byte 0 of (1,0) in the sample rectangle is the sample red.
  typedef struct packed {
    logic valid;
    logic [7:0] b0;
    logic [31:0] word;
    logic [6:0] x;
    logic [6:0] y;
    logic [63:0] addr;
  } apu_vgpu_crx_t;

  // ColorWindowOffset (cof) status.
  typedef enum logic [1:0] {
    APU_VGPU_COF_OK    = 2'd0,
    APU_VGPU_COF_EMPTY = 2'd1,
    APU_VGPU_COF_FAULT = 2'd2
  } apu_vgpu_cof_status_e;

  // ColorWindowOffset (cof) completion.
  typedef struct packed {
    apu_vgpu_cof_status_e status;
  } apu_vgpu_cof_cpl_t;

  // ColorWindowOffset (cof): Byte offset of one point in the sample rectangle.
  typedef struct packed {
    logic valid;
    logic [15:0] offset;
    logic [63:0] addr;
    logic [6:0] x;
    logic [6:0] y;
  } apu_vgpu_cof_t;

  // ColorWindowOffsetOrigin (cor) status.
  typedef enum logic [1:0] {
    APU_VGPU_COR_OK    = 2'd0,
    APU_VGPU_COR_EMPTY = 2'd1,
    APU_VGPU_COR_FAULT = 2'd2
  } apu_vgpu_cor_status_e;

  // ColorWindowOffsetOrigin (cor) completion.
  typedef struct packed {
    apu_vgpu_cor_status_e status;
  } apu_vgpu_cor_cpl_t;

  // ColorWindowOffsetOrigin (cor): (0,0) in the sample rectangle is the clamp texel.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [15:0] offset;
    logic [6:0] x;
    logic [6:0] y;
    logic [63:0] addr;
  } apu_vgpu_cor_t;

  // ColorWindowOffsetCheck (cox) status.
  typedef enum logic [1:0] {
    APU_VGPU_COX_OK    = 2'd0,
    APU_VGPU_COX_EMPTY = 2'd1,
    APU_VGPU_COX_FAULT = 2'd2
  } apu_vgpu_cox_status_e;

  // ColorWindowOffsetCheck (cox) completion.
  typedef struct packed {
    apu_vgpu_cox_status_e status;
  } apu_vgpu_cox_cpl_t;

  // ColorWindowOffsetCheck (cox): Byte 0 of (0,0) is the sample red. The word is not the neighbor.
  typedef struct packed {
    logic valid;
    logic [7:0] b0;
    logic [31:0] word;
    logic [15:0] offset;
    logic [6:0] x;
    logic [6:0] y;
  } apu_vgpu_cox_t;

  // TransferDestCopy (rpw) status.
  typedef enum logic [1:0] {
    APU_VGPU_RPW_OK    = 2'd0,
    APU_VGPU_RPW_EMPTY = 2'd1,
    APU_VGPU_RPW_FAULT = 2'd2
  } apu_vgpu_rpw_status_e;

  // TransferDestCopy (rpw) completion.
  typedef struct packed {
    apu_vgpu_rpw_status_e status;
  } apu_vgpu_rpw_cpl_t;

  // TransferDestCopy (rpw): Guest copy of the 64 by 64 sample rectangle. The image is not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] origin;
    logic [31:0] neighbor;
    logic [15:0] beats;
    logic [63:0] src;
    logic [63:0] dst;
    logic [31:0] cmd;
    logic [31:0] resource_id;
  } apu_vgpu_rpw_t;

  // TransferDestRead (rpr) status.
  typedef enum logic [1:0] {
    APU_VGPU_RPR_OK    = 2'd0,
    APU_VGPU_RPR_EMPTY = 2'd1,
    APU_VGPU_RPR_FAULT = 2'd2
  } apu_vgpu_rpr_status_e;

  // TransferDestRead (rpr) completion.
  typedef struct packed {
    apu_vgpu_rpr_status_e status;
  } apu_vgpu_rpr_cpl_t;

  // TransferDestRead (rpr): Beat 0 of the guest buffer. (0,0) and (1,0) are the sample pair.
  typedef struct packed {
    logic valid;
    logic [31:0] origin;
    logic [31:0] neighbor;
    logic [15:0] off0;
    logic [15:0] off1;
    logic [6:0] x0;
    logic [6:0] x1;
    logic [63:0] base;
  } apu_vgpu_rpr_t;

  // TransferDestCheck (rpx) status.
  typedef enum logic [1:0] {
    APU_VGPU_RPX_OK    = 2'd0,
    APU_VGPU_RPX_EMPTY = 2'd1,
    APU_VGPU_RPX_FAULT = 2'd2
  } apu_vgpu_rpx_status_e;

  // TransferDestCheck (rpx) completion.
  typedef struct packed {
    apu_vgpu_rpx_status_e status;
  } apu_vgpu_rpx_cpl_t;

  // TransferDestCheck (rpx): Byte 0 of (1,0) in the guest buffer is the sample red.
  typedef struct packed {
    logic valid;
    logic [7:0] b0;
    logic [15:0] off0;
    logic [15:0] off1;
    logic [6:0] x0;
    logic [6:0] x1;
    logic [31:0] origin;
    logic [31:0] neighbor;
  } apu_vgpu_rpx_t;

  // GuestReadpixelsRect (grd) status.
  typedef enum logic [1:0] {
    APU_VGPU_GRD_OK    = 2'd0,
    APU_VGPU_GRD_EMPTY = 2'd1,
    APU_VGPU_GRD_FAULT = 2'd2
  } apu_vgpu_grd_status_e;

  // GuestReadpixelsRect (grd) completion.
  typedef struct packed {
    apu_vgpu_grd_status_e status;
  } apu_vgpu_grd_cpl_t;

  // GuestReadpixelsRect (grd): 64 by 64 guest readpixels rectangle. The image is not kept.
  typedef struct packed {
    logic valid;
    logic [15:0] width;
    logic [15:0] height;
    logic [15:0] stride;
    logic [31:0] bytes;
    logic [31:0] format;
    logic [63:0] base;
    logic [31:0] origin;
    logic [31:0] neighbor;
    logic [31:0] cmd;
  } apu_vgpu_grd_t;

  // GuestReadpixelsLane (grl) status.
  typedef enum logic [1:0] {
    APU_VGPU_GRL_OK    = 2'd0,
    APU_VGPU_GRL_EMPTY = 2'd1,
    APU_VGPU_GRL_FAULT = 2'd2
  } apu_vgpu_grl_status_e;

  // GuestReadpixelsLane (grl) completion.
  typedef struct packed {
    apu_vgpu_grl_status_e status;
  } apu_vgpu_grl_cpl_t;

  // GuestReadpixelsLane (grl): (1,0) in the guest rectangle is the half blend.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [6:0] x;
    logic [6:0] y;
    logic [63:0] addr;
  } apu_vgpu_grl_t;

  // GuestReadpixelsCheck (grx) status.
  typedef enum logic [1:0] {
    APU_VGPU_GRX_OK    = 2'd0,
    APU_VGPU_GRX_EMPTY = 2'd1,
    APU_VGPU_GRX_FAULT = 2'd2
  } apu_vgpu_grx_status_e;

  // GuestReadpixelsCheck (grx) completion.
  typedef struct packed {
    apu_vgpu_grx_status_e status;
  } apu_vgpu_grx_cpl_t;

  // GuestReadpixelsCheck (grx): Byte 0 of (1,0) in the guest rectangle is the sample red.
  typedef struct packed {
    logic valid;
    logic [7:0] b0;
    logic [31:0] word;
    logic [6:0] x;
    logic [6:0] y;
    logic [63:0] addr;
  } apu_vgpu_grx_t;

  // GuestReadpixelsOffset (rof) status.
  typedef enum logic [1:0] {
    APU_VGPU_ROF_OK    = 2'd0,
    APU_VGPU_ROF_EMPTY = 2'd1,
    APU_VGPU_ROF_FAULT = 2'd2
  } apu_vgpu_rof_status_e;

  // GuestReadpixelsOffset (rof) completion.
  typedef struct packed {
    apu_vgpu_rof_status_e status;
  } apu_vgpu_rof_cpl_t;

  // GuestReadpixelsOffset (rof): Byte offset of one point in the guest rectangle.
  typedef struct packed {
    logic valid;
    logic [15:0] offset;
    logic [63:0] addr;
    logic [6:0] x;
    logic [6:0] y;
  } apu_vgpu_rof_t;

  // GuestReadpixelsOffsetOrigin (ror) status.
  typedef enum logic [1:0] {
    APU_VGPU_ROR_OK    = 2'd0,
    APU_VGPU_ROR_EMPTY = 2'd1,
    APU_VGPU_ROR_FAULT = 2'd2
  } apu_vgpu_ror_status_e;

  // GuestReadpixelsOffsetOrigin (ror) completion.
  typedef struct packed {
    apu_vgpu_ror_status_e status;
  } apu_vgpu_ror_cpl_t;

  // GuestReadpixelsOffsetOrigin (ror): (0,0) in the guest rectangle is the clamp texel.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [15:0] offset;
    logic [6:0] x;
    logic [6:0] y;
    logic [63:0] addr;
  } apu_vgpu_ror_t;

  // GuestReadpixelsOffsetCheck (rox) status.
  typedef enum logic [1:0] {
    APU_VGPU_ROX_OK    = 2'd0,
    APU_VGPU_ROX_EMPTY = 2'd1,
    APU_VGPU_ROX_FAULT = 2'd2
  } apu_vgpu_rox_status_e;

  // GuestReadpixelsOffsetCheck (rox) completion.
  typedef struct packed {
    apu_vgpu_rox_status_e status;
  } apu_vgpu_rox_cpl_t;

  // GuestReadpixelsOffsetCheck (rox): Byte 0 of (0,0) in the guest rectangle is the sample red.
  typedef struct packed {
    logic valid;
    logic [7:0] b0;
    logic [31:0] word;
    logic [15:0] offset;
    logic [6:0] x;
    logic [6:0] y;
  } apu_vgpu_rox_t;

  // TransferBox (tfb) status.
  typedef enum logic [1:0] {
    APU_VGPU_TFB_OK    = 2'd0,
    APU_VGPU_TFB_EMPTY = 2'd1,
    APU_VGPU_TFB_FAULT = 2'd2
  } apu_vgpu_tfb_status_e;

  // TransferBox (tfb) completion.
  typedef struct packed {
    apu_vgpu_tfb_status_e status;
  } apu_vgpu_tfb_cpl_t;

  // TransferBox (tfb): Mesa glReadPixels box (0,0,64,64) of the 640 by 480 target.
  typedef struct packed {
    logic valid;
    logic [15:0] x;
    logic [15:0] y;
    logic [15:0] width;
    logic [15:0] height;
    logic [31:0] res_w;
    logic [31:0] res_h;
    logic [31:0] cmd;
    logic [31:0] resource_id;
  } apu_vgpu_tfb_t;

  // TransferBoxRead (tfr) status.
  typedef enum logic [1:0] {
    APU_VGPU_TFR_OK    = 2'd0,
    APU_VGPU_TFR_EMPTY = 2'd1,
    APU_VGPU_TFR_FAULT = 2'd2
  } apu_vgpu_tfr_status_e;

  // TransferBoxRead (tfr) completion.
  typedef struct packed {
    apu_vgpu_tfr_status_e status;
  } apu_vgpu_tfr_cpl_t;

  // TransferBoxRead (tfr): Guest TRANSFER_FROM_HOST_3D command of that box.
  typedef struct packed {
    logic valid;
    logic [15:0] x;
    logic [15:0] y;
    logic [15:0] width;
    logic [15:0] height;
    logic [31:0] stride;
    logic [31:0] resource_id;
    logic [31:0] cmd;
    logic [63:0] addr;
  } apu_vgpu_tfr_t;

  // TransferBoxCheck (tfx) status.
  typedef enum logic [1:0] {
    APU_VGPU_TFX_OK    = 2'd0,
    APU_VGPU_TFX_EMPTY = 2'd1,
    APU_VGPU_TFX_FAULT = 2'd2
  } apu_vgpu_tfx_status_e;

  // TransferBoxCheck (tfx) completion.
  typedef struct packed {
    apu_vgpu_tfx_status_e status;
  } apu_vgpu_tfx_cpl_t;

  // TransferBoxCheck (tfx): Packed stride of the box is 256, not the 640-wide resource row.
  typedef struct packed {
    logic valid;
    logic [31:0] stride;
    logic [15:0] x;
    logic [15:0] y;
    logic [31:0] res_w;
  } apu_vgpu_tfx_t;

  // TransferAttach (rab) status.
  typedef enum logic [1:0] {
    APU_VGPU_RAB_OK    = 2'd0,
    APU_VGPU_RAB_EMPTY = 2'd1,
    APU_VGPU_RAB_FAULT = 2'd2
  } apu_vgpu_rab_status_e;

  // TransferAttach (rab) completion.
  typedef struct packed {
    apu_vgpu_rab_status_e status;
  } apu_vgpu_rab_cpl_t;

  // TransferAttach (rab): RESOURCE_ATTACH_BACKING of the 64 by 64 readpixels buffer.
  typedef struct packed {
    logic valid;
    logic [63:0] addr;
    logic [31:0] length;
    logic [31:0] resource_id;
    logic [31:0] cmd;
  } apu_vgpu_rab_t;

  // TransferAttachRead (rar) status.
  typedef enum logic [1:0] {
    APU_VGPU_RAR_OK    = 2'd0,
    APU_VGPU_RAR_EMPTY = 2'd1,
    APU_VGPU_RAR_FAULT = 2'd2
  } apu_vgpu_rar_status_e;

  // TransferAttachRead (rar) completion.
  typedef struct packed {
    apu_vgpu_rar_status_e status;
  } apu_vgpu_rar_cpl_t;

  // TransferAttachRead (rar): Guest RESOURCE_ATTACH_BACKING command of that buffer.
  typedef struct packed {
    logic valid;
    logic [63:0] addr;
    logic [31:0] length;
    logic [31:0] resource_id;
    logic [31:0] cmd;
    logic [63:0] cmd_addr;
  } apu_vgpu_rar_t;

  // TransferAttachCheck (rax) status.
  typedef enum logic [1:0] {
    APU_VGPU_RAX_OK    = 2'd0,
    APU_VGPU_RAX_EMPTY = 2'd1,
    APU_VGPU_RAX_FAULT = 2'd2
  } apu_vgpu_rax_status_e;

  // TransferAttachCheck (rax) completion.
  typedef struct packed {
    apu_vgpu_rax_status_e status;
  } apu_vgpu_rax_cpl_t;

  // TransferAttachCheck (rax): Length of the readpixels backing is 16384, not 1228800.
  typedef struct packed {
    logic valid;
    logic [31:0] length;
    logic [63:0] addr;
    logic [31:0] resource_id;
  } apu_vgpu_rax_t;

  // TransferFence (rfw) status.
  typedef enum logic [1:0] {
    APU_VGPU_RFW_OK    = 2'd0,
    APU_VGPU_RFW_EMPTY = 2'd1,
    APU_VGPU_RFW_FAULT = 2'd2
  } apu_vgpu_rfw_status_e;

  // TransferFence (rfw) completion.
  typedef struct packed {
    apu_vgpu_rfw_status_e status;
  } apu_vgpu_rfw_cpl_t;

  // TransferFence (rfw): virtio OK_NODATA fence response of the 64 by 64 transfer.
  typedef struct packed {
    logic valid;
    logic [31:0] resp;
    logic [31:0] flags;
    logic [63:0] fence;
    logic [31:0] ctx_id;
    logic [63:0] addr;
  } apu_vgpu_rfw_t;

  // TransferFenceRead (rfr) status.
  typedef enum logic [1:0] {
    APU_VGPU_RFR_OK    = 2'd0,
    APU_VGPU_RFR_EMPTY = 2'd1,
    APU_VGPU_RFR_FAULT = 2'd2
  } apu_vgpu_rfr_status_e;

  // TransferFenceRead (rfr) completion.
  typedef struct packed {
    apu_vgpu_rfr_status_e status;
  } apu_vgpu_rfr_cpl_t;

  // TransferFenceRead (rfr): Guest read of that transfer response.
  typedef struct packed {
    logic valid;
    logic [31:0] resp;
    logic [31:0] flags;
    logic [63:0] fence;
    logic [31:0] ctx_id;
    logic [63:0] addr;
  } apu_vgpu_rfr_t;

  // TransferFenceCheck (rfx) status.
  typedef enum logic [1:0] {
    APU_VGPU_RFX_OK    = 2'd0,
    APU_VGPU_RFX_EMPTY = 2'd1,
    APU_VGPU_RFX_FAULT = 2'd2
  } apu_vgpu_rfx_status_e;

  // TransferFenceCheck (rfx) completion.
  typedef struct packed {
    apu_vgpu_rfx_status_e status;
  } apu_vgpu_rfx_cpl_t;

  // TransferFenceCheck (rfx): Fence 2 of the transfer, not the scene fence.
  typedef struct packed {
    logic valid;
    logic [63:0] fence;
    logic [31:0] flags;
    logic [31:0] resp;
  } apu_vgpu_rfx_t;

  // TransferUsed (tuw) status.
  typedef enum logic [1:0] {
    APU_VGPU_TUW_OK    = 2'd0,
    APU_VGPU_TUW_EMPTY = 2'd1,
    APU_VGPU_TUW_FAULT = 2'd2
  } apu_vgpu_tuw_status_e;

  // TransferUsed (tuw) completion.
  typedef struct packed {
    apu_vgpu_tuw_status_e status;
  } apu_vgpu_tuw_cpl_t;

  // TransferUsed (tuw): Used element of the 64 by 64 transfer. id 1, used.idx 2.
  typedef struct packed {
    logic valid;
    logic [31:0] elem_id;
    logic [31:0] elem_len;
    logic [15:0] used_idx;
    logic [63:0] elem_addr;
    logic [63:0] idx_addr;
  } apu_vgpu_tuw_t;

  // TransferUsedRead (tur) status.
  typedef enum logic [1:0] {
    APU_VGPU_TUR_OK    = 2'd0,
    APU_VGPU_TUR_EMPTY = 2'd1,
    APU_VGPU_TUR_FAULT = 2'd2
  } apu_vgpu_tur_status_e;

  // TransferUsedRead (tur) completion.
  typedef struct packed {
    apu_vgpu_tur_status_e status;
  } apu_vgpu_tur_cpl_t;

  // TransferUsedRead (tur): Guest read of that used element and index.
  typedef struct packed {
    logic valid;
    logic [31:0] elem_id;
    logic [31:0] elem_len;
    logic [15:0] used_idx;
    logic [63:0] elem_addr;
    logic [63:0] idx_addr;
  } apu_vgpu_tur_t;

  // TransferUsedCheck (tux) status.
  typedef enum logic [1:0] {
    APU_VGPU_TUX_OK    = 2'd0,
    APU_VGPU_TUX_EMPTY = 2'd1,
    APU_VGPU_TUX_FAULT = 2'd2
  } apu_vgpu_tux_status_e;

  // TransferUsedCheck (tux) completion.
  typedef struct packed {
    apu_vgpu_tux_status_e status;
  } apu_vgpu_tux_cpl_t;

  // TransferUsedCheck (tux): used.idx 2 of the transfer, not the scene index 1.
  typedef struct packed {
    logic valid;
    logic [15:0] used_idx;
    logic [31:0] elem_id;
  } apu_vgpu_tux_t;

  // TransferIrq (tiw) status.
  typedef enum logic [1:0] {
    APU_VGPU_TIW_OK    = 2'd0,
    APU_VGPU_TIW_EMPTY = 2'd1,
    APU_VGPU_TIW_FAULT = 2'd2
  } apu_vgpu_tiw_status_e;

  // TransferIrq (tiw) completion.
  typedef struct packed {
    apu_vgpu_tiw_status_e status;
  } apu_vgpu_tiw_cpl_t;

  // TransferIrq (tiw): Used-buffer interrupt of the 64 by 64 transfer.
  typedef struct packed {
    logic valid;
    logic [31:0] reason;
    logic [15:0] used_idx;
    logic [63:0] addr;
  } apu_vgpu_tiw_t;

  // TransferIrqRead (tir) status.
  typedef enum logic [1:0] {
    APU_VGPU_TIR_OK    = 2'd0,
    APU_VGPU_TIR_EMPTY = 2'd1,
    APU_VGPU_TIR_FAULT = 2'd2
  } apu_vgpu_tir_status_e;

  // TransferIrqRead (tir) completion.
  typedef struct packed {
    apu_vgpu_tir_status_e status;
  } apu_vgpu_tir_cpl_t;

  // TransferIrqRead (tir): Guest read of that interrupt reason.
  typedef struct packed {
    logic valid;
    logic [31:0] reason;
    logic [15:0] used_idx;
    logic [63:0] addr;
  } apu_vgpu_tir_t;

  // TransferIrqCheck (tix) status.
  typedef enum logic [1:0] {
    APU_VGPU_TIX_OK    = 2'd0,
    APU_VGPU_TIX_EMPTY = 2'd1,
    APU_VGPU_TIX_FAULT = 2'd2
  } apu_vgpu_tix_status_e;

  // TransferIrqCheck (tix) completion.
  typedef struct packed {
    apu_vgpu_tix_status_e status;
  } apu_vgpu_tix_cpl_t;

  // TransferIrqCheck (tix): Reason 32'h1 at 64'h880C0000, not the scene status word.
  typedef struct packed {
    logic valid;
    logic [31:0] reason;
    logic [15:0] used_idx;
    logic [63:0] addr;
  } apu_vgpu_tix_t;

  // TransferAck (taw) status.
  typedef enum logic [1:0] {
    APU_VGPU_TAW_OK    = 2'd0,
    APU_VGPU_TAW_EMPTY = 2'd1,
    APU_VGPU_TAW_FAULT = 2'd2
  } apu_vgpu_taw_status_e;

  // TransferAck (taw) completion.
  typedef struct packed {
    apu_vgpu_taw_status_e status;
  } apu_vgpu_taw_cpl_t;

  // TransferAck (taw): Guest ack of the 64 by 64 transfer interrupt.
  typedef struct packed {
    logic valid;
    logic [31:0] ack;
    logic [31:0] remain;
    logic [15:0] used_idx;
    logic [63:0] ack_addr;
    logic [63:0] status_addr;
  } apu_vgpu_taw_t;

  // TransferAckRead (tar) status.
  typedef enum logic [1:0] {
    APU_VGPU_TAR_OK    = 2'd0,
    APU_VGPU_TAR_EMPTY = 2'd1,
    APU_VGPU_TAR_FAULT = 2'd2
  } apu_vgpu_tar_status_e;

  // TransferAckRead (tar) completion.
  typedef struct packed {
    apu_vgpu_tar_status_e status;
  } apu_vgpu_tar_cpl_t;

  // TransferAckRead (tar): Guest read of that ack and the cleared status.
  typedef struct packed {
    logic valid;
    logic [31:0] ack;
    logic [31:0] remain;
    logic [15:0] used_idx;
    logic [63:0] ack_addr;
    logic [63:0] status_addr;
  } apu_vgpu_tar_t;

  // TransferAckCheck (tax) status.
  typedef enum logic [1:0] {
    APU_VGPU_TAX_OK    = 2'd0,
    APU_VGPU_TAX_EMPTY = 2'd1,
    APU_VGPU_TAX_FAULT = 2'd2
  } apu_vgpu_tax_status_e;

  // TransferAckCheck (tax) completion.
  typedef struct packed {
    apu_vgpu_tax_status_e status;
  } apu_vgpu_tax_cpl_t;

  // TransferAckCheck (tax): Ack 32'h1 and remain 0 with used.idx 2.
  typedef struct packed {
    logic valid;
    logic [31:0] ack;
    logic [31:0] remain;
    logic [15:0] used_idx;
  } apu_vgpu_tax_t;

  // TransferChain (txc) status.
  typedef enum logic [1:0] {
    APU_VGPU_TXC_OK    = 2'd0,
    APU_VGPU_TXC_EMPTY = 2'd1,
    APU_VGPU_TXC_FAULT = 2'd2
  } apu_vgpu_txc_status_e;

  // TransferChain (txc) completion.
  typedef struct packed {
    apu_vgpu_txc_status_e status;
  } apu_vgpu_txc_cpl_t;

  // TransferChain (txc): Head descriptor 0, the attach, the transfer, the response, and
  // avail index 2. The descriptor bytes are not kept. This is not
  // g6lc_apu_vgpu_avail and not g6lc_apu_vgpu_nxc.
  typedef struct packed {
    logic valid;
    logic [15:0] head;
    logic [15:0] avail_idx;
    logic [31:0] att_len;
    logic [63:0] att_addr;
    logic [63:0] xfer_addr;
    logic [63:0] rsp_addr;
  } apu_vgpu_txc_t;

  // TransferChainKeep (txk) status.
  typedef enum logic [1:0] {
    APU_VGPU_TXK_OK    = 2'd0,
    APU_VGPU_TXK_EMPTY = 2'd1,
    APU_VGPU_TXK_FAULT = 2'd2
  } apu_vgpu_txk_status_e;

  // TransferChainKeep (txk) completion.
  typedef struct packed {
    apu_vgpu_txk_status_e status;
  } apu_vgpu_txk_cpl_t;

  // TransferChainKeep (txk): Kept head, avail index 2, attach, transfer, and response.
  typedef struct packed {
    logic valid;
    logic [15:0] head;
    logic [15:0] avail_idx;
    logic [31:0] att_len;
    logic [63:0] att_addr;
    logic [63:0] xfer_addr;
    logic [63:0] rsp_addr;
  } apu_vgpu_txk_t;

  // TransferChainCheck (txx) status.
  typedef enum logic [1:0] {
    APU_VGPU_TXX_OK    = 2'd0,
    APU_VGPU_TXX_EMPTY = 2'd1,
    APU_VGPU_TXX_FAULT = 2'd2
  } apu_vgpu_txx_status_e;

  // TransferChainCheck (txx) completion.
  typedef struct packed {
    apu_vgpu_txx_status_e status;
  } apu_vgpu_txx_cpl_t;

  // TransferChainCheck (txx): Avail index 2, not the scene index 1.
  typedef struct packed {
    logic valid;
    logic [15:0] head;
    logic [15:0] avail_idx;
    logic [63:0] att_addr;
  } apu_vgpu_txx_t;

  // TexSample (ftx) status.
  typedef enum logic [1:0] {
    APU_VGPU_FTX_OK    = 2'd0,
    APU_VGPU_FTX_EMPTY = 2'd1,
    APU_VGPU_FTX_FAULT = 2'd2
  } apu_vgpu_ftx_status_e;

  // TexSample (ftx) completion.
  typedef struct packed {
    apu_vgpu_ftx_status_e status;
  } apu_vgpu_ftx_cpl_t;

  // TexSample (ftx): TEX of sampler view 5. (0,0) is the clamp texel. (1,0) is the
  // half blend. refused is 0. The compiler opcode still returns -26.
  typedef struct packed {
    logic valid;
    logic refused;
    logic [31:0] resource_id;
    logic [31:0] view;
    logic [31:0] origin;
    logic [31:0] neighbor;
  } apu_vgpu_ftx_t;

  // TexSampleKeep (ftr) status.
  typedef enum logic [1:0] {
    APU_VGPU_FTR_OK    = 2'd0,
    APU_VGPU_FTR_EMPTY = 2'd1,
    APU_VGPU_FTR_FAULT = 2'd2
  } apu_vgpu_ftr_status_e;

  // TexSampleKeep (ftr) completion.
  typedef struct packed {
    apu_vgpu_ftr_status_e status;
  } apu_vgpu_ftr_cpl_t;

  // TexSampleKeep (ftr): Kept TEX result. refused stays 0.
  typedef struct packed {
    logic valid;
    logic refused;
    logic [31:0] resource_id;
    logic [31:0] view;
    logic [31:0] origin;
    logic [31:0] neighbor;
  } apu_vgpu_ftr_t;

  // TexSampleCheck (ftk) status.
  typedef enum logic [1:0] {
    APU_VGPU_FTK_OK    = 2'd0,
    APU_VGPU_FTK_EMPTY = 2'd1,
    APU_VGPU_FTK_FAULT = 2'd2
  } apu_vgpu_ftk_status_e;

  // TexSampleCheck (ftk) completion.
  typedef struct packed {
    apu_vgpu_ftk_status_e status;
  } apu_vgpu_ftk_cpl_t;

  // TexSampleCheck (ftk): refused 0, origin not the clear word, not the neighbor.
  typedef struct packed {
    logic valid;
    logic refused;
    logic [31:0] origin;
    logic [31:0] neighbor;
  } apu_vgpu_ftk_t;

  // SceneWindowTexWrite (ocw) status.
  typedef enum logic [1:0] {
    APU_VGPU_OCW_OK    = 2'd0,
    APU_VGPU_OCW_EMPTY = 2'd1,
    APU_VGPU_OCW_FAULT = 2'd2
  } apu_vgpu_ocw_status_e;

  // SceneWindowTexWrite (ocw) completion.
  typedef struct packed {
    apu_vgpu_ocw_status_e status;
  } apu_vgpu_ocw_cpl_t;

  // SceneWindowTexWrite (ocw): TEX pair in beat 0 of the scene window. The rest of the window
  // is not stored.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [63:0] base;
    logic [15:0] off0;
    logic [15:0] off1;
    logic [6:0] x0;
    logic [6:0] x1;
    logic [31:0] origin;
    logic [31:0] neighbor;
  } apu_vgpu_ocw_t;

  // SceneWindowTexRead (ocr) status.
  typedef enum logic [1:0] {
    APU_VGPU_OCR_OK    = 2'd0,
    APU_VGPU_OCR_EMPTY = 2'd1,
    APU_VGPU_OCR_FAULT = 2'd2
  } apu_vgpu_ocr_status_e;

  // SceneWindowTexRead (ocr) completion.
  typedef struct packed {
    apu_vgpu_ocr_status_e status;
  } apu_vgpu_ocr_cpl_t;

  // SceneWindowTexRead (ocr): Those two words read back from 64'h88020000.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [63:0] base;
    logic [15:0] off0;
    logic [15:0] off1;
    logic [6:0] x0;
    logic [6:0] x1;
    logic [31:0] origin;
    logic [31:0] neighbor;
  } apu_vgpu_ocr_t;

  // SceneWindowTexCheck (ocx) status.
  typedef enum logic [1:0] {
    APU_VGPU_OCX_OK    = 2'd0,
    APU_VGPU_OCX_EMPTY = 2'd1,
    APU_VGPU_OCX_FAULT = 2'd2
  } apu_vgpu_ocx_status_e;

  // SceneWindowTexCheck (ocx) completion.
  typedef struct packed {
    apu_vgpu_ocx_status_e status;
  } apu_vgpu_ocx_cpl_t;

  // SceneWindowTexCheck (ocx): Byte 0 of (0,0) is the sample red. The clear word records nothing.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off0;
    logic [15:0] off1;
    logic [6:0] x0;
    logic [6:0] x1;
    logic [7:0] b0;
    logic [31:0] origin;
    logic [31:0] neighbor;
  } apu_vgpu_ocx_t;

  // ReadbackTexWrite (pbw) status.
  typedef enum logic [1:0] {
    APU_VGPU_PBW_OK    = 2'd0,
    APU_VGPU_PBW_EMPTY = 2'd1,
    APU_VGPU_PBW_FAULT = 2'd2
  } apu_vgpu_pbw_status_e;

  // ReadbackTexWrite (pbw) completion.
  typedef struct packed {
    apu_vgpu_pbw_status_e status;
  } apu_vgpu_pbw_cpl_t;

  // ReadbackTexWrite (pbw): TEX pair in beat 0 of the guest readback. The rest is not stored.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [63:0] base;
    logic [15:0] off0;
    logic [15:0] off1;
    logic [6:0] x0;
    logic [6:0] x1;
    logic [31:0] origin;
    logic [31:0] neighbor;
  } apu_vgpu_pbw_t;

  // ReadbackTexRead (pbr) status.
  typedef enum logic [1:0] {
    APU_VGPU_PBR_OK    = 2'd0,
    APU_VGPU_PBR_EMPTY = 2'd1,
    APU_VGPU_PBR_FAULT = 2'd2
  } apu_vgpu_pbr_status_e;

  // ReadbackTexRead (pbr) completion.
  typedef struct packed {
    apu_vgpu_pbr_status_e status;
  } apu_vgpu_pbr_cpl_t;

  // ReadbackTexRead (pbr): Those two words read back from 64'h88030000.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [63:0] base;
    logic [15:0] off0;
    logic [15:0] off1;
    logic [6:0] x0;
    logic [6:0] x1;
    logic [31:0] origin;
    logic [31:0] neighbor;
  } apu_vgpu_pbr_t;

  // ReadbackTexCheck (pbx) status.
  typedef enum logic [1:0] {
    APU_VGPU_PBX_OK    = 2'd0,
    APU_VGPU_PBX_EMPTY = 2'd1,
    APU_VGPU_PBX_FAULT = 2'd2
  } apu_vgpu_pbx_status_e;

  // ReadbackTexCheck (pbx) completion.
  typedef struct packed {
    apu_vgpu_pbx_status_e status;
  } apu_vgpu_pbx_cpl_t;

  // ReadbackTexCheck (pbx): Byte 0 of (0,0) in the readback is the sample red.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off0;
    logic [15:0] off1;
    logic [6:0] x0;
    logic [6:0] x1;
    logic [7:0] b0;
    logic [31:0] origin;
    logic [31:0] neighbor;
  } apu_vgpu_pbx_t;

  // TransferNextWalk (tnw) op.
  typedef enum logic [1:0] {
    APU_VGPU_TNW_POST  = 2'd0,
    APU_VGPU_TNW_AVAIL = 2'd1,
    APU_VGPU_TNW_WALK  = 2'd2
  } apu_vgpu_tnw_op_e;

  // TransferNextWalk (tnw) request.
  typedef struct packed {
    apu_vgpu_tnw_op_e op;
    logic [15:0] avail_idx;
    logic [15:0] desc_id;
    apu_vgpu_desc_t desc;
  } apu_vgpu_tnw_req_t;

  // TransferNextWalk (tnw) status.
  typedef enum logic [1:0] {
    APU_VGPU_TNW_OK    = 2'd0,
    APU_VGPU_TNW_EMPTY = 2'd1,
    APU_VGPU_TNW_FAULT = 2'd2
  } apu_vgpu_tnw_status_e;

  // TransferNextWalk (tnw) completion.
  typedef struct packed {
    apu_vgpu_tnw_status_e status;
  } apu_vgpu_tnw_cpl_t;

  // TransferNextWalk (tnw): Posted transfer chain with NEXT accepted. Avail index 2. This does
  // not read guest memory and it is not g6lc_apu_vgpu_avail.
  typedef struct packed {
    logic valid;
    logic [15:0] head;
    logic [15:0] avail_idx;
    logic [15:0] device_idx;
    logic [63:0] att_addr;
    logic [63:0] xfer_addr;
    logic [63:0] rsp_addr;
  } apu_vgpu_tnw_t;

  // TransferNextKeep (tnk) status.
  typedef enum logic [1:0] {
    APU_VGPU_TNK_OK    = 2'd0,
    APU_VGPU_TNK_EMPTY = 2'd1,
    APU_VGPU_TNK_FAULT = 2'd2
  } apu_vgpu_tnk_status_e;

  // TransferNextKeep (tnk) completion.
  typedef struct packed {
    apu_vgpu_tnk_status_e status;
  } apu_vgpu_tnk_cpl_t;

  // TransferNextKeep (tnk): Kept walked transfer chain. Avail index 2.
  typedef struct packed {
    logic valid;
    logic [15:0] head;
    logic [15:0] avail_idx;
    logic [15:0] device_idx;
    logic [63:0] att_addr;
    logic [63:0] xfer_addr;
    logic [63:0] rsp_addr;
  } apu_vgpu_tnk_t;

  // TransferNextCheck (tnx) status.
  typedef enum logic [1:0] {
    APU_VGPU_TNX_OK    = 2'd0,
    APU_VGPU_TNX_EMPTY = 2'd1,
    APU_VGPU_TNX_FAULT = 2'd2
  } apu_vgpu_tnx_status_e;

  // TransferNextCheck (tnx) completion.
  typedef struct packed {
    apu_vgpu_tnx_status_e status;
  } apu_vgpu_tnx_cpl_t;

  // TransferNextCheck (tnx): Avail index 2, NEXT accepted, not the scene index 1.
  typedef struct packed {
    logic valid;
    logic [15:0] avail_idx;
    logic [15:0] device_idx;
    logic [63:0] att_addr;
  } apu_vgpu_tnx_t;

  // TransferQueueNotify (qnt) status.
  typedef enum logic [1:0] {
    APU_VGPU_QNT_OK    = 2'd0,
    APU_VGPU_QNT_EMPTY = 2'd1,
    APU_VGPU_QNT_FAULT = 2'd2
  } apu_vgpu_qnt_status_e;

  // TransferQueueNotify (qnt) completion.
  typedef struct packed {
    apu_vgpu_qnt_status_e status;
  } apu_vgpu_qnt_cpl_t;

  // TransferQueueNotify (qnt): Guest QueueNotify of control queue 0 after avail index 2.
  typedef struct packed {
    logic valid;
    logic [31:0] qid;
    logic [15:0] avail_idx;
    logic [63:0] addr;
  } apu_vgpu_qnt_t;

  // TransferQueueNotifyRead (qnr) status.
  typedef enum logic [1:0] {
    APU_VGPU_QNR_OK    = 2'd0,
    APU_VGPU_QNR_EMPTY = 2'd1,
    APU_VGPU_QNR_FAULT = 2'd2
  } apu_vgpu_qnr_status_e;

  // TransferQueueNotifyRead (qnr) completion.
  typedef struct packed {
    apu_vgpu_qnr_status_e status;
  } apu_vgpu_qnr_cpl_t;

  // TransferQueueNotifyRead (qnr): Guest read of that notify word.
  typedef struct packed {
    logic valid;
    logic [31:0] qid;
    logic [15:0] avail_idx;
    logic [63:0] addr;
  } apu_vgpu_qnr_t;

  // TransferQueueNotifyCheck (qnx) status.
  typedef enum logic [1:0] {
    APU_VGPU_QNX_OK    = 2'd0,
    APU_VGPU_QNX_EMPTY = 2'd1,
    APU_VGPU_QNX_FAULT = 2'd2
  } apu_vgpu_qnx_status_e;

  // TransferQueueNotifyCheck (qnx) completion.
  typedef struct packed {
    apu_vgpu_qnx_status_e status;
  } apu_vgpu_qnx_cpl_t;

  // TransferQueueNotifyCheck (qnx): Control queue 0, not the cursor queue, after avail index 2.
  typedef struct packed {
    logic valid;
    logic [31:0] qid;
    logic [15:0] avail_idx;
  } apu_vgpu_qnx_t;

  // TransferAvailIdx (qav) status.
  typedef enum logic [1:0] {
    APU_VGPU_QAV_OK    = 2'd0,
    APU_VGPU_QAV_EMPTY = 2'd1,
    APU_VGPU_QAV_FAULT = 2'd2
  } apu_vgpu_qav_status_e;

  // TransferAvailIdx (qav) completion.
  typedef struct packed {
    apu_vgpu_qav_status_e status;
  } apu_vgpu_qav_cpl_t;

  // TransferAvailIdx (qav): Guest virtq_avail.idx 2 after QueueNotify of queue 0.
  typedef struct packed {
    logic valid;
    logic [15:0] avail_idx;
    logic [63:0] addr;
  } apu_vgpu_qav_t;

  // TransferAvailIdxKeep (qak) status.
  typedef enum logic [1:0] {
    APU_VGPU_QAK_OK    = 2'd0,
    APU_VGPU_QAK_EMPTY = 2'd1,
    APU_VGPU_QAK_FAULT = 2'd2
  } apu_vgpu_qak_status_e;

  // TransferAvailIdxKeep (qak) completion.
  typedef struct packed {
    apu_vgpu_qak_status_e status;
  } apu_vgpu_qak_cpl_t;

  // TransferAvailIdxKeep (qak): Keep that avail.idx. Not the scene ring.
  typedef struct packed {
    logic valid;
    logic [15:0] avail_idx;
    logic [63:0] addr;
  } apu_vgpu_qak_t;

  // TransferAvailIdxCheck (qax) status.
  typedef enum logic [1:0] {
    APU_VGPU_QAX_OK    = 2'd0,
    APU_VGPU_QAX_EMPTY = 2'd1,
    APU_VGPU_QAX_FAULT = 2'd2
  } apu_vgpu_qax_status_e;

  // TransferAvailIdxCheck (qax) completion.
  typedef struct packed {
    apu_vgpu_qax_status_e status;
  } apu_vgpu_qax_cpl_t;

  // TransferAvailIdxCheck (qax): Avail index 2 at 64'h880D0100, not scene index 1.
  typedef struct packed {
    logic valid;
    logic [15:0] avail_idx;
  } apu_vgpu_qax_t;

  // TransferAvailRing (qrg) status.
  typedef enum logic [1:0] {
    APU_VGPU_QRG_OK    = 2'd0,
    APU_VGPU_QRG_EMPTY = 2'd1,
    APU_VGPU_QRG_FAULT = 2'd2
  } apu_vgpu_qrg_status_e;

  // TransferAvailRing (qrg) completion.
  typedef struct packed {
    apu_vgpu_qrg_status_e status;
  } apu_vgpu_qrg_cpl_t;

  // TransferAvailRing (qrg): Guest avail ring[0] names descriptor 0 after idx 2.
  typedef struct packed {
    logic valid;
    logic [15:0] desc_id;
    logic [63:0] addr;
  } apu_vgpu_qrg_t;

  // TransferAvailRingKeep (qrk) status.
  typedef enum logic [1:0] {
    APU_VGPU_QRK_OK    = 2'd0,
    APU_VGPU_QRK_EMPTY = 2'd1,
    APU_VGPU_QRK_FAULT = 2'd2
  } apu_vgpu_qrk_status_e;

  // TransferAvailRingKeep (qrk) completion.
  typedef struct packed {
    apu_vgpu_qrk_status_e status;
  } apu_vgpu_qrk_cpl_t;

  // TransferAvailRingKeep (qrk): Keep that ring name. Not the scene ring.
  typedef struct packed {
    logic valid;
    logic [15:0] desc_id;
    logic [63:0] addr;
  } apu_vgpu_qrk_t;

  // TransferAvailRingCheck (qrx) status.
  typedef enum logic [1:0] {
    APU_VGPU_QRX_OK    = 2'd0,
    APU_VGPU_QRX_EMPTY = 2'd1,
    APU_VGPU_QRX_FAULT = 2'd2
  } apu_vgpu_qrx_status_e;

  // TransferAvailRingCheck (qrx) completion.
  typedef struct packed {
    apu_vgpu_qrx_status_e status;
  } apu_vgpu_qrx_cpl_t;

  // TransferAvailRingCheck (qrx): Descriptor 0 at 64'h880D0104, not scene ring[0].
  typedef struct packed {
    logic valid;
    logic [15:0] desc_id;
  } apu_vgpu_qrx_t;

  // TransferDesc0 (qhd) status.
  typedef enum logic [1:0] {
    APU_VGPU_QHD_OK    = 2'd0,
    APU_VGPU_QHD_EMPTY = 2'd1,
    APU_VGPU_QHD_FAULT = 2'd2
  } apu_vgpu_qhd_status_e;

  // TransferDesc0 (qhd) completion.
  typedef struct packed {
    apu_vgpu_qhd_status_e status;
  } apu_vgpu_qhd_cpl_t;

  // TransferDesc0 (qhd): Guest virtq_desc 0: attach at RAB_CMD, NEXT to 1.
  typedef struct packed {
    logic valid;
    logic [63:0] att_addr;
    logic [31:0] att_len;
    logic [15:0] nxt;
  } apu_vgpu_qhd_t;

  // TransferDesc0Keep (qhk) status.
  typedef enum logic [1:0] {
    APU_VGPU_QHK_OK    = 2'd0,
    APU_VGPU_QHK_EMPTY = 2'd1,
    APU_VGPU_QHK_FAULT = 2'd2
  } apu_vgpu_qhk_status_e;

  // TransferDesc0Keep (qhk) completion.
  typedef struct packed {
    apu_vgpu_qhk_status_e status;
  } apu_vgpu_qhk_cpl_t;

  // TransferDesc0Keep (qhk): Keep that attach descriptor. Not the scene table.
  typedef struct packed {
    logic valid;
    logic [63:0] att_addr;
    logic [31:0] att_len;
    logic [15:0] nxt;
  } apu_vgpu_qhk_t;

  // TransferDesc0Check (qhx) status.
  typedef enum logic [1:0] {
    APU_VGPU_QHX_OK    = 2'd0,
    APU_VGPU_QHX_EMPTY = 2'd1,
    APU_VGPU_QHX_FAULT = 2'd2
  } apu_vgpu_qhx_status_e;

  // TransferDesc0Check (qhx) completion.
  typedef struct packed {
    apu_vgpu_qhx_status_e status;
  } apu_vgpu_qhx_cpl_t;

  // TransferDesc0Check (qhx): Attach at RAB_CMD, NEXT to 1, not the scene table.
  typedef struct packed {
    logic valid;
    logic [63:0] att_addr;
    logic [15:0] nxt;
  } apu_vgpu_qhx_t;

  // TransferDesc1 (qfd) status.
  typedef enum logic [1:0] {
    APU_VGPU_QFD_OK    = 2'd0,
    APU_VGPU_QFD_EMPTY = 2'd1,
    APU_VGPU_QFD_FAULT = 2'd2
  } apu_vgpu_qfd_status_e;

  // TransferDesc1 (qfd) completion.
  typedef struct packed {
    apu_vgpu_qfd_status_e status;
  } apu_vgpu_qfd_cpl_t;

  // TransferDesc1 (qfd): Guest virtq_desc 1: transfer at TFB_CMD, NEXT to 2.
  typedef struct packed {
    logic valid;
    logic [63:0] xfer_addr;
    logic [31:0] xfer_len;
    logic [15:0] nxt;
  } apu_vgpu_qfd_t;

  // TransferDesc1Keep (qfk) status.
  typedef enum logic [1:0] {
    APU_VGPU_QFK_OK    = 2'd0,
    APU_VGPU_QFK_EMPTY = 2'd1,
    APU_VGPU_QFK_FAULT = 2'd2
  } apu_vgpu_qfk_status_e;

  // TransferDesc1Keep (qfk) completion.
  typedef struct packed {
    apu_vgpu_qfk_status_e status;
  } apu_vgpu_qfk_cpl_t;

  // TransferDesc1Keep (qfk): Keep that transfer descriptor. Not desc 0.
  typedef struct packed {
    logic valid;
    logic [63:0] xfer_addr;
    logic [31:0] xfer_len;
    logic [15:0] nxt;
  } apu_vgpu_qfk_t;

  // TransferDesc1Check (qfx) status.
  typedef enum logic [1:0] {
    APU_VGPU_QFX_OK    = 2'd0,
    APU_VGPU_QFX_EMPTY = 2'd1,
    APU_VGPU_QFX_FAULT = 2'd2
  } apu_vgpu_qfx_status_e;

  // TransferDesc1Check (qfx) completion.
  typedef struct packed {
    apu_vgpu_qfx_status_e status;
  } apu_vgpu_qfx_cpl_t;

  // TransferDesc1Check (qfx): Transfer at TFB_CMD, NEXT to 2, not the attach.
  typedef struct packed {
    logic valid;
    logic [63:0] xfer_addr;
    logic [15:0] nxt;
  } apu_vgpu_qfx_t;

  // TransferDesc2 (qwd) status.
  typedef enum logic [1:0] {
    APU_VGPU_QWD_OK    = 2'd0,
    APU_VGPU_QWD_EMPTY = 2'd1,
    APU_VGPU_QWD_FAULT = 2'd2
  } apu_vgpu_qwd_status_e;

  // TransferDesc2 (qwd) completion.
  typedef struct packed {
    apu_vgpu_qwd_status_e status;
  } apu_vgpu_qwd_cpl_t;

  // TransferDesc2 (qwd): Guest virtq_desc 2: WRITE of the response at RFW_ADDR.
  typedef struct packed {
    logic valid;
    logic [63:0] rsp_addr;
    logic [31:0] rsp_len;
  } apu_vgpu_qwd_t;

  // TransferDesc2Keep (qwk) status.
  typedef enum logic [1:0] {
    APU_VGPU_QWK_OK    = 2'd0,
    APU_VGPU_QWK_EMPTY = 2'd1,
    APU_VGPU_QWK_FAULT = 2'd2
  } apu_vgpu_qwk_status_e;

  // TransferDesc2Keep (qwk) completion.
  typedef struct packed {
    apu_vgpu_qwk_status_e status;
  } apu_vgpu_qwk_cpl_t;

  // TransferDesc2Keep (qwk): Keep that WRITE descriptor. Not the transfer.
  typedef struct packed {
    logic valid;
    logic [63:0] rsp_addr;
    logic [31:0] rsp_len;
  } apu_vgpu_qwk_t;

  // TransferDesc2Check (qwx) status.
  typedef enum logic [1:0] {
    APU_VGPU_QWX_OK    = 2'd0,
    APU_VGPU_QWX_EMPTY = 2'd1,
    APU_VGPU_QWX_FAULT = 2'd2
  } apu_vgpu_qwx_status_e;

  // TransferDesc2Check (qwx) completion.
  typedef struct packed {
    apu_vgpu_qwx_status_e status;
  } apu_vgpu_qwx_cpl_t;

  // TransferDesc2Check (qwx): WRITE at RFW_ADDR, length 24, not the transfer.
  typedef struct packed {
    logic valid;
    logic [63:0] rsp_addr;
  } apu_vgpu_qwx_t;

  // TransferOkNodata (qok) status.
  typedef enum logic [1:0] {
    APU_VGPU_QOK_OK    = 2'd0,
    APU_VGPU_QOK_EMPTY = 2'd1,
    APU_VGPU_QOK_FAULT = 2'd2
  } apu_vgpu_qok_status_e;

  // TransferOkNodata (qok) completion.
  typedef struct packed {
    apu_vgpu_qok_status_e status;
  } apu_vgpu_qok_cpl_t;

  // TransferOkNodata (qok): Guest OK_NODATA at RFW_ADDR after the named WRITE.
  typedef struct packed {
    logic valid;
    logic [31:0] resp;
    logic [63:0] fence;
    logic [63:0] addr;
  } apu_vgpu_qok_t;

  // TransferOkNodataRead (qol) status.
  typedef enum logic [1:0] {
    APU_VGPU_QOL_OK    = 2'd0,
    APU_VGPU_QOL_EMPTY = 2'd1,
    APU_VGPU_QOL_FAULT = 2'd2
  } apu_vgpu_qol_status_e;

  // TransferOkNodataRead (qol) completion.
  typedef struct packed {
    apu_vgpu_qol_status_e status;
  } apu_vgpu_qol_cpl_t;

  // TransferOkNodataRead (qol): Guest read of that OK_NODATA. Fence 2.
  typedef struct packed {
    logic valid;
    logic [31:0] resp;
    logic [31:0] flg;
    logic [63:0] fence;
    logic [63:0] addr;
  } apu_vgpu_qol_t;

  // TransferOkNodataCheck (qox) status.
  typedef enum logic [1:0] {
    APU_VGPU_QOX_OK    = 2'd0,
    APU_VGPU_QOX_EMPTY = 2'd1,
    APU_VGPU_QOX_FAULT = 2'd2
  } apu_vgpu_qox_status_e;

  // TransferOkNodataCheck (qox) completion.
  typedef struct packed {
    apu_vgpu_qox_status_e status;
  } apu_vgpu_qox_cpl_t;

  // TransferOkNodataCheck (qox): Fence 2 OK_NODATA at 64'h880A0000, not the scene fence.
  typedef struct packed {
    logic valid;
    logic [63:0] fence;
    logic [31:0] resp;
  } apu_vgpu_qox_t;

  // TransferUsedWrite (quw) status.
  typedef enum logic [1:0] {
    APU_VGPU_QUW_OK    = 2'd0,
    APU_VGPU_QUW_EMPTY = 2'd1,
    APU_VGPU_QUW_FAULT = 2'd2
  } apu_vgpu_quw_status_e;

  // TransferUsedWrite (quw) completion.
  typedef struct packed {
    apu_vgpu_quw_status_e status;
  } apu_vgpu_quw_cpl_t;

  // TransferUsedWrite (quw): Guest used element after OK_NODATA. id 1, used.idx 2.
  typedef struct packed {
    logic valid;
    logic [31:0] elem_id;
    logic [31:0] elem_len;
    logic [15:0] used_idx;
    logic [63:0] elem_addr;
    logic [63:0] idx_addr;
  } apu_vgpu_quw_t;

  // TransferUsedWriteRead (qul) status.
  typedef enum logic [1:0] {
    APU_VGPU_QUL_OK    = 2'd0,
    APU_VGPU_QUL_EMPTY = 2'd1,
    APU_VGPU_QUL_FAULT = 2'd2
  } apu_vgpu_qul_status_e;

  // TransferUsedWriteRead (qul) completion.
  typedef struct packed {
    apu_vgpu_qul_status_e status;
  } apu_vgpu_qul_cpl_t;

  // TransferUsedWriteRead (qul): Guest read of that used element and index.
  typedef struct packed {
    logic valid;
    logic [31:0] elem_id;
    logic [31:0] elem_len;
    logic [15:0] used_idx;
    logic [63:0] elem_addr;
    logic [63:0] idx_addr;
  } apu_vgpu_qul_t;

  // TransferUsedWriteCheck (qux) status.
  typedef enum logic [1:0] {
    APU_VGPU_QUX_OK    = 2'd0,
    APU_VGPU_QUX_EMPTY = 2'd1,
    APU_VGPU_QUX_FAULT = 2'd2
  } apu_vgpu_qux_status_e;

  // TransferUsedWriteCheck (qux) completion.
  typedef struct packed {
    apu_vgpu_qux_status_e status;
  } apu_vgpu_qux_cpl_t;

  // TransferUsedWriteCheck (qux): used.idx 2 after the guest WRITE, not the scene index 1.
  typedef struct packed {
    logic valid;
    logic [15:0] used_idx;
    logic [31:0] elem_id;
  } apu_vgpu_qux_t;

  // TransferUsedIrq (qiw) status.
  typedef enum logic [1:0] {
    APU_VGPU_QIW_OK    = 2'd0,
    APU_VGPU_QIW_EMPTY = 2'd1,
    APU_VGPU_QIW_FAULT = 2'd2
  } apu_vgpu_qiw_status_e;

  // TransferUsedIrq (qiw) completion.
  typedef struct packed {
    apu_vgpu_qiw_status_e status;
  } apu_vgpu_qiw_cpl_t;

  // TransferUsedIrq (qiw): Guest used-buffer interrupt after used.idx 2.
  typedef struct packed {
    logic valid;
    logic [31:0] reason;
    logic [15:0] used_idx;
    logic [63:0] addr;
  } apu_vgpu_qiw_t;

  // TransferUsedIrqRead (qir) status.
  typedef enum logic [1:0] {
    APU_VGPU_QIR_OK    = 2'd0,
    APU_VGPU_QIR_EMPTY = 2'd1,
    APU_VGPU_QIR_FAULT = 2'd2
  } apu_vgpu_qir_status_e;

  // TransferUsedIrqRead (qir) completion.
  typedef struct packed {
    apu_vgpu_qir_status_e status;
  } apu_vgpu_qir_cpl_t;

  // TransferUsedIrqRead (qir): Guest read of that interrupt reason.
  typedef struct packed {
    logic valid;
    logic [31:0] reason;
    logic [15:0] used_idx;
    logic [63:0] addr;
  } apu_vgpu_qir_t;

  // TransferUsedIrqCheck (qix) status.
  typedef enum logic [1:0] {
    APU_VGPU_QIX_OK    = 2'd0,
    APU_VGPU_QIX_EMPTY = 2'd1,
    APU_VGPU_QIX_FAULT = 2'd2
  } apu_vgpu_qix_status_e;

  // TransferUsedIrqCheck (qix) completion.
  typedef struct packed {
    apu_vgpu_qix_status_e status;
  } apu_vgpu_qix_cpl_t;

  // TransferUsedIrqCheck (qix): Reason 32'h1 at 64'h880C0000 after the guest used ring.
  typedef struct packed {
    logic valid;
    logic [31:0] reason;
    logic [15:0] used_idx;
    logic [63:0] addr;
  } apu_vgpu_qix_t;


  // TransferUsedAck (qaw) status.
  typedef enum logic [1:0] {
    APU_VGPU_QAW_OK    = 2'd0,
    APU_VGPU_QAW_EMPTY = 2'd1,
    APU_VGPU_QAW_FAULT = 2'd2
  } apu_vgpu_qaw_status_e;

  // TransferUsedAck (qaw) completion.
  typedef struct packed {
    apu_vgpu_qaw_status_e status;
  } apu_vgpu_qaw_cpl_t;

  // TransferUsedAck (qaw): Guest ack of the guest-rung used-buffer interrupt.
  typedef struct packed {
    logic valid;
    logic [31:0] ack;
    logic [31:0] remain;
    logic [15:0] used_idx;
    logic [63:0] ack_addr;
    logic [63:0] status_addr;
  } apu_vgpu_qaw_t;

  // TransferUsedAckRead (qar) status.
  typedef enum logic [1:0] {
    APU_VGPU_QAR_OK    = 2'd0,
    APU_VGPU_QAR_EMPTY = 2'd1,
    APU_VGPU_QAR_FAULT = 2'd2
  } apu_vgpu_qar_status_e;

  // TransferUsedAckRead (qar) completion.
  typedef struct packed {
    apu_vgpu_qar_status_e status;
  } apu_vgpu_qar_cpl_t;

  // TransferUsedAckRead (qar): Guest read of that ack and the cleared status.
  typedef struct packed {
    logic valid;
    logic [31:0] ack;
    logic [31:0] remain;
    logic [15:0] used_idx;
    logic [63:0] ack_addr;
    logic [63:0] status_addr;
  } apu_vgpu_qar_t;

  // TransferUsedAckCheck (qay) status.
  typedef enum logic [1:0] {
    APU_VGPU_QAY_OK    = 2'd0,
    APU_VGPU_QAY_EMPTY = 2'd1,
    APU_VGPU_QAY_FAULT = 2'd2
  } apu_vgpu_qay_status_e;

  // TransferUsedAckCheck (qay) completion.
  typedef struct packed {
    apu_vgpu_qay_status_e status;
  } apu_vgpu_qay_cpl_t;

  // TransferUsedAckCheck (qay): Ack 32'h1 and remain 0 after the guest used ring.
  typedef struct packed {
    logic valid;
    logic [31:0] ack;
    logic [31:0] remain;
    logic [15:0] used_idx;
  } apu_vgpu_qay_t;


  // SceneAvailIdx (qsv) status.
  typedef enum logic [1:0] {
    APU_VGPU_QSV_OK    = 2'd0,
    APU_VGPU_QSV_EMPTY = 2'd1,
    APU_VGPU_QSV_FAULT = 2'd2
  } apu_vgpu_qsv_status_e;

  // SceneAvailIdx (qsv) completion.
  typedef struct packed {
    apu_vgpu_qsv_status_e status;
  } apu_vgpu_qsv_cpl_t;

  // SceneAvailIdx (qsv): Scene virtq_avail.idx 1 after the guest-rung transfer ack.
  typedef struct packed {
    logic valid;
    logic [15:0] avail_idx;
    logic [63:0] addr;
  } apu_vgpu_qsv_t;

  // SceneAvailIdxKeep (qsk) status.
  typedef enum logic [1:0] {
    APU_VGPU_QSK_OK    = 2'd0,
    APU_VGPU_QSK_EMPTY = 2'd1,
    APU_VGPU_QSK_FAULT = 2'd2
  } apu_vgpu_qsk_status_e;

  // SceneAvailIdxKeep (qsk) completion.
  typedef struct packed {
    apu_vgpu_qsk_status_e status;
  } apu_vgpu_qsk_cpl_t;

  // SceneAvailIdxKeep (qsk): Keep that scene index. Not the transfer ring.
  typedef struct packed {
    logic valid;
    logic [15:0] avail_idx;
    logic [63:0] addr;
  } apu_vgpu_qsk_t;

  // SceneAvailIdxCheck (qsx) status.
  typedef enum logic [1:0] {
    APU_VGPU_QSX_OK    = 2'd0,
    APU_VGPU_QSX_EMPTY = 2'd1,
    APU_VGPU_QSX_FAULT = 2'd2
  } apu_vgpu_qsx_status_e;

  // SceneAvailIdxCheck (qsx) completion.
  typedef struct packed {
    apu_vgpu_qsx_status_e status;
  } apu_vgpu_qsx_cpl_t;

  // SceneAvailIdxCheck (qsx): Scene index 1 at 64'h8800E200, not transfer index 2.
  typedef struct packed {
    logic valid;
    logic [15:0] avail_idx;
  } apu_vgpu_qsx_t;


  // SceneAvailRing (qsr) status.
  typedef enum logic [1:0] {
    APU_VGPU_QSR_OK    = 2'd0,
    APU_VGPU_QSR_EMPTY = 2'd1,
    APU_VGPU_QSR_FAULT = 2'd2
  } apu_vgpu_qsr_status_e;

  // SceneAvailRing (qsr) completion.
  typedef struct packed {
    apu_vgpu_qsr_status_e status;
  } apu_vgpu_qsr_cpl_t;

  // SceneAvailRing (qsr): Scene avail ring[0] names descriptor 0 after idx 1.
  typedef struct packed {
    logic valid;
    logic [15:0] desc_id;
    logic [63:0] addr;
  } apu_vgpu_qsr_t;

  // SceneAvailRingKeep (qsl) status.
  typedef enum logic [1:0] {
    APU_VGPU_QSL_OK    = 2'd0,
    APU_VGPU_QSL_EMPTY = 2'd1,
    APU_VGPU_QSL_FAULT = 2'd2
  } apu_vgpu_qsl_status_e;

  // SceneAvailRingKeep (qsl) completion.
  typedef struct packed {
    apu_vgpu_qsl_status_e status;
  } apu_vgpu_qsl_cpl_t;

  // SceneAvailRingKeep (qsl): Keep that scene ring name. Not the transfer ring.
  typedef struct packed {
    logic valid;
    logic [15:0] desc_id;
    logic [63:0] addr;
  } apu_vgpu_qsl_t;

  // SceneAvailRingCheck (qsy) status.
  typedef enum logic [1:0] {
    APU_VGPU_QSY_OK    = 2'd0,
    APU_VGPU_QSY_EMPTY = 2'd1,
    APU_VGPU_QSY_FAULT = 2'd2
  } apu_vgpu_qsy_status_e;

  // SceneAvailRingCheck (qsy) completion.
  typedef struct packed {
    apu_vgpu_qsy_status_e status;
  } apu_vgpu_qsy_cpl_t;

  // SceneAvailRingCheck (qsy): Descriptor 0 at 64'h8800E204, not transfer ring[0].
  typedef struct packed {
    logic valid;
    logic [15:0] desc_id;
  } apu_vgpu_qsy_t;


  // SceneDesc0 (qsd) status.
  typedef enum logic [1:0] {
    APU_VGPU_QSD_OK    = 2'd0,
    APU_VGPU_QSD_EMPTY = 2'd1,
    APU_VGPU_QSD_FAULT = 2'd2
  } apu_vgpu_qsd_status_e;

  // SceneDesc0 (qsd) completion.
  typedef struct packed {
    apu_vgpu_qsd_status_e status;
  } apu_vgpu_qsd_cpl_t;

  // SceneDesc0 (qsd): Scene virtq_desc 0: header at HDR_ADDR, NEXT to 1.
  typedef struct packed {
    logic valid;
    logic [63:0] hdr_addr;
    logic [31:0] hdr_len;
    logic [15:0] nxt;
  } apu_vgpu_qsd_t;

  // SceneDesc0Keep (qse) status.
  typedef enum logic [1:0] {
    APU_VGPU_QSE_OK    = 2'd0,
    APU_VGPU_QSE_EMPTY = 2'd1,
    APU_VGPU_QSE_FAULT = 2'd2
  } apu_vgpu_qse_status_e;

  // SceneDesc0Keep (qse) completion.
  typedef struct packed {
    apu_vgpu_qse_status_e status;
  } apu_vgpu_qse_cpl_t;

  // SceneDesc0Keep (qse): Keep that scene header descriptor. Not the transfer table.
  typedef struct packed {
    logic valid;
    logic [63:0] hdr_addr;
    logic [31:0] hdr_len;
    logic [15:0] nxt;
  } apu_vgpu_qse_t;

  // SceneDesc0Check (qsf) status.
  typedef enum logic [1:0] {
    APU_VGPU_QSF_OK    = 2'd0,
    APU_VGPU_QSF_EMPTY = 2'd1,
    APU_VGPU_QSF_FAULT = 2'd2
  } apu_vgpu_qsf_status_e;

  // SceneDesc0Check (qsf) completion.
  typedef struct packed {
    apu_vgpu_qsf_status_e status;
  } apu_vgpu_qsf_cpl_t;

  // SceneDesc0Check (qsf): Header at HDR_ADDR, NEXT to 1, not the transfer attach.
  typedef struct packed {
    logic valid;
    logic [63:0] hdr_addr;
    logic [15:0] nxt;
  } apu_vgpu_qsf_t;


  // SceneDesc1 (qed) status.
  typedef enum logic [1:0] {
    APU_VGPU_QED_OK    = 2'd0,
    APU_VGPU_QED_EMPTY = 2'd1,
    APU_VGPU_QED_FAULT = 2'd2
  } apu_vgpu_qed_status_e;

  // SceneDesc1 (qed) completion.
  typedef struct packed {
    apu_vgpu_qed_status_e status;
  } apu_vgpu_qed_cpl_t;

  // SceneDesc1 (qed): Scene virtq_desc 1: execbuffer at EXEC_ADDR, NEXT to 2.
  typedef struct packed {
    logic valid;
    logic [63:0] exec_addr;
    logic [31:0] exec_len;
    logic [15:0] nxt;
  } apu_vgpu_qed_t;

  // SceneDesc1Keep (qek) status.
  typedef enum logic [1:0] {
    APU_VGPU_QEK_OK    = 2'd0,
    APU_VGPU_QEK_EMPTY = 2'd1,
    APU_VGPU_QEK_FAULT = 2'd2
  } apu_vgpu_qek_status_e;

  // SceneDesc1Keep (qek) completion.
  typedef struct packed {
    apu_vgpu_qek_status_e status;
  } apu_vgpu_qek_cpl_t;

  // SceneDesc1Keep (qek): Keep that scene execbuffer descriptor. Not the transfer table.
  typedef struct packed {
    logic valid;
    logic [63:0] exec_addr;
    logic [31:0] exec_len;
    logic [15:0] nxt;
  } apu_vgpu_qek_t;

  // SceneDesc1Check (qex) status.
  typedef enum logic [1:0] {
    APU_VGPU_QEX_OK    = 2'd0,
    APU_VGPU_QEX_EMPTY = 2'd1,
    APU_VGPU_QEX_FAULT = 2'd2
  } apu_vgpu_qex_status_e;

  // SceneDesc1Check (qex) completion.
  typedef struct packed {
    apu_vgpu_qex_status_e status;
  } apu_vgpu_qex_cpl_t;

  // SceneDesc1Check (qex): Execbuffer at EXEC_ADDR, NEXT to 2, not the transfer command.
  typedef struct packed {
    logic valid;
    logic [63:0] exec_addr;
    logic [15:0] nxt;
  } apu_vgpu_qex_t;


  // SceneDesc2 (qrs) status.
  typedef enum logic [1:0] {
    APU_VGPU_QRS_OK    = 2'd0,
    APU_VGPU_QRS_EMPTY = 2'd1,
    APU_VGPU_QRS_FAULT = 2'd2
  } apu_vgpu_qrs_status_e;

  // SceneDesc2 (qrs) completion.
  typedef struct packed {
    apu_vgpu_qrs_status_e status;
  } apu_vgpu_qrs_cpl_t;

  // SceneDesc2 (qrs): Scene virtq_desc 2: WRITE of the 24-byte response at RSP_ADDR.
  typedef struct packed {
    logic valid;
    logic [63:0] rsp_addr;
    logic [31:0] rsp_len;
  } apu_vgpu_qrs_t;

  // SceneDesc2Keep (qrt) status.
  typedef enum logic [1:0] {
    APU_VGPU_QRT_OK    = 2'd0,
    APU_VGPU_QRT_EMPTY = 2'd1,
    APU_VGPU_QRT_FAULT = 2'd2
  } apu_vgpu_qrt_status_e;

  // SceneDesc2Keep (qrt) completion.
  typedef struct packed {
    apu_vgpu_qrt_status_e status;
  } apu_vgpu_qrt_cpl_t;

  // SceneDesc2Keep (qrt): Keep that scene WRITE descriptor. Not the transfer table.
  typedef struct packed {
    logic valid;
    logic [63:0] rsp_addr;
    logic [31:0] rsp_len;
  } apu_vgpu_qrt_t;

  // SceneDesc2Check (qru) status.
  typedef enum logic [1:0] {
    APU_VGPU_QRU_OK    = 2'd0,
    APU_VGPU_QRU_EMPTY = 2'd1,
    APU_VGPU_QRU_FAULT = 2'd2
  } apu_vgpu_qru_status_e;

  // SceneDesc2Check (qru) completion.
  typedef struct packed {
    apu_vgpu_qru_status_e status;
  } apu_vgpu_qru_cpl_t;

  // SceneDesc2Check (qru): WRITE of the 24-byte scene response at RSP_ADDR, not RFW_ADDR.
  typedef struct packed {
    logic valid;
    logic [63:0] rsp_addr;
  } apu_vgpu_qru_t;

  // SceneOkNodata (qso) status.
  typedef enum logic [1:0] {
    APU_VGPU_QSO_OK    = 2'd0,
    APU_VGPU_QSO_EMPTY = 2'd1,
    APU_VGPU_QSO_FAULT = 2'd2
  } apu_vgpu_qso_status_e;

  // SceneOkNodata (qso) completion.
  typedef struct packed {
    apu_vgpu_qso_status_e status;
  } apu_vgpu_qso_cpl_t;

  // SceneOkNodata (qso): Scene OK_NODATA at RSP_ADDR after the named WRITE.
  typedef struct packed {
    logic valid;
    logic [31:0] resp;
    logic [63:0] fence;
    logic [63:0] addr;
  } apu_vgpu_qso_t;

  // SceneOkNodataRead (qsp) status.
  typedef enum logic [1:0] {
    APU_VGPU_QSP_OK    = 2'd0,
    APU_VGPU_QSP_EMPTY = 2'd1,
    APU_VGPU_QSP_FAULT = 2'd2
  } apu_vgpu_qsp_status_e;

  // SceneOkNodataRead (qsp) completion.
  typedef struct packed {
    apu_vgpu_qsp_status_e status;
  } apu_vgpu_qsp_cpl_t;

  // SceneOkNodataRead (qsp): Guest read of that scene OK_NODATA. Scene fence.
  typedef struct packed {
    logic valid;
    logic [31:0] resp;
    logic [31:0] flg;
    logic [63:0] fence;
    logic [63:0] addr;
  } apu_vgpu_qsp_t;

  // SceneOkNodataCheck (qsq) status.
  typedef enum logic [1:0] {
    APU_VGPU_QSQ_OK    = 2'd0,
    APU_VGPU_QSQ_EMPTY = 2'd1,
    APU_VGPU_QSQ_FAULT = 2'd2
  } apu_vgpu_qsq_status_e;

  // SceneOkNodataCheck (qsq) completion.
  typedef struct packed {
    apu_vgpu_qsq_status_e status;
  } apu_vgpu_qsq_cpl_t;

  // SceneOkNodataCheck (qsq): Scene fence OK_NODATA at 64'h8800A800, not fence 2.
  typedef struct packed {
    logic valid;
    logic [63:0] fence;
    logic [31:0] resp;
  } apu_vgpu_qsq_t;

  // SceneUsedWrite (qsu) status.
  typedef enum logic [1:0] {
    APU_VGPU_QSU_OK    = 2'd0,
    APU_VGPU_QSU_EMPTY = 2'd1,
    APU_VGPU_QSU_FAULT = 2'd2
  } apu_vgpu_qsu_status_e;

  // SceneUsedWrite (qsu) completion.
  typedef struct packed {
    apu_vgpu_qsu_status_e status;
  } apu_vgpu_qsu_cpl_t;

  // SceneUsedWrite (qsu): Scene used element after OK_NODATA. id 0, used.idx 1.
  typedef struct packed {
    logic valid;
    logic [31:0] elem_id;
    logic [31:0] elem_len;
    logic [15:0] used_idx;
    logic [63:0] elem_addr;
    logic [63:0] idx_addr;
  } apu_vgpu_qsu_t;

  // SceneUsedWriteRead (qst) status.
  typedef enum logic [1:0] {
    APU_VGPU_QST_OK    = 2'd0,
    APU_VGPU_QST_EMPTY = 2'd1,
    APU_VGPU_QST_FAULT = 2'd2
  } apu_vgpu_qst_status_e;

  // SceneUsedWriteRead (qst) completion.
  typedef struct packed {
    apu_vgpu_qst_status_e status;
  } apu_vgpu_qst_cpl_t;

  // SceneUsedWriteRead (qst): Guest read of that scene used element and index.
  typedef struct packed {
    logic valid;
    logic [31:0] elem_id;
    logic [31:0] elem_len;
    logic [15:0] used_idx;
    logic [63:0] elem_addr;
    logic [63:0] idx_addr;
  } apu_vgpu_qst_t;

  // SceneUsedWriteCheck (qsz) status.
  typedef enum logic [1:0] {
    APU_VGPU_QSZ_OK    = 2'd0,
    APU_VGPU_QSZ_EMPTY = 2'd1,
    APU_VGPU_QSZ_FAULT = 2'd2
  } apu_vgpu_qsz_status_e;

  // SceneUsedWriteCheck (qsz) completion.
  typedef struct packed {
    apu_vgpu_qsz_status_e status;
  } apu_vgpu_qsz_cpl_t;

  // SceneUsedWriteCheck (qsz): used.idx 1 after the scene WRITE, not the transfer index 2.
  typedef struct packed {
    logic valid;
    logic [15:0] used_idx;
    logic [31:0] elem_id;
  } apu_vgpu_qsz_t;

  // SceneUsedIrq (qsi) status.
  typedef enum logic [1:0] {
    APU_VGPU_QSI_OK    = 2'd0,
    APU_VGPU_QSI_EMPTY = 2'd1,
    APU_VGPU_QSI_FAULT = 2'd2
  } apu_vgpu_qsi_status_e;

  // SceneUsedIrq (qsi) completion.
  typedef struct packed {
    apu_vgpu_qsi_status_e status;
  } apu_vgpu_qsi_cpl_t;

  // SceneUsedIrq (qsi): Scene used-buffer interrupt after used.idx 1.
  typedef struct packed {
    logic valid;
    logic [31:0] reason;
    logic [15:0] used_idx;
    logic [63:0] addr;
  } apu_vgpu_qsi_t;

  // SceneUsedIrqRead (qsn) status.
  typedef enum logic [1:0] {
    APU_VGPU_QSN_OK    = 2'd0,
    APU_VGPU_QSN_EMPTY = 2'd1,
    APU_VGPU_QSN_FAULT = 2'd2
  } apu_vgpu_qsn_status_e;

  // SceneUsedIrqRead (qsn) completion.
  typedef struct packed {
    apu_vgpu_qsn_status_e status;
  } apu_vgpu_qsn_cpl_t;

  // SceneUsedIrqRead (qsn): Guest read of that scene interrupt reason.
  typedef struct packed {
    logic valid;
    logic [31:0] reason;
    logic [15:0] used_idx;
    logic [63:0] addr;
  } apu_vgpu_qsn_t;

  // SceneUsedIrqCheck (qsm) status.
  typedef enum logic [1:0] {
    APU_VGPU_QSM_OK    = 2'd0,
    APU_VGPU_QSM_EMPTY = 2'd1,
    APU_VGPU_QSM_FAULT = 2'd2
  } apu_vgpu_qsm_status_e;

  // SceneUsedIrqCheck (qsm) completion.
  typedef struct packed {
    apu_vgpu_qsm_status_e status;
  } apu_vgpu_qsm_cpl_t;

  // SceneUsedIrqCheck (qsm): Reason 32'h1 at 64'h8800E500 after the scene used ring.
  typedef struct packed {
    logic valid;
    logic [31:0] reason;
    logic [15:0] used_idx;
    logic [63:0] addr;
  } apu_vgpu_qsm_t;

  // SceneUsedAck (qga) status.
  typedef enum logic [1:0] {
    APU_VGPU_QGA_OK    = 2'd0,
    APU_VGPU_QGA_EMPTY = 2'd1,
    APU_VGPU_QGA_FAULT = 2'd2
  } apu_vgpu_qga_status_e;

  // SceneUsedAck (qga) completion.
  typedef struct packed {
    apu_vgpu_qga_status_e status;
  } apu_vgpu_qga_cpl_t;

  // SceneUsedAck (qga): Scene guest ack of the scene used-buffer interrupt.
  typedef struct packed {
    logic valid;
    logic [31:0] ack;
    logic [31:0] remain;
    logic [15:0] used_idx;
    logic [63:0] ack_addr;
    logic [63:0] status_addr;
  } apu_vgpu_qga_t;

  // SceneUsedAckKeep (qgk) status.
  typedef enum logic [1:0] {
    APU_VGPU_QGK_OK    = 2'd0,
    APU_VGPU_QGK_EMPTY = 2'd1,
    APU_VGPU_QGK_FAULT = 2'd2
  } apu_vgpu_qgk_status_e;

  // SceneUsedAckKeep (qgk) completion.
  typedef struct packed {
    apu_vgpu_qgk_status_e status;
  } apu_vgpu_qgk_cpl_t;

  // SceneUsedAckKeep (qgk): Guest read of that scene ack and the cleared status.
  typedef struct packed {
    logic valid;
    logic [31:0] ack;
    logic [31:0] remain;
    logic [15:0] used_idx;
    logic [63:0] ack_addr;
    logic [63:0] status_addr;
  } apu_vgpu_qgk_t;

  // SceneUsedAckCheck (qgx) status.
  typedef enum logic [1:0] {
    APU_VGPU_QGX_OK    = 2'd0,
    APU_VGPU_QGX_EMPTY = 2'd1,
    APU_VGPU_QGX_FAULT = 2'd2
  } apu_vgpu_qgx_status_e;

  // SceneUsedAckCheck (qgx) completion.
  typedef struct packed {
    apu_vgpu_qgx_status_e status;
  } apu_vgpu_qgx_cpl_t;

  // SceneUsedAckCheck (qgx): Ack 32'h1 and remain 0 after the scene used ring.
  typedef struct packed {
    logic valid;
    logic [31:0] ack;
    logic [31:0] remain;
    logic [15:0] used_idx;
  } apu_vgpu_qgx_t;

  // SceneNextWalk (snw) op.
  typedef enum logic [1:0] {
    APU_VGPU_SNW_POST  = 2'd0,
    APU_VGPU_SNW_AVAIL = 2'd1,
    APU_VGPU_SNW_WALK  = 2'd2
  } apu_vgpu_snw_op_e;

  // SceneNextWalk (snw) request.
  typedef struct packed {
    apu_vgpu_snw_op_e op;
    logic [15:0] avail_idx;
    logic [15:0] desc_id;
    apu_vgpu_desc_t desc;
  } apu_vgpu_snw_req_t;

  // SceneNextWalk (snw) status.
  typedef enum logic [1:0] {
    APU_VGPU_SNW_OK    = 2'd0,
    APU_VGPU_SNW_EMPTY = 2'd1,
    APU_VGPU_SNW_FAULT = 2'd2
  } apu_vgpu_snw_status_e;

  // SceneNextWalk (snw) completion.
  typedef struct packed {
    apu_vgpu_snw_status_e status;
  } apu_vgpu_snw_cpl_t;

  // SceneNextWalk (snw): Posted scene chain with NEXT accepted. Avail index 1.
  typedef struct packed {
    logic valid;
    logic [15:0] head;
    logic [15:0] avail_idx;
    logic [15:0] device_idx;
    logic [63:0] att_addr;
    logic [63:0] xfer_addr;
    logic [63:0] rsp_addr;
  } apu_vgpu_snw_t;

  // SceneNextKeep (snk) status.
  typedef enum logic [1:0] {
    APU_VGPU_SNK_OK    = 2'd0,
    APU_VGPU_SNK_EMPTY = 2'd1,
    APU_VGPU_SNK_FAULT = 2'd2
  } apu_vgpu_snk_status_e;

  // SceneNextKeep (snk) completion.
  typedef struct packed {
    apu_vgpu_snk_status_e status;
  } apu_vgpu_snk_cpl_t;

  // SceneNextKeep (snk): Kept walked scene chain. Avail index 1.
  typedef struct packed {
    logic valid;
    logic [15:0] head;
    logic [15:0] avail_idx;
    logic [15:0] device_idx;
    logic [63:0] att_addr;
    logic [63:0] xfer_addr;
    logic [63:0] rsp_addr;
  } apu_vgpu_snk_t;

  // SceneNextCheck (snx) status.
  typedef enum logic [1:0] {
    APU_VGPU_SNX_OK    = 2'd0,
    APU_VGPU_SNX_EMPTY = 2'd1,
    APU_VGPU_SNX_FAULT = 2'd2
  } apu_vgpu_snx_status_e;

  // SceneNextCheck (snx) completion.
  typedef struct packed {
    apu_vgpu_snx_status_e status;
  } apu_vgpu_snx_cpl_t;

  // SceneNextCheck (snx): Avail index 1, NEXT accepted, not the transfer index 2.
  typedef struct packed {
    logic valid;
    logic [15:0] avail_idx;
    logic [15:0] device_idx;
    logic [63:0] att_addr;
  } apu_vgpu_snx_t;

  // SceneQueueNotify (snt) status.
  typedef enum logic [1:0] {
    APU_VGPU_SNT_OK    = 2'd0,
    APU_VGPU_SNT_EMPTY = 2'd1,
    APU_VGPU_SNT_FAULT = 2'd2
  } apu_vgpu_snt_status_e;

  // SceneQueueNotify (snt) completion.
  typedef struct packed {
    apu_vgpu_snt_status_e status;
  } apu_vgpu_snt_cpl_t;

  // SceneQueueNotify (snt): Scene QueueNotify of control queue 0 after avail index 1.
  typedef struct packed {
    logic valid;
    logic [31:0] qid;
    logic [15:0] avail_idx;
    logic [63:0] addr;
  } apu_vgpu_snt_t;

  // SceneQueueNotifyRead (snr) status.
  typedef enum logic [1:0] {
    APU_VGPU_SNR_OK    = 2'd0,
    APU_VGPU_SNR_EMPTY = 2'd1,
    APU_VGPU_SNR_FAULT = 2'd2
  } apu_vgpu_snr_status_e;

  // SceneQueueNotifyRead (snr) completion.
  typedef struct packed {
    apu_vgpu_snr_status_e status;
  } apu_vgpu_snr_cpl_t;

  // SceneQueueNotifyRead (snr): Guest read of that scene notify word.
  typedef struct packed {
    logic valid;
    logic [31:0] qid;
    logic [15:0] avail_idx;
    logic [63:0] addr;
  } apu_vgpu_snr_t;

  // SceneQueueNotifyCheck (sny) status.
  typedef enum logic [1:0] {
    APU_VGPU_SNY_OK    = 2'd0,
    APU_VGPU_SNY_EMPTY = 2'd1,
    APU_VGPU_SNY_FAULT = 2'd2
  } apu_vgpu_sny_status_e;

  // SceneQueueNotifyCheck (sny) completion.
  typedef struct packed {
    apu_vgpu_sny_status_e status;
  } apu_vgpu_sny_cpl_t;

  // SceneQueueNotifyCheck (sny): Control queue 0 after scene avail index 1, not index 2.
  typedef struct packed {
    logic valid;
    logic [31:0] qid;
    logic [15:0] avail_idx;
  } apu_vgpu_sny_t;

  // SceneAvailAfterNotify (sav) status.
  typedef enum logic [1:0] {
    APU_VGPU_SAV_OK    = 2'd0,
    APU_VGPU_SAV_EMPTY = 2'd1,
    APU_VGPU_SAV_FAULT = 2'd2
  } apu_vgpu_sav_status_e;

  // SceneAvailAfterNotify (sav) completion.
  typedef struct packed {
    apu_vgpu_sav_status_e status;
  } apu_vgpu_sav_cpl_t;

  // SceneAvailAfterNotify (sav): Scene virtq_avail.idx 1 after scene QueueNotify.
  typedef struct packed {
    logic valid;
    logic [15:0] avail_idx;
    logic [63:0] addr;
  } apu_vgpu_sav_t;

  // SceneAvailAfterNotifyKeep (sak) status.
  typedef enum logic [1:0] {
    APU_VGPU_SAK_OK    = 2'd0,
    APU_VGPU_SAK_EMPTY = 2'd1,
    APU_VGPU_SAK_FAULT = 2'd2
  } apu_vgpu_sak_status_e;

  // SceneAvailAfterNotifyKeep (sak) completion.
  typedef struct packed {
    apu_vgpu_sak_status_e status;
  } apu_vgpu_sak_cpl_t;

  // SceneAvailAfterNotifyKeep (sak): Keep that scene avail.idx. Not the transfer ring.
  typedef struct packed {
    logic valid;
    logic [15:0] avail_idx;
    logic [63:0] addr;
  } apu_vgpu_sak_t;

  // SceneAvailAfterNotifyCheck (sax) status.
  typedef enum logic [1:0] {
    APU_VGPU_SAX_OK    = 2'd0,
    APU_VGPU_SAX_EMPTY = 2'd1,
    APU_VGPU_SAX_FAULT = 2'd2
  } apu_vgpu_sax_status_e;

  // SceneAvailAfterNotifyCheck (sax) completion.
  typedef struct packed {
    apu_vgpu_sax_status_e status;
  } apu_vgpu_sax_cpl_t;

  // SceneAvailAfterNotifyCheck (sax): Avail index 1 at 64'h8800E200 after notify, not index 2.
  typedef struct packed {
    logic valid;
    logic [15:0] avail_idx;
  } apu_vgpu_sax_t;

  // SceneRingAfterNotify (srg) status.
  typedef enum logic [1:0] {
    APU_VGPU_SRG_OK    = 2'd0,
    APU_VGPU_SRG_EMPTY = 2'd1,
    APU_VGPU_SRG_FAULT = 2'd2
  } apu_vgpu_srg_status_e;

  // SceneRingAfterNotify (srg) completion.
  typedef struct packed {
    apu_vgpu_srg_status_e status;
  } apu_vgpu_srg_cpl_t;

  // SceneRingAfterNotify (srg): Scene virtq_avail.ring[0] names descriptor 0 after idx 1.
  typedef struct packed {
    logic valid;
    logic [15:0] desc_id;
    logic [63:0] addr;
  } apu_vgpu_srg_t;

  // SceneRingAfterNotifyKeep (srk) status.
  typedef enum logic [1:0] {
    APU_VGPU_SRK_OK    = 2'd0,
    APU_VGPU_SRK_EMPTY = 2'd1,
    APU_VGPU_SRK_FAULT = 2'd2
  } apu_vgpu_srk_status_e;

  // SceneRingAfterNotifyKeep (srk) completion.
  typedef struct packed {
    apu_vgpu_srk_status_e status;
  } apu_vgpu_srk_cpl_t;

  // SceneRingAfterNotifyKeep (srk): Keep that scene ring name. Not the transfer ring.
  typedef struct packed {
    logic valid;
    logic [15:0] desc_id;
    logic [63:0] addr;
  } apu_vgpu_srk_t;

  // SceneRingAfterNotifyCheck (srx) status.
  typedef enum logic [1:0] {
    APU_VGPU_SRX_OK    = 2'd0,
    APU_VGPU_SRX_EMPTY = 2'd1,
    APU_VGPU_SRX_FAULT = 2'd2
  } apu_vgpu_srx_status_e;

  // SceneRingAfterNotifyCheck (srx) completion.
  typedef struct packed {
    apu_vgpu_srx_status_e status;
  } apu_vgpu_srx_cpl_t;

  // SceneRingAfterNotifyCheck (srx): Descriptor 0 at 64'h8800E204 after notify, not transfer ring[0].
  typedef struct packed {
    logic valid;
    logic [15:0] desc_id;
  } apu_vgpu_srx_t;

  // SceneHeaderAfterNotify (shd) status.
  typedef enum logic [1:0] {
    APU_VGPU_SHD_OK    = 2'd0,
    APU_VGPU_SHD_EMPTY = 2'd1,
    APU_VGPU_SHD_FAULT = 2'd2
  } apu_vgpu_shd_status_e;

  // SceneHeaderAfterNotify (shd) completion.
  typedef struct packed {
    apu_vgpu_shd_status_e status;
  } apu_vgpu_shd_cpl_t;

  // SceneHeaderAfterNotify (shd): Scene virtq_desc 0: header at HDR_ADDR, NEXT to 1.
  typedef struct packed {
    logic valid;
    logic [63:0] hdr_addr;
    logic [31:0] hdr_len;
    logic [15:0] nxt;
  } apu_vgpu_shd_t;

  // SceneHeaderAfterNotifyKeep (shk) status.
  typedef enum logic [1:0] {
    APU_VGPU_SHK_OK    = 2'd0,
    APU_VGPU_SHK_EMPTY = 2'd1,
    APU_VGPU_SHK_FAULT = 2'd2
  } apu_vgpu_shk_status_e;

  // SceneHeaderAfterNotifyKeep (shk) completion.
  typedef struct packed {
    apu_vgpu_shk_status_e status;
  } apu_vgpu_shk_cpl_t;

  // SceneHeaderAfterNotifyKeep (shk): Keep that scene header descriptor. Not the transfer table.
  typedef struct packed {
    logic valid;
    logic [63:0] hdr_addr;
    logic [31:0] hdr_len;
    logic [15:0] nxt;
  } apu_vgpu_shk_t;

  // SceneHeaderAfterNotifyCheck (shx) status.
  typedef enum logic [1:0] {
    APU_VGPU_SHX_OK    = 2'd0,
    APU_VGPU_SHX_EMPTY = 2'd1,
    APU_VGPU_SHX_FAULT = 2'd2
  } apu_vgpu_shx_status_e;

  // SceneHeaderAfterNotifyCheck (shx) completion.
  typedef struct packed {
    apu_vgpu_shx_status_e status;
  } apu_vgpu_shx_cpl_t;

  // SceneHeaderAfterNotifyCheck (shx): Header at 64'h8800A000, NEXT to 1, not the transfer table.
  typedef struct packed {
    logic valid;
    logic [63:0] hdr_addr;
    logic [15:0] nxt;
  } apu_vgpu_shx_t;

  // SceneExecAfterNotify (sfd) status.
  typedef enum logic [1:0] {
    APU_VGPU_SFD_OK    = 2'd0,
    APU_VGPU_SFD_EMPTY = 2'd1,
    APU_VGPU_SFD_FAULT = 2'd2
  } apu_vgpu_sfd_status_e;

  // SceneExecAfterNotify (sfd) completion.
  typedef struct packed {
    apu_vgpu_sfd_status_e status;
  } apu_vgpu_sfd_cpl_t;

  // SceneExecAfterNotify (sfd): Scene virtq_desc 1: execbuffer at EXEC_ADDR, NEXT to 2.
  typedef struct packed {
    logic valid;
    logic [63:0] exec_addr;
    logic [31:0] exec_len;
    logic [15:0] nxt;
  } apu_vgpu_sfd_t;

  // SceneExecAfterNotifyKeep (sfk) status.
  typedef enum logic [1:0] {
    APU_VGPU_SFK_OK    = 2'd0,
    APU_VGPU_SFK_EMPTY = 2'd1,
    APU_VGPU_SFK_FAULT = 2'd2
  } apu_vgpu_sfk_status_e;

  // SceneExecAfterNotifyKeep (sfk) completion.
  typedef struct packed {
    apu_vgpu_sfk_status_e status;
  } apu_vgpu_sfk_cpl_t;

  // SceneExecAfterNotifyKeep (sfk): Keep that scene execbuffer descriptor. Not desc 0.
  typedef struct packed {
    logic valid;
    logic [63:0] exec_addr;
    logic [31:0] exec_len;
    logic [15:0] nxt;
  } apu_vgpu_sfk_t;

  // SceneExecAfterNotifyCheck (sfx) status.
  typedef enum logic [1:0] {
    APU_VGPU_SFX_OK    = 2'd0,
    APU_VGPU_SFX_EMPTY = 2'd1,
    APU_VGPU_SFX_FAULT = 2'd2
  } apu_vgpu_sfx_status_e;

  // SceneExecAfterNotifyCheck (sfx) completion.
  typedef struct packed {
    apu_vgpu_sfx_status_e status;
  } apu_vgpu_sfx_cpl_t;

  // SceneExecAfterNotifyCheck (sfx): Execbuffer at 64'h8800B000, NEXT to 2, not the header.
  typedef struct packed {
    logic valid;
    logic [63:0] exec_addr;
    logic [15:0] nxt;
  } apu_vgpu_sfx_t;

  // SceneWriteAfterNotify (swd) status.
  typedef enum logic [1:0] {
    APU_VGPU_SWD_OK    = 2'd0,
    APU_VGPU_SWD_EMPTY = 2'd1,
    APU_VGPU_SWD_FAULT = 2'd2
  } apu_vgpu_swd_status_e;

  // SceneWriteAfterNotify (swd) completion.
  typedef struct packed {
    apu_vgpu_swd_status_e status;
  } apu_vgpu_swd_cpl_t;

  // SceneWriteAfterNotify (swd): Scene virtq_desc 2: WRITE of the 24-byte response at RSP_ADDR.
  typedef struct packed {
    logic valid;
    logic [63:0] rsp_addr;
    logic [31:0] rsp_len;
  } apu_vgpu_swd_t;

  // SceneWriteAfterNotifyKeep (swk) status.
  typedef enum logic [1:0] {
    APU_VGPU_SWK_OK    = 2'd0,
    APU_VGPU_SWK_EMPTY = 2'd1,
    APU_VGPU_SWK_FAULT = 2'd2
  } apu_vgpu_swk_status_e;

  // SceneWriteAfterNotifyKeep (swk) completion.
  typedef struct packed {
    apu_vgpu_swk_status_e status;
  } apu_vgpu_swk_cpl_t;

  // SceneWriteAfterNotifyKeep (swk): Keep that scene WRITE descriptor. Not the transfer table.
  typedef struct packed {
    logic valid;
    logic [63:0] rsp_addr;
    logic [31:0] rsp_len;
  } apu_vgpu_swk_t;

  // SceneWriteAfterNotifyCheck (swx) status.
  typedef enum logic [1:0] {
    APU_VGPU_SWX_OK    = 2'd0,
    APU_VGPU_SWX_EMPTY = 2'd1,
    APU_VGPU_SWX_FAULT = 2'd2
  } apu_vgpu_swx_status_e;

  // SceneWriteAfterNotifyCheck (swx) completion.
  typedef struct packed {
    apu_vgpu_swx_status_e status;
  } apu_vgpu_swx_cpl_t;

  // SceneWriteAfterNotifyCheck (swx): WRITE at 64'h8800A800, length 24, not RFW_ADDR.
  typedef struct packed {
    logic valid;
    logic [63:0] rsp_addr;
  } apu_vgpu_swx_t;

  // SceneOkAfterNotify (sok) status.
  typedef enum logic [1:0] {
    APU_VGPU_SOK_OK    = 2'd0,
    APU_VGPU_SOK_EMPTY = 2'd1,
    APU_VGPU_SOK_FAULT = 2'd2
  } apu_vgpu_sok_status_e;

  // SceneOkAfterNotify (sok) completion.
  typedef struct packed {
    apu_vgpu_sok_status_e status;
  } apu_vgpu_sok_cpl_t;

  // SceneOkAfterNotify (sok): Scene OK_NODATA at RSP_ADDR after the named WRITE.
  typedef struct packed {
    logic valid;
    logic [31:0] resp;
    logic [63:0] fence;
    logic [63:0] addr;
  } apu_vgpu_sok_t;

  // SceneOkAfterNotifyKeep (sol) status.
  typedef enum logic [1:0] {
    APU_VGPU_SOL_OK    = 2'd0,
    APU_VGPU_SOL_EMPTY = 2'd1,
    APU_VGPU_SOL_FAULT = 2'd2
  } apu_vgpu_sol_status_e;

  // SceneOkAfterNotifyKeep (sol) completion.
  typedef struct packed {
    apu_vgpu_sol_status_e status;
  } apu_vgpu_sol_cpl_t;

  // SceneOkAfterNotifyKeep (sol): Guest read of that scene OK_NODATA. Scene fence.
  typedef struct packed {
    logic valid;
    logic [31:0] resp;
    logic [31:0] flg;
    logic [63:0] fence;
    logic [63:0] addr;
  } apu_vgpu_sol_t;

  // SceneOkAfterNotifyCheck (sox) status.
  typedef enum logic [1:0] {
    APU_VGPU_SOX_OK    = 2'd0,
    APU_VGPU_SOX_EMPTY = 2'd1,
    APU_VGPU_SOX_FAULT = 2'd2
  } apu_vgpu_sox_status_e;

  // SceneOkAfterNotifyCheck (sox) completion.
  typedef struct packed {
    apu_vgpu_sox_status_e status;
  } apu_vgpu_sox_cpl_t;

  // SceneOkAfterNotifyCheck (sox): Scene fence OK_NODATA at 64'h8800A800, not fence 2.
  typedef struct packed {
    logic valid;
    logic [63:0] fence;
    logic [31:0] resp;
  } apu_vgpu_sox_t;

  // SceneUsedAfterNotify (slw) status.
  typedef enum logic [1:0] {
    APU_VGPU_SLW_OK    = 2'd0,
    APU_VGPU_SLW_EMPTY = 2'd1,
    APU_VGPU_SLW_FAULT = 2'd2
  } apu_vgpu_slw_status_e;

  // SceneUsedAfterNotify (slw) completion.
  typedef struct packed {
    apu_vgpu_slw_status_e status;
  } apu_vgpu_slw_cpl_t;

  // SceneUsedAfterNotify (slw): Scene used element after OK_NODATA. id 0, used.idx 1.
  typedef struct packed {
    logic valid;
    logic [31:0] elem_id;
    logic [31:0] elem_len;
    logic [15:0] used_idx;
    logic [63:0] elem_addr;
    logic [63:0] idx_addr;
  } apu_vgpu_slw_t;

  // SceneUsedAfterNotifyKeep (sll) status.
  typedef enum logic [1:0] {
    APU_VGPU_SLL_OK    = 2'd0,
    APU_VGPU_SLL_EMPTY = 2'd1,
    APU_VGPU_SLL_FAULT = 2'd2
  } apu_vgpu_sll_status_e;

  // SceneUsedAfterNotifyKeep (sll) completion.
  typedef struct packed {
    apu_vgpu_sll_status_e status;
  } apu_vgpu_sll_cpl_t;

  // SceneUsedAfterNotifyKeep (sll): Guest read of that scene used element and index.
  typedef struct packed {
    logic valid;
    logic [31:0] elem_id;
    logic [31:0] elem_len;
    logic [15:0] used_idx;
    logic [63:0] elem_addr;
    logic [63:0] idx_addr;
  } apu_vgpu_sll_t;

  // SceneUsedAfterNotifyCheck (slx) status.
  typedef enum logic [1:0] {
    APU_VGPU_SLX_OK    = 2'd0,
    APU_VGPU_SLX_EMPTY = 2'd1,
    APU_VGPU_SLX_FAULT = 2'd2
  } apu_vgpu_slx_status_e;

  // SceneUsedAfterNotifyCheck (slx) completion.
  typedef struct packed {
    apu_vgpu_slx_status_e status;
  } apu_vgpu_slx_cpl_t;

  // SceneUsedAfterNotifyCheck (slx): used.idx 1 after the scene WRITE, not the transfer index 2.
  typedef struct packed {
    logic valid;
    logic [15:0] used_idx;
    logic [31:0] elem_id;
  } apu_vgpu_slx_t;

  // SceneIrqAfterNotify (siw) status.
  typedef enum logic [1:0] {
    APU_VGPU_SIW_OK    = 2'd0,
    APU_VGPU_SIW_EMPTY = 2'd1,
    APU_VGPU_SIW_FAULT = 2'd2
  } apu_vgpu_siw_status_e;

  // SceneIrqAfterNotify (siw) completion.
  typedef struct packed {
    apu_vgpu_siw_status_e status;
  } apu_vgpu_siw_cpl_t;

  // SceneIrqAfterNotify (siw): Scene used-buffer interrupt after used.idx 1 after QueueNotify.
  typedef struct packed {
    logic valid;
    logic [31:0] reason;
    logic [15:0] used_idx;
    logic [63:0] addr;
  } apu_vgpu_siw_t;

  // SceneIrqAfterNotifyKeep (sir) status.
  typedef enum logic [1:0] {
    APU_VGPU_SIR_OK    = 2'd0,
    APU_VGPU_SIR_EMPTY = 2'd1,
    APU_VGPU_SIR_FAULT = 2'd2
  } apu_vgpu_sir_status_e;

  // SceneIrqAfterNotifyKeep (sir) completion.
  typedef struct packed {
    apu_vgpu_sir_status_e status;
  } apu_vgpu_sir_cpl_t;

  // SceneIrqAfterNotifyKeep (sir): Guest read of that scene interrupt reason after QueueNotify.
  typedef struct packed {
    logic valid;
    logic [31:0] reason;
    logic [15:0] used_idx;
    logic [63:0] addr;
  } apu_vgpu_sir_t;

  // SceneIrqAfterNotifyCheck (six) status.
  typedef enum logic [1:0] {
    APU_VGPU_SIX_OK    = 2'd0,
    APU_VGPU_SIX_EMPTY = 2'd1,
    APU_VGPU_SIX_FAULT = 2'd2
  } apu_vgpu_six_status_e;

  // SceneIrqAfterNotifyCheck (six) completion.
  typedef struct packed {
    apu_vgpu_six_status_e status;
  } apu_vgpu_six_cpl_t;

  // SceneIrqAfterNotifyCheck (six): Reason 32'h1 at 64'h8800E500 after the scene used ring after notify.
  typedef struct packed {
    logic valid;
    logic [31:0] reason;
    logic [15:0] used_idx;
    logic [63:0] addr;
  } apu_vgpu_six_t;

  // SceneAckAfterNotify (sga) status.
  typedef enum logic [1:0] {
    APU_VGPU_SGA_OK    = 2'd0,
    APU_VGPU_SGA_EMPTY = 2'd1,
    APU_VGPU_SGA_FAULT = 2'd2
  } apu_vgpu_sga_status_e;

  // SceneAckAfterNotify (sga) completion.
  typedef struct packed {
    apu_vgpu_sga_status_e status;
  } apu_vgpu_sga_cpl_t;

  // SceneAckAfterNotify (sga): Scene guest ack of the used-buffer interrupt after QueueNotify.
  typedef struct packed {
    logic valid;
    logic [31:0] ack;
    logic [31:0] remain;
    logic [15:0] used_idx;
    logic [63:0] ack_addr;
    logic [63:0] status_addr;
  } apu_vgpu_sga_t;

  // SceneAckAfterNotifyKeep (sgk) status.
  typedef enum logic [1:0] {
    APU_VGPU_SGK_OK    = 2'd0,
    APU_VGPU_SGK_EMPTY = 2'd1,
    APU_VGPU_SGK_FAULT = 2'd2
  } apu_vgpu_sgk_status_e;

  // SceneAckAfterNotifyKeep (sgk) completion.
  typedef struct packed {
    apu_vgpu_sgk_status_e status;
  } apu_vgpu_sgk_cpl_t;

  // SceneAckAfterNotifyKeep (sgk): Guest read of that scene ack and the cleared status after notify.
  typedef struct packed {
    logic valid;
    logic [31:0] ack;
    logic [31:0] remain;
    logic [15:0] used_idx;
    logic [63:0] ack_addr;
    logic [63:0] status_addr;
  } apu_vgpu_sgk_t;

  // SceneAckAfterNotifyCheck (sgx) status.
  typedef enum logic [1:0] {
    APU_VGPU_SGX_OK    = 2'd0,
    APU_VGPU_SGX_EMPTY = 2'd1,
    APU_VGPU_SGX_FAULT = 2'd2
  } apu_vgpu_sgx_status_e;

  // SceneAckAfterNotifyCheck (sgx) completion.
  typedef struct packed {
    apu_vgpu_sgx_status_e status;
  } apu_vgpu_sgx_cpl_t;

  // SceneAckAfterNotifyCheck (sgx): Ack 32'h1 and remain 0 after the scene used ring after notify.
  typedef struct packed {
    logic valid;
    logic [31:0] ack;
    logic [31:0] remain;
    logic [15:0] used_idx;
  } apu_vgpu_sgx_t;

  // TransferNextAfterAckWalk (rnw) op.
  typedef enum logic [1:0] {
    APU_VGPU_RNW_POST  = 2'd0,
    APU_VGPU_RNW_AVAIL = 2'd1,
    APU_VGPU_RNW_WALK  = 2'd2
  } apu_vgpu_rnw_op_e;

  // TransferNextAfterAckWalk (rnw) request.
  typedef struct packed {
    apu_vgpu_rnw_op_e op;
    logic [15:0] avail_idx;
    logic [15:0] desc_id;
    apu_vgpu_desc_t desc;
  } apu_vgpu_rnw_req_t;

  // TransferNextAfterAckWalk (rnw) status.
  typedef enum logic [1:0] {
    APU_VGPU_RNW_OK    = 2'd0,
    APU_VGPU_RNW_EMPTY = 2'd1,
    APU_VGPU_RNW_FAULT = 2'd2
  } apu_vgpu_rnw_status_e;

  // TransferNextAfterAckWalk (rnw) completion.
  typedef struct packed {
    apu_vgpu_rnw_status_e status;
  } apu_vgpu_rnw_cpl_t;

  // TransferNextAfterAckWalk (rnw): Posted transfer chain after scene guest ack. Avail index 2.
  typedef struct packed {
    logic valid;
    logic [15:0] head;
    logic [15:0] avail_idx;
    logic [15:0] device_idx;
    logic [63:0] att_addr;
    logic [63:0] xfer_addr;
    logic [63:0] rsp_addr;
  } apu_vgpu_rnw_t;

  // TransferNextAfterAckKeep (rnk) status.
  typedef enum logic [1:0] {
    APU_VGPU_RNK_OK    = 2'd0,
    APU_VGPU_RNK_EMPTY = 2'd1,
    APU_VGPU_RNK_FAULT = 2'd2
  } apu_vgpu_rnk_status_e;

  // TransferNextAfterAckKeep (rnk) completion.
  typedef struct packed {
    apu_vgpu_rnk_status_e status;
  } apu_vgpu_rnk_cpl_t;

  // TransferNextAfterAckKeep (rnk): Kept walked transfer chain after scene guest ack. Avail index 2.
  typedef struct packed {
    logic valid;
    logic [15:0] head;
    logic [15:0] avail_idx;
    logic [15:0] device_idx;
    logic [63:0] att_addr;
    logic [63:0] xfer_addr;
    logic [63:0] rsp_addr;
  } apu_vgpu_rnk_t;

  // TransferNextAfterAckCheck (rnx) status.
  typedef enum logic [1:0] {
    APU_VGPU_RNX_OK    = 2'd0,
    APU_VGPU_RNX_EMPTY = 2'd1,
    APU_VGPU_RNX_FAULT = 2'd2
  } apu_vgpu_rnx_status_e;

  // TransferNextAfterAckCheck (rnx) completion.
  typedef struct packed {
    apu_vgpu_rnx_status_e status;
  } apu_vgpu_rnx_cpl_t;

  // TransferNextAfterAckCheck (rnx): Avail index 2, NEXT accepted after scene guest ack, not scene index 1.
  typedef struct packed {
    logic valid;
    logic [15:0] avail_idx;
    logic [15:0] device_idx;
    logic [63:0] att_addr;
  } apu_vgpu_rnx_t;

  // TransferNotifyAfterAck (rnt) status.
  typedef enum logic [1:0] {
    APU_VGPU_RNT_OK    = 2'd0,
    APU_VGPU_RNT_EMPTY = 2'd1,
    APU_VGPU_RNT_FAULT = 2'd2
  } apu_vgpu_rnt_status_e;

  // TransferNotifyAfterAck (rnt) completion.
  typedef struct packed {
    apu_vgpu_rnt_status_e status;
  } apu_vgpu_rnt_cpl_t;

  // TransferNotifyAfterAck (rnt): QueueNotify of control queue 0 after the transfer walker after scene ack.
  typedef struct packed {
    logic valid;
    logic [31:0] qid;
    logic [15:0] avail_idx;
    logic [63:0] addr;
  } apu_vgpu_rnt_t;

  // TransferNotifyAfterAckKeep (rnr) status.
  typedef enum logic [1:0] {
    APU_VGPU_RNR_OK    = 2'd0,
    APU_VGPU_RNR_EMPTY = 2'd1,
    APU_VGPU_RNR_FAULT = 2'd2
  } apu_vgpu_rnr_status_e;

  // TransferNotifyAfterAckKeep (rnr) completion.
  typedef struct packed {
    apu_vgpu_rnr_status_e status;
  } apu_vgpu_rnr_cpl_t;

  // TransferNotifyAfterAckKeep (rnr): Guest read of that notify word after scene guest ack.
  typedef struct packed {
    logic valid;
    logic [31:0] qid;
    logic [15:0] avail_idx;
    logic [63:0] addr;
  } apu_vgpu_rnr_t;

  // TransferNotifyAfterAckCheck (rny) status.
  typedef enum logic [1:0] {
    APU_VGPU_RNY_OK    = 2'd0,
    APU_VGPU_RNY_EMPTY = 2'd1,
    APU_VGPU_RNY_FAULT = 2'd2
  } apu_vgpu_rny_status_e;

  // TransferNotifyAfterAckCheck (rny) completion.
  typedef struct packed {
    apu_vgpu_rny_status_e status;
  } apu_vgpu_rny_cpl_t;

  // TransferNotifyAfterAckCheck (rny): Control queue 0 after avail index 2 after scene guest ack.
  typedef struct packed {
    logic valid;
    logic [31:0] qid;
    logic [15:0] avail_idx;
  } apu_vgpu_rny_t;

  // TransferAvailAfterAck (rav) status.
  typedef enum logic [1:0] {
    APU_VGPU_RAV_OK    = 2'd0,
    APU_VGPU_RAV_EMPTY = 2'd1,
    APU_VGPU_RAV_FAULT = 2'd2
  } apu_vgpu_rav_status_e;

  // TransferAvailAfterAck (rav) completion.
  typedef struct packed {
    apu_vgpu_rav_status_e status;
  } apu_vgpu_rav_cpl_t;

  // TransferAvailAfterAck (rav): virtq_avail.idx 2 after QueueNotify after scene guest ack.
  typedef struct packed {
    logic valid;
    logic [15:0] avail_idx;
    logic [63:0] addr;
  } apu_vgpu_rav_t;

  // TransferAvailAfterAckKeep (rak) status.
  typedef enum logic [1:0] {
    APU_VGPU_RAK_OK    = 2'd0,
    APU_VGPU_RAK_EMPTY = 2'd1,
    APU_VGPU_RAK_FAULT = 2'd2
  } apu_vgpu_rak_status_e;

  // TransferAvailAfterAckKeep (rak) completion.
  typedef struct packed {
    apu_vgpu_rak_status_e status;
  } apu_vgpu_rak_cpl_t;

  // TransferAvailAfterAckKeep (rak): Keep that avail.idx after scene guest ack. Not the scene ring.
  typedef struct packed {
    logic valid;
    logic [15:0] avail_idx;
    logic [63:0] addr;
  } apu_vgpu_rak_t;

  // TransferAvailAfterAckCheck (ray) status.
  typedef enum logic [1:0] {
    APU_VGPU_RAY_OK    = 2'd0,
    APU_VGPU_RAY_EMPTY = 2'd1,
    APU_VGPU_RAY_FAULT = 2'd2
  } apu_vgpu_ray_status_e;

  // TransferAvailAfterAckCheck (ray) completion.
  typedef struct packed {
    apu_vgpu_ray_status_e status;
  } apu_vgpu_ray_cpl_t;

  // TransferAvailAfterAckCheck (ray): Avail index 2 at 64'h880D0100 after scene guest ack, not scene index 1.
  typedef struct packed {
    logic valid;
    logic [15:0] avail_idx;
  } apu_vgpu_ray_t;

  // TransferRingAfterAck (rrg) status.
  typedef enum logic [1:0] {
    APU_VGPU_RRG_OK    = 2'd0,
    APU_VGPU_RRG_EMPTY = 2'd1,
    APU_VGPU_RRG_FAULT = 2'd2
  } apu_vgpu_rrg_status_e;

  // TransferRingAfterAck (rrg) completion.
  typedef struct packed {
    apu_vgpu_rrg_status_e status;
  } apu_vgpu_rrg_cpl_t;

  // TransferRingAfterAck (rrg): virtq_avail.ring[0] names descriptor 0 after idx 2 after scene guest ack.
  typedef struct packed {
    logic valid;
    logic [15:0] desc_id;
    logic [63:0] addr;
  } apu_vgpu_rrg_t;

  // TransferRingAfterAckKeep (rrk) status.
  typedef enum logic [1:0] {
    APU_VGPU_RRK_OK    = 2'd0,
    APU_VGPU_RRK_EMPTY = 2'd1,
    APU_VGPU_RRK_FAULT = 2'd2
  } apu_vgpu_rrk_status_e;

  // TransferRingAfterAckKeep (rrk) completion.
  typedef struct packed {
    apu_vgpu_rrk_status_e status;
  } apu_vgpu_rrk_cpl_t;

  // TransferRingAfterAckKeep (rrk): Keep that ring name after scene guest ack. Not the scene ring.
  typedef struct packed {
    logic valid;
    logic [15:0] desc_id;
    logic [63:0] addr;
  } apu_vgpu_rrk_t;

  // TransferRingAfterAckCheck (rrx) status.
  typedef enum logic [1:0] {
    APU_VGPU_RRX_OK    = 2'd0,
    APU_VGPU_RRX_EMPTY = 2'd1,
    APU_VGPU_RRX_FAULT = 2'd2
  } apu_vgpu_rrx_status_e;

  // TransferRingAfterAckCheck (rrx) completion.
  typedef struct packed {
    apu_vgpu_rrx_status_e status;
  } apu_vgpu_rrx_cpl_t;

  // TransferRingAfterAckCheck (rrx): Descriptor 0 at 64'h880D0104 after scene guest ack, not scene ring[0].
  typedef struct packed {
    logic valid;
    logic [15:0] desc_id;
  } apu_vgpu_rrx_t;

  // TransferDesc0AfterAck (rhd) status.
  typedef enum logic [1:0] {
    APU_VGPU_RHD_OK    = 2'd0,
    APU_VGPU_RHD_EMPTY = 2'd1,
    APU_VGPU_RHD_FAULT = 2'd2
  } apu_vgpu_rhd_status_e;

  // TransferDesc0AfterAck (rhd) completion.
  typedef struct packed {
    apu_vgpu_rhd_status_e status;
  } apu_vgpu_rhd_cpl_t;

  // TransferDesc0AfterAck (rhd): virtq_desc 0: attach at RAB_CMD, NEXT to 1 after scene guest ack.
  typedef struct packed {
    logic valid;
    logic [63:0] att_addr;
    logic [31:0] att_len;
    logic [15:0] nxt;
  } apu_vgpu_rhd_t;

  // TransferDesc0AfterAckKeep (rhk) status.
  typedef enum logic [1:0] {
    APU_VGPU_RHK_OK    = 2'd0,
    APU_VGPU_RHK_EMPTY = 2'd1,
    APU_VGPU_RHK_FAULT = 2'd2
  } apu_vgpu_rhk_status_e;

  // TransferDesc0AfterAckKeep (rhk) completion.
  typedef struct packed {
    apu_vgpu_rhk_status_e status;
  } apu_vgpu_rhk_cpl_t;

  // TransferDesc0AfterAckKeep (rhk): Keep that attach descriptor after scene guest ack. Not the scene table.
  typedef struct packed {
    logic valid;
    logic [63:0] att_addr;
    logic [31:0] att_len;
    logic [15:0] nxt;
  } apu_vgpu_rhk_t;

  // TransferDesc0AfterAckCheck (rhx) status.
  typedef enum logic [1:0] {
    APU_VGPU_RHX_OK    = 2'd0,
    APU_VGPU_RHX_EMPTY = 2'd1,
    APU_VGPU_RHX_FAULT = 2'd2
  } apu_vgpu_rhx_status_e;

  // TransferDesc0AfterAckCheck (rhx) completion.
  typedef struct packed {
    apu_vgpu_rhx_status_e status;
  } apu_vgpu_rhx_cpl_t;

  // TransferDesc0AfterAckCheck (rhx): Attach at RAB_CMD, NEXT to 1 after scene guest ack, not the scene table.
  typedef struct packed {
    logic valid;
    logic [63:0] att_addr;
    logic [15:0] nxt;
  } apu_vgpu_rhx_t;

  // TransferDesc1AfterAck (rfd) status.
  typedef enum logic [1:0] {
    APU_VGPU_RFD_OK    = 2'd0,
    APU_VGPU_RFD_EMPTY = 2'd1,
    APU_VGPU_RFD_FAULT = 2'd2
  } apu_vgpu_rfd_status_e;

  // TransferDesc1AfterAck (rfd) completion.
  typedef struct packed {
    apu_vgpu_rfd_status_e status;
  } apu_vgpu_rfd_cpl_t;

  // TransferDesc1AfterAck (rfd): virtq_desc 1: transfer at TFB_CMD, NEXT to 2 after scene guest ack.
  typedef struct packed {
    logic valid;
    logic [63:0] xfer_addr;
    logic [31:0] xfer_len;
    logic [15:0] nxt;
  } apu_vgpu_rfd_t;

  // TransferDesc1AfterAckKeep (rfk) status.
  typedef enum logic [1:0] {
    APU_VGPU_RFK_OK    = 2'd0,
    APU_VGPU_RFK_EMPTY = 2'd1,
    APU_VGPU_RFK_FAULT = 2'd2
  } apu_vgpu_rfk_status_e;

  // TransferDesc1AfterAckKeep (rfk) completion.
  typedef struct packed {
    apu_vgpu_rfk_status_e status;
  } apu_vgpu_rfk_cpl_t;

  // TransferDesc1AfterAckKeep (rfk): Keep that transfer descriptor after scene guest ack. Not desc 0.
  typedef struct packed {
    logic valid;
    logic [63:0] xfer_addr;
    logic [31:0] xfer_len;
    logic [15:0] nxt;
  } apu_vgpu_rfk_t;

  // TransferDesc1AfterAckCheck (rfy) status.
  typedef enum logic [1:0] {
    APU_VGPU_RFY_OK    = 2'd0,
    APU_VGPU_RFY_EMPTY = 2'd1,
    APU_VGPU_RFY_FAULT = 2'd2
  } apu_vgpu_rfy_status_e;

  // TransferDesc1AfterAckCheck (rfy) completion.
  typedef struct packed {
    apu_vgpu_rfy_status_e status;
  } apu_vgpu_rfy_cpl_t;

  // TransferDesc1AfterAckCheck (rfy): Transfer at TFB_CMD, NEXT to 2 after scene guest ack, not the attach.
  typedef struct packed {
    logic valid;
    logic [63:0] xfer_addr;
    logic [15:0] nxt;
  } apu_vgpu_rfy_t;

  // TransferDesc2AfterAck (rwd) status.
  typedef enum logic [1:0] {
    APU_VGPU_RWD_OK    = 2'd0,
    APU_VGPU_RWD_EMPTY = 2'd1,
    APU_VGPU_RWD_FAULT = 2'd2
  } apu_vgpu_rwd_status_e;

  // TransferDesc2AfterAck (rwd) completion.
  typedef struct packed {
    apu_vgpu_rwd_status_e status;
  } apu_vgpu_rwd_cpl_t;

  // TransferDesc2AfterAck (rwd): virtq_desc 2: WRITE of the response at RFW_ADDR after scene guest ack.
  typedef struct packed {
    logic valid;
    logic [63:0] rsp_addr;
    logic [31:0] rsp_len;
  } apu_vgpu_rwd_t;

  // TransferDesc2AfterAckKeep (rwk) status.
  typedef enum logic [1:0] {
    APU_VGPU_RWK_OK    = 2'd0,
    APU_VGPU_RWK_EMPTY = 2'd1,
    APU_VGPU_RWK_FAULT = 2'd2
  } apu_vgpu_rwk_status_e;

  // TransferDesc2AfterAckKeep (rwk) completion.
  typedef struct packed {
    apu_vgpu_rwk_status_e status;
  } apu_vgpu_rwk_cpl_t;

  // TransferDesc2AfterAckKeep (rwk): Keep that WRITE descriptor after scene guest ack. Not the transfer.
  typedef struct packed {
    logic valid;
    logic [63:0] rsp_addr;
    logic [31:0] rsp_len;
  } apu_vgpu_rwk_t;

  // TransferDesc2AfterAckCheck (rwx) status.
  typedef enum logic [1:0] {
    APU_VGPU_RWX_OK    = 2'd0,
    APU_VGPU_RWX_EMPTY = 2'd1,
    APU_VGPU_RWX_FAULT = 2'd2
  } apu_vgpu_rwx_status_e;

  // TransferDesc2AfterAckCheck (rwx) completion.
  typedef struct packed {
    apu_vgpu_rwx_status_e status;
  } apu_vgpu_rwx_cpl_t;

  // TransferDesc2AfterAckCheck (rwx): WRITE at RFW_ADDR, length 24 after scene guest ack, not the transfer.
  typedef struct packed {
    logic valid;
    logic [63:0] rsp_addr;
  } apu_vgpu_rwx_t;

  // TransferOkAfterAck (rok) status.
  typedef enum logic [1:0] {
    APU_VGPU_ROK_OK    = 2'd0,
    APU_VGPU_ROK_EMPTY = 2'd1,
    APU_VGPU_ROK_FAULT = 2'd2
  } apu_vgpu_rok_status_e;

  // TransferOkAfterAck (rok) completion.
  typedef struct packed {
    apu_vgpu_rok_status_e status;
  } apu_vgpu_rok_cpl_t;

  // TransferOkAfterAck (rok): Guest OK_NODATA at RFW_ADDR after the named WRITE after scene guest ack.
  typedef struct packed {
    logic valid;
    logic [31:0] resp;
    logic [63:0] fence;
    logic [63:0] addr;
  } apu_vgpu_rok_t;

  // TransferOkAfterAckKeep (rol) status.
  typedef enum logic [1:0] {
    APU_VGPU_ROL_OK    = 2'd0,
    APU_VGPU_ROL_EMPTY = 2'd1,
    APU_VGPU_ROL_FAULT = 2'd2
  } apu_vgpu_rol_status_e;

  // TransferOkAfterAckKeep (rol) completion.
  typedef struct packed {
    apu_vgpu_rol_status_e status;
  } apu_vgpu_rol_cpl_t;

  // TransferOkAfterAckKeep (rol): Guest read of that OK_NODATA after scene guest ack. Fence 2.
  typedef struct packed {
    logic valid;
    logic [31:0] resp;
    logic [31:0] flg;
    logic [63:0] fence;
    logic [63:0] addr;
  } apu_vgpu_rol_t;

  // TransferOkAfterAckCheck (roy) status.
  typedef enum logic [1:0] {
    APU_VGPU_ROY_OK    = 2'd0,
    APU_VGPU_ROY_EMPTY = 2'd1,
    APU_VGPU_ROY_FAULT = 2'd2
  } apu_vgpu_roy_status_e;

  // TransferOkAfterAckCheck (roy) completion.
  typedef struct packed {
    apu_vgpu_roy_status_e status;
  } apu_vgpu_roy_cpl_t;

  // TransferOkAfterAckCheck (roy): Fence 2 OK_NODATA at 64'h880A0000 after scene guest ack, not the scene fence.
  typedef struct packed {
    logic valid;
    logic [63:0] fence;
    logic [31:0] resp;
  } apu_vgpu_roy_t;

  // TransferUsedAfterAck (ruw) status.
  typedef enum logic [1:0] {
    APU_VGPU_RUW_OK    = 2'd0,
    APU_VGPU_RUW_EMPTY = 2'd1,
    APU_VGPU_RUW_FAULT = 2'd2
  } apu_vgpu_ruw_status_e;

  // TransferUsedAfterAck (ruw) completion.
  typedef struct packed {
    apu_vgpu_ruw_status_e status;
  } apu_vgpu_ruw_cpl_t;

  // TransferUsedAfterAck (ruw): Guest used element after OK_NODATA after scene guest ack. id 1, used.idx 2.
  typedef struct packed {
    logic valid;
    logic [31:0] elem_id;
    logic [31:0] elem_len;
    logic [15:0] used_idx;
    logic [63:0] elem_addr;
    logic [63:0] idx_addr;
  } apu_vgpu_ruw_t;

  // TransferUsedAfterAckKeep (rul) status.
  typedef enum logic [1:0] {
    APU_VGPU_RUL_OK    = 2'd0,
    APU_VGPU_RUL_EMPTY = 2'd1,
    APU_VGPU_RUL_FAULT = 2'd2
  } apu_vgpu_rul_status_e;

  // TransferUsedAfterAckKeep (rul) completion.
  typedef struct packed {
    apu_vgpu_rul_status_e status;
  } apu_vgpu_rul_cpl_t;

  // TransferUsedAfterAckKeep (rul): Guest read of that used element and index after scene guest ack.
  typedef struct packed {
    logic valid;
    logic [31:0] elem_id;
    logic [31:0] elem_len;
    logic [15:0] used_idx;
    logic [63:0] elem_addr;
    logic [63:0] idx_addr;
  } apu_vgpu_rul_t;

  // TransferUsedAfterAckCheck (rux) status.
  typedef enum logic [1:0] {
    APU_VGPU_RUX_OK    = 2'd0,
    APU_VGPU_RUX_EMPTY = 2'd1,
    APU_VGPU_RUX_FAULT = 2'd2
  } apu_vgpu_rux_status_e;

  // TransferUsedAfterAckCheck (rux) completion.
  typedef struct packed {
    apu_vgpu_rux_status_e status;
  } apu_vgpu_rux_cpl_t;

  // TransferUsedAfterAckCheck (rux): used.idx 2 after the guest WRITE after scene guest ack, not the scene index 1.
  typedef struct packed {
    logic valid;
    logic [15:0] used_idx;
    logic [31:0] elem_id;
  } apu_vgpu_rux_t;

  // TransferIrqAfterAck (riw) status.
  typedef enum logic [1:0] {
    APU_VGPU_RIW_OK    = 2'd0,
    APU_VGPU_RIW_EMPTY = 2'd1,
    APU_VGPU_RIW_FAULT = 2'd2
  } apu_vgpu_riw_status_e;

  // TransferIrqAfterAck (riw) completion.
  typedef struct packed {
    apu_vgpu_riw_status_e status;
  } apu_vgpu_riw_cpl_t;

  // TransferIrqAfterAck (riw): Guest used-buffer interrupt after used.idx 2 after scene guest ack.
  typedef struct packed {
    logic valid;
    logic [31:0] reason;
    logic [15:0] used_idx;
    logic [63:0] addr;
  } apu_vgpu_riw_t;

  // TransferIrqAfterAckKeep (rir) status.
  typedef enum logic [1:0] {
    APU_VGPU_RIR_OK    = 2'd0,
    APU_VGPU_RIR_EMPTY = 2'd1,
    APU_VGPU_RIR_FAULT = 2'd2
  } apu_vgpu_rir_status_e;

  // TransferIrqAfterAckKeep (rir) completion.
  typedef struct packed {
    apu_vgpu_rir_status_e status;
  } apu_vgpu_rir_cpl_t;

  // TransferIrqAfterAckKeep (rir): Guest read of that interrupt reason after scene guest ack.
  typedef struct packed {
    logic valid;
    logic [31:0] reason;
    logic [15:0] used_idx;
    logic [63:0] addr;
  } apu_vgpu_rir_t;

  // TransferIrqAfterAckCheck (rix) status.
  typedef enum logic [1:0] {
    APU_VGPU_RIX_OK    = 2'd0,
    APU_VGPU_RIX_EMPTY = 2'd1,
    APU_VGPU_RIX_FAULT = 2'd2
  } apu_vgpu_rix_status_e;

  // TransferIrqAfterAckCheck (rix) completion.
  typedef struct packed {
    apu_vgpu_rix_status_e status;
  } apu_vgpu_rix_cpl_t;

  // TransferIrqAfterAckCheck (rix): Reason 32'h1 at 64'h880C0000 after the guest used ring after scene guest ack.
  typedef struct packed {
    logic valid;
    logic [31:0] reason;
    logic [15:0] used_idx;
    logic [63:0] addr;
  } apu_vgpu_rix_t;

  // TransferAckAfterAck (rga) status.
  typedef enum logic [1:0] {
    APU_VGPU_RGA_OK    = 2'd0,
    APU_VGPU_RGA_EMPTY = 2'd1,
    APU_VGPU_RGA_FAULT = 2'd2
  } apu_vgpu_rga_status_e;

  // TransferAckAfterAck (rga) completion.
  typedef struct packed {
    apu_vgpu_rga_status_e status;
  } apu_vgpu_rga_cpl_t;

  // TransferAckAfterAck (rga): Guest ack of the used-buffer interrupt after scene guest ack.
  typedef struct packed {
    logic valid;
    logic [31:0] ack;
    logic [31:0] remain;
    logic [15:0] used_idx;
    logic [63:0] ack_addr;
    logic [63:0] status_addr;
  } apu_vgpu_rga_t;

  // TransferAckAfterAckKeep (rgk) status.
  typedef enum logic [1:0] {
    APU_VGPU_RGK_OK    = 2'd0,
    APU_VGPU_RGK_EMPTY = 2'd1,
    APU_VGPU_RGK_FAULT = 2'd2
  } apu_vgpu_rgk_status_e;

  // TransferAckAfterAckKeep (rgk) completion.
  typedef struct packed {
    apu_vgpu_rgk_status_e status;
  } apu_vgpu_rgk_cpl_t;

  // TransferAckAfterAckKeep (rgk): Guest read of that ack and the cleared status after scene guest ack.
  typedef struct packed {
    logic valid;
    logic [31:0] ack;
    logic [31:0] remain;
    logic [15:0] used_idx;
    logic [63:0] ack_addr;
    logic [63:0] status_addr;
  } apu_vgpu_rgk_t;

  // TransferAckAfterAckCheck (rgx) status.
  typedef enum logic [1:0] {
    APU_VGPU_RGX_OK    = 2'd0,
    APU_VGPU_RGX_EMPTY = 2'd1,
    APU_VGPU_RGX_FAULT = 2'd2
  } apu_vgpu_rgx_status_e;

  // TransferAckAfterAckCheck (rgx) completion.
  typedef struct packed {
    apu_vgpu_rgx_status_e status;
  } apu_vgpu_rgx_cpl_t;

  // TransferAckAfterAckCheck (rgx): Ack 32'h1 and remain 0 after the guest used ring after scene guest ack.
  typedef struct packed {
    logic valid;
    logic [31:0] ack;
    logic [31:0] remain;
    logic [15:0] used_idx;
  } apu_vgpu_rgx_t;

  // TexAfterAck (gtx) status.
  typedef enum logic [1:0] {
    APU_VGPU_GTX_OK    = 2'd0,
    APU_VGPU_GTX_EMPTY = 2'd1,
    APU_VGPU_GTX_FAULT = 2'd2
  } apu_vgpu_gtx_status_e;

  // TexAfterAck (gtx) completion.
  typedef struct packed {
    apu_vgpu_gtx_status_e status;
  } apu_vgpu_gtx_cpl_t;

  // TexAfterAck (gtx): TEX after transfer guest ack. refused 0, origin clamp, used.idx 2.
  typedef struct packed {
    logic valid;
    logic refused;
    logic [31:0] origin;
    logic [31:0] neighbor;
    logic [15:0] used_idx;
  } apu_vgpu_gtx_t;

  // TexAfterAckKeep (gtr) status.
  typedef enum logic [1:0] {
    APU_VGPU_GTR_OK    = 2'd0,
    APU_VGPU_GTR_EMPTY = 2'd1,
    APU_VGPU_GTR_FAULT = 2'd2
  } apu_vgpu_gtr_status_e;

  // TexAfterAckKeep (gtr) completion.
  typedef struct packed {
    apu_vgpu_gtr_status_e status;
  } apu_vgpu_gtr_cpl_t;

  // TexAfterAckKeep (gtr): Keep that TEX result after guest ack. refused stays 0.
  typedef struct packed {
    logic valid;
    logic refused;
    logic [31:0] origin;
    logic [31:0] neighbor;
    logic [15:0] used_idx;
  } apu_vgpu_gtr_t;

  // TexAfterAckCheck (gtk) status.
  typedef enum logic [1:0] {
    APU_VGPU_GTK_OK    = 2'd0,
    APU_VGPU_GTK_EMPTY = 2'd1,
    APU_VGPU_GTK_FAULT = 2'd2
  } apu_vgpu_gtk_status_e;

  // TexAfterAckCheck (gtk) completion.
  typedef struct packed {
    apu_vgpu_gtk_status_e status;
  } apu_vgpu_gtk_cpl_t;

  // TexAfterAckCheck (gtk): refused 0, origin clamp texel, used.idx 2 after guest ack.
  typedef struct packed {
    logic valid;
    logic refused;
    logic [31:0] origin;
    logic [15:0] used_idx;
  } apu_vgpu_gtk_t;

  // GuestTransferTexWrite (hcw) status.
  typedef enum logic [1:0] {
    APU_VGPU_HCW_OK    = 2'd0,
    APU_VGPU_HCW_EMPTY = 2'd1,
    APU_VGPU_HCW_FAULT = 2'd2
  } apu_vgpu_hcw_status_e;

  // GuestTransferTexWrite (hcw) completion.
  typedef struct packed {
    apu_vgpu_hcw_status_e status;
  } apu_vgpu_hcw_cpl_t;

  // GuestTransferTexWrite (hcw): TEX pair in beat 0 of the guest transfer buffer after guest ack.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [63:0] base;
    logic [15:0] off0;
    logic [15:0] off1;
    logic [6:0] x0;
    logic [6:0] x1;
    logic [31:0] origin;
    logic [31:0] neighbor;
  } apu_vgpu_hcw_t;

  // GuestTransferTexRead (hcr) status.
  typedef enum logic [1:0] {
    APU_VGPU_HCR_OK    = 2'd0,
    APU_VGPU_HCR_EMPTY = 2'd1,
    APU_VGPU_HCR_FAULT = 2'd2
  } apu_vgpu_hcr_status_e;

  // GuestTransferTexRead (hcr) completion.
  typedef struct packed {
    apu_vgpu_hcr_status_e status;
  } apu_vgpu_hcr_cpl_t;

  // GuestTransferTexRead (hcr): Those two words read back from 64'h88070000 after guest ack.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [63:0] base;
    logic [15:0] off0;
    logic [15:0] off1;
    logic [6:0] x0;
    logic [6:0] x1;
    logic [31:0] origin;
    logic [31:0] neighbor;
  } apu_vgpu_hcr_t;

  // GuestTransferTexCheck (hcx) status.
  typedef enum logic [1:0] {
    APU_VGPU_HCX_OK    = 2'd0,
    APU_VGPU_HCX_EMPTY = 2'd1,
    APU_VGPU_HCX_FAULT = 2'd2
  } apu_vgpu_hcx_status_e;

  // GuestTransferTexCheck (hcx) completion.
  typedef struct packed {
    apu_vgpu_hcx_status_e status;
  } apu_vgpu_hcx_cpl_t;

  // GuestTransferTexCheck (hcx): Byte 0 of (0,0) in the guest transfer buffer is the sample red.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [15:0] off0;
    logic [15:0] off1;
    logic [6:0] x0;
    logic [6:0] x1;
    logic [7:0] b0;
    logic [31:0] origin;
    logic [31:0] neighbor;
  } apu_vgpu_hcx_t;

  // CoveredTexSample (wld) status.
  typedef enum logic [1:0] {
    APU_VGPU_WLD_OK    = 2'd0,
    APU_VGPU_WLD_EMPTY = 2'd1,
    APU_VGPU_WLD_FAULT = 2'd2
  } apu_vgpu_wld_status_e;

  // CoveredTexSample (wld) completion.
  typedef struct packed {
    apu_vgpu_wld_status_e status;
  } apu_vgpu_wld_cpl_t;

  // CoveredTexSample (wld): Covered TEX sample after guest transfer beat. (0,0) or (1,0).
  typedef struct packed {
    logic valid;
    logic refused;
    logic [31:0] word;
    logic [13:0] addr;
    logic [6:0] x;
    logic [6:0] y;
  } apu_vgpu_wld_t;

  // CoveredTexSampleKeep (wlr) status.
  typedef enum logic [1:0] {
    APU_VGPU_WLR_OK    = 2'd0,
    APU_VGPU_WLR_EMPTY = 2'd1,
    APU_VGPU_WLR_FAULT = 2'd2
  } apu_vgpu_wlr_status_e;

  // CoveredTexSampleKeep (wlr) completion.
  typedef struct packed {
    apu_vgpu_wlr_status_e status;
  } apu_vgpu_wlr_cpl_t;

  // CoveredTexSampleKeep (wlr): Keep that covered TEX sample. refused stays 0.
  typedef struct packed {
    logic valid;
    logic refused;
    logic [31:0] word;
    logic [13:0] addr;
    logic [6:0] x;
    logic [6:0] y;
  } apu_vgpu_wlr_t;

  // CoveredTexSampleCheck (wlk) status.
  typedef enum logic [1:0] {
    APU_VGPU_WLK_OK    = 2'd0,
    APU_VGPU_WLK_EMPTY = 2'd1,
    APU_VGPU_WLK_FAULT = 2'd2
  } apu_vgpu_wlk_status_e;

  // CoveredTexSampleCheck (wlk) completion.
  typedef struct packed {
    apu_vgpu_wlk_status_e status;
  } apu_vgpu_wlk_cpl_t;

  // CoveredTexSampleCheck (wlk): refused 0, held word is clamp or half blend, not the clear word.
  typedef struct packed {
    logic valid;
    logic refused;
    logic [31:0] word;
    logic [13:0] addr;
  } apu_vgpu_wlk_t;

  // TexSampleChannels (cyr) status.
  typedef enum logic [1:0] {
    APU_VGPU_CYR_OK    = 2'd0,
    APU_VGPU_CYR_EMPTY = 2'd1,
    APU_VGPU_CYR_FAULT = 2'd2
  } apu_vgpu_cyr_status_e;

  // TexSampleChannels (cyr) completion.
  typedef struct packed {
    apu_vgpu_cyr_status_e status;
  } apu_vgpu_cyr_cpl_t;

  // TexSampleChannels (cyr): Four channels of the covered TEX sample. Byte 0 is red.
  typedef struct packed {
    logic valid;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
    logic [31:0] word;
    logic [13:0] addr;
  } apu_vgpu_cyr_t;

  // TexSampleChannelsKeep (cyk) status.
  typedef enum logic [1:0] {
    APU_VGPU_CYK_OK    = 2'd0,
    APU_VGPU_CYK_EMPTY = 2'd1,
    APU_VGPU_CYK_FAULT = 2'd2
  } apu_vgpu_cyk_status_e;

  // TexSampleChannelsKeep (cyk) completion.
  typedef struct packed {
    apu_vgpu_cyk_status_e status;
  } apu_vgpu_cyk_cpl_t;

  // TexSampleChannelsKeep (cyk): Keep those TEX channels. Byte 0 stays red 8'h00.
  typedef struct packed {
    logic valid;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
    logic [31:0] word;
    logic [13:0] addr;
  } apu_vgpu_cyk_t;

  // TexSampleChannelsCheck (cyx) status.
  typedef enum logic [1:0] {
    APU_VGPU_CYX_OK    = 2'd0,
    APU_VGPU_CYX_EMPTY = 2'd1,
    APU_VGPU_CYX_FAULT = 2'd2
  } apu_vgpu_cyx_status_e;

  // TexSampleChannelsCheck (cyx) completion.
  typedef struct packed {
    apu_vgpu_cyx_status_e status;
  } apu_vgpu_cyx_cpl_t;

  // TexSampleChannelsCheck (cyx): Byte 0 is red 8'h00, not the clear red.
  typedef struct packed {
    logic valid;
    logic [7:0] b0;
    logic [7:0] a;
    logic [31:0] word;
  } apu_vgpu_cyx_t;

  // GuestNextWalk (gnw) status.
  typedef enum logic [1:0] {
    APU_VGPU_GNW_OK    = 2'd0,
    APU_VGPU_GNW_EMPTY = 2'd1,
    APU_VGPU_GNW_FAULT = 2'd2
  } apu_vgpu_gnw_status_e;

  // GuestNextWalk (gnw) completion.
  typedef struct packed {
    apu_vgpu_gnw_status_e status;
  } apu_vgpu_gnw_cpl_t;

  // GuestNextWalk (gnw): Guest-rung scene NEXT chain after QueueNotify. Consumed device index 1.
  typedef struct packed {
    logic valid;
    logic [15:0] head;
    logic [15:0] avail_idx;
    logic [15:0] device_idx;
    logic [31:0] buf_len;
    logic [63:0] buf_addr;
    logic [63:0] rsp_addr;
  } apu_vgpu_gnw_t;

  // GuestNextKeep (gnk) status.
  typedef enum logic [1:0] {
    APU_VGPU_GNK_OK    = 2'd0,
    APU_VGPU_GNK_EMPTY = 2'd1,
    APU_VGPU_GNK_FAULT = 2'd2
  } apu_vgpu_gnk_status_e;

  // GuestNextKeep (gnk) completion.
  typedef struct packed {
    apu_vgpu_gnk_status_e status;
  } apu_vgpu_gnk_cpl_t;

  // GuestNextKeep (gnk): Kept guest-rung chain: avail 1, device 1, execbuffer, response.
  typedef struct packed {
    logic valid;
    logic [15:0] head;
    logic [15:0] avail_idx;
    logic [15:0] device_idx;
    logic [63:0] buf_addr;
    logic [63:0] rsp_addr;
  } apu_vgpu_gnk_t;

  // GuestNextCheck (gnx) status.
  typedef enum logic [1:0] {
    APU_VGPU_GNX_OK    = 2'd0,
    APU_VGPU_GNX_EMPTY = 2'd1,
    APU_VGPU_GNX_FAULT = 2'd2
  } apu_vgpu_gnx_status_e;

  // GuestNextCheck (gnx) completion.
  typedef struct packed {
    apu_vgpu_gnx_status_e status;
  } apu_vgpu_gnx_cpl_t;

  // GuestNextCheck (gnx): Avail index 1, consumed device index 1, execbuffer.
  typedef struct packed {
    logic valid;
    logic [15:0] avail_idx;
    logic [15:0] device_idx;
    logic [63:0] buf_addr;
  } apu_vgpu_gnx_t;

  typedef enum logic [1:0] {
    APU_VGPU_GEF_OK    = 2'd0,
    APU_VGPU_GEF_EMPTY = 2'd1,
    APU_VGPU_GEF_FAULT = 2'd2
  } apu_vgpu_gef_status_e;

  typedef struct packed {
    apu_vgpu_gef_status_e status;
  } apu_vgpu_gef_cpl_t;

  // GuestExecFetch (gef): Header type and first execbuffer word after consumed device index 1.
  typedef struct packed {
    logic valid;
    logic [31:0] kind;
    logic [31:0] cmd0;
    logic [5:0] beats;
    logic [15:0] device_idx;
  } apu_vgpu_gef_t;

  typedef enum logic [1:0] {
    APU_VGPU_GEK_OK    = 2'd0,
    APU_VGPU_GEK_EMPTY = 2'd1,
    APU_VGPU_GEK_FAULT = 2'd2
  } apu_vgpu_gek_status_e;

  typedef struct packed {
    apu_vgpu_gek_status_e status;
  } apu_vgpu_gek_cpl_t;

  // GuestExecKeep (gek): Kept submit type and first command after gnx.
  typedef struct packed {
    logic valid;
    logic [31:0] kind;
    logic [31:0] cmd0;
    logic [15:0] device_idx;
  } apu_vgpu_gek_t;

  typedef enum logic [1:0] {
    APU_VGPU_GEX_OK    = 2'd0,
    APU_VGPU_GEX_EMPTY = 2'd1,
    APU_VGPU_GEX_FAULT = 2'd2
  } apu_vgpu_gex_status_e;

  typedef struct packed {
    apu_vgpu_gex_status_e status;
  } apu_vgpu_gex_cpl_t;

  // GuestExecCheck (gex): cmd0 is CREATE_OBJECT after consumed device index 1.
  typedef struct packed {
    logic valid;
    logic [31:0] cmd0;
    logic [15:0] device_idx;
  } apu_vgpu_gex_t;

  typedef struct packed {
    logic [31:0] resp_type;
    logic [31:0] flags;
    logic [63:0] fence_id;
    logic [31:0] ctx_id;
    logic [31:0] resource_id;
    logic [31:0] format;
    logic [31:0] width;
    logic [31:0] height;
  } apu_vgpu_cpl_t;

  typedef struct packed {
    logic [31:0] slot;
    apu_dma_mapping_t mapping;
    logic [63:0] tag;
  } apu_map_insert_t;

  typedef struct packed {
    logic [31:0] resource_id;
    logic [31:0] context_id;
    logic [31:0] epoch;
    logic write_access;
    logic [63:0] tag;
  } apu_map_lookup_t;

  typedef enum logic [1:0] {
    APU_INVAL_SLOT     = 2'd0,
    APU_INVAL_RESOURCE = 2'd1,
    APU_INVAL_CONTEXT  = 2'd2,
    APU_INVAL_ALL      = 2'd3
  } apu_inval_mode_e;

  typedef struct packed {
    apu_inval_mode_e mode;
    logic [31:0] slot;
    logic [31:0] resource_id;
    logic [31:0] context_id;
    logic [63:0] tag;
  } apu_map_inval_t;

  typedef struct packed {
    logic [31:0] bytes;
    logic [31:0] resource_id;
    logic [31:0] context_id;
    logic [31:0] epoch;
    logic [63:0] tag;
  } apu_cmd_req_t;

  typedef struct packed {
    apu_dma_mapping_t mapping;
    logic [63:0] offset;
    logic [15:0] queue_num;
    logic [15:0] idx;
    logic [31:0] desc_id;
    logic [31:0] len;
    logic [31:0] qid;
    logic [31:0] context_id;
    logic [63:0] fence;
    logic [63:0] tag;
  } apu_used_req_t;

  typedef enum logic [3:0] {
    APU_MEM_NONE        = 4'd0,
    APU_MEM_MAP_INSERT  = 4'd1,
    APU_MEM_MAP_LOOKUP  = 4'd2,
    APU_MEM_MAP_INVAL   = 4'd3,
    APU_MEM_SG_LOAD     = 4'd4,
    APU_MEM_SG_XFER     = 4'd5,
    APU_MEM_CMD_DMA     = 4'd6,
    APU_MEM_CMD_RELEASE = 4'd7,
    APU_MEM_USED        = 4'd8,
    APU_MEM_EXEC_IMEM   = 4'd9,
    APU_MEM_EXEC_POKE   = 4'd10,
    APU_MEM_EXEC_PEEK   = 4'd11,
    APU_MEM_EXEC_RUN    = 4'd12,
    APU_MEM_EXEC_DPEEK  = 4'd13
  } apu_mem_op_e;

  function automatic bit apu_op_is_exec(input apu_mem_op_e op);
    return op >= APU_MEM_EXEC_IMEM && op <= APU_MEM_EXEC_DPEEK;
  endfunction

  // ExecCluster (exec) job.
  typedef struct packed {
    // Widths match APU_EXEC_IMEM_WORDS, APU_EXEC_THREADS, and APU_EXEC_REGS.
    logic [3:0]  idx;
    logic [31:0] inst;
    logic [1:0]  thread;
    logic [2:0]  regno;
    logic [31:0] data;
    logic        shader;
  } apu_exec_job_t;

  typedef struct packed {
    apu_dma_status_e status;
    logic [31:0] slot;
    logic [31:0] resource_id;
    logic [31:0] context_id;
    logic [31:0] epoch;
    logic [31:0] bytes;
    logic [63:0] tag;
  } apu_map_cpl_t;

  function automatic logic [255:0] apu_map_pack(input apu_dma_mapping_t mapping);
    return {29'h0, mapping.valid, mapping.permissions, mapping.resource_id,
            mapping.context_id, mapping.epoch, mapping.base, mapping.bytes};
  endfunction

  function automatic apu_dma_mapping_t apu_map_unpack(input logic [255:0] word);
    apu_dma_mapping_t mapping;
    mapping.bytes = word[63:0];
    mapping.base = word[127:64];
    mapping.epoch = word[159:128];
    mapping.context_id = word[191:160];
    mapping.resource_id = word[223:192];
    mapping.permissions = word[225:224];
    mapping.valid = word[226];
    return mapping;
  endfunction

  function automatic logic [63:0] apu_used_ring_bytes(input logic [15:0] num);
    return 64'd4 + (64'(num) << 3);
  endfunction

  function automatic logic [63:0] apu_used_elem_off(input logic [15:0] num,
                                                   input logic [15:0] idx);
    return 64'd4 + ((64'(idx) & (64'(num) - 64'd1)) << 3);
  endfunction

  function automatic apu_dma_status_e apu_xfer_check(
      input apu_dma_mapping_t mapping,
      input logic [31:0] offset,
      input logic [31:0] width,
      input logic [31:0] height,
      input logic [31:0] depth,
      input logic [31:0] stride,
      input logic [31:0] layer_stride,
      input logic [31:0] bpp
  );
    logic [63:0] row_bytes, used_stride, used_layer, last_row, last_layer, need;
    if (!mapping.valid || mapping.resource_id == 0 || mapping.bytes == 0)
      return APU_DMA_BAD_RESOURCE;
    if (width == 0 || height == 0 || depth == 0 || bpp == 0 || bpp > 16)
      return APU_DMA_BOUNDS;
    row_bytes = 64'(width) * 64'(bpp);
    used_stride = (stride == 0) ? row_bytes : 64'(stride);
    if (used_stride < row_bytes) return APU_DMA_BOUNDS;
    used_layer = (layer_stride == 0) ? (used_stride * 64'(height)) : 64'(layer_stride);
    if (depth > 1 && used_layer < used_stride * 64'(height)) return APU_DMA_BOUNDS;
    last_row = (64'(height) - 64'd1) * used_stride + row_bytes;
    last_layer = (64'(depth) - 64'd1) * used_layer + last_row;
    need = 64'(offset) + last_layer;
    if (need < 64'(offset) || need > mapping.bytes) return APU_DMA_BOUNDS;
    return APU_DMA_OK;
  endfunction

  function automatic bit apu_dma_mapping_in_window(input apu_cfg_t cfg,
                                                  input apu_dma_mapping_t mapping);
    return mapping.valid && mapping.bytes != 0 && mapping.base >= cfg.DmaWindowBase &&
           mapping.bytes <= cfg.DmaWindowBytes &&
           mapping.base - cfg.DmaWindowBase <= cfg.DmaWindowBytes - mapping.bytes;
  endfunction

  function automatic apu_dma_status_e apu_dma_check(
      input apu_cfg_t cfg,
      input apu_dma_mapping_t mapping,
      input apu_dma_read_req_t req,
      input bit write_access
  );
    if (!cfg.Enable || !(write_access ? cfg.DmaWriteEn : cfg.DmaReadEn) ||
        !mapping.valid || mapping.resource_id == 0 ||
        mapping.resource_id != req.resource_id) return APU_DMA_BAD_RESOURCE;
    if (!mapping.permissions[write_access] || mapping.context_id != req.context_id)
      return APU_DMA_PERMISSION;
    if (mapping.epoch != req.epoch) return APU_DMA_STALE;
    if (req.bytes == 0 || req.bytes > (write_access ? cfg.DmaWriteMaxBytes : cfg.DmaReadMaxBytes))
      return APU_DMA_LIMIT;
    if (!apu_dma_mapping_in_window(cfg, mapping) ||
        req.offset >= mapping.bytes || 64'(req.bytes) > mapping.bytes - req.offset)
      return APU_DMA_BOUNDS;
    return APU_DMA_OK;
  endfunction

  // Command DMA uses this published slot. The mailbox base is not an address.
  function automatic apu_dma_mapping_t apu_handle_pin(
      input apu_dma_mapping_t published
  );
    return published;
  endfunction

  function automatic apu_dma_status_e apu_dma_read_check(
      input apu_cfg_t cfg, input apu_dma_mapping_t mapping, input apu_dma_read_req_t req
  );
    return apu_dma_check(cfg, mapping, req, 1'b0);
  endfunction

  function automatic apu_dma_status_e apu_dma_write_check(
      input apu_cfg_t cfg, input apu_dma_mapping_t mapping, input apu_dma_write_req_t req
  );
    return apu_dma_check(cfg, mapping, req, 1'b1);
  endfunction

  function automatic logic [7:0] apu_status_read(
      input logic [7:0] driver_status,
      input logic       needs_reset
  );
    return driver_status | (needs_reset ? VSTATUS_DEVICE_NEEDS_RESET : 8'h0);
  endfunction

  function automatic bit apu_features_accepted(
      input apu_cfg_t      cfg,
      input logic [63:0]   driver_features
  );
    logic [63:0] offered;
    offered = apu_device_features(cfg);
    // Modern virtio requires VERSION_1. Anything outside the offered mask is a
    // negotiation failure, and transport-only profiles grant no virgl bits.
    return ((driver_features & ~offered) == 64'h0) &&
           ((driver_features & (64'd1 << VIRTIO_F_VERSION_1_BIT)) != 64'h0);
  endfunction

  function automatic bit apu_queue_cfg_ok(input apu_vq_state_t vq);
    logic [63:0] desc_bytes, avail_bytes, used_bytes;
    desc_bytes = 64'(vq.num) << 4;
    avail_bytes = (64'(vq.num) << 1) + 64'd6;
    used_bytes = (64'(vq.num) << 3) + 64'd6;
    return pow2(32'(vq.num)) && (vq.num <= 16'd32768) &&
           (vq.desc[3:0] == 0) && (vq.avail[0] == 0) && (vq.used[1:0] == 0) &&
           (vq.desc <= ~64'd0 - desc_bytes + 64'd1) &&
           (vq.avail <= ~64'd0 - avail_bytes + 64'd1) &&
           (vq.used <= ~64'd0 - used_bytes + 64'd1);
  endfunction

  localparam int unsigned APU_EXEC_IMEM = APU_EXEC_IMEM_WORDS;

  // ExecCluster (exec) op.
  typedef enum logic [4:0] {
    APU_EX_NOP     = 5'd0,
    APU_EX_HALT    = 5'd1,
    APU_EX_LDI     = 5'd2,
    APU_EX_MOV     = 5'd3,
    APU_EX_TID     = 5'd4,
    APU_EX_IADD    = 5'd5,
    APU_EX_ISUB    = 5'd6,
    APU_EX_IAND    = 5'd7,
    APU_EX_IOR     = 5'd8,
    APU_EX_IXOR    = 5'd9,
    APU_EX_FADD    = 5'd10,
    APU_EX_FMUL    = 5'd11,
    APU_EX_FMADD   = 5'd12,
    APU_EX_CMPLT   = 5'd13,
    APU_EX_QUADX   = 5'd14,
    APU_EX_SETMASK = 5'd15,
    APU_EX_BR      = 5'd16,
    APU_EX_LD      = 5'd17,
    APU_EX_ST      = 5'd18,
    APU_EX_FSUB    = 5'd19,
    APU_EX_FNEG    = 5'd20,
    // 32-bit payload in the next IMEM word. pc skips the payload after write.
    APU_EX_LDC     = 5'd21
  } apu_exec_op_e;

  // Compiler words for LDC into r4. 0xAA000000 matches APU_EX_LDC_R4_WORD.
  localparam logic [31:0] APU_EX_LDC_R4_WORD = 32'hAA00_0000;
  localparam logic [31:0] APU_EX_F32_ZERO = 32'h0000_0000;
  localparam logic [31:0] APU_EX_F32_HALF = 32'h3f00_0000;
  localparam logic [31:0] APU_EX_F32_ONE  = 32'h3f80_0000;

  // ExecCluster (exec) instruction.
  typedef struct packed {
    apu_exec_op_e op;
    logic [3:0]   rd;
    logic [3:0]   rs1;
    logic [3:0]   rs2;
    logic [3:0]   rs3;
    logic         pred;
    logic         priv;
    logic [8:0]   imm;
  } apu_exec_inst_t;

  function automatic logic [31:0] apu_exec_enc(
      input apu_exec_op_e op,
      input logic [3:0] rd, rs1, rs2, rs3,
      input logic pred, priv,
      input logic [8:0] imm
  );
    apu_exec_inst_t inst;
    inst = '{op: op, rd: rd, rs1: rs1, rs2: rs2, rs3: rs3, pred: pred, priv: priv, imm: imm};
    return 32'(inst);
  endfunction

  // SpirvSubset (spirv): 128-word immutable SPIR-V-subset program store.
  localparam int unsigned APU_SPIRV_IMEM_WORDS = 128;
  localparam int unsigned APU_SPIRV_IDS        = 32;
  localparam logic [31:0] APU_SPIRV_MAGIC      = 32'h0723_0203;

  // NextChain (chain): programmed virtq_desc table, bounded NEXT walk.
  localparam int unsigned APU_CHAIN_QMAX        = 16;
  localparam int unsigned APU_CHAIN_MAX         = 8;
  localparam int unsigned APU_CHAIN_DESC_BYTES  = 16;
  // ChainDma (cdma): checked DMA window used by the NextChain join.
  localparam logic [63:0] APU_CDMA_WIN_BASE  = 64'h8000_0000;
  localparam logic [63:0] APU_CDMA_WIN_BYTES = 64'h0100_0000;

  typedef enum logic {
    APU_CHAIN_OK    = 1'b0,
    APU_CHAIN_FAULT = 1'b1
  } apu_chain_status_e;

  typedef struct packed {
    apu_chain_status_e status;
  } apu_chain_cpl_t;

  // NextChain (chain): Programmed table base, head index, and bounded chain length.
  typedef struct packed {
    logic [63:0] desc_base;
    logic [7:0] queue_size;
    logic [7:0] head;
    logic [3:0] max_chain;
  } apu_chain_req_t;

  // NextChain (chain): Walked descriptor count and first/last payload windows.
  typedef struct packed {
    logic valid;
    logic [3:0] count;
    logic [7:0] head;
    logic [7:0] last_idx;
    logic [15:0] last_flags;
    logic [63:0] first_addr;
    logic [31:0] first_len;
    logic [63:0] last_addr;
    logic [31:0] last_len;
  } apu_chain_t;

  // AvailNext (avn): virtq_avail ring names a descriptor head for NextChain.
  typedef enum logic [1:0] {
    APU_AVN_OK    = 2'd0,
    APU_AVN_EMPTY = 2'd1,
    APU_AVN_FAULT = 2'd2
  } apu_avn_status_e;

  typedef struct packed {
    apu_avn_status_e status;
  } apu_avn_cpl_t;

  // AvailNext (avn): Programmed avail/desc bases, queue size, and device index.
  typedef struct packed {
    logic [63:0] avail_base;
    logic [63:0] desc_base;
    logic [7:0] queue_size;
    logic [15:0] device_idx;
    logic [3:0] max_chain;
  } apu_avn_req_t;

  // AvailNext (avn): Consumed avail index, named head, and walked windows.
  typedef struct packed {
    logic valid;
    logic [15:0] avail_idx;
    logic [15:0] device_idx;
    logic [15:0] desc_id;
    logic [3:0] count;
    logic [63:0] first_addr;
    logic [31:0] first_len;
    logic [63:0] last_addr;
    logic [31:0] last_len;
    logic [15:0] last_flags;
  } apu_avn_t;

  // AvailUsed (avu): AvailNext consume published on virtq_used.
  typedef enum logic [1:0] {
    APU_AVU_OK    = 2'd0,
    APU_AVU_EMPTY = 2'd1,
    APU_AVU_FAULT = 2'd2
  } apu_avu_status_e;

  typedef struct packed {
    apu_avu_status_e status;
  } apu_avu_cpl_t;

  // AvailUsed (avu): AvailNext request plus used-ring base and index.
  typedef struct packed {
    logic [63:0] avail_base;
    logic [63:0] desc_base;
    logic [63:0] used_base;
    logic [7:0] queue_size;
    logic [15:0] device_idx;
    logic [15:0] used_idx;
    logic [3:0] max_chain;
  } apu_avu_req_t;

  // AvailUsed (avu): Walked windows and published used.idx.
  typedef struct packed {
    logic valid;
    logic [15:0] avail_idx;
    logic [15:0] device_idx;
    logic [15:0] desc_id;
    logic [15:0] used_idx;
    logic [31:0] used_len;
    logic [3:0] count;
    logic [63:0] first_addr;
    logic [63:0] last_addr;
  } apu_avu_t;

  // UsedIrq (uir): virtio used-buffer ISR after used.idx publication.
  localparam logic [31:0] APU_UIR_ISR_VRING = 32'd1;

  typedef enum logic [1:0] {
    APU_UIR_OK    = 2'd0,
    APU_UIR_EMPTY = 2'd1,
    APU_UIR_FAULT = 2'd2
  } apu_uir_status_e;

  typedef struct packed {
    apu_uir_status_e status;
  } apu_uir_cpl_t;

  // UsedIrq (uir): ISR bit 0 after a published used.idx.
  typedef struct packed {
    logic valid;
    logic irq;
    logic [31:0] isr;
    logic [15:0] used_idx;
    logic [15:0] desc_id;
  } apu_uir_t;

  // CmdSnap (cms): immutable first-payload window after AvailNext.
  localparam int unsigned APU_CMS_WORDS = 8;
  localparam int unsigned APU_CMS_BYTES = 32;

  typedef enum logic [1:0] {
    APU_CMS_OK    = 2'd0,
    APU_CMS_EMPTY = 2'd1,
    APU_CMS_FAULT = 2'd2
  } apu_cms_status_e;

  typedef struct packed {
    apu_cms_status_e status;
  } apu_cms_cpl_t;

  // CmdSnap (cms): Snapshotted first payload length and first word.
  typedef struct packed {
    logic valid;
    logic locked;
    logic [31:0] bytes;
    logic [31:0] word0;
    logic [63:0] addr;
  } apu_cms_t;

  // PayResp (prs): WRITE-window response after AvailNext.
  localparam int unsigned APU_PRS_WORDS = 8;
  localparam int unsigned APU_PRS_BYTES = 32;

  typedef enum logic [1:0] {
    APU_PRS_OK    = 2'd0,
    APU_PRS_EMPTY = 2'd1,
    APU_PRS_FAULT = 2'd2
  } apu_prs_status_e;

  typedef struct packed {
    apu_prs_status_e status;
  } apu_prs_cpl_t;

  // PayResp (prs): Written response address, length, and first word.
  typedef struct packed {
    logic valid;
    logic [31:0] bytes;
    logic [31:0] word0;
    logic [63:0] addr;
  } apu_prs_t;

  // QueueDone (qdn): response then used.idx then ISR after one AvailNext.
  typedef enum logic [1:0] {
    APU_QDN_OK    = 2'd0,
    APU_QDN_EMPTY = 2'd1,
    APU_QDN_FAULT = 2'd2
  } apu_qdn_status_e;

  typedef struct packed {
    apu_qdn_status_e status;
  } apu_qdn_cpl_t;

  // QueueDone (qdn): Published used.idx, ISR, and WRITE response address.
  typedef struct packed {
    logic valid;
    logic irq;
    logic [31:0] isr;
    logic [15:0] used_idx;
    logic [15:0] desc_id;
    logic [31:0] resp_word0;
    logic [63:0] resp_addr;
  } apu_qdn_t;

  // GrantCapset (gcs): snapped GET_CAPSET/INFO, Venus blob WRITE, used.idx, ISR.
  // GET response is virtio_gpu_ctrl_hdr (24) plus virgl_renderer_capset_venus (160).
  localparam int unsigned APU_GCS_INFO_BYTES = 40;
  localparam int unsigned APU_GCS_GET_BYTES  = 184;

  typedef enum logic [1:0] {
    APU_GCS_OK    = 2'd0,
    APU_GCS_EMPTY = 2'd1,
    APU_GCS_FAULT = 2'd2
  } apu_gcs_status_e;

  typedef struct packed {
    apu_gcs_status_e status;
  } apu_gcs_cpl_t;

  // GrantCapset (gcs): Granted Venus id, INFO vs GET, and WRITE response address.
  typedef struct packed {
    logic valid;
    logic irq;
    logic info;
    logic [31:0] isr;
    logic [15:0] used_idx;
    logic [15:0] desc_id;
    logic [31:0] capset_id;
    logic [31:0] resp_word0;
    logic [63:0] resp_addr;
  } apu_gcs_t;

  typedef enum logic [1:0] {
    APU_HVIS_BLOB = 2'd0,
    APU_HVIS_MAP  = 2'd1,
    APU_HVIS_CTX  = 2'd2
  } apu_hvis_op_e;

  typedef enum logic {
    APU_HVIS_OK    = 1'b0,
    APU_HVIS_FAULT = 1'b1
  } apu_hvis_status_e;

  typedef struct packed {
    apu_hvis_status_e status;
  } apu_hvis_cpl_t;

  // HostVisible (hvis): Blob create/map and Venus context_init against the SHM window.
  typedef struct packed {
    apu_hvis_op_e op;
    logic [31:0] resource_id;
    logic [63:0] size;
    logic [31:0] blob_mem;
    logic [31:0] blob_flags;
    logic [63:0] map_offset;
    logic [31:0] ctx_id;
    logic [31:0] context_init;
  } apu_hvis_req_t;

  // HostVisible (hvis): Mapped HOST_VISIBLE blob and Venus context id.
  typedef struct packed {
    logic valid;
    logic [31:0] resource_id;
    logic [63:0] size;
    logic [63:0] map_offset;
    logic [31:0] ctx_id;
    logic [31:0] capset_id;
  } apu_hvis_t;

  // VenusCs (vncs): diagnostic HOST_VISIBLE ring, not Mesa vn_protocol.
  localparam int unsigned APU_VNCS_RING_WORDS = 128;
  localparam logic [31:0] APU_VNCS_CREATE     = 32'd1;
  localparam logic [31:0] APU_VNCS_DISPATCH   = 32'd2;

  typedef enum logic {
    APU_VNCS_OK    = 1'b0,
    APU_VNCS_FAULT = 1'b1
  } apu_vncs_status_e;

  typedef struct packed {
    apu_vncs_status_e status;
  } apu_vncs_cpl_t;

  // VenusCapset (vcap): virgl_renderer_capset_venus wire, 40 little-endian words.
  localparam int unsigned APU_VCAP_WORDS = 40;
  localparam int unsigned APU_VCAP_BYTES = 160;
  localparam logic [31:0] APU_VCAP_WIRE_FMT = 32'd1;
  localparam logic [31:0] APU_VCAP_VK_XML   = 32'h0040_1000;
  localparam logic [31:0] APU_VCAP_CMD_SER  = 32'd1;
  localparam logic [31:0] APU_VCAP_VN_PROTO = 32'd1;

  typedef enum logic {
    APU_VCAP_INFO = 1'b0,
    APU_VCAP_GET  = 1'b1
  } apu_vcap_op_e;

  typedef enum logic {
    APU_VCAP_OK    = 1'b0,
    APU_VCAP_FAULT = 1'b1
  } apu_vcap_status_e;

  typedef struct packed {
    apu_vcap_status_e status;
  } apu_vcap_cpl_t;

  // VenusCapset (vcap): GET_CAPSET_INFO / GET_CAPSET for Venus id 4.
  typedef struct packed {
    apu_vcap_op_e op;
    logic [31:0] capset_id;
    logic [31:0] capset_version;
  } apu_vcap_req_t;

  // VenusCapset (vcap): Venus id, max version/size, GET valid.
  typedef struct packed {
    logic valid;
    logic [31:0] capset_id;
    logic [31:0] max_version;
    logic [31:0] max_size;
  } apu_vcap_t;

  function automatic logic [31:0] apu_vcap_word(input logic [5:0] idx);
    unique case (idx)
      6'd0:  apu_vcap_word = APU_VCAP_WIRE_FMT;
      6'd1:  apu_vcap_word = APU_VCAP_VK_XML;
      6'd2:  apu_vcap_word = APU_VCAP_CMD_SER;
      6'd3:  apu_vcap_word = APU_VCAP_VN_PROTO;
      6'd4:  apu_vcap_word = 32'd0;
      6'd5:  apu_vcap_word = 32'd1;
      6'd37: apu_vcap_word = 32'd1;
      6'd38: apu_vcap_word = 32'd0;
      6'd39: apu_vcap_word = 32'd1;
      default: apu_vcap_word = 32'd0;
    endcase
  endfunction

  // VenusRing (vnring): Mesa vn_ring_get_layout, 64-byte aligned fields.
  localparam logic [15:0] APU_VNRING_HEAD_OFF   = 16'd0;
  localparam logic [15:0] APU_VNRING_TAIL_OFF   = 16'd64;
  localparam logic [15:0] APU_VNRING_STATUS_OFF = 16'd128;
  localparam logic [15:0] APU_VNRING_BUF_OFF    = 16'd192;
  localparam int unsigned APU_VNRING_BUF_BYTES  = 256;
  localparam int unsigned APU_VNRING_WORDS      = 128;
  localparam logic [31:0] APU_VNRING_STATUS_IDLE = 32'd1;

  typedef enum logic {
    APU_VNRING_OK    = 1'b0,
    APU_VNRING_FAULT = 1'b1
  } apu_vnring_status_e;

  typedef struct packed {
    apu_vnring_status_e status;
  } apu_vnring_cpl_t;

  // VenusRing (vnring): Consumed byte count and first buffer word.
  typedef struct packed {
    logic valid;
    logic [31:0] head;
    logic [31:0] tail;
    logic [31:0] bytes;
    logic [31:0] first_word;
  } apu_vnring_t;

  // VenusEncode (vnenc): Mesa vn_protocol vkCreateShaderModule CS.
  // Command type 59 is VK_COMMAND_TYPE_vkCreateShaderModule_EXT in Mesa
  // 26.0 / Vulkan 1.0 order. LP64 size_t and handles. Pointers are
  // nonzero uint64 presence flags. FeatureVirgl stays illegal.
  localparam int unsigned APU_VNENC_WORDS = 192;
  localparam logic [31:0] APU_VNENC_CMD_CREATE_SHADER_MODULE = 32'd59;
  localparam logic [31:0] APU_VNENC_STYPE_SHADER_MODULE = 32'd16;
  localparam logic [31:0] APU_VNENC_GENERATE_REPLY = 32'd1;
  localparam logic [31:0] APU_VNENC_SPIRV_MAGIC = 32'h0723_0203;
  localparam int unsigned APU_VNENC_CODE0 = 14;
  localparam int unsigned APU_VNENC_MAX_WORDS = 128;
  localparam int unsigned APU_VNENC_REPLY = 184;
  localparam int unsigned APU_VNENC_REPLY_WORDS = 6;

  typedef enum logic {
    APU_VNENC_OK    = 1'b0,
    APU_VNENC_FAULT = 1'b1
  } apu_vnenc_status_e;

  typedef struct packed {
    apu_vnenc_status_e status;
  } apu_vnenc_cpl_t;

  // VenusEncode (vnenc): Decoded vkCreateShaderModule fields.
  typedef struct packed {
    logic valid;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] device;
    logic [31:0] code_bytes;
    logic [31:0] code_words;
    logic [31:0] first_word;
    logic [63:0] module_id;
    logic reply;
  } apu_vnenc_t;

  // VenusPath (vnp): Mesa vn_ring_layout buffer_size 512, CS into SpirvSubset.
  localparam int unsigned APU_VNP_SHM_WORDS = 256;
  localparam logic [15:0] APU_VNP_BUF_OFF   = 16'd192;
  localparam int unsigned APU_VNP_BUF_BYTES = 512;

  typedef enum logic {
    APU_VNP_OK    = 1'b0,
    APU_VNP_FAULT = 1'b1
  } apu_vnp_status_e;

  typedef struct packed {
    apu_vnp_status_e status;
  } apu_vnp_cpl_t;

  // VenusPath (vnp): Loaded module id and last SPIR-V result.
  typedef struct packed {
    logic valid;
    logic loaded;
    logic [63:0] module_id;
    logic [31:0] code_words;
    logic [31:0] result;
  } apu_vnp_t;

  // VenusDispatch (vnd): Mesa vn_protocol vkCmdDispatch CS.
  // Command type 110 is VK_COMMAND_TYPE_vkCmdDispatch_EXT in Mesa 26.0 /
  // Vulkan 1.0 order (CreateShaderModule is 59 in the same catalog).
  // LP64 command-buffer handle, then groupCountX/Y/Z. GENERATE_REPLY
  // writes the command type. FeatureVirgl stays illegal.
  localparam int unsigned APU_VND_WORDS = 16;
  localparam logic [31:0] APU_VND_CMD_DISPATCH = 32'd110;
  localparam logic [31:0] APU_VND_CMD_DISPATCH_INDIRECT = 32'd111;
  localparam logic [31:0] APU_VND_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VND_REPLY = 8;

  typedef enum logic {
    APU_VND_OK    = 1'b0,
    APU_VND_FAULT = 1'b1
  } apu_vnd_status_e;

  typedef struct packed {
    apu_vnd_status_e status;
  } apu_vnd_cpl_t;

  // VenusDispatch (vnd): Decoded vkCmdDispatch command buffer and groups.
  typedef struct packed {
    logic valid;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] command_buffer;
    logic [31:0] group_x;
    logic [31:0] group_y;
    logic [31:0] group_z;
    logic reply;
  } apu_vnd_t;

  // GenHandle (gnh): generational context/resource/program/cmdbuf/queue table.
  // Published handle is {gen[31:16], 11'd0, slot[4:0]}. Slots 0-15 keep
  // the prior bit pattern. Stale gen lookups fault. Pin must be zero
  // to retire. FeatureVirgl stays illegal.
  localparam int unsigned APU_GNH_SLOTS = 32;

  typedef enum logic [2:0] {
    APU_GNH_ALLOC  = 3'd0,
    APU_GNH_LOOKUP = 3'd1,
    APU_GNH_PIN    = 3'd2,
    APU_GNH_UNPIN  = 3'd3,
    APU_GNH_RETIRE = 3'd4
  } apu_gnh_op_e;

  typedef enum logic [4:0] {
    APU_GNH_CTX      = 5'd0,
    APU_GNH_RES      = 5'd1,
    APU_GNH_MODULE   = 5'd2,
    APU_GNH_CMDBUF   = 5'd3,
    APU_GNH_QUEUE    = 5'd4,
    APU_GNH_DEVICE   = 5'd5,
    APU_GNH_INSTANCE = 5'd6,
    APU_GNH_PHYS     = 5'd7,
    APU_GNH_MEMORY   = 5'd8,
    APU_GNH_BUFFER   = 5'd9,
    APU_GNH_DSLAYOUT = 5'd10,
    APU_GNH_PLAYOUT  = 5'd11,
    APU_GNH_PIPELINE = 5'd12,
    APU_GNH_DESCSET  = 5'd13,
    APU_GNH_POOL     = 5'd14,
    APU_GNH_IMAGE    = 5'd15,
    APU_GNH_VIEW     = 5'd16,
    APU_GNH_SAMPLER  = 5'd17,
    APU_GNH_RPASS    = 5'd18,
    APU_GNH_FBUF     = 5'd19
  } apu_gnh_kind_e;

  typedef enum logic {
    APU_GNH_OK    = 1'b0,
    APU_GNH_FAULT = 1'b1
  } apu_gnh_status_e;

  typedef struct packed {
    apu_gnh_status_e status;
  } apu_gnh_cpl_t;

  typedef struct packed {
    apu_gnh_op_e op;
    apu_gnh_kind_e kind;
    logic [31:0] object_id;
    logic [31:0] handle;
  } apu_gnh_req_t;

  // GenHandle (gnh): Live published handle, kind, object id, and pin.
  typedef struct packed {
    logic valid;
    logic [4:0] slot;
    logic [15:0] gen;
    logic [7:0] pin;
    apu_gnh_kind_e kind;
    logic [31:0] object_id;
    logic [31:0] handle;
  } apu_gnh_t;

  function automatic logic [31:0] apu_gnh_handle(
      input logic [15:0] gen, input logic [4:0] slot);
    apu_gnh_handle = {gen, 11'd0, slot};
  endfunction

  // HandleDispatch (hdp): GenHandle lookup of vkCmdDispatch commandBuffer.
  typedef enum logic {
    APU_HDP_OK    = 1'b0,
    APU_HDP_FAULT = 1'b1
  } apu_hdp_status_e;

  typedef struct packed {
    apu_hdp_status_e status;
  } apu_hdp_cpl_t;

  typedef struct packed {
    logic dispatch;
    apu_gnh_req_t gnh;
  } apu_hdp_req_t;

  // HandleDispatch (hdp): Published cmdbuf handle and decoded groups.
  typedef struct packed {
    logic valid;
    logic dispatch;
    logic [4:0] slot;
    logic [15:0] gen;
    apu_gnh_kind_e kind;
    logic [31:0] object_id;
    logic [31:0] handle;
    logic [31:0] group_x;
    logic [31:0] group_y;
    logic [31:0] group_z;
  } apu_hdp_t;

  // HandlePath (hph): CreateShaderModule publishes MODULE; dispatch looks up CMDBUF.
  typedef enum logic [1:0] {
    APU_HPH_GNH      = 2'd0,
    APU_HPH_CREATE   = 2'd1,
    APU_HPH_DISPATCH = 2'd2
  } apu_hph_op_e;

  typedef enum logic {
    APU_HPH_OK    = 1'b0,
    APU_HPH_FAULT = 1'b1
  } apu_hph_status_e;

  typedef struct packed {
    apu_hph_status_e status;
  } apu_hph_cpl_t;

  typedef struct packed {
    apu_hph_op_e op;
    apu_gnh_req_t gnh;
  } apu_hph_req_t;

  // HandlePath (hph): Published MODULE or CMDBUF handle after create/dispatch.
  typedef struct packed {
    logic valid;
    logic create;
    logic dispatch;
    logic [4:0] slot;
    logic [15:0] gen;
    apu_gnh_kind_e kind;
    logic [31:0] object_id;
    logic [31:0] handle;
    logic [31:0] code_words;
    logic [31:0] group_x;
    logic [31:0] group_y;
    logic [31:0] group_z;
  } apu_hph_t;

  // HandleRun (hrn): HandlePath create/dispatch then SpirvSubset kick.
  typedef enum logic [1:0] {
    APU_HRN_GNH      = 2'd0,
    APU_HRN_CREATE   = 2'd1,
    APU_HRN_DISPATCH = 2'd2
  } apu_hrn_op_e;

  typedef enum logic {
    APU_HRN_OK    = 1'b0,
    APU_HRN_FAULT = 1'b1
  } apu_hrn_status_e;

  typedef struct packed {
    apu_hrn_status_e status;
  } apu_hrn_cpl_t;

  typedef struct packed {
    apu_hrn_op_e op;
    apu_gnh_req_t gnh;
  } apu_hrn_req_t;

  // HandleRun (hrn): Published handles, loaded module, and SPIR-V result.
  typedef struct packed {
    logic valid;
    logic create;
    logic dispatch;
    logic loaded;
    logic [4:0] slot;
    logic [15:0] gen;
    apu_gnh_kind_e kind;
    logic [31:0] object_id;
    logic [31:0] handle;
    logic [31:0] code_words;
    logic [31:0] group_x;
    logic [31:0] group_y;
    logic [31:0] group_z;
    logic [31:0] result;
  } apu_hrn_t;

  // RunDone (rdn): HandleRun dispatch then WRITE result, used.idx, ISR.
  typedef enum logic [1:0] {
    APU_RDN_OK    = 2'd0,
    APU_RDN_FAULT = 2'd1
  } apu_rdn_status_e;

  typedef struct packed {
    apu_rdn_status_e status;
  } apu_rdn_cpl_t;

  typedef struct packed {
    apu_hrn_req_t hrn;
    logic [63:0] used_base;
    logic [63:0] resp_addr;
    logic [15:0] used_idx;
    logic [15:0] desc_id;
    logic [7:0] queue_size;
  } apu_rdn_req_t;

  // RunDone (rdn): SPIR-V result published to WRITE window then used.idx.
  typedef struct packed {
    logic valid;
    logic dispatch;
    logic irq;
    logic [31:0] isr;
    logic [15:0] used_idx;
    logic [15:0] desc_id;
    logic [31:0] handle;
    logic [31:0] result;
    logic [31:0] resp_word0;
    logic [63:0] resp_addr;
  } apu_rdn_t;

  // QueueRun (qrn): AvailNext payload into RunDone CREATE or DISPATCH.
  typedef enum logic [1:0] {
    APU_QRN_OK    = 2'd0,
    APU_QRN_EMPTY = 2'd1,
    APU_QRN_FAULT = 2'd2
  } apu_qrn_status_e;

  typedef struct packed {
    apu_qrn_status_e status;
  } apu_qrn_cpl_t;

  typedef struct packed {
    logic gnh_only;
    apu_gnh_req_t gnh;
    apu_avu_req_t avu;
  } apu_qrn_req_t;

  // QueueRun (qrn): Walked CS command, published result, and used.idx.
  typedef struct packed {
    logic valid;
    logic dispatch;
    logic irq;
    logic [31:0] cmd;
    logic [31:0] result;
    logic [31:0] handle;
    logic [15:0] used_idx;
    logic [63:0] resp_addr;
  } apu_qrn_t;

  // QueueCmd (qcm): GrantCapset or QueueRun on one request port.
  typedef enum logic [1:0] {
    APU_QCM_OK    = 2'd0,
    APU_QCM_EMPTY = 2'd1,
    APU_QCM_FAULT = 2'd2
  } apu_qcm_status_e;

  typedef struct packed {
    apu_qcm_status_e status;
  } apu_qcm_cpl_t;

  typedef struct packed {
    logic capset;
    apu_qrn_req_t qrn;
  } apu_qcm_req_t;

  // QueueCmd (qcm): Capset blob or CREATE/DISPATCH result after one walk.
  typedef struct packed {
    logic valid;
    logic capset;
    logic info;
    logic dispatch;
    logic irq;
    logic [31:0] cmd;
    logic [31:0] result;
    logic [31:0] handle;
    logic [31:0] capset_id;
    logic [31:0] resp_word0;
    logic [15:0] used_idx;
    logic [63:0] resp_addr;
  } apu_qcm_t;

  // QueueType (qty): AvailNext type word selects GrantCapset or QueueRun.
  typedef enum logic [1:0] {
    APU_QTY_OK    = 2'd0,
    APU_QTY_EMPTY = 2'd1,
    APU_QTY_FAULT = 2'd2
  } apu_qty_status_e;

  typedef struct packed {
    apu_qty_status_e status;
  } apu_qty_cpl_t;

  typedef struct packed {
    apu_qrn_req_t qrn;
  } apu_qty_req_t;

  // QueueType (qty): Peeked type word, then capset blob or CREATE/DISPATCH.
  typedef struct packed {
    logic valid;
    logic capset;
    logic info;
    logic dispatch;
    logic irq;
    logic [31:0] type_word;
    logic [31:0] cmd;
    logic [31:0] result;
    logic [31:0] handle;
    logic [31:0] capset_id;
    logic [31:0] resp_word0;
    logic [15:0] used_idx;
    logic [63:0] resp_addr;
  } apu_qty_t;

  // VenusCtrl (vct): Private Venus config advertisement and QueueNotify.
  localparam int unsigned APU_VCT_NUM_CAPSETS = 1;

  typedef enum logic [1:0] {
    APU_VCT_CFG    = 2'd0,
    APU_VCT_INFO   = 2'd1,
    APU_VCT_NOTIFY = 2'd2
  } apu_vct_op_e;

  typedef enum logic [1:0] {
    APU_VCT_OK    = 2'd0,
    APU_VCT_EMPTY = 2'd1,
    APU_VCT_FAULT = 2'd2
  } apu_vct_status_e;

  typedef struct packed {
    apu_vct_status_e status;
  } apu_vct_cpl_t;

  typedef struct packed {
    apu_vct_op_e op;
    logic [15:0] cfg_addr;
    logic [31:0] capset_index;
    logic [31:0] queue_sel;
    apu_qty_req_t qty;
  } apu_vct_req_t;

  // VenusCtrl (vct): Private num_capsets=1, INFO, or QueueNotify result.
  typedef struct packed {
    logic valid;
    logic capset;
    logic info;
    logic dispatch;
    logic irq;
    logic [31:0] cfg_rdata;
    logic [31:0] num_capsets;
    logic [31:0] capset_id;
    logic [31:0] max_version;
    logic [31:0] max_size;
    logic [31:0] type_word;
    logic [31:0] cmd;
    logic [31:0] result;
    logic [31:0] handle;
    logic [31:0] resp_word0;
    logic [15:0] used_idx;
    logic [63:0] resp_addr;
  } apu_vct_t;

  // QueuePump (qpu): QueueNotify drains AvailNext until EMPTY.
  typedef enum logic [1:0] {
    APU_QPU_OK    = 2'd0,
    APU_QPU_EMPTY = 2'd1,
    APU_QPU_FAULT = 2'd2
  } apu_qpu_status_e;

  typedef struct packed {
    apu_qpu_status_e status;
  } apu_qpu_cpl_t;

  typedef struct packed {
    apu_vct_req_t vct;
  } apu_qpu_req_t;

  // QueuePump (qpu): Last command record and number of consumed descriptors.
  typedef struct packed {
    logic valid;
    logic capset;
    logic info;
    logic dispatch;
    logic irq;
    logic [7:0] count;
    logic [31:0] cfg_rdata;
    logic [31:0] num_capsets;
    logic [31:0] capset_id;
    logic [31:0] max_version;
    logic [31:0] max_size;
    logic [31:0] type_word;
    logic [31:0] cmd;
    logic [31:0] result;
    logic [31:0] handle;
    logic [31:0] resp_word0;
    logic [15:0] used_idx;
    logic [63:0] resp_addr;
  } apu_qpu_t;

  // NotifyTake (ntk): virtio notify_pending[0] consumes QueuePump.
  typedef enum logic [1:0] {
    APU_NTK_OK    = 2'd0,
    APU_NTK_EMPTY = 2'd1,
    APU_NTK_FAULT = 2'd2
  } apu_ntk_status_e;

  typedef struct packed {
    apu_ntk_status_e status;
  } apu_ntk_cpl_t;

  typedef struct packed {
    logic arm;
    apu_qpu_req_t qpu;
  } apu_ntk_req_t;

  // NotifyTake (ntk): Bound queue, consumed count, and last pump record.
  typedef struct packed {
    logic valid;
    logic bound;
    logic capset;
    logic info;
    logic dispatch;
    logic irq;
    logic [1:0] clear;
    logic [7:0] count;
    logic [31:0] cfg_rdata;
    logic [31:0] num_capsets;
    logic [31:0] capset_id;
    logic [31:0] max_version;
    logic [31:0] max_size;
    logic [31:0] type_word;
    logic [31:0] cmd;
    logic [31:0] result;
    logic [31:0] handle;
    logic [31:0] resp_word0;
    logic [15:0] used_idx;
    logic [63:0] resp_addr;
  } apu_ntk_t;

  // VqTake (vqt): virtio vq_state[0] arms NotifyTake on notify_pending[0].
  typedef enum logic [1:0] {
    APU_VQT_OK    = 2'd0,
    APU_VQT_EMPTY = 2'd1,
    APU_VQT_FAULT = 2'd2
  } apu_vqt_status_e;

  typedef struct packed {
    apu_vqt_status_e status;
  } apu_vqt_cpl_t;

  typedef struct packed {
    apu_ntk_req_t ntk;
  } apu_vqt_req_t;

  // VqTake (vqt): Armed from vq_state, last NotifyTake record.
  typedef struct packed {
    logic valid;
    logic bound;
    logic capset;
    logic info;
    logic dispatch;
    logic irq;
    logic [1:0] clear;
    logic [7:0] count;
    logic [31:0] cfg_rdata;
    logic [31:0] num_capsets;
    logic [31:0] capset_id;
    logic [31:0] max_version;
    logic [31:0] max_size;
    logic [31:0] type_word;
    logic [31:0] cmd;
    logic [31:0] result;
    logic [31:0] handle;
    logic [31:0] resp_word0;
    logic [15:0] used_idx;
    logic [63:0] resp_addr;
  } apu_vqt_t;

  // VqAxi (vax): VqTake guest beats on 64-bit AXI.
  typedef enum logic [1:0] {
    APU_VAX_OK    = 2'd0,
    APU_VAX_EMPTY = 2'd1,
    APU_VAX_FAULT = 2'd2
  } apu_vax_status_e;

  typedef struct packed {
    apu_vax_status_e status;
  } apu_vax_cpl_t;

  typedef struct packed {
    apu_vqt_req_t vqt;
  } apu_vax_req_t;

  // VqAxi (vax): Last VqTake record after AXI guest beats.
  typedef struct packed {
    logic valid;
    logic bound;
    logic capset;
    logic info;
    logic dispatch;
    logic irq;
    logic [1:0] clear;
    logic [7:0] count;
    logic [31:0] cfg_rdata;
    logic [31:0] num_capsets;
    logic [31:0] capset_id;
    logic [31:0] max_version;
    logic [31:0] max_size;
    logic [31:0] type_word;
    logic [31:0] cmd;
    logic [31:0] result;
    logic [31:0] handle;
    logic [31:0] resp_word0;
    logic [15:0] used_idx;
    logic [63:0] resp_addr;
  } apu_vax_t;

  // VenusAlloc (vac): Mesa vn_protocol vkAllocateCommandBuffers CS.
  // Command type 88 is VK_COMMAND_TYPE_vkAllocateCommandBuffers_EXT in
  // Mesa 26.0 / Vulkan 1.0 order (CreateShaderModule is 59, Dispatch is
  // 110 in the same catalog). sType 40 is
  // VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO. Count 1, PRIMARY
  // level, then ALLOC CMDBUF. FeatureVirgl stays illegal.
  localparam int unsigned APU_VAC_WORDS = 24;
  localparam logic [31:0] APU_VAC_CMD_ALLOC = 32'd88;
  localparam logic [31:0] APU_VAC_STYPE_ALLOC = 32'd40;
  localparam logic [31:0] APU_VAC_LEVEL_PRIMARY = 32'd0;
  localparam logic [31:0] APU_VAC_LEVEL_SECONDARY = 32'd1;
  localparam logic [31:0] APU_VAC_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VAC_REPLY = 18;
  localparam int unsigned APU_VAC_REPLY_WORDS = 6;

  typedef enum logic {
    APU_VAC_OK    = 1'b0,
    APU_VAC_FAULT = 1'b1
  } apu_vac_status_e;

  typedef struct packed {
    apu_vac_status_e status;
  } apu_vac_cpl_t;

  // VenusAlloc (vac): Decoded allocate and published CMDBUF handle.
  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] device;
    logic [63:0] pool;
    logic [31:0] level;
    logic [31:0] count;
    logic [31:0] object_id;
    logic [31:0] handle;
    logic [4:0] slot;
    logic [15:0] gen;
    apu_gnh_kind_e kind;
  } apu_vac_t;

  // HandleAlloc (hal): vkAllocateCommandBuffers ALLOC CMDBUF then
  // vkCmdDispatch LOOKUP on one GenHandle table. FeatureVirgl stays illegal.
  typedef enum logic [1:0] {
    APU_HAL_GNH      = 2'd0,
    APU_HAL_ALLOC    = 2'd1,
    APU_HAL_DISPATCH = 2'd2
  } apu_hal_op_e;

  typedef enum logic {
    APU_HAL_OK    = 1'b0,
    APU_HAL_FAULT = 1'b1
  } apu_hal_status_e;

  typedef struct packed {
    apu_hal_status_e status;
  } apu_hal_cpl_t;

  typedef struct packed {
    apu_hal_op_e op;
    apu_gnh_req_t gnh;
  } apu_hal_req_t;

  // HandleAlloc (hal): Published CMDBUF after allocate or dispatch lookup.
  typedef struct packed {
    logic valid;
    logic alloc;
    logic dispatch;
    logic reply;
    logic [4:0] slot;
    logic [15:0] gen;
    apu_gnh_kind_e kind;
    logic [31:0] object_id;
    logic [31:0] handle;
    logic [31:0] group_x;
    logic [31:0] group_y;
    logic [31:0] group_z;
  } apu_hal_t;

  // AllocRun (aru): ALLOC CMDBUF, CREATE MODULE, then DISPATCH SpirvSubset
  // on one GenHandle table. FeatureVirgl stays illegal.
  typedef enum logic [1:0] {
    APU_ARU_GNH      = 2'd0,
    APU_ARU_CREATE   = 2'd1,
    APU_ARU_DISPATCH = 2'd2,
    APU_ARU_ALLOC    = 2'd3
  } apu_aru_op_e;

  typedef enum logic {
    APU_ARU_OK    = 1'b0,
    APU_ARU_FAULT = 1'b1
  } apu_aru_status_e;

  typedef struct packed {
    apu_aru_status_e status;
  } apu_aru_cpl_t;

  typedef struct packed {
    apu_aru_op_e op;
    apu_gnh_req_t gnh;
  } apu_aru_req_t;

  // AllocRun (aru): Published handles, loaded module, and SPIR-V result.
  typedef struct packed {
    logic valid;
    logic alloc;
    logic create;
    logic dispatch;
    logic loaded;
    logic reply;
    logic [4:0] slot;
    logic [15:0] gen;
    apu_gnh_kind_e kind;
    logic [31:0] object_id;
    logic [31:0] handle;
    logic [31:0] code_words;
    logic [31:0] group_x;
    logic [31:0] group_y;
    logic [31:0] group_z;
    logic [31:0] result;
  } apu_aru_t;

  // QueueAlloc (qal): AvailNext CS into AllocRun ALLOC/CREATE/DISPATCH.
  typedef enum logic [1:0] {
    APU_QAL_OK    = 2'd0,
    APU_QAL_EMPTY = 2'd1,
    APU_QAL_FAULT = 2'd2
  } apu_qal_status_e;

  typedef struct packed {
    apu_qal_status_e status;
  } apu_qal_cpl_t;

  typedef struct packed {
    logic gnh_only;
    apu_gnh_req_t gnh;
    apu_avu_req_t avu;
  } apu_qal_req_t;

  // QueueAlloc (qal): Walked CS command, published result, and used.idx.
  typedef struct packed {
    logic valid;
    logic alloc;
    logic dispatch;
    logic irq;
    logic [31:0] cmd;
    logic [31:0] result;
    logic [31:0] handle;
    logic [15:0] used_idx;
    logic [63:0] resp_addr;
  } apu_qal_t;

  // QueueTypeAlloc (qta): AvailNext type word selects GrantCapset or QueueAlloc.
  typedef enum logic [1:0] {
    APU_QTA_OK    = 2'd0,
    APU_QTA_EMPTY = 2'd1,
    APU_QTA_FAULT = 2'd2
  } apu_qta_status_e;

  typedef struct packed {
    apu_qta_status_e status;
  } apu_qta_cpl_t;

  typedef struct packed {
    apu_qal_req_t qal;
  } apu_qta_req_t;

  // QueueTypeAlloc (qta): Peeked type word, then capset blob or ALLOC/CREATE/DISPATCH.
  typedef struct packed {
    logic valid;
    logic capset;
    logic info;
    logic alloc;
    logic dispatch;
    logic irq;
    logic [31:0] type_word;
    logic [31:0] cmd;
    logic [31:0] result;
    logic [31:0] handle;
    logic [31:0] capset_id;
    logic [31:0] resp_word0;
    logic [15:0] used_idx;
    logic [63:0] resp_addr;
  } apu_qta_t;

  // VenusCtrlAlloc (vca): Private Venus num_capsets=1 and QueueNotify into QueueTypeAlloc.
  localparam int unsigned APU_VCA_NUM_CAPSETS = 1;

  typedef enum logic [1:0] {
    APU_VCA_CFG    = 2'd0,
    APU_VCA_INFO   = 2'd1,
    APU_VCA_NOTIFY = 2'd2
  } apu_vca_op_e;

  typedef enum logic [1:0] {
    APU_VCA_OK    = 2'd0,
    APU_VCA_EMPTY = 2'd1,
    APU_VCA_FAULT = 2'd2
  } apu_vca_status_e;

  typedef struct packed {
    apu_vca_status_e status;
  } apu_vca_cpl_t;

  typedef struct packed {
    apu_vca_op_e op;
    logic [15:0] cfg_addr;
    logic [31:0] capset_index;
    logic [31:0] queue_sel;
    apu_qta_req_t qta;
  } apu_vca_req_t;

  // VenusCtrlAlloc (vca): Private num_capsets=1, INFO, or QueueNotify result.
  typedef struct packed {
    logic valid;
    logic capset;
    logic info;
    logic alloc;
    logic dispatch;
    logic irq;
    logic [31:0] cfg_rdata;
    logic [31:0] num_capsets;
    logic [31:0] capset_id;
    logic [31:0] max_version;
    logic [31:0] max_size;
    logic [31:0] type_word;
    logic [31:0] cmd;
    logic [31:0] result;
    logic [31:0] handle;
    logic [31:0] resp_word0;
    logic [15:0] used_idx;
    logic [63:0] resp_addr;
  } apu_vca_t;

  // QueuePumpAlloc (qpa): QueueNotify drains QueueTypeAlloc until EMPTY.
  typedef enum logic [1:0] {
    APU_QPA_OK    = 2'd0,
    APU_QPA_EMPTY = 2'd1,
    APU_QPA_FAULT = 2'd2
  } apu_qpa_status_e;

  typedef struct packed {
    apu_qpa_status_e status;
  } apu_qpa_cpl_t;

  typedef struct packed {
    apu_vca_req_t vca;
  } apu_qpa_req_t;

  // QueuePumpAlloc (qpa): Last command record and number of consumed descriptors.
  typedef struct packed {
    logic valid;
    logic capset;
    logic info;
    logic alloc;
    logic dispatch;
    logic irq;
    logic [7:0] count;
    logic [31:0] cfg_rdata;
    logic [31:0] num_capsets;
    logic [31:0] capset_id;
    logic [31:0] max_version;
    logic [31:0] max_size;
    logic [31:0] type_word;
    logic [31:0] cmd;
    logic [31:0] result;
    logic [31:0] handle;
    logic [31:0] resp_word0;
    logic [15:0] used_idx;
    logic [63:0] resp_addr;
  } apu_qpa_t;

  // NotifyTakeAlloc (nta): virtio notify_pending[0] consumes QueuePumpAlloc.
  typedef enum logic [1:0] {
    APU_NTA_OK    = 2'd0,
    APU_NTA_EMPTY = 2'd1,
    APU_NTA_FAULT = 2'd2
  } apu_nta_status_e;

  typedef struct packed {
    apu_nta_status_e status;
  } apu_nta_cpl_t;

  typedef struct packed {
    logic arm;
    apu_qpa_req_t qpa;
  } apu_nta_req_t;

  // NotifyTakeAlloc (nta): Bound queue, consumed count, and last pump record.
  typedef struct packed {
    logic valid;
    logic bound;
    logic capset;
    logic info;
    logic alloc;
    logic dispatch;
    logic irq;
    logic [1:0] clear;
    logic [7:0] count;
    logic [31:0] cfg_rdata;
    logic [31:0] num_capsets;
    logic [31:0] capset_id;
    logic [31:0] max_version;
    logic [31:0] max_size;
    logic [31:0] type_word;
    logic [31:0] cmd;
    logic [31:0] result;
    logic [31:0] handle;
    logic [31:0] resp_word0;
    logic [15:0] used_idx;
    logic [63:0] resp_addr;
  } apu_nta_t;

  // VqTakeAlloc (vqa): virtio vq_state[0] arms NotifyTakeAlloc on notify_pending[0].
  typedef enum logic [1:0] {
    APU_VQA_OK    = 2'd0,
    APU_VQA_EMPTY = 2'd1,
    APU_VQA_FAULT = 2'd2
  } apu_vqa_status_e;

  typedef struct packed {
    apu_vqa_status_e status;
  } apu_vqa_cpl_t;

  typedef struct packed {
    apu_nta_req_t nta;
  } apu_vqa_req_t;

  // VqTakeAlloc (vqa): Armed from vq_state, last NotifyTakeAlloc record.
  typedef struct packed {
    logic valid;
    logic bound;
    logic capset;
    logic info;
    logic alloc;
    logic dispatch;
    logic irq;
    logic [1:0] clear;
    logic [7:0] count;
    logic [31:0] cfg_rdata;
    logic [31:0] num_capsets;
    logic [31:0] capset_id;
    logic [31:0] max_version;
    logic [31:0] max_size;
    logic [31:0] type_word;
    logic [31:0] cmd;
    logic [31:0] result;
    logic [31:0] handle;
    logic [31:0] resp_word0;
    logic [15:0] used_idx;
    logic [63:0] resp_addr;
  } apu_vqa_t;

  // VqAxiAlloc (vaa): VqTakeAlloc guest beats on 64-bit AXI.
  typedef enum logic [1:0] {
    APU_VAA_OK    = 2'd0,
    APU_VAA_EMPTY = 2'd1,
    APU_VAA_FAULT = 2'd2
  } apu_vaa_status_e;

  typedef struct packed {
    apu_vaa_status_e status;
  } apu_vaa_cpl_t;

  typedef struct packed {
    apu_vqa_req_t vqa;
  } apu_vaa_req_t;

  // VqAxiAlloc (vaa): Last VqTakeAlloc record after AXI guest beats.
  typedef struct packed {
    logic valid;
    logic bound;
    logic capset;
    logic info;
    logic alloc;
    logic dispatch;
    logic irq;
    logic [1:0] clear;
    logic [7:0] count;
    logic [31:0] cfg_rdata;
    logic [31:0] num_capsets;
    logic [31:0] capset_id;
    logic [31:0] max_version;
    logic [31:0] max_size;
    logic [31:0] type_word;
    logic [31:0] cmd;
    logic [31:0] result;
    logic [31:0] handle;
    logic [31:0] resp_word0;
    logic [15:0] used_idx;
    logic [63:0] resp_addr;
  } apu_vaa_t;

  // VenusBegin (vbg): Mesa vn_protocol vkBeginCommandBuffer CS.
  // Command type 90 is VK_COMMAND_TYPE_vkBeginCommandBuffer_EXT in
  // Mesa 26.0 / Vulkan 1.0 catalog order (AllocateCommandBuffers is
  // 88, CreateShaderModule is 59, Dispatch is 110). sType 42 is
  // VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO. PRIMARY has a null
  // inheritance pointer. GENERATE_REPLY writes type + VK_SUCCESS.
  // FeatureVirgl stays illegal.
  localparam int unsigned APU_VBG_WORDS = 16;
  localparam logic [31:0] APU_VBG_CMD_BEGIN = 32'd90;
  localparam logic [31:0] APU_VBG_CMD_END = 32'd91;
  localparam logic [31:0] APU_VBG_STYPE_BEGIN = 32'd42;
  localparam logic [31:0] APU_VBG_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VBG_REPLY = 12;

  typedef enum logic {
    APU_VBG_OK    = 1'b0,
    APU_VBG_FAULT = 1'b1
  } apu_vbg_status_e;

  typedef struct packed {
    apu_vbg_status_e status;
  } apu_vbg_cpl_t;

  // VenusBegin (vbg): Decoded vkBeginCommandBuffer command buffer.
  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] command_buffer;
    logic [31:0] stype;
    logic [31:0] begin_flags;
  } apu_vbg_t;

  // BeginAlloc (bal): vkAllocateCommandBuffers ALLOC CMDBUF then
  // vkBeginCommandBuffer LOOKUP on one GenHandle table. FeatureVirgl
  // stays illegal.
  typedef enum logic [1:0] {
    APU_BAL_GNH   = 2'd0,
    APU_BAL_ALLOC = 2'd1,
    APU_BAL_BEGIN = 2'd2
  } apu_bal_op_e;

  typedef enum logic {
    APU_BAL_OK    = 1'b0,
    APU_BAL_FAULT = 1'b1
  } apu_bal_status_e;

  typedef struct packed {
    apu_bal_status_e status;
  } apu_bal_cpl_t;

  typedef struct packed {
    apu_bal_op_e op;
    apu_gnh_req_t gnh;
  } apu_bal_req_t;

  // BeginAlloc (bal): Published CMDBUF after allocate or begin lookup.
  typedef struct packed {
    logic valid;
    logic alloc;
    logic begin_cmd;
    logic reply;
    logic [4:0] slot;
    logic [15:0] gen;
    apu_gnh_kind_e kind;
    logic [31:0] object_id;
    logic [31:0] handle;
    logic [31:0] begin_flags;
  } apu_bal_t;

  // BeginRun (bru): ALLOC CMDBUF, BEGIN LOOKUP, CREATE MODULE,
  // DISPATCH SpirvSubset, then END LOOKUP on one GenHandle table.
  // FeatureVirgl stays illegal.
  typedef enum logic [6:0] {
    APU_BRU_GNH      = 7'd0,
    APU_BRU_ALLOC    = 7'd1,
    APU_BRU_BEGIN    = 7'd2,
    APU_BRU_CREATE   = 7'd3,
    APU_BRU_DISPATCH = 7'd4,
    APU_BRU_END      = 7'd5,
    APU_BRU_SUBMIT   = 7'd6,
    APU_BRU_WAIT     = 7'd7,
    APU_BRU_QUEUE    = 7'd8,
    APU_BRU_DEVICE   = 7'd9,
    APU_BRU_INSTANCE = 7'd10,
    APU_BRU_ENUM     = 7'd11,
    APU_BRU_QFAM     = 7'd12,
    APU_BRU_FEAT     = 7'd13,
    APU_BRU_PROPS    = 7'd14,
    APU_BRU_MEM      = 7'd15,
    APU_BRU_VKMEM    = 7'd16,
    APU_BRU_BUFFER   = 7'd17,
    APU_BRU_BIND     = 7'd18,
    APU_BRU_MAP      = 7'd19,
    APU_BRU_UNMAP    = 7'd20,
    APU_BRU_BUFREQ   = 7'd21,
    APU_BRU_FLUSH    = 7'd22,
    APU_BRU_INVAL    = 7'd23,
    APU_BRU_MEMC     = 7'd24,
    APU_BRU_DSLAYOUT = 7'd25,
    APU_BRU_PLAYOUT  = 7'd26,
    APU_BRU_CPIPE    = 7'd27,
    APU_BRU_DESCSET  = 7'd28,
    APU_BRU_UPDATE   = 7'd29,
    APU_BRU_BINDPIPE = 7'd30,
    APU_BRU_BINDDESC = 7'd31,
    APU_BRU_POOL     = 7'd32,
    APU_BRU_IMAGE    = 7'd33,
    APU_BRU_BINDIMG  = 7'd34,
    APU_BRU_IMGREQ   = 7'd35,
    APU_BRU_VIEW     = 7'd36,
    APU_BRU_SAMPLER  = 7'd37,
    APU_BRU_RPASS    = 7'd38,
    APU_BRU_GPIPE    = 7'd39,
    APU_BRU_FBUF     = 7'd40,
    APU_BRU_BEGINRP  = 7'd41,
    APU_BRU_DRAW     = 7'd42,
    APU_BRU_ENDRP    = 7'd43,
    APU_BRU_BINDVTX  = 7'd44,
    APU_BRU_BINDIDX  = 7'd45,
    APU_BRU_DRAWIDX  = 7'd46,
    APU_BRU_SETVP    = 7'd47,
    APU_BRU_SETSC    = 7'd48,
    APU_BRU_BARRIER  = 7'd49,
    APU_BRU_NEXTSP   = 7'd50,
    APU_BRU_DFB      = 7'd51,
    APU_BRU_DVW      = 7'd52,
    APU_BRU_DSM      = 7'd53,
    APU_BRU_DRP      = 7'd54,
    APU_BRU_DBF      = 7'd55,
    APU_BRU_DIM      = 7'd56,
    APU_BRU_FME      = 7'd57,
    APU_BRU_DMD      = 7'd58,
    APU_BRU_DPL      = 7'd59,
    APU_BRU_DYO      = 7'd60,
    APU_BRU_DDS      = 7'd61,
    APU_BRU_DPO      = 7'd62,
    APU_BRU_FDS      = 7'd63,
    APU_BRU_RCB      = 7'd64,
    APU_BRU_FCB      = 7'd65,
    APU_BRU_DDV      = 7'd66,
    APU_BRU_RCP      = 7'd67,
    APU_BRU_DCP      = 7'd68,
    APU_BRU_DIN      = 7'd69,
    APU_BRU_GFP      = 7'd70,
    APU_BRU_IFP      = 7'd71,
    APU_BRU_DEX      = 7'd72,
    APU_BRU_RDP      = 7'd73,
    APU_BRU_IEX      = 7'd74,
    APU_BRU_DWI      = 7'd75,
    APU_BRU_ISL      = 7'd76,
    APU_BRU_RAG      = 7'd77,
    APU_BRU_SLW      = 7'd78,
    APU_BRU_SDB      = 7'd79,
    APU_BRU_SBC      = 7'd80,
    APU_BRU_SBB      = 7'd81,
    APU_BRU_SCM      = 7'd82,
    APU_BRU_SWM      = 7'd83,
    APU_BRU_SRF      = 7'd84,
    APU_BRU_CCB      = 7'd85,
    APU_BRU_CCI      = 7'd86,
    APU_BRU_BLI      = 7'd87,
    APU_BRU_CBI      = 7'd88,
    APU_BRU_CIB      = 7'd89,
    APU_BRU_UBF      = 7'd90,
    APU_BRU_FIL      = 7'd91,
    APU_BRU_CCL      = 7'd92,
    APU_BRU_DRI      = 7'd93,
    APU_BRU_DXI      = 7'd94,
    APU_BRU_CDS      = 7'd95,
    APU_BRU_CAT      = 7'd96,
    APU_BRU_DSI      = 7'd97,
    APU_BRU_RSI      = 7'd98,
    APU_BRU_GFS      = 7'd99,
    APU_BRU_WFE      = 7'd100,
    APU_BRU_RFE      = 7'd101,
    APU_BRU_DFE      = 7'd102
  } apu_bru_op_e;

  typedef enum logic {
    APU_BRU_OK    = 1'b0,
    APU_BRU_FAULT = 1'b1
  } apu_bru_status_e;

  typedef struct packed {
    apu_bru_status_e status;
  } apu_bru_cpl_t;

  typedef struct packed {
    apu_bru_op_e op;
    apu_gnh_req_t gnh;
  } apu_bru_req_t;

  // BeginRun (bru): Published handles, begun CMDBUF, loaded module, and
  // SPIR-V result.
  typedef struct packed {
    logic valid;
    logic alloc;
    logic begin_cmd;
    logic end_cmd;
    logic create;
    logic dispatch;
    logic submit;
    logic wait_idle;
    logic get_queue;
    logic create_device;
    logic create_instance;
    logic enum_phys;
    logic get_qfam;
    logic get_feat;
    logic get_props;
    logic get_mem;
    logic alloc_mem;
    logic create_buffer;
    logic bind_buffer;
    logic map_mem;
    logic unmap_mem;
    logic buf_req;
    logic flush_mem;
    logic inval_mem;
    logic mem_commit;
    logic create_dslayout;
    logic create_playout;
    logic create_cpipe;
    logic alloc_descset;
    logic update_desc;
    logic bind_pipe;
    logic bind_desc;
    logic create_pool;
    logic create_image;
    logic bind_image;
    logic img_req;
    logic create_view;
    logic create_sampler;
    logic create_rpass;
    logic create_gpipe;
    logic create_fbuf;
    logic begin_rp;
    logic draw_cmd;
    logic end_rp;
    logic bind_vtx;
    logic bind_idx;
    logic draw_idx;
    logic set_vp;
    logic set_sc;
    logic barrier;
    logic next_sp;
    logic dest_fbuf;
    logic dest_view;
    logic dest_samp;
    logic dest_rpass;
    logic dest_buf;
    logic dest_img;
    logic free_mem;
    logic dest_mod;
    logic dest_pipe;
    logic dest_play;
    logic dest_dsl;
    logic dest_pool;
    logic free_dset;
    logic reset_cbuf;
    logic free_cbuf;
    logic dest_dev;
    logic reset_cpool;
    logic dest_cpool;
    logic dest_inst;
    logic get_fmt;
    logic get_ifmt;
    logic get_dext;
    logic reset_dpool;
    logic get_iext;
    logic wait_dev;
    logic get_isl;
    logic get_rag;
    logic set_lw;
    logic set_bias;
    logic set_blend;
    logic set_bounds;
    logic set_scmp;
    logic set_swm;
    logic set_sref;
    logic copy_buf;
    logic copy_img;
    logic blit_img;
    logic copy_b2i;
    logic copy_i2b;
    logic update_buf;
    logic fill_buf;
    logic clear_col;
    logic draw_indr;
    logic draw_iindr;
    logic clear_ds;
    logic clear_att;
    logic disp_indr;
    logic resolve_img;
    logic get_fence;
    logic wait_fence;
    logic reset_fence;
    logic dest_fence;
    logic loaded;
    logic begun;
    logic reply;
    logic [4:0] slot;
    logic [15:0] gen;
    apu_gnh_kind_e kind;
    logic [31:0] object_id;
    logic [31:0] handle;
    logic [31:0] begin_flags;
    logic [31:0] code_words;
    logic [31:0] group_x;
    logic [31:0] group_y;
    logic [31:0] group_z;
    logic [31:0] result;
  } apu_bru_t;

  // QueueBegin (qbn): AvailNext CS into BeginRun ALLOC/BEGIN/CREATE/DISPATCH/END.
  // FeatureVirgl stays illegal.
  typedef enum logic [1:0] {
    APU_QBN_OK    = 2'd0,
    APU_QBN_EMPTY = 2'd1,
    APU_QBN_FAULT = 2'd2
  } apu_qbn_status_e;

  typedef struct packed {
    apu_qbn_status_e status;
  } apu_qbn_cpl_t;

  typedef struct packed {
    logic gnh_only;
    apu_gnh_req_t gnh;
    apu_avu_req_t avu;
  } apu_qbn_req_t;

  // QueueBegin (qbn): Walked CS command, begun CMDBUF, published result.
  typedef struct packed {
    logic valid;
    logic alloc;
    logic begin_cmd;
    logic end_cmd;
    logic dispatch;
    logic submit;
    logic wait_idle;
    logic irq;
    logic [31:0] cmd;
    logic [31:0] result;
    logic [31:0] handle;
    logic [15:0] used_idx;
    logic [63:0] resp_addr;
  } apu_qbn_t;

  // QueueTypeBegin (qtb): AvailNext type word selects GrantCapset or
  // QueueBegin. FeatureVirgl stays illegal.
  typedef enum logic [1:0] {
    APU_QTB_OK    = 2'd0,
    APU_QTB_EMPTY = 2'd1,
    APU_QTB_FAULT = 2'd2
  } apu_qtb_status_e;

  typedef struct packed {
    apu_qtb_status_e status;
  } apu_qtb_cpl_t;

  typedef struct packed {
    apu_qbn_req_t qbn;
  } apu_qtb_req_t;

  // QueueTypeBegin (qtb): Peeked type word, then capset blob or
  // ALLOC/BEGIN/CREATE/DISPATCH.
  typedef struct packed {
    logic valid;
    logic capset;
    logic info;
    logic alloc;
    logic begin_cmd;
    logic dispatch;
    logic irq;
    logic [31:0] type_word;
    logic [31:0] cmd;
    logic [31:0] result;
    logic [31:0] handle;
    logic [31:0] capset_id;
    logic [31:0] resp_word0;
    logic [15:0] used_idx;
    logic [63:0] resp_addr;
  } apu_qtb_t;

  // VenusCtrlBegin (vcb): Private Venus num_capsets=1 and QueueNotify
  // into QueueTypeBegin. FeatureVirgl stays illegal.
  localparam int unsigned APU_VCB_NUM_CAPSETS = 1;

  typedef enum logic [1:0] {
    APU_VCB_CFG    = 2'd0,
    APU_VCB_INFO   = 2'd1,
    APU_VCB_NOTIFY = 2'd2
  } apu_vcb_op_e;

  typedef enum logic [1:0] {
    APU_VCB_OK    = 2'd0,
    APU_VCB_EMPTY = 2'd1,
    APU_VCB_FAULT = 2'd2
  } apu_vcb_status_e;

  typedef struct packed {
    apu_vcb_status_e status;
  } apu_vcb_cpl_t;

  typedef struct packed {
    apu_vcb_op_e op;
    logic [15:0] cfg_addr;
    logic [31:0] capset_index;
    logic [31:0] queue_sel;
    apu_qtb_req_t qtb;
  } apu_vcb_req_t;

  // VenusCtrlBegin (vcb): Private num_capsets=1, INFO, or QueueNotify result.
  typedef struct packed {
    logic valid;
    logic capset;
    logic info;
    logic alloc;
    logic begin_cmd;
    logic dispatch;
    logic irq;
    logic [31:0] cfg_rdata;
    logic [31:0] num_capsets;
    logic [31:0] capset_id;
    logic [31:0] max_version;
    logic [31:0] max_size;
    logic [31:0] type_word;
    logic [31:0] cmd;
    logic [31:0] result;
    logic [31:0] handle;
    logic [31:0] resp_word0;
    logic [15:0] used_idx;
    logic [63:0] resp_addr;
  } apu_vcb_t;

  // QueuePumpBegin (qpb): QueueNotify drains QueueTypeBegin until EMPTY.
  // FeatureVirgl stays illegal.
  typedef enum logic [1:0] {
    APU_QPB_OK    = 2'd0,
    APU_QPB_EMPTY = 2'd1,
    APU_QPB_FAULT = 2'd2
  } apu_qpb_status_e;

  typedef struct packed {
    apu_qpb_status_e status;
  } apu_qpb_cpl_t;

  typedef struct packed {
    apu_vcb_req_t vcb;
  } apu_qpb_req_t;

  // QueuePumpBegin (qpb): Last command record and number of consumed
  // descriptors.
  typedef struct packed {
    logic valid;
    logic capset;
    logic info;
    logic alloc;
    logic begin_cmd;
    logic dispatch;
    logic irq;
    logic [7:0] count;
    logic [31:0] cfg_rdata;
    logic [31:0] num_capsets;
    logic [31:0] capset_id;
    logic [31:0] max_version;
    logic [31:0] max_size;
    logic [31:0] type_word;
    logic [31:0] cmd;
    logic [31:0] result;
    logic [31:0] handle;
    logic [31:0] resp_word0;
    logic [15:0] used_idx;
    logic [63:0] resp_addr;
  } apu_qpb_t;

  // NotifyTakeBegin (ntb): virtio notify_pending[0] consumes QueuePumpBegin.
  // FeatureVirgl stays illegal.
  typedef enum logic [1:0] {
    APU_NTB_OK    = 2'd0,
    APU_NTB_EMPTY = 2'd1,
    APU_NTB_FAULT = 2'd2
  } apu_ntb_status_e;

  typedef struct packed {
    apu_ntb_status_e status;
  } apu_ntb_cpl_t;

  typedef struct packed {
    logic arm;
    apu_qpb_req_t qpb;
  } apu_ntb_req_t;

  // NotifyTakeBegin (ntb): Bound queue, consumed count, and last pump record.
  typedef struct packed {
    logic valid;
    logic bound;
    logic capset;
    logic info;
    logic alloc;
    logic begin_cmd;
    logic dispatch;
    logic irq;
    logic [1:0] clear;
    logic [7:0] count;
    logic [31:0] cfg_rdata;
    logic [31:0] num_capsets;
    logic [31:0] capset_id;
    logic [31:0] max_version;
    logic [31:0] max_size;
    logic [31:0] type_word;
    logic [31:0] cmd;
    logic [31:0] result;
    logic [31:0] handle;
    logic [31:0] resp_word0;
    logic [15:0] used_idx;
    logic [63:0] resp_addr;
  } apu_ntb_t;

  // VqTakeBegin (vqb): virtio vq_state[0] arms NotifyTakeBegin on
  // notify_pending[0]. FeatureVirgl stays illegal.
  typedef enum logic [1:0] {
    APU_VQB_OK    = 2'd0,
    APU_VQB_EMPTY = 2'd1,
    APU_VQB_FAULT = 2'd2
  } apu_vqb_status_e;

  typedef struct packed {
    apu_vqb_status_e status;
  } apu_vqb_cpl_t;

  typedef struct packed {
    apu_ntb_req_t ntb;
  } apu_vqb_req_t;

  // VqTakeBegin (vqb): Armed from vq_state, last NotifyTakeBegin record.
  typedef struct packed {
    logic valid;
    logic bound;
    logic capset;
    logic info;
    logic alloc;
    logic begin_cmd;
    logic dispatch;
    logic irq;
    logic [1:0] clear;
    logic [7:0] count;
    logic [31:0] cfg_rdata;
    logic [31:0] num_capsets;
    logic [31:0] capset_id;
    logic [31:0] max_version;
    logic [31:0] max_size;
    logic [31:0] type_word;
    logic [31:0] cmd;
    logic [31:0] result;
    logic [31:0] handle;
    logic [31:0] resp_word0;
    logic [15:0] used_idx;
    logic [63:0] resp_addr;
  } apu_vqb_t;

  // VqAxiBegin (vab): VqTakeBegin guest beats on 64-bit AXI.
  // FeatureVirgl stays illegal.
  typedef enum logic [1:0] {
    APU_VAB_OK    = 2'd0,
    APU_VAB_EMPTY = 2'd1,
    APU_VAB_FAULT = 2'd2
  } apu_vab_status_e;

  typedef struct packed {
    apu_vab_status_e status;
  } apu_vab_cpl_t;

  typedef struct packed {
    apu_vqb_req_t vqb;
  } apu_vab_req_t;

  // VqAxiBegin (vab): Last VqTakeBegin record after AXI guest beats.
  typedef struct packed {
    logic valid;
    logic bound;
    logic capset;
    logic info;
    logic alloc;
    logic begin_cmd;
    logic dispatch;
    logic irq;
    logic [1:0] clear;
    logic [7:0] count;
    logic [31:0] cfg_rdata;
    logic [31:0] num_capsets;
    logic [31:0] capset_id;
    logic [31:0] max_version;
    logic [31:0] max_size;
    logic [31:0] type_word;
    logic [31:0] cmd;
    logic [31:0] result;
    logic [31:0] handle;
    logic [31:0] resp_word0;
    logic [15:0] used_idx;
    logic [63:0] resp_addr;
  } apu_vab_t;

  // Command type 91 is VK_COMMAND_TYPE_vkEndCommandBuffer_EXT in
  // Mesa 26.0 / Vulkan 1.0 catalog order (BeginCommandBuffer is 90,
  // AllocateCommandBuffers is 88, CreateShaderModule is 59, Dispatch
  // is 110). CS is type, flags, LP64 commandBuffer. GENERATE_REPLY
  // writes type + VK_SUCCESS. FeatureVirgl stays illegal.
  localparam int unsigned APU_VEN_WORDS = 16;
  localparam logic [31:0] APU_VEN_CMD_END = 32'd91;
  localparam logic [31:0] APU_VEN_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VEN_REPLY = 4;

  typedef enum logic {
    APU_VEN_OK    = 1'b0,
    APU_VEN_FAULT = 1'b1
  } apu_ven_status_e;

  typedef struct packed {
    apu_ven_status_e status;
  } apu_ven_cpl_t;

  // VenusEnd (ven): Decoded vkEndCommandBuffer command buffer.
  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] command_buffer;
  } apu_ven_t;

  // EndAlloc (eal): vkAllocateCommandBuffers ALLOC CMDBUF, then
  // vkBeginCommandBuffer LOOKUP, then vkEndCommandBuffer LOOKUP on
  // one GenHandle table. FeatureVirgl stays illegal.
  typedef enum logic [1:0] {
    APU_EAL_GNH   = 2'd0,
    APU_EAL_ALLOC = 2'd1,
    APU_EAL_BEGIN = 2'd2,
    APU_EAL_END   = 2'd3
  } apu_eal_op_e;

  typedef enum logic {
    APU_EAL_OK    = 1'b0,
    APU_EAL_FAULT = 1'b1
  } apu_eal_status_e;

  typedef struct packed {
    apu_eal_status_e status;
  } apu_eal_cpl_t;

  typedef struct packed {
    apu_eal_op_e op;
    apu_gnh_req_t gnh;
  } apu_eal_req_t;

  // EndAlloc (eal): Published CMDBUF after allocate, begin, or end lookup.
  typedef struct packed {
    logic valid;
    logic alloc;
    logic begin_cmd;
    logic end_cmd;
    logic reply;
    logic [4:0] slot;
    logic [15:0] gen;
    apu_gnh_kind_e kind;
    logic [31:0] object_id;
    logic [31:0] handle;
    logic [31:0] begin_flags;
  } apu_eal_t;

  // Command type 18 is VK_COMMAND_TYPE_vkQueueSubmit_EXT in Mesa 26.0 /
  // Vulkan 1.0 catalog order (GetDeviceQueue is 17, QueueWaitIdle is
  // 19, EndCommandBuffer is 91, Dispatch is 110). One SUBMIT_INFO
  // (sType 4), one command buffer, no wait/signal semaphores, null
  // fence. GENERATE_REPLY writes type + VK_SUCCESS. FeatureVirgl
  // stays illegal.
  localparam int unsigned APU_VQS_WORDS = 32;
  localparam logic [31:0] APU_VQS_CMD_SUBMIT = 32'd18;
  localparam logic [31:0] APU_VQS_STYPE_SUBMIT = 32'd4;
  localparam logic [31:0] APU_VQS_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VQS_REPLY = 25;

  typedef enum logic {
    APU_VQS_OK    = 1'b0,
    APU_VQS_FAULT = 1'b1
  } apu_vqs_status_e;

  typedef struct packed {
    apu_vqs_status_e status;
  } apu_vqs_cpl_t;

  // VenusSubmit (vqs): Decoded vkQueueSubmit command stream.
  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] queue_handle;
    logic [31:0] submit_count;
    logic [63:0] command_buffer;
  } apu_vqs_t;

  // Command type 19 is VK_COMMAND_TYPE_vkQueueWaitIdle_EXT in Mesa
  // 26.0 / Vulkan 1.0 catalog order (QueueSubmit is 18). CS is type,
  // flags, LP64 queue. GENERATE_REPLY writes type + VK_SUCCESS.
  // FeatureVirgl stays illegal.
  localparam int unsigned APU_VWI_WORDS = 16;
  localparam logic [31:0] APU_VWI_CMD_WAIT = 32'd19;
  localparam logic [31:0] APU_VWI_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VWI_REPLY = 4;

  typedef enum logic {
    APU_VWI_OK    = 1'b0,
    APU_VWI_FAULT = 1'b1
  } apu_vwi_status_e;

  typedef struct packed {
    apu_vwi_status_e status;
  } apu_vwi_cpl_t;

  // VenusWaitIdle (vwi): Decoded vkQueueWaitIdle command stream.
  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] queue_handle;
  } apu_vwi_t;

  // Command type 17 is VK_COMMAND_TYPE_vkGetDeviceQueue_EXT in Mesa
  // 26.0 / Vulkan 1.0 catalog order (CreateDevice is 11, QueueSubmit
  // is 18). CS is type, flags, LP64 device, family 0, index 0.
  // GENERATE_REPLY writes type + published QUEUE handle. FeatureVirgl
  // stays illegal.
  localparam int unsigned APU_VGQ_WORDS = 16;
  localparam logic [31:0] APU_VGQ_CMD_QUEUE = 32'd17;
  localparam logic [31:0] APU_VGQ_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VGQ_REPLY = 6;

  typedef enum logic {
    APU_VGQ_OK    = 1'b0,
    APU_VGQ_FAULT = 1'b1
  } apu_vgq_status_e;

  typedef struct packed {
    apu_vgq_status_e status;
  } apu_vgq_cpl_t;

  // VenusGetQueue (vgq): Decoded vkGetDeviceQueue command stream.
  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] device;
    logic [31:0] family;
    logic [31:0] index;
  } apu_vgq_t;

  // Command type 11 is VK_COMMAND_TYPE_vkCreateDevice_EXT in Mesa
  // 26.0 / Vulkan 1.0 catalog order (GetDeviceQueue is 17). CS is
  // type, flags, LP64 physicalDevice, pCreateInfo pointer, sType 3
  // DEVICE_CREATE_INFO, one queue family 0 count 1 priority 1.0,
  // no layers/extensions/features, null allocator. GENERATE_REPLY
  // writes type + VK_SUCCESS. FeatureVirgl stays illegal.
  localparam int unsigned APU_VCD_WORDS = 40;
  localparam logic [31:0] APU_VCD_CMD_DEVICE = 32'd11;
  localparam logic [31:0] APU_VCD_STYPE_DEVICE = 32'd3;
  localparam logic [31:0] APU_VCD_STYPE_QUEUE = 32'd2;
  localparam logic [31:0] APU_VCD_PRIORITY_ONE = 32'h3f800000;
  localparam logic [31:0] APU_VCD_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VCD_REPLY = 32;

  typedef enum logic {
    APU_VCD_OK    = 1'b0,
    APU_VCD_FAULT = 1'b1
  } apu_vcd_status_e;

  typedef struct packed {
    apu_vcd_status_e status;
  } apu_vcd_cpl_t;

  // VenusCreateDevice (vcd): Decoded vkCreateDevice command stream.
  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] physical_device;
  } apu_vcd_t;

  // Command type 0 is VK_COMMAND_TYPE_vkCreateInstance_EXT in Mesa
  // 26.0 / Vulkan 1.0 catalog order (CreateDevice is 11). CS is type,
  // flags, pCreateInfo pointer, sType 1 INSTANCE_CREATE_INFO, no
  // application info, no layers/extensions, null allocator.
  // GENERATE_REPLY writes type + VK_SUCCESS. FeatureVirgl stays
  // illegal.
  localparam int unsigned APU_VCI_WORDS = 24;
  localparam logic [31:0] APU_VCI_CMD_INSTANCE = 32'd0;
  localparam logic [31:0] APU_VCI_STYPE_INSTANCE = 32'd1;
  localparam logic [31:0] APU_VCI_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VCI_REPLY = 18;
  localparam int unsigned APU_VCI_BRU_REPLY = 40;

  typedef enum logic {
    APU_VCI_OK    = 1'b0,
    APU_VCI_FAULT = 1'b1
  } apu_vci_status_e;

  typedef struct packed {
    apu_vci_status_e status;
  } apu_vci_cpl_t;

  // VenusCreateInstance (vci): Decoded vkCreateInstance command stream.
  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] info;
  } apu_vci_t;

  // Command type 2 is VK_COMMAND_TYPE_vkEnumeratePhysicalDevices_EXT
  // in Mesa 26.0 / Vulkan 1.0 catalog order (CreateInstance is 0,
  // CreateDevice is 11). CS is type, flags, LP64 instance, pCount
  // pointer, count 1, pDevices pointer, array_size 1. GENERATE_REPLY
  // writes type + VK_SUCCESS. FeatureVirgl stays illegal.
  localparam int unsigned APU_VEP_WORDS = 16;
  localparam logic [31:0] APU_VEP_CMD_ENUM = 32'd2;
  localparam logic [31:0] APU_VEP_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VEP_REPLY = 12;
  localparam int unsigned APU_VEP_BRU_REPLY = 48;

  typedef enum logic {
    APU_VEP_OK    = 1'b0,
    APU_VEP_FAULT = 1'b1
  } apu_vep_status_e;

  typedef struct packed {
    apu_vep_status_e status;
  } apu_vep_cpl_t;

  // VenusEnumeratePhys (vep): Decoded vkEnumeratePhysicalDevices CS.
  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] instance_handle;
  } apu_vep_t;

  // Command type 7 is VK_COMMAND_TYPE_vkGetPhysicalDeviceQueueFamilyProperties_EXT
  // in Mesa 26.0 / Vulkan 1.0 catalog order (EnumeratePhysicalDevices is 2,
  // CreateDevice is 11). CS is type, flags, LP64 physicalDevice, pCount
  // pointer, count 1, pProperties pointer, array_size 1. Void command.
  // GENERATE_REPLY writes type. FeatureVirgl stays illegal.
  localparam int unsigned APU_VQF_WORDS = 16;
  localparam logic [31:0] APU_VQF_CMD_QFAM = 32'd7;
  localparam logic [31:0] APU_VQF_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VQF_REPLY = 12;
  localparam int unsigned APU_VQF_BRU_REPLY = 56;
  localparam logic [31:0] APU_VQF_FAMILY_COUNT = 32'd1;
  localparam logic [31:0] APU_VQF_QUEUE_FLAGS = 32'd3;
  localparam logic [31:0] APU_VQF_QUEUE_COUNT = 32'd1;

  typedef enum logic {
    APU_VQF_OK    = 1'b0,
    APU_VQF_FAULT = 1'b1
  } apu_vqf_status_e;

  typedef struct packed {
    apu_vqf_status_e status;
  } apu_vqf_cpl_t;

  // VenusQueueFamily (vqf): Decoded vkGetPhysicalDeviceQueueFamilyProperties CS.
  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] phys_handle;
  } apu_vqf_t;

  // Command type 3 is VK_COMMAND_TYPE_vkGetPhysicalDeviceFeatures_EXT
  // in Mesa 26.0 / Vulkan 1.0 catalog order (QueueFamily is 7,
  // CreateDevice is 11). CS is type, flags, LP64 physicalDevice,
  // pFeatures pointer. Void command. GENERATE_REPLY writes type.
  // Compact reply publishes fragmentStoresAndAtomics. FeatureVirgl
  // stays illegal.
  localparam int unsigned APU_VPF_WORDS = 16;
  localparam logic [31:0] APU_VPF_CMD_FEAT = 32'd3;
  localparam logic [31:0] APU_VPF_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VPF_REPLY = 12;
  localparam int unsigned APU_VPF_BRU_REPLY = 64;
  localparam logic [31:0] APU_VPF_FRAGMENT_STORES = 32'd1;

  typedef enum logic {
    APU_VPF_OK    = 1'b0,
    APU_VPF_FAULT = 1'b1
  } apu_vpf_status_e;

  typedef struct packed {
    apu_vpf_status_e status;
  } apu_vpf_cpl_t;

  // VenusPhysFeatures (vpf): Decoded vkGetPhysicalDeviceFeatures CS.
  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] phys_handle;
  } apu_vpf_t;

  // Command type 6 is VK_COMMAND_TYPE_vkGetPhysicalDeviceProperties_EXT
  // in Mesa 26.0 / Vulkan 1.0 catalog order (Features is 3, QueueFamily
  // is 7). CS is type, flags, LP64 physicalDevice, pProperties pointer.
  // Void command. GENERATE_REPLY writes type. Compact reply publishes
  // Vulkan 1.1 apiVersion and maxBoundDescriptorSets=4. FeatureVirgl
  // stays illegal.
  localparam int unsigned APU_VPP_WORDS = 16;
  localparam logic [31:0] APU_VPP_CMD_PROPS = 32'd6;
  localparam logic [31:0] APU_VPP_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VPP_REPLY = 12;
  localparam int unsigned APU_VPP_BRU_REPLY = 72;
  localparam logic [31:0] APU_VPP_API_VERSION = 32'h00401000;
  localparam logic [31:0] APU_VPP_MAX_BOUND_DESCRIPTOR_SETS = 32'd4;

  typedef enum logic {
    APU_VPP_OK    = 1'b0,
    APU_VPP_FAULT = 1'b1
  } apu_vpp_status_e;

  typedef struct packed {
    apu_vpp_status_e status;
  } apu_vpp_cpl_t;

  // VenusPhysProps (vpp): Decoded vkGetPhysicalDeviceProperties CS.
  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] phys_handle;
  } apu_vpp_t;

  // Command type 8 is VK_COMMAND_TYPE_vkGetPhysicalDeviceMemoryProperties_EXT
  // in Mesa 26.0 / Vulkan 1.0 catalog order (Properties is 6, QueueFamily
  // is 7, CreateDevice is 11). CS is type, flags, LP64 physicalDevice,
  // pMemoryProperties pointer. Void command. GENERATE_REPLY writes type.
  // Compact reply publishes two memory types (DEVICE_LOCAL and
  // HOST_VISIBLE|HOST_COHERENT) and one heap. FeatureVirgl stays illegal.
  localparam int unsigned APU_VMP_WORDS = 16;
  localparam logic [31:0] APU_VMP_CMD_MEM = 32'd8;
  localparam logic [31:0] APU_VMP_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VMP_REPLY = 12;
  localparam int unsigned APU_VMP_BRU_REPLY = 80;
  localparam logic [31:0] APU_VMP_TYPE_COUNT = 32'd2;
  localparam logic [31:0] APU_VMP_DEVICE_LOCAL = 32'd1;
  localparam logic [31:0] APU_VMP_HOST_VISIBLE = 32'd6;
  localparam logic [31:0] APU_VMP_HEAP_COUNT = 32'd1;

  typedef enum logic {
    APU_VMP_OK    = 1'b0,
    APU_VMP_FAULT = 1'b1
  } apu_vmp_status_e;

  typedef struct packed {
    apu_vmp_status_e status;
  } apu_vmp_cpl_t;

  // VenusPhysMemory (vmp): Decoded vkGetPhysicalDeviceMemoryProperties CS.
  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] phys_handle;
  } apu_vmp_t;

  // Command type 21 is VK_COMMAND_TYPE_vkAllocateMemory_EXT in Mesa
  // 26.0 / Vulkan 1.0 catalog order (CreateDevice is 11, GetDeviceQueue
  // is 17). CS is type, flags, LP64 device, pAllocateInfo, sType 5
  // MEMORY_ALLOCATE_INFO, nonzero size, memoryTypeIndex 0 or 1, null
  // allocator, pMemory pointer. GENERATE_REPLY writes type +
  // VK_SUCCESS. FeatureVirgl stays illegal.
  localparam int unsigned APU_VAM_WORDS = 24;
  localparam logic [31:0] APU_VAM_CMD_MEMORY = 32'd21;
  localparam logic [31:0] APU_VAM_STYPE_ALLOC = 32'd5;
  localparam logic [31:0] APU_VAM_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VAM_REPLY = 18;
  localparam int unsigned APU_VAM_BRU_REPLY = 88;

  typedef enum logic {
    APU_VAM_OK    = 1'b0,
    APU_VAM_FAULT = 1'b1
  } apu_vam_status_e;

  typedef struct packed {
    apu_vam_status_e status;
  } apu_vam_cpl_t;

  // VenusAllocMemory (vam): Decoded vkAllocateMemory CS.
  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] device;
    logic [63:0] guest;
  } apu_vam_t;

  // Command type 50 is VK_COMMAND_TYPE_vkCreateBuffer_EXT in Mesa
  // 26.0 / Vulkan 1.0 catalog order (CreateShaderModule is 59,
  // AllocateMemory is 21). CS is type, flags, LP64 device,
  // pCreateInfo, sType 12 BUFFER_CREATE_INFO, size nonzero, usage
  // STORAGE_BUFFER, exclusive sharing, null allocator, pBuffer
  // pointer. GENERATE_REPLY writes type + VK_SUCCESS. FeatureVirgl
  // stays illegal.
  localparam int unsigned APU_VXB_WORDS = 32;
  localparam logic [31:0] APU_VXB_CMD_BUFFER = 32'd50;
  localparam logic [31:0] APU_VXB_STYPE_BUFFER = 32'd12;
  localparam logic [31:0] APU_VXB_USAGE_STORAGE = 32'h00000020;
  localparam logic [31:0] APU_VXB_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VXB_REPLY = 24;
  localparam int unsigned APU_VXB_BRU_REPLY = 96;

  typedef enum logic {
    APU_VXB_OK    = 1'b0,
    APU_VXB_FAULT = 1'b1
  } apu_vxb_status_e;

  typedef struct packed {
    apu_vxb_status_e status;
  } apu_vxb_cpl_t;

  // VenusCreateBuffer (vxb): Decoded vkCreateBuffer CS.
  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] device;
    logic [63:0] guest;
  } apu_vxb_t;

  // Command type 28 is VK_COMMAND_TYPE_vkBindBufferMemory_EXT in Mesa
  // 26.0 / Vulkan 1.0 catalog order (MapMemory is 23, CreateBuffer is
  // 50). CS is type, flags, LP64 device, LP64 buffer, LP64 memory,
  // uint64 offset 0. GENERATE_REPLY writes type + VK_SUCCESS.
  // FeatureVirgl stays illegal.
  localparam int unsigned APU_VBB_WORDS = 16;
  localparam logic [31:0] APU_VBB_CMD_BIND = 32'd28;
  localparam logic [31:0] APU_VBB_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VBB_REPLY = 10;
  localparam int unsigned APU_VBB_BRU_REPLY = 104;

  typedef enum logic {
    APU_VBB_OK    = 1'b0,
    APU_VBB_FAULT = 1'b1
  } apu_vbb_status_e;

  typedef struct packed {
    apu_vbb_status_e status;
  } apu_vbb_cpl_t;

  // VenusBindBuffer (vbb): Decoded vkBindBufferMemory CS.
  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] device;
    logic [63:0] buffer;
    logic [63:0] memory;
  } apu_vbb_t;

  // Command type 23 is VK_COMMAND_TYPE_vkMapMemory_EXT in Mesa
  // 26.0 / Vulkan 1.0 catalog order (BindBufferMemory is 28,
  // AllocateMemory is 21). CS is type, flags, LP64 device, LP64
  // memory, offset 0, nonzero size, map flags 0, ppData pointer.
  // GENERATE_REPLY writes type + VK_SUCCESS. FeatureVirgl stays
  // illegal.
  localparam int unsigned APU_VMM_WORDS = 16;
  localparam logic [31:0] APU_VMM_CMD_MAP = 32'd23;
  localparam logic [31:0] APU_VMM_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VMM_REPLY = 13;
  localparam int unsigned APU_VMM_BRU_REPLY = 112;
  localparam logic [63:0] APU_VMM_WHOLE_SIZE = 64'hFFFF_FFFF_FFFF_FFFF;

  typedef enum logic {
    APU_VMM_OK    = 1'b0,
    APU_VMM_FAULT = 1'b1
  } apu_vmm_status_e;

  typedef struct packed {
    apu_vmm_status_e status;
  } apu_vmm_cpl_t;

  // VenusMapMemory (vmm): Decoded vkMapMemory CS.
  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] device;
    logic [63:0] memory;
    logic [63:0] guest;
  } apu_vmm_t;

  // Command type 24 is VK_COMMAND_TYPE_vkUnmapMemory_EXT in Mesa
  // 26.0 / Vulkan 1.0 catalog order (MapMemory is 23). CS is type,
  // flags, LP64 device, LP64 memory. Void command: GENERATE_REPLY
  // writes type. FeatureVirgl stays illegal.
  localparam int unsigned APU_VUM_WORDS = 16;
  localparam logic [31:0] APU_VUM_CMD_UNMAP = 32'd24;
  localparam logic [31:0] APU_VUM_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VUM_REPLY = 6;
  localparam int unsigned APU_VUM_BRU_REPLY = 120;

  typedef enum logic {
    APU_VUM_OK    = 1'b0,
    APU_VUM_FAULT = 1'b1
  } apu_vum_status_e;

  typedef struct packed {
    apu_vum_status_e status;
  } apu_vum_cpl_t;

  // VenusUnmapMemory (vum): Decoded vkUnmapMemory CS.
  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] device;
    logic [63:0] memory;
  } apu_vum_t;

  // Command type 30 is VK_COMMAND_TYPE_vkGetBufferMemoryRequirements_EXT
  // in Mesa 26.0 / Vulkan 1.0 catalog order. CS is type, flags, LP64
  // device, LP64 buffer, pMemoryRequirements pointer. Void command:
  // GENERATE_REPLY writes type. Compact bru reply publishes size 4096,
  // alignment 256, memoryTypeBits 3. FeatureVirgl stays illegal.
  localparam int unsigned APU_VBM_WORDS = 16;
  localparam logic [31:0] APU_VBM_CMD_BUFREQ = 32'd30;
  localparam logic [31:0] APU_VBM_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VBM_REPLY = 8;
  localparam int unsigned APU_VBM_BRU_REPLY = 128;
  localparam logic [31:0] APU_VBM_SIZE = 32'd4096;
  localparam logic [31:0] APU_VBM_ALIGN = 32'd256;
  localparam logic [31:0] APU_VBM_TYPE_BITS = 32'd3;

  typedef enum logic {
    APU_VBM_OK    = 1'b0,
    APU_VBM_FAULT = 1'b1
  } apu_vbm_status_e;

  typedef struct packed {
    apu_vbm_status_e status;
  } apu_vbm_cpl_t;

  // VenusBufReq (vbm): Decoded vkGetBufferMemoryRequirements CS.
  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] device;
    logic [63:0] buffer;
  } apu_vbm_t;

  // Command type 25 is VK_COMMAND_TYPE_vkFlushMappedMemoryRanges_EXT.
  // CS is type, flags, LP64 device, count 1, pRanges, sType 6
  // MAPPED_MEMORY_RANGE, memory, offset 0, nonzero size.
  // GENERATE_REPLY writes type + VK_SUCCESS. FeatureVirgl stays illegal.
  localparam int unsigned APU_VFM_WORDS = 24;
  localparam logic [31:0] APU_VFM_CMD_FLUSH = 32'd25;
  localparam logic [31:0] APU_VFM_STYPE_RANGE = 32'd6;
  localparam logic [31:0] APU_VFM_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VFM_REPLY = 16;
  localparam int unsigned APU_VFM_BRU_REPLY = 136;

  typedef enum logic {
    APU_VFM_OK    = 1'b0,
    APU_VFM_FAULT = 1'b1
  } apu_vfm_status_e;

  typedef struct packed {
    apu_vfm_status_e status;
  } apu_vfm_cpl_t;

  // VenusFlushMap (vfm): Decoded vkFlushMappedMemoryRanges CS.
  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] device;
    logic [63:0] memory;
  } apu_vfm_t;

  // Command type 26 is VK_COMMAND_TYPE_vkInvalidateMappedMemoryRanges_EXT.
  // CS matches FlushMappedMemoryRanges: type, flags, LP64 device, count 1,
  // pRanges, sType 6 MAPPED_MEMORY_RANGE, memory, offset 0, nonzero size.
  // GENERATE_REPLY writes type + VK_SUCCESS. FeatureVirgl stays illegal.
  localparam int unsigned APU_VIM_WORDS = 24;
  localparam logic [31:0] APU_VIM_CMD_INVAL = 32'd26;
  localparam logic [31:0] APU_VIM_STYPE_RANGE = 32'd6;
  localparam logic [31:0] APU_VIM_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VIM_REPLY = 16;
  localparam int unsigned APU_VIM_BRU_REPLY = 144;

  typedef enum logic {
    APU_VIM_OK    = 1'b0,
    APU_VIM_FAULT = 1'b1
  } apu_vim_status_e;

  typedef struct packed {
    apu_vim_status_e status;
  } apu_vim_cpl_t;

  // VenusInvalidateMap (vim): Decoded vkInvalidateMappedMemoryRanges CS.
  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] device;
    logic [63:0] memory;
  } apu_vim_t;

  // Command type 27 is VK_COMMAND_TYPE_vkGetDeviceMemoryCommitment_EXT.
  // CS is type, flags, LP64 device, LP64 memory, pCommitted pointer.
  // Void command: GENERATE_REPLY writes type. Compact bru reply publishes
  // committed size 4096. FeatureVirgl stays illegal.
  localparam int unsigned APU_VMC_WORDS = 16;
  localparam logic [31:0] APU_VMC_CMD_MEMC = 32'd27;
  localparam logic [31:0] APU_VMC_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VMC_REPLY = 8;
  localparam int unsigned APU_VMC_BRU_REPLY = 152;
  localparam logic [31:0] APU_VMC_COMMITTED = 32'd4096;

  typedef enum logic {
    APU_VMC_OK    = 1'b0,
    APU_VMC_FAULT = 1'b1
  } apu_vmc_status_e;

  typedef struct packed {
    apu_vmc_status_e status;
  } apu_vmc_cpl_t;

  // VenusMemCommit (vmc): Decoded vkGetDeviceMemoryCommitment CS.
  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] device;
    logic [63:0] memory;
  } apu_vmc_t;

  // Command type 72 is VK_COMMAND_TYPE_vkCreateDescriptorSetLayout_EXT.
  // sType 32 DESCRIPTOR_SET_LAYOUT_CREATE_INFO, one STORAGE_BUFFER
  // compute binding. GENERATE_REPLY writes type + VK_SUCCESS.
  localparam int unsigned APU_VDL_WORDS = 24;
  localparam logic [31:0] APU_VDL_CMD_DSLAYOUT = 32'd72;
  localparam logic [31:0] APU_VDL_STYPE = 32'd32;
  localparam logic [31:0] APU_VDL_STORAGE = 32'd7;
  localparam logic [31:0] APU_VDL_COMPUTE = 32'h00000020;
  localparam logic [31:0] APU_VDL_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VDL_REPLY = 20;
  localparam int unsigned APU_VDL_BRU_REPLY = 160;

  typedef enum logic {
    APU_VDL_OK    = 1'b0,
    APU_VDL_FAULT = 1'b1
  } apu_vdl_status_e;

  typedef struct packed {
    apu_vdl_status_e status;
  } apu_vdl_cpl_t;

  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] device;
    logic [63:0] guest;
  } apu_vdl_t;

  // Command type 68 is VK_COMMAND_TYPE_vkCreatePipelineLayout_EXT.
  // sType 30 PIPELINE_LAYOUT_CREATE_INFO, one set layout, no push
  // constants. GENERATE_REPLY writes type + VK_SUCCESS.
  localparam int unsigned APU_VPL_WORDS = 24;
  localparam logic [31:0] APU_VPL_CMD_PLAYOUT = 32'd68;
  localparam logic [31:0] APU_VPL_STYPE = 32'd30;
  localparam logic [31:0] APU_VPL_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VPL_REPLY = 20;
  localparam int unsigned APU_VPL_BRU_REPLY = 168;

  typedef enum logic {
    APU_VPL_OK    = 1'b0,
    APU_VPL_FAULT = 1'b1
  } apu_vpl_status_e;

  typedef struct packed {
    apu_vpl_status_e status;
  } apu_vpl_cpl_t;

  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] device;
    logic [63:0] layout;
    logic [63:0] guest;
  } apu_vpl_t;

  // Command type 66 is VK_COMMAND_TYPE_vkCreateComputePipelines_EXT.
  // sType 29 COMPUTE_PIPELINE_CREATE_INFO, compute stage, module,
  // layout. GENERATE_REPLY writes type + VK_SUCCESS.
  localparam int unsigned APU_VCP_WORDS = 32;
  localparam logic [31:0] APU_VCP_CMD_CPIPE = 32'd66;
  localparam logic [31:0] APU_VCP_STYPE = 32'd29;
  localparam logic [31:0] APU_VCP_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VCP_REPLY = 24;
  localparam int unsigned APU_VCP_BRU_REPLY = 176;

  typedef enum logic {
    APU_VCP_OK    = 1'b0,
    APU_VCP_FAULT = 1'b1
  } apu_vcp_status_e;

  typedef struct packed {
    apu_vcp_status_e status;
  } apu_vcp_cpl_t;

  typedef struct packed {
    logic valid;
    logic reply;
    logic [31:0] cmd_type;
    logic [31:0] cmd_flags;
    logic [63:0] device;
    logic [63:0] shader;
    logic [63:0] layout;
    logic [63:0] guest;
  } apu_vcp_t;

  // Command type 77 is VK_COMMAND_TYPE_vkAllocateDescriptorSets_EXT.
  // sType 34 DESCRIPTOR_SET_ALLOCATE_INFO, one layout, nonzero pool.
  localparam int unsigned APU_VDA_WORDS = 24;
  localparam logic [31:0] APU_VDA_CMD_DESCSET = 32'd77;
  localparam logic [31:0] APU_VDA_STYPE = 32'd34;
  localparam logic [31:0] APU_VDA_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VDA_REPLY = 18;
  localparam int unsigned APU_VDA_BRU_REPLY = 184;

  typedef enum logic { APU_VDA_OK = 1'b0, APU_VDA_FAULT = 1'b1 } apu_vda_status_e;
  typedef struct packed { apu_vda_status_e status; } apu_vda_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] layout; logic [63:0] pool; logic [63:0] guest;
  } apu_vda_t;

  // Command type 79 is VK_COMMAND_TYPE_vkUpdateDescriptorSets_EXT.
  // sType 35 WRITE_DESCRIPTOR_SET, STORAGE_BUFFER, offset 0.
  localparam int unsigned APU_VUD_WORDS = 32;
  localparam logic [31:0] APU_VUD_CMD_UPDATE = 32'd79;
  localparam logic [31:0] APU_VUD_STYPE = 32'd35;
  localparam logic [31:0] APU_VUD_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VUD_REPLY = 22;
  localparam int unsigned APU_VUD_BRU_REPLY = 192;

  typedef enum logic { APU_VUD_OK = 1'b0, APU_VUD_FAULT = 1'b1 } apu_vud_status_e;
  typedef struct packed { apu_vud_status_e status; } apu_vud_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] dset; logic [63:0] buffer;
  } apu_vud_t;

  // Command type 93 is VK_COMMAND_TYPE_vkCmdBindPipeline_EXT.
  // Compute bind point 1.
  localparam int unsigned APU_VBP_WORDS = 16;
  localparam logic [31:0] APU_VBP_CMD_BINDPIPE = 32'd93;
  localparam logic [31:0] APU_VBP_COMPUTE = 32'd1;
  localparam logic [31:0] APU_VBP_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VBP_REPLY = 8;
  localparam int unsigned APU_VBP_BRU_REPLY = 200;

  typedef enum logic { APU_VBP_OK = 1'b0, APU_VBP_FAULT = 1'b1 } apu_vbp_status_e;
  typedef struct packed { apu_vbp_status_e status; } apu_vbp_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [63:0] pipeline;
  } apu_vbp_t;

  // Command type 103 is VK_COMMAND_TYPE_vkCmdBindDescriptorSets_EXT.
  localparam int unsigned APU_VBD_WORDS = 24;
  localparam logic [31:0] APU_VBD_CMD_BINDDESC = 32'd103;
  localparam logic [31:0] APU_VBD_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VBD_REPLY = 16;
  localparam int unsigned APU_VBD_BRU_REPLY = 208;

  typedef enum logic { APU_VBD_OK = 1'b0, APU_VBD_FAULT = 1'b1 } apu_vbd_status_e;
  typedef struct packed { apu_vbd_status_e status; } apu_vbd_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [63:0] layout; logic [63:0] dset;
  } apu_vbd_t;

  // Command type 74 is VK_COMMAND_TYPE_vkCreateDescriptorPool_EXT.
  // sType 33 DESCRIPTOR_POOL_CREATE_INFO, one STORAGE_BUFFER size.
  localparam int unsigned APU_VPO_WORDS = 24;
  localparam logic [31:0] APU_VPO_CMD_POOL = 32'd74;
  localparam logic [31:0] APU_VPO_STYPE = 32'd33;
  localparam logic [31:0] APU_VPO_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VPO_REPLY = 20;
  localparam int unsigned APU_VPO_BRU_REPLY = 216;
  typedef enum logic { APU_VPO_OK = 1'b0, APU_VPO_FAULT = 1'b1 } apu_vpo_status_e;
  typedef struct packed { apu_vpo_status_e status; } apu_vpo_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] guest;
  } apu_vpo_t;

  // Command type 54 is VK_COMMAND_TYPE_vkCreateImage_EXT.
  // sType 14 IMAGE_CREATE_INFO, 64x64 2D STORAGE linear R8G8B8A8.
  localparam int unsigned APU_VXI_WORDS = 32;
  localparam logic [31:0] APU_VXI_CMD_IMAGE = 32'd54;
  localparam logic [31:0] APU_VXI_STYPE = 32'd14;
  localparam logic [31:0] APU_VXI_TYPE_2D = 32'd1;
  localparam logic [31:0] APU_VXI_FORMAT = 32'd37;
  localparam logic [31:0] APU_VXI_WIDTH = 32'd64;
  localparam logic [31:0] APU_VXI_HEIGHT = 32'd64;
  localparam logic [31:0] APU_VXI_TILING_LINEAR = 32'd1;
  localparam logic [31:0] APU_VXI_USAGE_STORAGE = 32'd8;
  localparam logic [31:0] APU_VXI_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VXI_REPLY = 26;
  localparam int unsigned APU_VXI_BRU_REPLY = 224;
  typedef enum logic { APU_VXI_OK = 1'b0, APU_VXI_FAULT = 1'b1 } apu_vxi_status_e;
  typedef struct packed { apu_vxi_status_e status; } apu_vxi_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] guest;
  } apu_vxi_t;

  // Command type 29 is VK_COMMAND_TYPE_vkBindImageMemory_EXT. Offset 0.
  localparam int unsigned APU_VBI_WORDS = 16;
  localparam logic [31:0] APU_VBI_CMD_BINDIMG = 32'd29;
  localparam logic [31:0] APU_VBI_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VBI_REPLY = 10;
  localparam int unsigned APU_VBI_BRU_REPLY = 232;
  typedef enum logic { APU_VBI_OK = 1'b0, APU_VBI_FAULT = 1'b1 } apu_vbi_status_e;
  typedef struct packed { apu_vbi_status_e status; } apu_vbi_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] image; logic [63:0] memory;
  } apu_vbi_t;

  // Command type 31 is VK_COMMAND_TYPE_vkGetImageMemoryRequirements_EXT.
  localparam int unsigned APU_VMI_WORDS = 16;
  localparam logic [31:0] APU_VMI_CMD_IMGREQ = 32'd31;
  localparam logic [31:0] APU_VMI_SIZE = 32'd16384;
  localparam logic [31:0] APU_VMI_ALIGN = 32'd256;
  localparam logic [31:0] APU_VMI_TYPE_BITS = 32'd3;
  localparam logic [31:0] APU_VMI_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VMI_REPLY = 8;
  localparam int unsigned APU_VMI_BRU_REPLY = 240;
  typedef enum logic { APU_VMI_OK = 1'b0, APU_VMI_FAULT = 1'b1 } apu_vmi_status_e;
  typedef struct packed { apu_vmi_status_e status; } apu_vmi_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] image;
  } apu_vmi_t;

  localparam int unsigned APU_BRU_TAIL_REPLY = 248;

  // Command type 57 is VK_COMMAND_TYPE_vkCreateImageView_EXT. sType 15.
  localparam int unsigned APU_VXV_WORDS = 32;
  localparam logic [31:0] APU_VXV_CMD_VIEW = 32'd57;
  localparam logic [31:0] APU_VXV_STYPE = 32'd15;
  localparam logic [31:0] APU_VXV_TYPE_2D = 32'd1;
  localparam logic [31:0] APU_VXV_ASPECT_COLOR = 32'd1;
  localparam logic [31:0] APU_VXV_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VXV_REPLY = 28;
  localparam int unsigned APU_VXV_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_VXV_OK = 1'b0, APU_VXV_FAULT = 1'b1 } apu_vxv_status_e;
  typedef struct packed { apu_vxv_status_e status; } apu_vxv_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] image; logic [63:0] guest;
  } apu_vxv_t;

  // Command type 70 is VK_COMMAND_TYPE_vkCreateSampler_EXT. sType 31.
  localparam int unsigned APU_VSM_WORDS = 24;
  localparam logic [31:0] APU_VSM_CMD_SAMPLER = 32'd70;
  localparam logic [31:0] APU_VSM_STYPE = 32'd31;
  localparam logic [31:0] APU_VSM_LINEAR = 32'd1;
  localparam logic [31:0] APU_VSM_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VSM_REPLY = 20;
  localparam int unsigned APU_VSM_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_VSM_OK = 1'b0, APU_VSM_FAULT = 1'b1 } apu_vsm_status_e;
  typedef struct packed { apu_vsm_status_e status; } apu_vsm_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] guest;
  } apu_vsm_t;

  // Command type 82 is VK_COMMAND_TYPE_vkCreateRenderPass_EXT. sType 38.
  localparam int unsigned APU_VRP_WORDS = 24;
  localparam logic [31:0] APU_VRP_CMD_RPASS = 32'd82;
  localparam logic [31:0] APU_VRP_STYPE = 32'd38;
  localparam logic [31:0] APU_VRP_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VRP_REPLY = 20;
  localparam int unsigned APU_VRP_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_VRP_OK = 1'b0, APU_VRP_FAULT = 1'b1 } apu_vrp_status_e;
  typedef struct packed { apu_vrp_status_e status; } apu_vrp_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] guest;
  } apu_vrp_t;

  // Command type 65 is VK_COMMAND_TYPE_vkCreateGraphicsPipelines_EXT. sType 28.
  localparam int unsigned APU_VGP_WORDS = 32;
  localparam logic [31:0] APU_VGP_CMD_GPIPE = 32'd65;
  localparam logic [31:0] APU_VGP_STYPE = 32'd28;
  localparam logic [31:0] APU_VGP_VERTEX = 32'd1;
  localparam logic [31:0] APU_VGP_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VGP_REPLY = 26;
  localparam int unsigned APU_VGP_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_VGP_OK = 1'b0, APU_VGP_FAULT = 1'b1 } apu_vgp_status_e;
  typedef struct packed { apu_vgp_status_e status; } apu_vgp_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] shader; logic [63:0] layout;
    logic [63:0] rpass; logic [63:0] guest;
  } apu_vgp_t;

  // Command type 80 is VK_COMMAND_TYPE_vkCreateFramebuffer_EXT. sType 37.
  localparam int unsigned APU_VFB_WORDS = 24;
  localparam logic [31:0] APU_VFB_CMD_FBUF = 32'd80;
  localparam logic [31:0] APU_VFB_STYPE = 32'd37;
  localparam logic [31:0] APU_VFB_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VFB_REPLY = 22;
  localparam int unsigned APU_VFB_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_VFB_OK = 1'b0, APU_VFB_FAULT = 1'b1 } apu_vfb_status_e;
  typedef struct packed { apu_vfb_status_e status; } apu_vfb_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] rpass; logic [63:0] view; logic [63:0] guest;
  } apu_vfb_t;

  // Command type 133 is VK_COMMAND_TYPE_vkCmdBeginRenderPass_EXT. sType 43.
  localparam int unsigned APU_VRB_WORDS = 24;
  localparam logic [31:0] APU_VRB_CMD_BEGINRP = 32'd133;
  localparam logic [31:0] APU_VRB_STYPE = 32'd43;
  localparam logic [31:0] APU_VRB_INLINE = 32'd0;
  localparam logic [31:0] APU_VRB_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VRB_REPLY = 20;
  localparam int unsigned APU_VRB_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_VRB_OK = 1'b0, APU_VRB_FAULT = 1'b1 } apu_vrb_status_e;
  typedef struct packed { apu_vrb_status_e status; } apu_vrb_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [63:0] rpass; logic [63:0] fbuf;
  } apu_vrb_t;

  // Command type 106 is VK_COMMAND_TYPE_vkCmdDraw_EXT.
  localparam int unsigned APU_VDW_WORDS = 16;
  localparam logic [31:0] APU_VDW_CMD_DRAW = 32'd106;
  localparam logic [31:0] APU_VDW_VERTS = 32'd3;
  localparam logic [31:0] APU_VDW_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VDW_REPLY = 8;
  localparam int unsigned APU_VDW_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_VDW_OK = 1'b0, APU_VDW_FAULT = 1'b1 } apu_vdw_status_e;
  typedef struct packed { apu_vdw_status_e status; } apu_vdw_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [31:0] vcount;
  } apu_vdw_t;

  // Command type 135 is VK_COMMAND_TYPE_vkCmdEndRenderPass_EXT.
  localparam int unsigned APU_VRE_WORDS = 16;
  localparam logic [31:0] APU_VRE_CMD_ENDRP = 32'd135;
  localparam logic [31:0] APU_VRE_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VRE_REPLY = 8;
  localparam int unsigned APU_VRE_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_VRE_OK = 1'b0, APU_VRE_FAULT = 1'b1 } apu_vre_status_e;
  typedef struct packed { apu_vre_status_e status; } apu_vre_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf;
  } apu_vre_t;

  // Command type 105 is VK_COMMAND_TYPE_vkCmdBindVertexBuffers_EXT.
  localparam int unsigned APU_VVB_WORDS = 16;
  localparam logic [31:0] APU_VVB_CMD_BINDVTX = 32'd105;
  localparam logic [31:0] APU_VVB_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VVB_REPLY = 10;
  localparam int unsigned APU_VVB_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_VVB_OK = 1'b0, APU_VVB_FAULT = 1'b1 } apu_vvb_status_e;
  typedef struct packed { apu_vvb_status_e status; } apu_vvb_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [63:0] buffer;
  } apu_vvb_t;

  // Command type 104 is VK_COMMAND_TYPE_vkCmdBindIndexBuffer_EXT.
  localparam int unsigned APU_VIB_WORDS = 16;
  localparam logic [31:0] APU_VIB_CMD_BINDIDX = 32'd104;
  localparam logic [31:0] APU_VIB_UINT16 = 32'd0;
  localparam logic [31:0] APU_VIB_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VIB_REPLY = 10;
  localparam int unsigned APU_VIB_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_VIB_OK = 1'b0, APU_VIB_FAULT = 1'b1 } apu_vib_status_e;
  typedef struct packed { apu_vib_status_e status; } apu_vib_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [63:0] buffer;
  } apu_vib_t;

  // Command type 107 is VK_COMMAND_TYPE_vkCmdDrawIndexed_EXT.
  localparam int unsigned APU_VDI_WORDS = 16;
  localparam logic [31:0] APU_VDI_CMD_DRAWIDX = 32'd107;
  localparam logic [31:0] APU_VDI_INDICES = 32'd3;
  localparam logic [31:0] APU_VDI_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VDI_REPLY = 10;
  localparam int unsigned APU_VDI_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_VDI_OK = 1'b0, APU_VDI_FAULT = 1'b1 } apu_vdi_status_e;
  typedef struct packed { apu_vdi_status_e status; } apu_vdi_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [31:0] icount;
  } apu_vdi_t;

  // Command type 94 is VK_COMMAND_TYPE_vkCmdSetViewport_EXT.
  localparam int unsigned APU_VVP_WORDS = 16;
  localparam logic [31:0] APU_VVP_CMD_SETVP = 32'd94;
  localparam logic [31:0] APU_VVP_F64 = 32'h42800000;
  localparam logic [31:0] APU_VVP_F1 = 32'h3f800000;
  localparam logic [31:0] APU_VVP_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VVP_REPLY = 10;
  localparam int unsigned APU_VVP_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_VVP_OK = 1'b0, APU_VVP_FAULT = 1'b1 } apu_vvp_status_e;
  typedef struct packed { apu_vvp_status_e status; } apu_vvp_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [31:0] width_f;
  } apu_vvp_t;

  // Command type 95 is VK_COMMAND_TYPE_vkCmdSetScissor_EXT.
  localparam int unsigned APU_VSI_WORDS = 16;
  localparam logic [31:0] APU_VSI_CMD_SETSC = 32'd95;
  localparam logic [31:0] APU_VSI_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VSI_REPLY = 10;
  localparam int unsigned APU_VSI_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_VSI_OK = 1'b0, APU_VSI_FAULT = 1'b1 } apu_vsi_status_e;
  typedef struct packed { apu_vsi_status_e status; } apu_vsi_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [31:0] width;
  } apu_vsi_t;

  // Command type 126 is VK_COMMAND_TYPE_vkCmdPipelineBarrier_EXT.
  localparam int unsigned APU_VPB_WORDS = 16;
  localparam logic [31:0] APU_VPB_CMD_BARRIER = 32'd126;
  localparam logic [31:0] APU_VPB_TOP = 32'd1;
  localparam logic [31:0] APU_VPB_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VPB_REPLY = 10;
  localparam int unsigned APU_VPB_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_VPB_OK = 1'b0, APU_VPB_FAULT = 1'b1 } apu_vpb_status_e;
  typedef struct packed { apu_vpb_status_e status; } apu_vpb_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [31:0] src;
  } apu_vpb_t;

  // Command type 134 is VK_COMMAND_TYPE_vkCmdNextSubpass_EXT.
  localparam int unsigned APU_VNS_WORDS = 16;
  localparam logic [31:0] APU_VNS_CMD_NEXTSP = 32'd134;
  localparam logic [31:0] APU_VNS_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_VNS_REPLY = 10;
  localparam int unsigned APU_VNS_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_VNS_OK = 1'b0, APU_VNS_FAULT = 1'b1 } apu_vns_status_e;
  typedef struct packed { apu_vns_status_e status; } apu_vns_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [31:0] contents;
  } apu_vns_t;

  // Command type 81 is VK_COMMAND_TYPE_vkDestroyFramebuffer_EXT.
  localparam int unsigned APU_DFB_WORDS = 16;
  localparam logic [31:0] APU_DFB_CMD_DFB = 32'd81;
  localparam logic [31:0] APU_DFB_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_DFB_REPLY = 10;
  localparam int unsigned APU_DFB_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_DFB_OK = 1'b0, APU_DFB_FAULT = 1'b1 } apu_vdf_status_e;
  typedef struct packed { apu_vdf_status_e status; } apu_vdf_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vdf_t;

  // Command type 58 is VK_COMMAND_TYPE_vkDestroyImageView_EXT.
  localparam int unsigned APU_DVW_WORDS = 16;
  localparam logic [31:0] APU_DVW_CMD_DVW = 32'd58;
  localparam logic [31:0] APU_DVW_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_DVW_REPLY = 10;
  localparam int unsigned APU_DVW_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_DVW_OK = 1'b0, APU_DVW_FAULT = 1'b1 } apu_vdx_status_e;
  typedef struct packed { apu_vdx_status_e status; } apu_vdx_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vdx_t;

  // Command type 71 is VK_COMMAND_TYPE_vkDestroySampler_EXT.
  localparam int unsigned APU_DSM_WORDS = 16;
  localparam logic [31:0] APU_DSM_CMD_DSM = 32'd71;
  localparam logic [31:0] APU_DSM_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_DSM_REPLY = 10;
  localparam int unsigned APU_DSM_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_DSM_OK = 1'b0, APU_DSM_FAULT = 1'b1 } apu_vdk_status_e;
  typedef struct packed { apu_vdk_status_e status; } apu_vdk_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vdk_t;

  // Command type 83 is VK_COMMAND_TYPE_vkDestroyRenderPass_EXT.
  localparam int unsigned APU_DRP_WORDS = 16;
  localparam logic [31:0] APU_DRP_CMD_DRP = 32'd83;
  localparam logic [31:0] APU_DRP_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_DRP_REPLY = 10;
  localparam int unsigned APU_DRP_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_DRP_OK = 1'b0, APU_DRP_FAULT = 1'b1 } apu_vdr_status_e;
  typedef struct packed { apu_vdr_status_e status; } apu_vdr_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vdr_t;

  // Command type 51 is VK_COMMAND_TYPE_vkDestroyBuffer_EXT.
  localparam int unsigned APU_DBF_WORDS = 16;
  localparam logic [31:0] APU_DBF_CMD_DBF = 32'd51;
  localparam logic [31:0] APU_DBF_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_DBF_REPLY = 10;
  localparam int unsigned APU_DBF_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_DBF_OK = 1'b0, APU_DBF_FAULT = 1'b1 } apu_vdb_status_e;
  typedef struct packed { apu_vdb_status_e status; } apu_vdb_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vdb_t;

  // Command type 55 is VK_COMMAND_TYPE_vkDestroyImage_EXT.
  localparam int unsigned APU_DIM_WORDS = 16;
  localparam logic [31:0] APU_DIM_CMD_DIM = 32'd55;
  localparam logic [31:0] APU_DIM_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_DIM_REPLY = 10;
  localparam int unsigned APU_DIM_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_DIM_OK = 1'b0, APU_DIM_FAULT = 1'b1 } apu_vdg_status_e;
  typedef struct packed { apu_vdg_status_e status; } apu_vdg_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vdg_t;

  // Command type 22 is VK_COMMAND_TYPE_vkFreeMemory_EXT.
  localparam int unsigned APU_FME_WORDS = 16;
  localparam logic [31:0] APU_FME_CMD_FME = 32'd22;
  localparam logic [31:0] APU_FME_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_FME_REPLY = 10;
  localparam int unsigned APU_FME_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_FME_OK = 1'b0, APU_FME_FAULT = 1'b1 } apu_vfe_status_e;
  typedef struct packed { apu_vfe_status_e status; } apu_vfe_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vfe_t;

  // Command type 60 is VK_COMMAND_TYPE_vkDestroyShaderModule_EXT.
  localparam int unsigned APU_DMD_WORDS = 16;
  localparam logic [31:0] APU_DMD_CMD_DMD = 32'd60;
  localparam logic [31:0] APU_DMD_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_DMD_REPLY = 10;
  localparam int unsigned APU_DMD_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_DMD_OK = 1'b0, APU_DMD_FAULT = 1'b1 } apu_vdm_status_e;
  typedef struct packed { apu_vdm_status_e status; } apu_vdm_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vdm_t;

  // Command type 67 is VK_COMMAND_TYPE_vkDestroyPipeline_EXT.
  localparam int unsigned APU_DPL_WORDS = 16;
  localparam logic [31:0] APU_DPL_CMD_DPL = 32'd67;
  localparam logic [31:0] APU_DPL_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_DPL_REPLY = 10;
  localparam int unsigned APU_DPL_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_DPL_OK = 1'b0, APU_DPL_FAULT = 1'b1 } apu_vdp_status_e;
  typedef struct packed { apu_vdp_status_e status; } apu_vdp_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vdp_t;

  // Command type 69 is VK_COMMAND_TYPE_vkDestroyPipelineLayout_EXT.
  localparam int unsigned APU_DYO_WORDS = 16;
  localparam logic [31:0] APU_DYO_CMD_DYO = 32'd69;
  localparam logic [31:0] APU_DYO_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_DYO_REPLY = 10;
  localparam int unsigned APU_DYO_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_DYO_OK = 1'b0, APU_DYO_FAULT = 1'b1 } apu_vdy_status_e;
  typedef struct packed { apu_vdy_status_e status; } apu_vdy_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vdy_t;

  // Command type 73 is VK_COMMAND_TYPE_vkDestroyDescriptorSetLayout_EXT.
  localparam int unsigned APU_DDS_WORDS = 16;
  localparam logic [31:0] APU_DDS_CMD_DDS = 32'd73;
  localparam logic [31:0] APU_DDS_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_DDS_REPLY = 10;
  localparam int unsigned APU_DDS_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_DDS_OK = 1'b0, APU_DDS_FAULT = 1'b1 } apu_vdt_status_e;
  typedef struct packed { apu_vdt_status_e status; } apu_vdt_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vdt_t;

  // Command type 75 is VK_COMMAND_TYPE_vkDestroyDescriptorPool_EXT.
  localparam int unsigned APU_DPO_WORDS = 16;
  localparam logic [31:0] APU_DPO_CMD_DPO = 32'd75;
  localparam logic [31:0] APU_DPO_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_DPO_REPLY = 10;
  localparam int unsigned APU_DPO_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_DPO_OK = 1'b0, APU_DPO_FAULT = 1'b1 } apu_vdq_status_e;
  typedef struct packed { apu_vdq_status_e status; } apu_vdq_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vdq_t;
  // Command type 78 is VK_COMMAND_TYPE_vkFreeDescriptorSets_EXT.
  // Compact CS: device, pool, count 1, array size 1, one set. Pool is not
  // LOOKed up (DestroyDescriptorPool already RETIREd POOL).
  localparam int unsigned APU_FDS_WORDS = 16;
  localparam logic [31:0] APU_FDS_CMD_FDS = 32'd78;
  localparam logic [31:0] APU_FDS_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_FDS_REPLY = 10;
  localparam int unsigned APU_FDS_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_FDS_OK = 1'b0, APU_FDS_FAULT = 1'b1 } apu_vfs_status_e;
  typedef struct packed { apu_vfs_status_e status; } apu_vfs_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] pool; logic [63:0] obj;
  } apu_vfs_t;

  // Command type 92 is VK_COMMAND_TYPE_vkResetCommandBuffer_EXT.
  localparam int unsigned APU_RCB_WORDS = 16;
  localparam logic [31:0] APU_RCB_CMD_RCB = 32'd92;
  localparam logic [31:0] APU_RCB_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_RCB_REPLY = 10;
  localparam int unsigned APU_RCB_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_RCB_OK = 1'b0, APU_RCB_FAULT = 1'b1 } apu_vrc_status_e;
  typedef struct packed { apu_vrc_status_e status; } apu_vrc_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vrc_t;

  // Command type 89 is VK_COMMAND_TYPE_vkFreeCommandBuffers_EXT.
  // Compact CS: device, pool (vac guest 0xA1, no LOOKUP), count 1, one CMDBUF.
  localparam int unsigned APU_FCB_WORDS = 16;
  localparam logic [31:0] APU_FCB_CMD_FCB = 32'd89;
  localparam logic [31:0] APU_FCB_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_FCB_REPLY = 10;
  localparam int unsigned APU_FCB_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_FCB_OK = 1'b0, APU_FCB_FAULT = 1'b1 } apu_vfc_status_e;
  typedef struct packed { apu_vfc_status_e status; } apu_vfc_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] pool; logic [63:0] obj;
  } apu_vfc_t;

  // Command type 12 is VK_COMMAND_TYPE_vkDestroyDevice_EXT.
  // CS is (device, allocator); packed obj copies device for LOOKUP.
  localparam int unsigned APU_DDV_WORDS = 16;
  localparam logic [31:0] APU_DDV_CMD_DDV = 32'd12;
  localparam logic [31:0] APU_DDV_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_DDV_REPLY = 10;
  localparam int unsigned APU_DDV_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_DDV_OK = 1'b0, APU_DDV_FAULT = 1'b1 } apu_vdd_status_e;
  typedef struct packed { apu_vdd_status_e status; } apu_vdd_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vdd_t;
  // Command type 87 is VK_COMMAND_TYPE_vkResetCommandPool_EXT.
  // Compact CS: device, pool (vac guest 0xA1, no LOOKUP), reset flags 0.
  localparam int unsigned APU_RCP_WORDS = 16;
  localparam logic [31:0] APU_RCP_CMD_RCP = 32'd87;
  localparam logic [31:0] APU_RCP_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_RCP_REPLY = 10;
  localparam int unsigned APU_RCP_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_RCP_OK = 1'b0, APU_RCP_FAULT = 1'b1 } apu_vpc_status_e;
  typedef struct packed { apu_vpc_status_e status; } apu_vpc_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vpc_t;

  // Command type 86 is VK_COMMAND_TYPE_vkDestroyCommandPool_EXT.
  // Compact CS: device, pool, null allocator. Pool is not LOOKed up.
  localparam int unsigned APU_DCP_WORDS = 16;
  localparam logic [31:0] APU_DCP_CMD_DCP = 32'd86;
  localparam logic [31:0] APU_DCP_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_DCP_REPLY = 10;
  localparam int unsigned APU_DCP_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_DCP_OK = 1'b0, APU_DCP_FAULT = 1'b1 } apu_vdc_status_e;
  typedef struct packed { apu_vdc_status_e status; } apu_vdc_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vdc_t;

  // Command type 1 is VK_COMMAND_TYPE_vkDestroyInstance_EXT.
  // CS is (instance, allocator); packed obj copies instance for LOOKUP.
  localparam int unsigned APU_DIN_WORDS = 16;
  localparam logic [31:0] APU_DIN_CMD_DIN = 32'd1;
  localparam logic [31:0] APU_DIN_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_DIN_REPLY = 10;
  localparam int unsigned APU_DIN_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_DIN_OK = 1'b0, APU_DIN_FAULT = 1'b1 } apu_vdn_status_e;
  typedef struct packed { apu_vdn_status_e status; } apu_vdn_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vdn_t;
  // Command type 4 is VK_COMMAND_TYPE_vkGetPhysicalDeviceFormatProperties_EXT.
  localparam int unsigned APU_GFP_WORDS = 16;
  localparam logic [31:0] APU_GFP_CMD_GFP = 32'd4;
  localparam logic [31:0] APU_GFP_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_GFP_REPLY = 10;
  localparam int unsigned APU_GFP_BRU_REPLY = APU_BRU_TAIL_REPLY;
  localparam logic [31:0] APU_GFP_FORMAT = 32'd37;
  // SAMPLED_IMAGE|STORAGE_IMAGE|COLOR_ATTACHMENT|TRANSFER_SRC|TRANSFER_DST
  localparam logic [31:0] APU_GFP_FEATURES = 32'h00006083;
  typedef enum logic { APU_GFP_OK = 1'b0, APU_GFP_FAULT = 1'b1 } apu_vgf_status_e;
  typedef struct packed { apu_vgf_status_e status; } apu_vgf_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] phys_handle; logic [31:0] format;
  } apu_vgf_t;

  // Command type 5 is VK_COMMAND_TYPE_vkGetPhysicalDeviceImageFormatProperties_EXT.
  localparam int unsigned APU_IFP_WORDS = 16;
  localparam logic [31:0] APU_IFP_CMD_IFP = 32'd5;
  localparam logic [31:0] APU_IFP_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_IFP_REPLY = 10;
  localparam int unsigned APU_IFP_BRU_REPLY = APU_BRU_TAIL_REPLY;
  localparam logic [31:0] APU_IFP_TYPE_2D = 32'd1;
  localparam logic [31:0] APU_IFP_TILING_LINEAR = 32'd0;
  localparam logic [31:0] APU_IFP_USAGE_STORAGE = 32'h00000020;
  localparam logic [31:0] APU_IFP_MAX_EXTENT = 32'd64;
  localparam logic [31:0] APU_IFP_MAX_MIP = 32'd1;
  localparam logic [31:0] APU_IFP_SAMPLES = 32'd1;
  typedef enum logic { APU_IFP_OK = 1'b0, APU_IFP_FAULT = 1'b1 } apu_vip_status_e;
  typedef struct packed { apu_vip_status_e status; } apu_vip_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] phys_handle; logic [31:0] format;
  } apu_vip_t;

  // Command type 14 is VK_COMMAND_TYPE_vkEnumerateDeviceExtensionProperties_EXT.
  localparam int unsigned APU_DEX_WORDS = 16;
  localparam logic [31:0] APU_DEX_CMD_DEX = 32'd14;
  localparam logic [31:0] APU_DEX_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_DEX_REPLY = 10;
  localparam int unsigned APU_DEX_BRU_REPLY = APU_BRU_TAIL_REPLY;
  localparam logic [31:0] APU_DEX_COUNT = 32'd0;
  typedef enum logic { APU_DEX_OK = 1'b0, APU_DEX_FAULT = 1'b1 } apu_vxe_status_e;
  typedef struct packed { apu_vxe_status_e status; } apu_vxe_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] phys_handle;
  } apu_vxe_t;

  // Command type 76 is VK_COMMAND_TYPE_vkResetDescriptorPool_EXT.
  localparam int unsigned APU_RDP_WORDS = 16;
  localparam logic [31:0] APU_RDP_CMD_RDP = 32'd76;
  localparam logic [31:0] APU_RDP_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_RDP_REPLY = 10;
  localparam int unsigned APU_RDP_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_RDP_OK = 1'b0, APU_RDP_FAULT = 1'b1 } apu_vrd_status_e;
  typedef struct packed { apu_vrd_status_e status; } apu_vrd_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vrd_t;
  // Command type 13 is VK_COMMAND_TYPE_vkEnumerateInstanceExtensionProperties_EXT.
  localparam int unsigned APU_IEX_WORDS = 16;
  localparam logic [31:0] APU_IEX_CMD_IEX = 32'd13;
  localparam logic [31:0] APU_IEX_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_IEX_REPLY = 10;
  localparam int unsigned APU_IEX_BRU_REPLY = APU_BRU_TAIL_REPLY;
  localparam logic [31:0] APU_IEX_COUNT = 32'd0;
  typedef enum logic { APU_IEX_OK = 1'b0, APU_IEX_FAULT = 1'b1 } apu_vie_status_e;
  typedef struct packed { apu_vie_status_e status; } apu_vie_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
  } apu_vie_t;

  // Command type 20 is VK_COMMAND_TYPE_vkDeviceWaitIdle_EXT.
  localparam int unsigned APU_DWI_WORDS = 16;
  localparam logic [31:0] APU_DWI_CMD_DWI = 32'd20;
  localparam logic [31:0] APU_DWI_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_DWI_REPLY = 10;
  localparam int unsigned APU_DWI_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_DWI_OK = 1'b0, APU_DWI_FAULT = 1'b1 } apu_vwl_status_e;
  typedef struct packed { apu_vwl_status_e status; } apu_vwl_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device;
  } apu_vwl_t;

  // Command type 56 is VK_COMMAND_TYPE_vkGetImageSubresourceLayout_EXT.
  localparam int unsigned APU_ISL_WORDS = 16;
  localparam logic [31:0] APU_ISL_CMD_ISL = 32'd56;
  localparam logic [31:0] APU_ISL_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_ISL_REPLY = 10;
  localparam int unsigned APU_ISL_BRU_REPLY = APU_BRU_TAIL_REPLY;
  localparam logic [31:0] APU_ISL_ROW = 32'd256;
  typedef enum logic { APU_ISL_OK = 1'b0, APU_ISL_FAULT = 1'b1 } apu_vsl_status_e;
  typedef struct packed { apu_vsl_status_e status; } apu_vsl_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vsl_t;

  // Command type 84 is VK_COMMAND_TYPE_vkGetRenderAreaGranularity_EXT.
  localparam int unsigned APU_RAG_WORDS = 16;
  localparam logic [31:0] APU_RAG_CMD_RAG = 32'd84;
  localparam logic [31:0] APU_RAG_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_RAG_REPLY = 10;
  localparam int unsigned APU_RAG_BRU_REPLY = APU_BRU_TAIL_REPLY;
  localparam logic [31:0] APU_RAG_GRAN = 32'd1;
  typedef enum logic { APU_RAG_OK = 1'b0, APU_RAG_FAULT = 1'b1 } apu_vrg_status_e;
  typedef struct packed { apu_vrg_status_e status; } apu_vrg_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vrg_t;
  // Command type 96 is VK_COMMAND_TYPE_vkCmdSetLineWidth_EXT.
  localparam int unsigned APU_SLW_WORDS = 16;
  localparam logic [31:0] APU_SLW_CMD_SLW = 32'd96;
  localparam logic [31:0] APU_SLW_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_SLW_REPLY = 10;
  localparam int unsigned APU_SLW_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_SLW_OK = 1'b0, APU_SLW_FAULT = 1'b1 } apu_vlw_status_e;
  typedef struct packed { apu_vlw_status_e status; } apu_vlw_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf;
  } apu_vlw_t;

  // Command type 97 is VK_COMMAND_TYPE_vkCmdSetDepthBias_EXT.
  localparam int unsigned APU_SDB_WORDS = 16;
  localparam logic [31:0] APU_SDB_CMD_SDB = 32'd97;
  localparam logic [31:0] APU_SDB_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_SDB_REPLY = 10;
  localparam int unsigned APU_SDB_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_SDB_OK = 1'b0, APU_SDB_FAULT = 1'b1 } apu_vzb_status_e;
  typedef struct packed { apu_vzb_status_e status; } apu_vzb_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf;
  } apu_vzb_t;

  // Command type 98 is VK_COMMAND_TYPE_vkCmdSetBlendConstants_EXT.
  localparam int unsigned APU_SBC_WORDS = 16;
  localparam logic [31:0] APU_SBC_CMD_SBC = 32'd98;
  localparam logic [31:0] APU_SBC_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_SBC_REPLY = 10;
  localparam int unsigned APU_SBC_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_SBC_OK = 1'b0, APU_SBC_FAULT = 1'b1 } apu_vbc_status_e;
  typedef struct packed { apu_vbc_status_e status; } apu_vbc_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf;
  } apu_vbc_t;

  // Command type 99 is VK_COMMAND_TYPE_vkCmdSetDepthBounds_EXT.
  localparam int unsigned APU_SBB_WORDS = 16;
  localparam logic [31:0] APU_SBB_CMD_SBB = 32'd99;
  localparam logic [31:0] APU_SBB_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_SBB_REPLY = 10;
  localparam int unsigned APU_SBB_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_SBB_OK = 1'b0, APU_SBB_FAULT = 1'b1 } apu_vbo_status_e;
  typedef struct packed { apu_vbo_status_e status; } apu_vbo_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf;
  } apu_vbo_t;
  // Command type 100 is VK_COMMAND_TYPE_vkCmdSetStencilCompareMask_EXT.
  localparam int unsigned APU_SCM_WORDS = 16;
  localparam logic [31:0] APU_SCM_CMD_SCM = 32'd100;
  localparam logic [31:0] APU_SCM_FACE = 32'd3;
  localparam logic [31:0] APU_SCM_MASK = 32'hffffffff;
  localparam logic [31:0] APU_SCM_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_SCM_REPLY = 10;
  localparam int unsigned APU_SCM_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_SCM_OK = 1'b0, APU_SCM_FAULT = 1'b1 } apu_vcm_status_e;
  typedef struct packed { apu_vcm_status_e status; } apu_vcm_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf;
  } apu_vcm_t;

  // Command type 101 is VK_COMMAND_TYPE_vkCmdSetStencilWriteMask_EXT.
  localparam int unsigned APU_SWM_WORDS = 16;
  localparam logic [31:0] APU_SWM_CMD_SWM = 32'd101;
  localparam logic [31:0] APU_SWM_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_SWM_REPLY = 10;
  localparam int unsigned APU_SWM_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_SWM_OK = 1'b0, APU_SWM_FAULT = 1'b1 } apu_vwm_status_e;
  typedef struct packed { apu_vwm_status_e status; } apu_vwm_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf;
  } apu_vwm_t;

  // Command type 102 is VK_COMMAND_TYPE_vkCmdSetStencilReference_EXT.
  localparam int unsigned APU_SRF_WORDS = 16;
  localparam logic [31:0] APU_SRF_CMD_SRF = 32'd102;
  localparam logic [31:0] APU_SRF_REF = 32'd0;
  localparam logic [31:0] APU_SRF_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_SRF_REPLY = 10;
  localparam int unsigned APU_SRF_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_SRF_OK = 1'b0, APU_SRF_FAULT = 1'b1 } apu_vrf_status_e;
  typedef struct packed { apu_vrf_status_e status; } apu_vrf_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf;
  } apu_vrf_t;
  // Command type 112 is VK_COMMAND_TYPE_vkCmdCopyBuffer_EXT.
  localparam int unsigned APU_CCB_WORDS = 16;
  localparam logic [31:0] APU_CCB_CMD_CCB = 32'd112;
  localparam logic [31:0] APU_CCB_COUNT = 32'd1;
  localparam logic [31:0] APU_CCB_SRC_OFF = 32'd0;
  localparam logic [31:0] APU_CCB_DST_OFF = 32'd2048;
  localparam logic [31:0] APU_CCB_SIZE = 32'd2048;
  localparam logic [31:0] APU_CCB_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_CCB_REPLY = 10;
  localparam int unsigned APU_CCB_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_CCB_OK = 1'b0, APU_CCB_FAULT = 1'b1 } apu_vcc_status_e;
  typedef struct packed { apu_vcc_status_e status; } apu_vcc_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [63:0] src; logic [63:0] dst;
  } apu_vcc_t;

  // Command type 113 is VK_COMMAND_TYPE_vkCmdCopyImage_EXT.
  localparam int unsigned APU_CCI_WORDS = 32;
  localparam logic [31:0] APU_CCI_CMD_CCI = 32'd113;
  localparam logic [31:0] APU_CCI_SRC_LAYOUT = 32'd6;
  localparam logic [31:0] APU_CCI_DST_LAYOUT = 32'd7;
  localparam logic [31:0] APU_CCI_COUNT = 32'd1;
  localparam logic [31:0] APU_CCI_ASPECT = 32'd1;
  localparam logic [31:0] APU_CCI_SRC_X = 32'd0;
  localparam logic [31:0] APU_CCI_DST_X = 32'd32;
  localparam logic [31:0] APU_CCI_EXT_W = 32'd32;
  localparam logic [31:0] APU_CCI_EXT_H = 32'd64;
  localparam logic [31:0] APU_CCI_EXT_D = 32'd1;
  localparam logic [31:0] APU_CCI_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_CCI_REPLY = 10;
  localparam int unsigned APU_CCI_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_CCI_OK = 1'b0, APU_CCI_FAULT = 1'b1 } apu_vcy_status_e;
  typedef struct packed { apu_vcy_status_e status; } apu_vcy_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [63:0] src; logic [63:0] dst;
  } apu_vcy_t;

  // Command type 114 is VK_COMMAND_TYPE_vkCmdBlitImage_EXT.
  localparam int unsigned APU_BLI_WORDS = 32;
  localparam logic [31:0] APU_BLI_CMD_BLI = 32'd114;
  localparam logic [31:0] APU_BLI_SRC1_X = 32'd32;
  localparam logic [31:0] APU_BLI_SRC1_Y = 32'd64;
  localparam logic [31:0] APU_BLI_SRC1_Z = 32'd1;
  localparam logic [31:0] APU_BLI_DST0_X = 32'd32;
  localparam logic [31:0] APU_BLI_DST1_X = 32'd64;
  localparam logic [31:0] APU_BLI_DST1_Y = 32'd64;
  localparam logic [31:0] APU_BLI_DST1_Z = 32'd1;
  localparam logic [31:0] APU_BLI_FILTER = 32'd0;
  localparam logic [31:0] APU_BLI_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_BLI_REPLY = 10;
  localparam int unsigned APU_BLI_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_BLI_OK = 1'b0, APU_BLI_FAULT = 1'b1 } apu_vbl_status_e;
  typedef struct packed { apu_vbl_status_e status; } apu_vbl_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [63:0] src; logic [63:0] dst;
  } apu_vbl_t;

  // Command type 115 is VK_COMMAND_TYPE_vkCmdCopyBufferToImage_EXT.
  localparam int unsigned APU_CBI_WORDS = 32;
  localparam logic [31:0] APU_CBI_CMD_CBI = 32'd115;
  localparam logic [31:0] APU_CBI_EXT_W = 32'd32;
  localparam logic [31:0] APU_CBI_EXT_H = 32'd32;
  localparam logic [31:0] APU_CBI_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_CBI_REPLY = 10;
  localparam int unsigned APU_CBI_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_CBI_OK = 1'b0, APU_CBI_FAULT = 1'b1 } apu_vbt_status_e;
  typedef struct packed { apu_vbt_status_e status; } apu_vbt_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [63:0] src; logic [63:0] dst;
  } apu_vbt_t;
  // Command type 116 is VK_COMMAND_TYPE_vkCmdCopyImageToBuffer_EXT.
  localparam int unsigned APU_CIB_WORDS = 32;
  localparam logic [31:0] APU_CIB_CMD_CIB = 32'd116;
  localparam logic [31:0] APU_CIB_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_CIB_REPLY = 10;
  localparam int unsigned APU_CIB_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_CIB_OK = 1'b0, APU_CIB_FAULT = 1'b1 } apu_vic_status_e;
  typedef struct packed { apu_vic_status_e status; } apu_vic_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [63:0] src; logic [63:0] dst;
  } apu_vic_t;

  // Command type 117 is VK_COMMAND_TYPE_vkCmdUpdateBuffer_EXT.
  localparam int unsigned APU_UBF_WORDS = 16;
  localparam logic [31:0] APU_UBF_CMD_UBF = 32'd117;
  localparam logic [31:0] APU_UBF_SIZE = 32'd4;
  localparam logic [31:0] APU_UBF_DATA = 32'd0;
  localparam logic [31:0] APU_UBF_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_UBF_REPLY = 10;
  localparam int unsigned APU_UBF_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_UBF_OK = 1'b0, APU_UBF_FAULT = 1'b1 } apu_vub_status_e;
  typedef struct packed { apu_vub_status_e status; } apu_vub_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [63:0] dst;
  } apu_vub_t;

  // Command type 118 is VK_COMMAND_TYPE_vkCmdFillBuffer_EXT.
  localparam int unsigned APU_FIL_WORDS = 16;
  localparam logic [31:0] APU_FIL_CMD_FIL = 32'd118;
  localparam logic [31:0] APU_FIL_DATA = 32'd0;
  localparam logic [31:0] APU_FIL_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_FIL_REPLY = 10;
  localparam int unsigned APU_FIL_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_FIL_OK = 1'b0, APU_FIL_FAULT = 1'b1 } apu_vfl_status_e;
  typedef struct packed { apu_vfl_status_e status; } apu_vfl_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [63:0] dst;
  } apu_vfl_t;

  // Command type 119 is VK_COMMAND_TYPE_vkCmdClearColorImage_EXT.
  localparam int unsigned APU_CCL_WORDS = 32;
  localparam logic [31:0] APU_CCL_CMD_CCL = 32'd119;
  localparam logic [31:0] APU_CCL_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_CCL_REPLY = 10;
  localparam int unsigned APU_CCL_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_CCL_OK = 1'b0, APU_CCL_FAULT = 1'b1 } apu_vcl_status_e;
  typedef struct packed { apu_vcl_status_e status; } apu_vcl_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [63:0] dst;
  } apu_vcl_t;
  // Command type 108 is VK_COMMAND_TYPE_vkCmdDrawIndirect_EXT.
  localparam int unsigned APU_DRI_WORDS = 16;
  localparam logic [31:0] APU_DRI_CMD_DRI = 32'd108;
  localparam logic [31:0] APU_DRI_COUNT = 32'd1;
  localparam logic [31:0] APU_DRI_STRIDE = 32'd16;
  localparam logic [31:0] APU_DRI_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_DRI_REPLY = 10;
  localparam int unsigned APU_DRI_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_DRI_OK = 1'b0, APU_DRI_FAULT = 1'b1 } apu_vio_status_e;
  typedef struct packed { apu_vio_status_e status; } apu_vio_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [63:0] dst;
  } apu_vio_t;

  // Command type 109 is VK_COMMAND_TYPE_vkCmdDrawIndexedIndirect_EXT.
  localparam int unsigned APU_IXI_WORDS = 16;
  localparam logic [31:0] APU_IXI_CMD_IXI = 32'd109;
  localparam logic [31:0] APU_IXI_COUNT = 32'd1;
  localparam logic [31:0] APU_IXI_STRIDE = 32'd20;
  localparam logic [31:0] APU_IXI_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_IXI_REPLY = 10;
  localparam int unsigned APU_IXI_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_IXI_OK = 1'b0, APU_IXI_FAULT = 1'b1 } apu_vix_status_e;
  typedef struct packed { apu_vix_status_e status; } apu_vix_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [63:0] dst;
  } apu_vix_t;

  // Command type 120 is VK_COMMAND_TYPE_vkCmdClearDepthStencilImage_EXT.
  localparam int unsigned APU_CDS_WORDS = 32;
  localparam logic [31:0] APU_CDS_CMD_CDS = 32'd120;
  localparam logic [31:0] APU_CDS_ASPECT = 32'd2;
  localparam logic [31:0] APU_CDS_STENCIL = 32'd0;
  localparam logic [31:0] APU_CDS_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_CDS_REPLY = 10;
  localparam int unsigned APU_CDS_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_CDS_OK = 1'b0, APU_CDS_FAULT = 1'b1 } apu_vds_status_e;
  typedef struct packed { apu_vds_status_e status; } apu_vds_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [63:0] dst;
  } apu_vds_t;

  // Command type 121 is VK_COMMAND_TYPE_vkCmdClearAttachments_EXT.
  localparam int unsigned APU_CAT_WORDS = 32;
  localparam logic [31:0] APU_CAT_CMD_CAT = 32'd121;
  localparam logic [31:0] APU_CAT_COUNT = 32'd1;
  localparam logic [31:0] APU_CAT_ASPECT = 32'd1;
  localparam logic [31:0] APU_CAT_EXT = 32'd64;
  localparam logic [31:0] APU_CAT_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_CAT_REPLY = 10;
  localparam int unsigned APU_CAT_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_CAT_OK = 1'b0, APU_CAT_FAULT = 1'b1 } apu_vat_status_e;
  typedef struct packed { apu_vat_status_e status; } apu_vat_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf;
  } apu_vat_t;
  // Command type 111 is VK_COMMAND_TYPE_vkCmdDispatchIndirect_EXT.
  localparam int unsigned APU_DSI_WORDS = 16;
  localparam logic [31:0] APU_DSI_CMD_DSI = 32'd111;
  localparam logic [31:0] APU_DSI_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_DSI_REPLY = 10;
  localparam int unsigned APU_DSI_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_DSI_OK = 1'b0, APU_DSI_FAULT = 1'b1 } apu_vin_status_e;
  typedef struct packed { apu_vin_status_e status; } apu_vin_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [63:0] dst;
  } apu_vin_t;

  // Command type 122 is VK_COMMAND_TYPE_vkCmdResolveImage_EXT.
  localparam int unsigned APU_RSI_WORDS = 32;
  localparam logic [31:0] APU_RSI_CMD_RSI = 32'd122;
  localparam logic [31:0] APU_RSI_DST_X = 32'd32;
  localparam logic [31:0] APU_RSI_EXT = 32'd32;
  localparam logic [31:0] APU_RSI_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_RSI_REPLY = 10;
  localparam int unsigned APU_RSI_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_RSI_OK = 1'b0, APU_RSI_FAULT = 1'b1 } apu_vrs_status_e;
  typedef struct packed { apu_vrs_status_e status; } apu_vrs_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] cbuf; logic [63:0] src; logic [63:0] dst;
  } apu_vrs_t;
  // Command type 36 is VK_COMMAND_TYPE_vkDestroyFence_EXT. No FENCE gnh kind.
  localparam int unsigned APU_DFE_WORDS = 16;
  localparam logic [31:0] APU_DFE_CMD_DFE = 32'd36;
  localparam logic [31:0] APU_DFE_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_DFE_REPLY = 10;
  localparam int unsigned APU_DFE_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_DFE_OK = 1'b0, APU_DFE_FAULT = 1'b1 } apu_vfn_status_e;
  typedef struct packed { apu_vfn_status_e status; } apu_vfn_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vfn_t;

  // Command type 37 is VK_COMMAND_TYPE_vkResetFences_EXT.
  localparam int unsigned APU_RFE_WORDS = 16;
  localparam logic [31:0] APU_RFE_CMD_RFE = 32'd37;
  localparam logic [31:0] APU_RFE_COUNT = 32'd1;
  localparam logic [31:0] APU_RFE_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_RFE_REPLY = 10;
  localparam int unsigned APU_RFE_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_RFE_OK = 1'b0, APU_RFE_FAULT = 1'b1 } apu_vfr_status_e;
  typedef struct packed { apu_vfr_status_e status; } apu_vfr_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vfr_t;

  // Command type 38 is VK_COMMAND_TYPE_vkGetFenceStatus_EXT.
  localparam int unsigned APU_GFS_WORDS = 16;
  localparam logic [31:0] APU_GFS_CMD_GFS = 32'd38;
  localparam logic [31:0] APU_GFS_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_GFS_REPLY = 10;
  localparam int unsigned APU_GFS_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_GFS_OK = 1'b0, APU_GFS_FAULT = 1'b1 } apu_vgs_status_e;
  typedef struct packed { apu_vgs_status_e status; } apu_vgs_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vgs_t;

  // Command type 39 is VK_COMMAND_TYPE_vkWaitForFences_EXT.
  localparam int unsigned APU_WFE_WORDS = 16;
  localparam logic [31:0] APU_WFE_CMD_WFE = 32'd39;
  localparam logic [31:0] APU_WFE_COUNT = 32'd1;
  localparam logic [31:0] APU_WFE_WAITALL = 32'd1;
  localparam logic [31:0] APU_WFE_GENERATE_REPLY = 32'd1;
  localparam int unsigned APU_WFE_REPLY = 10;
  localparam int unsigned APU_WFE_BRU_REPLY = APU_BRU_TAIL_REPLY;
  typedef enum logic { APU_WFE_OK = 1'b0, APU_WFE_FAULT = 1'b1 } apu_vwf_status_e;
  typedef struct packed { apu_vwf_status_e status; } apu_vwf_cpl_t;
  typedef struct packed {
    logic valid; logic reply; logic [31:0] cmd_type; logic [31:0] cmd_flags;
    logic [63:0] device; logic [63:0] obj;
  } apu_vwf_t;

endpackage
