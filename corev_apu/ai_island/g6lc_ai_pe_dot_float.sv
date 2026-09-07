// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai floating dot product (F2–F5).
//
// Computes sum_{lane} (valid[lane] ? widen(a[lane]) * widen(b[lane]) : 0)
// for FP8 E4M3/E5M2, FP16, BF16 and FP32. Uses a block-floating-point reduction:
//   1. decode each element into (sign, mantissa, exponent);
//   2. multiply to (sign, product_mantissa, product_exponent);
//   3. pick the most-negative product exponent as the block exponent;
//   4. shift each product mantissa to that block and sum in a wide integer tree;
//   5. convert the integer sum and block exponent to IEEE 754 binary32.
//
// The output is rounded to nearest-even once, at the end of the dot. This is
// not identical to sequential f32 rounding for arbitrary operands, but it is
// the natural first parallel implementation. It is kept behind the live
// INT8/INT4 mask and gated by g6lc_ai_island_top's grant/impl checks.
//
// TODO (Lanes=256): the current implementation is a single-cycle fully
// combinational path. For Lanes=256 it must be pipelined: decode/multiply,
// block-exponent, align, multi-stage reduction tree, then normalise/round. The
// GEMM sequencer's one-cycle `sum_q` assumption will need a `valid` handshake
// once the dot-product latency exceeds one cycle. See
// architecture/ai-matrix/numeric-formats-datapath.md for the proposed stages.
//
// Not Variane. Not a throughput number.

module g6lc_ai_pe_dot_float #(
    parameter int unsigned Lanes = 4
) (
    input  logic        [31:0] a_i     [Lanes],
    input  logic        [31:0] b_i     [Lanes],
    input  logic               valid_i [Lanes],
    input  logic        [2:0]  numfmt_i,  // AI_FMT_FP8_E4M3/FP8_E5M2/FP16/BF16/FP32
    output logic        [31:0] sum_o,
    output logic        [4:0]  flags_o
);

  localparam logic [2:0] AI_FMT_FP8_E4M3 = 3'(config_pkg::AI_FMT_FP8_E4M3);
  localparam logic [2:0] AI_FMT_FP8_E5M2 = 3'(config_pkg::AI_FMT_FP8_E5M2);
  localparam logic [2:0] AI_FMT_FP16     = 3'(config_pkg::AI_FMT_FP16);
  localparam logic [2:0] AI_FMT_BF16     = 3'(config_pkg::AI_FMT_BF16);
  localparam logic [2:0] AI_FMT_FP32     = 3'(config_pkg::AI_FMT_FP32);

  // sentinel for "no finite product yet" (larger than any product exponent)
  localparam logic signed [15:0] NO_EXP = 16'sd32767;
  // round the lane count up to the next power of two for a clean balanced tree
  localparam int unsigned P2 = 1 << ($clog2(Lanes < 1 ? 1 : Lanes));
  localparam int unsigned LEVELS = $clog2(P2);
  localparam int unsigned MAXW = g6lc_ai_fp_pkg::FP_DOT_MAXW;

  // Per-lane decoded products and reduced control signals.
  g6lc_ai_fp_pkg::fp_dot_product_t prod [P2];
  logic        is_nan_arr  [P2];
  logic        is_inf_arr  [P2];
  logic        is_zero_arr [P2];
  logic        valid_arr   [P2];
  logic        sign_arr    [P2];
  logic signed [15:0] exp_arr [P2];

  logic        any_nan;
  logic        any_inf;
  logic        any_finite;
  logic        same_inf_sign;
  logic        inf_sign;
  logic signed [15:0] block_exp;

  logic signed [MAXW-1:0] bfp_sum;

  // 1. decode and multiply per lane; pad extra P2-Lanes slots with zero
  always_comb begin
    g6lc_ai_fp_pkg::fp_dot_product_t prod_zero;
    prod_zero = '0;
    prod_zero.is_nan  = 1'b0;
    prod_zero.is_inf  = 1'b0;
    prod_zero.is_zero = 1'b1;
    for (int unsigned l = 0; l < P2; l++) begin
      g6lc_ai_fp_pkg::fp_dot_value_t dec_a, dec_b;
      g6lc_ai_fp_pkg::fp_dot_product_t p;
      logic fmt_ok;
      dec_a = '0;
      dec_b = '0;
      p     = prod_zero;
      fmt_ok = (numfmt_i == AI_FMT_FP8_E4M3) ||
               (numfmt_i == AI_FMT_FP8_E5M2) ||
               (numfmt_i == AI_FMT_FP16)     ||
               (numfmt_i == AI_FMT_BF16)     ||
               (numfmt_i == AI_FMT_FP32);
      if (l < Lanes && fmt_ok) begin
        dec_a = g6lc_ai_fp_pkg::fp_dot_decode_value(a_i[l], numfmt_i);
        dec_b = g6lc_ai_fp_pkg::fp_dot_decode_value(b_i[l], numfmt_i);
        p     = g6lc_ai_fp_pkg::fp_dot_product(dec_a, dec_b);
      end
      prod[l] = p;

      is_nan_arr[l]  = (l < Lanes) && valid_i[l] && p.is_nan;
      is_inf_arr[l]  = (l < Lanes) && valid_i[l] && p.is_inf;
      is_zero_arr[l] = (l < Lanes) && valid_i[l] && p.is_zero;
      valid_arr[l]   = (l < Lanes) && valid_i[l] && !p.is_nan && !p.is_inf && !p.is_zero;
      sign_arr[l]    = p.sign;
      exp_arr[l]     = p.exp;
    end
  end

  // Reductions over the per-lane vectors.
  always_comb begin
    any_nan    = 1'b0;
    any_inf    = 1'b0;
    any_finite = 1'b0;
    for (int unsigned l = 0; l < P2; l++) begin
      any_nan    = any_nan    | is_nan_arr[l];
      any_inf    = any_inf    | is_inf_arr[l];
      any_finite = any_finite | valid_arr[l];
    end
  end

  logic has_pos_inf, has_neg_inf;
  always_comb begin
    has_pos_inf = 1'b0;
    has_neg_inf = 1'b0;
    for (int unsigned l = 0; l < P2; l++) begin
      if (is_inf_arr[l]) begin
        if (sign_arr[l]) has_neg_inf = 1'b1;
        else             has_pos_inf = 1'b1;
      end
    end
  end

  assign same_inf_sign = !(has_neg_inf && has_pos_inf);
  assign inf_sign      = has_neg_inf;  // irrelevant when both signs present (NaN)

  // Block exponent = minimum exponent over all valid, finite, non-zero lanes.
  logic signed [15:0] exp_min [0:LEVELS][0:P2-1];
  always_comb begin
    for (int unsigned l = 0; l < P2; l++) begin
      exp_min[0][l] = valid_arr[l] ? exp_arr[l] : NO_EXP;
    end
    for (int unsigned level = 1; level <= LEVELS; level++) begin
      for (int unsigned i = 0; i < (P2 >> level); i++) begin
        exp_min[level][i] = (exp_min[level-1][2*i] < exp_min[level-1][2*i+1]) ?
                            exp_min[level-1][2*i] : exp_min[level-1][2*i+1];
      end
    end
  end
  assign block_exp = exp_min[LEVELS][0];

  // Align each product and reduce using an in-place tree. Alignment is a pure
  // function so this block contains only the self-referential reduction.
  always_comb begin
    logic signed [MAXW-1:0] node [P2];
    int unsigned cnt;
    bfp_sum = MAXW'(0);
    for (int unsigned l = 0; l < P2; l++) begin
      node[l] = valid_arr[l] ? g6lc_ai_fp_pkg::fp_dot_product_aligned(prod[l], block_exp) : MAXW'(0);
    end

    cnt = P2;
    while (cnt > 1) begin
      for (int unsigned i = 0; i < cnt / 2; i++) begin
        node[i] = node[2*i] + node[2*i+1];
      end
      // P2 is a power of two; no odd tail
      cnt = cnt / 2;
    end
    bfp_sum = node[0];
  end

  // Final output: continuous assignment to avoid always_comb priority-mux loops.
  assign {flags_o, sum_o} =
      (any_nan || (any_inf && !same_inf_sign)) ? {5'b10000, 32'h7fc00000} :  // canonical quiet NaN (NV)
      (any_inf)                                ? {5'b00100, {inf_sign, 8'hff, 23'd0}} :  // OF
      (!any_finite)                            ? {5'd0,     32'd0} :
                                                  g6lc_ai_fp_pkg::bfp_mant_exp_to_fp32(
                                                    bfp_sum[MAXW-1], bfp_sum, block_exp);

  // pragma translate_off
  initial begin
    assert (Lanes >= 1) else $error("g6lc_ai_pe_dot_float: Lanes must be >= 1");
  end

  // MAXW sufficiency is an INVARIANT, not a comment.  `fp_dot_product_aligned`
  // silently returns zero when a product's alignment shift reaches MAXW, which
  // would drop the LARGEST term in the window - a wrong answer, not a rounding.
  // The width is provably sufficient today: with the integer-significand
  // convention the product exponent spans [-298, 208] for FP32 and [-266, 240]
  // for BF16, so the worst-case shift is 506, plus a 48-bit product and 8 bits
  // of headroom for 256 lanes gives 562 of the 640 available.  Every narrower
  // format is far smaller (FP16 80, FP8 <= 64).  So the zeroing arm is dead
  // code - but nothing checked that, and a future MAXW reduction or a wider
  // exponent format would reach it without a single failing test.  This checks
  // it every cycle in simulation instead.
  always_comb begin
    for (int unsigned l = 0; l < Lanes; l++) begin
      if (valid_arr[l] && !prod[l].is_nan && !prod[l].is_inf && !prod[l].is_zero) begin
        assert (int'(prod[l].exp) - int'(block_exp) >= 0 &&
                int'(prod[l].exp) - int'(block_exp) < MAXW)
          else $error("g6lc_ai_pe_dot_float: lane %0d alignment shift %0d outside [0,%0d) - product would be DROPPED",
                      l, int'(prod[l].exp) - int'(block_exp), MAXW);
      end
    end
  end
  // pragma translate_on

endmodule
