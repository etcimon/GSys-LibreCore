// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// CPU51 negative-oracle canary: a deliberately looped combinational cone plus a
// testbench top that instantiates the real core (via g6lc_core_scc_top) and the
// loop together. Injected only into the cpu-strict-pins oracle diagnostic; the
// strict flow must report an UNOPTFLAT identity naming the looped signal
// g6lc_strict_pins_canary_comb (a name no cpu-core identity can contain).
`include "axi/typedef.svh"
module g6lc_strict_pins_canary(input logic gate_i, output logic result_o);
  logic g6lc_strict_pins_canary_comb;
  always_comb g6lc_strict_pins_canary_comb =
      gate_i ? ~g6lc_strict_pins_canary_comb : 1'b0;
  assign result_o = g6lc_strict_pins_canary_comb;
endmodule

module g6lc_strict_pins_canary_top(input logic clk_i, input logic rst_ni,
    input logic gate_i, output logic result_o);
  g6lc_core_scc_top #(.OriginEnabled(1)) u_cpu(.clk_i(clk_i), .rst_ni(rst_ni));
  g6lc_strict_pins_canary canary(.gate_i(gate_i), .result_o(result_o));
endmodule
