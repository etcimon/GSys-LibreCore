// hyp8 provenance: REWRITTEN (rename stage R2 -- dependency resolve)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_rename_resolve -- R2 of the staged rename, the one kernel the
// unbanked design folded into its single-cycle map_d chain
// (analysis/g6lc_rename.md). An R1 map read cannot see:
//   * allocations by OLDER lanes of the same group (the unbanked design
//     saw them through its sequential map_d writes), or
//   * the writes of groups still ahead in the pipe -- a group in R3 has
//     not written map_q/busy_q yet, and the group just published may have
//     landed in the same edge the R1 read sampled.
// Both are covered by records: per lane, the newest matching destination
// wins in the order map-read < prev1 < prev0 < same-group-older-lane,
// which is exactly youngest-to-oldest program order for producers.
// A matched source is not ready: its physical tag is being written by an
// in-flight producer, so the IQ entry waits for its wakeup (the unbanked
// rs*_ready_o = 0 bypass, same meaning one stage later). A bypassed tag
// never changes correctness of the match itself -- it is the same phys tag
// the map would have returned once the producer's publish lands.
//
// prev records are written by the wrapper when a group leaves R1->R2;
// they are cleared on every recovery event (a dead group's registers are
// reclaimed and may be re-picked, so its tags must never satisfy a
// consumer). The hart compare on each record is a staged-form
// strengthening: under the drained handoff all lanes share a hart so it
// is inert, and under mixed residency it is the conservative direction.
//
// r43-T T1(b): RESOLVE_STAGES=2 splits RR into RR-a (the rd compares and
// ia/fa qualifiers, registered as per-lane match vectors) and RR-b (the
// late-select + rs_rdy clear). The register sits inside this module and
// carries three things per lane: the lane payload, the match vectors,
// and the producer tags ({prd,fprd} per producer slot) -- the live
// producer array holds different records at verdict time, so the tags
// travel with the vectors. The rra lane record also serves as the THIRD
// producer slot for the next group: a group two publish-edges ahead of
// the verdict is still unpublished when resolve takes two cycles, so
// the producer order under stages=2 is
//   prev1_i < prev0_i < rra lanes < same-group lanes
// -- the same three-record coverage the 1-stage form had, shifted by
// the added stage. Acceptance stays durable capture: lane_i always
// advances into the register (the downstream s2 stage drains
// unconditionally). Kill masking follows the parent's lane_dies: an rra
// lane dying at this edge neither produces nor presents.

module g6lc_rename_resolve
  import g6lc_ooo_pkg::*;
#(
    parameter int unsigned NR_PORTS = 2,
    parameter int unsigned NR_HARTS = 1,
    // r43-T T1(b): HypCfg.RenameResolveStages 1 = single-cycle resolve;
    // 2 = RR-a register + RR-b late-select.
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8
) (
    input  logic clk_i,
    input  logic rst_ni,
    // Kill view of the resolving/resident lanes (stage-2 register only;
    // stage-1 masking stays at the parent registers as before).
    input  logic kill_all_i,
    input  logic [(NR_HARTS<1?1:NR_HARTS)-1:0] kill_hart_i,
    input  ooo_ren_lane_t [NR_PORTS-1:0] lane_i,
    // Per-lane surviving-v for lane_i at this edge (the parent's r1
    // record keeps stale v bits after the stage drains; only the RR-a
    // register reads this).
    input  logic [NR_PORTS-1:0]        lane_v_i,
    // Previous producer records (prev0 = just ahead). Under stages=2 the
    // pair still names the two publish-edge records ahead of the verdict;
    // the immediate elder comes from the internal register.
    input  ooo_ren_lane_t [NR_PORTS-1:0] prev0_i,
    input  ooo_ren_lane_t [NR_PORTS-1:0] prev1_i,
    output ooo_ren_lane_t [NR_PORTS-1:0] lane_o,
    // stages=2: a resolved group is presented at lane_o this cycle.
    // stages=1: tied 0 (the parent gates the comb path itself).
    output logic vld_o,
    // stages=2: the in-kernel lane records (for the parent's freelist
    // kill accounting -- lanes dying while resident in RR-a/RR-b must
    // return their picks). stages=1: tied '0.
    output ooo_ren_lane_t [NR_PORTS-1:0] rra_o
);
`ifdef G6LC_MUT_T3_RR_SPLIT
  // Review mutant: the single-cycle RR form regardless of config.
  localparam int unsigned NPG   = 3;
`else
  localparam int unsigned NPG   = (HypCfg.RenameResolveStages == 2) ? 4 : 3;
`endif
  localparam int unsigned NH    = (NR_HARTS < 1) ? 1 : NR_HARTS;
  localparam int unsigned HW    = (NH > 1) ? $clog2(NH) : 1;
  localparam int unsigned NPROD = NPG * NR_PORTS;
  localparam int unsigned RMID  = NPROD / 2;
  localparam int unsigned RL    = (NPROD > 1) ? $clog2(NPROD) : 1;

`ifndef SYNTHESIS
  initial begin
    if (!(HypCfg.RenameResolveStages inside {1, 2}))
      $error("g6lc_rename_resolve: HypCfg.RenameResolveStages must be 1 or 2");
  end
`endif

  // lane_dies equivalent for the internal stage-2 producer record: an
  // rra lane dying at this edge must not produce (nor be presented).
  function automatic logic prod_dies(input ooo_ren_lane_t l);
    return l.v && (kill_all_i ||
                   (NR_HARTS > 1 && kill_hart_i[l.hart[HW-1:0]]));
  endfunction

  // hyp8: the serial fold over the producers is replaced by per-field
  // compare vectors and (r43-T T1(a)) a position-ordered late-select,
  // balanced into two half-chains: highest index = youngest = last
  // applied. hi_last + a masked-OR gather survive as the
  // G6LC_MUT_T3_RR_LATESEL review mutant; hi_first is the translate_off
  // reference.
  function automatic logic [NPROD-1:0] hi_last(
      input logic [NPROD-1:0] x);
    logic [NPROD-1:0] a;
    a = x << 1;
    for (int unsigned l = 1; l < NPROD; l = l << 1) a = a | (a << l);
    return x & ~a;
  endfunction

//pragma translate_off
  // The T1(a) equivalence reference one-hot. hi_last (the shipped
  // gather, kept verbatim for the mutant) isolates the LOWEST set bit
  // -- the oldest producer -- while the documented contract is
  // newest-wins in producer-index order (board doc g6lc_rename.md:
  // "priority mux newest-wins"; module header). The check-in gather
  // therefore picked the wrong producer on every multi-hot match: a
  // latent direction bug the T1(a) equivalence fire exposed at L3
  // smoke cycle ~300 (h_old, two live WAW producers). hi_first
  // isolates the HIGHEST set bit -- the intended winner the
  // late-select implements. A wrong-direction shipped pick only
  // corrupts on multi-hot windows (most cheaply on `old`, where a WAW
  // pair in the window double-frees one tag and leaks the youngest),
  // which is how it survived the earlier sims.
  function automatic logic [NPROD-1:0] hi_first(
      input logic [NPROD-1:0] x);
    logic [NPROD-1:0] a;
    a = x >> 1;
    for (int unsigned l = 1; l < NPROD; l = l << 1) a = a | (a >> l);
    return x & ~a;
  endfunction
//pragma translate_on

  // svt-stage: begin RR-a
  // Per-lane RR-a results hoisted to module scope so the stage-2
  // registers (inside gen_r2s) can be written without cross-scope
  // references on the LHS.
  logic [NR_PORTS-1:0]                    res_v;
  logic [NR_PORTS-1:0][6:0][NPROD-1:0]    h_all_w;
  logic [NR_PORTS-1:0][NPROD-1:0][7:0]    pg_prd_w, pg_fprd_w;
  // Stage-2 pipeline registers at module level so the rra lane record
  // can serve as a producer slot for the following group.
  if (NPG == 4) begin : gen_r2s
    ooo_ren_lane_t [NR_PORTS-1:0]          rra_q;
    logic [NR_PORTS-1:0][6:0][NPROD-1:0]   rra_h_q;
    logic [NR_PORTS-1:0][NPROD-1:0][7:0]   rra_prd_q;
    logic [NR_PORTS-1:0][NPROD-1:0][7:0]   rra_fprd_q;
    // svt-pipe: rra -- RR-a registers lane payload + match vectors +
    // producer tags; RR-b selects on the registered copies next cycle.
    // lane_v_i is the parent's kill-masked surviving-v (r1_q keeps stale
    // v bits after the stage drains, so the v bit is re-written, not
    // carried through with the record).
    for (genvar p = 0; p < NR_PORTS; p++) begin : gen_rv
      assign res_v[p] = rra_q[p].v && !prod_dies(rra_q[p]);
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          rra_q[p]     <= '0;
          rra_h_q[p]   <= '0;
          rra_prd_q[p] <= '0;
          rra_fprd_q[p]<= '0;
        end else begin
          rra_q[p]     <= lane_i[p];
          rra_q[p].v   <= lane_v_i[p];
          rra_h_q[p]   <= h_all_w[p];
          rra_prd_q[p] <= pg_prd_w[p];
          rra_fprd_q[p]<= pg_fprd_w[p];
        end
      end
    end
    assign rra_o = rra_q;
  end else begin : gen_r1s
    assign res_v = '0;
    assign rra_o = '{default: '0};
  end
  assign vld_o = |res_v;

  for (genvar p = 0; p < NR_PORTS; p++) begin : gen_lane
    // Ordered producers, oldest first; highest index = youngest.
    // stages=1: prev1 | prev0 | same-group lanes < p.
    // stages=2: prev1 | prev0 | rra lanes | same-group lanes < p -- the
    // rra record is the immediate elder whose publish lands between the
    // R1 read sample and this group's own publish.
    ooo_ren_lane_t prod_g [NPROD];
    for (genvar e = 0; e < NPROD; e++) begin : gen_pg
      if (e < NR_PORTS)
        assign prod_g[e] = prev1_i[e];
      else if (e < 2 * NR_PORTS)
        assign prod_g[e] = prev0_i[e - NR_PORTS];
      else if (NPG == 4 && e < 3 * NR_PORTS) begin : gen_rra_s
        ooo_ren_lane_t rp;
        always_comb begin
          rp = gen_r2s.rra_q[e - 2 * NR_PORTS];
          if (prod_dies(gen_r2s.rra_q[e - 2 * NR_PORTS])) rp.v = 1'b0;
        end
        assign prod_g[e] = rp;
      end
      else if (e - (NPG - 1) * NR_PORTS < p)
        assign prod_g[e] = lane_i[e - (NPG - 1) * NR_PORTS];
      else
        assign prod_g[e] = '0;
    end
    logic [NPROD-1:0] ia, fa;
    logic [NPROD-1:0] h_s1, h_s2, h_old, h_f1, h_f2, h_f3, h_fold;
    for (genvar e = 0; e < NPROD; e++) begin : gen_hv
      assign ia[e] = prod_g[e].v && prod_g[e].do_alloc &&
                     (prod_g[e].hart == lane_i[p].hart);
      assign fa[e] = prod_g[e].v && prod_g[e].do_falloc &&
                     (prod_g[e].hart == lane_i[p].hart);
      // r42-T item 1(c) countercase: a predecoded rd one-hot on the
      // record (indexed reads here) measured WORSE — 49.5 vs 41.6 FO4
      // on analyze-ghz-r4 (a 32-way select per compare is deeper than a
      // 5-bit equality). Reverted under T1 discipline; the compares
      // below stay scalar.
      assign h_s1[e] = ia[e] && !lane_i[p].f_rs1 &&
                       (prod_g[e].rd == lane_i[p].rs1) &&
                       (prod_g[e].rd != 5'd0);
      assign h_s2[e] = ia[e] && !lane_i[p].f_rs2 &&
                       (prod_g[e].rd == lane_i[p].rs2) &&
                       (prod_g[e].rd != 5'd0);
      assign h_old[e] = ia[e] && (prod_g[e].rd == lane_i[p].rd) &&
                        (prod_g[e].rd != 5'd0);
      assign h_f1[e] = fa[e] && lane_i[p].f_rs1 &&
                       (prod_g[e].rd == lane_i[p].rs1);
      assign h_f2[e] = fa[e] && lane_i[p].f_rs2 &&
                       (prod_g[e].rd == lane_i[p].rs2);
      assign h_f3[e] = fa[e] && lane_i[p].f_rs3 &&
                       (prod_g[e].rd == lane_i[p].rs3);
      assign h_fold[e] = fa[e] && lane_i[p].f_rd &&
                         (prod_g[e].rd == lane_i[p].rd);
    end
    logic [6:0][NPROD-1:0] h_all;
    assign h_all = {h_fold, h_f3, h_f2, h_f1, h_old, h_s2, h_s1};
    assign h_all_w[p] = h_all;
    for (genvar e = 0; e < NPROD; e++) begin : gen_pw
      assign pg_prd_w[p][e]  = prod_g[e].prd;
      assign pg_fprd_w[p][e] = prod_g[e].fprd;
    end
  // svt-stage: end RR-a
  // svt-stage: begin RR-b

    // The lane whose fields the select overwrites and the match/tag
    // vectors it resolves against: the live input under stages=1, the
    // registered payload under stages=2.
    ooo_ren_lane_t          lane_v;
    logic [6:0][NPROD-1:0]  h_v;
    logic [NPROD-1:0][7:0]  tag_i, tag_f;
    if (NPG == 4) begin : gen_st2
      assign lane_v = gen_r2s.rra_q[p];
      assign h_v    = gen_r2s.rra_h_q[p];
      for (genvar e = 0; e < NPROD; e++) begin : gen_tq
        assign tag_i[e] = gen_r2s.rra_prd_q[p][e];
        assign tag_f[e] = gen_r2s.rra_fprd_q[p][e];
      end
    end else begin : gen_st1
      assign lane_v = lane_i[p];
      assign h_v    = h_all;
      for (genvar e = 0; e < NPROD; e++) begin : gen_tq
        assign tag_i[e] = prod_g[e].prd;
        assign tag_f[e] = prod_g[e].fprd;
      end
    end

    // RR-b re-mask (stages=2 only): the verdict must respect kills that
    // land between RR-a and RR-b. The in-pipe slots re-read the live
    // valid bits -- prev1_i is the publish-edge record (masked when the
    // group died at its publish edge), prev0_i is s2_eff (masked by the
    // parent's live lane_dies). The published-record and same-group
    // slots keep the 1-stage semantics (record-level masking only).
    logic [NPROD-1:0] prod_ok;
    if (NPG == 4) begin : gen_pok
      for (genvar e = 0; e < NPROD; e++) begin : gen_pok_e
        if (e >= NR_PORTS && e < 2 * NR_PORTS)
          assign prod_ok[e] = prev1_i[e - NR_PORTS].v;
        else if (e >= 2 * NR_PORTS && e < 3 * NR_PORTS)
          assign prod_ok[e] = prev0_i[e - 2 * NR_PORTS].v;
        else
          assign prod_ok[e] = 1'b1;
      end
    end else begin : gen_pok1
      assign prod_ok = '1;
    end
    logic [6:0][NPROD-1:0] h_eff;
    for (genvar f = 0; f < 7; f++) begin : gen_he
      assign h_eff[f] = h_v[f] & prod_ok;
    end

`ifdef G6LC_MUT_T3_RR_LATESEL
    logic [NPROD-1:0] o_s1, o_s2, o_old, o_f1, o_f2, o_f3, o_fold;
    assign o_s1   = hi_last(h_eff[0]);
    assign o_s2   = hi_last(h_eff[1]);
    assign o_old  = hi_last(h_eff[2]);
    assign o_f1   = hi_last(h_eff[3]);
    assign o_f2   = hi_last(h_eff[4]);
    assign o_f3   = hi_last(h_eff[5]);
    assign o_fold = hi_last(h_eff[6]);
    logic [6:0][NPROD-1:0] oh;
    assign oh = {o_fold, o_f3, o_f2, o_f1, o_old, o_s2, o_s1};
`endif
    logic [6:0][7:0] pick;
`ifdef G6LC_MUT_T3_RR_LATESEL
    // Review mutant (r42 form): masked-OR pairwise gather over the
    // hi_last one-hot per field.
    logic [NPROD-1:0][7:0] leaf [7];
    for (genvar f = 0; f < 7; f++) begin : gen_f
      for (genvar e = 0; e < NPROD; e++) begin : gen_leaf
        if (f < 3)
          assign leaf[f][e] = {8{oh[f][e]}} & tag_i[e];
        else
          assign leaf[f][e] = {8{oh[f][e]}} & tag_f[e];
      end
      logic [RL:0][NPROD-1:0][7:0] rt;
      for (genvar e = 0; e < NPROD; e++)
        assign rt[0][e] = leaf[f][e];
      for (genvar l = 0; l < RL; l++) begin : gen_lvl
        localparam int unsigned NW = (NPROD + (1 << l) - 1) >> l;
        localparam int unsigned NX = (NPROD + (1 << (l+1)) - 1) >> (l+1);
        for (genvar t = 0; t < NPROD; t++) begin : gen_t
          if (t < NX) begin : gen_in
            if (2 * t + 1 < NW) begin : gen_pair
              assign rt[l+1][t] = rt[l][2*t] | rt[l][2*t+1];
            end else begin : gen_odd
              assign rt[l+1][t] = rt[l][2*t];
            end
          end else begin : gen_pad
            assign rt[l+1][t] = '0;
          end
        end
      end
      assign pick[f] = rt[RL][0];
    end
`else
    // r43-T T1(a): position-ordered late-select, balanced into two
    // half-chains. Producers are ordered oldest..youngest by index, so
    // the highest set hit wins -- the documented newest-wins contract
    // (the shipped gather selected the lowest; see hi_first). No
    // prefix-OR or OR-tree depth.
    for (genvar f = 0; f < 7; f++) begin : gen_f
      logic [7:0] sel_hi, sel_lo;
      always_comb begin
        // Two half-range chains: the procedural index must bound the
        // chain statically (a runtime e<RMID compare would still chain
        // all NPROD slots serially).
        sel_lo = '0;
        for (int unsigned e = 0; e < RMID; e++)
          if (h_eff[f][e]) sel_lo = (f < 3) ? tag_i[e] : tag_f[e];
        sel_hi = '0;
        for (int unsigned e = RMID; e < NPROD; e++)
          if (h_eff[f][e]) sel_hi = (f < 3) ? tag_i[e] : tag_f[e];
        pick[f] = (|h_eff[f][NPROD-1:RMID]) ? sel_hi : sel_lo;
      end
    end
`endif
    // One struct-literal assignment: sequential field writes on a packed
    // struct variable would read the previous field's result into every
    // later mux (a serial 7-mux chain in the dense-cone model).
    always_comb begin : p_out
      logic v_out;
      v_out = lane_v.v;
      if (NPG == 4 && !res_v[p]) v_out = 1'b0;
      lane_o[p] = '{
        v:         v_out,
        hart:      lane_v.hart,
        rs1:       lane_v.rs1,
        rs2:       lane_v.rs2,
        rs3:       lane_v.rs3,
        rd:        lane_v.rd,
        need_rd:   lane_v.need_rd,
        is_branch: lane_v.is_branch,
        f_rd:      lane_v.f_rd,
        f_rs1:     lane_v.f_rs1,
        f_rs2:     lane_v.f_rs2,
        f_rs3:     lane_v.f_rs3,
        prs1:      (|h_eff[0]) ? pick[0] : lane_v.prs1,
        prs2:      (|h_eff[1]) ? pick[1] : lane_v.prs2,
        old:       (|h_eff[2]) ? pick[2] : lane_v.old,
        fprs1:     (|h_eff[3]) ? pick[3] : lane_v.fprs1,
        fprs2:     (|h_eff[4]) ? pick[4] : lane_v.fprs2,
        fprs3:     (|h_eff[5]) ? pick[5] : lane_v.fprs3,
        fold:      (|h_eff[6]) ? pick[6] : lane_v.fold,
        rs1_rdy:   lane_v.rs1_rdy && ~(|h_eff[0]) && ~(|h_eff[3]),
        rs2_rdy:   lane_v.rs2_rdy && ~(|h_eff[1]) && ~(|h_eff[4]),
        rs3_rdy:   lane_v.rs3_rdy && ~(|h_eff[5]),
        do_alloc:  lane_v.do_alloc,
        do_falloc: lane_v.do_falloc,
        prd:       lane_v.prd,
        fprd:      lane_v.fprd,
        do_ckpt:   lane_v.do_ckpt,
        ckpt_slot: lane_v.ckpt_slot
      };
    end
  // svt-stage: end RR-b
//pragma translate_off
    // r43-T T1(a) equivalence: every field's pick must equal the
    // masked-OR gather of the winning one-hot over the same tag vector.
    // The reference is hi_first (highest producer = newest-wins, the
    // documented contract), not the shipped hi_last gather, which
    // selected the lowest -- see hi_first for the latent direction bug
    // this check's first fire exposed. Under G6LC_MUT_T3_RR_LATESEL the
    // mutant reproduces the shipped (lowest) pick, so a fire on a
    // multi-hot match is the expected mutant signature.
    for (genvar f = 0; f < 7; f++) begin : gen_eqf
      logic [NPROD-1:0] ref_oh;
      logic [7:0] ref_pick;
      assign ref_oh = hi_first(h_eff[f]);
      always_comb begin
        ref_pick = '0;
        for (int unsigned e = 0; e < NPROD; e++)
          if (ref_oh[e])
            ref_pick |= (f < 3) ? tag_i[e] : tag_f[e];
      end
      int unsigned t3_rr_sel_n = 0;
      always_ff @(posedge clk_i) begin
        if (rst_ni) begin
          t3_rr_sel_n <= t3_rr_sel_n + 1;
          g6lc_t3_rr_latesel_eq: assert (pick[f] === ref_pick)
            else $error("g6lc_rename_resolve: equiv latesel lane=%0d field=%0d pick=%h ref=%h",
                        p, f, pick[f], ref_pick);
        end
      end
      final begin
        if ($test$plusargs("equiv_report"))
          $display("[equiv] g6lc_rename_resolve latesel p%0d f%0d: checked=%0d",
                   p, f, t3_rr_sel_n);
      end
    end
    if (NPG == 4) begin : gen_st2_eq
      // r43-T T1(b) equivalence: the registered match vectors must equal
      // the verdict-time producer coverage. At RR-b the live records
      // are prev1_i (two publish-edges ahead), prev0_i (the immediate
      // elder, now resolved in s2 -- its producer fields are unchanged
      // by resolution) and the rra lanes' own same-group elders; the
      // third record is the prev1_i that RR-a sampled, kept in a shadow
      // register. A producer-timing miss shows as ref_h != rra_h_q.
      ooo_ren_lane_t prev2_sh [NR_PORTS];
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          prev2_sh <= '{default: '0};
        end else begin
          for (int unsigned e = 0; e < NR_PORTS; e++)
            prev2_sh[e] <= prev1_i[e];
        end
      end
      logic [6:0][NPROD-1:0] ref_h;
      always_comb begin
        ooo_ren_lane_t rp [NPROD];
        for (int unsigned e = 0; e < NPROD; e++) begin
          if (e < NR_PORTS)              rp[e] = prev2_sh[e];
          else if (e < 2 * NR_PORTS)     rp[e] = prev1_i[e - NR_PORTS];
          else if (e < 3 * NR_PORTS)     rp[e] = prev0_i[e - 2 * NR_PORTS];
          else if (e - 3 * NR_PORTS < p) rp[e] = gen_r2s.rra_q[e - 3 * NR_PORTS];
          else                           rp[e] = '0;
        end
        for (int unsigned e = 0; e < NPROD; e++) begin
          ref_h[0][e] = rp[e].v && rp[e].do_alloc &&
                        (rp[e].hart == gen_r2s.rra_q[p].hart) &&
                        !gen_r2s.rra_q[p].f_rs1 &&
                        (rp[e].rd == gen_r2s.rra_q[p].rs1) &&
                        (rp[e].rd != 5'd0);
          ref_h[1][e] = rp[e].v && rp[e].do_alloc &&
                        (rp[e].hart == gen_r2s.rra_q[p].hart) &&
                        !gen_r2s.rra_q[p].f_rs2 &&
                        (rp[e].rd == gen_r2s.rra_q[p].rs2) &&
                        (rp[e].rd != 5'd0);
          ref_h[2][e] = rp[e].v && rp[e].do_alloc &&
                        (rp[e].hart == gen_r2s.rra_q[p].hart) &&
                        (rp[e].rd == gen_r2s.rra_q[p].rd) &&
                        (rp[e].rd != 5'd0);
          ref_h[3][e] = rp[e].v && rp[e].do_falloc &&
                        (rp[e].hart == gen_r2s.rra_q[p].hart) &&
                        gen_r2s.rra_q[p].f_rs1 &&
                        (rp[e].rd == gen_r2s.rra_q[p].rs1);
          ref_h[4][e] = rp[e].v && rp[e].do_falloc &&
                        (rp[e].hart == gen_r2s.rra_q[p].hart) &&
                        gen_r2s.rra_q[p].f_rs2 &&
                        (rp[e].rd == gen_r2s.rra_q[p].rs2);
          ref_h[5][e] = rp[e].v && rp[e].do_falloc &&
                        (rp[e].hart == gen_r2s.rra_q[p].hart) &&
                        gen_r2s.rra_q[p].f_rs3 &&
                        (rp[e].rd == gen_r2s.rra_q[p].rs3);
          ref_h[6][e] = rp[e].v && rp[e].do_falloc &&
                        (rp[e].hart == gen_r2s.rra_q[p].hart) &&
                        gen_r2s.rra_q[p].f_rd &&
                        (rp[e].rd == gen_r2s.rra_q[p].rd);
        end
      end
      int unsigned t3_rr_cov_n = 0;
      always_ff @(posedge clk_i) begin
        if (rst_ni) begin
          t3_rr_cov_n <= t3_rr_cov_n + 1;
          if (gen_r2s.rra_q[p].v) begin
            g6lc_t3_rr_cover_eq: assert (h_eff === ref_h)
              else $error("g6lc_rename_resolve: producer coverage lane=%0d h=%h ref=%h",
                          p, gen_r2s.rra_h_q[p], ref_h);
          end
        end
      end
      final begin
        if ($test$plusargs("equiv_report"))
          $display("[equiv] g6lc_rename_resolve cover p%0d: checked=%0d",
                   p, t3_rr_cov_n);
      end
    end
//pragma translate_on
  end

  // svt-stage: class RR decision

endmodule
