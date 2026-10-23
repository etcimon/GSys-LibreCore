// hyp8 provenance: REWRITTEN for the 8-FO4 frontend (response-side verdict)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_fe_override — override #2 and the verdict stage of the response path.
//
// Stage L (lookup, registered): captures the realigned slot bundle, the
// response-keyed predictor lookups (BHT/TAGE chain + BTB/ITTAGE + RAS top)
// and the window metadata (vaddr, epoch, prefix-filter base, carry flags).
// The predecode bundle is NOT re-registered: it arrives already registered
// from instr_scan (which captured instr_o at the same edge stage L samples
// the slot bundle), so the rvi_*/rvc_* inputs are consumed combinationally
// at stage S.
//
// Stage S (select, same-cycle comb -> registered verdict + instruction-queue
// present): the reference cf_select priority — the lowest slot's prediction
// wins, with the leftover-complete slot0 override — followed by the
// fetchability/consumption gates. Its products drive the instruction queue
// THIS cycle (valid/cf_type/predict_address/ckpt) so consumed_o, the RAS
// push/pop and the checkpoint allocation close in one cycle exactly as the
// reference did.
//
// The verdict compares the selected target with the stream's recorded guess
// for the block after this window (the line/redirect guess captured at
// request-accept time, carried in the window metadata): agreement = no
// redirect; disagreement = override #2, a registered record that bumps the
// fetch epoch and restarts the stream at predict_address. The same live
// verdict trains the next-line table for this window's block (taken ->
// target, not-taken -> clear).
//
// Cut: rank 3 (overlap + epoch kill) for the override; rank 4 (front-end
// depth) for the two response stages added here. Latency: +2 cycles between
// the scan stage and the queue.

module g6lc_fe_override
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8,
    parameter type bht_prediction_t = logic,
    parameter type btb_prediction_t = logic,
    parameter type ras_t = logic
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    flush_i,
    input  logic [((HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1)-1:0] epoch_i,
    input  logic                    fetch_translation_en_i,

    // ---- stage-L inputs (from instr_realign stage B + instr_scan + bp lookups)
    // window meta (stamped at response accept, carried in the meta pipeline)
    input  logic                    win_valid_i,
    input  logic [G6LCCfg.VLEN-1:0] win_vaddr_i,
    input  logic [((HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1)-1:0] win_epoch_i,
    // the stream's recorded guess for the block after this window
    input  logic                    win_line_taken_i,
    input  logic [G6LCCfg.VLEN-1:0] win_line_target_i,
    // leftover state of this window
    input  logic                    serving_unaligned_i,
    input  logic                    carry_done_i,
    input  logic [63:0]             present_exp_i,
    // slot bundle (instr_realign stage B)
    input  logic [G6LCCfg.INSTR_PER_FETCH-1:0]              vld_raw_i,
    input  logic [G6LCCfg.INSTR_PER_FETCH-1:0][31:0]        instr_i,
    input  logic [G6LCCfg.INSTR_PER_FETCH-1:0][G6LCCfg.VLEN-1:0] addr_i,
    input  logic [G6LCCfg.INSTR_PER_FETCH-1:0][G6LCCfg.VLEN-1:0] base_i,
    input  logic [G6LCCfg.INSTR_PER_FETCH-1:0][G6LCCfg.VLEN-1:0] off_i,
    // predecode (instr_scan registered outputs)
    input  logic [G6LCCfg.INSTR_PER_FETCH-1:0]              rvi_return_i,
    input  logic [G6LCCfg.INSTR_PER_FETCH-1:0]              rvi_call_i,
    input  logic [G6LCCfg.INSTR_PER_FETCH-1:0]              rvi_branch_i,
    input  logic [G6LCCfg.INSTR_PER_FETCH-1:0]              rvi_jalr_i,
    input  logic [G6LCCfg.INSTR_PER_FETCH-1:0]              rvi_jump_i,
    input  logic [G6LCCfg.INSTR_PER_FETCH-1:0][G6LCCfg.VLEN-1:0] rvi_imm_i,
    input  logic [G6LCCfg.INSTR_PER_FETCH-1:0]              rvc_branch_i,
    input  logic [G6LCCfg.INSTR_PER_FETCH-1:0]              rvc_jump_i,
    input  logic [G6LCCfg.INSTR_PER_FETCH-1:0]              rvc_jr_i,
    input  logic [G6LCCfg.INSTR_PER_FETCH-1:0]              rvc_return_i,
    input  logic [G6LCCfg.INSTR_PER_FETCH-1:0]              rvc_jalr_i,
    input  logic [G6LCCfg.INSTR_PER_FETCH-1:0]              rvc_call_i,
    input  logic [G6LCCfg.INSTR_PER_FETCH-1:0][G6LCCfg.VLEN-1:0] rvc_imm_i,
    // predictor verdicts for this window — hyp8: REGISTERED by the fabric
    // (P2 verdict stage), live during the stage-S cycle; they bypass stage L
    // and are consumed directly by the select below. ras_predict_i is the
    // live stack top, captured into l_ras_q at the stage-L edge.
    input  bht_prediction_t [G6LCCfg.INSTR_PER_FETCH-1:0]   bht_pred_i,
    input  btb_prediction_t [G6LCCfg.INSTR_PER_FETCH-1:0]   btb_pred_i,
    input  ras_t                                          ras_predict_i,
    // ---- stage-S same-cycle handshake (instruction queue consumption)
    input  logic [G6LCCfg.INSTR_PER_FETCH-1:0]              consumed_i,

    // ---- stage-L registered outputs are internal; stage-S outputs to the queue
    output logic                    s_valid_o,     // a live window is at stage S
    output logic                    s_win_o,       // a window occupies stage S (live or dead)
    output logic [G6LCCfg.VLEN-1:0] s_vaddr_o,
    // the window's realigned payload, re-exported for the queue write
    output logic [G6LCCfg.INSTR_PER_FETCH-1:0][31:0]               s_instr_o,
    output logic [G6LCCfg.INSTR_PER_FETCH-1:0][G6LCCfg.VLEN-1:0]   s_addr_o,
    // instruction-queue presentation (stage-S comb)
    output logic [G6LCCfg.INSTR_PER_FETCH-1:0] iq_valid_o,
    output cf_t [G6LCCfg.INSTR_PER_FETCH-1:0]  iq_cf_type_o,
    output logic [G6LCCfg.VLEN-1:0]            iq_predict_address_o,
    output logic [G6LCCfg.INSTR_PER_FETCH-1:0] iq_is_call_o,
    output logic [G6LCCfg.INSTR_PER_FETCH-1:0] iq_is_return_o,
    output logic [G6LCCfg.INSTR_PER_FETCH-1:0] bp_push_cf_o,
    // RAS speculative update (epoch-qualified by the window's own epoch)
    output logic                    ras_push_o,
    output logic                    ras_pop_o,
    output logic [G6LCCfg.VLEN-1:0] ras_update_o,
    output logic [((HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1)-1:0] spec_epoch_o,
    // window bookkeeping exported to the frontend
    output logic                    s_carry_done_o,
    output logic                    s_serving_unaligned_o,
    output logic                    s_protect_o,   // split-branch protected carry
    output logic                    s_bp_valid_o,  // a CF was predicted this window
    output logic [G6LCCfg.VLEN-1:0] s_predict_o,   // selected target (comb)
    output logic                    spec_mark_o,   // window holds branch/ret/jalr
    output logic [G6LCCfg.VLEN-1:0] s_cf_pc_o,     // pc of the cf_select winner (loop-buffer end)
    // ---- registered verdict (applies next cycle via g6lc_fe_redirect)
    output logic                    ov2_valid_o,
    output logic [G6LCCfg.VLEN-1:0] ov2_pc_o,
    // ---- line-table training (registered with the verdict)
    output logic                    train_valid_o,
    output logic [G6LCCfg.VLEN-1:0] train_pc_o,
    output logic                    train_taken_o,
    output logic [G6LCCfg.VLEN-1:0] train_target_o,
    // the predicting slot's CF class is inside the tagged check's
    // adjudication domain (Return -> RAS; JumpR -> tagged BTB only where
    // g6lc_fe_btb_check's i_chk_btb is live). Only such verdicts may leave
    // a taken guess in the untagged line table: a guess the check cannot
    // back re-fires override #1 on every revisit.
    output logic                    train_tagdom_o
);

  localparam int unsigned NrInstr = G6LCCfg.INSTR_PER_FETCH;
  localparam int unsigned IdxW = (NrInstr > 1) ? $clog2(NrInstr) : 1;
  localparam int unsigned EW = (HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1;
  // Mirrors gen_no_chk_btb in g6lc_fe_btb_check: the tagged check can only
  // back a JumpR guess where its tagged BTB instance is live. Under
  // TAGE_LITE + BPIndirectEn that instance is compiled out, leaving the RAS
  // as the only adjudicator — Return guesses alone are tag-domain.
  localparam bit CHK_TAGGED_BTB =
      (G6LCCfg.BTBEntries != 0) && HypCfg.FeOverridePred
      && !(G6LCCfg.BPType == config_pkg::TAGE_LITE && G6LCCfg.BPIndirectEn);

  // ------------------------------------------------------------------
  // Stage L — lookup register
  // ------------------------------------------------------------------
  logic                    l_valid_q;
  logic [G6LCCfg.VLEN-1:0] l_vaddr_q;
  logic [EW-1:0]           l_epoch_q;
  logic                    l_line_taken_q;
  logic [G6LCCfg.VLEN-1:0] l_line_target_q;
  logic                    l_unaligned_q;
  logic                    l_carry_done_q;
  logic [63:0]             l_present_exp_q;
  logic [NrInstr-1:0]      l_vld_q;
  logic [NrInstr-1:0][31:0] l_instr_q;
  logic [NrInstr-1:0][G6LCCfg.VLEN-1:0] l_addr_q, l_base_q, l_off_q;
  ras_t                        l_ras_q;
  // prediction saved for the carried lower half: the uppermost position's
  // prediction of the PREVIOUS window (bht_q/btb_q of the reference)
  bht_prediction_t prev_bht_q;
  btb_prediction_t prev_btb_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      l_valid_q       <= 1'b0;
      l_vaddr_q       <= '0;
      l_epoch_q       <= '0;
      l_line_taken_q  <= 1'b0;
      l_line_target_q <= '0;
      l_unaligned_q   <= 1'b0;
      l_carry_done_q  <= 1'b0;
      l_present_exp_q <= '0;
      l_vld_q         <= '0;
      l_instr_q       <= '0;
      l_addr_q        <= '0;
      l_base_q        <= '0;
      l_off_q         <= '0;
      l_ras_q         <= '0;
      prev_bht_q      <= '0;
      prev_btb_q      <= '0;
    end else begin
      l_valid_q       <= win_valid_i & ~flush_i;
      l_vaddr_q       <= win_vaddr_i;
      l_epoch_q       <= win_epoch_i;
      l_line_taken_q  <= win_line_taken_i;
      l_line_target_q <= win_line_target_i;
      l_unaligned_q   <= serving_unaligned_i;
      l_carry_done_q  <= carry_done_i;
      l_present_exp_q <= present_exp_i;
      l_vld_q         <= vld_raw_i;
      l_instr_q       <= instr_i;
      l_addr_q        <= addr_i;
      l_base_q        <= base_i;
      l_off_q         <= off_i;
      l_ras_q         <= ras_predict_i;
      // save this window's uppermost-position prediction for a successor
      // whose slot0 completes a split instruction (reference bht_q/btb_q).
      // hyp8: the verdicts are registered by the fabric and live during the
      // stage-S cycle, so the save edge is the stage-S edge.
      if (l_valid_q) begin
        prev_bht_q <= bht_pred_i[NrInstr-1];
        prev_btb_q <= btb_pred_i[NrInstr-1];
      end
    end
  end

  // ------------------------------------------------------------------
  // Stage S — prefix filter, classify, cf_select, verdict
  // svt-stage: begin S
  // ------------------------------------------------------------------
  logic s_live;
  assign s_live = l_valid_q && (l_epoch_q == epoch_i);

  // Per-slot shifted prediction (serving_unaligned slot0 uses the saved
  // uppermost prediction of the previous window)
  bht_prediction_t [NrInstr-1:0] bht_shifted;
  btb_prediction_t [NrInstr-1:0] btb_shifted;
  for (genvar i = 0; i < NrInstr; i++) begin : gen_pred_shift
    logic [IdxW-1:0] sel;
    assign sel = l_addr_q[i][IdxW:1] & IdxW'(NrInstr - 1);
    if (i == 0) begin : gen_head
      assign bht_shifted[0] = l_unaligned_q ? prev_bht_q : bht_pred_i[sel];
      assign btb_shifted[0] = l_unaligned_q ? prev_btb_q : btb_pred_i[sel];
    end else begin : gen_tail
      assign bht_shifted[i] = bht_pred_i[sel];
      assign btb_shifted[i] = btb_pred_i[sel];
    end
  end

  // L2 live[]: drop slots with pc < present_exp. Same-window sequential HIT
  // of a forward jump target must not re-issue the +offset/ret prefix; direct
  // jal/call are kept (slot_keep_link). Carried verbatim from the reference.
  logic [NrInstr-1:0] instruction_valid;
  always_comb begin
    for (int unsigned i = 0; i < NrInstr; i++) begin
      instruction_valid[i] = g6lc_fetch_pkg::slot_live(
          l_vld_q[i],
          1'b1,
          g6lc_fetch_pkg::slot_keep_link(
              g6lc_fetch_pkg::slot_ge_expected(
`ifdef G6LC_NO_PREFIX_FILTER
                  1'b1,
`else
                  (i == 0) && l_unaligned_q,
`endif
                  64'(l_addr_q[i]),
                  l_present_exp_q),
              rvi_jump_i[i] | rvc_jump_i[i] | rvi_call_i[i] | rvc_call_i[i]));
    end
  end

  // direct targets as one three-operand sum each (base + off + imm)
  logic [NrInstr-1:0][G6LCCfg.VLEN-1:0] direct_rvi_target, direct_rvc_target;
  for (genvar i = 0; i < NrInstr; i++) begin : gen_direct_target
    assign direct_rvi_target[i] = l_base_q[i] + l_off_q[i] + rvi_imm_i[i];
    assign direct_rvc_target[i] = l_base_q[i] + l_off_q[i] + rvc_imm_i[i];
  end

  logic [NrInstr-1:0] is_branch, is_call, is_jump, is_return, is_jalr;
  for (genvar i = 0; i < NrInstr; i++) begin : gen_cf_class
    assign is_branch[i] = instruction_valid[i] & (rvi_branch_i[i] | rvc_branch_i[i]);
    assign is_call[i]   = instruction_valid[i] & (rvi_call_i[i] | rvc_call_i[i]);
    assign is_return[i] = instruction_valid[i] & (rvi_return_i[i] | rvc_return_i[i]);
    assign is_jump[i]   = instruction_valid[i] & (rvi_jump_i[i] | rvc_jump_i[i]);
    assign is_jalr[i]   = instruction_valid[i] & ~is_return[i]
                          & (rvi_jalr_i[i] | rvc_jalr_i[i] | rvc_jr_i[i]);
  end

  // taken/not-taken and target select. Each slot computes its own
  // target. The lowest slot that writes a prediction wins, which is the
  // same result as the old high-to-low overwrite, without a serial chain
  // of target muxes. The three-operand address adds stay per slot.
  cf_t [NrInstr-1:0] cf_type;
  logic [NrInstr-1:0] taken_rvi_cf, taken_rvc_cf;
  logic [NrInstr-1:0] slot_pred_v, slot_cf_v, slot_call_v;
  logic [NrInstr-1:0] slot_ras_pop;
  logic [NrInstr-1:0][G6LCCfg.VLEN-1:0] slot_pred, slot_ras_upd;
  logic [G6LCCfg.VLEN-1:0] predict_address;
  logic                    pred_tagdom;
  logic [G6LCCfg.VLEN-1:0] sel_cf_pc;
  logic ras_push_d, ras_pop_d;
  logic [G6LCCfg.VLEN-1:0] ras_update_d;

  for (genvar i = 0; i < NrInstr; i++) begin : gen_cf_slot
    always_comb begin
      cf_type[i]      = NoCF;
      taken_rvi_cf[i] = 1'b0;
      taken_rvc_cf[i] = 1'b0;
      slot_pred_v[i]  = 1'b0;
      slot_pred[i]    = '0;
      slot_ras_pop[i] = 1'b0;
      slot_ras_upd[i] = '0;
      unique case ({
        is_branch[i], is_return[i], is_jump[i], is_jalr[i]
      })
        4'b0000: ;
        4'b0001: begin
          if (G6LCCfg.BTBEntries != 0 && btb_shifted[i].valid) begin
            slot_pred[i]   = btb_shifted[i].target_address;
            slot_pred_v[i] = 1'b1;
            cf_type[i]     = JumpR;
          end
        end
        4'b0010: begin
          taken_rvi_cf[i] = rvi_jump_i[i];
          taken_rvc_cf[i] = rvc_jump_i[i];
          cf_type[i]      = Jump;
        end
        4'b0100: begin
          if (l_ras_q.valid) begin
            slot_ras_pop[i] = consumed_i[i];
            slot_pred[i]    = l_ras_q.ra;
            slot_pred_v[i]  = 1'b1;
            cf_type[i]      = Return;
          end
        end
        4'b1000: begin
          if (bht_shifted[i].valid) begin
            taken_rvi_cf[i] = rvi_branch_i[i] & bht_shifted[i].taken;
            taken_rvc_cf[i] = rvc_branch_i[i] & bht_shifted[i].taken;
          end else begin
            taken_rvi_cf[i] = rvi_branch_i[i] & rvi_imm_i[i][G6LCCfg.VLEN-1];
            taken_rvc_cf[i] = rvc_branch_i[i] & rvc_imm_i[i][G6LCCfg.VLEN-1];
          end
          if (taken_rvi_cf[i] || taken_rvc_cf[i]) cf_type[i] = Branch;
        end
        default: ;
      endcase
      if (taken_rvc_cf[i] || taken_rvi_cf[i]) begin
        slot_pred[i]   = taken_rvc_cf[i] ? direct_rvc_target[i] : direct_rvi_target[i];
        slot_pred_v[i] = 1'b1;
      end
      if (is_call[i]) begin
        slot_ras_upd[i] = l_base_q[i] + l_off_q[i] + (rvc_call_i[i] ? G6LCCfg.VLEN'(2) : G6LCCfg.VLEN'(4));
      end
      // Leftover-complete RVI jal is slot0 and wins over every later slot.
      if (i == 0 && l_unaligned_q && instruction_valid[0] && rvi_jump_i[0]) begin
        cf_type[0]      = Jump;
        taken_rvi_cf[0] = 1'b1;
        slot_pred[0]    = direct_rvi_target[0];
        slot_pred_v[0]  = 1'b1;
        if (rvi_call_i[0]) begin
          slot_ras_upd[0] = l_base_q[0] + l_off_q[0] + G6LCCfg.VLEN'(4);
        end
      end
    end
    assign slot_cf_v[i]   = (cf_type[i] != NoCF);
    assign slot_call_v[i] = is_call[i];
  end

  // Lowest set index wins, matching the old descending overwrite.
  logic [NrInstr-1:0] pred_win, cf_win, call_win;
  logic [NrInstr-1:0] pred_prefix, cf_prefix, call_prefix;
  for (genvar i = 0; i < NrInstr; i++) begin : gen_cf_win
    if (i == 0) begin : gen_first
      assign pred_prefix[0] = slot_pred_v[0];
      assign cf_prefix[0]   = slot_cf_v[0];
      assign call_prefix[0] = slot_call_v[0];
    end else begin : gen_rest
      assign pred_prefix[i] = pred_prefix[i-1] | slot_pred_v[i];
      assign cf_prefix[i]   = cf_prefix[i-1]   | slot_cf_v[i];
      assign call_prefix[i] = call_prefix[i-1] | slot_call_v[i];
    end
    assign pred_win[i] = slot_pred_v[i] && (i == 0 || !pred_prefix[i-1]);
    assign cf_win[i]   = slot_cf_v[i]   && (i == 0 || !cf_prefix[i-1]);
    assign call_win[i] = slot_call_v[i] && (i == 0 || !call_prefix[i-1]);
  end

  always_comb begin : cf_reduce
    predict_address = '0;
    pred_tagdom     = 1'b0;
    sel_cf_pc       = '0;
    ras_update_d    = '0;
    ras_push_d      = 1'b0;
    for (int i = 0; i < NrInstr; i++) begin
      // pred_win / cf_win / call_win are one-hot, so this is an OR tree.
      predict_address |= pred_win[i] ? slot_pred[i] : '0;
      pred_tagdom     |= pred_win[i]
                         && ((cf_type[i] == JumpR && CHK_TAGGED_BTB)
                             || (cf_type[i] == Return));
      sel_cf_pc       |= cf_win[i]   ? l_addr_q[i]  : '0;
      ras_push_d      |= call_win[i] && consumed_i[i];
      ras_update_d    |= call_win[i] ? slot_ras_upd[i] : '0;
    end
    // A return slot sets ras_pop and a lower non-return does not clear it.
    ras_pop_d = |slot_ras_pop;
  end

  logic bp_valid;
  always_comb begin : bp_valid_reduce
    bp_valid = 1'b0;
    for (int i = 0; i < NrInstr; i++) bp_valid |= (cf_type[i] != NoCF);
  end

  // fetchable + actually consumed (reference I19/L4 gates)
  logic [7:0] cf_v8, cf_t8, cf_c8;
  always_comb begin
    cf_v8 = '0; cf_t8 = '0; cf_c8 = '0;
    cf_v8[NrInstr-1:0] = instruction_valid;
    cf_c8[NrInstr-1:0] = consumed_i;
    for (int i = 0; i < NrInstr; i++) cf_t8[i] = (cf_type[i] != NoCF);
  end

  logic bp_fire_live;
  assign bp_fire_live = s_live && bp_valid
      && g6lc_fetch_pkg::predict_fetchable(G6LCCfg, 64'(predict_address), fetch_translation_en_i)
      && g6lc_fetch_pkg::cf_consumed(cf_v8, cf_t8, cf_c8);

  // ------------------------------------------------------------------
  // Queue presentation (stage-S comb) — the window must be live and its
  // epoch current; dead windows present nothing
  // ------------------------------------------------------------------
  assign s_valid_o             = s_live;
  assign s_win_o               = l_valid_q;
  assign s_vaddr_o             = l_vaddr_q;
  assign s_instr_o             = l_instr_q;
  assign s_addr_o              = l_addr_q;
  assign iq_valid_o            = s_live ? instruction_valid : '0;
  assign iq_cf_type_o          = cf_type;
  assign iq_predict_address_o  = predict_address;
  assign iq_is_call_o          = is_call;
  assign iq_is_return_o        = is_return;
  // checkpoint allocation set = decoded CF class, not predicted type
  for (genvar i = 0; i < NrInstr; i++) begin : gen_bp_push_cf
    assign bp_push_cf_o[i] = s_live & (is_branch[i] | is_jump[i] | is_jalr[i] | is_return[i])
                            & consumed_i[i];
  end
  assign ras_push_o    = s_live & ras_push_d;
  assign ras_pop_o     = s_live & ras_pop_d;
  assign ras_update_o  = ras_update_d;
  assign spec_epoch_o  = l_epoch_q;
  // carry bookkeeping tracks window PRESENCE, not epoch liveness: a
  // dead-epoch completer still advertises s_carry_done_o, but the
  // frontend's restore gate is s_live-qualified, so a dead stream simply
  // leaves its eagerly-advanced carry bank untouched
  assign s_carry_done_o       = l_valid_q & l_carry_done_q;
  assign s_serving_unaligned_o = l_unaligned_q;
  // split-branch carry protection: the completing window predicted a taken
  // conditional branch at slot0 — its carry must survive for the replay
  assign s_protect_o = s_live & l_unaligned_q & (cf_type[0] == Branch) & bp_valid;
  assign s_bp_valid_o = bp_fire_live;
  assign s_predict_o  = predict_address;
  assign spec_mark_o  = s_live & (|is_branch | |is_return | |is_jalr);
  assign s_cf_pc_o    = sel_cf_pc;

  // ------------------------------------------------------------------
  // Verdict (registered) — override #2 + line training
  // ------------------------------------------------------------------
  // The recorded stream guess for the block after this window came from the
  // request-time accept (want_*_line regs / FTQ entry). Agreement = the
  // fetch stream is already headed to the predicted target.
  logic guess_ok;
  assign guess_ok = bp_valid &&
      ((l_line_taken_q && (l_line_target_q == predict_address)));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ov2_valid_o    <= 1'b0;
      ov2_pc_o       <= '0;
      train_valid_o  <= 1'b0;
      train_pc_o     <= '0;
      train_taken_o  <= 1'b0;
      train_target_o <= '0;
      train_tagdom_o <= 1'b0;
    end else if (flush_i) begin
      ov2_valid_o   <= 1'b0;
      train_valid_o <= 1'b0;
    end else begin
      // Override #2: a live window whose verdict disagrees with what the
      // stream fetched next. FeOverridePred=0 still fires — the verdict IS
      // the reference bp_fire, one registered record later.
      ov2_valid_o <= bp_fire_live && !guess_ok;
      ov2_pc_o    <= predict_address;
      // Line training: every live verdict teaches the table the outcome for
      // this window's block (taken -> target; no CF -> clear).
      train_valid_o  <= s_live;
      train_pc_o     <= l_vaddr_q;
      train_taken_o  <= bp_fire_live;
      train_target_o <= predict_address;
      train_tagdom_o <= pred_tagdom;
    end
  end
  // svt-stage: end S
  // svt-stage: class S value

endmodule
