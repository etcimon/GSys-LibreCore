// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Multi-file fixture: include + ops for location goldens.

`include "include_pkg.svh"

module top_with_include (
    input  logic [7:0] a_i,
    input  logic [7:0] b_i,
    output logic [8:0] y_o
);
  always_comb begin
    y_o = a_i + b_i;
  end
endmodule
