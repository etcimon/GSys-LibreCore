// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

module g6lc_ai_policy_codec
  import g6lc_ai_policy_pkg::*;
#(
    parameter config_pkg::ai_cfg_t AiCfg = config_pkg::AiCfgOff,
    parameter int unsigned HoldWork = 3,
    parameter int unsigned DwellWork = 4,
    parameter int unsigned CooldownWork = 2,
    parameter int unsigned BankBits = 4
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
    input  logic [63:0] sample_i,
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
    output logic predict_miss_o
);

  // pragma translate_off
  initial begin
    assert (!AiCfg.PolicyCodecEn || (AiCfg.MatrixEn && AiCfg.Queues > 0))
      else $fatal(1, "Policy codec requires MatrixEn and a T2 queue");
    assert (HoldWork >= 1 && HoldWork <= 15 && DwellWork >= 1 && DwellWork <= 15)
      else $fatal(1, "Policy HoldWork/DwellWork must be in [1,15]");
    assert (CooldownWork <= 15 && BankBits >= 1 && BankBits <= 8)
      else $fatal(1, "Policy cooldown/bank geometry is unsupported");
  end
  // pragma translate_on

  if (AiCfg.PolicyCodecEn) begin : gen_codec
    localparam int VoteBits = (HoldWork < 2) ? 1 : $clog2(HoldWork + 1);
    localparam int DwellBits = (DwellWork < 2) ? 1 : $clog2(DwellWork + 1);
    localparam int CooldownBits = (CooldownWork < 2) ? 1 : $clog2(CooldownWork + 1);

    typedef struct packed {
      logic active;
      policy_features_t signature;
      logic [5:0] shape;
      policy_code_t candidate;
      policy_code_t code;
      policy_code_t pending;
      logic [VoteBits-1:0] votes;
      logic [DwellBits-1:0] dwell;
      logic [CooldownBits-1:0] cooldown;
      logic prediction_pending;
      policy_code_t predicted;
      logic work_valid;
      logic warm_valid;
      logic [63:0] warm_addr;
      logic residual_skip;
      logic evaluated;
      logic committed;
      logic held;
      logic predict_hit;
      logic predict_miss;
    } state_t;

    state_t state_q, state_d;
    policy_features_t features, encode_features;
    policy_code_t candidate;
    policy_t selected_policy, predicted_policy;
    logic accept, new_batch, evaluate, miss;

    assign ready_o = enable_i && !flush_i;
    assign accept = valid_i && ready_o;
    assign new_batch = !state_q.active || batch_first_i;

    always_comb begin
      features = '0;
      if (accept) begin
        features.m = policy_bucket(m_i);
        features.n = policy_bucket(n_i);
        features.k = policy_bucket(k_i);
        features.opcode = opcode_i;
        features.balance = (balance_i == 2'd3) ? 2'd1 : balance_i;
        features.sparse = sample_valid_i && policy_sparse_residue(sample_i);
        features.continuous = !new_batch &&
            ({features.m, features.n, features.k} == state_q.shape);
        features.shape_valid = (m_i != 16'd0) && (n_i != 16'd0) && (k_i != 16'd0);
      end
    end

    assign evaluate = accept && (new_batch || features != state_q.signature);
    assign encode_features = evaluate ? features : policy_features_t'('0);
    assign candidate = evaluate ? policy_encode(encode_features) : state_q.candidate;
    assign miss = accept && !new_batch && state_q.prediction_pending &&
        ((state_q.predicted != candidate) || mispredict_i);

    always_comb begin
      state_d = state_q;
      state_d.work_valid = 1'b0;
      state_d.warm_valid = 1'b0;
      state_d.residual_skip = 1'b0;
      state_d.evaluated = 1'b0;
      state_d.committed = 1'b0;
      state_d.held = 1'b0;
      state_d.predict_hit = 1'b0;
      state_d.predict_miss = 1'b0;
      selected_policy = policy_decode(state_q.code);
      predicted_policy = policy_decode(policy_successor(state_q.code));

      if (accept) begin
        state_d.active = !batch_last_i;
        state_d.work_valid = 1'b1;
        state_d.shape = {features.m, features.n, features.k};
        state_d.evaluated = evaluate;
        if (evaluate) begin
          state_d.signature = features;
          state_d.candidate = candidate;
        end

        if (new_batch) begin
          state_d.code = candidate;
          state_d.pending = candidate;
          state_d.votes = '0;
          state_d.dwell = '0;
          state_d.cooldown = '0;
          state_d.committed = 1'b1;
        end else begin
          if (state_q.dwell < DwellBits'(DwellWork))
            state_d.dwell = state_q.dwell + 1'b1;
          if (candidate == state_q.code) begin
            state_d.votes = '0;
          end else begin
            state_d.pending = candidate;
            if (candidate != state_q.pending || state_q.votes == '0)
              state_d.votes = VoteBits'(1);
            else if (state_q.votes < VoteBits'(HoldWork))
              state_d.votes = state_q.votes + 1'b1;
            if (state_d.votes >= VoteBits'(HoldWork) &&
                state_d.dwell >= DwellBits'(DwellWork)) begin
              state_d.code = candidate;
              state_d.votes = '0;
              state_d.dwell = '0;
              state_d.committed = 1'b1;
            end
          end
          state_d.predict_miss = miss;
          state_d.predict_hit = state_q.prediction_pending && !miss;
          if (miss) state_d.cooldown = CooldownBits'(CooldownWork);
          else if (state_q.cooldown != '0) state_d.cooldown = state_q.cooldown - 1'b1;
        end

        state_d.held = !state_d.committed;
        selected_policy = policy_decode(state_d.code);
        state_d.predicted = (features.continuous && candidate == state_d.code) ?
            state_d.code : policy_successor(state_d.code);
        predicted_policy = policy_decode(state_d.predicted);
        state_d.prediction_pending = 1'b0;
        state_d.residual_skip = features.shape_valid && selected_policy.sparse_check && exact_zero_i;
        if (!batch_last_i && features.shape_valid && next_addr_valid_i &&
            predicted_policy.prefetch_depth != 2'd0 && !miss &&
            (new_batch || state_q.cooldown == '0)) begin
          state_d.warm_valid = 1'b1;
          state_d.warm_addr = next_addr_i;
          state_d.prediction_pending = 1'b1;
        end
        if (batch_last_i) begin
          state_d.votes = '0;
          state_d.cooldown = '0;
        end
      end
      if (flush_i || !enable_i) state_d = '0;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) state_q <= '0;
      else if (testmode_i || accept || flush_i || !enable_i || state_q.work_valid)
        state_q <= state_d;
    end

    assign work_valid_o = state_q.work_valid;
    assign code_o = state_q.code;
    assign next_code_o = state_q.predicted;
    assign policy_o = policy_decode(state_q.code);
    assign next_policy_o = policy_decode(next_code_o);
    assign warm_valid_o = state_q.warm_valid;
    assign warm_addr_o = state_q.warm_addr;
    assign warm_bank_o = state_q.warm_addr[6 +: BankBits];
    assign residual_skip_o = state_q.residual_skip;
    assign eval_o = state_q.evaluated;
    assign commit_o = state_q.committed;
    assign hold_o = state_q.held;
    assign predict_hit_o = state_q.predict_hit;
    assign predict_miss_o = state_q.predict_miss;

    // pragma translate_off
    assert property (@(posedge clk_i) disable iff (!rst_ni) commit_o |-> work_valid_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni) warm_valid_o |-> work_valid_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        residual_skip_o |-> work_valid_o && policy_o.sparse_check && $past(exact_zero_i));
    assert property (@(posedge clk_i) disable iff (!rst_ni) !(predict_hit_o && predict_miss_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        !valid_i && enable_i && !flush_i |=> $stable(code_o));
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
  end
endmodule
