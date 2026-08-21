// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// U2 Fetch Target Queue: holds predicted/sequential fetch addresses between
// the NPC/predictor and the I$ request port. Flushable in one cycle.
// When DEPTH=0 the module is not instantiated (frontend uses direct path).

module g6lc_ftq
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter int unsigned DEPTH = 8
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    flush_i,
    // Enqueue a fetch target (from NPC path)
    input  logic                    push_i,
    input  logic [CVA6Cfg.VLEN-1:0] push_vaddr_i,
    input  logic                    push_taken_i,   // CF taken (for loop detection)
    input  logic [CVA6Cfg.VLEN-1:0] push_target_i,  // taken target if push_taken_i
    // Demand dequeue (I$ accepted a demand fetch)
    input  logic                    pop_i,
    output logic [CVA6Cfg.VLEN-1:0] head_vaddr_o,
    output logic                    head_taken_o,
    output logic [CVA6Cfg.VLEN-1:0] head_target_o,
    output logic                    head_valid_o,
    // Peek for FDIP (entry at head+offset, if valid)
    input  logic [$clog2(DEPTH+1)-1:0] peek_offset_i,
    output logic [CVA6Cfg.VLEN-1:0]    peek_vaddr_o,
    output logic                       peek_valid_o,
    // Status
    output logic                    full_o,
    output logic                    empty_o,
    output logic [$clog2(DEPTH+1)-1:0] count_o
);

  localparam int unsigned PTR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

  typedef struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] vaddr;
    logic                    taken;
    logic [CVA6Cfg.VLEN-1:0] target;
  } entry_t;

  entry_t [DEPTH-1:0] mem_q;
  logic [PTR_W-1:0] head_q, tail_q;
  logic [PTR_W:0] count_q;

  assign empty_o     = (count_q == '0);
  assign full_o      = (count_q == DEPTH[PTR_W:0]);
  assign count_o     = count_q;
  assign head_valid_o = !empty_o && mem_q[head_q].valid;
  assign head_vaddr_o = mem_q[head_q].vaddr;
  assign head_taken_o = mem_q[head_q].taken;
  assign head_target_o = mem_q[head_q].target;

  // Peek at head + offset (mod DEPTH)
  logic [PTR_W-1:0] peek_ptr;
  assign peek_ptr = head_q + PTR_W'(peek_offset_i);
  assign peek_valid_o = (count_q > peek_offset_i) && mem_q[peek_ptr].valid;
  assign peek_vaddr_o = mem_q[peek_ptr].vaddr;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      head_q  <= '0;
      tail_q  <= '0;
      count_q <= '0;
      for (int unsigned i = 0; i < DEPTH; i++) mem_q[i] <= '0;
    end else if (flush_i) begin
      // Drop all queued fetch targets. A same-cycle push re-seeds the redirect
      // (predicted taken CF / mispredict / pipeline flush) so the I$ can resume
      // at the new PC without draining stale sequential addresses.
      head_q <= '0;
      for (int unsigned i = 0; i < DEPTH; i++) mem_q[i].valid <= 1'b0;
      if (push_i) begin
        mem_q[0].valid  <= 1'b1;
        mem_q[0].vaddr  <= push_vaddr_i;
        mem_q[0].taken  <= push_taken_i;
        mem_q[0].target <= push_target_i;
        tail_q  <= PTR_W'(1);
        count_q <= (PTR_W+1)'(1);
      end else begin
        tail_q  <= '0;
        count_q <= '0;
      end
    end else begin
      logic [PTR_W:0] c;
      c = count_q;
      if (push_i && !full_o) begin
        mem_q[tail_q].valid  <= 1'b1;
        mem_q[tail_q].vaddr  <= push_vaddr_i;
        mem_q[tail_q].taken  <= push_taken_i;
        mem_q[tail_q].target <= push_target_i;
        tail_q <= tail_q + PTR_W'(1);
        c = c + (PTR_W+1)'(1);
      end
      if (pop_i && !empty_o) begin
        mem_q[head_q].valid <= 1'b0;
        head_q <= head_q + PTR_W'(1);
        c = c - (PTR_W+1)'(1);
      end
      count_q <= c;
    end
  end

endmodule
