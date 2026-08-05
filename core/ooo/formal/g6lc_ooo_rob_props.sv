// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal: ROB occupancy / full_o invariants against live `g6lc_rob`.
// Single alloc/retire/complete ports keep the cone small for BMC/prove.
//
// Run: sby -f core/ooo/formal/g6lc_ooo_rob.sby
//      cva6-build verify --formal

module g6lc_ooo_rob_props #(
    parameter int unsigned ROB_ENTRIES = 8,
    parameter int unsigned ROB_W       = $clog2(ROB_ENTRIES),
    parameter int unsigned NR_ALLOC    = 1,
    parameter int unsigned NR_RETIRE   = 1,
    parameter int unsigned NR_COMPLETE = 1,
    parameter int unsigned TID_W       = 3,
    parameter int unsigned NR_SB       = 8
) (
    input logic                                clk_i,
    input logic                                rst_ni,
    input logic                                flush_i,
    input logic [NR_SB-1:0]                    cancelled_mask_i,
    input logic [NR_ALLOC-1:0]                 alloc_valid_i,
    input logic [NR_ALLOC-1:0][TID_W-1:0]      alloc_tid_i,
    input logic [NR_COMPLETE-1:0]              complete_valid_i,
    input logic [NR_COMPLETE-1:0][TID_W-1:0]   complete_tid_i,
    input logic [NR_COMPLETE-1:0]              complete_exc_i,
    input logic [NR_RETIRE-1:0]                retire_ack_i
);

`ifdef FORMAL
  logic [NR_ALLOC-1:0][ROB_W-1:0]  alloc_id_o;
  logic                            full_o;
  logic [NR_RETIRE-1:0]            retire_valid_o;
  logic [NR_RETIRE-1:0][ROB_W-1:0] retire_id_o;
  // entry_t = logic: payload ignored by occupancy invariants
  logic [NR_ALLOC-1:0]             alloc_entry_i;
  logic [NR_RETIRE-1:0]            retire_entry_o;

  g6lc_rob #(
      .ROB_ENTRIES(ROB_ENTRIES),
      .ROB_W      (ROB_W),
      .NR_ALLOC   (NR_ALLOC),
      .NR_RETIRE  (NR_RETIRE),
      .NR_COMPLETE(NR_COMPLETE),
      .TID_W      (TID_W),
      .NR_SB      (NR_SB),
      .entry_t    (logic)
  ) dut (
      .clk_i,
      .rst_ni,
      .flush_i,
      .cancelled_mask_i,
      .alloc_valid_i,
      .alloc_entry_i,
      .alloc_tid_i,
      .alloc_id_o,
      .full_o,
      .complete_valid_i,
      .complete_tid_i,
      .complete_exc_i,
      .retire_valid_o,
      .retire_entry_o,
      .retire_id_o,
      .retire_ack_i
  );

  // BMC/prove: start from a forced reset (no free-state induction trap).
  initial assume (!rst_ni);

  // Legal scoreboard tid indices.
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      for (int unsigned a = 0; a < NR_ALLOC; a++)
        assume (alloc_tid_i[a] < NR_SB[TID_W-1:0]);
      for (int unsigned w = 0; w < NR_COMPLETE; w++)
        assume (complete_tid_i[w] < NR_SB[TID_W-1:0]);
      // Do not ack a retire that is not presented as valid this cycle.
      for (int unsigned r = 0; r < NR_RETIRE; r++)
        assume (!(retire_ack_i[r] && !retire_valid_o[r]));
    end
  end

  // Hierarchical occupancy (live RTL).
  wire [ROB_W:0]   count_w = dut.count_q;
  wire [ROB_W-1:0] head_w  = dut.head_q;
  wire [ROB_W-1:0] tail_w  = dut.tail_q;
  wire [ROB_W-1:0] dist    = tail_w - head_w;

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // Never over-full.
      assert (count_w <= ROB_ENTRIES[ROB_W:0]);
      // full_o threshold matches RTL formula for NR_ALLOC ports.
      assert (full_o == (count_w > ROB_ENTRIES[ROB_W:0] - NR_ALLOC[ROB_W:0]));
      // Circular-buffer occupancy identity.
      if (count_w != ROB_ENTRIES[ROB_W:0])
        assert (count_w == (ROB_W+1)'(dist));
      else
        assert (tail_w == head_w);
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      cover (count_w == ROB_ENTRIES[ROB_W:0]);
      cover (full_o && alloc_valid_i[0]);
      cover (retire_valid_o[0] && retire_ack_i[0]);
    end
  end
`endif

endmodule
