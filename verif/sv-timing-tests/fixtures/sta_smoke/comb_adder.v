// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Minimal pure-Verilog module for OpenSTA handoff S1 CI (Yosys read_verilog).
// Not part of any CVA6 flist; used only by timings-sta-handoff / staHandoff tests.

module comb_adder (
  input  wire       clk_i,
  input  wire [7:0] a_i,
  input  wire [7:0] b_i,
  output reg  [7:0] y_o
);
  wire [7:0] sum;
  assign sum = a_i + b_i;
  always @(posedge clk_i) begin
    y_o <= sum;
  end
endmodule
