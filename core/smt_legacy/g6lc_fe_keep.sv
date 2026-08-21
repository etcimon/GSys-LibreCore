// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Soft-ladder EXTRACT E6 — registered-I$ hold predicates (SMT+SS).
//
// Bit-identical move of g1cv/ek/el/ep/ex/ez/fa/ic/jm/bl/cr. Scan loop for
// jump/prefix/g1bp_nocf_dest stays in frontend (feeds keep_line + this OR).
// Mux that applies hold stays in frontend. G1bb freeze — HOLD-FAIL. G1in
// leftover-PC hold at npc 00 — MINI-FAIL. ld_until_01 keep registered
// 00 RVI LOAD until sibling 01 — MINI-FAIL FDT 106 @409 (G1lm class).
// load00_vs_off16 hygiene. load00_vs_lj: 00 first-8B LOAD vs
// leftover-PC I$ [2:1]==11, no npc-line. G1jm is C-Branch until
// same-8B 01. Do not re-land ld_until_01.
//
// Timing: same line compares already on the I$ return cone. No sequential
// logic in this package (g1ge_wait / g1jm_01_now stay in the host).

package g6lc_fe_keep;
  import config_pkg::*;

  function automatic logic smt_ss(input cva6_cfg_t cfg);
    smt_ss = cfg.SuperscalarEn && (cfg.NrHarts > 1);
  endfunction

  function automatic logic [63:0] line_mask(
      input int unsigned vlen,
      input int unsigned align
  );
    logic [63:0] m;
    m = ~((64'(1) << align) - 64'(1));
    if (vlen < 64) m = m & ((64'(1) << vlen) - 64'(1));
    line_mask = m;
  endfunction

  function automatic logic same_line(
      input int unsigned vlen,
      input int unsigned align,
      input logic [63:0] a,
      input logic [63:0] b
  );
    logic [63:0] m;
    m = line_mask(vlen, align);
    same_line = ((a & m) == (b & m));
  endfunction

  function automatic logic diff_line(
      input int unsigned vlen,
      input int unsigned align,
      input logic [63:0] a,
      input logic [63:0] b
  );
    diff_line = !same_line(vlen, align, a, b);
  endfunction

  // G1cv: leftover-complete unconsumed slot0 Jump.
  function automatic logic leftover_jump(
      input cva6_cfg_t cfg,
      input logic serving_unaligned,
      input logic v0,
      input logic consumed0,
      input logic is_jump,
      input logic ge_lift
  );
    leftover_jump = smt_ss(cfg) && serving_unaligned && v0 && !consumed0 &&
                    is_jump && !ge_lift;
  endfunction

  // G1ez: leftover-complete unconsumed slot0 NoCF dest, different-line I$.
  function automatic logic leftover_nocf(
      input cva6_cfg_t cfg,
      input logic icache_valid,
      input logic serving_unaligned,
      input logic v0,
      input logic consumed0,
      input logic is_nocf,
      input logic rd_nz,
      input logic dreq_v,
      input logic diff
  );
    leftover_nocf = smt_ss(cfg) && icache_valid && serving_unaligned && v0 &&
                    !consumed0 && is_nocf && rd_nz && dreq_v && diff;
  endfunction

  // G1ek: unconsumed aligned I|I.
  function automatic logic ii_hold(
      input cva6_cfg_t cfg,
      input logic icache_valid,
      input logic v0,
      input logic v1,
      input logic pc00,
      input logic rvi0,
      input logic rvi1,
      input logic consumed0,
      input logic consumed1,
      input logic dreq_v,
      input logic diff
  );
    ii_hold = smt_ss(cfg) && icache_valid && v0 && v1 && pc00 && rvi0 && rvi1 &&
              (!consumed0 || !consumed1) && dreq_v && diff;
  endfunction

  // G1el: unconsumed mid-line 01 package.
  function automatic logic mid_hold(
      input cva6_cfg_t cfg,
      input logic icache_valid,
      input logic v0,
      input logic pc01,
      input logic consumed0,
      input logic v1,
      input logic consumed1,
      input logic dreq_v,
      input logic diff
  );
    mid_hold = smt_ss(cfg) && icache_valid && v0 && pc01 &&
               (!consumed0 || (v1 && !consumed1)) && dreq_v && diff;
  endfunction

  // G1ep: after 01 consumed, reject non-sequential-next I$.
  function automatic logic seq_next_hold(
      input cva6_cfg_t cfg,
      input logic icache_valid,
      input logic v0,
      input logic pc01,
      input logic consumed0,
      input logic v1,
      input logic consumed1,
      input logic dreq_v,
      input logic not_next
  );
    seq_next_hold = smt_ss(cfg) && icache_valid && v0 && pc01 && consumed0 &&
                    (!v1 || consumed1) && dreq_v && not_next;
  endfunction

  // G1ex: CSR-to-a0 in IQ holds different-line I$.
  function automatic logic csr_a0_hold(
      input cva6_cfg_t cfg,
      input logic icache_valid,
      input logic csr_a0,
      input logic dreq_v,
      input logic diff
  );
    csr_a0_hold = smt_ss(cfg) && icache_valid && csr_a0 && dreq_v && diff;
  endfunction

  // G1fa: I$ line ahead of npc.
  function automatic logic ahead_npc(
      input cva6_cfg_t cfg,
      input logic icache_valid,
      input logic dreq_v,
      input logic ge_lift,
      input logic ahead
  );
    ahead_npc = smt_ss(cfg) && icache_valid && dreq_v && !ge_lift && ahead;
  endfunction

  // G1ic: leftover-PC I$ ([2:1]==11) while npc is 01.
  function automatic logic leftover_pc_01(
      input cva6_cfg_t cfg,
      input logic npc01,
      input logic dreq_v,
      input logic dreq11
  );
    leftover_pc_01 = smt_ss(cfg) && npc01 && dreq_v && dreq11;
  endfunction

  // Aligned compressed Branch (c.beqz / c.bnez) in registered I$ [15:0].
  function automatic logic is_cbranch16(input logic [15:0] hw);
    is_cbranch16 = (hw[1:0] == 2'b01) &&
                   ((hw[15:13] == 3'b110) || (hw[15:13] == 3'b111));
  endfunction

  // G1jm: keep aligned compressed-Branch line until sibling 01 presented.
  function automatic logic br_until_01(
      input cva6_cfg_t cfg,
      input logic icache_valid,
      input logic use_stash,
      input logic vaddr00,
      input logic [15:0] data0,
      input logic now01
  );
    br_until_01 = smt_ss(cfg) && icache_valid && !use_stash && vaddr00 &&
                  is_cbranch16(data0) && !now01;
  endfunction

  // ld_until_01 keep registered 00 first-8B
  // RVI LOAD until sibling 01 of the other
  // 8B — MINI-FAIL FDT 106 @409 (G1lm
  // class). lottery PASS. Do not re-land
  // (holds LOAD I$ and starves FDT fetch).
  // load00_vs_off16: that LOAD is not
  // replaced by an off-16B I$ return
  // while npc is 00 first 8B of the
  // LOAD's 16B line (n7b0 vs leftover
  // 768). Hygiene: registered is not
  // that LOAD at n7b0. Not until
  // sibling 01. Not G1in leftover-PC
  // hold. Not G1bb. Not fetch rewrite.
  // SMT+SS.
  function automatic logic load00_vs_off16(
      input cva6_cfg_t cfg,
      input logic icache_valid,
      input logic vaddr00,
      input logic vaddr_lo,
      input logic npc00,
      input logic npc_lo,
      input logic npc_line,
      input logic [31:0] data,
      input logic dreq_off16
  );
    load00_vs_off16 = smt_ss(cfg) && (cfg.FETCH_WIDTH >= 64) &&
                      (cfg.ICACHE_LINE_WIDTH >= 128) &&
                      icache_valid && vaddr00 && vaddr_lo &&
                      npc00 && npc_lo && npc_line && dreq_off16 &&
                      (data[1:0] == 2'b11) &&
                      (data[6:0] == 7'b0000011) &&
                      (data[11:7] != 5'd0);
  endfunction

  // load00_vs_lj: registered 00 first-8B
  // LOAD is not replaced by leftover-PC
  // I$ ([2:1]==11). No npc-line (7b0
  // may register at 7a8 then leftover
  // 766 overwrites before n7b0).
  // Hygiene: 7b0 never registers (keep
  // is a no-op). load00_vs_off16 hygiene
  // needed npc on that first 8B. Not
  // ld_until_01. Not G1in. Not G1bb.
  // SMT+SS.
  function automatic logic load00_vs_lj(
      input cva6_cfg_t cfg,
      input logic icache_valid,
      input logic vaddr00,
      input logic vaddr_lo,
      input logic [31:0] data,
      input logic dreq11
  );
    load00_vs_lj = smt_ss(cfg) && (cfg.FETCH_WIDTH >= 64) &&
                   (cfg.ICACHE_LINE_WIDTH >= 128) &&
                   icache_valid && vaddr00 && vaddr_lo &&
                   dreq11 &&
                   (data[1:0] == 2'b11) &&
                   (data[6:0] == 7'b0000011) &&
                   (data[11:7] != 5'd0);
  endfunction

  // G1bl: any of the hold reasons AND different-line I$ return.
  function automatic logic hold_diff(
      input cva6_cfg_t cfg,
      input logic icache_valid,
      input logic dreq_v,
      input logic diff,
      input logic reason
  );
    hold_diff = smt_ss(cfg) && icache_valid && reason && dreq_v && diff;
  endfunction

  // G1cr: keep registered line across mispredict to that same aligned target.
  function automatic logic keep_misp_tgt(
      input cva6_cfg_t cfg,
      input logic icache_valid,
      input logic ex_valid,
      input logic resolve_v,
      input logic is_misp,
      input logic tgt_aligned,
      input logic same
  );
    keep_misp_tgt = smt_ss(cfg) && icache_valid && !ex_valid && resolve_v &&
                    is_misp && tgt_aligned && same;
  endfunction

endpackage
