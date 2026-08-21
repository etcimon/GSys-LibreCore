// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Soft-ladder EXTRACT E3 — I4x / I4bz / I4ce predicted-correct CF
// still kills IQ fallthrough (flush_unissued, no flush_if).
//
// Jump requires is_taken; Return and JumpR always taken.
// G1y: do not drop the registered I$ line on bp_valid while a
// predicted Jump in that line is still unconsumed (P6 jal lost;
// fetch already at the target). SMT+SS only.
// G1aq: also keep while an older NoCF (e.g. c.ldsp) is unconsumed
// before a Branch on the same line. TRACE: 0x4d0 ld t3 + 0x4d2 beq;
// t3 stayed 0xed. Not G1z/aa/ab/ac/G1ap.
// G1au: also keep while leftover-RVI complete (serving_unaligned)
// slot0 is unconsumed. TRACE: 0x4d0 c.li never entered IQ.
// G1aw: serving_unaligned is only the complete beat (not leftover_rvi).
// G1bb hold registered I$ data — HOLD-FAIL plat_hc=80. Do not re-land.
// G1bd leftover-RVI taken-target replay — HOLD-FAIL mepc 0x7b0/4
// no cookie @6e6. Do not re-land.
// G1bf: leftover-pending aligned fetch presents slot0 as the 16-bit
// at address_i. Not leftover complete. Not G1as. Not G1bb.
// G1bp: prefix hold was any aligned NoCF dest slot — hygiene
// (0x4d0 never registered). G1ca: dest-before-Branch only
// (drop any-slot OR; leftover Branch then dest is not prefix).
// G1cb: leftover-complete later-slot Jump is not
// jump_unconsumed. Not G1bz (bp_valid stays).
// G1cc: do not +8 NPC while leftover-Branch target
// (g1bv_wait) is not yet presented. Not G1ab/G1bu.
// G1cd hold on g1bv_arm same-cycle — HOLD-FAIL no
// cookie-exit. Do not re-land.
// G1ce leftover-complete +8 stall — HOLD-FAIL no
// cookie-exit. Do not re-land.
// G1cf leftover-next I$ vaddr override — MINI-FAIL
// P1 0x10 @406. Do not re-land.
// G1cg leftover-complete idx_is restart — MINI-FAIL
// P1 0x10 @384. Do not re-land.
// G1ch leftover-complete Branch-only idx_is restart —
// HOLD-FAIL no cookie-exit. Do not re-land.
// G1bq leftover-complete !kill_s2 —
// HOLD-FAIL no cookie-exit. Do not re-land.
// G1br later-slot !is_branch + consumed — HOLD-FAIL combo
// loop. G1bs later-slot !is_branch from valid dest —
// HOLD-FAIL no cookie-exit. Do not re-land.
// G1bt leftover taken Branch to next 8B !kill_s2 — HOLD-FAIL
// no cookie-exit. Do not re-land. Not G1bq all leftover.
// G1bu leftover-Branch I$ target barrier — HOLD-FAIL no
// cookie-exit. Do not re-land.
// G1bv: stash leftover-Branch target I$ return; present
// after leftover line drops. Not G1bb/G1bu. Not G1bk/G1bn.
// G1bw s2==target !kill_s2 — HOLD-FAIL no cookie-exit.
// Do not re-land. Leftover kill_s2 family closed.
// G1bx: leftover Branch-to-next-line does not raise bp_valid.
// G1by later-slot !bp_valid while dest valid — HOLD-FAIL
// wfi-exit t=217088 plat_hc=80. Do not re-land.
// G1bz leftover-complete later-slot !bp_valid — MINI-FAIL
// P3 0x39 @437. Do not re-land.
// G1ci leftover-complete later-slot Jump !bp_valid
// while leftover slot0 is unconsumed. Not G1bz (all CF,
// no consume gate). Not G1cb (keep_line). Not G1by.
// G1cj leftover-complete NoCF sequential-next I$ stash
// without g1bv_wait — HOLD-FAIL wfi-exit t=217088
// plat_hc=80. Do not re-land.
// G1ck leftover-NoCF sequential-next +8 hold —
// HOLD-FAIL no cookie-exit. Do not re-land. Leftover
// NPC stall family closed (G1cd/G1ce/G1ck).
// G1cl leftover-complete later slots after leftover-RVI
// Branch — MINI-FAIL P1 0x11 @442. Do not re-land.
// G1cm leftover-complete later-slot Jump only not
// presented (keep later ALU). Not G1cl all slots.
// G1cn one-cycle I$ req suppress after leftover-NoCF
// sequential next — MINI-FAIL P1 0x10 @386. Do not
// re-land.
// G1co leftover-complete next-line RVI Branch as
// cf=Branch — HOLD-FAIL no cookie-exit. Do not re-land.
// G1cp aligned NoCF dest holds different-line I$
// without a later Branch. Leftover still G1ca prefix.
// G1cq leftover-complete NoCF does not replay-kill
// I$ s1. Not G1bq kill_s2. Not G1cn req.
// G1cq kept (hygiene; mini still 0x69 @949; hold cookie
// t=79872). G1cr: mispredict to the registered I$ line
// (line-aligned target) does not drop that line. Not
// G1bb freeze. Not G1bd replay. G1cr kept (hygiene;
// mini still 0x69 @949; hold cookie t=79872).
// G1cs: do not +8 NPC until a line-aligned mispredict
// target is presented. Not G1cc leftover-Branch wait.
// Not G1cd/G1ce/G1ck leftover NPC stall. G1cs kept
// (hygiene; fired; mini still 0x69 @970; hold cookie
// t=75776).
// G1ct: first presented beat of that target is dest-only
// to IQ (hide later slots). Not G1cl/G1cm leftover hide.
// G1ct kept — P6 0x69 closed; mini P8 0x18 @2446; hold
// cookie t=96256.
// G1cu leftover-complete slot0 Jump arms G1cc —
// MINI-FAIL P8 0x18 @200727. Do not re-land.
// G1cv: leftover-complete slot0 Jump holds different-line
// I$. Not G1cu NPC. Not leftover NoCF (P6 0x4d0). G1cv
// kept (hygiene; mini still P8 0x18 @2446; hold cookie
// t=96256).
// G1cw: leftover-complete slot0 JAL is cf=Jump. Not
// G1co leftover NT beq. Not G1cu NPC. G1cw kept
// (hygiene; mini still P8 0x18 @2446; hold cookie
// t=96256).
// G1cx: leftover-complete slot0 Jump must push (G1az
// for pc[2:1]==11). Not G1bd target replay. Not G1cu.
// G1cx kept (hygiene; mini still P8 0x18 @2446; hold
// cookie t=96256).
// G1cy: leftover-complete slot0 Jump issues before
// later-slot fallthrough (id_stage insert; not G1be
// same-line). Not G1bi. Not G1cu NPC. G1cy kept
// (hygiene; mini still P8 0x18 @2446; hold cookie
// t=96256).
// G1cz: leftover-complete slot0 Jump is slot0-only
// to IQ (not G1cl leftover-Branch hide). Not G1cm
// later-slot Jump hide. Not G1ct mispredict dest-only.
// G1cz kept (hygiene; mini still P8 0x18 @2446; hold
// cookie t=96256).
// G1da: leftover-complete slot0 Jump restarts idx_is
// (first IQ push). Not G1cg all leftover. Not G1ch
// Branch-only. Not G1cz valid mask. G1da kept (fired;
// mini still P8 0x18 @2454; hold cookie t=96256).
// G1db leftover-complete slot0 Jump !+8 this beat —
// HOLD-FAIL no cookie-exit (past 6 min). Do not
// re-land (G1ce leftover +8 stall class).
// G1dc: leftover Jump in any dest FIFO is IQ head.
// Not G1cy ID insert. Not G1db NPC. Not G1bc empty-only.
// G1dc kept — mini PASS @2692 (P8 0x18 closed); hold
// cookie t=22528.
// G1do leftover jal cf=Jump any slot — hygiene; hold
// cookie t=22528 ra still 752. Did not fire.
// G1dp: leftover-complete slot0 Jump dest FIFO 0
// full drains FIFO 0 so jal can push. Not G1dc
// (already-in-FIFO). Not G1db NPC. Not G1cv
// accept-target I$. G1dp kept (hygiene; hold+nat
// cookie t=22528; ra still 752; 7c8 one beat).
// G1dq TRACE: 996 fetched @20314 then leftover
// 7c8 @20484; no @38e0.
// G1dr leftover link-jal-only IQ head —
// MINI-FAIL P8 0x18 @2454. Do not re-land.
// G1ds: leftover Jump IQ head is oldest PC
// (996 jal x0 vs jal@7c6). Not G1dr rd filter.
// G1ds kept (hygiene; 996 then 7c8 ~100 cy;
// not simultaneous).
// G1dt: leftover Jump through unresolved leftover
// Jump (issue_barrier). Not G1ax. Not G1dr.
// G1dt kept (hygiene).
// G1du: leftover-RVI capture survives replay
// kill_s2 (7c0 jal first half). Not G1cq. Not G1as.
// G1du kept (hygiene).
// G1dv: presented leftover Jump PC != G1dc FIFO
// leftover (996 vs jal@7c6). Drain dest FIFO 0.
// Not G1dr rd. Not G1ds (7c6 not in FIFO yet).
// G1dv kept (hygiene; 7c8 not leftover Jump).
// G1dw: leftover-pending, NPC at complete line,
// hold +8 until leftover-complete. Not G1ce.
// G1df: COLD_EXCL lifts on boot-hart WFI (not a lower
// 200000). Hart1 can start when hart0 cave-WFI.
// G1df kept (fired; cookie act=1 @308 ra1=0x10; mini PASS).
// G1dg: COLD_EXCL also lifts after DRAM+grace so hart1
// joins HSM before cave WFI. Not lower 200000.
// Not G1as leftover-complete address. Not G1aa leftover-JAL NPC.
// G1z IQ/decode keep through flush_if — NAT-FAIL 51b1c001 / sp1=0.
// G1aa leftover-JAL NPC/keep — MINI-FAIL P3 0x2f. Do not re-land.
// G1as leftover-next-line-only complete — HOLD-FAIL plat_hc=80. Do not re-land
// (that *dropped* leftover). G1av keeps leftover on a later fetch.
// G1at ALU-li alloc on flush_unissued — HOLD-FAIL wfi-exit 7204/6. Do not re-land.
// G1ax leftover-RVI CF skip unresolved_cf — HOLD-FAIL plat_hc=80. Do not re-land.
// G1ab NPC hold for presented Jump — MINI-FAIL P3 0x38. Do not re-land.
// G1ac IQ Jump park on bp_valid — HOLD-FAIL no cookie. Do not re-land.
// Timing: one extra cf_type compare on the existing resolve cone.

package g6lc_cf_unissued;
  import config_pkg::*;
  import ariane_pkg::*;

  function automatic logic flush(
      input cva6_cfg_t cfg,
      input logic      valid,
      input logic      is_mispredict,
      input logic      is_taken,
      input cf_t       cf_type
  );
    flush = (cfg.NrHarts > 1) && valid && !is_mispredict &&
            ((is_taken && cf_type == Jump) ||
             cf_type == Return ||
             cf_type == JumpR);
  endfunction

  // G1y: hold the fetch block until the predicted Jump is in the IQ.
  // G1aq: or until an older NoCF before a Branch is consumed.
  // G1au: or until leftover-RVI complete slot0 is in the IQ.
  function automatic logic keep_line(
      input cva6_cfg_t cfg,
      input logic      jump_unconsumed,
      input logic      prefix_unconsumed,
      input logic      leftover_unconsumed
  );
    keep_line = cfg.SuperscalarEn && cfg.NrHarts > 1 &&
                (jump_unconsumed || prefix_unconsumed || leftover_unconsumed);
  endfunction

endpackage
