// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// P14 golden fixture (M1 — dataflow, not source order).
//
// Six assignments in ONE always_comb with **no data dependency between them**.
// Expected after M1 (def-use DAG + longest path):
//   * six independent sinks  ⇒ six shallow paths (one add each)
//   * worst-path total_fo4 == one add_sub (≈10 @ fo4-v1, width-normalized)
// Legacy (source-order chaining) reports ONE path of ≈60 FO4 — 6x pessimistic.

module independent_stmts (
    input  logic [7:0] a_i,
    input  logic [7:0] b_i,
    output logic [8:0] w_o,
    output logic [8:0] x_o,
    output logic [8:0] y_o,
    output logic [8:0] z_o,
    output logic [8:0] p_o,
    output logic [8:0] q_o
);
  always_comb begin : indep
    w_o = a_i + b_i;
    x_o = a_i + b_i;
    y_o = a_i + b_i;
    z_o = a_i + b_i;
    p_o = a_i + b_i;
    q_o = a_i + b_i;
  end
endmodule
