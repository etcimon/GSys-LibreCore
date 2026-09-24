// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// The crossbar port index is the upper ID bits. The master's low bits and
// any PROT value are not a hart.

`timescale 1ns/1ps

module tb_g6lc_apu_xbar_hart;
  logic [5:0] aw_id, ar_id;
  logic [31:0] aw_hart, ar_hart;
  int errors = 0, checks = 0;

  g6lc_apu_xbar_hart #(
      .IdxW(2),
      .IdW(6),
      .FwHart(32'd1),
      .ClusterPort(0)
  ) i_dut (
      .aw_id_i(aw_id),
      .ar_id_i(ar_id),
      .aw_hart_o(aw_hart),
      .ar_hart_o(ar_hart)
  );

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  initial begin
    aw_id = {2'b00, 4'hF}; ar_id = {2'b00, 4'h0};
    #1;
    check("cluster port is the firmware hart", aw_hart == 32'd1 && ar_hart == 32'd1);
    aw_id = {2'b00, 4'h0}; ar_id = {2'b00, 4'hA};
    #1;
    check("low ID bits do not change the cluster hart",
          aw_hart == 32'd1 && ar_hart == 32'd1);
    aw_id = {2'b01, 4'hF}; ar_id = {2'b01, 4'h1};
    #1;
    check("debug port is hart 0", aw_hart == 32'h0 && ar_hart == 32'h0);
    aw_id = {2'b10, 4'h0}; ar_id = {2'b11, 4'hF};
    #1;
    check("DMA and unknown ports are hart 0", aw_hart == 32'h0 && ar_hart == 32'h0);
    aw_id = {2'b00, 4'h1}; ar_id = {2'b10, 4'hF};
    #1;
    check("AW and AR ports are independent", aw_hart == 32'd1 && ar_hart == 32'h0);
    if (errors != 0) $fatal(1, "APU xbar hart errors=%0d", errors);
    $display("PASS tb_g6lc_apu_xbar_hart checks=%0d errors=0", checks);
    $finish;
  end
endmodule
