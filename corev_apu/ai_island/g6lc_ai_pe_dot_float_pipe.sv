// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Pipelined floating dot product for large lane counts (Lanes=256 target).
//
// Latency = $clog2(P2) + 4 cycles after a valid transaction is accepted.
// One dot product can be issued per cycle once the pipeline is filled, so
// throughput is one dot per cycle at the cost of depth.
//
// Stages:
//   1. decode & multiply per lane
//   2. reduce product exponents to a block exponent and detect NaN/Inf
//   3. align each product mantissa to the block exponent
//   4..(4+LEVELS-1): balanced signed adder tree, one level per cycle
//   final: convert the reduced (sign,mantissa,exponent) to RNE FP32
//
// `start_i` is a one-cycle pulse that tags a transaction. `valid_i[l]` are the
// per-lane valid bits for that transaction. `sum_o` and `flags_o` become valid
// when `valid_o` is asserted, `Latency` cycles after `start_i`.
//
// Not Variane. Not a throughput number.

module g6lc_ai_pe_dot_float_pipe #(
    parameter int unsigned Lanes = 4
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        start_i,
    input  logic [31:0] a_i     [Lanes],
    input  logic [31:0] b_i     [Lanes],
    input  logic               valid_i [Lanes],
    input  logic [2:0]  numfmt_i,
    output logic               valid_o,
    output logic        [31:0] sum_o,
    output logic        [4:0]  flags_o
);

  localparam logic [2:0] AI_FMT_FP8_E4M3 = 3'(config_pkg::AI_FMT_FP8_E4M3);
  localparam logic [2:0] AI_FMT_FP8_E5M2 = 3'(config_pkg::AI_FMT_FP8_E5M2);
  localparam logic [2:0] AI_FMT_FP16     = 3'(config_pkg::AI_FMT_FP16);
  localparam logic [2:0] AI_FMT_BF16     = 3'(config_pkg::AI_FMT_BF16);
  localparam logic [2:0] AI_FMT_FP32     = 3'(config_pkg::AI_FMT_FP32);

  localparam logic signed [15:0] NO_EXP = 16'sd32767;
  localparam int unsigned P2 = 1 << ($clog2(Lanes < 1 ? 1 : Lanes));
  localparam int unsigned LEVELS = $clog2(P2);
  localparam int unsigned MAXW = g6lc_ai_fp_pkg::FP_DOT_MAXW;

  localparam int unsigned LATENCY = LEVELS + 4;

  // fmt_ok is constant per tile
  logic fmt_ok;
  assign fmt_ok = (numfmt_i == AI_FMT_FP8_E4M3) ||
                  (numfmt_i == AI_FMT_FP8_E5M2) ||
                  (numfmt_i == AI_FMT_FP16)     ||
                  (numfmt_i == AI_FMT_BF16)     ||
                  (numfmt_i == AI_FMT_FP32);

  // Helper: a product with is_zero asserted and all other numeric fields zero.
  function automatic g6lc_ai_fp_pkg::fp_dot_product_t prod_zero();
    g6lc_ai_fp_pkg::fp_dot_product_t z;
    z = '0;
    z.is_nan  = 1'b0;
    z.is_inf  = 1'b0;
    z.is_zero = 1'b1;
    return z;
  endfunction

  // ---------------------------------------------------------------------------
  // Stage 1: decode and multiply
  //
  // Per-lane always_ff blocks avoid for-loop procedural-variable ordering
  // problems; each lane captures its own local product and valid flags.
  g6lc_ai_fp_pkg::fp_dot_product_t s1_prod    [P2];
  g6lc_ai_fp_pkg::fp_dot_product_t s1_prod_d  [P2];
  logic                            s1_vld     [P2];
  logic                            s1_vld_d   [P2];
  logic signed [15:0]              s1_exp     [P2];
  logic signed [15:0]              s1_exp_d   [P2];
  logic                            s1_is_nan  [P2];
  logic                            s1_is_nan_d[P2];
  logic                            s1_is_inf  [P2];
  logic                            s1_is_inf_d[P2];
  logic                            s1_sign    [P2];
  logic                            s1_sign_d  [P2];

  // Stage 1 combinational: decode, multiply and produce the next register value.
  always_comb begin
    for (int unsigned g = 0; g < P2; g++) begin
      g6lc_ai_fp_pkg::fp_dot_value_t dec_a;
      g6lc_ai_fp_pkg::fp_dot_value_t dec_b;
      g6lc_ai_fp_pkg::fp_dot_product_t p;
      dec_a = '0;
      dec_b = '0;
      p     = prod_zero();
      if (g < Lanes) begin
        dec_a = g6lc_ai_fp_pkg::fp_dot_decode_value(a_i[g], numfmt_i);
        dec_b = g6lc_ai_fp_pkg::fp_dot_decode_value(b_i[g], numfmt_i);
        if (fmt_ok)
          p = g6lc_ai_fp_pkg::fp_dot_product(dec_a, dec_b);
      end
      if (g < Lanes && fmt_ok) begin
        if (valid_i[g] && !p.is_nan && !p.is_inf && !p.is_zero) begin
          s1_prod_d[g]   = '{sign: p.sign, mant: p.mant, exp: p.exp,
                             is_nan: p.is_nan, is_inf: p.is_inf, is_zero: p.is_zero};
          s1_vld_d[g]    = 1'b1;
          s1_exp_d[g]    = p.exp;
        end else begin
          s1_prod_d[g]   = prod_zero();
          s1_vld_d[g]    = 1'b0;
          s1_exp_d[g]    = NO_EXP;
        end
        s1_is_nan_d[g] = valid_i[g] && p.is_nan;
        s1_is_inf_d[g] = valid_i[g] && p.is_inf;
        s1_sign_d[g]   = p.sign;
      end else begin
        s1_prod_d[g]   = prod_zero();
        s1_vld_d[g]    = 1'b0;
        s1_exp_d[g]    = NO_EXP;
        s1_is_nan_d[g] = 1'b0;
        s1_is_inf_d[g] = 1'b0;
        s1_sign_d[g]   = 1'b0;
      end
    end
  end

  // Stage 1 register: only load when start_i is asserted.
  // Gating on start_i is what makes back-to-back issue safe: a cycle with no
  // new transaction must hold S1 so the downstream stages keep a stable product.
  generate
    for (genvar g = 0; g < P2; g++) begin : gen_s1_reg
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          s1_prod[g]    <= prod_zero();
          s1_vld[g]     <= 1'b0;
          s1_exp[g]     <= NO_EXP;
          s1_is_nan[g]  <= 1'b0;
          s1_is_inf[g]  <= 1'b0;
          s1_sign[g]    <= 1'b0;
        end else if (start_i) begin
          s1_prod[g]    <= s1_prod_d[g];
          s1_vld[g]     <= s1_vld_d[g];
          s1_exp[g]     <= s1_exp_d[g];
          s1_is_nan[g]  <= s1_is_nan_d[g];
          s1_is_inf[g]  <= s1_is_inf_d[g];
          s1_sign[g]    <= s1_sign_d[g];
        end
      end
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Stage 2: block exponent + NaN/Inf detection + product hold
  //
  // s2_*_q registers are loaded with the S1 product and the S2 reduction
  // result in the same cycle.  They decouple S2 from S3 so that a new
  // start_i on the next cycle cannot overwrite the product before S3 has
  // aligned it, enabling true one-dot-per-cycle back-to-back issue.
  g6lc_ai_fp_pkg::fp_dot_product_t s2_prod_q       [P2];
  logic signed [15:0]              s2_block_exp_q;
  logic signed [15:0]              s2_block_exp_d;
  logic                            s2_any_nan_q;
  logic                            s2_any_nan_d;
  logic                            s2_any_inf_q;
  logic                            s2_any_inf_d;
  logic                            s2_any_finite_q;
  logic                            s2_any_finite_d;
  logic                            s2_same_inf_sign_q;
  logic                            s2_same_inf_sign_d;
  logic                            s2_inf_sign_q;
  logic                            s2_inf_sign_d;

  // Stage 2 combinational: block exponent + NaN/Inf/Inf-sign flags.
  always_comb begin
    logic signed [15:0] exp_min [0:LEVELS][0:P2-1];
    logic any_nan, any_inf, any_finite;
    logic has_pos_inf, has_neg_inf;
    // Block exponent = min over valid exponents
    for (int unsigned l = 0; l < P2; l++)
      exp_min[0][l] = s1_vld[l] ? s1_exp[l] : NO_EXP;
    for (int unsigned level = 1; level <= LEVELS; level++) begin
      for (int unsigned i = 0; i < (P2 >> level); i++) begin
        exp_min[level][i] = (exp_min[level-1][2*i] < exp_min[level-1][2*i+1]) ?
                            exp_min[level-1][2*i] : exp_min[level-1][2*i+1];
      end
    end

    any_nan = 1'b0;
    any_inf = 1'b0;
    any_finite = 1'b0;
    has_pos_inf = 1'b0;
    has_neg_inf = 1'b0;
    for (int unsigned l = 0; l < P2; l++) begin
      any_nan    = any_nan    | s1_is_nan[l];
      any_inf    = any_inf    | s1_is_inf[l];
      any_finite = any_finite | s1_vld[l];
      if (s1_is_inf[l]) begin
        if (s1_sign[l]) has_neg_inf = 1'b1;
        else            has_pos_inf = 1'b1;
      end
    end
    s2_block_exp_d    = exp_min[LEVELS][0];
    s2_any_nan_d      = any_nan;
    s2_any_inf_d      = any_inf;
    s2_any_finite_d   = any_finite;
    s2_same_inf_sign_d = !(has_neg_inf && has_pos_inf);
    s2_inf_sign_d     = has_neg_inf;
  end

  // Stage 2 register: product hold is per-lane above; this captures metadata.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s2_block_exp_q    <= NO_EXP;
      s2_any_nan_q      <= 1'b0;
      s2_any_inf_q      <= 1'b0;
      s2_any_finite_q   <= 1'b0;
      s2_same_inf_sign_q <= 1'b0;
      s2_inf_sign_q     <= 1'b0;
    end else begin
      s2_block_exp_q    <= s2_block_exp_d;
      s2_any_nan_q      <= s2_any_nan_d;
      s2_any_inf_q      <= s2_any_inf_d;
      s2_any_finite_q   <= s2_any_finite_d;
      s2_same_inf_sign_q <= s2_same_inf_sign_d;
      s2_inf_sign_q     <= s2_inf_sign_d;
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 3: align products to the block exponent
  //
  logic signed [MAXW-1:0] s3_aligned   [P2];
  logic signed [MAXW-1:0] s3_aligned_d [P2];
  logic signed [15:0]     s3_block_exp_q;
  logic                   s3_any_nan_q;
  logic                   s3_any_inf_q;
  logic                   s3_any_finite_q;
  logic                   s3_same_inf_sign_q;
  logic                   s3_inf_sign_q;

  generate
    for (genvar g = 0; g < P2; g++) begin : gen_s2_prod
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          s2_prod_q[g] <= prod_zero();
        end else begin
          s2_prod_q[g] <= s1_prod[g];
        end
      end
    end
  endgenerate

  // Stage 3 combinational: align each product to the block exponent.
  always_comb begin
    for (int unsigned g = 0; g < P2; g++) begin
      s3_aligned_d[g] = g6lc_ai_fp_pkg::fp_dot_product_aligned(s2_prod_q[g], s2_block_exp_q);
    end
  end

  // Stage 3 register: capture aligned products and pipe metadata.
  generate
    for (genvar g = 0; g < P2; g++) begin : gen_s3
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          s3_aligned[g] <= MAXW'(0);
        end else begin
          s3_aligned[g] <= s3_aligned_d[g];
        end
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        s3_block_exp_q    <= NO_EXP;
        s3_any_nan_q      <= 1'b0;
        s3_any_inf_q      <= 1'b0;
        s3_any_finite_q   <= 1'b0;
        s3_same_inf_sign_q <= 1'b0;
        s3_inf_sign_q     <= 1'b0;
      end else begin
        s3_block_exp_q    <= s2_block_exp_q;
        s3_any_nan_q      <= s2_any_nan_q;
        s3_any_inf_q      <= s2_any_inf_q;
        s3_any_finite_q   <= s2_any_finite_q;
        s3_same_inf_sign_q <= s2_same_inf_sign_q;
        s3_inf_sign_q     <= s2_inf_sign_q;
      end
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Stages 4..(4+LEVELS-1): balanced adder tree, one level per cycle.
  //
  logic signed [MAXW-1:0] red     [0:LEVELS][0:P2-1];
  logic                   red_nan [0:LEVELS];
  logic                   red_inf [0:LEVELS];
  logic                   red_fin [0:LEVELS];
  logic                   red_same [0:LEVELS];
  logic                   red_sign [0:LEVELS];

  // Pipe block_exp along with the reduction so the final conversion sees the
  // exponent that matches the reduced mantissa.
  logic signed [15:0] s2_block_exp_piped [0:LEVELS];

  generate
    for (genvar g = 0; g < P2; g++) begin : gen_red0
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          red[0][g] <= MAXW'(0);
        end else begin
          red[0][g] <= s3_aligned[g];
        end
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        red_nan[0]  <= 1'b0;
        red_inf[0]  <= 1'b0;
        red_fin[0]  <= 1'b0;
        red_same[0] <= 1'b0;
        red_sign[0] <= 1'b0;
        s2_block_exp_piped[0] <= NO_EXP;
      end else begin
        red_nan[0]  <= s3_any_nan_q;
        red_inf[0]  <= s3_any_inf_q;
        red_fin[0]  <= s3_any_finite_q;
        red_same[0] <= s3_same_inf_sign_q;
        red_sign[0] <= s3_inf_sign_q;
        s2_block_exp_piped[0] <= s3_block_exp_q;
      end
    end

    for (genvar level = 0; level < LEVELS; level++) begin : gen_red
      localparam int unsigned CNT = P2 >> (level + 1);
      for (genvar i = 0; i < P2; i++) begin : gen_red_i
        always_ff @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) begin
            red[level+1][i] <= MAXW'(0);
          end else if (i < CNT) begin
            red[level+1][i] <= red[level][2*i] + red[level][2*i+1];
          end else begin
            red[level+1][i] <= MAXW'(0);
          end
        end
      end

      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          red_nan[level+1]  <= 1'b0;
          red_inf[level+1]  <= 1'b0;
          red_fin[level+1]  <= 1'b0;
          red_same[level+1] <= 1'b0;
          red_sign[level+1] <= 1'b0;
          s2_block_exp_piped[level+1] <= NO_EXP;
        end else begin
          red_nan[level+1]  <= red_nan[level];
          red_inf[level+1]  <= red_inf[level];
          red_fin[level+1]  <= red_fin[level];
          red_same[level+1] <= red_same[level];
          red_sign[level+1] <= red_sign[level];
          s2_block_exp_piped[level+1] <= s2_block_exp_piped[level];
        end
      end
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Final output conversion
  //
  logic signed [MAXW-1:0] final_bfp_sum;
  logic signed [15:0]     final_block_exp;

  assign final_bfp_sum     = red[LEVELS][0];
  assign final_block_exp   = (red_fin[LEVELS] && final_bfp_sum != MAXW'(0)) ? s2_block_exp_piped[LEVELS] : 16'sd0;

  logic [36:0] final_result;

  assign final_result =
      (red_nan[LEVELS] || (red_inf[LEVELS] && !red_same[LEVELS])) ? {5'b10000, 32'h7fc00000} :
      (red_inf[LEVELS])                                           ? {5'b00100, {red_sign[LEVELS], 8'hff, 23'd0}} :
      (!red_fin[LEVELS])                                          ? {5'd0,     32'd0} :
                                                                   g6lc_ai_fp_pkg::bfp_mant_exp_to_fp32(
                                                                     final_bfp_sum[MAXW-1], final_bfp_sum,
                                                                     final_block_exp);

  // valid_o tracks the start pulse through the pipeline. LATENCY = LEVELS + 4.
  // A shift register rather than a counter: with one issue per cycle there can
  // be LATENCY transactions in flight, and each needs its own valid slot.
  logic [LATENCY-1:0] vld;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      vld <= '0;
    end else begin
      vld <= {vld[LATENCY-2:0], start_i};
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      {flags_o, sum_o} <= {5'd0, 32'd0};
      valid_o          <= 1'b0;
    end else begin
      {flags_o, sum_o} <= final_result;
      valid_o          <= vld[LATENCY-1];
    end
  end

endmodule
