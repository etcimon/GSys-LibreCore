// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// U1 global / folded history register bank.
// One architectural GHR plus folded (CSR-style) views for TAGE table geometries.
// Speculative update + checkpoint restore ports feed g6lc_bp_ckpt.

module g6lc_bp_ghist
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter int unsigned GHIST_LEN = 24,
    parameter int unsigned NR_FOLDS  = 4,
    parameter int unsigned FOLD_W    = 8
) (
    input  logic                         clk_i,
    input  logic                         rst_ni,
    input  logic                         flush_i,
    // U6.1: active fetch hart for live GHR read (ignored when NrHarts==1)
    input  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] hart_i,
    // FSE S5: resolve/train hart for update + restore (may differ after SMT switch)
    input  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] train_hart_i,
    // Speculative / architectural history update (shift in taken)
    input  logic                         update_valid_i,
    input  logic                         update_taken_i,
    // Checkpoint restore (overrides update in the same cycle)
    input  logic                         restore_valid_i,
    input  logic [GHIST_LEN-1:0]         restore_ghist_i,
    // Fold-source GHR selected by the caller for the update path: the resolving
    // branch's prediction-time snapshot (checkpoint head) when available, else
    // the train hart's live bank.
    input  logic [GHIST_LEN-1:0]         fold_src_i,
    // Live GHR
    output logic [GHIST_LEN-1:0]         ghist_o,
    // Live GHR of the train/resolve hart (ckpt fallback source)
    output logic [GHIST_LEN-1:0]         train_ghist_o,
    // Folded history per table geometry (XOR-fold of GHR into FOLD_W)
    output logic [NR_FOLDS-1:0][FOLD_W-1:0] folded_o,
    // Folded view of fold_src_i: TAGE/ITTAGE update index/tag must hash the
    // branch's prediction-time history snapshot, not a live bank.
    output logic [NR_FOLDS-1:0][FOLD_W-1:0] folded_src_o
);

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin g6lc_bp_ghist status=proposal target=10-adjusted-FO4
  // svt-plan: cone hart-selected history shift/restore and XOR folding;
  // live lookup and training history select different owners.
  // svt-plan: reshape balance XOR folds; optionally maintain per-hart
  // folded summaries incrementally with the full history on accepted update.
  // svt-plan: boundary restore-fold preparation -> atomic history+fold
  // publication; hold prediction until both represent the same history version.
  // svt-plan: carry hart, update/restore/flush kind and history version;
  // preserve restore-before-update and final flush priority for the selected bank.
  // svt-plan: effect replaces recurring full-history reduction with bounded
  // XOR updates; explicit fold_src_i still requires its independent reduction.
  // svt-plan: cost folded-state copies and restore logic; full history stays
  // available for checkpoints and arbitrary restore, not reconstructed from folds.
  // svt-plan: limit a register only on folded_o misaligns PC/history;
  // short existing fold trees may favor balancing without additional state.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 14.5 adjusted FO4 on the
  // Nangate45 board): global history: shift / restore.
  // svt-pipe: require-contract
  // svt-pipe: protocol gh valid=update_valid_i flush=flush_i
  // svt-pipe: no-cut on=ghist_d
  // svt-pipe: cycle gh q=ghist_d d=folded_o hold=update_valid_i steps=1

  localparam int unsigned NH    = (G6LCCfg.NrHarts < 1) ? 1 : G6LCCfg.NrHarts;
  localparam int unsigned HID_W = (NH <= 1) ? 1 : $clog2(NH);

  // Banked when NrHarts>1; single register otherwise (identity netlist).
  logic [NH-1:0][GHIST_LEN-1:0] ghist_d, ghist_q;
  logic [GHIST_LEN-1:0] ghist_live, ghist_train;

  // Bank selectors: fetch view vs train/restore view.
  logic [HID_W-1:0] live_sel, train_sel;
`ifdef G6LC_MUT_BP_SHARE_GHR
  // MUTANT: a single shared bank — every hart-qualified access lands on
  // slot 0, so hart A's resolves rewrite hart B's prediction context.
  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_bp_ghist  region=3578  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: ghist_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to ghist_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     ghist_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node13134 c=3.50 slack=0.00 */
//     /* node13135 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign live_sel  = '0;
  assign train_sel = '0;
`else
  assign live_sel  = hart_i;
  assign train_sel = train_hart_i;
`endif

  assign ghist_live   = ghist_q[live_sel];
  assign ghist_train  = ghist_q[train_sel];
  assign ghist_o      = ghist_live;
  assign train_ghist_o = ghist_train;

  always_comb begin
    ghist_d = ghist_q;
    if (restore_valid_i) begin
      // FSE S5: restore the resolving branch's bank, not necessarily fetch
      ghist_d[train_sel] = restore_ghist_i;
    end else if (update_valid_i) begin
      if (GHIST_LEN == 1) ghist_d[train_sel] = update_taken_i;
      else ghist_d[train_sel] = {ghist_train[GHIST_LEN-2:0], update_taken_i};
    end
    // Flush only the train bank on mispredict empty-ckpt path; fetch bank for flush_bp
    if (flush_i) begin
      ghist_d[train_sel] = '0;
    end
  end

  // Balanced-style fold: XOR every FOLD_W-wide slice of the GHR into one word.
  // Different folds rotate the GHR first so each table sees a distinct hash.
  for (genvar t = 0; t < NR_FOLDS; t++) begin : gen_fold
    logic [GHIST_LEN-1:0] rot, rot_src;
    logic [FOLD_W-1:0] f, f_src;
    // Rotate left by t bits (mod GHIST_LEN). Tables are few (≤ 8).
    assign rot     = (t == 0) ? ghist_live
                              : ((ghist_live << t) | (ghist_live >> (GHIST_LEN - t)));
    assign rot_src = (t == 0) ? fold_src_i
                              : ((fold_src_i << t) | (fold_src_i >> (GHIST_LEN - t)));
    always_comb begin
      f     = '0;
      f_src = '0;
      for (int unsigned k = 0; k < GHIST_LEN; k++) begin
        f[k%FOLD_W]     = f[k%FOLD_W]     ^ rot[k];
        f_src[k%FOLD_W] = f_src[k%FOLD_W] ^ rot_src[k];
      end
    end
    assign folded_o[t]     = f;
    assign folded_src_o[t] = f_src;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) ghist_q <= '0;
    else ghist_q <= ghist_d;
  end

endmodule
