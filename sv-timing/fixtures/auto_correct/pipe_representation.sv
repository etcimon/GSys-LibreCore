// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Two rows represent one modular sum. The preprocessor, not a handwritten
// `carry` directive, makes the companion row travel through an authorized cut.
module pipe_representation (
    input logic clk_i, rst_ni, flush_i, valid_i,
    input logic [3:0] tid_i,
    input logic [15:0] cancel_i,
    input logic [1:0] op_i,
    input logic [31:0] a_i, b_i, c_i,
    output logic res_valid_o,
    output logic [3:0] res_tid_o,
    output logic [31:0] res_o
);
  logic valid_q, res_valid_d;
  logic [3:0] tid_q, res_tid_d;
  logic [31:0] a_q, b_q, c_q, sum_row, carry_row, res_d;
  // svt-pipe: protocol ex valid=valid_q id=tid_q kill=cancel_i[$id] flush=flush_i
  // svt-pipe: result ex valid=res_valid_d id=res_tid_d
  // svt-pipe: representation ex carry-save sum=sum_row carry=carry_row result=res_d
  // svt-pipe: cut-ok ex on=sum_row
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q <= 1'b0;
      tid_q <= '0;
      a_q <= '0;
      b_q <= '0;
      c_q <= '0;
    end else begin
      valid_q <= flush_i ? 1'b0 : (valid_i & ~cancel_i[tid_i]);
      tid_q <= tid_i;
      a_q <= a_i;
      b_q <= b_i;
      c_q <= c_i;
    end
  end
  assign sum_row = (a_q ^ b_q) ^ c_q;
  assign carry_row = ((a_q & b_q) | (a_q & c_q) | (b_q & c_q)) << 1;
  assign res_d = sum_row + carry_row;
  assign res_valid_d = valid_q & ~cancel_i[tid_q];
  assign res_tid_d = tid_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      res_valid_o <= 1'b0;
      res_tid_o <= '0;
      res_o <= '0;
    end else begin
      res_valid_o <= flush_i ? 1'b0 : res_valid_d;
      res_tid_o <= res_tid_d;
      res_o <= res_d;
    end
  end
endmodule
