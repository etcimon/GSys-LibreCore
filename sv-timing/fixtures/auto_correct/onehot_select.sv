// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// One-hot select (ALGORITHMS-EXPERTS A104): the issue queue's per-port
// select — `for e: if (grant[p][e]) begin sbe_o[p] = q[e]; slot[p] = e; end`
// — is a DEPTH-deep priority chain to synthesis, but the module asserts
// `$onehot0(grant[p])` (the age matrix makes the no-older-ready match
// unique). Under that invariant the chain is an AND-OR accumulate of
// log2(DEPTH) depth. The rewrite is exact when the assertion holds and
// every output is zero before the loop; `grant_prio` below has no assertion
// and must be left alone.
module onehot_select #(parameter int unsigned N = 16, parameter int unsigned P = 2) (
    input  logic                 clk_i, rst_ni,
    input  logic [P-1:0][N-1:0]  grant_i,
    input  logic [N-1:0]         prio_i,
    input  logic [N-1:0][31:0]   q_i,
    output logic [P-1:0][31:0]   sbe_o,
    output logic [P-1:0][$clog2(N)-1:0] slot_o,
    output logic [31:0]          prio_o
);
  logic [P-1:0][31:0]           sbe_d;
  logic [P-1:0][$clog2(N)-1:0]  slot_d;
  logic [31:0]                  prio_d;

  always_comb begin
    sbe_d  = '0;
    slot_d = '0;
    for (int unsigned p = 0; p < P; p++) begin
      for (int unsigned e = 0; e < N; e++) begin
        if (grant_i[p][e]) begin
          sbe_d[p]  = q_i[e];
          slot_d[p] = $clog2(N)'(e);
        end
      end
    end
  end

  // No one-hot fact for prio_i: a genuine priority select, untouched.
  always_comb begin
    prio_d = '0;
    for (int unsigned e = 0; e < N; e++) begin
      if (prio_i[e]) prio_d = q_i[e];
    end
  end

  for (genvar p = 0; p < P; p++) begin : gen_assert
    always_ff @(posedge clk_i) begin
      if (rst_ni) iq_grant_unique: assert ($onehot0(grant_i[p]));
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sbe_o <= '0; slot_o <= '0; prio_o <= '0;
    end else begin
      sbe_o <= sbe_d; slot_o <= slot_d; prio_o <= prio_d;
    end
  end
endmodule
