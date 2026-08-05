// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// P14 golden fixture (M1 — a register terminates a combinational path).
//
// `q` is written by an always_ff (NBA) and read by a later always_comb.
// Expected after M1:
//   * NO path chains through `q`: the pre-flop cone (a_i+b_i) is one path
//     ending at RegData, and the post-flop cone (q+c_i -> y_o) is a separate
//     path starting at the register
//   * path_kind must reflect that (in->reg and reg->out), never in->out
// CVA6 style per architecture/CVA6-STYLE-SV.md: async-active-low reset,
// named begin blocks.

module seq_boundary (
    input  logic       clk_i,
    input  logic       rst_ni,
    input  logic [7:0] a_i,
    input  logic [7:0] b_i,
    input  logic [7:0] c_i,
    output logic [9:0] y_o
);
  logic [8:0] d;
  logic [8:0] q;

  always_comb begin : pre_flop
    d = a_i + b_i;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : regs
    if (!rst_ni) begin
      q <= '0;
    end else begin
      q <= d;
    end
  end

  always_comb begin : post_flop
    y_o = q + c_i;
  end
endmodule
