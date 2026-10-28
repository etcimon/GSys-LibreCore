// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
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

    

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_policy_codec  region=6788  makespan=7.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: state_q  ready_cycle=1  ready_fo4=7.500  OpenSTA: report_timing -from clk_i -to state_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     state_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node23845 c=3.50 slack=4.00 */
//     /* node23846 c=7.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// sv-timing: origin <src>/corev_apu/ai_island/g6lc_ai_policy_codec.sv:106:9 edit=656
  // relocation t1_balance_bundle; balance_mux credit path 17045 node 23790 exclusive residual 148.4->74.2 (latency-neutral) extras=0
// sv-timing: origin <src>/corev_apu/ai_island/g6lc_ai_policy_codec.sv:106:9 edit=663
  // relocation t1_balance_bundle; balance_mux credit path 17044 node 23790 exclusive residual 148.3->74.1 (latency-neutral) extras=0
  // END sv-timing auto-correct (balance_mux rewrite)
  // BEGIN sv-timing auto-correct (balance_mux rewrite)
  // --- BalanceMux arm staging (latency-neutral) ---
  logic svt_bm_p17046_n23781_0;
  var type(ready_o) svt_bm_top_p17046_n23781;
  always_comb begin : svt_bm_top_p17046_n23781_stage
    svt_bm_p17046_n23781_0 = !flush_i;
    svt_bm_top_p17046_n23781 = type(ready_o)'(enable_i && svt_bm_p17046_n23781_0);
  end
  // END sv-timing auto-correct (balance_mux rewrite)
assign ready_o = svt_bm_top_p17046_n23781 & ~win_busy; // r7 R5 window gate
    assign accept = valid_i && ready_o;
    assign new_batch = !state_q.active || batch_first_i;

    // r24: policy_sparse_residue(sample) is "six or more zero bytes", i.e.
    // at most two nonzero bytes: clear the lowest set bit twice.
    logic [7:0] nonzero_bytes, nonzero_m1, nonzero_m2;
    logic sparse_residue_c;
    always_comb for (int i = 0; i < 8; i++) nonzero_bytes[i] = |sample_i[i*8 +: 8];
    assign nonzero_m1 = nonzero_bytes & (nonzero_bytes - 8'd1);
    assign nonzero_m2 = nonzero_m1 & (nonzero_m1 - 8'd1);
    assign sparse_residue_c = nonzero_m2 == 8'd0;
    // pragma translate_off
    always @(posedge clk_i) if (rst_ni)
      assert (sparse_residue_c == policy_sparse_residue(sample_i))
        else $error("sparse residue identity");
    // pragma translate_on
    always_comb begin
      features = '0;
      if (accept) begin
        features.m = policy_bucket(m_i);
        features.n = policy_bucket(n_i);
        features.k = policy_bucket(k_i);
        features.opcode = opcode_i;
        features.balance = (balance_i == 2'd3) ? 2'd1 : balance_i;
        features.sparse = sample_valid_i && sparse_residue_c;
        features.continuous = !new_batch &&
            ({features.m, features.n, features.k} == state_q.shape);
        features.shape_valid = (m_i != 16'd0) && (n_i != 16'd0) && (k_i != 16'd0);
      end
    end

    // Re-encode only on a new batch or a genuine feature change; a steady shape
    // reuses the committed candidate so the encoder is not in the per-job path.
    // r26: evaluate/encode/miss run one stage later, from the captured
    // features. The window gate keeps one sample in flight, so state_q is
    // the same in the accept cycle and the f1 cycle; the accept-cycle
    // mispredict input is captured alongside the features.
    assign evaluate = f1_vld_q && (f1_new_batch_q || f1_features_q != state_q.signature);
    assign encode_features = evaluate ? f1_features_q : policy_features_t'('0);
    assign candidate = evaluate ? policy_encode(encode_features) : state_q.candidate;
    assign miss = f1_vld_q && !f1_new_batch_q && state_q.prediction_pending &&
        ((state_q.predicted != candidate) || f1_mispredict_q);
    assign f1_evaluate_q = evaluate;
    assign f1_candidate_q = candidate;
    assign f1_miss_q = miss;

    // P6/rank-0: split the monolithic next-state comb into per-family
    // blocks. Each family reads state_q + inputs + other families' *_d
    // leaf wires -- never a mid-flight struct member.
    logic                  work_valid_d, held_d, warm_valid_d,
                           residual_skip_d, prediction_pending_d;
    logic [63:0]           warm_addr_d;
    policy_code_t          predicted_d;

    // r7 R5: stage registers between the three families. f1_q captures
    // the accept-cycle terms; f2_q carries family-2's vote/dwell outputs
    // plus the passthroughs family-3 needs; the assemble stage writes
    // state_q one cycle later. ready_o is low while a sample is inside
    // the window, so at most one is in flight.
    policy_features_t      f1_features_q;
    logic                  f1_evaluate_q, f1_new_batch_q, f1_miss_q,
                           f1_batch_last_q, f1_next_addr_valid_q,
                           f1_exact_zero_q, f1_vld_q, f1_mispredict_q;
    policy_code_t          f1_candidate_q;
    logic [63:0]           f1_next_addr_q;
    logic                  win_q0, win_q1, win_q2;
    wire                   win_busy = win_q0 || win_q1 || win_q2;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        win_q0 <= 1'b0; win_q1 <= 1'b0; win_q2 <= 1'b0;
      end else if (flush_i || !enable_i) begin
        win_q0 <= 1'b0; win_q1 <= 1'b0; win_q2 <= 1'b0;
      end else begin
        win_q0 <= accept;
        win_q1 <= win_q0;
        win_q2 <= win_q1;
      end
    end

    // Family 1 register stage: accept-cycle capture.
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        f1_features_q <= '0; f1_new_batch_q <= 1'b0;
        f1_batch_last_q <= 1'b0; f1_mispredict_q <= 1'b0;
        f1_next_addr_valid_q <= 1'b0; f1_exact_zero_q <= 1'b0;
        f1_next_addr_q <= '0; f1_vld_q <= 1'b0;
      end else if (flush_i || !enable_i) begin
        f1_vld_q <= 1'b0;
      end else begin
        f1_features_q        <= features;
        f1_new_batch_q       <= new_batch;
        f1_mispredict_q      <= mispredict_i;
        f1_batch_last_q      <= batch_last_i;
        f1_next_addr_valid_q <= next_addr_valid_i;
        f1_exact_zero_q      <= exact_zero_i;
        f1_next_addr_q       <= next_addr_i;
        f1_vld_q             <= accept;
      end
    end

    // Family 2 register stage: policy state next values + passthroughs.
    policy_code_t          f2_code_q, f2_pending_q;
    logic [VoteBits-1:0]    f2_votes_q;
    logic [DwellBits-1:0]   f2_dwell_q;
    logic [CooldownBits-1:0] f2_cooldown_q;
    logic                  f2_committed_q, f2_predict_hit_q, f2_predict_miss_q;
    policy_features_t      f2_features_q;
    logic                  f2_evaluate_q, f2_new_batch_q, f2_miss_q,
                           f2_batch_last_q, f2_next_addr_valid_q,
                           f2_exact_zero_q, f2_vld_q;
    policy_code_t          f2_candidate_q;
    logic [63:0]           f2_next_addr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        f2_code_q <= policy_code_t'('0); f2_pending_q <= policy_code_t'('0); f2_votes_q <= '0;
        f2_dwell_q <= '0; f2_cooldown_q <= '0;
        f2_committed_q <= 1'b0; f2_predict_hit_q <= 1'b0; f2_predict_miss_q <= 1'b0;
        f2_features_q <= '0; f2_evaluate_q <= 1'b0; f2_new_batch_q <= 1'b0;
        f2_miss_q <= 1'b0; f2_batch_last_q <= 1'b0;
        f2_next_addr_valid_q <= 1'b0; f2_exact_zero_q <= 1'b0;
        f2_candidate_q <= policy_code_t'('0); f2_next_addr_q <= '0; f2_vld_q <= 1'b0;
      end else if (flush_i || !enable_i) begin
        f2_vld_q <= 1'b0;
        f2_committed_q <= 1'b0;
        f2_predict_hit_q <= 1'b0;
        f2_predict_miss_q <= 1'b0;
      end else begin
        // Passthroughs.
        f2_features_q        <= f1_features_q;
        f2_evaluate_q        <= f1_evaluate_q;
        f2_new_batch_q       <= f1_new_batch_q;
        f2_miss_q            <= f1_miss_q;
        f2_batch_last_q      <= f1_batch_last_q;
        f2_next_addr_valid_q <= f1_next_addr_valid_q;
        f2_exact_zero_q      <= f1_exact_zero_q;
        f2_candidate_q       <= f1_candidate_q;
        f2_next_addr_q       <= f1_next_addr_q;
        f2_vld_q             <= f1_vld_q;
        // Family-2 logic, computed on the f1 registers + live state_q.
        if (!f1_vld_q) begin
          f2_code_q      <= state_q.code;
          f2_pending_q   <= state_q.pending;
          f2_votes_q     <= state_q.votes;
          f2_dwell_q     <= state_q.dwell;
          f2_cooldown_q  <= state_q.cooldown;
          f2_committed_q <= 1'b0;
          f2_predict_hit_q  <= 1'b0;
          f2_predict_miss_q <= 1'b0;
        end else if (f1_new_batch_q) begin
          f2_code_q      <= f1_candidate_q;
          f2_pending_q   <= f1_candidate_q;
          f2_votes_q     <= '0;
          f2_dwell_q     <= '0;
          f2_cooldown_q  <= '0;
          f2_committed_q <= 1'b1;
          f2_predict_hit_q  <= 1'b0;
          f2_predict_miss_q <= 1'b0;
        end else begin
          f2_code_q    <= state_q.code;
          f2_pending_q <= state_q.pending;
          f2_votes_q   <= state_q.votes;
          f2_dwell_q   <= (state_q.dwell < DwellBits'(DwellWork))
                            ? state_q.dwell + 1'b1 : state_q.dwell;
          f2_committed_q <= 1'b0;
          if (f1_candidate_q == state_q.code) begin
            f2_votes_q <= '0;
          end else begin
            f2_pending_q <= f1_candidate_q;
            if (f1_candidate_q != state_q.pending || state_q.votes == '0)
              f2_votes_q <= VoteBits'(1);
            else if (state_q.votes < VoteBits'(HoldWork))
              f2_votes_q <= state_q.votes + 1'b1;
          end
          // Two independent gates: votes prove the new candidate is stable,
          // dwell proves the CURRENT code has been held long enough. Either
          // alone lets a workload oscillate between two codes. The tests use
          // the NEXT values (the registered f2_ wires above).
          if (((f1_candidate_q == state_q.code) ? '0 :
               (f1_candidate_q != state_q.pending || state_q.votes == '0) ?
                    VoteBits'(1) :
               (state_q.votes < VoteBits'(HoldWork)) ?
                    state_q.votes + 1'b1 : state_q.votes)
                >= VoteBits'(HoldWork) &&
              ((state_q.dwell < DwellBits'(DwellWork)) ?
                    state_q.dwell + 1'b1 : state_q.dwell)
                >= DwellBits'(DwellWork)) begin
            f2_code_q      <= f1_candidate_q;
            f2_votes_q     <= '0;
            f2_dwell_q     <= '0;
            f2_committed_q <= 1'b1;
          end
          f2_predict_miss_q <= f1_miss_q;
          f2_predict_hit_q  <= state_q.prediction_pending && !f1_miss_q;
          f2_cooldown_q <= f1_miss_q ? CooldownBits'(CooldownWork)
                           : (state_q.cooldown != '0)
                               ? state_q.cooldown - 1'b1 : state_q.cooldown;
          if (f1_batch_last_q) begin
            f2_votes_q    <= '0;
            f2_cooldown_q <= '0;
          end
        end
      end
    end

    // Family 3: decodes + warm/residual/pending outputs from f2.
    always_comb begin
      selected_policy = policy_decode(f2_code_q);
      predicted_d = (f2_vld_q && f2_features_q.continuous &&
                     f2_candidate_q == f2_code_q) ?
          f2_code_q : policy_successor(f2_code_q);
      predicted_policy = policy_decode(predicted_d);
      work_valid_d = f2_vld_q;
      held_d = f2_vld_q && !f2_committed_q;
      warm_valid_d = 1'b0;
      warm_addr_d  = state_q.warm_addr;
      residual_skip_d = 1'b0;
      prediction_pending_d = 1'b0;
      if (f2_vld_q) begin
        residual_skip_d = f2_features_q.shape_valid &&
            selected_policy.sparse_check && f2_exact_zero_q;
        if (!f2_batch_last_q && f2_features_q.shape_valid &&
            f2_next_addr_valid_q &&
            predicted_policy.prefetch_depth != 2'd0 && !f2_miss_q &&
            (f2_new_batch_q || state_q.cooldown == '0)) begin
          warm_valid_d = 1'b1;
          warm_addr_d  = f2_next_addr_q;
          prediction_pending_d = 1'b1;
        end
      end
    end

    // Assemble the next state from the f2 stage.
    always_comb begin
      state_d = state_q;
      state_d.active             = f2_vld_q ? !f2_batch_last_q : state_q.active;
      state_d.work_valid         = work_valid_d;
      state_d.warm_valid         = warm_valid_d;
      state_d.warm_addr          = warm_addr_d;
      state_d.residual_skip      = residual_skip_d;
      state_d.evaluated          = f2_vld_q && f2_evaluate_q;
      state_d.committed          = f2_vld_q && f2_committed_q;
      state_d.held               = held_d;
      state_d.predict_hit        = f2_vld_q && f2_predict_hit_q;
      state_d.predict_miss       = f2_vld_q && f2_predict_miss_q;
      state_d.shape              = f2_vld_q ?
          {f2_features_q.m, f2_features_q.n, f2_features_q.k}
          : state_q.shape;
      if (f2_vld_q && f2_evaluate_q) begin
        state_d.signature = f2_features_q;
        state_d.candidate = f2_candidate_q;
      end
      // The idle f2 register can contain the pre-commit state. Clearing the
      // result pulse must not replay that stale history one cycle later.
      if (f2_vld_q) begin
        state_d.code               = f2_code_q;
        state_d.pending            = f2_pending_q;
        state_d.votes              = f2_votes_q;
        state_d.dwell              = f2_dwell_q;
        state_d.cooldown           = f2_cooldown_q;
        state_d.predicted          = predicted_d;
        state_d.prediction_pending = prediction_pending_d;
      end
      if (flush_i || !enable_i) state_d = '0;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) state_q <= '0;
      else if (testmode_i || f2_vld_q || flush_i || !enable_i || state_q.work_valid)
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
    // r7 R1: ready_o stays combinational (same-cycle accept coupling);
    // every start must land while ready is live.
    assert property (@(posedge clk_i) disable iff (!rst_ni) accept |-> ready_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni) commit_o |-> work_valid_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni) warm_valid_o |-> work_valid_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        residual_skip_o |-> work_valid_o && policy_o.sparse_check && $past(f2_exact_zero_q));
    assert property (@(posedge clk_i) disable iff (!rst_ni) !(predict_hit_o && predict_miss_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        !f2_vld_q && enable_i && !flush_i |=> $stable(code_o));
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
