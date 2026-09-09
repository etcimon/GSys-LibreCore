// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Twin generate-if locals with the same `c_span` name (g6lc_ai_gemm_seq
// `gen_reuse_a` / `gen_reuse_b`). One InsertReg origin must rewrite both.

module twin_generate_span (
    input  logic [8:0]  m_q,
    input  logic [8:0]  n_q,
    output logic [31:0] y0,
    output logic [31:0] y1
);
  localparam bit En0 = 1'b1;
  localparam bit En1 = 1'b1;
  if (En0) begin : g0
    logic [31:0] c_span;
    assign c_span = (32'(m_q) * 32'(n_q)) << 2;
    assign y0 = c_span;
  end
  if (En1) begin : g1
    logic [31:0] c_span;
    assign c_span = (32'(m_q) * 32'(n_q)) << 2;
    assign y1 = c_span;
  end
endmodule
