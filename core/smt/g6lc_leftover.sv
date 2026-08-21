// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Soft-ladder EXTRACT leftover realign last — leftover-RVI classify
// (thin wrapper). Geometry FSM and per-hart leftover banks stay in
// instr_realign. G1as leftover-next-line-only drop — HOLD-FAIL. G1dy
// capture-outranks-kill_s2 — MINI-FAIL. Do not re-land.
//
// Timing: same [1:0]==11 / next-8B-line compares already on the
// realign cone. No sequential logic in this package.

package g6lc_leftover;
  import config_pkg::*;

  function automatic logic smt_ss(input cva6_cfg_t cfg);
    smt_ss = cfg.SuperscalarEn && (cfg.NrHarts > 1);
  endfunction

  // I4ad: leftover is completable only if it is RVI ([1:0]==11).
  function automatic logic leftover_rvi(
      input logic unaligned,
      input logic [15:0] hw
  );
    leftover_rvi = unaligned && (hw[1:0] == 2'b11);
  endfunction

  // G1av: complete only from the immediately next 8B line.
  function automatic logic on_next(
      input logic leftover_rvi,
      input logic same_next8
  );
    on_next = leftover_rvi && same_next8;
  endfunction

  // G1eg: leftover pending (not assembling this beat).
  function automatic logic pending(
      input logic leftover_rvi,
      input logic leftover_next
  );
    pending = leftover_rvi && !leftover_next;
  endfunction

  // G1aw: FETCH_WIDTH==64 advertises leftover-complete only on
  // the next-line assemble beat.
  function automatic logic serving(
      input cva6_cfg_t cfg,
      input logic leftover_next,
      input logic unaligned
  );
    serving = (cfg.FETCH_WIDTH == 64) ? leftover_next : unaligned;
  endfunction

  function automatic logic [31:0] assemble(
      input logic [15:0] lo,
      input logic [15:0] leftover
  );
    assemble = {lo, leftover};
  endfunction

  // G1cm: leftover-complete later-slot Jump is not presented.
  function automatic logic cm_arm(
      input cva6_cfg_t cfg,
      input logic leftover_next,
      input logic slot0_branch
  );
    cm_arm = smt_ss(cfg) && leftover_next && slot0_branch;
  endfunction

  function automatic logic later_jump(input logic [31:0] i);
    later_jump = (i[6:0] == riscv::OpcodeJal) ||
                 ((i[1:0] == riscv::OpcodeC1) &&
                  (i[15:13] == riscv::OpcodeC1J) &&
                  (i[31:16] == 16'b0));
  endfunction

  // Low-16 of jal x0 (rd==x0, opcode JAL) at leftover [2:1]==11.
  function automatic logic jal_x0_lo(input logic [15:0] hw);
    jal_x0_lo = (hw[1:0] == 2'b11) && (hw[6:0] == 7'b1101111) &&
                (hw[11:7] == 5'd0);
  endfunction

  // Arm skip: aligned 8B raw line has C.BEQZ/C.BNEZ at [15:0] and
  // leftover jal x0 start at [63:48]. Do not use decoded slot0 (present
  // mux can miss the I$ valid beat). c.jalr skip-arm and skip-range
  // leftover-PC replay latch — HOLD-FAIL cookie 51b1c001 mepc 3dc/6.
  // Do not re-land.
  function automatic logic skip_arm(
      input cva6_cfg_t cfg,
      input logic line_v,
      input logic vaddr00,
      input logic [15:0] hw0,
      input logic [15:0] hw11
  );
    skip_arm = smt_ss(cfg) && (cfg.FETCH_WIDTH >= 64) && line_v &&
               vaddr00 &&
               (hw0[1:0] == 2'b01) &&
               ((hw0[15:13] == 3'b110) || (hw0[15:13] == 3'b111)) &&
               jal_x0_lo(hw11);
  endfunction

  // Leftover jal x0 PC is in a taken Branch skip range.
  function automatic logic skip_range(
      input logic taken,
      input logic [63:0] br_pc,
      input logic [63:0] tgt,
      input logic [63:0] lj_pc
  );
    skip_range = taken && (lj_pc > br_pc) && (lj_pc < tgt);
  endfunction

  // Leftover-PC replay only while npc is on that leftover 8B line.
  // OpenSBI hangj 766: replay of 760-line jal x0 while npc is 7ba.
  // Skip-range latch / c.jalr skip-arm / G1gn bp_valid npc skip —
  // HOLD-FAIL. This is replay-block only (npc-select), not kill_s2.
  function automatic logic replay_off_line(
      input cva6_cfg_t cfg,
      input logic [63:0] replay,
      input logic [63:0] npc
  );
    replay_off_line = smt_ss(cfg) && (replay[2:1] == 2'b11) &&
                      (replay[63:3] != npc[63:3]);
  endfunction

endpackage

