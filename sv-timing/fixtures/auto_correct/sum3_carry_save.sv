// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Latency-neutral three-operand modular addition experiment.
// IMPL=0: two carry-propagate additions; IMPL=1: 3:2 compressor + one addition.
// W is the assignment context width. No intermediate narrows below W.
// This fixture proves binary-input arithmetic, not four-state X equivalence.
module sum3_carry_save #(
    parameter int unsigned W = 5,
    parameter bit IMPL = 1'b0
) (
    input  logic [W-1:0] a, b, c,
    input  logic flush,
    output logic [W-1:0] y
);
  if (IMPL) begin : gen_compressor
    assign y = flush ? '0 :
        ((a ^ b) ^ c) + (((a & b) | ((a & c) | (b & c))) << 1);
  end else begin : gen_serial
    assign y = flush ? '0 : (a + b) + c;
  end
endmodule

// Commit-count specialization of the same arithmetic. Offset is elaboration
// constant; count is bounded by PORTS, not an arbitrary W-bit operand.
module commit_pointer_trial #(
    parameter int unsigned W = 5,
    parameter int unsigned PORTS = 2,
    parameter int unsigned OFFSET = 1,
    parameter int unsigned IMPL = 0
) (
    input logic [W-1:0] pointer,
    input logic [PORTS-1:0] ack,
    input logic flush,
    output logic [W-1:0] y
);
  logic [$clog2(PORTS):0] count;
  always_comb begin
    count = '0;
    for (int i = 0; i < PORTS; i++) begin
      if (ack[i]) count = count + 1'b1;
    end
  end
  if (IMPL == 0) begin : gen_serial
    assign y = flush ? '0 : pointer + W'(count) + W'(OFFSET);
  end else if (IMPL == 1) begin : gen_compressor
    assign y = flush ? '0 :
        ((pointer ^ W'(count)) ^ W'(OFFSET)) +
        (((pointer & W'(count)) |
          ((pointer & W'(OFFSET)) | (W'(count) & W'(OFFSET)))) << 1);
  end else begin : gen_select
    // Precompute each constant increment in parallel; select by the count.
    // The default preserves an unknown count as X for simulation.
    always_comb begin
      y = 'x;
      for (int i = 0; i <= PORTS; i++) begin
        if (count == ($clog2(PORTS)+1)'(i))
          y = pointer + W'(i + OFFSET);
      end
      if (flush) y = '0;
    end
  end
endmodule

module commit_pointer_miter #(
    parameter int unsigned W = 5,
    parameter int unsigned PORTS = 2,
    parameter int unsigned IMPL = 1
) (
    input logic [W-1:0] pointer,
    input logic [PORTS-1:0] ack,
    input logic flush,
    output logic equal
);
  wire [W-1:0] serial, candidate;
  commit_pointer_trial #(.W(W), .PORTS(PORTS), .IMPL(0)) reference_sum
      (.pointer(pointer), .ack(ack), .flush(flush), .y(serial));
  commit_pointer_trial #(.W(W), .PORTS(PORTS), .IMPL(IMPL)) candidate_sum
      (.pointer(pointer), .ack(ack), .flush(flush), .y(candidate));
  assign equal = serial == candidate;
endmodule

// FIFO occupancy update: simultaneous push/pop must cancel in the same cycle.
module count_delta_trial #(
    parameter int unsigned W = 3,
    parameter bit IMPL = 0
) (
    input logic [W-1:0] count,
    input logic push, pop,
    output logic [W-1:0] y
);
  if (IMPL) begin : gen_delta
    always_comb begin
      case ({push, pop})
        2'b00, 2'b11: y = count;
        2'b10: y = count + 1'b1;
        2'b01: y = count - 1'b1;
        default: y = 'x;
      endcase
    end
  end else begin : gen_serial
    assign y = count + W'(push) - W'(pop);
  end
endmodule

module count_delta_miter #(
    parameter int unsigned W = 3
) (
    input logic [W-1:0] count,
    input logic push, pop,
    output logic equal
);
  wire [W-1:0] serial, candidate;
  count_delta_trial #(.W(W), .IMPL(0)) reference_delta
      (.count(count), .push(push), .pop(pop), .y(serial));
  count_delta_trial #(.W(W), .IMPL(1)) candidate_delta
      (.count(count), .push(push), .pop(pop), .y(candidate));
  assign equal = serial == candidate;
endmodule

// Fetch-pointer update: compare a serial accumulator with a balanced popcount.
// All sums have COUNT_W bits; padding unused leaves with zero handles nonpowers.
module popcount_step_trial #(
    parameter int unsigned W = 16,
    parameter int unsigned N = 4,
    parameter int unsigned IMPL = 0,
    localparam int unsigned COUNT_W = $clog2(N+1),
    localparam int unsigned LEAVES = 1 << $clog2(N),
    localparam int unsigned LOW_W = N > 1 ? $clog2(N) : 1
) (
    input logic [W-1:0] pointer,
    input logic [N-1:0] push,
    output logic [W-1:0] y
);
  logic [COUNT_W-1:0] step;
  if (IMPL == 1) begin : gen_tree
    wire [COUNT_W-1:0] sums [1:2*LEAVES-1];
    for (genvar i = 0; i < LEAVES; i++) begin : leaf
      if (i < N) assign sums[LEAVES+i] = COUNT_W'(push[i]);
      else assign sums[LEAVES+i] = '0;
    end
    for (genvar i = 1; i < LEAVES; i++) begin : branch
      assign sums[i] = sums[2*i] + sums[2*i+1];
    end
    assign step = sums[1];
  end else begin : gen_serial
    always_comb begin
      step = '0;
      for (int i = 0; i < N; i++) step = step + COUNT_W'(push[i]);
    end
  end
  if (IMPL == 2 && W > LOW_W) begin : gen_carry_select
    // step <= N <= 2**LOW_W, so only one carry enters the upper field.
    // Prepare both upper results before the late popcount carry arrives.
    wire [LOW_W:0] low_sum = {1'b0, pointer[LOW_W-1:0]} + (LOW_W+1)'(step);
    wire [W-LOW_W-1:0] upper_inc = pointer[W-1:LOW_W] + 1'b1;
    assign y = low_sum[LOW_W]
        ? {upper_inc, low_sum[LOW_W-1:0]}
        : {pointer[W-1:LOW_W], low_sum[LOW_W-1:0]};
  end else begin : gen_final_add
    assign y = pointer + W'(step);
  end
endmodule

module popcount_step_miter #(
    parameter int unsigned W = 16,
    parameter int unsigned N = 4,
    parameter int unsigned IMPL = 1
) (
    input logic [W-1:0] pointer,
    input logic [N-1:0] push,
    output logic equal
);
  wire [W-1:0] serial, candidate;
  popcount_step_trial #(.W(W), .N(N), .IMPL(0)) reference_count
      (.pointer(pointer), .push(push), .y(serial));
  popcount_step_trial #(.W(W), .N(N), .IMPL(IMPL)) candidate_count
      (.pointer(pointer), .push(push), .y(candidate));
  assign equal = serial == candidate;
endmodule

module sum3_miter #(
    parameter int unsigned W = 5
) (
    input logic [W-1:0] a, b, c,
    input logic flush,
    output logic equal
);
  wire [W-1:0] serial, compressed;
  sum3_carry_save #(.W(W), .IMPL(0)) reference_sum
      (.a(a), .b(b), .c(c), .flush(flush), .y(serial));
  sum3_carry_save #(.W(W), .IMPL(1)) candidate_sum
      (.a(a), .b(b), .c(c), .flush(flush), .y(compressed));
  assign equal = serial == compressed;
endmodule
