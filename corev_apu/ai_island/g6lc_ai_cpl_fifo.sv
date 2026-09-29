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
