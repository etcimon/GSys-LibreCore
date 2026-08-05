// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U6.2 L1 invalidation adapter — maps hub coh_inval_t → core l1_inval_* ports
// (wt_cache_subsystem inval_addr/valid/ready).
//
// Ready/valid handshake; when inv is all_ways, address is don't-care (core
// still receives a pulse — full-cache flush is via dcache_flush elsewhere).
// dcache/icache flags are folded: any dcache inv presents the line address.

module g6lc_l1_inv_adapter
  import g6lc_coherence_pkg::*;
#(
    parameter int unsigned LINE_BYTES = COH_DEFAULT_LINE_BYTES
) (
    input  logic       clk_i,
    input  logic       rst_ni,
    // From coherence hub / inval bus
    input  coh_inval_t inv_i,
    output logic       inv_ready_o,
    // Toward core (cva6 / ariane l1_inval_*)
    output logic [63:0] l1_inval_addr_o,
    output logic        l1_inval_valid_o,
    input  logic        l1_inval_ready_i
);

  // Present only dcache (or all_ways) invs; icache-only left for future fence.i path
  logic present;
  assign present = inv_i.valid & (inv_i.dcache | inv_i.all_ways);

  assign l1_inval_valid_o = present;
  assign l1_inval_addr_o  = coh_line_base(inv_i.line_addr, LINE_BYTES);
  assign inv_ready_o      = present ? l1_inval_ready_i : 1'b1;

endmodule
