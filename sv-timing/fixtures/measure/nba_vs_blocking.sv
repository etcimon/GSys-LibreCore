// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// PASS-STRATEGY: blocking temps in always_ff are combo, not flops.
// `tmp = a_i + b_i` must not be seq_lhs; `y_q <= tmp + c_i` is the NBA capture.

module nba_vs_blocking (
    input  logic       clk_i,
    input  logic       rst_ni,
    input  logic [7:0] a_i,
    input  logic [7:0] b_i,
    input  logic [7:0] c_i,
    output logic [9:0] y_o
);
  logic [8:0] tmp;
  logic [9:0] y_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      y_q <= '0;
    end else begin
      tmp = a_i + b_i;
      y_q <= tmp + c_i;
    end
  end

  assign y_o = y_q;
endmodule
