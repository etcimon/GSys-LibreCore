// hyp8 provenance: REWRITTEN (issue-queue payload array)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_iq_payload -- the (bank, entry)-indexed payload store of the banked
// issue queue (analysis/g6lc_iq.md). Written at dispatch allocation, read
// the cycle after the bank grant on the registered candidates' (bank,
// entry) indices -- the read is a flat two-level mux (bank then entry) so
// the presented issue_sbe_o / issue_orig_o / issue_prd_o are comb off the
// registered candidate the same cycle (the register boundary is the
// candidate register in g6lc_iq_arb; the held record there captures the
// payload for un-acked presentations).
//
// No per-entry valid bookkeeping lives here: a slot's payload is written
// before the bank ever offers it as a candidate, and a stale payload row
// is never read (grants only name live entries).

module g6lc_iq_payload #(
    parameter int unsigned BANKS   = 8,
    parameter int unsigned ENTRIES = 4,
    parameter int unsigned PRF_W   = 6,
    parameter int unsigned NLANES  = 2,   // alloc write lanes
    parameter int unsigned NPORTS  = 2,   // issue read ports
    parameter type scoreboard_entry_t = logic
) (
    input  logic clk_i,
    input  logic rst_ni,
    // Allocation write (wrapper's bank steering supplies bank + slot).
    input  logic [NLANES-1:0]                 wr_v_i,
    input  logic [NLANES-1:0][$clog2(BANKS > 1 ? BANKS : 2)-1:0] wr_bank_i,
    input  logic [NLANES-1:0][$clog2(ENTRIES > 1 ? ENTRIES : 2)-1:0] wr_entry_i,
    input  scoreboard_entry_t [NLANES-1:0]    wr_sbe_i,
    input  logic [NLANES-1:0][31:0]           wr_orig_i,
    input  logic [NLANES-1:0][PRF_W-1:0]      wr_prd_i,
    // Read: indexed by the registered candidates' (bank, entry).
    input  logic [NPORTS-1:0][$clog2(BANKS > 1 ? BANKS : 2)-1:0] rd_bank_i,
    input  logic [NPORTS-1:0][$clog2(ENTRIES > 1 ? ENTRIES : 2)-1:0] rd_entry_i,
    output scoreboard_entry_t [NPORTS-1:0]    rd_sbe_o,
    output logic [NPORTS-1:0][31:0]           rd_orig_o,
    output logic [NPORTS-1:0][PRF_W-1:0]      rd_prd_o
);

  localparam int unsigned BW = (BANKS > 1) ? $clog2(BANKS) : 1;
  localparam int unsigned EW = (ENTRIES > 1) ? $clog2(ENTRIES) : 1;

  typedef struct packed {
    scoreboard_entry_t sbe;
    logic [31:0]       orig;
    logic [PRF_W-1:0]  prd;
  } pay_t;

  pay_t [BANKS-1:0][ENTRIES-1:0] mem_q;

  always_comb begin
    for (int unsigned p = 0; p < NPORTS; p++) begin
      rd_sbe_o[p]  = mem_q[rd_bank_i[p]][rd_entry_i[p]].sbe;
      rd_orig_o[p] = mem_q[rd_bank_i[p]][rd_entry_i[p]].orig;
      rd_prd_o[p]  = mem_q[rd_bank_i[p]][rd_entry_i[p]].prd;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_q <= '0;
    end else begin
      for (int unsigned p = 0; p < NLANES; p++) begin
        if (wr_v_i[p]) begin
          mem_q[wr_bank_i[p]][wr_entry_i[p]].sbe  <= wr_sbe_i[p];
          mem_q[wr_bank_i[p]][wr_entry_i[p]].orig <= wr_orig_i[p];
          mem_q[wr_bank_i[p]][wr_entry_i[p]].prd  <= wr_prd_i[p];
        end
      end
    end
  end

endmodule
