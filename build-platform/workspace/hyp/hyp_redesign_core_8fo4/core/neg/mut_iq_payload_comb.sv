// hyp8 provenance: REWRITTEN (issue-queue payload array)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// NEGATIVE CONTROL (verification only, not for the design): a mutated
// copy of g6lc_iq_payload that restores the pre-repair COMBINATIONAL
// payload read (rd_enable_i ignored). tb_g6lc_hyp8_control instantiates
// it beside the real payload on identical stimulus and asserts the two
// differ exactly where the registered-read ownership contract matters,
// so the leaf cannot silently pass if the mutation were re-landed.
//
// g6lc_iq_payload -- the (bank, entry)-indexed payload store of the banked
// issue queue (analysis/g6lc_iq.md). Written at dispatch allocation.
// The read ports are registered: on an accepted read (rd_enable_i, the
// same accept event as the grant) each port captures the addressed
// payload row, so the presented issue_sbe_o / issue_orig_o / issue_prd_o
// hold stable behind a stalled presentation -- a held win_q cannot see a
// reused slot's payload while it waits for its issue port.
//
// No per-entry valid bookkeeping lives here: a slot's payload is written
// before the bank ever offers it as a candidate, and a stale payload row
// is never read (grants only name live entries).

module mut_iq_payload_comb #(
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
    // Read: indexed by the accepted candidates' (bank, entry); the read
    // registers capture only on the granted accept.
    input  logic [NPORTS-1:0]                 rd_enable_i,
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

  // MUTATION: combinational read ports (the pre-repair behaviour). The
  // addressed row is read every cycle, so a reused slot's new payload
  // leaks into a presentation the earlier grant launched.
  always_comb begin
    for (int unsigned p = 0; p < NPORTS; p++) begin
      rd_sbe_o[p]  = mem_q[rd_bank_i[p]][rd_entry_i[p]].sbe;
      rd_orig_o[p] = mem_q[rd_bank_i[p]][rd_entry_i[p]].orig;
      rd_prd_o[p]  = mem_q[rd_bank_i[p]][rd_entry_i[p]].prd;
    end
  end
  logic unused_sigs;
  assign unused_sigs = |rd_enable_i & clk_i & rst_ni;

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
