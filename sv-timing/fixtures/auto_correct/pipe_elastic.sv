// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// A149 M12 — an elastic (valid/ready) stream through a three-add cone.
// The contract names the downstream ready; a stage on the cone becomes a
// pipeline register that accepts when empty or draining, the producer's
// reads of `ready_i` move to the first stage's enable, and the consumer side
// keeps the real `ready_i`. The handshake absorbs the added cycle.
module pipe_elastic (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        flush_i,
    input  logic        valid_i,
    output logic        ready_o,
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    input  logic [31:0] c_i,
    output logic        valid_o,
    input  logic        ready_i,
    output logic [31:0] y_o
);
  // svt-pipe: protocol st valid=valid_q ready=ready_i flush=flush_i
  // svt-pipe: result st valid=valid_o y_o
  logic        valid_q;
  logic [31:0] a_q, b_q, c_q;
  // the producer: a registered input word, taken when the downstream is ready
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q <= 1'b0; a_q <= '0; b_q <= '0; c_q <= '0;
    end else if (ready_i || !valid_q) begin
      valid_q <= flush_i ? 1'b0 : valid_i;
      a_q <= a_i; b_q <= b_i; c_q <= c_i;
    end
  end
  assign ready_o = ready_i || !valid_q;
  logic [31:0] s1, s2, s3;
  // svt-pipe: cut-ok st
  assign s1 = a_q + b_q;
  // svt-pipe: cut-ok st
  assign s2 = s1 + c_q;
  // svt-pipe: cut-ok st
  assign s3 = s2 + {c_q[15:0], a_q[15:0]};
  assign y_o = s3;
  assign valid_o = valid_q;
endmodule
