// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// hyp8 r17: request ownership / ordered codec / parallel topology / publication.
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
    input logic clk_i, rst_ni, testmode_i, enable_i, flush_i, valid_i,
    input logic batch_first_i, batch_last_i,
    input logic [15:0] m_i, n_i, k_i,
    input logic [2:0] opcode_i,
    input logic [1:0] balance_i,
    input logic [2:0] numfmt_i,
    input logic [255:0] sample_i,
    input logic sample_valid_i, exact_zero_i,
    input logic [63:0] next_addr_i,
    input logic next_addr_valid_i, mispredict_i,
    output logic ready_o, work_valid_o,
    output policy_code_t code_o, next_code_o,
    output policy_t policy_o, next_policy_o,
    output logic warm_valid_o,
    output logic [63:0] warm_addr_o,
    output logic [BankBits-1:0] warm_bank_o,
    output logic residual_skip_o, eval_o, commit_o, hold_o,
    output logic predict_hit_o, predict_miss_o,
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
        assert (FormatSlotsLog2[i*4 +: 4] >= 1 && FormatSlotsLog2[i*4 +: 4] <= 9)
          else $fatal(1, "Policy format service budget must have log2 in [1,9]");
    end
  end
  // pragma translate_on

  if (AiCfg.PolicyCodecEn && AiCfg.PolicyBenefitEn) begin : gen_steering
    typedef struct packed {
      logic first, last;
      logic [15:0] m, n, k;
      logic [2:0] fmt, opcode;
      logic [1:0] balance;
      logic [63:0] sample, next_addr;
      logic sample_valid, exact_zero, next_addr_valid, mispredict;
    } request_t;
    typedef struct packed {
      policy_code_t code, next_code;
      policy_t policy, next_policy;
      logic warm, skip, evaluated, committed, held, hit, miss;
      logic [63:0] warm_addr;
      logic [BankBits-1:0] warm_bank;
    } result_t;
    request_t request_q;
    result_t codec_result, codec_q, published_q;
    logic accept, cancel, busy_q, launch_q, codec_ready, codec_valid;
    logic codec_seen_q, topology_seen_q, topology_valid, publish, work_q;
    logic seen_q, last_q, new_format;
    logic [2:0] previous_fmt_q;
    logic [15:0] published_m_q, published_n_q, published_k_q;
    logic [2:0] published_fmt_q;
    policy_topology_t candidates [8], selected_topology, published_topology_q;

    assign cancel = flush_i || !enable_i;
    assign ready_o = !cancel && !busy_q && codec_ready;
    assign accept = valid_i && ready_o;
    assign new_format = seen_q && previous_fmt_q != numfmt_i;
    assign publish = busy_q && codec_seen_q && topology_seen_q && !cancel;

    // One outstanding request is the ownership token: all request fields stay
    // stable until both branches complete. The island gates admission with ready.
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        busy_q <= 1'b0; launch_q <= 1'b0;
        codec_seen_q <= 1'b0; topology_seen_q <= 1'b0;
        seen_q <= 1'b0; last_q <= 1'b0; previous_fmt_q <= '0;
      end else if (cancel) begin
        busy_q <= 1'b0; launch_q <= 1'b0;
        codec_seen_q <= 1'b0; topology_seen_q <= 1'b0;
        seen_q <= 1'b0; last_q <= 1'b0; previous_fmt_q <= '0;
      end else begin
        launch_q <= accept;
        if (accept) begin
          busy_q <= 1'b1; codec_seen_q <= 1'b0; topology_seen_q <= 1'b0;
          seen_q <= 1'b1; last_q <= batch_last_i; previous_fmt_q <= numfmt_i;
        end else if (publish) begin
          busy_q <= 1'b0; codec_seen_q <= 1'b0; topology_seen_q <= 1'b0;
        end else begin
          if (codec_valid && busy_q) codec_seen_q <= 1'b1;
          if (topology_valid && busy_q) topology_seen_q <= 1'b1;
        end
      end
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) request_q <= '0;
      else if (accept) begin
        request_q.first <= batch_first_i || new_format;
        request_q.last <= batch_last_i;
        request_q.m <= m_i; request_q.n <= n_i; request_q.k <= k_i;
        request_q.fmt <= numfmt_i;
        request_q.opcode <= policy_format_known(numfmt_i) ? opcode_i : 3'd7;
        request_q.balance <= balance_i;
        request_q.sample <= policy_normalize_sample(sample_i, numfmt_i);
        request_q.sample_valid <= sample_valid_i && policy_format_known(numfmt_i);
        request_q.exact_zero <= exact_zero_i && policy_integer_format(numfmt_i);
        request_q.next_addr <= next_addr_i;
        request_q.next_addr_valid <= next_addr_valid_i && policy_format_known(numfmt_i);
        request_q.mispredict <= mispredict_i;
      end
    end

    g6lc_ai_policy_codec #(
      .AiCfg(AiCfg), .HoldWork(HoldWork), .DwellWork(DwellWork),
      .CooldownWork(CooldownWork), .BankBits(BankBits)
    ) i_codec (
      .clk_i, .rst_ni, .testmode_i, .enable_i, .flush_i,
      .valid_i(launch_q && !cancel),
      .batch_first_i(request_q.first), .batch_last_i(request_q.last),
      .m_i(request_q.m), .n_i(request_q.n), .k_i(request_q.k),
      .opcode_i(request_q.opcode), .balance_i(request_q.balance),
      .sample_i(request_q.sample), .sample_valid_i(request_q.sample_valid),
      .exact_zero_i(request_q.exact_zero),
      .next_addr_i(request_q.next_addr), .next_addr_valid_i(request_q.next_addr_valid),
      .mispredict_i(request_q.mispredict), .ready_o(codec_ready), .work_valid_o(codec_valid),
      .code_o(codec_result.code), .next_code_o(codec_result.next_code),
      .policy_o(codec_result.policy), .next_policy_o(codec_result.next_policy),
      .warm_valid_o(codec_result.warm), .warm_addr_o(codec_result.warm_addr),
      .warm_bank_o(codec_result.warm_bank), .residual_skip_o(codec_result.skip),
      .eval_o(codec_result.evaluated), .commit_o(codec_result.committed),
      .hold_o(codec_result.held), .predict_hit_o(codec_result.hit), .predict_miss_o(codec_result.miss)
    );
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) codec_q <= '0;
      else if (cancel) codec_q <= '0;
      else if (codec_valid && busy_q) codec_q <= codec_result;
    end

    g6lc_ai_policy_topology #(
      .ReadBytesPerCycle(ReadBytesPerCycle), .MinGain16ths(MinGain16ths),
      .FormatSlotsLog2(FormatSlotsLog2)
    ) i_topology (
      .clk_i, .rst_ni, .flush_i(cancel), .valid_i(accept),
      .m_i, .n_i, .k_i, .numfmt_i, .balance_i,
      .valid_o(topology_valid), .topology_o(candidates)
    );
    always_comb begin
      selected_topology = '0;
      for (int c = 0; c < 8; c++)
        selected_topology |= candidates[c] &
            {$bits(policy_topology_t){codec_q.code == policy_code_t'(c)}};
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        work_q <= 1'b0; published_q <= '0; published_topology_q <= '0;
        published_fmt_q <= '0;
        published_m_q <= '0; published_n_q <= '0; published_k_q <= '0;
      end else if (cancel) begin
        work_q <= 1'b0; published_q <= '0; published_topology_q <= '0;
        published_fmt_q <= '0;
        published_m_q <= '0; published_n_q <= '0; published_k_q <= '0;
      end else begin
        work_q <= publish;
        if (publish) begin
          published_q <= codec_q;
          published_topology_q <= selected_topology;
          published_fmt_q <= request_q.fmt;
          published_m_q <= request_q.m; published_n_q <= request_q.n; published_k_q <= request_q.k;
        end
      end
    end
    assign work_valid_o = work_q && !cancel;
    assign code_o = published_q.code;
    assign next_code_o = published_q.next_code;
    assign policy_o = published_q.policy;
    assign next_policy_o = published_q.next_policy;
    assign numfmt_o = published_fmt_q;
    assign topology_o = published_topology_q;
    assign warm_addr_o = published_q.warm_addr;
    assign warm_bank_o = published_q.warm_bank;
    assign warm_valid_o = work_valid_o && published_q.warm;
    assign residual_skip_o = work_valid_o && published_q.skip;
    assign eval_o = work_valid_o && published_q.evaluated;
    assign commit_o = work_valid_o && published_q.committed;
    assign hold_o = work_valid_o && published_q.held;
    assign predict_hit_o = work_valid_o && published_q.hit;
    assign predict_miss_o = work_valid_o && published_q.miss;

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
          batch_first_i || new_format || last_q))),
      .cancel_i(accept), .start_i(work_valid_o),
      .code_i(code_o), .numfmt_i(published_fmt_q),
      .m_i(published_m_q), .n_i(published_n_q), .k_i(published_k_q),
      .baseline_i(topology_o), .ready_o(), .busy_o(),
      .valid_o(subcode_valid_o), .evaluated_o(subcode_evaluated_o), .cache_hit_o(subcode_cache_hit_o),
      .subcode_o, .topology_o(subcode_topology_o),
      .baseline_cycles_o(subcode_baseline_cycles_o),
      .selected_cycles_o(subcode_selected_cycles_o)
    );
    // pragma translate_off
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        launch_q && !cancel |-> codec_ready);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        work_valid_o |-> !busy_q && topology_seen_q == 0 && codec_seen_q == 0);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        residual_skip_o |-> policy_integer_format(numfmt_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        topology_o.valid |-> {1'b0,topology_o.rows_log2} +
            {1'b0,topology_o.cols_log2} + topology_o.reduction_log2 == topology_o.slots_log2);
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
