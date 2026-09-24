// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// A RAM fault requests a fabric reset and holds it until the fault drops.
// The supervisor does not clear the fault by itself. Enable=0 stays quiet.

`timescale 1ns/1ps

module tb_g6lc_apu_fault_sup;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import axi_pkg::*;
  logic clk = 0, rst_ni = 0;
  logic reset_o, stuck_reset, off_reset, fault;
  logic ram_rst_n;
  apu_dma_axi_req_t req;
  apu_dma_axi_resp_t rsp;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  bit arm_legal = 0, saw_legal_reset = 0;

  assign ram_rst_n = rst_ni & ~reset_o;
  g6lc_apu_fwram #(
      .ApuCfg(ApuHarness),
      .RamIdx(12),
      .HexFile("none")
  ) i_ram (
      .clk_i(clk), .rst_ni(ram_rst_n), .testmode_i(1'b0),
      .aw_hart_i(32'd1), .ar_hart_i(32'd1),
      .slv_req_i(req), .slv_rsp_o(rsp),
      .ram_rule_o(), .ram_base_o(), .ram_end_o(),
      .fault_o(fault)
  );
  g6lc_apu_fault_sup #(.Enable(1'b1)) i_sup (
      .clk_i(clk), .rst_ni, .fault_i(fault), .reset_o(reset_o)
  );
  g6lc_apu_fault_sup #(.Enable(1'b1)) i_stuck (
      .clk_i(clk), .rst_ni, .fault_i(1'b1), .reset_o(stuck_reset)
  );
  g6lc_apu_fault_sup_fixture #(.Enable(1'b0)) i_off (
      .clk_i(clk), .rst_ni, .fault_i(1'b1), .reset_o(off_reset)
  );

  always #5 clk = ~clk;
  always @(posedge clk) begin
    cycles++;
    if (rst_ni && arm_legal && reset_o) saw_legal_reset = 1;
  end
  initial begin #200000; $fatal(1, "fault sup timeout case=%0d", cases); end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  task automatic write_word(input logic [63:0] addr, input logic [31:0] data,
      input logic last, input logic [1:0] bresp);
    bit aw_done, w_done, saw_b;
    aw_done = 0; w_done = 0; saw_b = 0;
    @(negedge clk);
    req = '0;
    req.aw.addr = addr; req.aw.size = 3'd2; req.aw.len = '0;
    req.aw.burst = BURST_INCR; req.aw.id = 4'h1;
    req.w.data = {32'h0, data}; req.w.strb = 8'h0f; req.w.last = last;
    req.aw_valid = 1; req.w_valid = 1;
    while (!aw_done || !w_done) begin
      @(posedge clk);
      if (req.aw_valid && rsp.aw_ready) aw_done = 1;
      if (req.w_valid && rsp.w_ready) w_done = 1;
      if (rsp.b_valid) saw_b = 1;
      @(negedge clk);
      if (aw_done) req.aw_valid = 0;
      if (w_done) req.w_valid = 0;
    end
    if (last) begin
      @(posedge clk);
      while (!rsp.b_valid) @(posedge clk);
      check("legal B", rsp.b.resp == bresp && rsp.b.id == 4'h1);
      @(negedge clk); req.b_ready = 1;
      @(posedge clk); @(negedge clk); req.b_ready = 0;
    end else begin
      check("quarantine has no B yet", !saw_b && !rsp.b_valid);
    end
  endtask

  task automatic read_word(input logic [63:0] addr, output logic [31:0] data);
    @(negedge clk);
    req = '0;
    req.ar.addr = addr; req.ar.size = 3'd2; req.ar.len = '0;
    req.ar.burst = BURST_INCR; req.ar.id = 4'h1; req.ar_valid = 1;
    @(posedge clk);
    while (!rsp.ar_ready) @(posedge clk);
    @(negedge clk); req.ar_valid = 0;
    @(posedge clk);
    while (!rsp.r_valid) @(posedge clk);
    data = rsp.r.data[31:0];
    check("read OKAY", rsp.r.resp == RESP_OKAY && rsp.r.last);
    @(negedge clk); req.r_ready = 1;
    @(posedge clk); @(negedge clk); req.r_ready = 0;
  endtask

  initial begin
    logic [31:0] got;
    int guard;
    bit saw_reset;
    req = '0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);

    cases = 1;
    arm_legal = 1;
    write_word(64'h9000_1000, 32'h5150_0001, 1'b1, RESP_OKAY);
    read_word(64'h9000_1000, got);
    check("legal store landed", got == 32'h5150_0001);
    check("legal store does not request reset", !saw_legal_reset && !reset_o && !fault);
    arm_legal = 0;

    cases = 2;
    write_word(64'h9000_1000, 32'hffff_ffff, 1'b0, RESP_OKAY);
    check("fault is high before the supervisor acts", fault && !reset_o);
    saw_reset = 0;
    guard = 0;
    // #1 is after the clock's nonblocking updates. reset_o rises then, and
    // the RAM's async reset has already dropped fault. They are not a pair
    // that stays high together for a whole cycle.
    while (!saw_reset) begin
      @(posedge clk);
      #1;
      check("no B while the master is still waiting", !rsp.b_valid);
      if (reset_o) saw_reset = 1;
      guard++;
      if (guard > 20) $fatal(1, "reset was not requested");
    end
    check("reset stays up after the fault drops", reset_o && !fault);
    guard = 0;
    while (reset_o || fault) begin
      @(posedge clk);
      #1;
      check("waiting master still has no B", !rsp.b_valid);
      guard++;
      if (guard > 20) $fatal(1, "reset did not release");
    end
    req = '0;
    @(posedge clk);
    read_word(64'h9000_1000, got);
    check("quarantined store did not land", got == 32'h5150_0001);
    write_word(64'h9000_1000, 32'h5150_0002, 1'b1, RESP_OKAY);
    read_word(64'h9000_1000, got);
    check("legal store works after the fabric reset", got == 32'h5150_0002);
    check("fault stays down", !fault && !reset_o);

    cases = 3;
    check("disabled supervisor ignores the fault", !off_reset);
    check("a held fault does not time out", stuck_reset);
    repeat (20) @(posedge clk);
    check("held fault is still in reset", stuck_reset && !off_reset);

    if (errors != 0) $fatal(1, "APU fault sup errors=%0d", errors);
    $display("PASS tb_g6lc_apu_fault_sup cases=%0d checks=%0d cycles=%0d errors=0",
             cases, checks, cycles);
    $finish;
  end
endmodule
