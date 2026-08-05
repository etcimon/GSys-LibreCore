// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// P16 golden fixture (B3 — per-module CST scoping).
//
// Two modules in ONE file, with deliberately disjoint ports, regions and one
// instantiation that belongs to `holder_b` only.
// Expected after B3:
//   * `leaf_a` sees exactly its own ports (a_i/b_i/y_o) — never `p_i`/`q_o`
//   * `holder_b` sees exactly its own ports (p_i/q_o) — never `a_i`/`b_i`/`y_o`
//   * `leaf_a` has 1 region, `holder_b` has 1 region (not 2 each)
//   * the `leaf_a` instance is attributed to `holder_b` only
// Before B3 every collector re-walked the whole file per module, so each module
// inherited the *union* of both modules' ports, params and regions.

module leaf_a #(
    parameter int unsigned WIDTH_A = 8
) (
    input  logic [WIDTH_A-1:0] a_i,
    input  logic [WIDTH_A-1:0] b_i,
    output logic [WIDTH_A:0]   y_o
);
  always_comb begin : leaf_a_cloud
    y_o = a_i + b_i;
  end
endmodule

module holder_b #(
    parameter int unsigned WIDTH_B = 16
) (
    input  logic [WIDTH_B-1:0] p_i,
    output logic [WIDTH_B:0]   q_o
);
  logic [8:0] mid;

  leaf_a #(
      .WIDTH_A(8)
  ) i_leaf (
      .a_i(p_i[7:0]),
      .b_i(p_i[7:0]),
      .y_o(mid)
  );

  always_comb begin : holder_b_cloud
    q_o = {7'b0, mid};
  end
endmodule
