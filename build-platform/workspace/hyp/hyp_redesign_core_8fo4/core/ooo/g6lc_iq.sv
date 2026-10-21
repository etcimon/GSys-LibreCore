// hyp8 provenance: REWRITTEN (banked issue-queue wrapper)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5.3 unified issue queue, banked form (analysis/g6lc_iq.md): HypCfg.IqBanks
// banks of HypCfg.IqBankEntries stationary entries each (8 x 4 = 32 in the
// hyp8 configuration) replace the flat DEPTH-entry queue. The single-cycle
// cone that measured worst in the flat design -- wake -> ready -> oldest
// select over every entry -- is split per bank; g6lc_iq_arb merges the
// per-bank ranked candidates and presents the issue record from registered
// state (payload + PRF read land the cycle after the bank grant -- the
// rank-2 IRO-latch replacement, cut_minimization.md "g6lc_iq" row).
//
// Modules: g6lc_iq_bank (entries, age, wakeup, spec countdown),
// g6lc_iq_xbar (+1 cross-bank wake tags), g6lc_iq_legal (registered N1d /
// T24 / head-only / may_bypass / mem_stall legality), g6lc_iq_arb
// (candidate registers, pair merge, FP read-port reservation, take/ack),
// g6lc_iq_payload ((bank, entry) payload read after grant).
//
// Public ports are the unbanked queue's, plus: replay_valid_i/replay_tid_i
// (LSU-side replay arrives later; dispatch ties low for now), steer_hint_i
// (dispatch's producer-locality bank hint) and issue_spec_o (the granted
// candidate was woken speculatively). HypCfg.IqBanks==1 degenerates to one
// bank of DEPTH entries, which preserves the unbanked organization.

module g6lc_iq
  import g6lc_ooo_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8,
    parameter int unsigned DEPTH  = 16,
    parameter int unsigned PRF_W  = 6,
    parameter int unsigned NR_WB = G6LCCfg.NrWbPorts,
    // Split FP register class: FP sources wake on the FP writeback and the FP
    // physical tag, which lives in a different file from the integer one.
    // FPRF_W=1 with the FP ports tied low reproduces the integer-only IQ.
    parameter int unsigned FPRF_W = 1,
    parameter type scoreboard_entry_t = logic
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    // U5 production: invalidate IQ entries whose SB slot is cancelled
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0]             cancelled_mask_i,
    input  logic [G6LCCfg.NrIssuePorts-1:0]              disp_valid_i,
    input  scoreboard_entry_t [G6LCCfg.NrIssuePorts-1:0] disp_sbe_i,
    input  logic [G6LCCfg.NrIssuePorts-1:0][31:0]        disp_orig_i,
    input  logic [G6LCCfg.NrIssuePorts-1:0][PRF_W-1:0]   disp_prs1_i,
    input  logic [G6LCCfg.NrIssuePorts-1:0][PRF_W-1:0]   disp_prs2_i,
    input  logic [G6LCCfg.NrIssuePorts-1:0][PRF_W-1:0]   disp_prd_i,
    input  logic [G6LCCfg.NrIssuePorts-1:0]               disp_rs1_ready_i,
    input  logic [G6LCCfg.NrIssuePorts-1:0]               disp_rs2_ready_i,
    // Dispatch-time memdep verdict: a load predicted independent may issue
    // past an older store whose address is still unresolved.
    input  logic [G6LCCfg.NrIssuePorts-1:0]               disp_may_bypass_i,
    // FP source tags + per-source class. rs3 is FP-only (FMA), so it has no
    // integer counterpart and its readiness is tracked separately.
    input  logic [G6LCCfg.NrIssuePorts-1:0][FPRF_W-1:0]  disp_fprs1_i,
    input  logic [G6LCCfg.NrIssuePorts-1:0][FPRF_W-1:0]  disp_fprs2_i,
    input  logic [G6LCCfg.NrIssuePorts-1:0][FPRF_W-1:0]  disp_fprs3_i,
    input  logic [G6LCCfg.NrIssuePorts-1:0]               disp_fpr_rs1_i,
    input  logic [G6LCCfg.NrIssuePorts-1:0]               disp_fpr_rs2_i,
    input  logic [G6LCCfg.NrIssuePorts-1:0]               disp_fpr_rs3_i,
    input  logic [G6LCCfg.NrIssuePorts-1:0]               disp_rs3_ready_i,
    // hyp8: dispatch's bank hint -- the bank of the most recent producer of
    // the lane's rs1 tag, so a likely consumer wakes same-bank (the local
    // same-cycle path) instead of through the +1 xbar.
    input  logic [G6LCCfg.NrIssuePorts-1:0][($clog2((HypCfg.IqBanks>1)?HypCfg.IqBanks:2))-1:0] steer_hint_i,
    // hyp8: LSU replay/kill by trans_id -- re-arms speculative wakeups.
    input  logic                                         replay_valid_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0]             replay_tid_i,
    output logic [G6LCCfg.NrIssuePorts-1:0]              disp_ack_o,
    output logic                                         full_o,
    // Drained-handoff seam (T6a): the thread selector may switch only when
    // empty_o holds.
    output logic                                         empty_o,
    input  logic [NR_WB-1:0]                 wb_valid_i,
    input  logic [NR_WB-1:0][PRF_W-1:0]      wb_prd_i,
    input  logic [NR_WB-1:0]                 fwb_valid_i,
    input  logic [NR_WB-1:0][FPRF_W-1:0]     fwb_prd_i,
    output scoreboard_entry_t [G6LCCfg.NrIssuePorts-1:0] issue_sbe_o,
    output logic [G6LCCfg.NrIssuePorts-1:0][31:0]        issue_orig_o,
    output logic [G6LCCfg.NrIssuePorts-1:0][PRF_W-1:0]   issue_prd_o,
    output logic [G6LCCfg.NrIssuePorts-1:0]               issue_valid_o,
    // hyp8: the presented candidate was woken speculatively (observability;
    // a speculative issue still honours every legality gate).
    output logic [G6LCCfg.NrIssuePorts-1:0]               issue_spec_o,
    // hyp8 g7: per-operand spec-arm bits + ALU-class producer tids for
    // the issue-stage in-ALU forward select.
    output logic [G6LCCfg.NrIssuePorts-1:0][1:0]           issue_spec_ab_o,
    output logic [G6LCCfg.NrIssuePorts-1:0][1:0][G6LCCfg.TRANS_ID_BITS-1:0] issue_ptid_o,
    // hyp8 g7: FU ready status consumed by the arb take-gate, so a
    // spec-broadcast producer can never stall after the IQ grant.
    input  logic                                         lsu_ready_i,
    input  logic                                         fpu_ready_i,
    input  logic                                         csr_ready_i,
    input  logic                                         mult_ready_i,
    input  logic [G6LCCfg.NrIssuePorts-1:0]               issue_ack_i,
    input  logic                                         mem_stall_i,
    // occupancy observability
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0]              st_live_mask_i,
    // Store age gate: live store trans_ids whose address is still UNRESOLVED
    // (one bit per scoreboard slot) and the commit pointer anchoring the
    // circular age order. A load waits only for unresolved stores OLDER than
    // itself; resolved stores are the store_buffer's forwarding domain.
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0]              st_unresolved_mask_i,
    // T6b: the live-store mask partitioned by owning hart. Under mixed
    // residency a load waits only on ITS hart's unresolved stores; the mask
    // is an AND in front of the existing age gate, never part of selection.
    // When NrHarts==1 the term constant-folds away.
    input  logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0][G6LCCfg.NR_SB_ENTRIES-1:0] st_hart_mask_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0]              commit_ptr_i,
    // Scoreboard issued mask (assertions only)
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0]              sb_live_i,
    // hyp8 H27: perf pulse from the arb take-gate — a selected ready
    // candidate declined only by a WB/FLU reservation slot.
    output logic                                          hyp_wb_reserve_stall_o
);

  localparam int unsigned NP    = G6LCCfg.NrIssuePorts;
  localparam int unsigned NH    = (G6LCCfg.NrHarts < 1) ? 1 : G6LCCfg.NrHarts;
  localparam int unsigned HID_W = (NH <= 1) ? 1 : $clog2(NH);
  localparam int unsigned TID_W = G6LCCfg.TRANS_ID_BITS;
  localparam int unsigned BANKS   = (HypCfg.IqBanks < 1) ? 1 : HypCfg.IqBanks;
  localparam int unsigned ENTRIES = (BANKS <= 1) ? DEPTH
                                  : ((HypCfg.IqBankEntries < 1) ? 1
                                     : HypCfg.IqBankEntries);
  localparam int unsigned BW = (BANKS > 1) ? $clog2(BANKS) : 1;
  localparam int unsigned EW = (ENTRIES > 1) ? $clog2(ENTRIES) : 1;
  localparam int unsigned FCNT_W = $clog2(ENTRIES + 1);

  // cls bit layout shared with g6lc_iq_bank / g6lc_iq_legal:
  //   {fp_consumer, cvxif, amo, csr_system, csr, store, load}
  localparam int unsigned C_LD = 0, C_ST = 1, C_CSR = 2, C_CSYS = 3,
                          C_AMO = 4, C_CVXI = 5, C_FP = 6;

  // ----------------------------------------------------------------------
  // Per-lane class encoding (the unbanked ready[] predicate's class tests)
  // ----------------------------------------------------------------------
  logic [NP-1:0][6:0] alloc_cls;
  g6lc_hyp_pkg::hyp_lat_class_e [NP-1:0] alloc_lat;
  // hyp8 g7: the bank needs the raw FU class for the arb resource gate.
  logic [NP-1:0][3:0] alloc_fu;
  always_comb begin
    for (int unsigned p = 0; p < NP; p++) begin
      alloc_fu[p] = 4'(disp_sbe_i[p].fu);
      alloc_cls[p][C_LD]   = (disp_sbe_i[p].fu == g6lc_core_pkg::LOAD);
      alloc_cls[p][C_ST]   = (disp_sbe_i[p].fu == g6lc_core_pkg::STORE);
      alloc_cls[p][C_CSR]  = (disp_sbe_i[p].fu == g6lc_core_pkg::CSR);
      alloc_cls[p][C_CSYS] = (disp_sbe_i[p].fu == g6lc_core_pkg::CSR) &&
          !(disp_sbe_i[p].op inside {g6lc_core_pkg::CSR_READ,
                                     g6lc_core_pkg::CSR_WRITE,
                                     g6lc_core_pkg::CSR_SET,
                                     g6lc_core_pkg::CSR_CLEAR});
      alloc_cls[p][C_AMO]  = G6LCCfg.RVA &&
          (disp_sbe_i[p].fu == g6lc_core_pkg::STORE) &&
          g6lc_core_pkg::is_amo(disp_sbe_i[p].op);
      alloc_cls[p][C_CVXI] = G6LCCfg.CvxifEn &&
          (disp_sbe_i[p].fu == g6lc_core_pkg::CVXIF);
      alloc_cls[p][C_FP]   = G6LCCfg.FpPresent &&
          (disp_fpr_rs1_i[p] | disp_fpr_rs2_i[p] | disp_fpr_rs3_i[p]);
      alloc_lat[p] = ooo_lat_class(disp_sbe_i[p].fu, disp_sbe_i[p].op);
    end
  end

  // ----------------------------------------------------------------------
  // Bank steering: first fit starting at the lane's hint; lane 0 (oldest)
  // claims first. A group is admitted only if every lane fits (dispatch is
  // all-or-nothing), so disp_ack_o only asserts for a fully-placed group.
  // ----------------------------------------------------------------------
  logic [BANKS-1:0][FCNT_W-1:0] bank_free;
  logic [NP-1:0][BW-1:0]        asgn;
  logic                          group_fits;
  logic [BANKS-1:0][NP-1:0]     balloc;
  logic [BANKS-1:0][NP-1:0]     back;
  logic [BANKS-1:0][NP-1:0][EW-1:0] bslot;

  always_comb begin
    automatic int unsigned used [BANKS];
    automatic logic [NP-1:0] fits;
    for (int unsigned b = 0; b < BANKS; b++) used[b] = 0;
    asgn = '0;
    fits = '1;
    for (int unsigned p = 0; p < NP; p++) begin
      if (disp_valid_i[p]) begin
        automatic logic found;
        found = 1'b0;
        for (int unsigned k = 0; k < BANKS; k++) begin
          automatic int unsigned b;
          b = (int'(steer_hint_i[p]) + k) % BANKS;
          if (!found && (int'(bank_free[b]) > used[b])) begin
            asgn[p] = BW'(b);
            used[b] = used[b] + 1;
            found = 1'b1;
          end
        end
        if (!found) fits[p] = 1'b0;
      end
    end
    group_fits = &fits;
  end

  // ----------------------------------------------------------------------
  // Banks
  // ----------------------------------------------------------------------
  logic [BANKS-1:0][1:0]            cand_v;
  logic [BANKS-1:0][1:0][EW-1:0]    cand_i;
  logic [BANKS-1:0][1:0][TID_W-1:0] cand_tid;
  logic [BANKS-1:0][1:0]            cand_fp;
  logic [BANKS-1:0][1:0]            cand_spec;
  logic [BANKS-1:0][1:0][1:0]       cand_spec_ab;
  logic [BANKS-1:0][1:0][1:0][TID_W-1:0] cand_ptid;
  logic [BANKS-1:0][1:0][3:0]       cand_fu;
  logic [BANKS-1:0][1:0]            cand_fluin;
  logic [BANKS-1:0][1:0][1:0]       cand_wbport;
  logic [BANKS-1:0][1:0][4:0]       cand_wboff;
  logic [BANKS-1:0][1:0][3:0]       cand_gate;
  logic [BANKS-1:0][1:0]            cand_div;
  logic [BANKS-1:0][NP-1:0]         take_v;
  logic [BANKS-1:0][NP-1:0]         take_cand;
  logic [BANKS-1:0][NP-1:0]         aack;
  logic [BANKS-1:0][NP-1:0][EW-1:0] aack_idx;
  logic [BANKS-1:0][ENTRIES-1:0]    legal;
  logic [BANKS-1:0][NP-1:0]         bcast_v;
  logic [BANKS-1:0][NP-1:0][PRF_W-1:0]  bcast_prd;
  logic [BANKS-1:0][NP-1:0][FPRF_W-1:0] bcast_fprd;
  logic [BANKS-1:0][NP-1:0]         bcast_fp;
  logic [BANKS-1:0][NP-1:0][2:0]    bcast_cnt;
  // hyp8 g7: producer tid + ALU/low-half class flags ride the
  // broadcast/xbar so consumers can arm the in-ALU forward path.
  logic [BANKS-1:0][NP-1:0][TID_W-1:0] bcast_tid;
  logic [BANKS-1:0][NP-1:0]         bcast_alu, bcast_lo;
  logic [BANKS*NP-1:0]              xw_v;
  logic [BANKS*NP-1:0][PRF_W-1:0]   xw_prd;
  logic [BANKS*NP-1:0][FPRF_W-1:0]  xw_fprd;
  logic [BANKS*NP-1:0]              xw_fp;
  logic [BANKS*NP-1:0][2:0]         xw_cnt;
  logic [BANKS*NP-1:0][TID_W-1:0]   xw_tid;
  logic [BANKS*NP-1:0]              xw_alu, xw_lo;
  logic [BANKS-1:0][ENTRIES-1:0]    info_v;
  logic [BANKS-1:0][ENTRIES-1:0][TID_W-1:0] info_tid;
  logic [BANKS-1:0][ENTRIES-1:0][HID_W-1:0] info_hart;
  logic [BANKS-1:0][ENTRIES-1:0][6:0] info_cls;
  logic [BANKS-1:0][ENTRIES-1:0]    info_bypass;
  // hyp8 g10: rdy/prs exports for the top-level sim debug windows.
  logic [BANKS-1:0][ENTRIES-1:0][2:0]     info_rdy;
  logic [BANKS-1:0][ENTRIES-1:0][PRF_W-1:0] info_prs1;
  logic [BANKS-1:0][ENTRIES-1:0][PRF_W-1:0] info_prs2;
  // hyp8 g10: occupancy mirror for the emit's flat i_iq.count_q debug
  // references (occupancy = BANKS*ENTRIES - total free).
  logic [31:0]                         dbg_occ;
  logic [BANKS-1:0]                 csr_oldest_v, st_oldest_v;
  logic [BANKS-1:0][TID_W-1:0]      csr_oldest_tid, st_oldest_tid;
  logic [NP-1:0][HID_W-1:0]         alloc_hart;

  // Dispatch-side fields the bank ports do not carry directly.
  logic [NP-1:0][TID_W-1:0]  disp_tid;
  logic [NP-1:0][FPRF_W-1:0] disp_fprd;
  logic [NP-1:0]             disp_is_fprd;
  always_comb begin
    for (int unsigned p = 0; p < NP; p++) begin
      disp_tid[p]     = disp_sbe_i[p].trans_id;
      // The FP destination tag arrives in the scoreboard entry's p_frd
      // field (dispatch sets it at publish); fall back to the prd port so
      // integer-only configurations still elaborate.
      disp_fprd[p]    = FPRF_W'(disp_sbe_i[p].p_frd);
      disp_is_fprd[p] = G6LCCfg.FpPresent &&
                        g6lc_core_pkg::is_rd_fpr(disp_sbe_i[p].op);
    end
  end

  always_comb begin
    for (int unsigned p = 0; p < NP; p++)
      alloc_hart[p] = HID_W'(disp_sbe_i[p].hart_id);
    for (int unsigned b = 0; b < BANKS; b++) begin
      for (int unsigned p = 0; p < NP; p++)
        balloc[b][p] = disp_valid_i[p] && group_fits && (asgn[p] == BW'(b));
    end
    // Acknowledge the steered bank's acceptance, gated by the group fit.
    for (int unsigned p = 0; p < NP; p++) begin
      disp_ack_o[p] = 1'b0;
      for (int unsigned b = 0; b < BANKS; b++)
        if (asgn[p] == BW'(b)) disp_ack_o[p] = back[b][p];
      disp_ack_o[p] = disp_ack_o[p] && group_fits;
    end
  end

  for (genvar b = 0; b < BANKS; b++) begin : gen_bank
    g6lc_iq_bank #(
        .G6LCCfg  (G6LCCfg),
        .HypCfg   (HypCfg),
        .ENTRIES  (ENTRIES),
        .PRF_W    (PRF_W),
        .FPRF_W   (FPRF_W),
        .NR_WB    (NR_WB),
        .NR_FWB   (NR_WB),
        .TID_W    (TID_W),
        .NLANES   (NP),
        .NTAKE    (NP),
        .NXW      (BANKS*NP),
        .HID_W    (HID_W)
    ) i_bank (
        .clk_i, .rst_ni, .flush_i,
        .cancelled_mask_i,
        .alloc_i          (balloc[b]),
        .alloc_cls_i      (alloc_cls),
        .alloc_lat_i      (alloc_lat),
        .alloc_fu_i       (alloc_fu),
        .alloc_tid_i      (disp_tid),
        .alloc_hart_i     (alloc_hart),
        .alloc_prs1_i     (disp_prs1_i),
        .alloc_prs2_i     (disp_prs2_i),
        .alloc_prd_i      (disp_prd_i),
        .alloc_fprs1_i    (disp_fprs1_i),
        .alloc_fprs2_i    (disp_fprs2_i),
        .alloc_fprs3_i    (disp_fprs3_i),
        .alloc_fprd_i     (disp_fprd),
        .alloc_fpr_rs1_i  (disp_fpr_rs1_i),
        .alloc_fpr_rs2_i  (disp_fpr_rs2_i),
        .alloc_fpr_rs3_i  (disp_fpr_rs3_i),
        .alloc_is_fprd_i  (disp_is_fprd),
        .alloc_may_bypass_i(disp_may_bypass_i),
        .alloc_rs1_rdy_i  (disp_rs1_ready_i),
        .alloc_rs2_rdy_i  (disp_rs2_ready_i),
        .alloc_rs3_rdy_i  (disp_rs3_ready_i),
        .alloc_ack_o      (back[b]),
        .alloc_slot_o     (bslot[b]),
        .free_cnt_o       (bank_free[b]),
        .wb_valid_i, .wb_prd_i, .fwb_valid_i, .fwb_prd_i,
        .xw_v_i    (xw_v),
        .xw_prd_i  (xw_prd),
        .xw_fprd_i (xw_fprd),
        .xw_fp_i   (xw_fp),
        .xw_cnt_i  (xw_cnt),
        .xw_tid_i  (xw_tid),
        .xw_alu_i  (xw_alu),
        .xw_lo_i   (xw_lo),
        .bcast_v_o   (bcast_v[b]),
        .bcast_prd_o (bcast_prd[b]),
        .bcast_fprd_o(bcast_fprd[b]),
        .bcast_fp_o  (bcast_fp[b]),
        .bcast_cnt_o (bcast_cnt[b]),
        .bcast_tid_o (bcast_tid[b]),
        .bcast_alu_o (bcast_alu[b]),
        .bcast_lo_o  (bcast_lo[b]),
        .legal_i     (legal[b]),
        .cand_v_o    (cand_v[b]),
        .cand_i_o    (cand_i[b]),
        .cand_tid_o  (cand_tid[b]),
        .cand_fp_o   (cand_fp[b]),
        .cand_spec_o (cand_spec[b]),
        .cand_spec_ab_o(cand_spec_ab[b]),
        .cand_ptid_o (cand_ptid[b]),
        .cand_fu_o   (cand_fu[b]),
        .cand_fluin_o(cand_fluin[b]),
        .cand_wbport_o(cand_wbport[b]),
        .cand_wboff_o(cand_wboff[b]),
        .cand_gate_o (cand_gate[b]),
        .cand_div_o  (cand_div[b]),
        .take_v_i    (take_v[b]),
        .take_cand_i (take_cand[b]),
        .ack_v_i     (aack[b]),
        .ack_idx_i   (aack_idx[b]),
        .replay_i    (replay_valid_i),
        .info_v_o    (info_v[b]),
        .info_tid_o  (info_tid[b]),
        .info_hart_o (info_hart[b]),
        .info_cls_o  (info_cls[b]),
        .info_bypass_o(info_bypass[b]),
        .info_rdy_o    (info_rdy[b]),
        .info_prs1_o   (info_prs1[b]),
        .info_prs2_o   (info_prs2[b]),
        .csr_oldest_v_o  (csr_oldest_v[b]),
        .csr_oldest_tid_o(csr_oldest_tid[b]),
        .st_oldest_v_o   (st_oldest_v[b]),
        .st_oldest_tid_o (st_oldest_tid[b])
    );
  end

  // ----------------------------------------------------------------------
  // Cross-bank wakeup interconnect (+1)
  // ----------------------------------------------------------------------
  g6lc_iq_xbar #(
      .BANKS (BANKS),
      .NTAKE (NP),
      .PRF_W (PRF_W),
      .FPRF_W(FPRF_W),
      .TID_W (TID_W)
  ) i_xbar (
      .clk_i, .rst_ni, .flush_i,
      .b_v_i    (bcast_v),
      .b_prd_i  (bcast_prd),
      .b_fprd_i (bcast_fprd),
      .b_fp_i   (bcast_fp),
      .b_cnt_i  (bcast_cnt),
      .b_tid_i  (bcast_tid),
      .b_alu_i  (bcast_alu),
      .b_lo_i   (bcast_lo),
      .xw_v_o   (xw_v),
      .xw_prd_o (xw_prd),
      .xw_fprd_o(xw_fprd),
      .xw_fp_o  (xw_fp),
      .xw_cnt_o (xw_cnt),
      .xw_tid_o (xw_tid),
      .xw_alu_o (xw_alu),
      .xw_lo_o  (xw_lo)
  );

  // ----------------------------------------------------------------------
  // Registered legality
  // ----------------------------------------------------------------------
  g6lc_iq_legal #(
      .G6LCCfg(G6LCCfg),
      .BANKS  (BANKS),
      .ENTRIES(ENTRIES),
      .TID_W  (TID_W),
      .HID_W  (HID_W),
      .NH     (NH)
  ) i_legal (
      .clk_i, .rst_ni, .flush_i,
      .info_v_i           (info_v),
      .info_tid_i         (info_tid),
      .info_hart_i        (info_hart),
      .info_cls_i         (info_cls),
      .info_bypass_i      (info_bypass),
      .csr_oldest_v_i     (csr_oldest_v),
      .csr_oldest_tid_i   (csr_oldest_tid),
      .st_oldest_v_i      (st_oldest_v),
      .st_oldest_tid_i    (st_oldest_tid),
      .commit_ptr_i       (commit_ptr_i),
      .st_unresolved_mask_i(st_unresolved_mask_i),
      .st_hart_mask_i     (st_hart_mask_i),
      .mem_stall_i        (mem_stall_i),
      .legal_o            (legal)
  );

  // ----------------------------------------------------------------------
  // Payload array: written at allocation on the steered bank's slot index,
  // read the cycle after the arb grant.
  // ----------------------------------------------------------------------
  logic [NP-1:0][BW-1:0] pay_bank;
  logic [NP-1:0][EW-1:0] pay_entry;
  scoreboard_entry_t [NP-1:0] pay_sbe;
  logic [NP-1:0][31:0]   pay_orig;
  logic [NP-1:0][PRF_W-1:0] pay_prd;

  logic [NP-1:0][BW-1:0] wr_bank;
  logic [NP-1:0][EW-1:0] wr_entry;
  always_comb begin
    for (int unsigned p = 0; p < NP; p++) begin
      wr_bank[p]  = asgn[p];
      wr_entry[p] = '0;
      for (int unsigned b = 0; b < BANKS; b++)
        if (asgn[p] == BW'(b)) wr_entry[p] = bslot[b][p];
    end
  end

  g6lc_iq_payload #(
      .BANKS  (BANKS),
      .ENTRIES(ENTRIES),
      .PRF_W  (PRF_W),
      .NLANES (NP),
      .NPORTS (NP),
      .scoreboard_entry_t(scoreboard_entry_t)
  ) i_payload (
      .clk_i, .rst_ni,
      .wr_v_i    ({NP{group_fits}} & disp_valid_i),
      .wr_bank_i (wr_bank),
      .wr_entry_i(wr_entry),
      .wr_sbe_i  (disp_sbe_i),
      .wr_orig_i (disp_orig_i),
      .wr_prd_i  (disp_prd_i),
      .rd_bank_i (pay_bank),
      .rd_entry_i(pay_entry),
      .rd_sbe_o  (pay_sbe),
      .rd_orig_o (pay_orig),
      .rd_prd_o  (pay_prd)
  );

  // ----------------------------------------------------------------------
  // Arbiter: candidate registers -> pair merge -> port select -> take/ack
  // ----------------------------------------------------------------------
  g6lc_iq_arb #(
      .G6LCCfg(G6LCCfg),
      .BANKS  (BANKS),
      .ENTRIES(ENTRIES),
      .TID_W  (TID_W),
      .PRF_W  (PRF_W),
      .NPORTS (NP),
      .scoreboard_entry_t(scoreboard_entry_t)
  ) i_arb (
      .clk_i, .rst_ni, .flush_i,
      .cancelled_mask_i,
      .commit_ptr_i,
      .cand_v_i   (cand_v),
      .cand_i_i   (cand_i),
      .cand_tid_i (cand_tid),
      .cand_fp_i  (cand_fp),
      .cand_spec_i(cand_spec),
      .cand_spec_ab_i(cand_spec_ab),
      .cand_ptid_i(cand_ptid),
      .cand_fluin_i(cand_fluin),
      .cand_wbport_i(cand_wbport),
      .cand_wboff_i(cand_wboff),
      .cand_gate_i(cand_gate),
      .cand_div_i (cand_div),
      .lsu_ready_i, .fpu_ready_i, .csr_ready_i, .mult_ready_i,
      .pay_bank_o (pay_bank),
      .pay_entry_o(pay_entry),
      .pay_sbe_i  (pay_sbe),
      .pay_orig_i (pay_orig),
      .pay_prd_i  (pay_prd),
      .issue_sbe_o, .issue_orig_o, .issue_prd_o, .issue_valid_o,
      .issue_spec_o,
      .issue_spec_ab_o, .issue_ptid_o,
      .issue_ack_i,
      .hyp_wb_reserve_stall_o,
      .take_v_o   (take_v),
      .take_cand_o(take_cand),
      .ack_v_o    (aack),
      .ack_idx_o  (aack_idx)
  );

  // ----------------------------------------------------------------------
  // Occupancy
  // ----------------------------------------------------------------------
  always_comb begin
    automatic int unsigned tot;
    tot = 0;
    for (int unsigned b = 0; b < BANKS; b++) tot += int'(bank_free[b]);
    // can_go's all-or-nothing check uses only the registered counts, exactly
    // as the flat queue's count register did; the actual placement is the
    // first-fit above, gated into disp_ack_o.
    full_o = (tot < NP);
    empty_o = (tot == int'(BANKS) * int'(ENTRIES));
    // hyp8 g10: flat-occupancy mirror read by the top-level sim windows.
    dbg_occ = int'(BANKS) * int'(ENTRIES) - tot;
  end

  // st_live_mask_i / sb_live_i are observability-only inputs carried over
  // from the unbanked queue (its liveness assertions lived at its tail);
  // they are intentionally unreferenced here pending the assertion port.

endmodule
