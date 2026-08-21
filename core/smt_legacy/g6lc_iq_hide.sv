// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Soft-ladder EXTRACT E8 — IQ hide / slot1-keep predicates (SMT+SS).
//
// Bit-identical move of g1er/g1fs (valid[1] through branch_mask),
// g1en CSR-to-a0 detect + leftover jal x0 encoding, g1fo jalr /
// leftover jal x0 encoding. Hide loops and the valid[1] mux stay in
// instr_queue. G1fb/G1fc npc-ahead hide — MINI-FAIL. G1fk hide until
// CSR-to-a0 commit — MINI-FAIL. G1fm any-slot mid-line arm — MINI-FAIL.
// Do not re-land.
//
// Timing: same opcode / rd / pc[2:1] compares already on the IQ
// consume cone. No sequential logic in this package.

package g6lc_iq_hide;
  import config_pkg::*;

  function automatic logic smt_ss(input cva6_cfg_t cfg);
    smt_ss = cfg.SuperscalarEn && (cfg.NrHarts > 1);
  endfunction

  // G1er: aligned I|I whose slot1 is CSR (rd != x0) keeps
  // valid[1] through branch_mask.
  function automatic logic ii_csr_keep(
      input cva6_cfg_t cfg,
      input logic v0,
      input logic v1,
      input logic pc00,
      input logic [31:0] i0,
      input logic [31:0] i1
  );
    ii_csr_keep = smt_ss(cfg) && v0 && v1 && pc00 &&
                  (i0[1:0] == 2'b11) && (i1[1:0] == 2'b11) &&
                  (i1[6:0] == 7'b1110011) && (i1[11:7] != 5'd0);
  endfunction

  // G1fs: aligned compressed/RVI Branch | jalr/c.jalr keeps
  // valid[1] through branch_mask.
  function automatic logic br_jalr_keep(
      input cva6_cfg_t cfg,
      input logic v0,
      input logic v1,
      input logic pc00,
      input logic [31:0] i0,
      input logic [31:0] i1
  );
    logic br0;
    br0 = g6lc_fe_keep::is_cbranch16(i0[15:0]) ||
          ((i0[1:0] == 2'b11) && (i0[6:0] == 7'b1100011));
    br_jalr_keep = smt_ss(cfg) && v0 && v1 && pc00 && br0 &&
                   g6lc_rvc_enc::is_jalr(i1);
  endfunction

  // RVI jal x0.
  function automatic logic is_jal_x0(input logic [31:0] i);
    is_jal_x0 = (i[1:0] == 2'b11) && (i[6:0] == 7'b1101111) &&
                (i[11:7] == 5'd0);
  endfunction

  // Leftover-PC ([2:1]==11) jal x0. Bit-identical to
  // g1ef_is_lj && jal-x0 encoding (jal x0 implies RVI jal).
  function automatic logic leftover_jal_x0(
      input logic [1:0] pc21,
      input logic [31:0] i
  );
    leftover_jal_x0 = (pc21 == 2'b11) && is_jal_x0(i);
  endfunction

  // G1en: CSR that writes a0 (rd==x10). No funct3.
  function automatic logic is_csr_a0(input logic [31:0] i);
    is_csr_a0 = (i[1:0] == 2'b11) && (i[6:0] == 7'b1110011) &&
                (i[11:7] == 5'd10);
  endfunction

  // G1fo / G1fp: RVI jalr or exact c.jalr (E5 encoding).
  function automatic logic is_jalr(input logic [31:0] i);
    is_jalr = g6lc_rvc_enc::is_jalr(i);
  endfunction

endpackage
