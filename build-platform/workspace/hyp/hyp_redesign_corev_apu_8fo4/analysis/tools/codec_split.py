from pathlib import Path
p = Path('build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/ai_island/g6lc_ai_policy_codec.sv')
s = p.read_text()

old = """    always_comb begin
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
            // Two independent gates: votes prove the new candidate is stable,
            // dwell proves the CURRENT code has been held long enough. Either
            // alone lets a workload oscillate between two codes.
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
    end"""

new = """    // P6/rank-0: split the monolithic next-state comb into per-family
    // blocks. Each family reads state_q + inputs + other families' *_d
    // leaf wires -- never a mid-flight struct member.
    g6lc_ai_island_cfg_pkg::policy_code_t code_d, pending_d, predicted_d;
    logic [VoteBits-1:0]     votes_d;
    logic [DwellBits-1:0]    dwell_d;
    logic [CooldownBits-1:0] cooldown_d;
    logic                   active_d, work_valid_d, evaluated_d,
                            committed_d, held_d, warm_valid_d,
                            predict_hit_d, predict_miss_d,
                            residual_skip_d, prediction_pending_d;
    logic [47:0]            shape_d, warm_addr_d;

    // Family 1: shape/signature/candidate tracking.
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
assert old in s, 'comb body'
s = s.replace(old, new)
p.write_text(s, newline='\n')
print('codec family split applied')
