// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// U1 prediction fabric top: composes GHR, checkpoint (GHR+RAS), TAGE-lite,
// optional loop / SC / ITTAGE. FSE S2: restore GHR+RAS on mispredict; if the
// checkpoint is empty, flush GHR rather than silently desyncing history.

module g6lc_bp_top
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type bht_update_t = logic,
    parameter type btb_update_t = logic,
    parameter type btb_prediction_t = logic,
    parameter type ras_t = logic
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    flush_bp_i,
    input  logic                    debug_mode_i,
    // U6.1: active fetch hart for banked GHR read / predict
    input  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] hart_i,
    // FSE S5: resolve/train hart for ckpt push/pop/restore and GHR train
    input  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] resolve_hart_i,
    input  logic [CVA6Cfg.VLEN-1:0] vpc_bht_i,
    input  logic [CVA6Cfg.VLEN-1:0] vpc_btb_i,
    input  bht_update_t             bht_update_i,
    input  btb_update_t             btb_update_i,
    // Mispredict restore of GHR/RAS (from resolved branch path)
    input  logic                    mispredict_i,
    // FSE S2: live RAS stack for checkpointing (train-hart snapshot)
    input  ras_t [CVA6Cfg.RASDepth == 0 ? 0 : CVA6Cfg.RASDepth-1:0] ras_stack_i,
    // FSE S2: restore RAS stack on mispredict
    output logic                    ras_restore_o,
    output ras_t [CVA6Cfg.RASDepth == 0 ? 0 : CVA6Cfg.RASDepth-1:0] ras_restore_stack_o,
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
  localparam int unsigned RAS_D = (CVA6Cfg.RASDepth < 1) ? 1 : CVA6Cfg.RASDepth;

  logic [GHIST_LEN-1:0] ghist, train_ghist;
  logic [NR_FOLDS-1:0][FOLD_W-1:0] folded;
  logic hist_upd_v, hist_upd_taken;
  logic restore_v;
  logic [GHIST_LEN-1:0] restore_ghist;
  logic ckpt_empty;
  // Mispredict with empty ckpt: flush resolve-hart GHR rather than leave wrong-path history
  logic ghist_flush;
  assign ghist_flush = flush_bp_i | (mispredict_i && !restore_v);
  // FSE S5: train/resolve hart for update+restore; fall back to fetch on bare flush_bp
  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] train_h;
  assign train_h = (hist_upd_v || mispredict_i) ? resolve_hart_i : hart_i;

  logic [RAS_D-1:0] push_ras_v, rest_ras_v;
  logic [RAS_D-1:0][CVA6Cfg.VLEN-1:0] push_ras_ra, rest_ras_ra;

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
      .update_valid_i   (hist_upd_v && !restore_v),
      .update_taken_i   (hist_upd_taken),
      .restore_valid_i  (restore_v),
      .restore_ghist_i  (restore_ghist),
      .ghist_o          (ghist),
      .train_ghist_o    (train_ghist),
      .folded_o         (folded)
  );

  // ----- Checkpoint (GHR + RAS stack), banked per resolve hart (FSE S5) -----
  if (CVA6Cfg.BPCkptDepth != 0) begin : gen_ckpt
    if (CVA6Cfg.RASDepth != 0) begin : gen_ras_pack
      for (genvar r = 0; r < CVA6Cfg.RASDepth; r++) begin : gen_r
        assign push_ras_v[r]  = ras_stack_i[r].valid;
        assign push_ras_ra[r] = ras_stack_i[r].ra;
      end
    end else begin : gen_no_ras_pack
      assign push_ras_v  = '0;
      assign push_ras_ra = '0;
    end

    g6lc_bp_ckpt #(
        .CVA6Cfg  (CVA6Cfg),
        .GHIST_LEN(GHIST_LEN),
        .DEPTH    (CKPT_DEPTH),
        .RAS_DEPTH(CVA6Cfg.RASDepth),
        .RAS_VLEN (CVA6Cfg.VLEN)
    ) i_ckpt (
        .clk_i,
        .rst_ni,
        .flush_i          (flush_bp_i),
        .hart_i           (resolve_hart_i),
        .push_i           (hist_upd_v),
        .push_ghist_i     (train_ghist),
        .push_ras_valid_i (push_ras_v),
        .push_ras_ra_i    (push_ras_ra),
        .pop_i            (hist_upd_v || mispredict_i),
        .restore_i        (mispredict_i),
        .restore_ghist_o  (restore_ghist),
        .restore_ras_valid_o(rest_ras_v),
        .restore_ras_ra_o   (rest_ras_ra),
        .restore_valid_o  (restore_v),
        .empty_o          (ckpt_empty),
        .full_o           ()
    );

    if (CVA6Cfg.RASDepth != 0) begin : gen_ras_restore
      assign ras_restore_o = restore_v;
      for (genvar r = 0; r < CVA6Cfg.RASDepth; r++) begin : gen_rr
        assign ras_restore_stack_o[r].valid = rest_ras_v[r];
        assign ras_restore_stack_o[r].ra    = rest_ras_ra[r];
      end
    end else begin : gen_no_ras_restore
      assign ras_restore_o = 1'b0;
      assign ras_restore_stack_o = '0;
    end
  end else begin : gen_no_ckpt
    assign restore_v     = 1'b0;
    assign restore_ghist = '0;
    assign ckpt_empty    = 1'b1;
    assign push_ras_v    = '0;
    assign push_ras_ra   = '0;
    assign rest_ras_v    = '0;
    assign rest_ras_ra   = '0;
    assign ras_restore_o = 1'b0;
    assign ras_restore_stack_o = '0;
  end

  // ----- TAGE direction -----
  logic [NR_TABLES-1:0][FOLD_W-1:0] folded_use;
  for (genvar t = 0; t < NR_TABLES; t++) begin : gen_fold_use
    assign folded_use[t] = folded[t];
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
        .btb_update_i  (btb_update_i),
        .btb_prediction_o(ittage_pred)
    );
    assign btb_prediction_o = ittage_pred;
  end else begin : gen_no_ittage
    assign btb_prediction_o = '0;
  end

endmodule
