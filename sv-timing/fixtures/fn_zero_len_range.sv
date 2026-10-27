// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// E6 model over-read fixture (hyp8 r79): a package-level
// `is_inside_*`-style region check whose rule array is entirely
// zero-length at elaboration. range_check(base=0, len=0, a) reduces
// to `a < 0` = constant false, so the consumer is a constant 0 — but
// the analyzer still builds the full compare tree per entry and
// bills the cone. Reproduces load_unit.sv's stall_ni/paddr_ni
// (NrNonIdempotentRules=2, NonIdempotentLength={0,0} in every g6lc
// profile): the billed hot node is the check on a dead predicate.
// Analyzer to-do: constant-fold range_check/is_inside_* with
// zero-length or constant rules (sv-timing/AGENTS-todo.md).
package fn_zero_len_range_pkg;
  localparam int unsigned N_RULES = 2;
  localparam logic [63:0] RULE_BASE [N_RULES] = '{64'h0, 64'h0};
  localparam logic [63:0] RULE_LEN  [N_RULES] = '{64'h0, 64'h0};

  function automatic logic range_check(
      input logic [63:0] base, input logic [63:0] len,
      input logic [63:0] address);
    return (address >= base) && (address < (base + len));
  endfunction

  function automatic logic is_inside_regions(
      input logic [63:0] address);
    logic inside;
    inside = 1'b0;
    for (int unsigned k = 0; k < N_RULES; k++)
      inside |= range_check(RULE_BASE[k], RULE_LEN[k], address);
    return inside;
  endfunction
endmodule

module fn_zero_len_range (
    input  logic        clk_i,
    input  logic [55:0] pa_i,
    input  logic        inflight_i,
    output logic        stall_o,
    output logic [7:0]  state_d_o
);
  import fn_zero_len_range_pkg::*;

  logic paddr_ni, stall_ni;
  // The over-read: the whole per-rule compare cone bills into
  // stall_ni even though every rule length is constant 0.
  assign paddr_ni = is_inside_regions({8'h0, pa_i});
  assign stall_ni = inflight_i && paddr_ni;

  always_comb begin
    state_d_o = 8'h01;
    if (stall_ni)      state_d_o = 8'h02;
    else if (pa_i[0])  state_d_o = 8'h04;
  end
endmodule
