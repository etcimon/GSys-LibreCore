// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// E6-b fixture (hyp8 r82): a localparam computed from a bound
// parameter gates two arms. With Stages=1 the live arm is the
// combinational f(a) — the registered record arm is dead and must
// not bill. Reproduces r80's load_unit finding (both gated arms
// billed together, ~45 FO4 makespan).
module localparam_gate_fold #(
    parameter int unsigned Stages = 1
) (
    input  logic        clk_i,
    input  logic [31:0] a_i,
    input  logic        en_i,
    output logic [31:0] y_o,
    output logic [31:0] z_o
);
  localparam bit REC = (Stages == 2);

  logic [31:0] r_q, f_a, g_a;
  always_ff @(posedge clk_i) r_q <= f_a;

  assign f_a = a_i + 32'd1;
  // Deep cone reachable only through the dead REC arm � it must not
  // appear in any billed path under Stages=1.
  assign g_a = (a_i & 32'hff00) * 32'h12345 + (a_i >> 4) ^ a_i;

  // (i) constant-conditional select — only f(a) is live.
  assign y_o = REC ? r_q : f_a;

  // (ii) generate-if pair — only the else arm is live.
  generate
    if (REC) begin : gen_rec
      assign z_o = g_a;
    end else begin : gen_live
      assign z_o = en_i ? r_q : a_i;
    end
  endgenerate
endmodule
