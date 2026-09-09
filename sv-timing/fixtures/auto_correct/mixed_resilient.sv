// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Mixed exclusive leftover + gemm-shaped serial mul chain. Module cleanliness
// wins seq_plus_comb / comb_exclusive (S3); the RegToReg cone is the resilient
// datapath exception that S4 may InsertReg (PASS-STRATEGY §8).

module mixed_resilient (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic [8:0]  m_i,
    input  logic [8:0]  n_i,
    input  logic [1:0]  sel_i,
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    input  logic [31:0] c_i,
    input  logic [31:0] d_i,
    output logic [31:0] y_o,
    output logic [31:0] rdata_o
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

  assign prod   = 32'(m_q) * 32'(n_q);
  assign acc0   = prod + 32'(m_q);
  assign acc1   = acc0 + 32'(n_q);
  assign c_span = (acc1 + prod) << 2;

  // Single NBA, no reset pair: a reset+data output flop is 2 pulse-like
  // NBAs and would trip P10 (handshake lock) on this cone.
  always_ff @(posedge clk_i) begin
    y_o <= c_span;
  end

  // Exclusive leftover so the module winner is not jit_datapath.
  always_comb begin
    unique case (sel_i)
      2'd0: rdata_o = a_i + b_i + c_i + d_i;
      2'd1: rdata_o = b_i + c_i + d_i + a_i;
      2'd2: rdata_o = c_i + d_i + a_i + b_i;
      default: rdata_o = d_i + a_i + b_i + c_i;
    endcase
  end
endmodule
