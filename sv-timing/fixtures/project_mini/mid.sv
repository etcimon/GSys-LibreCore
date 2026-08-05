// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Multi-module project fixture: mid combines leaf-style depth.

module proj_mid (
    input  logic [15:0] a_i,
    input  logic [15:0] b_i,
    input  logic [15:0] c_i,
    output logic [17:0] y_o
);
  logic [17:0] u0, u1;
  always_comb begin
    u0 = a_i + b_i;
    u1 = u0 + c_i;
    y_o = u1 + u0;
  end
endmodule
