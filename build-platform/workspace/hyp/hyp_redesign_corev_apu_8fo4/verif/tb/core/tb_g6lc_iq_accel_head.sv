// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_iq: an ACCEL (Ara / RVV) op issues only at the commit head, matching
// the CVXIF contract. acc_dispatcher forwards to Ara only after commit, so a
// younger-than-head issue would occupy the vector unit while an older op can
// still fault -- a wrong-path accelerator side effect. Dual-issue Ara relies
// on this plus port-0 steering (issue_read_operands steers ACCEL to port 0).
// Scenarios: not at head -> held; head reaches it -> offered on port 0; a
// plain ALU op younger than a held ACCEL op is not blocked (head-only, not a
// barrier); an ACCEL op at head with a younger ready ALU op takes port 0.
// Mutation +define+G6LC_MUT_ACCEL_NOHEAD must fail IQ_ACCEL_HEAD;
// +oracle_negative flips the verdict.
//
// Timing note: the banked IQ + registered arbiter is ~12+ cycles deep from a
// ready entry to issue_valid_o (bank rdy -> cand_v -> cand_v_q -> pv_d/pv_q ->
// merged -> win -> win_s -> take -> presentation). Positive checks POLL for
// issue_valid (it holds until acked, so waiting cannot drop it); held checks
// settle HELD_CYCLES -- longer than the full candidate->issue flight -- so a
// head-only mutation that lets the op issue is still caught.
module tb_g6lc_iq_accel_head;
  import g6lc_core_pkg::*;
  parameter int NP = 2, DEPTH = 8;
  localparam int HELD_CYCLES = 60, ISSUE_TIMEOUT = 120;
  function automatic config_pkg::g6lc_cfg_t configuration();
    config_pkg::g6lc_cfg_t c = config_pkg::g6lc_cfg_empty;
    c.NrIssuePorts = NP; c.NrWbPorts = 2; c.NR_SB_ENTRIES = 16; c.TRANS_ID_BITS = 4;
    c.RVV = 1; c.EnableAccelerator = 1;
    return c;
  endfunction
  localparam config_pkg::g6lc_cfg_t C = configuration();
  // Field set mirrors what g6lc_iq/_bank/_legal/_arb/_payload read off the
  // injected scoreboard_entry_t: fu/op/trans_id/hart_id for class+age, rd/rs1/
  // rs2 for operand bookkeeping, p_frd for the FPR-destination capture.
  typedef struct packed {
    fu_t fu; fu_op op; logic [3:0] trans_id; logic hart_id; logic [31:0] pc;
    logic [4:0] rd; logic [4:0] rs1; logic [4:0] rs2; logic [7:0] p_frd;
  } sbe_t;
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

  g6lc_iq #(.G6LCCfg(C), .DEPTH(DEPTH), .PRF_W(4), .scoreboard_entry_t(sbe_t)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush), .cancelled_mask_i(cancel),
    .disp_valid_i(dv), .disp_sbe_i(ds), .disp_orig_i(di), .disp_prs1_i(p1), .disp_prs2_i(p2), .disp_prd_i(pd),
    .disp_fprs1_i('0), .disp_fprs2_i('0), .disp_fprs3_i('0),
    .disp_fpr_rs1_i('0), .disp_fpr_rs2_i('0), .disp_fpr_rs3_i('0),
    .disp_rs3_ready_i('1), .fwb_valid_i('0), .fwb_prd_i('0),
    .disp_rs1_ready_i(r1), .disp_rs2_ready_i(r2), .disp_may_bypass_i(bypass), .disp_ack_o(da), .full_o(full), .empty_o(empty),
    .wb_valid_i(wv), .wb_prd_i(wp),
    // All functional units ready; no steering hints, no replay. (The
    // *_ready_i / steer / replay ports postdate the CVXIF bench this was
    // cloned from -- leaving them unconnected ties them to 0 and an
    // unready FU silently blocks issue.)
    .lsu_ready_i(1'b1), .fpu_ready_i(1'b1), .csr_ready_i(1'b1), .mult_ready_i(1'b1),
    .steer_hint_i('0), .steer_pre_valid_i('0), .steer_pre_hint_i('0),
    .replay_valid_i(1'b0), .replay_tid_i('0),
    .issue_sbe_o(is), .issue_orig_o(ii), .issue_prd_o(ip), .issue_valid_o(iv), .issue_ack_i(ia), .mem_stall_i(mem_stall),
    .st_live_mask_i(st_live), .st_unresolved_mask_i(st_unresolved), .st_hart_mask_i(st_live), .commit_ptr_i(commit_ptr), .sb_live_i('1));

  task automatic tick; clk = 1; #2; clk = 0; #2; endtask
  task automatic clear_inputs;
    flush = 0; mem_stall = 0; cancel = '0; dv = '0; ds = '0; di = '0; p1 = '0; p2 = '0; pd = '0; r1 = '0; r2 = '0; wv = '0; wp = '0; bypass = '0;
  endtask
  task automatic offer_op(input int id, input fu_t fu, input fu_op op);
    offer_op_prs(id, fu, op, 4'd0, 1'b1);
  endtask
  // prs = source register for rs1/rs2; rdy = dispatch-time operand-ready.
  // rdy=0 leaves the op unready until a wb_prd==prs writeback wakes it --
  // used to hold a younger op off the ports until the head op is granted.
  task automatic offer_op_prs(input int id, input fu_t fu, input fu_op op,
                              input logic [3:0] prs, input bit rdy);
    dv[0] = 1; ds[0] = '{fu: fu, op: op, trans_id: 4'(id), hart_id: 1'b0,
                    pc: 32'h1000 + 32'(id) * 4, rd: '0, rs1: '0, rs2: '0, p_frd: '0};
    di[0] = 32'h13000000 + 32'(id); p1[0] = prs; p2[0] = prs; pd[0] = 4'(id);
    r1[0] = rdy; r2[0] = rdy; bypass[0] = 0;
    tick(); clear_inputs(); #2;
  endtask
  // Pulse a writeback of `prs` so an unready op's rs1/rs2 wake (both read
  // the same source register in these tests).
  task automatic wake_prs(input logic [3:0] prs);
    wv[0] = 1; wp[0] = prs; tick(); wv = '0; wp = '0; #2;
  endtask
  // want=1: poll until ANY issue_valid bit rises (it holds until acked, so
  // waiting cannot drop it); the caller then checks the exact port/tid.
  // want=0: settle HELD_CYCLES so a would-be issue (e.g. under the NOHEAD
  // mutation) has the full flight window, then require iv==0.
  task automatic expect_issue(input bit want, input string tag);
    bit exp;
    exp = want ^ negative;
    if (exp) begin : expect_up
      int n = 0;
      while (iv === '0 && n < ISSUE_TIMEOUT) begin
        tick(); n++;
      end
      if (iv === '0) $fatal(1, "%s iv never rose", tag);
    end else begin : expect_down
      repeat (HELD_CYCLES) tick();
      if (iv !== '0) $fatal(1, "%s iv=%b expected held", tag, iv);
    end
    checked++;
  endtask
  // Poll until the issue_valid mask is fully presented (dual-issue checks).
  task automatic wait_iv(input logic [NP-1:0] mask, input string tag);
    int n = 0;
    while ((iv & mask) !== mask && n < ISSUE_TIMEOUT) begin tick(); n++; end
    if ((iv & mask) !== mask) $fatal(1, "%s iv=%b mask=%b", tag, iv, mask);
  endtask
  // Ack every presented port until issue_valid drains, so the next scenario
  // starts from an empty in-flight set.
  task automatic drain_ports;
    int n = 0;
    ia = '1;
    while (iv !== '0 && n < ISSUE_TIMEOUT) begin tick(); n++; end
    ia = '0; #2;
    if (iv !== '0) $fatal(1, "drain_ports stuck iv=%b", iv);
  endtask

  initial begin
    negative = $test$plusargs("oracle_negative");
    clear_inputs(); #2; tick(); rst_n = 1; #2;

    // S1: ACCEL op 3 while the head is 0 -> held; head moves to 3 -> offered.
    commit_ptr = 4'd0;
    offer_op(3, ACCEL, ACCEL_OP); expect_issue(0, "IQ_ACCEL_HEAD");
    commit_ptr = 4'd3; expect_issue(1, "IQ_ACCEL_HEAD");
    // ACCEL is port0-only: the single presented op must be on port 0.
    if (iv[0] !== 1'b1 || (NP > 1 && iv[1] !== 1'b0)) $fatal(1, "IQ_ACCEL_HEAD iv=%b", iv);
    if (is[0].fu !== ACCEL || is[0].trans_id !== 4'd3) $fatal(1, "IQ_ACCEL_HEAD wrong entry on port 0");
    drain_ports();

    // S2: a held ACCEL op does not block a younger plain op (head-only rule,
    // not a barrier). The lone ALU candidate takes the first free port.
    commit_ptr = 4'd0;
    offer_op(5, ACCEL, ACCEL_OP); expect_issue(0, "IQ_ACCEL_HEAD_HOLD");
    offer_op(6, ALU, ADD); expect_issue(1, "IQ_ACCEL_NOT_BARRIER");
    begin : find_tid6
      int n = 0;
      while (!((iv[0] && is[0].trans_id === 4'd6) ||
               (NP > 1 && iv[1] && is[1].trans_id === 4'd6)) && n < ISSUE_TIMEOUT) begin
        tick(); n++;
      end
    end
    if (!((iv[0] && is[0].trans_id === 4'd6) ||
          (NP > 1 && iv[1] && is[1].trans_id === 4'd6)))
      $fatal(1, "IQ_ACCEL_NOT_BARRIER tid6 not issued iv=%b", iv);
    drain_ports();
    // still held after the younger left
    expect_issue(0, "IQ_ACCEL_HEAD_HOLD2");

    // S3: head reaches the ACCEL op while a younger ALU op is held only by
    // its operands (an ALU is not head-only, so without the operand gate it
    // would issue early and steal port 0). op7 reads reg5 with rdy=0, so it
    // sits unready; commit=5 lets ACCEL take port 0, then the reg5 writeback
    // wakes op7 onto port 1 -- dual-issue under the head-only contract.
    offer_op_prs(7, ALU, ADD, 4'd5, 1'b0);
    // Wake op7's operands ~1 cycle after the head moves so its candidate
    // reaches the arbiter the same cycle op5's does -> simultaneous grant
    // (ACCEL port0, ALU port1). Too early and op7 steals port0; too late and
    // op5's held presentation marks it used before port1 can take it.
    commit_ptr = 4'd5; tick(); wake_prs(4'd5); wait_iv(NP'(3), "IQ_ACCEL_PORT0");
    if (is[0].fu !== ACCEL || is[0].trans_id !== 4'd5) $fatal(1, "IQ_ACCEL_PORT0 port0 tid=%0d fu=%0d", is[0].trans_id, is[0].fu);
    if (NP > 1 && (!iv[1] || is[1].trans_id !== 4'd7 || is[1].fu !== ALU))
      $fatal(1, "IQ_ACCEL_PORT0 port1 tid=%0d fu=%0d", is[1].trans_id, is[1].fu);

    if (negative) $fatal(1, "ORACLE_NEGATIVE forced");
    $display("PASS tb_g6lc_iq_accel_head checked=%0d", checked);
    $finish;
  end
endmodule
