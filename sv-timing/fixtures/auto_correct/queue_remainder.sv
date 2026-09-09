// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Sandwich remainder: cuts on `a` and `b` leave uncut `mid` whose RHS
// uses `a` and whose ident appears in `b`'s RHS (instr_queue push_instr).

module queue_remainder (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic [31:0] x_i,
    input  logic [31:0] y_i,
    input  logic [31:0] p_i,
    input  logic [31:0] q_i,
    output logic [31:0] z_o
);
  logic [31:0] x_q, y_q, p_q, q_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      x_q <= '0;
      y_q <= '0;
      p_q <= '0;
      q_q <= '0;
    end else begin
      x_q <= x_i;
      y_q <= y_i;
      p_q <= p_i;
      q_q <= q_i;
    end
  end

  logic [31:0] a, mid, b;
  assign a = x_q + y_q;
  assign mid = a + p_q;
  assign b = mid + q_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) z_o <= '0;
    else         z_o <= b;
  end
endmodule
