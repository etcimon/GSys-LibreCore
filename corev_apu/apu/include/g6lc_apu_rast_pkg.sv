// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Raster engine contract (g6lc_apu_rast) — first-pixel increment:
// CLEAR fills an attachment through the shared aperture port; DRAW
// gathers vertex attributes into VS input records, issues
// APU_SH_WORK_VS/FS wave batches on the ShaderCore work port, and
// scan-converts triangles between the two shader stages.
package g6lc_apu_rast_pkg;
  import g6lc_apu_cmdexec_pkg::apu_xfer_img_t;
  typedef enum logic [1:0] { APU_RAST_OP_NONE = 2'd0, APU_RAST_OP_CLEAR = 2'd1, APU_RAST_OP_DRAW = 2'd2 } apu_rast_op_e;
  // VkFormat ids accepted for vertex attributes (v1); missing components read as (0,0,0,1)
  localparam logic [7:0] APU_RAST_VF_R32_SFLOAT = 8'd100, APU_RAST_VF_RG32_SFLOAT = 8'd103,
                         APU_RAST_VF_RGB32_SFLOAT = 8'd106, APU_RAST_VF_RGBA32_SFLOAT = 8'd109,
                         APU_RAST_VF_RGBA8_UNORM = 8'd37;
  // VkBlendFactor subset (other factors → UNSUPPORTED) and VkBlendOp
  localparam logic [4:0] APU_RAST_BF_ZERO = 5'd0, APU_RAST_BF_ONE = 5'd1,
                         APU_RAST_BF_SRC_COLOR = 5'd2, APU_RAST_BF_OM_SRC_COLOR = 5'd3,
                         APU_RAST_BF_DST_COLOR = 5'd4, APU_RAST_BF_OM_DST_COLOR = 5'd5,
                         APU_RAST_BF_SRC_ALPHA = 5'd6, APU_RAST_BF_OM_SRC_ALPHA = 5'd7,
                         APU_RAST_BF_DST_ALPHA = 5'd8, APU_RAST_BF_OM_DST_ALPHA = 5'd9,
                         APU_RAST_BF_CONST_COLOR = 5'd10, APU_RAST_BF_OM_CONST_COLOR = 5'd11,
                         APU_RAST_BF_CONST_ALPHA = 5'd12, APU_RAST_BF_OM_CONST_ALPHA = 5'd13,
                         APU_RAST_BF_SRC_ALPHA_SAT = 5'd14;
  localparam logic [2:0] APU_RAST_BO_ADD = 3'd0, APU_RAST_BO_SUBTRACT = 3'd1,
                         APU_RAST_BO_REVERSE_SUBTRACT = 3'd2, APU_RAST_BO_MIN = 3'd3,
                         APU_RAST_BO_MAX = 3'd4;
  // per-attachment VkPipelineColorBlendAttachmentState, packed as the
  // ObjPay state words w14..w17 (graphics pipe) — {pad, mask, opA,
  // dstA, srcA, opC, dstC, srcC, en}
  typedef struct packed {
    logic        pad;                        // [31]
    logic [3:0]  mask;                       // [30:27] colorWriteMask RGBA
    logic [2:0]  op_a;                       // [26:24] alphaBlendOp
    logic [4:0]  dst_a;                      // [23:19] dstAlphaBlendFactor
    logic [4:0]  src_a;                      // [18:14] srcAlphaBlendFactor
    logic [2:0]  op_c;                       // [13:11] colorBlendOp
    logic [4:0]  dst_c;                      // [10:6] dstColorBlendFactor
    logic [4:0]  src_c;                      // [5:1]  srcColorBlendFactor
    logic        en;                         // [0]    blendEnable
  } apu_rast_blend_t;
  typedef struct packed { logic [2:0] loc; logic [1:0] binding; logic [7:0] fmt; logic [11:0] offset; logic valid; } apu_rast_attr_t;
  typedef struct packed { logic [31:0] x, y, w, h, minz, maxz; } apu_rast_vp_t;   // f32 bit patterns (VkViewport)
  typedef struct packed {
    apu_rast_op_e      op;
    logic [2:0]        vs_slot, fs_slot;
    logic [7:0]        fs_in_mask;           // FS Input locations to interpolate (entry.in_mask of the FS module)
    logic              fs_late;              // FS writes FragDepth or may kill/demote -> late-Z in the ROP
    logic              fs_fdepth;            // FS declares FragDepth out -> slot8 word0 is the depth source
    logic [7:0]        topology;             // VkPrimitiveTopology: 3 LIST, 4 STRIP, 5 FAN (others → UNSUPPORTED)
    logic [1:0]        cull;                 // VkCullModeFlags bit0 FRONT bit1 BACK
    logic              front_ccw;            // VK_FRONT_FACE_COUNTER_CLOCKWISE
    apu_rast_attr_t [7:0] attr;
    logic [3:0][31:0]  vb_base;              // aperture byte base (mem base + bind off + cmd offset)
    logic [3:0][31:0]  vb_size;              // bytes readable from vb_base (robust: OOB attribute reads as 0)
    logic [3:0][15:0]  vb_stride;
    logic [3:0]        vb_rate;              // per-binding inputRate: bit b = INSTANCE (index by inst, not vertex)
    logic [31:0]       ib_base, ib_size;
    logic [1:0]        ib_type;              // 0 none (vkCmdDraw), 1 UINT16, 2 UINT32
    apu_rast_vp_t      vp;                   // dynamic viewport (f32)
    logic [15:0]       sc_x, sc_y, sc_w, sc_h;
    apu_xfer_img_t [3:0] ca;                 // color attachments (FS out loc l -> ca[l]); CLEAR uses ca[0]
    logic [3:0]        ca_valid;
    apu_xfer_img_t     da;                   // depth attachment (D32_SFLOAT / D16_UNORM)
    logic              da_valid;
    apu_rast_blend_t [3:0] blend;            // per-attachment blend state
    logic [3:0][31:0]  blend_const;          // f32 blendConstants (dynamic or pipeline-static)
    logic              depth_test, depth_write;
    logic [2:0]        depth_op;             // VkCompareOp 0..7
    logic [31:0]       vertex_count, instance_count, first_vertex, first_instance;  // Draw; DrawIndexed: index_count in vertex_count
    logic [31:0]       first_index; logic signed [31:0] vertex_offset;
    logic [3:0][31:0]  clear_color;          // CLEAR: VkClearColorValue float32[4]; depth clear uses [0]
  } apu_rast_draw_t;
  localparam int unsigned APU_RAST_VS_BATCH = 63;   // vertices per VS batch (multiple of 3; a strip/fan longer than this → UNSUPPORTED in v1)
  localparam int unsigned APU_RAST_FS_BATCH = 64;   // fragments per FS wave batch
  // scratch rings carved once from the private arena (vgpages ALLOC_PRIV), in this order, each 64 B aligned:
  //   vs_in  VS_BATCH*ATTR_STRIDE, vs_out VS_BATCH*VARY_STRIDE, fs_in FS_BATCH*VARY_STRIDE, fs_out FS_BATCH*ATTR_STRIDE
  localparam int unsigned APU_RAST_SCRATCH_BYTES = 65536;
endpackage
