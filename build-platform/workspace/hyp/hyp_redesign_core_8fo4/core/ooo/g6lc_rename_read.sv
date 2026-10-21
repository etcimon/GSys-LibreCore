// hyp8 provenance: REWRITTEN (rename stage R1 -- state read + reserve)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_rename_read -- R1 of the staged rename (analysis/g6lc_rename.md).
// Everything here reads REGISTERED state only: the speculative and FP maps,
// the free/busy vectors, the per-hart checkpoint counters. Per lane it
// produces:
//   - the raw map reads (prs1/prs2/old, fprs1/fprs2/fprs3/fold),
//   - raw readiness (busy at read time; R2 may still override it against
//     in-flight producers),
//   - the destination pick. Port 0 takes the lowest free entry, port 1 the
//     highest from the same snapshot (sv-timing A106: neither waits for
//     the other's clear), ports >= 2 serial lowest -- the unbanked form.
//   - the checkpoint slot reservation for each branch lane.
// The pick and checkpoint reservations are committed to the state core at
// the R1 capture edge (res_* outputs); a killed group returns them exactly
// once through g6lc_rename's kill port.
//
// No intra-group chaining happens here: the unbanked design read the map
// through its own in-cycle writes (map_d); in the staged form that bypass
// lives in R2 (g6lc_rename_resolve) together with the previous-groups
// bypass, which is exactly the same dependency window seen one cycle
// later.

module g6lc_rename_read
  import g6lc_ooo_pkg::*;
#(
    parameter int unsigned PRF_ENTRIES  = 72,
    parameter int unsigned PRF_W        = 7,
    parameter int unsigned NR_PORTS     = 2,
    parameter int unsigned NR_HARTS     = 1,
    parameter int unsigned CKPT_DEPTH   = 8,
    parameter int unsigned FPRF_ENTRIES = 0,
    parameter int unsigned FPRF_W       = 1,
    // hyp8 r4: freelist bank count (HypCfg.FreelistBanks); lane p picks
    // only from bank p % FL_BANKS (entry index == bank mod FL_BANKS).
    parameter int unsigned FL_BANKS     = 1
) (
    // Live dispatch group (ungated intent -- the capacity test must not
    // depend on whether the group may proceed, exactly as the unbanked
    // stall_c).
    input  logic [NR_PORTS-1:0]       valid_i,
    input  logic [NR_PORTS-1:0][(NR_HARTS<=1?1:$clog2(NR_HARTS))-1:0] hart_i,
    input  logic [NR_PORTS-1:0][4:0]  rs1_i,
    input  logic [NR_PORTS-1:0][4:0]  rs2_i,
    input  logic [NR_PORTS-1:0][4:0]  rs3_i,
    input  logic [NR_PORTS-1:0][4:0]  rd_i,
    input  logic [NR_PORTS-1:0]       need_rd_i,
    input  logic [NR_PORTS-1:0]       is_branch_i,
    input  logic [NR_PORTS-1:0]       is_fpr_rd_i,
    input  logic [NR_PORTS-1:0]       is_fpr_rs1_i,
    input  logic [NR_PORTS-1:0]       is_fpr_rs2_i,
    input  logic [NR_PORTS-1:0]       is_fpr_rs3_i,
    // Registered state (from g6lc_rename_recover).
    input  logic [(NR_HARTS<1?1:NR_HARTS)-1:0][31:0][PRF_W-1:0]  map_q_i,
    input  logic [(NR_HARTS<1?1:NR_HARTS)-1:0][31:0][FPRF_W-1:0] fmap_q_i,
    input  logic [PRF_ENTRIES-1:0]    free_q_i,
    input  logic [(FPRF_ENTRIES<1?1:FPRF_ENTRIES)-1:0] ffree_q_i,
    input  logic [PRF_ENTRIES-1:0]    busy_q_i,
    input  logic [(FPRF_ENTRIES<1?1:FPRF_ENTRIES)-1:0] fbusy_q_i,
    input  logic [(NR_HARTS<1?1:NR_HARTS)-1:0][$clog2(CKPT_DEPTH+1)-1:0] ckpt_cnt_q_i,
    input  logic [(NR_HARTS<1?1:NR_HARTS)-1:0][$clog2(CKPT_DEPTH+1)-1:0] ckpt_head_q_i,
    // Capacity for the presented group (combinational, ungated intent).
    output logic                      stall_o,
    // R1 lane records.
    output ooo_ren_lane_t [NR_PORTS-1:0] lane_o,
    // Reservation writes committed at the capture edge.
    output logic [PRF_ENTRIES-1:0]    res_pick_mask_o,
    output logic [(FPRF_ENTRIES<1?1:FPRF_ENTRIES)-1:0] res_fpick_mask_o,
    output logic [(NR_HARTS<1?1:NR_HARTS)-1:0][$clog2(CKPT_DEPTH+1)-1:0] res_br_inc_o
);

  localparam int unsigned NH    = (NR_HARTS < 1) ? 1 : NR_HARTS;
  localparam int unsigned FPN   = (FPRF_ENTRIES < 1) ? 1 : FPRF_ENTRIES;
  localparam bit          FP_EN = (FPRF_ENTRIES >= 32);
  localparam int unsigned LVL_W = $clog2(CKPT_DEPTH+1);
  localparam int unsigned CKPT_PER_HART = (CKPT_DEPTH / NH < 1) ? 1 : CKPT_DEPTH / NH;

  // Ring index within hart h's slice (three conditional subtractions cover
  // head + count + NR_PORTS, as the unbanked ckpt_slot).
  function automatic logic [LVL_W-1:0] ckpt_slot(input int unsigned h,
                                               input int unsigned v);
    int unsigned t;
    t = v;
    for (int unsigned i = 0; i < 3; i++) if (t >= CKPT_PER_HART) t -= CKPT_PER_HART;
    return LVL_W'(h * CKPT_PER_HART + t);
  endfunction

  // Lowest set bit as a log-depth prefix OR (A136/A143: the mapped carry
  // chain of `fr & (~fr + 1)` measured +31% on the live board).
  function automatic logic [PRF_ENTRIES-1:0] lowest_set(input logic [PRF_ENTRIES-1:0] x);
    logic [PRF_ENTRIES-1:0] below;
    below = x << 1;
    for (int unsigned l = 1; l < PRF_ENTRIES; l = l << 1) below = below | (below << l);
    return x & ~below;
  endfunction
  function automatic logic [FPN-1:0] flowest_set(input logic [FPN-1:0] x);
    logic [FPN-1:0] below;
    below = x << 1;
    for (int unsigned l = 1; l < FPN; l = l << 1) below = below | (below << l);
    return x & ~below;
  endfunction

  // One-hot pick from a snapshot: port 0 lowest, port 1 highest (the
  // bit-reversed isolate), ports >= 2 serial lowest.
  function automatic logic [PRF_ENTRIES-1:0] pick_free_mask(
      input logic [PRF_ENTRIES-1:0] fr, input logic high);
    logic [PRF_ENTRIES-1:0] cand, ordered, lowest, reversed, reversed_lowest;
    cand = fr & ~PRF_ENTRIES'(1);
    reversed = {<<{cand}};
    ordered = high ? reversed : cand;
    lowest = lowest_set(ordered);
    reversed_lowest = {<<{lowest}};
    return high ? reversed_lowest : lowest;
  endfunction
  function automatic logic [FPN-1:0] pick_ffree_mask(
      input logic [FPN-1:0] fr, input logic high);
    logic [FPN-1:0] ordered, lowest, reversed, reversed_lowest;
    reversed = {<<{fr}};
    ordered = high ? reversed : fr;
    lowest = flowest_set(ordered);
    reversed_lowest = {<<{lowest}};
    return high ? reversed_lowest : lowest;
  endfunction

  function automatic logic [PRF_W-1:0] mask_to_tag(input logic [PRF_ENTRIES-1:0] m);
    mask_to_tag = '0;
    for (int unsigned i = 0; i < PRF_ENTRIES; i++)
      if (m[i]) mask_to_tag = mask_to_tag | PRF_W'(i);
  endfunction
  function automatic logic [FPRF_W-1:0] mask_to_ftag(input logic [FPN-1:0] m);
    mask_to_ftag = '0;
    for (int unsigned i = 0; i < FPN; i++)
      if (m[i]) mask_to_ftag = mask_to_ftag | FPRF_W'(i);
  endfunction

  // hyp8 r4: bank membership mask -- lane b sees only entries whose index
  // is congruent to b mod FL_BANKS (the interleaved banked free list, the
  // same mapping g6lc_freelist uses).
  function automatic logic [PRF_ENTRIES-1:0] bank_mask(input int unsigned b);
    bank_mask = '0;
    for (int unsigned i = 0; i < PRF_ENTRIES; i++)
      if ((i % FL_BANKS) == (b % FL_BANKS)) bank_mask[i] = 1'b1;
  endfunction
  function automatic logic [FPN-1:0] fbank_mask(input int unsigned b);
    fbank_mask = '0;
    for (int unsigned i = 0; i < FPN; i++)
      if ((i % FL_BANKS) == (b % FL_BANKS)) fbank_mask[i] = 1'b1;
  endfunction

  // ----------------------------------------------------------------------
  // Picks + capacity, from the registered free lists only. The sequential
  // claim of earlier lanes uses a running `taken` mask -- equivalent to the
  // unbanked free_d chain but with no map writes in between.
  // ----------------------------------------------------------------------
  // ----------------------------------------------------------------------
  // hyp8 r3: the composed per-port writer billed as one dense cone.
  // Split into the pick chain (NR_PORTS serial links of a one-hot pick —
  // each pool excludes the earlier lanes' actual takes, as before), one
  // always_comb per lane for the copies/map reads/ckpt reservation, and
  // the stall/reduction terms as independent cones.
  // ----------------------------------------------------------------------
  // ----------------------------------------------------------------------
  // hyp8 r4 (banked picks): lane gp picks only from bank gp % FL_BANKS
  // (entry index == bank mod FL_BANKS).  Cross-lane exclusion is required
  // only between lanes sharing a bank, so taken_lt[gp] is a static masked
  // OR of the earlier same-bank takes instead of a serial chain -- for
  // FL_BANKS >= NR_PORTS every lane is independent.  A lane stalls when
  // its own bank is empty (accepted bank-starvation trade-off).
  // ----------------------------------------------------------------------
  logic [PRF_ENTRIES-1:0] lone_p   [NR_PORTS];
  logic [FPN-1:0]         flone_p  [NR_PORTS];
  logic [PRF_ENTRIES-1:0] taken_lt [NR_PORTS];
  logic [FPN-1:0]         ftaken_lt[NR_PORTS];
  logic [NR_PORTS-1:0]    alloc_ok, falloc_ok, alloc_do, falloc_do;
  logic [NR_PORTS-1:0]    lane_stall;
  logic [NR_PORTS-1:0]    lane_ckpt;
  logic [NR_PORTS-1:0]    need_int, need_fp;

  for (genvar gp = 0; gp < NR_PORTS; gp++) begin : gen_picks
    assign need_int[gp] = valid_i[gp] && need_rd_i[gp] &&
                          !(FP_EN && is_fpr_rd_i[gp]);
    assign need_fp[gp]  = FP_EN && valid_i[gp] && need_rd_i[gp] &&
                          is_fpr_rd_i[gp];
    // Earlier takes by lanes sharing this lane's bank (static unroll).
    always_comb begin : p_prior
      taken_lt[gp]  = '0;
      ftaken_lt[gp] = '0;
      for (int unsigned ge = 0; ge < NR_PORTS; ge++) begin
        if ((ge < gp) && ((ge % FL_BANKS) == (gp % FL_BANKS))) begin
          if (alloc_do[ge])  taken_lt[gp]  |= lone_p[ge];
          if (falloc_do[ge]) ftaken_lt[gp] |= flone_p[ge];
        end
      end
    end
    assign lone_p[gp]   = pick_free_mask (free_q_i  & bank_mask(gp) &
                                          ~taken_lt[gp],  (gp == 1));
    assign flone_p[gp]  = pick_ffree_mask(ffree_q_i & fbank_mask(gp) &
                                          ~ftaken_lt[gp], (gp == 1));
    assign alloc_ok[gp]  = |lone_p[gp];
    assign falloc_ok[gp] = |flone_p[gp];
    assign alloc_do[gp]  = need_int[gp] && alloc_ok[gp];
    assign falloc_do[gp] = need_fp[gp]  && falloc_ok[gp];
    // a miss on a demanded pick stalls (any lane; its own bank pool)
    assign lane_stall[gp] = valid_i[gp] && need_rd_i[gp] &&
                            (is_fpr_rd_i[gp] ? !falloc_ok[gp] : !alloc_ok[gp]);
  end
  // Reservation masks: OR gather of every lane's actual take.
  always_comb begin : p_resmask
    res_pick_mask_o  = '0;
    res_fpick_mask_o = '0;
    for (int unsigned g = 0; g < NR_PORTS; g++) begin
      if (alloc_do[g])  res_pick_mask_o  |= lone_p[g];
      if (falloc_do[g]) res_fpick_mask_o |= flone_p[g];
    end
  end

  for (genvar gp = 0; gp < NR_PORTS; gp++) begin : gen_lane
    always_comb begin : p_lane
      lane_o[gp].v         = valid_i[gp];
      lane_o[gp].hart      = 2'(hart_i[gp]);
      lane_o[gp].rs1       = rs1_i[gp];
      lane_o[gp].rs2       = rs2_i[gp];
      lane_o[gp].rs3       = rs3_i[gp];
      lane_o[gp].rd        = rd_i[gp];
      lane_o[gp].need_rd   = need_rd_i[gp];
      lane_o[gp].is_branch = is_branch_i[gp];
      lane_o[gp].f_rd      = is_fpr_rd_i[gp];
      lane_o[gp].f_rs1     = is_fpr_rs1_i[gp];
      lane_o[gp].f_rs2     = is_fpr_rs2_i[gp];
      lane_o[gp].f_rs3     = is_fpr_rs3_i[gp];

      // -- raw map reads (x0 fixed at physical 0; FP f0 is ordinary) ------
      lane_o[gp].prs1 = 8'((rs1_i[gp] == 5'd0) ? '0 : map_q_i[hart_i[gp]][rs1_i[gp]]);
      lane_o[gp].prs2 = 8'((rs2_i[gp] == 5'd0) ? '0 : map_q_i[hart_i[gp]][rs2_i[gp]]);
      lane_o[gp].old  = 8'((rd_i[gp]  == 5'd0) ? '0 : map_q_i[hart_i[gp]][rd_i[gp]]);
      lane_o[gp].rs1_rdy = (rs1_i[gp] == 5'd0) ||
                           !busy_q_i[PRF_W'(lane_o[gp].prs1[PRF_W-1:0])];
      lane_o[gp].rs2_rdy = (rs2_i[gp] == 5'd0) ||
                           !busy_q_i[PRF_W'(lane_o[gp].prs2[PRF_W-1:0])];
      lane_o[gp].rs3_rdy = 1'b1;
      lane_o[gp].fprs1 = '0;
      lane_o[gp].fprs2 = '0;
      lane_o[gp].fprs3 = '0;
      lane_o[gp].fold  = '0;
      if (FP_EN) begin
        lane_o[gp].fprs1 = 8'(fmap_q_i[hart_i[gp]][rs1_i[gp]]);
        lane_o[gp].fprs2 = 8'(fmap_q_i[hart_i[gp]][rs2_i[gp]]);
        lane_o[gp].fprs3 = 8'(fmap_q_i[hart_i[gp]][rs3_i[gp]]);
        lane_o[gp].fold  = 8'(fmap_q_i[hart_i[gp]][rd_i[gp]]);
        if (is_fpr_rs1_i[gp])
          lane_o[gp].rs1_rdy = !fbusy_q_i[FPRF_W'(lane_o[gp].fprs1[FPRF_W-1:0])];
        if (is_fpr_rs2_i[gp])
          lane_o[gp].rs2_rdy = !fbusy_q_i[FPRF_W'(lane_o[gp].fprs2[FPRF_W-1:0])];
        if (is_fpr_rs3_i[gp])
          lane_o[gp].rs3_rdy = !fbusy_q_i[FPRF_W'(lane_o[gp].fprs3[FPRF_W-1:0])];
      end

      // -- destination pick ------------------------------------------------
      lane_o[gp].do_alloc  = alloc_do[gp];
      lane_o[gp].prd       = alloc_do[gp]  ? 8'(mask_to_tag(lone_p[gp]))  : '0;
      lane_o[gp].do_falloc = falloc_do[gp];
      lane_o[gp].fprd      = falloc_do[gp] ? 8'(mask_to_ftag(flone_p[gp])) : '0;
    end
  end

  // -- checkpoint reservation ---------------------------------------------
  // Same capacity accounting as the unbanked design, per hart slice:
  // earlier same-group branches of the same hart consume earlier slots.
  // same_before is a $countones over the earlier-lane mask; res_br_inc is
  // a per-hart count of ckpt lanes (the original dynamic += commute).
  logic [NR_PORTS-1:0] sbm [NR_PORTS];
  logic [31:0]         sb_cnt [NR_PORTS];
  for (genvar gp = 0; gp < NR_PORTS; gp++) begin : gen_ckpt
    for (genvar ge = 0; ge < NR_PORTS; ge++) begin : gen_sbm
      if (ge < gp) begin : gen_e
        assign sbm[gp][ge] = valid_i[ge] && is_branch_i[ge] &&
                             (2'(hart_i[ge]) == 2'(hart_i[gp]));
      end else begin : gen_z
        assign sbm[gp][ge] = 1'b0;
      end
    end
    assign sb_cnt[gp] = 32'($countones(sbm[gp]));
    always_comb begin : p_ckpt
      lane_o[gp].do_ckpt   = 1'b0;
      lane_o[gp].ckpt_slot = '0;
      if (valid_i[gp] && is_branch_i[gp] &&
          (32'(ckpt_cnt_q_i[hart_i[gp]]) + sb_cnt[gp]
             < 32'(CKPT_PER_HART))) begin
        lane_o[gp].do_ckpt   = 1'b1;
        lane_o[gp].ckpt_slot = 6'(ckpt_slot(int'(hart_i[gp]),
            int'(32'(ckpt_head_q_i[hart_i[gp]]) +
            32'(ckpt_cnt_q_i[hart_i[gp]]) + sb_cnt[gp])));
      end
    end
    assign lane_ckpt[gp] = lane_o[gp].do_ckpt;
  end
  for (genvar gh = 0; gh < NH; gh++) begin : gen_brinc
    logic [NR_PORTS-1:0] hmatch;
    for (genvar gp = 0; gp < NR_PORTS; gp++) begin : gen_hm
      assign hmatch[gp] = lane_ckpt[gp] && (int'(hart_i[gp]) == gh);
    end
    logic [31:0] hmc;
    assign hmc = 32'($countones(hmatch));
    assign res_br_inc_o[gh] = LVL_W'(hmc);
  end

  // -- stall: capacity misses, per-lane pick miss, per-hart ckpt overflow --
  logic [NH-1:0] br_over;
  for (genvar gh = 0; gh < NH; gh++) begin : gen_brover
    logic [NR_PORTS-1:0] hbr;
    for (genvar gp = 0; gp < NR_PORTS; gp++) begin : gen_hbr
      assign hbr[gp] = valid_i[gp] && is_branch_i[gp] &&
                       (int'(hart_i[gp]) == gh);
    end
    always_comb begin : p_brover
      automatic int unsigned nbr_cnt;
      nbr_cnt = int'($countones(hbr));
      br_over[gh] = (int'(ckpt_cnt_q_i[gh]) + int'(nbr_cnt)
                     > CKPT_PER_HART);
    end
  end
  // hyp8 r4: capacity is bank-aware -- the group stalls iff any demanded
  // pick misses its own bank pool (lane_stall, all lanes), or a checkpoint
  // ring overflows.  With FL_BANKS=1 this is the unbanked per-lane form.
  assign stall_o = (|lane_stall) || (|br_over);

endmodule
