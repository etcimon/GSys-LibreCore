// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Auto-correct fixture (A123): an operation in flight — valid, transaction
// id, a cancellation mask raised in later cycles, a flush — through a cone
// too deep for one 10-FO4 cycle. The `svt-pipe` pragmas declare the roles a
// register cut must carry, where a stage may be cut, and where it may not.
//
// `pipe_contract`: a straight chain. Every cut the planner takes is under a
// `cut-ok`, so each stage carries data, valid (killed at each stage), id and
// the operator together and the result side is rewired onto the last stage.
//
// `pipe_contract_side`: the same cone with a side path (the result reads an
// early intermediate directly). A carried plan would mix operations of two
// ages, so the contract must refuse it (balance registers are the next
// mechanism, not this one) and leave the module unchanged.
//
// Not equivalence-provable (latency changes); the witness is directed
// simulation (killed / flushed operations never emerge, ids stay paired).
module pipe_contract (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        flush_i,
    input  logic        valid_i,
    input  logic [3:0]  tid_i,
    input  logic [15:0] cancel_i,
    input  logic [1:0]  op_i,
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    input  logic [31:0] c_i,
    output logic        res_valid_o,
    output logic [3:0]  res_tid_o,
    output logic [31:0] res_o
);
  // svt-pipe: protocol ex valid=valid_q id=tid_q kill=cancel_i[$id] flush=flush_i
  // svt-pipe: carry ex op_q,a_q,c_q
  // svt-pipe: result ex valid=res_valid_d id=res_tid_d
  logic        valid_q;
  logic [3:0]  tid_q;
  logic [1:0]  op_q;
  logic [31:0] a_q, b_q, c_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q <= 1'b0; tid_q <= '0; op_q <= '0; a_q <= '0; b_q <= '0; c_q <= '0;
    end else begin
      valid_q <= flush_i ? 1'b0 : (valid_i & ~cancel_i[tid_i]);
      tid_q <= tid_i; op_q <= op_i; a_q <= a_i; b_q <= b_i; c_q <= c_i;
    end
  end

  // A deep arithmetic chain: three dependent 32-bit adds and a final select.
  logic [31:0] s1, s2, s3, res_d;
  logic        res_valid_d;
  logic [3:0]  res_tid_d;
  // svt-pipe: cut-ok ex
  assign s1 = a_q + b_q;
  // svt-pipe: cut-ok ex
  assign s2 = s1 + c_q;
  // svt-pipe: cut-ok ex
  assign s3 = s2 + {op_q, a_q[29:0]};
  // svt-pipe: cut-ok ex
  assign res_d = (s3[31] ^ s3[0]) ? s3 : ~s3;
  // the result side reads the operation's valid, killed again in this cycle
  assign res_valid_d = valid_q & ~cancel_i[tid_q];
  assign res_tid_d = tid_q;
  // svt-pipe: no-cut
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      res_valid_o <= 1'b0; res_tid_o <= '0; res_o <= '0;
    end else begin
      res_valid_o <= flush_i ? 1'b0 : res_valid_d;
      res_tid_o <= res_tid_d;
      res_o <= res_d;
    end
  end
endmodule

module pipe_contract_side (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        flush_i,
    input  logic        valid_i,
    input  logic [3:0]  tid_i,
    input  logic [15:0] cancel_i,
    input  logic [1:0]  op_i,
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    input  logic [31:0] c_i,
    output logic        res_valid_o,
    output logic [3:0]  res_tid_o,
    output logic [31:0] res_o
);
  // svt-pipe: protocol ex valid=valid_q id=tid_q kill=cancel_i[$id] flush=flush_i
  // svt-pipe: carry ex op_q
  // svt-pipe: result ex valid=res_valid_d id=res_tid_d
  logic        valid_q;
  logic [3:0]  tid_q;
  logic [1:0]  op_q;
  logic [31:0] a_q, b_q, c_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q <= 1'b0; tid_q <= '0; op_q <= '0; a_q <= '0; b_q <= '0; c_q <= '0;
    end else begin
      valid_q <= flush_i ? 1'b0 : (valid_i & ~cancel_i[tid_i]);
      tid_q <= tid_i; op_q <= op_i; a_q <= a_i; b_q <= b_i; c_q <= c_i;
    end
  end
  logic [31:0] s1, s2, s3, res_d;
  logic        res_valid_d;
  logic [3:0]  res_tid_d;
  // svt-pipe: cut-ok ex
  assign s1 = a_q + b_q;
  // svt-pipe: cut-ok ex
  assign s2 = s1 + c_q;
  // svt-pipe: cut-ok ex
  assign s3 = s2 + {op_q, a_q[29:0]};
  // svt-pipe: cut-ok ex
  assign res_d = (s3 > s2) ? s3 : (op_q[1] ? s1 : s2); // side path: reads s1 and s2 past their stages
  assign res_valid_d = valid_q & ~cancel_i[tid_q];
  assign res_tid_d = tid_q;
  // svt-pipe: no-cut
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      res_valid_o <= 1'b0; res_tid_o <= '0; res_o <= '0;
    end else begin
      res_valid_o <= flush_i ? 1'b0 : res_valid_d;
      res_tid_o <= res_tid_d;
      res_o <= res_d;
    end
  end
endmodule
