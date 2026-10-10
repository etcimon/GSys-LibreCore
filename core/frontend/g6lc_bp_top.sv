// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// U1 prediction fabric top: composes GHR, checkpoint (GHR + RAS top-of-stack),
// TAGE-lite, optional loop / SC / ITTAGE. FSE S2 / T21: every consumed control
// flow allocates a checkpoint whose tag travels with the instruction; its
// resolution addresses that entry for the update fold, and a mispredict
// restores the RAS from it (then re-applies the CF's own push/pop) and
// reclaims every younger entry. A resolve whose entry is gone falls back to
// the live history and leaves the RAS alone.

module g6lc_bp_top
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type bht_update_t = logic,
    parameter type btb_update_t = logic,
    parameter type btb_prediction_t = logic,
    // T21: width of the checkpoint index carried by branch_predict.ckpt_idx,
    // and the RAS top-of-stack checkpoint field widths (ras PTR_W / CNT_W)
    parameter int unsigned CKPT_IDX_W = 8,
    parameter int unsigned RAS_PTR_W = (CVA6Cfg.RASDepth <= 1) ? 1 : $clog2(CVA6Cfg.RASDepth),
    parameter int unsigned RAS_CNT_W = (CVA6Cfg.RASDepth < 1) ? 1 : $clog2(CVA6Cfg.RASDepth + 1)
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    flush_bp_i,
    input  logic                    debug_mode_i,
    // U6.1: active fetch hart for banked GHR read / predict
    input  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] hart_i,
    // FSE S5: resolve/train hart for ckpt push/pop/restore and GHR train
    input  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] resolve_hart_i,
    // T21: IF-level flush that is not a mispredict (switch / commit replay):
    // the fetch hart's consumed CFs die unresolved, drop its checkpoints
    input  logic                    clear_i,
    // Prediction-time checkpoint allocation: one bit per fetch slot carrying a
    // real control-flow instruction that was consumed by the instruction queue
    // this cycle. The allocated index per slot travels with the instruction.
    input  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] push_cf_i,
    output logic                    ckpt_alloc_v_o,
    output logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CKPT_IDX_W-1:0] ckpt_alloc_idx_o,
    // Any control-flow resolve this cycle (branch/jump/jalr/ret) frees its own
    // checkpoint (ckpt_v_i/ckpt_idx_i as carried by the instruction);
    // mispredict_i additionally restores from it and drops younger entries.
    input  logic                    cf_resolve_i,
    input  logic                    ckpt_v_i,
    input  logic [CKPT_IDX_W-1:0]   ckpt_idx_i,
    input  logic [CVA6Cfg.VLEN-1:0] vpc_bht_i,
    input  logic [CVA6Cfg.VLEN-1:0] vpc_btb_i,
    input  bht_update_t             bht_update_i,
    input  btb_update_t             btb_update_i,
    // Mispredict restore of GHR/RAS (from resolved branch path)
    input  logic                    mispredict_i,
    // T21: live RAS top-of-stack checkpoint of the fetch hart (ras snap_*_o)
    input  logic [RAS_PTR_W-1:0]    ras_tos_i,
    input  logic [RAS_CNT_W-1:0]    ras_cnt_i,
    input  logic [CVA6Cfg.VLEN-1:0] ras_top_i,
    // T21: restore the RAS top-of-stack checkpoint -- on a mispredict (the
    // resolving CF's entry, ras_restore_own_o set: the frontend re-applies
    // that CF's own push/pop) or on clear_i (the fetch hart's oldest live
    // entry = the restart frontier context; no own effect). ras_restore_hart_o
    // names the bank.
    output logic                    ras_restore_o,
    output logic                    ras_restore_own_o,
    output logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] ras_restore_hart_o,
    output logic [RAS_PTR_W-1:0]    ras_restore_tos_o,
    output logic [RAS_CNT_W-1:0]    ras_restore_cnt_o,
    output logic [CVA6Cfg.VLEN-1:0] ras_restore_top_o,
    output bht_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0] bht_prediction_o,
    output btb_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0] btb_prediction_o
);

  localparam int unsigned GHIST_LEN =
      (CVA6Cfg.BPGhistLen != 0) ? CVA6Cfg.BPGhistLen : 24;
  localparam int unsigned NR_TABLES =
      (CVA6Cfg.BPTageTables != 0) ? CVA6Cfg.BPTageTables : 3;
  localparam int unsigned TABLE_ENTRIES =
      (CVA6Cfg.BPTageTableEntries != 0) ? CVA6Cfg.BPTageTableEntries : 64;
  localparam int unsigned TAG_BITS =
      (CVA6Cfg.BPTageTagBits != 0) ? CVA6Cfg.BPTageTagBits : 8;
  localparam int unsigned CKPT_DEPTH =
      (CVA6Cfg.BPCkptDepth != 0) ? CVA6Cfg.BPCkptDepth : 8;
  localparam int unsigned IND_ENTRIES =
      (CVA6Cfg.BPIndirectEntries != 0) ? CVA6Cfg.BPIndirectEntries : 32;
  localparam int unsigned FOLD_W = 8;
  localparam int unsigned NR_FOLDS = 8;

  localparam int unsigned CKPT_IDX_LOCAL = (CKPT_DEPTH <= 1) ? 1 : $clog2(CKPT_DEPTH);

  logic [GHIST_LEN-1:0] ghist, train_ghist, ckpt_ghist, fold_src;
  logic [NR_FOLDS-1:0][FOLD_W-1:0] folded, folded_src;
  logic hist_upd_v, hist_upd_taken;
  logic restore_v;
  logic ckpt_entry_v;
  // The GHR bank only ever shifts in resolved (architectural) outcomes, so a
  // mispredict never needs a GHR restore — there is no speculative history to
  // unwind. flush_bp_i remains the only reset of a bank.
  logic ghist_flush;
  assign ghist_flush = flush_bp_i;
  // FSE S5: train/resolve hart for update; fall back to fetch on bare flush_bp
  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] train_h;
  assign train_h = (hist_upd_v || mispredict_i) ? resolve_hart_i : hart_i;

  // Update-fold source: the resolving CF's own prediction-time GHR snapshot
  // (its checkpoint entry, addressed by the index it carried) when that entry
  // is live, else the live train-hart bank (also the only source when
  // BPCkptDepth==0 or the window was not checkpointed).
  assign fold_src = ckpt_entry_v ? ckpt_ghist : train_ghist;
  // Suppress pushes on a mispredict cycle: any window consumed then is
  // wrong-path and is being flushed, so its CFs never resolve.
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] push_cf;
  assign push_cf = push_cf_i & {CVA6Cfg.INSTR_PER_FETCH{~mispredict_i}};

  logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CKPT_IDX_W-1:0] alloc_idx;
  logic                 clear_rest;
  logic [RAS_PTR_W-1:0] entry_tos, clear_tos;
  logic [RAS_CNT_W-1:0] entry_cnt, clear_cnt;
  logic [CVA6Cfg.VLEN-1:0] entry_top, clear_top;

  bht_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0] tage_pred, loop_pred, sc_pred;
  btb_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0] ittage_pred;

  // ----- GHR + folds -----
  // Live read: fetch hart. Train/update/restore: resolve hart (FSE S5).
  g6lc_bp_ghist #(
      .CVA6Cfg  (CVA6Cfg),
      .GHIST_LEN(GHIST_LEN),
      .NR_FOLDS (NR_FOLDS),
      .FOLD_W   (FOLD_W)
  ) i_ghist (
      .clk_i,
      .rst_ni,
      .flush_i          (ghist_flush),
      .hart_i           (hart_i),
      .train_hart_i     (train_h),
      // Every branch resolve shifts the actual outcome into the architectural
      // bank — including mispredicts (the real outcome belongs in history).
      .update_valid_i   (hist_upd_v),
      .update_taken_i   (hist_upd_taken),
      // Arch-GHR never restores: there is no speculative history to unwind.
      .restore_valid_i  (1'b0),
      .restore_ghist_i  ('0),
      .fold_src_i       (fold_src),
      .ghist_o          (ghist),
      .train_ghist_o    (train_ghist),
      .folded_o         (folded),
      .folded_src_o     (folded_src)
  );

  // ----- Checkpoint (GHR + RAS top-of-stack), banked per hart (FSE S5) -----
  // T21: indexed; the entry index travels with the instruction and comes back
  // with its resolution (ckpt_v_i / ckpt_idx_i).
  if (CVA6Cfg.BPCkptDepth != 0) begin : gen_ckpt
    if (CKPT_IDX_W < CKPT_IDX_LOCAL) begin : gen_err_ckpt_idx_width
      $error("g6lc_bp_top: the carried checkpoint index is narrower than BPCkptDepth needs");
    end

    g6lc_bp_ckpt #(
        .CVA6Cfg  (CVA6Cfg),
        .GHIST_LEN(GHIST_LEN),
        .DEPTH    (CKPT_DEPTH),
        .RAS_DEPTH(CVA6Cfg.RASDepth),
        .RAS_PTR_W(RAS_PTR_W),
        .RAS_CNT_W(RAS_CNT_W),
        .RAS_VLEN (CVA6Cfg.VLEN),
        .NR_PUSH  (CVA6Cfg.INSTR_PER_FETCH),
        .IDX_W    (CKPT_IDX_LOCAL),
        .TAG_W    (CKPT_IDX_W)
    ) i_ckpt (
        .clk_i,
        .rst_ni,
        .flush_i          (flush_bp_i),
        .clear_i          (clear_i),
        .clear_restore_o  (clear_rest),
        .clear_ras_tos_o  (clear_tos),
        .clear_ras_cnt_o  (clear_cnt),
        .clear_ras_top_o  (clear_top),
        .push_hart_i      (hart_i),
        .pop_hart_i       (resolve_hart_i),
        // Predict-time allocation: one entry per consumed CF slot, snapshotting
        // the live fetch-hart GHR and RAS top — the context the prediction used.
        .push_i           (push_cf),
        .push_ghist_i     (ghist),
        .push_ras_tos_i   (ras_tos_i),
        .push_ras_cnt_i   (ras_cnt_i),
        .push_ras_top_i   (ras_top_i),
        .alloc_v_o        (ckpt_alloc_v_o),
        .alloc_idx_o      (alloc_idx),
        .pop_i            (cf_resolve_i),
        .pop_v_i          (ckpt_v_i),
        .pop_idx_i        (ckpt_idx_i),
        .restore_i        (mispredict_i),
        .entry_valid_o    (ckpt_entry_v),
        .entry_ghist_o    (ckpt_ghist),
        .entry_ras_tos_o  (entry_tos),
        .entry_ras_cnt_o  (entry_cnt),
        .entry_ras_top_o  (entry_top),
        .restore_valid_o  (restore_v),
        .empty_o          (),
        .full_o           ()
    );
    assign ckpt_alloc_idx_o = alloc_idx;
    // clear and mispredict restore are exclusive by construction (clear_i is
    // the non-mispredict flush); the clear wins should they ever coincide.
    assign ras_restore_o      = (CVA6Cfg.RASDepth != 0) && (clear_rest || restore_v);
    assign ras_restore_own_o  = !clear_rest && restore_v;
    assign ras_restore_hart_o = clear_rest ? hart_i : resolve_hart_i;
    assign ras_restore_tos_o  = clear_rest ? clear_tos : entry_tos;
    assign ras_restore_cnt_o  = clear_rest ? clear_cnt : entry_cnt;
    assign ras_restore_top_o  = clear_rest ? clear_top : entry_top;
  end else begin : gen_no_ckpt
    assign restore_v          = 1'b0;
    assign ckpt_entry_v       = 1'b0;
    assign ckpt_ghist         = '0;
    assign alloc_idx          = '0;
    assign ckpt_alloc_v_o     = 1'b0;
    assign ckpt_alloc_idx_o   = '0;
    assign clear_rest         = 1'b0;
    assign entry_tos          = '0;
    assign entry_cnt          = '0;
    assign entry_top          = '0;
    assign clear_tos          = '0;
    assign clear_cnt          = '0;
    assign clear_top          = '0;
    assign ras_restore_o      = 1'b0;
    assign ras_restore_own_o  = 1'b0;
    assign ras_restore_hart_o = resolve_hart_i;
    assign ras_restore_tos_o  = '0;
    assign ras_restore_cnt_o  = '0;
    assign ras_restore_top_o  = '0;
  end

  // ----- TAGE direction -----
  // Update index/tag fold the resolving branch's prediction-time history
  // (checkpoint snapshot when live, train bank otherwise).
  logic [NR_TABLES-1:0][FOLD_W-1:0] folded_use, folded_update_use;
  for (genvar t = 0; t < NR_TABLES; t++) begin : gen_fold_use
    assign folded_use[t]        = folded[t];
    assign folded_update_use[t] = folded_src[t];
  end

  g6lc_bp_tage #(
      .CVA6Cfg       (CVA6Cfg),
      .bht_update_t  (bht_update_t),
      .NR_ENTRIES    (CVA6Cfg.BHTEntries),
      .NR_TABLES     (NR_TABLES),
      .TABLE_ENTRIES (TABLE_ENTRIES),
      .TAG_BITS      (TAG_BITS),
      .GHIST_LEN     (GHIST_LEN)
  ) i_tage (
      .clk_i,
      .rst_ni,
      .flush_bp_i,
      .debug_mode_i,
      .vpc_i               (vpc_bht_i),
      .ghist_i             (ghist),
      .folded_i            (folded_use),
      .folded_update_i     (folded_update_use),
      .bht_update_i        (bht_update_i),
      .bht_prediction_o    (tage_pred),
      .hist_update_valid_o (hist_upd_v),
      .hist_update_taken_o (hist_upd_taken)
  );

  if (CVA6Cfg.BPLoopEn) begin : gen_loop
    g6lc_bp_loop #(
        .CVA6Cfg     (CVA6Cfg),
        .bht_update_t(bht_update_t),
        .NR_ENTRIES  (16)
    ) i_loop (
        .clk_i,
        .rst_ni,
        .flush_i      (flush_bp_i),
        .vpc_i        (vpc_bht_i),
        .bht_update_i (bht_update_i),
        .pred_i       (tage_pred),
        .pred_o       (loop_pred)
    );
  end else begin : gen_no_loop
    assign loop_pred = tage_pred;
  end

  if (CVA6Cfg.BPStatCorEn) begin : gen_sc
    g6lc_bp_statcor #(
        .CVA6Cfg     (CVA6Cfg),
        .bht_update_t(bht_update_t),
        .NR_ENTRIES  (64)
    ) i_sc (
        .clk_i,
        .rst_ni,
        .flush_i      (flush_bp_i),
        .vpc_i        (vpc_bht_i),
        .bht_update_i (bht_update_i),
        .pred_i       (loop_pred),
        .pred_o       (sc_pred)
    );
  end else begin : gen_no_sc
    assign sc_pred = loop_pred;
  end

  // Direction is the end of the override chain TAGE -> loop -> statistical
  // corrector; each stage above tied itself through when disabled, so this is
  // a single assign rather than a mux. Indirect targets are ITTAGE's, below.
  assign bht_prediction_o = sc_pred;

  if (CVA6Cfg.BPIndirectEn) begin : gen_ittage
    g6lc_bp_ittage #(
        .CVA6Cfg           (CVA6Cfg),
        .btb_update_t      (btb_update_t),
        .btb_prediction_t  (btb_prediction_t),
        .NR_ENTRIES        (IND_ENTRIES),
        .TAG_BITS          (TAG_BITS),
        .FOLD_W            (FOLD_W)
    ) i_ittage (
        .clk_i,
        .rst_ni,
        .flush_i       (flush_bp_i),
        .debug_mode_i,
        .vpc_i         (vpc_btb_i),
        .folded_i      (folded[0]),
        .folded_update_i(folded_src[0]),
        .btb_update_i  (btb_update_i),
        .btb_prediction_o(ittage_pred)
    );
    assign btb_prediction_o = ittage_pred;
  end else begin : gen_no_ittage
    assign btb_prediction_o = '0;
  end

endmodule
