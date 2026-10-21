// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// U2 Fetch Target Queue: holds predicted/sequential fetch addresses between
// the NPC/predictor and the I$ request port. Flushable in one cycle.
// When DEPTH=0 the module is not instantiated (frontend uses direct path).
//
// hyp8: every entry carries the fetch epoch it was pushed under. An override
// or redirect bumps the frontend epoch (g6lc_fe_redirect); entries stamped
// with an older epoch are wrong-path and are retired internally one per cycle
// (stale_head -> pop) instead of being demanded. head_*_o and the FDIP peek
// suppress stale entries immediately, so a dead head never reaches the I$
// even while it is still draining.

module g6lc_ftq
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8,
    parameter int unsigned DEPTH = 8
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    flush_i,
    // hyp8: current fetch epoch (g6lc_fe_redirect.epoch_o); entries pushed are
    // stamped with it and stale-epoch entries are dropped on pop
    input  logic [((HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1)-1:0] epoch_i,
    // Enqueue a fetch target (from NPC path)
    input  logic                    push_i,
    input  logic [G6LCCfg.VLEN-1:0] push_vaddr_i,
    input  logic                    push_taken_i,   // CF taken (for loop detection)
    input  logic [G6LCCfg.VLEN-1:0] push_target_i,  // taken target if push_taken_i
    // Demand dequeue (I$ accepted a demand fetch)
    input  logic                    pop_i,
    output logic [G6LCCfg.VLEN-1:0] head_vaddr_o,
    output logic                    head_taken_o,
    output logic [G6LCCfg.VLEN-1:0] head_target_o,
    output logic                    head_valid_o,
    // hyp8: epoch of the head entry (dead heads present head_valid_o=0 and are
    // retired internally; the epoch output is for callers that tag the block)
    output logic [((HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1)-1:0] head_epoch_o,
    // Peek for FDIP (entry at head+offset, if valid)
    input  logic [$clog2(DEPTH+1)-1:0] peek_offset_i,
    output logic [G6LCCfg.VLEN-1:0]    peek_vaddr_o,
    output logic                       peek_valid_o,
    output logic [((HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1)-1:0] peek_epoch_o,
    // Status
    output logic                    full_o,
    output logic                    empty_o,
    output logic [$clog2(DEPTH+1)-1:0] count_o
);

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin g6lc_ftq status=proposal target=10-adjusted-FO4
  // svt-plan: cone head+peek_offset read and queue count/pointer updates;
  // flush plus push intentionally seeds a new entry rather than dropping it.
  // svt-plan: reshape cache the head tuple and bank peek selection;
  // count accepted push/pop once, independent of wide tuple writes.
  // svt-plan: boundary optional peek request -> prefetch hint, keeping
  // demand head visibility separate from the nonblocking prefetch stream.
  // svt-plan: carry VA/taken/target, offset and head/flush epoch; drop a
  // delayed peek after its head moved or queue was reseeded.
  // svt-plan: effect splits peek addition/read from prefetch PMA selection;
  // demand count feedback remains local instead of gaining another stage.
  // svt-plan: cost head/peek registers; preserve full/empty behavior and
  // same-cycle flush+push, which define the next demand stream.
  // svt-plan: limit stale peek is discardable, stale demand head is not;
  // head caching needs correct refill on every accepted pop and wrap.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 19.8 adjusted FO4 on the
  // Nangate45 board): fetch target queue: push / pop state (id-less fetch domain).
  // svt-pipe: require-contract
  // svt-pipe: protocol fq valid=push_i flush=flush_i
  // svt-pipe: no-cut on=count_o
  // svt-pipe: cycle fq q=count_o d=head_valid_o hold=push_i steps=1

  localparam int unsigned PTR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
  localparam int unsigned EW = (HypCfg.FeEpochBits > 0) ? HypCfg.FeEpochBits : 1;

  typedef struct packed {
    logic                    valid;
    logic [G6LCCfg.VLEN-1:0] vaddr;
    logic                    taken;
    logic [G6LCCfg.VLEN-1:0] target;
    logic [EW-1:0]           epoch;  // hyp8: fetch epoch at push
  } entry_t;

  entry_t [DEPTH-1:0] mem_q;
  logic [PTR_W-1:0] head_q, tail_q;
  logic [PTR_W:0] count_q;

  // hyp8: the head is stale when its stamp predates the current epoch. Such
  // entries are never presented (head_valid_o=0) and never peeked at; they
  // drain internally at one entry per cycle through the shared pop arm.
  logic stale_head;
  assign stale_head = !empty_o && mem_q[head_q].valid && (mem_q[head_q].epoch != epoch_i);

  assign empty_o     = (count_q == '0);
  assign full_o      = (count_q == DEPTH[PTR_W:0]);
  assign count_o     = count_q;
  assign head_valid_o = !empty_o && mem_q[head_q].valid && !stale_head;
  assign head_vaddr_o = mem_q[head_q].vaddr;
  assign head_taken_o = mem_q[head_q].taken;
  assign head_target_o = mem_q[head_q].target;
  assign head_epoch_o = mem_q[head_q].epoch;

  // Peek at head + offset (mod DEPTH)
  logic [PTR_W-1:0] peek_ptr;
  // BEGIN sv-timing auto-correct (balance_mux rewrite)
  // sv-timing select_increment: `peek_ptr = head_q + PTR_W'(peek_offset_i)` -> 16 precomputed
  // typed offsets of the register (off the `peek_offset_i` cone) and one select.
  var type(peek_ptr) peek_ptr_svt_cand [0:15];
  for (genvar svt_j = 0; svt_j < 16; svt_j++) begin : gen_peek_ptr_svt_cand
    assign peek_ptr_svt_cand[svt_j] = type(peek_ptr)'(head_q + PTR_W'(type(peek_offset_i)'(4'(svt_j))));
  end
  // END sv-timing auto-correct (balance_mux rewrite)
  assign peek_ptr = (peek_offset_i[3] ? peek_ptr_svt_cand[{1'b1, peek_offset_i[2:0]}] : peek_ptr_svt_cand[{1'b0, peek_offset_i[2:0]}]); // sv-timing: BalanceMux/rebalance #221 RHS rewrite
  // hyp8: a stale-epoch peek must not launch an FDIP prefetch for a dead path
  assign peek_valid_o = (count_q > peek_offset_i) && mem_q[peek_ptr].valid &&
                        (mem_q[peek_ptr].epoch == epoch_i);
  assign peek_vaddr_o = mem_q[peek_ptr].vaddr;
  assign peek_epoch_o = mem_q[peek_ptr].epoch;

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
        mem_q[0].epoch  <= epoch_i;
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
        mem_q[tail_q].epoch  <= epoch_i;
        tail_q <= tail_q + PTR_W'(1);
        c = c + (PTR_W+1)'(1);
      end
      // hyp8: stale heads retire without a demand; a real pop still wins the
      // cycle (both remove the head).
      if ((pop_i || stale_head) && !empty_o) begin
        mem_q[head_q].valid <= 1'b0;
        head_q <= head_q + PTR_W'(1);
        c = c - (PTR_W+1)'(1);
      end
      count_q <= c;
    end
  end

endmodule
