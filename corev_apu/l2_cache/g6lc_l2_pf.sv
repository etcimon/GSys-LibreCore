// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_l2_pf — demand-miss trained stream/stride prefetcher front-end for
// g6lc_l2_top (T9h/M5). The engine is a pure candidate source: it observes
// the S_TAG miss-commit stream (train_i/train_line_i) and emits at most one
// prefetch candidate line per cycle (cand_valid_o/cand_line_o, take via
// cand_take_i). All admission decisions — tag residency, MSHR dedup, the
// write-tracker R1 rule, the demand reserve — live in g6lc_l2_top; this
// module only learns the pattern and proposes lines.
//
// Streams are keyed on the 4 KiB page of the miss line (region tag): a
// stream can never propose a candidate outside its own page, so the page
// bound is structural, not a check. Next-line is stride=1 through the same
// path; a stride other than 1 is only armed when STRIDE_EN and confirmed by
// two consecutive equal deltas (the stored stride is the previous delta, so
// the first equal pair both confirms and triggers).
//
// Each trigger arms PF_DISTANCE pending candidates ahead of the training
// miss; a per-stream round-robin drains at most one per cycle. Candidates
// are re-derived from the stream's last miss, so a retrained stream never
// emits stale absolute addresses.
//
// Timing: the stream table is NR_STREAMS-deep (default 4) and sits off the
// demand path — train_i is a flop write, the candidate output is a
// registered walk. Nothing here lengthens the S_TAG compare or the MSHR
// alloc cone.

module g6lc_l2_pf #(
    parameter int unsigned NR_STREAMS   = 4,
    parameter int unsigned PF_DISTANCE  = 2,
    parameter bit          STRIDE_EN    = 1'b1,
    // T10b/N3 burst throttling: a confirmation arms at most MAX_OUT
    // candidates per stream (capped by PF_DISTANCE), no candidate is
    // offered within QUIET cycles of a demand miss commit, and a stream
    // must log two confirmed deltas before it may arm at all.
    parameter int unsigned MAX_OUT      = 1,
    parameter int unsigned QUIET        = 8,
    parameter int unsigned LINE_BYTES   = 64,
    parameter int unsigned AXI_ADDR_WIDTH = 64
) (
    input  logic clk_i,
    input  logic rst_ni,
    // Demand miss commit: line address of a cacheable read that just
    // allocated (fresh or merged) in the MSHR. One pulse per commit.
    input  logic                        train_i,
    input  logic [AXI_ADDR_WIDTH-1:0]   train_line_i,
    // Candidate stream: held until cand_take_i. At most one per cycle.
    output logic                        cand_valid_o,
    output logic [AXI_ADDR_WIDTH-1:0]   cand_line_o,
    input  logic                        cand_take_i
);

  localparam int unsigned OFF_BITS   = $clog2(LINE_BYTES);
  localparam int unsigned PAGE_LBITS = 12 - OFF_BITS;          // lines per 4 KiB
  localparam int unsigned LINE_BITS  = AXI_ADDR_WIDTH - OFF_BITS;
  localparam int unsigned PAGETAG_W  = LINE_BITS - PAGE_LBITS; // page number
  localparam int unsigned SW         = (NR_STREAMS <= 1) ? 1 : $clog2(NR_STREAMS);
  localparam int unsigned PW         = (PF_DISTANCE <= 1) ? 1 : $clog2(PF_DISTANCE + 1);
  localparam int unsigned DLT_W      = PAGE_LBITS + 1;         // signed delta
  // Burst cap: a confirmation can never arm more than the look-ahead or
  // the per-stream outstanding limit, whichever is smaller.
  localparam int unsigned PEND_CAP   = (MAX_OUT < PF_DISTANCE) ? MAX_OUT : PF_DISTANCE;
  localparam int unsigned QW         = (QUIET <= 1) ? 1 : $clog2(QUIET + 1);

  typedef struct packed {
    logic                      valid;
    logic [PAGETAG_W-1:0]      page;      // region tag = 4 KiB page number
    logic [LINE_BITS-1:0]      last;      // last trained line index
    logic signed [DLT_W-1:0]   stride;    // previous within-page delta
    logic                      seen;      // a first delta has been recorded
    logic [1:0]                conf;      // confirmed-delta count (saturates 3)
    logic [PW-1:0]             pend;      // armed candidates not yet emitted
    logic [PW-1:0]             ahead;     // next pend offset (1..PF_DISTANCE)
  } stream_t;

  stream_t [NR_STREAMS-1:0] st_q, st_d;
  logic [SW-1:0]             rr_q, rr_d;
  // Demand-miss quiet window: train_i reloads the countdown, and while it
  // is non-zero no candidate is offered (pend keeps its arming).
  logic [QW-1:0]             quiet_q, quiet_d;
  // Emit cursor: which stream is currently holding a pending candidate.
  // cand_valid_o is registered with the line so the output is a stable
  // offer, not a combinational walk of the table.
  logic                      cnd_vld_q, cnd_vld_d;
  logic [LINE_BITS-1:0]      cnd_line_q, cnd_line_d;

  function automatic logic [PAGETAG_W-1:0] page_of(
      input logic [LINE_BITS-1:0] l);
    return l[LINE_BITS-1:PAGE_LBITS];
  endfunction

  function automatic logic signed [DLT_W-1:0] delta_of(
      input logic [LINE_BITS-1:0] cur, input logic [LINE_BITS-1:0] last);
    return DLT_W'($signed({1'b0, cur[PAGE_LBITS-1:0]}) -
                  $signed({1'b0, last[PAGE_LBITS-1:0]}));
  endfunction

  // Candidates beyond the arming miss's own page are never armed.
  function automatic logic in_page(
      input logic [LINE_BITS-1:0] cand, input logic [LINE_BITS-1:0] last);
    return page_of(cand) == page_of(last);
  endfunction

  // Stream match for the training address (also gates the emit walk below).
  logic [LINE_BITS-1:0] train_line;
  logic                 train_hit;
  logic [SW-1:0]        train_hit_idx;
  assign train_line = train_line_i[AXI_ADDR_WIDTH-1:OFF_BITS];
  always_comb begin
    train_hit     = 1'b0;
    train_hit_idx = '0;
    for (int unsigned s = 0; s < NR_STREAMS; s++) begin
      if (st_q[s].valid && (st_q[s].page == page_of(train_line))) begin
        train_hit     = 1'b1;
        train_hit_idx = SW'(s);
      end
    end
  end

  always_comb begin
    // Hoisted locals — Verilator flags block-scope automatics that are only
    // conditionally assigned as latches; declare and default them here.
    int unsigned             em_s;
    int unsigned             em_v;
    logic                    em_found;
    logic [LINE_BITS-1:0]    em_base;
    logic signed [DLT_W-1:0] tr_d;
    logic signed [DLT_W-1:0] tr_str;
    em_s     = '0;
    em_v     = '0;
    em_found = 1'b0;
    em_base  = '0;
    tr_d     = '0;
    tr_str   = '0;
    st_d       = st_q;
    rr_d       = rr_q;
    cnd_vld_d  = cnd_vld_q;
    cnd_line_d = cnd_line_q;

    // ---- quiet window after a demand miss commit ----
    quiet_d = (quiet_q != '0) ? quiet_q - 1'b1 : '0;
    if (train_i) quiet_d = QW'(QUIET);

    // ---- retire the offered candidate ----
    if (cnd_vld_q && cand_take_i) cnd_vld_d = 1'b0;

    // ---- refill the offer register: round-robin over armed streams ----
    if (!cnd_vld_d && (quiet_d == '0)) begin
      for (int unsigned k = 0; k < NR_STREAMS; k++) begin
        em_s = (rr_q + k) % NR_STREAMS;
        // A stream being retrained this cycle keeps its new epoch: do not
        // emit a candidate derived from the old `last`.
        if (!cnd_vld_d && st_q[em_s].valid && (st_q[em_s].pend != '0) &&
            !(train_i && train_hit && (train_hit_idx == SW'(em_s)))) begin
          em_base = st_q[em_s].last +
                    LINE_BITS'($signed(st_q[em_s].stride) *
                               $signed({1'b0, st_q[em_s].ahead}));
          if (in_page(em_base, st_q[em_s].last)) begin
            cnd_vld_d  = 1'b1;
            cnd_line_d = em_base;
            st_d[em_s].pend  = st_q[em_s].pend - 1'b1;
            st_d[em_s].ahead = st_q[em_s].ahead + 1'b1;
            rr_d             = SW'((em_s + 1) % NR_STREAMS);
          end else begin
            // Page bound reached: drop the rest of this burst.
            st_d[em_s].pend = '0;
          end
        end
      end
    end

    // ---- train on a demand miss commit ----
    if (train_i) begin
      if (train_hit) begin
        tr_d = delta_of(train_line, st_q[train_hit_idx].last);
        st_d[train_hit_idx].last = train_line;
        if (tr_d != 0) begin
          tr_str = STRIDE_EN ? tr_d : DLT_W'(1);
          if (st_q[train_hit_idx].seen &&
              (tr_d == st_q[train_hit_idx].stride)) begin
            // Equal deltas → confirmed hit. N3: a stream arms only on its
            // SECOND confirmed hit (conf ≥ 2 counting this one) and then at
            // most PEND_CAP candidates — the burst cap that keeps PF fills
            // from crowding demand.
            st_d[train_hit_idx].stride = tr_str;
            st_d[train_hit_idx].conf   = (st_q[train_hit_idx].conf == 2'd3)
                ? st_q[train_hit_idx].conf : st_q[train_hit_idx].conf + 2'd1;
            if (st_q[train_hit_idx].conf >= 2'd1) begin
              st_d[train_hit_idx].pend  = PW'(PEND_CAP);
              st_d[train_hit_idx].ahead = PW'(1);
            end
          end else begin
            // First/changed delta: (re)train, drop the confidence history.
            st_d[train_hit_idx].stride = tr_str;
            st_d[train_hit_idx].seen   = 1'b1;
            st_d[train_hit_idx].conf   = '0;
            st_d[train_hit_idx].pend   = '0;
          end
        end
      end else begin
        // New region: first invalid stream, else the round-robin victim.
        em_v     = rr_q;
        em_found = 1'b0;
        for (int unsigned s = 0; s < NR_STREAMS; s++) begin
          if (!st_q[s].valid && !em_found) begin
            em_v     = s;
            em_found = 1'b1;
          end
        end
        st_d[em_v].valid  = 1'b1;
        st_d[em_v].page   = page_of(train_line);
        st_d[em_v].last   = train_line;
        st_d[em_v].stride = '0;
        st_d[em_v].seen   = 1'b0;
        st_d[em_v].conf   = '0;
        st_d[em_v].pend   = '0;
        st_d[em_v].ahead  = '0;
        rr_d = SW'((em_v + 1) % NR_STREAMS);
      end
    end
  end

  // The quiet window withholds the offer without dropping it: an armed
  // candidate presents again once QUIET cycles have passed with no demand
  // miss commit.
  assign cand_valid_o = cnd_vld_q && (quiet_q == '0);
  assign cand_line_o  = {cnd_line_q, {OFF_BITS{1'b0}}};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_q      <= '{default: '0};
      rr_q      <= '0;
      quiet_q   <= '0;
      cnd_vld_q <= 1'b0;
      cnd_line_q <= '0;
    end else begin
      st_q      <= st_d;
      rr_q      <= rr_d;
      quiet_q   <= quiet_d;
      cnd_vld_q <= cnd_vld_d;
      cnd_line_q <= cnd_line_d;
    end
  end

endmodule
