// hyp8 provenance: REWRITTEN (sv-timing emit base, staged wrapper)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// SPDX-FileCopyrightText: machine-generated
//
// hyp8 (group 6): scoreboard wrapper -- owns slots, transaction IDs, the
// commit pointer and the cancel mask (the AGENTS-ooo-contract §1 owner).
// Internals are staged:
//   sb_lifecycle      slot array + issue/commit pointers + counts +
//                     alloc/WB/kill/commit/flush next-state merge
//   sb_cancel         bmiss qualification + same-cycle window +
//                     cancelled_mask_o + per-slot kill request
//   sb_head           per-hart oldest-live discovery (registered 2-step
//                     for the recovery outputs; combinational emit form
//                     for the MixedSmt commit select)
//   sb_commit_bundle  commit-port slot select + the presented bundle
//                     with the same-cycle WB-record merge + ld_checked
//                     gate + commit_bundle_valid_o
// New ports (hyp8-authorized): ld_checked_i (load-check mask; tied high
// until the LSQ group lands) and commit_bundle_valid_o (per-port
// committable/droppable candidate qualifier for the registered-ack
// commit protocol).

module scoreboard
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::HypDefault,
    parameter type bp_resolve_t = logic,
    parameter type exception_t = logic,
    parameter type scoreboard_entry_t = logic,
    parameter type forwarding_t = logic,
    parameter type writeback_t = logic,
    parameter type rs3_len_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input  logic                                          clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input  logic                                          rst_ni,
    // Is scoreboard full - PERF_COUNTERS
    output logic                                          sb_full_o,
    output logic                                          sb_empty_o,
    // FSE: younger-than-branch cancel fired this cycle (SpeculativeSb path) - PERF
    output logic                                          spec_cancel_o,
    // U5 production: per-SB-slot cancel mask (sticky cancelled | same-cycle bmiss window)
    // OoO IQ/ROB/LSQ squash younger wrong-path ops without full-pipe flush.
    output logic [G6LCCfg.NR_SB_ENTRIES-1:0]              cancelled_mask_o,
    // Per-slot issued mask (OoO IQ/LSQ liveness assertions)
    output logic [G6LCCfg.NR_SB_ENTRIES-1:0]              sb_live_o,
    // T6b: per-hart head of the live ring -- PC of the oldest issued entry
    // of each hart, found scanning from commit_pointer_q[0] in ring order.
    output logic [G6LCCfg.NrHarts-1:0][G6LCCfg.VLEN-1:0]  sb_head_pc_o,
    output logic [G6LCCfg.NrHarts-1:0]                    sb_head_valid_o,
    // LSQ alias validation: youngest load that read bytes an older store
    // resolved later - OoO only, tied low in order.
    input  logic                                          mem_violation_i,
    input  logic              [G6LCCfg.TRANS_ID_BITS-1:0] mem_violation_id_i,
    // T33: load unit hands back a load parked on a speculative store
    input  logic                                          lu_replay_i,
    input  logic              [G6LCCfg.TRANS_ID_BITS-1:0] lu_replay_id_i,
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0]              phys_pending_i,
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0]              phys_replay_i,
    input  logic                                          phys_mod_i,
    // Prevent from issuing - CONTROLLER
    input  logic                                          flush_unissued_instr_i,
    // Flush whole scoreboard - CONTROLLER
    input  logic                                          flush_i,
    // Writeback Handling of CVXIF
    input  logic                                          x_transaction_accepted_i,
    input  logic                                          x_issue_writeback_i,
    input  logic              [G6LCCfg.TRANS_ID_BITS-1:0] x_id_i,
    // advertise instruction to commit stage, if commit_ack_i is asserted
    // advance the commit pointer
    output scoreboard_entry_t [G6LCCfg.NrCommitPorts-1:0] commit_instr_o,
    // Instruction is cancelled - COMMIT_STAGE
    output logic              [G6LCCfg.NrCommitPorts-1:0] commit_drop_o,
    // Committing slot requests a refetch from its own PC - COMMIT_STAGE
    output logic              [G6LCCfg.NrCommitPorts-1:0] commit_replay_o,
    // hyp8: bundle carries a live committable/droppable candidate this
    // cycle - COMMIT_STAGE (registered-ack protocol qualifier)
    output logic              [G6LCCfg.NrCommitPorts-1:0] commit_bundle_valid_o,
    // hyp8: per-slot load-check -- a LOAD slot is committable only when
    // the LSQ reports its memory-order resolution. Tie high until the
    // LSQ group lands (g6lc_core.sv ties it; the gate lives in
    // sb_commit_bundle).
    input  logic              [G6LCCfg.NR_SB_ENTRIES-1:0] ld_checked_i,
    // Commit acknowledge - COMMIT_STAGE
    input  logic              [G6LCCfg.NrCommitPorts-1:0] commit_ack_i,

    // instruction to put on top of scoreboard e.g.: top pointer
    input  scoreboard_entry_t [G6LCCfg.NrIssuePorts-1:0]       decoded_instr_i,
    input  logic              [G6LCCfg.NrIssuePorts-1:0][31:0] orig_instr_i,
    input  logic              [G6LCCfg.NrIssuePorts-1:0]       decoded_instr_valid_i,
    output logic              [G6LCCfg.NrIssuePorts-1:0]       decoded_instr_ack_o,

    // instruction to issue logic
    output scoreboard_entry_t [G6LCCfg.NrIssuePorts-1:0]       issue_instr_o,
    output logic              [G6LCCfg.NrIssuePorts-1:0][31:0] orig_instr_o,
    output logic              [G6LCCfg.NrIssuePorts-1:0]       issue_instr_valid_o,
    input  logic              [G6LCCfg.NrIssuePorts-1:0]       issue_ack_i,
    // Forwarding - ISSUE_READ_OPERANDS
    output forwarding_t                                        fwd_o,

    // Result from branch unit - EX_STAGE
    input  bp_resolve_t                                   resolved_branch_i,
    // Transaction ID at which to write the result back - EX_STAGE
    input  logic [G6LCCfg.NrWbPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] trans_id_i,
    // Results to write back - EX_STAGE
    input  logic [G6LCCfg.NrWbPorts-1:0][G6LCCfg.XLEN-1:0] wbdata_i,
    // Exception from a functional unit - EX_STAGE
    input  exception_t [G6LCCfg.NrWbPorts-1:0] ex_i,
    // Indicates valid results - EX_STAGE
    input  logic [G6LCCfg.NrWbPorts-1:0] wt_valid_i,
    // Cvxif we for writeback - EX_STAGE
    input  logic x_we_i,
    // CVXIF destination register - ISSUE_STAGE
    input  logic [4:0] x_rd_i,

    // Issue pointer - RVFI
    output logic [ G6LCCfg.NrIssuePorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] rvfi_issue_pointer_o,
    // Commit pointer - RVFI
    output logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] rvfi_commit_pointer_o,
    // T6b-4b: reclaim pointer -- the oldest live slot.
    output logic [G6LCCfg.TRANS_ID_BITS-1:0]                    reclaim_ptr_o,
    // G1mf: result-valid aligned-00 RVI LOAD per hart
    output logic [G6LCCfg.NrHarts-1:0] g1mf_v_o,
    output logic [G6LCCfg.NrHarts-1:0][4:0] g1mf_rd_o,
    output logic [G6LCCfg.NrHarts-1:0][G6LCCfg.VLEN-1:4] g1mf_line_o,
    output logic [G6LCCfg.NrHarts-1:0] g1mf_a3_o
);
  // svt-stage: begin RDY

  // this is the FIFO struct of the issue queue
  typedef struct packed {
    logic issued;  // this bit indicates whether we issued this instruction
    logic cancelled;  // this instruction was cancelled (speculative scoreboard)
    logic replay;  // memory-order violation: commit refetches from this PC
    logic is_rd_fpr_flag;  // redundant meta info, added for speed
    scoreboard_entry_t sbe;  // this is the score board entry we will send to ex
  } sb_mem_t;

  localparam int unsigned SB_NH = (G6LCCfg.NrHarts < 1) ? 1 : G6LCCfg.NrHarts;
  localparam bit MixedSmt = (G6LCCfg.NrHarts > 1) && !G6LCCfg.SmtDrainedHandoff;

  sb_mem_t [G6LCCfg.NR_SB_ENTRIES-1:0] mem_q;
  logic [G6LCCfg.TRANS_ID_BITS-1:0] issue_pointer_q;
  logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] commit_pointer_q;
  logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] commit_sel_slot;
  logic [SB_NH-1:0][G6LCCfg.TRANS_ID_BITS-1:0] head_slot_c;
  logic [SB_NH-1:0] head_valid_c;
  logic bmiss;
  logic [G6LCCfg.NR_SB_ENTRIES-1:0] kill_req;

  sb_lifecycle #(
      .G6LCCfg (G6LCCfg),
      .bp_resolve_t (bp_resolve_t),
      .exception_t (exception_t),
      .scoreboard_entry_t (scoreboard_entry_t),
      .forwarding_t (forwarding_t),
      .sb_mem_t (sb_mem_t),
      .writeback_t (writeback_t)
  ) i_sb_lifecycle (
      .clk_i,
      .rst_ni,
      .sb_full_o,
      .sb_empty_o,
      .sb_live_o,
      .mem_violation_i,
      .mem_violation_id_i,
      .lu_replay_i,
      .lu_replay_id_i,
      .phys_replay_i,
      .flush_unissued_instr_i,
      .flush_i,
      .x_transaction_accepted_i,
      .x_issue_writeback_i,
      .x_id_i,
      .commit_ack_i,
      .commit_sel_slot_i (commit_sel_slot),
      .decoded_instr_i,
      .orig_instr_i,
      .decoded_instr_valid_i,
      .decoded_instr_ack_o,
      .issue_instr_o,
      .orig_instr_o,
      .issue_instr_valid_o,
      .issue_ack_i,
      .fwd_o,
      .resolved_branch_i,
      .bmiss_i      (bmiss),
      .kill_req_i   (kill_req),
      .trans_id_i,
      .wbdata_i,
      .ex_i,
      .wt_valid_i,
      .x_we_i,
      .x_rd_i,
      .rvfi_issue_pointer_o,
      .mem_q_o      (mem_q),
      .issue_pointer_q_o  (issue_pointer_q),
      .commit_pointer_q_o (commit_pointer_q),
      .reclaim_ptr_o,
      .g1mf_v_o,
      .g1mf_rd_o,
      .g1mf_line_o,
      .g1mf_a3_o
  );

  sb_cancel #(
      .G6LCCfg (G6LCCfg),
      .bp_resolve_t (bp_resolve_t),
      .sb_mem_t (sb_mem_t)
  ) i_sb_cancel (
      .resolved_branch_i,
      .mem_q_i          (mem_q),
      .issue_pointer_i  (issue_pointer_q),
      .bmiss_o          (bmiss),
      .spec_cancel_o,
      .cancelled_mask_o,
      .kill_req_o       (kill_req)
  );

  sb_head #(
      .G6LCCfg (G6LCCfg),
      .sb_mem_t (sb_mem_t)
  ) i_sb_head (
      .clk_i,
      .rst_ni,
      .flush_i,
      .mem_q_i        (mem_q),
      .commit_ptr_i   (commit_pointer_q[0]),
      .sb_head_pc_o,
      .sb_head_valid_o,
      .head_slot_c_o  (head_slot_c),
      .head_valid_c_o (head_valid_c)
  );

  sb_commit_bundle #(
      .G6LCCfg (G6LCCfg),
      .sb_mem_t (sb_mem_t),
      .scoreboard_entry_t (scoreboard_entry_t),
      .exception_t (exception_t)
  ) i_sb_commit_bundle (
      .mem_q_i          (mem_q),
      .commit_ptr_i     (commit_pointer_q),
      .head_slot_i      (head_slot_c),
      .head_valid_i     (head_valid_c),
      .wt_valid_i,
      .trans_id_i,
      .wbdata_i,
      .ex_i,
      .ld_checked_i,
      .phys_pending_i,
      .phys_mod_i,
      .commit_sel_slot_o (commit_sel_slot),
      .commit_instr_o,
      .commit_drop_o,
      .commit_replay_o,
      .commit_bundle_valid_o
  );

  //RVFI
  assign rvfi_commit_pointer_o = commit_sel_slot;

//pragma translate_off
  // assert that we never acknowledge a commit if the instruction is not valid
  // hyp8 contract: the drop path is validity-agnostic by design — a
  // cancelled load's ld_checked bit may be released before its
  // drop-commit lands, so an ack with commit_drop_o set need not carry
  // commit_instr_o[].valid.  The strict form is kept for non-drop acks.
  assert property (
    @(posedge clk_i) disable iff (!rst_ni) commit_ack_i[0] |-> (commit_instr_o[0].valid || commit_drop_o[0]))
  else $fatal(1, "Commit acknowledged but instruction is not valid");
  for (genvar cp = 1; cp < G6LCCfg.NrCommitPorts; cp++) begin : gen_commit_port_valid
    assert property (
        @(posedge clk_i) disable iff (!rst_ni) commit_ack_i[cp] |-> (commit_instr_o[cp].valid || commit_drop_o[cp]))
    else $fatal(1, "Commit acknowledged but instruction is not valid");
  end
  // assert that we never give an issue ack signal if the instruction is not valid
  for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin
    assert property (
      @(posedge clk_i) disable iff (!rst_ni) issue_ack_i[i] |-> issue_instr_valid_o[i])
    else $fatal(1, "Issue acknowledged but instruction is not valid");
  end

  // there should never be more than one instruction writing the same
  // transaction id
  for (genvar i = 0; i < G6LCCfg.NrWbPorts; i++) begin
    for (genvar j = 0; j < G6LCCfg.NrWbPorts; j++) begin
      assert property (
        @(posedge clk_i) disable iff (!rst_ni) wt_valid_i[i] && wt_valid_i[j] && (i != j) |-> (trans_id_i[i] != trans_id_i[j]))
      else
        $fatal(
            1,
            "Two or more functional units are retiring instructions with the same transaction id!"
        );
    end
  end

  // hyp8: common retirement event — an ack retires the slot presented
  // THIS cycle: it must be a live decidable bundle entry issued by the
  // scoreboard, not a previous-cycle presentation.
  for (genvar p = 0; p < G6LCCfg.NrCommitPorts; p++) begin : gen_ack_slot_chk
    assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
      commit_ack_i[p] |->
      (commit_bundle_valid_o[p] && mem_q[commit_sel_slot[p]].issued))
    else $fatal(1, "SBC_ACK_PRESENT: commit ack for a slot that was not presented");
  end

  // ----------------------------------------------------------------------
  // T6b-4b MIXED invariants -- per-hart commit heads over the shared ring.
  // ----------------------------------------------------------------------
  // hyp8: inline the condition so const-eval prunes under NrHarts==1.
  if ((G6LCCfg.NrHarts > 1) && !G6LCCfg.SmtDrainedHandoff) begin : gen_mixed_sbc_checks
    // Each committed port presents its hart's head, or the permitted legacy
    // same-hart +1 slot paired with a port-0 commit.
    for (genvar p = 0; p < G6LCCfg.NrCommitPorts; p++) begin : gen_port_head_chk
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
        commit_ack_i[p] |->
        (commit_sel_slot[p] == head_slot_c[commit_instr_o[p].hart_id]) ||
        ((p > 0) &&
         (commit_sel_slot[p] == commit_sel_slot[0] + G6LCCfg.TRANS_ID_BITS'(1)) &&
         (commit_instr_o[p].hart_id == commit_instr_o[0].hart_id) &&
         commit_ack_i[0]))
      else $fatal(1, "SBC_PORT_HEAD: commit port is neither a per-hart head nor the legacy +1 slot");
    end
    // Per-hart commit order is program order.
    int unsigned sbc_alloc_seq;
    int unsigned sbc_slot_seq[G6LCCfg.NR_SB_ENTRIES];
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        sbc_alloc_seq <= 0;
        foreach (sbc_slot_seq[s]) sbc_slot_seq[s] <= 0;
      end else begin
        int unsigned seq;
        seq = sbc_alloc_seq;
        for (int unsigned i = 0; i < G6LCCfg.NrIssuePorts; i++)
          if (decoded_instr_valid_i[i] && decoded_instr_ack_o[i] &&
              !flush_unissued_instr_i) begin
            seq = seq + 1;
            sbc_slot_seq[issue_pointer_q + G6LCCfg.TRANS_ID_BITS'(i)] <= seq;
          end
        sbc_alloc_seq <= seq;
      end
    end
    function automatic logic sbc_older_live(
        input int unsigned h, input int unsigned s);
      for (int unsigned i = 0; i < G6LCCfg.NR_SB_ENTRIES; i++) begin
        logic committing;
        committing = 1'b0;
        for (int unsigned q = 0; q < G6LCCfg.NrCommitPorts; q++)
          if (commit_ack_i[q] && (int'(commit_sel_slot[q]) == i))
            committing = 1'b1;
        if (mem_q[i].issued && !committing && (i != s) &&
            (mem_q[i].sbe.hart_id == $bits(mem_q[i].sbe.hart_id)'(h)) &&
            (sbc_slot_seq[i] < sbc_slot_seq[s]))
          return 1'b1;
      end
      return 1'b0;
    endfunction
    for (genvar p = 0; p < G6LCCfg.NrCommitPorts; p++) begin : gen_prog_order_chk
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
        commit_ack_i[p] |->
        !sbc_older_live(int'(commit_instr_o[p].hart_id),
                        int'(commit_sel_slot[p])))
      else $fatal(1, "SBC_PROG_ORDER: per-hart commit order is not program order");
    end
    // Flush-capable-privileged entries never commit off port 0.
    for (genvar p = 1; p < G6LCCfg.NrCommitPorts; p++) begin : gen_p1_priv_chk
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
        commit_ack_i[p] |-> !i_sb_commit_bundle.sb_privileged(mem_q[commit_sel_slot[p]]))
      else $fatal(1, "SBC_P1_PRIV: flush-capable-privileged entry committed off port 0");
    end
    // A cross-hart port-1 commit never coincides with a flush-capable
    // port-0 ack.
    if (G6LCCfg.NrCommitPorts > 1) begin : gen_xflush_chk
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
        (commit_ack_i[1] &&
         (commit_instr_o[1].hart_id != commit_instr_o[0].hart_id)) |->
        !(i_sb_commit_bundle.sb_privileged(mem_q[commit_sel_slot[0]]) && commit_ack_i[0]))
      else $fatal(1, "SBC_P1_XFLUSH: cross-hart port-1 commit under a flush-capable port-0 ack");
    end
    // A cross-hart port-1 commit never lands on a full-flush cycle.
    if (G6LCCfg.NrCommitPorts > 1) begin : gen_xcommit_flush_chk
      assert property (@(posedge clk_i) disable iff (!rst_ni)
        (commit_ack_i[1] &&
         (commit_instr_o[1].hart_id != commit_instr_o[0].hart_id)) |->
        !flush_i)
      else $fatal(1, "SBC_P1_FLUSH: cross-hart port-1 commit on a full-flush cycle");
    end
    // The reclaim window is contiguous: every live slot lies in
    // [reclaim, issue_pointer).
    logic [$clog2(G6LCCfg.NR_SB_ENTRIES+1)-1:0] sb_issued_cnt_chk;
    always_comb begin
      sb_issued_cnt_chk = '0;
      for (int unsigned i = 0; i < G6LCCfg.NR_SB_ENTRIES; i++)
        if (mem_q[i].issued) sb_issued_cnt_chk += 1'b1;
    end
    for (genvar s = 0; s < G6LCCfg.NR_SB_ENTRIES; s++) begin : gen_reclaim_chk
      assert property (@(posedge clk_i) disable iff (!rst_ni)
        mem_q[s].issued |->
        (((G6LCCfg.TRANS_ID_BITS'(s) - commit_pointer_q[0]) <
          (issue_pointer_q - commit_pointer_q[0])) ||
         ((issue_pointer_q == commit_pointer_q[0]) && (sb_issued_cnt_chk != '0))))
      else $fatal(1, "SBC_RECLAIM_WIN: live slot outside the reclaim window");
    end
    // Dispatch never allocates onto a live slot.
    for (genvar i = 0; i < G6LCCfg.NrIssuePorts; i++) begin : gen_overwrite_chk
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
        (decoded_instr_valid_i[i] && decoded_instr_ack_o[i] && !flush_unissued_instr_i) |->
        !mem_q[issue_pointer_q + G6LCCfg.TRANS_ID_BITS'(i)].issued)
      else $fatal(1, "SBC_NO_OVERWRITE: dispatch allocated onto a live scoreboard slot");
    end
  end
//pragma translate_on

//pragma translate_off
  // +smt_flow_trace window probe (+trace_from/+trace_to, default 0..3000):
  // [cnc] every set/clear edge of cancelled_mask_o / kill_req on the
  // watched tids {0,1,5}, with the producing cause: the comb bmiss window
  // (resolving branch tid) or the per-slot sticky cancelled bit. A mask
  // pulse that drops an in-flight LSU request must be traceable to the
  // exact resolve/sticky event that raised it.
  bit cnc_tr;
  int unsigned cnc_cyc = 0;
  int unsigned cnc_lo, cnc_hi;
  logic [2:0] cnc_mask_q = '0, cnc_kill_q = '0, cnc_stk_q = '0;
  initial begin
    cnc_tr = $test$plusargs("smt_flow_trace");
    cnc_lo = 0;
    cnc_hi = 3000;
    void'($value$plusargs("trace_from=%d", cnc_lo));
    void'($value$plusargs("trace_to=%d", cnc_hi));
  end

  always @(posedge clk_i) begin
    if (!rst_ni) begin
      cnc_cyc = 0;
      cnc_mask_q = '0;
      cnc_kill_q = '0;
      cnc_stk_q  = '0;
    end else if (cnc_tr) begin
      cnc_cyc++;
      if ((cnc_cyc >= cnc_lo) && (cnc_cyc <= cnc_hi)) begin
        for (int unsigned k = 0; k < 3; k++) begin
          automatic int unsigned t = (k == 0) ? 0 : (k == 1) ? 1 : 5;
          if (cancelled_mask_o[t] != cnc_mask_q[k] ||
              kill_req[t] != cnc_kill_q[k] ||
              mem_q[t].cancelled != cnc_stk_q[k]) begin
            $display("[cnc] c=%0d tid=%0d mask=%b->%b kill=%b->%b sticky=%b->%b bmiss=%b brv=%b brmisp=%b brtid=%0d iptr=%0d",
                     cnc_cyc, t, cnc_mask_q[k], cancelled_mask_o[t],
                     cnc_kill_q[k], kill_req[t],
                     cnc_stk_q[k], mem_q[t].cancelled,
                     bmiss, resolved_branch_i.valid,
                     resolved_branch_i.is_mispredict,
                     resolved_branch_i.trans_id, issue_pointer_q);
          end
          cnc_mask_q[k] = cancelled_mask_o[t];
          cnc_kill_q[k] = kill_req[t];
          cnc_stk_q[k]  = mem_q[t].cancelled;
        end
      end
    end
  end
//pragma translate_on

  // svt-stage: end RDY
  // svt-stage: class RDY decision
endmodule
