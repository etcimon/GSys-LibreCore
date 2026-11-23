from pathlib import Path
p = Path('build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/ai_island/g6lc_ai_policy_codec.sv')
s = p.read_text()

# ---- 1) ready_o: gate on the 3-cycle window
old = """assign ready_o = svt_bm_top_p17046_n23781; // sv-timing: BalanceMux/rebalance #653 RHS rewrite"""
new = """assign ready_o = svt_bm_top_p17046_n23781 & ~win_busy; // r7 R5 window gate"""
assert old in s; s = s.replace(old, new)

# ---- 2) declare f1/f2 regs + window shift, rewrite families
old = """    // Family 1: shape/signature/candidate tracking.
    always_comb begin
      shape_d     = state_q.shape;
      evaluated_d = 1'b0;
      if (accept) begin
        shape_d     = {features.m, features.n, features.k};
        evaluated_d = evaluate;
      end
    end
    always_comb begin
      state_d.signature = state_q.signature;
      state_d.candidate = state_q.candidate;
      if (accept && evaluate) begin
        state_d.signature = features;
        state_d.candidate = candidate;
      end
    end

    // Family 2: code/pending/votes/dwell/cooldown policy state.
    always_comb begin
      code_d     = state_q.code;
      pending_d  = state_q.pending;
      votes_d    = state_q.votes;
      dwell_d    = state_q.dwell;
      cooldown_d = state_q.cooldown;
      committed_d = 1'b0;
      predict_hit_d  = 1'b0;
      predict_miss_d = 1'b0;
      if (accept) begin
        if (new_batch) begin
          code_d     = candidate;
          pending_d  = candidate;
          votes_d    = '0;
          dwell_d    = '0;
          cooldown_d = '0;
          committed_d = 1'b1;
        end else begin
          if (state_q.dwell < DwellBits'(DwellWork))
            dwell_d = state_q.dwell + 1'b1;
          if (candidate == state_q.code) begin
            votes_d = '0;
          end else begin
            pending_d = candidate;
            if (candidate != state_q.pending || state_q.votes == '0)
              votes_d = VoteBits'(1);
            else if (state_q.votes < VoteBits'(HoldWork))
              votes_d = state_q.votes + 1'b1;
            // Two independent gates: votes prove the new candidate is stable,
            // dwell proves the CURRENT code has been held long enough. Either
            // alone lets a workload oscillate between two codes.
            if (votes_d >= VoteBits'(HoldWork) &&
                dwell_d >= DwellBits'(DwellWork)) begin
              code_d = candidate;
              votes_d = '0;
              dwell_d = '0;
              committed_d = 1'b1;
            end
          end
          predict_miss_d = miss;
          predict_hit_d = state_q.prediction_pending && !miss;
          if (miss) cooldown_d = CooldownBits'(CooldownWork);
          else if (state_q.cooldown != '0) cooldown_d = state_q.cooldown - 1'b1;
        end
        if (batch_last_i) begin
          votes_d = '0;
          cooldown_d = '0;
        end
      end
    end

    // Family 3: selected/predicted decodes + warm/residual/pending outputs.
    always_comb begin
      selected_policy = policy_decode(code_d);
      predicted_d = (accept && features.continuous && candidate == code_d) ?
          code_d : policy_successor(code_d);
      predicted_policy = policy_decode(predicted_d);
      work_valid_d = accept;
      held_d = accept && !committed_d;
      warm_valid_d = 1'b0;
      warm_addr_d  = state_q.warm_addr;
      residual_skip_d = 1'b0;
      prediction_pending_d = 1'b0;
      if (accept) begin
        residual_skip_d = features.shape_valid && selected_policy.sparse_check && exact_zero_i;
        if (!batch_last_i && features.shape_valid && next_addr_valid_i &&
            predicted_policy.prefetch_depth != 2'd0 && !miss &&
            (new_batch || state_q.cooldown == '0)) begin
          warm_valid_d = 1'b1;
          warm_addr_d  = next_addr_i;
          prediction_pending_d = 1'b1;
        end
      end
    end

    // Assemble the next state from the families.
    always_comb begin
      state_d = state_q;
      state_d.active             = accept ? !batch_last_i : state_q.active;
      state_d.work_valid         = work_valid_d;
      state_d.warm_valid         = warm_valid_d;
      state_d.warm_addr          = warm_addr_d;
      state_d.residual_skip      = residual_skip_d;
      state_d.evaluated          = evaluated_d;
      state_d.committed          = committed_d;
      state_d.held               = held_d;
      state_d.predict_hit        = predict_hit_d;
      state_d.predict_miss       = predict_miss_d;
      state_d.shape              = shape_d;
      state_d.code               = code_d;
      state_d.pending            = pending_d;
      state_d.votes              = votes_d;
      state_d.dwell              = dwell_d;
      state_d.cooldown           = cooldown_d;
      state_d.predicted          = predicted_d;
      state_d.prediction_pending = prediction_pending_d;
      if (flush_i || !enable_i) state_d = '0;
    end"""

new = """    // r7 R5: stage registers between the three families. f1_q captures
    // the accept-cycle terms; f2_q carries family-2's vote/dwell outputs
    // plus the passthroughs family-3 needs; the assemble stage writes
    // state_q one cycle later. ready_o is low while a sample is inside
    // the window, so at most one is in flight.
    policy_features_t      f1_features_q;
    logic                  f1_evaluate_q, f1_new_batch_q, f1_miss_q,
                           f1_batch_last_q, f1_next_addr_valid_q,
                           f1_exact_zero_q, f1_vld_q;
    policy_code_t          f1_candidate_q;
    logic [47:0]           f1_next_addr_q;
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
        f1_features_q <= '0; f1_evaluate_q <= 1'b0; f1_new_batch_q <= 1'b0;
        f1_miss_q <= 1'b0; f1_batch_last_q <= 1'b0;
        f1_next_addr_valid_q <= 1'b0; f1_exact_zero_q <= 1'b0;
        f1_candidate_q <= '0; f1_next_addr_q <= '0; f1_vld_q <= 1'b0;
      end else begin
        f1_features_q        <= features;
        f1_evaluate_q        <= evaluate;
        f1_new_batch_q       <= new_batch;
        f1_miss_q            <= miss;
        f1_batch_last_q      <= batch_last_i;
        f1_next_addr_valid_q <= next_addr_valid_i;
        f1_exact_zero_q      <= exact_zero_i;
        f1_candidate_q       <= candidate;
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
    logic [47:0]           f2_next_addr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        f2_code_q <= '0; f2_pending_q <= '0; f2_votes_q <= '0;
        f2_dwell_q <= '0; f2_cooldown_q <= '0;
        f2_committed_q <= 1'b0; f2_predict_hit_q <= 1'b0; f2_predict_miss_q <= 1'b0;
        f2_features_q <= '0; f2_evaluate_q <= 1'b0; f2_new_batch_q <= 1'b0;
        f2_miss_q <= 1'b0; f2_batch_last_q <= 1'b0;
        f2_next_addr_valid_q <= 1'b0; f2_exact_zero_q <= 1'b0;
        f2_candidate_q <= '0; f2_next_addr_q <= '0; f2_vld_q <= 1'b0;
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
      state_d.committed          = f2_committed_q;
      state_d.held               = held_d;
      state_d.predict_hit        = f2_predict_hit_q;
      state_d.predict_miss       = f2_predict_miss_q;
      state_d.shape              = f2_vld_q ?
          {f2_features_q.m, f2_features_q.n, f2_features_q.k}
          : state_q.shape;
      if (f2_vld_q && f2_evaluate_q) begin
        state_d.signature = f2_features_q;
        state_d.candidate = f2_candidate_q;
      end
      state_d.code               = f2_code_q;
      state_d.pending            = f2_pending_q;
      state_d.votes              = f2_votes_q;
      state_d.dwell              = f2_dwell_q;
      state_d.cooldown           = f2_cooldown_q;
      state_d.predicted          = predicted_d;
      state_d.prediction_pending = prediction_pending_d;
      if (flush_i || !enable_i) state_d = '0;
    end"""
assert old in s, 'family block'
s = s.replace(old, new)

# ---- 3) state_q write enable: f2_vld replaces accept
old = """    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) state_q <= '0;
      else if (testmode_i || accept || flush_i || !enable_i || state_q.work_valid)
        state_q <= state_d;
    end"""
new = """    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) state_q <= '0;
      else if (testmode_i || f2_vld_q || flush_i || !enable_i || state_q.work_valid)
        state_q <= state_d;
    end"""
assert old in s, 'state ff'
s = s.replace(old, new)

# ---- 4) drop now-unused family _d decls
old = """    policy_code_t code_d, pending_d, predicted_d;
    logic [VoteBits-1:0]     votes_d;
    logic [DwellBits-1:0]    dwell_d;
    logic [CooldownBits-1:0] cooldown_d;
    logic                   active_d, work_valid_d, evaluated_d,
                            committed_d, held_d, warm_valid_d,
                            predict_hit_d, predict_miss_d,
                            residual_skip_d, prediction_pending_d;
    logic [47:0]            shape_d, warm_addr_d;"""
new = """    logic                  work_valid_d, held_d, warm_valid_d,
                           residual_skip_d, prediction_pending_d;
    logic [47:0]           warm_addr_d;
    policy_code_t          predicted_d;"""
assert old in s, 'decls'
s = s.replace(old, new)
p.write_text(s, newline='\n')
print('R5 codec stages applied')
