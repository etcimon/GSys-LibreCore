// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon

module tb_g6lc_ai_policy_subcode #(
  parameter bit CacheEn = 1'b0,
  parameter int unsigned ReadBytesPerCycle = 128,
  parameter int unsigned MinSavingsCycles = 2,
  parameter int unsigned SwitchCycles = 2,
  parameter logic [31:0] FormatStepCycles = 32'h11111111,
  parameter logic [31:0] FormatMinReductionLog2 = 32'h00000000,
  parameter logic [23:0] GroupShapeLog2 = 24'h4420ca
) (
  input logic clk_i, rst_ni, testmode_i, enable_i, flush_i, cancel_i, start_i,
  input logic [2:0] code_i, numfmt_i,
  input logic [15:0] m_i, n_i, k_i,
  input logic [1:0] balance_i,
  input logic baseline_override_i,
  input g6lc_ai_policy_pkg::policy_topology_t baseline_i,
  output g6lc_ai_policy_pkg::policy_topology_t baseline_o,
  output logic ready_o, busy_o, valid_o, evaluated_o,
  output logic [2:0] subcode_o,
  output g6lc_ai_policy_pkg::policy_topology_t topology_o,
  output logic [31:0] baseline_cycles_o, selected_cycles_o,
  output logic disabled_nonzero_o, cache_enabled_o, cache_hit_o,
  output logic [31:0] read_bytes_o, min_savings_o, switch_cycles_o,
  output logic [31:0] format_steps_o, format_min_reduction_o,
  output logic [23:0] group_shapes_o,
  input logic steer_enable_i, steer_flush_i, steer_valid_i,
  input logic steer_batch_first_i, steer_batch_last_i,
  input logic [15:0] steer_m_i, steer_n_i, steer_k_i,
  input logic [2:0] steer_opcode_i, steer_numfmt_i,
  input logic [1:0] steer_balance_i,
  input logic [255:0] steer_sample_i,
  input logic steer_sample_valid_i, steer_exact_zero_i,
  input logic [63:0] steer_next_addr_i,
  input logic steer_next_addr_valid_i, steer_mispredict_i,
  output logic steer_ready_o, steer_work_valid_o,
  output logic [2:0] steer_code_o, steer_numfmt_o,
  output g6lc_ai_policy_pkg::policy_topology_t steer_topology_o,
  output logic steer_legacy_mismatch_o, steer_disabled_nonzero_o,
  output logic steer_subcode_valid_o, steer_subcode_evaluated_o, steer_subcode_cache_hit_o,
  output logic [2:0] steer_subcode_o,
  output g6lc_ai_policy_pkg::policy_topology_t steer_subcode_topology_o,
  output logic [31:0] steer_baseline_cycles_o, steer_selected_cycles_o
);
  import g6lc_ai_policy_pkg::*;

  assign baseline_o = baseline_override_i ? baseline_i : policy_topology(
      policy_code_t'(code_i), numfmt_i, m_i, n_i, k_i, balance_i,
      ReadBytesPerCycle, 2, 32'h67788098);
  assign cache_enabled_o = CacheEn;
  assign read_bytes_o = ReadBytesPerCycle;
  assign min_savings_o = MinSavingsCycles;
  assign switch_cycles_o = SwitchCycles;
  assign format_steps_o = FormatStepCycles;
  assign format_min_reduction_o = FormatMinReductionLog2;
  assign group_shapes_o = GroupShapeLog2;

  initial begin : va_heuristic_checks
    config_pkg::ai_cfg_t cfg;
    va_turbo_request_t r;
    va_turbo_plan_t p;
    int unsigned bytes_per_row, expected_groups, checks;
    cfg = config_pkg::AiCfgOff;
    cfg.VaTurboEn = 1'b1;
    cfg.MatrixEn = 1'b1;
    cfg.Queues = 1;
    cfg.PolicyCodecEn = 1'b1;
    cfg.PolicyBenefitEn = 1'b1;
    cfg.PolicySubcodeEn = 1'b1;
    cfg.IslandFpEn = 1'b1;
    r = '0;
    r.enable = 1'b1;
    r.level = 4'd15;
    r.bank = 2'd1;
    r.subcode = 3'd5;
    r.code = POLICY_BULK;
    r.m = 16'd16;
    r.n = 16'd16;
    r.regular_layout = 1'b1;
    r.ready_jobs = 9'd16;
    r.free_accumulators = 9'd16;
    r.bank_groups = 9'd16;
    r.qualified_mask = '1;
    r.window_valid = 1'b1;
    checks = 0;
    for (int fmt = 0; fmt < 8; fmt++) begin
      r.numfmt = 3'(fmt);
      for (int k = 1; k <= 256; k++) begin
        r.k = 16'(k);
        bytes_per_row = (k * (fmt == 1 ? 4 : fmt == 5 || fmt == 6 ? 16 : fmt == 7 ? 32 : 8) + 7) / 8;
        for (int bank_cap = 0; bank_cap <= 8; bank_cap++) begin
          r.bank_groups = 9'(bank_cap);
          p = va_turbo_select(cfg, r, 64, 8, 8, 32'hffffffff);
          expected_groups = 1;
          for (int g = 2; g <= 8; g *= 2)
            if (fmt != 2 && bytes_per_row <= 64/g && 8 <= 64/g && g <= bank_cap)
              expected_groups = g;
          assert (p.apply == (expected_groups > 1) &&
                  (1 << p.groups_log2) == expected_groups)
            else $fatal(1, "VA group capacity fmt=%0d k=%0d banks=%0d", fmt, k, bank_cap);
          if (p.apply)
            assert (p.reuse_a && !p.reuse_b && !p.convert && p.target_numfmt == r.numfmt)
              else $fatal(1, "VA exact grouping changed arithmetic");
          checks++;
        end
      end
    end
    r.numfmt = 3'd1; r.k = 16'd17; r.bank_groups = 9'd8;
    r.code = POLICY_TALL; r.m = 16'd3; r.n = 16'd1;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.groups_log2 == 1 && p.tail_outputs == 1 &&
            p.split_rows && p.reuse_b && !p.reuse_a)
      else $fatal(1, "VA tall odd-tail grouping");
    r.bank = 1; r.subcode = 3; r.independent_jobs = 1;
    for (int jobs = 0; jobs <= 8; jobs++) begin
      r.ready_jobs = 9'(jobs);
      r.free_accumulators = 9'd3;
      p = va_turbo_select(cfg, r, 64, 8, 8, '1);
      assert (p.apply == (jobs >= 2) && p.groups_log2 == (jobs >= 2 ? 1 : 0))
        else $fatal(1, "VA independent-job/accumulator bound");
      checks++;
    end
    r.m = 16; r.n = 16; r.k = 16; r.code = POLICY_BULK;
    r.numfmt = 7; r.bank = 0; r.subcode = 4;
    r.free_accumulators = 8; r.ready_jobs = 8; r.bank_groups = 8;
    r.range_safe = 1; r.accuracy_valid = 1; r.error_bound_q4 = 2; r.level = 2;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.convert && p.target_numfmt == 5 && p.groups_log2 == 1 && p.row_bytes == 32)
      else $fatal(1, "VA FP16 bound equality");
    r.error_bound_q4 = 3;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply && p.target_numfmt == 7 && !p.convert) else $fatal(1, "VA excessive error");
    r.error_bound_q4 = 1; r.accuracy_valid = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA missing accuracy contract");
    r.accuracy_valid = 1; r.range_safe = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA unqualified range");
    r.range_safe = 1; r.subcode = 5;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.target_numfmt == 6) else $fatal(1, "VA BF16 recipe");
    r.subcode = 6; r.scale_valid = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA INT8 missing scale");
    r.scale_valid = 1;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.target_numfmt == 0 && p.groups_log2 == 2)
      else $fatal(1, "VA INT8 recipe");
    r.subcode = 2; r.exact_zero_proven = 1;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA floating zero skip forbidden");
    r.numfmt = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.skip_products) else $fatal(1, "VA integer-zero recipe");
    r.exact_zero_proven = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA sparse residue is not proof");
    r.bank = 2; r.subcode = 0; r.reuse_a_valid = 1;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.reuse_a && !p.reuse_b) else $fatal(1, "VA resident operand reuse");
    r.reuse_a_valid = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA stale reuse");
    r.bank = 1; r.subcode = 1;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.groups_log2 == 1) else $fatal(1, "VA paired output");
    r.subcode = 2;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.groups_log2 == 2) else $fatal(1, "VA four outputs");
    p = va_turbo_select(cfg, r, 64, 8, 8, '0);
    assert (!p.apply && p.eligible && p.recipe == 0) else $fatal(1, "VA absent consumer gate");
    r.qualified_mask = '0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply && p.eligible) else $fatal(1, "VA approval gate");
    r.qualified_mask = '1; r.window_valid = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply && p.eligible) else $fatal(1, "VA stale opportunity window");
    r.window_valid = 1; r.level = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply && !p.eligible) else $fatal(1, "VA level zero");
    r.level = 2; cfg.VaTurboEn = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply && !p.eligible) else $fatal(1, "VA compile gate");
    cfg.VaTurboEn = 1; cfg.Queues = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply && !p.eligible) else $fatal(1, "VA queue prerequisite");
    cfg.Queues = 1;
    for (int id = 0; id < 32; id++) begin
      r.bank = 2'(id >> 3); r.subcode = 3'(id);
      p = va_turbo_select(cfg, r, 64, 8, 8, '1);
      if (!(id inside {0, 2, 4, 5, 6, 9, 10, 11, 13, 16}))
        assert (!p.supported && !p.apply && p.recipe == 0)
          else $fatal(1, "VA reserved recipe applied: %0d", id);
      checks++;
    end
    r.bank = 1; r.subcode = 5;
    r.k = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA zero K");
    r.k = 257;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA oversized K");
    r.k = 16; r.regular_layout = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA irregular layout");
    r.regular_layout = 1;
    p = va_turbo_select(cfg, r, 63, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA invalid provisioning");
    $display("VA_HEURISTICS PASS sweep_checks=%0d formats=8 k=1..256 banks=0..8 reserved=fail_closed", checks);
  end

  g6lc_ai_policy_subcode #(
    .Enabled(1'b1), .CacheEn(CacheEn), .ReadBytesPerCycle(ReadBytesPerCycle),
    .MinSavingsCycles(MinSavingsCycles), .SwitchCycles(SwitchCycles),
    .FormatStepCycles(FormatStepCycles),
    .FormatMinReductionLog2(FormatMinReductionLog2), .GroupShapeLog2(GroupShapeLog2)
  ) i_enabled (
    .clk_i, .rst_ni, .testmode_i, .enable_i, .flush_i, .cancel_i, .start_i,
    .code_i(policy_code_t'(code_i)), .numfmt_i, .m_i, .n_i, .k_i,
    .baseline_i(baseline_o), .ready_o, .busy_o, .valid_o, .subcode_o,
    .evaluated_o, .cache_hit_o, .topology_o, .baseline_cycles_o, .selected_cycles_o
  );

  logic off_ready, off_busy, off_valid, off_evaluated, off_hit;
  logic [2:0] off_subcode;
  policy_topology_t off_topology;
  logic [31:0] off_baseline_cycles, off_selected_cycles;
  g6lc_ai_policy_subcode #(
    .Enabled(1'b0), .ReadBytesPerCycle(ReadBytesPerCycle),
    .MinSavingsCycles(MinSavingsCycles), .SwitchCycles(SwitchCycles),
    .FormatStepCycles(FormatStepCycles),
    .FormatMinReductionLog2(FormatMinReductionLog2), .GroupShapeLog2(GroupShapeLog2)
  ) i_disabled (
    .clk_i, .rst_ni, .testmode_i, .enable_i, .flush_i, .cancel_i, .start_i,
    .code_i(policy_code_t'(code_i)), .numfmt_i, .m_i, .n_i, .k_i,
    .baseline_i(baseline_o), .ready_o(off_ready), .busy_o(off_busy),
    .valid_o(off_valid), .subcode_o(off_subcode), .evaluated_o(off_evaluated), .cache_hit_o(off_hit),
    .topology_o(off_topology), .baseline_cycles_o(off_baseline_cycles),
    .selected_cycles_o(off_selected_cycles)
  );
  assign disabled_nonzero_o = |{off_ready, off_busy, off_valid, off_evaluated, off_hit,
      off_subcode, off_topology, off_baseline_cycles, off_selected_cycles};

  function automatic config_pkg::ai_cfg_t steer_cfg(input bit subcode);
    config_pkg::ai_cfg_t cfg = config_pkg::AiCfgOff;
    cfg.MatrixEn = 1'b1;
    cfg.Queues = 1;
    cfg.PolicyCodecEn = 1'b1;
    cfg.PolicyBenefitEn = 1'b1;
    cfg.PolicySubcodeEn = subcode;
    cfg.PolicySubcodeCacheEn = subcode && CacheEn;
    return cfg;
  endfunction

  logic [142:0] steer_legacy [2];
  logic [1:0] s_ready, s_work, s_valid, s_evaluated, s_hit;
  logic [2:0] s_code [2], s_fmt [2], s_subcode [2];
  policy_topology_t s_topology [2], s_selected [2];
  logic [31:0] s_baseline_cycles [2], s_selected_cycles [2];
  for (genvar i = 0; i < 2; i++) begin : gen_steer
    policy_code_t next_code;
    policy_t policy, next_policy;
    logic warm, skip, evaluated, commit, hold, hit, miss;
    logic [63:0] warm_addr;
    logic [3:0] warm_bank;
    g6lc_ai_policy_steer #(
      .AiCfg(steer_cfg(i == 1)), .ReadBytesPerCycle(ReadBytesPerCycle),
      .SubcodeMinSavingsCycles(MinSavingsCycles), .SubcodeSwitchCycles(SwitchCycles),
      .SubcodeFormatStepCycles(FormatStepCycles),
      .SubcodeMinReductionLog2(FormatMinReductionLog2),
      .SubcodeGroupShapeLog2(GroupShapeLog2)
    ) i_steer (
      .clk_i, .rst_ni, .testmode_i, .enable_i(steer_enable_i), .flush_i(steer_flush_i),
      .valid_i(steer_valid_i), .batch_first_i(steer_batch_first_i),
      .batch_last_i(steer_batch_last_i), .m_i(steer_m_i), .n_i(steer_n_i), .k_i(steer_k_i),
      .opcode_i(steer_opcode_i), .numfmt_i(steer_numfmt_i), .balance_i(steer_balance_i),
      .sample_i(steer_sample_i), .sample_valid_i(steer_sample_valid_i),
      .exact_zero_i(steer_exact_zero_i), .next_addr_i(steer_next_addr_i),
      .next_addr_valid_i(steer_next_addr_valid_i), .mispredict_i(steer_mispredict_i),
      .ready_o(s_ready[i]), .work_valid_o(s_work[i]), .code_o(s_code[i]), .next_code_o(next_code),
      .policy_o(policy), .next_policy_o(next_policy), .warm_valid_o(warm), .warm_addr_o(warm_addr),
      .warm_bank_o(warm_bank), .residual_skip_o(skip), .eval_o(evaluated), .commit_o(commit),
      .hold_o(hold), .predict_hit_o(hit), .predict_miss_o(miss), .numfmt_o(s_fmt[i]),
      .topology_o(s_topology[i]), .subcode_valid_o(s_valid[i]), .subcode_evaluated_o(s_evaluated[i]),
      .subcode_cache_hit_o(s_hit[i]), .subcode_o(s_subcode[i]), .subcode_topology_o(s_selected[i]),
      .subcode_baseline_cycles_o(s_baseline_cycles[i]), .subcode_selected_cycles_o(s_selected_cycles[i])
    );
    assign steer_legacy[i] = {s_ready[i], s_work[i], s_code[i], next_code, policy, next_policy,
        warm, warm_addr, warm_bank, skip, evaluated, commit, hold, hit, miss, s_fmt[i], s_topology[i]};
  end
  assign steer_legacy_mismatch_o = steer_legacy[0] != steer_legacy[1];
  assign steer_disabled_nonzero_o = |{s_valid[0], s_evaluated[0], s_hit[0], s_subcode[0], s_selected[0],
      s_baseline_cycles[0], s_selected_cycles[0]};
  assign steer_ready_o = s_ready[1];
  assign steer_work_valid_o = s_work[1];
  assign steer_code_o = s_code[1];
  assign steer_numfmt_o = s_fmt[1];
  assign steer_topology_o = s_topology[1];
  assign steer_subcode_valid_o = s_valid[1];
  assign steer_subcode_evaluated_o = s_evaluated[1];
  assign steer_subcode_cache_hit_o = s_hit[1];
  assign steer_subcode_o = s_subcode[1];
  assign steer_subcode_topology_o = s_selected[1];
  assign steer_baseline_cycles_o = s_baseline_cycles[1];
  assign steer_selected_cycles_o = s_selected_cycles[1];

  // pragma translate_off
  // Pin policy_dot_lanes_log2 / policy_lane_groups_log2 to the measured
  // provisioning basis (ai-gemm-codec-basis-20260906T165957Z-718434a9a9d1):
  // best lanes were 8 for INT4, 16 for INT8/FP8, 32 for FP16/BF16/FP32.  If
  // someone retunes these functions without new measured evidence, this fails.
  //
  // These expectations are k=16 values.  The underlying quantity is
  // fmt_row_bytes(k) (the operand row in bytes), which only equals twice the
  // element width at k=16; the basis could not measure other k because MaxDim
  // caps it.  If a k sweep lands, these assertions must be re-derived rather
  // than relaxed.
  initial begin
    assert (policy_dot_lanes_log2(3'(config_pkg::AI_FMT_INT4)) == 3'd3)
      else $fatal(1, "INT4 measured optimum is 8 lanes");
    assert (policy_dot_lanes_log2(3'(config_pkg::AI_FMT_INT)) == 3'd4)
      else $fatal(1, "INT8 measured optimum is 16 lanes");
    assert (policy_dot_lanes_log2(3'(config_pkg::AI_FMT_FP8_E4M3)) == 3'd4)
      else $fatal(1, "FP8 E4M3 measured optimum is 16 lanes");
    assert (policy_dot_lanes_log2(3'(config_pkg::AI_FMT_FP8_E5M2)) == 3'd4)
      else $fatal(1, "FP8 E5M2 measured optimum is 16 lanes");
    assert (policy_dot_lanes_log2(3'(config_pkg::AI_FMT_FP16)) == 3'd5)
      else $fatal(1, "FP16 measured optimum is 32 lanes");
    assert (policy_dot_lanes_log2(3'(config_pkg::AI_FMT_BF16)) == 3'd5)
      else $fatal(1, "BF16 measured optimum is 32 lanes");
    // FP32 wants 64, measured: it wins at 64 lanes for every shape class in the
    // 8/32/64-lane run, up to +320.0% on 16x16 against the 8-lane baseline.
    assert (policy_dot_lanes_log2(3'(config_pkg::AI_FMT_FP32)) == 3'd6)
      else $fatal(1, "FP32 measured optimum is 64 lanes");
    // Unsupported format must gang everything and split nothing.
    assert (policy_dot_lanes_log2(3'(config_pkg::AI_FMT_SP24)) == 3'd6 &&
            policy_lane_groups_log2(3'(config_pkg::AI_FMT_SP24), 3'd5) == 3'd0)
      else $fatal(1, "unknown format must fail closed to a single group");
    // A 32-lane array (log2 5) splits 4 ways for INT4, 2 for INT8/FP8 and not
    // at all for the 16/32-bit formats.
    assert (policy_lane_groups_log2(3'(config_pkg::AI_FMT_INT4), 3'd5) == 3'd2)
      else $fatal(1, "INT4 leaves 32 lanes idle enough for four groups");
    assert (policy_lane_groups_log2(3'(config_pkg::AI_FMT_INT), 3'd5) == 3'd1)
      else $fatal(1, "INT8 splits a 32-lane array in two");
    assert (policy_lane_groups_log2(3'(config_pkg::AI_FMT_FP16), 3'd5) == 3'd0 &&
            policy_lane_groups_log2(3'(config_pkg::AI_FMT_FP32), 3'd5) == 3'd0)
      else $fatal(1, "16/32-bit formats gang a 32-lane array");
    // Never split below the shipped 8-lane provisioning.
    for (int unsigned fmt = 0; fmt < 8; fmt++)
      assert (policy_lane_groups_log2(3'(fmt), 3'd3) == 3'd0)
        else $fatal(1, "an 8-lane array must never be split");
  end
  // pragma translate_on
endmodule

module tb_g6lc_ai_va_turbo_plan #(
  parameter bit Enabled = 1'b0
) (
  input g6lc_ai_policy_pkg::va_turbo_request_t request_i,
  input logic [31:0] consumer_mask_i,
  output g6lc_ai_policy_pkg::va_turbo_plan_t plan_o
);
  function automatic config_pkg::ai_cfg_t va_cfg();
    config_pkg::ai_cfg_t cfg = config_pkg::AiCfgOff;
    cfg.MatrixEn = 1'b1;
    cfg.Queues = 1;
    cfg.PolicyCodecEn = Enabled;
    cfg.PolicyBenefitEn = Enabled;
    cfg.PolicySubcodeEn = Enabled;
    cfg.IslandFpEn = Enabled;
    cfg.VaTurboEn = Enabled;
    return cfg;
  endfunction
  if (Enabled) begin : gen_on
    assign plan_o = g6lc_ai_policy_pkg::va_turbo_select(va_cfg(), request_i, 64, 8, 8, consumer_mask_i);
  end else begin : gen_off
    assign plan_o = '0;
  end
endmodule

module tb_g6lc_ai_va_turbo_plan_on (
  input g6lc_ai_policy_pkg::va_turbo_request_t request_i,
  input logic [31:0] consumer_mask_i,
  output g6lc_ai_policy_pkg::va_turbo_plan_t plan_o
);
  tb_g6lc_ai_va_turbo_plan #(.Enabled(1'b1)) i_on (.*);
endmodule

module tb_g6lc_ai_policy_subcode_instance #(
  parameter bit Enabled = 1'b0,
  parameter bit CacheEn = 1'b0
) (
  input logic clk_i, rst_ni, testmode_i, enable_i, flush_i, start_i,
  input g6lc_ai_policy_pkg::policy_code_t code_i,
  input logic [2:0] numfmt_i,
  input logic [15:0] m_i, n_i, k_i,
  input g6lc_ai_policy_pkg::policy_topology_t baseline_i,
  output logic ready_o, busy_o, valid_o, evaluated_o,
  output logic [2:0] subcode_o,
  output g6lc_ai_policy_pkg::policy_topology_t topology_o,
  output logic [31:0] baseline_cycles_o, selected_cycles_o
);
  g6lc_ai_policy_subcode #(.Enabled(Enabled), .CacheEn(CacheEn)) i_subcode (
    .cancel_i(1'b0), .cache_hit_o(), .*
  );
endmodule

module tb_g6lc_ai_policy_subcode_on (
  input logic clk_i, rst_ni, testmode_i, enable_i, flush_i, start_i,
  input g6lc_ai_policy_pkg::policy_code_t code_i,
  input logic [2:0] numfmt_i,
  input logic [15:0] m_i, n_i, k_i,
  input g6lc_ai_policy_pkg::policy_topology_t baseline_i,
  output logic ready_o, busy_o, valid_o, evaluated_o,
  output logic [2:0] subcode_o,
  output g6lc_ai_policy_pkg::policy_topology_t topology_o,
  output logic [31:0] baseline_cycles_o, selected_cycles_o
);
  tb_g6lc_ai_policy_subcode_instance #(.Enabled(1'b1)) i_on (.*);
endmodule

module tb_g6lc_ai_policy_subcode_cache_on (
  input logic clk_i, rst_ni, testmode_i, enable_i, flush_i, cancel_i, start_i,
  input g6lc_ai_policy_pkg::policy_code_t code_i,
  input logic [2:0] numfmt_i,
  input logic [15:0] m_i, n_i, k_i,
  input g6lc_ai_policy_pkg::policy_topology_t baseline_i,
  output logic ready_o, busy_o, valid_o, evaluated_o, cache_hit_o,
  output logic [2:0] subcode_o,
  output g6lc_ai_policy_pkg::policy_topology_t topology_o,
  output logic [31:0] baseline_cycles_o, selected_cycles_o
);
  g6lc_ai_policy_subcode #(.Enabled(1'b1), .CacheEn(1'b1)) i_cache (.*);
endmodule

`ifdef FORMAL
module tb_g6lc_ai_policy_subcode_cache_control (
  input logic clk_i, rst_ni, testmode_i, enable_i, flush_i, cancel_i, start_i, key_i,
  output logic ready_o, busy_o, valid_o, evaluated_o, cache_hit_o
);
  import g6lc_ai_policy_pkg::*;
  localparam policy_topology_t Base = {1'b1, 1'b0, 3'd0, 3'd0, 4'd9, 4'd9, 3'd2, 4'd0};
  logic [2:0] subcode;
  policy_topology_t topology;
  logic [31:0] baseline_cycles, selected_cycles;
  g6lc_ai_policy_subcode #(.Enabled(1'b1), .CacheEn(1'b1)) i_control (
    .clk_i, .rst_ni, .testmode_i, .enable_i, .flush_i, .cancel_i, .start_i,
    .code_i(POLICY_BULK), .numfmt_i(3'd1), .m_i(16'd16), .n_i(16'd16),
    .k_i(key_i ? 16'd18 : 16'd17), .baseline_i(Base),
    .ready_o, .busy_o, .valid_o, .evaluated_o, .cache_hit_o,
    .subcode_o(subcode), .topology_o(topology), .baseline_cycles_o(baseline_cycles),
    .selected_cycles_o(selected_cycles)
  );
  logic past_valid = 1'b0;
  logic [5:0] remaining_q;
  logic result_q, hit_q, pending_hit_q, completed_q, key_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      remaining_q <= '0; result_q <= 1'b0; hit_q <= 1'b0;
      pending_hit_q <= 1'b0; completed_q <= 1'b0; key_q <= 1'b0;
    end else if (flush_i || !enable_i) begin
      remaining_q <= '0; result_q <= 1'b0; hit_q <= 1'b0;
      pending_hit_q <= 1'b0; completed_q <= 1'b0; key_q <= 1'b0;
    end else if (cancel_i) begin
      remaining_q <= '0; result_q <= 1'b0; hit_q <= 1'b0;
      pending_hit_q <= 1'b0;
    end else if (remaining_q != 0) begin
      remaining_q <= remaining_q - 6'd1;
      if (remaining_q == 1) begin
        result_q <= 1'b1; hit_q <= pending_hit_q; completed_q <= 1'b1;
      end
    end else if (start_i) begin
      remaining_q <= completed_q && key_i == key_q ? 6'd1 : 6'd32;
      pending_hit_q <= completed_q && key_i == key_q;
      completed_q <= completed_q && key_i == key_q;
      key_q <= key_i; result_q <= 1'b0; hit_q <= 1'b0;
    end
  end
  always_ff @(posedge clk_i) begin
    past_valid <= 1'b1;
    if (!past_valid) assume (!rst_ni);
    if (past_valid && rst_ni) begin
      assert (busy_o == (remaining_q != 0));
      assert (ready_o == (enable_i && !flush_i && !cancel_i && remaining_q == 0));
      assert (valid_o == result_q);
      assert (evaluated_o == result_q);
      assert (cache_hit_o == hit_q);
    end
  end
endmodule

module tb_g6lc_ai_policy_subcode_control (
  input logic clk_i, rst_ni, testmode_i, enable_i, flush_i, start_i,
  output logic ready_o, busy_o, valid_o, evaluated_o
);
  import g6lc_ai_policy_pkg::*;
  localparam policy_topology_t Base = {1'b1, 1'b0, 3'd0, 3'd0, 4'd9, 4'd9, 3'd2, 4'd0};
  logic [2:0] subcode;
  policy_topology_t topology;
  logic [31:0] baseline_cycles, selected_cycles;
  g6lc_ai_policy_subcode #(.Enabled(1'b1)) i_control (
    .clk_i, .rst_ni, .testmode_i, .enable_i, .flush_i, .start_i, .cancel_i(1'b0), .cache_hit_o(),
    .code_i(POLICY_BULK), .numfmt_i(3'd1), .m_i(16'd16), .n_i(16'd16), .k_i(16'd17),
    .baseline_i(Base), .ready_o, .busy_o, .valid_o, .evaluated_o,
    .subcode_o(subcode), .topology_o(topology), .baseline_cycles_o(baseline_cycles),
    .selected_cycles_o(selected_cycles)
  );
  logic past_valid = 1'b0;
  logic [5:0] remaining_q;
  logic result_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin remaining_q <= '0; result_q <= 1'b0; end
    else if (flush_i || !enable_i) begin remaining_q <= '0; result_q <= 1'b0; end
    else if (remaining_q != 0) begin
      remaining_q <= remaining_q - 6'd1;
      if (remaining_q == 1) result_q <= 1'b1;
    end else if (start_i) begin remaining_q <= 6'd32; result_q <= 1'b0; end
  end
  always_ff @(posedge clk_i) begin
    past_valid <= 1'b1;
    if (!past_valid) assume (!rst_ni);
    if (past_valid && rst_ni) begin
      assert (busy_o == (remaining_q != 0));
      assert (ready_o == (enable_i && !flush_i && remaining_q == 0));
      assert (valid_o == result_q);
      assert (evaluated_o == result_q);
    end
  end
endmodule
`endif
