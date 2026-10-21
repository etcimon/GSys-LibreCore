// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_iq: stores issue in age order among stores (T24). The store unit's
// speculative queue is freed only by in-order commit, so a younger store whose
// data was ready first must not take the slot the older store at the ROB head
// needs -- the deadlock mc_l3_evict_inclusion.S hit on the 4-core server (two
// younger stores issued ahead of an older one waiting on an L3-victim load,
// filled the two speculative slots, and the head could never issue).
// Scenarios: S1 an older store not yet ready holds a younger ready store, and
// a younger plain ALU op is NOT held (store-to-store only); S2 once the older
// store's operand arrives it issues first, the younger store the cycle after;
// S3 a younger ready load is not held by the older store either (the load
// ordering gate is the separate st_unresolved rule, tied off here).
// Mutation +define+G6LC_MUT_ST_NOAGE must fail IQ_ST_AGE; +oracle_negative
// flips the verdict.
module tb_g6lc_iq_store_age;
  import g6lc_core_pkg::*;
  parameter int NP = 2, DEPTH = 8;
  function automatic config_pkg::g6lc_cfg_t configuration();
    config_pkg::g6lc_cfg_t c = config_pkg::g6lc_cfg_empty;
    c.NrIssuePorts = NP; c.NrWbPorts = 2; c.NR_SB_ENTRIES = 16; c.TRANS_ID_BITS = 4; c.RVA = 1;
    return c;
  endfunction
  localparam config_pkg::g6lc_cfg_t C = configuration();
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

  g6lc_iq #(.G6LCCfg(C), .DEPTH(DEPTH), .PRF_W(4), .scoreboard_entry_t(sbe_t)) dut (
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
  // offer one op on dispatch port 0; rs2 ready flag and its physical tag are the knobs
  task automatic offer_op(input int id, input fu_t fu, input fu_op op, input bit rs2_ready, input logic [3:0] prs2);
    dv[0] = 1; ds[0] = '{fu: fu, op: op, trans_id: 4'(id), hart_id: 1'b0, pc: 32'h1000 + 32'(id) * 4};
    di[0] = 32'h13000000 + 32'(id); p1[0] = 0; p2[0] = prs2; pd[0] = 4'(id); r1[0] = 1; r2[0] = rs2_ready; bypass[0] = 0;
    tick(); clear_inputs(); #2;
  endtask
  task automatic wakeup(input logic [3:0] prd);
    wv[0] = 1; wp[0] = prd; tick(); clear_inputs(); #2;
  endtask
  task automatic expect_issue(input bit want, input string tag);
    if (iv[0] !== (want ^ negative)) $fatal(1, "%s iv=%b", tag, iv[0]);
    checked++;
  endtask
  task automatic expect_port0(input int tid, input string tag);
    if (!iv[0] || is[0].trans_id !== 4'(tid)) $fatal(1, "%s port0 iv=%b tid=%0d", tag, iv[0], is[0].trans_id);
    checked++;
  endtask
  task automatic drain_port0;
    ia = '1; tick(); ia = '0; #2;
  endtask

  initial begin
    negative = $test$plusargs("oracle_negative");
    clear_inputs(); #2; tick(); rst_n = 1; #2;
    commit_ptr = 4'd0;

    // S1: older store 2 waits on tag 9; younger store 3 is ready -> held.
    offer_op(2, STORE, SD, 1'b0, 4'd9); expect_issue(0, "IQ_ST_AGE_OLDER_NOT_READY");
    offer_op(3, STORE, SD, 1'b1, 4'd0); expect_issue(0, "IQ_ST_AGE");
    // a younger plain op is not held by the waiting stores (store-to-store rule only)
    offer_op(4, ALU, ADD, 1'b1, 4'd0); expect_port0(4, "IQ_ST_AGE_NOT_BARRIER");
    drain_port0();
    expect_issue(0, "IQ_ST_AGE_HOLD2");

    // S2: tag 9 arrives -> store 2 issues first, then store 3.
    wakeup(4'd9);
    expect_port0(2, "IQ_ST_AGE_OLDER_FIRST");
    drain_port0();
    expect_port0(3, "IQ_ST_AGE_YOUNGER_NEXT");
    drain_port0();
    expect_issue(0, "IQ_ST_AGE_EMPTY");

    // S3: an older waiting store does not hold a younger ready load (that is
    // the st_unresolved gate, tied off here).
    offer_op(5, STORE, SD, 1'b0, 4'd10); expect_issue(0, "IQ_ST_AGE_S3_HOLD");
    offer_op(6, LOAD, LD, 1'b1, 4'd0); expect_port0(6, "IQ_ST_AGE_LOAD_FREE");
    drain_port0();
    wakeup(4'd10);
    expect_port0(5, "IQ_ST_AGE_S3_RELEASE");
    drain_port0();

    if (negative) $fatal(1, "ORACLE_NEGATIVE forced");
    $display("PASS tb_g6lc_iq_store_age checked=%0d", checked);
    $finish;
  end
endmodule
