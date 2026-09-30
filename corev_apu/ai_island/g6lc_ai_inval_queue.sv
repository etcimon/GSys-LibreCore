// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai island DMA write -> cache-line invalidation queue (AiCfg.DmaInvalEn).
//
// The island joins the fabric BELOW the cluster: its writes (C tiles, completion
// words, descriptor status) land in DRAM without passing the coherence hub, the
// L2/L3 or any WT L1, so a core that already holds one of those lines keeps a
// stale copy. This queue turns every completed island write into an `inval` on
// the eWT CMO engine's writer port (g6lc_cmo_engine NR_WRITERS), which broadcasts
// the line to every L1 and clears the L2/L3 tags -- the same path `cbo.inval`
// takes. Contract the island top builds on:
//
//   idle_o  <=>  every write this queue has seen is (a) complete (B returned)
//                and (b) invalidated through the hierarchy (done returned).
//
// Ordering: an invalidation is issued only AFTER the write's B (the data is in
// DRAM), never at AW -- an inval before landing would let a core re-fetch the
// old data and cache it again. Line coalescing at the tail (consecutive
// single-line writes to one 64 B line share one entry with a B count) keeps a
// pair-store C row at one inval per line. The queue backpressures the island's
// AW when full so no line is ever dropped; one invalidation is in flight at a
// time.
//
// The island issues writes from ONE master (fetch/GEMM/completion store are
// muxed, one writer active), so B responses return in AW order and a single
// FIFO with two consumers suffices: `b_ptr` walks it as B's land, `rd` walks it
// as lines are invalidated (rd <= b_ptr <= wr).

module g6lc_ai_inval_queue #(
    parameter int unsigned AddrWidth = 64,
    parameter int unsigned LineBytes = 64,
    parameter int unsigned Depth     = 8,     // entries (bursts) awaiting B / inval
    parameter int unsigned BeatCntW  = 9      // coalesced B count per entry
) (
    input  logic                 clk_i,
    input  logic                 rst_ni,
    // Island master write handshakes (post-arbitration, post-cut).
    input  logic                 aw_fire_i,
    input  logic [AddrWidth-1:0] aw_addr_i,
    input  logic [7:0]           aw_len_i,        // beats - 1
    input  logic [2:0]           aw_size_i,       // log2 bytes per beat
    input  logic                 b_fire_i,
    // Hold the island's AW when the queue cannot take another entry.
    output logic                 aw_hold_o,
    // Writer port of g6lc_cmo_engine (inval only).
    output logic                 inval_valid_o,
    output logic [AddrWidth-1:0] inval_addr_o,
    input  logic                 inval_ready_i,
    input  logic                 inval_done_i,
    // Every seen write landed and its line(s) were invalidated everywhere.
    output logic                 idle_o,
    // Observability: lines invalidated, AW cycles held.
    output logic [31:0]          pmu_invals_o,
    output logic [31:0]          pmu_hold_o
);
  localparam int unsigned LineShift = $clog2(LineBytes);
  localparam int unsigned PtrW = (Depth > 1) ? $clog2(Depth) : 1;
  localparam int unsigned CntW = $clog2(Depth + 1);

  // One entry per AW: {first line, lines covered - 1, B responses awaited}.
  // A multi-line burst (a 2 KiB C row = 32 lines) is one entry released by its
  // single B; the inval side then walks its lines one at a time. Consecutive
  // single-line AWs to the same line coalesce into the tail entry's B count.
  typedef struct packed {
    logic [AddrWidth-LineShift-1:0] line;
    logic [7:0]                     nlines;
    logic [BeatCntW-1:0]            nb;
  } ent_t;

  ent_t            q_q [Depth];
  logic [PtrW-1:0] wr_q, bp_q, rd_q;     // push, B-consume, inval-walk pointers
  logic [CntW-1:0] cnt_q;                // entries pushed and not yet walked
  logic [CntW-1:0] land_q;               // entries pushed and not yet landed (B)
  logic            full, empty, none_pending_b;
  assign full  = (cnt_q == CntW'(Depth));
  assign empty = (cnt_q == '0);
  assign none_pending_b = (land_q == '0);

  // Lines touched by the AW: first to last byte.
  logic [AddrWidth-1:0] aw_last_byte;
  logic [AddrWidth-LineShift-1:0] aw_line0, aw_line1;
  logic [7:0] aw_nlines;
  always_comb begin
    aw_last_byte = aw_addr_i + ((AddrWidth'(aw_len_i) + 1) << aw_size_i) - 1;
    aw_line0  = aw_addr_i[AddrWidth-1:LineShift];
    aw_line1  = aw_last_byte[AddrWidth-1:LineShift];
    aw_nlines = 8'(aw_line1 - aw_line0);
  end

  // Tail coalescing: single-line AW onto a single-line tail that still awaits
  // at least one B (the tail has not been consumed by bp) and has count room.
  logic            tail_same;
  logic [PtrW-1:0] tail_idx;
  assign tail_idx  = wr_q - PtrW'(1);
  assign tail_same = !none_pending_b && (aw_nlines == 8'd0) &&
                     (q_q[tail_idx].nlines == 8'd0) && (q_q[tail_idx].line == aw_line0) &&
                     (q_q[tail_idx].nb != '1);
  assign aw_hold_o = full && !tail_same;

  // B consumption: the oldest not-yet-landed entry is q_q[bp_q].
  // A same-cycle coalescing push onto the bp entry keeps its count (+1 -1), so it
  // does not land on this B.
  logic b_lands_entry, same_cycle_refill;
  assign same_cycle_refill = tail_same && aw_fire_i && (tail_idx == bp_q);
  assign b_lands_entry = b_fire_i && !none_pending_b && (q_q[bp_q].nb == BeatCntW'(1)) &&
                         !same_cycle_refill;

  // Inval walker over landed entries (rd_q != bp_q).
  logic                           walk_v_q, inval_out_q;
  logic [AddrWidth-LineShift-1:0] walk_line_q;
  logic [7:0]                     walk_rem_q;
  logic landed_avail, take_head;
`ifdef G6LC_MUT_INVAL_AT_AW
  // Review mutation: walk entries as soon as they are pushed (before B). The
  // leaf's "no inval before its write landed" check must fail on this build.
  assign landed_avail = !empty;
`else
  assign landed_avail = (cnt_q != land_q);           // entries between rd and bp
`endif
  assign take_head    = !walk_v_q && landed_avail;

  assign inval_valid_o = walk_v_q && !inval_out_q;
  assign inval_addr_o  = {walk_line_q, {LineShift{1'b0}}};
  assign idle_o        = empty && !walk_v_q && !inval_out_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_q <= '0; bp_q <= '0; rd_q <= '0; cnt_q <= '0; land_q <= '0;
      for (int i = 0; i < Depth; i++) q_q[i] <= '0;
      walk_v_q <= 1'b0; walk_line_q <= '0; walk_rem_q <= '0; inval_out_q <= 1'b0;
      pmu_invals_o <= '0; pmu_hold_o <= '0;
    end else begin
      // ---- push / coalesce ----
      if (aw_fire_i) begin
        if (tail_same) q_q[tail_idx].nb <= q_q[tail_idx].nb + BeatCntW'(1);
        else begin
          q_q[wr_q] <= '{line: aw_line0, nlines: aw_nlines, nb: BeatCntW'(1)};
          wr_q <= wr_q + PtrW'(1);
        end
      end
      if (aw_hold_o) pmu_hold_o <= pmu_hold_o + 32'd1;
      // ---- B: land the oldest pending entry ----
      if (b_fire_i && !none_pending_b) begin
        // nb decrement and the coalescing increment never target the same
        // entry in one cycle unless the tail is the bp entry with nb>=2 (then
        // the two updates below are on different fields/values; keep it exact).
        if (same_cycle_refill)
          q_q[bp_q].nb <= q_q[bp_q].nb;             // +1 -1
        else
          q_q[bp_q].nb <= q_q[bp_q].nb - BeatCntW'(1);
        if (b_lands_entry) bp_q <= bp_q + PtrW'(1);
      end
      // ---- landed head -> walker ----
      if (take_head) begin
        walk_v_q    <= 1'b1;
        walk_line_q <= q_q[rd_q].line;
        walk_rem_q  <= q_q[rd_q].nlines;
        rd_q <= rd_q + PtrW'(1);
      end
      // ---- occupancy ----
      cnt_q  <= cnt_q  + CntW'(aw_fire_i && !tail_same) - CntW'(take_head);
      land_q <= land_q + CntW'(aw_fire_i && !tail_same) - CntW'(b_lands_entry);
      // ---- inval issue / done ----
      if (inval_valid_o && inval_ready_i) inval_out_q <= 1'b1;
      if (inval_out_q && inval_done_i) begin
        inval_out_q  <= 1'b0;
        pmu_invals_o <= pmu_invals_o + 32'd1;
        if (walk_rem_q == 8'd0) walk_v_q <= 1'b0;
        else begin
          walk_rem_q  <= walk_rem_q - 8'd1;
          walk_line_q <= walk_line_q + 1'b1;
        end
      end
    end
  end

  // pragma translate_off
  always_ff @(posedge clk_i) if (rst_ni) begin
    assert (!(aw_fire_i && aw_hold_o))
      else $error("g6lc_ai_inval_queue: AW accepted while the queue held it");
    assert (!(b_fire_i && none_pending_b))
      else $error("g6lc_ai_inval_queue: B without a pending AW");
`ifndef G6LC_MUT_INVAL_AT_AW
    // (off under the review mutation so the leaf's ORDER oracle, not this
    // bookkeeping check, is what catches an inval issued before its B)
    assert (land_q <= cnt_q)
      else $error("g6lc_ai_inval_queue: landed count exceeds occupancy");
`endif
  end
  // pragma translate_on
endmodule
