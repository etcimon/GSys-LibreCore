// hyp8 provenance: REWRITTEN (sv-timing emit base, g6lc_lsq__svt.sv)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// SPDX-FileCopyrightText: machine-generated
//
// g6lc_lsq_reduce — hyp8 LSQ banked-candidate reduction (stage R).
//
// Consumes the registered bank outputs (match & older candidates plus a
// small number of extra leaves the wrapper appends — see g6lc_lsq.sv)
// and reduces them, one stage, registered:
//
//   DIR=0 (store-to-load direction): youngest older store whose lanes
//     fully cover the load's bytes — the A119 stable youngest-store
//     tournament (max circular age distance wins; lowest index breaks
//     ties, preserving the emit's scan order).  `wait_o` reports an
//     older unresolved store or a matched older store whose data has
//     not landed — the STL "stall" verdict source.  `dwait_ids_o` is
//     the tid mask of matched-older stores lacking data, consumed by
//     g6lc_lsq_release's per-load data-wait mask.
//   DIR=1 (violation direction): oldest younger load the resolving
//     store aliases — the A119 stable oldest-violation tournament
//     (min age distance wins; lowest index breaks ties).  `win_*`
//     carries the violating load's slot id and PC.
//
// Kill identities: the candidate set is already dead-event-free (the
// CAM/age stages gate on cancelled_mask_i); the stage registers are
// cleared by flush_i.

module g6lc_lsq_reduce #(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8,
    parameter int unsigned NLEAF = 8,
    parameter int unsigned PAYW  = 8,
    parameter bit DIR = 1'b0,
    // TRACK_WAIT=0 (violation-direction callers): wait_o/dwait_ids_o are
    // defined-zero and the nodata/unres wait decode is not built.
    parameter bit TRACK_WAIT = 1'b1
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,

    // Registered stage-C leaf vectors (banks' match/unres/nodata, ages).
    input  logic [NLEAF-1:0]                                match_i,
    input  logic [NLEAF-1:0]                                unres_i,
    input  logic [NLEAF-1:0]                                nodata_i,
    input  logic [NLEAF-1:0]                                older_i,
    // r53-B6: pairwise leaf age matrix, "row older than column",
    // snapshotted by the parent at the same C-stage edge as *_eid_q.
    input  logic [NLEAF-1:0][NLEAF-1:0]                     age_i,
    input  logic [NLEAF-1:0][G6LCCfg.TRANS_ID_BITS-1:0]     dist_i,
    input  logic [NLEAF-1:0][G6LCCfg.TRANS_ID_BITS-1:0]     ent_id_i,
    input  logic [NLEAF-1:0][PAYW-1:0]                      ent_pay_i,

    output logic                                          win_valid_o,
    output logic [NLEAF-1:0]                              win_leaf_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0]              win_id_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0]              win_dist_o,
    output logic [PAYW-1:0]                               win_pay_o,
    output logic                                          wait_o,
    output logic [G6LCCfg.NR_SB_ENTRIES-1:0]              dwait_ids_o
);
  // svt-stage: begin R1

  localparam int unsigned LEAVES = 1 << $clog2(NLEAF);
  localparam int unsigned IDW = G6LCCfg.TRANS_ID_BITS;
  localparam int unsigned LG = $clog2(LEAVES);
  // r43-T T3: HypCfg.LsqReduceStages splits R into R1 (lower tournament
  // levels + candidate terms, registered at the mid-tree frontier — the
  // leaf inputs may change next cycle, so the gather's sources travel
  // with the pick as the leaf id/pay arrays) and R2 (upper levels, the
  // one-hot leaf decode, the id/pay gathers, publish). +1 cycle R->V;
  // the wrapper's ctx pipeline extends one stage to keep event/verdict
  // pairing exact. SL = lower-tree levels inside R1; the frontier nodes
  // are FBASE .. 2*FBASE-1.
  localparam int unsigned SL = (LG > 1) ? (LG + 1) / 2 : LG;
  localparam int unsigned FBASE = LEAVES >> SL;
  localparam int unsigned NFR = FBASE;
  // Slot/within-group index width: LEAVES==1 gives LG==0, so every slot
  // wire/cast uses SW (one bit) — the degenerate singleton still
  // elaborates the same number of stages as the real trees.
  localparam int unsigned SW = (LG > 0) ? LG : 1;
  // Upper-tree node range [UP_LAST:1]: FBASE==1 leaves the tree empty —
  // the frontier IS the root — so the range is degenerate [1:1] and the
  // nodes are tied (root selects fr_*/pick_* directly below).
  localparam int unsigned UP_LAST = (FBASE > 1) ? (FBASE - 1) : 1;
`ifdef G6LC_MUT_T3_LSQ_R2
  // Review mutant: single-stage publish, the pre-r43 form.
  localparam bit RSTG = 1'b0;
`else
  // r44: stage count is a property of the config, not the tree — the
  // wrapper's ctx pipeline extends whenever LsqReduceStages==2, so R1/R2
  // must exist even when the tournament is degenerate (FBASE==1).
  localparam bit RSTG = (HypCfg.LsqReduceStages >= 2);
`endif

  logic [NLEAF-1:0] cand;      // match && older
  logic [NLEAF-1:0] cand_nd;   // match && older && !data
  logic [NLEAF-1:0] cand_ur;   // unresolved && older
  logic wait_d;
  logic [G6LCCfg.NR_SB_ENTRIES-1:0] dwait_d;

  assign cand = match_i & older_i;
  if (TRACK_WAIT) begin : gen_wait
    assign cand_nd = match_i & older_i & nodata_i;
    assign cand_ur = unres_i & older_i;
    assign wait_d  = |cand_ur | |cand_nd;
    // Row-local data-wait decode: tid t waits when a matched older
    // dataless store holds it — the flat form of the former
    // dynamic-index write dwait_d[ent_id_i[j]] = 1.
    for (genvar t = 0; t < G6LCCfg.NR_SB_ENTRIES; t++) begin : gen_dwait_row
      logic [NLEAF-1:0] hit;
      for (genvar j = 0; j < NLEAF; j++) begin : gen_dwait_hit
        assign hit[j] = cand_nd[j] && (ent_id_i[j] == IDW'(t));
      end
      assign dwait_d[t] = |hit;
    end
  end else begin : gen_no_wait
    assign cand_nd = '0;
    assign cand_ur = '0;
    assign wait_d  = 1'b0;
    assign dwait_d = '0;
  end

  // r53-B6: pairwise age matrix replaces the distance tournament.
  // age_i[r][c] = "leaf r is older than leaf c", computed by the
  // parent with ooo_age_older over the same leaf ids the C-stage edge
  // snapshots into *_eid_q — vv_* virtual leaves need no special
  // rows (they have ids). Relative order of two live ids is
  // pivot-invariant: commit_ptr_i can only retire entries and a
  // retired leaf is dead in cand, so the snapshot stays valid into
  // the reduce stage.
  // DIR=0 (youngest older store): leaf i wins when no candidate is
  // younger than i — row i (age_i[i][j] = i older than j = j younger).
  // DIR=1 (oldest): no candidate older than i — column i. Equal ids
  // give both directions false, so the only multi-hot is a
  // resident/virtual equal-id tie; the lowest concatenated index
  // wins, matching the old strict-compare left-keep (vv sits high,
  // resident low — resident wins the tie, as before).
  logic [NLEAF-1:0]                win_mask;
  logic [NLEAF-1:0][NLEAF-1:0]     age_col;
  for (genvar i = 0; i < NLEAF; i++) begin : gen_age_pick
    for (genvar j = 0; j < NLEAF; j++)
      assign age_col[i][j] = age_i[j][i];
`ifdef G6LC_MUT_LSQ_AGE_DIR
    assign win_mask[i] = cand[i] & ~|(cand & (DIR ? age_i[i] : age_col[i]));
`else
    assign win_mask[i] = cand[i] & ~|(cand & (DIR ? age_col[i] : age_i[i]));
`endif
  end

  // R1 capture registers (module scope: the R2 publish reads them).
  logic [NLEAF-1:0]                r1_mask;
  logic [NLEAF-1:0][IDW-1:0]       r1_dist;
  logic                            r1_wait;
  logic [G6LCCfg.NR_SB_ENTRIES-1:0] r1_dwait;
  logic [NLEAF-1:0][IDW-1:0]       r1_id;
  logic [NLEAF-1:0][PAYW-1:0]      r1_pay;
  if (RSTG) begin : gen_r1regs
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        r1_mask  <= '0;
        r1_dist  <= '0;
        r1_wait  <= 1'b0;
        r1_dwait <= '0;
        r1_id    <= '0;
        r1_pay   <= '0;
      end else if (flush_i) begin
        r1_mask  <= '0;
        r1_dist  <= '0;
        r1_wait  <= 1'b0;
        r1_dwait <= '0;
        r1_id    <= '0;
        r1_pay   <= '0;
      end else begin
        r1_mask  <= win_mask;
        r1_dist  <= dist_i;
        r1_id    <= ent_id_i;
        r1_pay   <= ent_pay_i;
        r1_wait  <= wait_d;
        r1_dwait <= dwait_d;
      end
    end
  end
  // svt-stage: end R1
  // svt-stage: begin R2

  // Publish select: the R1 snapshot under the 2-stage form, the live
  // pick under the 1-stage form — the select folds under RSTG.
  logic [NLEAF-1:0]                sel_mask;
  logic [NLEAF-1:0][IDW-1:0]       sel_id, sel_dist;
  logic [NLEAF-1:0][PAYW-1:0]      sel_pay;
  logic                            sel_wait;
  logic [G6LCCfg.NR_SB_ENTRIES-1:0] sel_dwait;
  if (RSTG) begin : gen_r2_sel
    assign sel_mask  = r1_mask;
    assign sel_id    = r1_id;
    assign sel_dist  = r1_dist;
    assign sel_pay   = r1_pay;
    assign sel_wait  = r1_wait;
    assign sel_dwait = r1_dwait;
  end else begin : gen_r1_sel
    assign sel_mask  = win_mask;
    assign sel_id    = ent_id_i;
    assign sel_dist  = dist_i;
    assign sel_pay   = ent_pay_i;
    assign sel_wait  = wait_d;
    assign sel_dwait = dwait_d;
  end

  // Lowest-index one-hot of the selected mask (resident/virtual
  // equal-id tie resolved lowest-first — the strict left-keep).
  // Two's-complement isolate: mask & (-mask) keeps the lowest set bit
  // with no serial prefix chain.
  logic [NLEAF-1:0] sel_oh;
  assign sel_oh = sel_mask & (~sel_mask + NLEAF'(1));

  // One-hot id/dist/pay gathers by the winning mask.
  logic [IDW-1:0]  sel_id_g, sel_dist_g;
  logic [PAYW-1:0] sel_pay_g;
  always_comb begin
    sel_id_g   = '0;
    sel_dist_g = '0;
    sel_pay_g  = '0;
    for (int unsigned i = 0; i < NLEAF; i++)
      if (sel_oh[i]) begin
        sel_id_g   |= sel_id[i];
        sel_dist_g |= sel_dist[i];
        sel_pay_g  |= sel_pay[i];
      end
  end

  // Publish registers — leaf one-hot + gathered record. Identical
  // shape under both stage counts; only the select differs.
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_publish
    if (!rst_ni) begin
      win_valid_o <= 1'b0;
      win_leaf_o  <= '0;
      win_id_o    <= '0;
      win_dist_o  <= '0;
      win_pay_o   <= '0;
      wait_o      <= 1'b0;
      dwait_ids_o <= '0;
    end else if (flush_i) begin
      win_valid_o <= 1'b0;
      win_leaf_o  <= '0;
      win_id_o    <= '0;
      win_dist_o  <= '0;
      win_pay_o   <= '0;
      wait_o      <= 1'b0;
      dwait_ids_o <= '0;
    end else begin
      win_valid_o <= |sel_mask;
      win_leaf_o  <= sel_oh;
      if (|sel_mask) begin
        win_id_o   <= sel_id_g;
        win_dist_o <= sel_dist_g;
        win_pay_o  <= sel_pay_g;
      end
      wait_o      <= sel_wait;
      dwait_ids_o <= sel_dwait;
    end
  end
  // svt-stage: end R2

//pragma translate_off
  // r44 dwait row-decoder equivalence: the per-tid row OR must equal the
  // original dynamic-index scan (dwait_d[ent_id_i[j]] = 1 for cand_nd
  // leaves). Under TRACK_WAIT=0 both forms are defined '0.
  logic [G6LCCfg.NR_SB_ENTRIES-1:0] ref_dwait_scan;
  always_comb begin
    ref_dwait_scan = '0;
    for (int unsigned j = 0; j < NLEAF; j++)
      if (cand_nd[j]) ref_dwait_scan[ent_id_i[j]] = 1'b1;
  end
  int unsigned t4_dwait_n = 0;
  always_ff @(posedge clk_i) begin
    if (rst_ni && !flush_i) begin
      t4_dwait_n <= t4_dwait_n + 1;
      g6lc_t4_dwait_eq: assert (dwait_d === ref_dwait_scan)
        else $error("g6lc_lsq_reduce: dwait row decoder diverged (%h != %h)",
                    dwait_d, ref_dwait_scan);
    end
  end
  final begin
    if ($test$plusargs("equiv_report"))
      $display("[equiv] g6lc_lsq_reduce dwait: checked=%0d", t4_dwait_n);
  end

  // r53-B6 reference: the pre-B6 distance tournament, kept verbatim
  // under translate_off as the oracle for g6lc_lsq_red_age_miter and
  // the staged lsqr2 output check.
  logic [2*LEAVES-1:1]                 ref_valid;
  logic [2*LEAVES-1:1][IDW-1:0]        ref_dist;
  logic [2*LEAVES-1:1][SW-1:0]         ref_slot;
  for (genvar i = 0; i < LEAVES; i++) begin : gen_ref_leaf
    if (i < NLEAF) begin : ge
      assign ref_valid[LEAVES+i] = cand[i];
      assign ref_dist[LEAVES+i]  = dist_i[i];
      assign ref_slot[LEAVES+i]  = SW'(i);
    end else begin : gp
      assign ref_valid[LEAVES+i] = 1'b0;
      assign ref_dist[LEAVES+i]  = '1;
      assign ref_slot[LEAVES+i]  = '0;
    end
  end
  for (genvar n = 1; n < LEAVES; n++) begin : gen_ref_pick
    logic tr;
    if (DIR) begin
      assign tr = ref_valid[2*n+1] &&
                  (!ref_valid[2*n] || ref_dist[2*n+1] < ref_dist[2*n]);
    end else begin
      assign tr = ref_valid[2*n+1] &&
                  (!ref_valid[2*n] || ref_dist[2*n+1] > ref_dist[2*n]);
    end
    assign ref_valid[n] = ref_valid[2*n] | ref_valid[2*n+1];
    assign ref_dist[n]  = tr ? ref_dist[2*n+1] : ref_dist[2*n];
    assign ref_slot[n]  = tr ? ref_slot[2*n+1] : ref_slot[2*n];
  end

  // r53-B6 miter: the age-matrix pick must agree with the verbatim
  // distance tournament (ref_* above) at the pick point — comb compare
  // every cycle; the registered outputs inherit the check.
  logic [SW-1:0] w_oh_s;
  logic [IDW-1:0] w_oh_d;
  always_comb begin
    // Lowest-index bit of win_mask — the functional sel_oh lives one
    // stage later; the reference picks at the comb win_mask point.
    logic seen;
    seen = 1'b0;
    w_oh_s = '0;
    w_oh_d = '0;
    for (int unsigned i = 0; i < NLEAF; i++)
      if (win_mask[i] && !seen) begin
        seen   = 1'b1;
        w_oh_s = SW'(i);
        w_oh_d = dist_i[i];
      end
  end
  int unsigned r53_age_n = 0;
  always_ff @(posedge clk_i) begin
    if (rst_ni && !flush_i) begin
      r53_age_n <= r53_age_n + 1;
      g6lc_lsq_red_age_miter: assert (
          (|win_mask) === ref_valid[1] &&
          (!ref_valid[1] ||
           (w_oh_s === ref_slot[1] && w_oh_d === ref_dist[1][IDW-1:0])))
        else $error("g6lc_lsq_reduce: age-matrix pick diverged mask=%b oh_s=%0d/%0d d=%h/%h",
                    win_mask, w_oh_s, ref_slot[1], w_oh_d, ref_dist[1]);
    end
  end
  final begin
    if ($test$plusargs("equiv_report"))
      $display("[equiv] g6lc_lsq_reduce age_miter: checked=%0d", r53_age_n);
  end

  // r43-T T3 equivalence (2-stage form): the original single-stage
  // publish is replayed as a reference pipeline; its output is compared
  // against the R2 outputs one edge later (the stage the split adds).
  // Plus the structural checks: win_leaf_o is $onehot0 and equals the
  // decode of the registered R1 slot.
  if (RSTG) begin : gen_lsq_r2_eq
    logic                            ref_v;
    logic [NLEAF-1:0]                ref_leaf;
    logic [IDW-1:0]                  ref_id, ref_d;
    logic [PAYW-1:0]                 ref_pay;
    logic                            ref_wait;
    logic [G6LCCfg.NR_SB_ENTRIES-1:0] ref_dwait;
    logic                            ref2_v;
    logic [NLEAF-1:0]                ref2_leaf;
    logic [IDW-1:0]                  ref2_id, ref2_d;
    logic [PAYW-1:0]                 ref2_pay;
    logic                            ref2_wait;
    logic [G6LCCfg.NR_SB_ENTRIES-1:0] ref2_dwait;
    int unsigned t3_lsqr2_n = 0;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        ref_v <= 1'b0; ref_leaf <= '0; ref_id <= '0; ref_d <= '0;
        ref_pay <= '0; ref_wait <= 1'b0; ref_dwait <= '0;
        ref2_v <= 1'b0; ref2_leaf <= '0; ref2_id <= '0; ref2_d <= '0;
        ref2_pay <= '0; ref2_wait <= 1'b0; ref2_dwait <= '0;
      end else if (flush_i) begin
        ref_v <= 1'b0; ref_leaf <= '0; ref_id <= '0; ref_d <= '0;
        ref_pay <= '0; ref_wait <= 1'b0; ref_dwait <= '0;
        ref2_v <= 1'b0; ref2_leaf <= '0; ref2_id <= '0; ref2_d <= '0;
        ref2_pay <= '0; ref2_wait <= 1'b0; ref2_dwait <= '0;
      end else begin
        // Reference = the single-stage publish on the live full-depth
        // tree (ref_*), proven equal to pick_* by the pickdist check.
        ref_v <= ref_valid[1];
        ref_leaf <= '0;
        if (ref_valid[1]) begin
          ref_leaf[ref_slot[1]] <= 1'b1;
          ref_id                <= ent_id_i[ref_slot[1]];
          ref_d                 <= ref_dist[1];
          ref_pay               <= ent_pay_i[ref_slot[1]];
        end
        ref_wait  <= wait_d;
        ref_dwait <= dwait_d;
        ref2_v     <= ref_v;     ref2_leaf <= ref_leaf;
        ref2_id    <= ref_id;    ref2_d    <= ref_d;
        ref2_pay   <= ref_pay;   ref2_wait <= ref_wait;
        ref2_dwait <= ref_dwait;
      end
    end
    always_ff @(posedge clk_i) begin
      if (rst_ni && !flush_i) begin
        t3_lsqr2_n <= t3_lsqr2_n + 1;
        g6lc_t3_lsqr2_oh: assert ($onehot0(win_leaf_o) &&
            (|win_leaf_o) === win_valid_o)
          else $error("g6lc_lsq_reduce: win_leaf not onehot/valid");
        g6lc_t3_lsqr2_eq: assert (
            win_valid_o === ref2_v && win_leaf_o === ref2_leaf &&
            wait_o === ref2_wait && dwait_ids_o === ref2_dwait &&
            (!win_valid_o ||
             (win_id_o === ref2_id && win_dist_o === ref2_d &&
              win_pay_o === ref2_pay)))
          else $error("g6lc_lsq_reduce: equiv lsqr2 v=%b/%b leaf=%h/%h id=%h/%h dist=%h/%h pay=%h/%h wait=%b/%b dwait=%h/%h ref_v=%b ref_s=%0d",
                      win_valid_o, ref2_v, win_leaf_o, ref2_leaf,
                      win_id_o, ref2_id, win_dist_o, ref2_d,
                      win_pay_o, ref2_pay, wait_o, ref2_wait,
                      dwait_ids_o, ref2_dwait, ref_valid[1], ref_slot[1]);
      end
    end
    final begin
      if ($test$plusargs("equiv_report"))
        $display("[equiv] g6lc_lsq_reduce lsqr2: checked=%0d", t3_lsqr2_n);
    end
  end
//pragma translate_on
  // svt-stage: class R value
endmodule
