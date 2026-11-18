// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Directed execute leaf for g6lc_fp_zfa (fli / fround / fcvtmod).
`timescale 1ns / 1ps
module tb_g6lc_fp_zfa
  import ariane_pkg::*;
;
  function automatic config_pkg::cva6_cfg_t cfg();
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN = 64;
    c.FLen = 64;
    c.RVF = 1'b1;
    c.RVD = 1'b1;
    c.RVZfa = 1'b1;
    c.XF16 = 1'b0;
    c.TRANS_ID_BITS = 4;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C = cfg();

  logic clk, rst_n, flush, valid_i, ready_o, ready_i, valid_o;
  fu_op op;
  logic [1:0] fmt;
  logic [2:0] rm;
  logic [63:0] operand, result;
  logic [3:0] tag_i, tag_o;
  logic [4:0] status;

  g6lc_fp_zfa #(
      .CVA6Cfg (C),
      .TagWidth(4)
  ) dut (
      .clk_i(clk),
      .rst_ni(rst_n),
      .flush_i(flush),
      .valid_i(valid_i),
      .ready_o(ready_o),
      .op_i(op),
      .fmt_i(fmt),
      .rm_i(rm),
      .operand_i(operand),
      .tag_i(tag_i),
      .ready_i(ready_i),
      .valid_o(valid_o),
      .result_o(result),
      .status_o(status),
      .tag_o(tag_o)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  task automatic issue(input fu_op o, input logic [1:0] f, input logic [2:0] r, input logic [63:0] a);
    @(posedge clk);
    op = o;
    fmt = f;
    rm = r;
    operand = a;
    tag_i = 4'd1;
    valid_i = 1'b1;
    @(posedge clk);
    valid_i = 1'b0;
    while (!valid_o) @(posedge clk);
  endtask

  initial begin
    rst_n = 1'b0;
    flush = 1'b0;
    valid_i = 1'b0;
    ready_i = 1'b1;
    op = FLI;
    fmt = 2'b00;
    rm = 3'b000;
    operand = '0;
    tag_i = '0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    issue(FLI, 2'b00, 3'b000, 64'd16);
    if (result !== 64'hFFFFFFFF3F800000)
      $fatal(1, "ZFA_ON fli.s 1.0 got %h", result);

    issue(FLI, 2'b00, 3'b000, 64'd0);
    if (result !== 64'hFFFFFFFFBF800000)
      $fatal(1, "ZFA_ON fli.s -1.0 got %h", result);

    issue(FLI, 2'b01, 3'b000, 64'd16);
    if (result !== 64'h3FF0000000000000)
      $fatal(1, "ZFA_ON fli.d 1.0 got %h", result);

    issue(FROUND, 2'b00, 3'b000, 64'hFFFFFFFF3FC00000);
    if (result !== 64'hFFFFFFFF40000000)
      $fatal(1, "ZFA_ON fround.s 1.5 rne got %h", result);

    issue(FROUND, 2'b00, 3'b001, 64'hFFFFFFFF3FC00000);
    if (result !== 64'hFFFFFFFF3F800000)
      $fatal(1, "ZFA_ON fround.s 1.5 rtz got %h", result);

    issue(FROUND, 2'b00, 3'b000, 64'hFFFFFFFF3F000000);
    if (result !== 64'hFFFFFFFF00000000)
      $fatal(1, "ZFA_ON fround.s 0.5 rne got %h", result);

    issue(FROUNDNX, 2'b00, 3'b000, 64'hFFFFFFFF3FC00000);
    if (result !== 64'hFFFFFFFF40000000 || status[0] !== 1'b1)
      $fatal(1, "ZFA_ON froundnx.s 1.5 nx got %h st=%b", result, status);

    issue(FCVTMOD, 2'b01, 3'b001, 64'h3FF8000000000000);
    if (result[31:0] !== 32'd1 || status[0] !== 1'b1)
      $fatal(1, "ZFA_ON fcvtmod 1.5 got %h st=%b", result, status);

    issue(FCVTMOD, 2'b01, 3'b001, 64'hBFF8000000000000);
    if (result[31:0] !== 32'hFFFFFFFF)
      $fatal(1, "ZFA_ON fcvtmod -1.5 got %h", result);

    issue(FCVTMOD, 2'b01, 3'b001, 64'h7FF0000000000000);
    if (result !== 64'd0 || status[4] !== 1'b1)
      $fatal(1, "ZFA_ON fcvtmod inf got %h st=%b", result, status);

    issue(FCVTMOD, 2'b01, 3'b001, 64'h41F0000000100000);
    if (result[31:0] !== 32'd1)
      $fatal(1, "ZFA_ON fcvtmod 2^32+1 got %h", result);

    $display("PASS tb_g6lc_fp_zfa");
    $finish;
  end
endmodule
