// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U4 in-order issue queue (FIFO). Instantiated twice: A-IQ and B-IQ.
// No associative search / wakeup-select — head-only ready + pop.
// Uses the cva6_fifo_v3 pattern (async-active-low reset, flushable).

module g6lc_slice_iq
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter int unsigned DEPTH = 4,
    parameter type scoreboard_entry_t = logic
) (
    input  logic                              clk_i,
    input  logic                              rst_ni,
    input  logic                              flush_i,
    // Enqueue
    input  logic                              push_i,
    input  scoreboard_entry_t                 push_sbe_i,
    input  logic [31:0]                       push_orig_i,
    input  logic [CVA6Cfg.TRANS_ID_BITS-1:0]  push_age_i,  // program-order age
    output logic                              ready_o,     // can accept push
    // Head
    output logic                              head_valid_o,
    output scoreboard_entry_t                 head_sbe_o,
    output logic [31:0]                       head_orig_o,
    output logic [CVA6Cfg.TRANS_ID_BITS-1:0]  head_age_o,
    input  logic                              pop_i,
    // Occupancy (for runahead accounting)
    output logic [$clog2(DEPTH+1)-1:0]        count_o
);

  localparam int unsigned PTR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

  typedef struct packed {
    scoreboard_entry_t                sbe;
    logic [31:0]                      orig;
    logic [CVA6Cfg.TRANS_ID_BITS-1:0] age;
  } entry_t;

  entry_t [DEPTH-1:0] mem_q;
  logic [PTR_W-1:0] head_q, tail_q;
  logic [PTR_W:0] count_q;

  assign ready_o      = (count_q < DEPTH[PTR_W:0]);
  assign head_valid_o = (count_q != '0);
  assign head_sbe_o   = mem_q[head_q].sbe;
  assign head_orig_o  = mem_q[head_q].orig;
  assign head_age_o   = mem_q[head_q].age;
  assign count_o      = count_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      head_q  <= '0;
      tail_q  <= '0;
      count_q <= '0;
      for (int unsigned i = 0; i < DEPTH; i++) mem_q[i] <= '0;
    end else if (flush_i) begin
      head_q  <= '0;
      tail_q  <= '0;
      count_q <= '0;
    end else begin
      unique case ({push_i && ready_o, pop_i && head_valid_o})
        2'b10: begin
          mem_q[tail_q] <= '{sbe: push_sbe_i, orig: push_orig_i, age: push_age_i};
          tail_q  <= tail_q + PTR_W'(1);
          count_q <= count_q + (PTR_W+1)'(1);
        end
        2'b01: begin
          head_q  <= head_q + PTR_W'(1);
          count_q <= count_q - (PTR_W+1)'(1);
        end
        2'b11: begin
          mem_q[tail_q] <= '{sbe: push_sbe_i, orig: push_orig_i, age: push_age_i};
          tail_q  <= tail_q + PTR_W'(1);
          head_q  <= head_q + PTR_W'(1);
          // count unchanged
        end
        default: ;
      endcase
    end
  end

endmodule
