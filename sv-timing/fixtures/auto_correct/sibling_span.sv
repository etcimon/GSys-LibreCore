// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Two generate-if span cones with *different* RHS (gemm a_span vs b_span).
// Twin emit cannot share a pipe; S4 sibling-span extra must cut both.

module sibling_span (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic [31:0] x_i,
    input  logic [31:0] y_i,
    input  logic [31:0] p_i,
    input  logic [31:0] q_i,
    input  logic [31:0] pa_i,
    input  logic [31:0] pb_i,
    output logic [31:0] ya_o,
    output logic [31:0] yb_o
);
  logic [31:0] x_q, y_q, p_q, q_q, pa_q, pb_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      x_q <= '0;
      y_q <= '0;
      p_q <= '0;
      q_q <= '0;
      pa_q <= '0;
      pb_q <= '0;
    end else begin
      x_q <= x_i;
      y_q <= y_i;
      p_q <= p_i;
      q_q <= q_i;
      pa_q <= pa_i;
      pb_q <= pb_i;
    end
  end

  localparam bit ReuseAEn = 1'b1;
  localparam bit ReuseBEn = 1'b1;
  logic [31:0] a_span, a_end, b_span, b_end;

  if (ReuseAEn) begin : gen_reuse_a
    assign a_span = x_q + y_q;
    assign a_end = pa_q + a_span;
  end
  if (ReuseBEn) begin : gen_reuse_b
    assign b_span = p_q + q_q;
    assign b_end = pb_q + b_span;
  end

  // Separate processes: one always_ff with two output NBAs (even reset
  // `'0`) is a P10 pulse+index bundle and would starve S4.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) ya_o <= '0;
    else         ya_o <= a_end;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) yb_o <= '0;
    else         yb_o <= b_end;
  end
endmodule
