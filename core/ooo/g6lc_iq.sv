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
    output logic [CVA6Cfg.NrIssuePorts-1:0]              disp_ack_o,
    output logic                                         full_o,
    input  logic [CVA6Cfg.NrWbPorts-1:0]                 wb_valid_i,
    input  logic [CVA6Cfg.NrWbPorts-1:0][PRF_W-1:0]      wb_prd_i,
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
    input  logic [CVA6Cfg.TRANS_ID_BITS-1:0]              commit_ptr_i
);

  localparam int unsigned DW = (DEPTH <= 1) ? 1 : $clog2(DEPTH + 1);

  typedef struct packed {
    logic               valid;
    logic               rs1_rdy;
    logic               rs2_rdy;
    logic [PRF_W-1:0]   prs1;
    logic [PRF_W-1:0]   prs2;
    logic [PRF_W-1:0]   prd;
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
        for (int unsigned w = 0; w < CVA6Cfg.NrWbPorts; w++) begin
          if (wb_valid_i[w] && wb_prd_i[w] != '0) begin
            if (q_wake[e].prs1 == wb_prd_i[w]) q_wake[e].rs1_rdy = 1'b1;
            if (q_wake[e].prs2 == wb_prd_i[w]) q_wake[e].rs2_rdy = 1'b1;
          end
        end
      end
    end
  end

  // 2) Dispatch readiness and writeback establish operand availability.
  //    Producer selection alone does not make its result available.
  // Memory pressure is applied at issue selection, independently of wakeup.
  assign q_chain = q_wake;

  // 3) Select up to NrIssuePorts oldest-ready (mem-aware)
  always_comb begin
    automatic int unsigned grants;
    q_after_issue = q_chain;
    issue_sbe_o   = '0;
    issue_orig_o  = '0;
    issue_prd_o   = '0;
    issue_valid_o = '0;
    grants = 0;
    for (int unsigned e = 0; e < DEPTH; e++) begin
      automatic logic ready;
      automatic logic is_ld;
      automatic logic older_st;
      ready  = q_chain[e].valid && q_chain[e].rs1_rdy && q_chain[e].rs2_rdy;
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
            (CVA6Cfg.TRANS_ID_BITS'(s) - commit_ptr_i) <
            (q_chain[e].sbe.trans_id - commit_ptr_i))
          older_st = 1'b1;
      if (ready && !(is_ld && (mem_stall_i || older_st)) && grants < CVA6Cfg.NrIssuePorts) begin
        issue_valid_o[grants] = 1'b1;
        issue_sbe_o[grants]   = q_chain[e].sbe;
        issue_orig_o[grants]  = q_chain[e].orig;
        issue_prd_o[grants]   = q_chain[e].prd;
        if (issue_ack_i[grants]) begin
          q_after_issue[e].valid = 1'b0;
          grants++;
        end else begin
          // Head of ready stream not accepted — stop (preserve age order)
          grants = CVA6Cfg.NrIssuePorts;
        end
      end
    end
    // Accepted issue does not wake retained entries; actual writeback does.
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
        for (int unsigned w = 0; w < CVA6Cfg.NrWbPorts; w++) begin
          if (wb_valid_i[w] && wb_prd_i[w] != '0) begin
            if (disp_prs1_i[p] == wb_prd_i[w]) q_d[count_d].rs1_rdy = 1'b1;
            if (disp_prs2_i[p] == wb_prd_i[w]) q_d[count_d].rs2_rdy = 1'b1;
          end
        end
        q_d[count_d].prs1    = disp_prs1_i[p];
        q_d[count_d].prs2    = disp_prs2_i[p];
        q_d[count_d].prd     = disp_prd_i[p];
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

endmodule
