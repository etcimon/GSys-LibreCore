// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Inclusive-L3 back-invalidate: when L3 (or L2 when L3 off) replaces a valid
// victim line, broadcast a dcache line inv to all cores via coh_inval_t.
// Parameter InclusiveEn=0 → never asserts inv (identity for status).

module g6lc_l3_inclusive_inv
  import g6lc_coherence_pkg::*;
#(
    parameter bit          InclusiveEn = 1'b0,
    parameter int unsigned NR_CORES    = 1,
    parameter int unsigned LINE_BYTES  = COH_DEFAULT_LINE_BYTES,
    parameter int unsigned AXI_ADDR_WIDTH = 64
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic                          evict_valid_i,
    input  logic [AXI_ADDR_WIDTH-1:0]     evict_addr_i,
    // Ready from each core's inv adapter (all must accept)
    input  logic [NR_CORES-1:0]           inv_ready_i,
    output coh_inval_t [NR_CORES-1:0]     inv_o,
    output logic                          inv_busy_o,
    // Admission backpressure for the eviction producer. A victim offered while
    // this is low is NOT captured: only one back-invalidation drains at a time,
    // and the previous code silently discarded any eviction arriving during a
    // drain, so an L1 could keep a line the L3 had already replaced -- an
    // inclusion violation. The producer must hold evict_valid_i/evict_addr_i
    // until this is high.
    output logic                          evict_ready_o
);

  if (!InclusiveEn) begin : gen_off
    assign inv_o         = '0;
    assign inv_busy_o    = 1'b0;
    assign evict_ready_o = 1'b1;
  end else begin : gen_on
    logic                          pend_q, pend_d;
    logic [AXI_ADDR_WIDTH-1:0]     addr_q, addr_d;
    logic [NR_CORES-1:0]           done_q, done_d;

    assign inv_busy_o = pend_q;
    // Only accept a victim when no drain is in progress. Registered state only,
    // so this is a clean handshake and adds no path from inv_ready_i.
    assign evict_ready_o = !pend_q;

    always_comb begin
      pend_d = pend_q;
      addr_d = addr_q;
      done_d = done_q;
      for (int unsigned c = 0; c < NR_CORES; c++) begin
        inv_o[c] = '0;
      end

      // Inclusion is only restored once EVERY core has accepted the
      // invalidation, so done_q accumulates per-core acks and the victim
      // cannot be reused while any L1 may still hold the line.
      if (pend_q) begin
        for (int unsigned c = 0; c < NR_CORES; c++) begin
          if (!done_q[c]) begin
            inv_o[c].valid     = 1'b1;
            inv_o[c].dcache    = 1'b1;
            inv_o[c].icache    = 1'b0;
            inv_o[c].all_ways  = 1'b0;
            inv_o[c].line_addr = coh_line_tag(addr_q, LINE_BYTES);
            if (inv_ready_i[c]) done_d[c] = 1'b1;
          end
        end
        if (&done_d) begin
          pend_d = 1'b0;
          done_d = '0;
        end
      end else if (evict_valid_i) begin
        pend_d = 1'b1;
        addr_d = evict_addr_i;
        done_d = '0;
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        pend_q <= 1'b0;
        addr_q <= '0;
        done_q <= '0;
      end else begin
        pend_q <= pend_d;
        addr_q <= addr_d;
        done_q <= done_d;
      end
    end
  end

endmodule
