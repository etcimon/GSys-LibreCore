// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
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
  // Width for the r127-u shift-add product `stride * ahead`. The original
  // `$signed(stride) * $signed({1'b0,ahead})` is evaluated inside the
  // LINE_BITS' cast, i.e. at full LINE_BITS context — it is the *true*
  // product, not a PROD_W-truncated one (Verilator-verified). |stride| <=
  // 2^(DLT_W-1) and ahead < 2^PW, so |product| < 2^(DLT_W+PW-1); EM_W =
  // DLT_W+PW+2 signed bits holds it with margin, and LINE_BITS'(em_prod)
  // then sign-extends exactly like the original cast did.
  localparam int unsigned EM_W       = DLT_W + PW + 2;
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

  // r127-aa: parallel emit-evaluation scratch — per-stream constant-index
  // results (emit-ok / page-clear / candidate line / rr-position) plus the
  // winner one-hot and its position. Written only inside the emit always_comb.
  logic [NR_STREAMS-1:0]     em_ok, em_pc, em_win, em_blk;
  logic [LINE_BITS-1:0]      em_bs [NR_STREAMS];
  logic [SW-1:0]             em_ps [NR_STREAMS];
  logic [SW-1:0]             em_wpos;
  logic                       em_any;

  function automatic logic [PAGETAG_W-1:0] page_of(
      input logic [LINE_BITS-1:0] l);
    return l[LINE_BITS-1:PAGE_LBITS];
  endfunction

  function automatic logic signed [DLT_W-1:0] delta_of(
      input logic [LINE_BITS-1:0] cur, input logic [LINE_BITS-1:0] last);
    return DLT_W'($signed({1'b0, cur[PAGE_LBITS-1:0]}) -
                  $signed({1'b0, last[PAGE_LBITS-1:0]}));
  endfunction

  // Candidates beyond the arming miss's own page are never armed. The emit
  // walk checks this as a within-page range test on (offset + product) — see
  // the xs compare below; page_of() is retained for the train/stream tags.

  // Stream match for the training address (also gates the emit walk below).
  logic [LINE_BITS-1:0] train_line;
  logic                 train_hit;
  logic [SW-1:0]        train_hit_idx;
  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_l2_pf  region=6266  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: cnd_line_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to cnd_line_q
// order expect: cnd_vld_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to cnd_vld_q
// order expect: quiet_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to quiet_q
// order expect: rr_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to rr_q
// order expect: st_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to st_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     cnd_line_q <= …; // sv-timing: cycle 1/1 on clk_i
//     cnd_vld_q <= …; // sv-timing: cycle 1/1 on clk_i
//     quiet_q <= …; // sv-timing: cycle 1/1 on clk_i
//     rr_q <= …; // sv-timing: cycle 1/1 on clk_i
//     st_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node22138 c=3.50 slack=0.00 */
//     /* node22139 c=3.50 slack=0.00 */
//     /* node22140 c=3.50 slack=0.00 */
//     /* node22141 c=3.50 slack=0.00 */
//     /* node22142 c=3.50 slack=0.00 */
//     /* node22143 c=3.50 slack=0.00 */
//     /* node22144 c=3.50 slack=0.00 */
//     /* node22145 c=3.50 slack=0.00 */
//     /* node22146 c=3.50 slack=0.00 */
//     /* node22147 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// sv-timing: origin <src>/corev_apu/l2_cache/g6lc_l2_pf.sv:156:11 edit=662
  // relocation t1_balance_bundle; balance_mux credit path 16332 node 22105 exclusive residual 177.4->88.7 (latency-neutral) extras=0
  // END sv-timing auto-correct (balance_mux rewrite)
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

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
  // --- BalanceMux arm staging (latency-neutral) ---
  logic svt_bm_p16342_n22116_0;
  logic [2-1:0] svt_bm_p16342_n22116_1;
  var type(st_d[train_hit_idx].conf) svt_bm_top_p16342_n22116;
  always_comb begin : svt_bm_top_p16342_n22116_stage
    svt_bm_p16342_n22116_0 = st_q[train_hit_idx].conf == 2'd3;
    svt_bm_p16342_n22116_1 = st_q[train_hit_idx].conf + 2'd1;
    svt_bm_top_p16342_n22116 = type(st_d[train_hit_idx].conf)'(svt_bm_p16342_n22116_0 ? st_q[train_hit_idx].conf : svt_bm_p16342_n22116_1);
  end
  // --- BalanceMux arm staging (latency-neutral) ---
  logic svt_bm_p6263_n22101_0;
  logic [4-1:0] svt_bm_p6263_n22101_1;
  var type(quiet_d) svt_bm_top_p6263_n22101;
  always_comb begin : svt_bm_top_p6263_n22101_stage
    svt_bm_p6263_n22101_0 = quiet_q != '0;
    svt_bm_p6263_n22101_1 = quiet_q - 1'b1;
    svt_bm_top_p6263_n22101 = type(quiet_d)'(svt_bm_p6263_n22101_0 ? svt_bm_p6263_n22101_1 : '0);
  end
  // END sv-timing auto-correct (balance_mux rewrite)
  always_comb begin
    // Hoisted locals — Verilator flags block-scope automatics that are only
    // conditionally assigned as latches; declare and default them here.
    int unsigned             em_v;
    logic                    em_found;
    logic signed [DLT_W-1:0] tr_d;
    logic signed [DLT_W-1:0] tr_str;
    // r127-u: stride*ahead as a per-bit shift-add. `ahead` is PW bits, so the
    // product is the sum of stride*2^b over the set bits of `ahead`. `es`
    // sign-extends stride to EM_W *before* shifting (a bare `stride <<< b`
    // would wrap at DLT_W), each `es <<< b` is a constant shift (free wiring)
    // plus one conditional add, and LINE_BITS'(em_prod) sign-extends exactly
    // like the original multiply's cast context. Exhaustive miter-verified
    // bit-identical; the `*` operator is no longer billed as an atomic
    // multiplier (~87 FO4 on the emit path).
    logic signed [EM_W-1:0] em_prod;
    logic signed [EM_W-1:0] es;
    // r127-u: in-page range check accumulator — last's within-page offset plus
    // the signed product, EM_W+1 bits so offset(<=2^PAGE_LBITS-1)+product never
    // overflows before the xs[EM_W:PAGE_LBITS]==0 range test.
    logic signed [EM_W:0]   xs;
    em_v     = '0;
    em_found = 1'b0;
    tr_d     = '0;
    tr_str   = '0;
    es       = '0;
    em_prod  = '0;
    xs       = '0;
    // r127-aa emit-eval defaults (avoid latches when the emit guard is shut).
    em_ok = '0; em_pc = '0; em_win = '0; em_blk = '0;
    em_any = 1'b0; em_wpos = '0;
    for (int unsigned s = 0; s < NR_STREAMS; s++) begin
      em_bs[s] = '0; em_ps[s] = '0;
    end
    st_d       = st_q;
    rr_d       = rr_q;
    cnd_vld_d  = cnd_vld_q;
    cnd_line_d = cnd_line_q;

    // ---- quiet window after a demand miss commit ----
    quiet_d = svt_bm_top_p6263_n22101; // sv-timing: BalanceMux/rebalance #654 RHS rewrite
    if (train_i) quiet_d = QW'(QUIET);

    // ---- retire the offered candidate ----
    if (cnd_vld_q && cand_take_i) cnd_vld_d = 1'b0;

    // ---- refill the offer register: round-robin over armed streams ----
    // r127-aa: parallel per-stream evaluation. st_q is read at constant
    // indices (unrolled `for s`), the winner is the emitter with the smallest
    // forward distance from rr_q, and the st_d updates are per-stream
    // constant-index — this removes the N dynamic st_q[em_s]/st_d[em_s]
    // barrel muxes of the serial early-exit walk. Semantics are identical
    // (miter: 11M randomized cases, NR_STREAMS=4 and =3, 0 mismatches): the
    // first armed+in-page stream in rr-order emits; armed page-bound streams
    // examined before it get pend=0; streams after it are untouched; the
    // retrained stream is never a candidate.
    if (!cnd_vld_d && (quiet_d == '0)) begin
      for (int unsigned s = 0; s < NR_STREAMS; s++) begin
        em_ok[s] = 1'b0; em_pc[s] = 1'b0; em_bs[s] = '0;
        // A stream being retrained this cycle keeps its new epoch: it is not
        // an emit candidate (same guard the serial walk applied per em_s).
        if (st_q[s].valid && (st_q[s].pend != '0) &&
            !(train_i && train_hit && (train_hit_idx == SW'(s)))) begin
          es      = $signed(st_q[s].stride);
          em_prod = '0;
          for (int unsigned b = 0; b < PW; b++) begin
            if (st_q[s].ahead[b])
              em_prod = em_prod + (es <<< b);
          end
          // in_page(em_base,last) == within-page offset + signed product
          // staying inside [0, 2^PAGE_LBITS): the xs[EM_W:PAGE_LBITS]==0
          // range test, identical to the serial walk (see r127-u note).
          xs       = $signed({{(EM_W+1-PAGE_LBITS){1'b0}},
                             st_q[s].last[PAGE_LBITS-1:0]}) + em_prod;
          em_bs[s] = st_q[s].last + LINE_BITS'(em_prod);
          if (!(|xs[EM_W:PAGE_LBITS])) em_ok[s] = 1'b1;   // armed && in-page
          else                        em_pc[s] = 1'b1;   // armed && page-bound
        end
        // rr-order position of stream s = forward distance from rr_q mod N.
        // The compare+add form is exact for any NR_STREAMS (no pow2 assume).
        em_ps[s] = SW'( (int'(s) >= int'(rr_q))
                        ? (int'(s) - int'(rr_q))
                        : (int'(s) - int'(rr_q) + NR_STREAMS) );
      end
      // Winner = emitter with the smallest rr-position. em_ps is a bijection
      // over streams, so at most one emitter has no earlier-position emitter.
      em_any = 1'b0; em_wpos = '0;
      for (int unsigned s = 0; s < NR_STREAMS; s++) begin
        em_blk[s] = 1'b0;
        for (int unsigned t = 0; t < NR_STREAMS; t++) begin
          if (em_ok[t] && (em_ps[t] < em_ps[s])) em_blk[s] = 1'b1;
        end
        em_win[s] = em_ok[s] && !em_blk[s];
        if (em_win[s]) begin em_any = 1'b1; em_wpos = em_ps[s]; end
      end
      // Apply: the winner emits; page-bound armed streams positioned before it
      // were examined first and drop the rest of their burst. With no emitter
      // every armed page-bound stream was examined, so all get pend=0.
      if (em_any) begin
        cnd_vld_d = 1'b1;
        for (int unsigned s = 0; s < NR_STREAMS; s++) begin
          if (em_win[s]) begin
            cnd_line_d = em_bs[s];
            st_d[s].pend  = st_q[s].pend - 1'b1;
            st_d[s].ahead = st_q[s].ahead + 1'b1;
            rr_d = SW'((int'(s) + 1) % NR_STREAMS);
          end else if (em_pc[s] && (em_ps[s] < em_wpos)) begin
            st_d[s].pend = '0;
          end
        end
      end else begin
        for (int unsigned s = 0; s < NR_STREAMS; s++) begin
          if (em_pc[s]) st_d[s].pend = '0;
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
            st_d[train_hit_idx].conf = svt_bm_top_p16342_n22116; // sv-timing: BalanceMux/rebalance #648 RHS rewrite
                // sv-timing: (RHS rewrite continuation removed) ? st_q[train_hit_idx].conf : st_q[train_hit_idx].conf + 2'd1;
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
