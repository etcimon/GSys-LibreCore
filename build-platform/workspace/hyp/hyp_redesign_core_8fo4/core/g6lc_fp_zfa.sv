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
  localparam int unsigned WIDTH = EXP_BITS + MAN_BITS + 1;
  localparam int unsigned BIAS = (1 << (EXP_BITS - 1)) - 1;
  localparam logic [EXP_BITS-1:0] EXP_INF = {EXP_BITS{1'b1}};
  localparam logic [EXP_BITS-1:0] EXP_ONE = EXP_BITS'(BIAS);
  localparam logic [EXP_BITS-1:0] EXP_HALF = EXP_BITS'(BIAS - 1);

  logic                    sign;
  logic [EXP_BITS-1:0]     exp_f;
  logic [MAN_BITS-1:0]     man;
  logic                    is_inf, is_nan, is_snan, is_zero;
  int                      uexp;
  logic                    is_half, mag_gt_half, round_up;
  logic [MAN_BITS:0]       sig;
  logic [MAN_BITS+1:0]     acc;
  logic [MAN_BITS+1:0]     frac_mask;
  int unsigned             frac_len;
  logic                    guard, sticky, lsb;

  assign sign    = op_i[WIDTH-1];
  assign exp_f   = op_i[MAN_BITS+EXP_BITS-1:MAN_BITS];
  assign man     = op_i[MAN_BITS-1:0];
  assign is_inf  = (exp_f == EXP_INF) && (man == '0);
  assign is_nan  = (exp_f == EXP_INF) && (man != '0);
  assign is_snan = is_nan && !man[MAN_BITS-1];
  assign is_zero = (exp_f == '0) && (man == '0);
  // Subnormals have |x| < 1; normals use unbiased exp.
  assign uexp    = (exp_f == '0) ? -1 : (int'(exp_f) - int'(BIAS));

  always_comb begin
    res_o       = op_i;
    nv_o        = 1'b0;
    nx_o        = 1'b0;
    sig         = {1'b1, man};
    acc         = '0;
    frac_mask   = '0;
    frac_len    = 0;
    guard       = 1'b0;
    sticky      = 1'b0;
    lsb         = 1'b0;
    is_half     = 1'b0;
    mag_gt_half = 1'b0;
    round_up    = 1'b0;

    if (is_nan) begin
      res_o = {1'b0, EXP_INF, 1'b1, {MAN_BITS - 1{1'b0}}};
      nv_o  = is_snan;
    end else if (is_inf || is_zero) begin
      res_o = op_i;
    end else if (uexp < 0) begin
      is_half     = (exp_f == EXP_HALF) && (man == '0);
      mag_gt_half = (exp_f == EXP_HALF) && (man != '0);
      unique case (rm_i)
        3'b000:  round_up = mag_gt_half;
        3'b001:  round_up = 1'b0;
        3'b010:  round_up = sign;
        3'b011:  round_up = ~sign;
        3'b100:  round_up = is_half | mag_gt_half;
        default: round_up = mag_gt_half;
      endcase
      if (round_up) res_o = {sign, EXP_ONE, {MAN_BITS{1'b0}}};
      else res_o = {sign, {EXP_BITS{1'b0}}, {MAN_BITS{1'b0}}};
      nx_o = set_nx_i;
    end else if (uexp >= int'(MAN_BITS)) begin
      res_o = op_i;
    end else begin
      frac_len  = MAN_BITS - unsigned'(uexp);
      guard     = sig[frac_len-1];
      lsb       = sig[frac_len];
      frac_mask = ((MAN_BITS + 2)'(1) << (frac_len - 1)) - 1;
      sticky    = |(sig & frac_mask[MAN_BITS:0]);
      unique case (rm_i)
        3'b000:  round_up = guard && (sticky || lsb);
        3'b001:  round_up = 1'b0;
        3'b010:  round_up = sign && (guard || sticky);
        3'b011:  round_up = ~sign && (guard || sticky);
        3'b100:  round_up = guard;
        default: round_up = guard && (sticky || lsb);
      endcase
      acc = {1'b0, sig};
      acc = acc & ~(((MAN_BITS + 2)'(1) << frac_len) - 1);
      if (round_up) acc = acc + ((MAN_BITS + 2)'(1) << frac_len);
      if (acc[MAN_BITS+1]) begin
        if (exp_f == (EXP_INF - 1'b1)) res_o = {sign, EXP_INF, {MAN_BITS{1'b0}}};
        else res_o = {sign, exp_f + 1'b1, {MAN_BITS{1'b0}}};
      end else begin
        res_o = {sign, exp_f, acc[MAN_BITS-1:0]};
      end
      nx_o = set_nx_i && (guard || sticky);
    end
  end
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

  logic [G6LCCfg.FLen-1:0] result_d;
  logic [             4:0] status_d;
  logic                    nv_d, nx_d;
  logic [             4:0] fli_idx;
  logic [            31:0] mag32, i32_res;
  logic                    d_nan, d_inf, d_zero, d_sign;
  logic [            10:0] d_exp;
  logic [            51:0] d_man;
  logic [            52:0] d_sig;
  logic [            52:0] d_frac_mask;
  int                      d_uexp;
  int unsigned             d_shift;

  assign fli_idx = operand_i[4:0];
  assign d_sign  = op_d[63];
  assign d_exp   = op_d[62:52];
  assign d_man   = op_d[51:0];
  assign d_nan   = (d_exp == 11'h7FF) && (d_man != '0);
  assign d_inf   = (d_exp == 11'h7FF) && (d_man == '0);
  assign d_zero  = (d_exp == '0) && (d_man == '0);
  assign d_sig   = (d_exp == '0) ? {1'b0, d_man} : {1'b1, d_man};
  assign d_uexp  = (d_exp == '0) ? -1 : (int'(d_exp) - 1023);

  always_comb begin
    result_d    = '0;
    nv_d        = 1'b0;
    nx_d        = 1'b0;
    mag32       = '0;
    i32_res     = '0;
    d_shift     = 0;
    d_frac_mask = '0;

    unique case (op_i)
      FLI: begin
        unique case (fmt_i)
          2'b01:   result_d = (G6LCCfg.FLen >= 64) ? G6LCCfg.FLen'(fli_d(fli_idx)) : box32(32'h7FC00000);
          2'b10:   result_d = box16(fli_h(fli_idx));
          default: result_d = box32(fli_s(fli_idx));
        endcase
      end
      FROUND, FROUNDNX: begin
        unique case (fmt_i)
          2'b01: begin
            result_d = (G6LCCfg.FLen >= 64) ? G6LCCfg.FLen'(round_d_res) : box32(32'h7FC00000);
            nv_d     = round_d_nv;
            nx_d     = round_d_nx;
          end
          2'b10: begin
            result_d = box16(round_h_res);
            nv_d     = round_h_nv;
            nx_d     = round_h_nx;
          end
          default: begin
            result_d = box32(round_s_res);
            nv_d     = round_s_nv;
            nx_d     = round_s_nx;
          end
        endcase
      end
      FCVTMOD: begin
        if (d_nan || d_inf) begin
          result_d = '0;
          nv_d     = 1'b1;
        end else if (d_zero) begin
          result_d = '0;
        end else if (d_uexp < 0) begin
          result_d = '0;
          nx_d     = 1'b1;
        end else if (d_uexp <= 52) begin
          d_shift     = 52 - unsigned'(d_uexp);
          mag32       = 32'(d_sig >> d_shift);
          d_frac_mask = (d_shift == 0) ? '0 : ((53'(1) << d_shift) - 1);
          nx_d        = |(d_sig & d_frac_mask);
          i32_res     = d_sign ? (32'(0) - mag32) : mag32;
          result_d    = sext32(i32_res);
        end else begin
          d_shift  = unsigned'(d_uexp) - 52;
          nx_d     = 1'b0;
          mag32    = (d_shift >= 32) ? 32'b0 : 32'(d_sig << d_shift);
          i32_res  = d_sign ? (32'(0) - mag32) : mag32;
          result_d = sext32(i32_res);
        end
      end
      default: result_d = '0;
    endcase
    status_d = {nv_d, 3'b000, nx_d};
  end

  assign ready_o = !valid_o || ready_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_o  <= 1'b0;
      result_o <= '0;
      status_o <= '0;
      tag_o    <= '0;
    end else if (flush_i) begin
      valid_o <= 1'b0;
    end else if (ready_o) begin
      valid_o  <= valid_i;
      result_o <= result_d;
      status_o <= status_d;
      tag_o    <= tag_i;
    end
  end
endmodule
