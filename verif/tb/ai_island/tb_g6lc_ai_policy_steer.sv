// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon

module tb_g6lc_ai_policy_steer_instance #(
  parameter bit CodecEn = 1'b0,
  parameter bit BenefitEn = 1'b0,
  parameter int unsigned ReadBytesPerCycle = 128,
  parameter int unsigned MinGain16ths = 2,
  parameter logic [31:0] FormatSlotsLog2 = 32'h67788098
) (
  input logic clk_i, rst_ni, testmode_i, enable_i, flush_i, valid_i,
  input logic batch_first_i, batch_last_i,
  input logic [15:0] m_i, n_i, k_i,
  input logic [2:0] opcode_i, numfmt_i,
  input logic [1:0] balance_i,
  input logic [255:0] sample_i,
  input logic sample_valid_i, exact_zero_i,
  input logic [63:0] next_addr_i,
  input logic next_addr_valid_i, mispredict_i,
  output logic ready_o, work_valid_o,
  output logic [2:0] code_o, next_code_o, numfmt_o,
  output logic [16:0] policy_o, next_policy_o,
  output g6lc_ai_policy_pkg::policy_topology_t topology_o,
  output logic warm_valid_o,
  output logic [63:0] warm_addr_o,
  output logic [3:0] warm_bank_o,
  output logic residual_skip_o, eval_o, commit_o, hold_o, predict_hit_o, predict_miss_o
);
  function automatic config_pkg::ai_cfg_t make_cfg();
    config_pkg::ai_cfg_t cfg = CodecEn ? cva6_config_pkg::ai_cfg : config_pkg::AiCfgOff;
    cfg.PolicyCodecEn = CodecEn;
    cfg.PolicyBenefitEn = BenefitEn;
    return cfg;
  endfunction
  localparam config_pkg::ai_cfg_t TestCfg = make_cfg();

  g6lc_ai_policy_steer #(
    .AiCfg(TestCfg), .ReadBytesPerCycle(ReadBytesPerCycle),
    .MinGain16ths(MinGain16ths), .FormatSlotsLog2(FormatSlotsLog2)
  ) i_steer (
    .code_o(code_o), .next_code_o(next_code_o),
    .policy_o(policy_o), .next_policy_o(next_policy_o), .topology_o(topology_o), .*
  );

`ifdef FORMAL
  logic formal_past_valid = 1'b0;
  logic [15:0] fm_q, fn_q, fk_q;
  logic [2:0] ff_q;
  logic [1:0] fb_q;
  logic fseen_q;
  int unsigned baseline_k, baseline_bytes;
  logic state_nonzero;
  assign state_nonzero = |{ready_o, work_valid_o, code_o, next_code_o, numfmt_o,
      (policy_o ^ 17'h03332), (next_policy_o ^ 17'h03332), topology_o,
      warm_valid_o, warm_addr_o, warm_bank_o, residual_skip_o, eval_o,
      commit_o, hold_o, predict_hit_o, predict_miss_o};
  always_comb begin
    baseline_k = 32'(fk_q);
    if (baseline_k > (32'd1 << topology_o.slots_log2))
      baseline_k = 32'd1 << topology_o.slots_log2;
    baseline_bytes = 2 * ((baseline_k * (32'd1 << topology_o.element_bits_log2) + 7) / 8);
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fm_q <= '0;
      fn_q <= '0;
      fk_q <= '0;
      ff_q <= '0;
      fb_q <= '0;
      fseen_q <= 1'b0;
    end else if (flush_i || !enable_i) begin
      fm_q <= '0;
      fn_q <= '0;
      fk_q <= '0;
      ff_q <= '0;
      fb_q <= '0;
      fseen_q <= 1'b0;
    end else if (valid_i && ready_o) begin
      fm_q <= m_i;
      fn_q <= n_i;
      fk_q <= k_i;
      ff_q <= numfmt_i;
      fb_q <= balance_i;
      fseen_q <= 1'b1;
    end
  end
  always_ff @(posedge clk_i) begin
    formal_past_valid <= 1'b1;
    if (!formal_past_valid) assume (!rst_ni);
    if (!(CodecEn && BenefitEn)) assert (!state_nonzero);
    else if (formal_past_valid) begin
      assert (ready_o == (enable_i && !flush_i));
      assert (numfmt_o == ff_q);
      assert (topology_o == g6lc_ai_policy_pkg::policy_topology(
          g6lc_ai_policy_pkg::policy_code_t'(code_o), ff_q, fm_q, fn_q, fk_q, fb_q,
          ReadBytesPerCycle, MinGain16ths, FormatSlotsLog2));
      assert (topology_o.valid == (fseen_q && ff_q != 3'd2 &&
          fm_q != '0 && fn_q != '0 && fk_q != '0));
      assert (!residual_skip_o || (work_valid_o && numfmt_o <= 3'd1));
      assert (!(warm_valid_o || residual_skip_o) || numfmt_o != 3'd2);
      assert (!(predict_hit_o && predict_miss_o));
      assert (!(commit_o && hold_o));
      if (topology_o.apply) begin
        assert (topology_o.valid && code_o != 3'd7);
        assert (fb_q != 2'd0 || (code_o == 3'd3 &&
            (32'(fk_q) <= ((32'd1 << topology_o.slots_log2) >> 1) ||
             baseline_bytes >= 4 * ReadBytesPerCycle)));
        assert (32'(topology_o.rows_log2) + 32'(topology_o.cols_log2) <= 4);
        assert (fm_q >= 16'd8 || fn_q >= 16'd8);
        assert (32'(topology_o.rows_log2) + 32'(topology_o.cols_log2) +
            32'(topology_o.reduction_log2) == 32'(topology_o.slots_log2));
        assert (topology_o.rows_log2 != '0 || topology_o.cols_log2 != '0);
        assert (32'(topology_o.gain_16ths) >= MinGain16ths);
        assert ((32'(fm_q) & ((32'd1 << topology_o.rows_log2) - 1)) == 0);
        assert ((32'(fn_q) & ((32'd1 << topology_o.cols_log2) - 1)) == 0);
        assert (32'(fk_q) <= ((32'd1 << topology_o.slots_log2) >> 1) ||
            baseline_bytes > ReadBytesPerCycle);
      end else begin
        assert (topology_o.rows_log2 == '0 && topology_o.cols_log2 == '0);
        assert (topology_o.gain_16ths == '0);
      end
      if (work_valid_o && $past(rst_ni && valid_i && ready_o)) begin
        if ($past(fseen_q && numfmt_i != ff_q)) begin
          assert (commit_o && eval_o && !hold_o);
          assert (!predict_hit_o && !predict_miss_o);
        end
        if (residual_skip_o) assert ($past(exact_zero_i));
      end
      if (rst_ni && $past(rst_ni && enable_i && !flush_i && !valid_i)) begin
        assert (numfmt_o == $past(numfmt_o));
        assert (topology_o == $past(topology_o));
        assert (code_o == $past(code_o));
      end
    end
  end
`endif
endmodule

module tb_g6lc_ai_policy_steer_on #(
  parameter int unsigned ReadBytesPerCycle = 128,
  parameter int unsigned MinGain16ths = 2,
  parameter logic [31:0] FormatSlotsLog2 = 32'h67788098
) (
  input logic clk_i, rst_ni, testmode_i, enable_i, flush_i, valid_i,
  input logic batch_first_i, batch_last_i,
  input logic [15:0] m_i, n_i, k_i,
  input logic [2:0] opcode_i, numfmt_i,
  input logic [1:0] balance_i,
  input logic [255:0] sample_i,
  input logic sample_valid_i, exact_zero_i,
  input logic [63:0] next_addr_i,
  input logic next_addr_valid_i, mispredict_i,
  output logic ready_o, work_valid_o,
  output logic [2:0] code_o, next_code_o, numfmt_o,
  output logic [16:0] policy_o, next_policy_o,
  output g6lc_ai_policy_pkg::policy_topology_t topology_o,
  output logic warm_valid_o,
  output logic [63:0] warm_addr_o,
  output logic [3:0] warm_bank_o,
  output logic residual_skip_o, eval_o, commit_o, hold_o, predict_hit_o, predict_miss_o
);
  tb_g6lc_ai_policy_steer_instance #(
    .CodecEn(1'b1), .BenefitEn(1'b1), .ReadBytesPerCycle(ReadBytesPerCycle),
    .MinGain16ths(MinGain16ths), .FormatSlotsLog2(FormatSlotsLog2)
  ) i_on (.*);
endmodule

module tb_g6lc_ai_policy_steer #(
  parameter int unsigned ReadBytesPerCycle = 128,
  parameter int unsigned MinGain16ths = 2,
  parameter logic [31:0] FormatSlotsLog2 = 32'h67788098
) (
  input logic clk_i, rst_ni, testmode_i, enable_i, flush_i, valid_i,
  input logic batch_first_i, batch_last_i,
  input logic [15:0] m_i, n_i, k_i,
  input logic [2:0] opcode_i, numfmt_i,
  input logic [1:0] balance_i,
  input logic [255:0] sample_i,
  input logic sample_valid_i, exact_zero_i,
  input logic [63:0] next_addr_i,
  input logic next_addr_valid_i, mispredict_i,
  output logic ready_o, work_valid_o,
  output logic [2:0] code_o, next_code_o, numfmt_o,
  output logic [16:0] policy_o, next_policy_o,
  output g6lc_ai_policy_pkg::policy_topology_t topology_o,
  output logic warm_valid_o,
  output logic [63:0] warm_addr_o,
  output logic [3:0] warm_bank_o,
  output logic residual_skip_o, eval_o, commit_o, hold_o, predict_hit_o, predict_miss_o,
  output logic disabled_nonzero_o,
  input logic [2:0] probe_code_i,
  input logic [31:0] probe_read_bytes_i, probe_min_gain_i, probe_slots_i,
  output logic [63:0] normalized_o,
  output g6lc_ai_policy_pkg::policy_topology_t probe_topology_o,
  input logic resource_start_i, resource_decision_i,
  input logic [15:0] resource_m_i, resource_n_i, resource_k_i,
  input logic [2:0] resource_fmt_i, resource_rows_i, resource_cols_i,
  input logic [3:0] resource_reduction_i,
  output logic resource_busy_o, resource_done_o, resource_rejected_o,
  output logic [63:0] resource_cycles_o, resource_compute_o, resource_external_o,
  output logic [63:0] resource_macs_o, resource_reads_o, resource_operands_o,
  output logic [63:0] resource_c_o, resource_steps_o
);
  tb_g6lc_ai_policy_steer_on #(
    .ReadBytesPerCycle(ReadBytesPerCycle), .MinGain16ths(MinGain16ths),
    .FormatSlotsLog2(FormatSlotsLog2)
  ) i_enabled (.*);

  logic [1:0] off_nonzero;
  for (genvar i = 0; i < 2; i++) begin : gen_disabled
    logic off_ready, off_work, off_warm, off_skip, off_eval, off_commit, off_hold, off_hit, off_miss;
    logic [2:0] off_code, off_next, off_fmt;
    logic [16:0] off_policy, off_next_policy;
    g6lc_ai_policy_pkg::policy_topology_t off_topology;
    logic [63:0] off_addr;
    logic [3:0] off_bank;
    tb_g6lc_ai_policy_steer_instance #(.CodecEn(i == 1)) i_off (
      .clk_i, .rst_ni, .testmode_i, .enable_i, .flush_i, .valid_i,
      .batch_first_i, .batch_last_i, .m_i, .n_i, .k_i, .opcode_i, .numfmt_i,
      .balance_i, .sample_i, .sample_valid_i, .exact_zero_i, .next_addr_i,
      .next_addr_valid_i, .mispredict_i,
      .ready_o(off_ready), .work_valid_o(off_work), .code_o(off_code),
      .next_code_o(off_next), .numfmt_o(off_fmt), .policy_o(off_policy),
      .next_policy_o(off_next_policy), .topology_o(off_topology), .warm_valid_o(off_warm),
      .warm_addr_o(off_addr), .warm_bank_o(off_bank), .residual_skip_o(off_skip),
      .eval_o(off_eval), .commit_o(off_commit), .hold_o(off_hold),
      .predict_hit_o(off_hit), .predict_miss_o(off_miss)
    );
    assign off_nonzero[i] = |{off_ready, off_work, off_code, off_next, off_fmt,
        (off_policy ^ 17'h03332), (off_next_policy ^ 17'h03332), off_topology,
        off_warm, off_addr, off_bank, off_skip, off_eval, off_commit, off_hold, off_hit, off_miss};
  end
  assign disabled_nonzero_o = |off_nonzero;
  assign normalized_o = g6lc_ai_policy_pkg::policy_normalize_sample(sample_i, numfmt_i);
  assign probe_topology_o = g6lc_ai_policy_pkg::policy_topology(
      g6lc_ai_policy_pkg::policy_code_t'(probe_code_i), numfmt_i, m_i, n_i, k_i,
      balance_i, probe_read_bytes_i, probe_min_gain_i, probe_slots_i);

  tb_g6lc_ai_policy_resource #(.SramReadBytes(ReadBytesPerCycle)) i_resource (
    .clk_i, .rst_ni, .start_i(resource_start_i), .decision_i(resource_decision_i),
    .m_i(resource_m_i), .n_i(resource_n_i), .k_i(resource_k_i), .numfmt_i(resource_fmt_i),
    .rows_log2_i(resource_rows_i), .cols_log2_i(resource_cols_i),
    .reduction_log2_i(resource_reduction_i), .busy_o(resource_busy_o),
    .done_o(resource_done_o), .rejected_o(resource_rejected_o),
    .cycles_o(resource_cycles_o), .compute_cycles_o(resource_compute_o),
    .external_cycles_o(resource_external_o), .useful_macs_o(resource_macs_o),
    .read_bytes_o(resource_reads_o), .operand_bytes_o(resource_operands_o),
    .c_bytes_o(resource_c_o), .steps_o(resource_steps_o)
  );
endmodule
