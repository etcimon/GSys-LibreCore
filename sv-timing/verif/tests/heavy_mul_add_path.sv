// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Heavy timing path fixture: long mul+add cloud for frequency-closure / precompiler regress.
// Target: force negative slack at multi-GHz structural FO4 budgets.

module heavy_mul_add_path (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    input  logic [31:0] c_i,
    input  logic [31:0] d_i,
    input  logic [31:0] e_i,
    output logic [63:0] y_o
);
  logic [63:0] m0, m1, m2, s0, s1, s2;

  // Deep combinational cloud (precompiler should split / pipeline).
  always_comb begin
    m0 = a_i * b_i;
    m1 = c_i * d_i;
    m2 = m0 * e_i;
    s0 = m0 + m1;
    s1 = s0 + m2;
    s2 = s1 + {32'b0, a_i};
    y_o = s2 + m1;
  end
endmodule
