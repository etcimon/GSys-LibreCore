// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Sibling always_ff NBAs (some reading Q) must not serial-sum as one Plain
// cone. delay-v17: NBA write→later-read is Q, IndependentLhsBundle deflates.

module always_ff_nba_bundle (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic [7:0]  a_i,
    input  logic [7:0]  b_i,
    input  logic [7:0]  c_i,
    input  logic [7:0]  d_i,
    output logic [7:0]  q0_o,
    output logic [7:0]  q1_o,
    output logic [7:0]  q2_o,
    output logic [7:0]  q3_o,
    output logic [7:0]  q4_o,
    output logic [7:0]  q5_o,
    output logic [7:0]  q6_o,
    output logic [7:0]  q7_o
);
  logic [7:0] q0, q1, q2, q3, q4, q5, q6, q7;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      q0 <= '0;
      q1 <= '0;
      q2 <= '0;
      q3 <= '0;
      q4 <= '0;
      q5 <= '0;
      q6 <= '0;
      q7 <= '0;
    end else begin
      q0 <= a_i + b_i;
      q1 <= q0 + 8'd1;
      q2 <= c_i + d_i;
      q3 <= q2 + 8'd1;
      q4 <= a_i + c_i;
      q5 <= b_i + d_i;
      q6 <= a_i + d_i;
      q7 <= b_i + c_i;
    end
  end

  assign q0_o = q0;
  assign q1_o = q1;
  assign q2_o = q2;
  assign q3_o = q3;
  assign q4_o = q4;
  assign q5_o = q5;
  assign q6_o = q6;
  assign q7_o = q7;
endmodule
