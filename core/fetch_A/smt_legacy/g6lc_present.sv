// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Soft-ladder EXTRACT E9 — present-at-npc / mid-line 16-bit (layer 1).
//
// Bit-identical move of g1fu_mid / g1gx shift / g1ha +2 c.jalr present,
// G1fq/G1hc +2 fills, G1fu–G1gd npc +2 after compressed Branch, and
// realign G1bf/ed / G1gx mid / G1eu leftover jal x0 vs I|I. Mux writes
// and leftover FSM stay in the host. G1gz all mid-line slot0 — MINI-FAIL.
// G1es aligned I|I overrides leftover_next — MINI-FAIL. G1bo any
// aligned compressed — MINI-FAIL. later_br_01 npc-01 later-slot
// Branch mute — MINI-FAIL FDT 23 @1184 (G1iz/G1jh). G1jd
// sequential-next at npc 00 — MINI-FAIL. sib8_fetch sibling 8B
// while npc on first half of 16B line — MINI-FAIL FDT hang
// @400000. plus2_stay: fetch stays on aligned C-Branch 8B
// (hygiene). hi8_npc_fetch any-diff-8B — MINI-FAIL lottery
// 4 @362 G1ja / FDT 57 @445 G1jd. lo11_npc00 leftover-PC
// fetch [2:1]==11 vs npc 00 first 8B — MINI-FAIL sib P0
// fail 1 @407 / FDT 0x10 @423 (jalr-target [2:1]==11).
// lo_pc_npc00 leftover serving + fetch is
// that leftover 8B vs npc 00 first 8B —
// HOLD-FAIL plat_hc=80 mepc 0xb0/2 @250000.
// ljx0_off / ljx0_pc hygiene (not serving
// at n7b0; fetch==leftover 8B misses
// bp_valid Jump target). ljx0_bp_npc00:
// leftover jal x0 presented + bp_valid
// stole fetch; npc 00 first 8B requests
// npc. Not JumpR. Not G1gn. lo_ld_stay
// RVI LOAD at npc 00 first 8B — HOLD-FAIL
// 51b1c001 @250000. lo_ld_lo11: that LOAD
// plus leftover-PC-shaped fetch [2:1]==11
// off-line. Not lo11 any-hw11. Not lo_ld
// any-LOAD. hi8_lo11 leftover-PC-shaped
// fetch vs npc 00 of 16B-line second 8B
// — MINI-FAIL FDT 57 @445 (G1jd). Not
// hi8 any-diff. sib_lo_s2 MINI-FAIL G1jp.
// leftover_off_npc00 hygiene (I$ of
// leftover_next is not a 00-first-8B
// LOAD off leftover's 16B at n7b0).
// leftover_slot0_off_npc00 npc-based
// leftover slot0 hide — MINI-FAIL sib
// printed 4 @448 / lottery hang /
// FDT 17. leftover_nx8_npc00: fetch
// leftover+8 vs npc 00 first 8B off
// leftover 16B. Not G1es. Not G1eu.
// Not skip_next. Not lo_pc. Not lo11.
// G1fx/fz stay dead. Do not re-land.
//
// Timing: same npc[2:1] / I$ line / 16-bit compares already on the
// present cone. No sequential logic in this package.

package g6lc_present;
  import config_pkg::*;

  function automatic logic smt_ss(input cva6_cfg_t cfg);
    smt_ss = cfg.SuperscalarEn && (cfg.NrHarts > 1);
  endfunction

  function automatic logic fw64(input cva6_cfg_t cfg);
    fw64 = cfg.FETCH_WIDTH >= 64;
  endfunction

  // G1fu: registered same-line I$ while npc is mid-line 01.
  function automatic logic fu_mid(
      input cva6_cfg_t cfg,
      input logic icache_valid,
      input logic npc01,
      input logic same_line
  );
    fu_mid = smt_ss(cfg) && icache_valid && npc01 && same_line;
  endfunction

  // G1gx: shift registered I$ so slot0 is the 16-bit at npc 01.
  function automatic logic gx_shift(
      input cva6_cfg_t cfg,
      input logic fu,
      input logic vaddr00
  );
    gx_shift = fw64(cfg) && fu && vaddr00;
  endfunction

  // I$ +2 halfword: aligned line uses [31:16], mid-line uses [15:0].
  function automatic logic [15:0] plus2_hw(
      input logic [1:0] v01,
      input logic [31:0] data
  );
    plus2_hw = (v01 == 2'b00) ? data[31:16] : data[15:0];
  endfunction

  // G1ha: present slot0 from I$ +2 only when that halfword is c.jalr.
  function automatic logic ha_mid(
      input cva6_cfg_t cfg,
      input logic line_v,
      input logic v01_ok,
      input logic cjalr,
      input logic fu_live,
      input logic ra01_same
  );
    ha_mid = smt_ss(cfg) && fw64(cfg) && line_v && v01_ok && cjalr &&
             (fu_live || ra01_same);
  endfunction

  // G1fq: aligned compressed slot0, fill slot1 from I$ +2 c.jalr.
  function automatic logic fq_cjalr(
      input cva6_cfg_t cfg,
      input logic line_v,
      input logic serving,
      input logic v0,
      input logic pc00,
      input logic compr0,
      input logic [31:0] data
  );
    fq_cjalr = smt_ss(cfg) && fw64(cfg) && line_v && !serving && v0 &&
               pc00 && compr0 && g6lc_rvc_enc::is_cjalr16(data[31:16]);
  endfunction

  // G1hc: leftover slot0, fill slot1 from aligned I$ +2 c.jalr.
  // Only while npc is mid-line 01 (7ba). Aligned leftover-next
  // (p2_ok auipc+addi) must keep realign slot1. Not G1es.
  function automatic logic hc_cjalr(
      input cva6_cfg_t cfg,
      input logic line_v,
      input logic serving,
      input logic v0,
      input logic addr11,
      input logic iaddr00,
      input logic npc01,
      input logic [31:0] data
  );
    hc_cjalr = smt_ss(cfg) && fw64(cfg) && line_v && serving && v0 &&
               addr11 && iaddr00 && npc01 &&
               g6lc_rvc_enc::is_cjalr16(data[31:16]);
  endfunction

  // G1hh: rewrite a [2:1]==01 slot to I$ +2 c.jalr only
  // while npc is mid-line 01. Leftover-complete later
  // RVI at 01 (p2_ok addi) must stay. Not G1hi same-line.
  // G1hm: leftover-complete slot1 from stashed +2 c.jalr
  // only if leftover slot0 is Jump/JumpR (766 / 7ba).
  // Leftover auipc (p2_ok) keeps realign addi. Not G1es.
  function automatic logic hm_cjalr(
      input cva6_cfg_t cfg,
      input logic hj_v,
      input logic ha_cjalr,
      input logic serving,
      input logic v0,
      input logic addr11,
      input logic slot0_jump
  );
    hm_cjalr = smt_ss(cfg) && fw64(cfg) && hj_v && !ha_cjalr && serving &&
               v0 && addr11 && slot0_jump;
  endfunction

  function automatic logic hh_cjalr(
      input cva6_cfg_t cfg,
      input logic line_v,
      input logic ha_cjalr,
      input logic npc01
  );
    hh_cjalr = smt_ss(cfg) && fw64(cfg) && line_v && ha_cjalr && npc01;
  endfunction

  // G1fu +2: slot0-only consume of aligned compressed Branch.
  function automatic logic plus2_cons(
      input cva6_cfg_t cfg,
      input logic v0,
      input logic serving,
      input logic pc00,
      input logic compr,
      input logic br,
      input logic cons0,
      input logic cons1
  );
    plus2_cons = smt_ss(cfg) && v0 && !serving && pc00 && compr && br &&
                 cons0 && !cons1;
  endfunction

  // G1fv: aligned compressed Branch presented slot0-only.
  function automatic logic plus2_pres(
      input cva6_cfg_t cfg,
      input logic v0,
      input logic v1,
      input logic serving,
      input logic pc00,
      input logic compr,
      input logic br
  );
    plus2_pres = smt_ss(cfg) && v0 && !v1 && !serving && pc00 && compr && br;
  endfunction

  // G1fw / G1fy: IQ view slot0-only +2 (is_branch or rvc_branch).
  function automatic logic plus2_iq(
      input cva6_cfg_t cfg,
      input logic ct0,
      input logic ct1,
      input logic serving,
      input logic pc00,
      input logic compr,
      input logic br
  );
    plus2_iq = smt_ss(cfg) && ct0 && !ct1 && !serving && pc00 && compr && br;
  endfunction

  // G1ga / G1gb / G1gc: aligned compressed Branch | JumpR +2.
  function automatic logic plus2_jalr(
      input cva6_cfg_t cfg,
      input logic v0,
      input logic v1,
      input logic serving_ok,
      input logic pc00,
      input logic compr,
      input logic br,
      input logic [31:0] i1
  );
    plus2_jalr = smt_ss(cfg) && v0 && v1 && serving_ok && pc00 && compr &&
                 br && g6lc_rvc_enc::is_jalr(i1);
  endfunction

  // G1bf / G1ed: leftover-pending aligned fetch presents 16-bit at PC.
  function automatic logic bf_ed(
      input cva6_cfg_t cfg,
      input logic leftover_rvi,
      input logic leftover_next,
      input logic valid,
      input logic pc00,
      input logic compr0
  );
    bf_ed = smt_ss(cfg) && leftover_rvi && !leftover_next && valid &&
            pc00 && compr0;
  endfunction

  // Realign G1gx: leftover-complete mid-line 01 is the 16-bit at that PC.
  function automatic logic gx_mid01(
      input cva6_cfg_t cfg,
      input logic leftover_next,
      input logic valid,
      input logic pc01,
      input logic compr0
  );
    gx_mid01 = smt_ss(cfg) && leftover_next && valid && pc01 && compr0;
  endfunction

  // G1eu: leftover jal x0 does not complete onto aligned I|I.
  function automatic logic eu_jalx0_ii(
      input cva6_cfg_t cfg,
      input logic leftover_next,
      input logic valid,
      input logic pc00,
      input logic compr0,
      input logic compr2,
      input logic [31:0] leftover
  );
    eu_jalx0_ii = smt_ss(cfg) && leftover_next && valid && pc00 &&
                  !compr0 && !compr2 &&
                  g6lc_iq_hide::is_jal_x0(leftover);
  endfunction

  // Aligned compressed Branch at npc 00: I$ stays on
  // that 8B line (7b8), not bp_valid sequential 7c0.
  // TRACE n7b8 @20431 then n7c0 @20438 then n7ba
  // @20440. fetch_address only. Not G1ja any-00
  // under predict. Not G1iz npc 01. Not G1fz
  // slot1-valid +2. Not sib8_fetch.
  function automatic logic plus2_stay(
      input cva6_cfg_t cfg,
      input logic npc00,
      input logic v0,
      input logic compr0,
      input logic br0
  );
    plus2_stay = smt_ss(cfg) && fw64(cfg) && npc00 && v0 &&
                 compr0 && br0;
  endfunction

  // npc already on the second 8B of a 16B I$ line
  // (7b8): fetch that 8B, not sequential 7c0.
  // plus2_stay needs C-Branch presented — TRACE
  // n7b8@20431 has no slot0 C-Branch yet. Not
  // sib8_fetch (npc on first half). Not G1ja
  // any-00. Not G1jd.
  // hi8_npc_fetch any-diff-8B — MINI-FAIL lottery
  // tohost 4 @362 (G1ja) FDT 57 @445 (G1jd). Do
  // not re-land.
  function automatic logic line_hi8_stay(
      input cva6_cfg_t cfg,
      input logic npc00,
      input logic npc_hi,
      input logic fetch_next8
  );
    line_hi8_stay = smt_ss(cfg) && fw64(cfg) &&
                    (cfg.ICACHE_LINE_WIDTH >= 128) &&
                    npc00 && npc_hi && fetch_next8;
  endfunction

  // lo11_npc00 leftover-PC-shaped fetch
  // ([2:1]==11) vs npc 00 first 8B of a
  // 16B line — MINI-FAIL sib P0 fail 1
  // @407 / FDT printed 16 (0x10 blob
  // magic) @423. lottery PASS. Do not
  // re-land (jalr-target [2:1]==11 is
  // not leftover 766).
  // lo_pc_npc00 leftover serving + fetch
  // is that leftover 8B vs npc 00 first
  // 8B — HOLD-FAIL plat_hc=80 mepc
  // 0x800000b0 mcause=2 npc 0x10050
  // @250000. Minis PASS @597/@558/@2729.
  // Do not re-land (starves leftover-PC
  // I$ at npc 00 first 8B / G1iz analog).
  // ljx0_off_npc00: leftover jal x0
  // serving on a different 16B line
  // than npc, fetch is that leftover
  // 8B, npc 00 first 8B (7b0). Spare
  // same-line leftover-RVI complete
  // (lo_pc HOLD-FAIL). Host also
  // passes latched leftover jal x0
  // PC after serving ends (ljx0_pc).
  // Not lo11. Not G1ja. SMT+SS.
  function automatic logic ljx0_off_npc00(
      input cva6_cfg_t cfg,
      input logic npc00,
      input logic npc_lo,
      input logic leftover_lj,
      input logic off16,
      input logic fetch_lo
  );
    ljx0_off_npc00 = smt_ss(cfg) && fw64(cfg) &&
                     npc00 && npc_lo && leftover_lj &&
                     off16 && fetch_lo;
  endfunction

  // leftover jal x0 presented ([2:1]==11) with
  // bp_valid stole fetch to the Jump target, not
  // leftover PC. npc 00 first 8B (7b0) still
  // requests npc. ljx0_off fetch==leftover 8B
  // is a no-op after bp_valid. Not JumpR (lo11
  // jalr-target). Not lo_pc any-leftover. Not
  // G1gn npc skip. SMT+SS.
  function automatic logic ljx0_bp_npc00(
      input cva6_cfg_t cfg,
      input logic npc00,
      input logic npc_lo,
      input logic leftover_lj,
      input logic bp,
      input logic fetch_ne
  );
    ljx0_bp_npc00 = smt_ss(cfg) && fw64(cfg) &&
                    npc00 && npc_lo && leftover_lj &&
                    bp && fetch_ne;
  endfunction

  // lo_ld_stay aligned RVI LOAD at npc 00
  // first 8B — HOLD-FAIL [1000]=51b1c001
  // no cookie @250000 plat_hc=80. Minis
  // PASS @597/@558/@2729. hangj 766
  // moved 20443→25481 (class fired).
  // Do not re-land (keeps fetch on LOAD
  // 00 first 8B; yanked success-cave
  // addi / G1jw analog).
  // lo_ld_lo11: RVI LOAD at npc 00 first
  // 8B and fetch is leftover-PC-shaped
  // ([2:1]==11) off the npc 16B line.
  // lo11 without LOAD — MINI-FAIL jalr
  // target. lo_ld without fetch11 —
  // HOLD-FAIL cave addi. SMT+SS.
  function automatic logic lo_ld_lo11(
      input cva6_cfg_t cfg,
      input logic npc00,
      input logic npc_lo,
      input logic v0,
      input logic rvi0,
      input logic load0,
      input logic fetch11,
      input logic off16
  );
    lo_ld_lo11 = smt_ss(cfg) && fw64(cfg) && npc00 &&
                 npc_lo && v0 && rvi0 && load0 &&
                 fetch11 && off16;
  endfunction

  // hi8_lo11 leftover-PC-shaped fetch
  // [2:1]==11 vs npc 00 of 16B-line
  // second 8B — MINI-FAIL FDT 57 @445
  // (G1jd). lottery PASS @558 (narrower
  // than hi8 lottery 4). Do not re-land
  // (7b8-shaped npc I$ vs leftover-PC
  // fetch is load-bearing).
  // leftover_off_npc00: leftover-complete
  // of a *different* 16B line must not
  // occupy slot0 when the completing
  // fetch is 00 first 8B (7b0 ld). Present
  // aligned I$ slot0; keep leftover
  // pending. Same-16B leftover_next
  // (766 from 768) still completes.
  // Hygiene: leftover_next onto a 7b0
  // LOAD I$ is a no-op at n7b0 (I$ of
  // leftover_next is not that LOAD).
  // Not G1es any I|I. Not G1eu jal x0.
  // Not skip_next later-slot hide. Not
  // fetch rewrite. SMT+SS.
  function automatic logic leftover_off_npc00(
      input cva6_cfg_t cfg,
      input logic leftover_next,
      input logic valid,
      input logic pc00,
      input logic npc_lo,
      input logic off16,
      input logic [31:0] data
  );
    leftover_off_npc00 = smt_ss(cfg) && fw64(cfg) &&
                         (cfg.ICACHE_LINE_WIDTH >= 128) &&
                         leftover_next && valid && pc00 &&
                         npc_lo && off16 &&
                         (data[1:0] == 2'b11) &&
                         (data[6:0] == 7'b0000011) &&
                         (data[11:7] != 5'd0);
  endfunction

  // leftover_slot0_off_npc00 npc-based
  // leftover slot0 hide at npc 00 first
  // 8B off leftover 16B — MINI-FAIL sib
  // printed 4 @448 (P2 leftover jal x0
  // executed) / lottery hang @400000 /
  // FDT printed 17 @413. Do not re-land
  // (off-line leftover slot0 at npc 00
  // first 8B is load-bearing; skip_next
  // analog).
  // leftover_nx8_npc00: leftover occupying
  // slot0, fetch is leftover's *next* 8B
  // (768 leftover_next, not leftover PC
  // 766), npc 00 first 8B off leftover
  // 16B. Request npc. Hygiene: leftover
  // occupying + fetch leftover+8 is not
  // true at n7b0. Not lo_pc (fetch
  // leftover 8B). Not lo11 hw11. Not
  // leftover_slot0 hide. Not leftover_off
  // present. SMT+SS.
  function automatic logic leftover_nx8_npc00(
      input cva6_cfg_t cfg,
      input logic leftover_slot0,
      input logic npc00,
      input logic npc_lo,
      input logic off16,
      input logic fetch_nx8
  );
    leftover_nx8_npc00 = smt_ss(cfg) && fw64(cfg) &&
                         (cfg.ICACHE_LINE_WIDTH >= 128) &&
                         leftover_slot0 && npc00 && npc_lo &&
                         off16 && fetch_nx8;
  endfunction

endpackage
