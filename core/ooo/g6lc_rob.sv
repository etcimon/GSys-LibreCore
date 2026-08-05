// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5.2 Reorder Buffer — circular buffer allocated in program order,
// completed out of order (by scoreboard trans_id), retired in order.
// Multi-WB complete ports. Stores tid separately so entry_t need not expose fields.

module g6lc_rob #(
    parameter int unsigned ROB_ENTRIES = 16,
    parameter int unsigned ROB_W       = 4,
    parameter int unsigned NR_ALLOC    = 2,
    parameter int unsigned NR_RETIRE   = 2,
    parameter int unsigned NR_COMPLETE = 2,
    parameter int unsigned TID_W       = 5,
    parameter int unsigned NR_SB       = 16,
    parameter type entry_t = logic
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    // U5 production: squash slots whose scoreboard tid is cancelled
    input  logic [NR_SB-1:0]                       cancelled_mask_i,
    // Allocate at dispatch
    input  logic [NR_ALLOC-1:0]                    alloc_valid_i,
    input  entry_t [NR_ALLOC-1:0]                  alloc_entry_i,
    input  logic [NR_ALLOC-1:0][TID_W-1:0]         alloc_tid_i,
    output logic [NR_ALLOC-1:0][ROB_W-1:0]         alloc_id_o,
    output logic                                   full_o,
    // Complete (writeback) — match by scoreboard trans_id
    input  logic [NR_COMPLETE-1:0]                 complete_valid_i,
    input  logic [NR_COMPLETE-1:0][TID_W-1:0]      complete_tid_i,
    input  logic [NR_COMPLETE-1:0]                 complete_exc_i,
    // Retire
    output logic [NR_RETIRE-1:0]                   retire_valid_o,
    output entry_t [NR_RETIRE-1:0]                 retire_entry_o,
    output logic [NR_RETIRE-1:0][ROB_W-1:0]        retire_id_o,
    input  logic [NR_RETIRE-1:0]                   retire_ack_i
);

  typedef struct packed {
    logic             valid;
    logic             complete;
    logic             exc;
    logic [TID_W-1:0] tid;
    entry_t           e;
  } rob_slot_t;

  rob_slot_t [ROB_ENTRIES-1:0] rob_q, rob_d;
  logic [ROB_W-1:0] head_q, head_d, tail_q, tail_d;
  logic [ROB_W:0]   count_q, count_d;

  assign full_o = (count_q > ROB_ENTRIES[ROB_W:0] - NR_ALLOC[ROB_W:0]);

  always_comb begin
    rob_d   = rob_q;
    head_d  = head_q;
    tail_d  = tail_q;
    count_d = count_q;
    for (int unsigned a = 0; a < NR_ALLOC; a++) begin
      alloc_id_o[a] = '0;
      if (alloc_valid_i[a] && !full_o) begin
        automatic logic [ROB_W-1:0] rid;
        rid = tail_q + ROB_W'(a);
        alloc_id_o[a] = rid;
        rob_d[rid].valid = 1'b1;
        rob_d[rid].complete = 1'b0;
        rob_d[rid].exc = 1'b0;
        rob_d[rid].tid = alloc_tid_i[a];
        rob_d[rid].e = alloc_entry_i[a];
      end
    end
    for (int unsigned a = 0; a < NR_ALLOC; a++) begin
      if (alloc_valid_i[a] && !full_o) begin
        tail_d  = tail_d + 1'b1;
        count_d = count_d + 1'b1;
      end
    end
    for (int unsigned w = 0; w < NR_COMPLETE; w++) begin
      if (complete_valid_i[w]) begin
        for (int unsigned i = 0; i < ROB_ENTRIES; i++) begin
          if (rob_q[i].valid && !rob_q[i].complete && rob_q[i].tid == complete_tid_i[w]) begin
            rob_d[i].complete = 1'b1;
            rob_d[i].exc = complete_exc_i[w];
          end
        end
      end
    end
    // Squash cancelled younger ops: mark complete so in-order retire can drain
    // when commit_ack/commit_drop retires the matching SB slot (keep older valid).
    for (int unsigned i = 0; i < ROB_ENTRIES; i++) begin
      if (rob_d[i].valid && cancelled_mask_i[rob_d[i].tid]) begin
        rob_d[i].complete = 1'b1;
      end
    end
    for (int unsigned r = 0; r < NR_RETIRE; r++) begin
      automatic logic [ROB_W-1:0] hid;
      hid = head_q + ROB_W'(r);
      retire_valid_o[r] = rob_q[hid].valid && rob_q[hid].complete;
      retire_entry_o[r] = rob_q[hid].e;
      retire_id_o[r]    = hid;
      if (retire_ack_i[r] && rob_q[hid].valid && rob_q[hid].complete) begin
        rob_d[hid].valid = 1'b0;
        head_d  = head_d + 1'b1;
        count_d = count_d - 1'b1;
      end
    end
    if (flush_i) begin
      rob_d   = '0;
      head_d  = '0;
      tail_d  = '0;
      count_d = '0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rob_q   <= '0;
      head_q  <= '0;
      tail_q  <= '0;
      count_q <= '0;
    end else begin
      rob_q   <= rob_d;
      head_q  <= head_d;
      tail_q  <= tail_d;
      count_q <= count_d;
    end
  end

endmodule
