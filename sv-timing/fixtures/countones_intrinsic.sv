// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Population count uses operand geometry, including nested/parallel calls.
module countones_intrinsic (
    input logic [7:0] a,
    input logic [7:0] b,
    input logic [15:0] wide,
    input logic select_i,
    output logic [3:0] small_o,
    output logic [63:0] extended,
    output logic [4:0] larger,
    output logic one_bit,
    output logic [31:0] parallel_count,
    output logic [31:0] nested_count,
    output logic [31:0] sum_count,
    output logic [31:0] literal_count,
    output logic guard_hit
);
  assign small_o = 4'($countones(a));
  assign extended = 64'($countones(a));
  assign larger = 5'($countones(wide));
  assign one_bit = 1'($countones(a[0]));
  assign parallel_count = select_i ? $countones(a) : $countones(wide);
  assign nested_count = $countones($countones(a));
  assign sum_count = $countones(a) + $countones(wide);
  assign literal_count = $countones(16'hffff);
  always_comb begin
    guard_hit = 1'b0;
    if ($countones(a) == 32'd3) guard_hit = 1'b1;
  end
endmodule
