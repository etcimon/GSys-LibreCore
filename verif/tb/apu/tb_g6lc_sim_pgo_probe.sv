// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Standalone compiler infrastructure regression, not functional device RTL.
`timescale 1ns/1ps
module tb_g6lc_sim_pgo_probe;
  //pragma translate_off
  bit clk = 0;
  logic rst_ni = 0;
  logic [31:0] count_q;
  always #1 clk = ~clk;
  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) count_q <= '0;
    else count_q <= count_q + 1;
  end
  initial begin
    repeat (2) @(negedge clk);
    rst_ni = 1;
    repeat (16) @(negedge clk);
    if (count_q != 16) $fatal(1, "counter mismatch");
    $display("PASS tb_g6lc_sim_pgo_probe checks=1");
    $finish;
  end
  //pragma translate_on
endmodule
