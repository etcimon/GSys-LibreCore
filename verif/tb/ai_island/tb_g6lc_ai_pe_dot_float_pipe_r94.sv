// SPDX-License-Identifier: MIT
// Copyright 2026 Etienne Cimon
// Cycle-exact comparison with the pinned pre-r94 pipeline, including flags.
module tb_g6lc_ai_pe_dot_float_pipe_r94 #(
    parameter int unsigned Lanes = 4
) (
    input logic clk_i, rst_ni, start_i,
    input logic [31:0] a_i [Lanes], b_i [Lanes],
    input logic valid_i [Lanes],
    input logic [2:0] numfmt_i,
    output logic valid_o,
    output logic [31:0] sum_o,
    output logic [4:0] flags_o
);
  logic ref_valid;
  logic [31:0] ref_sum;
  logic [4:0] ref_flags;
  localparam int unsigned TOTAL = $clog2(Lanes < 1 ? 1 : Lanes) + 6;
  logic [TOTAL-1:0] due;
  g6lc_ai_pe_dot_float_pipe #(.Lanes(Lanes)) dut (.*);
  g6lc_ai_pe_dot_float_pipe_ref #(.Lanes(Lanes)) reference_dut (
      .clk_i, .rst_ni, .start_i, .a_i, .b_i, .valid_i, .numfmt_i,
      .valid_o(ref_valid), .sum_o(ref_sum), .flags_o(ref_flags)
  );
  always_ff @(posedge clk_i or negedge rst_ni)
    if (!rst_ni) due <= '0;
    else due <= {due[TOTAL-2:0], start_i};
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (valid_o === due[TOTAL-1]) else $fatal(1, "r94 exact float latency");
      assert (valid_o === ref_valid) else $fatal(1, "r94 float token identity");
      if (valid_o)
        assert ({flags_o, sum_o} === {ref_flags, ref_sum})
          else $fatal(1, "r94 float result/flags differ from reference");
    end
  end
endmodule
