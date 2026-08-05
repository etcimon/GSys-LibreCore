// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U4 slice steer — decode/dispatch-time classification.
// Slice (A-queue): address-generating ops + loads (IST hit or static LOAD).
// Everything else → B-queue. Pure combinational demux, no state.

module g6lc_slice_steer
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type scoreboard_entry_t = logic
) (
    input  scoreboard_entry_t instr_i,
    input  logic              ist_is_slice_i,
    output logic              to_a_o,   // 1 → A-IQ, 0 → B-IQ
    output logic              is_load_o
);

  // Static seed: all LOADs are A-class (they *are* the slice tail).
  // ALU/other join A when the IST has learned they feed a load address.
  // CTRL_FLOW / CSR / STORE always stay on B (precise side effects).
  logic static_a;
  assign is_load_o = (instr_i.fu == LOAD);
  assign static_a  = (instr_i.fu == LOAD) ||
                     ((instr_i.fu == ALU) && ist_is_slice_i);

  // Never put side-effecting or control ops on A
  logic force_b;
  assign force_b = (instr_i.fu inside {STORE, CTRL_FLOW, CSR, CVXIF, ACCEL}) ||
                   instr_i.ex.valid;

  assign to_a_o = static_a && !force_b;

endmodule
