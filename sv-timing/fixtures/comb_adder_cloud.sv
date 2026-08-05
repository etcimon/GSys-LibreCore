// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Fixture: shallow combinational cloud for parse / later FO4 tests.

module comb_adder_cloud (
    input  logic [7:0] a_i,
    input  logic [7:0] b_i,
    input  logic [7:0] c_i,
    output logic [9:0] y_o
);
  logic [8:0] s1;
  logic [9:0] s2;
  always_comb begin
    s1 = a_i + b_i;
    s2 = s1 + c_i;
    y_o = s2;
  end
endmodule
