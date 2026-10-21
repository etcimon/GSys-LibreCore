// hyp8 provenance: REWRITTEN (sv-timing emit base, g6lc_lsq__svt.sv)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// SPDX-FileCopyrightText: machine-generated
//
// g6lc_lsq_reduce — hyp8 LSQ banked-candidate reduction (stage R).
//
// Consumes the registered bank outputs (match & older candidates plus a
// small number of extra leaves the wrapper appends — see g6lc_lsq.sv)
// and reduces them, one stage, registered:
//
//   DIR=0 (store-to-load direction): youngest older store whose lanes
//     fully cover the load's bytes — the A119 stable youngest-store
//     tournament (max circular age distance wins; lowest index breaks
//     ties, preserving the emit's scan order).  `wait_o` reports an
//     older unresolved store or a matched older store whose data has
//     not landed — the STL "stall" verdict source.  `dwait_ids_o` is
//     the tid mask of matched-older stores lacking data, consumed by
//     g6lc_lsq_release's per-load data-wait mask.
//   DIR=1 (violation direction): oldest younger load the resolving
//     store aliases — the A119 stable oldest-violation tournament
//     (min age distance wins; lowest index breaks ties).  `win_*`
//     carries the violating load's slot id and PC.
//
// Kill identities: the candidate set is already dead-event-free (the
// CAM/age stages gate on cancelled_mask_i); the stage registers are
// cleared by flush_i.

module g6lc_lsq_reduce #(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter int unsigned NLEAF = 8,
    parameter int unsigned PAYW  = 8,
    parameter bit DIR = 1'b0
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,

    // Registered stage-C leaf vectors (banks' match/unres/nodata, ages).
    input  logic [NLEAF-1:0]                                match_i,
    input  logic [NLEAF-1:0]                                unres_i,
    input  logic [NLEAF-1:0]                                nodata_i,
    input  logic [NLEAF-1:0]                                older_i,
    input  logic [NLEAF-1:0][G6LCCfg.TRANS_ID_BITS-1:0]     dist_i,
    input  logic [NLEAF-1:0][G6LCCfg.TRANS_ID_BITS-1:0]     ent_id_i,
    input  logic [NLEAF-1:0][PAYW-1:0]                      ent_pay_i,

    output logic                                          win_valid_o,
    output logic [NLEAF-1:0]                              win_leaf_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0]              win_id_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0]              win_dist_o,
    output logic [PAYW-1:0]                               win_pay_o,
    output logic                                          wait_o,
    output logic [G6LCCfg.NR_SB_ENTRIES-1:0]              dwait_ids_o
);
  // svt-stage: begin R

  localparam int unsigned LEAVES = 1 << $clog2(NLEAF);
  localparam int unsigned IDW = G6LCCfg.TRANS_ID_BITS;

  logic [NLEAF-1:0] cand;      // match && older
  logic [NLEAF-1:0] cand_nd;   // match && older && !data
  logic [NLEAF-1:0] cand_ur;   // unresolved && older
  logic wait_d;
  logic [G6LCCfg.NR_SB_ENTRIES-1:0] dwait_d;

  always_comb begin
    cand    = match_i & older_i;
    cand_nd = match_i & older_i & nodata_i;
    cand_ur = unres_i & older_i;
    dwait_d = '0;
    wait_d  = |cand_ur | |cand_nd;
    for (int unsigned i = 0; i < NLEAF; i++)
      if (cand_nd[i]) dwait_d[ent_id_i[i]] = 1'b1;
  end

  // A119 stable tournament — balanced tree, registered output.
  logic [2*LEAVES-1:1]                 pick_valid;
  logic [2*LEAVES-1:1][IDW-1:0]        pick_dist;
  logic [2*LEAVES-1:1][$clog2(LEAVES)-1:0] pick_slot;

  for (genvar i = 0; i < LEAVES; i++) begin : gen_leaf
    if (i < NLEAF) begin : gen_entry
      assign pick_valid[LEAVES+i] = cand[i];
      assign pick_dist[LEAVES+i]  = dist_i[i];
      assign pick_slot[LEAVES+i]  = $clog2(LEAVES)'(i);
    end else begin : gen_pad
      assign pick_valid[LEAVES+i] = 1'b0;
      // Keep the emit's oldest-scan sentinel shape for DIR=1.
      assign pick_dist[LEAVES+i]  = '1;
      assign pick_slot[LEAVES+i]  = '0;
    end
  end
  for (genvar n = 1; n < LEAVES; n++) begin : gen_pick
    logic take_right;
    if (DIR) begin : gen_oldest
      // Oldest violating load = smallest circular distance.
      assign take_right = pick_valid[2*n+1] &&
                          (!pick_valid[2*n] || pick_dist[2*n+1] < pick_dist[2*n]);
    end else begin : gen_youngest
      // Youngest covering store = largest circular distance; strict >
      // preserves the emit's first-index tie rule.
      assign take_right = pick_valid[2*n+1] &&
                          (!pick_valid[2*n] || pick_dist[2*n+1] > pick_dist[2*n]);
    end
    assign pick_valid[n] = pick_valid[2*n] | pick_valid[2*n+1];
    assign pick_dist[n]  = take_right ? pick_dist[2*n+1] : pick_dist[2*n];
    assign pick_slot[n]  = take_right ? pick_slot[2*n+1] : pick_slot[2*n];
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      win_valid_o <= 1'b0;
      win_leaf_o  <= '0;
      win_id_o    <= '0;
      win_dist_o  <= '0;
      win_pay_o   <= '0;
      wait_o      <= 1'b0;
      dwait_ids_o <= '0;
    end else if (flush_i) begin
      win_valid_o <= 1'b0;
      win_leaf_o  <= '0;
      win_id_o    <= '0;
      win_dist_o  <= '0;
      win_pay_o   <= '0;
      wait_o      <= 1'b0;
      dwait_ids_o <= '0;
    end else begin
      win_valid_o <= pick_valid[1];
      win_leaf_o  <= '0;
      if (pick_valid[1]) begin
        win_leaf_o[pick_slot[1]] <= 1'b1;
        win_id_o                 <= ent_id_i[pick_slot[1]];
        win_dist_o               <= pick_dist[1];
        win_pay_o                <= ent_pay_i[pick_slot[1]];
      end
      wait_o      <= wait_d;
      dwait_ids_o <= dwait_d;
    end
  end

  // svt-stage: end R
  // svt-stage: class R value
endmodule
