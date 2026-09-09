// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// PASS-STRATEGY P1: a genvar is elaboration-constant *inside its generate
// loop*, not module-wide (runtime `idx` must stay a multiply). Header
// `WIDTH / 2` is an LRM-constant generate condition.

module genvar_lattice (
    input  logic [31:0] a,
    input  logic [31:0] idx,
    output logic [31:0] y_o,
    output logic [31:0] p_o
);
  localparam int WIDTH = 8;
  logic [31:0] cells [0:3];

  for (genvar i = 0; i < WIDTH / 2; i++) begin : g
    assign cells[i] = WIDTH * i;
  end

  assign y_o = cells[0];
  assign p_o = a * idx;
endmodule
