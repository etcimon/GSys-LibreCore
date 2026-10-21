// hyp8 provenance: REWRITTEN (sv-timing emit base, g6lc_lsq__svt.sv)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// SPDX-FileCopyrightText: machine-generated
//
// g6lc_lsq_age — hyp8 LSQ banked age compare.
//
// hyp8: runs in parallel with g6lc_lsq_cam_bank at stage C.  For each
// entry in the bank it registers (a) the ordering bit the direction
// needs, and (b) the entry's circular trans_id distance from
// commit_ptr_i, which the reduce stage's tournaments use to pick the
// youngest-matching store (STL) or the oldest violating load.
//
// Age is the circular trans_id distance from commit_ptr_i: program order
// is [cp, 2^width) then [0, cp) — slot index order is NOT age.  DIR=0
// (STL direction): older_o means "entry older than the event"
// (store older than the querying load).  DIR=1 (violation direction):
// older_o means "event older than the entry" (the resolving store is
// older than the scanned load — only then can it have produced stale
// data in the younger load).
//
// Kill identities: a dead event produces no age bits; flush clears the
// stage.

module g6lc_lsq_age #(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter int unsigned ENTRIES = 4,
    parameter bit DIR = 1'b0
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0] cancelled_mask_i,

    input  logic                            ev_valid_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] ev_id_i,

    input  logic [ENTRIES-1:0]                            ent_valid_i,
    input  logic [ENTRIES-1:0][G6LCCfg.TRANS_ID_BITS-1:0] ent_id_i,

    // Age anchor — the scoreboard commit pointer (contract §2).
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0]              commit_ptr_i,

    output logic [ENTRIES-1:0]                            older_o,
    output logic [ENTRIES-1:0][G6LCCfg.TRANS_ID_BITS-1:0] dist_o
);

  localparam int unsigned IDW = G6LCCfg.TRANS_ID_BITS;

  logic [ENTRIES-1:0]       older_d;
  logic [ENTRIES-1:0][31:0] dist_d;

  always_comb begin
    for (int unsigned i = 0; i < ENTRIES; i++) begin
      dist_d[i] = g6lc_ooo_pkg::ooo_age_dist(IDW, 32'(ent_id_i[i]),
                                             32'(commit_ptr_i));
      if (ev_valid_i && !cancelled_mask_i[ev_id_i] && ent_valid_i[i]) begin
        if (DIR)
          // Violation direction: store event older than the load entry.
          older_d[i] = g6lc_ooo_pkg::ooo_age_older(
              IDW, 32'(ev_id_i), 32'(ent_id_i[i]), 32'(commit_ptr_i));
        else
          // STL direction: store entry older than the load event.
          older_d[i] = g6lc_ooo_pkg::ooo_age_older(
              IDW, 32'(ent_id_i[i]), 32'(ev_id_i), 32'(commit_ptr_i));
      end else begin
        older_d[i] = 1'b0;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      older_o <= '0;
      dist_o  <= '0;
    end else if (flush_i) begin
      older_o <= '0;
      dist_o  <= '0;
    end else begin
      older_o <= older_d;
      for (int unsigned i = 0; i < ENTRIES; i++)
        dist_o[i] <= IDW'(dist_d[i]);
    end
  end

endmodule
