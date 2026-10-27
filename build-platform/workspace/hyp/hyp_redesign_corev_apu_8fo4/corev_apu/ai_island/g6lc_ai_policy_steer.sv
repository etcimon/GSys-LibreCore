// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

module g6lc_ai_policy_steer
  import g6lc_ai_policy_pkg::*;
#(
    parameter config_pkg::ai_cfg_t AiCfg = config_pkg::AiCfgOff,
    parameter int unsigned HoldWork = 3,
    parameter int unsigned DwellWork = 4,
    parameter int unsigned CooldownWork = 2,
    parameter int unsigned BankBits = 4,
    parameter int unsigned ReadBytesPerCycle = 128,
    parameter int unsigned MinGain16ths = 2,
    parameter logic [31:0] FormatSlotsLog2 = 32'h67788098,
    parameter int unsigned SubcodeMinSavingsCycles = 2,
    parameter int unsigned SubcodeSwitchCycles = 2,
    parameter logic [31:0] SubcodeFormatStepCycles = 32'h11111111,
    parameter logic [31:0] SubcodeMinReductionLog2 = 32'h00000000,
    parameter logic [23:0] SubcodeGroupShapeLog2 = 24'h4420ca
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic testmode_i,
    input  logic enable_i,
    input  logic flush_i,
    input  logic valid_i,
    input  logic batch_first_i,
    input  logic batch_last_i,
    input  logic [15:0] m_i,
    input  logic [15:0] n_i,
    input  logic [15:0] k_i,
    input  logic [2:0] opcode_i,
    input  logic [1:0] balance_i,
    input  logic [2:0] numfmt_i,
    input  logic [255:0] sample_i,
    input  logic sample_valid_i,
    input  logic exact_zero_i,
    input  logic [63:0] next_addr_i,
    input  logic next_addr_valid_i,
    input  logic mispredict_i,
    output logic ready_o,
    output logic work_valid_o,
    output policy_code_t code_o,
    output policy_code_t next_code_o,
    output policy_t policy_o,
    output policy_t next_policy_o,
    output logic warm_valid_o,
    output logic [63:0] warm_addr_o,
    output logic [BankBits-1:0] warm_bank_o,
    output logic residual_skip_o,
    output logic eval_o,
    output logic commit_o,
    output logic hold_o,
    output logic predict_hit_o,
    output logic predict_miss_o,
    output logic [2:0] numfmt_o,
    output policy_topology_t topology_o,
    output logic subcode_valid_o, subcode_evaluated_o, subcode_cache_hit_o,
    output logic [2:0] subcode_o,
    output policy_topology_t subcode_topology_o,
    output logic [31:0] subcode_baseline_cycles_o, subcode_selected_cycles_o
);

  // pragma translate_off
  initial begin
    assert (!AiCfg.PolicyBenefitEn || AiCfg.PolicyCodecEn)
      else $fatal(1, "Policy benefit steering requires PolicyCodecEn");
    assert (!AiCfg.PolicySubcodeEn || AiCfg.PolicyBenefitEn)
      else $fatal(1, "Policy subcode requires benefit steering");
    assert (!AiCfg.PolicySubcodeCacheEn || AiCfg.PolicySubcodeEn)
      else $fatal(1, "Policy subcode cache requires subcode evaluation");
    assert (ReadBytesPerCycle > 0 && ReadBytesPerCycle <= 4096 &&
        (ReadBytesPerCycle & (ReadBytesPerCycle - 1)) == 0)
      else $fatal(1, "Policy SRAM read service must be a power of two in [1,4096]");
    assert (MinGain16ths > 0 && MinGain16ths < 16)
      else $fatal(1, "Policy gain threshold must be in [1,15]");
    for (int i = 0; i < 8; i++) begin
      if (i != config_pkg::AI_FMT_SP24)
        assert (FormatSlotsLog2[i*4 +: 4] >= 4'd1 && FormatSlotsLog2[i*4 +: 4] <= 4'd9)
          else $fatal(1, "Policy format service budget must have log2 in [1,9]");
    end
  end
  // pragma translate_on

  if (AiCfg.PolicyCodecEn && AiCfg.PolicyBenefitEn) begin : gen_steering
    typedef struct packed {
      logic seen;
      logic last;
      logic [15:0] m, n;
      logic [15:0] k;
      logic [2:0] numfmt;
      logic [1:0] balance;
    } metadata_t;

    metadata_t metadata_q, metadata_d;
    logic accept, format_known, new_format;
    logic [63:0] normalized_sample;

    

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_policy_steer  region=6839  makespan=6.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: metadata_q  ready_cycle=1  ready_fo4=6.500  OpenSTA: report_timing -from clk_i -to metadata_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     metadata_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node24068 c=3.50 slack=3.00 */
//     /* node24069 c=6.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign accept = valid_i && ready_o;
    assign format_known = policy_format_known(numfmt_i);
    // A format change starts a new batch: the codec's hysteresis is fitted per
    // format, so carrying votes across a switch would commit a code that was
    // only ever measured for the previous element width.
    assign new_format = metadata_q.seen && metadata_q.numfmt != numfmt_i;
    assign normalized_sample = policy_normalize_sample(sample_i, numfmt_i);

    g6lc_ai_policy_codec #(
      .AiCfg(AiCfg), .HoldWork(HoldWork), .DwellWork(DwellWork),
      .CooldownWork(CooldownWork), .BankBits(BankBits)
    ) i_codec (
      .clk_i, .rst_ni, .testmode_i, .enable_i, .flush_i, .valid_i,
      .batch_first_i(batch_first_i || new_format), .batch_last_i,
      .m_i, .n_i, .k_i, .opcode_i(format_known ? opcode_i : 3'd7), .balance_i,
      .sample_i(normalized_sample), .sample_valid_i(sample_valid_i && format_known),
      .exact_zero_i(exact_zero_i && policy_integer_format(numfmt_i)),
      .next_addr_i, .next_addr_valid_i(next_addr_valid_i && format_known), .mispredict_i,
      .ready_o, .work_valid_o, .code_o, .next_code_o, .policy_o, .next_policy_o,
      .warm_valid_o, .warm_addr_o, .warm_bank_o, .residual_skip_o,
      .eval_o, .commit_o, .hold_o, .predict_hit_o, .predict_miss_o
    );

    always_comb begin
      metadata_d = metadata_q;
      if (accept) begin
        metadata_d.seen = 1'b1;
        metadata_d.last = batch_last_i;
        metadata_d.m = m_i;
        metadata_d.n = n_i;
        metadata_d.k = k_i;
        metadata_d.numfmt = numfmt_i;
        metadata_d.balance = balance_i;
      end
      if (flush_i || !enable_i) metadata_d = '0;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) metadata_q <= '0;
      else if (testmode_i || accept || flush_i || !enable_i) metadata_q <= metadata_d;
    end

    g6lc_ai_policy_subcode #(
      .Enabled(AiCfg.PolicySubcodeEn), .CacheEn(AiCfg.PolicySubcodeCacheEn),
      .ReadBytesPerCycle(ReadBytesPerCycle),
      .MinSavingsCycles(SubcodeMinSavingsCycles), .SwitchCycles(SubcodeSwitchCycles),
      .FormatStepCycles(SubcodeFormatStepCycles),
      .FormatMinReductionLog2(SubcodeMinReductionLog2),
      .GroupShapeLog2(SubcodeGroupShapeLog2)
    ) i_subcode (
      .clk_i, .rst_ni, .testmode_i, .enable_i,
      .flush_i(flush_i || (accept && (!AiCfg.PolicySubcodeCacheEn ||
          batch_first_i || new_format || metadata_q.last))),
      .cancel_i(accept), .start_i(work_valid_o),
      .code_i(code_o), .numfmt_i(metadata_q.numfmt),
      .m_i(metadata_q.m), .n_i(metadata_q.n), .k_i(metadata_q.k),
      .baseline_i(topology_o), .ready_o(), .busy_o(),
      .valid_o(subcode_valid_o), .evaluated_o(subcode_evaluated_o), .cache_hit_o(subcode_cache_hit_o),
      .subcode_o, .topology_o(subcode_topology_o),
      .baseline_cycles_o(subcode_baseline_cycles_o),
      .selected_cycles_o(subcode_selected_cycles_o)
    );

    assign numfmt_o = metadata_q.numfmt;
    // r7 R1 / F1: the topology evaluator registers its result one cycle
    // after code_o/metadata_q settle; both inputs are already flops, so
    // topology_q is a clean flop-to-flop hop at the module boundary.
    // r8 A134: policy_topology as a multi-cycle evaluator. The one-shot
    // function's serial arithmetic (aligned_log2 x4 + reuse_gain x2 +
    // balanced-row/col chain + base_step mul) is split over three stages
    // on registered inputs; inputs (code_o, metadata_q) are already flops
    // and stable across a job, so the stages run every cycle.
    policy_topology_t topology_q;
    // Stage 1: validity + slot/format selects + the four aligned_log2 +
    // active_k -- each leaf in its own comb so no ff composes serial deps.
    logic        t1_known_q, t1_valid_q;
    logic [2:0]  t1_slots_q, t1_elem_bits_q, t1_fmt_q;
    logic [2:0]  t1_row_log_q, t1_col_log_q, t1_row_max_q, t1_col_max_q;
    logic [3:0]  t1_gain_q;
    logic [15:0] t1_m_q, t1_n_q, t1_k_q, t1_active_k_q;
    logic [1:0]  t1_balance_q;
    policy_code_t t1_code_q;
    logic [2:0]  s1_row_cap_w, s1_col_cap_w;
    logic [2:0]  s1_row_log_w, s1_col_log_w, s1_row_max_w, s1_col_max_w;
    logic [3:0]  s1_gain_w;
    logic [2:0]  s1_slots_w;

    always_comb begin
      s1_row_cap_w = '0; s1_col_cap_w = '0;
      unique case (code_o)
        POLICY_BULK, POLICY_ATTENTION, POLICY_SPARSE: begin
          s1_row_cap_w = 3'd2; s1_col_cap_w = 3'd2;
        end
        POLICY_WIDE:  begin s1_row_cap_w = 3'd1; s1_col_cap_w = 3'd3; end
        POLICY_TALL:  begin s1_row_cap_w = 3'd3; s1_col_cap_w = 3'd1; end
        POLICY_DECODE: s1_col_cap_w = 3'd4;
        POLICY_ROUTED: begin s1_row_cap_w = 3'd1; s1_col_cap_w = 3'd2; end
        default: ;
      endcase
    end
    always_comb s1_row_log_w = policy_aligned_log2(metadata_q.m, s1_row_cap_w);
    always_comb s1_col_log_w = policy_aligned_log2(metadata_q.n, s1_col_cap_w);
    always_comb s1_row_max_w = policy_aligned_log2(metadata_q.m, 3'd4);
    always_comb s1_col_max_w = policy_aligned_log2(metadata_q.n, 3'd4);
    always_comb s1_gain_w    = policy_reuse_gain(s1_row_log_w, s1_col_log_w);
    always_comb s1_slots_w   = FormatSlotsLog2[metadata_q.numfmt*4 +: 4];

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        t1_known_q <= 1'b0; t1_valid_q <= 1'b0;
        t1_slots_q <= '0; t1_elem_bits_q <= '0; t1_fmt_q <= '0;
        t1_row_log_q <= '0; t1_col_log_q <= '0; t1_row_max_q <= '0; t1_col_max_q <= '0;
        t1_gain_q <= '0;
        t1_m_q <= '0; t1_n_q <= '0; t1_k_q <= '0; t1_active_k_q <= '0;
        t1_balance_q <= '0; t1_code_q <= policy_code_t'('0);
      end else begin
        t1_fmt_q       <= metadata_q.numfmt;
        t1_slots_q     <= s1_slots_w;
        t1_elem_bits_q <= policy_element_bits_log2(metadata_q.numfmt);
        t1_known_q     <= policy_format_known(metadata_q.numfmt);
        t1_valid_q     <= policy_format_known(metadata_q.numfmt) &&
            metadata_q.m != 16'd0 && metadata_q.n != 16'd0 && metadata_q.k != 16'd0 &&
            s1_slots_w != 4'd0 && s1_slots_w <= 4'd9;
        t1_row_log_q   <= s1_row_log_w;
        t1_col_log_q   <= s1_col_log_w;
        t1_row_max_q   <= s1_row_max_w;
        t1_col_max_q   <= s1_col_max_w;
        t1_gain_q      <= s1_gain_w;
        t1_m_q         <= metadata_q.m;
        t1_n_q         <= metadata_q.n;
        t1_k_q         <= metadata_q.k;
        t1_active_k_q  <= (metadata_q.k < (16'd1 << s1_slots_w))
                          ? metadata_q.k : (16'd1 << s1_slots_w);
        t1_balance_q   <= metadata_q.balance;
        t1_code_q      <= code_o;
      end
    end
    // Stage 2: slot clamps + group/balanced evaluation -- leaf wires in
    // combs, thin ff for the register group.
    logic [2:0]  t2_slots_q, t2_fmt_q, t2_elem_bits_q;
    logic        t2_known_q, t2_valid_q;
    logic [2:0]  t2_row_log_q, t2_col_log_q;
    logic [3:0]  t2_gain_q;
    logic [15:0] t2_m_q, t2_n_q, t2_k_q, t2_active_k_q;
    logic [1:0]  t2_balance_q;
    policy_code_t t2_code_q;
    logic [2:0]  s2_row_log_w, s2_col_log_w;
    logic [3:0]  s2_gain_w;

    always_comb begin
      automatic logic [2:0] row_log, col_log, balanced_row, balanced_col;
      automatic logic [3:0] group_log, gain, balanced_gain;
      row_log = t1_row_log_q; col_log = t1_col_log_q;
      if (int'(row_log) > int'(t1_slots_q)) row_log = 3'(t1_slots_q);
      if (int'(row_log) + int'(col_log) > int'(t1_slots_q))
        col_log = 3'(t1_slots_q - {1'b0, row_log});
      gain = policy_reuse_gain(row_log, col_log);
      group_log = {1'b0, t1_row_max_q} + {1'b0, t1_col_max_q};
      if (group_log > 4'd4) group_log = 4'd4;
      if (group_log > t1_slots_q) group_log = t1_slots_q;
      balanced_row = 3'(group_log >> 1);
      if (balanced_row > t1_row_max_q) balanced_row = t1_row_max_q;
      balanced_col = 3'(group_log - {1'b0, balanced_row});
      if (balanced_col > t1_col_max_q) begin
        balanced_col = t1_col_max_q;
        balanced_row = 3'(group_log - {1'b0, balanced_col});
      end
      balanced_gain = policy_reuse_gain(balanced_row, balanced_col);
      if (balanced_gain > gain || (balanced_gain == gain &&
          int'(group_log) > int'(row_log) + int'(col_log))) begin
        row_log = balanced_row;
        col_log = balanced_col;
        gain    = balanced_gain;
      end
      s2_row_log_w = row_log;
      s2_col_log_w = col_log;
      s2_gain_w    = gain;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        t2_slots_q <= '0; t2_fmt_q <= '0; t2_elem_bits_q <= '0;
        t2_known_q <= 1'b0; t2_valid_q <= 1'b0;
        t2_row_log_q <= '0; t2_col_log_q <= '0; t2_gain_q <= '0;
        t2_m_q <= '0; t2_n_q <= '0; t2_k_q <= '0; t2_active_k_q <= '0;
        t2_balance_q <= '0; t2_code_q <= policy_code_t'('0);
      end else begin
        t2_slots_q      <= t1_slots_q;
        t2_fmt_q        <= t1_fmt_q;
        t2_elem_bits_q  <= t1_elem_bits_q;
        t2_known_q      <= t1_known_q;
        t2_valid_q      <= t1_valid_q;
        t2_row_log_q    <= s2_row_log_w;
        t2_col_log_q    <= s2_col_log_w;
        t2_gain_q       <= s2_gain_w;
        t2_m_q          <= t1_m_q;
        t2_n_q          <= t1_n_q;
        t2_k_q          <= t1_k_q;
        t2_active_k_q   <= t1_active_k_q;
        t2_balance_q    <= t1_balance_q;
        t2_code_q       <= t1_code_q;
      end
    end
    // Stage 3: base_step + underfilled + balance_ok + apply latch.
    policy_topology_t topology_d;
    always_comb begin
      automatic logic [63:0] base_step;
      automatic logic        underfilled, balance_ok;
      topology_d = '0;
      if (t2_valid_q) begin
        topology_d.valid          = 1'b1;
        topology_d.slots_log2     = t2_slots_q;
        topology_d.reduction_log2 = t2_slots_q;
        topology_d.element_bits_log2 = t2_elem_bits_q;
        base_step  = (64'(t2_m_q) + 64'(t2_n_q)) * policy_rowbytes(t2_active_k_q, t2_fmt_q);
        underfilled = t2_k_q <= (16'd1 << (int'(t2_slots_q) - 1));
        balance_ok  = t2_balance_q != 2'd0 || (t2_code_q == POLICY_DECODE);
        if (t2_code_q != POLICY_MOVEMENT && balance_ok &&
            (t2_row_log_q != 3'd0 || t2_col_log_q != 3'd0) &&
            (t2_m_q >= 16'd8 || t2_n_q >= 16'd8) &&
            int'(t2_gain_q) >= MinGain16ths &&
            (underfilled || base_step >= 64'(ReadBytesPerCycle))) begin
          topology_d.apply      = 1'b1;
          topology_d.rows_log2  = t2_row_log_q;
          topology_d.cols_log2  = t2_col_log_q;
          topology_d.reduction_log2 =
              4'(int'(t2_slots_q) - int'(t2_row_log_q) - int'(t2_col_log_q));
          topology_d.gain_16ths = t2_gain_q;
        end
      end
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) topology_q <= '0;
      else         topology_q <= topology_d;
    end
    assign topology_o = topology_q;

    // pragma translate_off
    // r7 R1: ready_o stays combinational (codec-coupled accept path) --
    // the seam invariant is that a start lands only while ready is live.
    assert property (@(posedge clk_i) disable iff (!rst_ni) accept |-> ready_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        !policy_integer_format(numfmt_o) |-> !residual_skip_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        !policy_format_known(numfmt_o) |-> !warm_valid_o && !topology_o.valid);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        topology_o.apply |-> topology_o.valid && int'(topology_o.gain_16ths) >= MinGain16ths);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        topology_o.valid |-> int'(topology_o.rows_log2) + int'(topology_o.cols_log2) +
            int'(topology_o.reduction_log2) == int'(topology_o.slots_log2));
    // pragma translate_on
  end else begin : gen_off
    assign ready_o = 1'b0;
    assign work_valid_o = 1'b0;
    assign code_o = POLICY_BULK;
    assign next_code_o = POLICY_BULK;
    assign policy_o = policy_decode(POLICY_BULK);
    assign next_policy_o = policy_decode(POLICY_BULK);
    assign warm_valid_o = 1'b0;
    assign warm_addr_o = '0;
    assign warm_bank_o = '0;
    assign residual_skip_o = 1'b0;
    assign eval_o = 1'b0;
    assign commit_o = 1'b0;
    assign hold_o = 1'b0;
    assign predict_hit_o = 1'b0;
    assign predict_miss_o = 1'b0;
    assign numfmt_o = '0;
    assign topology_o = '0;
    assign subcode_valid_o = 1'b0;
    assign subcode_evaluated_o = 1'b0;
    assign subcode_cache_hit_o = 1'b0;
    assign subcode_o = '0;
    assign subcode_topology_o = '0;
    assign subcode_baseline_cycles_o = '0;
    assign subcode_selected_cycles_o = '0;
  end
endmodule
