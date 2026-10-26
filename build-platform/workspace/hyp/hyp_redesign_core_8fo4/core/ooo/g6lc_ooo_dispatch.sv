// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5 production OoO dispatch (config-gated; OoOEn=0 is netlist identity):
// staged rename + banked IQ + ROB + LSQ/CAM + PRF operands for the IRO
// cutover + live AGU.
//
// Recovery timeline (FSE S3 -- single ordering for mispredict vs full flush):
//   1. Same cycle as branch resolve mispredict:
//        - controller: flush_if + flush_unissued (not full flush_i)
//        - scoreboard: SpeculativeSb cancels younger TIDs -> cancelled_mask_i
//        - rename: mispredict_i restores map/free/busy from branch ckpt
//          (registered select, repair next cycle -- the rename pipe is empty
//          by then because no group can be in flight across a mispredict)
//        - IQ / ROB / LSQ: squash entries whose TID is in cancelled_mask_i
//        - PRF: WB gated by !cancelled_mask[wb_tid]
//        - memdep: flush_i | mispredict_i clears store-set table
//   2. Exception / fence / CSR side-effect:
//        - controller asserts flush_i (and more) -> full structure clear
//        - rename full reset; IQ/ROB/LSQ flush_i; memdep flush
//   3. commit_drop retires cancelled SB slots without architectural write.
//
// hyp8 (group 4/5, analysis/t1_rest.md g6lc_ooo_dispatch, cut_minimization
// "g6lc_ooo_dispatch"): two departures from the emit base, both rank 2/4
// front-end-depth cuts, neither touching architectural semantics:
//   A. The rename group is registered. can_go still derives from
//      registered counts only; the group now enters g6lc_rename's R1
//      stage, and the dispatch-side record (tagged sbe + orig +
//      classification) is latched on the rename's group_valid_o strobe.
//      IQ/ROB/LSQ allocation and the tid_* side tables are written at the
//      registered group's accept, so ROB/rename/LSQ allocation stays
//      contiguous, in-order and recoverable exactly as before -- just two
//      cycles later.
//   B. The IQ presents registered candidates. Dispatch stages each
//      presented candidate one cycle (iss_q) while the PRF does its
//      2-step read, so issue_sbe_o/issue_orig_o and issue_op_* are all
//      registered-derived -- the rank-2 replacement for the IRO operand
//      latch. The FP read-port reservation lives in the IQ arbiter; the
//      legacy fp_port_sel mux still runs at take time so the FP file's
//      three read ports are driven correctly.
//   The dispatch-time memdep query (port 0) is unchanged: the predictor's
//      verdict is now registered inside g6lc_memdep and is sampled into
//      the group record at publish. No issue-time combinational predictor
//      feedback exists.

module g6lc_ooo_dispatch
  import g6lc_core_pkg::*;
  import g6lc_ooo_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    // hyp8: staged rename / banked IQ configuration.
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8,
    parameter type scoreboard_entry_t = logic
) (
    input  logic clk_i,
    input  logic rst_ni,
    input logic [1:0] phys_valid_i,
    input logic [1:0][G6LCCfg.PLEN-1:0] phys_addr_i,
    input logic [1:0][G6LCCfg.TRANS_ID_BITS-1:0] phys_id_i,
    input logic [1:0][$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] phys_hart_i,
    input logic [1:0][1:0] phys_size_i,
    input logic [1:0] mod_valid_i,
    input logic [1:0][G6LCCfg.PLEN-1:0] mod_addr_i,
    output logic [G6LCCfg.NR_SB_ENTRIES-1:0] phys_pending_o,
    output logic [G6LCCfg.NR_SB_ENTRIES-1:0] phys_replay_o,
    input  logic flush_i,
    input  logic flush_unissued_i,
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0]                   cancelled_mask_i,
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0]                   sb_live_i,
    input  scoreboard_entry_t [G6LCCfg.NrIssuePorts-1:0]       dispatch_sbe_i,
    input  logic              [G6LCCfg.NrIssuePorts-1:0][31:0] dispatch_orig_i,
    input  logic              [G6LCCfg.NrIssuePorts-1:0]       dispatch_valid_i,
    output logic              [G6LCCfg.NrIssuePorts-1:0]       dispatch_ack_o,
    output scoreboard_entry_t [G6LCCfg.NrIssuePorts-1:0]       issue_sbe_o,
    output logic              [G6LCCfg.NrIssuePorts-1:0][31:0] issue_orig_o,
    output logic              [G6LCCfg.NrIssuePorts-1:0]       issue_valid_o,
    input  logic              [G6LCCfg.NrIssuePorts-1:0]       issue_ack_i,
    // hyp8 g7: per-operand spec-arm bits + ALU-class producer tids of the
    // staged issue record (drives the in-ALU forward select in the IRO).
    output logic              [G6LCCfg.NrIssuePorts-1:0][1:0]  issue_spec_ab_o,
    output logic              [G6LCCfg.NrIssuePorts-1:0][1:0][G6LCCfg.TRANS_ID_BITS-1:0] issue_ptid_o,
    // hyp8 g7: FU ready status for the IQ arb take-gate -- a spec-broadcast
    // producer must never stall between the IQ grant and the FU input
    // registers, so the grant is gated on the ready line itself.
    input  logic                                             lsu_ready_i,
    input  logic                                             fpu_ready_i,
    input  logic                                             csr_ready_i,
    input  logic                                             mult_ready_i,
    // hyp8 r33: CSR address-table credit (free entries after the buffer's
    // sweeps). A group is consumed only when the table can hold every
    // CSR-class lane it carries — a resource released in commit order is
    // allocated in program order, so the group waits, never partially.
    input  logic [1:0]                                         csr_credit_i,
    // Allocation strobes for csr_buffer: one per lane the cycle the lane
    // is consumed into the IQ (dispatch_ack_o && CSR class).
    output logic [G6LCCfg.NrIssuePorts-1:0]                      csr_disp_valid_o,
    output logic [G6LCCfg.NrIssuePorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] csr_disp_tid_o,
    output logic [G6LCCfg.NrIssuePorts-1:0][11:0]                  csr_disp_addr_o,
    output logic [G6LCCfg.NrIssuePorts-1:0][G6LCCfg.XLEN-1:0] issue_op_a_o,
    output logic [G6LCCfg.NrIssuePorts-1:0][G6LCCfg.XLEN-1:0] issue_op_b_o,
    output logic [G6LCCfg.NrIssuePorts-1:0]                   issue_op_a_valid_o,
    output logic [G6LCCfg.NrIssuePorts-1:0]                   issue_op_b_valid_o,
    output logic [G6LCCfg.NrIssuePorts-1:0][G6LCCfg.FLen-1:0] issue_op_c_o,
    output logic [G6LCCfg.NrIssuePorts-1:0]                   issue_op_c_valid_o,
    input  logic [G6LCCfg.NrWbPorts-1:0]                            wb_valid_i,
    input  logic [G6LCCfg.NrWbPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] wb_id_i,
    input  logic [G6LCCfg.NrWbPorts-1:0][G6LCCfg.XLEN-1:0]          wb_data_i,
    input  logic [G6LCCfg.NrWbPorts-1:0]                            wb_exc_i,
    input  logic [G6LCCfg.NrCommitPorts-1:0]                        commit_we_i,
    input  logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.XLEN-1:0]      commit_wdata_i,
    input  logic [G6LCCfg.NrCommitPorts-1:0]                        commit_ack_i,
    input  scoreboard_entry_t [G6LCCfg.NrCommitPorts-1:0]           commit_instr_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0]                        commit_ptr_i,
    input  logic                                                    mispredict_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0]                        mispredict_id_i,
    output logic freelist_empty_o,
    output logic rob_full_o,
    output logic iq_full_o,
    output logic ooo_drained_o,
    output logic lsq_stall_o,
    output logic rename_stall_o,
    output logic stl_forward_o,
    output logic mem_violation_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0]             mem_violation_id_o,
    // hyp8: LSQ checked bits — a load may publish only once its verdict
    // is final (group 8/9). Routed to scoreboard.ld_checked_i through
    // issue_stage/g6lc_core in the group-10 integration.
    output logic [G6LCCfg.NR_SB_ENTRIES-1:0]             ld_checked_o,
    // hyp8 g10: LSU-side replay (load-unit replay_o/replay_tid_o routed
    // through issue_stage). Merged with the LSQ violation pulse into the
    // IQ re-arm broadcast below; a losing tid queues in rp_mask_q.
    input  logic                                       lsu_replay_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0]           lsu_replay_tid_i,
    // hyp8 H27: perf pulse — IQ arb take-gate declined a selected ready
    // candidate only for a WB/FLU reservation slot.
    output logic                                       hyp_wb_reserve_stall_o
);

  localparam int unsigned ROB_N = (G6LCCfg.RobEntries == 0) ? G6LCCfg.NR_SB_ENTRIES
                                                            : G6LCCfg.RobEntries;
  localparam int unsigned NH = G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts;
  localparam int unsigned HID_W = NH <= 1 ? 1 : $clog2(NH);
  localparam int unsigned PRF_N = (G6LCCfg.PrfEntries == 0) ? (1 + 31 * NH + ROB_N + 8)
                                                            : G6LCCfg.PrfEntries;
  localparam int unsigned IQ_N  = (G6LCCfg.IqEntries == 0) ? ROB_N : G6LCCfg.IqEntries;
  localparam int unsigned LD_N  = (G6LCCfg.LsqLoadEntries == 0) ? 8 : G6LCCfg.LsqLoadEntries;
  localparam int unsigned ST_N  = (G6LCCfg.LsqStoreEntries == 0) ? 8 : G6LCCfg.LsqStoreEntries;
  localparam int unsigned PRF_W = ooo_prf_w(PRF_N);
  localparam int unsigned FPRF_N = G6LCCfg.FpPresent ? (32 * NH + ROB_N + 8) : 1;
  localparam int unsigned FPRF_W = G6LCCfg.FpPresent ? ooo_prf_w(FPRF_N) : 1;
  localparam int unsigned ROB_W = ooo_rob_w(ROB_N);
  localparam int unsigned CKPT  = (G6LCCfg.BPCkptDepth == 0) ? 8 : G6LCCfg.BPCkptDepth;
  localparam int unsigned NP    = G6LCCfg.NrIssuePorts;

  localparam int unsigned CKPT_W = $clog2(CKPT+1);
  localparam int unsigned PRF_MIRROR =
      (G6LCCfg.RVZacas && G6LCCfg.NrCommitPorts > 1) ? 2 : 1;
  localparam int unsigned DATA_WB_NR = G6LCCfg.NrWbPorts + PRF_MIRROR;
  localparam int unsigned NB   = (HypCfg.IqBanks < 1) ? 1 : HypCfg.IqBanks;
  localparam int unsigned BW   = (NB > 1) ? $clog2(NB) : 1;

  // Elaboration guards, not simulation assertions. The legality checks in
  // config_pkg::check_cfg sit under `pragma translate_off`, so an unsound
  // configuration still ELABORATES AND SYNTHESISES and only complains in
  // simulation. Refuse to build instead. These are duplicated in check_cfg;
  // both copies must move together.
  // Integer multi-hart OoO is legal under the drained handoff; FP under
  // mixed residency is legal since FP-2 -- see the emit-base comment for the
  // full qualification history.
  if (ST_N > ooo_spec_store_depth(G6LCCfg)) begin : gen_err_ooo_st_credits
    $error("LSQ store credits exceed the speculative store queue: reservation unsound");
  end

  logic [NP-1:0] need_rd, is_br, is_ld, is_st;
  logic [NP-1:0][HID_W-1:0] dispatch_hart;
  logic [G6LCCfg.NrCommitPorts-1:0][HID_W-1:0] commit_hart;

  if (PRF_N < 1 + 31 * NH || PRF_W > 8 || FPRF_W > 8 || CKPT < NH) begin : gen_err_ooo_geometry
    $error("OoO physical pool or checkpoint geometry cannot represent every hart.");
  end

  // Raw IQ presentation, before the dispatch-side staging + FP read-port
  // mux below.
  logic [NP-1:0] iqi_valid, iqi_take, iq_issue_ack;
  logic [NP-1:0][4:0] rs1_a, rs2_a, rd_a, rs3_a;
  logic [NP-1:0] is_fpr_rd_c, is_fpr_rs1_c, is_fpr_rs2_c, is_fpr_rs3_c;
  logic [NP-1:0][FPRF_W-1:0] fprs1, fprs2, fprs3, fprd, fprd_old;
  logic ren_stall, can_go, lsq_disp_block, lsq_grp_block;
  logic [NP-1:0][PRF_W-1:0] prs1, prs2, prd, prd_old;
  logic [NP-1:0][CKPT_W-1:0] ren_ckpt_id;
  logic [NP-1:0] ren_group_valid;
  logic [G6LCCfg.NrWbPorts-1:0][PRF_W-1:0] wb_prd;
  logic [G6LCCfg.NR_SB_ENTRIES-1:0][PRF_W-1:0] tid_prd_q, tid_prd_d;
  logic [G6LCCfg.NR_SB_ENTRIES-1:0][PRF_W-1:0] tid_old_q, tid_old_d;
  logic [G6LCCfg.NR_SB_ENTRIES-1:0] tid_is_st_q, tid_is_st_d;
  logic [G6LCCfg.NR_SB_ENTRIES-1:0] tid_late_result_q, tid_late_result_d;
  logic [DATA_WB_NR-1:0] data_wb_valid, fdata_wb_valid;
  logic [DATA_WB_NR-1:0][PRF_W-1:0] data_wb_prd;
  logic [DATA_WB_NR-1:0][FPRF_W-1:0] fdata_wb_prd;
  logic [G6LCCfg.NR_SB_ENTRIES-1:0] tid_is_fpr_q, tid_is_fpr_d;
  logic [G6LCCfg.NR_SB_ENTRIES-1:0][FPRF_W-1:0] tid_fprd_q, tid_fprd_d;
  logic [G6LCCfg.NR_SB_ENTRIES-1:0][FPRF_W-1:0] tid_fold_q, tid_fold_d;
  logic [G6LCCfg.NrWbPorts-1:0][FPRF_W-1:0] fwb_prd;
  logic [G6LCCfg.NrWbPorts-1:0] fwb_value_valid;
  logic [G6LCCfg.NR_SB_ENTRIES-1:0][CKPT_W-1:0] tid_ckpt_q, tid_ckpt_d;

  for (genvar p = 0; p < NP; p++) begin : gen_ports
    assign dispatch_hart[p] = NH > 1 ? HID_W'(dispatch_sbe_i[p].hart_id) : '0;
    assign rs1_a[p] = dispatch_sbe_i[p].rs1[4:0];
    assign rs2_a[p] = dispatch_sbe_i[p].rs2[4:0];
    assign rd_a[p]  = dispatch_sbe_i[p].rd;
    // There is no rs3 field: FP compute ops carry the third register number in
    // result[4:0] (is_imm_fpr covers FADD:FSUB as well as FMADD:FNMADD). The
    // overload is disjoint by FU -- the AGU below reads result as the immediate
    // only for LOAD/STORE, and FP loads are is_rd_fpr without being is_imm_fpr.
    assign rs3_a[p] = dispatch_sbe_i[p].result[4:0];
    assign is_fpr_rd_c[p]  = G6LCCfg.FpPresent && is_rd_fpr(dispatch_sbe_i[p].op);
    assign is_fpr_rs1_c[p] = G6LCCfg.FpPresent && is_rs1_fpr(dispatch_sbe_i[p].op);
    assign is_fpr_rs2_c[p] = G6LCCfg.FpPresent && is_rs2_fpr(dispatch_sbe_i[p].op);
    assign is_fpr_rs3_c[p] = G6LCCfg.FpPresent && is_imm_fpr(dispatch_sbe_i[p].op);
    assign need_rd[p] = dispatch_valid_i[p] &&
                        (is_fpr_rd_c[p] ? 1'b1 : (rd_a[p] != 5'd0));
    assign is_br[p] = dispatch_valid_i[p] && (dispatch_sbe_i[p].fu == CTRL_FLOW);
    assign is_ld[p] = dispatch_valid_i[p] && (dispatch_sbe_i[p].fu == LOAD);
    assign is_st[p] = dispatch_valid_i[p] && (dispatch_sbe_i[p].fu == STORE);
  end

  logic rob_full, iq_full, ld_full, st_full;
  logic rob_empty, iq_empty;
  logic [$clog2(G6LCCfg.LsqLoadEntries+1)-1:0] ld_free;
  logic [$clog2(G6LCCfg.LsqStoreEntries+1)-1:0] st_free;
  logic store_pend, stl_fwd, stl_stall, lsq_busy, mem_stall;
  logic [NP-1:0] md_stall_v, md_predict_v;
  logic [G6LCCfg.NR_SB_ENTRIES-1:0] st_live_mask, st_unresolved_mask;
  logic [NH-1:0][G6LCCfg.NR_SB_ENTRIES-1:0] st_hart_mask;
  logic [G6LCCfg.VLEN-1:0] mem_violation_pc;
  logic [NP-1:0] may_bypass;

  // ----------------------------------------------------------------------
  // hyp8: the registered rename group. The scoreboard holds the group on
  // the input until dispatch_ack_o; rename takes it when can_go permits
  // (enable_i), the group_valid_o strobe announces the resolved record two
  // cycles later, and grp_q then drives IQ/ROB/LSQ allocation.
  // grp_pend_q covers the rename-pipe occupancy; grp_v_q covers the
  // latched record awaiting its alloc edge. Both are bookkeeping copies --
  // the state that matters lives in g6lc_rename's own stages.
  // ----------------------------------------------------------------------
  logic                    grp_pend_q;
  logic [NP-1:0]           grp_v_q;
  scoreboard_entry_t [NP-1:0] grp_sbe_q;
  logic [NP-1:0][31:0]     grp_orig_q;
  logic [NP-1:0][PRF_W-1:0] grp_prs1_q, grp_prs2_q, grp_prd_q;
  // Allocation readiness comes from rename's CURRENT busy bitmaps looked
  // up by the final held-group physical tags -- a WB that lands between
  // R1 capture and IQ allocation is visible here; the R1 ready snapshot
  // is not consulted at this seam.
  logic [PRF_N-1:0]        ren_int_busy;
  logic [FPRF_N-1:0]       ren_fp_busy;
  logic [NP-1:0]           grp_rs1_ready, grp_rs2_ready, grp_rs3_ready;
  for (genvar p = 0; p < NP; p++) begin : gen_group_ready
    assign grp_rs1_ready[p] = grp_is_fpr_rs1_q[p]
        ? !ren_fp_busy[grp_fprs1_q[p]] : !ren_int_busy[grp_prs1_q[p]];
    assign grp_rs2_ready[p] = grp_is_fpr_rs2_q[p]
        ? !ren_fp_busy[grp_fprs2_q[p]] : !ren_int_busy[grp_prs2_q[p]];
    assign grp_rs3_ready[p] = !grp_is_fpr_rs3_q[p] ||
                              !ren_fp_busy[grp_fprs3_q[p]];
  end
  logic [NP-1:0][FPRF_W-1:0] grp_fprs1_q, grp_fprs2_q, grp_fprs3_q;
  logic [NP-1:0][FPRF_W-1:0] grp_fprd_q;
  logic [NP-1:0]           grp_is_fpr_rs1_q, grp_is_fpr_rs2_q, grp_is_fpr_rs3_q;
  logic [NP-1:0][CKPT_W-1:0] grp_ckpt_q;
  logic [NP-1:0]           grp_may_bypass_q;
  logic [NP-1:0]           grp_is_st_q, grp_is_ld_q, grp_is_br_q;
  logic [NP-1:0]           grp_is_fpr_rd_q;

  logic ren_capture, ren_pub;
  assign ren_capture = can_go && (|dispatch_valid_i);
  assign ren_pub     = |ren_group_valid;

  // Allocation of the latched group: all-or-nothing, re-evaluated at
  // publish time against registered counts exactly as can_go was.
  // hyp8: balanced popcounts instead of serial accumulates. The need
  // count sits in the free counter's own unsigned width so the capacity
  // compare is a plain same-width unsigned relation.
  localparam int unsigned LDW = $clog2(G6LCCfg.LsqLoadEntries+1);
  localparam int unsigned STW = $clog2(G6LCCfg.LsqStoreEntries+1);
  logic [LDW-1:0] need_ld, grp_need_ld;
  logic [STW-1:0] need_st, grp_need_st;
  // r42-T item 21: legality predecoded at ren_pub — grp_go reads these
  // registered counts instead of same-cycle popcounts over the group
  // registers. Stale after a kill/consume, but grp_go then reads
  // grp_v_q==0 (or the kill terms), so they are unobservable there.
  logic [LDW-1:0]          grp_need_ld_q;
  logic [STW-1:0]          grp_need_st_q;
  logic [1:0]              grp_csr_need_q;
  assign need_ld      = LDW'($countones(is_ld));
  assign need_st      = STW'($countones(is_st));
`ifdef G6LC_MUT_T2_DISP_GRPGO
  // Review mutant: the pre-r42 same-cycle popcounts on grp_go's cone.
  assign grp_need_ld  = LDW'($countones(grp_is_ld_q));
  assign grp_need_st  = STW'($countones(grp_is_st_q));
`else
  // r42-T item 21: the held group's LSQ demand and CSR credit need are
  // predecoded at the ren_pub edge — grp_go's grant cone reads
  // registered counts against the live free counters; kill still
  // dominates as the last AND in grp_go (and through grp_v_q itself).
  assign grp_need_ld  = grp_need_ld_q;
  assign grp_need_st  = grp_need_st_q;
`endif
  assign lsq_disp_block = (need_ld > ld_free) || (need_st > st_free);
  assign lsq_grp_block  = (grp_need_ld > ld_free) || (grp_need_st > st_free);

  // can_go: registered counts only, plus "no group already in flight".
  assign can_go = !rob_full && !iq_full && !ren_stall && !flush_i &&
                  !flush_unissued_i && !lsq_disp_block &&
                  !grp_pend_q && !(|grp_v_q);
  assign rename_stall_o = (|dispatch_valid_i) && !can_go;
  assign freelist_empty_o = ren_stall;
  assign rob_full_o = rob_full;
  assign iq_full_o  = iq_full;
  assign ooo_drained_o = rob_empty && iq_empty && !lsq_busy && !grp_pend_q &&
                        !(|grp_v_q);
  assign stl_forward_o = stl_fwd;

  logic grp_go;
  logic [NP-1:0] iqdisp_ack;
  // r33: CSR-class lanes of the held group (same predicate as
  // alloc_cls[C_CSR]: fu == CSR covers MRET/WFI/fences/system CSRs). The
  // group is consumed only when the address table can hold every CSR
  // lane — kill-dominates ordering and the all-or-nothing ack are
  // untouched: a credit-short group simply waits in grp_v_q.
  logic [NP-1:0] grp_csr;
  logic [1:0]    csr_need;
  for (genvar p = 0; p < NP; p++) begin : gen_grp_csr
    assign grp_csr[p] = grp_v_q[p] && (grp_sbe_q[p].fu == CSR);
  end
`ifdef G6LC_MUT_T2_DISP_GRPGO
  assign csr_need = 2'($countones(grp_csr));
`else
  assign csr_need = grp_csr_need_q;
`endif
  assign grp_go = (|grp_v_q) && !rob_full && !iq_full && !lsq_grp_block &&
                  !flush_i && !flush_unissued_i &&
                  (csr_credit_i >= csr_need);
  // The scoreboard consumes the group when the IQ confirms the whole
  // placement -- disp_ack_o on the IQ is already all-or-nothing over the
  // lanes it is shown (dead lanes stay off the bus and need no ack).
  assign dispatch_ack_o = iqdisp_ack & grp_v_q & {NP{grp_go}};
  // Program-order table ownership: the consume strobes carry the held
  // lane's trans_id and the CSR immediate the decoder left in result.
  for (genvar p = 0; p < NP; p++) begin : gen_csr_disp
    assign csr_disp_valid_o[p] = dispatch_ack_o[p] && grp_csr[p];
    assign csr_disp_tid_o[p]   = grp_tid[p];
    assign csr_disp_addr_o[p]  = grp_sbe_q[p].result[11:0];
  end
  // The group retires when every LIVE lane was acknowledged.
  logic grp_done;
  assign grp_done = &(iqdisp_ack | ~grp_v_q) && (|grp_v_q);

  // ----------------------------------------------------------------------
  // WB gating (unchanged from the emit base).
  // ----------------------------------------------------------------------
  logic [G6LCCfg.NrWbPorts-1:0] wb_value_valid;
  // hyp8: per-port independent assigns (no serial loop billing).
  for (genvar w = 0; w < G6LCCfg.NrWbPorts; w++) begin : gen_wb_tag
    assign wb_prd[w]  = tid_prd_q[wb_id_i[w]];
    assign fwb_prd[w] = tid_fprd_q[wb_id_i[w]];
    // One writeback bus, two files: the destination class decides which
    // busy table the completion clears.
    assign wb_value_valid[w] =
        wb_valid_i[w] && !wb_exc_i[w] &&
        !cancelled_mask_i[wb_id_i[w]] && !tid_is_fpr_q[wb_id_i[w]] &&
        !tid_late_result_q[wb_id_i[w]];
    assign fwb_value_valid[w] =
        G6LCCfg.FpPresent && wb_valid_i[w] && !wb_exc_i[w] &&
        !cancelled_mask_i[wb_id_i[w]] && tid_is_fpr_q[wb_id_i[w]];
  end

  // Multi-port freelist free on all commit ports
  logic [G6LCCfg.NrCommitPorts-1:0] free_en;
  logic [G6LCCfg.NrCommitPorts-1:0][PRF_W-1:0] free_prd;
  logic [G6LCCfg.NrCommitPorts-1:0] ckpt_retire;
  logic [G6LCCfg.NrCommitPorts-1:0] commit_wr, commit_arch;
  logic [G6LCCfg.NrCommitPorts-1:0][4:0] commit_rd;
  logic [G6LCCfg.NrCommitPorts-1:0][PRF_W-1:0] commit_prd;
  // FP counterparts. Every `rd != 0` filter on the integer side is absent
  // here on purpose: f0 is an ordinary register, so an f0 commit updates
  // the architectural map and an f0 predecessor is freed like any other.
  logic [G6LCCfg.NrCommitPorts-1:0] ffree_en, commit_is_fpr;
  logic [G6LCCfg.NrCommitPorts-1:0][FPRF_W-1:0] ffree_prd, commit_fprd;

  // The FP PRF has NO commit-write mirror (commit_stage never substitutes
  // an FP value -- see the emit-base comment for the derivation).
  //pragma translate_off
  // r42-T item 21 equivalence: while a group is held (|grp_v_q), the
  // predecoded legality counts must equal the same-cycle popcounts they
  // replaced. Kill/consume edges clear grp_v_q, which is exactly where
  // the registered counts may stale — the guard bounds the check to the
  // observable window.
  int unsigned t2_grpgo_n = 0;
  always_ff @(posedge clk_i) begin
    if (rst_ni && (|grp_v_q)) begin
      t2_grpgo_n <= t2_grpgo_n + 1;
      g6lc_t2_grpgo_eq: assert (
          grp_need_ld === LDW'($countones(grp_is_ld_q)) &&
          grp_need_st === STW'($countones(grp_is_st_q)) &&
          csr_need === 2'($countones(grp_csr)))
        else $error("g6lc_ooo_dispatch: equiv grp_go legality");
    end
  end
  final begin
    if ($test$plusargs("equiv_report"))
      $display("[equiv] g6lc_ooo_dispatch grpgo: checked=%0d", t2_grpgo_n);
  end
  always_ff @(posedge clk_i) begin
    if (rst_ni && G6LCCfg.FpPresent) begin
      for (int unsigned c = 0; c < G6LCCfg.NrCommitPorts; c++) begin
        if (commit_we_i[c] && commit_is_fpr[c]) begin
          $error("OOO_COMMIT_CLASS port=%0d claims both a GPR write and an FP destination", c);
        end
        if (commit_arch[c] &&
            (tid_is_fpr_q[commit_instr_i[c].trans_id] !=
             (G6LCCfg.FpPresent && is_rd_fpr(commit_instr_i[c].op)))) begin
          $error("OOO_COMMIT_CLASS_STALE port=%0d tid=%0d tracked=%b opcode_fpr=%b",
                 c, commit_instr_i[c].trans_id,
                 tid_is_fpr_q[commit_instr_i[c].trans_id],
                 (G6LCCfg.FpPresent && is_rd_fpr(commit_instr_i[c].op)));
        end
      end
    end
  end
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert ((iq_issue_ack & ~iqi_valid) == '0)
        else $fatal(1, "OOO_ISSUE_ACCEPT_WITHOUT_OFFER");
      if (flush_i || flush_unissued_i) begin
        assert (issue_valid_o == '0 && iq_issue_ack == '0 && dispatch_ack_o == '0)
          else $fatal(1, "OOO_RECOVERY_ACCEPT");
      end
    end
  end
  //pragma translate_on

  // hyp8: per-commit-port independent assigns (no serial loop billing).
  for (genvar c = 0; c < G6LCCfg.NrCommitPorts; c++) begin : gen_commit
    assign commit_arch[c] =
        commit_ack_i[c] && !cancelled_mask_i[commit_instr_i[c].trans_id];
    assign commit_is_fpr[c] =
        G6LCCfg.FpPresent && commit_arch[c] &&
        tid_is_fpr_q[commit_instr_i[c].trans_id];
    assign commit_fprd[c] = tid_fprd_q[commit_instr_i[c].trans_id];
    assign ffree_en[c]  = commit_is_fpr[c];
    assign ffree_prd[c] = tid_fold_q[commit_instr_i[c].trans_id];
    assign free_en[c]  = commit_arch[c] && !commit_is_fpr[c] &&
                         (commit_instr_i[c].rd != 5'd0) &&
                         (tid_old_q[commit_instr_i[c].trans_id] != '0);
    assign free_prd[c] = tid_old_q[commit_instr_i[c].trans_id];
    assign ckpt_retire[c] =
        commit_arch[c] && (tid_ckpt_q[commit_instr_i[c].trans_id] != '1);
    assign commit_wr[c]  = commit_arch[c] &&
        (commit_is_fpr[c] || commit_instr_i[c].rd != 5'd0);
    assign commit_hart[c] = NH > 1 ? HID_W'(commit_instr_i[c].hart_id) : '0;
    assign commit_rd[c]  = commit_instr_i[c].rd[4:0];
    assign commit_prd[c] = tid_prd_q[commit_instr_i[c].trans_id];
  end

  // hyp8: independent per-port assigns.
  for (genvar w = 0; w < G6LCCfg.NrWbPorts; w++) begin : gen_dwb
    assign data_wb_valid[w]  = wb_value_valid[w];
    assign data_wb_prd[w]    = wb_prd[w];
    assign fdata_wb_valid[w] = fwb_value_valid[w];
    assign fdata_wb_prd[w]   = fwb_prd[w];
  end
  for (genvar c = 0; c < PRF_MIRROR; c++) begin : gen_dwb_mirror
    assign data_wb_valid[G6LCCfg.NrWbPorts+c] =
        commit_arch[c] && commit_we_i[c] && commit_prd[c] != '0;
    assign data_wb_prd[G6LCCfg.NrWbPorts+c] = commit_prd[c];
    assign fdata_wb_valid[G6LCCfg.NrWbPorts+c] = 1'b0;
    assign fdata_wb_prd[G6LCCfg.NrWbPorts+c]   = '0;
  end

  // ----------------------------------------------------------------------
  // Staged rename (hyp8 R1/R2/R3). Inputs identical to the unbanked
  // instantiation; enable_i is still can_go -- the capture edge inside
  // rename is what the unbanked single-cycle enable was.
  // ----------------------------------------------------------------------
  g6lc_rename #(
      .PRF_ENTRIES(PRF_N),
      .PRF_W      (PRF_W),
      .FPRF_ENTRIES(G6LCCfg.FpPresent ? FPRF_N : 0),
      .FPRF_W      (FPRF_W),
      .NR_PORTS   (NP),
      .NR_HARTS   (NH),
      .NR_FREE    (G6LCCfg.NrCommitPorts),
      .NR_WB      (DATA_WB_NR),
      .CKPT_DEPTH (CKPT),
      .HypCfg     (HypCfg)
  ) i_rename (
      .clk_i,
      .rst_ni,
      .flush_i,
      .mispredict_i,
      .flush_unissued_i,
      // Branch-tag plumbing: each dispatched branch recorded the checkpoint
      // level it consumed (rename's ckpt_id_o) keyed by its trans_id. On
      // resolve, the resolving branch's id selects its own level, so an OLDER
      // branch unwinds to its own checkpoint instead of the youngest.
      .mispredict_level_i(tid_ckpt_q[mispredict_id_i]),
      .hart_i    (dispatch_hart),
      // Per-hart flush is not driven at this level: with flush_hart_i tied
      // off, an in-flight group can only die via kill_all events
      // (mispredict_i/flush_i/flush_unissued_i), which also clear
      // grp_pend_q -- a fully killed group therefore can never orphan the
      // pending flag.
      .flush_hart_i('0),
      .is_fpr_rd_i(is_fpr_rd_c), .is_fpr_rs1_i(is_fpr_rs1_c),
      .is_fpr_rs2_i(is_fpr_rs2_c),
      .rs3_i(rs3_a), .is_fpr_rs3_i(is_fpr_rs3_c),
      .fprs3_o(fprs3), .rs3_ready_o(),
      .fprs1_o(fprs1), .fprs2_o(fprs2), .fprd_o(fprd), .fprd_old_o(fprd_old),
      .fwb_valid_i(fdata_wb_valid), .fwb_prd_i(fdata_wb_prd),
      .ffree_i(ffree_en), .ffree_prd_i(ffree_prd),
      .commit_is_fpr_i(commit_is_fpr), .commit_fprd_i(commit_fprd),
      .valid_i   (dispatch_valid_i),
      .rs1_i     (rs1_a),
      .rs2_i     (rs2_a),
      .rd_i      (rd_a),
      .need_rd_i (need_rd),
      .is_branch_i(is_br),
      .prs1_o    (prs1),
      .prs2_o    (prs2),
      .prd_o     (prd),
      .prd_old_o (prd_old),
      // R1 ready snapshots are capture-time diagnostics only -- IQ
      // allocation readiness below reads int_busy_o/fp_busy_o instead.
      .rs1_ready_o(),
      .rs2_ready_o(),
      .int_busy_o(ren_int_busy),
      .fp_busy_o (ren_fp_busy),
      .ckpt_id_o (ren_ckpt_id),
      .ckpt_retire_i(ckpt_retire),
      .commit_valid_i(commit_wr),
      .commit_hart_i (commit_hart),
      .commit_rd_i   (commit_rd),
      .commit_prd_i  (commit_prd),
      .stall_o   (ren_stall),
      .wb_valid_i(data_wb_valid),
      .wb_prd_i  (data_wb_prd),
      .free_i    (free_en),
      .free_prd_i(free_prd),
      .enable_i  (can_go),
      .group_valid_o(ren_group_valid)
  );

  // ----------------------------------------------------------------------
  // Group record: captured at the rename publish strobe. The scoreboard
  // holds dispatch_sbe_i/dispatch_orig_i until dispatch_ack_o, so the
  // input fields below still describe this group at the strobe edge; the
  // rename outputs (prs*/prd*/rdy/ckpt) are registered and final. The
  // memdep verdict for lane 0's load is the registered predict_o -- the
  // query fired at the capture edge and no other group can have queried
  // since (grp_pend_q blocks can_go).
  // ----------------------------------------------------------------------
  logic [BW-1:0] steer_q;

  // hyp8 bring-up: the group capture was one sequential block whose 26
  // field writes the structural model billed as a single chain. Split
  // into housekeeping flops + one per-lane capture block so each lane is
  // its own independent-LHS bundle; the sbe record is assembled
  // combinationally per lane (sbe_pub).
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      grp_pend_q <= 1'b0;
      grp_v_q    <= '0;
      grp_may_bypass_q <= '0;
      steer_q    <= '0;
    end else begin
      // Pipe bookkeeping: capture sets, publish/kill clears. A killed
      // in-flight group can produce no strobe (its stages are cleared), so
      // pend must drop on the kill events themselves.
      if (ren_pub || mispredict_i || flush_i || flush_unissued_i) begin
        grp_pend_q <= 1'b0;
      end else if (ren_capture) begin
        grp_pend_q <= 1'b1;
      end
      // Kill outranks publish for grp_v_q. The dispatch_valid_i zombie
      // mask below samples the scoreboard's PRE-flush presentation -- the
      // presented lanes retract at this edge, not before -- so a rename
      // publish coincident with mispredict/flush/flush_unissued would
      // capture dead lanes into grp_v_q and dispatch_ack_o them a cycle
      // later while the scoreboard presents nothing (the zombie also
      // allocates IQ/LSQ entries on a non-flush edge). Sibling state
      // written under ren_pub is inert while grp_v_q==0:
      // grp_sbe_q/grp_orig_q/tid staging and grp_may_bypass_q reach
      // consumers only through grp_v_q/grp_go/dispatch_ack_o, steer_q is
      // a performance hint, and grp_pend_q already has kill priority.
      if (mispredict_i || flush_i || flush_unissued_i) begin
        grp_v_q <= '0;
      end else if (ren_pub) begin
        // Mask the published lanes by the scoreboard's live view. A group
        // captured before a kill the rename pipe does not observe
        // (flush_unissued between the capture and publish edges, a
        // cancelled slot) still publishes; its dead lanes have
        // dispatch_valid_i == 0 here and must not enter grp_v_q -- a
        // zombie lane would allocate an IQ/ROB entry and issue.
        grp_v_q <= ren_group_valid & dispatch_valid_i;
        // Each lane keeps its own store-set verdict. A hit on one load
        // does not clear bypass on the other lanes or the other hart.
        for (int unsigned p = 0; p < NP; p++)
          grp_may_bypass_q[p] <= G6LCCfg.MemDepPredEn && is_ld[p] &&
                                 !md_predict_v[p];
        // hyp8: bank steering -- lanes spread across consecutive banks
        // starting at a rotating base, so consecutive groups rotate and a
        // group's siblings wake each other through the short local path
        // when the predictor/decode order allows.
        steer_q <= steer_q + BW'(NP);
      end else if (grp_go && grp_done) begin
        grp_v_q <= '0;
      end
    end
  end

`ifndef G6LC_MUT_T2_DISP_GRPGO
  // r42-T item 21: predecode the held group's LSQ demand and CSR credit
  // need at the publish edge. The popcount then sits behind the edge and
  // grp_go compares registered counts against the live free counters.
  // The csr need counts only the lanes grp_v_q actually captures —
  // ren_group_valid masked by the scoreboard's live view (same mask as
  // the grp_v_q write above); the need counts keep the old unmasked
  // is_ld/is_st shape (grp_is_*_q were stored unmasked too).
  logic [NP-1:0] ren_csr_pub;
  for (genvar p = 0; p < NP; p++) begin : gen_ren_csr_pub
    assign ren_csr_pub[p] = ren_group_valid[p] && dispatch_valid_i[p] &&
                            (dispatch_sbe_i[p].fu == CSR);
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      grp_need_ld_q  <= '0;
      grp_need_st_q  <= '0;
      grp_csr_need_q <= '0;
    end else if (ren_pub) begin
      grp_need_ld_q  <= LDW'($countones(is_ld));
      grp_need_st_q  <= STW'($countones(is_st));
      grp_csr_need_q <= 2'($countones(ren_csr_pub));
    end
  end
`endif

  // Published scoreboard-entry record per lane (combinational assembly).
  scoreboard_entry_t [NP-1:0] sbe_pub;
  for (genvar p = 0; p < NP; p++) begin : gen_sbe_pub
    always_comb begin
      sbe_pub[p] = dispatch_sbe_i[p];
      sbe_pub[p].p_rs1 = 8'(prs1[p]);
      sbe_pub[p].p_rs2 = 8'(prs2[p]);
      sbe_pub[p].p_rd  = 8'(prd[p]);
      sbe_pub[p].p_frs1 = 8'(fprs1[p]);
      sbe_pub[p].p_frs2 = 8'(fprs2[p]);
      sbe_pub[p].p_frs3 = 8'(fprs3[p]);
      sbe_pub[p].p_frd  = 8'(fprd[p]);
      sbe_pub[p].ooo_renamed = ren_group_valid[p] && dispatch_valid_i[p];
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        grp_sbe_q[p] <= '0;
        grp_orig_q[p] <= '0;
        grp_prs1_q[p] <= '0; grp_prs2_q[p] <= '0; grp_prd_q[p] <= '0;
        grp_fprs1_q[p] <= '0; grp_fprs2_q[p] <= '0; grp_fprs3_q[p] <= '0;
        grp_fprd_q[p] <= '0;
        grp_is_fpr_rs1_q[p] <= '0; grp_is_fpr_rs2_q[p] <= '0;
        grp_is_fpr_rs3_q[p] <= '0;
        grp_ckpt_q[p] <= '0;
        grp_is_st_q[p] <= '0; grp_is_ld_q[p] <= '0; grp_is_br_q[p] <= '0;
        grp_is_fpr_rd_q[p] <= '0;
      end else if (ren_pub) begin
        grp_sbe_q[p]   <= sbe_pub[p];
        grp_orig_q[p]  <= dispatch_orig_i[p];
        grp_prs1_q[p]  <= prs1[p];
        grp_prs2_q[p]  <= prs2[p];
        grp_prd_q[p]   <= prd[p];
        grp_fprs1_q[p] <= fprs1[p];
        grp_fprs2_q[p] <= fprs2[p];
        grp_fprs3_q[p] <= fprs3[p];
        grp_fprd_q[p]  <= fprd[p];
        grp_is_fpr_rs1_q[p] <= is_fpr_rs1_c[p];
        grp_is_fpr_rs2_q[p] <= is_fpr_rs2_c[p];
        grp_is_fpr_rs3_q[p] <= is_fpr_rs3_c[p];
        grp_ckpt_q[p]  <= ren_ckpt_id[p];
        grp_is_st_q[p] <= is_st[p];
        grp_is_ld_q[p] <= is_ld[p];
        grp_is_br_q[p] <= is_br[p];
        grp_is_fpr_rd_q[p] <= is_fpr_rd_c[p];
      end
    end
  end

  // may_bypass now lives in the group record; the live signal only feeds
  // the IQ ports below.
  assign may_bypass = grp_may_bypass_q;

  // tid_* side tables, written at the registered group's ack edge (the
  // unbanked design wrote them under dispatch_ack_o -- same handshake, two
  // cycles later). Read by the issue/retire/recovery paths below.
  logic [NP-1:0][G6LCCfg.TRANS_ID_BITS-1:0] grp_tid;
  // Old-destination tags: the rename reports them on prd_old_o /
  // fprd_old_o at the publish strobe; they are captured alongside the rest
  // of the record.
  logic [NP-1:0][PRF_W-1:0] grp_prd_old_q;
  logic [NP-1:0][FPRF_W-1:0] grp_fprd_old_q;
  for (genvar p = 0; p < NP; p++) begin : gen_grp_tid
    assign grp_tid[p] = grp_sbe_q[p].trans_id;
  end

  // hyp8 bring-up: split the composed next-state writer into one block
  // per side table so each LHS is billed as an independent bundle.
  always_comb begin
    tid_prd_d = tid_prd_q;
    for (int unsigned p = 0; p < NP; p++)
      if (dispatch_ack_o[p]) tid_prd_d[grp_tid[p]] = grp_prd_q[p];
    if (flush_i) tid_prd_d = '0;
  end
  always_comb begin
    tid_old_d = tid_old_q;
    for (int unsigned p = 0; p < NP; p++)
      if (dispatch_ack_o[p]) tid_old_d[grp_tid[p]] = grp_prd_old_q[p];
    if (flush_i) tid_old_d = '0;
  end
  always_comb begin
    tid_is_st_d = tid_is_st_q;
    for (int unsigned p = 0; p < NP; p++)
      if (dispatch_ack_o[p]) tid_is_st_d[grp_tid[p]] = grp_is_st_q[p];
    if (flush_i) tid_is_st_d = '0;
  end
  always_comb begin
    tid_late_result_d = tid_late_result_q;
    for (int unsigned p = 0; p < NP; p++)
      if (dispatch_ack_o[p])
        tid_late_result_d[grp_tid[p]] = grp_sbe_q[p].fu == CSR ||
            (G6LCCfg.RVA && is_amo(grp_sbe_q[p].op));
    if (flush_i) tid_late_result_d = '0;
  end
  always_comb begin
    tid_is_fpr_d = tid_is_fpr_q;
    for (int unsigned p = 0; p < NP; p++)
      if (dispatch_ack_o[p]) tid_is_fpr_d[grp_tid[p]] = grp_is_fpr_rd_q[p];
    if (flush_i) tid_is_fpr_d = '0;
  end
  always_comb begin
    tid_fprd_d = tid_fprd_q;
    for (int unsigned p = 0; p < NP; p++)
      if (dispatch_ack_o[p]) tid_fprd_d[grp_tid[p]] = grp_fprd_q[p];
    if (flush_i) tid_fprd_d = '0;
  end
  always_comb begin
    tid_fold_d = tid_fold_q;
    for (int unsigned p = 0; p < NP; p++)
      if (dispatch_ack_o[p]) tid_fold_d[grp_tid[p]] = grp_fprd_old_q[p];
    if (flush_i) tid_fold_d = '0;
  end
  always_comb begin
    tid_ckpt_d = tid_ckpt_q;
    for (int unsigned p = 0; p < NP; p++)
      if (dispatch_ack_o[p])
        // Record the checkpoint level this branch consumed; '1 is the
        // untagged "youngest" default and also clears a reused slot.
        tid_ckpt_d[grp_tid[p]] = grp_is_br_q[p] ? grp_ckpt_q[p] : '1;
    if (mispredict_i) tid_ckpt_d[mispredict_id_i] = '1;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      grp_prd_old_q <= '0;
      grp_fprd_old_q <= '0;
    end else if (ren_pub) begin
      grp_prd_old_q <= prd_old;
      grp_fprd_old_q <= fprd_old;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tid_prd_q <= '0;
      tid_old_q <= '0;
      tid_is_st_q <= '0;
      tid_late_result_q <= '0;
      tid_is_fpr_q <= '0;
      tid_fprd_q <= '0;
      tid_fold_q <= '0;
      tid_ckpt_q <= '1;
    end else begin
      // hyp8 bring-up fix: the late_result/is_fpr/fprd/fold RHS were
      // self-assigns to the _d comb wires -- the _q tables never updated
      // after reset (also the source of the MULTIDRIVEN lint hits).
      tid_prd_q <= tid_prd_d;
      tid_old_q <= tid_old_d;
      tid_is_st_q <= tid_is_st_d;
      tid_late_result_q <= tid_late_result_d;
      tid_is_fpr_q <= tid_is_fpr_d;
      tid_fprd_q <= tid_fprd_d;
      tid_fold_q <= tid_fold_d;
      tid_ckpt_q <= tid_ckpt_d;
    end
  end

  //pragma translate_off
  // M3 bring-up probe (+icf_trace): dispatch offer/ack handshake. Catches the
  // scoreboard's "Issue acknowledged but instruction is not valid" firing.
  logic disp_trace;
  int unsigned dsp_lo, dsp_hi;
  initial begin
    disp_trace = $test$plusargs("disp_trace");
    dsp_lo = 0;
    dsp_hi = 3000;
    void'($value$plusargs("trace_from=%d", dsp_lo));
    void'($value$plusargs("trace_to=%d", dsp_hi));
  end
  always_ff @(negedge clk_i) begin
    if (rst_ni && disp_trace && $time() >= dsp_lo && $time() <= dsp_hi &&
        (|dispatch_valid_i || |dispatch_ack_o || ren_capture || ren_pub || (|grp_v_q))) begin
      $display("[dsp] t=%0t dv=%b dack=%b | cap=%b pub=%b cango=%b | grpv=%b go=%b iqdack=%b done=%b | rg=%b gt0=%0d gt1=%0d sbe0=%0d sbe1=%0d dsbe0=%0d dsbe1=%0d | lane0 pc=%h fu=%0d | gf=%b asg=%0d,%0d bf=%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d bk=%b,%b",
        $time, dispatch_valid_i, dispatch_ack_o, ren_capture, ren_pub, can_go,
        grp_v_q, grp_go, iqdisp_ack, grp_done,
        ren_group_valid, grp_tid[0], grp_tid[1],
        grp_sbe_q[0].trans_id, grp_sbe_q[1].trans_id,
        dispatch_sbe_i[0].trans_id, dispatch_sbe_i[1].trans_id,
        dispatch_sbe_i[0].pc, dispatch_sbe_i[0].fu,
        i_iq.group_fits, i_iq.asgn[0], i_iq.asgn[1],
        i_iq.bank_free[0], i_iq.bank_free[1], i_iq.bank_free[2], i_iq.bank_free[3],
        i_iq.bank_free[4], i_iq.bank_free[5], i_iq.bank_free[6], i_iq.bank_free[7],
        i_iq.back[i_iq.asgn[0]][0], i_iq.back[i_iq.asgn[1]][1]);
    end
  end
  //pragma translate_on

  // ROB -- multi-WB complete by scoreboard trans_id (unchanged).
  logic [G6LCCfg.NrWbPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] rob_c_tid;
  for (genvar w = 0; w < G6LCCfg.NrWbPorts; w++) begin : gen_rob_ctid
    assign rob_c_tid[w] = wb_id_i[w];
  end

  logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] rob_retire_tid;
  for (genvar p = 0; p < G6LCCfg.NrCommitPorts; p++) begin : gen_rob_rtid
    assign rob_retire_tid[p] = commit_instr_i[p].trans_id;
  end

  g6lc_rob #(
      .ROB_ENTRIES(ROB_N),
      .ROB_W      (ROB_W),
      .NR_ALLOC   (NP),
      .NR_RETIRE  (G6LCCfg.NrCommitPorts),
      .NR_COMPLETE(G6LCCfg.NrWbPorts),
      .TID_W      (G6LCCfg.TRANS_ID_BITS),
      .NR_SB      (G6LCCfg.NR_SB_ENTRIES),
      .entry_t    (scoreboard_entry_t)
  ) i_rob (
      .clk_i,
      .rst_ni,
      .flush_i,
      .cancelled_mask_i,
      .alloc_valid_i (dispatch_ack_o),
      .alloc_entry_i (grp_sbe_q),
      .alloc_tid_i   (grp_tid),
      .alloc_id_o    (),
      .full_o        (rob_full),
      .empty_o       (rob_empty),
      .complete_valid_i(wb_valid_i),
      .complete_tid_i  (rob_c_tid),
      .complete_exc_i  (wb_exc_i),
      .retire_valid_o(),
      .retire_entry_o(),
      .retire_id_o   (),
      .retire_ack_i  (commit_ack_i),
      .retire_tid_i  (rob_retire_tid)
  );

  // ----------------------------------------------------------------------
  // Banked IQ. The dispatch record it consumes is the registered group.
  // issue candidates arrive registered; dispatch stages them once more
  // (iss_q) so the PRF's 2-step read aligns with issue_valid_o.
  // ----------------------------------------------------------------------
  logic [NP-1:0][PRF_W-1:0] iqi_prd;
  scoreboard_entry_t [NP-1:0] iqi_sbe;
  logic [NP-1:0][31:0]   iqi_orig;
  logic [NP-1:0]         iqi_spec;
  logic [NP-1:0][1:0]    iqi_spec_ab;
  logic [NP-1:0][1:0][G6LCCfg.TRANS_ID_BITS-1:0] iqi_ptid;
  logic [NP-1:0][BW-1:0] steer_hint;

  for (genvar p = 0; p < NP; p++) begin : gen_steer_hint
    assign steer_hint[p] = steer_q + BW'(p);
  end

  logic [NP-1:0]                 agu_valid;
  logic [NP-1:0][G6LCCfg.PLEN-1:0] agu_addr;
  logic [NP-1:0]                 agu_is_st;
  logic [NP-1:0][1:0]            agu_size;
  logic [NP-1:0]                 st_data_v;
  logic [NP-1:0][G6LCCfg.XLEN-1:0] st_data;
  logic [NP-1:0][G6LCCfg.TRANS_ID_BITS-1:0] agu_id;
  logic [NP-1:0][G6LCCfg.TRANS_ID_BITS-1:0] st_data_id;
  logic [G6LCCfg.PLEN-1:0] ld_qaddr;
  logic [1:0]              ld_qsize;
  logic [G6LCCfg.NrWbPorts-1:0] complete_is_st;

  // mem_stall survives only as the lsq_stall_o PMU probe (loads are
  // ordered by the IQ's per-entry older-UNRESOLVED-store gate).
  // Predictor hits are per load (may_bypass). A global stall here would
  // freeze every hart's loads when one lane collides.
  assign mem_stall = stl_stall;

  logic                                     iq_replay_v;
  logic [G6LCCfg.TRANS_ID_BITS-1:0]         iq_replay_t;

  g6lc_iq #(
      .G6LCCfg(G6LCCfg),
      .HypCfg (HypCfg),
      .DEPTH  (IQ_N),
      .NR_WB  (DATA_WB_NR),
      .PRF_W  (PRF_W),
      .FPRF_W (FPRF_W),
      .scoreboard_entry_t(scoreboard_entry_t)
  ) i_iq (
      .clk_i,
      .rst_ni,
      .flush_i,
      .cancelled_mask_i,
      // hyp8: the registered group's alloc request; the IQ's own
      // disp_ack_o is the dispatch_ack_o of record.
      .disp_valid_i    (grp_v_q & {NP{grp_go}}),
      .disp_sbe_i      (grp_sbe_q),
      .disp_orig_i     (grp_orig_q),
      .disp_prs1_i     (grp_prs1_q),
      .disp_prs2_i     (grp_prs2_q),
      .disp_prd_i      (grp_prd_q),
      .disp_rs1_ready_i(grp_rs1_ready),
      .disp_rs2_ready_i(grp_rs2_ready),
      .disp_may_bypass_i(may_bypass),
      .disp_rs3_ready_i(grp_rs3_ready),
      .disp_fprs1_i(grp_fprs1_q), .disp_fprs2_i(grp_fprs2_q),
      .disp_fprs3_i(grp_fprs3_q),
      .disp_fpr_rs1_i(grp_is_fpr_rs1_q), .disp_fpr_rs2_i(grp_is_fpr_rs2_q),
      .disp_fpr_rs3_i(grp_is_fpr_rs3_q),
      .steer_hint_i    (steer_hint),
      // hyp8: the IQ re-arm broadcast merges the LSQ violation pulse
      // (group 8/9) with the LSU load-unit replay — a load's dependents
      // lose their spec wakeup so they cannot issue ahead of the
      // refetch. Coincident same-tid pulses collapse; a divergent loser
      // sets its bit in rp_mask_q and presents on a later cycle (a
      // delayed re-arm only drops spec rdy bits — always conservative).
      .replay_valid_i  (iq_replay_v),
      .replay_tid_i    (iq_replay_t),
      .fwb_valid_i     (fdata_wb_valid),
      .fwb_prd_i       (fdata_wb_prd),
      .disp_ack_o      (iqdisp_ack),
      .full_o          (iq_full),
      .empty_o         (iq_empty),
      .wb_valid_i      (data_wb_valid),
      .wb_prd_i        (data_wb_prd),
      .issue_sbe_o     (iqi_sbe),
      .issue_orig_o    (iqi_orig),
      .issue_prd_o     (iqi_prd),
      .issue_valid_o   (iqi_valid),
      .issue_spec_o    (iqi_spec),
      .issue_spec_ab_o (iqi_spec_ab),
      .issue_ptid_o    (iqi_ptid),
      // hyp8 g7: take-gate FU readies (flu_ready carries mult readiness
      // under OoO: ex_stage's flu_ready_o == mult_ready).
      .lsu_ready_i, .fpu_ready_i, .csr_ready_i, .mult_ready_i,
      .issue_ack_i     (iq_issue_ack),
      .mem_stall_i     (1'b0),
      .st_live_mask_i  (st_live_mask),
      .st_unresolved_mask_i(st_unresolved_mask),
      .st_hart_mask_i  (st_hart_mask),
      .commit_ptr_i    (commit_ptr_i),
      .sb_live_i       (sb_live_i),
      .hyp_wb_reserve_stall_o
  );

  // ----------------------------------------------------------------------
  // svt-stage: begin ISS
  // hyp8: issue staging. Each presented candidate enters iss_q for exactly
  // one PRF-read cycle (longer if the consumer stalls issue_ack_i). The
  // take signal doubles as the IQ's ack -- the arbiter drops the candidate
  // once dispatch has staged it. A candidate cancelled while staged is
  // dropped here too (the arbiter can no longer see it).
  // ----------------------------------------------------------------------
  logic [NP-1:0]           iss_v_q;
  scoreboard_entry_t [NP-1:0] iss_sbe_q;
  logic [NP-1:0][31:0]     iss_orig_q;
  logic [NP-1:0][PRF_W-1:0] iss_prd_q;
  logic [NP-1:0]           iss_fpsel_q;
  // r44: the FP-use class predicates (rs1/rs2/imm use the FP operand
  // file) captured at the same iqi_take edge as iss_sbe_q/iss_fpsel_q —
  // state-derived, no new latency, holds exactly when those hold.
  logic [NP-1:0]           iss_fpa_q, iss_fpb_q, iss_fpc_q;
  logic [NP-1:0]           iss_spec_q;
  logic [NP-1:0][1:0]      iss_spec_ab_q;
  logic [NP-1:0][1:0][G6LCCfg.TRANS_ID_BITS-1:0] iss_ptid_q;

  // FP read-port mux, evaluated on the presented candidate (kept from the
  // unbanked form; the arbiter's reservation additionally guarantees at
  // most one FP candidate per cycle).
  logic [NP-1:0] fp_port_sel, fp_blocked;
  // hyp8: the single FP read-port grant is the lowest-index FP candidate
  // (prefix-OR priority), not a serial taken-chain. fp_blocked marks the
  // other FP candidates exactly as the original did.
  logic [NP-1:0] fp_need;
  for (genvar p = 0; p < NP; p++) begin : gen_fp_sel
    assign fp_need[p] = G6LCCfg.FpPresent && iqi_valid[p] &&
        iqi_sbe[p].ooo_renamed &&
        (is_rs1_fpr(iqi_sbe[p].op) || is_rs2_fpr(iqi_sbe[p].op) ||
         is_imm_fpr(iqi_sbe[p].op));
    if (p == 0) begin : gen_first
      assign fp_port_sel[p] = fp_need[p];
      assign fp_blocked[p]  = 1'b0;
    end else begin : gen_rest
      assign fp_port_sel[p] = fp_need[p] && !(|fp_need[p-1:0]);
      assign fp_blocked[p]  = fp_need[p] &&  (|fp_need[p-1:0]);
    end
  end

  logic [NP-1:0] iss_pop;
  // hyp8: while an FP operation holds a lane's staged record the shared
  // FPRF's registered read addresses still belong to it; a new FP
  // candidate may launch its read only on the current holder's pop edge.
  logic fp_pending_hold;
  assign fp_pending_hold = |(iss_v_q & iss_fpsel_q & ~iss_pop);
  for (genvar p = 0; p < NP; p++) begin : gen_take
    assign iss_pop[p]  = iss_v_q[p] && issue_ack_i[p];
    // hyp8: a take under flush/cancel is not an accepted transfer — the
    // candidate's read/capture must not launch on dead work.
    assign iqi_take[p] = iqi_valid[p] && !fp_blocked[p] &&
                         !flush_i && !flush_unissued_i &&
                         !cancelled_mask_i[iqi_sbe[p].trans_id] &&
                         (!iss_v_q[p] || iss_pop[p]) &&
                         !(fp_need[p] && fp_pending_hold);
  end
  assign iq_issue_ack = iqi_take;

  // The externally visible issue record is the staged one.
  assign issue_valid_o = iss_v_q & {NP{!flush_i && !flush_unissued_i}};
  assign issue_sbe_o   = iss_sbe_q;
  assign issue_orig_o  = iss_orig_q;
  assign issue_spec_ab_o = iss_spec_ab_q;
  assign issue_ptid_o    = iss_ptid_q;

  // hyp8: one capture block per issue lane (independent-LHS bundles).
  for (genvar p = 0; p < NP; p++) begin : gen_iss_cap
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        iss_v_q[p] <= '0;
        iss_sbe_q[p] <= '0;
        iss_orig_q[p] <= '0;
        iss_prd_q[p] <= '0;
        iss_fpsel_q[p] <= '0;
        iss_fpa_q[p] <= '0;
        iss_fpb_q[p] <= '0;
        iss_fpc_q[p] <= '0;
        iss_spec_q[p] <= '0;
        iss_spec_ab_q[p] <= '0;
        iss_ptid_q[p] <= '0;
      end else begin
        // hyp8: the staged record survives flush_unissued_i — the partial
        // kill only masks issue_valid_o for that cycle; accepted work is
        // reoffered next cycle. A full flush or its own cancelled TID
        // still clears it.
        if (flush_i ||
            (iss_v_q[p] && cancelled_mask_i[iss_sbe_q[p].trans_id])) begin
          iss_v_q[p] <= 1'b0;
        end else if (iqi_take[p]) begin
          iss_v_q[p]   <= 1'b1;
          iss_sbe_q[p] <= iqi_sbe[p];
          iss_orig_q[p]<= iqi_orig[p];
          iss_prd_q[p] <= iqi_prd[p];
          iss_fpsel_q[p] <= fp_port_sel[p];
          iss_fpa_q[p] <= G6LCCfg.FpPresent && fp_port_sel[p] &&
                          iqi_sbe[p].ooo_renamed && is_rs1_fpr(iqi_sbe[p].op);
          iss_fpb_q[p] <= G6LCCfg.FpPresent && fp_port_sel[p] &&
                          iqi_sbe[p].ooo_renamed && is_rs2_fpr(iqi_sbe[p].op);
          iss_fpc_q[p] <= G6LCCfg.FpPresent && fp_port_sel[p] &&
                          iqi_sbe[p].ooo_renamed && is_imm_fpr(iqi_sbe[p].op);
          iss_spec_q[p]  <= iqi_spec[p];
          iss_spec_ab_q[p] <= iqi_spec_ab[p];
          iss_ptid_q[p]  <= iqi_ptid[p];
        end else if (iss_pop[p]) begin
          iss_v_q[p] <= 1'b0;
        end
      end
    end
  end

  // ----------------------------------------------------------------------
  // PRF dual-read per issue port + multi-write WB with write-through.
  // hyp8: the read address launches at the take cycle; data arrives in the
  // staged cycle (2-step read inside g6lc_prf).
  // ----------------------------------------------------------------------
  logic [NP*2-1:0][PRF_W-1:0] prf_raddr;
  logic [NP*2-1:0]           prf_ren;
  logic [NP*2-1:0][G6LCCfg.XLEN-1:0] prf_rdata;
  localparam int unsigned PRF_WR = G6LCCfg.NrWbPorts + PRF_MIRROR;
  logic [PRF_WR-1:0][PRF_W-1:0] prf_waddr;
  logic [PRF_WR-1:0][G6LCCfg.XLEN-1:0] prf_wdata;
  logic [PRF_WR-1:0] prf_we;

  // FP physical file. THREE read ports total (rs1/rs2/rs3), muxed to the
  // issue port holding the FP op -- deliberately mirroring the in-order FP
  // regfile, so only one FP instruction reads per cycle.
  localparam int unsigned FPRF_WR = G6LCCfg.NrWbPorts;
  logic [2:0][FPRF_W-1:0] fprf_raddr;
  logic [2:0][G6LCCfg.FLen-1:0] fprf_rdata;
  logic [FPRF_WR-1:0][FPRF_W-1:0] fprf_waddr;
  logic [FPRF_WR-1:0][G6LCCfg.FLen-1:0] fprf_wdata;
  logic [FPRF_WR-1:0] fprf_we;

  // hyp8: per-port independent assigns. The read enables follow the take
  // so a stalled lane's staged record keeps the operand addresses it was
  // granted (the integer PRF holds its last read while !iqi_take).
  for (genvar p = 0; p < NP; p++) begin : gen_prf_ra
    assign prf_raddr[p*2+0] = iqi_take[p] && iqi_sbe[p].ooo_renamed
                              ? PRF_W'(iqi_sbe[p].p_rs1) : '0;
    assign prf_raddr[p*2+1] = iqi_take[p] && iqi_sbe[p].ooo_renamed
                              ? PRF_W'(iqi_sbe[p].p_rs2) : '0;
    assign prf_ren[p*2+0]   = iqi_take[p];
    assign prf_ren[p*2+1]   = iqi_take[p];
  end
  for (genvar w = 0; w < G6LCCfg.NrWbPorts; w++) begin : gen_prf_wa
    assign prf_waddr[w] = wb_prd[w];
    assign prf_wdata[w] = wb_data_i[w];
    assign prf_we[w]    = wb_value_valid[w] && (wb_prd[w] != '0);
  end
  // Mirror exactly what the architectural register file receives, keyed
  // by the committing instruction's OWN physical register.
  for (genvar c = 0; c < PRF_MIRROR; c++) begin : gen_prf_mirror
    assign prf_waddr[G6LCCfg.NrWbPorts+c] = commit_prd[c];
    assign prf_wdata[G6LCCfg.NrWbPorts+c] = commit_wdata_i[c];
    assign prf_we[G6LCCfg.NrWbPorts+c]    = commit_we_i[c] &&
                                          (commit_prd[c] != '0);
  end

  // hyp8: fp_port_sel is one-hot-ish (at most one granted lane), so the
  // read-address select is a masked OR per read port rather than a serial
  // last-writer loop.
  logic [NP-1:0] fp_take;
  logic [2:0][NP-1:0][FPRF_W-1:0] fprf_term;
  for (genvar p = 0; p < NP; p++) begin : gen_fprf_ra
    assign fp_take[p] = iqi_take[p] && fp_port_sel[p];
    assign fprf_term[0][p] = {FPRF_W{fp_take[p]}} &
                             FPRF_W'(iqi_sbe[p].p_frs1);
    assign fprf_term[1][p] = {FPRF_W{fp_take[p]}} &
                             FPRF_W'(iqi_sbe[p].p_frs2);
    assign fprf_term[2][p] = {FPRF_W{fp_take[p]}} &
                             FPRF_W'(iqi_sbe[p].p_frs3);
  end
  for (genvar k = 0; k < 3; k++) begin : gen_fprf_or
    localparam int unsigned RLV = (NP > 1) ? $clog2(NP) : 1;
    logic [RLV:0][NP-1:0][FPRF_W-1:0] r;
    for (genvar p = 0; p < NP; p++) assign r[0][p] = fprf_term[k][p];
    for (genvar l = 0; l < RLV; l++) begin : gen_lvl
      for (genvar i = 0; i < NP; i++) begin : gen_or
        if (i < ((NP + (1 << l) - 1) >> (l + 1))) begin : gen_cmp
          if ((2 * i + 1) < ((NP + (1 << l) - 1) >> l)) begin : gen_pair
            assign r[l+1][i] = r[l][2*i] | r[l][2*i+1];
          end else begin : gen_odd
            assign r[l+1][i] = r[l][2*i];
          end
        end else begin : gen_pad
          assign r[l+1][i] = '0;
        end
      end
    end
    assign fprf_raddr[k] = r[RLV][0];
  end
  for (genvar w = 0; w < G6LCCfg.NrWbPorts; w++) begin : gen_fprf_wa
    assign fprf_waddr[w] = fwb_prd[w];
    assign fprf_wdata[w] = wb_data_i[w][G6LCCfg.FLen-1:0];
    assign fprf_we[w]    = fwb_value_valid[w];
  end

  g6lc_prf #(
      .DATA_WIDTH (G6LCCfg.FLen),
      .PRF_ENTRIES(FPRF_N),
      .NR_READ    (3),
      .NR_WRITE   (FPRF_WR),
      .PRF_W      (FPRF_W),
      .ZERO_REG_ZERO(1'b0)
  ) i_fprf (
      .clk_i,
      .rst_ni,
      .raddr_i(fprf_raddr),
      .read_enable_i({3{|fp_take}}),
      .rdata_o(fprf_rdata),
      .waddr_i(fprf_waddr),
      .wdata_i(fprf_wdata),
      .we_i   (fprf_we)
  );

  g6lc_prf #(
      .DATA_WIDTH (G6LCCfg.XLEN),
      .PRF_ENTRIES(PRF_N),
      .NR_READ    (NP * 2),
      .NR_WRITE   (PRF_WR),
      .PRF_W      (PRF_W)
  ) i_prf (
      .clk_i,
      .rst_ni,
      .raddr_i(prf_raddr),
      .read_enable_i(prf_ren),
      .rdata_o(prf_rdata),
      .waddr_i(prf_waddr),
      .wdata_i(prf_wdata),
      .we_i   (prf_we)
  );

  // ----------------------------------------------------------------------
  // Operand assemble from the staged record plus writeback bypass.
  // (Separate from the forward path to keep the ld_qaddr -> LSQ CAM ->
  // stl_fwd loop broken exactly as the unbanked design did.)
  // ----------------------------------------------------------------------
  logic [NP-1:0][G6LCCfg.XLEN-1:0] op_a_agu, op_b_pre;
  // hyp8: per-port compare vectors + masked OR-select for the writeback
  // bypass (physical dst tags are unique across WB ports in a cycle, so
  // at most one lane hits -- the mask-OR is identical to the emit's
  // last-writer-wins loop). The FP override selects the FP file value
  // with its own hit vector, as the emit's ordered overwrite did.
  for (genvar p = 0; p < NP; p++) begin : gen_op_asm
    localparam int unsigned WLV =
        (G6LCCfg.NrWbPorts > 1) ? $clog2(G6LCCfg.NrWbPorts) : 1;
    logic [G6LCCfg.NrWbPorts-1:0] hit_a, hit_b, fh_a, fh_b;
    logic [G6LCCfg.NrWbPorts-1:0][G6LCCfg.XLEN-1:0] ta, tb, tfa, tfb;
    logic [WLV:0][G6LCCfg.NrWbPorts-1:0][G6LCCfg.XLEN-1:0] oa, ob, ofa, ofb;
    for (genvar w = 0; w < G6LCCfg.NrWbPorts; w++) begin : gen_hit
      assign hit_a[w] = wb_value_valid[w] && iss_sbe_q[p].ooo_renamed &&
                        (wb_prd[w] == PRF_W'(iss_sbe_q[p].p_rs1)) &&
                        (wb_prd[w] != '0);
      assign hit_b[w] = wb_value_valid[w] && iss_sbe_q[p].ooo_renamed &&
                        (wb_prd[w] == PRF_W'(iss_sbe_q[p].p_rs2)) &&
                        (wb_prd[w] != '0);
      assign fh_a[w]  = fwb_value_valid[w] &&
                        (fwb_prd[w] == FPRF_W'(iss_sbe_q[p].p_frs1));
      assign fh_b[w]  = fwb_value_valid[w] &&
                        (fwb_prd[w] == FPRF_W'(iss_sbe_q[p].p_frs2));
      assign ta[w]  = {G6LCCfg.XLEN{hit_a[w]}} & wb_data_i[w];
      assign tb[w]  = {G6LCCfg.XLEN{hit_b[w]}} & wb_data_i[w];
      assign tfa[w] = {G6LCCfg.XLEN{fh_a[w]}} & wb_data_i[w];
      assign tfb[w] = {G6LCCfg.XLEN{fh_b[w]}} & wb_data_i[w];
      assign oa[0][w]  = ta[w];
      assign ob[0][w]  = tb[w];
      assign ofa[0][w] = tfa[w];
      assign ofb[0][w] = tfb[w];
    end
    for (genvar l = 0; l < WLV; l++) begin : gen_lvl
      for (genvar i = 0; i < G6LCCfg.NrWbPorts; i++) begin : gen_or
        if (i < ((G6LCCfg.NrWbPorts + (1 << l) - 1) >> (l + 1))) begin : gen_cmp
          if ((2 * i + 1) < ((G6LCCfg.NrWbPorts + (1 << l) - 1) >> l)) begin : gen_pair
            assign oa[l+1][i]  = oa[l][2*i]  | oa[l][2*i+1];
            assign ob[l+1][i]  = ob[l][2*i]  | ob[l][2*i+1];
            assign ofa[l+1][i] = ofa[l][2*i] | ofa[l][2*i+1];
            assign ofb[l+1][i] = ofb[l][2*i] | ofb[l][2*i+1];
          end else begin : gen_odd
            assign oa[l+1][i]  = oa[l][2*i];
            assign ob[l+1][i]  = ob[l][2*i];
            assign ofa[l+1][i] = ofa[l][2*i];
            assign ofb[l+1][i] = ofb[l][2*i];
          end
        end else begin : gen_pad
          assign oa[l+1][i]  = '0;
          assign ob[l+1][i]  = '0;
          assign ofa[l+1][i] = '0;
          assign ofb[l+1][i] = '0;
        end
      end
    end
    logic fp_a, fp_b;
    assign fp_a = iss_fpa_q[p];
    assign fp_b = iss_fpb_q[p];
    // r46: flat AND-OR select (was a nested 2:1 chain). The four quadrant
    // predicates {fp,fp-file,int,int-file} partition the space exactly.
    logic sel_fpb_a, sel_fpf_a, sel_ib_a, sel_if_a;
    logic sel_fpb_b, sel_fpf_b, sel_ib_b, sel_if_b;
    // ofa/oa are zero whenever their hit vectors are zero (masked
    // writeback data), so the bypass terms gate on fp_ alone.
    assign sel_fpb_a = fp_a;
    assign sel_fpf_a = fp_a && !(|fh_a);
    assign sel_ib_a  = !fp_a;
    assign sel_if_a  = !fp_a && !(|hit_a);
    assign sel_fpb_b = fp_b;
    assign sel_fpf_b = fp_b && !(|fh_b);
    assign sel_ib_b  = !fp_b;
    assign sel_if_b  = !fp_b && !(|hit_b);
    assign op_a_agu[p] = (ofa[WLV][0] & {G6LCCfg.XLEN{sel_fpb_a}})
                       | (G6LCCfg.XLEN'(fprf_rdata[0]) & {G6LCCfg.XLEN{sel_fpf_a}})
                       | (oa[WLV][0] & {G6LCCfg.XLEN{sel_ib_a}})
                       | (prf_rdata[p*2+0] & {G6LCCfg.XLEN{sel_if_a}});
    assign op_b_pre[p] = (ofb[WLV][0] & {G6LCCfg.XLEN{sel_fpb_b}})
                       | (G6LCCfg.XLEN'(fprf_rdata[1]) & {G6LCCfg.XLEN{sel_fpf_b}})
                       | (ob[WLV][0] & {G6LCCfg.XLEN{sel_ib_b}})
                       | (prf_rdata[p*2+1] & {G6LCCfg.XLEN{sel_if_b}});
    //pragma translate_off
    // Reference for the flat select: the pre-r46 nested mux form,
    // compared every cycle, plus an exact-onehot check on the quadrant.
    logic [G6LCCfg.XLEN-1:0] ref_op_a, ref_op_b;
    assign ref_op_a = fp_a ? ((|fh_a) ? ofa[WLV][0]
                                      : G6LCCfg.XLEN'(fprf_rdata[0]))
                           : ((|hit_a) ? oa[WLV][0] : prf_rdata[p*2+0]);
    assign ref_op_b = fp_b ? ((|fh_b) ? ofb[WLV][0]
                                      : G6LCCfg.XLEN'(fprf_rdata[1]))
                           : ((|hit_b) ? ob[WLV][0] : prf_rdata[p*2+1]);
    always_ff @(posedge clk_i) begin
      if (rst_ni) begin
        g6lc_opasm_eq_a: assert (op_a_agu[p] === ref_op_a)
          else $error("g6lc_ooo_dispatch: op_a_agu flat/AND-OR diverged");
        g6lc_opasm_eq_b: assert (op_b_pre[p] === ref_op_b)
          else $error("g6lc_ooo_dispatch: op_b_pre flat/AND-OR diverged");
        g6lc_opasm_oh_a: assert (
            $onehot({fp_a && (|fh_a), fp_a && !(|fh_a),
                     !fp_a && (|hit_a), !fp_a && !(|hit_a)}))
          else $error("g6lc_ooo_dispatch: op_a select quadrant not onehot");
        g6lc_opasm_oh_b: assert (
            $onehot({fp_b && (|fh_b), fp_b && !(|fh_b),
                     !fp_b && (|hit_b), !fp_b && !(|hit_b)}))
          else $error("g6lc_ooo_dispatch: op_b select quadrant not onehot");
      end
    end
    //pragma translate_on
  end

  // hyp8: per-port independent assigns; the op_c FP bypass uses the same
  // masked-OR form as gen_op_asm (at most one hit per cycle).
  for (genvar p = 0; p < NP; p++) begin : gen_issue_op
    localparam int unsigned WLV =
        (G6LCCfg.NrWbPorts > 1) ? $clog2(G6LCCfg.NrWbPorts) : 1;
    logic [G6LCCfg.NrWbPorts-1:0] fh_c;
    logic [WLV:0][G6LCCfg.NrWbPorts-1:0][G6LCCfg.FLen-1:0] oc;
    for (genvar w = 0; w < G6LCCfg.NrWbPorts; w++) begin : gen_hit_c
      assign fh_c[w] = G6LCCfg.FpPresent && fwb_value_valid[w] &&
                       iss_fpsel_q[p] &&
                       (fwb_prd[w] == FPRF_W'(iss_sbe_q[p].p_frs3));
      assign oc[0][w] = {G6LCCfg.FLen{fh_c[w]}} &
                        wb_data_i[w][G6LCCfg.FLen-1:0];
    end
    for (genvar l = 0; l < WLV; l++) begin : gen_lvl
      for (genvar i = 0; i < G6LCCfg.NrWbPorts; i++) begin : gen_or
        if (i < ((G6LCCfg.NrWbPorts + (1 << l) - 1) >> (l + 1))) begin : gen_cmp
          if ((2 * i + 1) < ((G6LCCfg.NrWbPorts + (1 << l) - 1) >> l)) begin : gen_pair
            assign oc[l+1][i] = oc[l][2*i] | oc[l][2*i+1];
          end else begin : gen_odd
            assign oc[l+1][i] = oc[l][2*i];
          end
        end else begin : gen_pad
          assign oc[l+1][i] = '0;
        end
      end
    end
    assign issue_op_a_o[p] = op_a_agu[p];
    assign issue_op_b_o[p] = op_b_pre[p];
    assign issue_op_a_valid_o[p] = issue_valid_o[p] && iss_sbe_q[p].ooo_renamed;
    assign issue_op_b_valid_o[p] = issue_valid_o[p] && iss_sbe_q[p].ooo_renamed;
    assign issue_op_c_o[p] = (|fh_c) ? oc[WLV][0] : fprf_rdata[2];
    assign issue_op_c_valid_o[p] = issue_valid_o[p] && iss_fpc_q[p];
  end

  // Live AGU at issue: vaddr = imm + rs1 (matches load_store_unit AGU)
  // hyp8: per-lane independent assigns (no serial loop billing).
  for (genvar p = 0; p < NP; p++) begin : gen_agu
    logic [G6LCCfg.XLEN-1:0] vaddr_p;
    assign vaddr_p = $unsigned($signed(iss_sbe_q[p].result) +
                               $signed(issue_op_a_o[p]));
    assign agu_valid[p] =
        issue_valid_o[p] && issue_ack_i[p] && iss_sbe_q[p].ooo_renamed &&
        (iss_sbe_q[p].fu == LOAD || iss_sbe_q[p].fu == STORE);
    assign agu_addr[p]  = agu_valid[p] ?
        G6LCCfg.PLEN'(vaddr_p[G6LCCfg.PLEN-1:0]) : '0;
    assign agu_is_st[p] = agu_valid[p] && (iss_sbe_q[p].fu == STORE);
    assign agu_size[p]  = agu_valid[p] ?
        g6lc_core_pkg::extract_transfer_size(iss_sbe_q[p].op) : '0;
    assign agu_id[p]    = agu_valid[p] ? iss_sbe_q[p].trans_id : '0;
    assign st_data_v[p]  = agu_valid[p] && (iss_sbe_q[p].fu == STORE);
    assign st_data[p]    = st_data_v[p] ? issue_op_b_o[p] : '0;
    assign st_data_id[p] = st_data_v[p] ? iss_sbe_q[p].trans_id : '0;
  end

  // Load query address for CAM (port 0). Real transfer size so the LSQ can
  // do byte-overlap hazard checks instead of whole-word group matches.
  logic ld_qsel;
  logic [G6LCCfg.XLEN-1:0] ld_qvaddr;
  assign ld_qsel  = issue_valid_o[0] && iss_sbe_q[0].fu == LOAD &&
                    iss_sbe_q[0].ooo_renamed;
  assign ld_qvaddr = $unsigned($signed(iss_sbe_q[0].result) +
                               $signed(op_a_agu[0]));
  assign ld_qaddr = ld_qsel ?
      G6LCCfg.PLEN'(ld_qvaddr[G6LCCfg.PLEN-1:0]) : '0;
  assign ld_qsize = ld_qsel ?
      g6lc_core_pkg::extract_transfer_size(iss_sbe_q[0].op) : '0;

  for (genvar w = 0; w < G6LCCfg.NrWbPorts; w++) begin : gen_cis
    assign complete_is_st[w] = tid_is_st_q[wb_id_i[w]];
  end

  // Store commit across every commit port.
  logic [G6LCCfg.NrCommitPorts-1:0] commit_st, commit_ld;
  logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] commit_st_id;
  for (genvar c = 0; c < G6LCCfg.NrCommitPorts; c++) begin : gen_commit_st
    assign commit_st[c]    = commit_arch[c] && (commit_instr_i[c].fu == STORE);
    assign commit_ld[c]    = commit_ack_i[c] && (commit_instr_i[c].fu == LOAD);
    assign commit_st_id[c] = commit_instr_i[c].trans_id;
  end

  // LSQ allocation from the registered group at the ack edge.
  logic [NP-1:0] ld_alloc, st_alloc;
  logic [NP-1:0][G6LCCfg.TRANS_ID_BITS-1:0] alloc_ids;
  logic [NP-1:0][G6LCCfg.VLEN-1:0] alloc_pcs;
  logic [NP-1:0][HID_W-1:0] grp_hart;
  for (genvar p = 0; p < NP; p++) begin : gen_alloc
    assign ld_alloc[p]  = dispatch_ack_o[p] && grp_is_ld_q[p];
    assign st_alloc[p]  = dispatch_ack_o[p] && grp_is_st_q[p];
    assign alloc_ids[p] = grp_tid[p];
    assign alloc_pcs[p] = grp_sbe_q[p].pc;
    assign grp_hart[p]  = NH > 1 ? HID_W'(grp_sbe_q[p].hart_id) : '0;
  end

  logic                        lsq_replay_v;
  logic [G6LCCfg.TRANS_ID_BITS-1:0] lsq_replay_t;

  // ----------------------------------------------------------------------
  // hyp8 g10: IQ re-arm fan-in. The LSQ violation pulse and the LSU
  // load-unit replay both drive the bank's replay broadcast. Priority:
  // a queued loser (rp_mask_q) > LSQ pulse > LSU pulse; coincident
  // same-tid pulses collapse into one broadcast, a divergent loser sets
  // its bit and presents on a later cycle. One bit per trans_id means
  // the pending set can never overflow, and a delayed re-arm only drops
  // spec rdy bits — always conservative. flush_i clears the set (the
  // entries it would re-arm are dead).
  // ----------------------------------------------------------------------
  logic [G6LCCfg.NR_SB_ENTRIES-1:0]          rp_mask_q, rp_mask_d;
  logic [G6LCCfg.TRANS_ID_BITS-1:0]          rp_pend_tid;

  // hyp8: generic lowest-set select over NR_SB_ENTRIES (one pending bit
  // per trans_id). Prefix-OR below-mask isolates the lowest set bit; each
  // index bit is an OR over the one-hot's positions — no fixed-width
  // reduction tree.
  localparam int unsigned RP_N = G6LCCfg.NR_SB_ENTRIES;
  function automatic logic [RP_N-1:0] rp_below(input logic [RP_N-1:0] x);
    logic [RP_N-1:0] below;
    below = x << 1;
    for (int unsigned l = 1; l < RP_N; l = l << 1)
      below = below | (below << l);
    return below;
  endfunction
  logic [RP_N-1:0] rp_oh;
  assign rp_oh = rp_mask_q & ~rp_below(rp_mask_q);
  for (genvar b = 0; b < G6LCCfg.TRANS_ID_BITS; b++) begin : gen_rp_index
    logic [RP_N-1:0] terms;
    for (genvar t = 0; t < RP_N; t++) begin : gen_term
      assign terms[t] = rp_oh[t] && (((t >> b) & 1) != 0);
    end
    assign rp_pend_tid[b] = |terms;
  end

  assign iq_replay_v = (|rp_mask_q) | lsq_replay_v | lsu_replay_i;
  always_comb begin
    unique case ({|rp_mask_q, lsq_replay_v})
      2'b10, 2'b11: iq_replay_t = rp_pend_tid;
      2'b01:        iq_replay_t = lsq_replay_t;
      default:      iq_replay_t = lsu_replay_tid_i;
    endcase
  end

  always_comb begin
    rp_mask_d = rp_mask_q;
    if (|rp_mask_q) rp_mask_d[rp_pend_tid] = 1'b0;
    if (lsq_replay_v && (lsq_replay_t != iq_replay_t))
      rp_mask_d[lsq_replay_t] = 1'b1;
    if (lsu_replay_i && (lsu_replay_tid_i != iq_replay_t))
      rp_mask_d[lsu_replay_tid_i] = 1'b1;
    if (flush_i) rp_mask_d = '0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) rp_mask_q <= '0;
    else         rp_mask_q <= rp_mask_d;
  end

  // svt-stage: end ISS
  g6lc_lsq #(
      .G6LCCfg   (G6LCCfg),
      .HypCfg    (HypCfg),
      .LD_ENTRIES(LD_N),
      .ST_ENTRIES(ST_N),
      .NR_ALLOC  (NP),
      .NR_UPDATE (NP)
  ) i_lsq (
      .clk_i,
      .rst_ni,
      .phys_valid_i, .phys_addr_i, .phys_id_i, .phys_hart_i, .phys_size_i,
      .mod_valid_i, .mod_addr_i, .phys_pending_o, .phys_replay_o,
      .commit_ld_i(commit_ld),
      .flush_i,
      .cancelled_mask_i,
      .sb_live_i   (sb_live_i),
      .ld_alloc_i (ld_alloc),
      .st_alloc_i (st_alloc),
      .alloc_id_i (alloc_ids),
      .alloc_hart_i(grp_hart),
      .alloc_pc_i (alloc_pcs),
      .ld_full_o  (ld_full),
      .st_full_o  (st_full),
      .ld_free_o  (ld_free),
      .st_free_o  (st_free),
      .addr_valid_i(agu_valid),
      .addr_id_i   (agu_id),
      .addr_i      (agu_addr),
      .addr_is_st_i(agu_is_st),
      .addr_size_i (agu_size),
      .st_data_valid_i(st_data_v),
      .st_data_id_i   (st_data_id),
      .st_data_i      (st_data),
      .complete_valid_i(wb_valid_i),
      .complete_id_i   (wb_id_i),
      .complete_is_st_i(complete_is_st),
      .commit_st_i(commit_st),
      .commit_id_i(commit_st_id),
      .commit_ptr_i(commit_ptr_i),
      .ld_query_i (issue_valid_o[0] && iss_sbe_q[0].fu == LOAD),
      .ld_query_addr_i(ld_qaddr),
      .ld_query_size_i(ld_qsize),
      .ld_query_id_i  (iss_sbe_q[0].trans_id),
      // T6b: the issuing load's hart -- the query orders only against the
      // load's own hart's stores.
      .ld_query_hart_i(HID_W'(iss_sbe_q[0].hart_id)),
      .st_live_mask_o (st_live_mask),
      .st_unresolved_mask_o(st_unresolved_mask),
      .st_hart_mask_o (st_hart_mask),
      .store_pending_o(store_pend),
      .stl_forward_o(stl_fwd),
      .stl_data_o   (),
      .stl_stall_o  (stl_stall),
      .lsq_busy_o   (lsq_busy),
      .mem_violation_o    (mem_violation_o),
      .mem_violation_id_o (mem_violation_id_o),
      .mem_violation_pc_o (mem_violation_pc),
      .ld_checked_o  (ld_checked_o),
      .replay_valid_o(lsq_replay_v),
      .replay_tid_o  (lsq_replay_t)
  );

  // Multi-port store train + observed-dependence train; clear on full
  // flush or mispredict.
  logic [NP-1:0] memdep_st_v;
  logic [NP-1:0][G6LCCfg.VLEN-1:0] memdep_st_pc;
  for (genvar p = 0; p < NP; p++) begin : gen_memdep_st
    assign memdep_st_v[p]  = dispatch_ack_o[p] && grp_is_st_q[p];
    assign memdep_st_pc[p] = grp_sbe_q[p].pc;
  end

  logic [NP-1:0] md_query;
  logic [NP-1:0][G6LCCfg.VLEN-1:0] md_pc;
  for (genvar p = 0; p < NP; p++) begin : gen_md_q
    assign md_query[p] = can_go && dispatch_valid_i[p] && is_ld[p];
    assign md_pc[p]    = dispatch_sbe_i[p].pc;
  end

  g6lc_memdep #(
      .G6LCCfg (G6LCCfg),
      .NR_SETS (64),
      .NR_TRAIN(NP),
      .NR_QUERY(NP)
  ) i_memdep (
      .clk_i,
      .rst_ni,
      .flush_i (flush_i | mispredict_i),
      .enable_i(G6LCCfg.MemDepPredEn),
      .st_valid_i(memdep_st_v),
      .st_pc_i   (memdep_st_pc),
      // One query per issue lane at the rename capture edge. The verdict
      // is registered and sampled into that lane's may_bypass at publish.
      .ld_query_i(md_query),
      .ld_pc_i   (md_pc),
      .train_valid_i(mem_violation_o),
      .train_pc_i  (mem_violation_pc),
      .store_pending_i(store_pend),
      .stall_o   (md_stall_v),
      .predict_o (md_predict_v)
  );

  assign lsq_stall_o = mem_stall || lsq_disp_block ||
                       ((|grp_v_q) && !grp_go);

  // Keep observability nets live.
  logic _unused;
  assign _unused = |iqi_spec | |iss_spec_q | |iss_prd_q | ld_full | st_full;

  // svt-stage: class ISS decision
  // hyp8: no absorb claim -- the staged presentation is not hidden by
  // real-WB scheduling (IqSpecWakeup==0 in the executable profile).

//pragma translate_off
  // +disp_trace: dispatch/IQ lifecycle probe (diagnostic only).
  localparam int unsigned IQE =
      (NB <= 1) ? IQ_N : ((HypCfg.IqBankEntries < 1) ? 1 : HypCfg.IqBankEntries);
  bit disp_life_trace;
  int unsigned disp_cyc = 0;
  int unsigned disp_lo, disp_hi;
  logic [NB-1:0][IQE-1:0]                          dinfo_v;
  logic [NB-1:0][IQE-1:0][G6LCCfg.TRANS_ID_BITS-1:0] dinfo_tid;
  logic [NB-1:0][IQE-1:0][2:0]                     dinfo_rdy;
  logic [NB-1:0][IQE-1:0]                          dacked;
  initial begin
    disp_life_trace = $test$plusargs("disp_trace");
    disp_lo = 0;
    disp_hi = 3000;
    void'($value$plusargs("trace_from=%d", disp_lo));
    void'($value$plusargs("trace_to=%d", disp_hi));
  end

  always @(posedge clk_i) begin
    if (!rst_ni) begin
      disp_cyc = 0;
      dinfo_v = '0;
      dacked = '0;
    end else if (disp_life_trace) begin
      disp_cyc++;
      if (disp_cyc >= disp_lo && disp_cyc <= disp_hi) begin
        for (int unsigned p = 0; p < NP; p++) begin
          // IQ allocation: the all-or-nothing group ack places the lane
          // on the steered bank's returned slot.
          if (dispatch_ack_o[p]) begin
            $display("[disp] alloc c=%0d p=%0d tid=%0d bank=%0d ent=%0d fu=%0d rd=%0d prs1=%0d prs2=%0d prd=%0d rs1_rdy=%b rs2_rdy=%b rs3_rdy=%b busy_prs1=%b busy_prs2=%b",
                     disp_cyc, p, grp_tid[p], i_iq.asgn[p],
                     i_iq.wr_entry[p], grp_sbe_q[p].fu,
                     grp_sbe_q[p].rd, grp_prs1_q[p], grp_prs2_q[p],
                     grp_prd_q[p], grp_rs1_ready[p], grp_rs2_ready[p],
                     grp_rs3_ready[p],
                     ren_int_busy[grp_prs1_q[p]],
                     ren_int_busy[grp_prs2_q[p]]);
            // Rename marks the new prd busy at the same publish edge.
            $display("[disp] busyset c=%0d prd=%0d tid=%0d",
                     disp_cyc, grp_prd_q[p], grp_tid[p]);
          end
        end
        // Integer busy clears: wb completions plus commit-publish writes.
        for (int unsigned w = 0; w < G6LCCfg.NrWbPorts; w++)
          if (data_wb_valid[w])
            $display("[disp] wbclr c=%0d port=%0d tid=%0d prd=%0d cmt=0",
                     disp_cyc, w, wb_id_i[w], data_wb_prd[w]);
        for (int unsigned c = 0; c < PRF_MIRROR; c++)
          if (data_wb_valid[G6LCCfg.NrWbPorts + c])
            $display("[disp] wbclr c=%0d port=%0d tid=%0d prd=%0d cmt=1",
                     disp_cyc, G6LCCfg.NrWbPorts + c,
                     commit_instr_i[c].trans_id,
                     data_wb_prd[G6LCCfg.NrWbPorts + c]);
        for (int unsigned p = 0; p < NP; p++) begin
          // Arb select this cycle (grant at the take/accept decision).
          if (i_iq.i_arb.win_v[p] && i_iq.i_arb.take_ok[p])
            $display("[disp] grant c=%0d port=%0d tid=%0d bank=%0d ent=%0d",
                     disp_cyc, p, i_iq.i_arb.win[p].tid,
                     i_iq.i_arb.win[p].bank, i_iq.i_arb.win[p].entry);
          if (i_iq.i_arb.win_v[p] && i_iq.i_arb.take_ok[p] &&
              cancelled_mask_i[i_iq.i_arb.win[p].tid])
            $display("[disp] kill c=%0d port=%0d tid=%0d why=arb_sel_cancel",
                     disp_cyc, p, i_iq.i_arb.win[p].tid);
          if (i_iq.i_arb.win_q[p].v &&
              cancelled_mask_i[i_iq.i_arb.win_q[p].tid])
            $display("[disp] kill c=%0d port=%0d tid=%0d why=arb_winq_cancel",
                     disp_cyc, p, i_iq.i_arb.win_q[p].tid);
          if (i_iq.i_arb.pres_q[p].v &&
              cancelled_mask_i[i_iq.i_arb.pres_q[p].tid])
            $display("[disp] kill c=%0d port=%0d tid=%0d why=arb_pres_cancel",
                     disp_cyc, p, i_iq.i_arb.pres_q[p].tid);
          // Take into dispatch staging and pop to the IRO.
          if (iqi_take[p])
            $display("[disp] take c=%0d port=%0d tid=%0d",
                     disp_cyc, p, iqi_sbe[p].trans_id);
          if (iss_pop[p])
            $display("[disp] pop c=%0d port=%0d tid=%0d",
                     disp_cyc, p, iss_sbe_q[p].trans_id);
          if (issue_valid_o[p] || issue_ack_i[p])
            $display("[disp] iro c=%0d port=%0d tid=%0d v=%b ack=%b",
                     disp_cyc, p, iss_sbe_q[p].trans_id,
                     issue_valid_o[p], issue_ack_i[p]);
          // Kill-class events on the staged / presented records.
          if (iss_v_q[p] && flush_i)
            $display("[disp] kill c=%0d port=%0d tid=%0d why=flush",
                     disp_cyc, p, iss_sbe_q[p].trans_id);
          if (iss_v_q[p] && cancelled_mask_i[iss_sbe_q[p].trans_id])
            $display("[disp] kill c=%0d port=%0d tid=%0d why=staged_cancel",
                     disp_cyc, p, iss_sbe_q[p].trans_id);
          if (iqi_valid[p] && cancelled_mask_i[iqi_sbe[p].trans_id])
            $display("[disp] kill c=%0d port=%0d tid=%0d why=cand_cancel",
                     disp_cyc, p, iqi_sbe[p].trans_id);
          if (iqi_valid[p] && (flush_i || flush_unissued_i))
            $display("[disp] kill c=%0d port=%0d tid=%0d why=flushblk",
                     disp_cyc, p, iqi_sbe[p].trans_id);
          if (iqi_valid[p] && fp_blocked[p])
            $display("[disp] kill c=%0d port=%0d tid=%0d why=fpblk",
                     disp_cyc, p, iqi_sbe[p].trans_id);
        end
        // Per-entry state: rdy-bit changes and entries that vanish
        // without a bank ack (cancel/flush/take-side free or defect).
        for (int unsigned b = 0; b < NB; b++) begin
          for (int unsigned e = 0; e < IQE; e++) begin
            if (dinfo_v[b][e] &&
                dinfo_rdy[b][e] != i_iq.info_rdy[b][e] &&
                i_iq.info_v[b][e])
              $display("[disp] rdy c=%0d bank=%0d ent=%0d tid=%0d rdy=%b",
                       disp_cyc, b, e, i_iq.info_tid[b][e],
                       i_iq.info_rdy[b][e]);
            if (dinfo_v[b][e] && !i_iq.info_v[b][e] && !dacked[b][e])
              $display("[disp] kill c=%0d bank=%0d ent=%0d tid=%0d why=vanish canc=%b flush=%b",
                       disp_cyc, b, e, dinfo_tid[b][e],
                       cancelled_mask_i[dinfo_tid[b][e]],
                       flush_i || flush_unissued_i);
          end
        end
      end
      dinfo_v   = i_iq.info_v;
      dinfo_tid = i_iq.info_tid;
      dinfo_rdy = i_iq.info_rdy;
      for (int unsigned b = 0; b < NB; b++)
        for (int unsigned e = 0; e < IQE; e++) begin
          dacked[b][e] = 1'b0;
          for (int unsigned p = 0; p < NP; p++)
            if (i_iq.aack[b][p] && i_iq.aack_idx[b][p] == IQE'(e))
              dacked[b][e] = 1'b1;
        end
    end
  end

  // r44 state-derived-cache invariant: the captured FP-use predicates
  // must equal the expressions they cache, evaluated over the held
  // iss_fpsel_q/iss_sbe_q record — checked every cycle (rst_ni), not
  // only while the lane is valid, since the registers hold across
  // flush/cancel/pop exactly like the record they shadow.
  int unsigned fp_pred_checked_n = 0;
  int unsigned fp_pred_active_fp_n = 0;
  int unsigned fp_pred_active_int_n = 0;
  for (genvar p = 0; p < NP; p++) begin : gen_fp_pred_eq
    logic ref_fpa, ref_fpb, ref_fpc;
    assign ref_fpa = G6LCCfg.FpPresent && iss_fpsel_q[p] &&
                     iss_sbe_q[p].ooo_renamed && is_rs1_fpr(iss_sbe_q[p].op);
    assign ref_fpb = G6LCCfg.FpPresent && iss_fpsel_q[p] &&
                     iss_sbe_q[p].ooo_renamed && is_rs2_fpr(iss_sbe_q[p].op);
    assign ref_fpc = G6LCCfg.FpPresent && iss_fpsel_q[p] &&
                     iss_sbe_q[p].ooo_renamed && is_imm_fpr(iss_sbe_q[p].op);
    always_ff @(posedge clk_i) begin
      if (rst_ni) begin
        if (p == 0) fp_pred_checked_n <= fp_pred_checked_n + 1;
        if (p == 0 && iss_v_q[p] &&
            (iss_fpa_q[p] || iss_fpb_q[p] || iss_fpc_q[p]))
          fp_pred_active_fp_n <= fp_pred_active_fp_n + 1;
        if (p == 0 && iss_v_q[p] && !iss_fpsel_q[p])
          fp_pred_active_int_n <= fp_pred_active_int_n + 1;
        g6lc_fp_pred_eq : assert (
            iss_fpa_q[p] === ref_fpa &&
            iss_fpb_q[p] === ref_fpb &&
            iss_fpc_q[p] === ref_fpc)
          else $error("g6lc_ooo_dispatch: FP predicate cache diverged lane %0d (%b%b%b != %b%b%b)",
                      p, iss_fpa_q[p], iss_fpb_q[p], iss_fpc_q[p],
                      ref_fpa, ref_fpb, ref_fpc);
      end
    end
  end
  final begin
    if ($test$plusargs("equiv_report"))
      $display("[equiv] g6lc_ooo_dispatch fp_pred: checked=%0d lane0_active_fp=%0d lane0_active_int=%0d",
               fp_pred_checked_n, fp_pred_active_fp_n, fp_pred_active_int_n);
  end
//pragma translate_on

endmodule
