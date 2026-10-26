// hyp8 provenance: REWRITTEN (staged multi-port rename wrapper)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_rename -- U5.1 multi-port rename, hyp8 staged form
// (analysis/g6lc_rename.md, analysis/cut_minimization.md "g6lc_rename").
// The unbanked design folded map read -> intra-group forwarding -> map/
// busy/free/checkpoint write -> recovery repair into one combinational
// cycle (~115 FO4). The staged form keeps the same public contract but
// splits it:
//   R1  g6lc_rename_read    -- registered-state reads, free-register picks,
//                             checkpoint slot reservation, capacity.
//   R2  g6lc_rename_resolve -- the only kernel: previous-group and
//                             intra-group (older-lane) dependency bypass.
//   R3  g6lc_rename_publish -- write assembly: map/busy/owner updates,
//                             checkpoint payload capture, alloc marks.
//   core g6lc_rename_recover -- all persistent state, WB/commit events and
//                             the registered mispredict repair.
// hyp8: two internal pipeline registers (R1|R2|R3) = +2 cycles of
// front-end depth, rank 4; the resolve kernel itself is rank 0/1
// (restructure). Outputs land registered, one cycle after the group's
// state writes are applied, and are announced on group_valid_o -- dispatch
// latches the whole group on that strobe (enable_i stays high while the
// group waits at the input, exactly the unbanked handshake stretched).
//
// RenameStages=1 (HypDefault) is NOT reachable here: the single-cycle
// form lives in the reference tree; this file implements the staged form
// only and asserts the knob.
//
// Kill identities (analysis/callers_and_kills B): mispredict_i/flush_i
// kill every in-flight group; flush_hart_i kills only that hart's lanes
// (survivors of a mixed-residency group still publish). A killed lane's
// free/checkpoint reservations return exactly once, at the kill edge.
// Cross-hart contamination from an already-resolved group is impossible:
// every bypass record is hart-qualified, and a same-hart consumer in the
// pipe dies with its producer.

module g6lc_rename
  import g6lc_ooo_pkg::*;
#(
    parameter int unsigned PRF_ENTRIES  = 72,
    parameter int unsigned PRF_W        = 7,
    parameter int unsigned NR_PORTS     = 2,
    parameter int unsigned NR_FREE      = 2,
    parameter int unsigned NR_WB        = 1,
    parameter int unsigned CKPT_DEPTH   = 8,
    parameter int unsigned NR_HARTS     = 1,
    parameter int unsigned FPRF_ENTRIES = 0,
    parameter int unsigned FPRF_W       = 1,
    // hyp8: HypCfg.RenameStages must be 3 (checked below).
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    input  logic [(NR_HARTS<1?1:NR_HARTS)-1:0] flush_hart_i,
    input  logic mispredict_i,
    input  logic [$clog2(CKPT_DEPTH+1)-1:0] mispredict_level_i,
    // Unissued-window kill (controller flush_unissued): a group still in
    // this pipe has not dispatched, so its scoreboard window is in the
    // unissued tail and dies with the event. The stage must die with it —
    // a survivor would publish later and dispatch's grp_pend_q (already
    // cleared) could not keep a second group out of the pipe.
    input  logic flush_unissued_i,
    input  logic [NR_PORTS-1:0][(NR_HARTS<=1?1:$clog2(NR_HARTS))-1:0] hart_i,
    input  logic [NR_PORTS-1:0]       valid_i,
    input  logic [NR_PORTS-1:0][4:0]  rs1_i,
    input  logic [NR_PORTS-1:0][4:0]  rs2_i,
    input  logic [NR_PORTS-1:0][4:0]  rd_i,
    input  logic [NR_PORTS-1:0]       need_rd_i,
    input  logic [NR_PORTS-1:0]       is_branch_i,
    input  logic [NR_PORTS-1:0]       is_fpr_rd_i,
    input  logic [NR_PORTS-1:0]       is_fpr_rs1_i,
    input  logic [NR_PORTS-1:0]       is_fpr_rs2_i,
    input  logic [NR_PORTS-1:0][4:0]  rs3_i,
    input  logic [NR_PORTS-1:0]       is_fpr_rs3_i,
    output logic [NR_PORTS-1:0][PRF_W-1:0] prs1_o,
    output logic [NR_PORTS-1:0][PRF_W-1:0] prs2_o,
    output logic [NR_PORTS-1:0][PRF_W-1:0] prd_o,
    output logic [NR_PORTS-1:0][PRF_W-1:0] prd_old_o,
    output logic [NR_PORTS-1:0][FPRF_W-1:0] fprs1_o,
    output logic [NR_PORTS-1:0][FPRF_W-1:0] fprs2_o,
    output logic [NR_PORTS-1:0][FPRF_W-1:0] fprs3_o,
    output logic [NR_PORTS-1:0]             rs3_ready_o,
    output logic [NR_PORTS-1:0][FPRF_W-1:0] fprd_o,
    output logic [NR_PORTS-1:0][FPRF_W-1:0] fprd_old_o,
    output logic [NR_PORTS-1:0]       rs1_ready_o,
    output logic [NR_PORTS-1:0]       rs2_ready_o,
    // Current allocation readiness: the live busy bitmaps, so a WB that
    // lands while a group waits in rename/backpressure is visible at IQ
    // allocation even though the R1 ready snapshot is stale.
    output logic [PRF_ENTRIES-1:0] int_busy_o,
    output logic [(FPRF_ENTRIES < 1 ? 1 : FPRF_ENTRIES)-1:0] fp_busy_o,
    output logic [NR_PORTS-1:0][$clog2(CKPT_DEPTH+1)-1:0] ckpt_id_o,
    input  logic [NR_FREE-1:0]        ckpt_retire_i,
    output logic                      stall_o,
    input  logic [NR_WB-1:0]            wb_valid_i,
    input  logic [NR_WB-1:0][PRF_W-1:0] wb_prd_i,
    input  logic [NR_WB-1:0]             fwb_valid_i,
    input  logic [NR_WB-1:0][FPRF_W-1:0] fwb_prd_i,
    input  logic [NR_FREE-1:0]            free_i,
    input  logic [NR_FREE-1:0][PRF_W-1:0] free_prd_i,
    input  logic [NR_FREE-1:0]             ffree_i,
    input  logic [NR_FREE-1:0][FPRF_W-1:0] ffree_prd_i,
    input  logic [NR_FREE-1:0]            commit_valid_i,
    input  logic [NR_FREE-1:0][(NR_HARTS<=1?1:$clog2(NR_HARTS))-1:0] commit_hart_i,
    input  logic [NR_FREE-1:0][4:0]       commit_rd_i,
    input  logic [NR_FREE-1:0][PRF_W-1:0] commit_prd_i,
    input  logic [NR_FREE-1:0]             commit_is_fpr_i,
    input  logic [NR_FREE-1:0][FPRF_W-1:0] commit_fprd_i,
    input  logic                      enable_i,
    // hyp8: registered-group announce -- pulses for one cycle when the
    // oldest in-flight group's state writes have landed and prs*/prd*/
    // ckpt_id below are registered and final. Per lane, matching valid_i.
    output logic [NR_PORTS-1:0]       group_valid_o
);

  localparam int unsigned NH    = (NR_HARTS < 1) ? 1 : NR_HARTS;
  localparam int unsigned FPN   = (FPRF_ENTRIES < 1) ? 1 : FPRF_ENTRIES;
  localparam int unsigned LVL_W = $clog2(CKPT_DEPTH+1);
  // r43-T T1(b): resolve stage count; the review mutant restores the
  // single-cycle form regardless of config.
`ifdef G6LC_MUT_T3_RR_SPLIT
  localparam int unsigned RRS = 1;
`else
  localparam int unsigned RRS = HypCfg.RenameResolveStages;
`endif

`ifndef SYNTHESIS
  initial begin
    if (HypCfg.RenameStages != 3)
      $error("g6lc_rename: staged rewrite requires HypCfg.RenameStages == 3");
    if (!(RRS inside {1, 2}))
      $error("g6lc_rename: HypCfg.RenameResolveStages must be 1 or 2");
  end
`endif

  // ---------------------------------------------------------------------
  // Registered state (recover core) -> R1 reads.
  // ---------------------------------------------------------------------
  logic [NH-1:0][31:0][PRF_W-1:0]  map_q;
  logic [NH-1:0][31:0][FPRF_W-1:0] fmap_q;
  logic [PRF_ENTRIES-1:0]          free_q;
  logic [FPN-1:0]                  ffree_q;
  logic [PRF_ENTRIES-1:0]          busy_q;
  logic [FPN-1:0]                  fbusy_q;
  assign int_busy_o = busy_q;
  assign fp_busy_o = fbusy_q;
  logic [NH-1:0][LVL_W-1:0]        ckpt_cnt_q;
  logic [NH-1:0][LVL_W-1:0]        ckpt_head_q;
  logic                            recovering;

  // R1 combinational outputs.
  logic                          r1_stall;
  ooo_ren_lane_t [NR_PORTS-1:0]  r1_lane;
  logic [PRF_ENTRIES-1:0]        res_pick_mask;
  logic [FPN-1:0]                res_fpick_mask;
  logic [NH-1:0][LVL_W-1:0]      res_br_inc;

  // Pipeline registers: r1_q holds the captured reads (resolve input),
  // s2_q holds the resolved lanes (publish input). s2_lane is the
  // resolve output; rra_lane/res_vld expose the kernel's internal RR-a
  // register (RRS==2) for kill accounting and pipe control.
  logic                          r1_v_q, s2_v_q;
  ooo_ren_lane_t [NR_PORTS-1:0]  r1_q, s2_q;
  ooo_ren_lane_t [NR_PORTS-1:0]  s2_lane;
  ooo_ren_lane_t [NR_PORTS-1:0]  rra_lane;
  logic                          res_vld;
  // The group that published at the last edge -- invisible to the newest
  // R1 map read, still a producer. One-cycle lifetime.
  ooo_ren_lane_t [NR_PORTS-1:0]  prev1_q;

  // Kill decode: which in-flight lanes die at this edge.
  logic                          kill_all;
  logic [NH-1:0]                 kill_hart;
  assign kill_all = mispredict_i || flush_i || flush_unissued_i;
  always_comb begin
    kill_hart = '0;
    for (int unsigned h = 0; h < NH; h++)
      if (flush_hart_i[h]) kill_hart[h] = 1'b1;
  end
  function automatic logic lane_dies(input ooo_ren_lane_t l);
    return l.v && (kill_all || kill_hart[l.hart]);
  endfunction

  // Effective lanes for publish/prev0: drop lanes dying at this edge, and
  // gate on s2_v_q -- the lane registers are not cleared when the stage
  // drains or is killed, so without the valid gate a stale record could
  // leak into a later group's bypass as a phantom producer.
  ooo_ren_lane_t [NR_PORTS-1:0] s2_eff;
  always_comb begin
    for (int unsigned p = 0; p < NR_PORTS; p++) begin
      s2_eff[p] = s2_q[p];
      if (!s2_v_q || lane_dies(s2_q[p])) s2_eff[p].v = 1'b0;
    end
  end

  // Kill accounting: picks of lanes dying at this edge return to the free
  // lists exactly once. Checkpoint reservations need no un-count: a killed
  // lane's slot either drops with the ring unwind (mispredict -- the
  // reservation is the youngest work) or with the per-hart ring reset
  // (flush_hart); a surviving partial group never loses a mid-ring slot.
  // rra_occ covers lanes resident in the resolve kernel under RRS==2 --
  // a fully dying rra group has res_vld==0 but still holds picks.
  logic                    rra_occ;
  logic [PRF_ENTRIES-1:0] kill_pick_mask;
  logic [FPN-1:0]         kill_fpick_mask;
  logic                   kill_v;
  always_comb begin
    kill_pick_mask = '0;
    kill_fpick_mask = '0;
    rra_occ = 1'b0;
    for (int unsigned p = 0; p < NR_PORTS; p++)
      rra_occ |= rra_lane[p].v;
    if (r1_v_q || rra_occ || s2_v_q) begin
      for (int unsigned p = 0; p < NR_PORTS; p++) begin
        if (r1_v_q && lane_dies(r1_q[p])) begin
          if (r1_q[p].do_alloc)
            kill_pick_mask |= PRF_ENTRIES'(1) <<
                r1_q[p].prd[$clog2(PRF_ENTRIES > 1 ? PRF_ENTRIES : 2)-1:0];
          if (r1_q[p].do_falloc)
            kill_fpick_mask |= FPN'(1) <<
                r1_q[p].fprd[$clog2(FPN > 1 ? FPN : 2)-1:0];
        end
        if (s2_v_q && lane_dies(s2_q[p])) begin
          if (s2_q[p].do_alloc)
            kill_pick_mask |= PRF_ENTRIES'(1) <<
                s2_q[p].prd[$clog2(PRF_ENTRIES > 1 ? PRF_ENTRIES : 2)-1:0];
          if (s2_q[p].do_falloc)
            kill_fpick_mask |= FPN'(1) <<
                s2_q[p].fprd[$clog2(FPN > 1 ? FPN : 2)-1:0];
        end
        // r43-T T1(b): lanes resident in the resolve kernel's RR-a
        // register die on the same kill decode and return their picks.
        if (lane_dies(rra_lane[p])) begin
          if (rra_lane[p].do_alloc)
            kill_pick_mask |= PRF_ENTRIES'(1) <<
                rra_lane[p].prd[$clog2(PRF_ENTRIES > 1 ? PRF_ENTRIES : 2)-1:0];
          if (rra_lane[p].do_falloc)
            kill_fpick_mask |= FPN'(1) <<
                rra_lane[p].fprd[$clog2(FPN > 1 ? FPN : 2)-1:0];
        end
      end
    end
    kill_v = |kill_pick_mask | |kill_fpick_mask;
  end

  // ---------------------------------------------------------------------
  // R2 -- resolve (the kernel). prev0 is simply the group sitting in s2
  // (s2_eff: it has not published yet and its write lands no earlier than
  // the next edge); prev1 is the group that published at the last edge.
  // r43-T T1(b): under RRS==2 the kernel holds its own RR-a register
  // (rra) between r1 and s2; the rra lane record itself is the third
  // producer slot, so no third record is needed at this level. res_vld
  // presents the resolved group; rra_lane_o exposes the in-kernel record
  // for the freelist kill accounting.
  // ---------------------------------------------------------------------
  g6lc_rename_resolve #(
      .NR_PORTS        (NR_PORTS),
      .NR_HARTS        (NR_HARTS),
      .HypCfg          (HypCfg)
  ) u_resolve (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .kill_all_i (kill_all),
      .kill_hart_i(kill_hart),
      .lane_i     (r1_q),
      .lane_v_i   (r1_surv),
      .prev0_i    (s2_eff),
      .prev1_i    (prev1_q),
      .lane_o     (s2_lane),
      .vld_o      (res_vld),
      .rra_o      (rra_lane)
  );

  // ---------------------------------------------------------------------
  // R3 -- publish (comb write assembly over s2_eff).
  // ---------------------------------------------------------------------
  logic [NR_PORTS-1:0]      pub_map_wr_v;
  logic [NR_PORTS-1:0][1:0] pub_map_h;
  logic [NR_PORTS-1:0][4:0] pub_map_rd;
  logic [NR_PORTS-1:0][7:0] pub_map_prd;
  logic [NR_PORTS-1:0]      pub_fmap_wr_v;
  logic [NR_PORTS-1:0][7:0] pub_fmap_prd;
  logic [PRF_ENTRIES-1:0]   pub_busy_set;
  logic [FPN-1:0]           pub_fbusy_set;
  logic [NR_PORTS-1:0]      pub_own_v;
  logic [NR_PORTS-1:0][7:0] pub_own_idx;
  logic [NR_PORTS-1:0][1:0] pub_own_h;
  logic [NR_PORTS-1:0]      pub_fown_v;
  logic [NR_PORTS-1:0][7:0] pub_fown_idx;
  logic [NR_PORTS-1:0]      pub_ck_v;
  logic [NR_PORTS-1:0][5:0] pub_ck_slot;
  logic [NR_PORTS-1:0][1:0] pub_ck_h;
  logic [NR_PORTS-1:0][31:0][PRF_W-1:0]  pub_ck_map;
  logic [NR_PORTS-1:0][31:0][FPRF_W-1:0] pub_ck_fmap;
  logic [NR_PORTS-1:0][PRF_ENTRIES-1:0]  pub_ck_aval;
  logic [NR_PORTS-1:0][FPN-1:0]          pub_ck_faval;
  logic [NH-1:0][PRF_ENTRIES-1:0]        pub_mark;
  logic [NH-1:0][FPN-1:0]                pub_fmark;

  g6lc_rename_publish #(
      .PRF_ENTRIES (PRF_ENTRIES), .PRF_W (PRF_W), .NR_PORTS (NR_PORTS),
      .NR_HARTS (NR_HARTS), .CKPT_DEPTH (CKPT_DEPTH),
      .FPRF_ENTRIES (FPRF_ENTRIES), .FPRF_W (FPRF_W)
  ) u_publish (
      .lane_i (s2_eff),
      .map_q_i (map_q), .fmap_q_i (fmap_q),
      .pub_map_wr_v_o (pub_map_wr_v), .pub_map_h_o (pub_map_h),
      .pub_map_rd_o (pub_map_rd), .pub_map_prd_o (pub_map_prd),
      .pub_fmap_wr_v_o (pub_fmap_wr_v), .pub_fmap_prd_o (pub_fmap_prd),
      .pub_busy_set_o (pub_busy_set), .pub_fbusy_set_o (pub_fbusy_set),
      .pub_own_v_o (pub_own_v), .pub_own_idx_o (pub_own_idx),
      .pub_own_h_o (pub_own_h),
      .pub_fown_v_o (pub_fown_v), .pub_fown_idx_o (pub_fown_idx),
      .pub_ck_v_o (pub_ck_v), .pub_ck_slot_o (pub_ck_slot),
      .pub_ck_h_o (pub_ck_h), .pub_ck_map_o (pub_ck_map),
      .pub_ck_fmap_o (pub_ck_fmap), .pub_ck_aval_o (pub_ck_aval),
      .pub_ck_faval_o (pub_ck_faval),
      .pub_mark_o (pub_mark), .pub_fmark_o (pub_fmark)
  );

  // ---------------------------------------------------------------------
  // Pipe control. s2 always drains (publish is unconditional); r1 fills s2
  // the next edge; a group captures only into an empty-or-draining r1 and
  // never during recovery (A147) or a kill edge.
  // ---------------------------------------------------------------------
  logic can_capture, capture, s2_pub;
  assign s2_pub = s2_v_q;  // every occupied s2 publishes at this edge
  // r43-T T1(b): the resolve kernel adds one in-flight slot under
  // RRS==2; the same "capture only into headroom" gate extends to it
  // (degenerates to !(r1_v_q && s2_v_q) at RRS==1 since res_vld==0).
  assign can_capture = !(r1_v_q && (RRS == 1 || res_vld) && s2_v_q) &&
                       !recovering && !kill_all && !(|kill_hart);
  // Group admission is all-or-nothing, as the unbanked ren_v group gate.
  assign capture = can_capture && enable_i && (|valid_i) && !r1_stall;

  // Reported to dispatch: capacity of the PRESENTED group plus pipe room
  // and recovery -- a held group simply waits at the input while
  // dispatch's own handshake holds it (all-or-nothing).
  assign stall_o = r1_stall || !can_capture;

  // ---------------------------------------------------------------------
  // R1 instance + capture register.
  // ---------------------------------------------------------------------
  g6lc_rename_read #(
      .PRF_ENTRIES (PRF_ENTRIES), .PRF_W (PRF_W), .NR_PORTS (NR_PORTS),
      .NR_HARTS (NR_HARTS), .CKPT_DEPTH (CKPT_DEPTH),
      .FPRF_ENTRIES (FPRF_ENTRIES), .FPRF_W (FPRF_W),
      .FL_BANKS (HypCfg.FreelistBanks)
  ) u_read (
      .valid_i (valid_i), .hart_i (hart_i),
      .rs1_i (rs1_i), .rs2_i (rs2_i), .rs3_i (rs3_i), .rd_i (rd_i),
      .need_rd_i (need_rd_i), .is_branch_i (is_branch_i),
      .is_fpr_rd_i (is_fpr_rd_i), .is_fpr_rs1_i (is_fpr_rs1_i),
      .is_fpr_rs2_i (is_fpr_rs2_i), .is_fpr_rs3_i (is_fpr_rs3_i),
      .map_q_i (map_q), .fmap_q_i (fmap_q),
      .free_q_i (free_q), .ffree_q_i (ffree_q),
      .busy_q_i (busy_q), .fbusy_q_i (fbusy_q),
      .ckpt_cnt_q_i (ckpt_cnt_q), .ckpt_head_q_i (ckpt_head_q),
      .stall_o (r1_stall),
      .lane_o (r1_lane),
      .res_pick_mask_o (res_pick_mask),
      .res_fpick_mask_o (res_fpick_mask),
      .res_br_inc_o (res_br_inc)
  );

  // ---------------------------------------------------------------------
  // State core.
  // ---------------------------------------------------------------------
  g6lc_rename_recover #(
      .PRF_ENTRIES (PRF_ENTRIES), .PRF_W (PRF_W), .NR_PORTS (NR_PORTS),
      .NR_FREE (NR_FREE), .NR_WB (NR_WB), .NR_HARTS (NR_HARTS),
      .CKPT_DEPTH (CKPT_DEPTH), .FPRF_ENTRIES (FPRF_ENTRIES),
      .FPRF_W (FPRF_W)
  ) u_recover (
      .clk_i (clk_i), .rst_ni (rst_ni),
      .flush_i (flush_i), .flush_hart_i (flush_hart_i),
      .mispredict_i (mispredict_i), .mispredict_level_i (mispredict_level_i),
      .res_v_i (capture),
      .res_pick_mask_i (res_pick_mask),
      .res_fpick_mask_i (res_fpick_mask),
      .res_br_inc_i (res_br_inc),
      .pub_v_i (s2_pub),
      .pub_map_wr_v_i (pub_map_wr_v), .pub_map_h_i (pub_map_h),
      .pub_map_rd_i (pub_map_rd), .pub_map_prd_i (pub_map_prd),
      .pub_fmap_wr_v_i (pub_fmap_wr_v), .pub_fmap_prd_i (pub_fmap_prd),
      .pub_busy_set_i (pub_busy_set), .pub_fbusy_set_i (pub_fbusy_set),
      .pub_own_v_i (pub_own_v), .pub_own_idx_i (pub_own_idx),
      .pub_own_h_i (pub_own_h),
      .pub_fown_v_i (pub_fown_v), .pub_fown_idx_i (pub_fown_idx),
      .pub_ck_v_i (pub_ck_v), .pub_ck_slot_i (pub_ck_slot),
      .pub_ck_h_i (pub_ck_h), .pub_ck_map_i (pub_ck_map),
      .pub_ck_fmap_i (pub_ck_fmap), .pub_ck_aval_i (pub_ck_aval),
      .pub_ck_faval_i (pub_ck_faval),
      .pub_mark_i (pub_mark), .pub_fmark_i (pub_fmark),
      .kill_v_i (kill_v),
      .kill_pick_mask_i (kill_pick_mask),
      .kill_fpick_mask_i (kill_fpick_mask),
      .wb_valid_i (wb_valid_i), .wb_prd_i (wb_prd_i),
      .fwb_valid_i (fwb_valid_i), .fwb_prd_i (fwb_prd_i),
      .free_i (free_i), .free_prd_i (free_prd_i),
      .ffree_i (ffree_i), .ffree_prd_i (ffree_prd_i),
      .ckpt_retire_i (ckpt_retire_i),
      .commit_valid_i (commit_valid_i), .commit_hart_i (commit_hart_i),
      .commit_rd_i (commit_rd_i), .commit_prd_i (commit_prd_i),
      .commit_is_fpr_i (commit_is_fpr_i), .commit_fprd_i (commit_fprd_i),
      .map_q_o (map_q), .fmap_q_o (fmap_q),
      .free_q_o (free_q), .ffree_q_o (ffree_q),
      .busy_q_o (busy_q), .fbusy_q_o (fbusy_q),
      .ckpt_cnt_q_o (ckpt_cnt_q), .ckpt_head_q_o (ckpt_head_q),
      .recovering_o (recovering)
  );

  // Next-state validity helpers (a stage is alive if any lane survives the
  // kill decode -- dead lanes carry no state forward).
  logic [NR_PORTS-1:0] r1_v_next, s2_v_next, r1_surv;
  logic                s2_load;
  always_comb begin
    for (int unsigned p = 0; p < NR_PORTS; p++) begin
      // Per-lane surviving-v of the r1 record at this edge: the RR-a
      // register's lane_v_i under RRS==2, the s2 next-state under
      // RRS==1 (the kernel masks its own output record then).
      r1_surv[p] = r1_q[p].v && r1_v_q && !lane_dies(r1_q[p]);
      s2_v_next[p] = (RRS == 2) ? s2_lane[p].v : r1_surv[p];
      r1_v_next[p] = r1_lane[p].v && !lane_dies(r1_lane[p]);
    end
    s2_load = (RRS == 2) ? res_vld : r1_v_q;
  end

  // ---------------------------------------------------------------------
  // Pipeline registers + output register.
  // ---------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      r1_v_q <= 1'b0;
      s2_v_q <= 1'b0;
      r1_q <= '{default: '0};
      s2_q <= '{default: '0};
      prev1_q <= '{default: '0};
      group_valid_o <= '0;
      prs1_o <= '0; prs2_o <= '0; prd_o <= '0; prd_old_o <= '0;
      fprs1_o <= '0; fprs2_o <= '0; fprs3_o <= '0;
      rs3_ready_o <= '0;
      fprd_o <= '0; fprd_old_o <= '0;
      rs1_ready_o <= '0; rs2_ready_o <= '0;
      ckpt_id_o <= '{default: '1};
    end else begin
      // prev1: group published at this edge, one-cycle lifetime.
      for (int unsigned p = 0; p < NR_PORTS; p++) begin
        prev1_q[p] <= s2_eff[p];
        if (!s2_pub || lane_dies(s2_q[p])) prev1_q[p].v <= 1'b0;
      end
      // s2 <- resolve output. Under RRS==2 the kernel's lane_o already
      // carries kill-masked v bits (the RR-a register is the dying lane's
      // home, not r1_q).
      if (kill_all) begin
        s2_v_q <= 1'b0;
      end else if (s2_load) begin
        s2_q <= s2_lane;
        if (RRS == 1)
          for (int unsigned p = 0; p < NR_PORTS; p++)
            if (lane_dies(r1_q[p])) s2_q[p].v <= 1'b0;
        s2_v_q <= |s2_v_next;
      end else begin
        s2_v_q <= 1'b0;
      end
      // r1 <- capture. s2 drains (publishes) every occupied cycle, so r1
      // also drains every cycle: it either takes the newly captured group
      // or goes empty -- a held input group simply re-presents until
      // can_go lets capture fire.
      if (kill_all) begin
        r1_v_q <= 1'b0;
      end else if (capture) begin
        r1_q <= r1_lane;
        for (int unsigned p = 0; p < NR_PORTS; p++)
          if (lane_dies(r1_lane[p])) r1_q[p].v <= 1'b0;
        r1_v_q <= |r1_v_next;
      end else begin
        r1_v_q <= 1'b0;
      end
      // Outputs: registered at the publish edge, announced for one cycle.
      if (s2_pub) begin
        group_valid_o <= '0;
        for (int unsigned p = 0; p < NR_PORTS; p++) begin
          group_valid_o[p] <= s2_eff[p].v;
          prs1_o[p] <= PRF_W'(s2_eff[p].prs1[PRF_W-1:0]);
          prs2_o[p] <= PRF_W'(s2_eff[p].prs2[PRF_W-1:0]);
          prd_o[p] <= s2_eff[p].do_alloc
                      ? PRF_W'(s2_eff[p].prd[PRF_W-1:0])
                      : PRF_W'(s2_eff[p].old[PRF_W-1:0]);
          prd_old_o[p] <= PRF_W'(s2_eff[p].old[PRF_W-1:0]);
          fprs1_o[p] <= FPRF_W'(s2_eff[p].fprs1[FPRF_W-1:0]);
          fprs2_o[p] <= FPRF_W'(s2_eff[p].fprs2[FPRF_W-1:0]);
          fprs3_o[p] <= FPRF_W'(s2_eff[p].fprs3[FPRF_W-1:0]);
          fprd_o[p] <= s2_eff[p].do_falloc
                       ? FPRF_W'(s2_eff[p].fprd[FPRF_W-1:0])
                       : FPRF_W'(s2_eff[p].fold[FPRF_W-1:0]);
          fprd_old_o[p] <= FPRF_W'(s2_eff[p].fold[FPRF_W-1:0]);
          rs1_ready_o[p] <= s2_eff[p].rs1_rdy;
          rs2_ready_o[p] <= s2_eff[p].rs2_rdy;
          rs3_ready_o[p] <= s2_eff[p].rs3_rdy;
          ckpt_id_o[p] <= s2_eff[p].do_ckpt
                          ? LVL_W'(s2_eff[p].ckpt_slot[LVL_W-1:0])
                          : '1;
        end
      end else begin
        group_valid_o <= '0;
      end
    end
  end

endmodule
