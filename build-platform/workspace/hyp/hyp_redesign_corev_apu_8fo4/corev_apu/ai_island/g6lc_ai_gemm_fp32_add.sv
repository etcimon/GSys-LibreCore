// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Exact specialization of g6lc_ai_fp_pkg::fp32_add for two FP32 operands.
// Each signed significand fits 25 bits; their aligned sum fits 26. The
// 640-bit dot-product representation is unnecessary on this recurrence.
// Preserve the reference's signed alignment/truncation and zero exponent
// convention, including its non-IEEE corner behavior. This is not a new FPU.
//
// r21: sign-magnitude arithmetic. The reference's arithmetic right shift of
// a negative significand floors, which equals -(magnitude >> d) - sticky.
// Three magnitude sums run in parallel with their corrections folded into
// carry-ins, so no operand negation, sum negation or post-sum increment
// remains in series. Rounding for the 25-bit result is computed from the
// operand halves beside the main sum.
//
// r22: the computation is split at the aligned-operand boundary into two
// combinational leaves. `g6lc_ai_gemm_fp32_add` composes them without a
// register (the reference miter); `g6lc_ai_gemm_fp32_add_p2` registers the
// aligned operands, so an accumulator fed by interleaved independent
// elements adds one partial every other cycle per element.

// Stage 1: classify, compare exponents, align the smaller magnitude.
module g6lc_ai_gemm_fp32_align (
  input  logic [31:0] a_i,
  input  logic [31:0] b_i,
  output g6lc_ai_fp_pkg::fp32_align_t align_o
);
  logic az, bz, an, bn, ai, bi, sa, sb, swap;
  logic [7:0] ea, eb, delta_ab, delta_ba, delta;
  logic [23:0] mag_a, mag_b, y_full;
  logic [24:0] below_or;
  logic sticky;

  assign sa = a_i[31];
  assign sb = b_i[31];
  assign az = a_i[30:0] == '0;
  assign bz = b_i[30:0] == '0;
  assign an = (&a_i[30:23]) && (|a_i[22:0]);
  assign bn = (&b_i[30:23]) && (|b_i[22:0]);
  assign ai = (&a_i[30:23]) && !(|a_i[22:0]);
  assign bi = (&b_i[30:23]) && !(|b_i[22:0]);
  // E = integer-significand exponent + 150. The reference initializes
  // zero's exponent to 0, hence E=150 rather than the subnormal E=1.
  assign ea = az ? 8'd150 : (a_i[30:23] == 0 ? 8'd1 : a_i[30:23]);
  assign eb = bz ? 8'd150 : (b_i[30:23] == 0 ? 8'd1 : b_i[30:23]);
  assign mag_a = {(|a_i[30:23]), a_i[22:0]};
  assign mag_b = {(|b_i[30:23]), b_i[22:0]};
  // Differences run beside the exponent compare, not after its max mux.
  assign delta_ab = ea - eb;
  assign delta_ba = eb - ea;
  assign swap = ea < eb;
  assign delta = swap ? delta_ba : delta_ab;
  assign y_full = swap ? mag_a : mag_b;
  // Shifts of 24 or more clear every bit; the sticky then covers the whole
  // operand, reproducing the reference's -1 for a shifted-out negative value.
  // Sticky = any bit below the shift amount: constant-width prefix ORs run
  // beside the shifter and the amount only selects one of them.
  for (genvar k = 0; k <= 24; k++) begin : gen_below_or
    if (k == 0) begin : gen_none
      assign below_or[k] = 1'b0;
    end else begin : gen_prefix
      assign below_or[k] = |y_full[k-1:0];
    end
  end
  assign sticky = delta >= 8'd24 ? below_or[24] : below_or[delta[4:0]];

  assign align_o.nan = an || bn || (ai && bi && sa != sb);
  assign align_o.inf_a = ai;
  assign align_o.inf_b = bi;
  assign align_o.sign_a = sa;
  assign align_o.sign_b = sb;
  assign align_o.zero_both = az && bz;
  assign align_o.ec = swap ? eb : ea;
  // X keeps the larger (or equal) exponent and is never shifted.
  assign align_o.sx = swap ? sb : sa;
  assign align_o.sy = swap ? sa : sb;
  assign align_o.x_mag = swap ? mag_b : mag_a;
  assign align_o.y_shift = delta >= 8'd24 ? 24'd0 : (y_full >> delta);
  assign align_o.corr = align_o.sy && sticky;
endmodule

// Stage 2: parallel magnitude sums, select, normalize, pack.
module g6lc_ai_gemm_fp32_norm (
  input  g6lc_ai_fp_pkg::fp32_align_t align_i,
  output logic [36:0] result_o
);
  logic [23:0] x_mag, y_shift;
  logic sx, sy, corr, same_sign, nonneg, sign;
  logic [7:0] ec;
  logic [24:0] sum_same, diff_xy, diff_yx, magnitude, rounded;
  logic [25:0] diff_xy_wide;
  logic [24:0] diff_yx_xor, diff_yx_carry;
  logic [1:0] low_sum, round_inc;
  logic [24:0] leading;
  logic [22:0] subnormal_fraction;
  logic [24:0] overflow_hit, subnormal_hit, normal_hit;
  logic [22:0] normal_fraction [25];
  logic [7:0] normal_exponent [25];
  logic [36:0] finite_result;

  assign x_mag = align_i.x_mag;
  assign y_shift = align_i.y_shift;
  assign sx = align_i.sx;
  assign sy = align_i.sy;
  assign corr = align_i.corr;
  assign ec = align_i.ec;
  assign same_sign = sx == sy;
  // Same sign: |X| + |Y| + corr. Opposite sign: X - Y - corr, or its negation
  // when the first borrows; the 1 + corr carry is carried as a two-bit term.
  assign sum_same = {1'b0, x_mag} + {1'b0, y_shift} + 25'(corr);
  assign diff_xy_wide = {2'b00, x_mag} + {1'b0, ~{1'b0, y_shift}} + 26'(!corr);
  assign {nonneg, diff_xy} = diff_xy_wide;
  assign diff_yx_xor = {1'b0, y_shift} ^ ~{1'b0, x_mag} ^ {23'd0, corr, !corr};
  assign diff_yx_carry = ((({1'b0, y_shift} & ~{1'b0, x_mag}) |
                           ({1'b0, y_shift} & {23'd0, corr, !corr}) |
                           (~{1'b0, x_mag} & {23'd0, corr, !corr})) << 1);
  assign diff_yx = diff_yx_xor + diff_yx_carry;
  assign magnitude = same_sign ? sum_same : (nonneg ? diff_xy : diff_yx);
  assign sign = same_sign ? sx : (nonneg ? sx : !sx);
  // Rounding for the overflowing same-sign sum, from the operand halves:
  // sum = 2*(Xh + Yh) + low_sum, rounded = (sum >> 1) + (sum[0] & sum[1]),
  // and sum[1] is the parity of Xh + Yh + low_sum[1].
  assign low_sum = 2'(x_mag[0]) + 2'(y_shift[0]) + 2'(corr);
  assign round_inc = 2'(low_sum[1]) +
                     2'(low_sum[0] && (x_mag[1] ^ y_shift[1] ^ low_sum[1]));
  assign rounded = {2'b00, x_mag[23:1]} + {2'b00, y_shift[23:1]} + 25'(round_inc);
  for (genvar b = 0; b < 25; b++) begin : gen_leading
    logic [7:0] exponent_field;
    logic [22:0] fraction;
    logic overflow_sel, subnormal_sel, normal_sel;
    if (b == 24) begin : gen_top
      assign leading[b] = magnitude[b];
    end else begin : gen_suffix
      assign leading[b] = magnitude[b] && !(|magnitude[24:b+1]);
    end
    assign exponent_field = ec + 8'(b) - 8'd23;
    if (b == 24) begin : gen_round
      assign fraction = rounded[22:0];
    end else begin : gen_exact
      assign fraction = 23'(magnitude << (23 - b));
    end
    // The exponent-range selects depend on ec only and settle beside the
    // adders; the candidate is a masked OR, not a select chain.
    assign overflow_sel = {1'b0, ec} > 9'(277 - b);
    assign subnormal_sel = {1'b0, ec} < 9'(24 - b);
    assign normal_sel = !overflow_sel && !subnormal_sel;
    assign overflow_hit[b] = leading[b] && overflow_sel;
    assign subnormal_hit[b] = leading[b] && subnormal_sel;
    assign normal_hit[b] = leading[b] && normal_sel;
    assign normal_fraction[b] = {23{normal_hit[b]}} & fraction;
    assign normal_exponent[b] = {8{normal_hit[b]}} & exponent_field;
  end
  // Factor common sign, overflow and subnormal data out of the 25-way select.
  // Only normal fraction/exponent vary with the leading position.
  for (genvar l = 0; l <= 5; l++) begin : gen_normal_or
    localparam int N = 32 >> l;
    logic [22:0] fraction [N];
    logic [7:0] exponent [N];
    for (genvar i = 0; i < N; i++) begin : gen_node
      if (l == 0) begin : gen_input
        if (i < 25) begin : gen_used
          assign fraction[i] = normal_fraction[i];
          assign exponent[i] = normal_exponent[i];
        end else begin : gen_pad
          assign fraction[i] = '0;
          assign exponent[i] = '0;
        end
      end else begin : gen_or
        assign fraction[i] = gen_normal_or[l-1].fraction[2*i] |
                             gen_normal_or[l-1].fraction[2*i+1];
        assign exponent[i] = gen_normal_or[l-1].exponent[2*i] |
                             gen_normal_or[l-1].exponent[2*i+1];
      end
    end
  end
  assign finite_result[36:32] = {2'b00, (|overflow_hit), 1'b0,
                                (normal_hit[24] && low_sum[0])};
  assign finite_result[31] = sign && (|magnitude);
  assign finite_result[30:23] = {8{|overflow_hit}} | gen_normal_or[5].exponent[0];
  assign finite_result[22:0] = gen_normal_or[5].fraction[0] |
                             ({23{|subnormal_hit}} & subnormal_fraction);
  // At most one significand bit is discarded: msb <= 24. There is no
  // subnormal right shift because ec >= 1 (integer exponent >= -149).
  // r127-t: subnormal_fraction is only consumed under |subnormal_hit, which
  // needs ec < 24-b for some b <= 24, i.e. ec <= 23 and ec-1 <= 22. Larger
  // ec leave |subnormal_hit = 0 and mask the term to zero, so the shift
  // amount is clamped to 5 bits -- identical on every consumed value, and
  // the 44.1-FO4 8-bit barrel collapses to a 5-bit one.
  logic [4:0] sub_shift;
  assign sub_shift = (ec >= 8'd24) ? 5'd22 : 5'(ec - 8'd1);
  // magnitude[23:24] can never reach the 23-bit result (i-s <= 22-s <= 22),
  // so the barrel runs on 23 bits, not 25.
  assign subnormal_fraction = 23'(magnitude[22:0] << sub_shift);
  always_comb begin
    if (align_i.nan) result_o = {5'b10000, 32'h7fc00000};
    else if (align_i.inf_a) result_o = {5'b00100, align_i.sign_a, 8'hff, 23'd0};
    else if (align_i.inf_b) result_o = {5'b00100, align_i.sign_b, 8'hff, 23'd0};
    else if (align_i.zero_both) result_o = {5'd0, (align_i.sign_a & align_i.sign_b), 31'd0};
    else result_o = finite_result;
  end
endmodule

// r127 contract item "AI FP32 add third stage": pipeline the norm leaf at the
// candidate-vector boundary. `g6lc_ai_gemm_fp32_norm` is one combinational
// cone (align_i -> magnitude -> leading-one -> masked 25-way candidates ->
// 6-level OR-reduce -> pack, ~44 FO4). The two halves below are bit-identical
// extracts of that cone: cand evaluates align_i into the masked candidate
// vectors + the scalar terms the pack needs; pack only OR-reduces and packs.
// Registering the candidate bundle between them splits the cone into a
// candidate-eval stage and a shallow reduce+pack stage. Purely additive: the
// comb `g6lc_ai_gemm_fp32_norm`/`_add`/`_add_p2` are untouched, so the default
// build is unchanged; a consumer opts in by instantiating `_add_p3`.
module g6lc_ai_gemm_fp32_norm_p1 (
  input  logic clk_i,
  input  logic rst_ni,
  input  g6lc_ai_fp_pkg::fp32_align_t align_i,
  output logic [36:0] result_o
);
  // ---- stage A (comb): candidate evaluation, identical to fp32_norm ----
  logic [23:0] x_mag, y_shift;
  logic sx, sy, corr, same_sign, nonneg, sign;
  logic [7:0] ec;
  logic [24:0] sum_same, diff_xy, diff_yx, magnitude, rounded;
  logic [25:0] diff_xy_wide;
  logic [24:0] diff_yx_xor, diff_yx_carry;
  logic [1:0] low_sum, round_inc;
  logic [24:0] leading;
  logic [22:0] subnormal_fraction;
  logic [24:0] overflow_hit, subnormal_hit, normal_hit;
  logic [22:0] normal_fraction [25];
  logic [7:0] normal_exponent [25];
  logic        magn_nonzero, ovf_any, sub_any, topnl;
  // special-case passthrough terms (registered so stage B needs no align_i)
  logic        nan_q_in, inf_a_q_in, inf_b_q_in, zero_both_q_in;
  logic        sign_a_q_in, sign_b_q_in;

  assign x_mag = align_i.x_mag;
  assign y_shift = align_i.y_shift;
  assign sx = align_i.sx;
  assign sy = align_i.sy;
  assign corr = align_i.corr;
  assign ec = align_i.ec;
  assign same_sign = sx == sy;
  assign sum_same = {1'b0, x_mag} + {1'b0, y_shift} + 25'(corr);
  assign diff_xy_wide = {2'b00, x_mag} + {1'b0, ~{1'b0, y_shift}} + 26'(!corr);
  assign {nonneg, diff_xy} = diff_xy_wide;
  assign diff_yx_xor = {1'b0, y_shift} ^ ~{1'b0, x_mag} ^ {23'd0, corr, !corr};
  assign diff_yx_carry = ((({1'b0, y_shift} & ~{1'b0, x_mag}) |
                           ({1'b0, y_shift} & {23'd0, corr, !corr}) |
                           (~{1'b0, x_mag} & {23'd0, corr, !corr})) << 1);
  assign diff_yx = diff_yx_xor + diff_yx_carry;
  assign magnitude = same_sign ? sum_same : (nonneg ? diff_xy : diff_yx);
  assign sign = same_sign ? sx : (nonneg ? sx : !sx);
  assign low_sum = 2'(x_mag[0]) + 2'(y_shift[0]) + 2'(corr);
  assign round_inc = 2'(low_sum[1]) +
                     2'(low_sum[0] && (x_mag[1] ^ y_shift[1] ^ low_sum[1]));
  assign rounded = {2'b00, x_mag[23:1]} + {2'b00, y_shift[23:1]} + 25'(round_inc);
  for (genvar b = 0; b < 25; b++) begin : gen_leading
    logic [7:0] exponent_field;
    logic [22:0] fraction;
    logic overflow_sel, subnormal_sel, normal_sel;
    if (b == 24) begin : gen_top
      assign leading[b] = magnitude[b];
    end else begin : gen_suffix
      assign leading[b] = magnitude[b] && !(|magnitude[24:b+1]);
    end
    assign exponent_field = ec + 8'(b) - 8'd23;
    if (b == 24) begin : gen_round
      assign fraction = rounded[22:0];
    end else begin : gen_exact
      assign fraction = 23'(magnitude << (23 - b));
    end
    assign overflow_sel = {1'b0, ec} > 9'(277 - b);
    assign subnormal_sel = {1'b0, ec} < 9'(24 - b);
    assign normal_sel = !overflow_sel && !subnormal_sel;
    assign overflow_hit[b] = leading[b] && overflow_sel;
    assign subnormal_hit[b] = leading[b] && subnormal_sel;
    assign normal_hit[b] = leading[b] && normal_sel;
    assign normal_fraction[b] = {23{normal_hit[b]}} & fraction;
    assign normal_exponent[b] = {8{normal_hit[b]}} & exponent_field;
  end
  logic [4:0] sub_shift;
  assign sub_shift = (ec >= 8'd24) ? 5'd22 : 5'(ec - 8'd1);
  assign subnormal_fraction = 23'(magnitude[22:0] << sub_shift);
  // Scalar terms the pack stage needs (pre-reduced so stage B stays shallow).
  assign magn_nonzero = |magnitude;
  assign ovf_any     = |overflow_hit;
  assign sub_any     = |subnormal_hit;
  assign topnl       = normal_hit[24] && low_sum[0];
  assign nan_q_in      = align_i.nan;
  assign inf_a_q_in    = align_i.inf_a;
  assign inf_b_q_in    = align_i.inf_b;
  assign zero_both_q_in= align_i.zero_both;
  assign sign_a_q_in   = align_i.sign_a;
  assign sign_b_q_in   = align_i.sign_b;

  // ---- pipeline register: the candidate bundle ----
  logic [22:0] normal_fraction_q [25];
  logic [7:0]  normal_exponent_q [25];
  logic        sign_q, magn_nonzero_q, ovf_any_q, sub_any_q, topnl_q;
  logic        nan_q, inf_a_q, inf_b_q, zero_both_q, sign_a_q, sign_b_q;
  logic [22:0] subnormal_fraction_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int b = 0; b < 25; b++) begin
        normal_fraction_q[b] <= '0;
        normal_exponent_q[b] <= '0;
      end
      sign_q <= 1'b0; magn_nonzero_q <= 1'b0; ovf_any_q <= 1'b0;
      sub_any_q <= 1'b0; topnl_q <= 1'b0;
      nan_q <= 1'b0; inf_a_q <= 1'b0; inf_b_q <= 1'b0;
      zero_both_q <= 1'b0; sign_a_q <= 1'b0; sign_b_q <= 1'b0;
      subnormal_fraction_q <= '0;
    end else begin
      for (int b = 0; b < 25; b++) begin
        normal_fraction_q[b] <= normal_fraction[b];
        normal_exponent_q[b] <= normal_exponent[b];
      end
      sign_q <= sign; magn_nonzero_q <= magn_nonzero; ovf_any_q <= ovf_any;
      sub_any_q <= sub_any; topnl_q <= topnl;
      nan_q <= nan_q_in; inf_a_q <= inf_a_q_in; inf_b_q <= inf_b_q_in;
      zero_both_q <= zero_both_q_in; sign_a_q <= sign_a_q_in; sign_b_q <= sign_b_q_in;
      subnormal_fraction_q <= subnormal_fraction;
    end
  end

  // ---- stage B (comb): OR-reduce + pack + special mux, identical ----
  for (genvar l = 0; l <= 5; l++) begin : gen_normal_or
    localparam int N = 32 >> l;
    logic [22:0] fraction_l [N];
    logic [7:0] exponent_l [N];
    for (genvar i = 0; i < N; i++) begin : gen_node
      if (l == 0) begin : gen_input
        if (i < 25) begin : gen_used
          assign fraction_l[i] = normal_fraction_q[i];
          assign exponent_l[i] = normal_exponent_q[i];
        end else begin : gen_pad
          assign fraction_l[i] = '0;
          assign exponent_l[i] = '0;
        end
      end else begin : gen_or
        assign fraction_l[i] = gen_normal_or[l-1].fraction_l[2*i] |
                               gen_normal_or[l-1].fraction_l[2*i+1];
        assign exponent_l[i] = gen_normal_or[l-1].exponent_l[2*i] |
                               gen_normal_or[l-1].exponent_l[2*i+1];
      end
    end
  end
  logic [36:0] finite_result;
  assign finite_result[36:32] = {2'b00, ovf_any_q, 1'b0, topnl_q};
  assign finite_result[31] = sign_q && magn_nonzero_q;
  assign finite_result[30:23] = {8{ovf_any_q}} | gen_normal_or[5].exponent_l[0];
  assign finite_result[22:0] = gen_normal_or[5].fraction_l[0] |
                             ({23{sub_any_q}} & subnormal_fraction_q);
  always_comb begin
    if (nan_q) result_o = {5'b10000, 32'h7fc00000};
    else if (inf_a_q) result_o = {5'b00100, sign_a_q, 8'hff, 23'd0};
    else if (inf_b_q) result_o = {5'b00100, sign_b_q, 8'hff, 23'd0};
    else if (zero_both_q) result_o = {5'd0, (sign_a_q & sign_b_q), 31'd0};
    else result_o = finite_result;
  end
endmodule

// Three-stage composition: align registered (as _p2), then the norm leaf
// pipelined at the candidate boundary. Operands presented at edge N produce
// result_o after edge N+2; the caller owns the three-cycle spacing.
module g6lc_ai_gemm_fp32_add_p3 (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic en_i,
  input  logic [31:0] a_i,
  input  logic [31:0] b_i,
  output logic [36:0] result_o
);
  g6lc_ai_fp_pkg::fp32_align_t align, align_q;
  g6lc_ai_gemm_fp32_align i_align (.a_i, .b_i, .align_o(align));
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) align_q <= '0;
    else if (en_i) align_q <= align;
  end
  g6lc_ai_gemm_fp32_norm_p1 i_norm (.clk_i, .rst_ni, .align_i(align_q),
                                    .result_o);
endmodule

// Combinational composition: the reference-equivalence surface.
module g6lc_ai_gemm_fp32_add (
  input  logic [31:0] a_i,
  input  logic [31:0] b_i,
  output logic [36:0] result_o
);
  g6lc_ai_fp_pkg::fp32_align_t align;
  g6lc_ai_gemm_fp32_align i_align (.a_i, .b_i, .align_o(align));
  g6lc_ai_gemm_fp32_norm i_norm (.align_i(align), .result_o);
endmodule

// Two-stage composition: aligned operands are registered; the result of the
// operands presented at edge N is valid after edge N+1. No handshake: the
// caller owns the two-cycle spacing between dependent additions.
module g6lc_ai_gemm_fp32_add_p2 (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic en_i,
  input  logic [31:0] a_i,
  input  logic [31:0] b_i,
  output logic [36:0] result_o
);
  g6lc_ai_fp_pkg::fp32_align_t align, align_q;
  g6lc_ai_gemm_fp32_align i_align (.a_i, .b_i, .align_o(align));
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) align_q <= '0;
    else if (en_i) align_q <= align;
  end
  g6lc_ai_gemm_fp32_norm i_norm (.align_i(align_q), .result_o);
endmodule
