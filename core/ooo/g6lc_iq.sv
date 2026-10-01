// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5.3 unified issue queue — stationary entries, age matrix, cascaded
// oldest-first grant; rank kept as the sim-only reference.
// Bottleneck optimizations:
//   * Same-cycle WB tag wakeup
//   * Same-cycle dispatch/WB capture without speculative issue-time wakeup
//   * mem_stall only blocks LOAD; STORE/ALU/MULT/CTRL issue under mem pressure
//   * Loads wait only on older UNRESOLVED stores; a dispatch-time memdep
//     verdict (may_bypass) lets a predicted-independent load pass them
//   * CSR data ops issue freely against the dual-entry csr_buffer credit;
//     only fence/system CSR-class ops still wait for the commit head
//   * Dual-grant oldest-ready up to NrIssuePorts
//   * Entries never move: relative age lives in a DEPTH x DEPTH `older`
//     matrix and selection grants ports in oldest-first order by cascade.
//     The previous compacting layout rebuilt the whole queue every cycle —
//     a DEPTH-wide mux tree on the entry payload. The matrix costs DEPTH^2
//     one-bit flops and no payload movement at all.

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
    // Dispatch-time memdep verdict: a load predicted independent may issue
    // past an older store whose address is still unresolved.
    input  logic [CVA6Cfg.NrIssuePorts-1:0]               disp_may_bypass_i,
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
    // occupancy observability
    input  logic [CVA6Cfg.NR_SB_ENTRIES-1:0]              st_live_mask_i,
    // Store age gate: live store trans_ids whose address is still UNRESOLVED
    // (one bit per scoreboard slot) and the commit pointer anchoring the
    // circular age order. A load waits only for unresolved stores OLDER than
    // itself; resolved stores are the store_buffer's forwarding domain.
    input  logic [CVA6Cfg.NR_SB_ENTRIES-1:0]              st_unresolved_mask_i,
    // T6b: the live-store mask partitioned by owning hart. Under mixed
    // residency a load waits only on ITS hart's unresolved stores; the mask
    // is an AND in front of the existing age gate, never part of selection.
    // When NrHarts==1 the term constant-folds away.
    input  logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0][CVA6Cfg.NR_SB_ENTRIES-1:0] st_hart_mask_i,
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
    logic               may_bypass;
    scoreboard_entry_t  sbe;
    logic [31:0]        orig;
  } iq_entry_t;

  iq_entry_t [DEPTH-1:0] q_q, q_wake, q_chain, q_after_issue, q_d;
  // Relative age: older_q[o][e] = "entry o is older than entry e". Entries
  // are stationary; this matrix replaces slot index as the age order. Only
  // bits between two live entries are meaningful.
  logic [DEPTH-1:0][DEPTH-1:0] older_q, older_d;
  logic [DW-1:0] count_q, count_d;
  logic [DEPTH-1:0] ready;
  logic [CVA6Cfg.NrIssuePorts-1:0][DEPTH-1:0] grant;
  logic [DEPTH-1:0] valid_after;

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
  // Cascaded oldest-first grant: port p takes the ready entry with no
  // remaining entry older than it (col_e is the transposed age matrix),
  // then that entry leaves the pool. The grant set is identical to the
  // rank==p selection it replaces — the p-th oldest ready entry, the same
  // grants the compacting layout produced by scanning slots in order; the
  // sim-only rank popcount (ooo_iq_grant_is_rank) pins the two together.
  logic [DEPTH-1:0][DEPTH-1:0] older_t;
  for (genvar e = 0; e < DEPTH; e++) begin : gen_older_t
    for (genvar o = 0; o < DEPTH; o++) begin : gen_older_t_o
      assign older_t[e][o] = older_q[o][e];
    end
  end
  for (genvar p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin : gen_grant
    // Per-scope pool nets: rem for port p is a distinct signal, so the
    // cascade chain is acyclic at signal granularity (a shared pool array
    // reads as a false combinational loop to the simulator).
    logic [DEPTH-1:0] rem, g;
    if (p == 0) begin : gen_first
      assign rem = ready;
    end else begin : gen_next
      assign rem = gen_grant[p-1].rem & ~gen_grant[p-1].g;
    end
    for (genvar e = 0; e < DEPTH; e++) begin : gen_grant_e
      assign g[e] = rem[e] && !(|(rem & older_t[e]));
    end
    assign grant[p] = g;
  end
  always_comb begin
    issue_sbe_o   = '0;
    issue_orig_o  = '0;
    issue_prd_o   = '0;
    issue_valid_o = '0;
    slot_entry    = '0;
    // Issue predicate, identical to the compacting design: operand
    // readiness, the load/store ordering gates, and the commit-head rule
    // for fence/system CSR-class ops. Selection below only re-derives the
    // AGE order; it never changes which entries pass this predicate.
    for (int unsigned e = 0; e < DEPTH; e++) begin
      automatic logic is_ld;
      automatic logic older_unresolved_st;
      automatic logic older_csr_iq;
      automatic logic is_csr;
      automatic logic is_amo;
      automatic logic is_cvxif;
      // rs3 participates only when the entry actually has an FP third source;
      // otherwise rs3_rdy is set at dispatch and the term is inert.
      ready[e] = q_chain[e].valid && q_chain[e].rs1_rdy && q_chain[e].rs2_rdy &&
                 q_chain[e].rs3_rdy;
      // mem_stall_i gates LOADs only. A STORE allocates its LSQ entry at
      // dispatch and the live-store mask is derived from that entry, so gating
      // STORE here would block the issue -> AGU -> WB path that is the only
      // way to resolve and free it: the first store would deadlock permanently.
      is_ld  = (q_chain[e].sbe.fu == LOAD);
      // Age-aware store gate: only a store OLDER than this load (closer to the
      // commit pointer in the circular trans_id window) whose address is still
      // unresolved may block it. Resolved older stores are covered by the
      // store_buffer's forwarding compare, and stores the dispatch-time
      // predictor cleared (may_bypass) issue past an unresolved one.
      older_unresolved_st = 1'b0;
      for (int unsigned s = 0; s < CVA6Cfg.NR_SB_ENTRIES; s++)
        if (st_unresolved_mask_i[s] &&
            (CVA6Cfg.NrHarts <= 1 ||
             st_hart_mask_i[q_chain[e].sbe.hart_id][s]) &&
            g6lc_ooo_pkg::ooo_age_older(CVA6Cfg.TRANS_ID_BITS, 32'(s),
                                        32'(q_chain[e].sbe.trans_id), 32'(commit_ptr_i)))
          older_unresolved_st = 1'b1;
      // Store ordering between themselves moved to the LSQ hold-to-commit
      // reservation: an issued store's slot is held until its commit releases
      // it, so a younger store that fills the queue first can no longer strand
      // an older one. No program-order admission rule is needed here.
      //
      // Fence/system CSR-class ops still issue only at the commit head (their
      // side effects are global). Plain CSR accesses are covered by the
      // dual-entry csr_buffer's credit in issue_read_operands instead.
      is_csr = (q_chain[e].sbe.fu == CSR);
      // N1d (T10g): CSR ops issue strictly in IQ age order, not just behind
      // the csr_buffer's credit. The buffer's two entries are freed only by
      // a commit, and commit is in-order — a younger CSR claiming a credit
      // ahead of an older CSR still waiting in the queue leaves the older
      // one unable to issue (csr_ready_i low): its sbe.valid never sets,
      // the commit head never validates, and the buffered youngers can never
      // commit — a circular wedge (ring-32 four-hart boot, OpenSBI CSR probe
      // burst at 0x8000e9fa). IQ-age order guarantees every buffered CSR
      // retires before any CSR still queued, so the head can never be
      // starved by younger entries.
      older_csr_iq = 1'b0;
      for (int unsigned o = 0; o < DEPTH; o++)
        if (q_chain[o].valid && q_chain[o].sbe.fu == CSR &&
            (o != e) && older_q[o][e])
          older_csr_iq = 1'b1;
      // An atomic also issues only at the commit head. The store unit holds
      // an issued AMO in a one-entry buffer and is not ready for any other
      // store until that AMO commits; an AMO issued ahead of an older store
      // therefore blocks the store it must wait for (OpenSBI coldboot_lottery
      // amoswap.d behind `sd a5,-32(s0)` on g6lc64_ooo_int2). At commit the
      // AMO waits for the drained store buffer anyway, so the head rule costs
      // nothing it would not already pay.
      is_amo = CVA6Cfg.RVA && (q_chain[e].sbe.fu == STORE) && ariane_pkg::is_amo(q_chain[e].sbe.op);
      // A CVXIF (Xg6lcai coprocessor) op issues only at the commit head. The
      // coprocessor executes at issue and the CVXIF driver signals commit in the
      // issue cycle ("goes to execute = not speculative"), which is only true
      // when nothing older can still fault or redirect and the op itself cannot
      // be cancelled: exactly the head, whose cancelled predecessors have all
      // drained. Its side effects (accumulator tiles, ai.enq kicks, AI CSR
      // dirtying) therefore never happen on a wrong path, and its result can
      // never arrive for a cancelled entry. The oldest ready entry takes port
      // 0, which also keeps the port-0 steering contract of
      // issue_read_operands. T0 ops are control plane; the serialisation is
      // the price of not needing a kill-capable coprocessor.
`ifdef G6LC_MUT_CVXIF_NOHEAD
      is_cvxif = 1'b0;   // review mutation: the rule is dropped
`else
      is_cvxif = CVA6Cfg.CvxifEn && (q_chain[e].sbe.fu == CVXIF);
`endif
      ready[e] = ready[e] &&
          !(is_cvxif && (q_chain[e].sbe.trans_id != commit_ptr_i)) &&
          !(is_ld && (mem_stall_i ||
                      (older_unresolved_st && !q_chain[e].may_bypass))) &&
          !(is_csr && older_csr_iq) &&
          !(is_csr &&
            !(q_chain[e].sbe.op inside {CSR_READ, CSR_WRITE, CSR_SET, CSR_CLEAR}) &&
            (q_chain[e].sbe.trans_id != commit_ptr_i)) &&
          !(is_amo && (q_chain[e].sbe.trans_id != commit_ptr_i));
    end
    // The age matrix is a strict total order over the live entries
    // (ooo_iq_age_acyclic/ooo_iq_age_total below), so the cascade's
    // no-older match is unique per port.
    for (int unsigned p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin
      issue_valid_o[p] = |grant[p];
      for (int unsigned e = 0; e < DEPTH; e++) begin
        if (grant[p][e]) begin
          issue_sbe_o[p]   = q_chain[e].sbe;
          issue_orig_o[p]  = q_chain[e].orig;
          issue_prd_o[p]   = q_chain[e].prd;
          slot_entry[p]    = EW'(e);
        end
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
  for (genvar e = 0; e < DEPTH; e++) begin : gen_valid_after
    assign valid_after[e] = q_after_issue[e].valid;
  end

  // 4) Dispatch: entries are stationary — a newcomer takes the lowest free
  //    slot and the age matrix records that every still-live entry is older
  //    than it (dispatch port order breaks same-cycle ties).
  always_comb begin
    automatic logic [DEPTH-1:0] free;
    automatic logic [CVA6Cfg.NrIssuePorts-1:0][EW-1:0] alloc_slot;
    automatic logic [CVA6Cfg.NrIssuePorts-1:0] alloc;
    automatic int unsigned slot;
    q_d = q_after_issue;
    older_d = older_q;
    // Removed entries (squashed, issue-acked, or never valid) lose their row
    // and column so stale age bits can never influence a future rank.
    for (int unsigned r = 0; r < DEPTH; r++) begin
      if (!valid_after[r]) begin
        older_d[r] = '0;
        for (int unsigned o = 0; o < DEPTH; o++) older_d[o][r] = 1'b0;
      end
    end
    disp_ack_o = '0;
    free = ~valid_after;
    alloc = '0;
    alloc_slot = '0;
    slot = 0;
    for (int unsigned p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin
      if (disp_valid_i[p]) begin
        for (int unsigned e = 0; e < DEPTH; e++) begin
          if (free[e] && !alloc[p]) begin
            alloc[p] = 1'b1;
            alloc_slot[p] = EW'(e);
            free[e] = 1'b0;
          end
        end
      end
    end
    for (int unsigned p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin
      if (alloc[p]) begin
        slot = int'(alloc_slot[p]);
        disp_ack_o[p] = 1'b1;
        q_d[slot].valid   = 1'b1;
        q_d[slot].rs1_rdy = disp_rs1_ready_i[p];
        q_d[slot].rs2_rdy = disp_rs2_ready_i[p];
        q_d[slot].rs3_rdy = disp_rs3_ready_i[p];
        for (int unsigned w = 0; w < NR_WB; w++) begin
          // Same-cycle writeback capture, per class: a newly dispatched waiter
          // must not miss the pulse that would have woken it.
          if (wb_valid_i[w] && wb_prd_i[w] != '0) begin
            if (!disp_fpr_rs1_i[p] && disp_prs1_i[p] == wb_prd_i[w])
              q_d[slot].rs1_rdy = 1'b1;
            if (!disp_fpr_rs2_i[p] && disp_prs2_i[p] == wb_prd_i[w])
              q_d[slot].rs2_rdy = 1'b1;
          end
          if (fwb_valid_i[w]) begin
            if (disp_fpr_rs1_i[p] && disp_fprs1_i[p] == fwb_prd_i[w])
              q_d[slot].rs1_rdy = 1'b1;
            if (disp_fpr_rs2_i[p] && disp_fprs2_i[p] == fwb_prd_i[w])
              q_d[slot].rs2_rdy = 1'b1;
            if (disp_fpr_rs3_i[p] && disp_fprs3_i[p] == fwb_prd_i[w])
              q_d[slot].rs3_rdy = 1'b1;
          end
        end
        q_d[slot].prs1    = disp_prs1_i[p];
        q_d[slot].prs2    = disp_prs2_i[p];
        q_d[slot].prd     = disp_prd_i[p];
        q_d[slot].fprs1   = disp_fprs1_i[p];
        q_d[slot].fprs2   = disp_fprs2_i[p];
        q_d[slot].fprs3   = disp_fprs3_i[p];
        q_d[slot].fpr_rs1 = disp_fpr_rs1_i[p];
        q_d[slot].fpr_rs2 = disp_fpr_rs2_i[p];
        q_d[slot].fpr_rs3 = disp_fpr_rs3_i[p];
        q_d[slot].sbe     = disp_sbe_i[p];
        q_d[slot].orig    = disp_orig_i[p];
        q_d[slot].may_bypass = disp_may_bypass_i[p];
        // Rename readiness is retained, including same-cycle WB above;
        // a newly dispatched waiter must not miss its writeback pulse.
        //
        // Age: every entry still live after this cycle's issue removals is
        // older than the newcomer; the newcomer is older than nobody.
        for (int unsigned o = 0; o < DEPTH; o++)
          older_d[o][slot] = valid_after[o];
        older_d[slot] = '0;
      end
    end
    // Same-cycle dispatches order by port: port 0's slot is older than
    // port 1's, matching the compacting layout's append order.
    for (int unsigned p = 0; p < CVA6Cfg.NrIssuePorts; p++)
      for (int unsigned q = p + 1; q < CVA6Cfg.NrIssuePorts; q++)
        if (alloc[p] && alloc[q]) older_d[alloc_slot[p]][alloc_slot[q]] = 1'b1;
    if (flush_i) begin
      q_d = '0;
      older_d = '0;
      disp_ack_o = '0;
    end
  end

  // Live count of the resolved next state — an unconditional single-assignment
  // block so the popcount cannot infer a latch.
  always_comb begin
    count_d = '0;
    for (int unsigned e = 0; e < DEPTH; e++)
      count_d = count_d + DW'(q_d[e].valid);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      q_q <= '0;
      older_q <= '0;
      count_q <= '0;
    end else begin
      q_q <= q_d;
      older_q <= older_d;
      count_q <= count_d;
    end
  end

  //pragma translate_off
  // Immediate posedge assertions: `assert property` makes Verilator snapshot
  // every referenced signal into __Vsampled, and for the unpacked q_q array
  // that snapshot is a __Vilp copy loop whose DepSet partitioning can emit
  // the loop ahead of the variable's declaration (the use-before-decl codegen
  // defect already documented for scoreboard.sv's commit SVA). Immediate
  // assertions read live values — for flop state the same values a clocked
  // property would sample.
  for (genvar e = 0; e < DEPTH; e++) begin : gen_iq_live_assert
    always_ff @(posedge clk_i) begin
      if (rst_ni)
        ooo_iq_entry_live: assert (!q_q[e].valid || sb_live_i[q_q[e].sbe.trans_id]);
    end
  end
  // The rank popcount is the sim-only reference for the cascade: rank[e]
  // counts the ready entries older than e, so grant[p][e] must equal
  // ready && rank==p exactly.
  logic [DEPTH-1:0][DW-1:0] rank;
  always_comb begin
    for (int unsigned e = 0; e < DEPTH; e++) begin
      rank[e] = '0;
      for (int unsigned o = 0; o < DEPTH; o++)
        if (ready[o] && older_q[o][e]) rank[e] = rank[e] + DW'(1);
    end
  end
  for (genvar p = 0; p < CVA6Cfg.NrIssuePorts; p++) begin : gen_iq_grant_assert
    for (genvar e = 0; e < DEPTH; e++) begin : gen_iq_grant_rank
      always_ff @(posedge clk_i) begin
        if (rst_ni)
          ooo_iq_grant_is_rank: assert (grant[p][e] == (ready[e] && rank[e] == DW'(p)));
      end
    end
    // The no-older-ready match is unique per port: at most one entry is
    // granted to each issue port per cycle.
    always_ff @(posedge clk_i) begin
      if (rst_ni)
        ooo_iq_rank_unique: assert ($onehot0(grant[p]));
    end
    // N1d/T10g: a granted CSR never overtakes an older CSR still resident in
    // the queue — the ordering rule that prevents the csr_buffer credit
    // circle (younger CSRs consuming both credits ahead of an unissued older
    // CSR whose commit must precede theirs).
    for (genvar e = 0; e < DEPTH; e++) begin : gen_iq_csr_entry
      for (genvar o = 0; o < DEPTH; o++) begin : gen_iq_csr_older
        if (o != e) begin
          always_ff @(posedge clk_i) begin
            if (rst_ni)
              ooo_iq_csr_order: assert (
                  !(grant[p][e] && q_chain[e].valid && q_chain[e].sbe.fu == CSR &&
                    q_chain[o].valid && q_chain[o].sbe.fu == CSR && older_q[o][e]));
          end
        end
      end
    end
  end
  for (genvar a = 0; a < DEPTH; a++) begin : gen_iq_age_a
    for (genvar b = 0; b < DEPTH; b++) begin : gen_iq_age_b
      if (a != b) begin
        always_ff @(posedge clk_i) begin
          if (rst_ni) begin
            ooo_iq_age_acyclic: assert (!(older_q[a][b] && older_q[b][a]));
            ooo_iq_age_total: assert (!(q_q[a].valid && q_q[b].valid) ||
                                      (older_q[a][b] != older_q[b][a]));
          end
        end
      end
    end
  end
  //pragma translate_on

endmodule
