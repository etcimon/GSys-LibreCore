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

  localparam int unsigned APU_EXEC_IMEM = 16;

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
