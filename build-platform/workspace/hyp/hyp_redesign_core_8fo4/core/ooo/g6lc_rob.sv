// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5.2 Reorder Buffer — circular buffer allocated in program order,
// completed out of order (by scoreboard trans_id), retired in order.
// Multi-WB complete ports. Stores tid separately so entry_t need not expose fields.
//
// hyp8 (group 4/5): the head re-anchor is a 2-step lowest-set with a
// registered intermediate (analysis/t1_rest.md, rank 4 bookkeeping): each
// cycle the post-event stop vector is quartered and every quarter's
// lowest-set bit is captured; the next cycle the four quarter candidates
// are merged in absolute slot order against the registered head -- first
// candidate at or above head, else the lowest candidate (same semantics as
// the single-cycle hi/lo split it replaces, computed one cycle later).
// Because each merge re-derives "at or above" against the *current* head_q,
// the anchor can never regress: a freed-underneath stop leaves head on a
// dead slot for at most one cycle and the next record re-anchors past it
// (retire_valid_o reads valid && complete, so the slot simply stalls a
// retire for that cycle -- a bubble, never a wrong retire).
// Completion by tid from the WB records, retire by tid from the commit
// bundle, flush identity: all unchanged.

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

  // A136: the head re-anchor searches the post-free valid vector in
  // absolute slot order (two parallel-prefix find-firsts split at the
  // registered head) instead of rotating it by the head first; the head
  // becomes the found slot, not head + steps. hyp8: the same find is done
  // in two steps across a cycle boundary -- per-quarter lowest-set
  // registered, quarter candidates merged next cycle.

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
  logic [ROB_ENTRIES-1:0] anchor_stop;
  // hyp8: quartered stage-1 candidates (one lowest-set one-hot per quarter)
  localparam int unsigned NQ = 4;
  localparam int unsigned QW = (ROB_ENTRIES + NQ - 1) / NQ;
  logic [NQ-1:0][ROB_ENTRIES-1:0] qstop_d, qstop_q;

  // Lowest set bit as a log-depth prefix OR (no carry chain). Exact for any
  // width: a bit is the lowest set bit iff it is set and no lower bit is.
  function automatic logic [ROB_ENTRIES-1:0] lowest_set(input logic [ROB_ENTRIES-1:0] x);
    logic [ROB_ENTRIES-1:0] below;
    below = x << 1;
    for (int unsigned l = 1; l < ROB_ENTRIES; l = l << 1) below = below | (below << l);
    return x & ~below;
  endfunction

  assign full_o  = (count_q > ROB_ENTRIES[ROB_W:0] - NR_ALLOC[ROB_W:0]);
  assign empty_o = (count_q == '0);

  always_comb begin
    automatic logic [ROB_W-1:0] hid;
    hid = '0;
    tail_d  = tail_q;
    count_d = count_q;
    for (int unsigned a = 0; a < NR_ALLOC; a++) begin
      alloc_id_o[a] = '0;
      if (alloc_valid_i[a] && !full_o) alloc_id_o[a] = tail_q + ROB_W'(a);
    end
    // Pointer and count advance by the number of allocations at once
    // (sv-timing A107), not by one serial increment per port.
    begin
      automatic logic [NR_ALLOC-1:0] alloc_fire;
      for (int unsigned a = 0; a < NR_ALLOC; a++) alloc_fire[a] = alloc_valid_i[a] && !full_o;
      tail_d  = tail_d + ROB_W'($countones(alloc_fire));
      count_d = count_d + (ROB_W + 1)'($countones(alloc_fire));
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
        // hyp8: head comes from the 2-step merge even under the mutant arm
        count_d = count_d - 1'b1;
      end
    end
`else
    // T6b-4b: free by transaction id — under per-hart commit heads commit
    // order across harts need not match dispatch order; a positional head+r
    // free would evict the wrong slot and leak the acked one.
    // Count still drops by one per port that hit. The slot clear is the
    // per-entry assign below; free_hit is that assign's predicate.
    for (int unsigned r = 0; r < NR_RETIRE; r++)
      count_d = count_d - (ROB_W + 1)'(|free_hit[r]);
    // hyp8: head is NOT re-anchored in this cone -- the post-event stop
    // vector is captured per quarter below and merged next cycle.
`endif
    if (flush_i) begin
      tail_d  = '0;
      count_d = '0;
    end
  end

  // Constant-index next state. Alloc, complete, cancel, free, flush keep
  // the old priority (later steps win) without a variable rob_d[idx] write.
  for (genvar s = 0; s < ROB_ENTRIES; s++) begin : gen_slot
    logic [NR_RETIRE-1:0] claimed;
    logic [NR_ALLOC-1:0] ahit;
    logic [NR_COMPLETE-1:0] whit;
    logic any_a, any_w, slot_free;
    logic [ROB_W-1:0] a_pick;
    logic             c_exc;
    logic             do_alloc;
    logic [TID_W-1:0] tid_nx;
    logic             vld_nx, cmp_nx;
    for (genvar r = 0; r < NR_RETIRE; r++) begin : gen_fr
      if (r == 0) begin : gen_r0
        assign claimed[r] = 1'b0;
      end else begin : gen_rn
        assign claimed[r] = claimed[r-1] | free_hit[r-1][s];
      end
      assign free_hit[r][s] = retire_ack_i[r] && rob_q[s].valid &&
                              (rob_q[s].tid == retire_tid_i[r]) && !claimed[r];
    end
    logic [NR_RETIRE-1:0] hit_col;
    for (genvar r = 0; r < NR_RETIRE; r++) begin : gen_col
      assign hit_col[r] = free_hit[r][s];
    end
    assign slot_free = |hit_col;
    for (genvar a = 0; a < NR_ALLOC; a++) begin : gen_ah
      assign ahit[a] = alloc_valid_i[a] && !full_o &&
                       ((tail_q + ROB_W'(a)) == ROB_W'(s));
    end
    // r42-T item 23 (A22): ahit is one-hot0 — at most one a satisfies
    // tail_q + a == s — so the last-match loop is a parallel OR of
    // exclusive arms.
    always_comb begin
      a_pick = '0;
      for (int unsigned a = 0; a < NR_ALLOC; a++)
        a_pick |= ahit[a] ? ROB_W'(a) : '0;
      any_a = |ahit;
    end
    for (genvar w = 0; w < NR_COMPLETE; w++) begin : gen_wh
      assign whit[w] = complete_valid_i[w] && rob_q[s].valid && !rob_q[s].complete &&
                       (rob_q[s].tid == complete_tid_i[w]);
    end
    // r42-T item 23 (A22): whit is one-hot0 (complete tids are unique).
    always_comb begin
      c_exc = '0;
      for (int unsigned w = 0; w < NR_COMPLETE; w++)
        c_exc |= whit[w] ? complete_exc_i[w] : '0;
      any_w = |whit;
    end
    assign do_alloc = any_a && !flush_i;
    assign tid_nx   = do_alloc ? alloc_tid_i[a_pick] : rob_q[s].tid;
    // Cancel of the held tid and of each alloc tid do not wait on a_pick.
    // A slot matches at most one alloc port, so the OR is the selected bit.
    logic held_kill, alloc_kill;
    logic [NR_ALLOC-1:0] alloc_kill_oh;
    assign held_kill = cancelled_mask_i[rob_q[s].tid];
    for (genvar a = 0; a < NR_ALLOC; a++) begin : gen_ak
      assign alloc_kill_oh[a] = ahit[a] && cancelled_mask_i[alloc_tid_i[a]];
    end
    assign alloc_kill = |alloc_kill_oh;
    assign vld_nx   = flush_i ? 1'b0 : (slot_free ? 1'b0 : (do_alloc ? 1'b1 : rob_q[s].valid));
    assign cmp_nx   = flush_i ? 1'b0 :
                      ((vld_nx && (do_alloc ? alloc_kill : held_kill)) || any_w) ? 1'b1 :
                      (do_alloc ? 1'b0 : rob_q[s].complete);
    assign rob_d[s].valid    = vld_nx;
//pragma translate_off
    // r42-T item 23 equivalence: the parallel pick must equal the
    // serial last-match form every cycle (it differs only if ahit/whit
    // is multi-hot, which would itself be a contract violation). The
    // check lives inside gen_slot because a generate scope only takes a
    // constant index.
    int unsigned  t2_rob_pick_n = 0;
    logic [ROB_W-1:0] ref_pick;
    logic             ref_exc;
    always_ff @(posedge clk_i) begin
      if (rst_ni) begin
        t2_rob_pick_n <= t2_rob_pick_n + 1;
        ref_pick = '0;
        ref_exc  = '0;
        for (int unsigned a = 0; a < NR_ALLOC; a++)
          if (ahit[a]) ref_pick = ROB_W'(a);
        for (int unsigned w = 0; w < NR_COMPLETE; w++)
          if (whit[w]) ref_exc = complete_exc_i[w];
        g6lc_t2_rob_pick_eq: assert (
          (a_pick === ref_pick) && (c_exc === ref_exc) &&
          (any_a === |ahit)      && (any_w === |whit))
          else $error("g6lc_rob: equiv pick slot=%0d", s);
      end
    end
    final begin
      if ($test$plusargs("equiv_report"))
        $display("[equiv] g6lc_rob pick[%0d]: checked=%0d", s, t2_rob_pick_n);
    end
//pragma translate_on
    assign rob_d[s].complete = cmp_nx;
    assign rob_d[s].exc      = flush_i ? 1'b0 : (any_w ? c_exc : (do_alloc ? 1'b0 : rob_q[s].exc));
    assign rob_d[s].tid      = flush_i ? '0 : tid_nx;
    assign rob_d[s].e        = flush_i ? '0 : (do_alloc ? alloc_entry_i[a_pick] : rob_q[s].e);
  end

  // hyp8 stage 1 (registered intermediate): the stop vector of the next
  // state -- post-free/post-alloc valid slots plus the tail (a full ring
  // keeps head == tail, an empty ring stops at head == tail) -- reduced to
  // one lowest-set candidate per quarter.
  for (genvar j = 0; j < ROB_ENTRIES; j++) begin : gen_anchor
    assign anchor_stop[j] = rob_d[j].valid || (ROB_W'(j) == tail_d);
  end
  // Quarter mask is a constant slice of the stop vector, then the same
  // lowest-set prefix. Quarters are independent.
  for (genvar q = 0; q < NQ; q++) begin : gen_qstop
    logic [ROB_ENTRIES-1:0] qmask;
    for (genvar j = 0; j < ROB_ENTRIES; j++) begin : gen_qbit
      if ((j >= q * QW) && (j < (q + 1) * QW)) begin : gen_in
        assign qmask[j] = anchor_stop[j];
      end else begin : gen_out
        assign qmask[j] = 1'b0;
      end
    end
    assign qstop_d[q] = flush_i ? '0 : lowest_set(qmask);
  end

  // Merge: one-hot of the first quarter at or above head, else the first
  // quarter. Same result as the serial have_ge / have_lo scan.
  logic [NQ-1:0] cand_v, cand_ge, lo_oh, ge_oh;
  logic [NQ-1:0][ROB_W-1:0] qidx;
  logic have_ge;
  logic [ROB_W-1:0] sel_ge, sel_lo;
  for (genvar q = 0; q < NQ; q++) begin : gen_qidx
    logic [ROB_ENTRIES-1:0][ROB_W-1:0] ibit;
    for (genvar j = 0; j < ROB_ENTRIES; j++) begin : gen_ibit
      assign ibit[j] = qstop_q[q][j] ? ROB_W'(j) : '0;
    end
    always_comb begin
      qidx[q] = '0;
      for (int unsigned j = 0; j < ROB_ENTRIES; j++) qidx[q] = qidx[q] | ibit[j];
    end
    assign cand_v[q]  = |qstop_q[q];
    assign cand_ge[q] = cand_v[q] && (qidx[q] >= head_q);
    if (q == 0) begin : gen_oh0
      assign lo_oh[q] = cand_v[q];
      assign ge_oh[q] = cand_ge[q];
    end else begin : gen_ohn
      assign lo_oh[q] = cand_v[q] && !(|cand_v[q-1:0]);
      assign ge_oh[q] = cand_ge[q] && !(|cand_ge[q-1:0]);
    end
  end
  assign have_ge = |cand_ge;
  always_comb begin
    sel_ge = '0;
    sel_lo = '0;
    for (int unsigned q = 0; q < NQ; q++) begin
      if (ge_oh[q]) sel_ge = qidx[q];
      if (lo_oh[q]) sel_lo = qidx[q];
    end
  end
  always_comb begin
    unique case (have_ge)
      1'b1:    head_d = flush_i ? '0 : sel_ge;
      default: head_d = flush_i ? '0 : sel_lo;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rob_q   <= '0;
      head_q  <= '0;
      tail_q  <= '0;
      count_q <= '0;
      qstop_q <= '0;
    end else begin
      rob_q   <= rob_d;
      head_q  <= head_d;
      tail_q  <= tail_d;
      count_q <= count_d;
      qstop_q <= qstop_d;
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

  // The head must always rest on a live stop (or tail): the 2-step anchor
  // can point at a slot freed underneath it for one cycle, so the check
  // tolerates that single lag cycle by accepting a slot that is valid in
  // the pre-update view.
  logic [ROB_ENTRIES-1:0] chk_stop;
  always_comb begin
    for (int unsigned j = 0; j < ROB_ENTRIES; j++)
      chk_stop[j] = rob_q[j].valid || (ROB_W'(j) == tail_q);
  end
  // The 2-step anchor derives head_d from the quarter one-hots registered
  // LAST cycle, so a stop freed this cycle legitimately leaves head_q dead
  // for exactly one cycle (the next merge re-anchors past it; retire simply
  // stalls that cycle). Tolerate that single lag cycle by accepting a slot
  // that was a stop in the previous cycle's view.
  logic [ROB_ENTRIES-1:0] chk_stop_q;
  always_ff @(posedge clk_i) begin
    if (!rst_ni || flush_i) chk_stop_q <= '0;
    else                  chk_stop_q <= chk_stop;
  end
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      for (int unsigned r = 0; r < NR_RETIRE; r++)
        ooo_rob_hit_onehot: assert ($onehot0(free_hit[r]))
          else $error("g6lc_rob: retire tid %0d names %0d entries", retire_tid_i[r], $countones(free_hit[r]));
      if (!flush_i)
        ooo_rob_head_stop: assert (chk_stop[head_q] || chk_stop_q[head_q] || count_q == '0)
          else $error("g6lc_rob: head %0d rests on no live stop", head_q);
    end
  end
  //pragma translate_on
endmodule
