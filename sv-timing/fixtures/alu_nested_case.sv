// SPDX-License-Identifier: MIT
// Nested unique case (alu-like if/RVB style) for CaseItem label lower tests.
module alu_nested_case (
    input  logic [2:0]  op,
    input  logic [63:0] a,
    input  logic [63:0] b,
    output logic [63:0] result_o
);
  localparam logic [2:0] ROL = 3'd0;
  localparam logic [2:0] ROR = 3'd1;
  localparam logic [2:0] ADD = 3'd2;
  localparam logic [2:0] SUB = 3'd3;
  localparam logic [2:0] XOR = 3'd4;
  logic rvb;
  assign rvb = 1'b1;
  always_comb begin
    result_o = '0;
    if (rvb) begin
      unique case (op)
        ROL:
        result_o = (a << b[5:0]) | (a >> (64 - b[5:0]));
        ROR: result_o = (a >> b[5:0]) | (a << (64 - b[5:0]));
        ADD: result_o = a + b;
        SUB: result_o = a - b;
        XOR: result_o = a ^ b;
        default: ;
      endcase
    end
  end
endmodule
