// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5 production OoO dispatch (config-gated; OoOEn=0 is netlist identity):
// multi-port rename + IQ + ROB + LSQ/CAM + PRF operands for IRO cutover + live AGU.
//
// Recovery timeline (FSE S3 — single ordering for mispredict vs full flush):
//   1. Same cycle as branch resolve mispredict:
//        - controller: flush_if + flush_unissued (not full flush_i)
//        - scoreboard: SpeculativeSb cancels younger TIDs → cancelled_mask_i
//        - rename: mispredict_i restores map/free/busy from branch ckpt
//        - IQ / ROB / LSQ: squash entries whose TID is in cancelled_mask_i
//        - PRF: WB gated by !cancelled_mask[wb_tid]
//        - memdep: flush_i | mispredict_i clears store-set table
//   2. Exception / fence / CSR side-effect:
//        - controller asserts flush_i (and more) → full structure clear
//        - rename full reset; IQ/ROB/LSQ flush_i; memdep flush
//   3. commit_drop retires cancelled SB slots without architectural write.
//
// Bottleneck optimizations:
//   * Single-cycle multi-port rename (later ports see earlier allocs)
//   * Precise free+busy+map checkpoint on branch / restore on mispredict
//   * WB → busy-table wakeup + PRF write-through + issue bypass
//   * IQ same-cycle chain wakeup + multi age-ordered grant
//   * Live AGU (rs1+imm) / store data into LSQ at issue
//   * LSQ CAM / STL forward; memdep train on store + observed dependence
//   * Multi-WB ROB complete by trans_id; multi freelist free at commit
//   * LSQ full only blocks mem dispatch (ALU continues)

module g6lc_ooo_dispatch
  import ariane_pkg::*;
  import g6lc_ooo_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type scoreboard_entry_t = logic
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    input  logic flush_unissued_i,
    // Younger wrong-path SB slots (SpeculativeSb cancel + same-cycle bmiss)
    input  logic [CVA6Cfg.NR_SB_ENTRIES-1:0]                   cancelled_mask_i,
    input  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0]       dispatch_sbe_i,
    input  logic              [CVA6Cfg.NrIssuePorts-1:0][31:0] dispatch_orig_i,
    input  logic              [CVA6Cfg.NrIssuePorts-1:0]       dispatch_valid_i,
    output logic              [CVA6Cfg.NrIssuePorts-1:0]       dispatch_ack_o,
    output scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0]       issue_sbe_o,
    output logic              [CVA6Cfg.NrIssuePorts-1:0][31:0] issue_orig_o,
    output logic              [CVA6Cfg.NrIssuePorts-1:0]       issue_valid_o,
    input  logic              [CVA6Cfg.NrIssuePorts-1:0]       issue_ack_i,
    // PRF operands for IRO (production cutover when OoOEn)
    output logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.XLEN-1:0] issue_op_a_o,
    output logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.XLEN-1:0] issue_op_b_o,
    output logic [CVA6Cfg.NrIssuePorts-1:0]                   issue_op_a_valid_o,
    output logic [CVA6Cfg.NrIssuePorts-1:0]                   issue_op_b_valid_o,
    // Third operand, FP only. The value cannot ride back in sbe.result: that
    // field still holds the rs3 REGISTER NUMBER the consumer would re-read.
    output logic [CVA6Cfg.NrIssuePorts-1:0][CVA6Cfg.FLen-1:0] issue_op_c_o,
    output logic [CVA6Cfg.NrIssuePorts-1:0]                   issue_op_c_valid_o,
    // WB
    input  logic [CVA6Cfg.NrWbPorts-1:0]                            wb_valid_i,
    input  logic [CVA6Cfg.NrWbPorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] wb_id_i,
    input  logic [CVA6Cfg.NrWbPorts-1:0][CVA6Cfg.XLEN-1:0]          wb_data_i,
    input  logic [CVA6Cfg.NrWbPorts-1:0]                            wb_exc_i,
    // Architectural commit write, mirrored into the PRF. Results produced AT
    // commit (CSR read data, AMO/LR response) are substituted by commit_stage
    // into wdata_o and never appear on wb_data_i, so without this a renamed
    // consumer would read the execute-stage placeholder instead.
    input  logic [CVA6Cfg.NrCommitPorts-1:0]                        commit_we_i,
    input  logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.XLEN-1:0]      commit_wdata_i,
    input  logic [CVA6Cfg.NrCommitPorts-1:0]                        commit_ack_i,
    input  scoreboard_entry_t [CVA6Cfg.NrCommitPorts-1:0]           commit_instr_i,
    // Oldest live scoreboard slot: the age anchor for LSQ store ordering and
    // the IQ's per-entry older-store gate.
    input  logic [CVA6Cfg.TRANS_ID_BITS-1:0]                        commit_ptr_i,
    input  logic                                                    mispredict_i,
    // Resolving branch's scoreboard trans_id (bp_resolve_t.trans_id): selects
    // the checkpoint level to unwind to via the per-tid tag table below.
    input  logic [CVA6Cfg.TRANS_ID_BITS-1:0]                        mispredict_id_i,
    // PMU group-1 probes
    output logic freelist_empty_o,
    output logic rob_full_o,
    output logic iq_full_o,
    output logic lsq_stall_o,
    output logic rename_stall_o,
    output logic stl_forward_o
);

  localparam int unsigned ROB_N = (CVA6Cfg.RobEntries == 0) ? CVA6Cfg.NR_SB_ENTRIES
                                                            : CVA6Cfg.RobEntries;
  localparam int unsigned NH = CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts;
  localparam int unsigned HID_W = NH <= 1 ? 1 : $clog2(NH);
  localparam int unsigned PRF_N = (CVA6Cfg.PrfEntries == 0) ? (1 + 31 * NH + ROB_N + 8)
                                                            : CVA6Cfg.PrfEntries;
  localparam int unsigned IQ_N  = (CVA6Cfg.IqEntries == 0) ? ROB_N : CVA6Cfg.IqEntries;
  localparam int unsigned LD_N  = (CVA6Cfg.LsqLoadEntries == 0) ? 8 : CVA6Cfg.LsqLoadEntries;
  localparam int unsigned ST_N  = (CVA6Cfg.LsqStoreEntries == 0) ? 8 : CVA6Cfg.LsqStoreEntries;
  localparam int unsigned PRF_W = ooo_prf_w(PRF_N);
  // FP physical file. Sized like the integer one but with 32 committed
  // identities rather than 31, because f0 is a real register. Derived rather
  // than given its own CVA6Cfg field: no target needs to tune it independently
  // yet, and an unused config knob is a maintenance cost. Collapses to a single
  // entry when FP is absent so the whole class disappears.
  localparam int unsigned FPRF_N = CVA6Cfg.FpPresent ? (32 * NH + ROB_N + 8) : 1;
  localparam int unsigned FPRF_W = CVA6Cfg.FpPresent ? ooo_prf_w(FPRF_N) : 1;
  localparam int unsigned ROB_W = ooo_rob_w(ROB_N);
  localparam int unsigned CKPT  = (CVA6Cfg.BPCkptDepth == 0) ? 8 : CVA6Cfg.BPCkptDepth;
  localparam int unsigned NP    = CVA6Cfg.NrIssuePorts;

  localparam int unsigned CKPT_W = $clog2(CKPT+1);
  localparam int unsigned PRF_MIRROR =
      (CVA6Cfg.RVZacas && CVA6Cfg.NrCommitPorts > 1) ? 2 : 1;
  localparam int unsigned DATA_WB_NR = CVA6Cfg.NrWbPorts + PRF_MIRROR;

  // Elaboration guards, not simulation assertions. The legality checks in
  // config_pkg::check_cfg sit under `pragma translate_off`, so an unsound
  // configuration still ELABORATES AND SYNTHESISES and only complains in
  // simulation. Refuse to build instead. These are duplicated in check_cfg;
  // both copies must move together.
  //
  // The reasons below are narrower than they were. Phase 4 gave rename per-hart
  // maps, checkpoints and register ownership, and Phase 5 added the split FP
  // register class — so neither guard any longer means "the mechanism does not
  // exist". Keep the messages honest about what is actually still missing,
  // because a guard that misstates its own reason is how a stale refusal
  // survives long after the work is done.
  if (CVA6Cfg.NrHarts > 1) begin : gen_err_ooo_smt
    // g6lc_rename is per-hart, but core/ooo/** outside it still contains no
    // hart signal at all: the IQ, ROB and LSQ are hart-blind, so a load can be
    // ordered against (and forwarded from) the peer hart's speculative stores.
    $error("OoO multi-hart integration is unqualified: mixed residency and recovery ownership remain open.");
  end
  if (CVA6Cfg.FpPresent) begin : gen_err_ooo_fp
    // The FP class is implemented and tested at module level, and the
    // FP-enabled full core elaborates and synthesises clean. What is missing is
    // behavioural evidence: no FP program has been simulated on this path, and
    // there is no independent-reference comparison.
    $error("OoO FP register class is implemented but unqualified: full release qualification is pending.");
  end

  logic [NP-1:0] need_rd, is_br, is_ld, is_st;
  logic [NP-1:0][HID_W-1:0] dispatch_hart;
  logic [CVA6Cfg.NrCommitPorts-1:0][HID_W-1:0] commit_hart;

  if (PRF_N < 1 + 31 * NH || PRF_W > 8 || FPRF_W > 8 || CKPT < NH) begin : gen_err_ooo_geometry
    $error("OoO physical pool or checkpoint geometry cannot represent every hart.");
  end
  // Raw IQ grant, before the FP read-port gate below. Declared here rather
  // than beside fp_port_sel because the IQ instantiation above consumes it and
  // slang -- unlike Verilator -- requires declaration before use.
  logic [NP-1:0] iq_issue_valid, iq_issue_ack;
  logic [NP-1:0][4:0] rs1_a, rs2_a, rd_a, rs3_a;
  logic [NP-1:0] is_fpr_rd_c, is_fpr_rs1_c, is_fpr_rs2_c, is_fpr_rs3_c;
  logic [NP-1:0][FPRF_W-1:0] fprs1, fprs2, fprs3, fprd, fprd_old;
  logic [NP-1:0] rs3_rdy;
  logic ren_stall, can_go, lsq_disp_block;
  logic [NP-1:0][PRF_W-1:0] prs1, prs2, prd, prd_old;
  logic [NP-1:0][CKPT_W-1:0] ren_ckpt_id;
  logic [NP-1:0] rs1_rdy, rs2_rdy;
  logic [CVA6Cfg.NrWbPorts-1:0][PRF_W-1:0] wb_prd;
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0][PRF_W-1:0] tid_prd_q, tid_prd_d;
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0][PRF_W-1:0] tid_old_q, tid_old_d;
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0] tid_is_st_q, tid_is_st_d;
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0] tid_late_result_q, tid_late_result_d;
  logic [DATA_WB_NR-1:0] data_wb_valid, fdata_wb_valid;
  logic [DATA_WB_NR-1:0][PRF_W-1:0] data_wb_prd;
  logic [DATA_WB_NR-1:0][FPRF_W-1:0] fdata_wb_prd;
  // Destination CLASS per trans_id, plus the FP tags. A writeback carries
  // only a trans_id, so this is what tells the completion path which file to
  // write and which busy bit to clear.
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0] tid_is_fpr_q, tid_is_fpr_d;
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0][FPRF_W-1:0] tid_fprd_q, tid_fprd_d;
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0][FPRF_W-1:0] tid_fold_q, tid_fold_d;
  logic [CVA6Cfg.NrWbPorts-1:0][FPRF_W-1:0] fwb_prd;
  logic [CVA6Cfg.NrWbPorts-1:0] fwb_value_valid;
  // Checkpoint tag per scoreboard slot: which rename checkpoint level the
  // branch occupying that tid consumed. '1 (out of range) = untagged -> the
  // recovery path unwinds to the youngest checkpoint, the legacy behaviour.
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0][CKPT_W-1:0] tid_ckpt_q, tid_ckpt_d;

  for (genvar p = 0; p < NP; p++) begin : gen_ports
    assign dispatch_hart[p] = NH > 1 ? HID_W'(dispatch_sbe_i[p].hart_id) : '0;
    assign rs1_a[p] = dispatch_sbe_i[p].rs1[4:0];
    assign rs2_a[p] = dispatch_sbe_i[p].rs2[4:0];
    assign rd_a[p]  = dispatch_sbe_i[p].rd;
    // There is no rs3 field: FP compute ops carry the third register number in
    // result[4:0] (is_imm_fpr covers FADD:FSUB as well as FMADD:FNMADD). The
    // overload is disjoint by FU — the AGU below reads result as the immediate
    // only for LOAD/STORE, and FP loads are is_rd_fpr without being is_imm_fpr.
    assign rs3_a[p] = dispatch_sbe_i[p].result[4:0];
    assign is_fpr_rd_c[p]  = CVA6Cfg.FpPresent && is_rd_fpr(dispatch_sbe_i[p].op);
    assign is_fpr_rs1_c[p] = CVA6Cfg.FpPresent && is_rs1_fpr(dispatch_sbe_i[p].op);
    assign is_fpr_rs2_c[p] = CVA6Cfg.FpPresent && is_rs2_fpr(dispatch_sbe_i[p].op);
    assign is_fpr_rs3_c[p] = CVA6Cfg.FpPresent && is_imm_fpr(dispatch_sbe_i[p].op);
    // An FP destination now needs a rename like any other, and f0 is NOT
    // exempt the way x0 is — dropping the rd!=0 filter for the FP class is the
    // whole point of keeping the two namespaces separate.
    assign need_rd[p] = dispatch_valid_i[p] &&
                        (is_fpr_rd_c[p] ? 1'b1 : (rd_a[p] != 5'd0));
    assign is_br[p] = dispatch_valid_i[p] && (dispatch_sbe_i[p].fu == CTRL_FLOW);
    assign is_ld[p] = dispatch_valid_i[p] && (dispatch_sbe_i[p].fu == LOAD);
    assign is_st[p] = dispatch_valid_i[p] && (dispatch_sbe_i[p].fu == STORE);
  end

  logic rob_full, iq_full, ld_full, st_full;
  logic [$clog2(CVA6Cfg.LsqLoadEntries+1)-1:0] ld_free;
  logic [$clog2(CVA6Cfg.LsqStoreEntries+1)-1:0] st_free;
  logic store_pend, stl_fwd, stl_stall, lsq_busy, md_stall, mem_stall;
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0] st_live_mask;

  assign rob_full_o = rob_full;
  assign iq_full_o  = iq_full;
  // LSQ pressure blocks unless the whole group fits: dispatch is all-or-nothing,
  // so admitting a group with more memory ops than free entries would leave the
  // surplus without a queue entry. Counts are registered state and the group size
  // comes from ungated intent, so this cannot feed back through can_go.
  always_comb begin
    automatic int unsigned n_ld, n_st;
    n_ld = 0;
    n_st = 0;
    for (int unsigned p = 0; p < NP; p++) begin
      n_ld += int'(is_ld[p]);
      n_st += int'(is_st[p]);
    end
    lsq_disp_block = (n_ld > int'(ld_free)) || (n_st > int'(st_free));
  end
  // Dispatch is all-or-nothing across the group: partial allocation would leave
  // ROB/rename/LSQ indices out of program order and break flush recovery, which
  // walks those structures assuming contiguous in-order allocation.
  assign can_go = !rob_full && !iq_full && !ren_stall && !flush_i && !flush_unissued_i && !lsq_disp_block;
  assign rename_stall_o = (|dispatch_valid_i) && !can_go;
  assign freelist_empty_o = ren_stall;
  assign stl_forward_o = stl_fwd;

  logic [CVA6Cfg.NrWbPorts-1:0] wb_value_valid;
  always_comb begin
    for (int unsigned w = 0; w < CVA6Cfg.NrWbPorts; w++) begin
      wb_prd[w] = tid_prd_q[wb_id_i[w]];
      fwb_prd[w] = tid_fprd_q[wb_id_i[w]];
      // One writeback bus, two files: the destination class decides which
      // busy table the completion clears.
      wb_value_valid[w] = wb_valid_i[w] && !wb_exc_i[w] &&
                          !cancelled_mask_i[wb_id_i[w]] && !tid_is_fpr_q[wb_id_i[w]] &&
                          !tid_late_result_q[wb_id_i[w]];
      fwb_value_valid[w] = CVA6Cfg.FpPresent && wb_valid_i[w] && !wb_exc_i[w] &&
                           !cancelled_mask_i[wb_id_i[w]] && tid_is_fpr_q[wb_id_i[w]];
    end
  end

  // The FP PRF has NO commit-write mirror, and that is a conclusion rather than
  // an omission. The integer mirror exists only because commit_stage
  // SUBSTITUTES a value at commit — csr_rdata_i for CSR, amo_resp_i.result for
  // AMO — which never reaches wb_data_i. Neither CSR nor AMO has an FP
  // destination (`is_rd_fpr` excludes both), and for an FP destination
  // commit_stage writes plain commit_instr.result, i.e. the value the execute
  // writeback already delivered to the FP PRF. So no FP value is produced at
  // commit and no FP write port is needed — worth having, since PRF ports are
  // the measured area driver.
  //
  // The property that makes this sound is that the two classes are mutually
  // exclusive at commit, which commit_stage enforces with an if/else on
  // is_rd_fpr. Pin it: if it ever broke, the integer mirror would silently
  // write the integer PRF for an FP-destination instruction.
  //pragma translate_off
  always_ff @(posedge clk_i) begin
    if (rst_ni && CVA6Cfg.FpPresent) begin
      for (int unsigned c = 0; c < CVA6Cfg.NrCommitPorts; c++) begin
        if (commit_we_i[c] && commit_is_fpr[c]) begin
          $error("OOO_COMMIT_CLASS port=%0d claims both a GPR write and an FP destination", c);
        end
        // Discriminating probe for the FP bring-up race. commit_is_fpr is
        // derived from tid_is_fpr_q, a per-trans_id bit written at dispatch.
        // If a slot's bit is ever stale relative to the instruction actually
        // committing there, an integer op is treated as FP at commit: its
        // architectural map update and its predecessor free are both skipped,
        // so later readers of that register see the OLD physical. That would
        // explain integer corruption from an FP-only change. Compare the
        // tracked class against the committing opcode, which is ground truth.
        if (commit_arch[c] &&
            (tid_is_fpr_q[commit_instr_i[c].trans_id] !=
             (CVA6Cfg.FpPresent && is_rd_fpr(commit_instr_i[c].op)))) begin
          $error("OOO_COMMIT_CLASS_STALE port=%0d tid=%0d tracked=%b opcode_fpr=%b",
                 c, commit_instr_i[c].trans_id,
                 tid_is_fpr_q[commit_instr_i[c].trans_id],
                 (CVA6Cfg.FpPresent && is_rd_fpr(commit_instr_i[c].op)));
        end
      end
    end
  end
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert ((iq_issue_ack & ~issue_valid_o) == '0)
        else $fatal(1, "OOO_ISSUE_ACCEPT_WITHOUT_OFFER");
      if (flush_i || flush_unissued_i) begin
        assert (issue_valid_o == '0 && iq_issue_ack == '0 && dispatch_ack_o == '0)
          else $fatal(1, "OOO_RECOVERY_ACCEPT");
      end
    end
  end
  //pragma translate_on

  // Multi-port freelist free on all commit ports
  logic [CVA6Cfg.NrCommitPorts-1:0] free_en;
  logic [CVA6Cfg.NrCommitPorts-1:0][PRF_W-1:0] free_prd;
  // A committing branch's checkpoint can never be unwound to again, so commit is
  // what returns it to the pool. Commit is in program order, matching the order
  // the checkpoints were taken.
  logic [CVA6Cfg.NrCommitPorts-1:0] ckpt_retire;
  logic [CVA6Cfg.NrCommitPorts-1:0] commit_wr, commit_arch;
  logic [CVA6Cfg.NrCommitPorts-1:0][4:0] commit_rd;
  logic [CVA6Cfg.NrCommitPorts-1:0][PRF_W-1:0] commit_prd;
  // FP counterparts. Every `rd != 0` filter on the integer side is absent here
  // on purpose: f0 is an ordinary register, so an f0 commit updates the
  // architectural map and an f0 predecessor is freed like any other.
  logic [CVA6Cfg.NrCommitPorts-1:0] ffree_en, commit_is_fpr;
  logic [CVA6Cfg.NrCommitPorts-1:0][FPRF_W-1:0] ffree_prd, commit_fprd;
  always_comb begin
    for (int unsigned c = 0; c < CVA6Cfg.NrCommitPorts; c++) begin
      commit_arch[c] = commit_ack_i[c] && !cancelled_mask_i[commit_instr_i[c].trans_id];
      commit_is_fpr[c] = CVA6Cfg.FpPresent && commit_arch[c] &&
                         tid_is_fpr_q[commit_instr_i[c].trans_id];
      commit_fprd[c] = tid_fprd_q[commit_instr_i[c].trans_id];
      ffree_en[c]  = commit_is_fpr[c];
      ffree_prd[c] = tid_fold_q[commit_instr_i[c].trans_id];
      free_en[c]  = commit_arch[c] && !commit_is_fpr[c] &&
                    (commit_instr_i[c].rd != 5'd0) &&
                    (tid_old_q[commit_instr_i[c].trans_id] != '0);
      free_prd[c] = tid_old_q[commit_instr_i[c].trans_id];
      ckpt_retire[c] = commit_arch[c] &&
                       (tid_ckpt_q[commit_instr_i[c].trans_id] != '1);
      // Architectural map update: the destination and the physical register this
      // committing instruction owns. A non-renamed op carries physical 0 and is
      // filtered inside rename.
      commit_wr[c]  = commit_arch[c] &&
                      (commit_is_fpr[c] || commit_instr_i[c].rd != 5'd0);
      commit_hart[c] = NH > 1 ? HID_W'(commit_instr_i[c].hart_id) : '0;
      commit_rd[c]  = commit_instr_i[c].rd[4:0];
      commit_prd[c] = tid_prd_q[commit_instr_i[c].trans_id];
    end
  end

  always_comb begin
    data_wb_valid = '0;
    data_wb_prd = '0;
    fdata_wb_valid = '0;
    fdata_wb_prd = '0;
    for (int unsigned w = 0; w < CVA6Cfg.NrWbPorts; w++) begin
      data_wb_valid[w] = wb_value_valid[w];
      data_wb_prd[w] = wb_prd[w];
      fdata_wb_valid[w] = fwb_value_valid[w];
      fdata_wb_prd[w] = fwb_prd[w];
    end
    for (int unsigned c = 0; c < PRF_MIRROR; c++) begin
      data_wb_valid[CVA6Cfg.NrWbPorts+c] = commit_arch[c] && commit_we_i[c] && commit_prd[c] != '0;
      data_wb_prd[CVA6Cfg.NrWbPorts+c] = commit_prd[c];
    end
  end

  g6lc_rename #(
      .PRF_ENTRIES(PRF_N),
      .PRF_W      (PRF_W),
      .FPRF_ENTRIES(CVA6Cfg.FpPresent ? FPRF_N : 0),
      .FPRF_W      (FPRF_W),
      .NR_PORTS   (NP),
      .NR_HARTS   (NH),
      .NR_FREE    (CVA6Cfg.NrCommitPorts),
      .NR_WB      (DATA_WB_NR),
      .CKPT_DEPTH (CKPT)
  ) i_rename (
      .clk_i,
      .rst_ni,
      .flush_i,
      .mispredict_i,
      // Branch-tag plumbing: each dispatched branch recorded the checkpoint
      // level it consumed (rename's ckpt_id_o) keyed by its trans_id. On
      // resolve, the resolving branch's id selects its own level, so an OLDER
      // branch unwinds to its own checkpoint instead of the youngest.
      .mispredict_level_i(tid_ckpt_q[mispredict_id_i]),
      // Ungated intent. can_go is already delivered through enable_i, which
      // gates every state update inside rename, so gating valid_i with it as
      // well was redundant and closed a combinational loop
      // (can_go -> valid_i -> capacity/stall_c -> ren_stall -> can_go).
      // Rename must see what the group *needs* independently of whether the
      // group is allowed to proceed.
      // Single architectural namespace until Phase 4 lands the rest of the
      // per-hart work; check_cfg still refuses OoOEn with NrHarts>1.
      .hart_i    (dispatch_hart),
      .flush_hart_i('0),
      .is_fpr_rd_i(is_fpr_rd_c), .is_fpr_rs1_i(is_fpr_rs1_c),
      .is_fpr_rs2_i(is_fpr_rs2_c),
      .rs3_i(rs3_a), .is_fpr_rs3_i(is_fpr_rs3_c),
      .fprs3_o(fprs3), .rs3_ready_o(rs3_rdy),
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
      .rs1_ready_o(rs1_rdy),
      .rs2_ready_o(rs2_rdy),
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
      .enable_i  (can_go)
  );

  scoreboard_entry_t [NP-1:0] tagged_sbe;
  always_comb begin
    tagged_sbe = dispatch_sbe_i;
    for (int unsigned p = 0; p < NP; p++) begin
      tagged_sbe[p].p_rs1 = 8'(prs1[p]);
      tagged_sbe[p].p_rs2 = 8'(prs2[p]);
      tagged_sbe[p].p_rd  = 8'(prd[p]);
      tagged_sbe[p].p_frs1 = 8'(fprs1[p]);
      tagged_sbe[p].p_frs2 = 8'(fprs2[p]);
      tagged_sbe[p].p_frs3 = 8'(fprs3[p]);
      tagged_sbe[p].p_frd  = 8'(fprd[p]);
      tagged_sbe[p].ooo_renamed = can_go && dispatch_valid_i[p];
    end
  end

  always_comb begin
    tid_prd_d = tid_prd_q;
    tid_old_d = tid_old_q;
    tid_is_st_d = tid_is_st_q;
    tid_late_result_d = tid_late_result_q;
    tid_is_fpr_d = tid_is_fpr_q;
    tid_fprd_d = tid_fprd_q;
    tid_fold_d = tid_fold_q;
    tid_ckpt_d = tid_ckpt_q;
    for (int unsigned p = 0; p < NP; p++) begin
      if (dispatch_ack_o[p]) begin
        tid_prd_d[dispatch_sbe_i[p].trans_id] = prd[p];
        tid_old_d[dispatch_sbe_i[p].trans_id] = prd_old[p];
        tid_is_st_d[dispatch_sbe_i[p].trans_id] = is_st[p];
        tid_late_result_d[dispatch_sbe_i[p].trans_id] = dispatch_sbe_i[p].fu == CSR ||
            (CVA6Cfg.RVA && is_amo(dispatch_sbe_i[p].op));
        tid_is_fpr_d[dispatch_sbe_i[p].trans_id] = is_fpr_rd_c[p];
        tid_fprd_d[dispatch_sbe_i[p].trans_id] = fprd[p];
        tid_fold_d[dispatch_sbe_i[p].trans_id] = fprd_old[p];
        // Record the checkpoint level this branch consumed. Non-branch ports
        // emit '1 from rename, which is exactly the "no tag -> youngest"
        // default the recovery path expects for an untagged resolve. Writing it
        // unconditionally also clears a previous branch's tag from a reused
        // slot, which would otherwise retire a checkpoint this slot never took.
        tid_ckpt_d[dispatch_sbe_i[p].trans_id] = is_br[p] ? ren_ckpt_id[p] : '1;
      end
    end
    // The resolving branch's own checkpoint is consumed by the unwind, so its
    // later commit must not retire a second one.
    if (mispredict_i) tid_ckpt_d[mispredict_id_i] = '1;
    if (flush_i) begin
      tid_prd_d = '0;
      tid_old_d = '0;
      tid_is_st_d = '0;
      tid_late_result_d = '0;
      tid_is_fpr_d = '0;
      tid_fprd_d = '0;
      tid_fold_d = '0;
      // tid_ckpt survives a flush: entries are keyed by trans_id and rewritten
      // whenever that slot's next branch dispatches, so a stale tag can only be
      // read by a resolve for a branch that was never re-dispatched -- which
      // cannot resolve.
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

  // ROB — multi-WB complete by scoreboard trans_id
  logic [CVA6Cfg.NrWbPorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] rob_c_tid;
  always_comb begin
    for (int unsigned w = 0; w < CVA6Cfg.NrWbPorts; w++) rob_c_tid[w] = wb_id_i[w];
  end

  logic [NP-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] rob_alloc_tid;
  always_comb begin
    for (int unsigned p = 0; p < NP; p++) rob_alloc_tid[p] = dispatch_sbe_i[p].trans_id;
  end

  g6lc_rob #(
      .ROB_ENTRIES(ROB_N),
      .ROB_W      (ROB_W),
      .NR_ALLOC   (NP),
      .NR_RETIRE  (CVA6Cfg.NrCommitPorts),
      .NR_COMPLETE(CVA6Cfg.NrWbPorts),
      .TID_W      (CVA6Cfg.TRANS_ID_BITS),
      .NR_SB      (CVA6Cfg.NR_SB_ENTRIES),
      .entry_t    (scoreboard_entry_t)
  ) i_rob (
      .clk_i,
      .rst_ni,
      .flush_i,
      .cancelled_mask_i,
      .alloc_valid_i (dispatch_ack_o),
      .alloc_entry_i (tagged_sbe),
      .alloc_tid_i   (rob_alloc_tid),
      .alloc_id_o    (),
      .full_o        (rob_full),
      .complete_valid_i(wb_valid_i),
      .complete_tid_i  (rob_c_tid),
      .complete_exc_i  (wb_exc_i),
      .retire_valid_o(),
      .retire_entry_o(),
      .retire_id_o   (),
      .retire_ack_i  (commit_ack_i)
  );

  // ---- PRF first (needed for live AGU) — issue selects feed PRF read ----
  // IQ + LSQ need issue_valid; PRF reads issue_sbe tags. Order: IQ, then PRF/AGU/LSQ.

  logic [NP-1:0][PRF_W-1:0] issue_prd;
  scoreboard_entry_t [NP-1:0] tagged_from_rename;
  assign tagged_from_rename = tagged_sbe;

  // LSQ + memdep (declared before IQ mem_stall)
  logic [NP-1:0]                 agu_valid;
  logic [NP-1:0][CVA6Cfg.PLEN-1:0] agu_addr;
  logic [NP-1:0]                 agu_is_st;
  logic [NP-1:0][1:0]            agu_size;
  logic [NP-1:0]                 st_data_v;
  logic [NP-1:0][CVA6Cfg.XLEN-1:0] st_data;
  logic [NP-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] agu_id;
  logic [NP-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] st_data_id;
  logic [CVA6Cfg.PLEN-1:0] ld_qaddr;
  logic [1:0]              ld_qsize;
  logic [CVA6Cfg.NrWbPorts-1:0] complete_is_st;

  // IQ (mem_stall from LSQ/memdep below — combinational loop risk:
  // mem_stall uses issue_valid; IQ uses mem_stall. Break: mem_stall only from
  // LSQ state + memdep on issue candidate ports is OK if stl uses registered
  // LSQ and memdep table. issue_valid is comb from IQ; stl_stall uses ld_query
  // which is issue_valid. That forms IQ→mem_stall→IQ. Mitigate: mem_stall for
  // select uses only older_st/md from registered state + ld_full, NOT stl_stall
  // of current select. STL applied as post-select recheck / op forward only.

  // Prefer: stall mem issue when memdep predicts or an OLDER store is pending.
  // md_stall and the registered st_live_mask/commit_ptr are safe inside the IQ
  // select; the load's own trans_id is not available here (it is a select
  // result), so the per-entry age comparison lives inside g6lc_iq and this
  // path stays free of the issue_valid → stall → issue_valid loop.
  assign mem_stall = md_stall || stl_stall;

  g6lc_iq #(
      .CVA6Cfg(CVA6Cfg),
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
      .disp_valid_i    (dispatch_valid_i & {NP{can_go && !ren_stall}}),
      .disp_sbe_i      (tagged_from_rename),
      .disp_orig_i     (dispatch_orig_i),
      .disp_prs1_i     (prs1),
      .disp_prs2_i     (prs2),
      .disp_prd_i      (prd),
      .disp_rs1_ready_i(rs1_rdy),
      .disp_rs2_ready_i(rs2_rdy),
      // FP wakeup: an entry waiting on an FP producer must see the FP
      // writeback, not the integer one.
      .disp_rs3_ready_i(rs3_rdy),
      .disp_fprs1_i(fprs1), .disp_fprs2_i(fprs2), .disp_fprs3_i(fprs3),
      .disp_fpr_rs1_i(is_fpr_rs1_c), .disp_fpr_rs2_i(is_fpr_rs2_c),
      .disp_fpr_rs3_i(is_fpr_rs3_c),
      .fwb_valid_i     (fdata_wb_valid),
      .fwb_prd_i       (fdata_wb_prd),
      .disp_ack_o      (dispatch_ack_o),
      .full_o          (iq_full),
      .wb_valid_i      (data_wb_valid),
      .wb_prd_i        (data_wb_prd),
      .issue_sbe_o     (issue_sbe_o),
      .issue_orig_o    (issue_orig_o),
      .issue_prd_o     (issue_prd),
      .issue_valid_o   (iq_issue_valid),
      .issue_ack_i     (iq_issue_ack),
      // Not md_stall: the predictor's stall is a combinational function of this
      // IQ's own issue outputs (its query is the selected load), so feeding it
      // back into selection is a real cycle, which MemDepPredEn=1 exposes. It is
      // also wrongly conservative — store_pending is global, so it blocks a load
      // whose only pending stores are YOUNGER and cannot alias it. Safety comes
      // from the per-entry age gate below (st_live_mask/commit_ptr), which
      // already blocks a load behind every older store. A predictor that
      // RELAXES that gate needs an alias proof and its own dispatch-time query;
      // until then the predictor trains and reports, and does not gate issue.
      .mem_stall_i     (1'b0),
      .st_live_mask_i  (st_live_mask),
      .commit_ptr_i    (commit_ptr_i)
  );

  // Block PRF writeback for cancelled SB slots (wrong-path after mispredict)

  // PRF dual-read per issue port + multi-write WB with write-through
  logic [NP*2-1:0][PRF_W-1:0] prf_raddr;
  logic [NP*2-1:0][CVA6Cfg.XLEN-1:0] prf_rdata;
  // Write ports: the execute writebacks first, then one mirror per commit port.
  // g6lc_prf lets the highest port win a same-address clash, so the commit
  // mirror — architectural truth — overrides a coincident execute writeback.
  // Only commit port 0 can carry a value produced AT commit: commit_stage drives
  // wdata_o[0] from csr_rdata_i / amo_resp_i.result, while port 1 writes
  // commit_instr[1].result, which the execute writeback already delivered. The
  // sole exception is the AMOCAS.Q dual write, so a second mirror port is added
  // only when RVZacas is configured. PRF write ports are expensive.
  localparam int unsigned PRF_WR = CVA6Cfg.NrWbPorts + PRF_MIRROR;
  logic [PRF_WR-1:0][PRF_W-1:0] prf_waddr;
  logic [PRF_WR-1:0][CVA6Cfg.XLEN-1:0] prf_wdata;
  logic [PRF_WR-1:0] prf_we;

  always_comb begin
    for (int unsigned p = 0; p < NP; p++) begin
      prf_raddr[p*2+0] = issue_sbe_o[p].ooo_renamed ? PRF_W'(issue_sbe_o[p].p_rs1) : '0;
      prf_raddr[p*2+1] = issue_sbe_o[p].ooo_renamed ? PRF_W'(issue_sbe_o[p].p_rs2) : '0;
    end
    for (int unsigned w = 0; w < CVA6Cfg.NrWbPorts; w++) begin
      prf_waddr[w] = wb_prd[w];
      prf_wdata[w] = wb_data_i[w];
      prf_we[w]    = wb_value_valid[w] && (wb_prd[w] != '0);
    end
    // Mirror exactly what the architectural register file receives, keyed by the
    // committing instruction's OWN physical register rather than by a trans_id
    // that could already belong to someone else.
    for (int unsigned c = 0; c < PRF_MIRROR; c++) begin
      prf_waddr[CVA6Cfg.NrWbPorts+c] = commit_prd[c];
      prf_wdata[CVA6Cfg.NrWbPorts+c] = commit_wdata_i[c];
      prf_we[CVA6Cfg.NrWbPorts+c]    = commit_we_i[c] && (commit_prd[c] != '0);
    end
  end

  // FP physical file. THREE read ports total (rs1/rs2/rs3), muxed to whichever
  // issue port holds the FP op — deliberately mirroring the in-order FP
  // regfile, whose fp_raddr_pack is also [2:0] muxed across issue ports, so
  // only one FP instruction reads per cycle. Giving every issue port its own
  // three would be a PERFORMANCE change (dual-issue FP) smuggled in alongside a
  // correctness feature, and PRF ports are the measured area driver: one added
  // write port cost 7,681 generic cells. Widen this deliberately, with numbers.
  localparam int unsigned FPRF_WR = CVA6Cfg.NrWbPorts;
  logic [2:0][FPRF_W-1:0] fprf_raddr;
  logic [2:0][CVA6Cfg.FLen-1:0] fprf_rdata;
  logic [FPRF_WR-1:0][FPRF_W-1:0] fprf_waddr;
  logic [FPRF_WR-1:0][CVA6Cfg.FLen-1:0] fprf_wdata;
  logic [FPRF_WR-1:0] fprf_we;
  logic [NP-1:0] fp_port_sel, fp_blocked;
  // The FP file has three read ports for the whole group, so at most one
  // issue port can read FP operands per cycle. A second FP consumer in the
  // same group is held back rather than issued with operands it cannot read.
  // Gating the IQ's RAW valid (not issue_valid_o) keeps fp_port_sel out of
  // its own cone: fp_port_sel <- iq_issue_valid, issue_valid_o <- f(fp_port_sel).
  assign issue_valid_o = iq_issue_valid & ~fp_blocked & {NP{!flush_i && !flush_unissued_i}};
  assign iq_issue_ack = issue_ack_i & issue_valid_o;

  always_comb begin
    automatic logic taken;
    taken = 1'b0;
    fp_port_sel = '0;
    fp_blocked = '0;
    fprf_raddr = '0;
    // Lowest-numbered issue port carrying a renamed FP op owns the read ports.
    for (int unsigned p = 0; p < NP; p++) begin
      if (CVA6Cfg.FpPresent && iq_issue_valid[p] &&
          issue_sbe_o[p].ooo_renamed &&
          (is_rs1_fpr(issue_sbe_o[p].op) || is_rs2_fpr(issue_sbe_o[p].op) ||
           is_imm_fpr(issue_sbe_o[p].op))) begin
        if (taken) fp_blocked[p] = 1'b1;
        else begin
        taken = 1'b1;
        fp_port_sel[p] = 1'b1;
        fprf_raddr[0] = FPRF_W'(issue_sbe_o[p].p_frs1);
        fprf_raddr[1] = FPRF_W'(issue_sbe_o[p].p_frs2);
        fprf_raddr[2] = FPRF_W'(issue_sbe_o[p].p_frs3);
        end
      end
    end
    for (int unsigned w = 0; w < CVA6Cfg.NrWbPorts; w++) begin
      fprf_waddr[w] = fwb_prd[w];
      fprf_wdata[w] = wb_data_i[w][CVA6Cfg.FLen-1:0];
      fprf_we[w]    = fwb_value_valid[w];
    end
  end

  g6lc_prf #(
      .DATA_WIDTH (CVA6Cfg.FLen),
      .PRF_ENTRIES(FPRF_N),
      .NR_READ    (3),
      .NR_WRITE   (FPRF_WR),
      .PRF_W      (FPRF_W),
      .ZERO_REG_ZERO(1'b0)
  ) i_fprf (
      .clk_i,
      .rst_ni,
      .raddr_i(fprf_raddr),
      .rdata_o(fprf_rdata),
      .waddr_i(fprf_waddr),
      .wdata_i(fprf_wdata),
      .we_i   (fprf_we)
  );

  g6lc_prf #(
      .DATA_WIDTH (CVA6Cfg.XLEN),
      .PRF_ENTRIES(PRF_N),
      .NR_READ    (NP * 2),
      .NR_WRITE   (PRF_WR),
      .PRF_W      (PRF_W)
  ) i_prf (
      .clk_i,
      .rst_ni,
      .raddr_i(prf_raddr),
      .rdata_o(prf_rdata),
      .waddr_i(prf_waddr),
      .wdata_i(prf_wdata),
      .we_i   (prf_we)
  );

  logic [NP-1:0][CVA6Cfg.XLEN-1:0] op_a_agu, op_b_pre;
  // Operand assemble from the register file plus writeback bypass. This block
  // must NOT read the store-to-load forward: the address-generation value
  // op_a_agu feeds the LSQ query, and the forward is produced by that query, so
  // reading stl_* here closes a combinational loop
  // (ld_qaddr -> LSQ CAM -> stl_fwd -> op_a -> ld_qaddr). Dependency analysis is
  // per always_comb block, so the forward is applied in a separate block below.
  always_comb begin
    for (int unsigned p = 0; p < NP; p++) begin
      automatic logic [CVA6Cfg.XLEN-1:0] a, b;
      a = prf_rdata[p*2+0];
      b = prf_rdata[p*2+1];
      for (int unsigned w = 0; w < CVA6Cfg.NrWbPorts; w++) begin
        if (wb_value_valid[w] && issue_sbe_o[p].ooo_renamed) begin
          if (wb_prd[w] == PRF_W'(issue_sbe_o[p].p_rs1) && wb_prd[w] != '0)
            a = wb_data_i[w];
          if (wb_prd[w] == PRF_W'(issue_sbe_o[p].p_rs2) && wb_prd[w] != '0)
            b = wb_data_i[w];
        end
      end
      // FP sources read the FP physical file, not the integer one. Without
      // this a dependent fadd.d falls through to the ARCHITECTURAL f-register
      // and misses every in-flight renamed producer.
      if (CVA6Cfg.FpPresent && fp_port_sel[p] && issue_sbe_o[p].ooo_renamed) begin
        if (is_rs1_fpr(issue_sbe_o[p].op)) begin
          a = CVA6Cfg.XLEN'(fprf_rdata[0]);
          for (int unsigned w = 0; w < CVA6Cfg.NrWbPorts; w++)
            if (fwb_value_valid[w] && fwb_prd[w] == FPRF_W'(issue_sbe_o[p].p_frs1))
              a = wb_data_i[w];
        end
        if (is_rs2_fpr(issue_sbe_o[p].op)) begin
          b = CVA6Cfg.XLEN'(fprf_rdata[1]);
          for (int unsigned w = 0; w < CVA6Cfg.NrWbPorts; w++)
            if (fwb_value_valid[w] && fwb_prd[w] == FPRF_W'(issue_sbe_o[p].p_frs2))
              b = wb_data_i[w];
        end
      end
      op_a_agu[p] = a;
      op_b_pre[p] = b;
    end
  end

  // operand_a of a LOAD is its base register -- the LSU computes
  // vaddr = imm + operand_a, so it must NOT be overwritten with forwarded
  // data. The byte-exact data path lives downstream in the LSU store_buffer
  // (full PA + byte enables, spec+commit queues, commit handoff); the LSQ
  // supplies only the ordering stall (stl_stall) since the serial LSU pipe
  // lands any older store in the buffer before a younger load's PA compare.
  always_comb begin
    for (int unsigned p = 0; p < NP; p++) begin
      issue_op_a_o[p] = op_a_agu[p];
      issue_op_b_o[p] = op_b_pre[p];
      issue_op_a_valid_o[p] = issue_valid_o[p] && issue_sbe_o[p].ooo_renamed;
      issue_op_b_valid_o[p] = issue_valid_o[p] && issue_sbe_o[p].ooo_renamed;
      // Only the port that won the muxed FP read ports has a valid rs3.
      issue_op_c_o[p] = fprf_rdata[2];
      for (int unsigned w = 0; w < CVA6Cfg.NrWbPorts; w++)
        if (CVA6Cfg.FpPresent && fwb_value_valid[w] && fp_port_sel[p] &&
            fwb_prd[w] == FPRF_W'(issue_sbe_o[p].p_frs3))
          issue_op_c_o[p] = wb_data_i[w][CVA6Cfg.FLen-1:0];
      issue_op_c_valid_o[p] = CVA6Cfg.FpPresent && issue_valid_o[p] &&
                              issue_sbe_o[p].ooo_renamed && fp_port_sel[p] &&
                              is_imm_fpr(issue_sbe_o[p].op);
    end
  end

  // Live AGU at issue: vaddr = imm + rs1 (matches load_store_unit AGU)
  always_comb begin
    automatic logic [CVA6Cfg.XLEN-1:0] vaddr_x;
    agu_valid = '0;
    agu_addr  = '0;
    agu_is_st = '0;
    agu_size  = '0;
    agu_id    = '0;
    st_data_v = '0;
    st_data   = '0;
    st_data_id = '0;
    vaddr_x   = '0;
    for (int unsigned p = 0; p < NP; p++) begin
      if (issue_valid_o[p] && issue_ack_i[p] && issue_sbe_o[p].ooo_renamed &&
          (issue_sbe_o[p].fu == LOAD || issue_sbe_o[p].fu == STORE)) begin
        vaddr_x = $unsigned($signed(issue_sbe_o[p].result) + $signed(issue_op_a_o[p]));
        agu_valid[p] = 1'b1;
        agu_addr[p]  = CVA6Cfg.PLEN'(vaddr_x[CVA6Cfg.PLEN-1:0]);
        agu_is_st[p] = (issue_sbe_o[p].fu == STORE);
        agu_size[p]  = ariane_pkg::extract_transfer_size(issue_sbe_o[p].op);
        agu_id[p]    = issue_sbe_o[p].trans_id;
        if (issue_sbe_o[p].fu == STORE) begin
          st_data_v[p]  = 1'b1;
          st_data[p]    = issue_op_b_o[p];
          st_data_id[p] = issue_sbe_o[p].trans_id;
        end
      end
    end
  end

  // Load query address for CAM (port 0). Real transfer size so the LSQ can do
  // byte-overlap hazard checks instead of whole-word group matches.
  always_comb begin
    automatic logic [CVA6Cfg.XLEN-1:0] v;
    ld_qaddr = '0;
    ld_qsize = '0;
    v        = '0;
    if (issue_valid_o[0] && issue_sbe_o[0].fu == LOAD && issue_sbe_o[0].ooo_renamed) begin
      v = $unsigned($signed(issue_sbe_o[0].result) + $signed(op_a_agu[0]));
      ld_qaddr = CVA6Cfg.PLEN'(v[CVA6Cfg.PLEN-1:0]);
      ld_qsize = ariane_pkg::extract_transfer_size(issue_sbe_o[0].op);
    end
  end

  always_comb begin
    for (int unsigned w = 0; w < CVA6Cfg.NrWbPorts; w++)
      complete_is_st[w] = tid_is_st_q[wb_id_i[w]];
  end

  // Store commit across every commit port, not just port 0: a store retiring on
  // a higher port would otherwise never release its LSQ entry.
  logic [CVA6Cfg.NrCommitPorts-1:0] commit_st;
  logic [CVA6Cfg.NrCommitPorts-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] commit_st_id;
  always_comb begin
    for (int unsigned c = 0; c < CVA6Cfg.NrCommitPorts; c++) begin
      commit_st[c]    = commit_arch[c] && (commit_instr_i[c].fu == STORE);
      commit_st_id[c] = commit_instr_i[c].trans_id;
    end
  end

  logic [NP-1:0] ld_alloc, st_alloc;
  logic [NP-1:0][CVA6Cfg.TRANS_ID_BITS-1:0] alloc_ids;
  always_comb begin
    for (int unsigned p = 0; p < NP; p++) begin
      ld_alloc[p]  = dispatch_ack_o[p] && is_ld[p];
      st_alloc[p]  = dispatch_ack_o[p] && is_st[p];
      alloc_ids[p] = dispatch_sbe_i[p].trans_id;
    end
  end

  g6lc_lsq #(
      .CVA6Cfg   (CVA6Cfg),
      .LD_ENTRIES(LD_N),
      .ST_ENTRIES(ST_N),
      .NR_ALLOC  (NP),
      .NR_UPDATE (NP)
  ) i_lsq (
      .clk_i,
      .rst_ni,
      .flush_i,
      .cancelled_mask_i,
      .ld_alloc_i (ld_alloc),
      .st_alloc_i (st_alloc),
      .alloc_id_i (alloc_ids),
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
      .ld_query_i (issue_valid_o[0] && issue_sbe_o[0].fu == LOAD),
      .ld_query_addr_i(ld_qaddr),
      .ld_query_size_i(ld_qsize),
      .ld_query_id_i  (issue_sbe_o[0].trans_id),
      .st_live_mask_o (st_live_mask),
      .store_pending_o(store_pend),
      .stl_forward_o(stl_fwd),
      .stl_data_o   (),
      .stl_stall_o  (stl_stall),
      .lsq_busy_o   (lsq_busy)
  );

  // Multi-port store train + observed-dependence train; clear on full flush or mispredict
  logic [NP-1:0] memdep_st_v;
  logic [NP-1:0][CVA6Cfg.VLEN-1:0] memdep_st_pc;
  always_comb begin
    for (int unsigned p = 0; p < NP; p++) begin
      memdep_st_v[p]  = dispatch_ack_o[p] && is_st[p];
      memdep_st_pc[p] = dispatch_sbe_i[p].pc;
    end
  end

  g6lc_memdep #(
      .CVA6Cfg (CVA6Cfg),
      .NR_SETS (64),
      .NR_TRAIN(NP)
  ) i_memdep (
      .clk_i,
      .rst_ni,
      .flush_i (flush_i | mispredict_i),
      .enable_i(CVA6Cfg.MemDepPredEn),
      .st_valid_i(memdep_st_v),
      .st_pc_i   (memdep_st_pc),
      .ld_query_i(issue_valid_o[0] && issue_sbe_o[0].fu == LOAD),
      .ld_pc_i   (issue_sbe_o[0].pc),
      .dep_observe_i(stl_stall || (store_pend && issue_valid_o[0] && issue_sbe_o[0].fu == LOAD)),
      .store_pending_i(store_pend),
      .stall_o   (md_stall),
      .predict_o ()
  );

  assign lsq_stall_o = mem_stall || lsq_disp_block;

endmodule
