// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai island completion FIFO (I3+ / production RT).
//
// Holds completed {ticket, status, irq} so host can claim DONE multiple times
// without losing intermediate completions. Engine remains single-outstanding;
// FIFO depth bounds how many finishes may queue before SW claims.
//
// See architecture/ai-matrix/completion-fifo.md.

module g6lc_ai_cpl_fifo #(
    parameter int unsigned Depth = 4,
    // Width of count port (clog2(Depth+1))
    parameter int unsigned CntW  = (Depth <= 1) ? 1 : $clog2(Depth + 1)
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    // Push one completion (full accepts only with a simultaneous valid pop)
    input  logic        push_i,
    input  logic [31:0] ticket_i,
    input  logic [15:0] status_i,
    input  logic        irq_i,
    // Pop head (claim DONE)
    input  logic        pop_i,
    // Head + status
    output logic        empty_o,
    output logic        full_o,
    output logic [31:0] ticket_o,
    output logic [15:0] status_o,
    output logic        head_irq_o,
    output logic [CntW-1:0] count_o
);

  typedef struct packed {
    logic [31:0] ticket;
    logic [15:0] status;
    logic        irq;
  } cpl_t;

  cpl_t mem_q[Depth];
  logic [CntW-1:0] count_q;
  localparam int unsigned PtrW = Depth <= 1 ? 1 : $clog2(Depth);
  logic [PtrW-1:0] wr_q, rd_q;

  function automatic logic [PtrW-1:0] next_ptr(input logic [PtrW-1:0] ptr);
    if (Depth == 1) return '0;
    if ((Depth & (Depth - 1)) == 0) return ptr + PtrW'(1);
    return ptr == PtrW'(Depth - 1) ? '0 : ptr + PtrW'(1);
  endfunction

  // pragma translate_off
  initial begin
    assert (Depth >= 1 && CntW >= $clog2(64'(Depth) + 64'd1))
      else $error("g6lc_ai_cpl_fifo: invalid depth/count width");
  end
  // pragma translate_on

  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_cpl_fifo  region=6967  makespan=13.000 FO4  cycle_count=2  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: count_q  ready_cycle=1  ready_fo4=3.768  OpenSTA: report_timing -from clk_i -to count_q
// order expect: mem_q  ready_cycle=1  ready_fo4=4.500  OpenSTA: report_timing -from clk_i -to mem_q
// order expect: rd_q  ready_cycle=2  ready_fo4=13.000  OpenSTA: report_timing -from clk_i -to rd_q
// order expect: wr_q  ready_cycle=2  ready_fo4=13.000  OpenSTA: report_timing -from clk_i -to wr_q
// --- factor stage 1/2  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     count_q <= …; // sv-timing: cycle 1/2 on clk_i
//     mem_q <= …; // sv-timing: cycle 1/2 on clk_i
//     /* node25049 c=3.50 slack=9.50 */
//     /* node25050 c=3.50 slack=9.50 */
//     /* node25051 c=3.50 slack=9.50 */
//     /* node25052 c=3.50 slack=9.50 */
//     /* node25053 c=3.50 slack=9.50 */
//     /* node25054 c=3.50 slack=9.50 */
//     /* node25055 c=4.50 slack=8.50 */
//     /* node25056 c=4.50 slack=8.50 */
//     /* node25057 c=4.50 slack=8.50 */
//     /* node25059 c=3.77 slack=9.23 */
//     /* node25061 c=3.77 slack=9.23 */
//     /* node25062 c=4.50 slack=8.50 */
//     /* node25063 c=4.50 slack=8.50 */
//     /* node25064 c=4.50 slack=8.50 */
//   end
// end
// --- factor stage 2/2  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     rd_q <= …; // sv-timing: cycle 2/2 on clk_i
//     wr_q <= …; // sv-timing: cycle 2/2 on clk_i
//     /* node25058 c=13.00 slack=0.00 */
//     /* node25060 c=13.00 slack=0.00 */
//     /* node25065 c=13.00 slack=0.00 */
//     /* node25066 c=13.00 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
assign empty_o    = (count_q == '0);
  assign full_o     = (count_q == CntW'(Depth));
  assign count_o    = count_q;
  assign ticket_o   = mem_q[rd_q].ticket;
  assign status_o   = mem_q[rd_q].status;
  assign head_irq_o = mem_q[rd_q].irq;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      count_q <= '0;
      wr_q    <= '0;
      rd_q    <= '0;
      for (int unsigned i = 0; i < Depth; i++) begin
        mem_q[i].ticket <= '0;
        mem_q[i].status <= '0;
        mem_q[i].irq    <= 1'b0;
      end
    end else begin
      unique case ({push_i && (!full_o || (pop_i && !empty_o)), pop_i && !empty_o})
        2'b10: begin
          mem_q[wr_q].ticket <= ticket_i;
          mem_q[wr_q].status <= status_i;
          mem_q[wr_q].irq    <= irq_i;
          wr_q    <= next_ptr(wr_q);
          count_q <= count_q + 1'b1;
        end
        2'b01: begin
          rd_q    <= next_ptr(rd_q);
          count_q <= count_q - 1'b1;
        end
        2'b11: begin
          // Simultaneous push+pop: replace head slot stream — write at wr, advance both
          // Occupancy is unchanged, so count_q must NOT be touched; incrementing
          // and decrementing in the same cycle is what corrupts a full FIFO.
          mem_q[wr_q].ticket <= ticket_i;
          mem_q[wr_q].status <= status_i;
          mem_q[wr_q].irq    <= irq_i;
          wr_q    <= next_ptr(wr_q);
          rd_q    <= next_ptr(rd_q);
          // count unchanged
        end
        default: ;
      endcase
    end
  end

endmodule
