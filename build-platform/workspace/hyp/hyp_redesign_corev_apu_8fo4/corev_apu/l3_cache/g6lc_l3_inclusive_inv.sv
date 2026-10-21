// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
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
    output logic                          evict_ready_o,
    // T9a: drain-completion pulse (one cycle when the last core acked). The
    // CMO engine uses this instance as its L1 broadcaster and needs the
    // event, not just the busy level.
    output logic                          drain_done_o
);

  if (!InclusiveEn) begin : gen_off
    

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_l3_inclusive_inv  region=6419  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: addr_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to addr_q
// order expect: done_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to done_q
// order expect: pend_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to pend_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     addr_q <= …; // sv-timing: cycle 1/1 on clk_i
//     done_q <= …; // sv-timing: cycle 1/1 on clk_i
//     pend_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node22835 c=3.50 slack=0.00 */
//     /* node22836 c=3.50 slack=0.00 */
//     /* node22837 c=3.50 slack=0.00 */
//     /* node22838 c=3.50 slack=0.00 */
//     /* node22839 c=3.50 slack=0.00 */
//     /* node22840 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign inv_o         = '0;
    assign inv_busy_o    = 1'b0;
    assign evict_ready_o = 1'b1;
    assign drain_done_o  = 1'b0;
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
      drain_done_o = 1'b0;

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
        // Completion pulse must be computed BEFORE the done_d clear below —
        // evaluated after the clear it would be permanently 0.
        drain_done_o = &done_d;
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
