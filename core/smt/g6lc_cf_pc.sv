// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Soft-ladder G1r — control-flow PC is the issuing instruction's PC.
//
// branch_unit next_pc / non-JALR jump_base used the shared EX pc_i flop
// (G1p holds the last acked CF). A later jal can retire the previous
// call's next_pc (mini P6 0x65: RF ra stayed P5 0x8000014c). SMT+SS
// carries the instr PC in fu_data.operand_c (IRO) and this function
// selects it. SI / no-carry: shared pc_i (identity).
//
// Timing: one VLEN mux on the existing resolve cone. No sequential logic.

package g6lc_cf_pc;
  import config_pkg::*;

  function automatic logic [63:0] pc(
      input cva6_cfg_t   cfg,
      input logic        use_carried,
      input logic [63:0] shared_pc,
      input logic [63:0] carried_pc
  );
    if (cfg.SuperscalarEn && cfg.NrHarts > 1 && use_carried) pc = carried_pc;
    else pc = shared_pc;
  endfunction

endpackage
