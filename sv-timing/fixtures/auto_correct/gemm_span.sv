// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Reduced stand-in for g6lc_ai_gemm_seq `c_span`: continuous mul/shift
// chain with launch/capture flops. Lean emit must leave the origin
// assign intact; `--real-cut-feeds` must comment it out and sink lhs
// from the pipe (PASS-STRATEGY IR/emit contract).

module gemm_span (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic [8:0]  m_i,
    input  logic [8:0]  n_i,
    output logic [31:0] y_o
);
  logic [8:0]  m_q, n_q;
  logic [31:0] prod, acc0, acc1, c_span;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      m_q <= '0;
      n_q <= '0;
    end else begin
      m_q <= m_i;
      n_q <= n_i;
    end
  end

  assign prod = 32'(m_q) * 32'(n_q);
  assign acc0 = prod + 32'(m_q);
  assign acc1 = acc0 + 32'(n_q);
  assign c_span = (acc1 + prod) << 2;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      y_o <= '0;
    end else begin
      y_o <= c_span;
    end
  end
endmodule
