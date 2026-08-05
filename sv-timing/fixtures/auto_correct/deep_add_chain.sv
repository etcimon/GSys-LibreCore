// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Auto-correct fixture: deep add chain (pipeline opportunity).

module deep_add_chain (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic [15:0] a_i,
    input  logic [15:0] b_i,
    input  logic [15:0] c_i,
    input  logic [15:0] d_i,
    output logic [17:0] y_o
);
  logic [17:0] t0, t1, t2;
  always_comb begin
    t0 = a_i + b_i;
    t1 = t0 + c_i;
    t2 = t1 + d_i;
    y_o = t2;
  end
endmodule
