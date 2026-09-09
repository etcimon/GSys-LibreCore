// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// PASS-STRATEGY P1: packed-dimension and case-item-label arithmetic is
// elaboration-constant (IEEE 1800). Must not lower as DivRem/Mul.

module packed_dim_lrm (
    input  logic [7:0] sel,
    output logic       y
);
  localparam int WIDTH = 16;

  // Assign-less region: only a packed local. WIDTH/2-1 must not be DivRem.
  always_comb begin : dims_only
    logic [WIDTH / 2 - 1:0] t;
  end

  // Case label WIDTH/8 is a constant item expression, not a datapath divide.
  always_comb begin : labels
    unique case (sel)
      WIDTH / 8: y = 1'b1;
      default: y = 1'b0;
    endcase
  end
endmodule
