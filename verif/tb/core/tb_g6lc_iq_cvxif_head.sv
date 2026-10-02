// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_iq: a CVXIF (Xg6lcai coprocessor) op issues only at the commit head.
// The coprocessor executes at issue and the CVXIF driver commits in the issue
// cycle, so anything younger than an unresolved older op would be a wrong-path
// side effect (accumulator tiles, ai.enq kicks). Scenarios: not at head -> held;
// head reaches it -> offered on port 0; a plain ALU op younger than a held CVXIF
// op is not blocked (the rule is head-only, not a barrier); a CVXIF op at head
// with a younger ready ALU op takes port 0 (port-0 steering). Mutation
// +define+G6LC_MUT_CVXIF_NOHEAD must fail IQ_CVXIF_HEAD; +oracle_negative
// flips the verdict.
module tb_g6lc_iq_cvxif_head;
  import ariane_pkg::*;
  parameter int NP = 2, DEPTH = 8;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.NrIssuePorts = NP; c.NrWbPorts = 2; c.NR_SB_ENTRIES = 16; c.TRANS_ID_BITS = 4; c.RVA = 1;
    c.CvxifEn = 1;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C = configuration();
  typedef struct packed {fu_t fu; fu_op op; logic [3:0] trans_id; logic hart_id; logic [31:0] pc;} sbe_t;
  logic clk = 0, rst_n = 0, flush = 0, mem_stall = 0, full, empty;
  logic [15:0] cancel = '0, st_unresolved = '0, st_live = '0;
  logic [3:0] commit_ptr = '0;
  logic [NP-1:0] dv = '0, da, iv, ia = '0, r1 = '0, r2 = '0, bypass = '0;
  sbe_t [NP-1:0] ds, is;
  logic [NP-1:0][31:0] di, ii;
  logic [NP-1:0][3:0] p1, p2, pd, ip;
  logic [1:0] wv = '0;
  logic [1:0][3:0] wp = '0;
  bit negative;
  int checked = 0;

  g6lc_iq #(.CVA6Cfg(C), .DEPTH(DEPTH), .PRF_W(4), .scoreboard_entry_t(sbe_t)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush), .cancelled_mask_i(cancel),
    .disp_valid_i(dv), .disp_sbe_i(ds), .disp_orig_i(di), .disp_prs1_i(p1), .disp_prs2_i(p2), .disp_prd_i(pd),
    .disp_fprs1_i('0), .disp_fprs2_i('0), .disp_fprs3_i('0),
    .disp_fpr_rs1_i('0), .disp_fpr_rs2_i('0), .disp_fpr_rs3_i('0),
    .disp_rs3_ready_i('1), .fwb_valid_i('0), .fwb_prd_i('0),
    .disp_rs1_ready_i(r1), .disp_rs2_ready_i(r2), .disp_may_bypass_i(bypass), .disp_ack_o(da), .full_o(full), .empty_o(empty),
    .wb_valid_i(wv), .wb_prd_i(wp),
    .issue_sbe_o(is), .issue_orig_o(ii), .issue_prd_o(ip), .issue_valid_o(iv), .issue_ack_i(ia), .mem_stall_i(mem_stall),
    .st_live_mask_i(st_live), .st_unresolved_mask_i(st_unresolved), .st_hart_mask_i(st_live), .commit_ptr_i(commit_ptr), .sb_live_i('1));

  task automatic tick; clk = 1; #2; clk = 0; #2; endtask
  task automatic clear_inputs;
    flush = 0; mem_stall = 0; cancel = '0; dv = '0; ds = '0; di = '0; p1 = '0; p2 = '0; pd = '0; r1 = '0; r2 = '0; wv = '0; wp = '0; bypass = '0;
  endtask
  task automatic offer_op(input int id, input fu_t fu, input fu_op op);
    dv[0] = 1; ds[0] = '{fu: fu, op: op, trans_id: 4'(id), hart_id: 1'b0, pc: 32'h1000 + 32'(id) * 4};
    di[0] = 32'h13000000 + 32'(id); p1[0] = 0; p2[0] = 0; pd[0] = 4'(id); r1[0] = 1; r2[0] = 1; bypass[0] = 0;
    tick(); clear_inputs(); #2;
  endtask
  task automatic expect_issue(input bit want, input string tag);
    if (iv[0] !== (want ^ negative)) $fatal(1, "%s iv=%b", tag, iv[0]);
    checked++;
  endtask
  task automatic drain_port0;
    ia = '1; tick(); ia = '0; #2;
  endtask

  initial begin
    negative = $test$plusargs("oracle_negative");
    clear_inputs(); #2; tick(); rst_n = 1; #2;

    // S1: CVXIF op 3 while the head is 0 -> held; head moves to 3 -> offered.
    commit_ptr = 4'd0;
    offer_op(3, CVXIF, OFFLOAD); expect_issue(0, "IQ_CVXIF_HEAD");
    commit_ptr = 4'd3; #2; expect_issue(1, "IQ_CVXIF_HEAD");
    if (is[0].fu !== CVXIF || is[0].trans_id !== 4'd3) $fatal(1, "IQ_CVXIF_HEAD wrong entry on port 0");
    drain_port0();

    // S2: a held CVXIF op does not block a younger plain op (head-only rule, not a barrier).
    commit_ptr = 4'd0;
    offer_op(5, CVXIF, OFFLOAD); expect_issue(0, "IQ_CVXIF_HEAD_HOLD");
    offer_op(6, ALU, ADD); expect_issue(1, "IQ_CVXIF_NOT_BARRIER");
    if (is[0].trans_id !== 4'd6) $fatal(1, "IQ_CVXIF_NOT_BARRIER tid=%0d", is[0].trans_id);
    drain_port0();
    // still held after the younger left
    expect_issue(0, "IQ_CVXIF_HEAD_HOLD2");

    // S3: head reaches the CVXIF op while a younger ready ALU op waits: the CVXIF op
    // is the oldest ready and takes port 0 (port-0 steering), the ALU op port 1.
    offer_op(7, ALU, ADD);
    commit_ptr = 4'd5; #2;
    expect_issue(1, "IQ_CVXIF_PORT0");
    if (is[0].fu !== CVXIF || is[0].trans_id !== 4'd5) $fatal(1, "IQ_CVXIF_PORT0 port0 tid=%0d fu=%0d", is[0].trans_id, is[0].fu);
    if (NP > 1 && (!iv[1] || is[1].trans_id !== 4'd7)) $fatal(1, "IQ_CVXIF_PORT0 port1");

    if (negative) $fatal(1, "ORACLE_NEGATIVE forced");
    $display("PASS tb_g6lc_iq_cvxif_head checked=%0d", checked);
    $finish;
  end
endmodule
