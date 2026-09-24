// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Native APU contract package. The public guest ABI is modern virtio-mmio
// DeviceID 16; the structs below are the protected control-plane handoff into
// the resident command firmware. No virgl command semantics live in this
// register block: firmware owns protocol decode, resource lifetimes and shader
// compilation, while the APU datapath owns execution.

package g6lc_apu_pkg;

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

  // One sample against one triangle. +x right, +y up. Weights are the
  // integer edge functions; they sum to the signed area. Color is carried
  // through and is not computed here. This is not an SG fragment.
  typedef struct packed {
    logic signed [15:0] x;
    logic signed [15:0] y;
  } apu_cover_xy_t;

  typedef struct packed {
    apu_cover_xy_t v0, v1, v2;
    apu_cover_xy_t sample;
    logic [31:0] color;
  } apu_cover_req_t;

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

  typedef enum logic [1:0] {
    APU_FRAG_OK    = 2'd0,
    APU_FRAG_MISS  = 2'd1,
    APU_FRAG_FAULT = 2'd2
  } apu_frag_status_e;

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
  // Used-buffer interrupt reason after that completion. Not the
  // virtio-mmio window at 0x40001000 and not PLIC source 9.
  // Bit 0 is the queue. The config bit stays clear.
  localparam logic [63:0] APU_VGPU_VIW_ADDR = 64'h0000_0000_8800_E500;
  localparam logic [31:0] APU_VGPU_VIW_REASON = 32'h1;
  // Guest ack of that reason. Not the status word and not 0x40001000.
  localparam logic [63:0] APU_VGPU_VAW_ADDR = 64'h0000_0000_8800_E510;
  localparam logic [31:0] APU_VGPU_VAW_CLEAR = 32'h0;
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

  typedef enum logic [1:0] {
    APU_VGPU_UWR_OK    = 2'd0,
    APU_VGPU_UWR_EMPTY = 2'd1,
    APU_VGPU_UWR_FAULT = 2'd2,
    APU_VGPU_UWR_BUS   = 2'd3
  } apu_vgpu_uwr_status_e;

  typedef struct packed {
    apu_vgpu_uwr_status_e status;
    logic [31:0] elem_id;
    logic [31:0] elem_len;
    logic [63:0] addr;
  } apu_vgpu_uwr_cpl_t;

  typedef enum logic [1:0] {
    APU_VGPU_UIDX_OK    = 2'd0,
    APU_VGPU_UIDX_EMPTY = 2'd1,
    APU_VGPU_UIDX_FAULT = 2'd2,
    APU_VGPU_UIDX_BUS   = 2'd3
  } apu_vgpu_uidx_status_e;

  typedef struct packed {
    apu_vgpu_uidx_status_e status;
    logic [15:0] idx;
    logic [63:0] addr;
  } apu_vgpu_uidx_cpl_t;

  // One covered sample copied from a packed resource image. The address
  // is y * stride + x * 4, the same rule as the fragment surface.
  // Byte 0 is red. This is not a draw and not an SG fragment.
  typedef struct packed {
    logic covered;
    logic signed [15:0] x, y;
    logic [15:0] stride, width, height;
  } apu_rsurf_req_t;

  typedef struct packed {
    logic [15:0] idx;
    logic [31:0] desc_id;
    logic [31:0] len;
  } apu_vgpu_used_req_t;

  typedef struct packed {
    logic ok;
    logic [15:0] idx;
    logic [31:0] desc_id;
    logic [31:0] len;
  } apu_vgpu_used_cpl_t;

  typedef enum logic [1:0] {
    APU_VGPU_AVAIL_OK    = 2'd0,
    APU_VGPU_AVAIL_EMPTY = 2'd1,
    APU_VGPU_AVAIL_FAULT = 2'd2
  } apu_vgpu_avail_status_e;

  typedef enum logic {
    APU_VGPU_AVAIL_POST = 1'b0,
    APU_VGPU_AVAIL_WALK = 1'b1
  } apu_vgpu_avail_op_e;

  typedef struct packed {
    apu_vgpu_avail_op_e op;
    logic [15:0] avail_idx;
    logic [15:0] desc_id;
    logic [15:0] flags;
    logic [31:0] len;
    logic [319:0] cmd;
  } apu_vgpu_avail_req_t;

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

  // SUBMIT_3D as descriptors 0, 1, and 2. d0 is the 32-byte header,
  // d1 names the execbuffer, and d2 is the writable response.
  typedef struct packed {
    apu_vgpu_desc_t d0;
    apu_vgpu_desc_t d1;
    apu_vgpu_desc_t d2;
  } apu_vgpu_sub_req_t;

  // The accepted submit. buf_addr is the execbuffer. The bytes are not stored.
  typedef struct packed {
    logic valid;
    logic [31:0] ctx_id;
    logic [31:0] size;
    logic [63:0] buf_addr;
    logic [63:0] rsp_addr;
  } apu_vgpu_sub_t;

  typedef enum logic [1:0] {
    APU_VGPU_BUF_OK    = 2'd0,
    APU_VGPU_BUF_EMPTY = 2'd1,
    APU_VGPU_BUF_FAULT = 2'd2,
    APU_VGPU_BUF_BUS   = 2'd3
  } apu_vgpu_buf_status_e;

  typedef struct packed {
    apu_vgpu_buf_status_e status;
    logic [31:0] ctx_id;
    logic [31:0] size;
  } apu_vgpu_buf_cpl_t;

  // Bytes of one fetched execbuffer. valid means every beat arrived.
  typedef struct packed {
    logic valid;
    logic [31:0] ctx_id;
    logic [31:0] size;
    logic [63:0] buf_addr;
  } apu_vgpu_buf_t;

  typedef enum logic [1:0] {
    APU_VGPU_DEC_OK    = 2'd0,
    APU_VGPU_DEC_EMPTY = 2'd1,
    APU_VGPU_DEC_FAULT = 2'd2
  } apu_vgpu_dec_status_e;

  typedef struct packed {
    apu_vgpu_dec_status_e status;
  } apu_vgpu_dec_cpl_t;

  // The first command in a fetched execbuffer. next is the byte offset
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

  typedef enum logic [1:0] {
    APU_VGPU_SH_OK    = 2'd0,
    APU_VGPU_SH_EMPTY = 2'd1,
    APU_VGPU_SH_FAULT = 2'd2
  } apu_vgpu_sh_status_e;

  typedef struct packed {
    apu_vgpu_sh_status_e status;
  } apu_vgpu_sh_cpl_t;

  // The shader create after the surface. text_at is the TGSI text.
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

  typedef enum logic [1:0] {
    APU_VGPU_VE_OK    = 2'd0,
    APU_VGPU_VE_EMPTY = 2'd1,
    APU_VGPU_VE_FAULT = 2'd2
  } apu_vgpu_ve_status_e;

  typedef struct packed {
    apu_vgpu_ve_status_e status;
  } apu_vgpu_ve_cpl_t;

  // Two vertex attributes after the fragment shader. Both use buffer 0.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] off0;
    logic [31:0] fmt0;
    logic [31:0] off1;
    logic [31:0] fmt1;
    logic [31:0] next;
  } apu_vgpu_ve_t;

  typedef enum logic [1:0] {
    APU_VGPU_SV_OK    = 2'd0,
    APU_VGPU_SV_EMPTY = 2'd1,
    APU_VGPU_SV_FAULT = 2'd2
  } apu_vgpu_sv_status_e;

  typedef struct packed {
    apu_vgpu_sv_status_e status;
  } apu_vgpu_sv_cpl_t;

  // One sampler view over a 2D resource. This is not a texture fetch.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] resource_id;
    logic [23:0] format;
    logic [7:0] target;
    logic [31:0] swizzle;
    logic [31:0] next;
  } apu_vgpu_sv_t;

  typedef enum logic [1:0] {
    APU_VGPU_SS_OK    = 2'd0,
    APU_VGPU_SS_EMPTY = 2'd1,
    APU_VGPU_SS_FAULT = 2'd2
  } apu_vgpu_ss_status_e;

  typedef struct packed {
    apu_vgpu_ss_status_e status;
  } apu_vgpu_ss_cpl_t;

  // One sampler state after the sampler view. This is not a texture fetch.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] s0;
    logic [31:0] max_lod;
    logic [31:0] next;
  } apu_vgpu_ss_t;

  typedef enum logic [1:0] {
    APU_VGPU_BL_OK    = 2'd0,
    APU_VGPU_BL_EMPTY = 2'd1,
    APU_VGPU_BL_FAULT = 2'd2
  } apu_vgpu_bl_status_e;

  typedef struct packed {
    apu_vgpu_bl_status_e status;
  } apu_vgpu_bl_cpl_t;

  // One blend object. Color buffer 0 only. This is not a draw.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] s2;
    logic [31:0] next;
  } apu_vgpu_bl_t;

  typedef enum logic [1:0] {
    APU_VGPU_DS_OK    = 2'd0,
    APU_VGPU_DS_EMPTY = 2'd1,
    APU_VGPU_DS_FAULT = 2'd2
  } apu_vgpu_ds_status_e;

  typedef struct packed {
    apu_vgpu_ds_status_e status;
  } apu_vgpu_ds_cpl_t;

  // One depth-stencil object. Depth and stencil are off. This is not a draw.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] next;
  } apu_vgpu_ds_t;

  typedef enum logic [1:0] {
    APU_VGPU_RZ_OK    = 2'd0,
    APU_VGPU_RZ_EMPTY = 2'd1,
    APU_VGPU_RZ_FAULT = 2'd2
  } apu_vgpu_rz_status_e;

  typedef struct packed {
    apu_vgpu_rz_status_e status;
  } apu_vgpu_rz_cpl_t;

  // One rasterizer object. Fill both faces and cull none. This is not a draw.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] next;
  } apu_vgpu_rz_t;

  typedef enum logic [1:0] {
    APU_VGPU_BB_OK    = 2'd0,
    APU_VGPU_BB_EMPTY = 2'd1,
    APU_VGPU_BB_FAULT = 2'd2
  } apu_vgpu_bb_status_e;

  typedef struct packed {
    apu_vgpu_bb_status_e status;
  } apu_vgpu_bb_cpl_t;

  // The blend object named by BIND_OBJECT. This is not a draw.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] next;
  } apu_vgpu_bb_t;

  typedef enum logic [1:0] {
    APU_VGPU_DB_OK    = 2'd0,
    APU_VGPU_DB_EMPTY = 2'd1,
    APU_VGPU_DB_FAULT = 2'd2
  } apu_vgpu_db_status_e;

  typedef struct packed {
    apu_vgpu_db_status_e status;
  } apu_vgpu_db_cpl_t;

  // The depth-stencil object named by BIND_OBJECT. Depth stays off.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] next;
  } apu_vgpu_db_t;

  typedef enum logic [1:0] {
    APU_VGPU_RB_OK    = 2'd0,
    APU_VGPU_RB_EMPTY = 2'd1,
    APU_VGPU_RB_FAULT = 2'd2
  } apu_vgpu_rb_status_e;

  typedef struct packed {
    apu_vgpu_rb_status_e status;
  } apu_vgpu_rb_cpl_t;

  // The rasterizer object named by BIND_OBJECT. This does not walk a triangle.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] next;
  } apu_vgpu_rb_t;

  typedef enum logic [1:0] {
    APU_VGPU_VSB_OK    = 2'd0,
    APU_VGPU_VSB_EMPTY = 2'd1,
    APU_VGPU_VSB_FAULT = 2'd2
  } apu_vgpu_vsb_status_e;

  typedef struct packed {
    apu_vgpu_vsb_status_e status;
  } apu_vgpu_vsb_cpl_t;

  // Vertex shader named by BIND_SHADER. The text stays in the buffer.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [7:0] stage;
    logic [31:0] next;
  } apu_vgpu_vsb_t;

  typedef enum logic [1:0] {
    APU_VGPU_FSB_OK    = 2'd0,
    APU_VGPU_FSB_EMPTY = 2'd1,
    APU_VGPU_FSB_FAULT = 2'd2
  } apu_vgpu_fsb_status_e;

  typedef struct packed {
    apu_vgpu_fsb_status_e status;
  } apu_vgpu_fsb_cpl_t;

  // Fragment shader named by BIND_SHADER. The text stays in the buffer.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [7:0] stage;
    logic [31:0] next;
  } apu_vgpu_fsb_t;

  typedef enum logic [1:0] {
    APU_VGPU_VEB_OK    = 2'd0,
    APU_VGPU_VEB_EMPTY = 2'd1,
    APU_VGPU_VEB_FAULT = 2'd2
  } apu_vgpu_veb_status_e;

  typedef struct packed {
    apu_vgpu_veb_status_e status;
  } apu_vgpu_veb_cpl_t;

  // Vertex elements named by BIND_OBJECT. This is not a draw.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] next;
  } apu_vgpu_veb_t;

  typedef enum logic [1:0] {
    APU_VGPU_SSB_OK    = 2'd0,
    APU_VGPU_SSB_EMPTY = 2'd1,
    APU_VGPU_SSB_FAULT = 2'd2
  } apu_vgpu_ssb_status_e;

  typedef struct packed {
    apu_vgpu_ssb_status_e status;
  } apu_vgpu_ssb_cpl_t;

  // Sampler state bound on fragment slot 0. This is not a texture fetch.
  typedef struct packed {
    logic valid;
    logic [7:0] stage;
    logic [31:0] slot;
    logic [31:0] handle;
    logic [31:0] next;
  } apu_vgpu_ssb_t;

  typedef enum logic [1:0] {
    APU_VGPU_SVB_OK    = 2'd0,
    APU_VGPU_SVB_EMPTY = 2'd1,
    APU_VGPU_SVB_FAULT = 2'd2
  } apu_vgpu_svb_status_e;

  typedef struct packed {
    apu_vgpu_svb_status_e status;
  } apu_vgpu_svb_cpl_t;

  // Sampler view set on fragment slot 0. This is not a texture fetch.
  typedef struct packed {
    logic valid;
    logic [7:0] stage;
    logic [31:0] slot;
    logic [31:0] handle;
    logic [31:0] next;
  } apu_vgpu_svb_t;

  typedef enum logic [1:0] {
    APU_VGPU_IW_OK    = 2'd0,
    APU_VGPU_IW_EMPTY = 2'd1,
    APU_VGPU_IW_FAULT = 2'd2
  } apu_vgpu_iw_status_e;

  typedef struct packed {
    apu_vgpu_iw_status_e status;
  } apu_vgpu_iw_cpl_t;

  // Vertex inline write. The floats stay in the execbuffer.
  typedef struct packed {
    logic valid;
    logic [31:0] resource;
    logic [31:0] nbytes;
    logic [31:0] next;
  } apu_vgpu_iw_t;

  typedef enum logic [1:0] {
    APU_VGPU_VB_OK    = 2'd0,
    APU_VGPU_VB_EMPTY = 2'd1,
    APU_VGPU_VB_FAULT = 2'd2
  } apu_vgpu_vb_status_e;

  typedef struct packed {
    apu_vgpu_vb_status_e status;
  } apu_vgpu_vb_cpl_t;

  // Vertex buffer 0. This is not a vertex fetch.
  typedef struct packed {
    logic valid;
    logic [31:0] stride;
    logic [31:0] offset;
    logic [31:0] resource;
    logic [31:0] next;
  } apu_vgpu_vb_t;

  typedef enum logic [1:0] {
    APU_VGPU_SCI_OK    = 2'd0,
    APU_VGPU_SCI_EMPTY = 2'd1,
    APU_VGPU_SCI_FAULT = 2'd2
  } apu_vgpu_sci_status_e;

  typedef struct packed {
    apu_vgpu_sci_status_e status;
  } apu_vgpu_sci_cpl_t;

  // Scissor of the 640 by 480 execbuffer. This is not a draw.
  typedef struct packed {
    logic valid;
    logic [15:0] width;
    logic [15:0] height;
    logic [31:0] next;
  } apu_vgpu_sci_t;

  typedef enum logic [1:0] {
    APU_VGPU_VP_OK    = 2'd0,
    APU_VGPU_VP_EMPTY = 2'd1,
    APU_VGPU_VP_FAULT = 2'd2
  } apu_vgpu_vp_status_e;

  typedef struct packed {
    apu_vgpu_vp_status_e status;
  } apu_vgpu_vp_cpl_t;

  // Viewport scale of the 640 by 480 execbuffer. This is not a transform.
  typedef struct packed {
    logic valid;
    logic [31:0] scale_x;
    logic [31:0] scale_y;
    logic [31:0] next;
  } apu_vgpu_vp_t;

  typedef enum logic [1:0] {
    APU_VGPU_FBO_OK    = 2'd0,
    APU_VGPU_FBO_EMPTY = 2'd1,
    APU_VGPU_FBO_FAULT = 2'd2
  } apu_vgpu_fbo_status_e;

  typedef struct packed {
    apu_vgpu_fbo_status_e status;
  } apu_vgpu_fbo_cpl_t;

  // Framebuffer state naming the surface. This does not attach memory.
  typedef struct packed {
    logic valid;
    logic [31:0] nr_cbufs;
    logic [31:0] surface;
    logic [31:0] next;
  } apu_vgpu_fbo_t;

  typedef enum logic [1:0] {
    APU_VGPU_CLR_OK    = 2'd0,
    APU_VGPU_CLR_EMPTY = 2'd1,
    APU_VGPU_CLR_FAULT = 2'd2
  } apu_vgpu_clr_status_e;

  typedef struct packed {
    apu_vgpu_clr_status_e status;
  } apu_vgpu_clr_cpl_t;

  // Clear color of the frozen execbuffer. This does not write pixels.
  typedef struct packed {
    logic valid;
    logic [31:0] buffers;
    logic [31:0] red;
    logic [31:0] green;
    logic [31:0] blue;
    logic [31:0] alpha;
    logic [31:0] next;
  } apu_vgpu_clr_t;

  typedef enum logic [1:0] {
    APU_VGPU_DRW_OK    = 2'd0,
    APU_VGPU_DRW_EMPTY = 2'd1,
    APU_VGPU_DRW_FAULT = 2'd2
  } apu_vgpu_drw_status_e;

  typedef struct packed {
    apu_vgpu_drw_status_e status;
  } apu_vgpu_drw_cpl_t;

  // Draw of the four-vertex strip. This does not walk a triangle.
  typedef struct packed {
    logic valid;
    logic [31:0] count;
    logic [31:0] prim;
    logic [31:0] next;
  } apu_vgpu_drw_t;

  typedef enum logic [1:0] {
    APU_VGPU_CTX_OK    = 2'd0,
    APU_VGPU_CTX_EMPTY = 2'd1,
    APU_VGPU_CTX_FAULT = 2'd2
  } apu_vgpu_ctx_status_e;

  typedef struct packed {
    apu_vgpu_ctx_status_e status;
  } apu_vgpu_ctx_cpl_t;

  // CTX_CREATE for context 1, debug name "main". Not an OS context.
  typedef struct packed {
    logic valid;
    logic [31:0] ctx_id;
    logic [31:0] next;
  } apu_vgpu_ctx_t;

  typedef enum logic [1:0] {
    APU_VGPU_C3D_OK    = 2'd0,
    APU_VGPU_C3D_EMPTY = 2'd1,
    APU_VGPU_C3D_FAULT = 2'd2
  } apu_vgpu_c3d_status_e;

  typedef struct packed {
    apu_vgpu_c3d_status_e status;
  } apu_vgpu_c3d_cpl_t;

  // RESOURCE_CREATE_3D for the render target and the vertex buffer.
  // This does not allocate memory.
  typedef struct packed {
    logic rt_valid;
    logic vbo_valid;
    logic [31:0] rt_w;
    logic [31:0] rt_h;
    logic [31:0] vbo_bytes;
    logic [31:0] next;
  } apu_vgpu_c3d_t;

  typedef enum logic [1:0] {
    APU_VGPU_ATT_OK    = 2'd0,
    APU_VGPU_ATT_EMPTY = 2'd1,
    APU_VGPU_ATT_FAULT = 2'd2
  } apu_vgpu_att_status_e;

  typedef struct packed {
    apu_vgpu_att_status_e status;
  } apu_vgpu_att_cpl_t;

  // CTX_ATTACH of the render target, the vertex buffer, and resource 1.
  // This does not map guest memory.
  typedef struct packed {
    logic rt;
    logic vbo;
    logic scan;
    logic [31:0] next;
  } apu_vgpu_att_t;

  typedef enum logic [1:0] {
    APU_VGPU_RSP_OK    = 2'd0,
    APU_VGPU_RSP_EMPTY = 2'd1,
    APU_VGPU_RSP_FAULT = 2'd2,
    APU_VGPU_RSP_BUS   = 2'd3
  } apu_vgpu_rsp_status_e;

  typedef struct packed {
    apu_vgpu_rsp_status_e status;
    logic [63:0] addr;
    logic [31:0] ctx_id;
  } apu_vgpu_rsp_cpl_t;

  // The 24-byte submit response. This does not store a pixel.
  typedef struct packed {
    logic valid;
    logic [63:0] addr;
    logic [31:0] ctx_id;
    logic [63:0] fence;
  } apu_vgpu_rsp_t;

  typedef enum logic [1:0] {
    APU_VGPU_NFO_OK    = 2'd0,
    APU_VGPU_NFO_EMPTY = 2'd1,
    APU_VGPU_NFO_FAULT = 2'd2
  } apu_vgpu_nfo_status_e;

  typedef struct packed {
    apu_vgpu_nfo_status_e status;
  } apu_vgpu_nfo_cpl_t;

  // GET_CAPSET_INFO index 0. refused means the answer is no capset.
  typedef struct packed {
    logic refused;
    logic [31:0] resp;
    logic [31:0] next;
  } apu_vgpu_nfo_t;

  typedef enum logic [1:0] {
    APU_VGPU_CAP_OK    = 2'd0,
    APU_VGPU_CAP_EMPTY = 2'd1,
    APU_VGPU_CAP_FAULT = 2'd2
  } apu_vgpu_cap_status_e;

  typedef struct packed {
    apu_vgpu_cap_status_e status;
  } apu_vgpu_cap_cpl_t;

  // GET_CAPSET for virgl version 1. refused means no blob is returned.
  typedef struct packed {
    logic refused;
    logic [31:0] resp;
    logic [31:0] next;
  } apu_vgpu_cap_t;

  typedef enum logic [1:0] {
    APU_VGPU_SCN_OK    = 2'd0,
    APU_VGPU_SCN_EMPTY = 2'd1,
    APU_VGPU_SCN_FAULT = 2'd2
  } apu_vgpu_scn_status_e;

  typedef struct packed {
    apu_vgpu_scn_status_e status;
  } apu_vgpu_scn_cpl_t;

  // SET_SCANOUT of resource 4 at 640 by 480. This is not a HDMI mode.
  typedef struct packed {
    logic valid;
    logic [31:0] scanout_id;
    logic [31:0] resource_id;
    logic [31:0] width;
    logic [31:0] height;
    logic [31:0] next;
  } apu_vgpu_scn_t;

  typedef enum logic [1:0] {
    APU_VGPU_FLU_OK    = 2'd0,
    APU_VGPU_FLU_EMPTY = 2'd1,
    APU_VGPU_FLU_FAULT = 2'd2
  } apu_vgpu_flu_status_e;

  typedef struct packed {
    apu_vgpu_flu_status_e status;
  } apu_vgpu_flu_cpl_t;

  // RESOURCE_FLUSH of that scanout rectangle. This does not present a frame.
  typedef struct packed {
    logic valid;
    logic [31:0] resource_id;
    logic [31:0] width;
    logic [31:0] height;
    logic [31:0] next;
  } apu_vgpu_flu_t;

  typedef enum logic [1:0] {
    APU_VGPU_CHN_POST  = 2'd0,
    APU_VGPU_CHN_AVAIL = 2'd1,
    APU_VGPU_CHN_WALK  = 2'd2
  } apu_vgpu_chn_op_e;

  typedef struct packed {
    apu_vgpu_chn_op_e op;
    logic [15:0] avail_idx;
    logic [15:0] desc_id;
    apu_vgpu_desc_t desc;
  } apu_vgpu_chn_req_t;

  typedef enum logic [1:0] {
    APU_VGPU_CHN_OK    = 2'd0,
    APU_VGPU_CHN_EMPTY = 2'd1,
    APU_VGPU_CHN_FAULT = 2'd2
  } apu_vgpu_chn_status_e;

  typedef struct packed {
    apu_vgpu_chn_status_e status;
  } apu_vgpu_chn_cpl_t;

  // One accepted scene chain. Head is descriptor 0. This does not read
  // guest memory and it is not g6lc_apu_vgpu_avail.
  typedef struct packed {
    logic valid;
    logic [15:0] head;
    logic [31:0] buf_len;
    logic [63:0] buf_addr;
    logic [63:0] rsp_addr;
    logic [15:0] device_idx;
  } apu_vgpu_chn_t;

  typedef enum logic [1:0] {
    APU_VGPU_CMX_OK    = 2'd0,
    APU_VGPU_CMX_EMPTY = 2'd1,
    APU_VGPU_CMX_FAULT = 2'd2
  } apu_vgpu_cmx_status_e;

  typedef struct packed {
    apu_vgpu_cmx_status_e status;
  } apu_vgpu_cmx_cpl_t;

  // The chain, the submit record, and the response name the same buffer.
  typedef struct packed {
    logic linked;
  } apu_vgpu_cmx_t;

  typedef enum logic [1:0] {
    APU_VGPU_SUN_OK    = 2'd0,
    APU_VGPU_SUN_EMPTY = 2'd1,
    APU_VGPU_SUN_FAULT = 2'd2
  } apu_vgpu_sun_status_e;

  typedef struct packed {
    apu_vgpu_sun_status_e status;
  } apu_vgpu_sun_cpl_t;

  // Local used element for descriptor 0, length 24. Not a guest store
  // and not g6lc_apu_vgpu_used.
  typedef struct packed {
    logic valid;
    logic [15:0] idx;
    logic [31:0] desc_id;
    logic [31:0] len;
  } apu_vgpu_sun_t;

  typedef enum logic [1:0] {
    APU_VGPU_SUW_OK    = 2'd0,
    APU_VGPU_SUW_EMPTY = 2'd1,
    APU_VGPU_SUW_FAULT = 2'd2,
    APU_VGPU_SUW_BUS   = 2'd3
  } apu_vgpu_suw_status_e;

  typedef struct packed {
    apu_vgpu_suw_status_e status;
    logic [31:0] elem_id;
    logic [31:0] elem_len;
    logic [63:0] addr;
  } apu_vgpu_suw_cpl_t;

  // Guest store of the scene used element. Not g6lc_apu_vgpu_uwr.
  typedef struct packed {
    logic wrote;
    logic [63:0] addr;
  } apu_vgpu_suw_t;

  typedef enum logic [1:0] {
    APU_VGPU_SUX_OK    = 2'd0,
    APU_VGPU_SUX_EMPTY = 2'd1,
    APU_VGPU_SUX_FAULT = 2'd2,
    APU_VGPU_SUX_BUS   = 2'd3
  } apu_vgpu_sux_status_e;

  typedef struct packed {
    apu_vgpu_sux_status_e status;
    logic [15:0] idx;
    logic [63:0] addr;
  } apu_vgpu_sux_cpl_t;

  // Guest store of the scene used.idx. Not g6lc_apu_vgpu_uidx.
  typedef struct packed {
    logic wrote;
    logic [15:0] idx;
    logic [63:0] addr;
  } apu_vgpu_sux_t;

  typedef enum logic [1:0] {
    APU_VGPU_U8_OK    = 2'd0,
    APU_VGPU_U8_EMPTY = 2'd1,
    APU_VGPU_U8_FAULT = 2'd2
  } apu_vgpu_u8_status_e;

  typedef struct packed {
    apu_vgpu_u8_status_e status;
  } apu_vgpu_u8_cpl_t;

  // RGBA8 bytes of the frozen clear. Not a stored pixel.
  typedef struct packed {
    logic valid;
    logic [7:0] red;
    logic [7:0] green;
    logic [7:0] blue;
    logic [7:0] alpha;
    logic [31:0] word;
  } apu_vgpu_u8_t;

  typedef enum logic [1:0] {
    APU_VGPU_PIX_OK    = 2'd0,
    APU_VGPU_PIX_EMPTY = 2'd1,
    APU_VGPU_PIX_FAULT = 2'd2
  } apu_vgpu_pix_status_e;

  typedef struct packed {
    apu_vgpu_pix_status_e status;
  } apu_vgpu_pix_cpl_t;

  // Four corner samples. The interior is not written.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [13:0] a00;
    logic [13:0] ax;
    logic [13:0] ay;
    logic [13:0] axy;
  } apu_vgpu_pix_t;

  typedef enum logic [1:0] {
    APU_VGPU_PXR_OK    = 2'd0,
    APU_VGPU_PXR_EMPTY = 2'd1,
    APU_VGPU_PXR_MISS  = 2'd2,
    APU_VGPU_PXR_FAULT = 2'd3
  } apu_vgpu_pxr_status_e;

  typedef struct packed {
    apu_vgpu_pxr_status_e status;
    logic [31:0] word;
    logic [13:0] addr;
  } apu_vgpu_pxr_cpl_t;

  typedef enum logic [1:0] {
    APU_VGPU_FIL_OK    = 2'd0,
    APU_VGPU_FIL_EMPTY = 2'd1,
    APU_VGPU_FIL_FAULT = 2'd2
  } apu_vgpu_fil_status_e;

  typedef struct packed {
    apu_vgpu_fil_status_e status;
  } apu_vgpu_fil_cpl_t;

  // The clear word covers the ceiling. Samples are not stored one by one.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [31:0] samples;
  } apu_vgpu_fil_t;

  typedef enum logic [1:0] {
    APU_VGPU_FRD_OK    = 2'd0,
    APU_VGPU_FRD_EMPTY = 2'd1,
    APU_VGPU_FRD_FAULT = 2'd2
  } apu_vgpu_frd_status_e;

  typedef struct packed {
    apu_vgpu_frd_status_e status;
    logic [31:0] word;
    logic [13:0] addr;
  } apu_vgpu_frd_cpl_t;

  typedef enum logic [1:0] {
    APU_VGPU_QD_OK    = 2'd0,
    APU_VGPU_QD_EMPTY = 2'd1,
    APU_VGPU_QD_FAULT = 2'd2
  } apu_vgpu_qd_status_e;

  typedef struct packed {
    apu_vgpu_qd_status_e status;
  } apu_vgpu_qd_cpl_t;

  // The fullscreen NDC strip. Positions were checked. Not a transform.
  typedef struct packed {
    logic valid;
  } apu_vgpu_qd_t;

  typedef enum logic [1:0] {
    APU_VGPU_CV_OK    = 2'd0,
    APU_VGPU_CV_EMPTY = 2'd1,
    APU_VGPU_CV_FAULT = 2'd2
  } apu_vgpu_cv_status_e;

  typedef struct packed {
    apu_vgpu_cv_status_e status;
  } apu_vgpu_cv_cpl_t;

  // The strip covers the ceiling. The stored color is still the clear.
  typedef struct packed {
    logic valid;
    logic covered;
    logic [31:0] word;
    logic [31:0] samples;
  } apu_vgpu_cv_t;

  typedef enum logic [1:0] {
    APU_VGPU_CVR_OK    = 2'd0,
    APU_VGPU_CVR_EMPTY = 2'd1,
    APU_VGPU_CVR_FAULT = 2'd2
  } apu_vgpu_cvr_status_e;

  typedef struct packed {
    apu_vgpu_cvr_status_e status;
    logic covered;
    logic [31:0] word;
    logic [13:0] addr;
  } apu_vgpu_cvr_cpl_t;

  typedef enum logic [1:0] {
    APU_VGPU_VST_OK    = 2'd0,
    APU_VGPU_VST_EMPTY = 2'd1,
    APU_VGPU_VST_FAULT = 2'd2
  } apu_vgpu_vst_status_e;

  typedef struct packed {
    apu_vgpu_vst_status_e status;
  } apu_vgpu_vst_cpl_t;

  // The vertex shader text matched. The text is not stored here.
  typedef struct packed {
    logic valid;
  } apu_vgpu_vst_t;

  typedef enum logic [1:0] {
    APU_VGPU_FST_OK    = 2'd0,
    APU_VGPU_FST_EMPTY = 2'd1,
    APU_VGPU_FST_FAULT = 2'd2
  } apu_vgpu_fst_status_e;

  typedef struct packed {
    apu_vgpu_fst_status_e status;
  } apu_vgpu_fst_cpl_t;

  // The fragment shader text matched. tex means that text is the TEX program.
  typedef struct packed {
    logic valid;
    logic tex;
  } apu_vgpu_fst_t;

  typedef enum logic [1:0] {
    APU_VGPU_HLD_OK    = 2'd0,
    APU_VGPU_HLD_EMPTY = 2'd1,
    APU_VGPU_HLD_FAULT = 2'd2
  } apu_vgpu_hld_status_e;

  typedef struct packed {
    apu_vgpu_hld_status_e status;
    logic held;
    logic [31:0] word;
    logic [13:0] addr;
  } apu_vgpu_hld_cpl_t;

  typedef enum logic [1:0] {
    APU_VGPU_TBN_OK    = 2'd0,
    APU_VGPU_TBN_EMPTY = 2'd1,
    APU_VGPU_TBN_FAULT = 2'd2
  } apu_vgpu_tbn_status_e;

  typedef struct packed {
    apu_vgpu_tbn_status_e status;
  } apu_vgpu_tbn_cpl_t;

  // TEX names this sampler view and sampler state. Not a fetch.
  typedef struct packed {
    logic valid;
    logic [31:0] resource_id;
    logic [31:0] view;
    logic [31:0] sampler;
  } apu_vgpu_tbn_t;

  typedef enum logic [1:0] {
    APU_VGPU_DEN_OK    = 2'd0,
    APU_VGPU_DEN_EMPTY = 2'd1,
    APU_VGPU_DEN_FAULT = 2'd2
  } apu_vgpu_den_status_e;

  typedef struct packed {
    apu_vgpu_den_status_e status;
  } apu_vgpu_den_cpl_t;

  // Resource 1 has no texel image here. The word stays the clear.
  typedef struct packed {
    logic valid;
    logic refused;
    logic [31:0] resource_id;
    logic [31:0] word;
    logic [31:0] samples;
  } apu_vgpu_den_t;

  typedef enum logic [1:0] {
    APU_VGPU_DNR_OK    = 2'd0,
    APU_VGPU_DNR_EMPTY = 2'd1,
    APU_VGPU_DNR_FAULT = 2'd2
  } apu_vgpu_dnr_status_e;

  typedef struct packed {
    apu_vgpu_dnr_status_e status;
    logic refused;
    logic [31:0] word;
    logic [13:0] addr;
  } apu_vgpu_dnr_cpl_t;

  typedef enum logic [1:0] {
    APU_VGPU_S2D_OK    = 2'd0,
    APU_VGPU_S2D_EMPTY = 2'd1,
    APU_VGPU_S2D_FAULT = 2'd2
  } apu_vgpu_s2d_status_e;

  typedef struct packed {
    apu_vgpu_s2d_status_e status;
  } apu_vgpu_s2d_cpl_t;

  // Resource 1 exists as a 640 by 480 image. No pixels are stored.
  typedef struct packed {
    logic valid;
    logic [31:0] resource_id;
    logic [31:0] format;
    logic [15:0] width;
    logic [15:0] height;
  } apu_vgpu_s2d_t;

  typedef enum logic [1:0] {
    APU_VGPU_SBK_OK    = 2'd0,
    APU_VGPU_SBK_EMPTY = 2'd1,
    APU_VGPU_SBK_FAULT = 2'd2
  } apu_vgpu_sbk_status_e;

  typedef struct packed {
    apu_vgpu_sbk_status_e status;
  } apu_vgpu_sbk_cpl_t;

  // One backing entry for resource 1. The bytes are not read.
  typedef struct packed {
    logic valid;
    logic [31:0] resource_id;
    logic [31:0] addr;
    logic [31:0] length;
  } apu_vgpu_sbk_t;

  typedef enum logic [1:0] {
    APU_VGPU_SXF_OK    = 2'd0,
    APU_VGPU_SXF_EMPTY = 2'd1,
    APU_VGPU_SXF_FAULT = 2'd2
  } apu_vgpu_sxf_status_e;

  typedef struct packed {
    apu_vgpu_sxf_status_e status;
  } apu_vgpu_sxf_cpl_t;

  // The top 64 rows were named. copied is 0. The color stays the clear.
  typedef struct packed {
    logic valid;
    logic copied;
    logic [15:0] width;
    logic [15:0] height;
    logic [31:0] word;
  } apu_vgpu_sxf_t;

  typedef enum logic [1:0] {
    APU_VGPU_SSC_OK    = 2'd0,
    APU_VGPU_SSC_EMPTY = 2'd1,
    APU_VGPU_SSC_FAULT = 2'd2
  } apu_vgpu_ssc_status_e;

  typedef struct packed {
    apu_vgpu_ssc_status_e status;
  } apu_vgpu_ssc_cpl_t;

  // Scanout 0 names resource 1 at 640 by 480. Nothing is presented.
  typedef struct packed {
    logic valid;
    logic shown;
    logic [31:0] scanout_id;
    logic [31:0] resource_id;
    logic [15:0] width;
    logic [15:0] height;
  } apu_vgpu_ssc_t;

  typedef enum logic [1:0] {
    APU_VGPU_SFL_OK    = 2'd0,
    APU_VGPU_SFL_EMPTY = 2'd1,
    APU_VGPU_SFL_FAULT = 2'd2
  } apu_vgpu_sfl_status_e;

  typedef struct packed {
    apu_vgpu_sfl_status_e status;
  } apu_vgpu_sfl_cpl_t;

  // Flush of the 640 by 64 band. Nothing is presented.
  typedef struct packed {
    logic valid;
    logic shown;
    logic [31:0] resource_id;
    logic [15:0] width;
    logic [15:0] height;
  } apu_vgpu_sfl_t;

  typedef enum logic [1:0] {
    APU_VGPU_SPR_OK    = 2'd0,
    APU_VGPU_SPR_EMPTY = 2'd1,
    APU_VGPU_SPR_FAULT = 2'd2
  } apu_vgpu_spr_status_e;

  typedef struct packed {
    apu_vgpu_spr_status_e status;
    logic shown;
    logic [31:0] word;
    logic [13:0] addr;
  } apu_vgpu_spr_cpl_t;

  typedef enum logic [1:0] {
    APU_VGPU_BCP_OK    = 2'd0,
    APU_VGPU_BCP_EMPTY = 2'd1,
    APU_VGPU_BCP_FAULT = 2'd2
  } apu_vgpu_bcp_status_e;

  typedef struct packed {
    apu_vgpu_bcp_status_e status;
  } apu_vgpu_bcp_cpl_t;

  // The band was read. The image is not stored. word is beat 0 only.
  typedef struct packed {
    logic valid;
    logic [12:0] beats;
    logic [31:0] bytes;
    logic [31:0] word;
  } apu_vgpu_bcp_t;

  typedef enum logic [1:0] {
    APU_VGPU_BCR_OK    = 2'd0,
    APU_VGPU_BCR_EMPTY = 2'd1,
    APU_VGPU_BCR_FAULT = 2'd2
  } apu_vgpu_bcr_status_e;

  typedef struct packed {
    apu_vgpu_bcr_status_e status;
    logic [12:0] beats;
    logic [31:0] word;
    logic [31:0] scene;
  } apu_vgpu_bcr_cpl_t;

  typedef enum logic [1:0] {
    APU_VGPU_TAP_OK    = 2'd0,
    APU_VGPU_TAP_EMPTY = 2'd1,
    APU_VGPU_TAP_FAULT = 2'd2
  } apu_vgpu_tap_status_e;

  typedef struct packed {
    apu_vgpu_tap_status_e status;
  } apu_vgpu_tap_cpl_t;

  // One texel inside the copied band. x is clamped to 639.
  typedef struct packed {
    logic valid;
    logic [9:0] x;
    logic [5:0] y;
    logic [31:0] word;
  } apu_vgpu_tap_t;

  typedef enum logic [1:0] {
    APU_VGPU_PXC_OK    = 2'd0,
    APU_VGPU_PXC_EMPTY = 2'd1,
    APU_VGPU_PXC_FAULT = 2'd2
  } apu_vgpu_pxc_status_e;

  typedef struct packed {
    apu_vgpu_pxc_status_e status;
  } apu_vgpu_pxc_cpl_t;

  // Ceiling pixel (0,0) holds the corner texel.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
  } apu_vgpu_pxc_t;

  typedef enum logic [1:0] {
    APU_VGPU_PXQ_OK    = 2'd0,
    APU_VGPU_PXQ_EMPTY = 2'd1,
    APU_VGPU_PXQ_FAULT = 2'd2
  } apu_vgpu_pxq_status_e;

  typedef struct packed {
    apu_vgpu_pxq_status_e status;
    logic replaced;
    logic [31:0] word;
    logic [13:0] addr;
  } apu_vgpu_pxq_cpl_t;

  typedef enum logic [1:0] {
    APU_VGPU_LIN_OK    = 2'd0,
    APU_VGPU_LIN_EMPTY = 2'd1,
    APU_VGPU_LIN_FAULT = 2'd2
  } apu_vgpu_lin_status_e;

  typedef struct packed {
    apu_vgpu_lin_status_e status;
  } apu_vgpu_lin_cpl_t;

  // One horizontal blend on row 0. x = 0 is texel 0. x = 1..7 blends
  // texel x-1 with texel x.
  typedef struct packed {
    logic valid;
    logic [2:0] x;
    logic [31:0] word;
  } apu_vgpu_lin_t;

  typedef enum logic [1:0] {
    APU_VGPU_LNR_OK    = 2'd0,
    APU_VGPU_LNR_EMPTY = 2'd1,
    APU_VGPU_LNR_FAULT = 2'd2
  } apu_vgpu_lnr_status_e;

  typedef struct packed {
    apu_vgpu_lnr_status_e status;
  } apu_vgpu_lnr_cpl_t;

  // The origin texel and the blended neighbor at x = 1.
  typedef struct packed {
    logic valid;
    logic [31:0] origin;
    logic [31:0] neighbor;
  } apu_vgpu_lnr_t;

  typedef enum logic [1:0] {
    APU_VGPU_SPN_OK    = 2'd0,
    APU_VGPU_SPN_EMPTY = 2'd1,
    APU_VGPU_SPN_FAULT = 2'd2
  } apu_vgpu_spn_status_e;

  typedef struct packed {
    apu_vgpu_spn_status_e status;
  } apu_vgpu_spn_cpl_t;

  // A row-0 blend whose taps may sit in beat 0 and beat 1.
  typedef struct packed {
    logic valid;
    logic [3:0] x;
    logic [31:0] word;
  } apu_vgpu_spn_t;

  typedef enum logic [1:0] {
    APU_VGPU_SPX_OK    = 2'd0,
    APU_VGPU_SPX_EMPTY = 2'd1,
    APU_VGPU_SPX_FAULT = 2'd2
  } apu_vgpu_spx_status_e;

  typedef struct packed {
    apu_vgpu_spx_status_e status;
  } apu_vgpu_spx_cpl_t;

  // The x = 8 sample. (0,0) and (1,0) stay the earlier words.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
  } apu_vgpu_spx_t;

  typedef enum logic [1:0] {
    APU_VGPU_VLN_OK    = 2'd0,
    APU_VGPU_VLN_EMPTY = 2'd1,
    APU_VGPU_VLN_FAULT = 2'd2
  } apu_vgpu_vln_status_e;

  typedef struct packed {
    apu_vgpu_vln_status_e status;
  } apu_vgpu_vln_cpl_t;

  // y = 1 blends row 0 with row 1 at one half. x is 0 or 1.
  typedef struct packed {
    logic valid;
    logic [1:0] x;
    logic [31:0] word;
  } apu_vgpu_vln_t;

  typedef enum logic [1:0] {
    APU_VGPU_VLR_OK    = 2'd0,
    APU_VGPU_VLR_EMPTY = 2'd1,
    APU_VGPU_VLR_FAULT = 2'd2
  } apu_vgpu_vlr_status_e;

  typedef struct packed {
    apu_vgpu_vlr_status_e status;
  } apu_vgpu_vlr_cpl_t;

  // The two y = 1 samples. Row 0 stays the earlier words.
  typedef struct packed {
    logic valid;
    logic [31:0] at0;
    logic [31:0] at1;
  } apu_vgpu_vlr_t;

  typedef enum logic [1:0] {
    APU_VGPU_VBX_OK    = 2'd0,
    APU_VGPU_VBX_EMPTY = 2'd1,
    APU_VGPU_VBX_FAULT = 2'd2
  } apu_vgpu_vbx_status_e;

  typedef struct packed {
    apu_vgpu_vbx_status_e status;
  } apu_vgpu_vbx_cpl_t;

  // y = 1, x = 0..7. Both taps stay in beat 0 of row 0 and of row 1.
  typedef struct packed {
    logic valid;
    logic [2:0] x;
    logic [31:0] word;
  } apu_vgpu_vbx_t;

  typedef enum logic [1:0] {
    APU_VGPU_VBR_OK    = 2'd0,
    APU_VGPU_VBR_EMPTY = 2'd1,
    APU_VGPU_VBR_FAULT = 2'd2
  } apu_vgpu_vbr_status_e;

  typedef struct packed {
    apu_vgpu_vbr_status_e status;
  } apu_vgpu_vbr_cpl_t;

  // The y = 1 sample at x = 2. The x = 0 and x = 1 pair stays put.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
  } apu_vgpu_vbr_t;

  typedef enum logic [1:0] {
    APU_VGPU_VSP_OK    = 2'd0,
    APU_VGPU_VSP_EMPTY = 2'd1,
    APU_VGPU_VSP_FAULT = 2'd2
  } apu_vgpu_vsp_status_e;

  typedef struct packed {
    apu_vgpu_vsp_status_e status;
  } apu_vgpu_vsp_cpl_t;

  // y = 1, x = 0..15. x = 8 reads beat 0 and beat 1 of each row.
  typedef struct packed {
    logic valid;
    logic [3:0] x;
    logic [31:0] word;
  } apu_vgpu_vsp_t;

  typedef enum logic [1:0] {
    APU_VGPU_VSX_OK    = 2'd0,
    APU_VGPU_VSX_EMPTY = 2'd1,
    APU_VGPU_VSX_FAULT = 2'd2
  } apu_vgpu_vsx_status_e;

  typedef struct packed {
    apu_vgpu_vsx_status_e status;
  } apu_vgpu_vsx_cpl_t;

  // The y = 1 sample at x = 8. Earlier y = 1 words stay put.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
  } apu_vgpu_vsx_t;

  typedef enum logic [1:0] {
    APU_VGPU_Y2B_OK    = 2'd0,
    APU_VGPU_Y2B_EMPTY = 2'd1,
    APU_VGPU_Y2B_FAULT = 2'd2
  } apu_vgpu_y2b_status_e;

  typedef struct packed {
    apu_vgpu_y2b_status_e status;
  } apu_vgpu_y2b_cpl_t;

  // y = 2, x = 0..7. Halfway between row 1 and row 2, beat 0 only.
  typedef struct packed {
    logic valid;
    logic [2:0] x;
    logic [31:0] word;
  } apu_vgpu_y2b_t;

  typedef enum logic [1:0] {
    APU_VGPU_Y2R_OK    = 2'd0,
    APU_VGPU_Y2R_EMPTY = 2'd1,
    APU_VGPU_Y2R_FAULT = 2'd2
  } apu_vgpu_y2r_status_e;

  typedef struct packed {
    apu_vgpu_y2r_status_e status;
  } apu_vgpu_y2r_cpl_t;

  // The two y = 2 samples. The y = 1 words stay put.
  typedef struct packed {
    logic valid;
    logic [31:0] at0;
    logic [31:0] at1;
  } apu_vgpu_y2r_t;

  typedef enum logic [1:0] {
    APU_VGPU_SMP_OK    = 2'd0,
    APU_VGPU_SMP_EMPTY = 2'd1,
    APU_VGPU_SMP_FAULT = 2'd2
  } apu_vgpu_smp_status_e;

  typedef struct packed {
    apu_vgpu_smp_status_e status;
  } apu_vgpu_smp_cpl_t;

  // One ceiling sample, x and y in 0..63. The image is not stored.
  typedef struct packed {
    logic valid;
    logic [5:0] x;
    logic [5:0] y;
    logic [31:0] word;
  } apu_vgpu_smp_t;

  typedef enum logic [1:0] {
    APU_VGPU_SMX_OK    = 2'd0,
    APU_VGPU_SMX_EMPTY = 2'd1,
    APU_VGPU_SMX_FAULT = 2'd2
  } apu_vgpu_smx_status_e;

  typedef struct packed {
    apu_vgpu_smx_status_e status;
  } apu_vgpu_smx_cpl_t;

  // The ceiling sample at x = 0, y = 3.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
  } apu_vgpu_smx_t;

  typedef enum logic [1:0] {
    APU_VGPU_RBF_OK    = 2'd0,
    APU_VGPU_RBF_EMPTY = 2'd1,
    APU_VGPU_RBF_FAULT = 2'd2
  } apu_vgpu_rbf_status_e;

  typedef struct packed {
    apu_vgpu_rbf_status_e status;
  } apu_vgpu_rbf_cpl_t;

  // The 64 by 64 readback was written. The image is not kept here.
  typedef struct packed {
    logic valid;
    logic [31:0] word0;
    logic [31:0] bytes;
    logic [9:0] beats;
    logic [63:0] last_addr;
  } apu_vgpu_rbf_t;

  typedef enum logic [1:0] {
    APU_VGPU_RBK_OK    = 2'd0,
    APU_VGPU_RBK_EMPTY = 2'd1,
    APU_VGPU_RBK_FAULT = 2'd2
  } apu_vgpu_rbk_status_e;

  typedef struct packed {
    apu_vgpu_rbk_status_e status;
  } apu_vgpu_rbk_cpl_t;

  // Kept readback record. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] word0;
    logic [9:0] beats;
    logic [63:0] last_addr;
  } apu_vgpu_rbk_t;

  typedef enum logic [1:0] {
    APU_VGPU_RDR_OK    = 2'd0,
    APU_VGPU_RDR_EMPTY = 2'd1,
    APU_VGPU_RDR_FAULT = 2'd2
  } apu_vgpu_rdr_status_e;

  typedef struct packed {
    apu_vgpu_rdr_status_e status;
  } apu_vgpu_rdr_cpl_t;

  // Collected ceiling. word0 is beat 0. at03 is beat 24. Image not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] word0;
    logic [31:0] at03;
    logic [9:0] beats;
  } apu_vgpu_rdr_t;

  typedef enum logic [1:0] {
    APU_VGPU_RDK_OK    = 2'd0,
    APU_VGPU_RDK_EMPTY = 2'd1,
    APU_VGPU_RDK_FAULT = 2'd2
  } apu_vgpu_rdk_status_e;

  typedef struct packed {
    apu_vgpu_rdk_status_e status;
  } apu_vgpu_rdk_cpl_t;

  // Kept pair from the ceiling read. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] word0;
    logic [31:0] at03;
  } apu_vgpu_rdk_t;

  typedef enum logic [1:0] {
    APU_VGPU_FET_OK    = 2'd0,
    APU_VGPU_FET_EMPTY = 2'd1,
    APU_VGPU_FET_FAULT = 2'd2
  } apu_vgpu_fet_status_e;

  typedef struct packed {
    apu_vgpu_fet_status_e status;
  } apu_vgpu_fet_cpl_t;

  // Header type and the first execbuffer word. The 960 bytes are not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] kind;
    logic [31:0] cmd0;
    logic [5:0] beats;
  } apu_vgpu_fet_t;

  typedef enum logic [1:0] {
    APU_VGPU_FEK_OK    = 2'd0,
    APU_VGPU_FEK_EMPTY = 2'd1,
    APU_VGPU_FEK_FAULT = 2'd2
  } apu_vgpu_fek_status_e;

  typedef struct packed {
    apu_vgpu_fek_status_e status;
  } apu_vgpu_fek_cpl_t;

  // Kept submit type and first command. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] kind;
    logic [31:0] cmd0;
  } apu_vgpu_fek_t;

  typedef enum logic [1:0] {
    APU_VGPU_DRD_OK    = 2'd0,
    APU_VGPU_DRD_EMPTY = 2'd1,
    APU_VGPU_DRD_FAULT = 2'd2
  } apu_vgpu_drd_status_e;

  typedef struct packed {
    apu_vgpu_drd_status_e status;
  } apu_vgpu_drd_cpl_t;

  // Vertex count and primitive of the fetched DRAW_VBO. The draw is not executed.
  typedef struct packed {
    logic valid;
    logic [31:0] count;
    logic [31:0] prim;
  } apu_vgpu_drd_t;

  typedef enum logic [1:0] {
    APU_VGPU_DRK_OK    = 2'd0,
    APU_VGPU_DRK_EMPTY = 2'd1,
    APU_VGPU_DRK_FAULT = 2'd2
  } apu_vgpu_drk_status_e;

  typedef struct packed {
    apu_vgpu_drk_status_e status;
  } apu_vgpu_drk_cpl_t;

  // Kept count and primitive. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] count;
    logic [31:0] prim;
  } apu_vgpu_drk_t;

  typedef enum logic [1:0] {
    APU_VGPU_QDR_OK    = 2'd0,
    APU_VGPU_QDR_EMPTY = 2'd1,
    APU_VGPU_QDR_FAULT = 2'd2
  } apu_vgpu_qdr_status_e;

  typedef struct packed {
    apu_vgpu_qdr_status_e status;
  } apu_vgpu_qdr_cpl_t;

  // First and last float of the fetched NDC strip. The floats are not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] x0;
    logic [31:0] last;
  } apu_vgpu_qdr_t;

  typedef enum logic [1:0] {
    APU_VGPU_QDK_OK    = 2'd0,
    APU_VGPU_QDK_EMPTY = 2'd1,
    APU_VGPU_QDK_FAULT = 2'd2
  } apu_vgpu_qdk_status_e;

  typedef struct packed {
    apu_vgpu_qdk_status_e status;
  } apu_vgpu_qdk_cpl_t;

  // Kept endpoints. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] x0;
    logic [31:0] last;
  } apu_vgpu_qdk_t;

  typedef enum logic [1:0] {
    APU_VGPU_VWX_OK    = 2'd0,
    APU_VGPU_VWX_EMPTY = 2'd1,
    APU_VGPU_VWX_FAULT = 2'd2
  } apu_vgpu_vwx_status_e;

  typedef struct packed {
    apu_vgpu_vwx_status_e status;
  } apu_vgpu_vwx_cpl_t;

  // Frozen ±1 square through scales 320 and 240. Not a float multiply.
  typedef struct packed {
    logic valid;
    logic [31:0] scale_x;
    logic [31:0] scale_y;
    logic [15:0] x_neg;
    logic [15:0] y_neg;
    logic [15:0] x_pos;
    logic [15:0] y_pos;
  } apu_vgpu_vwx_t;

  typedef enum logic [1:0] {
    APU_VGPU_VWK_OK    = 2'd0,
    APU_VGPU_VWK_EMPTY = 2'd1,
    APU_VGPU_VWK_FAULT = 2'd2
  } apu_vgpu_vwk_status_e;

  typedef struct packed {
    apu_vgpu_vwk_status_e status;
  } apu_vgpu_vwk_cpl_t;

  // Kept scales and window edges. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] scale_x;
    logic [31:0] scale_y;
    logic [15:0] x_neg;
    logic [15:0] y_neg;
    logic [15:0] x_pos;
    logic [15:0] y_pos;
  } apu_vgpu_vwk_t;

  typedef enum logic [1:0] {
    APU_VGPU_CXR_OK    = 2'd0,
    APU_VGPU_CXR_EMPTY = 2'd1,
    APU_VGPU_CXR_FAULT = 2'd2
  } apu_vgpu_cxr_status_e;

  typedef struct packed {
    apu_vgpu_cxr_status_e status;
  } apu_vgpu_cxr_cpl_t;

  // Scissor box matched to the window edges. No pixel is clipped.
  typedef struct packed {
    logic valid;
    logic [15:0] width;
    logic [15:0] height;
  } apu_vgpu_cxr_t;

  typedef enum logic [1:0] {
    APU_VGPU_CXK_OK    = 2'd0,
    APU_VGPU_CXK_EMPTY = 2'd1,
    APU_VGPU_CXK_FAULT = 2'd2
  } apu_vgpu_cxk_status_e;

  typedef struct packed {
    apu_vgpu_cxk_status_e status;
  } apu_vgpu_cxk_cpl_t;

  // Kept scissor width and height. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [15:0] width;
    logic [15:0] height;
  } apu_vgpu_cxk_t;

  typedef enum logic [1:0] {
    APU_VGPU_CWR_OK    = 2'd0,
    APU_VGPU_CWR_EMPTY = 2'd1,
    APU_VGPU_CWR_FAULT = 2'd2
  } apu_vgpu_cwr_status_e;

  typedef struct packed {
    apu_vgpu_cwr_status_e status;
  } apu_vgpu_cwr_cpl_t;

  // Clear color of the fetched command. The word is not a pixel store.
  typedef struct packed {
    logic valid;
    logic [31:0] red;
    logic [31:0] blue;
    logic [31:0] word;
  } apu_vgpu_cwr_t;

  typedef enum logic [1:0] {
    APU_VGPU_CWK_OK    = 2'd0,
    APU_VGPU_CWK_EMPTY = 2'd1,
    APU_VGPU_CWK_FAULT = 2'd2
  } apu_vgpu_cwk_status_e;

  typedef struct packed {
    apu_vgpu_cwk_status_e status;
  } apu_vgpu_cwk_cpl_t;

  // Kept red, blue, and the packed word. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] red;
    logic [31:0] blue;
    logic [31:0] word;
  } apu_vgpu_cwk_t;

  typedef enum logic [1:0] {
    APU_VGPU_FBR_OK    = 2'd0,
    APU_VGPU_FBR_EMPTY = 2'd1,
    APU_VGPU_FBR_FAULT = 2'd2
  } apu_vgpu_fbr_status_e;

  typedef struct packed {
    apu_vgpu_fbr_status_e status;
  } apu_vgpu_fbr_cpl_t;

  // One color buffer, surface 1, and the accepted clear word.
  // This does not attach memory.
  typedef struct packed {
    logic valid;
    logic [31:0] nr_cbufs;
    logic [31:0] surface;
    logic [31:0] word;
  } apu_vgpu_fbr_t;

  typedef enum logic [1:0] {
    APU_VGPU_FBK_OK    = 2'd0,
    APU_VGPU_FBK_EMPTY = 2'd1,
    APU_VGPU_FBK_FAULT = 2'd2
  } apu_vgpu_fbk_status_e;

  typedef struct packed {
    apu_vgpu_fbk_status_e status;
  } apu_vgpu_fbk_cpl_t;

  // Kept buffer count, surface, and clear word. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] nr_cbufs;
    logic [31:0] surface;
    logic [31:0] word;
  } apu_vgpu_fbk_t;

  typedef enum logic [1:0] {
    APU_VGPU_VBF_OK    = 2'd0,
    APU_VGPU_VBF_EMPTY = 2'd1,
    APU_VGPU_VBF_FAULT = 2'd2
  } apu_vgpu_vbf_status_e;

  typedef struct packed {
    apu_vgpu_vbf_status_e status;
  } apu_vgpu_vbf_cpl_t;

  // Stride 24, offset 0, resource 3. This does not fetch vertices.
  typedef struct packed {
    logic valid;
    logic [31:0] stride;
    logic [31:0] offset;
    logic [31:0] resource;
  } apu_vgpu_vbf_t;

  typedef enum logic [1:0] {
    APU_VGPU_VBK_OK    = 2'd0,
    APU_VGPU_VBK_EMPTY = 2'd1,
    APU_VGPU_VBK_FAULT = 2'd2
  } apu_vgpu_vbk_status_e;

  typedef struct packed {
    apu_vgpu_vbk_status_e status;
  } apu_vgpu_vbk_cpl_t;

  // Kept stride, offset, and resource. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] stride;
    logic [31:0] offset;
    logic [31:0] resource;
  } apu_vgpu_vbk_t;

  typedef enum logic [1:0] {
    APU_VGPU_IWR_OK    = 2'd0,
    APU_VGPU_IWR_EMPTY = 2'd1,
    APU_VGPU_IWR_FAULT = 2'd2
  } apu_vgpu_iwr_status_e;

  typedef struct packed {
    apu_vgpu_iwr_status_e status;
  } apu_vgpu_iwr_cpl_t;

  // Inline-write resource and byte count. The floats are not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] resource;
    logic [31:0] nbytes;
  } apu_vgpu_iwr_t;

  typedef enum logic [1:0] {
    APU_VGPU_IWK_OK    = 2'd0,
    APU_VGPU_IWK_EMPTY = 2'd1,
    APU_VGPU_IWK_FAULT = 2'd2
  } apu_vgpu_iwk_status_e;

  typedef struct packed {
    apu_vgpu_iwk_status_e status;
  } apu_vgpu_iwk_cpl_t;

  // Kept resource and byte count. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] resource;
    logic [31:0] nbytes;
  } apu_vgpu_iwk_t;

  typedef enum logic [1:0] {
    APU_VGPU_SVR_OK    = 2'd0,
    APU_VGPU_SVR_EMPTY = 2'd1,
    APU_VGPU_SVR_FAULT = 2'd2
  } apu_vgpu_svr_status_e;

  typedef struct packed {
    apu_vgpu_svr_status_e status;
  } apu_vgpu_svr_cpl_t;

  // Fragment stage, slot 0, sampler-view handle 5. No texture is bound.
  typedef struct packed {
    logic valid;
    logic [31:0] stage;
    logic [31:0] slot;
    logic [31:0] handle;
  } apu_vgpu_svr_t;

  typedef enum logic [1:0] {
    APU_VGPU_SVK_OK    = 2'd0,
    APU_VGPU_SVK_EMPTY = 2'd1,
    APU_VGPU_SVK_FAULT = 2'd2
  } apu_vgpu_svk_status_e;

  typedef struct packed {
    apu_vgpu_svk_status_e status;
  } apu_vgpu_svk_cpl_t;

  // Kept stage, slot, and handle. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] stage;
    logic [31:0] slot;
    logic [31:0] handle;
  } apu_vgpu_svk_t;

  typedef enum logic [1:0] {
    APU_VGPU_SSR_OK    = 2'd0,
    APU_VGPU_SSR_EMPTY = 2'd1,
    APU_VGPU_SSR_FAULT = 2'd2
  } apu_vgpu_ssr_status_e;

  typedef struct packed {
    apu_vgpu_ssr_status_e status;
  } apu_vgpu_ssr_cpl_t;

  // Fragment stage, slot 0, sampler-state handle 6. No texture is bound.
  typedef struct packed {
    logic valid;
    logic [31:0] stage;
    logic [31:0] slot;
    logic [31:0] handle;
  } apu_vgpu_ssr_t;

  typedef enum logic [1:0] {
    APU_VGPU_SSK_OK    = 2'd0,
    APU_VGPU_SSK_EMPTY = 2'd1,
    APU_VGPU_SSK_FAULT = 2'd2
  } apu_vgpu_ssk_status_e;

  typedef struct packed {
    apu_vgpu_ssk_status_e status;
  } apu_vgpu_ssk_cpl_t;

  // Kept stage, slot, and handle. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] stage;
    logic [31:0] slot;
    logic [31:0] handle;
  } apu_vgpu_ssk_t;

  typedef enum logic [1:0] {
    APU_VGPU_VER_OK    = 2'd0,
    APU_VGPU_VER_EMPTY = 2'd1,
    APU_VGPU_VER_FAULT = 2'd2
  } apu_vgpu_ver_status_e;

  typedef struct packed {
    apu_vgpu_ver_status_e status;
  } apu_vgpu_ver_cpl_t;

  // Vertex-element header and handle 4. No vertices are fetched.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_ver_t;

  typedef enum logic [1:0] {
    APU_VGPU_VEK_OK    = 2'd0,
    APU_VGPU_VEK_EMPTY = 2'd1,
    APU_VGPU_VEK_FAULT = 2'd2
  } apu_vgpu_vek_status_e;

  typedef struct packed {
    apu_vgpu_vek_status_e status;
  } apu_vgpu_vek_cpl_t;

  // Kept header and handle. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_vek_t;

  typedef enum logic [1:0] {
    APU_VGPU_FSR_OK    = 2'd0,
    APU_VGPU_FSR_EMPTY = 2'd1,
    APU_VGPU_FSR_FAULT = 2'd2
  } apu_vgpu_fsr_status_e;

  typedef struct packed {
    apu_vgpu_fsr_status_e status;
  } apu_vgpu_fsr_cpl_t;

  // Fragment shader handle 3 and fragment stage. The shader is not run.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] stage;
  } apu_vgpu_fsr_t;

  typedef enum logic [1:0] {
    APU_VGPU_FSK_OK    = 2'd0,
    APU_VGPU_FSK_EMPTY = 2'd1,
    APU_VGPU_FSK_FAULT = 2'd2
  } apu_vgpu_fsk_status_e;

  typedef struct packed {
    apu_vgpu_fsk_status_e status;
  } apu_vgpu_fsk_cpl_t;

  // Kept handle and stage. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] stage;
  } apu_vgpu_fsk_t;

  typedef enum logic [1:0] {
    APU_VGPU_VSR_OK    = 2'd0,
    APU_VGPU_VSR_EMPTY = 2'd1,
    APU_VGPU_VSR_FAULT = 2'd2
  } apu_vgpu_vsr_status_e;

  typedef struct packed {
    apu_vgpu_vsr_status_e status;
  } apu_vgpu_vsr_cpl_t;

  // Vertex shader handle 2 and vertex stage. The shader is not run.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] stage;
  } apu_vgpu_vsr_t;

  typedef enum logic [1:0] {
    APU_VGPU_VSK_OK    = 2'd0,
    APU_VGPU_VSK_EMPTY = 2'd1,
    APU_VGPU_VSK_FAULT = 2'd2
  } apu_vgpu_vsk_status_e;

  typedef struct packed {
    apu_vgpu_vsk_status_e status;
  } apu_vgpu_vsk_cpl_t;

  // Kept handle and stage. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] handle;
    logic [31:0] stage;
  } apu_vgpu_vsk_t;

  typedef enum logic [1:0] {
    APU_VGPU_RZR_OK    = 2'd0,
    APU_VGPU_RZR_EMPTY = 2'd1,
    APU_VGPU_RZR_FAULT = 2'd2
  } apu_vgpu_rzr_status_e;

  typedef struct packed {
    apu_vgpu_rzr_status_e status;
  } apu_vgpu_rzr_cpl_t;

  // Rasterizer bind header and handle 9. No triangle is walked.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_rzr_t;

  typedef enum logic [1:0] {
    APU_VGPU_RZK_OK    = 2'd0,
    APU_VGPU_RZK_EMPTY = 2'd1,
    APU_VGPU_RZK_FAULT = 2'd2
  } apu_vgpu_rzk_status_e;

  typedef struct packed {
    apu_vgpu_rzk_status_e status;
  } apu_vgpu_rzk_cpl_t;

  // Kept header and handle. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_rzk_t;

  typedef enum logic [1:0] {
    APU_VGPU_DBR_OK    = 2'd0,
    APU_VGPU_DBR_EMPTY = 2'd1,
    APU_VGPU_DBR_FAULT = 2'd2
  } apu_vgpu_dbr_status_e;

  typedef struct packed {
    apu_vgpu_dbr_status_e status;
  } apu_vgpu_dbr_cpl_t;

  // Depth-stencil bind header and handle 8. No depth test is run.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_dbr_t;

  typedef enum logic [1:0] {
    APU_VGPU_DBK_OK    = 2'd0,
    APU_VGPU_DBK_EMPTY = 2'd1,
    APU_VGPU_DBK_FAULT = 2'd2
  } apu_vgpu_dbk_status_e;

  typedef struct packed {
    apu_vgpu_dbk_status_e status;
  } apu_vgpu_dbk_cpl_t;

  // Kept header and handle. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_dbk_t;

  typedef enum logic [1:0] {
    APU_VGPU_BBR_OK    = 2'd0,
    APU_VGPU_BBR_EMPTY = 2'd1,
    APU_VGPU_BBR_FAULT = 2'd2
  } apu_vgpu_bbr_status_e;

  typedef struct packed {
    apu_vgpu_bbr_status_e status;
  } apu_vgpu_bbr_cpl_t;

  // Blend bind header and handle 7. No blend is applied.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_bbr_t;

  typedef enum logic [1:0] {
    APU_VGPU_BBK_OK    = 2'd0,
    APU_VGPU_BBK_EMPTY = 2'd1,
    APU_VGPU_BBK_FAULT = 2'd2
  } apu_vgpu_bbk_status_e;

  typedef struct packed {
    apu_vgpu_bbk_status_e status;
  } apu_vgpu_bbk_cpl_t;

  // Kept header and handle. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_bbk_t;

  typedef enum logic [1:0] {
    APU_VGPU_RCR_OK    = 2'd0,
    APU_VGPU_RCR_EMPTY = 2'd1,
    APU_VGPU_RCR_FAULT = 2'd2
  } apu_vgpu_rcr_status_e;

  typedef struct packed {
    apu_vgpu_rcr_status_e status;
  } apu_vgpu_rcr_cpl_t;

  // Rasterizer object header and handle 9. The eight state words stay 0.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_rcr_t;

  typedef enum logic [1:0] {
    APU_VGPU_RCK_OK    = 2'd0,
    APU_VGPU_RCK_EMPTY = 2'd1,
    APU_VGPU_RCK_FAULT = 2'd2
  } apu_vgpu_rck_status_e;

  typedef struct packed {
    apu_vgpu_rck_status_e status;
  } apu_vgpu_rck_cpl_t;

  // Kept header and handle. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_rck_t;

  typedef enum logic [1:0] {
    APU_VGPU_DCR_OK    = 2'd0,
    APU_VGPU_DCR_EMPTY = 2'd1,
    APU_VGPU_DCR_FAULT = 2'd2
  } apu_vgpu_dcr_status_e;

  typedef struct packed {
    apu_vgpu_dcr_status_e status;
  } apu_vgpu_dcr_cpl_t;

  // Depth-stencil object header and handle 8. The four state words stay 0.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_dcr_t;

  typedef enum logic [1:0] {
    APU_VGPU_DCK_OK    = 2'd0,
    APU_VGPU_DCK_EMPTY = 2'd1,
    APU_VGPU_DCK_FAULT = 2'd2
  } apu_vgpu_dck_status_e;

  typedef struct packed {
    apu_vgpu_dck_status_e status;
  } apu_vgpu_dck_cpl_t;

  // Kept header and handle. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
  } apu_vgpu_dck_t;

  typedef enum logic [1:0] {
    APU_VGPU_BLR_OK    = 2'd0,
    APU_VGPU_BLR_EMPTY = 2'd1,
    APU_VGPU_BLR_FAULT = 2'd2
  } apu_vgpu_blr_status_e;

  typedef struct packed {
    apu_vgpu_blr_status_e status;
  } apu_vgpu_blr_cpl_t;

  // Blend object header, handle 7, and color word. The other words stay 0.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] s2;
  } apu_vgpu_blr_t;

  typedef enum logic [1:0] {
    APU_VGPU_BLK_OK    = 2'd0,
    APU_VGPU_BLK_EMPTY = 2'd1,
    APU_VGPU_BLK_FAULT = 2'd2
  } apu_vgpu_blk_status_e;

  typedef struct packed {
    apu_vgpu_blk_status_e status;
  } apu_vgpu_blk_cpl_t;

  // Kept header, handle, and color word. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] s2;
  } apu_vgpu_blk_t;

  typedef enum logic [1:0] {
    APU_VGPU_SCR_OK    = 2'd0,
    APU_VGPU_SCR_EMPTY = 2'd1,
    APU_VGPU_SCR_FAULT = 2'd2
  } apu_vgpu_scr_status_e;

  typedef struct packed {
    apu_vgpu_scr_status_e status;
  } apu_vgpu_scr_cpl_t;

  // Sampler-state header, handle 6, wrap word, and max LOD.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] s0;
    logic [31:0] max_lod;
  } apu_vgpu_scr_t;

  typedef enum logic [1:0] {
    APU_VGPU_SCK_OK    = 2'd0,
    APU_VGPU_SCK_EMPTY = 2'd1,
    APU_VGPU_SCK_FAULT = 2'd2
  } apu_vgpu_sck_status_e;

  typedef struct packed {
    apu_vgpu_sck_status_e status;
  } apu_vgpu_sck_cpl_t;

  // Kept header, handle, wrap word, and max LOD. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] s0;
    logic [31:0] max_lod;
  } apu_vgpu_sck_t;

  typedef enum logic [1:0] {
    APU_VGPU_SVC_OK    = 2'd0,
    APU_VGPU_SVC_EMPTY = 2'd1,
    APU_VGPU_SVC_FAULT = 2'd2
  } apu_vgpu_svc_status_e;

  typedef struct packed {
    apu_vgpu_svc_status_e status;
  } apu_vgpu_svc_cpl_t;

  // Sampler-view header, handle 5, resource, format word, and swizzle.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] resource;
    logic [31:0] format;
    logic [31:0] swizzle;
  } apu_vgpu_svc_t;

  typedef enum logic [1:0] {
    APU_VGPU_VCK_OK    = 2'd0,
    APU_VGPU_VCK_EMPTY = 2'd1,
    APU_VGPU_VCK_FAULT = 2'd2
  } apu_vgpu_vck_status_e;

  typedef struct packed {
    apu_vgpu_vck_status_e status;
  } apu_vgpu_vck_cpl_t;

  // Kept header, handle, resource, format word, and swizzle.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] resource;
    logic [31:0] format;
    logic [31:0] swizzle;
  } apu_vgpu_vck_t;

  typedef enum logic [1:0] {
    APU_VGPU_VEC_OK    = 2'd0,
    APU_VGPU_VEC_EMPTY = 2'd1,
    APU_VGPU_VEC_FAULT = 2'd2
  } apu_vgpu_vec_status_e;

  typedef struct packed {
    apu_vgpu_vec_status_e status;
  } apu_vgpu_vec_cpl_t;

  // Vertex-element header, handle 4, and the two element offsets and formats.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] off0;
    logic [31:0] fmt0;
    logic [31:0] off1;
    logic [31:0] fmt1;
  } apu_vgpu_vec_t;

  typedef enum logic [1:0] {
    APU_VGPU_VCE_OK    = 2'd0,
    APU_VGPU_VCE_EMPTY = 2'd1,
    APU_VGPU_VCE_FAULT = 2'd2
  } apu_vgpu_vce_status_e;

  typedef struct packed {
    apu_vgpu_vce_status_e status;
  } apu_vgpu_vce_cpl_t;

  // Kept header, handle, and the two element offsets and formats.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] off0;
    logic [31:0] fmt0;
    logic [31:0] off1;
    logic [31:0] fmt1;
  } apu_vgpu_vce_t;

  typedef enum logic [1:0] {
    APU_VGPU_FSC_OK    = 2'd0,
    APU_VGPU_FSC_EMPTY = 2'd1,
    APU_VGPU_FSC_FAULT = 2'd2
  } apu_vgpu_fsc_status_e;

  typedef struct packed {
    apu_vgpu_fsc_status_e status;
  } apu_vgpu_fsc_cpl_t;

  // Fragment-shader header, handle 3, stage, length, token count, and text0.
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

  typedef enum logic [1:0] {
    APU_VGPU_FCE_OK    = 2'd0,
    APU_VGPU_FCE_EMPTY = 2'd1,
    APU_VGPU_FCE_FAULT = 2'd2
  } apu_vgpu_fce_status_e;

  typedef struct packed {
    apu_vgpu_fce_status_e status;
  } apu_vgpu_fce_cpl_t;

  // Kept fragment-shader header, handle, stage, length, tokens, and text0.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] stage;
    logic [31:0] offlen;
    logic [31:0] tokens;
    logic [31:0] text0;
  } apu_vgpu_fce_t;

  typedef enum logic [1:0] {
    APU_VGPU_VSC_OK    = 2'd0,
    APU_VGPU_VSC_EMPTY = 2'd1,
    APU_VGPU_VSC_FAULT = 2'd2
  } apu_vgpu_vsc_status_e;

  typedef struct packed {
    apu_vgpu_vsc_status_e status;
  } apu_vgpu_vsc_cpl_t;

  // Vertex-shader header, handle 2, stage, length, token count, and text0.
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

  typedef enum logic [1:0] {
    APU_VGPU_VSE_OK    = 2'd0,
    APU_VGPU_VSE_EMPTY = 2'd1,
    APU_VGPU_VSE_FAULT = 2'd2
  } apu_vgpu_vse_status_e;

  typedef struct packed {
    apu_vgpu_vse_status_e status;
  } apu_vgpu_vse_cpl_t;

  // Kept vertex-shader header, handle, stage, length, tokens, and text0.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] stage;
    logic [31:0] offlen;
    logic [31:0] tokens;
    logic [31:0] text0;
  } apu_vgpu_vse_t;

  typedef enum logic [1:0] {
    APU_VGPU_SFC_OK    = 2'd0,
    APU_VGPU_SFC_EMPTY = 2'd1,
    APU_VGPU_SFC_FAULT = 2'd2
  } apu_vgpu_sfc_status_e;

  typedef struct packed {
    apu_vgpu_sfc_status_e status;
  } apu_vgpu_sfc_cpl_t;

  // Surface header, handle 1, resource 4, and format 2. No pixels are stored.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] resource;
    logic [31:0] format;
  } apu_vgpu_sfc_t;

  typedef enum logic [1:0] {
    APU_VGPU_SFE_OK    = 2'd0,
    APU_VGPU_SFE_EMPTY = 2'd1,
    APU_VGPU_SFE_FAULT = 2'd2
  } apu_vgpu_sfe_status_e;

  typedef struct packed {
    apu_vgpu_sfe_status_e status;
  } apu_vgpu_sfe_cpl_t;

  // Kept surface header, handle, resource, and format.
  typedef struct packed {
    logic valid;
    logic [31:0] hdr;
    logic [31:0] handle;
    logic [31:0] resource;
    logic [31:0] format;
  } apu_vgpu_sfe_t;

  typedef enum logic [1:0] {
    APU_VGPU_NXC_OK    = 2'd0,
    APU_VGPU_NXC_EMPTY = 2'd1,
    APU_VGPU_NXC_FAULT = 2'd2
  } apu_vgpu_nxc_status_e;

  typedef struct packed {
    apu_vgpu_nxc_status_e status;
  } apu_vgpu_nxc_cpl_t;

  // Head descriptor 0, the 960-byte execbuffer, the response, and avail index 1.
  // The descriptor bytes are not kept. This is not g6lc_apu_vgpu_avail.
  typedef struct packed {
    logic valid;
    logic [15:0] head;
    logic [15:0] avail_idx;
    logic [31:0] buf_len;
    logic [63:0] buf_addr;
    logic [63:0] rsp_addr;
  } apu_vgpu_nxc_t;

  typedef enum logic [1:0] {
    APU_VGPU_NXK_OK    = 2'd0,
    APU_VGPU_NXK_EMPTY = 2'd1,
    APU_VGPU_NXK_FAULT = 2'd2
  } apu_vgpu_nxk_status_e;

  typedef struct packed {
    apu_vgpu_nxk_status_e status;
  } apu_vgpu_nxk_cpl_t;

  // Kept head, avail index, execbuffer, and response.
  typedef struct packed {
    logic valid;
    logic [15:0] head;
    logic [15:0] avail_idx;
    logic [31:0] buf_len;
    logic [63:0] buf_addr;
    logic [63:0] rsp_addr;
  } apu_vgpu_nxk_t;

  typedef enum logic [1:0] {
    APU_VGPU_OLS_OK    = 2'd0,
    APU_VGPU_OLS_EMPTY = 2'd1,
    APU_VGPU_OLS_FAULT = 2'd2
  } apu_vgpu_ols_status_e;

  typedef struct packed {
    apu_vgpu_ols_status_e status;
  } apu_vgpu_ols_cpl_t;

  // Completed-opcode count, capset id, and response. The count is 0.
  // Capset id 0 is not virgl id 1. No caps blob is stored.
  typedef struct packed {
    logic valid;
    logic [31:0] count;
    logic [31:0] capset_id;
    logic [31:0] resp;
  } apu_vgpu_ols_t;

  typedef enum logic [1:0] {
    APU_VGPU_OLK_OK    = 2'd0,
    APU_VGPU_OLK_EMPTY = 2'd1,
    APU_VGPU_OLK_FAULT = 2'd2
  } apu_vgpu_olk_status_e;

  typedef struct packed {
    apu_vgpu_olk_status_e status;
  } apu_vgpu_olk_cpl_t;

  // Kept count, capset id, and response. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] count;
    logic [31:0] capset_id;
    logic [31:0] resp;
  } apu_vgpu_olk_t;

  typedef enum logic [1:0] {
    APU_VGPU_GPW_OK    = 2'd0,
    APU_VGPU_GPW_EMPTY = 2'd1,
    APU_VGPU_GPW_FAULT = 2'd2
  } apu_vgpu_gpw_status_e;

  typedef struct packed {
    apu_vgpu_gpw_status_e status;
  } apu_vgpu_gpw_cpl_t;

  // 64 by 64 clear-word window. The bytes are not kept in registers.
  typedef struct packed {
    logic valid;
    logic [15:0] beats;
    logic [31:0] word;
    logic [63:0] base;
  } apu_vgpu_gpw_t;

  typedef enum logic [1:0] {
    APU_VGPU_GPR_OK    = 2'd0,
    APU_VGPU_GPR_EMPTY = 2'd1,
    APU_VGPU_GPR_FAULT = 2'd2
  } apu_vgpu_gpr_status_e;

  typedef struct packed {
    apu_vgpu_gpr_status_e status;
  } apu_vgpu_gpr_cpl_t;

  // First and last beat of that window. Both carry the clear word.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [63:0] first;
    logic [63:0] last;
  } apu_vgpu_gpr_t;

  typedef enum logic [1:0] {
    APU_VGPU_GPK_OK    = 2'd0,
    APU_VGPU_GPK_EMPTY = 2'd1,
    APU_VGPU_GPK_FAULT = 2'd2
  } apu_vgpu_gpk_status_e;

  typedef struct packed {
    apu_vgpu_gpk_status_e status;
  } apu_vgpu_gpk_cpl_t;

  // Kept clear word and the two beat addresses.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [63:0] first;
    logic [63:0] last;
  } apu_vgpu_gpk_t;

  typedef enum logic [1:0] {
    APU_VGPU_GCW_OK    = 2'd0,
    APU_VGPU_GCW_EMPTY = 2'd1,
    APU_VGPU_GCW_FAULT = 2'd2
  } apu_vgpu_gcw_status_e;

  typedef struct packed {
    apu_vgpu_gcw_status_e status;
  } apu_vgpu_gcw_cpl_t;

  // Response type, fence, used element, and used index. The 24 bytes
  // are not kept. This is not g6lc_apu_vgpu_rsp.
  typedef struct packed {
    logic valid;
    logic [31:0] resp;
    logic [63:0] fence;
    logic [31:0] elem_id;
    logic [31:0] elem_len;
    logic [15:0] used_idx;
  } apu_vgpu_gcw_t;

  typedef enum logic [1:0] {
    APU_VGPU_GCR_OK    = 2'd0,
    APU_VGPU_GCR_EMPTY = 2'd1,
    APU_VGPU_GCR_FAULT = 2'd2
  } apu_vgpu_gcr_status_e;

  typedef struct packed {
    apu_vgpu_gcr_status_e status;
  } apu_vgpu_gcr_cpl_t;

  // The same fields read back from guest memory.
  typedef struct packed {
    logic valid;
    logic [31:0] resp;
    logic [63:0] fence;
    logic [31:0] elem_id;
    logic [31:0] elem_len;
    logic [15:0] used_idx;
  } apu_vgpu_gcr_t;

  typedef enum logic [1:0] {
    APU_VGPU_GCK_OK    = 2'd0,
    APU_VGPU_GCK_EMPTY = 2'd1,
    APU_VGPU_GCK_FAULT = 2'd2
  } apu_vgpu_gck_status_e;

  typedef struct packed {
    apu_vgpu_gck_status_e status;
  } apu_vgpu_gck_cpl_t;

  // Kept response, fence, element, and used index. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] resp;
    logic [63:0] fence;
    logic [31:0] elem_id;
    logic [31:0] elem_len;
    logic [15:0] used_idx;
  } apu_vgpu_gck_t;

  typedef enum logic [1:0] {
    APU_VGPU_VIW_OK    = 2'd0,
    APU_VGPU_VIW_EMPTY = 2'd1,
    APU_VGPU_VIW_FAULT = 2'd2
  } apu_vgpu_viw_status_e;

  typedef struct packed {
    apu_vgpu_viw_status_e status;
  } apu_vgpu_viw_cpl_t;

  // Used-buffer interrupt reason and the used index. The status word
  // is not kept in a register file. This is not g6lc_apu_vgpu_sun.
  typedef struct packed {
    logic valid;
    logic [31:0] reason;
    logic [15:0] used_idx;
  } apu_vgpu_viw_t;

  typedef enum logic [1:0] {
    APU_VGPU_VIR_OK    = 2'd0,
    APU_VGPU_VIR_EMPTY = 2'd1,
    APU_VGPU_VIR_FAULT = 2'd2
  } apu_vgpu_vir_status_e;

  typedef struct packed {
    apu_vgpu_vir_status_e status;
  } apu_vgpu_vir_cpl_t;

  // The reason read back from the stand-in word.
  typedef struct packed {
    logic valid;
    logic [31:0] reason;
    logic [15:0] used_idx;
  } apu_vgpu_vir_t;

  typedef enum logic [1:0] {
    APU_VGPU_VIK_OK    = 2'd0,
    APU_VGPU_VIK_EMPTY = 2'd1,
    APU_VGPU_VIK_FAULT = 2'd2
  } apu_vgpu_vik_status_e;

  typedef struct packed {
    apu_vgpu_vik_status_e status;
  } apu_vgpu_vik_cpl_t;

  // Kept reason and used index. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] reason;
    logic [15:0] used_idx;
  } apu_vgpu_vik_t;

  typedef enum logic [1:0] {
    APU_VGPU_VAW_OK    = 2'd0,
    APU_VGPU_VAW_EMPTY = 2'd1,
    APU_VGPU_VAW_FAULT = 2'd2
  } apu_vgpu_vaw_status_e;

  typedef struct packed {
    apu_vgpu_vaw_status_e status;
  } apu_vgpu_vaw_cpl_t;

  // Guest ack word and the cleared status. The beats are not kept.
  // This is not the viw pin.
  typedef struct packed {
    logic valid;
    logic [31:0] ack;
    logic [31:0] remain;
    logic [15:0] used_idx;
  } apu_vgpu_vaw_t;

  typedef enum logic [1:0] {
    APU_VGPU_VAR_OK    = 2'd0,
    APU_VGPU_VAR_EMPTY = 2'd1,
    APU_VGPU_VAR_FAULT = 2'd2
  } apu_vgpu_var_status_e;

  typedef struct packed {
    apu_vgpu_var_status_e status;
  } apu_vgpu_var_cpl_t;

  // Ack word and cleared status read back.
  typedef struct packed {
    logic valid;
    logic [31:0] ack;
    logic [31:0] remain;
    logic [15:0] used_idx;
  } apu_vgpu_var_t;

  typedef enum logic [1:0] {
    APU_VGPU_VAK_OK    = 2'd0,
    APU_VGPU_VAK_EMPTY = 2'd1,
    APU_VGPU_VAK_FAULT = 2'd2
  } apu_vgpu_vak_status_e;

  typedef struct packed {
    apu_vgpu_vak_status_e status;
  } apu_vgpu_vak_cpl_t;

  // Kept ack, cleared status, and used index. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] ack;
    logic [31:0] remain;
    logic [15:0] used_idx;
  } apu_vgpu_vak_t;

  typedef enum logic [1:0] {
    APU_VGPU_WFR_OK    = 2'd0,
    APU_VGPU_WFR_EMPTY = 2'd1,
    APU_VGPU_WFR_FAULT = 2'd2
  } apu_vgpu_wfr_status_e;

  typedef struct packed {
    apu_vgpu_wfr_status_e status;
  } apu_vgpu_wfr_cpl_t;

  // Full scan of the clear-word window. The image is not kept.
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

  typedef enum logic [1:0] {
    APU_VGPU_WFK_OK    = 2'd0,
    APU_VGPU_WFK_EMPTY = 2'd1,
    APU_VGPU_WFK_FAULT = 2'd2
  } apu_vgpu_wfk_status_e;

  typedef struct packed {
    apu_vgpu_wfk_status_e status;
  } apu_vgpu_wfk_cpl_t;

  // Kept clear word at the three sampled points.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [31:0] pix10;
    logic [31:0] pix63;
    logic [15:0] beats;
  } apu_vgpu_wfk_t;

  typedef enum logic [1:0] {
    APU_VGPU_WFX_OK    = 2'd0,
    APU_VGPU_WFX_EMPTY = 2'd1,
    APU_VGPU_WFX_FAULT = 2'd2
  } apu_vgpu_wfx_status_e;

  typedef struct packed {
    apu_vgpu_wfx_status_e status;
  } apu_vgpu_wfx_cpl_t;

  // One in-range point. A coordinate past 63 records nothing.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [6:0] x;
    logic [6:0] y;
  } apu_vgpu_wfx_t;

  typedef enum logic [1:0] {
    APU_VGPU_GBW_OK    = 2'd0,
    APU_VGPU_GBW_EMPTY = 2'd1,
    APU_VGPU_GBW_FAULT = 2'd2
  } apu_vgpu_gbw_status_e;

  typedef struct packed {
    apu_vgpu_gbw_status_e status;
  } apu_vgpu_gbw_cpl_t;

  // Copy of the scanned window into the readback buffer. The image is
  // not kept. This is not Mesa glReadPixels.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [15:0] beats;
    logic [63:0] src;
    logic [63:0] dst;
  } apu_vgpu_gbw_t;

  typedef enum logic [1:0] {
    APU_VGPU_GBR_OK    = 2'd0,
    APU_VGPU_GBR_EMPTY = 2'd1,
    APU_VGPU_GBR_FAULT = 2'd2
  } apu_vgpu_gbr_status_e;

  typedef struct packed {
    apu_vgpu_gbr_status_e status;
  } apu_vgpu_gbr_cpl_t;

  // First and last beats of the readback buffer.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [63:0] first;
    logic [63:0] last;
  } apu_vgpu_gbr_t;

  typedef enum logic [1:0] {
    APU_VGPU_GBK_OK    = 2'd0,
    APU_VGPU_GBK_EMPTY = 2'd1,
    APU_VGPU_GBK_FAULT = 2'd2
  } apu_vgpu_gbk_status_e;

  typedef struct packed {
    apu_vgpu_gbk_status_e status;
  } apu_vgpu_gbk_cpl_t;

  // Kept clear word, source, and readback address.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [15:0] beats;
    logic [63:0] src;
    logic [63:0] dst;
  } apu_vgpu_gbk_t;

  typedef enum logic [1:0] {
    APU_VGPU_GBD_OK    = 2'd0,
    APU_VGPU_GBD_EMPTY = 2'd1,
    APU_VGPU_GBD_FAULT = 2'd2
  } apu_vgpu_gbd_status_e;

  typedef struct packed {
    apu_vgpu_gbd_status_e status;
  } apu_vgpu_gbd_cpl_t;

  // 64 by 64 readback rectangle. The image is not kept.
  typedef struct packed {
    logic valid;
    logic [15:0] width;
    logic [15:0] height;
    logic [15:0] stride;
    logic [31:0] bytes;
    logic [31:0] format;
    logic [63:0] base;
  } apu_vgpu_gbd_t;

  typedef enum logic [1:0] {
    APU_VGPU_GBL_OK    = 2'd0,
    APU_VGPU_GBL_EMPTY = 2'd1,
    APU_VGPU_GBL_FAULT = 2'd2
  } apu_vgpu_gbl_status_e;

  typedef struct packed {
    apu_vgpu_gbl_status_e status;
  } apu_vgpu_gbl_cpl_t;

  // One lane of the readback buffer. A coordinate past 63 reads nothing.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [6:0] x;
    logic [6:0] y;
    logic [63:0] addr;
  } apu_vgpu_gbl_t;

  typedef enum logic [1:0] {
    APU_VGPU_GBX_OK    = 2'd0,
    APU_VGPU_GBX_EMPTY = 2'd1,
    APU_VGPU_GBX_FAULT = 2'd2
  } apu_vgpu_gbx_status_e;

  typedef struct packed {
    apu_vgpu_gbx_status_e status;
  } apu_vgpu_gbx_cpl_t;

  // Kept rectangle and the sampled lane. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [15:0] width;
    logic [15:0] height;
    logic [31:0] bytes;
    logic [31:0] word;
    logic [6:0] x;
    logic [6:0] y;
  } apu_vgpu_gbx_t;

  typedef enum logic [1:0] {
    APU_VGPU_GOF_OK    = 2'd0,
    APU_VGPU_GOF_EMPTY = 2'd1,
    APU_VGPU_GOF_FAULT = 2'd2
  } apu_vgpu_gof_status_e;

  typedef struct packed {
    apu_vgpu_gof_status_e status;
  } apu_vgpu_gof_cpl_t;

  // Byte offset of one in-range point. The image is not kept.
  typedef struct packed {
    logic valid;
    logic [15:0] offset;
    logic [63:0] addr;
    logic [6:0] x;
    logic [6:0] y;
  } apu_vgpu_gof_t;

  typedef enum logic [1:0] {
    APU_VGPU_GBO_OK    = 2'd0,
    APU_VGPU_GBO_EMPTY = 2'd1,
    APU_VGPU_GBO_FAULT = 2'd2
  } apu_vgpu_gbo_status_e;

  typedef struct packed {
    apu_vgpu_gbo_status_e status;
  } apu_vgpu_gbo_cpl_t;

  // The lane at that byte offset. It is the clear word.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [15:0] offset;
    logic [6:0] x;
    logic [6:0] y;
  } apu_vgpu_gbo_t;

  typedef enum logic [1:0] {
    APU_VGPU_GBZ_OK    = 2'd0,
    APU_VGPU_GBZ_EMPTY = 2'd1,
    APU_VGPU_GBZ_FAULT = 2'd2
  } apu_vgpu_gbz_status_e;

  typedef struct packed {
    apu_vgpu_gbz_status_e status;
  } apu_vgpu_gbz_cpl_t;

  // Kept offset and lane. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] word;
    logic [15:0] offset;
    logic [31:0] bytes;
    logic [6:0] x;
    logic [6:0] y;
  } apu_vgpu_gbz_t;

  typedef enum logic [1:0] {
    APU_VGPU_BYR_OK    = 2'd0,
    APU_VGPU_BYR_EMPTY = 2'd1,
    APU_VGPU_BYR_FAULT = 2'd2
  } apu_vgpu_byr_status_e;

  typedef struct packed {
    apu_vgpu_byr_status_e status;
  } apu_vgpu_byr_cpl_t;

  // Little-endian channels of the clear word. Byte 0 is red.
  // The image is not kept.
  typedef struct packed {
    logic valid;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_byr_t;

  typedef enum logic [1:0] {
    APU_VGPU_BYK_OK    = 2'd0,
    APU_VGPU_BYK_EMPTY = 2'd1,
    APU_VGPU_BYK_FAULT = 2'd2
  } apu_vgpu_byk_status_e;

  typedef struct packed {
    apu_vgpu_byk_status_e status;
  } apu_vgpu_byk_cpl_t;

  // Kept channels. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_byk_t;

  typedef enum logic [1:0] {
    APU_VGPU_BYX_OK    = 2'd0,
    APU_VGPU_BYX_EMPTY = 2'd1,
    APU_VGPU_BYX_FAULT = 2'd2
  } apu_vgpu_byx_status_e;

  typedef struct packed {
    apu_vgpu_byx_status_e status;
  } apu_vgpu_byx_cpl_t;

  // The first raw byte is red, not the high byte of the word.
  typedef struct packed {
    logic valid;
    logic [7:0] b0;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_byx_t;

  typedef enum logic [1:0] {
    APU_VGPU_RYR_OK    = 2'd0,
    APU_VGPU_RYR_EMPTY = 2'd1,
    APU_VGPU_RYR_FAULT = 2'd2
  } apu_vgpu_ryr_status_e;

  typedef struct packed {
    apu_vgpu_ryr_status_e status;
  } apu_vgpu_ryr_cpl_t;

  // Row 1 of the readback, byte 0 red. The image is not kept.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_ryr_t;

  typedef enum logic [1:0] {
    APU_VGPU_RYK_OK    = 2'd0,
    APU_VGPU_RYK_EMPTY = 2'd1,
    APU_VGPU_RYK_FAULT = 2'd2
  } apu_vgpu_ryk_status_e;

  typedef struct packed {
    apu_vgpu_ryk_status_e status;
  } apu_vgpu_ryk_cpl_t;

  // Kept row channels and format tag. A second store keeps the first.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_ryk_t;

  typedef enum logic [1:0] {
    APU_VGPU_RYX_OK    = 2'd0,
    APU_VGPU_RYX_EMPTY = 2'd1,
    APU_VGPU_RYX_FAULT = 2'd2
  } apu_vgpu_ryx_status_e;

  typedef struct packed {
    apu_vgpu_ryx_status_e status;
  } apu_vgpu_ryx_cpl_t;

  // Byte 0 of row 1 is red. Blue or 8'hFF records nothing.
  typedef struct packed {
    logic valid;
    logic [31:0] format;
    logic [7:0] b0;
    logic [7:0] r;
    logic [7:0] g;
    logic [7:0] b;
    logic [7:0] a;
  } apu_vgpu_ryx_t;

  typedef enum logic [1:0] {
    APU_VGPU_TPR_OK    = 2'd0,
    APU_VGPU_TPR_EMPTY = 2'd1,
    APU_VGPU_TPR_FAULT = 2'd2
  } apu_vgpu_tpr_status_e;

  typedef struct packed {
    apu_vgpu_tpr_status_e status;
  } apu_vgpu_tpr_cpl_t;

  // Three readback points. The image is not kept.
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

  typedef enum logic [1:0] {
    APU_VGPU_TPK_OK    = 2'd0,
    APU_VGPU_TPK_EMPTY = 2'd1,
    APU_VGPU_TPK_FAULT = 2'd2
  } apu_vgpu_tpk_status_e;

  typedef struct packed {
    apu_vgpu_tpk_status_e status;
  } apu_vgpu_tpk_cpl_t;

  // Kept offsets and channels. A second store keeps the first.
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

  typedef enum logic [1:0] {
    APU_VGPU_TPX_OK    = 2'd0,
    APU_VGPU_TPX_EMPTY = 2'd1,
    APU_VGPU_TPX_FAULT = 2'd2
  } apu_vgpu_tpx_status_e;

  typedef struct packed {
    apu_vgpu_tpx_status_e status;
  } apu_vgpu_tpx_cpl_t;

  // Byte 0 of (0,63) is red. Blue or 8'hFF records nothing.
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

  typedef enum logic [1:0] {
    APU_VGPU_X6R_OK    = 2'd0,
    APU_VGPU_X6R_EMPTY = 2'd1,
    APU_VGPU_X6R_FAULT = 2'd2
  } apu_vgpu_x6r_status_e;

  typedef struct packed {
    apu_vgpu_x6r_status_e status;
  } apu_vgpu_x6r_cpl_t;

  // (63,0) is byte 252. The image is not kept.
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

  typedef enum logic [1:0] {
    APU_VGPU_X6K_OK    = 2'd0,
    APU_VGPU_X6K_EMPTY = 2'd1,
    APU_VGPU_X6K_FAULT = 2'd2
  } apu_vgpu_x6k_status_e;

  typedef struct packed {
    apu_vgpu_x6k_status_e status;
  } apu_vgpu_x6k_cpl_t;

  // Kept (63,0). A second store keeps the first.
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

  typedef enum logic [1:0] {
    APU_VGPU_X6X_OK    = 2'd0,
    APU_VGPU_X6X_EMPTY = 2'd1,
    APU_VGPU_X6X_FAULT = 2'd2
  } apu_vgpu_x6x_status_e;

  typedef struct packed {
    apu_vgpu_x6x_status_e status;
  } apu_vgpu_x6x_cpl_t;

  // Byte 0 of (63,0) is red. Blue or 8'hFF records nothing.
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

  typedef enum logic [1:0] {
    APU_VGPU_TCR_OK    = 2'd0,
    APU_VGPU_TCR_EMPTY = 2'd1,
    APU_VGPU_TCR_FAULT = 2'd2
  } apu_vgpu_tcr_status_e;

  typedef struct packed {
    apu_vgpu_tcr_status_e status;
  } apu_vgpu_tcr_cpl_t;

  // (63,63) is byte 16380. The image is not kept.
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

  typedef enum logic [1:0] {
    APU_VGPU_TCK_OK    = 2'd0,
    APU_VGPU_TCK_EMPTY = 2'd1,
    APU_VGPU_TCK_FAULT = 2'd2
  } apu_vgpu_tck_status_e;

  typedef struct packed {
    apu_vgpu_tck_status_e status;
  } apu_vgpu_tck_cpl_t;

  // Kept (63,63). A second store keeps the first.
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

  typedef enum logic [1:0] {
    APU_VGPU_TCX_OK    = 2'd0,
    APU_VGPU_TCX_EMPTY = 2'd1,
    APU_VGPU_TCX_FAULT = 2'd2
  } apu_vgpu_tcx_status_e;

  typedef struct packed {
    apu_vgpu_tcx_status_e status;
  } apu_vgpu_tcx_cpl_t;

  // Byte 0 of (63,63) is red. Blue or 8'hFF records nothing.
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

  typedef enum logic [1:0] {
    APU_VGPU_P7R_OK    = 2'd0,
    APU_VGPU_P7R_EMPTY = 2'd1,
    APU_VGPU_P7R_FAULT = 2'd2
  } apu_vgpu_p7r_status_e;

  typedef struct packed {
    apu_vgpu_p7r_status_e status;
  } apu_vgpu_p7r_cpl_t;

  // (7,0) is byte 28. The image is not kept.
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

  typedef enum logic [1:0] {
    APU_VGPU_P7K_OK    = 2'd0,
    APU_VGPU_P7K_EMPTY = 2'd1,
    APU_VGPU_P7K_FAULT = 2'd2
  } apu_vgpu_p7k_status_e;

  typedef struct packed {
    apu_vgpu_p7k_status_e status;
  } apu_vgpu_p7k_cpl_t;

  // Kept (7,0). A second store keeps the first.
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

  typedef enum logic [1:0] {
    APU_VGPU_P7X_OK    = 2'd0,
    APU_VGPU_P7X_EMPTY = 2'd1,
    APU_VGPU_P7X_FAULT = 2'd2
  } apu_vgpu_p7x_status_e;

  typedef struct packed {
    apu_vgpu_p7x_status_e status;
  } apu_vgpu_p7x_cpl_t;

  // Byte 0 of (7,0) is red. Blue or 8'hFF records nothing.
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

  typedef enum logic [1:0] {
    APU_VGPU_B1R_OK    = 2'd0,
    APU_VGPU_B1R_EMPTY = 2'd1,
    APU_VGPU_B1R_FAULT = 2'd2
  } apu_vgpu_b1r_status_e;

  typedef struct packed {
    apu_vgpu_b1r_status_e status;
  } apu_vgpu_b1r_cpl_t;

  // (8,0) and (15,0) share one beat. The image is not kept.
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

  typedef enum logic [1:0] {
    APU_VGPU_B1K_OK    = 2'd0,
    APU_VGPU_B1K_EMPTY = 2'd1,
    APU_VGPU_B1K_FAULT = 2'd2
  } apu_vgpu_b1k_status_e;

  typedef struct packed {
    apu_vgpu_b1k_status_e status;
  } apu_vgpu_b1k_cpl_t;

  // Kept beat-1 offsets. A second store keeps the first.
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

  typedef enum logic [1:0] {
    APU_VGPU_B1X_OK    = 2'd0,
    APU_VGPU_B1X_EMPTY = 2'd1,
    APU_VGPU_B1X_FAULT = 2'd2
  } apu_vgpu_b1x_status_e;

  typedef struct packed {
    apu_vgpu_b1x_status_e status;
  } apu_vgpu_b1x_cpl_t;

  // Byte 0 of (8,0) is red. Blue or 8'hFF records nothing.
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

  typedef enum logic [1:0] {
    APU_VGPU_B7R_OK    = 2'd0,
    APU_VGPU_B7R_EMPTY = 2'd1,
    APU_VGPU_B7R_FAULT = 2'd2
  } apu_vgpu_b7r_status_e;

  typedef struct packed {
    apu_vgpu_b7r_status_e status;
  } apu_vgpu_b7r_cpl_t;

  // (56,0) shares the beat with (63,0). The image is not kept.
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

  typedef enum logic [1:0] {
    APU_VGPU_B7K_OK    = 2'd0,
    APU_VGPU_B7K_EMPTY = 2'd1,
    APU_VGPU_B7K_FAULT = 2'd2
  } apu_vgpu_b7k_status_e;

  typedef struct packed {
    apu_vgpu_b7k_status_e status;
  } apu_vgpu_b7k_cpl_t;

  // Kept (56,0) and (63,0). A second store keeps the first.
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

  typedef enum logic [1:0] {
    APU_VGPU_B7X_OK    = 2'd0,
    APU_VGPU_B7X_EMPTY = 2'd1,
    APU_VGPU_B7X_FAULT = 2'd2
  } apu_vgpu_b7x_status_e;

  typedef struct packed {
    apu_vgpu_b7x_status_e status;
  } apu_vgpu_b7x_cpl_t;

  // Byte 0 of (56,0) is red. Blue or 8'hFF records nothing.
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

  typedef enum logic [1:0] {
    APU_VGPU_B2R_OK    = 2'd0,
    APU_VGPU_B2R_EMPTY = 2'd1,
    APU_VGPU_B2R_FAULT = 2'd2
  } apu_vgpu_b2r_status_e;

  typedef struct packed {
    apu_vgpu_b2r_status_e status;
  } apu_vgpu_b2r_cpl_t;

  // Beat 2 of row 0. (16,0) and (23,0). The image is not kept.
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

  typedef enum logic [1:0] {
    APU_VGPU_B2K_OK    = 2'd0,
    APU_VGPU_B2K_EMPTY = 2'd1,
    APU_VGPU_B2K_FAULT = 2'd2
  } apu_vgpu_b2k_status_e;

  typedef struct packed {
    apu_vgpu_b2k_status_e status;
  } apu_vgpu_b2k_cpl_t;

  // Kept (16,0) and (23,0). A second store keeps the first.
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

  typedef enum logic [1:0] {
    APU_VGPU_B2X_OK    = 2'd0,
    APU_VGPU_B2X_EMPTY = 2'd1,
    APU_VGPU_B2X_FAULT = 2'd2
  } apu_vgpu_b2x_status_e;

  typedef struct packed {
    apu_vgpu_b2x_status_e status;
  } apu_vgpu_b2x_cpl_t;

  // Byte 0 of (16,0) is red. Blue or 8'hFF records nothing.
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

  typedef enum logic [1:0] {
    APU_VGPU_B3R_OK    = 2'd0,
    APU_VGPU_B3R_EMPTY = 2'd1,
    APU_VGPU_B3R_FAULT = 2'd2
  } apu_vgpu_b3r_status_e;

  typedef struct packed {
    apu_vgpu_b3r_status_e status;
  } apu_vgpu_b3r_cpl_t;

  // Beat 3 of row 0. (24,0) and (31,0). The image is not kept.
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

  typedef enum logic [1:0] {
    APU_VGPU_B3K_OK    = 2'd0,
    APU_VGPU_B3K_EMPTY = 2'd1,
    APU_VGPU_B3K_FAULT = 2'd2
  } apu_vgpu_b3k_status_e;

  typedef struct packed {
    apu_vgpu_b3k_status_e status;
  } apu_vgpu_b3k_cpl_t;

  // Kept (24,0) and (31,0). A second store keeps the first.
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

  typedef enum logic [1:0] {
    APU_VGPU_B3X_OK    = 2'd0,
    APU_VGPU_B3X_EMPTY = 2'd1,
    APU_VGPU_B3X_FAULT = 2'd2
  } apu_vgpu_b3x_status_e;

  typedef struct packed {
    apu_vgpu_b3x_status_e status;
  } apu_vgpu_b3x_cpl_t;

  // Byte 0 of (24,0) is red. Blue or 8'hFF records nothing.
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

  typedef enum logic [1:0] {
    APU_VGPU_B4R_OK    = 2'd0,
    APU_VGPU_B4R_EMPTY = 2'd1,
    APU_VGPU_B4R_FAULT = 2'd2
  } apu_vgpu_b4r_status_e;

  typedef struct packed {
    apu_vgpu_b4r_status_e status;
  } apu_vgpu_b4r_cpl_t;

  // Beat 4 of row 0. (32,0) and (39,0). The image is not kept.
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

  typedef enum logic [1:0] {
    APU_VGPU_B4K_OK    = 2'd0,
    APU_VGPU_B4K_EMPTY = 2'd1,
    APU_VGPU_B4K_FAULT = 2'd2
  } apu_vgpu_b4k_status_e;

  typedef struct packed {
    apu_vgpu_b4k_status_e status;
  } apu_vgpu_b4k_cpl_t;

  // Kept (32,0) and (39,0). A second store keeps the first.
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

  typedef enum logic [1:0] {
    APU_VGPU_B4X_OK    = 2'd0,
    APU_VGPU_B4X_EMPTY = 2'd1,
    APU_VGPU_B4X_FAULT = 2'd2
  } apu_vgpu_b4x_status_e;

  typedef struct packed {
    apu_vgpu_b4x_status_e status;
  } apu_vgpu_b4x_cpl_t;

  // Byte 0 of (32,0) is red. Blue or 8'hFF records nothing.
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

  typedef enum logic [1:0] {
    APU_VGPU_B5R_OK    = 2'd0,
    APU_VGPU_B5R_EMPTY = 2'd1,
    APU_VGPU_B5R_FAULT = 2'd2
  } apu_vgpu_b5r_status_e;

  typedef struct packed {
    apu_vgpu_b5r_status_e status;
  } apu_vgpu_b5r_cpl_t;

  // Beat 5 of row 0. (40,0) and (47,0). The image is not kept.
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

  typedef enum logic [1:0] {
    APU_VGPU_B5K_OK    = 2'd0,
    APU_VGPU_B5K_EMPTY = 2'd1,
    APU_VGPU_B5K_FAULT = 2'd2
  } apu_vgpu_b5k_status_e;

  typedef struct packed {
    apu_vgpu_b5k_status_e status;
  } apu_vgpu_b5k_cpl_t;

  // Kept (40,0) and (47,0). A second store keeps the first.
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

  typedef enum logic [1:0] {
    APU_VGPU_B5X_OK    = 2'd0,
    APU_VGPU_B5X_EMPTY = 2'd1,
    APU_VGPU_B5X_FAULT = 2'd2
  } apu_vgpu_b5x_status_e;

  typedef struct packed {
    apu_vgpu_b5x_status_e status;
  } apu_vgpu_b5x_cpl_t;

  // Byte 0 of (40,0) is red. Blue or 8'hFF records nothing.
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

  typedef enum logic [1:0] {
    APU_VGPU_B6R_OK    = 2'd0,
    APU_VGPU_B6R_EMPTY = 2'd1,
    APU_VGPU_B6R_FAULT = 2'd2
  } apu_vgpu_b6r_status_e;

  typedef struct packed {
    apu_vgpu_b6r_status_e status;
  } apu_vgpu_b6r_cpl_t;

  // Beat 6 of row 0. (48,0) and (55,0). The image is not kept.
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

  typedef enum logic [1:0] {
    APU_VGPU_B6K_OK    = 2'd0,
    APU_VGPU_B6K_EMPTY = 2'd1,
    APU_VGPU_B6K_FAULT = 2'd2
  } apu_vgpu_b6k_status_e;

  typedef struct packed {
    apu_vgpu_b6k_status_e status;
  } apu_vgpu_b6k_cpl_t;

  // Kept (48,0) and (55,0). A second store keeps the first.
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

  typedef enum logic [1:0] {
    APU_VGPU_B6X_OK    = 2'd0,
    APU_VGPU_B6X_EMPTY = 2'd1,
    APU_VGPU_B6X_FAULT = 2'd2
  } apu_vgpu_b6x_status_e;

  typedef struct packed {
    apu_vgpu_b6x_status_e status;
  } apu_vgpu_b6x_cpl_t;

  // Byte 0 of (48,0) is red. Blue or 8'hFF records nothing.
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

endpackage
