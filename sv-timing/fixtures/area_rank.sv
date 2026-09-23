// SPDX-License-Identifier: MIT
// A wide register bank off the adder path. Area rank proof, not a timing rewrite.
module area_rank (
    input  logic       clk,
    input  logic [7:0] a,
    input  logic [7:0] b,
    output logic [7:0] y
);
  logic [31:0] bank[0:63];

  always_ff @(posedge clk) begin
    y <= a + b;
  end
endmodule
