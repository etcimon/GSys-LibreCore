// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5.3 unified issue queue — compacting age-ordered multi-grant ready select.
// Bottleneck optimizations:
//   * Same-cycle WB tag wakeup
//   * Same-cycle issue→dependent wakeup (issued prd wakes peers this cycle)
//   * mem_stall only blocks LOAD/STORE; ALU/MULT/CTRL issue under mem pressure
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
    input  logic                                         mem_stall_i
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

  assign full_o = (count_q >= DEPTH[DW-1:0] - DW'(CVA6Cfg.NrIssuePorts));

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

  // 2) Same-cycle chain: older ready producer (age order) wakes younger sources
  //    on its prd — collapses 1-cycle dependent ALU bubbles when both in IQ.
  always_comb begin
    q_chain = q_wake;
    for (int unsigned prod = 0; prod < DEPTH; prod++) begin
      automatic logic prod_ready;
      prod_ready = q_wake[prod].valid && q_wake[prod].rs1_rdy && q_wake[prod].rs2_rdy &&
                   (q_wake[prod].prd != '0);
      if (prod_ready) begin
        // producers blocked only if mem under mem_stall (same rule as issue)
        automatic logic prod_mem;
        prod_mem = (q_wake[prod].sbe.fu == LOAD) || (q_wake[prod].sbe.fu == STORE);
        if (!(prod_mem && mem_stall_i)) begin
          for (int unsigned cons = prod + 1; cons < DEPTH; cons++) begin
            if (q_wake[cons].valid) begin
              if (q_wake[cons].prs1 == q_wake[prod].prd) q_chain[cons].rs1_rdy = 1'b1;
              if (q_wake[cons].prs2 == q_wake[prod].prd) q_chain[cons].rs2_rdy = 1'b1;
            end
          end
        end
      end
    end
  end

  // 3) Select up to NrIssuePorts oldest-ready (mem-aware)
  always_comb begin
    automatic int unsigned grants;
    automatic logic [CVA6Cfg.NrIssuePorts-1:0][PRF_W-1:0] granted_prd;
    automatic logic [CVA6Cfg.NrIssuePorts-1:0]            granted_v;
    q_after_issue = q_chain;
    issue_sbe_o   = '0;
    issue_orig_o  = '0;
    issue_prd_o   = '0;
    issue_valid_o = '0;
    granted_prd   = '0;
    granted_v     = '0;
    grants = 0;
    for (int unsigned e = 0; e < DEPTH; e++) begin
      automatic logic ready;
      automatic logic is_mem;
      ready  = q_chain[e].valid && q_chain[e].rs1_rdy && q_chain[e].rs2_rdy;
      is_mem = (q_chain[e].sbe.fu == LOAD) || (q_chain[e].sbe.fu == STORE);
      if (ready && !(is_mem && mem_stall_i) && grants < CVA6Cfg.NrIssuePorts) begin
        issue_valid_o[grants] = 1'b1;
        issue_sbe_o[grants]   = q_chain[e].sbe;
        issue_orig_o[grants]  = q_chain[e].orig;
        issue_prd_o[grants]   = q_chain[e].prd;
        granted_prd[grants]   = q_chain[e].prd;
        granted_v[grants]     = 1'b1;
        if (issue_ack_i[grants]) begin
          q_after_issue[e].valid = 1'b0;
          grants++;
        end else begin
          // Head of ready stream not accepted — stop (preserve age order)
          grants = CVA6Cfg.NrIssuePorts;
        end
      end
    end
    // Same-cycle issue wakeup into remaining entries (for next-state readiness)
    for (int unsigned g = 0; g < CVA6Cfg.NrIssuePorts; g++) begin
      if (granted_v[g] && issue_ack_i[g] && granted_prd[g] != '0) begin
        for (int unsigned e = 0; e < DEPTH; e++) begin
          if (q_after_issue[e].valid) begin
            if (q_after_issue[e].prs1 == granted_prd[g]) q_after_issue[e].rs1_rdy = 1'b1;
            if (q_after_issue[e].prs2 == granted_prd[g]) q_after_issue[e].rs2_rdy = 1'b1;
          end
        end
      end
    end
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
        q_d[count_d].prs1    = disp_prs1_i[p];
        q_d[count_d].prs2    = disp_prs2_i[p];
        q_d[count_d].prd     = disp_prd_i[p];
        q_d[count_d].sbe     = disp_sbe_i[p];
        q_d[count_d].orig    = disp_orig_i[p];
        // Same-cycle dispatch-to-dispatch WAW ready already handled in rename;
        // same-cycle issue prd vs new dispatch handled if still in q_after_issue.
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
