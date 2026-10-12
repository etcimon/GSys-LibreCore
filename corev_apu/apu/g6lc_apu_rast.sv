// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Raster engine (G2a): CLEAR fills one attachment per work item —
// color attachment 0 by default, or the depth attachment `da` when
// da_valid is set (D32_SFLOAT raw f32 words, D16_UNORM packed u16);
// DRAW runs the vertex→raster→fragment chain.  Attribute gather
// reads the vertex buffers into VS input records
// (APU_SH_ATTR_STRIDE, 9 slots — slot 8 carries
// {VertexIndex, InstanceIndex, 0, 0}) honoring per-binding
// inputRate (instance-rate attributes are indexed by the absolute
// instance index), issues an APU_SH_WORK_VS batch per ≤
// APU_RAST_VS_BATCH vertices on the ShaderCore work port, then
// scan-converts each primitive against the VS output records: w≤0
// vertices are skipped (no clipping in v1), NDC+viewport transform
// to 16.8 fixed point, signed-area cull/front-face handling, a
// scissor-clamped bounding box, and a top-left-rule point sample at
// each pixel center.  Triangle list/strip/fan topologies; indexed
// draws fetch UINT16/UINT32 indices (OOB → index 0 + robust) and
// gl_VertexIndex = index + vertexOffset.  With a depth attachment,
// early-Z tests (and optionally writes) the interpolated z before
// the fragment enters the FS batch.  Fragments accumulate into FS
// input records (FragCoord at slot 0, the fs_in_mask locations
// perspective-corrected) and flush in APU_SH_WORK_FS batches of ≤
// APU_RAST_FS_BATCH; the ROP then processes every valid color
// attachment (FS-out location l → ca[l]): per-attachment blending
// in f32 on the fpnew units (dst read-back, VkBlendFactor/Op on
// color and alpha, blendConstants from the draw record), encode to
// R8G8B8A8/B8G8R8A8_UNORM or _SRGB (12-bit linear → 8-bit sRGB via
// APU_SRGB_ENC, alpha stays linear), and byte strobes per
// colorWriteMask.
//
// The scratch rings (vs_in/vs_out/fs_in/fs_out, in the pkg's fixed
// order, each 64 B aligned) are carved once from the device-private
// arena through one lazy vgpages ALLOC_PRIV of
// APU_RAST_SCRATCH_BYTES at the first work record and never freed.
//
// Datapath: exactly one each of fpnew_fma (FP32), the E906
// correctly-rounding fpnew_divsqrt_th_32, and fpnew_cast_multi —
// every float micro-op is sequenced through them by the S_FPS/S_FPW
// call/return pair (same zero-output-register handshake shwave
// uses: in_valid held until in_ready, out_valid is a single-cycle
// pulse).  Discipline: a state that issued an op captures fp_res_q
// at the ENTRY of its return state.  Integer edge/area math is
// plain 64-bit logic.  The big tables are flops in v1: the
// 3-vertex × 8-location × vec4 varying cache (3 KiBit), the
// 64-entry fs_xy fragment table, and the 24-byte gather window —
// first pixel, not throughput.
//
// Timing/area note: the FSM is a slow micro-sequencer (one memory
// word / one float op in flight); the only wide combinational cone
// is the three 64-bit edge multiplies in the scan state.  The flop
// tables above dominate the area (~5 KiBit).
//
// Review checklist: always_ff/always_comb split, async active-low
// reset, no latches, Enable=0 constant-zero netlist.
//
// Known v1 limits: no clipping (w≤0 prims skipped), no stencil, no
// FragDepth output (shmod rejects FS modules declaring builtin 22),
// subpass color reference l → attachment l (identity), primitive
// restart ignored, strips and fans must fit one vertex batch,
// area/edge values are shifted into int32 for the float λ path (the
// exact inside test stays 64-bit), scissor offsets are unsigned.
module g6lc_apu_rast
  import g6lc_apu_mp_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_sh_pkg::*;
  import g6lc_apu_rast_pkg::*;
  import g6lc_apu_vgpages_pkg::*;
  import g6lc_apu_vn_pkg::*;
  import g6lc_apu_srgb_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic              clk_i,
  input  logic              rst_ni,
  input  logic              testmode_i,
  // cmdexec work-port record + draw sideband (rd_i/desc_i/push_*
  // valid with work_valid_i; rd_i is the resolved draw record)
  input  logic              work_valid_i,
  output logic              work_ready_o,
  input  apu_cmdexec_work_t work_i,
  input  apu_rast_draw_t    rd_i,
  input  apu_sh_desc_t      desc_i,
  input  logic [5:0]        push_n_i,
  input  logic [1023:0]     push_i,
  output logic              done_o,
  output apu_sh_done_t      done_pl_o,
  // ShaderCore work port (VS/FS wave batches; desc/push are the
  // latched draw-accept copies replayed with every wave)
  output logic              sh_work_valid_o,
  input  logic              sh_work_ready_i,
  output logic [31:0]       sh_ctype_o,
  output logic [7:0][31:0]  sh_imm_o,
  output logic [2:0]        sh_slot_o,
  output apu_sh_desc_t      sh_desc_o,
  output logic [5:0]        sh_push_n_o,
  output logic [1023:0]     sh_push_o,
  input  logic              sh_done_i,
  input  apu_sh_done_t      sh_done_pl_i,
  // shared aperture memory port (dom=1, single outstanding)
  output logic              mp_req_valid_o,
  input  logic              mp_req_ready_i,
  output apu_mp_req_t       mp_req_o,
  input  logic              mp_rsp_valid_i,
  input  apu_mp_rsp_t       mp_rsp_i,
  // vgpages requester (lazy one-time ALLOC_PRIV of the scratch rings)
  output logic              pg_req_valid_o,
  input  logic              pg_req_ready_i,
  output apu_vgpages_req_t  pg_req_o,
  input  logic              pg_cpl_valid_i,
  output logic              pg_cpl_ready_o,
  input  apu_vgpages_cpl_t  pg_cpl_i,
  output logic              busy_o
);
  if (!Enable) begin : gen_off
    assign work_ready_o = 1'b0;
    assign done_o = 1'b0; assign done_pl_o = '0;
    assign sh_work_valid_o = 1'b0; assign sh_ctype_o = '0;
    assign sh_imm_o = '0; assign sh_slot_o = '0;
    assign sh_desc_o = '0; assign sh_push_n_o = '0; assign sh_push_o = '0;
    assign mp_req_valid_o = 1'b0; assign mp_req_o = '0;
    assign pg_req_valid_o = 1'b0; assign pg_req_o = '0;
    assign pg_cpl_ready_o = 1'b0;
    assign busy_o = 1'b0;
    logic unused;
    assign unused = clk_i | rst_ni | testmode_i | work_valid_i |
                    (|work_i) | (|rd_i) | (|desc_i) | (|push_n_i) |
                    (|push_i) | sh_work_ready_i | sh_done_i |
                    (|sh_done_pl_i) | mp_req_ready_i | mp_rsp_valid_i |
                    (|mp_rsp_i) | pg_req_ready_i | pg_cpl_valid_i |
                    (|pg_cpl_i);
  end else begin : gen_on

    localparam int unsigned VSB  = APU_RAST_VS_BATCH;   // 63
    localparam int unsigned FSB  = APU_RAST_FS_BATCH;   // 64
    localparam int unsigned ASTR = APU_SH_ATTR_STRIDE;  // 144
    localparam int unsigned VSTR = APU_SH_VARY_STRIDE;  // 144
    // scratch carve order (pkg): vs_in, vs_out, fs_in, fs_out,
    // clip_out, clip_tmp — each base 64 B aligned.  The two 9-record
    // clip rings are the S-H ping-pong buffers; clip_out always
    // holds the final polygon (the fan-triangulated records the
    // setup path then reads through the selectable record base).
    localparam int unsigned OFF_VSI = 0;
    localparam int unsigned OFF_VSO = VSB * ASTR;                          // 8064
    localparam int unsigned OFF_FSI = (OFF_VSO + VSB * VSTR + 63) & ~63;   // 17152
    localparam int unsigned OFF_FSO = OFF_FSI + FSB * VSTR;                // 26368
    localparam int unsigned OFF_CLP = (OFF_FSO + FSB * ASTR + 63) & ~63;
    localparam int unsigned OFF_CTP = OFF_CLP + ((9 * VSTR + 63) & ~63);

    typedef enum logic [7:0] {
      S_IDLE,
      S_ALLOC, S_ALLOC_W,
      S_OP,
      S_CLR_X, S_CLR_N,
      S_DR_HW, S_DR_HH, S_DR_DZ,
      S_DR_BATCH,
      S_GA_ISET, S_GA_IBX,
      S_GA_ATTR, S_GA_RD, S_GA_CVT,
      S_GA_U8I, S_GA_U8M, S_GA_U8S,
      S_GA_W0, S_GA_W1, S_GA_S8A, S_GA_S8B,
      S_VS_ISS, S_VS_WAIT,
      S_PR_I0, S_PR_I0B, S_PR_I1, S_PR_I2, S_PR_W,
      S_T0R, S_T1R, S_T2R,
      S_T0X, S_T0Y, S_T0Z, S_T1X, S_T1Y, S_T1Z, S_T2X, S_T2Y, S_T2Z,
      S_T0SA, S_T0SF, S_T0SM, S_T0SC, S_T0YA, S_T0YF, S_T0YM, S_T0YC,
      S_T0ZF,
      S_T1SA, S_T1SF, S_T1SM, S_T1SC, S_T1YA, S_T1YF, S_T1YM, S_T1YC,
      S_T1ZF,
      S_T2SA, S_T2SF, S_T2SM, S_T2SC, S_T2YA, S_T2YF, S_T2YM, S_T2YC,
      S_T2ZF,
      S_PR_AREA, S_PR_SHF, S_PR_BBX,
      S_PR_RCI, S_PR_RCD, S_PR_VF, S_PR_VF2,
      S_SCAN,
      S_F_LE0, S_F_LE1, S_F_LE2,
      S_F_L0, S_F_L1, S_F_L2,
      S_F_P0, S_F_P1, S_F_P2,
      S_F_S0, S_F_S1, S_F_RD,
      S_F_Z1, S_F_Z2, S_F_Z3,
      S_F_PXI, S_F_PXM, S_F_PYI, S_F_PYM,
      S_DZ_RD, S_DZ_DI, S_DZ_DM, S_DZ_C2, S_DZ_WR,
      S_F_W0, S_F_W1,
      S_F_LSET,
      S_F_V0, S_F_V1, S_F_V2, S_F_VS, S_F_VN,
      S_F_VW0, S_F_VW1,
      // G2b clip-space clipper: outcode eval (gw = 4096*w per
      // vertex), then Sutherland–Hodgman over the violated planes
      // ping-ponging {in,out} vertex rings; emit states write
      // VS-out-format records (slot 0 + fs_in_mask locations)
      S_OC_G1, S_OC_G2, S_OC_G3, S_OC,
      S_CP_RP0, S_CP_RP1, S_CP_RP2, S_CP_DD, S_CP_DG,
      S_CP_EDGE, S_CP_ENX,
      S_CP_IT0, S_CP_IT1, S_CP_IT2,
      S_CP_ILP,
      S_CP_IR0, S_CP_IR1, S_CP_IR2, S_CP_IR3,
      S_CP_IS, S_CP_IF, S_CP_IW2, S_CP_IW3, S_CP_IW4,
      S_CP_CB0, S_CP_CB1, S_CP_CBL, S_CP_CBR, S_CP_CBQ, S_CP_CBW,
      S_CP_PDN,
      S_F_PY2, S_F_LNEXT,
      S_FLUSH, S_FS_WAIT,
      S_ROP_R0, S_ROP_R1, S_ROP_R2,
      S_ROP_DRD, S_ROP_DI, S_ROP_DM, S_ROP_DS,
      S_BL_SAT, S_BL_MM,
      S_BL_F1, S_BL_F1B, S_BL_F2, S_BL_F2B,
      S_BL_M1, S_BL_M2, S_BL_OP, S_BL_ST,
      S_ROP_WR, S_ROP_NX,
      S_BATNEXT,
      S_FIN_OK, S_FIN_BAD,
      S_MPW,
      S_FPS, S_FPW
    } st_e;
    st_e st_q;

    // ---- latched record + sideband -------------------------------------
    apu_rast_draw_t dr_q;
    apu_sh_desc_t   desc_q;
    logic [5:0]     push_n_q;
    logic [1023:0]  push_q;
    logic [31:0]    wid_q;
    logic [31:0]    robust_q;
    logic [7:0]     code_q;

    // ---- scratch ring bases (carved once) ------------------------------
    logic           scr_ok_q;
    logic [31:0]    vsi_q, vso_q, fsi_q, fso_q, clp_q, ctp_q;

    // ---- memory-port sequencer ------------------------------------------
    // S_MPW issues one request (held until ready), then waits for the
    // single response; mp_acked_q marks the accepted request.  The
    // windowed gather (mp_ret_q == S_GA_RD) chains word reads; the
    // varying prefetch chains two words via S_PR_VF/S_PR_VF2.
    logic           mp_acked_q, mp_we_q;
    logic [63:0]    mp_addr_q, mp_data_q;
    logic [7:0]     mp_strb_q;
    logic [63:0]    mp_res_q;
    st_e            mp_ret_q;

    // ---- fpnew sequencer --------------------------------------------------
    // fp_kind_q 0=fma 1=dsq 2=cvt; fp_o_q: fma 0=FMADD 1=ADD 2=MUL,
    // cvt 0=I2F 1=F2I; fp_mod_q: fma-ADD subtract / cvt unsigned.
    logic [1:0]     fp_kind_q, fp_o_q;
    logic           fp_mod_q;
    logic [31:0]    fp_a_q, fp_b_q, fp_c_q, fp_res_q;
    st_e            fp_ret_q;
    logic           fp_iss_q;

    // fpnew wiring
    logic [2:0][31:0] fma_ops;
    fpnew_pkg::operation_e fma_op;
    logic                 fma_mod, fma_iv, fma_ir, fma_ov;
    logic [31:0]          fma_res;
    logic [1:0][31:0]     dq_ops;
    fpnew_pkg::operation_e dq_op;
    logic                 dq_iv, dq_ir, dq_ov;
    logic [31:0]          dq_res;
    logic [31:0]          cv_ops;
    fpnew_pkg::operation_e cv_op;
    fpnew_pkg::roundmode_e cv_rnd;
    logic                 cv_mod, cv_iv, cv_ir, cv_ov;
    logic [31:0]          cv_res;

    fpnew_fma #(
      .FpFormat(fpnew_pkg::FP32), .NumPipeRegs(1),
      .PipeConfig(fpnew_pkg::BEFORE),
      .TagType(logic), .AuxType(logic)
    ) i_fma (
      .clk_i, .rst_ni,
      .operands_i(fma_ops), .is_boxed_i(3'b111),
      .rnd_mode_i(fpnew_pkg::RNE), .op_i(fma_op),
      .op_mod_i(fma_mod), .tag_i(1'b0), .mask_i(1'b1), .aux_i(1'b0),
      .in_valid_i(fma_iv), .in_ready_o(fma_ir),
      .flush_i(1'b0),
      .result_o(fma_res), .status_o(),
      .extension_bit_o(), .tag_o(), .mask_o(), .aux_o(),
      .out_valid_o(fma_ov), .out_ready_i(1'b1),
      .busy_o(), .reg_ena_i('0), .early_out_valid_o()
    );
    fpnew_divsqrt_th_32 #(
      .NumPipeRegs(1), .PipeConfig(fpnew_pkg::BEFORE),
      .TagType(logic), .AuxType(logic)
    ) i_dsq (
      .clk_i, .rst_ni,
      .operands_i(dq_ops),
      .is_boxed_i({fpnew_pkg::NUM_FP_FORMATS{2'b11}}),
      .rnd_mode_i(fpnew_pkg::RNE), .op_i(dq_op),
      .tag_i(1'b0), .mask_i(1'b1), .aux_i(1'b0),
      .in_valid_i(dq_iv), .in_ready_o(dq_ir),
      .flush_i(1'b0),
      .result_o(dq_res), .status_o(),
      .extension_bit_o(), .tag_o(), .mask_o(), .aux_o(),
      .out_valid_o(dq_ov), .out_ready_i(1'b1),
      .busy_o(), .reg_ena_i('0), .early_out_valid_o()
    );
    fpnew_cast_multi #(
      // fmt_logic_t is [0:4]: index 0 (FP32) is the MSB;
      // ifmt_logic_t is [0:3]: index 2 (INT32)
      .FpFmtConfig(5'b10000), .IntFmtConfig(4'b0010),
      .NumPipeRegs(1), .PipeConfig(fpnew_pkg::BEFORE),
      .TagType(logic), .AuxType(logic)
    ) i_cvt (
      .clk_i, .rst_ni,
      .operands_i(cv_ops), .is_boxed_i(1'b1),
      .rnd_mode_i(cv_rnd), .op_i(cv_op), .op_mod_i(cv_mod),
      .src_fmt_i(fpnew_pkg::FP32), .dst_fmt_i(fpnew_pkg::FP32),
      .int_fmt_i(fpnew_pkg::INT32),
      .tag_i(1'b0), .mask_i(1'b1), .aux_i(1'b0),
      .in_valid_i(cv_iv), .in_ready_o(cv_ir), .flush_i(1'b0),
      .result_o(cv_res), .status_o(),
      .extension_bit_o(), .tag_o(), .mask_o(), .aux_o(),
      .out_valid_o(cv_ov), .out_ready_i(1'b1),
      .busy_o(), .reg_ena_i('0), .early_out_valid_o()
    );

    assign fma_ops = {fp_c_q, fp_b_q, fp_a_q};
    assign fma_op  = (fp_o_q == 2'd0) ? fpnew_pkg::FMADD :
                     (fp_o_q == 2'd1) ? fpnew_pkg::ADD : fpnew_pkg::MUL;
    assign fma_mod = fp_mod_q;
    assign fma_iv  = fp_iss_q && fp_kind_q == 2'd0;
    assign dq_ops  = {fp_b_q, fp_a_q};
    assign dq_op   = fpnew_pkg::DIV;
    assign dq_iv   = fp_iss_q && fp_kind_q == 2'd1;
    assign cv_ops  = fp_a_q;
    assign cv_op   = (fp_o_q == 2'd0) ? fpnew_pkg::I2F : fpnew_pkg::F2I;
    assign cv_rnd  = fpnew_pkg::RNE;
    assign cv_mod  = fp_mod_q;
    assign cv_iv   = fp_iss_q && fp_kind_q == 2'd2;

    // ---- helpers --------------------------------------------------------
    // fp32 -> UNORM8, clamped, round-to-nearest (same rule as
    // g6lc_apu_xfer::f_f32_u8 — v = f*255)
    function automatic logic [7:0] f_f32_u8(input logic [31:0] f);
      logic [39:0] p;
      logic [8:0]  sh;
      p  = 40'({1'b1, f[22:0]}) * 40'd255;
      sh = 9'd150 - {1'b0, f[30:23]};
      if (f[31])              return 8'h00;
      if (f[30:23] == 8'h00)  return 8'h00;   // subnormal/zero
      if (f[30:23] >= 8'd127) return 8'hff;   // f >= 1.0 / inf / nan
      return 8'((p + (40'h1 << (sh - 9'd1))) >> sh);
    endfunction

    // fp32 -> UNORM16, clamped, round-to-nearest (f*65535 — same
    // structure as f_f32_u8; used by the D16 depth clear/write)
    function automatic logic [15:0] f_f32_u16(input logic [31:0] f);
      logic [39:0] p;
      logic [8:0]  sh;
      p  = 40'({1'b1, f[22:0]}) * 40'd65535;
      sh = 9'd150 - {1'b0, f[30:23]};
      if (f[31])              return 16'h0000;
      if (f[30:23] == 8'h00)  return 16'h0000;
      if (f[30:23] >= 8'd127) return 16'hFFFF;
      return 16'((p + (40'h1 << (sh - 9'd1))) >> sh);
    endfunction

    // fp32 -> 12-bit linear index for the sRGB encode LUT
    // (clamp*4095 RNE; APU_SRGB_ENC is contracted to u12)
    function automatic logic [11:0] f_f32_u12(input logic [31:0] f);
      logic [39:0] p;
      logic [8:0]  sh;
      p  = 40'({1'b1, f[22:0]}) * 40'd4095;
      sh = 9'd150 - {1'b0, f[30:23]};
      if (f[31])              return 12'h000;
      if (f[30:23] == 8'h00)  return 12'h000;
      if (f[30:23] >= 8'd127) return 12'hFFF;
      return 12'((p + (40'h1 << (sh - 9'd1))) >> sh);
    endfunction

    // f32 a < b on magnitudes (NaN → false; -0 == +0)
    function automatic logic f_f32_lt(input logic [31:0] a,
                                      input logic [31:0] b);
      if ({a[30:0], b[30:0]} == 62'h0) return 1'b0;
      if (a[31] != b[31])              return a[31];
      return a[31] ? (a > b) : (a < b);
    endfunction

    // depth compare (VkCompareOp 0..7) on f32 values
    function automatic logic f_dcmp(input logic [2:0] op,
                                    input logic [31:0] a,
                                    input logic [31:0] b);
      unique case (op)
        3'd0:     f_dcmp = 1'b0;                       // NEVER
        3'd1:     f_dcmp = f_f32_lt(a, b);             // LESS
        3'd2:     f_dcmp = (a == b);                   // EQUAL
        3'd3:     f_dcmp = f_f32_lt(a, b) || (a == b); // LEQUAL
        3'd4:     f_dcmp = f_f32_lt(b, a);             // GREATER
        3'd5:     f_dcmp = (a != b);                   // NOTEQUAL
        3'd6:     f_dcmp = f_f32_lt(b, a) || (a == b); // GEQUAL
        default:  f_dcmp = 1'b1;                       // ALWAYS
      endcase
    endfunction

    // attachment row pitch — the Xfer device-linear rule
    // (align(w*bpp,64)); bpp is 4 for the color/D32 formats and 2
    // for D16_UNORM.
    function automatic logic [31:0] f_pitch2(input logic [15:0] w,
                                             input logic [2:0]  bpp);
      return ((32'(w) * 32'(bpp)) + 32'd63) & ~32'd63;
    endfunction

    // color-attachment format legality
    function automatic logic f_cfmt_ok(input logic [7:0] f);
      return f == 8'(APU_IMG_FMT_R8G8B8A8_UNORM) ||
             f == 8'(APU_IMG_FMT_B8G8R8A8_UNORM) ||
             f == 8'(APU_IMG_FMT_R8G8B8A8_SRGB)  ||
             f == 8'(APU_IMG_FMT_B8G8R8A8_SRGB);
    endfunction
    function automatic logic f_dfmt_ok(input logic [7:0] f);
      return f == 8'(APU_IMG_FMT_D32_SFLOAT) ||
             f == 8'(APU_IMG_FMT_D16_UNORM);
    endfunction
    // sRGB formats share the BGRA/RGBA byte orders
    function automatic logic f_is_srgb(input logic [7:0] f);
      return f == 8'(APU_IMG_FMT_R8G8B8A8_SRGB) ||
             f == 8'(APU_IMG_FMT_B8G8R8A8_SRGB);
    endfunction
    function automatic logic f_is_bgr(input logic [7:0] f);
      return f == 8'(APU_IMG_FMT_B8G8R8A8_UNORM) ||
             f == 8'(APU_IMG_FMT_B8G8R8A8_SRGB);
    endfunction

    // attribute byte count per accepted format (0 = unsupported)
    function automatic logic [4:0] f_asz(input logic [7:0] f);
      unique case (f)
        APU_RAST_VF_R32_SFLOAT:    f_asz = 5'd4;
        APU_RAST_VF_RG32_SFLOAT:   f_asz = 5'd8;
        APU_RAST_VF_RGB32_SFLOAT:  f_asz = 5'd12;
        APU_RAST_VF_RGBA32_SFLOAT: f_asz = 5'd16;
        APU_RAST_VF_RGBA8_UNORM:   f_asz = 5'd4;
        default:                   f_asz = 5'd0;
      endcase
    endfunction

    // blend-factor operand base for factor code f on component c
    // (the ONE_MINUS_* variants share the code's base and are flagged
    // by f_fminus; SRC_ALPHA_SATURATE uses the precomputed 1-dst.a)
    function automatic logic f_fminus(input logic [4:0] f);
      return f == APU_RAST_BF_OM_SRC_COLOR  ||
             f == APU_RAST_BF_OM_DST_COLOR  ||
             f == APU_RAST_BF_OM_SRC_ALPHA  ||
             f == APU_RAST_BF_OM_DST_ALPHA  ||
             f == APU_RAST_BF_OM_CONST_COLOR ||
             f == APU_RAST_BF_OM_CONST_ALPHA;
    endfunction
    // f32 strictly positive and finite (w > 0 keeps the prim)
    function automatic logic f_wpos(input logic [31:0] w);
      return !w[31] && (w[30:0] != 31'h0) && (w[30:23] != 8'hFF);
    endfunction

    // highest set bit of |v| (for the λ shift); 63 = no bit found
    function automatic logic [5:0] f_msb(input logic [63:0] v);
      logic [63:0] a;
      a = v[63] ? ~v + 64'd1 : v;
      f_msb = 6'd63;
      for (int i = 62; i >= 0; i--)
        if (a[i] && f_msb == 6'd63) f_msb = 6'(i);
    endfunction

    // ---- state -----------------------------------------------------------
    // CLEAR
    logic [31:0]  clr_pix_q;
    logic [15:0]  cy_q, cx_q;
    // DRAW setup
    logic [31:0]  vphw_q, vphh_q, vpdz_q;   // vp.w/2, vp.h/2, maxz-minz
    logic [31:0]  inst_q, bat_q;
    logic [5:0]   nv_q, j_q;
    logic [2:0]   a_q;
    logic [1:0]   i_q;                      // window word cursor
    logic [1:0]   t_q;                      // triangle vertex cursor
    logic signed [31:0] ib_i;               // current vertex index
    logic [191:0] win_q;                    // gather window (3 words)
    logic [1:0]   wn_q;                     // words still to read
    logic [31:0]  caddr_q, gbase_q, gsize_q;// gather addr / bounds
    logic [4:0]   csz_q;
    st_e          gret_q;
    logic [3:0][31:0] conv_q;               // converted attr / frag tmp
    logic [2:0]   c_q;                      // component cursor
    // primitive transform results
    logic [3:0][31:0] pos_q [3];            // raw Position x,y,z,w
    logic [31:0]  vrw_q [3];                // 1/w
    logic [31:0]  vnd_q [3][3];             // ndc x,y,z
    logic [31:0]  vz_q  [3];                // viewport z
    logic signed [31:0] vxi_q [3], vyi_q [3]; // 16.8 screen coords
    // edges: E_k anchored at vertex (k+1)%3, direction to (k+2)%3
    logic signed [31:0] ex_q [3], ey_q [3], edx_q [3], edy_q [3];
    logic [2:0]   tl_q;
    logic signed [63:0] area_q;
    logic [5:0]   shf_q;
    logic [31:0]  rcpa_q;
    logic [15:0]  bx0_q, bx1_q, by0_q, by1_q;
    logic [15:0]  sx_q, sy_q;               // scan cursor
    logic [5:0]   p_q;                      // primitive cursor
    logic [5:0]   f_q;                      // queued frags (0..FSB-1)
    logic [6:0]   nf_q;                     // in-flight frag count
    // per-fragment temporaries
    logic signed [63:0] e_q [3];
    logic [31:0]  lam_q [3], pv_q [3], rs_q, fz_q;
    logic [3:0]   lc_q;                     // location cursor (0..8)
    // fragment tables (flops, v1 — see header note)
    logic [31:0]  fsxy_q [FSB];             // {py[15:0], px[15:0]}
    logic         fs_help_q [FSB];          // G2b helper-lane flags
    logic [31:0]  var_q [3][8][4];          // [vert][loc][comp] cache
    logic [7:0]   varm_q;                   // locs fetched this prim
    // G2b quad scan: (sx_q,sy_q) is the even-aligned 2x2 block base,
    // (px_q,py_q) the pixel of the lane under construction; lane_q
    // is the 0..3 lane cursor inside the block and help_q its flag
    logic [1:0]   lane_q;
    logic         help_q;
    logic [15:0]  px_q, py_q;
    logic         front_q;                  // accepted prim's front bit
    logic         vsw_q;                    // geom slots 1/2 swapped this prim
    // ---- G2b clip-space clipper state -----------------------------------
    // Clip planes (bit order): 0 near z>=0, 1 far z<=w, 2 w>=1e-5,
    // 3 |x|<=4096w, 4 |y|<=4096w — outcodes + the violating-plane mask
    localparam logic [31:0] CLIP_EPS = 32'h3727C5AC;  // 1e-5f
    localparam logic [31:0] CLIP_GB  = 32'h45800000;  // 4096.0f
    logic [4:0]   oc_q [3];                 // per-vertex outcodes
    logic [31:0]  gw_q [3];                 // 4096*w per vertex
    logic [4:0]   cpm_q;                    // planes still to clip
    logic [2:0]   cpl_q;                    // current plane
    logic [3:0]   cn_q, co_q;               // in-poly / out-poly counts
    logic [3:0]   ce_q, ceb_q;              // edge cursor + its b vertex
    logic [31:0]  cib_q, cob_q;             // in/out ring byte bases
    logic         cmap_q;                   // in-rec index = f_pi (vso)
    logic         cslot_q;                  // emit cursor: 1 = slot 0
    logic         cemitb_q;                 // emit copy of b after interp
    logic [31:0]  cpos_q [9][4];            // in-poly positions
    logic [31:0]  cdis_q [9];               // in-poly plane distances
    logic [8:0]   cin_q;                    // in-poly inside mask
    logic [31:0]  cva_q [4], cvb_q [4];     // a/b varying staging
    logic [31:0]  ctt_q;                    // edge-crossing t
    logic         clip_q;                   // fan-triangulate clip_out
    logic [3:0]   cfan_q;                   // fan cursor (tri = 0,ci,ci+1)
    logic [3:0]   cpn_q;                    // final polygon vertex count
    // early-Z / ROP
    logic [31:0]  dz_q;                     // decoded depth texel
    logic [5:0]   r_q;
    logic [1:0]   at_q;                     // attachment cursor (0..3)
    logic [3:0][31:0] src_q;                // fs_out color (f32)
    logic [3:0][31:0] dst_q;                // decoded dst texel (f32)
    logic [3:0][31:0] res_q;                // blend result / src pass
    logic [31:0]  sf_q, df_q;               // blend factors
    logic [31:0]  bm1_q, bm2_q;             // s*sf, d*df products
    logic [31:0]  omd3_q;                   // 1 - dst.a (SATURATE)
    // flush return state + sticky shader-done latch
    st_e          flr_q;
    logic         shd_q;
    apu_sh_done_t shdp_q;

    // blend factor base value: picks src/dst colour, alpha or the
    // blend constant per the factor id (declared after the ROP regs
    // so slang sees the operands before use)
    function automatic logic [31:0] f_fbase(input logic [4:0] f,
                                            input logic [1:0] c);
      unique case (f)
        APU_RAST_BF_ZERO:          f_fbase = 32'h00000000;
        APU_RAST_BF_ONE:           f_fbase = 32'h3F800000;
        APU_RAST_BF_SRC_COLOR,
        APU_RAST_BF_OM_SRC_COLOR:  f_fbase = src_q[c];
        APU_RAST_BF_DST_COLOR,
        APU_RAST_BF_OM_DST_COLOR:  f_fbase = dst_q[c];
        APU_RAST_BF_SRC_ALPHA,
        APU_RAST_BF_OM_SRC_ALPHA:  f_fbase = src_q[3];
        APU_RAST_BF_DST_ALPHA,
        APU_RAST_BF_OM_DST_ALPHA:  f_fbase = dst_q[3];
        APU_RAST_BF_CONST_COLOR,
        APU_RAST_BF_OM_CONST_COLOR: f_fbase = dr_q.blend_const[c];
        APU_RAST_BF_CONST_ALPHA,
        APU_RAST_BF_OM_CONST_ALPHA: f_fbase = dr_q.blend_const[3];
        default: // SRC_ALPHA_SATURATE: min(As, 1-Ad) on RGB, 1 on alpha
          f_fbase = (c == 2'd3) ? 32'h3F800000
                    : (src_q[3][31] ? src_q[3]
                       : (f_f32_lt(omd3_q, src_q[3]) ? omd3_q
                          : src_q[3]));
      endcase
    endfunction

    // primitive vertex slot (batch-local): list steps 3; strip steps 1
    // and swaps slots 1/2 on odd primitives to keep the winding; fan
    // steps 1 anchored at vertex 0.  Clip mode fan-triangulates the
    // clipped polygon: tri (0, cfan, cfan+1) of the clip_out ring.
    function automatic logic [5:0] f_pi(input logic [1:0] t);
      if (clip_q)
        f_pi = (t == 2'd0) ? 6'd0 : {2'b0, cfan_q} + 6'(t) - 6'd1;
      else if (dr_q.topology == 8'd5)
        f_pi = (t == 2'd0) ? 6'd0 : p_q + 6'(t);
      else if (dr_q.topology == 8'd4 && p_q[0])
        f_pi = p_q + 6'(t == 2'd0 ? 0 : t == 2'd1 ? 2 : 1);
      else
        f_pi = p_q + 6'(t);
    endfunction

    // ---- G2b clip helpers -------------------------------------------------
    // 5-bit outcode for clip-space vertex p with guard product gw=4096*w:
    //   0 near z<0 | 1 far z>w | 2 w<1e-5 | 3 |x|>gw | 4 |y|>gw
    function automatic logic [4:0] f_oc(input logic [3:0][31:0] p,
                                        input logic [31:0] gw);
      f_oc[0] = f_f32_lt(p[2], 32'h0);
      f_oc[1] = f_f32_lt(p[3], p[2]);
      f_oc[2] = f_f32_lt(p[3], CLIP_EPS);
      f_oc[3] = f_f32_lt(gw, {1'b0, p[0][30:0]});
      f_oc[4] = f_f32_lt(gw, {1'b0, p[1][30:0]});
    endfunction

    // byte address of in-polygon vertex i's record: the first clip
    // plane reads the VS-out ring through the topology map; later
    // planes read the contiguous clip rings
    function automatic logic [63:0] f_crec(input logic [3:0] i);
      f_crec = {32'h0, cib_q} +
               64'(cmap_q ? f_pi(i[1:0]) : {2'b0, i}) * 64'(VSTR);
    endfunction

    // next violated plane after cpl_q (7 = none — mask bits above)
    function automatic logic [2:0] f_npl(input logic [4:0] m,
                                         input logic [2:0] c);
      f_npl = 3'd7;
      for (int p = 4; p >= 0; p--)
        if (p > int'(c) && m[p]) f_npl = 3'(p);
    endfunction

    // prim done: advance the topo cursor, or the clip fan cursor while
    // fan tris of the clipped polygon remain (fan ends the whole prim)
    task automatic t_pd;
      if (clip_q) begin
        if (cfan_q >= cpn_q - 4'd2) begin
          clip_q <= 1'b0;
          if (dr_q.topology != 8'd3) p_q <= p_q + 6'd1;
          else                       p_q <= p_q + 6'd3;
        end else
          cfan_q <= cfan_q + 4'd1;
      end else begin
        if (dr_q.topology != 8'd3) p_q <= p_q + 6'd1;
        else                       p_q <= p_q + 6'd3;
      end
    endtask

    // ---- combinational views -------------------------------------------
    // clear target: the depth attachment wins a depth-clear record,
    // else color attachment 0 (one CLEAR work per attachment)
    wire        clr_is_d = dr_q.da_valid;
    wire [31:0] clr_base = clr_is_d ? dr_q.da.base : dr_q.ca[0].base;
    wire [15:0] clr_w    = clr_is_d ? dr_q.da.w    : dr_q.ca[0].w;
    wire [15:0] clr_h    = clr_is_d ? dr_q.da.h    : dr_q.ca[0].h;
    wire [2:0]  clr_bpp  = (clr_is_d &&
                          dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM))
                         ? 3'd2 : 3'd4;
    wire [31:0] clr_pitch = f_pitch2(clr_w, clr_bpp);
    wire [31:0] clr_rowb = 32'(clr_w) * 32'(clr_bpp);
    // clear-target format legality (DRAW legality is per-attachment
    // in S_OP)
    wire        fmt_ok   = clr_is_d
                           ? f_dfmt_ok(dr_q.da.fmt)
                           : f_cfmt_ok(dr_q.ca[0].fmt);
    // pitch of the color attachment under the ROP cursor, and of the
    // depth attachment (early-Z)
    wire [31:0] cpitch_w = f_pitch2(dr_q.ca[at_q].w, 3'd4);
    wire [31:0] dpitch_w = f_pitch2(
        dr_q.da.w, dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM)
                   ? 3'd2 : 3'd4);
    // current scan pixel center, 16.8 fixed
    wire signed [31:0] cpx = {16'(sx_q), 8'd0} + 32'd128;
    wire signed [31:0] cpy = {16'(sy_q), 8'd0} + 32'd128;
    // edge functions at the pixel center (edge opposite vertex k,
    // anchored at (k+1)%3 toward (k+2)%3):  E = d × (P - anchor),
    // interior-positive for the post-swap positive-area winding, so
    // E_k / area is exactly the barycentric weight of vertex k
    logic signed [63:0] ec [3];
    always_comb begin
      for (int k = 0; k < 3; k++)
        ec[k] = 64'(edx_q[k]) * (64'(cpy) - 64'(ey_q[k])) -
                64'(edy_q[k]) * (64'(cpx) - 64'(ex_q[k]));
    end
    wire in_tri = ((ec[0] > 64'sd0) || (ec[0] == 64'sd0 && tl_q[0])) &&
                  ((ec[1] > 64'sd0) || (ec[1] == 64'sd0 && tl_q[1])) &&
                  ((ec[2] > 64'sd0) || (ec[2] == 64'sd0 && tl_q[2]));
    // edge-function value at block lane l of the current 2x2 block
    // (the lane offsets shift the 16.8 sample point by one pixel)
    function automatic logic signed [63:0] f_le(
        input int k, input logic [1:0] l);
      f_le = ec[k] + (l[0] ? -(64'(edy_q[k]) <<< 8) : 64'sd0)
                   + (l[1] ?  (64'(edx_q[k]) <<< 8) : 64'sd0);
    endfunction
    // coverage test (same edge+top-left rule as in_tri) for lane l;
    // lanes outside the scissor-clamped bbox are never covered (the
    // even-aligned block may reach one pixel past the box)
    function automatic logic f_lcov(input logic [1:0] l);
      logic signed [63:0] e [3];
      logic [15:0] lx, ly;
      for (int k = 0; k < 3; k++) e[k] = f_le(k, l);
      lx = sx_q + {15'h0, l[0]};
      ly = sy_q + {15'h0, l[1]};
      f_lcov = ((e[0] > 64'sd0) || (e[0] == 64'sd0 && tl_q[0])) &&
               ((e[1] > 64'sd0) || (e[1] == 64'sd0 && tl_q[1])) &&
               ((e[2] > 64'sd0) || (e[2] == 64'sd0 && tl_q[2])) &&
               lx >= bx0_q && lx <= bx1_q &&
               ly >= by0_q && ly <= by1_q;
    endfunction
    // block coverage: 1 when any of the four 2x2 pixels is covered;
    // uncovered lanes of a hit block emit helper invocations
    wire blk_hit = f_lcov(2'd0) || f_lcov(2'd1) ||
                   f_lcov(2'd2) || f_lcov(2'd3);
    // signed area of the current vertex set (standard shoelace in
    // framebuffer coordinates)
    wire signed [63:0] area_w =
        (64'(vxi_q[1]) - 64'(vxi_q[0])) * (64'(vyi_q[2]) - 64'(vyi_q[0])) -
        (64'(vxi_q[2]) - 64'(vxi_q[0])) * (64'(vyi_q[1]) - 64'(vyi_q[0]));
    // Vulkan face orientation: the spec's signed area is the NEGATED
    // shoelace (a = -1/2 * sum x_i*y_{i+1} - x_{i+1}*y_i), so CCW
    // front-facing means area < 0 here and CW means area > 0.
    wire front_w = (area_q < 64'sd0) == dr_q.front_ccw;
    // vertex bbox (16.8 -> covered pixel centers)
    wire signed [31:0] xmin_w =
        vxi_q[0] < vxi_q[1]
        ? (vxi_q[0] < vxi_q[2] ? vxi_q[0] : vxi_q[2])
        : (vxi_q[1] < vxi_q[2] ? vxi_q[1] : vxi_q[2]);
    wire signed [31:0] xmax_w =
        vxi_q[0] > vxi_q[1]
        ? (vxi_q[0] > vxi_q[2] ? vxi_q[0] : vxi_q[2])
        : (vxi_q[1] > vxi_q[2] ? vxi_q[1] : vxi_q[2]);
    wire signed [31:0] ymin_w =
        vyi_q[0] < vyi_q[1]
        ? (vyi_q[0] < vyi_q[2] ? vyi_q[0] : vyi_q[2])
        : (vyi_q[1] < vyi_q[2] ? vyi_q[1] : vyi_q[2]);
    wire signed [31:0] ymax_w =
        vyi_q[0] > vyi_q[1]
        ? (vyi_q[0] > vyi_q[2] ? vyi_q[0] : vyi_q[2])
        : (vyi_q[1] > vyi_q[2] ? vyi_q[1] : vyi_q[2]);
    wire signed [31:0] vlo_x = xmin_w >>> 8;
    wire signed [31:0] vhi_x = (xmax_w - 32'sd128) >>> 8;
    wire signed [31:0] vlo_y = ymin_w >>> 8;
    wire signed [31:0] vhi_y = (ymax_w - 32'sd128) >>> 8;
    // scissor ∩ attachment clamp
    wire signed [31:0] slo_x = 32'({16'h0, dr_q.sc_x});
    wire signed [31:0] slo_y = 32'({16'h0, dr_q.sc_y});
    wire signed [31:0] shi_x = slo_x + 32'({16'h0, dr_q.sc_w}) - 32'sd1;
    wire signed [31:0] shi_y = slo_y + 32'({16'h0, dr_q.sc_h}) - 32'sd1;
    wire signed [31:0] whi_x = 32'({16'h0, dr_q.ca[0].w}) - 32'sd1;
    wire signed [31:0] whi_y = 32'({16'h0, dr_q.ca[0].h}) - 32'sd1;
    wire signed [31:0] mxlo_x = vlo_x > slo_x ? vlo_x : slo_x;
    wire signed [31:0] mxhi_x = vhi_x < shi_x ? vhi_x : shi_x;
    wire signed [31:0] mxlo_y = vlo_y > slo_y ? vlo_y : slo_y;
    wire signed [31:0] mxhi_y = vhi_y < shi_y ? vhi_y : shi_y;
    wire signed [31:0] blo_x = mxlo_x < 0 ? 0 : mxlo_x;
    wire signed [31:0] blo_y = mxlo_y < 0 ? 0 : mxlo_y;
    wire signed [31:0] bhi_x = mxhi_x > whi_x ? whi_x : mxhi_x;
    wire signed [31:0] bhi_y = mxhi_y > whi_y ? whi_y : mxhi_y;
    wire              bbox_empty = bhi_x < blo_x || bhi_y < blo_y;
    // current attribute fields
    wire [7:0]  a_fmt = dr_q.attr[a_q].fmt;
    wire [1:0]  a_bnd = dr_q.attr[a_q].binding;
    wire [31:0] a_off = 32'({18'h0, dr_q.attr[a_q].offset});
    wire        attr_ok = dr_q.attr[a_q].valid && f_asz(a_fmt) != 5'd0;
    // gather-range bounds check (signed: a negative vertex index must
    // not wrap below the buffer base)
    wire        g_oob = $signed(caddr_q) < $signed(gbase_q) ||
                        caddr_q + {27'h0, csz_q} > gbase_q + gsize_q;
    // fragment pixel coordinates (fsxy widened to 16+16)
    wire [15:0] fr_px = fsxy_q[r_q][15:0];
    wire [15:0] fr_py = fsxy_q[r_q][31:16];
    // ROP encode: comp c -> byte (sRGB LUT on rgb comps of sRGB
    // formats; linear elsewhere)
    function automatic logic [7:0] f_enc8(input logic [7:0] fmt,
                                          input logic [1:0] c,
                                          input logic [31:0] f);
      if (f_is_srgb(fmt) && c != 2'd3)
        return APU_SRGB_ENC[f_f32_u12(f)];
      return f_f32_u8(f);
    endfunction
    // packed dst-byte position for comp c under the attachment's
    // channel order
    function automatic logic [1:0] f_cbyte(input logic [7:0] fmt,
                                           input logic [1:0] c);
      if (f_is_bgr(fmt))
        return (c == 2'd0) ? 2'd2 : (c == 2'd1) ? 2'd1
               : (c == 2'd2) ? 2'd0 : 2'd3;
      return c;
    endfunction
    wire [7:0] rop_b0 = f_enc8(dr_q.ca[at_q].fmt, 2'd0, res_q[0]);
    wire [7:0] rop_b1 = f_enc8(dr_q.ca[at_q].fmt, 2'd1, res_q[1]);
    wire [7:0] rop_b2 = f_enc8(dr_q.ca[at_q].fmt, 2'd2, res_q[2]);
    wire [7:0] rop_b3 = f_enc8(dr_q.ca[at_q].fmt, 2'd3, res_q[3]);
    wire [31:0] rop_pix = f_is_bgr(dr_q.ca[at_q].fmt)
        ? {rop_b3, rop_b0, rop_b1, rop_b2}
        : {rop_b3, rop_b2, rop_b1, rop_b0};
    // byte strobes for the pixel under the ROP cursor
    wire [7:0] rop_strb = {4'h0, dr_q.blend[at_q].mask}
                          << {fr_px[0], 2'b00};
    // early-Z clamps the interpolated z into [0,1] for test+write
    wire [31:0] zc_w = fz_q[31] ? 32'h0
                       : (f_f32_lt(32'h3F800000, fz_q) ? 32'h3F800000
                          : fz_q);
    // blend-state field selects for the comp under the blend cursor
    wire [4:0] bsf_w = (c_q[1:0] == 2'd3) ? dr_q.blend[at_q].src_a
                                        : dr_q.blend[at_q].src_c;
    wire [4:0] bdf_w = (c_q[1:0] == 2'd3) ? dr_q.blend[at_q].dst_a
                                        : dr_q.blend[at_q].dst_c;
    wire [2:0] bop_w = (c_q[1:0] == 2'd3) ? dr_q.blend[at_q].op_a
                                        : dr_q.blend[at_q].op_c;

    assign busy_o = st_q != S_IDLE;
    assign work_ready_o = st_q == S_IDLE;
    assign mp_req_valid_o = st_q == S_MPW && !mp_acked_q;
    assign mp_req_o = '{dom: 1'b1, we: mp_we_q, addr: mp_addr_q,
                       wdata: mp_data_q, wstrb: mp_strb_q};
    assign pg_req_valid_o = st_q == S_ALLOC;
    assign pg_req_o = '{op: APU_VGPAGES_OP_ALLOC_PRIV, base: '0,
                       excl_hi: '0, bytes: 32'(APU_RAST_SCRATCH_BYTES)};
    assign pg_cpl_ready_o = st_q == S_ALLOC_W;
    // shv_q: registered work-valid — the ctype/imm/slot payload is
    // written in the same state entry, so valid is delayed one cycle;
    // a peer that is ready on entry never latches a stale record.
    logic           shv_q;
    assign sh_work_valid_o = shv_q;
    assign sh_desc_o = desc_q;
    assign sh_push_n_o = push_n_q;
    assign sh_push_o = push_q;

    // ---- the FSM ---------------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        st_q <= S_IDLE;
        dr_q <= '0; desc_q <= '0; push_n_q <= '0; push_q <= '0;
        wid_q <= '0; robust_q <= '0; code_q <= '0;
        scr_ok_q <= 1'b0;
        vsi_q <= '0; vso_q <= '0; fsi_q <= '0; fso_q <= '0;
        mp_acked_q <= 1'b0; mp_we_q <= 1'b0; mp_addr_q <= '0;
        mp_data_q <= '0; mp_strb_q <= '0; mp_res_q <= '0;
        mp_ret_q <= S_IDLE;
        fp_kind_q <= '0; fp_o_q <= '0; fp_mod_q <= 1'b0;
        fp_a_q <= '0; fp_b_q <= '0; fp_c_q <= '0; fp_res_q <= '0;
        fp_ret_q <= S_IDLE; fp_iss_q <= 1'b0;
        clr_pix_q <= '0; cy_q <= '0; cx_q <= '0;
        vphw_q <= '0; vphh_q <= '0; vpdz_q <= '0;
        inst_q <= '0; bat_q <= '0; nv_q <= '0; j_q <= '0; a_q <= '0;
        i_q <= '0; t_q <= '0; ib_i <= '0; win_q <= '0; wn_q <= '0;
        caddr_q <= '0; gbase_q <= '0; gsize_q <= '0; csz_q <= '0;
        gret_q <= S_IDLE;
        conv_q <= '0; c_q <= '0;
        for (int v = 0; v < 3; v++) begin
          pos_q[v] <= '0; vrw_q[v] <= '0; vz_q[v] <= '0;
          vxi_q[v] <= '0; vyi_q[v] <= '0;
          vnd_q[v][0] <= '0; vnd_q[v][1] <= '0; vnd_q[v][2] <= '0;
          ex_q[v] <= '0; ey_q[v] <= '0; edx_q[v] <= '0; edy_q[v] <= '0;
          e_q[v] <= '0; lam_q[v] <= '0; pv_q[v] <= '0;
        end
        tl_q <= '0; area_q <= '0; shf_q <= '0; rcpa_q <= '0;
        vsw_q <= 1'b0;
        bx0_q <= '0; bx1_q <= '0; by0_q <= '0; by1_q <= '0;
        sx_q <= '0; sy_q <= '0; p_q <= '0; f_q <= '0; nf_q <= '0;
        rs_q <= '0; fz_q <= '0; lc_q <= '0;
        for (int i = 0; i < FSB; i++) begin
          fsxy_q[i] <= '0; fs_help_q[i] <= 1'b0;
        end
        for (int v = 0; v < 3; v++)
          for (int l = 0; l < 8; l++)
            for (int c = 0; c < 4; c++) var_q[v][l][c] <= '0;
        varm_q <= '0;
        lane_q <= '0; help_q <= 1'b0; px_q <= '0; py_q <= '0;
        front_q <= 1'b0;
        for (int v = 0; v < 3; v++) begin
          oc_q[v] <= '0; gw_q[v] <= '0;
        end
        cpm_q <= '0; cpl_q <= '0; cn_q <= '0; co_q <= '0;
        ce_q <= '0; ceb_q <= '0; cib_q <= '0; cob_q <= '0;
        clp_q <= '0; ctp_q <= '0;
        cmap_q <= 1'b0; cslot_q <= 1'b0; cemitb_q <= 1'b0;
        for (int v = 0; v < 9; v++) begin
          cpos_q[v] <= '{default: '0};
          cdis_q[v] <= '0;
        end
        cin_q <= '0;
        cva_q <= '{default: '0}; cvb_q <= '{default: '0};
        ctt_q <= '0; clip_q <= 1'b0; cfan_q <= '0; cpn_q <= '0;
        dz_q <= '0;
        r_q <= '0; at_q <= '0;
        src_q <= '0; dst_q <= '0; res_q <= '0;
        sf_q <= '0; df_q <= '0; bm1_q <= '0; bm2_q <= '0; omd3_q <= '0;
        flr_q <= S_IDLE;
        shd_q <= 1'b0; shdp_q <= '0; shv_q <= 1'b0;
        done_o <= 1'b0; done_pl_o <= '0;
      end else begin
        done_o <= 1'b0;
        if (sh_done_i) begin
          shd_q <= 1'b1; shdp_q <= sh_done_pl_i;
        end
        unique case (st_q)
          // ============================================================
          S_IDLE: begin
            if (work_valid_i) begin
              dr_q <= rd_i;
              desc_q <= desc_i;
              push_n_q <= push_n_i;
              push_q <= push_i;
              wid_q <= wid_q + 32'd1;
              robust_q <= '0;
              shd_q <= 1'b0;
              if (!scr_ok_q) st_q <= S_ALLOC;
              else           st_q <= S_OP;
            end
          end
          // ---- one-time private scratch allocation ---------------------
          S_ALLOC:
            if (pg_req_ready_i) st_q <= S_ALLOC_W;
          S_ALLOC_W:
            if (pg_cpl_valid_i) begin
              if (pg_cpl_i.status == APU_VGPAGES_OK) begin
                scr_ok_q <= 1'b1;
                vsi_q <= pg_cpl_i.base + 32'(OFF_VSI);
                vso_q <= pg_cpl_i.base + 32'(OFF_VSO);
                fsi_q <= pg_cpl_i.base + 32'(OFF_FSI);
                fso_q <= pg_cpl_i.base + 32'(OFF_FSO);
                clp_q <= pg_cpl_i.base + 32'(OFF_CLP);
                ctp_q <= pg_cpl_i.base + 32'(OFF_CTP);
                st_q <= S_OP;
              end else begin
                code_q <= APU_SH_DONE_FAULT;
                st_q <= S_FIN_BAD;
              end
            end
          // ---- opcode dispatch -----------------------------------------
          S_OP: begin
            unique case (dr_q.op)
              APU_RAST_OP_CLEAR: begin
                if ((!dr_q.da_valid && !dr_q.ca_valid[0]) ||
                    !fmt_ok || clr_w == 16'd0 || clr_h == 16'd0)
                  begin code_q <= APU_SH_DONE_UNSUPPORTED;
                        st_q <= S_FIN_BAD; end
                else begin
                  // clr_pix is the two-pixel write pattern: an encoded
                  // color for 4 B formats, {u16,u16} for D16
                  if (clr_is_d)
                    clr_pix_q <=
                      dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM)
                      ? {2{f_f32_u16(dr_q.clear_color[0])}}
                      : dr_q.clear_color[0];
                  else
                    clr_pix_q <=
                      f_is_bgr(dr_q.ca[0].fmt)
                      ? {f_enc8(dr_q.ca[0].fmt, 2'd3,
                                dr_q.clear_color[3]),
                         f_enc8(dr_q.ca[0].fmt, 2'd0,
                                dr_q.clear_color[0]),
                         f_enc8(dr_q.ca[0].fmt, 2'd1,
                                dr_q.clear_color[1]),
                         f_enc8(dr_q.ca[0].fmt, 2'd2,
                                dr_q.clear_color[2])}
                      : {f_enc8(dr_q.ca[0].fmt, 2'd3,
                                dr_q.clear_color[3]),
                         f_enc8(dr_q.ca[0].fmt, 2'd2,
                                dr_q.clear_color[2]),
                         f_enc8(dr_q.ca[0].fmt, 2'd1,
                                dr_q.clear_color[1]),
                         f_enc8(dr_q.ca[0].fmt, 2'd0,
                                dr_q.clear_color[0])};
                  cy_q <= '0; cx_q <= '0;
                  st_q <= S_CLR_X;
                end
              end
              APU_RAST_OP_DRAW: begin
                if ((dr_q.topology != 8'd3 && dr_q.topology != 8'd4 &&
                     dr_q.topology != 8'd5) ||
                    (dr_q.topology != 8'd3 &&
                     dr_q.vertex_count > 32'(VSB)) ||
                    dr_q.ib_type > 2'd2 ||
                    (dr_q.ib_type != 2'd0 && dr_q.ib_size == 32'd0) ||
                    (dr_q.ca_valid == 4'h0 && !dr_q.da_valid) ||
                    (dr_q.ca_valid[0] && !f_cfmt_ok(dr_q.ca[0].fmt)) ||
                    (dr_q.ca_valid[1] && !f_cfmt_ok(dr_q.ca[1].fmt)) ||
                    (dr_q.ca_valid[2] && !f_cfmt_ok(dr_q.ca[2].fmt)) ||
                    (dr_q.ca_valid[3] && !f_cfmt_ok(dr_q.ca[3].fmt)) ||
                    (dr_q.da_valid && !f_dfmt_ok(dr_q.da.fmt)) ||
                    (dr_q.ca_valid[0] && dr_q.blend[0].en &&
                     (dr_q.blend[0].src_c > 5'd14 ||
                      dr_q.blend[0].dst_c > 5'd14 ||
                      dr_q.blend[0].src_a > 5'd14 ||
                      dr_q.blend[0].dst_a > 5'd14 ||
                      dr_q.blend[0].op_c > 3'd4 ||
                      dr_q.blend[0].op_a > 3'd4)) ||
                    (dr_q.ca_valid[1] && dr_q.blend[1].en &&
                     (dr_q.blend[1].src_c > 5'd14 ||
                      dr_q.blend[1].dst_c > 5'd14 ||
                      dr_q.blend[1].src_a > 5'd14 ||
                      dr_q.blend[1].dst_a > 5'd14 ||
                      dr_q.blend[1].op_c > 3'd4 ||
                      dr_q.blend[1].op_a > 3'd4)) ||
                    (dr_q.ca_valid[2] && dr_q.blend[2].en &&
                     (dr_q.blend[2].src_c > 5'd14 ||
                      dr_q.blend[2].dst_c > 5'd14 ||
                      dr_q.blend[2].src_a > 5'd14 ||
                      dr_q.blend[2].dst_a > 5'd14 ||
                      dr_q.blend[2].op_c > 3'd4 ||
                      dr_q.blend[2].op_a > 3'd4)) ||
                    (dr_q.ca_valid[3] && dr_q.blend[3].en &&
                     (dr_q.blend[3].src_c > 5'd14 ||
                      dr_q.blend[3].dst_c > 5'd14 ||
                      dr_q.blend[3].src_a > 5'd14 ||
                      dr_q.blend[3].dst_a > 5'd14 ||
                      dr_q.blend[3].op_c > 3'd4 ||
                      dr_q.blend[3].op_a > 3'd4))) begin
                  code_q <= APU_SH_DONE_UNSUPPORTED;
                  st_q <= S_FIN_BAD;
                end else if (dr_q.vertex_count == 32'd0 ||
                             dr_q.instance_count == 32'd0) begin
                  st_q <= S_FIN_OK;
                end else begin
                  // fp chain: vp.w*0.5, vp.h*0.5, maxz-minz
                  fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
                  fp_a_q <= dr_q.vp.w;
                  fp_b_q <= 32'h3F000000;           // 0.5f
                  fp_ret_q <= S_DR_HW;
                  st_q <= S_FPS;
                end
              end
              default: begin
                code_q <= APU_SH_DONE_UNSUPPORTED;
                st_q <= S_FIN_BAD;
              end
            endcase
          end
          // ---- CLEAR: 8-byte beats across the clear target --------
          S_CLR_X: begin
            mp_we_q <= 1'b1;
            mp_addr_q <= {32'h0, clr_base} +
                         64'(cy_q) * 64'(clr_pitch) +
                         {29'h0, cx_q, 3'h0};
            mp_data_q <= {clr_pix_q, clr_pix_q};
            mp_strb_q <= (clr_rowb - {16'h0, cx_q, 3'h0} >= 32'd8)
                         ? 8'hFF
                         : 8'hFF >> (4'd8 - 4'(clr_rowb -
                                              {16'h0, cx_q, 3'h0}));
            mp_ret_q <= S_CLR_N;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_CLR_N: begin
            if ({16'h0, cx_q, 3'h0} + 32'd8 >= clr_rowb) begin
              cx_q <= '0;
              if (cy_q + 16'd1 >= clr_h) st_q <= S_FIN_OK;
              else begin
                cy_q <= cy_q + 16'd1;
                st_q <= S_CLR_X;
              end
            end else begin
              cx_q <= cx_q + 16'd1;
              st_q <= S_CLR_X;
            end
          end
          // ---- DRAW: viewport constants --------------------------------
          S_DR_HW: begin
            vphw_q <= fp_res_q;
            fp_a_q <= dr_q.vp.h; fp_b_q <= 32'h3F000000;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_ret_q <= S_DR_HH; st_q <= S_FPS;
          end
          S_DR_HH: begin
            vphh_q <= fp_res_q;
            fp_a_q <= '0;
            fp_b_q <= dr_q.vp.maxz; fp_c_q <= dr_q.vp.minz;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1; // SUB b-c
            fp_ret_q <= S_DR_DZ; st_q <= S_FPS;
          end
          S_DR_DZ: begin
            vpdz_q <= fp_res_q;
            inst_q <= dr_q.first_instance;
            bat_q <= '0;
            st_q <= S_DR_BATCH;
          end
          // ---- batch / gather ------------------------------------------
          S_DR_BATCH: begin
            if (dr_q.topology != 8'd3)
              // strips and fans stay in one vertex batch (≤63)
              nv_q <= 6'(dr_q.vertex_count[5:0]);
            else
              nv_q <= 6'((dr_q.vertex_count - bat_q >= 32'(VSB))
                         ? VSB : dr_q.vertex_count - bat_q);
            j_q <= '0;
`ifdef G6LC_APU_DBG_LOST
            $display("[DBG] rast batch nv=%0d vb0={b=%08x s=%08x st=%0d} a0={v=%0d b=%0d f=%0d o=%0d} a1={v=%0d b=%0d f=%0d o=%0d} t=%0t",
                     dr_q.vertex_count - bat_q, dr_q.vb_base[0],
                     dr_q.vb_size[0], dr_q.vb_stride[0],
                     dr_q.attr[0].valid, dr_q.attr[0].binding,
                     dr_q.attr[0].fmt, dr_q.attr[0].offset,
                     dr_q.attr[1].valid, dr_q.attr[1].binding,
                     dr_q.attr[1].fmt, dr_q.attr[1].offset, $time);
`endif
            st_q <= S_GA_ISET;
          end
          S_GA_ISET: begin
            if (dr_q.ib_type == 2'd0) begin
              ib_i <= $signed(dr_q.first_vertex + bat_q + {26'h0, j_q});
              a_q <= '0;
              st_q <= S_GA_ATTR;
            end else begin
              caddr_q <= dr_q.ib_base +
                         (dr_q.first_index + bat_q + {26'h0, j_q}) *
                         (dr_q.ib_type == 2'd1 ? 32'd2 : 32'd4);
              csz_q <= (dr_q.ib_type == 2'd1) ? 5'd2 : 5'd4;
              gbase_q <= dr_q.ib_base;
              gsize_q <= dr_q.ib_size;
              gret_q <= S_GA_IBX;
              st_q <= S_GA_RD;
            end
          end
          S_GA_IBX: begin
            // index element (zero window when OOB) + vertex_offset
            if (dr_q.ib_type == 2'd1)
              ib_i <= dr_q.vertex_offset +
                      {16'h0, win_q[8*caddr_q[2:0] +: 16]};
            else
              ib_i <= dr_q.vertex_offset +
                      win_q[8*caddr_q[2:0] +: 32];
            a_q <= '0;
            st_q <= S_GA_ATTR;
          end
          // ---- attribute gather -----------------------------------------
          S_GA_ATTR: begin
            if (j_q >= nv_q) begin
              st_q <= S_VS_ISS;
            end else if (!dr_q.attr[a_q].valid) begin
              if (a_q == 3'd7) begin
                a_q <= '0;
                st_q <= S_GA_S8A;   // slot-8 write ends vertex j
              end
              else a_q <= a_q + 3'd1;
            end else if (!attr_ok) begin
              // valid flag set but unknown format -> honest refusal
              code_q <= APU_SH_DONE_UNSUPPORTED;
              st_q <= S_FIN_BAD;
            end else begin
              // instance-rate bindings index by the absolute instance
              // index; vertex-rate bindings index by the (resolved)
              // vertex index
              caddr_q <= dr_q.vb_base[a_bnd] +
                         32'($signed(dr_q.vb_rate[a_bnd]
                                    ? inst_q : 32'(ib_i)) *
                             $signed({16'h0, dr_q.vb_stride[a_bnd]})) +
                         a_off;
              csz_q <= f_asz(a_fmt);
              gbase_q <= dr_q.vb_base[a_bnd];
              gsize_q <= dr_q.vb_size[a_bnd];
              gret_q <= S_GA_CVT;
              st_q <= S_GA_RD;
            end
          end
          // shared small window read (1..3 words) into win_q; bounds
          // checked against [gbase, gbase+gsize) — OOB reads a zero
          // window and counts robust
          S_GA_RD: begin
            if (g_oob) begin
              win_q <= '0;
              robust_q <= robust_q + 32'd1;
              st_q <= gret_q;
            end else begin
              wn_q <= 2'((caddr_q[2:0] + csz_q + 5'd7) >> 3) - 2'd1;
              i_q <= '0;
              win_q <= '0;
              mp_we_q <= 1'b0;
              mp_addr_q <= {32'h0, caddr_q[31:3], 3'h0};
              mp_data_q <= '0; mp_strb_q <= '0;
              mp_ret_q <= S_GA_RD;
              mp_acked_q <= 1'b0;
              st_q <= S_MPW;
            end
          end
          S_GA_CVT: begin
            if (a_fmt == APU_RAST_VF_RGBA8_UNORM) begin
              conv_q <= '0;
              c_q <= '0;
              st_q <= S_GA_U8I;
            end else begin
              // f32 formats: unpack; missing comps read (0,0,0,1)
              conv_q[0] <= csz_q >= 5'd4
                  ? win_q[8*caddr_q[2:0] +: 32] : '0;
              conv_q[1] <= csz_q >= 5'd8
                  ? win_q[8*caddr_q[2:0] + 32 +: 32] : '0;
              conv_q[2] <= csz_q >= 5'd12
                  ? win_q[8*caddr_q[2:0] + 64 +: 32] : '0;
              conv_q[3] <= csz_q >= 5'd16
                  ? win_q[8*caddr_q[2:0] + 96 +: 32] : 32'h3F800000;
              st_q <= S_GA_W0;
            end
          end
          S_GA_U8I: begin
            fp_kind_q <= 2'd2; fp_o_q <= 2'd0; fp_mod_q <= 1'b1; // I2F u32
            fp_a_q <= {24'h0, win_q[8*caddr_q[2:0] + 8*c_q +: 8]};
            fp_ret_q <= S_GA_U8M;
            st_q <= S_FPS;
          end
          S_GA_U8M: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_a_q <= fp_res_q;
            fp_b_q <= 32'h3B808081;               // *1/255
            fp_ret_q <= S_GA_U8S;
            st_q <= S_FPS;
          end
          S_GA_U8S: begin
            conv_q[c_q[1:0]] <= fp_res_q;
            if (c_q[1:0] == 2'd3) st_q <= S_GA_W0;
            else begin
              c_q <= c_q + 3'd1;
              st_q <= S_GA_U8I;
            end
          end
          // two-word record write into vs_in
          S_GA_W0: begin
            mp_we_q <= 1'b1;
            mp_addr_q <= {32'h0, vsi_q} +
                         {26'h0, j_q} * 64'(ASTR) +
                         {29'h0, dr_q.attr[a_q].loc, 4'h0};
            mp_data_q <= {conv_q[1], conv_q[0]};
            mp_strb_q <= 8'hFF;
            mp_ret_q <= S_GA_W1;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_GA_W1: begin
            mp_we_q <= 1'b1;
            mp_addr_q <= {32'h0, vsi_q} +
                         {26'h0, j_q} * 64'(ASTR) +
                         {29'h0, dr_q.attr[a_q].loc, 4'h0} + 64'd8;
            mp_data_q <= {conv_q[3], conv_q[2]};
            mp_strb_q <= 8'hFF;
            mp_ret_q <= (a_q == 3'd7) ? S_GA_S8A : S_GA_ATTR;
            mp_acked_q <= 1'b0;
            if (a_q == 3'd7) a_q <= '0;
            else             a_q <= a_q + 3'd1;
            st_q <= S_MPW;
          end
          // slot 8 of the VS-in record = {VertexIndex, InstanceIndex,
          // 0, 0}; the ShaderCore reads the builtins from here (G2a)
          S_GA_S8A: begin
            mp_we_q <= 1'b1;
            mp_addr_q <= {32'h0, vsi_q} +
                         {26'h0, j_q} * 64'(ASTR) + 64'd128;
            mp_data_q <= {inst_q, 32'(ib_i)};
            mp_strb_q <= 8'hFF;
            mp_ret_q <= S_GA_S8B;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_GA_S8B: begin
            mp_we_q <= 1'b1;
            mp_addr_q <= {32'h0, vsi_q} +
                         {26'h0, j_q} * 64'(ASTR) + 64'd136;
            mp_data_q <= 64'h0;
            mp_strb_q <= 8'hFF;
            mp_ret_q <= S_GA_ISET;
            mp_acked_q <= 1'b0;
            j_q <= j_q + 6'd1;
            st_q <= S_MPW;
          end
          // ---- VS batch wave ---------------------------------------------
          S_VS_ISS: begin
            sh_ctype_o <= APU_SH_WORK_VS;
            sh_slot_o <= dr_q.vs_slot;
            sh_imm_o[0] <= {26'h0, nv_q};
            sh_imm_o[1] <= vsi_q;
            sh_imm_o[2] <= vso_q;
            sh_imm_o[3] <= (dr_q.ib_type == 2'd0)
                           ? dr_q.first_vertex + bat_q : '0;
            sh_imm_o[4] <= inst_q;
            sh_imm_o[5] <= '0; sh_imm_o[6] <= '0; sh_imm_o[7] <= '0;
            shv_q <= 1'b1;
            if (shv_q && sh_work_ready_i) begin
              shv_q <= 1'b0;
              shd_q <= 1'b0;
              st_q <= S_VS_WAIT;
            end
          end
          S_VS_WAIT:
            if (shd_q) begin
              shd_q <= 1'b0;
              if (shdp_q.code != APU_SH_DONE_OK) begin
                code_q <= shdp_q.code;
                st_q <= S_FIN_BAD;
              end else begin
                robust_q <= robust_q + shdp_q.robust;
                p_q <= '0; f_q <= '0;
                st_q <= S_PR_I0;
              end
            end
          // ---- primitive loop ---------------------------------------------
          // Position fetch: two words per vertex, t_q = 0..2
          S_PR_I0: begin
            // clip mode: the fan cursor, not nv_q, bounds the loop —
            // exhaustion was already decided in the prim-done advance
            if (!clip_q && p_q + 6'd2 >= nv_q) begin
              if (f_q != 6'd0) begin
                nf_q <= {1'b0, f_q}; f_q <= '0;
                flr_q <= S_BATNEXT;
                st_q <= S_FLUSH;
              end else
                st_q <= S_BATNEXT;
            end else begin
              t_q <= '0;
              st_q <= S_PR_I0B;
            end
          end
          S_PR_I0B: begin
            mp_we_q <= 1'b0;
            // clip fan tris read the clip_out ring, plain prims vso_q
            mp_addr_q <= {32'h0, clip_q ? clp_q : vso_q} +
                         64'(f_pi(t_q)) * 64'(VSTR);
            mp_data_q <= '0; mp_strb_q <= '0;
            mp_ret_q <= S_PR_I1;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_PR_I1: begin
            pos_q[t_q][0] <= mp_res_q[31:0];
            pos_q[t_q][1] <= mp_res_q[63:32];
            mp_we_q <= 1'b0;
            mp_addr_q <= mp_addr_q + 64'd8;
            mp_ret_q <= S_PR_I2;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_PR_I2: begin
            pos_q[t_q][2] <= mp_res_q[31:0];
            pos_q[t_q][3] <= mp_res_q[63:32];
            if (t_q == 2'd2) st_q <= S_PR_W;
            else begin
              t_q <= t_q + 2'd1;
              st_q <= S_PR_I0B;
            end
          end
          S_PR_W: begin
`ifdef G6LC_APU_DBG_LOST
            $display("[DBG] rast prim p=%0d pos0=%08x %08x %08x %08x pos1=%08x %08x %08x %08x pos2=%08x %08x %08x %08x t=%0t",
                     p_q, pos_q[0][0], pos_q[0][1], pos_q[0][2],
                     pos_q[0][3], pos_q[1][0], pos_q[1][1], pos_q[1][2],
                     pos_q[1][3], pos_q[2][0], pos_q[2][1], pos_q[2][2],
                     pos_q[2][3], $time);
`endif
            // G2b: evaluate outcodes instead of the w<=0 skip.  gw =
            // 4096*w per vertex (guard band), then S_OC decides
            // trivial-reject / trivial-accept / clip.  Fan tris of an
            // already-clipped polygon skip the eval: the S-H output is
            // inside by construction, and re-clipping under f32 is not
            // idempotent — a lerped vertex can land 1 ulp outside its
            // plane and re-clip forever.
            if (clip_q) begin
              fp_kind_q <= 2'd1; fp_o_q <= '0;
              fp_a_q <= 32'h3F800000; fp_b_q <= pos_q[0][3];
              fp_ret_q <= S_T0R;
            end else begin
              fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
              fp_a_q <= CLIP_GB; fp_b_q <= pos_q[0][3];
              fp_ret_q <= S_OC_G1;
            end
            st_q <= S_FPS;
          end
          S_OC_G1: begin
            gw_q[0] <= fp_res_q;
            fp_a_q <= CLIP_GB; fp_b_q <= pos_q[1][3];
            fp_ret_q <= S_OC_G2; st_q <= S_FPS;
          end
          S_OC_G2: begin
            gw_q[1] <= fp_res_q;
            fp_a_q <= CLIP_GB; fp_b_q <= pos_q[2][3];
            fp_ret_q <= S_OC_G3; st_q <= S_FPS;
          end
          S_OC_G3: begin
            gw_q[2] <= fp_res_q;
            oc_q[0] <= f_oc(pos_q[0], gw_q[0]);
            oc_q[1] <= f_oc(pos_q[1], gw_q[1]);
            oc_q[2] <= f_oc(pos_q[2], fp_res_q);
            st_q <= S_OC;
          end
          S_OC: begin
            // oc_q holds all three outcodes now
            if (|(oc_q[0] & oc_q[1] & oc_q[2])) begin
              // trivially outside a common plane -> drop the prim
              if (dr_q.topology != 8'd3) p_q <= p_q + 6'd1;
              else                       p_q <= p_q + 6'd3;
              st_q <= S_PR_I0;
            end else if (!(|oc_q[0] || |oc_q[1] || |oc_q[2])) begin
              // all inside -> straight to perspective divide
              fp_kind_q <= 2'd1; fp_o_q <= '0;
              fp_a_q <= 32'h3F800000; fp_b_q <= pos_q[0][3];
              fp_ret_q <= S_T0R;
              st_q <= S_FPS;
            end else begin
              // clip needed: Sutherland–Hodgman over the violated
              // planes.  in-ring = vso records (topology-mapped);
              // out-ring parity keeps the final polygon in clip_out
              // when popcount(cpm) is odd -> first out goes to clp_q
              cpm_q <= oc_q[0] | oc_q[1] | oc_q[2];
              cpl_q <= oc_q[0][0] | oc_q[1][0] | oc_q[2][0] ? 3'd0 :
                       oc_q[0][1] | oc_q[1][1] | oc_q[2][1] ? 3'd1 :
                       oc_q[0][2] | oc_q[1][2] | oc_q[2][2] ? 3'd2 :
                       oc_q[0][3] | oc_q[1][3] | oc_q[2][3] ? 3'd3 :
                                                             3'd4;
              cn_q   <= 4'd3; ce_q <= '0; co_q <= '0; cin_q <= '0;
              cib_q  <= vso_q; cmap_q <= 1'b1;
              cob_q  <= ^(oc_q[0] | oc_q[1] | oc_q[2]) ? clp_q : ctp_q;
              st_q <= S_CP_RP0;
            end
          end
          // ---- clip-space clipping (G2b) ---------------------------------
          // Per in-polygon vertex: fetch Position from the in-ring,
          // evaluate its signed distance to the current plane (f32 on
          // the fpnew units) and its inside bit, then the edge walk
          // emits the out-polygon as VS-out-format records.  Every
          // crossing interpolates Position and all fs_in_mask
          // locations linearly in CLIP space; the later perspective
          // divide restores exact perspective correctness because a
          // clip-space lerp commutes with it.
          S_CP_RP0: begin
            mp_we_q <= 1'b0;
            mp_addr_q <= f_crec(ce_q);
            mp_data_q <= '0; mp_strb_q <= '0;
            mp_ret_q <= S_CP_RP1;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_CP_RP1: begin
            cpos_q[ce_q][0] <= mp_res_q[31:0];
            cpos_q[ce_q][1] <= mp_res_q[63:32];
            mp_we_q <= 1'b0;
            mp_addr_q <= mp_addr_q + 64'd8;
            mp_ret_q <= S_CP_RP2;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_CP_RP2: begin
            cpos_q[ce_q][2] <= mp_res_q[31:0];
            cpos_q[ce_q][3] <= mp_res_q[63:32];
            unique case (cpl_q)
              3'd0: begin                     // near: dist = z
                cdis_q[ce_q] <= mp_res_q[31:0];
                cin_q[ce_q]  <= !f_f32_lt(mp_res_q[31:0], 32'h0);
                if (ce_q == cn_q - 4'd1) begin
                  ce_q <= '0; st_q <= S_CP_EDGE;
                end else begin
                  ce_q <= ce_q + 4'd1; st_q <= S_CP_RP0;
                end
              end
              3'd3, 3'd4: begin               // guard: 4096*w first
                fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
                fp_a_q <= CLIP_GB; fp_b_q <= mp_res_q[63:32];
                fp_ret_q <= S_CP_DG;
                st_q <= S_FPS;
              end
              default: begin                  // far: w-z; eps: w-1e-5
                fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
                fp_a_q <= '0;
                fp_b_q <= mp_res_q[63:32];
                fp_c_q <= (cpl_q == 3'd1) ? mp_res_q[31:0] : CLIP_EPS;
                fp_ret_q <= S_CP_DD;
                st_q <= S_FPS;
              end
            endcase
          end
          S_CP_DG: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
            fp_a_q <= '0;
            fp_b_q <= fp_res_q;                // 4096*w
            fp_c_q <= {1'b0, cpos_q[ce_q][cpl_q == 3'd3 ? 0 : 1][30:0]};
            fp_ret_q <= S_CP_DD;
            st_q <= S_FPS;
          end
          S_CP_DD: begin
            cdis_q[ce_q] <= fp_res_q;
            cin_q[ce_q]  <= !f_f32_lt(fp_res_q, 32'h0);
            if (ce_q == cn_q - 4'd1) begin
              ce_q <= '0; st_q <= S_CP_EDGE;
            end else begin
              ce_q <= ce_q + 4'd1; st_q <= S_CP_RP0;
            end
          end
          // edge (a=ce_q -> b): emit rules of Sutherland–Hodgman
          S_CP_EDGE: begin
            ceb_q <= (ce_q == cn_q - 4'd1) ? 4'd0 : ce_q + 4'd1;
            unique case ({cin_q[ce_q],
                          cin_q[(ce_q == cn_q - 4'd1)
                                ? 4'd0 : ce_q + 4'd1]})
              2'b11:  st_q <= S_CP_CB0;              // in->in: copy b
              2'b01: begin                           // out->in: i, b
                     cemitb_q <= 1'b1; st_q <= S_CP_IT0; end
              2'b10: begin                           // in->out: i
                     cemitb_q <= 1'b0; st_q <= S_CP_IT0; end
              default: st_q <= S_CP_ENX;             // out->out: none
            endcase
          end
          S_CP_ENX: begin
            if (ce_q == cn_q - 4'd1)
              st_q <= S_CP_PDN;
            else begin
              ce_q <= ce_q + 4'd1;
              st_q <= S_CP_EDGE;
            end
          end
          // ---- interpolation t = da/(da-db), then record emit -------
          S_CP_IT0: begin                     // sub: da - db
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
            fp_a_q <= '0;
            fp_b_q <= cdis_q[ce_q];
            fp_c_q <= cdis_q[(ce_q == cn_q - 4'd1)
                             ? 4'd0 : ce_q + 4'd1];
            fp_ret_q <= S_CP_IT1; st_q <= S_FPS;
          end
          S_CP_IT1: begin                     // div: da/(da-db)
            fp_kind_q <= 2'd1; fp_o_q <= '0;
            fp_a_q <= cdis_q[ce_q]; fp_b_q <= fp_res_q;
            fp_ret_q <= S_CP_IT2; st_q <= S_FPS;
          end
          S_CP_IT2: begin
            ctt_q <= fp_res_q;
            c_q <= '0; lc_q <= '0;
            cslot_q <= 1'b1;                  // Position slot first
            st_q <= S_CP_ILP;
          end
          // emit pump: slot 0, then every masked varying location
          S_CP_ILP: begin
            if (cslot_q) begin
              c_q <= '0;
              st_q <= S_CP_IS;
            end else if (lc_q == 4'd8) begin
              // record complete
              co_q <= co_q + 4'd1;
              if (cemitb_q) begin
                cemitb_q <= 1'b0;
                st_q <= S_CP_CB0;
              end else
                st_q <= S_CP_ENX;
            end else if (!dr_q.fs_in_mask[lc_q[2:0]]) begin
              lc_q <= lc_q + 4'd1;
            end else begin
              mp_we_q <= 1'b0;
              mp_addr_q <= f_crec(ce_q) + 64'd16 +
                           {28'h0, lc_q[2:0], 4'h0};
              mp_data_q <= '0; mp_strb_q <= '0;
              mp_ret_q <= S_CP_IR0;
              mp_acked_q <= 1'b0;
              st_q <= S_MPW;
            end
          end
          // chain: a.lo, a.hi, b.lo, b.hi of the location
          S_CP_IR0: begin
            cva_q[0] <= mp_res_q[31:0]; cva_q[1] <= mp_res_q[63:32];
            mp_we_q <= 1'b0;
            mp_addr_q <= mp_addr_q + 64'd8;
            mp_ret_q <= S_CP_IR1;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_CP_IR1: begin
            cva_q[2] <= mp_res_q[31:0]; cva_q[3] <= mp_res_q[63:32];
            mp_we_q <= 1'b0;
            mp_addr_q <= f_crec(ceb_q) + 64'd16 +
                         {28'h0, lc_q[2:0], 4'h0};
            mp_ret_q <= S_CP_IR2;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_CP_IR2: begin
            cvb_q[0] <= mp_res_q[31:0]; cvb_q[1] <= mp_res_q[63:32];
            mp_we_q <= 1'b0;
            mp_addr_q <= mp_addr_q + 64'd8;
            mp_ret_q <= S_CP_IR3;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_CP_IR3: begin
            cvb_q[2] <= mp_res_q[31:0]; cvb_q[3] <= mp_res_q[63:32];
            c_q <= '0;
            st_q <= S_CP_IS;
          end
          // per comp: (vb - va), then t*(vb-va) + va
          S_CP_IS: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
            fp_a_q <= '0;
            fp_b_q <= cslot_q ? cpos_q[ceb_q][c_q[1:0]]
                              : cvb_q[c_q[1:0]];
            fp_c_q <= cslot_q ? cpos_q[ce_q][c_q[1:0]]
                              : cva_q[c_q[1:0]];
            fp_ret_q <= S_CP_IF; st_q <= S_FPS;
          end
          S_CP_IF: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_a_q <= ctt_q; fp_b_q <= fp_res_q;
            fp_c_q <= cslot_q ? cpos_q[ce_q][c_q[1:0]]
                              : cva_q[c_q[1:0]];
            fp_ret_q <= S_CP_IW2; st_q <= S_FPS;
          end
          S_CP_IW2: begin
            conv_q[c_q[1:0]] <= fp_res_q;
            if (c_q[1:0] == 2'd3) begin
              mp_we_q <= 1'b1;
              mp_addr_q <= {32'h0, cob_q} + {26'h0, co_q} * 64'(VSTR) +
                           (cslot_q ? 64'd0
                                    : 64'd16 + {28'h0, lc_q[2:0], 4'h0});
              mp_data_q <= {conv_q[1], conv_q[0]};
              mp_strb_q <= 8'hFF;
              mp_ret_q <= S_CP_IW3;
              mp_acked_q <= 1'b0;
              st_q <= S_MPW;
            end else begin
              c_q <= c_q + 3'd1;
              st_q <= S_CP_IS;
            end
          end
          S_CP_IW3: begin
            mp_we_q <= 1'b1;
            mp_addr_q <= mp_addr_q + 64'd8;
            mp_data_q <= {conv_q[3], conv_q[2]};
            mp_strb_q <= 8'hFF;
            mp_ret_q <= S_CP_IW4;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_CP_IW4: begin
            if (cslot_q) begin
              cslot_q <= 1'b0;
              st_q <= S_CP_ILP;
            end else begin
              lc_q <= lc_q + 4'd1;
              st_q <= S_CP_ILP;
            end
          end
          // ---- emit an unmodified inside vertex b --------------------
          S_CP_CB0: begin
            mp_we_q <= 1'b1;
            mp_addr_q <= {32'h0, cob_q} + {26'h0, co_q} * 64'(VSTR);
            mp_data_q <= {cpos_q[ceb_q][1], cpos_q[ceb_q][0]};
            mp_strb_q <= 8'hFF;
            mp_ret_q <= S_CP_CB1;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_CP_CB1: begin
            mp_we_q <= 1'b1;
            mp_addr_q <= mp_addr_q + 64'd8;
            mp_data_q <= {cpos_q[ceb_q][3], cpos_q[ceb_q][2]};
            mp_strb_q <= 8'hFF;
            mp_ret_q <= S_CP_CBL;
            mp_acked_q <= 1'b0;
            lc_q <= '0;
            st_q <= S_MPW;
          end
          S_CP_CBL: begin
            if (lc_q == 4'd8) begin
              co_q <= co_q + 4'd1;
              st_q <= S_CP_ENX;
            end else if (!dr_q.fs_in_mask[lc_q[2:0]]) begin
              lc_q <= lc_q + 4'd1;
            end else begin
              mp_we_q <= 1'b0;
              mp_addr_q <= f_crec(ceb_q) + 64'd16 +
                           {28'h0, lc_q[2:0], 4'h0};
              mp_data_q <= '0; mp_strb_q <= '0;
              mp_ret_q <= S_CP_CBR;
              mp_acked_q <= 1'b0;
              st_q <= S_MPW;
            end
          end
          S_CP_CBR: begin                 // write loc lo, then read hi
            mp_we_q <= 1'b1;
            mp_addr_q <= {32'h0, cob_q} + {26'h0, co_q} * 64'(VSTR) +
                         64'd16 + {28'h0, lc_q[2:0], 4'h0};
            mp_data_q <= mp_res_q;
            mp_strb_q <= 8'hFF;
            mp_ret_q <= S_CP_CBQ;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_CP_CBQ: begin                 // read loc hi of vertex b
            mp_we_q <= 1'b0;
            mp_addr_q <= f_crec(ceb_q) + 64'd16 +
                         {28'h0, lc_q[2:0], 4'h0} + 64'd8;
            mp_data_q <= '0; mp_strb_q <= '0;
            mp_ret_q <= S_CP_CBW;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_CP_CBW: begin                 // write loc hi
            mp_we_q <= 1'b1;
            mp_addr_q <= {32'h0, cob_q} + {26'h0, co_q} * 64'(VSTR) +
                         64'd16 + {28'h0, lc_q[2:0], 4'h0} + 64'd8;
            mp_data_q <= mp_res_q;
            mp_strb_q <= 8'hFF;
            mp_ret_q <= S_CP_CBL;
            mp_acked_q <= 1'b0;
            lc_q <= lc_q + 4'd1;
            st_q <= S_MPW;
          end
          // plane done: swap the rings, next plane or finish
          S_CP_PDN: begin
            if (co_q < 4'd3) begin
              // the clip consumed the whole primitive
              t_pd();
              st_q <= S_PR_I0;
            end else begin
              cn_q   <= co_q;
              co_q   <= '0; ce_q <= '0; cin_q <= '0;
              cmap_q <= 1'b0;
              cib_q  <= cob_q;
              cob_q  <= (cob_q == clp_q) ? ctp_q : clp_q;
              if (f_npl(cpm_q, cpl_q) == 3'd7) begin
                // final polygon: cob (now cib) — always clp_q by the
                // parity pick in S_OC — feeds the fan setup path
                clip_q <= 1'b1; cfan_q <= 4'd1; cpn_q <= co_q;
                st_q <= S_PR_I0;
              end else begin
                cpl_q <= f_npl(cpm_q, cpl_q);
                st_q <= S_CP_RP0;
              end
            end
          end
          // -- per-vertex: rcp_w then ndc = pos.xyz * rcp_w ----------------
          S_T0R: begin
            vrw_q[0] <= fp_res_q;
            fp_kind_q <= 2'd1; fp_o_q <= '0;
            fp_a_q <= 32'h3F800000; fp_b_q <= pos_q[1][3];
            fp_ret_q <= S_T1R; st_q <= S_FPS;
          end
          S_T1R: begin
            vrw_q[1] <= fp_res_q;
            fp_kind_q <= 2'd1; fp_o_q <= '0;
            fp_a_q <= 32'h3F800000; fp_b_q <= pos_q[2][3];
            fp_ret_q <= S_T2R; st_q <= S_FPS;
          end
          S_T2R: begin
            vrw_q[2] <= fp_res_q;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_a_q <= pos_q[0][0]; fp_b_q <= vrw_q[0];
            fp_ret_q <= S_T0X; st_q <= S_FPS;
          end
          S_T0X: begin
            vnd_q[0][0] <= fp_res_q;
            fp_a_q <= pos_q[0][1]; fp_b_q <= vrw_q[0];
            fp_ret_q <= S_T0Y; st_q <= S_FPS;
          end
          S_T0Y: begin
            vnd_q[0][1] <= fp_res_q;
            fp_a_q <= pos_q[0][2]; fp_b_q <= vrw_q[0];
            fp_ret_q <= S_T0Z; st_q <= S_FPS;
          end
          S_T0Z: begin
            vnd_q[0][2] <= fp_res_q;
            fp_a_q <= pos_q[1][0]; fp_b_q <= vrw_q[1];
            fp_ret_q <= S_T1X; st_q <= S_FPS;
          end
          S_T1X: begin
            vnd_q[1][0] <= fp_res_q;
            fp_a_q <= pos_q[1][1]; fp_b_q <= vrw_q[1];
            fp_ret_q <= S_T1Y; st_q <= S_FPS;
          end
          S_T1Y: begin
            vnd_q[1][1] <= fp_res_q;
            fp_a_q <= pos_q[1][2]; fp_b_q <= vrw_q[1];
            fp_ret_q <= S_T1Z; st_q <= S_FPS;
          end
          S_T1Z: begin
            vnd_q[1][2] <= fp_res_q;
            fp_a_q <= pos_q[2][0]; fp_b_q <= vrw_q[2];
            fp_ret_q <= S_T2X; st_q <= S_FPS;
          end
          S_T2X: begin
            vnd_q[2][0] <= fp_res_q;
            fp_a_q <= pos_q[2][1]; fp_b_q <= vrw_q[2];
            fp_ret_q <= S_T2Y; st_q <= S_FPS;
          end
          S_T2Y: begin
            vnd_q[2][1] <= fp_res_q;
            fp_a_q <= pos_q[2][2]; fp_b_q <= vrw_q[2];
            fp_ret_q <= S_T2Z; st_q <= S_FPS;
          end
          S_T2Z: begin
            vnd_q[2][2] <= fp_res_q;
            fp_a_q <= '0;
            fp_b_q <= vnd_q[0][0]; fp_c_q <= 32'h3F800000;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T0SA; st_q <= S_FPS;
          end
          // -- screen transform per vertex: x=fma(ndc.x+1,vphw,vp.x), ----
          //    xi=F2I(x*256 RNE); same for y; z=fma(ndc.z,vpdz,vp.minz)
          S_T0SA: begin
            fp_a_q <= fp_res_q; fp_b_q <= vphw_q; fp_c_q <= dr_q.vp.x;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T0SF; st_q <= S_FPS;
          end
          S_T0SF: begin
            fp_a_q <= fp_res_q; fp_b_q <= 32'h43800000; // *256
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T0SM; st_q <= S_FPS;
          end
          S_T0SM: begin
            fp_kind_q <= 2'd2; fp_o_q <= 2'd1; fp_mod_q <= 1'b0; // F2I s32
            fp_a_q <= fp_res_q;
            fp_ret_q <= S_T0SC; st_q <= S_FPS;
          end
          S_T0SC: begin
            vxi_q[0] <= fp_res_q;
            fp_a_q <= '0;
            fp_b_q <= vnd_q[0][1]; fp_c_q <= 32'h3F800000;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T0YA; st_q <= S_FPS;
          end
          S_T0YA: begin
            fp_a_q <= fp_res_q; fp_b_q <= vphh_q; fp_c_q <= dr_q.vp.y;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T0YF; st_q <= S_FPS;
          end
          S_T0YF: begin
            fp_a_q <= fp_res_q; fp_b_q <= 32'h43800000;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T0YM; st_q <= S_FPS;
          end
          S_T0YM: begin
            fp_kind_q <= 2'd2; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
            fp_a_q <= fp_res_q;
            fp_ret_q <= S_T0YC; st_q <= S_FPS;
          end
          S_T0YC: begin
            vyi_q[0] <= fp_res_q;
            fp_a_q <= vnd_q[0][2]; fp_b_q <= vpdz_q;
            fp_c_q <= dr_q.vp.minz;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T0ZF; st_q <= S_FPS;
          end
          S_T0ZF: begin
            vz_q[0] <= fp_res_q;
            fp_a_q <= '0;
            fp_b_q <= vnd_q[1][0]; fp_c_q <= 32'h3F800000;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T1SA; st_q <= S_FPS;
          end
          S_T1SA: begin
            fp_a_q <= fp_res_q; fp_b_q <= vphw_q; fp_c_q <= dr_q.vp.x;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T1SF; st_q <= S_FPS;
          end
          S_T1SF: begin
            fp_a_q <= fp_res_q; fp_b_q <= 32'h43800000;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T1SM; st_q <= S_FPS;
          end
          S_T1SM: begin
            fp_kind_q <= 2'd2; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
            fp_a_q <= fp_res_q;
            fp_ret_q <= S_T1SC; st_q <= S_FPS;
          end
          S_T1SC: begin
            vxi_q[1] <= fp_res_q;
            fp_a_q <= '0;
            fp_b_q <= vnd_q[1][1]; fp_c_q <= 32'h3F800000;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T1YA; st_q <= S_FPS;
          end
          S_T1YA: begin
            fp_a_q <= fp_res_q; fp_b_q <= vphh_q; fp_c_q <= dr_q.vp.y;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T1YF; st_q <= S_FPS;
          end
          S_T1YF: begin
            fp_a_q <= fp_res_q; fp_b_q <= 32'h43800000;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T1YM; st_q <= S_FPS;
          end
          S_T1YM: begin
            fp_kind_q <= 2'd2; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
            fp_a_q <= fp_res_q;
            fp_ret_q <= S_T1YC; st_q <= S_FPS;
          end
          S_T1YC: begin
            vyi_q[1] <= fp_res_q;
            fp_a_q <= vnd_q[1][2]; fp_b_q <= vpdz_q;
            fp_c_q <= dr_q.vp.minz;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T1ZF; st_q <= S_FPS;
          end
          S_T1ZF: begin
            vz_q[1] <= fp_res_q;
            fp_a_q <= '0;
            fp_b_q <= vnd_q[2][0]; fp_c_q <= 32'h3F800000;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T2SA; st_q <= S_FPS;
          end
          S_T2SA: begin
            fp_a_q <= fp_res_q; fp_b_q <= vphw_q; fp_c_q <= dr_q.vp.x;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T2SF; st_q <= S_FPS;
          end
          S_T2SF: begin
            fp_a_q <= fp_res_q; fp_b_q <= 32'h43800000;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T2SM; st_q <= S_FPS;
          end
          S_T2SM: begin
            fp_kind_q <= 2'd2; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
            fp_a_q <= fp_res_q;
            fp_ret_q <= S_T2SC; st_q <= S_FPS;
          end
          S_T2SC: begin
            vxi_q[2] <= fp_res_q;
            fp_a_q <= '0;
            fp_b_q <= vnd_q[2][1]; fp_c_q <= 32'h3F800000;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T2YA; st_q <= S_FPS;
          end
          S_T2YA: begin
            fp_a_q <= fp_res_q; fp_b_q <= vphh_q; fp_c_q <= dr_q.vp.y;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T2YF; st_q <= S_FPS;
          end
          S_T2YF: begin
            fp_a_q <= fp_res_q; fp_b_q <= 32'h43800000;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T2YM; st_q <= S_FPS;
          end
          S_T2YM: begin
            fp_kind_q <= 2'd2; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
            fp_a_q <= fp_res_q;
            fp_ret_q <= S_T2YC; st_q <= S_FPS;
          end
          S_T2YC: begin
            vyi_q[2] <= fp_res_q;
            fp_a_q <= vnd_q[2][2]; fp_b_q <= vpdz_q;
            fp_c_q <= dr_q.vp.minz;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_ret_q <= S_T2ZF; st_q <= S_FPS;
          end
          S_T2ZF: begin
            vz_q[2] <= fp_res_q;
            area_q <= area_w;
            st_q <= S_PR_AREA;
          end
          // -- area, cull, top-left, bbox, rcp_area --------------------------
          S_PR_AREA: begin
`ifdef G6LC_APU_DBG_LOST
            $display("[DBG] rast area=%0d (%016x) front=%0d cull=%0d ff=%0d xy=(%0d,%0d)(%0d,%0d)(%0d,%0d) t=%0t",
                     area_q, area_q, front_w, dr_q.cull, dr_q.front_ccw,
                     32'(vxi_q[0]), 32'(vyi_q[0]), 32'(vxi_q[1]),
                     32'(vyi_q[1]), 32'(vxi_q[2]), 32'(vyi_q[2]), $time);
`endif
            // front = (signed area > 0) == front_ccw, evaluated on the
            // PRE-swap area; cull[0]=FRONT, cull[1]=BACK.  G2b: the
            // face/cull decision is taken once on the clipped
            // polygon's first fan tri; later fan tris share its
            // winding (degenerate-area still drops each tri)
            if (clip_q && cfan_q > 4'd1) begin
              if (area_q == 64'sd0) begin
                t_pd();
                st_q <= S_PR_I0;
              end else begin
                vsw_q <= (area_q < 64'sd0);
                if (area_q < 64'sd0) begin
                  area_q <= -area_q;
                  {vxi_q[1], vxi_q[2]} <= {vxi_q[2], vxi_q[1]};
                  {vyi_q[1], vyi_q[2]} <= {vyi_q[2], vyi_q[1]};
                  {vz_q[1], vz_q[2]}   <= {vz_q[2], vz_q[1]};
                  {vrw_q[1], vrw_q[2]} <= {vrw_q[2], vrw_q[1]};
                end
                st_q <= S_PR_SHF;
              end
            end else if (area_q == 64'sd0 ||
                         (front_w && dr_q.cull[0]) ||
                         (!front_w && dr_q.cull[1])) begin
              clip_q <= 1'b0;      // cull aborts the whole clip fan
              if (dr_q.topology != 8'd3) p_q <= p_q + 6'd1;
              else                       p_q <= p_q + 6'd3;
              st_q <= S_PR_I0;
            end else begin
              front_q <= front_w;
              vsw_q <= (area_q < 64'sd0);
              if (area_q < 64'sd0) begin
                // swap v1/v2: the math below sees a positive area
                area_q <= -area_q;
                {vxi_q[1], vxi_q[2]} <= {vxi_q[2], vxi_q[1]};
                {vyi_q[1], vyi_q[2]} <= {vyi_q[2], vyi_q[1]};
                {vz_q[1], vz_q[2]}   <= {vz_q[2], vz_q[1]};
                {vrw_q[1], vrw_q[2]} <= {vrw_q[2], vrw_q[1]};
              end
              st_q <= S_PR_SHF;
            end
          end
          S_PR_SHF: begin
            shf_q <= (f_msb(area_q) > 6'd28) ? f_msb(area_q) - 6'd28
                                             : 6'd0;
            // edge geometry (post-swap order); E_k anchored at (k+1)%3,
            // direction to (k+2)%3
            ex_q[0]  <= vxi_q[1]; ey_q[0]  <= vyi_q[1];
            edx_q[0] <= vxi_q[2] - vxi_q[1];
            edy_q[0] <= vyi_q[2] - vyi_q[1];
            ex_q[1]  <= vxi_q[2]; ey_q[1]  <= vyi_q[2];
            edx_q[1] <= vxi_q[0] - vxi_q[2];
            edy_q[1] <= vyi_q[0] - vyi_q[2];
            ex_q[2]  <= vxi_q[0]; ey_q[2]  <= vyi_q[0];
            edx_q[2] <= vxi_q[1] - vxi_q[0];
            edy_q[2] <= vyi_q[1] - vyi_q[0];
            // top-left flags: include a zero edge iff it goes "up"
            // (anchor.y > end.y) or is a horizontal top edge (same y,
            // anchor.x < end.x); the opposite direction is never
            // top-left, so shared edges draw exactly once
            tl_q[0] <= (vyi_q[1] > vyi_q[2]) ||
                       (vyi_q[1] == vyi_q[2] && vxi_q[1] < vxi_q[2]);
            tl_q[1] <= (vyi_q[2] > vyi_q[0]) ||
                       (vyi_q[2] == vyi_q[0] && vxi_q[2] < vxi_q[0]);
            tl_q[2] <= (vyi_q[0] > vyi_q[1]) ||
                       (vyi_q[0] == vyi_q[1] && vxi_q[0] < vxi_q[1]);
            st_q <= S_PR_BBX;
          end
          S_PR_BBX: begin
`ifdef G6LC_APU_DBG_LOST
            $display("[DBG] rast bbox empty=%0d x=[%0d,%0d] y=[%0d,%0d] sc=%0d,%0d %0dx%0d t=%0t",
                     bbox_empty, blo_x, bhi_x, blo_y, bhi_y,
                     dr_q.sc_x, dr_q.sc_y, dr_q.sc_w, dr_q.sc_h, $time);
`endif
            if (bbox_empty) begin
              t_pd();
              st_q <= S_PR_I0;
            end else begin
              bx0_q <= 16'(blo_x); bx1_q <= 16'(bhi_x);
              by0_q <= 16'(blo_y); by1_q <= 16'(bhi_y);
              // G2b: the scan walks even-aligned 2x2 blocks, so the
              // cursor starts at the even pixel <= the bbox corner
              sx_q <= 16'(blo_x) & ~16'd1;
              sy_q <= 16'(blo_y) & ~16'd1;
              // I2F(area >> shf) then 1/x
              fp_kind_q <= 2'd2; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
              fp_a_q <= 32'(area_q >>> shf_q);
              fp_ret_q <= S_PR_RCI;
              st_q <= S_FPS;
            end
          end
          S_PR_RCI: begin
            fp_kind_q <= 2'd1; fp_o_q <= '0;
            fp_a_q <= 32'h3F800000; fp_b_q <= fp_res_q;
            fp_ret_q <= S_PR_RCD;
            st_q <= S_FPS;
          end
          S_PR_RCD: begin
            rcpa_q <= fp_res_q;
            varm_q <= dr_q.fs_in_mask;
            lc_q <= '0;
            t_q <= '0;                       // vertex cursor for fetch
            st_q <= S_PR_VF;
          end
          // -- varying prefetch: masked locs × 3 verts → var_q --------------
          // (S_MPW chains the second word for mp_ret S_PR_VF/S_PR_VF2)
          S_PR_VF: begin
            if (lc_q == 4'd8) begin
              st_q <= S_SCAN;
            end else if (!varm_q[lc_q[2:0]]) begin
              lc_q <= lc_q + 4'd1;
            end else begin
              mp_we_q <= 1'b0;
              // vsw_q: slots 1/2 swapped at S_PR_AREA, so the record for
              // post-swap vertex t lives at f_pi of the mirrored index
              mp_addr_q <= {32'h0, clip_q ? clp_q : vso_q} +
                           64'(f_pi(vsw_q && t_q != 2'd0
                                    ? 2'd3 - t_q : t_q)) * 64'(VSTR) +
                           64'd16 + {28'h0, lc_q[2:0], 4'h0};
              mp_data_q <= '0; mp_strb_q <= '0;
              mp_ret_q <= S_PR_VF;
              mp_acked_q <= 1'b0;
              st_q <= S_MPW;
            end
          end
          // -- scan loop: 2x2 blocks; a block with any covered pixel
          // emits four lane records (uncovered lanes = helpers) ------
          S_SCAN: begin
            if (sx_q > bx1_q) begin
              sx_q <= bx0_q & ~16'd1;
              if (sy_q >= by1_q) begin
                t_pd();
                // per-primitive flush keeps front_q constant inside
                // each FS batch (imm[3] carries it to the wave)
                if (f_q != 6'd0) begin
                  nf_q <= {1'b0, f_q}; f_q <= '0;
                  flr_q <= S_PR_I0;
                  st_q <= S_FLUSH;
                end else
                  st_q <= S_PR_I0;
              end else
                sy_q <= sy_q + 16'd2;
            end else if (blk_hit) begin
              lane_q <= 2'd0;
              help_q <= !f_lcov(2'd0);
              px_q   <= sx_q;
              py_q   <= sy_q;
              e_q[0] <= f_le(0, 2'd0);
              e_q[1] <= f_le(1, 2'd0);
              e_q[2] <= f_le(2, 2'd0);
              st_q <= S_F_LE0;
            end else
              sx_q <= sx_q + 16'd2;
          end
          // next lane of the block: reload its edge functions and
          // helper flag, then rerun the interpolation sequence
          S_F_LNEXT: begin
            help_q <= !f_lcov(lane_q);
            px_q   <= sx_q + {15'h0, lane_q[0]};
            py_q   <= sy_q + {15'h0, lane_q[1]};
            e_q[0] <= f_le(0, lane_q);
            e_q[1] <= f_le(1, lane_q);
            e_q[2] <= f_le(2, lane_q);
            st_q <= S_F_LE0;
          end
          // -- per-fragment fp sequence -------------------------------------
          S_F_LE0: begin
            fp_kind_q <= 2'd2; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_a_q <= 32'(e_q[0] >>> shf_q);
            fp_ret_q <= S_F_LE1; st_q <= S_FPS;
          end
          S_F_LE1: begin
            lam_q[0] <= fp_res_q;
            fp_a_q <= 32'(e_q[1] >>> shf_q);
            fp_ret_q <= S_F_LE2; st_q <= S_FPS;
          end
          S_F_LE2: begin
            lam_q[1] <= fp_res_q;
            fp_a_q <= 32'(e_q[2] >>> shf_q);
            fp_ret_q <= S_F_L0; st_q <= S_FPS;
          end
          S_F_L0: begin
            lam_q[2] <= fp_res_q;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_a_q <= lam_q[0]; fp_b_q <= rcpa_q;
            fp_ret_q <= S_F_L1; st_q <= S_FPS;
          end
          S_F_L1: begin
            lam_q[0] <= fp_res_q;
            fp_a_q <= lam_q[1]; fp_b_q <= rcpa_q;
            fp_ret_q <= S_F_L2; st_q <= S_FPS;
          end
          S_F_L2: begin
            lam_q[1] <= fp_res_q;
            fp_a_q <= lam_q[2]; fp_b_q <= rcpa_q;
            fp_ret_q <= S_F_P0; st_q <= S_FPS;
          end
          S_F_P0: begin
            lam_q[2] <= fp_res_q;
            fp_a_q <= lam_q[0]; fp_b_q <= vrw_q[0];
            fp_ret_q <= S_F_P1; st_q <= S_FPS;
          end
          S_F_P1: begin
            pv_q[0] <= fp_res_q;
            fp_a_q <= lam_q[1]; fp_b_q <= vrw_q[1];
            fp_ret_q <= S_F_P2; st_q <= S_FPS;
          end
          S_F_P2: begin
            pv_q[1] <= fp_res_q;
            fp_a_q <= lam_q[2]; fp_b_q <= vrw_q[2];
            fp_ret_q <= S_F_S0; st_q <= S_FPS;
          end
          S_F_S0: begin
            pv_q[2] <= fp_res_q;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b0;
            fp_a_q <= '0;
            fp_b_q <= pv_q[0]; fp_c_q <= pv_q[1];
            fp_ret_q <= S_F_S1; st_q <= S_FPS;
          end
          S_F_S1: begin
            fp_a_q <= '0;
            fp_b_q <= fp_res_q; fp_c_q <= pv_q[2];
            fp_ret_q <= S_F_RD; st_q <= S_FPS;
          end
          S_F_RD: begin
            fp_kind_q <= 2'd1; fp_o_q <= '0;
            fp_a_q <= 32'h3F800000; fp_b_q <= fp_res_q;
            fp_ret_q <= S_F_Z1; st_q <= S_FPS;
          end
          S_F_Z1: begin
            rs_q <= fp_res_q;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_a_q <= lam_q[0]; fp_b_q <= vz_q[0];
            fp_c_q <= 32'h0;
            fp_ret_q <= S_F_Z2; st_q <= S_FPS;
          end
          S_F_Z2: begin
            fp_a_q <= lam_q[1]; fp_b_q <= vz_q[1];
            fp_c_q <= fp_res_q;
            fp_ret_q <= S_F_Z3; st_q <= S_FPS;
          end
          S_F_Z3: begin
            fp_a_q <= lam_q[2]; fp_b_q <= vz_q[2];
            fp_c_q <= fp_res_q;
            fp_ret_q <= S_F_PXI; st_q <= S_FPS;
          end
          S_F_PXI: begin
            fz_q <= fp_res_q;                    // z = Σ λ·z
            fp_kind_q <= 2'd2; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_a_q <= {15'h0, px_q, 1'b1};       // 2*px+1
            fp_ret_q <= S_F_PXM; st_q <= S_FPS;
          end
          S_F_PXM: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_a_q <= fp_res_q; fp_b_q <= 32'h3F000000; // *0.5
            fp_ret_q <= S_F_PYI; st_q <= S_FPS;
          end
          S_F_PYI: begin
            conv_q[0] <= fp_res_q;               // px+0.5
            fp_kind_q <= 2'd2; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_a_q <= {15'h0, py_q, 1'b1};
            fp_ret_q <= S_F_PYM; st_q <= S_FPS;
          end
          S_F_PYM: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_a_q <= fp_res_q; fp_b_q <= 32'h3F000000;
            // conv_q[1] must land before the early-Z detour can
            // clobber fp_res_q (the D16 decode) — S_F_PY2 latches it
            fp_ret_q <= S_F_PY2;
            st_q <= S_FPS;
          end
          S_F_PY2: begin
            conv_q[1] <= fp_res_q;               // py+0.5
            // helpers skip early-Z entirely (G2b); so do draws with
            // no depth attachment
            st_q <= (!dr_q.da_valid || help_q) ? S_F_W0
                    : dr_q.depth_test ? S_DZ_RD
                    : dr_q.depth_write ? S_DZ_WR
                    : S_F_W0;
          end
          // ---- early-Z: read depth, compare, optionally write ----
          S_DZ_RD: begin
            mp_we_q <= 1'b0;
            mp_addr_q <= {32'h0, dr_q.da.base} +
                         64'(py_q) * 64'(dpitch_w) +
                         64'((32'(px_q) *
                              (dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM)
                               ? 32'd2 : 32'd4)) & ~64'd7);
            mp_data_q <= '0; mp_strb_q <= '0;
            mp_ret_q <= S_DZ_DI;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_DZ_DI: begin
            if (dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM)) begin
              // u16 -> f32 then *1/65535
              fp_kind_q <= 2'd2; fp_o_q <= 2'd0; fp_mod_q <= 1'b1;
              fp_a_q <= {16'h0, mp_res_q[16*px_q[1:0] +: 16]};
              fp_ret_q <= S_DZ_DM;
              st_q <= S_FPS;
            end else begin
              dz_q <= mp_res_q[32*px_q[0] +: 32];
              st_q <= S_DZ_C2;
            end
          end
          S_DZ_DM: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_a_q <= fp_res_q;
            fp_b_q <= 32'h38008001;              // *1/65535
            fp_ret_q <= S_DZ_C2;
            st_q <= S_FPS;
          end
          S_DZ_C2: begin
            if (dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM))
              dz_q <= fp_res_q;
            // (dz_q holds the decoded texel for D32 already)
            if (!f_dcmp(dr_q.depth_op, zc_w,
                        dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM)
                        ? fp_res_q : dz_q)) begin
              // depth fail: the lane still joins the FS batch but as
              // a helper — quad records must stay 4-aligned for the
              // shader's derivative groups, and helpers never reach
              // the ROP so nothing is written
              help_q <= 1'b1;
              st_q <= S_F_W0;
            end else if (dr_q.depth_write)
              st_q <= S_DZ_WR;
            else
              st_q <= S_F_W0;
          end
          S_DZ_WR: begin
            mp_we_q <= 1'b1;
            mp_addr_q <= {32'h0, dr_q.da.base} +
                         64'(py_q) * 64'(dpitch_w) +
                         64'((32'(px_q) *
                              (dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM)
                               ? 32'd2 : 32'd4)) & ~64'd7);
            mp_data_q <=
              dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM)
              ? {4{f_f32_u16(zc_w)}} : {2{zc_w}};
            mp_strb_q <=
              dr_q.da.fmt == 8'(APU_IMG_FMT_D16_UNORM)
              ? 8'h03 << {px_q[1:0], 1'b0}
              : 8'h0F << {px_q[0], 2'b00};
            mp_ret_q <= S_F_W0;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          // write fs_in slot0 {px+.5, py+.5, z, rcp_s}
          S_F_W0: begin
            mp_we_q <= 1'b1;
            mp_addr_q <= {32'h0, fsi_q} +
                         {26'h0, f_q} * 64'(VSTR);
            mp_data_q <= {conv_q[1], conv_q[0]};
            mp_strb_q <= 8'hFF;
            mp_ret_q <= S_F_W1;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_F_W1: begin
            mp_we_q <= 1'b1;
            mp_addr_q <= {32'h0, fsi_q} +
                         {26'h0, f_q} * 64'(VSTR) + 64'd8;
            mp_data_q <= {rs_q, fz_q};
            mp_strb_q <= 8'hFF;
            mp_ret_q <= S_F_LSET;
            mp_acked_q <= 1'b0;
            lc_q <= '0;
            st_q <= S_MPW;
          end
          // per-location interpolation
          S_F_LSET: begin
            if (lc_q == 4'd8) begin
              // fragment complete: record pixel + helper flag, then
              // the next lane of the 2x2 block (or the next block).
              // f_q is always ≡0 mod 4 at a block boundary, so a
              // batch-full flush can only split between blocks
              fsxy_q[f_q]   <= {py_q, px_q};
              fs_help_q[f_q] <= help_q;
              lane_q <= lane_q + 2'd1;
              if ({1'b0, f_q} + 7'd1 == 7'(FSB)) begin
                nf_q <= {1'b0, f_q} + 7'd1; f_q <= '0;
                if (lane_q == 2'd3) sx_q <= sx_q + 16'd2;
                flr_q <= (lane_q == 2'd3) ? S_SCAN : S_F_LNEXT;
                st_q <= S_FLUSH;
              end else begin
                f_q <= f_q + 6'd1;
                if (lane_q == 2'd3) sx_q <= sx_q + 16'd2;
                st_q <= (lane_q == 2'd3) ? S_SCAN : S_F_LNEXT;
              end
            end else if (!varm_q[lc_q[2:0]]) begin
              lc_q <= lc_q + 4'd1;
            end else begin
              c_q <= '0;
              st_q <= S_F_V0;
            end
          end
          S_F_V0: begin
            // comp c: v = (p0*V0 + p1*V1 + p2*V2) * rcp_s
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_a_q <= pv_q[0]; fp_b_q <= var_q[0][lc_q[2:0]][c_q[1:0]];
            fp_ret_q <= S_F_V1; st_q <= S_FPS;
          end
          S_F_V1: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd0; fp_mod_q <= 1'b0;
            fp_a_q <= pv_q[1]; fp_b_q <= var_q[1][lc_q[2:0]][c_q[1:0]];
            fp_c_q <= fp_res_q;
            fp_ret_q <= S_F_V2; st_q <= S_FPS;
          end
          S_F_V2: begin
            fp_a_q <= pv_q[2]; fp_b_q <= var_q[2][lc_q[2:0]][c_q[1:0]];
            fp_c_q <= fp_res_q;
            fp_ret_q <= S_F_VS; st_q <= S_FPS;
          end
          S_F_VS: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_a_q <= fp_res_q; fp_b_q <= rs_q;
            fp_ret_q <= (c_q[1:0] == 2'd3) ? S_F_VW0 : S_F_VN;
            st_q <= S_FPS;
          end
          S_F_VN: begin
            conv_q[c_q[1:0]] <= fp_res_q;
            c_q <= c_q + 3'd1;
            st_q <= S_F_V0;
          end
          S_F_VW0: begin
            conv_q[3] <= fp_res_q;
            mp_we_q <= 1'b1;
            mp_addr_q <= {32'h0, fsi_q} +
                         {26'h0, f_q} * 64'(VSTR) +
                         64'd16 + {28'h0, lc_q[2:0], 4'h0};
            mp_data_q <= {conv_q[1], conv_q[0]};
            mp_strb_q <= 8'hFF;
            mp_ret_q <= S_F_VW1;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_F_VW1: begin
            mp_we_q <= 1'b1;
            mp_addr_q <= {32'h0, fsi_q} +
                         {26'h0, f_q} * 64'(VSTR) +
                         64'd16 + {28'h0, lc_q[2:0], 4'h0} + 64'd8;
            mp_data_q <= {conv_q[3], conv_q[2]};
            mp_strb_q <= 8'hFF;
            mp_ret_q <= S_F_LSET;
            mp_acked_q <= 1'b0;
            lc_q <= lc_q + 4'd1;
            st_q <= S_MPW;
          end
          // ---- FS batch flush ----------------------------------------------
          S_FLUSH: begin
`ifdef G6LC_APU_DBG_LOST
            if (!shv_q)
              $display("[DBG] rast flush: nf=%0d ret=%0d t=%0t",
                       nf_q, flr_q, $time);
`endif
            sh_ctype_o <= APU_SH_WORK_FS;
            sh_slot_o <= dr_q.fs_slot;
            sh_imm_o[0] <= {25'h0, nf_q};
            sh_imm_o[1] <= fsi_q;
            sh_imm_o[2] <= fso_q;
            // imm[3].0 = the primitive's front-facing bit for the
            // FrontFacing builtin; constant for the whole batch
            // because the scan flushes at every primitive boundary
            sh_imm_o[3] <= {31'h0, front_q}; sh_imm_o[4] <= '0;
            sh_imm_o[5] <= '0; sh_imm_o[6] <= '0; sh_imm_o[7] <= '0;
            shv_q <= 1'b1;
            if (shv_q && sh_work_ready_i) begin
              shv_q <= 1'b0;
              shd_q <= 1'b0;
              st_q <= S_FS_WAIT;
            end
          end
          S_FS_WAIT:
            if (shd_q) begin
              shd_q <= 1'b0;
              if (shdp_q.code != APU_SH_DONE_OK) begin
                code_q <= shdp_q.code;
                st_q <= S_FIN_BAD;
              end else begin
                robust_q <= robust_q + shdp_q.robust;
                r_q <= '0; at_q <= '0;
                st_q <= S_ROP_R0;
              end
            end
          // ---- ROP: per fragment × per valid attachment ---------------
          // FS-out location l -> ca[l]; dst read-back + f32 blend when
          // enabled, per-format encode, colorWriteMask strobes
          S_ROP_R0: begin
            if (fs_help_q[r_q]) begin
              // helper invocation: it only exists to complete the
              // derivative quad — never let it reach a pixel write
              at_q <= '0;
              if ({1'b0, r_q} + 7'd1 >= nf_q) st_q <= flr_q;
              else begin
                r_q <= r_q + 6'd1;
                st_q <= S_ROP_R0;
              end
            end else if (!dr_q.ca_valid[at_q]) begin
              // skip an absent attachment; at 3 the fragment is done
              if (at_q == 2'd3) begin
                at_q <= '0;
                if ({1'b0, r_q} + 7'd1 >= nf_q) st_q <= flr_q;
                else begin
                  r_q <= r_q + 6'd1;
                  st_q <= S_ROP_R0;
                end
              end else
                at_q <= at_q + 2'd1;
            end else begin
              mp_we_q <= 1'b0;
              mp_addr_q <= {32'h0, fso_q} +
                           {26'h0, r_q} * 64'(ASTR) +
                           {28'h0, at_q, 4'h0};
              mp_data_q <= '0; mp_strb_q <= '0;
              mp_ret_q <= S_ROP_R1;
              mp_acked_q <= 1'b0;
              st_q <= S_MPW;
            end
          end
          S_ROP_R1: begin
            src_q[0] <= mp_res_q[31:0];
            src_q[1] <= mp_res_q[63:32];
            mp_we_q <= 1'b0;
            mp_addr_q <= mp_addr_q + 64'd8;
            mp_ret_q <= S_ROP_R2;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_ROP_R2: begin
            src_q[2] <= mp_res_q[31:0];
            src_q[3] <= mp_res_q[63:32];
            if (!dr_q.blend[at_q].en) begin
              res_q <= {mp_res_q[63:32], mp_res_q[31:0],
                        src_q[1], src_q[0]};
              st_q <= S_ROP_WR;
            end else begin
              // blend needs the dst texel decoded to f32
              c_q <= '0;
              mp_we_q <= 1'b0;
              mp_addr_q <= {32'h0, dr_q.ca[at_q].base} +
                           64'(fr_py) * 64'(cpitch_w) +
                           64'((32'(fr_px) * 32'd4) & ~64'd7);
              mp_data_q <= '0; mp_strb_q <= '0;
              mp_ret_q <= S_ROP_DI;
              mp_acked_q <= 1'b0;
              st_q <= S_MPW;
            end
          end
          // dst decode: UNORM byte -> I2F *1/255; sRGB -> LUT16 -> I2F
          // *1/65535 (alpha stays on the linear byte path)
          S_ROP_DI: begin
            fp_kind_q <= 2'd2; fp_o_q <= 2'd0; fp_mod_q <= 1'b1;
            fp_a_q <= (f_is_srgb(dr_q.ca[at_q].fmt) &&
                       c_q[1:0] != 2'd3)
                      ? {16'h0, APU_SRGB_TO_LIN[
                          mp_res_q[32*fr_px[0] +
                                   8*f_cbyte(dr_q.ca[at_q].fmt,
                                             c_q[1:0]) +: 8]]}
                      : {24'h0, mp_res_q[32*fr_px[0] +
                                8*f_cbyte(dr_q.ca[at_q].fmt,
                                          c_q[1:0]) +: 8]};
            fp_ret_q <= S_ROP_DM;
            st_q <= S_FPS;
          end
          S_ROP_DM: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_a_q <= fp_res_q;
            fp_b_q <= (f_is_srgb(dr_q.ca[at_q].fmt) &&
                       c_q[1:0] != 2'd3)
                      ? 32'h38008001                    // *1/65535
                      : 32'h3B808081;                   // *1/255
            fp_ret_q <= S_ROP_DS;
            st_q <= S_FPS;
          end
          S_ROP_DS: begin
            dst_q[c_q[1:0]] <= fp_res_q;
            if (c_q[1:0] == 2'd3) begin
              // precompute 1 - dst.a for SRC_ALPHA_SATURATE
              fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
              fp_a_q <= '0;
              fp_b_q <= 32'h3F800000; fp_c_q <= fp_res_q;
              fp_ret_q <= S_BL_SAT;
              st_q <= S_FPS;
            end else begin
              c_q <= c_q + 3'd1;
              st_q <= S_ROP_DI;
            end
          end
          S_BL_SAT: begin
            omd3_q <= fp_res_q;
            c_q <= '0;
            st_q <= (dr_q.blend[at_q].op_c >= 3'd3) ? S_BL_MM
                                                    : S_BL_F1;
          end
          // MIN/MAX ignore the factors (fp f32 compare in int domain)
          S_BL_MM: begin
            res_q[c_q[1:0]] <=
              (bop_w == APU_RAST_BO_MIN)
              ? (f_f32_lt(src_q[c_q[1:0]], dst_q[c_q[1:0]])
                 ? src_q[c_q[1:0]] : dst_q[c_q[1:0]])
              : (f_f32_lt(dst_q[c_q[1:0]], src_q[c_q[1:0]])
                 ? src_q[c_q[1:0]] : dst_q[c_q[1:0]]);
            if (c_q[1:0] == 2'd3) st_q <= S_ROP_WR;
            else begin
              c_q <= c_q + 3'd1;
              st_q <= (c_q[1:0] == 2'd2 &&
                       dr_q.blend[at_q].op_a >= 3'd3) ? S_BL_MM
                      : (c_q[1:0] == 2'd2 ||
                         dr_q.blend[at_q].op_c < 3'd3) ? S_BL_F1
                      : S_BL_MM;
            end
          end
          // factor selects: ONE_MINUS_* issue SUB(1.0, base)
          S_BL_F1: begin
            if (f_fminus(bsf_w)) begin
              fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
              fp_a_q <= '0;
              fp_b_q <= 32'h3F800000;
              fp_c_q <= f_fbase(bsf_w, c_q[1:0]);
              fp_ret_q <= S_BL_F1B;
              st_q <= S_FPS;
            end else begin
              sf_q <= f_fbase(bsf_w, c_q[1:0]);
              st_q <= S_BL_F2;
            end
          end
          S_BL_F1B: begin
            sf_q <= fp_res_q;
            st_q <= S_BL_F2;
          end
          S_BL_F2: begin
            if (f_fminus(bdf_w)) begin
              fp_kind_q <= 2'd0; fp_o_q <= 2'd1; fp_mod_q <= 1'b1;
              fp_a_q <= '0;
              fp_b_q <= 32'h3F800000;
              fp_c_q <= f_fbase(bdf_w, c_q[1:0]);
              fp_ret_q <= S_BL_F2B;
              st_q <= S_FPS;
            end else begin
              df_q <= f_fbase(bdf_w, c_q[1:0]);
              st_q <= S_BL_M1;
            end
          end
          S_BL_F2B: begin
            df_q <= fp_res_q;
            st_q <= S_BL_M1;
          end
          S_BL_M1: begin
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_a_q <= src_q[c_q[1:0]]; fp_b_q <= sf_q;
            fp_ret_q <= S_BL_M2;
            st_q <= S_FPS;
          end
          S_BL_M2: begin
            bm1_q <= fp_res_q;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd2; fp_mod_q <= 1'b0;
            fp_a_q <= dst_q[c_q[1:0]]; fp_b_q <= df_q;
            fp_ret_q <= S_BL_OP;
            st_q <= S_FPS;
          end
          S_BL_OP: begin
            bm2_q <= fp_res_q;
            fp_kind_q <= 2'd0; fp_o_q <= 2'd1;
            fp_a_q <= '0;
            // ADD: b+c; SUBTRACT: s-d; REVERSE_SUBTRACT: d-s
            fp_b_q <= (bop_w == APU_RAST_BO_REVERSE_SUBTRACT)
                      ? fp_res_q : bm1_q;
            fp_c_q <= (bop_w == APU_RAST_BO_REVERSE_SUBTRACT)
                      ? bm1_q : fp_res_q;
            fp_mod_q <= (bop_w != APU_RAST_BO_ADD);
            fp_ret_q <= S_BL_ST;
            st_q <= S_FPS;
          end
          S_BL_ST: begin
            res_q[c_q[1:0]] <= fp_res_q;
            if (c_q[1:0] == 2'd3) st_q <= S_ROP_WR;
            else begin
              c_q <= c_q + 3'd1;
              st_q <= (c_q[1:0] == 2'd2 &&
                       dr_q.blend[at_q].op_a >= 3'd3) ? S_BL_MM
                      : (c_q[1:0] == 2'd2 ||
                         dr_q.blend[at_q].op_c < 3'd3) ? S_BL_F1
                      : S_BL_MM;
            end
          end
          S_ROP_WR: begin
            mp_we_q <= 1'b1;
            mp_addr_q <= {32'h0, dr_q.ca[at_q].base} +
                         64'(fr_py) * 64'(cpitch_w) +
                         64'((32'(fr_px) * 32'd4) & ~64'd7);
            mp_data_q <= {rop_pix, rop_pix};
            mp_strb_q <= rop_strb;
            mp_ret_q <= S_ROP_NX;
            mp_acked_q <= 1'b0;
            st_q <= S_MPW;
          end
          S_ROP_NX: begin
            if (at_q == 2'd3) begin
              at_q <= '0;
              if ({1'b0, r_q} + 7'd1 >= nf_q) st_q <= flr_q;
              else begin
                r_q <= r_q + 6'd1;
                st_q <= S_ROP_R0;
              end
            end else begin
              at_q <= at_q + 2'd1;
              st_q <= S_ROP_R0;
            end
          end
          // ---- batch / instance advance ------------------------------------
          S_BATNEXT: begin
            if (bat_q + {26'h0, nv_q} >= dr_q.vertex_count) begin
              bat_q <= '0;
              if (inst_q + 32'd1 >=
                  dr_q.first_instance + dr_q.instance_count)
                st_q <= S_FIN_OK;
              else begin
                inst_q <= inst_q + 32'd1;
                st_q <= S_DR_BATCH;
              end
            end else begin
              bat_q <= bat_q + {26'h0, nv_q};
              st_q <= S_DR_BATCH;
            end
          end
          // ---- shared sequencers ------------------------------------------
          S_MPW: begin
            if (!mp_acked_q && mp_req_ready_i) mp_acked_q <= 1'b1;
            if (mp_acked_q && mp_rsp_valid_i) begin
              mp_res_q <= mp_rsp_i.rdata;
              if (mp_ret_q == S_GA_RD) begin
                // windowed gather: chain until the byte range is covered
                win_q[64 * i_q +: 64] <= mp_rsp_i.rdata;
                if (wn_q != 2'd0) begin
                  wn_q <= wn_q - 2'd1;
                  i_q <= i_q + 2'd1;
                  mp_addr_q <= mp_addr_q + 64'd8;
                  mp_acked_q <= 1'b0;
                end else
                  st_q <= gret_q;
              end else if (mp_ret_q == S_PR_VF) begin
                var_q[t_q][lc_q[2:0]][0] <= mp_rsp_i.rdata[31:0];
                var_q[t_q][lc_q[2:0]][1] <= mp_rsp_i.rdata[63:32];
                mp_addr_q <= mp_addr_q + 64'd8;
                mp_acked_q <= 1'b0;
                mp_ret_q <= S_PR_VF2;
              end else if (mp_ret_q == S_PR_VF2) begin
                var_q[t_q][lc_q[2:0]][2] <= mp_rsp_i.rdata[31:0];
                var_q[t_q][lc_q[2:0]][3] <= mp_rsp_i.rdata[63:32];
                if (t_q == 2'd2) begin
                  t_q <= '0;
                  lc_q <= lc_q + 4'd1;
                end else
                  t_q <= t_q + 2'd1;
                st_q <= S_PR_VF;
              end else
                st_q <= mp_ret_q;
            end
          end
          S_FPS: begin
            fp_iss_q <= 1'b1;
            st_q <= S_FPW;
          end
          S_FPW: begin
            if (fma_ir || dq_ir || cv_ir) fp_iss_q <= 1'b0;
            if (fma_ov || dq_ov || cv_ov) begin
              fp_res_q <= fma_ov ? fma_res : dq_ov ? dq_res : cv_res;
              st_q <= fp_ret_q;
            end
          end
          // ---- completion --------------------------------------------------
          S_FIN_OK: begin
            done_o <= 1'b1;
            done_pl_o <= '{code: APU_SH_DONE_OK, wave: '0, pc: '0,
                           robust: robust_q, work_id: wid_q - 32'd1};
            st_q <= S_IDLE;
          end
          S_FIN_BAD: begin
            done_o <= 1'b1;
            done_pl_o <= '{code: code_q, wave: '0, pc: '0,
                           robust: robust_q, work_id: wid_q - 32'd1};
            st_q <= S_IDLE;
          end
          default: st_q <= S_IDLE;
        endcase
      end
    end

`ifdef G6LC_APU_DBG_LOST
    // debug probe: which state reaches S_FIN_BAD + the shader code
    // when a VS/FS wave fails (temporary G1c bring-up aid)
    logic [7:0] dbg_st_q;
    always_ff @(posedge clk_i) begin
      if (st_q == S_FIN_BAD && dbg_st_q != S_FIN_BAD)
        $display("[DBG] rast FIN_BAD: from=%0d code=%0d op=%0d topo=%0d ibt=%0d vc=%0d ic=%0d fmtok=%0d shcode=%0d t=%0t",
                 dbg_st_q, code_q, dr_q.op, dr_q.topology, dr_q.ib_type,
                 dr_q.vertex_count, dr_q.instance_count, fmt_ok,
                 shdp_q.code, $time);
      if (sh_done_i && sh_done_pl_i.code != APU_SH_DONE_OK)
        $display("[DBG] rast sh wave fault: st=%0d code=%0d wid=%08x t=%0t",
                 st_q, sh_done_pl_i.code, sh_done_pl_i.work_id, $time);
      dbg_st_q <= 8'(st_q);
    end
`endif
  end
endmodule

// enable-0 fixture for the synthesis screen
module g6lc_apu_rast_fixture
  import g6lc_apu_mp_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_sh_pkg::*;
  import g6lc_apu_rast_pkg::*;
  import g6lc_apu_vgpages_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic              clk_i,
  input  logic              rst_ni,
  input  logic              testmode_i,
  input  logic              work_valid_i,
  output logic              work_ready_o,
  input  apu_cmdexec_work_t work_i,
  input  apu_rast_draw_t    rd_i,
  input  apu_sh_desc_t      desc_i,
  input  logic [5:0]        push_n_i,
  input  logic [1023:0]     push_i,
  output logic              done_o,
  output apu_sh_done_t      done_pl_o,
  output logic              sh_work_valid_o,
  input  logic              sh_work_ready_i,
  output logic [31:0]       sh_ctype_o,
  output logic [7:0][31:0]  sh_imm_o,
  output logic [2:0]        sh_slot_o,
  output apu_sh_desc_t      sh_desc_o,
  output logic [5:0]        sh_push_n_o,
  output logic [1023:0]     sh_push_o,
  input  logic              sh_done_i,
  input  apu_sh_done_t      sh_done_pl_i,
  output logic              mp_req_valid_o,
  input  logic              mp_req_ready_i,
  output apu_mp_req_t       mp_req_o,
  input  logic              mp_rsp_valid_i,
  input  apu_mp_rsp_t       mp_rsp_i,
  output logic              pg_req_valid_o,
  input  logic              pg_req_ready_i,
  output apu_vgpages_req_t  pg_req_o,
  input  logic              pg_cpl_valid_i,
  output logic              pg_cpl_ready_o,
  input  apu_vgpages_cpl_t  pg_cpl_i,
  output logic              busy_o
);
  g6lc_apu_rast #(.Enable(Enable)) i_dut (.*);
endmodule
