// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
// Unit leaf for g6lc_ai_mul_seq (WA x WB -> WA+WB product, WB-cycle
// shift-add). 5 pairs per (WA,WB) configuration, including top-bit-set
// operands, checked against native `*`.
`timescale 1ns/1ps
module tb_g6lc_ai_mul_seq;
  logic clk = 0, rst_n = 0;
  always #1 clk = ~clk;
  int unsigned checks = 0, fails = 0;

  // (WA,WB) = (32,32)
  logic        s32_start; logic [31:0] s32_a, s32_b;
  logic        s32_done; logic [63:0] s32_p;
  g6lc_ai_mul_seq #(.WA(32), .WB(32)) i_c (
    .clk_i(clk), .rst_ni(rst_n), .start_i(s32_start),
    .a_i(s32_a), .b_i(s32_b), .done_o(s32_done), .product_o(s32_p));

  // (WA,WB) = (32,64)
  logic        s64_start; logic [31:0] s64_a; logic [63:0] s64_b;
  logic        s64_done; logic [95:0] s64_p;
  g6lc_ai_mul_seq #(.WA(32), .WB(64)) i_o (
    .clk_i(clk), .rst_ni(rst_n), .start_i(s64_start),
    .a_i(s64_a), .b_i(s64_b), .done_o(s64_done), .product_o(s64_p));

  task automatic run32(input logic [31:0] a, b);
    logic [63:0] exp;
    int polls;
    exp = 64'(a) * 64'(b);
    @(posedge clk); s32_a <= a; s32_b <= b; s32_start <= 1;
    @(posedge clk); s32_start <= 0;
    polls = 0;
    while (!s32_done && polls < 300) begin @(posedge clk); polls++; end
    checks++;
    if (!s32_done) begin
      fails++;
      $display("FAIL s32 done timeout a=%h b=%h", a, b);
    end else if (s32_p !== exp) begin
      fails++;
      $display("FAIL s32 %h*%h: got %h want %h", a, b, s32_p, exp);
    end else
      $display("PASS s32 %h*%h = %h (%0d cyc)", a, b, s32_p, polls);
  endtask

  task automatic run64(input logic [31:0] a, input logic [63:0] b);
    logic [95:0] exp;
    int polls;
    exp = 96'(a) * 96'(b);
    @(posedge clk); s64_a <= a; s64_b <= b; s64_start <= 1;
    @(posedge clk); s64_start <= 0;
    polls = 0;
    while (!s64_done && polls < 300) begin @(posedge clk); polls++; end
    checks++;
    if (!s64_done) begin
      fails++;
      $display("FAIL s64 done timeout a=%h b=%h", a, b);
    end else if (s64_p !== exp) begin
      fails++;
      $display("FAIL s64 %h*%h: got %h want %h", a, b, s64_p, exp);
    end else
      $display("PASS s64 %h*%h = %h (%0d cyc)", a, b, s64_p, polls);
  endtask

  initial begin
    s32_start = 0; s32_a = '0; s32_b = '0;
    s64_start = 0; s64_a = '0; s64_b = '0;
    repeat (4) @(posedge clk); rst_n = 1;
    repeat (2) @(posedge clk);
    run32(32'd0, 32'd0);
    run32(32'd1, 32'd1);
    run32(32'd2, 32'd4);
    run32(32'h8000_0000, 32'h8000_0001);
    run32(32'hFFFF_FFFF, 32'hFFFF_FFFF);
    run64(32'd0, 64'd0);
    run64(32'd1, 64'd4);
    run64(32'd4, 64'h2_0000_0000);
    run64(32'h8000_0000, 64'h8_0000_0001);
    run64(32'hFFFF_FFFF, 64'hF_FFFF_FFFF);
    repeat (3) @(posedge clk);
    if (fails == 0) $display("PASS tb_g6lc_ai_mul_seq checks=%0d", checks);
    else            $display("FAIL tb_g6lc_ai_mul_seq checks=%0d fails=%0d", checks, fails);
    $finish;
  end
endmodule
