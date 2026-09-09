// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// PASS-STRATEGY P1: arithmetic inside [msb:lsb] / replication counts is
// elaboration-constant. Residual MMU atomics (`cva6_shared_tlb.sv:219`
// `HYP_EXT*2`, `:260` `VpnLen%PtLevels`) were billed as Mul/DivRem because a
// 0-FO4 Expr tree fell back to a string-heuristic op_class.

module part_select_const_arith (
    input  logic [31:0] v,
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [4:0]  slice_o,
    output logic [11:0] repl_o,
    output logic [31:0] prod_o,
    output logic [31:0] idx_o
);
  localparam int WIDTH = 16;
  localparam int HYP_EXT = 2;

  // Pure slice: `*` only in a fixed part-select. Must not be Mul.
  assign slice_o = v[HYP_EXT*2:0];

  // Replication count with `/` and `%` of localparams (shared-TLB VPN pad).
  assign repl_o = {{(((WIDTH / 8) - (WIDTH % 8))) {1'b0}}, v[3:0]};

  // Real datapath multiply — still charged.
  assign prod_o = a * b;

  // Runtime bit-select index — still charged.
  assign idx_o = v[a * b];
endmodule
