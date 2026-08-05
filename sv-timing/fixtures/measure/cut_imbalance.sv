// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// P14 golden fixture (M5 — cost-balanced cut, not index midpoint).
//
// One expensive node (multiply, ≈56 FO4) followed by eight cheap bit ops
// (≈1 FO4 each). Total ≈64 FO4 on a 9-node chain.
// Expected after M5 with `--opt-cut-strategy cost-balanced`:
//   * cut lands immediately AFTER the multiply (prefix sum first reaches
//     total/2 at that node) ⇒ segments ≈56 / ≈8
//   * legacy `mid-node` cuts at node index 3 ⇒ segments ≈59 / ≈5, i.e. it
//     leaves the multiply and three bit ops in the same stage and buys nothing
// The fixture is intentionally 1-bit-wide on the cheap ops so width scaling
// (M3) cannot mask the imbalance.

module cut_imbalance (
    input  logic [15:0] a_i,
    input  logic [15:0] b_i,
    input  logic        c_i,
    output logic        y_o
);
  logic [31:0] prod;
  logic        n0, n1, n2, n3, n4, n5, n6;

  always_comb begin : hot_chain
    prod = a_i * b_i;
    n0   = prod[0] & c_i;
    n1   = n0 ^ c_i;
    n2   = n1 & c_i;
    n3   = n2 ^ c_i;
    n4   = n3 & c_i;
    n5   = n4 ^ c_i;
    n6   = n5 & c_i;
    y_o  = n6 ^ c_i;
  end
endmodule
