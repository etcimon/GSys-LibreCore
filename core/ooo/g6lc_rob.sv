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
    // Drained-handoff seam (T6a): the thread selector may switch only when
    // empty_o holds.
    output logic                                   empty_o,
    // Complete (writeback) — match by scoreboard trans_id
    input  logic [NR_COMPLETE-1:0]                 complete_valid_i,
    input  logic [NR_COMPLETE-1:0][TID_W-1:0]      complete_tid_i,
    input  logic [NR_COMPLETE-1:0]                 complete_exc_i,
    // Retire
    output logic [NR_RETIRE-1:0]                   retire_valid_o,
    output entry_t [NR_RETIRE-1:0]                 retire_entry_o,
    output logic [NR_RETIRE-1:0][ROB_W-1:0]        retire_id_o,
    input  logic [NR_RETIRE-1:0]                   retire_ack_i,
    // T6b-4b: the committing scoreboard tid per retire port. Under per-hart
    // commit heads the committed slot need not be the ring head, so frees
    // are keyed by tid, not by head position.
    input  logic [NR_RETIRE-1:0][TID_W-1:0]        retire_tid_i
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
  // Free-by-tid hit vectors per retire port and the head re-anchor scratch
  // (driven only in the always_comb below; module-scope so every frontend
  // scopes them the same way).
  logic [NR_RETIRE-1:0][ROB_ENTRIES-1:0] free_hit;
  logic [ROB_ENTRIES-1:0] rean_stop, rean_first;
  logic [ROB_W-1:0]       rean_dist, rean_steps;

  assign full_o = (count_q > ROB_ENTRIES[ROB_W:0] - NR_ALLOC[ROB_W:0]);
  assign empty_o = (count_q == '0);

  always_comb begin
    automatic logic [ROB_W-1:0] rid, hid;
    rid = '0;
    hid = '0;
    rob_d   = rob_q;
    head_d  = head_q;
    tail_d  = tail_q;
    count_d = count_q;
    for (int unsigned a = 0; a < NR_ALLOC; a++) begin
      alloc_id_o[a] = '0;
      if (alloc_valid_i[a] && !full_o) begin
        rid = tail_q + ROB_W'(a);
        alloc_id_o[a] = rid;
        rob_d[rid].valid = 1'b1;
        rob_d[rid].complete = 1'b0;
        rob_d[rid].exc = 1'b0;
        rob_d[rid].tid = alloc_tid_i[a];
        rob_d[rid].e = alloc_entry_i[a];
      end
    end
    // Pointer and count advance by the number of allocations at once
    // (sv-timing A107), not by one serial increment per port.
    begin
      automatic logic [NR_ALLOC-1:0] alloc_fire;
      for (int unsigned a = 0; a < NR_ALLOC; a++) alloc_fire[a] = alloc_valid_i[a] && !full_o;
      tail_d  = tail_d + ROB_W'($countones(alloc_fire));
      count_d = count_d + (ROB_W + 1)'($countones(alloc_fire));
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
      hid = head_q + ROB_W'(r);
      retire_valid_o[r] = rob_q[hid].valid && rob_q[hid].complete;
      retire_entry_o[r] = rob_q[hid].e;
      retire_id_o[r]    = hid;
    end
`ifdef G6LC_MUT_ROB_POSITIONAL_FREE
    // MUTANT: positional head+r free. Under per-hart commit heads the acked
    // tid is not at head+r — the wrong slot is freed and count_q drifts.
    for (int unsigned r = 0; r < NR_RETIRE; r++) begin
      hid = head_q + ROB_W'(r);
      if (retire_ack_i[r] && rob_q[hid].valid && rob_q[hid].complete) begin
        rob_d[hid].valid = 1'b0;
        head_d  = head_d + 1'b1;
        count_d = count_d - 1'b1;
      end
    end
`else
    // T6b-4b: free by transaction id — under per-hart commit heads commit
    // order across harts need not match dispatch order; a positional head+r
    // free would evict the wrong slot and leak the acked one.
    //
    // Timing (sv-timing A99): the count is decremented by the popcount of
    // each port's hit vector, not once per matching slot inside the slot
    // loop — that form is a NR_RETIRE x ROB_ENTRIES chain of conditional
    // decrements synthesis keeps serial (structural 63 FO4 at 2 x 32). Port
    // r's hits are taken on the state port r-1 left, so two ports naming
    // the same tid still free one slot and count one, as before.
    // Hits from the registered state for every port at once (sv-timing
    // A107): an entry allocated this cycle cannot retire this cycle, so
    // `rob_q` and the pre-free `rob_d` agree on what a retire tid can hit;
    // "port r's hits on the state port r-1 left" is the mask by the earlier
    // ports' hits. The ports' hit vectors are then disjoint, so one
    // popcount of their union is the count's decrement. Exact as before:
    // two ports naming one tid still free one slot and count one.
    free_hit = '0;
    begin
      automatic logic [ROB_ENTRIES-1:0] taken, all_hits;
      taken = '0;
      for (int unsigned r = 0; r < NR_RETIRE; r++) begin
        for (int unsigned i = 0; i < ROB_ENTRIES; i++) begin
          free_hit[r][i] = retire_ack_i[r] && rob_q[i].valid &&
                           (rob_q[i].tid == retire_tid_i[r]) && !taken[i];
        end
        taken = taken | free_hit[r];
      end
      all_hits = taken;
      for (int unsigned i = 0; i < ROB_ENTRIES; i++) begin
        if (all_hits[i]) rob_d[i].valid = 1'b0;
      end
      // A tid names at most one valid entry (a live instruction has one ROB
      // slot), so each port's hit vector is one-hot-or-zero and the count
      // decrements by the number of ports that hit — an OR-reduce per port,
      // not a popcount over the entries (sv-timing A111; asserted below).
      for (int unsigned r = 0; r < NR_RETIRE; r++)
        count_d = count_d - (ROB_W + 1)'(|free_hit[r]);
    end
    // Re-anchor the report-only head on the oldest remaining entry: advance
    // past the run of freed slots starting at head, never past tail. The
    // step-until-valid walk (dynamic index per step) is the same chain shape;
    // the run length is one find-first over the valid vector rotated to head,
    // stopped at tail (`stop` marks the first valid slot or the tail itself,
    // so an empty ring yields zero steps). Exact for ROB_ENTRIES == 2**ROB_W.
    // Both rewrites: whole-module sequential miter against the pre-change
    // RTL (Yosys SAT, 6 steps from reset) proved at ROB_ENTRIES = 4; the
    // 8-entry miter (304 k variables) exceeded a 40-minute budget.
    rean_dist  = tail_d - head_d;
    rean_steps = '0;
    for (int unsigned j = 0; j < ROB_ENTRIES; j++) begin
      rean_stop[j] = rob_d[ROB_W'(head_d + ROB_W'(j))].valid || (ROB_W'(j) == rean_dist);
    end
    // `rean_stop` is never empty (j == dist always stops); isolate its lowest
    // set bit and encode it — a find-first without a priority chain.
    rean_first = rean_stop & (~rean_stop + 1'b1);
    for (int unsigned j = 0; j < ROB_ENTRIES; j++) begin
      if (rean_first[j]) rean_steps = rean_steps | ROB_W'(j);
    end
    head_d = head_d + rean_steps;
`endif
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

//pragma translate_off
  // Every retire ack must find its tid in the ROB — a miss means the free
  // bookkeeping silently dropped a slot (or the ack carries no allocation).
  for (genvar r = 0; r < NR_RETIRE; r++) begin : gen_retire_hit_chk
    logic rob_retire_hit;
    always_comb begin
      rob_retire_hit = 1'b0;
      for (int unsigned i = 0; i < ROB_ENTRIES; i++)
        if (rob_q[i].valid && (rob_q[i].tid == retire_tid_i[r])) rob_retire_hit = 1'b1;
    end
    assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
      retire_ack_i[r] |-> rob_retire_hit)
    else $fatal(1, "ROB_RETIRE_TID: retire ack found no matching ROB entry");
  end
//pragma translate_on

  //pragma translate_off
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      for (int unsigned r = 0; r < NR_RETIRE; r++)
        ooo_rob_hit_onehot: assert ($onehot0(free_hit[r]))
          else $error("g6lc_rob: retire tid %0d names %0d entries", retire_tid_i[r], $countones(free_hit[r]));
    end
  end
  //pragma translate_on
endmodule
