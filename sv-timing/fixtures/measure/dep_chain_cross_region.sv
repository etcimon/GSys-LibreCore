// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// P14 golden fixture (M1 — the true longest path spans regions).
//
// The dependency chain is a_i -> t1 -> t2 -> t3 -> y_o and is deliberately
// split across two always_comb blocks and one continuous assign.
// Expected after M1:
//   * ONE worst path chaining all four adds (≈40 FO4 @ fo4-v1)
//   * the path's primary_loc is the highest-cost node on it
// Legacy (per-region paths) reports three separate paths of ≈20/10/10 and
// therefore UNDER-estimates the real cloud depth.

module dep_chain_cross_region (
    input  logic [7:0]  a_i,
    input  logic [7:0]  b_i,
    output logic [11:0] y_o
);
  logic [8:0]  t1;
  logic [9:0]  t2;
  logic [10:0] t3;

  always_comb begin : stage_a
    t1 = a_i + b_i;
    t2 = t1 + b_i;
  end

  always_comb begin : stage_b
    t3 = t2 + b_i;
  end

  assign y_o = t3 + b_i;
endmodule
