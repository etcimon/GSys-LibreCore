// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon

module tb_g6lc_ai_policy_instance #(
  parameter bit CodecEn = 1'b0,
  parameter int unsigned HoldWork = 3,
  parameter int unsigned DwellWork = 4,
  parameter int unsigned CooldownWork = 2,
  parameter int unsigned BankBits = 4
) (
  input logic clk_i,
  input logic rst_ni,
  input logic testmode_i,
  input logic enable_i,
  input logic flush_i,
  input logic valid_i,
  input logic batch_first_i,
  input logic batch_last_i,
  input logic [15:0] m_i,
  input logic [15:0] n_i,
  input logic [15:0] k_i,
  input logic [2:0] opcode_i,
  input logic [1:0] balance_i,
  input logic [63:0] sample_i,
  input logic sample_valid_i,
  input logic exact_zero_i,
  input logic [63:0] next_addr_i,
  input logic next_addr_valid_i,
  input logic mispredict_i,
  output logic ready_o,
  output logic work_valid_o,
  output logic [2:0] code_o,
  output logic [2:0] next_code_o,
  output logic [16:0] policy_o,
  output logic [16:0] next_policy_o,
  output logic warm_valid_o,
  output logic [63:0] warm_addr_o,
  output logic [BankBits-1:0] warm_bank_o,
  output logic residual_skip_o,
  output logic eval_o,
  output logic commit_o,
  output logic hold_o,
  output logic predict_hit_o,
  output logic predict_miss_o
);
  function automatic config_pkg::ai_cfg_t make_cfg();
    config_pkg::ai_cfg_t cfg = CodecEn ? cva6_config_pkg::ai_cfg : config_pkg::AiCfgOff;
    cfg.PolicyCodecEn = CodecEn;
    return cfg;
  endfunction

  localparam config_pkg::ai_cfg_t TestCfg = make_cfg();

  g6lc_ai_policy_codec #(
    .AiCfg(TestCfg),
    .HoldWork(HoldWork),
    .DwellWork(DwellWork),
    .CooldownWork(CooldownWork),
    .BankBits(BankBits)
  ) i_codec (
    .code_o(code_o), .next_code_o(next_code_o),
    .policy_o(policy_o), .next_policy_o(next_policy_o), .*
  );

`ifdef FORMAL
  logic formal_past_valid = 1'b0;
  logic formal_state_nonzero;
  assign formal_state_nonzero = |{work_valid_o, code_o, next_code_o,
    (policy_o ^ 17'h03332), (next_policy_o ^ 17'h03332),
    warm_valid_o, warm_addr_o, warm_bank_o, residual_skip_o,
    eval_o, commit_o, hold_o, predict_hit_o, predict_miss_o};

  always_ff @(posedge clk_i) begin
    formal_past_valid <= 1'b1;
    if (!formal_past_valid) assume (!rst_ni);
    if (CodecEn) begin
      assert (ready_o == (enable_i && !flush_i));
      assert (!(predict_hit_o && predict_miss_o));
      assert (!(commit_o && hold_o));
      assert ((commit_o || hold_o) == work_valid_o);
      assert (!(eval_o || warm_valid_o || residual_skip_o ||
          predict_hit_o || predict_miss_o) || work_valid_o);
      if (formal_past_valid) begin
        assert (work_valid_o == (rst_ni &&
            $past(rst_ni && valid_i && enable_i && !flush_i)));
        if (residual_skip_o) begin
          assert (work_valid_o && policy_o[2]);
          assert ($past(exact_zero_i && m_i != 16'd0 && n_i != 16'd0 && k_i != 16'd0));
        end
        if (rst_ni && $past(rst_ni && !valid_i && enable_i && !flush_i)) begin
          assert (code_o == $past(code_o));
          assert (next_code_o == $past(next_code_o));
        end
        if (code_o != $past(code_o))
          assert (!rst_ni || $past(!rst_ni || (valid_i && ready_o) || flush_i || !enable_i));
        if (!rst_ni || $past(!rst_ni || flush_i || !enable_i))
          assert (!formal_state_nonzero);
      end
    end else begin
      assert (!ready_o && !formal_state_nonzero);
    end
  end
`endif
endmodule

module tb_g6lc_ai_policy #(
  parameter int unsigned HoldWork = 3,
  parameter int unsigned DwellWork = 4,
  parameter int unsigned CooldownWork = 2,
  parameter int unsigned BankBits = 4
) (
  input logic clk_i,
  input logic rst_ni,
  input logic testmode_i,
  input logic enable_i,
  input logic flush_i,
  input logic valid_i,
  input logic batch_first_i,
  input logic batch_last_i,
  input logic [15:0] m_i,
  input logic [15:0] n_i,
  input logic [15:0] k_i,
  input logic [2:0] opcode_i,
  input logic [1:0] balance_i,
  input logic [63:0] sample_i,
  input logic sample_valid_i,
  input logic exact_zero_i,
  input logic [63:0] next_addr_i,
  input logic next_addr_valid_i,
  input logic mispredict_i,
  output logic ready_o,
  output logic work_valid_o,
  output logic [2:0] code_o,
  output logic [2:0] next_code_o,
  output logic [16:0] policy_o,
  output logic [16:0] next_policy_o,
  output logic warm_valid_o,
  output logic [63:0] warm_addr_o,
  output logic [BankBits-1:0] warm_bank_o,
  output logic residual_skip_o,
  output logic eval_o,
  output logic commit_o,
  output logic hold_o,
  output logic predict_hit_o,
  output logic predict_miss_o,
  output logic disabled_nonzero_o
);
  logic off_ready, off_work_valid, off_warm_valid, off_skip;
  logic off_eval, off_commit, off_hold, off_hit, off_miss;
  logic [2:0] off_code, off_next_code;
  logic [16:0] off_policy, off_next_policy;
  logic [63:0] off_warm_addr;
  logic [BankBits-1:0] off_warm_bank;

  tb_g6lc_ai_policy_instance #(
    .CodecEn(1'b1), .HoldWork(HoldWork), .DwellWork(DwellWork),
    .CooldownWork(CooldownWork), .BankBits(BankBits)
  ) i_enabled (.*);

  tb_g6lc_ai_policy_instance #(
    .HoldWork(HoldWork), .DwellWork(DwellWork),
    .CooldownWork(CooldownWork), .BankBits(BankBits)
  ) i_disabled (
    .clk_i, .rst_ni, .testmode_i, .enable_i, .flush_i, .valid_i,
    .batch_first_i, .batch_last_i, .m_i, .n_i, .k_i, .opcode_i, .balance_i,
    .sample_i, .sample_valid_i, .exact_zero_i, .next_addr_i,
    .next_addr_valid_i, .mispredict_i,
    .ready_o(off_ready), .work_valid_o(off_work_valid),
    .code_o(off_code), .next_code_o(off_next_code),
    .policy_o(off_policy), .next_policy_o(off_next_policy),
    .warm_valid_o(off_warm_valid), .warm_addr_o(off_warm_addr),
    .warm_bank_o(off_warm_bank), .residual_skip_o(off_skip),
    .eval_o(off_eval), .commit_o(off_commit), .hold_o(off_hold),
    .predict_hit_o(off_hit), .predict_miss_o(off_miss)
  );

  assign disabled_nonzero_o = |{off_ready, off_work_valid, off_code, off_next_code,
    (off_policy ^ 17'h03332), (off_next_policy ^ 17'h03332),
    off_warm_valid, off_warm_addr, off_warm_bank,
    off_skip, off_eval, off_commit, off_hold, off_hit, off_miss};
endmodule
