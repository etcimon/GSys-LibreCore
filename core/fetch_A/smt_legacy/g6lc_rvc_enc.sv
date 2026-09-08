// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Soft-ladder EXTRACT E5 — RVC encodings used by SMT+SS recover.
//
// Bit-identical move of:
//   g1fr_is_jalr          RVI jalr or compressed c.jalr
//   g1ha_cjalr            16-bit exact c.jalr
//   G1ba mash             leftover {c.li_hi, BRANCH_lo} → c.li
//   G1gu mash             leftover {c.jalr_hi, BRANCH_lo} → jalr
//
// G1gt any-RVI high-half c.jalr — MINI-FAIL. Do not re-land.
// Callers still gate present with NrHarts>1. No sequential logic.

package g6lc_rvc_enc;
  import config_pkg::*;

  // Exact compressed c.jalr: [15:12]==1001, [6:2]==0, [11:7]!=0, [1:0]==10.
  function automatic logic is_cjalr16(input logic [15:0] hw);
    is_cjalr16 = (hw[15:12] == 4'b1001) && (hw[6:2] == 5'd0) &&
                 (hw[11:7] != 5'd0) && (hw[1:0] == 2'b10);
  endfunction

  // RVI jalr (imm=0 funct3) or c.jalr in a 32-bit fetch slot.
  function automatic logic is_jalr(input logic [31:0] i);
    if ((i[1:0] == 2'b11) && (i[6:0] == 7'b1100111) && (i[14:12] == 3'b000))
      return 1'b1;
    if ((i[1:0] == 2'b10) && (i[15:12] == 4'b1001) && (i[6:2] == 5'd0) &&
        (i[11:7] != 5'd0))
      return 1'b1;
    return 1'b0;
  endfunction

  function automatic logic smt_ss(input cva6_cfg_t cfg);
    smt_ss = cfg.SuperscalarEn && (cfg.NrHarts > 32'd1);
  endfunction

  // G1ba: 32-bit mash {C1-li high, BRANCH low}.
  function automatic logic mash_c1li(input cva6_cfg_t cfg, input logic [31:0] instr);
    mash_c1li = smt_ss(cfg) && (instr[6:0] == riscv::OpcodeBranch) &&
                (instr[17:16] == 2'b01) && (instr[31:29] == riscv::OpcodeC1Li);
  endfunction

  function automatic logic [31:0] expand_c1li(input logic [31:0] instr);
    expand_c1li = {{6{instr[28]}}, instr[28], instr[22:18], 5'b0, 3'b0,
                   instr[27:23], riscv::OpcodeOpImm};
  endfunction

  // G1gu: 32-bit mash {c.jalr high, BRANCH low}. Not G1gt any-RVI.
  function automatic logic mash_cjalr(input cva6_cfg_t cfg, input logic [31:0] instr);
    mash_cjalr = smt_ss(cfg) && (instr[6:0] == riscv::OpcodeBranch) &&
                 (instr[17:16] == 2'b10) && (instr[31:28] == 4'b1001) &&
                 (instr[22:18] == 5'd0) && (instr[27:23] != 5'd0);
  endfunction

  function automatic logic [31:0] expand_cjalr(input logic [31:0] instr);
    expand_cjalr = {12'b0, instr[27:23], 3'b000, 5'b00001, riscv::OpcodeJalr};
  endfunction

endpackage
