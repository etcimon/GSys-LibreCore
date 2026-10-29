// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Pipelined floating dot product for large lane counts (Lanes=256 target).
//
// Output is valid on sampled edge $clog2(P2)+6, counting acceptance as edge 1.
// One dot product can be issued per cycle once the pipeline is filled, so
// throughput is one dot per cycle at the cost of depth.
//
// Stages:
//   0. decode per lane and capture the format/lane-valid facts
//   1. multiply registered operands per lane
//   2. reduce product exponents to a block exponent and detect NaN/Inf
//   3. align each product mantissa to the block exponent
//   4..(4+LEVELS-1): balanced signed adder tree, one level per cycle
//   final: convert the reduced (sign,mantissa,exponent) to RNE FP32
//
// `start_i` is a one-cycle pulse that tags a transaction. `valid_i[l]` are the
// per-lane valid bits for that transaction. `sum_o` and `flags_o` become valid
// when `valid_o` is asserted, `Latency` cycles after `start_i`.
//
// Not Vg6lc. Not a throughput number.

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
  // r94: the minimum-exponent search is pre-reduced in groups of
  // EXP_GROUP_SIZE lanes during S1 (inside the existing multiply
  // window); S2's tree then only walks the group roots.
  localparam int unsigned EXP_GROUP_LEVELS = (LEVELS < 3) ? LEVELS : 3;
  localparam int unsigned EXP_GROUP_SIZE   = 1 << EXP_GROUP_LEVELS;
  localparam int unsigned EXP_GROUPS       = P2 / EXP_GROUP_SIZE;
  localparam int unsigned EXP_TAIL_LEVELS  = LEVELS - EXP_GROUP_LEVELS;
  localparam int unsigned MAXW = g6lc_ai_fp_pkg::FP_DOT_MAXW;

  localparam int unsigned LATENCY = LEVELS + 5;

  // fmt_ok is constant per tile
  logic fmt_ok;
  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_pe_dot_float_pipe  region=6763  makespan=4.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: s1_exp  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to s1_exp
// order expect: s1_is_inf  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to s1_is_inf
// order expect: s1_is_nan  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to s1_is_nan
// order expect: s1_prod  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to s1_prod
// order expect: s1_sign  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to s1_sign
// order expect: s1_vld  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to s1_vld
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     s1_exp <= …; // sv-timing: cycle 1/1 on clk_i
//     s1_is_inf <= …; // sv-timing: cycle 1/1 on clk_i
//     s1_is_nan <= …; // sv-timing: cycle 1/1 on clk_i
//     s1_prod <= …; // sv-timing: cycle 1/1 on clk_i
//     s1_sign <= …; // sv-timing: cycle 1/1 on clk_i
//     s1_vld <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node23684 c=3.50 slack=1.00 */
//     /* node23685 c=3.50 slack=1.00 */
//     /* node23686 c=3.50 slack=1.00 */
//     /* node23687 c=3.50 slack=1.00 */
//     /* node23688 c=3.50 slack=1.00 */
//     /* node23689 c=3.50 slack=1.00 */
//     /* node23690 c=4.50 slack=0.00 */
//     /* node23691 c=4.50 slack=0.00 */
//     /* node23692 c=4.50 slack=0.00 */
//     /* node23693 c=4.50 slack=0.00 */
//     /* node23694 c=4.50 slack=0.00 */
//     /* node23695 c=4.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_pe_dot_float_pipe  region=6765  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: s2_any_finite_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to s2_any_finite_q
// order expect: s2_any_inf_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to s2_any_inf_q
// order expect: s2_any_nan_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to s2_any_nan_q
// order expect: s2_block_exp_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to s2_block_exp_q
// order expect: s2_inf_sign_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to s2_inf_sign_q
// order expect: s2_same_inf_sign_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to s2_same_inf_sign_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     s2_any_finite_q <= …; // sv-timing: cycle 1/1 on clk_i
//     s2_any_inf_q <= …; // sv-timing: cycle 1/1 on clk_i
//     s2_any_nan_q <= …; // sv-timing: cycle 1/1 on clk_i
//     s2_block_exp_q <= …; // sv-timing: cycle 1/1 on clk_i
//     s2_inf_sign_q <= …; // sv-timing: cycle 1/1 on clk_i
//     s2_same_inf_sign_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node23714 c=3.50 slack=0.00 */
//     /* node23715 c=3.50 slack=0.00 */
//     /* node23716 c=3.50 slack=0.00 */
//     /* node23717 c=3.50 slack=0.00 */
//     /* node23718 c=3.50 slack=0.00 */
//     /* node23719 c=3.50 slack=0.00 */
//     /* node23720 c=3.50 slack=0.00 */
//     /* node23721 c=3.50 slack=0.00 */
//     /* node23722 c=3.50 slack=0.00 */
//     /* node23723 c=3.50 slack=0.00 */
//     /* node23724 c=3.50 slack=0.00 */
//     /* node23725 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_pe_dot_float_pipe  region=6766  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: s2_prod_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to s2_prod_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     s2_prod_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node23726 c=3.50 slack=0.00 */
//     /* node23727 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_pe_dot_float_pipe  region=6768  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: s3_aligned  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to s3_aligned
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     s3_aligned <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node23729 c=3.50 slack=0.00 */
//     /* node23730 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_pe_dot_float_pipe  region=6769  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: s3_any_finite_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to s3_any_finite_q
// order expect: s3_any_inf_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to s3_any_inf_q
// order expect: s3_any_nan_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to s3_any_nan_q
// order expect: s3_block_exp_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to s3_block_exp_q
// order expect: s3_inf_sign_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to s3_inf_sign_q
// order expect: s3_same_inf_sign_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to s3_same_inf_sign_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     s3_any_finite_q <= …; // sv-timing: cycle 1/1 on clk_i
//     s3_any_inf_q <= …; // sv-timing: cycle 1/1 on clk_i
//     s3_any_nan_q <= …; // sv-timing: cycle 1/1 on clk_i
//     s3_block_exp_q <= …; // sv-timing: cycle 1/1 on clk_i
//     s3_inf_sign_q <= …; // sv-timing: cycle 1/1 on clk_i
//     s3_same_inf_sign_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node23731 c=3.50 slack=0.00 */
//     /* node23732 c=3.50 slack=0.00 */
//     /* node23733 c=3.50 slack=0.00 */
//     /* node23734 c=3.50 slack=0.00 */
//     /* node23735 c=3.50 slack=0.00 */
//     /* node23736 c=3.50 slack=0.00 */
//     /* node23737 c=3.50 slack=0.00 */
//     /* node23738 c=3.50 slack=0.00 */
//     /* node23739 c=3.50 slack=0.00 */
//     /* node23740 c=3.50 slack=0.00 */
//     /* node23741 c=3.50 slack=0.00 */
//     /* node23742 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_pe_dot_float_pipe  region=6770  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: red  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to red
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     red <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node23743 c=3.50 slack=0.00 */
//     /* node23744 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_pe_dot_float_pipe  region=6771  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: red_fin  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to red_fin
// order expect: red_inf  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to red_inf
// order expect: red_nan  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to red_nan
// order expect: red_same  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to red_same
// order expect: red_sign  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to red_sign
// order expect: s2_block_exp_piped  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to s2_block_exp_piped
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     red_fin <= …; // sv-timing: cycle 1/1 on clk_i
//     red_inf <= …; // sv-timing: cycle 1/1 on clk_i
//     red_nan <= …; // sv-timing: cycle 1/1 on clk_i
//     red_same <= …; // sv-timing: cycle 1/1 on clk_i
//     red_sign <= …; // sv-timing: cycle 1/1 on clk_i
//     s2_block_exp_piped <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node23745 c=3.50 slack=0.00 */
//     /* node23746 c=3.50 slack=0.00 */
//     /* node23747 c=3.50 slack=0.00 */
//     /* node23748 c=3.50 slack=0.00 */
//     /* node23749 c=3.50 slack=0.00 */
//     /* node23750 c=3.50 slack=0.00 */
//     /* node23751 c=3.50 slack=0.00 */
//     /* node23752 c=3.50 slack=0.00 */
//     /* node23753 c=3.50 slack=0.00 */
//     /* node23754 c=3.50 slack=0.00 */
//     /* node23755 c=3.50 slack=0.00 */
//     /* node23756 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_pe_dot_float_pipe  region=6772  makespan=26.144 FO4  cycle_count=4  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: red  ready_cycle=4  ready_fo4=26.144  OpenSTA: report_timing -from clk_i -to red
// --- factor stage 1/4  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 1: no capture on this edge (slack) */
//   end
// end
// --- factor stage 2/4  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 2: no capture on this edge (slack) */
//     /* node23757 c=8.50 slack=17.64 */
//     /* node23759 c=8.50 slack=17.64 */
//   end
// end
// --- factor stage 3/4  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 3: no capture on this edge (slack) */
//   end
// end
// --- factor stage 4/4  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     red <= …; // sv-timing: cycle 4/4 on clk_i
//     /* node23758 c=26.14 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_pe_dot_float_pipe  region=6773  makespan=8.500 FO4  cycle_count=2  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: red_fin  ready_cycle=2  ready_fo4=8.500  OpenSTA: report_timing -from clk_i -to red_fin
// order expect: red_inf  ready_cycle=2  ready_fo4=8.500  OpenSTA: report_timing -from clk_i -to red_inf
// order expect: red_nan  ready_cycle=2  ready_fo4=8.500  OpenSTA: report_timing -from clk_i -to red_nan
// order expect: red_same  ready_cycle=2  ready_fo4=8.500  OpenSTA: report_timing -from clk_i -to red_same
// order expect: red_sign  ready_cycle=2  ready_fo4=8.500  OpenSTA: report_timing -from clk_i -to red_sign
// order expect: s2_block_exp_piped  ready_cycle=2  ready_fo4=8.500  OpenSTA: report_timing -from clk_i -to s2_block_exp_piped
// --- factor stage 1/2  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 1: no capture on this edge (slack) */
//   end
// end
// --- factor stage 2/2  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     red_fin <= …; // sv-timing: cycle 2/2 on clk_i
//     red_inf <= …; // sv-timing: cycle 2/2 on clk_i
//     red_nan <= …; // sv-timing: cycle 2/2 on clk_i
//     red_same <= …; // sv-timing: cycle 2/2 on clk_i
//     red_sign <= …; // sv-timing: cycle 2/2 on clk_i
//     s2_block_exp_piped <= …; // sv-timing: cycle 2/2 on clk_i
//     /* node23760 c=8.50 slack=0.00 */
//     /* node23761 c=8.50 slack=0.00 */
//     /* node23762 c=8.50 slack=0.00 */
//     /* node23763 c=8.50 slack=0.00 */
//     /* node23764 c=8.50 slack=0.00 */
//     /* node23765 c=8.50 slack=0.00 */
//     /* node23766 c=8.50 slack=0.00 */
//     /* node23767 c=8.50 slack=0.00 */
//     /* node23768 c=8.50 slack=0.00 */
//     /* node23769 c=8.50 slack=0.00 */
//     /* node23770 c=8.50 slack=0.00 */
//     /* node23771 c=8.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_pe_dot_float_pipe  region=6777  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: vld  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to vld
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     vld <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node23775 c=3.50 slack=0.00 */
//     /* node23776 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_pe_dot_float_pipe  region=6778  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: valid_o  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to valid_o
// order expect: {flags_o, sum_o}  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to {flags_o, sum_o}
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     valid_o <= …; // sv-timing: cycle 1/1 on clk_i
//     {flags_o, sum_o} <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node23777 c=3.50 slack=0.00 */
//     /* node23778 c=3.50 slack=0.00 */
//     /* node23779 c=3.50 slack=0.00 */
//     /* node23780 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
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
  // Stage 0: decode operands, retaining lane ownership across issue bubbles.
  g6lc_ai_fp_pkg::fp_dot_value_t s0_a_q [P2], s0_b_q [P2];
  logic s0_lane_q [P2];
  logic s0_start_q, s0_fmt_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s0_start_q <= 1'b0;
      s0_fmt_q <= 1'b0;
    end else begin
      s0_start_q <= start_i;
      if (start_i) s0_fmt_q <= fmt_ok;
    end
  end
  for (genvar g = 0; g < P2; g++) begin : gen_decode
    if (g < Lanes) begin : gen_used
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          s0_a_q[g] <= '0;
          s0_b_q[g] <= '0;
          s0_lane_q[g] <= 1'b0;
        end else if (start_i) begin
          s0_a_q[g] <= g6lc_ai_fp_pkg::fp_dot_decode_value(a_i[g], numfmt_i);
          s0_b_q[g] <= g6lc_ai_fp_pkg::fp_dot_decode_value(b_i[g], numfmt_i);
          s0_lane_q[g] <= valid_i[g];
        end
      end
    end else begin : gen_pad
      assign s0_a_q[g] = '0;
      assign s0_b_q[g] = '0;
      assign s0_lane_q[g] = 1'b0;
    end
  end

  // Stage 1: multiply the registered decoded operands.
  //
  // Per-lane always_ff blocks avoid for-loop procedural-variable ordering
  // problems; each lane captures its own local product and valid flags.
  // early_exp mirrors fp_dot_product's validity exactly: a lane's
  // exponent joins the minimum iff both operands are finite non-zero
  // and the lane is valid; eligibility never reads the product, so the
  // group minima can register in the same S1 window.
  logic signed [15:0] early_exp    [P2];
  logic signed [15:0] group_min_d  [EXP_GROUPS];
  logic signed [15:0] group_min_q  [EXP_GROUPS];
  for (genvar g = 0; g < P2; g++) begin : gen_early_exp
    assign early_exp[g] =
        (s0_fmt_q && s0_lane_q[g] &&
         !s0_a_q[g].is_nan && !s0_b_q[g].is_nan &&
         !s0_a_q[g].is_inf && !s0_b_q[g].is_inf &&
         !s0_a_q[g].is_zero && !s0_b_q[g].is_zero)
        ? (s0_a_q[g].exp + s0_b_q[g].exp) : NO_EXP;
  end
  for (genvar grp = 0; grp < EXP_GROUPS; grp++) begin : gen_group_min
    logic signed [15:0] gmin [0:EXP_GROUP_LEVELS][0:EXP_GROUP_SIZE-1];
    for (genvar l = 0; l < EXP_GROUP_SIZE; l++)
      assign gmin[0][l] = early_exp[grp * EXP_GROUP_SIZE + l];
    for (genvar level = 1; level <= EXP_GROUP_LEVELS; level++)
      for (genvar n = 0; n < (EXP_GROUP_SIZE >> level); n++)
        assign gmin[level][n] =
            (gmin[level-1][2*n] < gmin[level-1][2*n+1])
            ? gmin[level-1][2*n] : gmin[level-1][2*n+1];
    assign group_min_d[grp] = gmin[EXP_GROUP_LEVELS][0];
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni)         group_min_q[grp] <= NO_EXP;
      else if (s0_start_q) group_min_q[grp] <= group_min_d[grp];
    end
  end

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

  // Stage 1 combinational: multiply and produce the next register value.
  always_comb begin
    for (int unsigned g = 0; g < P2; g++) begin
      g6lc_ai_fp_pkg::fp_dot_product_t p;
      p     = prod_zero();
      if (g < Lanes) begin
        if (s0_fmt_q)
          p = g6lc_ai_fp_pkg::fp_dot_product(s0_a_q[g], s0_b_q[g]);
      end
      if (g < Lanes && s0_fmt_q) begin
        if (s0_lane_q[g] && !p.is_nan && !p.is_inf && !p.is_zero) begin
          s1_prod_d[g]   = '{sign: p.sign, mant: p.mant, exp: p.exp,
                             is_nan: p.is_nan, is_inf: p.is_inf, is_zero: p.is_zero};
          s1_vld_d[g]    = 1'b1;
          s1_exp_d[g]    = p.exp;
        end else begin
          s1_prod_d[g]   = prod_zero();
          s1_vld_d[g]    = 1'b0;
          s1_exp_d[g]    = NO_EXP;
        end
        s1_is_nan_d[g] = s0_lane_q[g] && p.is_nan;
        s1_is_inf_d[g] = s0_lane_q[g] && p.is_inf;
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

  // Stage 1 register: only load when the decode stage owns a transaction.
  // Gating on s0_start_q makes back-to-back issue safe: a cycle with no
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
        end else if (s0_start_q) begin
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
    logic signed [15:0] exp_min [0:EXP_TAIL_LEVELS][0:EXP_GROUPS-1];
    logic any_nan, any_inf, any_finite;
    logic has_pos_inf, has_neg_inf;
    // Block exponent = min over the registered group minima; the group
    // roots already encode invalid lanes as NO_EXP.
    for (int unsigned l = 0; l < EXP_GROUPS; l++)
      exp_min[0][l] = group_min_q[l];
    for (int unsigned level = 1; level <= EXP_TAIL_LEVELS; level++) begin
      for (int unsigned i = 0; i < (EXP_GROUPS >> level); i++) begin
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
    s2_block_exp_d    = exp_min[EXP_TAIL_LEVELS][0];
    s2_any_nan_d      = any_nan;
    s2_any_inf_d      = any_inf;
    s2_any_finite_d   = any_finite;
    s2_same_inf_sign_d = !(has_neg_inf && has_pos_inf);
    s2_inf_sign_d     = has_neg_inf;
  end
// pragma translate_off
  // The grouped S1/S2 split must equal the original single-pass minimum.
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin : gexp_chk
      logic signed [15:0] ref_min;
      ref_min = NO_EXP;
      for (int unsigned l = 0; l < P2; l++)
        if ((s1_vld[l] ? s1_exp[l] : NO_EXP) < ref_min)
          ref_min = s1_vld[l] ? s1_exp[l] : NO_EXP;
      assert (s2_block_exp_d == ref_min)
        else $error("grouped exponent-min identity");
    end
  end
// pragma translate_on

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

  // valid_o tracks the start pulse through the pipeline. LATENCY = LEVELS + 5.
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
