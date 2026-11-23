// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Zfa execute leaf muxed in fpu_wrap: fli.fmt, fround/froundnx.fmt, fcvtmod.w.d.
// fminm/fmaxm and fleq/fltq stay in fpnew_noncomp. Round-to-integral is not F2F.

// hyp8 port of core/g6lc_fp_zfa.sv (89d3dadd0). Config type adapted
// cva6_cfg_t/CVA6Cfg -> g6lc_cfg_t/G6LCCfg; ariane_pkg -> g6lc_core_pkg.
//
module g6lc_fp_zfa_round #(
    parameter int unsigned EXP_BITS = 8,
    parameter int unsigned MAN_BITS = 23
) (
    input  logic [EXP_BITS+MAN_BITS:0] op_i,
    input  logic [2:0]                 rm_i,
    input  logic                       set_nx_i,
    output logic [EXP_BITS+MAN_BITS:0] res_o,
    output logic                       nv_o,
    output logic                       nx_o
);
  localparam int unsigned WIDTH   = EXP_BITS + MAN_BITS + 1;
  localparam int unsigned BIAS    = (1 << (EXP_BITS - 1)) - 1;
  localparam int unsigned SH_W    = $clog2(MAN_BITS + 1);
  localparam logic [EXP_BITS-1:0] EXP_INF  = {EXP_BITS{1'b1}};
  localparam logic [EXP_BITS-1:0] EXP_ONE  = EXP_BITS'(BIAS);
  localparam logic [EXP_BITS-1:0] EXP_HALF = EXP_BITS'(BIAS - 1);
  localparam logic [EXP_BITS-1:0] EXP_INT  = EXP_BITS'(BIAS + MAN_BITS);

  logic                    sign;
  logic [EXP_BITS-1:0]     exp_f;
  logic [MAN_BITS-1:0]     man;
  logic                    is_inf, is_nan, is_snan, is_zero;
  logic                    lt_one, ge_int;
  logic [SH_W-1:0]         frac_len;
  logic                    is_half, mag_gt_half, round_up;
  logic [MAN_BITS:0]       sig;
  logic [MAN_BITS+1:0]     acc;
  logic [MAN_BITS:0]       sticky_mask, keep_mask;
  logic [MAN_BITS+1:0]     inc_mask;
  logic                    guard, sticky, lsb;

  assign sign    = op_i[WIDTH-1];
  assign exp_f   = op_i[MAN_BITS+EXP_BITS-1:MAN_BITS];
  assign man     = op_i[MAN_BITS-1:0];
  assign is_inf  = (exp_f == EXP_INF) && (man == '0);
  assign is_nan  = (exp_f == EXP_INF) && (man != '0);
  assign is_snan = is_nan && !man[MAN_BITS-1];
  assign is_zero = (exp_f == '0) && (man == '0);
  // A10 narrow biased exponent compares (no 32-bit int subtraction).
  assign lt_one   = (exp_f < EXP_ONE);
  assign ge_int   = (exp_f >= EXP_INT);
  assign frac_len = SH_W'(EXP_INT - exp_f);
  assign sig      = {1'b1, man};

  // Thermometer masks via flat genvar assigns (zero procedural loop carry).
  for (genvar k = 0; k <= MAN_BITS; k++) begin : gen_round_masks
    assign sticky_mask[k] = ({1'b0, SH_W'(k)} + (SH_W+1)'(1)) < {1'b0, frac_len};
    assign keep_mask[k]   = SH_W'(k) >= frac_len;
    assign inc_mask[k]    = (SH_W'(k) == frac_len);
  end
  assign inc_mask[MAN_BITS+1] = 1'b0;

  // Unconditional mid-range rounding datapath (A118: hoisted outside if-chain).
  logic [SH_W-1:0]         guard_idx;
  logic                    mid_guard, mid_lsb, mid_sticky, mid_rup;
  logic [MAN_BITS+1:0]     mid_acc_trunc, mid_acc_inc, mid_acc;
  logic [WIDTH-1:0]        mid_res, lt1_res;
  logic                    lt1_rup;
  assign guard_idx  = frac_len - SH_W'(1);
  assign mid_guard  = sig[guard_idx];
  assign mid_lsb    = sig[frac_len];
  assign mid_sticky = |(sig & sticky_mask);
  assign is_half     = (exp_f == EXP_HALF) && (man == '0);
  assign mag_gt_half = (exp_f == EXP_HALF) && (man != '0);
  always_comb begin
    unique case (rm_i)
      3'b000:  begin lt1_rup = mag_gt_half;          mid_rup = mid_guard && (mid_sticky || mid_lsb); end
      3'b001:  begin lt1_rup = 1'b0;                 mid_rup = 1'b0; end
      3'b010:  begin lt1_rup = sign;                 mid_rup = sign && (mid_guard || mid_sticky); end
      3'b011:  begin lt1_rup = ~sign;                mid_rup = ~sign && (mid_guard || mid_sticky); end
      3'b100:  begin lt1_rup = is_half | mag_gt_half; mid_rup = mid_guard; end
      default: begin lt1_rup = mag_gt_half;          mid_rup = mid_guard && (mid_sticky || mid_lsb); end
    endcase
  end
  assign mid_acc_trunc = {1'b0, sig & keep_mask};
  assign mid_acc_inc   = mid_acc_trunc + inc_mask;
  // A146 per-chunk select replication on wide FP mantissa/result muxes.
  localparam int unsigned ACC_W = MAN_BITS + 2;
  for (genvar b = 0; b < ACC_W; b = b + 8) begin : gen_acc_lane
    localparam int unsigned LW = ((b + 8) <= ACC_W) ? 8 : (ACC_W - b);
    logic rup_b;
    assign rup_b = mid_rup;
    assign mid_acc[b +: LW] = rup_b ? mid_acc_inc[b +: LW] : mid_acc_trunc[b +: LW];
  end
  logic [WIDTH-1:0] qnan_val, mid_ovf_val, mid_norm_val;
  assign qnan_val     = {1'b0, EXP_INF, 1'b1, {MAN_BITS - 1{1'b0}}};
  assign mid_ovf_val  = (exp_f == (EXP_INF - 1'b1)) ? {sign, EXP_INF, {MAN_BITS{1'b0}}}
                                                    : {sign, exp_f + 1'b1, {MAN_BITS{1'b0}}};
  assign mid_norm_val = {sign, exp_f, mid_acc[MAN_BITS-1:0]};
  assign lt1_res      = lt1_rup ? {sign, EXP_ONE, {MAN_BITS{1'b0}}}
                                : {sign, {EXP_BITS{1'b0}}, {MAN_BITS{1'b0}}};
  for (genvar b = 0; b < WIDTH; b = b + 8) begin : gen_res_lane
    localparam int unsigned LW = ((b + 8) <= WIDTH) ? 8 : (WIDTH - b);
    logic s_nan, s_pass, s_lt1, s_ovf;
    assign s_nan  = is_nan;
    assign s_pass = !is_nan && (is_inf || is_zero || (!lt_one && ge_int));
    assign s_lt1  = !is_nan && !is_inf && !is_zero && lt_one;
    assign s_ovf  = mid_acc[MAN_BITS+1];
    assign mid_res[b +: LW] = s_ovf ? mid_ovf_val[b +: LW] : mid_norm_val[b +: LW];
    assign res_o[b +: LW]   = s_nan  ? qnan_val[b +: LW] :
                              s_pass ? op_i[b +: LW] :
                              s_lt1  ? lt1_res[b +: LW] :
                                       mid_res[b +: LW];
  end
  assign nv_o  = is_nan && is_snan;
  assign nx_o  = !is_nan && !is_inf && !is_zero && set_nx_i &&
                 (lt_one || (!ge_int && (mid_guard || mid_sticky)));
endmodule

module g6lc_fp_zfa
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg  = config_pkg::g6lc_cfg_empty,
    parameter int unsigned           TagWidth = 4
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    flush_i,
    input  logic                    valid_i,
    output logic                    ready_o,
    input  fu_op                    op_i,
    input  logic [             1:0] fmt_i,
    input  logic [             2:0] rm_i,
    input  logic [G6LCCfg.FLen-1:0] operand_i,
    input  logic [    TagWidth-1:0] tag_i,
    input  logic                    ready_i,
    output logic                    valid_o,
    output logic [G6LCCfg.FLen-1:0] result_o,
    output logic [             4:0] status_o,
    output logic [    TagWidth-1:0] tag_o
);
  function automatic logic [G6LCCfg.FLen-1:0] box32(input logic [31:0] v);
    if (G6LCCfg.FLen <= 32) box32 = G6LCCfg.FLen'(v);
    else box32 = {{G6LCCfg.FLen - 32{1'b1}}, v};
  endfunction

  function automatic logic [G6LCCfg.FLen-1:0] box16(input logic [15:0] v);
    if (G6LCCfg.FLen <= 16) box16 = G6LCCfg.FLen'(v);
    else box16 = {{G6LCCfg.FLen - 16{1'b1}}, v};
  endfunction

  function automatic logic [G6LCCfg.FLen-1:0] sext32(input logic [31:0] v);
    if (G6LCCfg.FLen <= 32) sext32 = G6LCCfg.FLen'(v);
    else sext32 = {{G6LCCfg.FLen - 32{v[31]}}, v};
  endfunction

  function automatic logic [31:0] fli_s(input logic [4:0] idx);
    unique case (idx)
      5'd0:    fli_s = 32'hBF800000;
      5'd1:    fli_s = 32'h00800000;
      5'd2:    fli_s = 32'h37800000;
      5'd3:    fli_s = 32'h38000000;
      5'd4:    fli_s = 32'h3B800000;
      5'd5:    fli_s = 32'h3C000000;
      5'd6:    fli_s = 32'h3D800000;
      5'd7:    fli_s = 32'h3E000000;
      5'd8:    fli_s = 32'h3E800000;
      5'd9:    fli_s = 32'h3EA00000;
      5'd10:   fli_s = 32'h3EC00000;
      5'd11:   fli_s = 32'h3EE00000;
      5'd12:   fli_s = 32'h3F000000;
      5'd13:   fli_s = 32'h3F200000;
      5'd14:   fli_s = 32'h3F400000;
      5'd15:   fli_s = 32'h3F600000;
      5'd16:   fli_s = 32'h3F800000;
      5'd17:   fli_s = 32'h3FA00000;
      5'd18:   fli_s = 32'h3FC00000;
      5'd19:   fli_s = 32'h3FE00000;
      5'd20:   fli_s = 32'h40000000;
      5'd21:   fli_s = 32'h40200000;
      5'd22:   fli_s = 32'h40400000;
      5'd23:   fli_s = 32'h40800000;
      5'd24:   fli_s = 32'h41000000;
      5'd25:   fli_s = 32'h41800000;
      5'd26:   fli_s = 32'h43000000;
      5'd27:   fli_s = 32'h43800000;
      5'd28:   fli_s = 32'h47000000;
      5'd29:   fli_s = 32'h47800000;
      5'd30:   fli_s = 32'h7F800000;
      default: fli_s = 32'h7FC00000;
    endcase
  endfunction

  function automatic logic [63:0] fli_d(input logic [4:0] idx);
    unique case (idx)
      5'd0:    fli_d = 64'hBFF0000000000000;
      5'd1:    fli_d = 64'h0010000000000000;
      5'd2:    fli_d = 64'h3EF0000000000000;
      5'd3:    fli_d = 64'h3F00000000000000;
      5'd4:    fli_d = 64'h3F70000000000000;
      5'd5:    fli_d = 64'h3F80000000000000;
      5'd6:    fli_d = 64'h3FB0000000000000;
      5'd7:    fli_d = 64'h3FC0000000000000;
      5'd8:    fli_d = 64'h3FD0000000000000;
      5'd9:    fli_d = 64'h3FD4000000000000;
      5'd10:   fli_d = 64'h3FD8000000000000;
      5'd11:   fli_d = 64'h3FDC000000000000;
      5'd12:   fli_d = 64'h3FE0000000000000;
      5'd13:   fli_d = 64'h3FE4000000000000;
      5'd14:   fli_d = 64'h3FE8000000000000;
      5'd15:   fli_d = 64'h3FEC000000000000;
      5'd16:   fli_d = 64'h3FF0000000000000;
      5'd17:   fli_d = 64'h3FF4000000000000;
      5'd18:   fli_d = 64'h3FF8000000000000;
      5'd19:   fli_d = 64'h3FFC000000000000;
      5'd20:   fli_d = 64'h4000000000000000;
      5'd21:   fli_d = 64'h4004000000000000;
      5'd22:   fli_d = 64'h4008000000000000;
      5'd23:   fli_d = 64'h4010000000000000;
      5'd24:   fli_d = 64'h4020000000000000;
      5'd25:   fli_d = 64'h4030000000000000;
      5'd26:   fli_d = 64'h4060000000000000;
      5'd27:   fli_d = 64'h4070000000000000;
      5'd28:   fli_d = 64'h40E0000000000000;
      5'd29:   fli_d = 64'h40F0000000000000;
      5'd30:   fli_d = 64'h7FF0000000000000;
      default: fli_d = 64'h7FF8000000000000;
    endcase
  endfunction

  function automatic logic [15:0] fli_h(input logic [4:0] idx);
    unique case (idx)
      5'd0:    fli_h = 16'hBC00;
      5'd1:    fli_h = 16'h0400;
      5'd2:    fli_h = 16'h0100;
      5'd3:    fli_h = 16'h0200;
      5'd4:    fli_h = 16'h1C00;
      5'd5:    fli_h = 16'h2000;
      5'd6:    fli_h = 16'h2C00;
      5'd7:    fli_h = 16'h3000;
      5'd8:    fli_h = 16'h3400;
      5'd9:    fli_h = 16'h3500;
      5'd10:   fli_h = 16'h3600;
      5'd11:   fli_h = 16'h3700;
      5'd12:   fli_h = 16'h3800;
      5'd13:   fli_h = 16'h3900;
      5'd14:   fli_h = 16'h3A00;
      5'd15:   fli_h = 16'h3B00;
      5'd16:   fli_h = 16'h3C00;
      5'd17:   fli_h = 16'h3D00;
      5'd18:   fli_h = 16'h3E00;
      5'd19:   fli_h = 16'h3F00;
      5'd20:   fli_h = 16'h4000;
      5'd21:   fli_h = 16'h4100;
      5'd22:   fli_h = 16'h4200;
      5'd23:   fli_h = 16'h4400;
      5'd24:   fli_h = 16'h4800;
      5'd25:   fli_h = 16'h4C00;
      5'd26:   fli_h = 16'h5800;
      5'd27:   fli_h = 16'h5C00;
      5'd28:   fli_h = 16'h7800;
      5'd29:   fli_h = 16'h7C00;
      5'd30:   fli_h = 16'h7C00;
      default: fli_h = 16'h7E00;
    endcase
  endfunction

  logic [31:0] round_s_res;
  logic [63:0] round_d_res;
  logic [15:0] round_h_res;
  logic        round_s_nv, round_s_nx;
  logic        round_d_nv, round_d_nx;
  logic        round_h_nv, round_h_nx;
  logic        boxed_s, boxed_h;
  logic [31:0] op_s;
  logic [63:0] op_d;
  logic [15:0] op_h;

  if (G6LCCfg.FLen > 32) begin : gen_box_s
    assign boxed_s = &operand_i[G6LCCfg.FLen-1:32];
  end else begin : gen_box_s_full
    assign boxed_s = 1'b1;
  end
  if (G6LCCfg.FLen > 16) begin : gen_box_h
    assign boxed_h = &operand_i[G6LCCfg.FLen-1:16];
  end else begin : gen_box_h_full
    assign boxed_h = 1'b1;
  end

  assign op_s = boxed_s ? operand_i[31:0] : 32'h7FC00000;
  if (G6LCCfg.FLen >= 64) begin : gen_op_d
    assign op_d = operand_i[63:0];
  end else begin : gen_op_d_none
    assign op_d = 64'h7FF8000000000000;
  end
  assign op_h = boxed_h ? operand_i[15:0] : 16'h7E00;

  g6lc_fp_zfa_round #(
      .EXP_BITS(8),
      .MAN_BITS(23)
  ) i_round_s (
      .op_i    (op_s),
      .rm_i    (rm_i),
      .set_nx_i(op_i == FROUNDNX),
      .res_o   (round_s_res),
      .nv_o    (round_s_nv),
      .nx_o    (round_s_nx)
  );

  if (G6LCCfg.RVD && G6LCCfg.FLen >= 64) begin : gen_round_d
    g6lc_fp_zfa_round #(
        .EXP_BITS(11),
        .MAN_BITS(52)
    ) i_round_d (
        .op_i    (op_d),
        .rm_i    (rm_i),
        .set_nx_i(op_i == FROUNDNX),
        .res_o   (round_d_res),
        .nv_o    (round_d_nv),
        .nx_o    (round_d_nx)
    );
  end else begin : gen_no_round_d
    assign round_d_res = '0;
    assign round_d_nv  = 1'b0;
    assign round_d_nx  = 1'b0;
  end

  if (G6LCCfg.XF16) begin : gen_round_h
    g6lc_fp_zfa_round #(
        .EXP_BITS(5),
        .MAN_BITS(10)
    ) i_round_h (
        .op_i    (op_h),
        .rm_i    (rm_i),
        .set_nx_i(op_i == FROUNDNX),
        .res_o   (round_h_res),
        .nv_o    (round_h_nv),
        .nx_o    (round_h_nx)
    );
  end else begin : gen_no_round_h
    assign round_h_res = '0;
    assign round_h_nv  = 1'b0;
    assign round_h_nx  = 1'b0;
  end

  logic [             4:0] fli_idx;
  logic                    d_nan, d_inf, d_zero, d_sign;
  logic [            10:0] d_exp;
  logic [            51:0] d_man;
  logic [            52:0] d_sig;
  logic [            52:0] d_frac_mask;
  // A10 narrow biased exponent predicates + 5/6-bit shift amounts (replaces
  // two cascaded 32-bit int subtracts and a 53-bit x 32-bit dynamic shift).
  logic                    d_lt_one, d_le_52, d_ge_84;
  logic [             5:0] d_rsh;
  logic [             4:0] d_lsh;
  logic [            31:0] fcvt_rsh_mag, fcvt_lsh_mag, fcvt_mag_s1;
  logic                    fcvt_nv_s1, fcvt_nx_s1, fcvt_zero_s1;

  assign fli_idx  = operand_i[4:0];
  assign d_sign   = op_d[63];
  assign d_exp    = op_d[62:52];
  assign d_man    = op_d[51:0];
  assign d_nan    = (d_exp == 11'h7FF) && (d_man != '0);
  assign d_inf    = (d_exp == 11'h7FF) && (d_man == '0);
  assign d_zero   = (d_exp == '0) && (d_man == '0);
  assign d_sig    = (d_exp == '0) ? {1'b0, d_man} : {1'b1, d_man};
  assign d_lt_one = (d_exp < 11'd1023);
  assign d_le_52  = (d_exp <= 11'd1075);
  assign d_ge_84  = (d_exp >= 11'd1107);
  assign d_rsh    = 6'(11'd1075 - d_exp);
  assign d_lsh    = 5'(d_exp - 11'd1075);

  // Thermometer sticky mask for right-shifted FCVTMOD (zero 53b shift+sub).
  for (genvar k = 0; k < 53; k++) begin : gen_fcvt_mask
    assign d_frac_mask[k] = (6'(k) < d_rsh);
  end
  assign fcvt_rsh_mag = 32'(d_sig >> d_rsh);
  assign fcvt_lsh_mag = d_ge_84 ? 32'b0 : (d_sig[31:0] << d_lsh);
  assign fcvt_zero_s1 = d_nan || d_inf || d_zero || d_lt_one;
  assign fcvt_nv_s1   = d_nan || d_inf;
  assign fcvt_nx_s1   = !d_nan && !d_inf && !d_zero &&
                        (d_lt_one || (d_le_52 && (|(d_sig & d_frac_mask))));
  assign fcvt_mag_s1  = fcvt_zero_s1 ? 32'b0 : (d_le_52 ? fcvt_rsh_mag : fcvt_lsh_mag);

  // Stage-1 comb: FLI + FROUND result assembly and FCVTMOD shift/flags.
  logic [G6LCCfg.FLen-1:0] s1_nonfcvt_res_d;
  logic                    s1_nonfcvt_nv_d, s1_nonfcvt_nx_d;
  always_comb begin
    s1_nonfcvt_res_d = '0;
    s1_nonfcvt_nv_d  = 1'b0;
    s1_nonfcvt_nx_d  = 1'b0;
    unique case (op_i)
      FLI: begin
        unique case (fmt_i)
          2'b01:   s1_nonfcvt_res_d = (G6LCCfg.FLen >= 64) ? G6LCCfg.FLen'(fli_d(fli_idx)) : box32(32'h7FC00000);
          2'b10:   s1_nonfcvt_res_d = box16(fli_h(fli_idx));
          default: s1_nonfcvt_res_d = box32(fli_s(fli_idx));
        endcase
      end
      FROUND, FROUNDNX: begin
        unique case (fmt_i)
          2'b01: begin
            s1_nonfcvt_res_d = (G6LCCfg.FLen >= 64) ? G6LCCfg.FLen'(round_d_res) : box32(32'h7FC00000);
            s1_nonfcvt_nv_d  = round_d_nv;
            s1_nonfcvt_nx_d  = round_d_nx;
          end
          2'b10: begin
            s1_nonfcvt_res_d = box16(round_h_res);
            s1_nonfcvt_nv_d  = round_h_nv;
            s1_nonfcvt_nx_d  = round_h_nx;
          end
          default: begin
            s1_nonfcvt_res_d = box32(round_s_res);
            s1_nonfcvt_nv_d  = round_s_nv;
            s1_nonfcvt_nx_d  = round_s_nx;
          end
        endcase
      end
      default: ;
    endcase
  end

  // A40/A123 internal 2-stage decoupled pipeline behind the existing
  // valid_i/ready_o/valid_o/ready_i handshake (zero caller contract changes):
  // Stage 1 captures shifts/flags/FLI/FROUND; Stage 2 finishes FCVTMOD negate
  // and sign-extension into the output registers.
  logic                    s1_v_q, s1_is_fcvt_q, s1_sign_q;
  logic                    s1_nv_q, s1_nx_q;
  logic [            31:0] s1_mag32_q;
  logic [G6LCCfg.FLen-1:0] s1_res_q;
  logic [    TagWidth-1:0] s1_tag_q;
  logic                    s2_ready, s1_ready;
  logic [            31:0] s2_i32_res;
  logic [G6LCCfg.FLen-1:0] s2_result_d;
  logic [             4:0] s2_status_d;

  assign s2_ready    = !valid_o || ready_i;
  assign s1_ready    = !s1_v_q || s2_ready;
  assign ready_o     = s1_ready;
  assign s2_i32_res  = s1_sign_q ? (32'(0) - s1_mag32_q) : s1_mag32_q;
  assign s2_result_d = s1_is_fcvt_q ? sext32(s2_i32_res) : s1_res_q;
  assign s2_status_d = {s1_nv_q, 3'b000, s1_nx_q};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_v_q       <= 1'b0;
      s1_is_fcvt_q <= 1'b0;
      s1_sign_q    <= 1'b0;
      s1_nv_q      <= 1'b0;
      s1_nx_q      <= 1'b0;
      s1_mag32_q   <= '0;
      s1_res_q     <= '0;
      s1_tag_q     <= '0;
      valid_o      <= 1'b0;
      result_o     <= '0;
      status_o     <= '0;
      tag_o        <= '0;
    end else if (flush_i) begin
      s1_v_q  <= 1'b0;
      valid_o <= 1'b0;
    end else begin
      if (s1_ready) begin
        s1_v_q       <= valid_i;
        s1_is_fcvt_q <= (op_i == FCVTMOD);
        s1_sign_q    <= d_sign;
        s1_nv_q      <= (op_i == FCVTMOD) ? fcvt_nv_s1 : s1_nonfcvt_nv_d;
        s1_nx_q      <= (op_i == FCVTMOD) ? fcvt_nx_s1 : s1_nonfcvt_nx_d;
        s1_mag32_q   <= fcvt_mag_s1;
        s1_res_q     <= s1_nonfcvt_res_d;
        s1_tag_q     <= tag_i;
      end
      if (s2_ready) begin
        valid_o  <= s1_v_q;
        result_o <= s2_result_d;
        status_o <= s2_status_d;
        tag_o    <= s1_tag_q;
      end
    end
  end
endmodule
