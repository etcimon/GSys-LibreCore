// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Soft-ladder EXTRACT E7 — I$ kill_s1/s2 spare predicates (SMT+SS).
//
// Bit-identical move of g1hv/g1jq/g1jt/g1jn/g1ix/g1jo (and leftover
// replay NoCF/Jump g1cq/g1hs). Mux that applies kill_s1/s2 stays in
// frontend. G1jp all-npc-00 kill_s2 — MINI-FAIL. G1jr/G1js flush_i at
// npc 00 — HOLD-FAIL. G1hu leftover Jump kill_s2 — MINI-FAIL. G1iy
// flush/mispredict at npc 01 — MINI-FAIL. sib_lo_s2 npc 00 of
// 16B-line second 8B vs first-8B in-flight — MINI-FAIL lottery
// 2 @420 / FDT 50 @545 (G1jp class). leftover_hi8_s2 MINI-FAIL
// FDT 24 @201516 (G1hu). leftover_lo8_s2 leftover occupying
// off-line vs same-8B in-flight at npc first 8B (hygiene:
// leftover_slot0 false at n7b0). load00_lo8_s2: same-8B
// in-flight is 00 first-8B RVI LOAD rd!=0 — no leftover
// occupying. Do not re-land sib_lo_s2 / leftover_hi8_s2 /
// G1jp / G1hu.
//
// Timing: same npc[2:1] / leftover-Jump / c.beqz compares already on
// the I$ kill cone. No sequential logic in this package.

package g6lc_fe_kill;
  import config_pkg::*;

  function automatic logic smt_ss(input cva6_cfg_t cfg);
    smt_ss = cfg.SuperscalarEn && (cfg.NrHarts > 1);
  endfunction

  // G1hv (npc 01) / G1jq (npc 00): leftover-complete Jump must not
  // flush_i- or is_mispredict-kill s1. G1hw is the mispredict half of
  // the same leftover-Jump spare (OR'd in the frontend mux).
  function automatic logic leftover_jump_s1(
      input cva6_cfg_t cfg,
      input logic serving_unaligned,
      input logic v0,
      input logic is_jump,
      input logic npc_sel,
      input logic ex_valid
  );
    leftover_jump_s1 = smt_ss(cfg) && serving_unaligned && v0 &&
                       is_jump && npc_sel && !ex_valid;
  endfunction

  // G1jt: is_mispredict must not kill_s1 while npc is aligned 00.
  // Flush_i at 00 stays (G1jr/G1js HOLD-FAIL).
  function automatic logic aligned_misp_s1(
      input cva6_cfg_t cfg,
      input logic npc00
  );
    aligned_misp_s1 = smt_ss(cfg) && npc00;
  endfunction

  // Replay must not kill_s1 when leftover-complete NoCF/Jump is
  // serving (G1cq/G1hs) or npc is mid-line 01 (G1ht) or aligned 00
  // (G1jo).
  function automatic logic replay_spare(
      input cva6_cfg_t cfg,
      input logic serving_unaligned,
      input logic v0,
      input logic is_nocf,
      input logic is_jump,
      input logic npc01,
      input logic npc00
  );
    replay_spare = smt_ss(cfg) &&
                   ((serving_unaligned && v0 && (is_nocf || is_jump)) ||
                    npc01 || npc00);
  endfunction

  // G1jn: spare kill_s2 when the returning I$ is the npc-00 aligned
  // compressed Branch (c.beqz / c.bnez) on the same 8B line.
  function automatic logic cbranch_s2(
      input cva6_cfg_t cfg,
      input logic npc00,
      input logic vaddr00,
      input logic same8,
      input logic [15:0] hw
  );
    cbranch_s2 = smt_ss(cfg) && npc00 && vaddr00 && same8 &&
                 g6lc_fe_keep::is_cbranch16(hw);
  endfunction

  // G1ix (npc 01) or G1jn: bp_valid must not kill_s2. G1jp all-00
  // without returning-data — MINI-FAIL. Do not re-land.
  function automatic logic bp_s2_spare(
      input cva6_cfg_t cfg,
      input logic npc01,
      input logic jn
  );
    bp_s2_spare = smt_ss(cfg) && (npc01 || jn);
  endfunction

  // sib_lo_s2 npc 00 of 16B-line second
  // 8B vs first-8B in-flight — MINI-FAIL
  // lottery tohost 2 @420, FDT 50 @545
  // (G1jp class). Do not re-land (7b8
  // C-Branch bp_valid kill of previous
  // 8B is load-bearing).
  // leftover_hi8_s2 leftover occupying
  // off-line vs first-8B in-flight at
  // npc high half — MINI-FAIL FDT
  // printed 24 @201516 (G1hu leftover
  // Jump kill_s2 class). lottery PASS
  // @558. sib @595. Do not re-land.
  // leftover_lo8_s2: leftover occupying
  // slot0 off the npc 16B line, npc 00
  // first 8B, in-flight I$ is that same
  // 8B (7b0 fill while npc 7b0). Spare
  // leftover jal bp_valid kill of the
  // line we're on. Hygiene: leftover
  // occupying + same-8B in-flight is
  // not true at n7b0. Not leftover_hi8_s2
  // high half. Not sib_lo_s2. Not G1jp
  // all-00. Not G1jn C-Branch. Not
  // G1hu different-line. SMT+SS.
  function automatic logic leftover_lo8_s2(
      input cva6_cfg_t cfg,
      input logic leftover_slot0,
      input logic npc00,
      input logic npc_lo,
      input logic off16,
      input logic dreq00,
      input logic same8
  );
    leftover_lo8_s2 = smt_ss(cfg) && (cfg.FETCH_WIDTH >= 64) &&
                      (cfg.ICACHE_LINE_WIDTH >= 128) &&
                      leftover_slot0 && npc00 && npc_lo &&
                      off16 && dreq00 && same8;
  endfunction

  // load00_lo8_s2: npc 00 first 8B of a 16B
  // I$ line, in-flight I$ is that same 8B
  // and the beat is RVI LOAD rd!=0. Spare
  // bp_valid kill_s2 of the line we are
  // on (7b0 fill). leftover_lo8_s2 needed
  // leftover occupying — false at n7b0.
  // Not leftover_hi8_s2 high half. Not
  // sib_lo_s2. Not G1jp all-00. Not G1jn
  // C-Branch. Not G1hu leftover Jump.
  // Not ld_until_01 registered keep.
  // Gate stays smt_ss (Phase 4b layer 1
  // is SS&&RVC&&FW64; this kill spare
  // must not arm stream I=2 / server
  // T=1). Geometry via CVA6Cfg (pc[2:1],
  // addr[3], VLEN 8B, FETCH_WIDTH,
  // ICACHE_LINE_WIDTH) — not OpenSBI
  // PCs. No recover ports (OoO / RVV /
  // RVH / NrCores / NrIssuePorts). Spare
  // is not inject (H-safe). SMT+SS.
  function automatic logic load00_lo8_s2(
      input cva6_cfg_t cfg,
      input logic icache_valid,
      input logic npc00,
      input logic npc_lo,
      input logic dreq00,
      input logic same8,
      input logic [31:0] data
  );
    load00_lo8_s2 = smt_ss(cfg) && (cfg.FETCH_WIDTH >= 64) &&
                    (cfg.ICACHE_LINE_WIDTH >= 128) &&
                    icache_valid && npc00 && npc_lo &&
                    dreq00 && same8 &&
                    (data[1:0] == 2'b11) &&
                    (data[6:0] == 7'b0000011) &&
                    (data[11:7] != 5'd0);
  endfunction

endpackage
