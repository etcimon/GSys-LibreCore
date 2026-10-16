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
  end else if (IMPL == 3 && W > LOW_W) begin : gen_late_carry
    // Compute each upper propagate predicate from the old pointer in parallel.
    // The late popcount carry enters only the last AND/XOR, not each prefix node.
    wire [LOW_W:0] low_sum = {1'b0, pointer[LOW_W-1:0]} + (LOW_W+1)'(step);
    assign y[LOW_W-1:0] = low_sum[LOW_W-1:0];
    for (genvar i = LOW_W; i < W; i++) begin : bit_sum
      if (i == LOW_W)
        assign y[i] = pointer[i] ^ low_sum[LOW_W];
      else
        assign y[i] = pointer[i] ^ (low_sum[LOW_W] & (&pointer[i-1:LOW_W]));
    end
  end else if (IMPL == 4) begin : gen_prefix
    // Parallel prefix carry network for the final addition. Each stage doubles
    // the covered span; carries read only the previous stage.
    localparam int unsigned LEVELS = $clog2(W);
    wire [W-1:0] p [0:LEVELS];
    wire [W-1:0] g [0:LEVELS];
    assign p[0] = pointer ^ W'(step);
    assign g[0] = pointer & W'(step);
    for (genvar level = 0; level < LEVELS; level++) begin : level_sum
      for (genvar i = 0; i < W; i++) begin : bit_sum
        if (i >= (1 << level)) begin : combine
          assign g[level+1][i] = g[level][i] | (p[level][i] & g[level][i-(1 << level)]);
          assign p[level+1][i] = p[level][i] & p[level][i-(1 << level)];
        end else begin : pass
          assign g[level+1][i] = g[level][i];
          assign p[level+1][i] = p[level][i];
        end
      end
    end
    assign y = p[0] ^ (g[LEVELS] << 1);
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

// Admission-count factoring for a power-of-two instruction FIFO bank.
// valid already incorporates the first-taken-branch mask. Compaction preserves
// its population count, and the leftover exception can accept only slot zero.
module queue_count_trial #(
    parameter int unsigned W = 16,
    parameter int unsigned N = 4,
    parameter bit IMPL = 0,
    localparam int unsigned IW = $clog2(N),
    localparam int unsigned CW = $clog2(N+1)
) (
    input logic [W-1:0] pointer,
    input logic [IW-1:0] head,
    input logic [N-1:0] valid, full,
    input logic leftover, address_overflow,
    output logic [CW-1:0] step,
    output logic [W-1:0] y
);
  logic [N-1:0] desired;
  logic [IW-1:0] rank, slot;
  always_comb begin
    desired = '0;
    rank = '0;
    slot = '0;
    for (int s = 0; s < N; s++) begin
      slot = head + rank;
      if (valid[s]) begin
        desired[slot] = 1'b1;
        rank = rank + 1'b1;
      end
    end
  end
  wire [N-1:0] slot0 = N'(valid[0]) << head;
  wire overflow = |(desired & full);
  wire partial = leftover && valid[0] && !(|(slot0 & full)) && overflow;
  wire [N-1:0] pushed = (partial ? slot0 : (desired & {N{!overflow}}))
      & {N{!address_overflow}};
  if (!IMPL) begin : gen_post_count
    always_comb begin
      step = '0;
      for (int s = 0; s < N; s++) step = step + CW'(pushed[s]);
    end
  end else begin : gen_pre_count
    logic [CW-1:0] count;
    always_comb begin
      count = '0;
      for (int s = 0; s < N; s++)
        if (valid[s]) count = count + 1'b1;
    end
    assign step = address_overflow ? '0 : partial ? CW'(1) : overflow ? '0 : count;
  end
  assign y = pointer + W'(step);
endmodule

module queue_count_miter #(
    parameter int unsigned W = 16,
    parameter int unsigned N = 4,
    localparam int unsigned IW = $clog2(N),
    localparam int unsigned CW = $clog2(N+1)
) (
    input logic [W-1:0] pointer,
    input logic [IW-1:0] head,
    input logic [N-1:0] valid, full,
    input logic leftover, address_overflow,
    output logic equal
);
  wire [W-1:0] reference_y, candidate_y;
  wire [CW-1:0] reference_step, candidate_step;
  queue_count_trial #(.W(W), .N(N), .IMPL(0)) reference_count
      (.pointer(pointer), .head(head), .valid(valid), .full(full),
       .leftover(leftover), .address_overflow(address_overflow),
       .step(reference_step), .y(reference_y));
  queue_count_trial #(.W(W), .N(N), .IMPL(1)) candidate_count
      (.pointer(pointer), .head(head), .valid(valid), .full(full),
       .leftover(leftover), .address_overflow(address_overflow),
       .step(candidate_step), .y(candidate_y));
  assign equal = (reference_step == candidate_step) && (reference_y == candidate_y);
endmodule
