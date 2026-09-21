// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5.3 unified issue queue — compacting age-ordered multi-grant ready select.
// Bottleneck optimizations:
//   * Same-cycle WB tag wakeup
//   * Same-cycle dispatch/WB capture without speculative issue-time wakeup
//   * mem_stall only blocks LOAD; STORE/ALU/MULT/CTRL issue under mem pressure
//   * Dual-grant oldest-ready up to NrIssuePorts

module g6lc_iq
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter int unsigned DEPTH  = 16,
    parameter int unsigned PRF_W  = 6,
    parameter int unsigned NR_WB = CVA6Cfg.NrWbPorts,
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
    input  logic [CVA6Cfg.NR_SB_ENTRIES-1:0]             cancelled_mask_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0]              disp_valid_i,
    input  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] disp_sbe_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0][31:0]        disp_orig_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0][PRF_W-1:0]   disp_prs1_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0][PRF_W-1:0]   disp_prs2_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0][PRF_W-1:0]   disp_prd_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0]               disp_rs1_ready_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0]               disp_rs2_ready_i,
    // FP source tags + per-source class. rs3 is FP-only (FMA), so it has no
    // integer counterpart and its readiness is tracked separately.
    input  logic [CVA6Cfg.NrIssuePorts-1:0][FPRF_W-1:0]  disp_fprs1_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0][FPRF_W-1:0]  disp_fprs2_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0][FPRF_W-1:0]  disp_fprs3_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0]               disp_fpr_rs1_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0]               disp_fpr_rs2_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0]               disp_fpr_rs3_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0]               disp_rs3_ready_i,
    output logic [CVA6Cfg.NrIssuePorts-1:0]              disp_ack_o,
    output logic                                         full_o,
    input  logic [NR_WB-1:0]                 wb_valid_i,
    input  logic [NR_WB-1:0][PRF_W-1:0]      wb_prd_i,
    input  logic [NR_WB-1:0]                 fwb_valid_i,
    input  logic [NR_WB-1:0][FPRF_W-1:0]     fwb_prd_i,
    output scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] issue_sbe_o,
    output logic [CVA6Cfg.NrIssuePorts-1:0][31:0]        issue_orig_o,
    output logic [CVA6Cfg.NrIssuePorts-1:0][PRF_W-1:0]   issue_prd_o,
    output logic [CVA6Cfg.NrIssuePorts-1:0]               issue_valid_o,
    input  logic [CVA6Cfg.NrIssuePorts-1:0]               issue_ack_i,
    input  logic                                         mem_stall_i,
    // Store age gate: live store trans_ids (one bit per scoreboard slot) and
    // the commit pointer anchoring the circular age order. A load waits only
    // for stores OLDER than itself; younger stores can never alias it.
    input  logic [CVA6Cfg.NR_SB_ENTRIES-1:0]              st_live_mask_i,
    input  logic [CVA6Cfg.TRANS_ID_BITS-1:0]              commit_ptr_i,
    // Scoreboard issued mask (assertions only)
    input  logic [CVA6Cfg.NR_SB_ENTRIES-1:0]              sb_live_i
);

  localparam int unsigned DW = (DEPTH <= 1) ? 1 : $clog2(DEPTH + 1);

  typedef struct packed {
    logic               valid;
    logic               rs1_rdy;
    logic               rs2_rdy;
    logic               rs3_rdy;
    logic [PRF_W-1:0]   prs1;
    logic [PRF_W-1:0]   prs2;
    logic [PRF_W-1:0]   prd;
    logic [FPRF_W-1:0]  fprs1;
    logic [FPRF_W-1:0]  fprs2;
    logic [FPRF_W-1:0]  fprs3;
    logic               fpr_rs1;
    logic               fpr_rs2;
    logic               fpr_rs3;
    scoreboard_entry_t  sbe;
    logic [31:0]        orig;
  } iq_entry_t;

  iq_entry_t [DEPTH-1:0] q_q, q_wake, q_chain, q_after_issue, q_d;
  logic [DW-1:0] count_q, count_d;

  assign full_o = (int'(count_q) + CVA6Cfg.NrIssuePorts > DEPTH);

  // 1) Cancel squash + WB wakeup
  always_comb begin
    q_wake = q_q;
    for (int unsigned e = 0; e < DEPTH; e++) begin
      // Drop wrong-path ops still waiting in the IQ (keep older non-cancelled)
      if (q_q[e].valid && cancelled_mask_i[q_q[e].sbe.trans_id])
        q_wake[e].valid = 1'b0;
      if (q_wake[e].valid) begin
        for (int unsigned w = 0; w < NR_WB; w++) begin
          // Integer sources wake on the integer writeback and tag. The
          // `!= 0` guard is the integer no-destination convention.
          if (wb_valid_i[w] && wb_prd_i[w] != '0) begin
            if (!q_wake[e].fpr_rs1 && q_wake[e].prs1 == wb_prd_i[w])
              q_wake[e].rs1_rdy = 1'b1;
            if (!q_wake[e].fpr_rs2 && q_wake[e].prs2 == wb_prd_i[w])
              q_wake[e].rs2_rdy = 1'b1;
          end
          // FP sources wake on the FP writeback and the FP tag. Without this
          // an entry waiting on an FP producer is never woken, never issues,
          // and the ROB head never retires -- the deadlock the FP bring-up
          // run hit. No `!= 0` guard: FP physical 0 is a real destination.
          if (fwb_valid_i[w]) begin
            if (q_wake[e].fpr_rs1 && q_wake[e].fprs1 == fwb_prd_i[w])
              q_wake[e].rs1_rdy = 1'b1;
            if (q_wake[e].fpr_rs2 && q_wake[e].fprs2 == fwb_prd_i[w])
              q_wake[e].rs2_rdy = 1'b1;
            if (q_wake[e].fpr_rs3 && q_wake[e].fprs3 == fwb_prd_i[w])
              q_wake[e].rs3_rdy = 1'b1;
          end
        end
      end
    end
  end

  // 2) Dispatch readiness and writeback establish operand availability.
  //    Producer selection alone does not make its result available.
  // Memory pressure is applied at issue selection, independently of wakeup.
  assign q_chain = q_wake;

  // 3) Select up to NrIssuePorts oldest-ready (mem-aware).
  //
  // Selection is a PURE FUNCTION OF QUEUE STATE and must never read
  // issue_ack_i. It used to: a low ack stopped the scan to preserve age order,
  // but issue_read_operands derives issue_ack_o[p] from the very entry selected
  // here, so selection depended on the ack and the ack on the selection. That
  // closed a real combinational cycle — `check -assert
  // -force-detailed-loop-check` on the full core reported 497 problems naming
  // i_iq.issue_ack_i and i_issue_read_operands.issue_ack. The component fixture
  // never saw it because it ties issue_ack_i to a constant.
  //
  // Acks are now consumed only by the removal step below, which is next-state
  // logic, so the cycle is broken without costing an issue cycle.
  localparam int unsigned EW = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
  logic [CVA6Cfg.NrIssuePorts-1:0][EW-1:0] slot_entry;
  always_comb begin
    automatic int unsigned grants;
    issue_sbe_o   = '0;
    issue_orig_o  = '0;
    issue_prd_o   = '0;
    issue_valid_o = '0;
    slot_entry    = '0;
    grants = 0;
    for (int unsigned e = 0; e < DEPTH; e++) begin
      automatic logic ready;
      automatic logic is_ld;
      automatic logic older_st;
      automatic logic is_st;
      automatic logic is_csr;
      automatic logic older_unissued_st;
      // rs3 participates only when the entry actually has an FP third source;
      // otherwise rs3_rdy is set at dispatch and the term is inert.
      ready  = q_chain[e].valid && q_chain[e].rs1_rdy && q_chain[e].rs2_rdy &&
               q_chain[e].rs3_rdy;
      // mem_stall_i (memdep) gates LOADs only. A STORE allocates its LSQ entry
      // at dispatch and the live-store mask is derived from that entry, so
      // gating STORE here would block the issue -> AGU -> WB path that is the
      // only way to resolve and free it: the first store would deadlock
      // permanently.
      is_ld  = (q_chain[e].sbe.fu == LOAD);
      // Age-aware store gate: only a store OLDER than this load (closer to the
      // commit pointer in the circular trans_id window) may block it. A load
      // whose pending stores are all younger issues freely.
      older_st = 1'b0;
      for (int unsigned s = 0; s < CVA6Cfg.NR_SB_ENTRIES; s++)
        if (st_live_mask_i[s] &&
            g6lc_ooo_pkg::ooo_age_older(CVA6Cfg.TRANS_ID_BITS, 32'(s),
                                        32'(q_chain[e].sbe.trans_id), 32'(commit_ptr_i)))
          older_st = 1'b1;
      // Stores issue in program order relative to each other.
      //
      // This is an ADMISSION rule, not the live-store gate warned about above:
      // it looks only at stores still waiting HERE, never at the entry itself
      // or at stores already issued. The oldest unissued store therefore never
      // has an older unissued store, so it always proceeds and the rule cannot
      // deadlock the way a live-store gate would.
      //
      // Needed because the speculative store queue drains only on commit, and
      // commit is in program order. If younger stores whose operands resolved
      // first could fill that queue while an older store is still waiting, the
      // older store could never post, so nothing could retire and nothing could
      // drain. Refusing them later -- in store_buffer.ready_o or store_unit --
      // does not work: the refused store then occupies the one-deep store pipe
      // and blocks the older store from issuing at all. Loads are unaffected
      // and still issue out of order.
      is_st = (q_chain[e].sbe.fu == STORE);
      older_unissued_st = 1'b0;
      for (int unsigned o = 0; o < DEPTH; o++)
        if ((o != e) && q_chain[o].valid && (q_chain[o].sbe.fu == STORE) &&
            g6lc_ooo_pkg::ooo_age_older(CVA6Cfg.TRANS_ID_BITS,
                                        32'(q_chain[o].sbe.trans_id),
                                        32'(q_chain[e].sbe.trans_id), 32'(commit_ptr_i)))
          older_unissued_st = 1'b1;
      // A CSR issues only when it is the oldest live instruction.
      //
      // csr_buffer is depth-1 and hart-agnostic, and it holds csr_ready low from
      // issue until the CSR COMMITS. ex_stage feeds that into
      // flu_ready_o = csr_ready & mult_ready, which issue_read_operands turns
      // into "every FLU unit is busy" -- ALU and branch included, for every hart.
      // So an uncommitted CSR stops all fixed-latency issue. In order that is
      // harmless because a CSR is effectively the oldest instruction when it
      // issues, so it commits promptly. Out of order it need not be: younger
      // work can fill the scoreboard while the CSR waits behind older
      // instructions that themselves need the FLU, and nothing can then retire.
      // Gating on the commit head keeps the buffer's depth-1 assumption true.
      is_csr = (q_chain[e].sbe.fu == CSR);
      if (ready && !(is_ld && (mem_stall_i || older_st)) &&
          !(is_st && older_unissued_st) &&
          !(is_csr && (q_chain[e].sbe.trans_id != commit_ptr_i)) &&
          grants < CVA6Cfg.NrIssuePorts) begin
        issue_valid_o[grants] = 1'b1;
        issue_sbe_o[grants]   = q_chain[e].sbe;
        issue_orig_o[grants]  = q_chain[e].orig;
        issue_prd_o[grants]   = q_chain[e].prd;
        slot_entry[grants]    = EW'(e);
        grants++;
      end
    end
    // Accepted issue does not wake retained entries; actual writeback does.
  end

  // Removal (next-state only): drop exactly the ports the consumer accepted.
  //
  // Not a prefix rule. A prefix would keep an entry whose port WAS acked
  // whenever an earlier port was not, and the consumer has already taken that
  // instruction — it would issue again next cycle. Removing precisely what was
  // acknowledged is correct for any ack pattern and needs no assumption about
  // the consumer. Under SuperscalarEn issue_read_operands acks a prefix anyway,
  // so the in-order-issue behaviour is unchanged there; dropping the old
  // "stop scanning after a non-ack" rule only widens SELECTION, which is what
  // removes the ack from the combinational cone.
  always_comb begin
    q_after_issue = q_chain;
    for (int unsigned g = 0; g < CVA6Cfg.NrIssuePorts; g++)
      if (issue_valid_o[g] && issue_ack_i[g]) q_after_issue[slot_entry[g]].valid = 1'b0;
  end

  // 4) Compact + dispatch
  always_comb begin
    iq_entry_t [DEPTH-1:0] compact;
    int unsigned wptr;
    compact = '0;
    wptr = 0;
    for (int unsigned e = 0; e < DEPTH; e++) begin
      if (q_after_issue[e].valid) begin
        compact[wptr] = q_after_issue[e];
        wptr++;
      end
    end
    q_d = compact;
    count_d = DW'(wptr);
    disp_ack_o = '0;
    for (int unsigned p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin
      if (disp_valid_i[p] && count_d < DEPTH[DW-1:0]) begin
        disp_ack_o[p] = 1'b1;
        q_d[count_d].valid   = 1'b1;
        q_d[count_d].rs1_rdy = disp_rs1_ready_i[p];
        q_d[count_d].rs2_rdy = disp_rs2_ready_i[p];
        q_d[count_d].rs3_rdy = disp_rs3_ready_i[p];
        for (int unsigned w = 0; w < NR_WB; w++) begin
          // Same-cycle writeback capture, per class: a newly dispatched waiter
          // must not miss the pulse that would have woken it.
          if (wb_valid_i[w] && wb_prd_i[w] != '0) begin
            if (!disp_fpr_rs1_i[p] && disp_prs1_i[p] == wb_prd_i[w])
              q_d[count_d].rs1_rdy = 1'b1;
            if (!disp_fpr_rs2_i[p] && disp_prs2_i[p] == wb_prd_i[w])
              q_d[count_d].rs2_rdy = 1'b1;
          end
          if (fwb_valid_i[w]) begin
            if (disp_fpr_rs1_i[p] && disp_fprs1_i[p] == fwb_prd_i[w])
              q_d[count_d].rs1_rdy = 1'b1;
            if (disp_fpr_rs2_i[p] && disp_fprs2_i[p] == fwb_prd_i[w])
              q_d[count_d].rs2_rdy = 1'b1;
            if (disp_fpr_rs3_i[p] && disp_fprs3_i[p] == fwb_prd_i[w])
              q_d[count_d].rs3_rdy = 1'b1;
          end
        end
        q_d[count_d].prs1    = disp_prs1_i[p];
        q_d[count_d].prs2    = disp_prs2_i[p];
        q_d[count_d].prd     = disp_prd_i[p];
        q_d[count_d].fprs1   = disp_fprs1_i[p];
        q_d[count_d].fprs2   = disp_fprs2_i[p];
        q_d[count_d].fprs3   = disp_fprs3_i[p];
        q_d[count_d].fpr_rs1 = disp_fpr_rs1_i[p];
        q_d[count_d].fpr_rs2 = disp_fpr_rs2_i[p];
        q_d[count_d].fpr_rs3 = disp_fpr_rs3_i[p];
        q_d[count_d].sbe     = disp_sbe_i[p];
        q_d[count_d].orig    = disp_orig_i[p];
        // Rename readiness is retained, including same-cycle WB above;
        // a newly dispatched waiter must not miss its writeback pulse.
        count_d = count_d + 1'b1;
      end
    end
    if (flush_i) begin
      q_d = '0;
      count_d = '0;
      disp_ack_o = '0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      q_q <= '0;
      count_q <= '0;
    end else begin
      q_q <= q_d;
      count_q <= count_d;
    end
  end

  //pragma translate_off
  for (genvar e = 0; e < DEPTH; e++) begin : gen_iq_live_assert
    ooo_iq_entry_live: assert property (@(posedge clk_i) disable iff (!rst_ni)
        q_q[e].valid |-> sb_live_i[q_q[e].sbe.trans_id]);
  end
  //pragma translate_on

endmodule
