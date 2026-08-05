// SPDX-License-Identifier: MIT
// Minimal exclusive unique-case result mux for lower CaseItem label tests.
module exclusive_case_mux (
    input  logic [2:0] op_i,
    input  logic [63:0] a_i,
    input  logic [63:0] b_i,
    output logic [63:0] result_o
);
  localparam logic [2:0] ADD = 3'd0;
  localparam logic [2:0] SUB = 3'd1;
  localparam logic [2:0] AND = 3'd2;
  localparam logic [2:0] OR  = 3'd3;
  localparam logic [2:0] XOR = 3'd4;

  always_comb begin
    result_o = '0;
    unique case (op_i)
      ADD: result_o = a_i + b_i;
      SUB: result_o = a_i - b_i;
      AND: result_o = a_i & b_i;
      OR:  result_o = a_i | b_i;
      XOR: result_o = a_i ^ b_i;
      default: result_o = '0;
    endcase
  end
endmodule
