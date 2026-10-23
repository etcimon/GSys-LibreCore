// hyp8 provenance: REWRITTEN for the 8-FO4 frontend (BTB check / override #1)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_fe_btb_check — override #1.
//
// One cycle after a fetch target is pushed (the line table's guess already
// steering npc_d), this block checks the TAGGED predictors against the
// guess:
//   * a dedicated BTB lookup on the pushed block address answers "which
//     slot position carries a taken control flow, and to where" — the
//     lowest-position hit wins, matching the cf_select convention;
//   * the RAS top-of-stack covers the case the BTB does not track: a
//     predicted target equal to the RAS top is a return the untagged line
//     learned correctly — no override.
//
// Disagreement issues an override #1 record {pc, epoch-bump}: every younger
// fetch dies by epoch. The restart target is the queue frontier
// (resume_pc_i — the successor of the newest instruction the queue has
// accepted), NOT the tagged target and NOT next_block: the epoch kill drops
// every in-flight window between the queue tail and this block, and only a
// resume at the frontier refetches them (osbi fdt_next_tag: a stale
// line-table taken on the ret block squelched the stream to next_block and
// skipped the whole dispatch tail). Queue-owned entries still deliver and
// retire; the checked block's CF then resolves architecturally against the
// tagged predictors/RAS at execute time.
//
// The check is off both critical paths: the npc loop uses the line table
// (same cycle), the response path uses the response-keyed predictors (stage
// L/S). This is a third, block-keyed look at the shared BTB contents — a
// small duplicate lookup array, updated by the same btb_update stream.
//
// Cut: rank 3 (overlap + epoch kill); +1 cycle for a wrong line guess.

module g6lc_fe_btb_check
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8,
    parameter type btb_update_t = logic,
    parameter type btb_prediction_t = logic,
    parameter type ras_t = logic
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    flush_bp_i,
    input  logic                    debug_mode_i,
    // current fetch epoch — a pending check whose epoch died is dropped
    input  logic [((HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1)-1:0] epoch_i,
    // The pushed block and the guess that pushed it (registered here)
    input  logic                    push_valid_i,
    input  logic [G6LCCfg.VLEN-1:0] push_vaddr_i,
    input  logic [((HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1)-1:0] push_epoch_i,
    input  logic                    push_line_taken_i,
    input  logic [G6LCCfg.VLEN-1:0] push_line_target_i,
    // Predictor updates (shared with the response-path BTB)
    input  btb_update_t             btb_update_i,
    // RAS top-of-stack snapshot (fetch hart)
    input  ras_t                    ras_predict_i,
    // Queue-owned stream frontier for the restart: the successor of the
    // newest instruction the queue has accepted for the checked window's
    // hart. Combinational, sampled the cycle the check fires.
    input  logic [G6LCCfg.VLEN-1:0] resume_pc_i,
    // Override #1 record (one-cycle pulse when the tagged check disagrees)
    output logic                    ov1_valid_o,
    output logic [G6LCCfg.VLEN-1:0] ov1_pc_o,
    // Line-table training hint from the tagged check: a BTB hit teaches the
    // line the tagged target; a miss where the line guessed taken unlearns it
    output logic                    train_valid_o,
    output logic [G6LCCfg.VLEN-1:0] train_pc_o,
    output logic                    train_taken_o,
    output logic [G6LCCfg.VLEN-1:0] train_target_o
);

  localparam g6lc_fetch_pkg::fetch_geo_t Geo = g6lc_fetch_pkg::geo(G6LCCfg);
  localparam int unsigned NrPos = G6LCCfg.INSTR_PER_FETCH;
  localparam int unsigned EW = (HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1;

  // ------------------------------------------------------------------
  // Push record: the guess is checked one cycle after the push
  // ------------------------------------------------------------------
  logic                    chk_valid_q;
  logic [G6LCCfg.VLEN-1:0] chk_vaddr_q;
  logic [EW-1:0]           chk_epoch_q;
  logic                    chk_line_taken_q;
  logic [G6LCCfg.VLEN-1:0] chk_line_target_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      chk_valid_q       <= 1'b0;
      chk_vaddr_q       <= '0;
      chk_epoch_q       <= '0;
      chk_line_taken_q  <= 1'b0;
      chk_line_target_q <= '0;
    end else begin
      chk_valid_q       <= push_valid_i;
      chk_vaddr_q       <= push_vaddr_i;
      chk_epoch_q       <= push_epoch_i;
      chk_line_taken_q  <= push_line_taken_i;
      chk_line_target_q <= push_line_target_i;
    end
  end

  // ------------------------------------------------------------------
  // Block-keyed tagged BTB lookup (owns its read port; shares updates)
  // ------------------------------------------------------------------
  btb_prediction_t [NrPos-1:0] chk_pred;

  if (G6LCCfg.BTBEntries == 0
      || !HypCfg.FeOverridePred
      || (G6LCCfg.BPType == config_pkg::TAGE_LITE && G6LCCfg.BPIndirectEn)) begin : gen_no_chk_btb
    // no tagged target predictor to check against (or checks disabled)
    assign chk_pred = '0;
  end else begin : gen_chk_btb
    btb #(
        .G6LCCfg         (G6LCCfg),
        .btb_update_t    (btb_update_t),
        .btb_prediction_t(btb_prediction_t),
        .NR_ENTRIES      (G6LCCfg.BTBEntries)
    ) i_chk_btb (
        .clk_i,
        .rst_ni,
        .flush_bp_i,
        .debug_mode_i,
        .vpc_i           (chk_vaddr_q),
        .btb_update_i    (btb_update_i),
        .btb_prediction_o(chk_pred)
    );
  end

  // Lowest-position hit wins (cf_select iterates high-to-low and the lowest
  // keeps precedence through the final write).
  logic                    btb_hit;
  logic [G6LCCfg.VLEN-1:0] btb_target;
  always_comb begin
    btb_hit    = 1'b0;
    btb_target = '0;
    for (int unsigned i = 0; i < NrPos; i++) begin
      if (chk_pred[i].valid && !btb_hit) begin
        btb_hit    = 1'b1;
        btb_target = chk_pred[i].target_address;
      end
    end
  end

  // RAS covers returns (BTB does not track them): a line target equal to the
  // RAS top is the tagged predictor agreeing.
  logic ras_agree;
  assign ras_agree = ras_predict_i.valid && (ras_predict_i.ra == chk_line_target_q);

  logic live;
  assign live = chk_valid_q && (chk_epoch_q == epoch_i);

  // ---- verdict
  // 1) BTB hit disagrees with the guess (not-taken guess, or wrong target
  //    that the RAS cannot explain as a correct return prediction).
  // 2) taken guess with no tagged backing (no BTB hit, RAS disagrees):
  //    fall through sequentially.
  logic ov1;
  logic [G6LCCfg.VLEN-1:0] ov1_pc;
  assign ov1 = live && HypCfg.FeOverridePred &&
      ((btb_hit && (!chk_line_taken_q ||
                    (chk_line_target_q != btb_target && !ras_agree))) ||
       (!btb_hit && chk_line_taken_q && !ras_agree));
  // The squelch restart is the queue frontier in both legs: restart after
  // the newest accepted instruction so the epoch-killed windows between the
  // queue tail and this block are refetched. The checked block's CF stays
  // queued and resolves at execute time (the tagged target, if right, is
  // reproposed by the stage-S verdict when the refetched block returns).
  assign ov1_pc = resume_pc_i;

  assign ov1_valid_o = ov1;
  assign ov1_pc_o    = ov1_pc;

  // Training: a live BTB disagreement teaches the line the tagged outcome —
  // the hit target on a hit, not-taken on a miss. A RAS-agreed taken guess is
  // already right and is left alone.
  assign train_valid_o  = live && HypCfg.FeNextlineUntagged && ov1;
  assign train_pc_o     = chk_vaddr_q;
  assign train_taken_o  = btb_hit;
  assign train_target_o = btb_target;

endmodule
