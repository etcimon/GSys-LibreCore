// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// PASS-STRATEGY P2: block-comment interiors and trailing `//` must not lower
// as Mul / DivRem / LogicBit (te_priority.sv:139, cva6_shared_tlb.sv:260).

module comment_interiors (
    input  logic       tc_privchange_i,
    input  logic [7:0] a,
    input  logic [7:0] b,
    output logic       y,
    output logic [7:0] z
);
  // te_priority shape: live ident, operators only inside /* */
  assign y = tc_privchange_i /*|| (a * b) / 2 */;

  // trailing // on the same statement — slashes in the comment, not DivRem
  assign z = a + b; // c / d * e || f

  // continued statement then trailing comment
  assign z = a
    + b; // more / slashes * and ||
endmodule
