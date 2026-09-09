// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// always_ff NBA stand-in for g6lc_ai_gemm_seq path 3131 (`dot_pending_q <= …`).
// `--real-cut-feeds` must rewrite the NBA to sample the pipe so post_analyze
// sees the InsertReg (R12d used to keep the origin and leave FO4 unchanged).

module proc_nba_span (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic [8:0]  m_i,
    input  logic [8:0]  n_i,
    output logic [31:0] y_o
);
  logic [8:0] m_q, n_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      m_q <= '0;
      n_q <= '0;
    end else begin
      m_q <= m_i;
      n_q <= n_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      y_o <= '0;
    end else begin
      y_o <= (32'(m_q) * 32'(n_q) + 32'(m_q) + 32'(n_q)) << 2;
    end
  end
endmodule
