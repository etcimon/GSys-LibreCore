// SPDX-License-Identifier: MIT
// Procedural if and generate-if stay summed. Area tags them. Delay is unchanged.
module procedural_if (
    input  logic       clk,
    input  logic [7:0] a,
    input  logic [7:0] b,
    output logic [7:0] y
);
  parameter int EN = 1;
  always_comb begin
    if (EN) begin
      y = a + b;
    end else begin
      y = a - b;
    end
  end
endmodule

module gen_if (
    input  logic [7:0] a,
    output logic [7:0] y
);
  parameter int EN = 1;
  if (EN) begin : g_on
    assign y = a;
  end else begin : g_off
    assign y = ~a;
  end
endmodule
