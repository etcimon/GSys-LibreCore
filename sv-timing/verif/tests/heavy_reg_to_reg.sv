// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Heavy reg→reg style path: always_ff with expensive datapath (startpoint CP, endpoint D).

module heavy_reg_to_reg (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        valid_i,
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    input  logic [31:0] c_i,
    output logic [63:0] y_o
);
  logic [63:0] prod, acc;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      y_o <= '0;
    end else if (valid_i) begin
      prod = a_i * b_i;
      acc  = prod + {32'b0, c_i};
      y_o  <= acc * {32'b0, b_i} + prod;
    end
  end
endmodule
