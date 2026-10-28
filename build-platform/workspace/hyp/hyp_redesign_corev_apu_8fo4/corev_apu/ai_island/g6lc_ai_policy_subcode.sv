// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Modified by: Etienne Cimon (2026), r32 rank + r40 SHAPE/fact ownership decomposition.
module g6lc_ai_policy_subcode
  import g6lc_ai_policy_pkg::*;
#(
    parameter bit Enabled = 1'b0,
    parameter bit CacheEn = 1'b0,
    parameter int unsigned ReadBytesPerCycle = 128,
    parameter int unsigned MinSavingsCycles = 2,
    parameter int unsigned SwitchCycles = 2,
    parameter logic [31:0] FormatStepCycles = 32'h11111111,
    parameter logic [31:0] FormatMinReductionLog2 = 32'h00000000,
    parameter logic [23:0] GroupShapeLog2 = 24'h4420ca
) (
    input logic clk_i, rst_ni, testmode_i, enable_i, flush_i, cancel_i, start_i,
    input policy_code_t code_i,
    input logic [2:0] numfmt_i,
    input logic [15:0] m_i, n_i, k_i,
    input policy_topology_t baseline_i,
    output logic ready_o, busy_o, valid_o, evaluated_o, cache_hit_o,
    output logic [2:0] subcode_o,
    output policy_topology_t topology_o,
    output logic [31:0] baseline_cycles_o, selected_cycles_o
);
  localparam int unsigned EvaluationCycles = 32;
  localparam int unsigned ReadShift = $clog2(ReadBytesPerCycle);

`ifndef SYNTHESIS
  initial begin
    assert (!CacheEn || Enabled)
      else $fatal(1, "Subcode cache requires the evaluator");
    assert (ReadBytesPerCycle >= 1 && ReadBytesPerCycle <= 4096 &&
        (ReadBytesPerCycle & (ReadBytesPerCycle - 1)) == 0)
      else $fatal(1, "Subcode read service must be a power of two in [1,4096]");
    assert (MinSavingsCycles <= 65535 && SwitchCycles <= 65535)
      else $fatal(1, "Subcode cost margins must fit 16 bits");
    for (int f = 0; f < 8; f++) begin
      assert (FormatStepCycles[f*4 +: 4] != 0 && FormatMinReductionLog2[f*4 +: 4] <= 9)
        else $fatal(1, "Invalid subcode format service parameters");
    end
    for (int g = 0; g < 4; g++) begin
      assert (GroupShapeLog2[g*6+3 +: 3] <= 4 && GroupShapeLog2[g*6 +: 3] <= 4 &&
          int'(GroupShapeLog2[g*6+3 +: 3]) + int'(GroupShapeLog2[g*6 +: 3]) <= 4)
        else $fatal(1, "Subcode group shape exceeds 16 output slots");
    end
  end
`endif

  if (Enabled) begin : gen_on
    // r25: COST evaluates the byte/service terms from facts registered in PREP.
    typedef enum logic [3:0] {IDLE, PREP, COST, SERVICE, TOTAL, COMPARE, CACHED, RANK, SHAPE} state_t;
    state_t state_q;
    policy_topology_t base_q, candidate_q, candidate_d, best_q, winner;
    logic [8:0] m_q, n_q, k_q;
    logic [2:0] fmt_q, index_q, best_index_q, winner_index;
    logic [1:0] group_q, input_group;
    logic cache_valid_q, cache_match;
    logic candidate_ok_q, candidate_ok, eligible, better, choose;
    logic better_q;
    logic [7:0] m_align_q, n_align_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) better_q <= 1'b0;
      else if (flush_i || !enable_i || cancel_i) better_q <= 1'b0;
      else if (state_q == RANK) better_q <= candidate_ok_q && cost_q < best_cost_q;
    end
    for (genvar ga = 0; ga < 8; ga++) begin : gen_alignment
      if (ga > 0 && ga <= 4) begin : gen_mask
        always_ff @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) begin m_align_q[ga] <= 1'b0; n_align_q[ga] <= 1'b0; end
          else if (state_q == IDLE && start_i) begin
            m_align_q[ga] <= m_i[ga-1:0] == '0;
            n_align_q[ga] <= n_i[ga-1:0] == '0;
          end
        end
      end else begin : gen_constant
        always_ff @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) begin m_align_q[ga] <= 1'b0; n_align_q[ga] <= 1'b0; end
          else if (state_q == IDLE && start_i) begin
            m_align_q[ga] <= ga == 0;
            n_align_q[ga] <= ga == 0;
          end
        end
      end
    end
    logic [2:0] r, c;
    logic [3:0] d;
    logic [5:0] group_shape_i, group_shape_q;
    logic [2:0] shape_r, shape_c;
    logic [3:0] shape_sum_q;
    always_comb begin
      case (input_group)
        2'd0: group_shape_i = GroupShapeLog2[5:0];
        2'd1: group_shape_i = GroupShapeLog2[11:6];
        2'd2: group_shape_i = GroupShapeLog2[17:12];
        default: group_shape_i = GroupShapeLog2[23:18];
      endcase
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) group_shape_q <= '0;
      else if (state_q == IDLE && start_i) group_shape_q <= group_shape_i;
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin r <= '0; c <= '0; shape_sum_q <= '0; end
      else if (state_q == SHAPE) begin
        r <= shape_r;
        c <= shape_c;
        shape_sum_q <= {1'b0, shape_r} + {1'b0, shape_c};
      end
    end
    logic [8:0] mgroups, ngroups;
    logic [16:0] groups_q;
    logic [8:0] full_q;
    logic [15:0] full_service_q, tail_service_q;
    logic [14:0] service_q;
    logic [27:0] cost_q, best_cost_q, base_cost_q, winner_cost;
    logic [9:0] depth, tail;
    logic [5:0] inputs_per_group;
    logic [15:0] full_bytes, tail_bytes;
    logic [15:0] full_service, tail_service;
    logic [3:0] step_cycles;
    // r26: the reuse gain depends only on (r, c) in 0..4: an elaboration
    // table selected by the pair replaces the package function's divide.
    localparam logic [3:0] reuse_gain_tab [8][8] = '{
      '{4'd0,4'd4,4'd6,4'd7,4'd7,4'd7,4'd15,4'd7},
      '{4'd4,4'd8,4'd10,4'd11,4'd11,4'd11,4'd7,4'd3},
      '{4'd6,4'd10,4'd12,4'd13,4'd13,4'd5,4'd3,4'd1},
      '{4'd7,4'd11,4'd13,4'd14,4'd6,4'd2,4'd1,4'd0},
      '{4'd7,4'd11,4'd13,4'd6,4'd3,4'd1,4'd0,4'd0},
      '{4'd7,4'd11,4'd5,4'd2,4'd1,4'd0,4'd0,4'd0},
      '{4'd15,4'd7,4'd3,4'd1,4'd0,4'd0,4'd0,4'd0},
      '{4'd7,4'd3,4'd1,4'd0,4'd0,4'd0,4'd0,4'd0}};
    // pragma translate_off
    always @(posedge clk_i) if (rst_ni && state_q == PREP)
      assert (reuse_gain_tab[r][c] == policy_reuse_gain(r, c)) else $error("reuse gain table");
    // pragma translate_on
    // r26: the self-charging threshold is one registered fact per
    // evaluation; the per-candidate decision is a single compare.
    logic [27:0] threshold_q;
    logic threshold_ok_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin threshold_q <= '0; threshold_ok_q <= 1'b0; end
      else begin
        threshold_ok_q <= 64'(base_cost_q) > 64'(SwitchCycles) + 64'(EvaluationCycles) + 64'(MinSavingsCycles);
        threshold_q <= 28'(64'(base_cost_q) - 64'(SwitchCycles) - 64'(EvaluationCycles) - 64'(MinSavingsCycles));
      end
    end
    // r30 shared sequential multiplier: launched on entry to each product
    // state; done is a one-cycle pulse the state consumes.
    logic mul_start, mul_done, mul_done_raw, mul_launched_q;
    logic mul_pending_q, mul_owned_q, eval_abort;
    assign eval_abort = flush_i || !enable_i || cancel_i;
    assign mul_done = mul_done_raw && mul_owned_q && !eval_abort;
    logic [31:0] mul_a, mul_b;
    logic [63:0] mul_product;
    always_comb begin
      mul_a = '0; mul_b = '0;
      case (state_q)
        COST: begin mul_a = 32'(mgroups_q); mul_b = 32'(ngroups_q); end
        SERVICE: begin mul_a = 32'(full_q); mul_b = 32'(full_service_q); end
        TOTAL: begin mul_a = 32'(groups_q); mul_b = 32'(service_q); end
        default: ;
      endcase
    end
    assign mul_start = state_q inside {COST, SERVICE, TOTAL} &&
        !mul_launched_q && !mul_pending_q && !eval_abort;
    // The shared multiplier cannot cancel. Drain aborted work before relaunch,
    // and only publish completion owned by the current evaluation.
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin mul_pending_q <= 1'b0; mul_owned_q <= 1'b0; end
      else begin
        if (mul_done_raw) begin mul_pending_q <= 1'b0; mul_owned_q <= 1'b0; end
        if (mul_start) begin mul_pending_q <= 1'b1; mul_owned_q <= 1'b1; end
        if (eval_abort) mul_owned_q <= 1'b0;
      end
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) mul_launched_q <= 1'b0;
      else if (eval_abort || mul_done || !(state_q inside {COST, SERVICE, TOTAL})) mul_launched_q <= 1'b0;
      else if (mul_start) mul_launched_q <= 1'b1;
    end
    g6lc_ai_mul_seq #(.WA(32), .WB(32)) i_mul (
      .clk_i, .rst_ni, .start_i(mul_start), .a_i(mul_a), .b_i(mul_b),
      .done_o(mul_done_raw), .product_o(mul_product)
    );
    // pragma translate_off
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      mul_done && state_q == TOTAL |-> 28'(mul_product) == 28'(28'(groups_q) * 28'(service_q)));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        mul_done |-> mul_pending_q && mul_launched_q &&
        (state_q inside {COST, SERVICE, TOTAL}));
    // pragma translate_on
    // r25 registered shape facts (PREP -> COST)
    logic [2:0] r_q, c_q;
    logic [9:0] tail_q;
    logic [11:0] rb_full_q, rb_tail_q;
    logic [8:0] mgroups_q, ngroups_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        r_q <= '0; c_q <= '0; tail_q <= '0; rb_full_q <= '0; rb_tail_q <= '0;
        mgroups_q <= '0; ngroups_q <= '0;
      end else if (state_q == PREP) begin
        r_q <= r; c_q <= c; tail_q <= tail;
        rb_full_q <= row_bytes(depth, fmt_q); rb_tail_q <= row_bytes(tail, fmt_q);
        mgroups_q <= mgroups; ngroups_q <= ngroups;
      end
    end

    function automatic logic [11:0] row_bytes(input logic [9:0] count, input logic [2:0] fmt);
      case (fmt)
        3'(config_pkg::AI_FMT_INT4): return 12'(({1'b0, count} + 11'd1) >> 1);
        3'(config_pkg::AI_FMT_FP16), 3'(config_pkg::AI_FMT_BF16): return {1'b0, count, 1'b0};
        3'(config_pkg::AI_FMT_FP32): return {count, 2'b00};
        default: return {2'b00, count};
      endcase
    endfunction

    

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_policy_subcode  region=6824  makespan=60.342 FO4  cycle_count=8  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: base_cost_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to base_cost_q
// order expect: base_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to base_q
// order expect: baseline_cycles_o  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to baseline_cycles_o
// order expect: best_cost_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to best_cost_q
// order expect: best_index_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to best_index_q
// order expect: best_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to best_q
// order expect: cache_hit_o  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to cache_hit_o
// order expect: cache_valid_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to cache_valid_q
// order expect: candidate_ok_q  ready_cycle=2  ready_fo4=11.500  OpenSTA: report_timing -from clk_i -to candidate_ok_q
// order expect: candidate_q  ready_cycle=2  ready_fo4=11.500  OpenSTA: report_timing -from clk_i -to candidate_q
// order expect: cost_q  ready_cycle=8  ready_fo4=60.342  OpenSTA: report_timing -from clk_i -to cost_q
// order expect: evaluated_o  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to evaluated_o
// order expect: fmt_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to fmt_q
// order expect: full_q  ready_cycle=2  ready_fo4=11.500  OpenSTA: report_timing -from clk_i -to full_q
// order expect: full_service_q  ready_cycle=2  ready_fo4=11.500  OpenSTA: report_timing -from clk_i -to full_service_q
// order expect: group_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to group_q
// order expect: groups_q  ready_cycle=7  ready_fo4=52.280  OpenSTA: report_timing -from clk_i -to groups_q
// order expect: index_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to index_q
// order expect: k_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to k_q
// order expect: m_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to m_q
// order expect: n_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to n_q
// order expect: selected_cycles_o  ready_cycle=3  ready_fo4=17.000  OpenSTA: report_timing -from clk_i -to selected_cycles_o
// order expect: service_q  ready_cycle=8  ready_fo4=59.300  OpenSTA: report_timing -from clk_i -to service_q
// order expect: state_q  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to state_q
// order expect: subcode_o  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to subcode_o
// order expect: tail_service_q  ready_cycle=2  ready_fo4=11.500  OpenSTA: report_timing -from clk_i -to tail_service_q
// order expect: topology_o  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to topology_o
// order expect: valid_o  ready_cycle=2  ready_fo4=12.500  OpenSTA: report_timing -from clk_i -to valid_o
// --- factor stage 1/8  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 1: no capture on this edge (slack) */
//     /* node23925 c=3.50 slack=56.84 */
//     /* node23926 c=3.50 slack=56.84 */
//     /* node23927 c=3.50 slack=56.84 */
//     /* node23928 c=3.50 slack=56.84 */
//     /* node23929 c=3.50 slack=56.84 */
//     /* node23930 c=3.50 slack=56.84 */
//     /* node23931 c=3.50 slack=56.84 */
//     /* node23932 c=3.50 slack=56.84 */
//     /* node23933 c=3.50 slack=56.84 */
//     /* node23934 c=3.50 slack=56.84 */
//     /* node23935 c=3.50 slack=56.84 */
//     /* node23936 c=3.50 slack=56.84 */
//     /* node23937 c=3.50 slack=56.84 */
//     /* node23938 c=3.50 slack=56.84 */
//     /* node23939 c=3.50 slack=56.84 */
//     /* node23940 c=3.50 slack=56.84 */
//     /* node23941 c=3.50 slack=56.84 */
//     /* node23942 c=3.50 slack=56.84 */
//     /* node23943 c=3.50 slack=56.84 */
//     /* node23944 c=3.50 slack=56.84 */
//     /* node23945 c=3.50 slack=56.84 */
//     /* node23946 c=3.50 slack=56.84 */
//     /* node23947 c=3.50 slack=56.84 */
//     /* node23948 c=3.50 slack=56.84 */
//     /* node23949 c=3.50 slack=56.84 */
//     /* node23950 c=3.50 slack=56.84 */
//     /* node23951 c=3.50 slack=56.84 */
//     /* node23952 c=3.50 slack=56.84 */
//     /* node24028 c=0.00 slack=60.34 */
//     /* node24029 c=0.00 slack=60.34 */
//     /* node24030 c=0.00 slack=60.34 */
//     /* node24031 c=0.00 slack=60.34 */
//     /* node24037 c=0.00 slack=60.34 */
//     /* node24038 c=0.00 slack=60.34 */
//     /* node24039 c=0.00 slack=60.34 */
//     /* node24040 c=0.00 slack=60.34 */
//     /* node24041 c=0.00 slack=60.34 */
//     /* node24042 c=0.00 slack=60.34 */
//     /* node24043 c=0.00 slack=60.34 */
//   end
// end
// --- factor stage 2/8  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     base_cost_q <= …; // sv-timing: cycle 2/8 on clk_i
//     base_q <= …; // sv-timing: cycle 2/8 on clk_i
//     baseline_cycles_o <= …; // sv-timing: cycle 2/8 on clk_i
//     best_cost_q <= …; // sv-timing: cycle 2/8 on clk_i
//     best_index_q <= …; // sv-timing: cycle 2/8 on clk_i
//     best_q <= …; // sv-timing: cycle 2/8 on clk_i
//     cache_hit_o <= …; // sv-timing: cycle 2/8 on clk_i
//     cache_valid_q <= …; // sv-timing: cycle 2/8 on clk_i
//     candidate_ok_q <= …; // sv-timing: cycle 2/8 on clk_i
//     candidate_q <= …; // sv-timing: cycle 2/8 on clk_i
//     evaluated_o <= …; // sv-timing: cycle 2/8 on clk_i
//     fmt_q <= …; // sv-timing: cycle 2/8 on clk_i
//     full_q <= …; // sv-timing: cycle 2/8 on clk_i
//     full_service_q <= …; // sv-timing: cycle 2/8 on clk_i
//     group_q <= …; // sv-timing: cycle 2/8 on clk_i
//     index_q <= …; // sv-timing: cycle 2/8 on clk_i
//     k_q <= …; // sv-timing: cycle 2/8 on clk_i
//     m_q <= …; // sv-timing: cycle 2/8 on clk_i
//     n_q <= …; // sv-timing: cycle 2/8 on clk_i
//     state_q <= …; // sv-timing: cycle 2/8 on clk_i
//     subcode_o <= …; // sv-timing: cycle 2/8 on clk_i
//     tail_service_q <= …; // sv-timing: cycle 2/8 on clk_i
//     topology_o <= …; // sv-timing: cycle 2/8 on clk_i
//     valid_o <= …; // sv-timing: cycle 2/8 on clk_i
//     /* node23953 c=10.50 slack=49.84 */
//     /* node23954 c=10.50 slack=49.84 */
//     /* node23955 c=10.50 slack=49.84 */
//     /* node23956 c=10.50 slack=49.84 */
//     /* node23957 c=10.50 slack=49.84 */
//     /* node23958 c=10.50 slack=49.84 */
//     /* node23959 c=10.50 slack=49.84 */
//     /* node23960 c=10.50 slack=49.84 */
//     /* node23961 c=10.50 slack=49.84 */
//     /* node23962 c=10.50 slack=49.84 */
//     /* node23963 c=10.50 slack=49.84 */
//     /* node23964 c=10.50 slack=49.84 */
//     /* node23965 c=10.50 slack=49.84 */
//     /* node23966 c=10.50 slack=49.84 */
//     /* node23967 c=10.50 slack=49.84 */
//     /* node23968 c=10.50 slack=49.84 */
//     /* node23969 c=10.50 slack=49.84 */
//     /* node23970 c=10.50 slack=49.84 */
//     /* node23971 c=10.50 slack=49.84 */
//     /* node23972 c=10.50 slack=49.84 */
//     /* node23973 c=10.50 slack=49.84 */
//     /* node23974 c=10.50 slack=49.84 */
//     /* node23975 c=10.50 slack=49.84 */
//     /* node23976 c=10.50 slack=49.84 */
//     /* node23977 c=10.50 slack=49.84 */
//     /* node23978 c=10.50 slack=49.84 */
//     /* node23979 c=10.50 slack=49.84 */
//     /* node23980 c=10.50 slack=49.84 */
//     /* node23981 c=11.50 slack=48.84 */
//     /* node23982 c=11.50 slack=48.84 */
//     /* node23983 c=11.50 slack=48.84 */
//     /* node23984 c=11.50 slack=48.84 */
//     /* node23985 c=11.50 slack=48.84 */
//     /* node23986 c=11.50 slack=48.84 */
//     /* node23987 c=11.50 slack=48.84 */
//     /* node23988 c=11.50 slack=48.84 */
//     /* node23989 c=12.50 slack=47.84 */
//     /* node23990 c=12.50 slack=47.84 */
//     /* node23991 c=12.50 slack=47.84 */
//     /* node23992 c=12.50 slack=47.84 */
//     /* node23993 c=12.50 slack=47.84 */
//     /* node23994 c=12.50 slack=47.84 */
//     /* node23995 c=12.50 slack=47.84 */
//     /* node23996 c=12.50 slack=47.84 */
//     /* node23997 c=12.50 slack=47.84 */
//     /* node23998 c=12.50 slack=47.84 */
//     /* node23999 c=12.50 slack=47.84 */
//     /* node24000 c=12.50 slack=47.84 */
//     /* node24001 c=12.50 slack=47.84 */
//     /* node24002 c=12.50 slack=47.84 */
//     /* node24003 c=12.50 slack=47.84 */
//     /* node24004 c=12.50 slack=47.84 */
//     /* node24005 c=12.50 slack=47.84 */
//     /* node24006 c=12.50 slack=47.84 */
//     /* node24007 c=12.50 slack=47.84 */
//     /* node24008 c=11.50 slack=48.84 */
//     /* node24009 c=11.50 slack=48.84 */
//     /* node24011 c=11.50 slack=48.84 */
//     /* node24012 c=11.50 slack=48.84 */
//     /* node24013 c=11.50 slack=48.84 */
//     /* node24014 c=11.50 slack=48.84 */
//     /* node24016 c=11.50 slack=48.84 */
//     /* node24018 c=11.50 slack=48.84 */
//     /* node24019 c=12.50 slack=47.84 */
//     /* node24020 c=12.50 slack=47.84 */
//     /* node24021 c=12.50 slack=47.84 */
//     /* node24022 c=12.50 slack=47.84 */
//     /* node24023 c=12.50 slack=47.84 */
//     /* node24024 c=12.50 slack=47.84 */
//     /* node24025 c=12.50 slack=47.84 */
//     /* node24026 c=12.50 slack=47.84 */
//     /* node24032 c=12.50 slack=47.84 */
//     /* node24033 c=12.50 slack=47.84 */
//     /* node24034 c=12.50 slack=47.84 */
//     /* node24035 c=12.50 slack=47.84 */
//     /* node24036 c=12.50 slack=47.84 */
//     /* node24044 c=11.50 slack=48.84 */
//     /* node24045 c=11.50 slack=48.84 */
//   end
// end
// --- factor stage 3/8  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     selected_cycles_o <= …; // sv-timing: cycle 3/8 on clk_i
//     /* node24027 c=17.00 slack=43.34 */
//   end
// end
// --- factor stage 4/8  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 4: no capture on this edge (slack) */
//   end
// end
// --- factor stage 5/8  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 5: no capture on this edge (slack) */
//   end
// end
// --- factor stage 6/8  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     /* cycle 6: no capture on this edge (slack) */
//   end
// end
// --- factor stage 7/8  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     groups_q <= …; // sv-timing: cycle 7/8 on clk_i
//     /* node24010 c=52.28 slack=8.06 */
//   end
// end
// --- factor stage 8/8  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     cost_q <= …; // sv-timing: cycle 8/8 on clk_i
//     service_q <= …; // sv-timing: cycle 8/8 on clk_i
//     /* node24015 c=59.30 slack=1.04 */
//     /* node24017 c=60.34 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
    // r7 R1: job-event outputs registered (one-cycle-delayed state).
    logic ready_q, busy_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        ready_q <= 1'b0; busy_q <= 1'b0;
      end else begin
        ready_q <= enable_i && !flush_i && !cancel_i && state_q == IDLE;
        busy_q  <= state_q != IDLE;
      end
    end
    assign ready_o = ready_q;
    assign busy_o  = busy_q;
    always_comb begin
      case (code_i)
        POLICY_DECODE: input_group = 2'd1;
        POLICY_ROUTED: input_group = 2'd2;
        POLICY_SPARSE: input_group = 2'd3;
        default: input_group = 2'd0;
      endcase
    end
    assign cache_match = CacheEn && cache_valid_q && eligible && baseline_i == base_q &&
        m_i == {7'd0, m_q} && n_i == {7'd0, n_q} && k_i == {7'd0, k_q} &&
        numfmt_i == fmt_q && input_group == group_q;
    assign eligible = baseline_i.valid && policy_format_known(numfmt_i) &&
        m_i != 0 && n_i != 0 && k_i != 0 && m_i <= 256 && n_i <= 256 && k_i <= 256 &&
        (code_i inside {POLICY_BULK, POLICY_DECODE, POLICY_ROUTED, POLICY_SPARSE}) &&
        baseline_i.slots_log2 >= 1 && baseline_i.slots_log2 <= 9 &&
        baseline_i.rows_log2 <= 4 && baseline_i.cols_log2 <= 4 &&
        int'(baseline_i.rows_log2) + int'(baseline_i.cols_log2) <= 4 &&
        int'(baseline_i.rows_log2) + int'(baseline_i.cols_log2) +
            int'(baseline_i.reduction_log2) == int'(baseline_i.slots_log2) &&
        baseline_i.element_bits_log2 == policy_element_bits_log2(numfmt_i) &&
        (m_i & ((16'd1 << baseline_i.rows_log2) - 16'd1)) == 0 &&
        (n_i & ((16'd1 << baseline_i.cols_log2) - 16'd1)) == 0;

    // r8 P6: one always_comb per output family -- the single block
    // composed candidate/cost/winner as a serial makespan (~96.4).
    // Family 1: candidate terms (r/c/d/ok/candidate_d).
    always_comb begin
      shape_r = '0;
      shape_c = '0;
      case (index_q)
        3'd0: begin shape_r = base_q.rows_log2; shape_c = base_q.cols_log2; end
        3'd2: shape_c = 3'd4;
        3'd3: begin shape_r = 3'd1; shape_c = 3'd3; end
        3'd4: begin shape_r = 3'd2; shape_c = 3'd2; end
        3'd5: begin shape_r = 3'd3; shape_c = 3'd1; end
        3'd6: shape_r = 3'd4;
        3'd7: begin shape_r = group_shape_q[5:3]; shape_c = group_shape_q[2:0]; end
        default: begin end
      endcase
    end
    assign d = base_q.slots_log2 - shape_sum_q;
    assign candidate_ok = r <= 3'd4 && c <= 3'd4 && shape_sum_q <= 4'd4 &&
        shape_sum_q <= base_q.slots_log2 && m_align_q[r] && n_align_q[c] &&
        (index_q == 0 || d >= FormatMinReductionLog2[int'(fmt_q)*4 +: 4]);
    always_comb begin
      candidate_d = base_q;
      if (index_q != 0) begin
        candidate_d.rows_log2 = r;
        candidate_d.cols_log2 = c;
        candidate_d.reduction_log2 = d;
        candidate_d.apply = r != 0 || c != 0;
        candidate_d.gain_16ths = reuse_gain_tab[r][c];
      end
    end

    // Family 2: cost/service terms (reads family-1 leaf wires r/c/d).
    always_comb begin
      mgroups = m_q >> r;
      ngroups = n_q >> c;
      depth = 10'd1 << d;
      tail = {1'b0, k_q} & (depth - 10'd1);
      inputs_per_group = (6'd1 << r) + (6'd1 << c);
    end
    // Independent byte and service cones; preserve the original truncations.
    logic [15:0] full_service_raw, tail_service_raw;
    assign full_bytes = (16'(rb_full_q) << r_q) + (16'(rb_full_q) << c_q);
    assign tail_bytes = (16'(rb_tail_q) << r_q) + (16'(rb_tail_q) << c_q);
    assign step_cycles = FormatStepCycles[int'(fmt_q)*4 +: 4];
    assign full_service_raw = 16'((32'(full_bytes) + ReadBytesPerCycle - 1) >> ReadShift);
    assign tail_service_raw = 16'((32'(tail_bytes) + ReadBytesPerCycle - 1) >> ReadShift);
    assign full_service = full_service_raw < {12'd0, step_cycles} ?
                          {12'd0, step_cycles} : full_service_raw;
    assign tail_service = tail_q == 0 ? 16'd0 :
                          (tail_service_raw < {12'd0, step_cycles} ?
                           {12'd0, step_cycles} : tail_service_raw);

    // Family 3: better/winner/choose (reads registered cost/candidate_ok).
    logic candidate_choose_q, best_choose_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin candidate_choose_q <= 1'b0; best_choose_q <= 1'b0; end
      else if (state_q == RANK) begin
        candidate_choose_q <= index_q != 0 && threshold_ok_q && cost_q < threshold_q;
        best_choose_q <= best_index_q != 0 && threshold_ok_q && best_cost_q < threshold_q;
      end
    end
    assign better = better_q;
    assign winner = better_q ? candidate_q : best_q;
    assign winner_index = better_q ? index_q : best_index_q;
    assign winner_cost = better_q ? cost_q : best_cost_q;
    // The evaluator charges ITSELF: a candidate must beat the baseline after
    // paying the switch cost, the 32-cycle evaluation tax and a minimum
    // margin. Without those terms it would report wins it cannot bank.
    assign choose = better_q ? candidate_choose_q : best_choose_q;
    // pragma translate_off
    always @(posedge clk_i) if (rst_ni) begin
      if (state_q == PREP) begin
        assert ({r, c} == {shape_r, shape_c} &&
            shape_sum_q == {1'b0, r} + {1'b0, c}) else $fatal(1, "r40 shape ownership");
        assert (d == base_q.slots_log2 - {1'b0, r} - {1'b0, c})
          else $fatal(1, "r40 reduction geometry");
        assert (candidate_ok == (r <= 4 && c <= 4 && int'(r) + int'(c) <= 4 &&
            int'(r) + int'(c) <= int'(base_q.slots_log2) && m_align_q[r] && n_align_q[c] &&
            (index_q == 0 || d >= FormatMinReductionLog2[int'(fmt_q)*4 +: 4])))
          else $fatal(1, "r40 candidate eligibility");
      end
      if (state_q == COMPARE)
        assert (choose == (winner_index != 0 &&
            64'(winner_cost) + 64'(SwitchCycles) + 64'(EvaluationCycles) +
            64'(MinSavingsCycles) < 64'(base_cost_q)))
          else $fatal(1, "r40 winner threshold identity");
    end
    // pragma translate_on

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= IDLE;
        base_q <= '0; candidate_q <= '0; best_q <= '0;
        m_q <= '0; n_q <= '0; k_q <= '0; fmt_q <= '0; group_q <= '0;
        index_q <= '0; best_index_q <= '0; candidate_ok_q <= 1'b0;
        groups_q <= '0; full_q <= '0; full_service_q <= '0; tail_service_q <= '0;
        service_q <= '0; cost_q <= '0; best_cost_q <= '0; base_cost_q <= '0;
        valid_o <= 1'b0; evaluated_o <= 1'b0; subcode_o <= '0; topology_o <= '0;
        baseline_cycles_o <= '0; selected_cycles_o <= '0;
        cache_valid_q <= 1'b0; cache_hit_o <= 1'b0;
      end else if (flush_i || !enable_i || (!CacheEn && cancel_i)) begin
        state_q <= IDLE;
        base_q <= '0; candidate_q <= '0; best_q <= '0;
        m_q <= '0; n_q <= '0; k_q <= '0; fmt_q <= '0; group_q <= '0;
        index_q <= '0; best_index_q <= '0; candidate_ok_q <= 1'b0;
        groups_q <= '0; full_q <= '0; full_service_q <= '0; tail_service_q <= '0;
        service_q <= '0; cost_q <= '0; best_cost_q <= '0; base_cost_q <= '0;
        valid_o <= 1'b0; evaluated_o <= 1'b0; subcode_o <= '0; topology_o <= '0;
        baseline_cycles_o <= '0; selected_cycles_o <= '0;
        cache_valid_q <= 1'b0; cache_hit_o <= 1'b0;
      end else if (cancel_i) begin
        state_q <= IDLE;
        valid_o <= 1'b0; evaluated_o <= 1'b0; cache_hit_o <= 1'b0;
        subcode_o <= '0; topology_o <= '0;
        baseline_cycles_o <= '0; selected_cycles_o <= '0;
      end else if (testmode_i || state_q != IDLE || start_i) begin
        case (state_q)
          IDLE: if (start_i) begin
            valid_o <= !eligible;
            evaluated_o <= 1'b0;
            subcode_o <= '0;
            topology_o <= baseline_i;
            baseline_cycles_o <= '0;
            selected_cycles_o <= '0;
            cache_hit_o <= 1'b0;
            cache_valid_q <= cache_match;
            if (cache_match) begin
              state_q <= CACHED;
            end else if (eligible) begin
              base_q <= baseline_i;
              m_q <= m_i[8:0]; n_q <= n_i[8:0]; k_q <= k_i[8:0]; fmt_q <= numfmt_i;
              group_q <= input_group;
              index_q <= '0;
              best_index_q <= '0;
              best_q <= baseline_i;
              state_q <= SHAPE;
            end
          end
          SHAPE: state_q <= PREP;
          PREP: begin
            candidate_q <= candidate_d;
            candidate_ok_q <= candidate_ok;
            full_q <= k_q >> d;
            state_q <= COST;
          end
          // r30: the three products share one 32-cycle shift-add multiplier
          // (g6lc_ai_mul_seq, 20 FO4). Each product state launches on entry
          // and advances on done; SHAPE adds one cycle per candidate, so the
          // fixed 32-cycle model charge does NOT hide the actual evaluator
          // latency from the steering decision.
          COST: begin
            full_service_q <= full_service;
            tail_service_q <= tail_service;
            if (mul_done) begin
              groups_q <= 17'(mul_product);
              state_q <= SERVICE;
            end
          end
          SERVICE: if (mul_done) begin
            service_q <= 15'(25'(mul_product) + 25'(tail_service_q));
            state_q <= TOTAL;
          end
          TOTAL: if (mul_done) begin
            cost_q <= 28'(mul_product);
            state_q <= RANK;
          end
          RANK: state_q <= COMPARE;
          COMPARE: begin
            if (index_q == 0) begin
              best_cost_q <= cost_q;
              base_cost_q <= cost_q;
            end else if (better) begin
              best_cost_q <= cost_q;
              best_index_q <= index_q;
              best_q <= candidate_q;
            end
            if (index_q == 7) begin
              topology_o <= choose ? winner : base_q;
              subcode_o <= choose ? winner_index : 3'd0;
              baseline_cycles_o <= 32'(base_cost_q);
              selected_cycles_o <= (choose ? 32'(winner_cost) + SwitchCycles : 32'(base_cost_q)) + EvaluationCycles;
              if (CacheEn) begin
                best_q <= choose ? winner : base_q;
                best_index_q <= choose ? winner_index : 3'd0;
                best_cost_q <= choose ? winner_cost : base_cost_q;
                cache_valid_q <= 1'b1;
              end
              evaluated_o <= 1'b1;
              valid_o <= 1'b1;
              state_q <= IDLE;
            end else begin
              index_q <= index_q + 3'd1;
              state_q <= SHAPE;
            end
          end
          CACHED: begin
            if (CacheEn) begin
              topology_o <= best_q;
              subcode_o <= best_index_q;
              baseline_cycles_o <= 32'(base_cost_q);
              selected_cycles_o <= 32'(best_cost_q) + (best_index_q != 0 ? SwitchCycles : 0) + 1;
              evaluated_o <= 1'b1;
              valid_o <= 1'b1;
              cache_hit_o <= 1'b1;
            end
            state_q <= IDLE;
          end
          default: state_q <= IDLE;
        endcase
      end
    end
  end else begin : gen_off
    assign ready_o = 1'b0;
    assign busy_o = 1'b0;
    assign valid_o = 1'b0;
    assign evaluated_o = 1'b0;
    assign cache_hit_o = 1'b0;
    assign subcode_o = '0;
    assign topology_o = '0;
    assign baseline_cycles_o = '0;
    assign selected_cycles_o = '0;
  end
endmodule
