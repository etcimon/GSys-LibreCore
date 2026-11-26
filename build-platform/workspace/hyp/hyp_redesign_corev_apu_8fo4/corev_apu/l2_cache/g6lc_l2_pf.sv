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
// Streams are keyed on the 4 KiB page of the miss line (region tag): an armed
// burst can never propose a candidate outside its own page, so the page bound
// is structural, not a check. A confirmed stride-1 stream may carry its
// confidence into the physically adjacent next page only after demand first
// misses there; the first cross-page line is never speculated. Next-line is
// stride=1 through the same path; a stride other than 1 is only armed when
// STRIDE_EN and confirmed by two consecutive equal deltas (the stored stride
// is the previous delta, so the first equal pair both confirms and triggers).
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
    // Demand-miss commit component of train_i. Hit-based retraining advances
    // the stream but must not reload the demand-miss quiet window.
    input  logic                        train_miss_i,
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
    logic [PAGETAG_W-1:0]      page;         // region tag = 4 KiB page number
    logic [LINE_BITS-1:0]      last;         // last trained line index
    logic signed [DLT_W-1:0]   stride;       // previous within-page delta
    logic                      seen;         // a first delta has been recorded
    logic [1:0]                conf;         // confirmed-delta count (saturates 3)
    logic [PW-1:0]             pend;         // armed candidates not yet emitted
    logic [PW-1:0]             ahead;        // next pend offset (1..PF_DISTANCE)
    // A136 registered derived candidate: offset within the 4 KiB page and its
    // in-page predicate, maintained incrementally on arm (ahead=1) and emit
    // (ahead+=1). Since every emitted candidate is guaranteed in-page, the full
    // candidate line is `{page, cand_off}` with zero emit-path multiply or
    // 58-bit addition.
    logic [PAGE_LBITS-1:0]     cand_off;
    logic                      cand_in_page;
  } stream_t;

  stream_t [NR_STREAMS-1:0] st_q, st_d;
  logic [SW-1:0]             rr_q, rr_d;
  // Demand-miss quiet window: train_miss_i reloads the countdown, and while it
  // is non-zero no candidate is offered (pend keeps its arming).
  logic [QW-1:0]             quiet_q, quiet_d;
  // Emit cursor: which stream is currently holding a pending candidate.
  // cand_valid_o is registered with the line so the output is a stable
  // offer, not a combinational walk of the table.
  logic                      cnd_vld_q, cnd_vld_d;
  logic [LINE_BITS-1:0]      cnd_line_q, cnd_line_d;

  // Parallel emit-evaluation scratch — per-stream constant-index results
  // (emit-ok / page-clear / next-offset / rr-position) plus winner one-hot.
  logic [NR_STREAMS-1:0]     em_ok, em_pc, em_win, em_blk;
  logic [SW-1:0]             em_ps [NR_STREAMS];
  logic [PAGE_LBITS-1:0]     em_next_off [NR_STREAMS];
  logic [NR_STREAMS-1:0]     em_next_in_page;
  logic [SW-1:0]             em_wpos;
  logic                       em_any;
  logic                      emit_en;
  logic                      cnd_vld_after_take;
  logic [NR_STREAMS-1:0]     train_match;
  logic [NR_STREAMS-1:0]     train_same;
  logic [NR_STREAMS-1:0]     train_xcont;
  logic [NR_STREAMS-1:0]     train_xcont_sel;
  logic [NR_STREAMS-1:0]     alloc_oh;

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
  always_comb begin : p_train_match
    logic xsel_seen;
    xsel_seen = 1'b0;
    for (int unsigned s = 0; s < NR_STREAMS; s++) begin
      logic [DLT_W-1:0] xgap_s;
      // Exact adjacent-page line gap for stride 1: lines remaining in the
      // predecessor page plus the line offset in the successor page. This is
      // only PAGE_LBITS+1 bits wide, unlike a full physical-line subtract.
      xgap_s = DLT_W'(1 << PAGE_LBITS) -
               DLT_W'(st_q[s].last[PAGE_LBITS-1:0]) +
               DLT_W'(train_line[PAGE_LBITS-1:0]);
`ifdef G6LC_MUT_PF_NO_XPAGE_CONTINUE
      train_xcont[s] = 1'b0;
`else
      // Confirmed stride-1 continuation into the physically adjacent page.
      // Demand hits do not retrain `last`, so accept a small positive line
      // gap rather than only last+1; the first line in the new page remains
      // a demand miss and no candidate is emitted speculatively across the
      // boundary.
      train_xcont[s] = st_q[s].valid && (st_q[s].conf >= 2'd2) &&
                       (st_q[s].stride == DLT_W'(1)) &&
                       (page_of(train_line) == (st_q[s].page + PAGETAG_W'(1))) &&
                       (xgap_s <= DLT_W'(PF_DISTANCE) + DLT_W'(4));
`endif
      train_same[s] = st_q[s].valid && (st_q[s].page == page_of(train_line));
    end
    // Same-page residency takes priority. Cross-page continuation is a
    // single-owner transfer: without this priority select, two adjacent-page
    // stride-1 streams could both be retrained onto one successor page.
    train_xcont_sel = '0;
    for (int unsigned s = 0; s < NR_STREAMS; s++) begin
      if (train_xcont[s] && !xsel_seen) begin
        train_xcont_sel[s] = 1'b1;
        xsel_seen = 1'b1;
      end
    end
    train_match = (train_same != '0) ? train_same : train_xcont_sel;
    train_hit = |train_match;
  end

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
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

  assign quiet_d            = train_miss_i ? QW'(QUIET) : svt_bm_top_p6263_n22101;
  assign cnd_vld_after_take = cnd_vld_q && !cand_take_i;
  assign emit_en            = !cnd_vld_after_take && (quiet_d == '0);

  // Unconditional flop-only precompute (A136/A118): next candidate offset,
  // rr-order positions, and allocation victim one-hot depend only on st_q/rr_q.
  logic [NR_STREAMS-1:0] inv_v_s, first_inv_s;
  logic                  any_inv_s;
  for (genvar gs = 0; gs < NR_STREAMS; gs++) begin : gen_alloc_oh
    assign inv_v_s[gs] = !st_q[gs].valid;
    if (gs == 0) begin : gen_s0
      assign first_inv_s[0] = inv_v_s[0];
    end else begin : gen_sn
      assign first_inv_s[gs] = inv_v_s[gs] && !(|inv_v_s[gs-1:0]);
    end
    assign alloc_oh[gs] = any_inv_s ? first_inv_s[gs] : (rr_q == SW'(gs));
  end
  assign any_inv_s = |inv_v_s;

  always_comb begin : p_emit_prep
    for (int unsigned s = 0; s < NR_STREAMS; s++) begin
      logic signed [DLT_W:0] next_xs;
      next_xs = $signed({{(DLT_W+1-PAGE_LBITS){1'b0}}, st_q[s].cand_off}) +
                $signed(st_q[s].stride);
      em_next_off[s]     = next_xs[PAGE_LBITS-1:0];
      em_next_in_page[s] = !(|next_xs[DLT_W:PAGE_LBITS]);
      em_ps[s] = SW'( (int'(s) >= int'(rr_q))
                      ? (int'(s) - int'(rr_q))
                      : (int'(s) - int'(rr_q) + NR_STREAMS) );
    end
  end

  // Parallel emit eligibility + RR-position winner selection (zero arithmetic).
  always_comb begin : p_emit_pick
    em_ok   = '0;
    em_pc   = '0;
    em_blk  = '0;
    em_win  = '0;
    em_any  = 1'b0;
    em_wpos = '0;
    for (int unsigned s = 0; s < NR_STREAMS; s++) begin
      logic retrain_s, armed_s;
      retrain_s = train_i && train_match[s];
      armed_s   = st_q[s].valid && (st_q[s].pend != '0) && !retrain_s;
      em_ok[s]  = emit_en && armed_s && st_q[s].cand_in_page;
      em_pc[s]  = emit_en && armed_s && !st_q[s].cand_in_page;
    end
    for (int unsigned s = 0; s < NR_STREAMS; s++) begin
      for (int unsigned t = 0; t < NR_STREAMS; t++) begin
        if (em_ok[t] && (em_ps[t] < em_ps[s])) em_blk[s] = 1'b1;
      end
      em_win[s] = em_ok[s] && !em_blk[s];
      if (em_win[s]) begin
        em_any  = 1'b1;
        em_wpos = em_ps[s];
      end
    end
  end

  // Unconditional per-stream train arithmetic (A118/A146): decouple delta,
  // stride, and arm candidate calculation from the nested if-guards.
  logic signed [DLT_W-1:0] tr_d_s [NR_STREAMS];
  logic signed [DLT_W-1:0] tr_str_s [NR_STREAMS];
  logic [PAGE_LBITS-1:0]   tr_arm_off_s [NR_STREAMS];
  logic [NR_STREAMS-1:0]   tr_arm_ip_s;
  logic [PAGE_LBITS-1:0]   tr_front_off_s [NR_STREAMS];
  logic [NR_STREAMS-1:0]   tr_front_ip_s;
  logic [NR_STREAMS-1:0]   tr_confirm_s;
  logic [1:0]              tr_conf_inc_s [NR_STREAMS];
  always_comb begin : p_train_prep
    for (int unsigned s = 0; s < NR_STREAMS; s++) begin
      logic signed [DLT_W-1:0] d_s, str_s;
      logic signed [DLT_W:0]   axs;
      logic signed [EM_W-1:0]  fxs;
      d_s             = delta_of(train_line, st_q[s].last);
      str_s           = train_xcont[s] ? st_q[s].stride : (STRIDE_EN ? d_s : DLT_W'(1));
      axs             = $signed({{(DLT_W+1-PAGE_LBITS){1'b0}}, train_line[PAGE_LBITS-1:0]}) +
                        $signed(str_s);
      fxs             = $signed({{(EM_W-PAGE_LBITS){1'b0}}, train_line[PAGE_LBITS-1:0]}) +
                        ($signed({{(EM_W-DLT_W){str_s[DLT_W-1]}}, str_s}) * $signed(EM_W'(PEND_CAP)));
      tr_d_s[s]       = d_s;
      tr_str_s[s]     = str_s;
      tr_arm_off_s[s] = axs[PAGE_LBITS-1:0];
      tr_arm_ip_s[s]  = !(|axs[DLT_W:PAGE_LBITS]);
      tr_front_off_s[s]= fxs[PAGE_LBITS-1:0];
      tr_front_ip_s[s] = !(|fxs[EM_W-1:PAGE_LBITS]);
      tr_confirm_s[s] = train_xcont[s] ||
                        (st_q[s].seen && (d_s == st_q[s].stride));
      tr_conf_inc_s[s]= (st_q[s].conf == 2'd3) ? 2'd3 : (st_q[s].conf + 2'd1);
    end
  end

  // Per-stream constant-index state updates (A135 row-local, zero dynamic
  // st_d[...] indexing on either emit or train).
  always_comb begin : p_state_upd
    st_d       = st_q;
    rr_d       = rr_q;
    cnd_vld_d  = cnd_vld_after_take;
    cnd_line_d = cnd_line_q;

    if (em_any) begin
      cnd_vld_d = 1'b1;
      for (int unsigned s = 0; s < NR_STREAMS; s++) begin
        if (em_win[s]) begin
          cnd_line_d           = {st_q[s].page, st_q[s].cand_off};
          st_d[s].pend         = st_q[s].pend - 1'b1;
          st_d[s].ahead        = st_q[s].ahead + 1'b1;
          st_d[s].cand_off     = em_next_off[s];
          st_d[s].cand_in_page = em_next_in_page[s];
          rr_d                 = SW'((int'(s) + 1) % NR_STREAMS);
        end else if (em_pc[s] && (em_ps[s] < em_wpos)) begin
          st_d[s].pend = '0;
        end
      end
    end else begin
      for (int unsigned s = 0; s < NR_STREAMS; s++) begin
        if (em_pc[s]) st_d[s].pend = '0;
      end
    end

    // ---- train on a demand miss commit ----
    for (int unsigned s = 0; s < NR_STREAMS; s++) begin
      if (train_i && train_match[s]) begin
        st_d[s].last = train_line;
        if (train_xcont[s]) st_d[s].page = page_of(train_line);
        if (tr_d_s[s] != '0) begin
          st_d[s].stride = tr_str_s[s];
          if (tr_confirm_s[s]) begin
            st_d[s].conf = tr_conf_inc_s[s];
            if (st_q[s].conf >= 2'd1) begin
`ifdef G6LC_MUT_PF_REDUNDANT_REARM
              st_d[s].pend         = PW'(PEND_CAP);
              st_d[s].ahead        = PW'(1);
              st_d[s].cand_off     = tr_arm_off_s[s];
              st_d[s].cand_in_page = tr_arm_ip_s[s];
`else
              // On steady-state advance (already conf>=2 and prior burst drained),
              // arm only the single new frontier line at +PEND_CAP*stride so we do
              // not re-emit already-issued candidates +1..+(PEND_CAP-1).
              if ((st_q[s].conf >= 2'd2) && (st_q[s].pend == '0) && (PEND_CAP > 1)) begin
                st_d[s].pend         = PW'(1);
                st_d[s].ahead        = PW'(PEND_CAP);
                st_d[s].cand_off     = tr_front_off_s[s];
                st_d[s].cand_in_page = tr_front_ip_s[s];
              end else begin
                st_d[s].pend         = PW'(PEND_CAP);
                st_d[s].ahead        = PW'(1);
                st_d[s].cand_off     = tr_arm_off_s[s];
                st_d[s].cand_in_page = tr_arm_ip_s[s];
              end
`endif
            end
          end else begin
            st_d[s].seen         = 1'b1;
            st_d[s].conf         = '0;
            st_d[s].pend         = '0;
            st_d[s].cand_off     = '0;
            st_d[s].cand_in_page = 1'b0;
          end
        end
      end else if (train_i && !train_hit && alloc_oh[s]) begin
        st_d[s].valid        = 1'b1;
        st_d[s].page         = page_of(train_line);
        st_d[s].last         = train_line;
        st_d[s].stride       = '0;
        st_d[s].seen         = 1'b0;
        st_d[s].conf         = '0;
        st_d[s].pend         = '0;
        st_d[s].ahead        = '0;
        st_d[s].cand_off     = '0;
        st_d[s].cand_in_page = 1'b0;
        rr_d                 = SW'((int'(s) + 1) % NR_STREAMS);
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
