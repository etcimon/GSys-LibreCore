// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
// r88 / delay-v49: a statement that follows a deep one in the same
// always_comb but reads nothing it wrote must not inherit its cone
// (dep-chain enumeration has no statement-order fallback). `z` in
// `stmt_order_no_chain` is independent of `y`; in
// `stmt_order_chain` it reads `y` and must still chain.
module stmt_order_no_chain (
    input  logic        clk_i,
    input  logic [31:0] a_i,
    input  logic [7:0]  b_i,
    output logic [31:0] y_o,
    output logic [7:0]  z_o
);
  logic [31:0] a_q, y_q, y_d;
  logic [7:0]  b_q, z_q, z_d;
  always_comb begin
    y_d = ((a_q * 32'h12345) + (a_q >> 3)) ^ a_q;
    z_d = b_q + 8'd1;
  end
  always_ff @(posedge clk_i) begin
    a_q <= a_i;
    b_q <= b_i;
    y_q <= y_d;
    z_q <= z_d;
  end
  assign y_o = y_q;
  assign z_o = z_q;
endmodule

module stmt_order_chain (
    input  logic        clk_i,
    input  logic [31:0] a_i,
    input  logic [7:0]  b_i,
    output logic [31:0] y_o,
    output logic [7:0]  z_o
);
  logic [31:0] a_q, y_q, y_d;
  logic [7:0]  b_q, z_q, z_d;
  always_comb begin
    y_d = ((a_q * 32'h12345) + (a_q >> 3)) ^ a_q;
    z_d = b_q + y_d[7:0];
  end
  always_ff @(posedge clk_i) begin
    a_q <= a_i;
    b_q <= b_i;
    y_q <= y_d;
    z_q <= z_d;
  end
  assign y_o = y_q;
  assign z_o = z_q;
endmodule
