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

    assign accept = valid_i && ready_o;
    assign format_known = policy_format_known(numfmt_i);
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
    assign topology_o = policy_topology(code_o, metadata_q.numfmt,
        metadata_q.m, metadata_q.n, metadata_q.k, metadata_q.balance,
        ReadBytesPerCycle, MinGain16ths, FormatSlotsLog2);

    // pragma translate_off
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
