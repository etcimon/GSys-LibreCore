// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Auto-correct fixture: enabled multiply (GateInfo enable).

module enabled_mul (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        valid_i,
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    output logic [63:0] y_o
);
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      y_o <= '0;
    end else if (valid_i) begin
      y_o <= a_i * b_i;
    end
  end
endmodule
