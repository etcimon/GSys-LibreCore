// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Soft-ladder EXTRACT E4 — sibling 01 Branch → c.jalr recover.
//
// ID/SB: recover predicates (G1hd/hx/hy/id/ik/ln/lz/ij) + G1mf scan.
// E4 FE: frontend LOAD capture/hit (g1kk/g1le/g1lq), +2 stash capture
// (G1hj/jy encodings), leftover-slot0, leftover_blocks_01 (off-line
// leftover must not own npc 01), stash_keep16 (hygiene),
// stash_keep_pc (held +2 c.jalr until that PC is presented;
// 71e4 must not last-replace 7ba), load_flush_keep
// (G1kk survives flush_i while npc is on the captured 16B line),
// load_flush_next16 (flush while npc is the next 16B line —
// 7c0 between 7b0 and 7ba).
// Present mux writes and FE flops stay in frontend. G1je any-op —
// MINI-FAIL. G1lm IQ rewrite — MINI-FAIL. G1lk no-npc-line —
// reverted. G1jj/jw / idle_sib16 / idle_load_sib stay dead. G1mg
// not next. Do not re-land.
//
// Timing: same pc[2:1] / encoding / 8B+16B line compares already on
// the recover/present cone. No sequential logic in this package.

package g6lc_sib_cjalr;
  import config_pkg::*;

  function automatic logic smt_ss(input cva6_cfg_t cfg);
    smt_ss = cfg.SuperscalarEn && (cfg.NrHarts > 1);
  endfunction

  function automatic logic fw64(input cva6_cfg_t cfg);
    fw64 = cfg.FETCH_WIDTH >= 64;
  endfunction

  function automatic logic is_rvi_branch(input logic [31:0] i);
    is_rvi_branch = (i[1:0] == 2'b11) && (i[6:0] == 7'b1100011);
  endfunction

  function automatic logic [4:0] cbranch_rs1(input logic [15:0] hw);
    cbranch_rs1 = {2'b01, hw[9:7]};
  endfunction

  function automatic logic [4:0] cjalr_rs1(input logic [31:0] i);
    if (g6lc_rvc_enc::is_cjalr16(i[15:0]))
      cjalr_rs1 = i[11:7];
    else
      cjalr_rs1 = i[27:23];
  endfunction

  function automatic logic [4:0] aligned_br_rs1(
      input logic [31:0] i,
      input logic [4:0] decoded_rs1
  );
    if (is_rvi_branch(i))
      aligned_br_rs1 = i[19:15];
    else if (i[1:0] == 2'b01)
      aligned_br_rs1 = cbranch_rs1(i[15:0]);
    else
      aligned_br_rs1 = decoded_rs1;
  endfunction

  // G1hd: mid-line 01 fetch has exact c.jalr in either half.
  function automatic logic mid_cjalr(
      input cva6_cfg_t cfg,
      input logic pc01,
      input logic [31:0] instr
  );
    mid_cjalr = smt_ss(cfg) && pc01 &&
                (g6lc_rvc_enc::is_cjalr16(instr[15:0]) ||
                 g6lc_rvc_enc::is_cjalr16(instr[31:16]));
  endfunction

  // G1hx: mid-line 01 compressed Branch, same 16-bit as aligned
  // sibling (latch or same-packet slot0).
  function automatic logic hx_rec(
      input cva6_cfg_t cfg,
      input logic pc01,
      input logic cbr,
      input logic is_br,
      input logic hx_match,
      input logic dup
  );
    hx_rec = smt_ss(cfg) && pc01 && cbr && is_br && (hx_match || dup);
  endfunction

  // G1hy: mid-line 01 Branch, aligned sibling [31:16] exact c.jalr.
  function automatic logic hy_rec(
      input cva6_cfg_t cfg,
      input logic pc01,
      input logic is_br,
      input logic hy_match,
      input logic slot0_hi
  );
    hy_rec = smt_ss(cfg) && pc01 && is_br && (hy_match || slot0_hi);
  endfunction

  // G1id/ik/ln/lz: mid-line 01 Branch on the same line as a just-seen
  // aligned Branch or sibling 00 LOAD.
  function automatic logic id_rec(
      input cva6_cfg_t cfg,
      input logic pc01,
      input logic is_br,
      input logic hx_line,
      input logic ik,
      input logic ln,
      input logic lz,
      input logic pkt_br
  );
    id_rec = smt_ss(cfg) && pc01 && is_br &&
             (hx_line || ik || ln || lz || pkt_br);
  endfunction

  // G1ij: mid-line 01 Branch whose 16-bit is not a Branch encoding.
  function automatic logic mash_drop(
      input cva6_cfg_t cfg,
      input logic pc01,
      input logic is_br,
      input logic cbr,
      input logic rvi_br
  );
    mash_drop = smt_ss(cfg) && pc01 && is_br && !cbr && !rvi_br;
  endfunction

  // G1ik: in-ID aligned Branch, same 8B line.
  function automatic logic ik_arm(
      input cva6_cfg_t cfg,
      input logic valid,
      input logic pc00,
      input logic is_br,
      input logic same8
  );
    ik_arm = smt_ss(cfg) && valid && pc00 && is_br && same8;
  endfunction

  // G1ln: in-ID aligned-00 RVI LOAD, sibling 16-byte half, same hart.
  function automatic logic ln_arm(
      input cva6_cfg_t cfg,
      input logic valid,
      input logic same_hart,
      input logic pc00,
      input logic is_load,
      input logic rd_nz,
      input logic same16,
      input logic a3_diff
  );
    ln_arm = smt_ss(cfg) && fw64(cfg) && valid && same_hart && pc00 &&
             is_load && rd_nz && same16 && a3_diff;
  endfunction

  // G1lz: per-hart g1lo hit on sibling 01 of that hart's 00 LOAD.
  function automatic logic lz_hit(
      input cva6_cfg_t cfg,
      input logic lo_v,
      input logic same16,
      input logic a3_diff
  );
    lz_hit = smt_ss(cfg) && lo_v && same16 && a3_diff;
  endfunction

  // G1hx capture from issue_q: aligned Branch.
  function automatic logic aligned_br_op(
      input cva6_cfg_t cfg,
      input logic valid,
      input logic pc00,
      input logic is_br
  );
    aligned_br_op = smt_ss(cfg) && valid && pc00 && is_br;
  endfunction

  // G1hx capture from fetch_entry: aligned compressed/RVI/decoded Branch.
  function automatic logic aligned_br_fetch(
      input cva6_cfg_t cfg,
      input logic valid,
      input logic pc00,
      input logic [31:0] instr,
      input logic op_br
  );
    aligned_br_fetch = smt_ss(cfg) && valid && pc00 &&
                       (g6lc_fe_keep::is_cbranch16(instr[15:0]) ||
                        is_rvi_branch(instr) || op_br);
  endfunction

  // G1hy capture: aligned fetch [31:16] exact c.jalr.
  function automatic logic aligned_hi_cjalr(
      input cva6_cfg_t cfg,
      input logic valid,
      input logic pc00,
      input logic [31:0] instr
  );
    aligned_hi_cjalr = smt_ss(cfg) && valid && pc00 &&
                       g6lc_rvc_enc::is_cjalr16(instr[31:16]);
  endfunction

  // G1lo capture / G1md: aligned-00 LOAD rd!=0.
  function automatic logic load00(
      input cva6_cfg_t cfg,
      input logic valid,
      input logic pc00,
      input logic is_load,
      input logic rd_nz
  );
    load00 = smt_ss(cfg) && fw64(cfg) && valid && pc00 && is_load && rd_nz;
  endfunction

  function automatic logic cmt_load00(
      input cva6_cfg_t cfg,
      input logic ack,
      input logic ex_valid,
      input logic is_compressed,
      input logic pc00,
      input logic is_load,
      input logic rd_nz
  );
    cmt_load00 = smt_ss(cfg) && fw64(cfg) && ack && !ex_valid &&
                 !is_compressed && pc00 && is_load && rd_nz;
  endfunction

  // G1mf: result-valid aligned-00 RVI LOAD (WB done, before commit).
  function automatic logic sb_load00(
      input cva6_cfg_t cfg,
      input logic issued,
      input logic cancelled,
      input logic sbe_valid,
      input logic ex_valid,
      input logic is_compressed,
      input logic pc00,
      input logic is_load,
      input logic rd_nz
  );
    sb_load00 = smt_ss(cfg) && fw64(cfg) && issued && !cancelled &&
                sbe_valid && !ex_valid && !is_compressed && pc00 &&
                is_load && rd_nz;
  endfunction

  // --- E4 FE: frontend LOAD / stash / inject ---

  function automatic logic is_rvi_load(input logic [31:0] i);
    is_rvi_load = (i[1:0] == 2'b11) && (i[6:0] == 7'b0000011) &&
                  (i[11:7] != 5'd0);
  endfunction

  function automatic logic [15:0] make_cjalr16(input logic [4:0] rs1);
    make_cjalr16 = {4'b1001, rs1, 5'd0, 2'b10};
  endfunction

  function automatic logic leftover_slot0(
      input logic serving_unaligned,
      input logic v0,
      input logic addr11
  );
    leftover_slot0 = serving_unaligned && v0 && addr11;
  endfunction

  // Leftover-complete of a *different* 8B line must not own npc 01
  // (OpenSBI 766 leftover vs 7ba). Same-line leftover still blocks
  // (p2_ok). Soaked hygiene (cookie t=83968; hangj 766 unchanged —
  // leftover 11 was not occupying slot0 at npc 7ba). G1es leftover_next
  // — MINI-FAIL. Not G1hm slot1.
  function automatic logic leftover_blocks_01(
      input logic serving_unaligned,
      input logic v0,
      input logic addr11,
      input logic same8
  );
    leftover_blocks_01 = leftover_slot0(serving_unaligned, v0, addr11) &&
                         same8;
  endfunction

  function automatic logic icache_seen(
      input logic dreq_v,
      input logic kill_s2
  );
    icache_seen = dreq_v || (!dreq_v && !kill_s2);
  endfunction

  // G1le: I$ aligned-00 RVI LOAD (no npc-line).
  function automatic logic fe_load00(
      input cva6_cfg_t cfg,
      input logic seen,
      input logic vaddr00,
      input logic [31:0] data
  );
    fe_load00 = smt_ss(cfg) && fw64(cfg) && seen && vaddr00 &&
                is_rvi_load(data);
  endfunction

  // G1kn / G1kw: same plus npc on that 16-byte line.
  function automatic logic fe_load00_npc(
      input cva6_cfg_t cfg,
      input logic seen,
      input logic vaddr00,
      input logic [31:0] data,
      input logic npc_line
  );
    fe_load00_npc = fe_load00(cfg, seen, vaddr00, data) && npc_line;
  endfunction

  // G1lh / G1ls present-path 00 LOAD (inside smt_ss && fw64).
  function automatic logic present_load00(
      input logic valid,
      input logic pc00,
      input logic [31:0] instr
  );
    present_load00 = valid && pc00 && is_rvi_load(instr);
  endfunction

  // G1le_hit / G1lq_hit: latched 00 LOAD, npc sibling 01.
  function automatic logic sib01_hit(
      input cva6_cfg_t cfg,
      input logic lo_v,
      input logic npc01,
      input logic same16,
      input logic a3_diff
  );
    sib01_hit = smt_ss(cfg) && fw64(cfg) && lo_v && npc01 &&
                same16 && a3_diff;
  endfunction

  // G1ky / G1lj: same-cycle LOAD cap at npc sibling 01.
  function automatic logic sib01_cap(
      input cva6_cfg_t cfg,
      input logic npc01,
      input logic load,
      input logic a3_diff
  );
    sib01_cap = smt_ss(cfg) && fw64(cfg) && npc01 && load && a3_diff;
  endfunction

  // idle_sib16 IDLE user[33] pair on npc 16B line —
  // HOLD-FAIL 51b1c001 @250000 (G1jw class, mepc
  // 14f34/2 npc 71f0). Do not re-land.
  // idle_load_sib IDLE pair + aligned-00 RVI LOAD —
  // HOLD-FAIL same pin as idle_sib16. IDLE user[33]
  // into G1hj is closed. Do not re-land.
  // Held +2 c.jalr of the current npc 16-byte line
  // is not last-replaced (7b0 sibling 7ba vs later
  // 7c0). Not G1jb any-01 keep. Not G1kt first-LOAD
  // block: a different 16B line may still recapture.
  function automatic logic stash_keep16(
      input cva6_cfg_t cfg,
      input logic v,
      input logic pc01,
      input logic same16
  );
    stash_keep16 = smt_ss(cfg) && fw64(cfg) && v && pc01 && same16;
  endfunction

  // Held +2 c.jalr is not last-replaced until npc
  // is that PC (7b0 captured 7ba, npc 71e4 must
  // not overwrite). stash_keep16 only while npc
  // is on the same 16B line — hygiene. Not G1jb
  // any-01. Not G1kt first-LOAD block of a
  // different line when npc is already the
  // stashed PC (npc_eq allows recapture).
  function automatic logic stash_keep_pc(
      input cva6_cfg_t cfg,
      input logic v,
      input logic npc_ne
  );
    stash_keep_pc = smt_ss(cfg) && fw64(cfg) && v && npc_ne;
  endfunction

  // G1kk survives flush_i while npc is still on
  // the captured 16-byte line (7b0 ld → 7ba).
  // G1ko leftover-Jump spare missed flush after
  // leftover stopped serving. Not G1jr kill_s1.
  // Not G1iy all-01. ex_valid still clears.
  function automatic logic load_flush_keep(
      input cva6_cfg_t cfg,
      input logic v,
      input logic same16
  );
    load_flush_keep = smt_ss(cfg) && fw64(cfg) && v && same16;
  endfunction

  // G1kk survives flush_i while npc is the
  // sequential-next 16B line (7c0 after
  // 7b0, before plus2 to 7ba). load_flush
  // keep same-line is a no-op at 7c0.
  // TRACE n7c0@20438 then n7ba@20440.
  // Not G1kt keep-until-01 (first LOAD
  // blocks 7b0). Not G1jr. SMT+SS.
  function automatic logic load_flush_next16(
      input cva6_cfg_t cfg,
      input logic v,
      input logic npc_next16
  );
    load_flush_next16 = smt_ss(cfg) && fw64(cfg) && v &&
                        npc_next16;
  endfunction

  // G1hj / G1jy slot0 present at stashed +2 PC.
  function automatic logic stash_npc01(
      input cva6_cfg_t cfg,
      input logic v,
      input logic ha_cjalr,
      input logic npc01,
      input logic npc_eq,
      input logic leftover0
  );
    stash_npc01 = smt_ss(cfg) && fw64(cfg) && v && !ha_cjalr &&
                  npc01 && npc_eq && !leftover0;
  endfunction

  // G1iq: stash of aligned compressed Branch at npc 00.
  function automatic logic iq_br_npc00(
      input cva6_cfg_t cfg,
      input logic v,
      input logic npc00,
      input logic same8
  );
    iq_br_npc00 = smt_ss(cfg) && fw64(cfg) && v && npc00 && same8;
  endfunction

  // G1ie rewrite: mid-line 01 compressed/RVI Branch slot.
  function automatic logic mid_br_slot(
      input logic valid,
      input logic pc01,
      input logic [31:0] instr
  );
    mid_br_slot = valid && pc01 &&
                  (g6lc_fe_keep::is_cbranch16(instr[15:0]) ||
                   is_rvi_branch(instr));
  endfunction

  // G1ke: IDLE aligned-00 Branch + [31:16] c.jalr pair.
  function automatic logic idle_br_cjalr(
      input cva6_cfg_t cfg,
      input logic dreq_v,
      input logic kill_s2,
      input logic vaddr00,
      input logic [31:0] data
  );
    idle_br_cjalr = smt_ss(cfg) && fw64(cfg) && !dreq_v && !kill_s2 &&
                    vaddr00 && g6lc_fe_keep::is_cbranch16(data[15:0]) &&
                    g6lc_rvc_enc::is_cjalr16(data[31:16]);
  endfunction

  // G1kg: kill_s2 aligned-00 Branch + [31:16] c.jalr pair.
  function automatic logic kill_br_cjalr(
      input cva6_cfg_t cfg,
      input logic kill_s2,
      input logic vaddr00,
      input logic [31:0] data
  );
    kill_br_cjalr = smt_ss(cfg) && fw64(cfg) && kill_s2 && vaddr00 &&
                    g6lc_fe_keep::is_cbranch16(data[15:0]) &&
                    g6lc_rvc_enc::is_cjalr16(data[31:16]);
  endfunction

endpackage

