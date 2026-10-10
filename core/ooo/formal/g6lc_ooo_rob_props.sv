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
  logic                            empty_o;
  logic [NR_RETIRE-1:0]            retire_valid_o;
  logic [NR_RETIRE-1:0][ROB_W-1:0] retire_id_o;
  // entry_t = logic: payload ignored by occupancy invariants
  logic [NR_ALLOC-1:0]             alloc_entry_i;
  logic [NR_RETIRE-1:0]            retire_entry_o;

  logic [NR_RETIRE-1:0][TID_W-1:0] rob_retire_tid;

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
      .bulk_drop_mask_i('0),
      .alloc_valid_i,
      .alloc_entry_i,
      .alloc_tid_i,
      .alloc_id_o,
      .full_o,
      .empty_o,
      .complete_valid_i,
      .complete_tid_i,
      .complete_exc_i,
      .retire_valid_o,
      .retire_entry_o,
      .retire_id_o,
      .retire_ack_i,
      // In-order retire model: the acked tid is the presented head's.
      .retire_tid_i  (rob_retire_tid)
  );

  for (genvar pr = 0; pr < NR_RETIRE; pr++) begin : gen_ret_tid
    assign rob_retire_tid[pr] = dut.rob_q[retire_id_o[pr]].tid;
  end

  // BMC/prove: start from a forced reset (no free-state induction trap).
  // `initial assume (!rst_ni)` is rejected by the slang frontend, so drive it
  // from an initialised register.
  logic rst_init_q = 1'b1;
  always_ff @(posedge clk_i) rst_init_q <= 1'b0;
  always_ff @(posedge clk_i) begin
    if (rst_init_q) assume (!rst_ni);
  end

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
  wire [ROB_W-1:0] dist_w  = tail_w - head_w;

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // Never over-full.
      assert (count_w <= ROB_ENTRIES[ROB_W:0]);
      // full_o threshold matches RTL formula for NR_ALLOC ports.
      assert (full_o == (count_w > ROB_ENTRIES[ROB_W:0] - NR_ALLOC[ROB_W:0]));
      // empty_o is the drained-handoff seam (FP-3d): exactly count==0.
      assert (empty_o == (count_w == '0));
      // Circular-buffer occupancy identity.
      if (count_w != ROB_ENTRIES[ROB_W:0])
        assert (count_w == (ROB_W+1)'(dist_w));
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
