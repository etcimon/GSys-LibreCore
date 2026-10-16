// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Transition relation for a counter incremented by popcount(push).
// Cached predicates record whether the current low bits would carry for each
// possible nonzero step. This is redundant state, not an extra cycle of latency.
// Parameters: W >= 1, BLOCK >= 1, 1 <= N < 2**BLOCK.
// A real counter registers y and next_cache together, resetting both to zero.
module bounded_step_counter_trial #(
    parameter int unsigned W = 16,
    parameter int unsigned N = 4,
    parameter int unsigned BLOCK = 4,
    parameter int unsigned IMPL = 0,
    localparam int unsigned GROUPS = (W + BLOCK - 1) / BLOCK,
    localparam int unsigned CW = GROUPS > 1 ? (GROUPS-1)*N : 1
) (
    input logic [W-1:0] pointer,
    input logic [N-1:0] push,
    input logic flush,
    input logic [CW-1:0] cache,
    output logic [W-1:0] y,
    output logic [CW-1:0] next_cache
);
  logic [$clog2(N+1)-1:0] step;
  always_comb begin
    step = '0;
    for (int i = 0; i < N; i++) step = step + ($clog2(N+1))'(push[i]);
  end
  wire [N:0] at_least, exactly;
  assign at_least[0] = 1'b1;
  if (N == 4 && IMPL == 2) begin : gen_thermometer4
    wire left_one = push[0] | push[1];
    wire right_one = push[2] | push[3];
    wire left_two = push[0] & push[1];
    wire right_two = push[2] & push[3];
    assign at_least[1] = left_one | right_one;
    assign at_least[2] = left_two | right_two | (left_one & right_one);
    assign at_least[3] = (left_two & right_one) | (right_two & left_one);
    assign at_least[4] = left_two & right_two;
  end else begin : gen_thermometer
    for (genvar d = 1; d <= N; d++)
      assign at_least[d] = step >= d;
  end
  for (genvar d = 0; d < N; d++)
    assign exactly[d] = at_least[d] & !at_least[d+1];
  assign exactly[N] = at_least[N];
  if (!IMPL) begin : gen_reference
    assign y = flush ? '0 : pointer + W'(step);
    assign next_cache = '0;
  end else begin : gen_cached
    for (genvar group = 0; group < GROUPS; group++) begin : segment
      localparam int unsigned LO = group * BLOCK;
      localparam int unsigned BITS = W - LO < BLOCK ? W - LO : BLOCK;
      if (group == 0) begin : low
        assign y[LO +: BITS] = flush ? '0 : pointer[LO +: BITS] + BITS'(step);
      end else begin : high
        wire [N-1:0] carry_terms;
        for (genvar d = 1; d <= N; d++) begin : select_step
          if (IMPL == 2)
            assign carry_terms[d-1] = at_least[d] & cache[(group-1)*N+d-1];
          else
            assign carry_terms[d-1] = (step == d) & cache[(group-1)*N+d-1];
        end
        assign y[LO +: BITS] = flush ? '0 :
            pointer[LO +: BITS] + BITS'(|carry_terms);
      end
    end
    for (genvar group = 1; group < GROUPS; group++) begin : predicate
      localparam int unsigned B = group * BLOCK;
      for (genvar d = 1; d <= N; d++) begin : threshold
        wire [N:0] selected;
        for (genvar e = 0; e <= N; e++) begin : advance
          // (old_low + e) mod 2**B >= 2**B-d iff old_low lies in
          // [(-d-e) mod 2**B, (-1-e) mod 2**B], a possibly wrapping interval.
          localparam logic [B-1:0] FIRST = B'(-d-e);
          localparam logic [B-1:0] LAST = B'(-1-e);
          wire member;
          if (FIRST <= LAST) begin : normal
            assign member = pointer[B-1:0] >= FIRST && pointer[B-1:0] <= LAST;
          end else begin : wrapping
            assign member = pointer[B-1:0] >= FIRST || pointer[B-1:0] <= LAST;
          end
          if (IMPL == 2) assign selected[e] = exactly[e] & member;
          else assign selected[e] = (step == e) & member;
        end
        assign next_cache[(group-1)*N+d-1] = !flush & (|selected);
      end
    end
    if (GROUPS == 1) assign next_cache = '0;
  end
endmodule

// Registered implementation of the transition relation used for physical
// timing/area checks. Both pointer and predicates update on the same edge.
// No extra visible latency; no additional clock or reset domain.
module bounded_counter_registered #(
    parameter int unsigned W = 16,
    parameter int unsigned N = 4,
    parameter int unsigned BLOCK = 4,
    parameter int unsigned IMPL = 0,
    localparam int unsigned GROUPS = (W + BLOCK - 1) / BLOCK,
    localparam int unsigned CW = GROUPS > 1 ? (GROUPS-1)*N : 1
) (
    input logic clk_i, rst_ni,
    input logic [N-1:0] push,
    input logic flush,
    output logic [W-1:0] y
);
  logic [W-1:0] pointer_q;
  logic [CW-1:0] cache_q;
  wire [W-1:0] pointer_d;
  wire [CW-1:0] cache_d;
  bounded_step_counter_trial #(.W(W), .N(N), .BLOCK(BLOCK), .IMPL(IMPL)) transition
      (.pointer(pointer_q), .push(push), .flush(flush), .cache(cache_q),
       .y(pointer_d), .next_cache(cache_d));
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pointer_q <= '0;
      cache_q <= '0;
    end else begin
      pointer_q <= pointer_d;
      cache_q <= cache_d;
    end
  end
  assign y = pointer_q;
endmodule

// One-step inductive witness: assume cache encodes the current pointer; prove
// both the visible next pointer and the cache invariant for the next cycle.
// flush proves the zero-reset base as well. All pointer states are symbolic,
// including near-wrap values; this is not a short simulation from zero.
module bounded_step_counter_miter #(
    parameter int unsigned W = 16,
    parameter int unsigned N = 4,
    parameter int unsigned BLOCK = 4,
    parameter int unsigned IMPL = 1,
    localparam int unsigned GROUPS = (W + BLOCK - 1) / BLOCK,
    localparam int unsigned CW = GROUPS > 1 ? (GROUPS-1)*N : 1
) (
    input logic [W-1:0] pointer,
    input logic [N-1:0] push,
    input logic flush,
    output logic equal
);
  wire [CW-1:0] current_cache, next_cache, expected_cache;
  wire [W-1:0] candidate;
  logic [$clog2(N+1)-1:0] count;
  always_comb begin
    count = '0;
    for (int i = 0; i < N; i++) count = count + ($clog2(N+1))'(push[i]);
  end
  wire [W-1:0] expected = flush ? '0 : pointer + W'(count);
  for (genvar group = 1; group < GROUPS; group++) begin : invariant
    localparam int unsigned B = group * BLOCK;
    for (genvar d = 1; d <= N; d++) begin : threshold
      localparam logic [B-1:0] LIMIT = B'(-d);
      assign current_cache[(group-1)*N+d-1] = pointer[B-1:0] >= LIMIT;
      assign expected_cache[(group-1)*N+d-1] = expected[B-1:0] >= LIMIT;
    end
  end
  if (GROUPS == 1) begin : no_cache
    assign current_cache = '0;
    assign expected_cache = '0;
  end
  bounded_step_counter_trial #(.W(W), .N(N), .BLOCK(BLOCK), .IMPL(IMPL)) candidate_counter
      (.pointer(pointer), .push(push), .flush(flush), .cache(current_cache),
       .y(candidate), .next_cache(next_cache));
  assign equal = (candidate == expected) && (next_cache == expected_cache);
endmodule
