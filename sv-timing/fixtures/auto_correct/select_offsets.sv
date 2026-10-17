// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Typed offset regression: signed selector patterns, widening/narrowing
// casts, mixed signedness and subtraction. Every output is compared against
// the emitted tree using matched-state equivalence.
module select_offsets (
    input logic clk_i,
    input logic [7:0] q_i,
    input logic signed [1:0] signed_step_i,
    input logic [1:0] mask_i,
    input logic [2:0] step_i,
    input logic choose_i,
    output logic signed [15:0] signed_minus,
    output logic signed [15:0] signed_plus,
    output logic [15:0] mixed_minus,
    output logic [15:0] narrowed
);
  logic signed [7:0] sq_q;
  logic [7:0] uq_q;
  logic signed [1:0] signed_step;
  logic [2:0] step;
  // A late control cone makes selection useful at the 10-FO4 budget.
  assign signed_step = choose_i ? (signed_step_i ^ mask_i) : (signed_step_i & mask_i);
  assign step = choose_i ? step_i : ~step_i;
  always_ff @(posedge clk_i) begin
    sq_q <= q_i;
    uq_q <= q_i;
  end
  assign signed_minus = sq_q - 16'(signed_step);
  assign signed_plus = sq_q + signed_step;
  assign mixed_minus = uq_q - signed_step;
  assign narrowed = uq_q - 2'(step);
endmodule
