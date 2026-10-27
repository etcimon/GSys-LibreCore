// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// hyp8 provenance: ai-hyp-r3 (Batch-2 lc m*n sequential multiplier)
//
// WB-cycle shift-add multiplier (right-shift b, left-shift a, one adder).
// start/done handshake; product is a function of the operands at start_i.
// ai-hyp-r4 G1 uses it for the desc_engine operand/result spans; its
// product must carry the full WA+WB width so the span functions'
// saturation arithmetic (bits above the architectural ceiling) can fire.
module g6lc_ai_mul_seq #(
  parameter int unsigned WA = 32,
  parameter int unsigned WB = 32,
  parameter int unsigned CntW = (WB > 1) ? $clog2(WB + 1) : 1
) (
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic             start_i,
  input  logic [WA-1:0]    a_i,
  input  logic [WB-1:0]    b_i,
  output logic             done_o,
  output logic [WA+WB-1:0] product_o
);
  logic [WA+WB-1:0] acc_q;
  logic [WA+WB-1:0] a_ext_q;   // shifted a kept at full product width
  logic [WB-1:0]    b_q;
  logic [CntW-1:0]  cnt_q;
  logic             busy_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      acc_q <= '0; a_ext_q <= '0; b_q <= '0; cnt_q <= '0; busy_q <= 1'b0;
      product_o <= '0; done_o <= 1'b0;
    end else begin
      done_o <= 1'b0;
      if (busy_q) begin
        if (b_q[0]) acc_q <= acc_q + a_ext_q;
        a_ext_q <= {a_ext_q[WA+WB-2:0], 1'b0};
        b_q     <= {1'b0, b_q[WB-1:1]};
        cnt_q   <= cnt_q + CntW'(1);
        if (cnt_q == CntW'(WB - 1)) begin
          busy_q    <= 1'b0;
          product_o <= acc_q + (b_q[0] ? a_ext_q : '0);
          done_o    <= 1'b1;
        end
      end else if (start_i) begin
        acc_q     <= '0;
        a_ext_q   <= (WA+WB)'(a_i);
        b_q       <= b_i;
        cnt_q     <= '0;
        busy_q    <= 1'b1;
        product_o <= '0;
        if (a_i == '0 || b_i == '0) begin
          busy_q    <= 1'b0;
          product_o <= '0;
          done_o    <= 1'b1;
        end
      end
    end
  end
endmodule
