// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget; registered
// update record + checkpoint-carried training token added for Hyp8)
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
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type bht_update_t = logic,
    parameter type btb_update_t = logic,
    parameter type btb_prediction_t = logic,
    // T21: width of the checkpoint index carried by branch_predict.ckpt_idx,
    // and the RAS top-of-stack checkpoint field widths (ras PTR_W / CNT_W)
    parameter int unsigned CKPT_IDX_W = 8,
    parameter int unsigned RAS_PTR_W = (G6LCCfg.RASDepth <= 1) ? 1 : $clog2(G6LCCfg.RASDepth),
    parameter int unsigned RAS_CNT_W = (G6LCCfg.RASDepth < 1) ? 1 : $clog2(G6LCCfg.RASDepth + 1)
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    flush_bp_i,
    input  logic                    debug_mode_i,
    // U6.1: active fetch hart for banked GHR read / predict
    input  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] hart_i,
    // FSE S5: resolve/train hart for ckpt push/pop/restore and GHR train
    input  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] resolve_hart_i,
    // T21: IF-level flush that is not a mispredict (switch / commit replay):
    // the fetch hart's consumed CFs die unresolved, drop its checkpoints
    input  logic                    clear_i,
    // Prediction-time checkpoint allocation: one bit per fetch slot carrying a
    // real control-flow instruction that was consumed by the instruction queue
    // this cycle. The allocated index per slot travels with the instruction.
    input  logic [G6LCCfg.INSTR_PER_FETCH-1:0] push_cf_i,
    output logic                    ckpt_alloc_v_o,
    output logic [G6LCCfg.INSTR_PER_FETCH-1:0][CKPT_IDX_W-1:0] ckpt_alloc_idx_o,
    // Any control-flow resolve this cycle (branch/jump/jalr/ret) frees its own
    // checkpoint (ckpt_v_i/ckpt_idx_i as carried by the instruction);
    // mispredict_i additionally restores from it and drops younger entries.
    input  logic                    cf_resolve_i,
    input  logic                    ckpt_v_i,
    input  logic [CKPT_IDX_W-1:0]   ckpt_idx_i,
    input  logic [G6LCCfg.VLEN-1:0] vpc_bht_i,
    input  logic [G6LCCfg.VLEN-1:0] vpc_btb_i,
    input  bht_update_t             bht_update_i,
    input  btb_update_t             btb_update_i,
    // Mispredict restore of GHR/RAS (from resolved branch path)
    input  logic                    mispredict_i,
    // T21: live RAS top-of-stack checkpoint of the fetch hart (ras snap_*_o)
    input  logic [RAS_PTR_W-1:0]    ras_tos_i,
    input  logic [RAS_CNT_W-1:0]    ras_cnt_i,
    input  logic [G6LCCfg.VLEN-1:0] ras_top_i,
    // T21: restore the RAS top-of-stack checkpoint -- on a mispredict (the
    // resolving CF's entry, ras_restore_own_o set: the frontend re-applies
    // that CF's own push/pop) or on clear_i (the fetch hart's oldest live
    // entry = the restart frontier context; no own effect). ras_restore_hart_o
    // names the bank.
    output logic                    ras_restore_o,
    output logic                    ras_restore_own_o,
    output logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] ras_restore_hart_o,
    output logic [RAS_PTR_W-1:0]    ras_restore_tos_o,
    output logic [RAS_CNT_W-1:0]    ras_restore_cnt_o,
    output logic [G6LCCfg.VLEN-1:0] ras_restore_top_o,
    output bht_prediction_t [G6LCCfg.INSTR_PER_FETCH-1:0] bht_prediction_o,
    output btb_prediction_t [G6LCCfg.INSTR_PER_FETCH-1:0] btb_prediction_o
);

  localparam int unsigned GHIST_LEN =
      (G6LCCfg.BPGhistLen != 0) ? G6LCCfg.BPGhistLen : 24;
  localparam int unsigned NR_TABLES =
      (G6LCCfg.BPTageTables != 0) ? G6LCCfg.BPTageTables : 3;
  localparam int unsigned TABLE_ENTRIES =
      (G6LCCfg.BPTageTableEntries != 0) ? G6LCCfg.BPTageTableEntries : 64;
  localparam int unsigned TAG_BITS =
      (G6LCCfg.BPTageTagBits != 0) ? G6LCCfg.BPTageTagBits : 8;
  localparam int unsigned CKPT_DEPTH =
      (G6LCCfg.BPCkptDepth != 0) ? G6LCCfg.BPCkptDepth : 8;
  localparam int unsigned IND_ENTRIES =
      (G6LCCfg.BPIndirectEntries != 0) ? G6LCCfg.BPIndirectEntries : 32;
  localparam int unsigned FOLD_W = 8;
  localparam int unsigned NR_FOLDS = 8;

  localparam int unsigned CKPT_IDX_LOCAL = (CKPT_DEPTH <= 1) ? 1 : $clog2(CKPT_DEPTH);
  localparam int unsigned TBL_IDX_W = (TABLE_ENTRIES <= 1) ? 1 : $clog2(TABLE_ENTRIES);
  localparam int unsigned ITT_IDX_W =
      ((IND_ENTRIES / G6LCCfg.INSTR_PER_FETCH) <= 1) ? 1
          : $clog2(IND_ENTRIES / G6LCCfg.INSTR_PER_FETCH);
  localparam int unsigned HID_W =
      (G6LCCfg.NrHarts <= 1) ? 1 : $clog2(G6LCCfg.NrHarts);

  // hyp8: the checkpoint-carried lookup token — the verdict-time index/tag
  // the pushed CF's own lookup used. Training replays these fields instead of
  // recomputing the folded hash on the update path.
  typedef struct packed {
    logic [NR_TABLES-1:0][TBL_IDX_W-1:0] tage_idx;
    logic [NR_TABLES-1:0][TAG_BITS-1:0]  tage_tag;
    logic [ITT_IDX_W-1:0]                itt_idx;
    logic [TAG_BITS-1:0]                 itt_tag;
  } bp_lktok_t;

  logic [GHIST_LEN-1:0] ghist, train_ghist, ckpt_ghist;
  logic [NR_FOLDS-1:0][FOLD_W-1:0] folded, folded_src;
  logic hist_upd_v, hist_upd_taken;
  logic restore_v;
  logic ckpt_entry_v;
  bp_lktok_t ckpt_entry_tok;
  // The GHR bank only ever shifts in resolved (architectural) outcomes, so a
  // mispredict never needs a GHR restore — there is no speculative history to
  // unwind. flush_bp_i remains the only reset of a bank.
  logic ghist_flush;
  assign ghist_flush = flush_bp_i;

  // hyp8: the update record is registered once here so the table-side update
  // runs on register outputs at resolve+1 — the same cycle the checkpoint's
  // registered entry read (token / ghist snapshot) is valid. The
  // architectural GHR shift keeps the resolve cycle (live record) so the
  // train-hart select and the fallback fold stay paired with the pop.
  bht_update_t upd_bht_q;
  btb_update_t upd_btb_q;
  logic [HID_W-1:0] resolve_hart_q;
  // Fallback update fold: the train hart's bank folded at the resolve cycle.
  logic [NR_FOLDS-1:0][FOLD_W-1:0] folded_upd_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      upd_bht_q      <= '0;
      upd_btb_q      <= '0;
      resolve_hart_q <= '0;
      folded_upd_q   <= '0;
    end else begin
      // A flushed update must not train after the tables were cleared.
      upd_bht_q       <= bht_update_i;
      upd_btb_q       <= btb_update_i;
      if (flush_bp_i) begin
        upd_bht_q.valid <= 1'b0;
        upd_btb_q.valid <= 1'b0;
      end
      resolve_hart_q  <= resolve_hart_i;
      folded_upd_q    <= folded_src;
    end
  end

  // Architectural GHR update on the live resolve record (resolve cycle), as
  // the reference did inside g6lc_bp_tage — moved here because the table-side
  // record is now the registered one.
  assign hist_upd_v     = bht_update_i.valid &&
      ((G6LCCfg.DebugEn && !debug_mode_i) || !G6LCCfg.DebugEn);
  assign hist_upd_taken = bht_update_i.taken;

  // FSE S5: train/resolve hart for update; fall back to fetch on bare flush_bp.
  // Covers the live resolve (pop / fallback fold / GHR shift) and the
  // registered update one cycle later.
  logic [HID_W-1:0] train_h;
  assign train_h = (hist_upd_v || mispredict_i || cf_resolve_i) ? resolve_hart_i
                 : hart_i;
  // Suppress pushes on a mispredict cycle: any window consumed then is
  // wrong-path and is being flushed, so its CFs never resolve.
  logic [G6LCCfg.INSTR_PER_FETCH-1:0] push_cf;
  assign push_cf = push_cf_i & {G6LCCfg.INSTR_PER_FETCH{~mispredict_i}};

  logic [G6LCCfg.INSTR_PER_FETCH-1:0][CKPT_IDX_W-1:0] alloc_idx;
  logic                 clear_rest;
  logic [RAS_PTR_W-1:0] entry_tos, clear_tos;
  logic [RAS_CNT_W-1:0] entry_cnt, clear_cnt;
  logic [G6LCCfg.VLEN-1:0] entry_top, clear_top;

  // hyp8: verdict-time lookup tokens from the predictors, packed per pushed
  // slot for the checkpoint entry.
  logic [NR_TABLES-1:0][G6LCCfg.INSTR_PER_FETCH-1:0][TBL_IDX_W-1:0] tage_lk_idx;
  logic [NR_TABLES-1:0][G6LCCfg.INSTR_PER_FETCH-1:0][TAG_BITS-1:0]  tage_lk_tag;
  logic [G6LCCfg.INSTR_PER_FETCH-1:0][ITT_IDX_W-1:0]                itt_lk_idx;
  logic [G6LCCfg.INSTR_PER_FETCH-1:0][TAG_BITS-1:0]                 itt_lk_tag;
  logic [G6LCCfg.INSTR_PER_FETCH-1:0][$bits(bp_lktok_t)-1:0] push_tok;
  always_comb begin
    bp_lktok_t tok;
    for (int unsigned k = 0; k < G6LCCfg.INSTR_PER_FETCH; k++) begin
      for (int unsigned t = 0; t < NR_TABLES; t++) begin
        tok.tage_idx[t] = tage_lk_idx[t][k];
        tok.tage_tag[t] = tage_lk_tag[t][k];
      end
      tok.itt_idx = itt_lk_idx[k];
      tok.itt_tag = itt_lk_tag[k];
      push_tok[k] = tok;
    end
  end

  bht_prediction_t [G6LCCfg.INSTR_PER_FETCH-1:0] tage_pred, loop_pred, sc_pred;
  btb_prediction_t [G6LCCfg.INSTR_PER_FETCH-1:0] ittage_pred;

  // ----- GHR + folds -----
  // Live read: fetch hart. Train/update/restore: resolve hart (FSE S5).
  g6lc_bp_ghist #(
      .G6LCCfg  (G6LCCfg),
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
      // hyp8: the update fallback fold is always the train hart's live bank —
      // the checkpoint's own ghist snapshot is no longer needed for training
      // (the token carries the lookup's index/tag), so the source is fixed.
      .fold_src_i       (train_ghist),
      .ghist_o          (ghist),
      .train_ghist_o    (train_ghist),
      .folded_o         (folded),
      .folded_src_o     (folded_src)
  );

  // ----- Checkpoint (GHR + RAS top-of-stack), banked per hart (FSE S5) -----
  // T21: indexed; the entry index travels with the instruction and comes back
  // with its resolution (ckpt_v_i / ckpt_idx_i).
  if (G6LCCfg.BPCkptDepth != 0) begin : gen_ckpt
    if (CKPT_IDX_W < CKPT_IDX_LOCAL) begin : gen_err_ckpt_idx_width
      $error("g6lc_bp_top: the carried checkpoint index is narrower than BPCkptDepth needs");
    end

    g6lc_bp_ckpt #(
        .G6LCCfg  (G6LCCfg),
        .GHIST_LEN(GHIST_LEN),
        .DEPTH    (CKPT_DEPTH),
        .RAS_DEPTH(G6LCCfg.RASDepth),
        .RAS_PTR_W(RAS_PTR_W),
        .RAS_CNT_W(RAS_CNT_W),
        .RAS_VLEN (G6LCCfg.VLEN),
        .TOK_W    ($bits(bp_lktok_t)),
        .NR_PUSH  (G6LCCfg.INSTR_PER_FETCH),
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
        // hyp8: each pushed slot's checkpoint entry stores that slot's
        // registered lookup token (the index/tag its lookup used).
        .push_tok_i       (push_tok),
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
        .entry_tok_o      (ckpt_entry_tok),
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
    assign ras_restore_o      = (G6LCCfg.RASDepth != 0) && (clear_rest || restore_v);
    assign ras_restore_own_o  = !clear_rest && restore_v;
    assign ras_restore_hart_o = clear_rest ? hart_i : resolve_hart_i;
    assign ras_restore_tos_o  = clear_rest ? clear_tos : entry_tos;
    assign ras_restore_cnt_o  = clear_rest ? clear_cnt : entry_cnt;
    assign ras_restore_top_o  = clear_rest ? clear_top : entry_top;
  end else begin : gen_no_ckpt
    assign restore_v          = 1'b0;
    assign ckpt_entry_v       = 1'b0;
    assign ckpt_ghist         = '0;
    assign ckpt_entry_tok     = '0;
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
  // hyp8: the lookup uses the live fetch-hart folds; the update uses the
  // checkpoint token (the index/tag the resolving CF's own lookup used) when
  // its entry lives, else the registered train-bank fallback fold. The
  // architectural GHR shift is generated here on the live resolve record so
  // it keeps the resolve cycle; the table updates run one cycle later on the
  // registered record.
  logic [NR_TABLES-1:0][FOLD_W-1:0] folded_use, folded_update_use;
  for (genvar t = 0; t < NR_TABLES; t++) begin : gen_fold_use
    assign folded_use[t]        = folded[t];
    assign folded_update_use[t] = folded_upd_q[t];
  end
  // Token fields for the TAGE update (resolve+1, aligned with upd_*_q).
  logic [NR_TABLES-1:0][TBL_IDX_W-1:0] tok_tage_idx;
  logic [NR_TABLES-1:0][TAG_BITS-1:0]  tok_tage_tag;
  for (genvar t = 0; t < NR_TABLES; t++) begin : gen_tok_sel
    assign tok_tage_idx[t] = ckpt_entry_tok.tage_idx[t];
    assign tok_tage_tag[t] = ckpt_entry_tok.tage_tag[t];
  end

  g6lc_bp_tage #(
      .G6LCCfg       (G6LCCfg),
      .bht_update_t  (bht_update_t),
      .NR_ENTRIES    (G6LCCfg.BHTEntries),
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
      .upd_tok_v_i         (ckpt_entry_v),
      .upd_tok_idx_i       (tok_tage_idx),
      .upd_tok_tag_i       (tok_tage_tag),
      .bht_update_i        (upd_bht_q),
      .bht_prediction_o    (tage_pred),
      .lk_index_o          (tage_lk_idx),
      .lk_tag_o            (tage_lk_tag),
      .hist_update_valid_o (),
      .hist_update_taken_o ()
  );

  if (G6LCCfg.BPLoopEn) begin : gen_loop
    g6lc_bp_loop #(
        .G6LCCfg     (G6LCCfg),
        .bht_update_t(bht_update_t),
        .NR_ENTRIES  (16)
    ) i_loop (
        .clk_i,
        .rst_ni,
        .flush_i      (flush_bp_i),
        .vpc_i        (vpc_bht_i),
        // hyp8: registered resolve record (resolve+1, token/entry aligned)
        .bht_update_i (upd_bht_q),
        .pred_i       (tage_pred),
        .pred_o       (loop_pred)
    );
  end else begin : gen_no_loop
    assign loop_pred = tage_pred;
  end

  if (G6LCCfg.BPStatCorEn) begin : gen_sc
    g6lc_bp_statcor #(
        .G6LCCfg     (G6LCCfg),
        .bht_update_t(bht_update_t),
        .NR_ENTRIES  (64)
    ) i_sc (
        .clk_i,
        .rst_ni,
        .flush_i      (flush_bp_i),
        .vpc_i        (vpc_bht_i),
        // hyp8: registered resolve record (resolve+1)
        .bht_update_i (upd_bht_q),
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

  if (G6LCCfg.BPIndirectEn) begin : gen_ittage
    g6lc_bp_ittage #(
        .G6LCCfg           (G6LCCfg),
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
        // hyp8: registered train-bank fallback fold + checkpoint token +
        // registered resolve record (same contract as i_tage).
        .folded_update_i(folded_upd_q[0]),
        .upd_tok_v_i   (ckpt_entry_v),
        .upd_tok_idx_i (ckpt_entry_tok.itt_idx),
        .upd_tok_tag_i (ckpt_entry_tok.itt_tag),
        .btb_update_i  (upd_btb_q),
        .btb_prediction_o(ittage_pred),
        .lk_index_o    (itt_lk_idx),
        .lk_tag_o      (itt_lk_tag)
    );
    assign btb_prediction_o = ittage_pred;
  end else begin : gen_no_ittage
    assign btb_prediction_o = '0;
    assign itt_lk_idx       = '0;
    assign itt_lk_tag       = '0;
  end

endmodule
