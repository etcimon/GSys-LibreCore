// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Zicclsm splitter: intra-word pass-through; wrapping LH two-beat merge.
// Mutation +define+G6LC_MUT_ZICCLSM_OFF must fail ZICCLSM_ON.
`timescale 1ns / 1ps
module tb_g6lc_zicclsm
  import ariane_pkg::*;
;
  function automatic config_pkg::cva6_cfg_t cfg_of(input bit on);
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN = 64;
    c.VLEN = 64;
    c.IS_XLEN64 = 1'b1;
    c.TRANS_ID_BITS = 4;
    c.NrHarts = 1;
`ifdef G6LC_MUT_ZICCLSM_OFF
    c.RVZicclsm = 1'b0;
`else
    c.RVZicclsm = on;
`endif
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C_ON = cfg_of(1'b1);
  localparam config_pkg::cva6_cfg_t C_OFF = cfg_of(1'b0);

  typedef struct packed {
    logic [63:0] cause;
    logic [63:0] tval;
    logic [40:0] tval2;
    logic [31:0] tinst;
    logic        gva;
    logic        valid;
  } exception_t;
  typedef struct packed {
    logic [2:0]  data_prot;
    logic        valid;
    logic [63:0] vaddr;
    logic [31:0] tinst;
    logic        hs_ld_st_inst;
    logic        hlvx_inst;
    logic        overflow;
    logic        g_overflow;
    logic [63:0] data;
    logic [63:0] data_cmp;
    logic [63:0] data_hi;
    logic [63:0] data_cmp_hi;
    logic [7:0]  be;
    fu_t         fu;
    fu_op        operation;
    logic [3:0]  trans_id;
    logic        hart;
    logic        is_speculative_load;
    logic        is_speculative_load_miss;
  } lsu_ctrl_t;

  logic clk, rst_n, flush;
  lsu_ctrl_t ctrl_i, ctrl_on, ctrl_off;
  logic pop_ld_fu, pop_st_fu, pop_ld_byp, pop_st_byp;
  logic ld_valid_fu, ld_valid_on;
  logic [63:0] ld_result_fu, ld_result_on;
  exception_t ld_ex_fu, ld_ex_on;
  logic [3:0] ld_tid_fu, ld_tid_on;
  logic st_valid_fu, st_valid_on;
  logic [63:0] st_result_fu, st_result_on;
  exception_t st_ex_fu, st_ex_on;
  logic [3:0] st_tid_fu, st_tid_on;

  g6lc_zicclsm #(
      .CVA6Cfg(C_ON), .lsu_ctrl_t(lsu_ctrl_t), .exception_t(exception_t)
  ) dut_on (
      .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
      .ctrl_i(ctrl_i), .ctrl_o(ctrl_on),
      .pop_ld_fu_i(pop_ld_fu), .pop_st_fu_i(pop_st_fu),
      .pop_ld_byp_o(pop_ld_byp), .pop_st_byp_o(pop_st_byp),
      .ld_valid_fu_i(ld_valid_fu), .ld_result_fu_i(ld_result_fu),
      .ld_ex_fu_i(ld_ex_fu), .ld_tid_fu_i(ld_tid_fu),
      .ld_valid_o(ld_valid_on), .ld_result_o(ld_result_on),
      .ld_ex_o(ld_ex_on), .ld_tid_o(ld_tid_on),
      .st_valid_fu_i(st_valid_fu), .st_result_fu_i(st_result_fu),
      .st_ex_fu_i(st_ex_fu), .st_tid_fu_i(st_tid_fu),
      .st_valid_o(st_valid_on), .st_result_o(st_result_on),
      .st_ex_o(st_ex_on), .st_tid_o(st_tid_on)
  );

  g6lc_zicclsm #(
      .CVA6Cfg(C_OFF), .lsu_ctrl_t(lsu_ctrl_t), .exception_t(exception_t)
  ) dut_off (
      .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
      .ctrl_i(ctrl_i), .ctrl_o(ctrl_off),
      .pop_ld_fu_i(pop_ld_fu), .pop_st_fu_i(pop_st_fu),
      .pop_ld_byp_o(), .pop_st_byp_o(),
      .ld_valid_fu_i(ld_valid_fu), .ld_result_fu_i(ld_result_fu),
      .ld_ex_fu_i(ld_ex_fu), .ld_tid_fu_i(ld_tid_fu),
      .ld_valid_o(), .ld_result_o(), .ld_ex_o(), .ld_tid_o(),
      .st_valid_fu_i(st_valid_fu), .st_result_fu_i(st_result_fu),
      .st_ex_fu_i(st_ex_fu), .st_tid_fu_i(st_tid_fu),
      .st_valid_o(), .st_result_o(), .st_ex_o(), .st_tid_o()
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  task automatic idle_bus();
    pop_ld_fu = 1'b0;
    pop_st_fu = 1'b0;
    ld_valid_fu = 1'b0;
    st_valid_fu = 1'b0;
    ld_result_fu = '0;
    st_result_fu = '0;
    ld_ex_fu = '0;
    st_ex_fu = '0;
    ld_tid_fu = '0;
    st_tid_fu = '0;
  endtask

  initial begin
    rst_n = 1'b0;
    flush = 1'b0;
    ctrl_i = '0;
    idle_bus();
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // Intra-word LH at offset 1: pass through.
    ctrl_i.valid = 1'b1;
    ctrl_i.fu = LOAD;
    ctrl_i.operation = LH;
    ctrl_i.vaddr = 64'h1;
    ctrl_i.trans_id = 4'd3;
    @(posedge clk);
    if (ctrl_on.vaddr[2:0] !== 3'd1 || ctrl_on.operation !== LH)
      $fatal(1, "ZICCLSM_ON intra-word lh must pass through");
    if (ctrl_off.vaddr[2:0] !== 3'd1)
      $fatal(1, "ZICCLSM_ON off path broken");
    ctrl_i.valid = 1'b0;
    @(posedge clk);

    // Wrapping LH at offset 7: two aligned LD beats, merge 0xBBAA.
    idle_bus();
    ctrl_i.valid = 1'b1;
    ctrl_i.fu = LOAD;
    ctrl_i.operation = LH;
    ctrl_i.vaddr = 64'h7;
    ctrl_i.trans_id = 4'd4;
    @(posedge clk);
    if (ctrl_off.operation !== LH)
      $fatal(1, "ZICCLSM_ON wrap must stay unsplit with knob off");
    if (ctrl_on.operation !== LD || ctrl_on.vaddr[2:0] !== 3'd0)
      $fatal(1, "ZICCLSM_ON wrap beat0 op=%0d vaddr=%h", ctrl_on.operation, ctrl_on.vaddr);
    pop_ld_fu = 1'b1;
    @(posedge clk);
    pop_ld_fu = 1'b0;
    ld_valid_fu = 1'b1;
    ld_result_fu = 64'hAA00000000000000;
    @(posedge clk);
    ld_valid_fu = 1'b0;
    ld_result_fu = '0;
    @(posedge clk);
    if (ctrl_on.operation !== LD || ctrl_on.vaddr !== 64'h8)
      $fatal(1, "ZICCLSM_ON wrap beat1 vaddr=%h op=%0d", ctrl_on.vaddr, ctrl_on.operation);
    pop_ld_fu = 1'b1;
    @(posedge clk);
    pop_ld_fu = 1'b0;
    ld_valid_fu = 1'b1;
    ld_result_fu = 64'h00000000000000BB;
    @(posedge clk);
    ld_valid_fu = 1'b0;
    if (!ld_valid_on || ld_result_on[15:0] !== 16'hBBAA)
      $fatal(1, "ZICCLSM_ON wrap merge got %h valid=%0d", ld_result_on, ld_valid_on);
    if (ld_result_on[63:16] !== {48{1'b1}})
      $fatal(1, "ZICCLSM_ON lh sign-extend got %h", ld_result_on);
    @(posedge clk);
    idle_bus();
    ctrl_i.valid = 1'b0;

    // Squash landing mid-split (B0_WAIT): OoO cancelled_mask recovery is not
    // a flush_i, so the held bypass head must be released, not pinned. With
    // the fix the module returns to IDLE and re-presents the still-flagged
    // head unsplit; without it ctrl_o.valid stays 0 in B0_WAIT forever.
    ctrl_i.valid = 1'b1;
    ctrl_i.fu = LOAD;
    ctrl_i.operation = LH;
    ctrl_i.vaddr = 64'h7;
    ctrl_i.trans_id = 4'd5;
    ctrl_i.is_speculative_load_miss = 1'b0;
    @(posedge clk);                 // split_now -> B0_ACTIVE, beat0 driven
    pop_ld_fu = 1'b1;               // beat0 squashed: FU pops, no result
    @(posedge clk);                 // B0_ACTIVE -> B0_WAIT
    pop_ld_fu = 1'b0;
    ctrl_i.is_speculative_load_miss = 1'b1;   // cancel lands while held
    @(posedge clk);                 // B0_WAIT + miss -> abort -> IDLE + pop
    // IDLE now passes the still-cancelled head through unsplit (split_now
    // guard). Buggy behaviour: ctrl_o.valid==0 held in B0_WAIT.
    if (ctrl_on.valid !== 1'b1 || ctrl_on.operation !== LH ||
        ctrl_on.is_speculative_load_miss !== 1'b1)
      $fatal(1, "ZICCLSM_ON cancel-in-B0_WAIT did not release head: v=%0d op=%0d miss=%0d",
             ctrl_on.valid, ctrl_on.operation, ctrl_on.is_speculative_load_miss);
    ctrl_i.valid = 1'b0;
    ctrl_i.is_speculative_load_miss = 1'b0;
    @(posedge clk);
    idle_bus();
    $display("PASS tb_g6lc_zicclsm");
    $finish;
  end
endmodule
