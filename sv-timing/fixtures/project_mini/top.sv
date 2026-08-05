// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Multi-module project fixture: top wires leaf + mid (no instance elab required for v1 paths).

module proj_top (
    input  logic [15:0] a_i,
    input  logic [15:0] b_i,
    input  logic [15:0] c_i,
    input  logic [15:0] d_i,
    output logic [17:0] y_leaf_o,
    output logic [17:0] y_mid_o
);
  // Structural stubs: modules analyzed independently in v1 (no cross-module paths yet).
  // Hosts may elaborate instances later; filelist still compiles as a multi-file unit.
  proj_leaf u_leaf (
      .a_i(a_i),
      .b_i(b_i),
      .c_i(c_i),
      .d_i(d_i),
      .y_o(y_leaf_o)
  );
  proj_mid u_mid (
      .a_i(a_i),
      .b_i(b_i),
      .c_i(c_i),
      .y_o(y_mid_o)
  );
endmodule
