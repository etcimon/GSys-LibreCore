// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Heavy compare / add chain (priority-like depth) for path ranking regress.

module heavy_priority_chain (
    input  logic [15:0] a_i,
    input  logic [15:0] b_i,
    input  logic [15:0] c_i,
    input  logic [15:0] d_i,
    input  logic [15:0] e_i,
    input  logic [15:0] f_i,
    output logic [17:0] y_o
);
  logic [17:0] t0, t1, t2, t3, t4;
  always_comb begin
    t0 = a_i + b_i;
    t1 = t0 + c_i;
    t2 = t1 + d_i;
    t3 = t2 + e_i;
    t4 = t3 + f_i;
    y_o = (t4 > 18'd100) ? (t4 - 18'd1) : (t4 + 18'd1);
  end
endmodule
