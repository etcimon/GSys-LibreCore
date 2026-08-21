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
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter int unsigned GHIST_LEN = 24,
    parameter int unsigned NR_FOLDS  = 4,
    parameter int unsigned FOLD_W    = 8
) (
    input  logic                         clk_i,
    input  logic                         rst_ni,
    input  logic                         flush_i,
    // U6.1: active fetch hart for live GHR read (ignored when NrHarts==1)
    input  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] hart_i,
    // FSE S5: resolve/train hart for update + restore (may differ after SMT switch)
    input  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] train_hart_i,
    // Speculative / architectural history update (shift in taken)
    input  logic                         update_valid_i,
    input  logic                         update_taken_i,
    // Checkpoint restore (overrides update in the same cycle)
    input  logic                         restore_valid_i,
    input  logic [GHIST_LEN-1:0]         restore_ghist_i,
    // Live GHR
    output logic [GHIST_LEN-1:0]         ghist_o,
    // Live GHR of the train/resolve hart (for ckpt push on resolve path)
    output logic [GHIST_LEN-1:0]         train_ghist_o,
    // Folded history per table geometry (XOR-fold of GHR into FOLD_W)
    output logic [NR_FOLDS-1:0][FOLD_W-1:0] folded_o
);

  localparam int unsigned NH    = (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;
  localparam int unsigned HID_W = (NH <= 1) ? 1 : $clog2(NH);

  // Banked when NrHarts>1; single register otherwise (identity netlist).
  logic [NH-1:0][GHIST_LEN-1:0] ghist_d, ghist_q;
  logic [GHIST_LEN-1:0] ghist_live, ghist_train;

  assign ghist_live   = ghist_q[hart_i];
  assign ghist_train  = ghist_q[train_hart_i];
  assign ghist_o      = ghist_live;
  assign train_ghist_o = ghist_train;

  always_comb begin
    ghist_d = ghist_q;
    if (restore_valid_i) begin
      // FSE S5: restore the resolving branch's bank, not necessarily fetch
      ghist_d[train_hart_i] = restore_ghist_i;
    end else if (update_valid_i) begin
      if (GHIST_LEN == 1) ghist_d[train_hart_i] = update_taken_i;
      else ghist_d[train_hart_i] = {ghist_train[GHIST_LEN-2:0], update_taken_i};
    end
    // Flush only the train bank on mispredict empty-ckpt path; fetch bank for flush_bp
    if (flush_i) begin
      ghist_d[train_hart_i] = '0;
    end
  end

  // Balanced-style fold: XOR every FOLD_W-wide slice of the GHR into one word.
  // Different folds rotate the GHR first so each table sees a distinct hash.
  for (genvar t = 0; t < NR_FOLDS; t++) begin : gen_fold
    logic [GHIST_LEN-1:0] rot;
    logic [FOLD_W-1:0] f;
    // Rotate left by t bits (mod GHIST_LEN). Tables are few (Γëñ 8).
    assign rot = (t == 0) ? ghist_live
                          : ((ghist_live << t) | (ghist_live >> (GHIST_LEN - t)));
    always_comb begin
      f = '0;
      for (int unsigned k = 0; k < GHIST_LEN; k++) begin
        f[k%FOLD_W] = f[k%FOLD_W] ^ rot[k];
      end
    end
    assign folded_o[t] = f;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) ghist_q <= '0;
    else ghist_q <= ghist_d;
  end

endmodule
