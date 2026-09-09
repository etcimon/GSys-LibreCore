// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// PASS-STRATEGY P1: mixed-case module localparams (VpnLen / PtLevels) are
// elaboration-constant. Heuristic ConstSeed misses them (not SCREAMING, not
// *Cfg.*); delay-v11 seeds the lattice from the module's localparam list.

module param_lattice (
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] w_o,
    output logic [31:0] p_o
);
  localparam int VpnLen = 27;
  localparam int PtLevels = 3;

  assign w_o = (VpnLen / PtLevels) * VpnLen;
  assign p_o = a * b;
endmodule
