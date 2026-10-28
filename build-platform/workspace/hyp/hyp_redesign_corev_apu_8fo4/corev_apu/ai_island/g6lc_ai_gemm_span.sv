// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Per-job residency overlap facts: parallel products, then span/end/compare
// windows. The retained valid bit belongs to the descriptor captured at start.
module g6lc_ai_gemm_span #(
  parameter int unsigned AddrWidth = 64
) (
  input logic clk_i, rst_ni, start_i,
  input logic [31:0] m_i, n_i, k_bytes_i,
  input logic [31:0] stride_a_i, stride_b_i, ldc_i,
  input logic [AddrWidth-1:0] pa_i, pb_i, pc_i,
  output logic valid_o, disjoint_a_o, disjoint_b_o
);
  typedef enum logic [2:0] {IDLE, LAUNCH, COLLECT, SPANS, ENDS, COMPARE, DONE} phase_t;
  phase_t phase_q;
  logic [31:0] rows_q [3], stride_q [3], product_q [3], span_q [3];
  logic [AddrWidth-1:0] base_q [3];
  logic [AddrWidth:0] end_q [3];
  logic [31:0] k_bytes_q, n_q;
  logic [2:0] done, seen_q;
  for (genvar g = 0; g < 3; g++) begin : gen_product
    logic [63:0] product;
    g6lc_ai_mul_seq #(.WA(32), .WB(32)) i_mul (
      .clk_i, .rst_ni, .start_i(phase_q == LAUNCH),
      .a_i(rows_q[g]), .b_i(stride_q[g]), .done_o(done[g]), .product_o(product)
    );
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) product_q[g] <= '0;
      else if (phase_q == COLLECT && done[g]) product_q[g] <= product[31:0];
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) end_q[g] <= '0;
      else if (phase_q == ENDS) end_q[g] <= {1'b0, base_q[g]} + (AddrWidth+1)'(span_q[g]);
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      phase_q <= IDLE; seen_q <= '0;
      k_bytes_q <= '0; n_q <= '0;
      for (int g = 0; g < 3; g++) begin rows_q[g] <= '0; stride_q[g] <= '0; base_q[g] <= '0; end
    end else if (start_i) begin
      rows_q[0] <= m_i - 32'd1; rows_q[1] <= n_i - 32'd1; rows_q[2] <= m_i - 32'd1;
      stride_q[0] <= stride_a_i; stride_q[1] <= stride_b_i; stride_q[2] <= ldc_i;
      base_q[0] <= pa_i; base_q[1] <= pb_i; base_q[2] <= pc_i;
      k_bytes_q <= k_bytes_i; n_q <= n_i; seen_q <= '0;
      phase_q <= LAUNCH;
    end else begin
      unique case (phase_q)
        LAUNCH: phase_q <= COLLECT;
        COLLECT: begin
          seen_q <= seen_q | done;
          if (&(seen_q | done)) phase_q <= SPANS;
        end
        SPANS: phase_q <= ENDS;
        ENDS: phase_q <= COMPARE;
        COMPARE: phase_q <= DONE;
        default: ;
      endcase
    end
  end
  // Preserve the original 32-bit span arithmetic before the widened end sum.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) for (int g = 0; g < 3; g++) span_q[g] <= '0;
    else if (phase_q == SPANS) begin
      span_q[0] <= product_q[0] + k_bytes_q;
      span_q[1] <= product_q[1] + k_bytes_q;
      span_q[2] <= (product_q[2] + n_q) << 2;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin disjoint_a_o <= 1'b0; disjoint_b_o <= 1'b0; end
    else if (phase_q == COMPARE) begin
      disjoint_a_o <= !end_q[0][AddrWidth] && !end_q[2][AddrWidth] &&
          ({1'b0, base_q[2]} >= end_q[0] || {1'b0, base_q[0]} >= end_q[2]);
      disjoint_b_o <= !end_q[1][AddrWidth] && !end_q[2][AddrWidth] &&
          ({1'b0, base_q[2]} >= end_q[1] || {1'b0, base_q[1]} >= end_q[2]);
    end
  end
  assign valid_o = phase_q == DONE;
  // pragma translate_off
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      start_i |-> phase_q inside {IDLE, DONE});
  // pragma translate_on
endmodule
