// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Multi-module project fixture: leaf datapath (hot add chain).

module proj_leaf (
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
    y_o = t2 + t0;
  end
endmodule
