# Soft-ladder extract (before G0)

**Standing increment** between I4cf and `COMPLETION.md` G0. Pull I4* *policy*
out of the pipeline into designated `core/smt/g6lc_*` modules. **No behavior
change** until G0.

Same I1–I6 loop as `README.md`. One extract per increment. Hold cookie
`51b1babe` only. Do not start I4cg. Do not land G0 in the same increment.

---

## Why extract first

`mini_fdt_a0_is_fdt` failed P9 (tohost=19) on slfix. G0 belongs in an
**issue barrier**, not another clause on the scoreboard keep soup. The soup
is duplicated (sequential cancel + `cancelled_mask`) in tier-U
`scoreboard.sv`. Extracting it:

- gives G0 a clean home (`g6lc_issue_barrier`) instead of a 15th keep;
- shrinks the interior delta in tier-U files (branding §3);
- matches U6.1 (`543cf4c35`, `025fedbdc`): new files under `core/smt/`.

---

## Binding rules

| Rule | Meaning |
|------|---------|
| **Bit-identical** | Same compares, same SI const-fold. Mini still FAIL 19; hold+nat still `51b1babe`+`51b1d000`. |
| **One extract family** | E0 was keep-only. E1–E3 combined (user) is still bit-identical — no G0. |
| **Home** | `core/smt/g6lc_*.sv`, CERN-OHL-S / GSys-Commercial. List in `Flist.cva6` SMT block (how U6.1 landed) **and** note in `Flist.g6lc`. |
| **Hook** | Caller becomes `if (!g6lc_sb_keep::keep(...))`. Do not rename `CVA6Cfg`. |
| **Hold-FAIL** | Revert the extract. |
| **G0** | Only after E0 (keep) is soaked. G0 is `COMPLETION.md` stage 1, not a keep clause. |

---

## Extract queue

| # | Module | Pull from | Status |
|---|--------|-----------|--------|
| **E0** | `g6lc_sb_keep` | I4m–cf keep predicate ×2 in `scoreboard.sv` | **soaked** |
| **E1** | `g6lc_issue_barrier` | unresolved CF/CSR/SP in `issue_stage.sv` | **soaked** with E2/E3 |
| **E2** | `g6lc_jalr_usable` | I4t/v in branch_unit / frontend / `bmiss` / BTB | **soaked** |
| **E2+** | `g6lc_jalr_usable` mid-line JumpR | G1gs / G1hf / G1hg (`pick_usable`, `mid_nbranch`, `mid_cjalr_branch`) | **soaked** bit-identical; lottery @558; FDT @2719; hold cookie t=83968; slfix `c5761fcc` / `b585325e`. Next E6/E7. G1he/G1ig stay dead |
| **E3** | `g6lc_cf_unissued` | I4x/bz/ce in `controller.sv` | **soaked** |
| **E4** | `g6lc_sib_cjalr` ID/SB | sibling `01` recover predicates (`g1lo`/`ln`/`lz`/`hx`/`hy`/`ik`/`id`/`ij`, SB G1mf) | **soaked** bit-identical; lottery @558; FDT @2719; hold cookie t=83968; slfix `8d0ee26d` / `27221419`. G1je/lk/lm/mg stay dead |
| **E4 FE** | extend `g6lc_sib_cjalr` | frontend LOAD capture/hit (`g1kk`/`g1le`/`g1lq`), +2 stash encodings (G1hj/jy), constructed `c.jalr` | **soaked** bit-identical; lottery @558; FDT @2719; hold cookie t=83968; slfix `9aa3360c` / `8fe2d083`. Next E9. G1jj/jw stay dead |
| **E5** | `g6lc_rvc_enc` | exact `c.jalr` / C1-li mash (`g1fr_is_jalr`, decoder G1ba/G1gu) | **soaked** bit-identical; lottery PASS @558; FDT PASS @2719; hold cookie t=83968 `51b1babe`+`51b1d000`+BANR; slfix `86ee035b` / `20f7f886`. Next E2+ |
| **E6** | `g6lc_fe_keep` | registered-I$ hold predicates (`g1cv`/`ek`/`el`/`ep`/`ex`/`ez`/`fa`/`ic`/`jm`/`bl`/`cr`) | **soaked** bit-identical; lottery @558; FDT @2719; hold cookie t=83968; slfix `6f90de0f` / `4412d136`. Next E7. G1bb/G1in stay dead |
| **E7** | `g6lc_fe_kill` | `kill_s1`/`kill_s2` spare predicates (`g1hv`/`g1jq`/`g1jt`/`g1jn`/`g1ix`/`g1jo`) | **soaked** bit-identical; lottery @558; FDT @2719; hold cookie t=83968; slfix `c162608c` / `b7faf8e8`. Next E8. G1jp/jr/js/hu/iy stay dead |
| **E8** | `g6lc_iq_hide` | IQ hide / slot1 keep (`g1fo`/`g1en`/`g1er`/`g1fs`) | **soaked** bit-identical; lottery @558; FDT @2719; hold cookie t=83968; slfix `e87ba20c` / `e673a237`. Next E4. G1fb/fc/fk/fm stay dead |
| **E9** | `g6lc_present` | present-at-npc / mid-line 16-bit (`g1gx`/`g1fu`/`g1ha`; realign G1bf/eu/ed) | **soaked** bit-identical; lottery @558; FDT @2719; hold cookie t=83968; slfix `e396f136` / `47c636b1`. G1gz/es/bo/fx/fz stay dead |
| **leftover** | `g6lc_leftover` | leftover-RVI classify / next-line / serving / G1cm later Jump (thin wrapper) | **soaked** bit-identical; lottery @558; FDT @2719; hold cookie t=83968; slfix `7af3e3c8` / `2707526e`. FSM stays in realign. G1as/dy stay dead |
| **jal-x0 squash** | `g6lc_lj_hide` + leftover skip-arm | leftover jal x0 after taken skip (`mini_sib_cjalr` P2 / 766). G1hc/hh npc 01; G1hm Jump-only slot1 inject | **soaked**; mini P0–P2 @431; P3 @518; P4 @597. skip-range latch HOLD-FAIL. Off-line leftover-PC replay block **kept**. leftover_blocks_01 + G1hj consume-PC-match **hygiene**. G1hj/jy is_mispredict spare **hygiene**. stash_keep16 **hygiene**. stash_keep_pc **hygiene**. load_flush_keep **hygiene**. plus2_stay + line_hi8_stay **hygiene**. idle_sib16 / idle_load_sib HOLD-FAIL (G1jw). sib8_fetch / hi8_npc_fetch MINI-FAIL. lo11_npc00 MINI-FAIL sib P0 fail 1 @407 / FDT 0x10 @423 (jalr-target `[2:1]==11`). lo_pc_npc00 HOLD-FAIL plat_hc=80 mepc 0xb0/2. ljx0_off / ljx0_pc / ljx0_bp **hygiene**. sib_lo_s2 MINI-FAIL G1jp. lo_ld_stay HOLD-FAIL 51b1c001. lo_ld_lo11 **hygiene**. hi8_lo11 MINI-FAIL FDT 57 @445 (G1jd). load_flush_next16 **hygiene**. ld_until_01 MINI-FAIL FDT 106 @409 (G1lm). leftover_off_npc00 **hygiene**. leftover_slot0_off_npc00 MINI-FAIL sib printed 4 @448 / lottery hang @400000 / FDT 17 @413 — reverted. load00_vs_off16 **hygiene**. leftover_nx8_npc00 **hygiene**. leftover_hi8_s2 MINI-FAIL FDT 24 @201516 (G1hu) — reverted. load00_vs_lj **hygiene**. leftover_lo8_s2 **hygiene**. load00_lo8_s2 **hygiene** (7b0 not a valid same-8B LOAD return at n7b0). hangj 766 still bp_valid. slfix `2db4dea7` / `f5f908e4`. G1mg not next |
| **g1gi–gm peel** | extend `g6lc_lj_hide` | G1gi jalr-in-flight hide, G1gj npc 01, G1gk 01-hold, G1gl/gm leftover-PC replay block | **soaked** bit-identical; mini @431; lottery @558; FDT @2719; hold+nat+peel cookie t=83968; slfix `7e280d82` / `a0d82504`. Scan loop + apply mux stay in frontend. G1gn stay dead |
| **G0** | small-nz stall + LOAD/STORE drop-fwd | page-0 non-zero address-use | **HOLD-FAIL** — **reverted** |
| **G1** | `g6lc_sb_keep` callee-saved class | sp-based s0–s11/ra | **soaked** hold+nat green; peel `129f8`/4/9; mini 19. Restored after W1 revert (`ca1012be` / `71c500f1`). |
| **G1b** | `g6lc_sb_keep` `c.mv a0,s*` | restore class (a0←s0 in offset_ptr_raw) | **soaked** hold+nat green; peel `129f8`/4/9; mini 19. Keep. |
| **G6** | call-nest quantum/starve suppress | `g6lc_issue_barrier` + `g6lc_thread_select` | **HOLD-FAIL** — **reverted** (mepc=`0xa9c8` mcause=2) |
| **G1c** | `g6lc_sb_keep` `c.mv s*,a0` | save class (s0←a0 in offset_ptr_raw) | **soaked** hold+nat green; peel `129f8`/4/9; mini 19. Keep. |
| **G1d** | `g6lc_sb_keep` `addi sp,sp,*` | frame adjust (`rd==x2 && rs1==x2`) | **soaked** hold+nat green; peel `129f8`/4/9; mini 19. Keep. |
| **G1e** | `g6lc_sb_keep` arg self-add | `c.add a1,a5` / `c.addiw a5` (P3) | **soaked** hold+nat green; peel `129f8`/4/9; mini still P3=19. Keep. |
| **G1f** | `g6lc_sb_keep` `c.mv a*,a0` | arg←a0 (`mv a5,a0` in offset_ptr) | **soaked** hold+nat green; peel `129f8`/4/9; mini still P3=19. Keep. |
| **G1g** | `g6lc_sb_keep` ALU `rd==a0` | BE `or a0,t0,t1` | **soaked** hold+nat green; peel `129f8`/4/9; mini still P3=19. Keep. |
| **G1h** | IRO drop exec-base fwd on `c.mv a0↔s*` | `s0` was boot `0x80000000` | **soaked** hold+nat green; peel `129f8`/4/9; mini still `0x32`. Keep (hygiene). RF `a0` is also boot at the `c.mv` — drop did not change s0. |
| **G1i** | stall `c.mv s*,a0` while a0 in-flight | `unresolved_a0_q` | **HOLD-FAIL** — reverted (`mepc1=0x75a` mcause=4). Do not re-land. |
| **G1j** | I4ao only byte-unaligned s0 | `result[2:0]!=0` | **soaked** hold+nat green; peel `129f8`/4/9; mini left `0x39` (offset_ptr now returns). Keep. |
| **G1k** | IRO LOAD cached-RF vs non-cached fwd | P4 `c.lw` a5=0x010dfeec | **soaked** hold+nat green; peel `129f8`/4/9; mini still P4 dump 8847222 @200649. Keep (hygiene). Address forward is not this write. |
| **G1l** | `load_unit` ghost `rvalid` needs live ldbuf | leftover D$ rid | **soaked** hold+nat green; peel `129f8`/4/9; mini still 8847222 @200649. Keep. Slot was live — not a free-rid ghost. |
| **G1m** | STQ interlock only if live load | `load_paddr_valid=valid_i` | **soaked** hold+nat green; peel `129f8`/4/9; mini still 8847222 @200649. Keep. 200k is not a false STQ stall. |
| **G1n** | smt2 `DcacheIdWidth=3` | hang-7 ldbuf=8 rid truncate | **soaked** hold+nat green; peel `129f8`/4/9. Isolated P4 (no 2nd `offset_ptr`) **green @1161**. Keep (completes hang-7). 200k leftover was the 2nd `offset_ptr`, not rid width. |
| **G1o** | IRO stall STORE ra while jal issued | P6 `0x65` stale ra=`0x14c` | **soaked** hold+nat green; peel `129f8`/4/9; mini still `0x65` @956 (`0x68` passed — slot==RF). Jal not `still_issued`. Keep (hygiene). |
| **G1p** | IRO hold EX PC; acked CF only | jal `next_pc=4` + I4as | **soaked** hold+nat green; peel `129f8`/4/9; mini still `0x65` @956. Not a zeroed PC. Keep (hygiene). |
| **G1q** | I4as skip CTRL_FLOW rd==ra | page-0 jal result drop | **soaked** hold+nat green cookie-exit t=204800; peel `129f8`/4/9; mini still `0x65` @1008. Not I4as. Keep (hygiene). |
| **G1r** | per-instr CF PC (`operand_c`) | P6 jal retired P5 `0x14c` | **soaked** hold+nat green cookie-exit t=204800; peel `129f8`/4/9; mini still `0x65` @1008. Not a shared-PC write. Keep (hygiene). |
| **G1s** | cancelled link-jal still retires ra | P6 `0x65` commit_drop | **soaked** hold+nat green cookie-exit t=204800; peel `129f8`/4/9; mini still `0x65` @1008. Not a cancelled commit. Keep (hygiene). |
| **G1t** | link-jal alloc despite `flush_unissued` | jal popped, no SB slot | **soaked** hold+nat green cookie-exit t=204800; peel `129f8`/4/9; mini still `0x65` @1008. Not this hole. Keep (hygiene). |
| **G1u** | flu mux pairs with branch port | jal WB stolen / wrong tid | **soaked** hold+nat green cookie-exit t=204800; peel `129f8`/4/9; mini still `0x65` @1008. Not flu steal. Keep (hygiene). |
| **G1v** | issue-time jal link (`pc+ilen`) | sbe.result stays J-imm | **soaked** hold+nat green cookie-exit t=204800; peel `129f8`/4/9; mini still `0x65` @1008. Flu replaced it or jal never committed that result. Keep (hygiene). |
| **G1w** | flu does not replace alloc-time link | flu wrote P5 `0x14c` | **soaked** hold+nat green cookie-exit t=204800; peel `129f8`/4/9; mini still `0x65` @1008. Not a flu overwrite of a live alloc link. Keep (hygiene). |
| **G1x** | link-jal valid at alloc | jal never retired | **soaked** hold cookie green; nat cookie-exit `51b1babe`; peel `129f8`/4/9; mini still `0x65` @1008. Jal was not an invalid SB slot. Keep (hygiene). |
| **G1y** | keep I$ line until Jump consumed | `bp_valid` dropped jal+`li t2` | **soaked** hold+nat green cookie-exit t=204800; peel `129f8`/4/9; mini still `0x65` @1008. Not this I$ kill. Keep (hygiene). |
| **G1z** | IQ/decode keep Jump through `flush_if` | jal flushed before issue | **NAT-FAIL** `51b1c001` / hart1 `sp=0` (hold still cookie). Mini still `0x65` @1008. Reverted. Do not re-land. |
| **G1aa** | leftover-JAL NPC + keep through `kill_s2` | leftover jal @`0x2be` never presented | **MINI-FAIL** P3 `0x2f` @590 (`offset_ptr` → `fdt+8`). Reverted. Do not re-land. |
| **G1ab** | NPC hold only for presented `cf==Jump` | `bp_valid` stole NPC before consume | **MINI-FAIL** P3 `0x38` @545 (`s0==boot`). Reverted. NPC-delay family closed. Do not re-land. |
| **G1ac** | IQ head Jump park on `bp_valid` | consumed jal never reached ID | **HOLD-FAIL** no cookie `[1000]=80008cb6` hart1 `8cb6`/4. Mini still `0x65`. Reverted. Do not re-land. |
| **G1ad** | align P6 jal (mini only) | leftover straddle @`0x2be` | **landed.** Mini still `0x65` @1021. Jal @`0x2c4` complete. Leftover not the hole. Keep. |
| **G1ae** | G1o also `sbe.valid` (cancelled jal) | `sd ra` before cancelled jal commit | **soaked** hold cookie t=202752; mini still `0x65` @1021 (same cy). Not a live SB jal at `sd`. Keep (hygiene). |
| **G1af** | SMT+SS STQ fwd only from commit queue | `0x68` spec-fwd then DRAM P5 `0x14c` | **HOLD-FAIL** `51b1c001` @6e6 hart1 `8df0`/4. Mini still `0x65` @1021. Reverted. Do not re-land. |
| **G1ag** | stall STORE ra while older link-jal in ID | jal unissued at `sd ra` | **soaked** hold cookie t=202752; mini still `0x65` @1021. Jal not in ID. Keep (hygiene). |
| **G1ah** | spec STQ `fwd_keep` after forward | `0x68` fwd then DRAM `0x14c` | **soaked** hold cookie t=202752; mini still `0x65` @1021. Not squash-after-fwd. Keep. |
| **G1ai** | STORE ra waits for `addi sp` | `sd` fetch `sp=0x80008000` | **soaked** hold cookie t=202752; mini still `0x65` @1021. `addi` not in SB at `sd`. Keep. |
| **G1aj** | LOAD rd==ra waits any STORE rs2==ra | `0x68` `0x2c8`; epi `0x14c` | **HOLD-FAIL** `51b1c001` @6e6 hart1 `8df0`/4. Mini still `0x65` @1021. Reverted. Do not re-land. |
| **G1ak** | LOAD ra waits older STORE ra only | same as G1aj + `pc` order | **HOLD-FAIL** `51b1c001` @6e6 hart1 `8df0`/4. Mini still `0x65` @1021. Reverted. Family closed. Do not re-land. |
| **G1al** | STORE ra waits older ID addi sp | t=877 `sd` NPC `sp=0x80008000` | **soaked** hold cookie t=202752; mini still `0x65` @1021. `addi` not in ID. Keep. |
| **G1am** | mini 2nd load of `8(sp)` | `0x68` `0x2c8`; epi `0x14c` | **landed.** Mini **`0x69` @953**. `t1=0x2c8`; `t3` stuck `0xed`. `0x68` false pass. Keep. |
| **G1an** | cancelled-valid LOAD dest → RF | `c.ldsp t3` leaves `0xed` | **soaked** hold cookie t=202752; mini still `0x69` @953. Not cancelled-valid. Keep. |
| **G1ao** | STQ last-forward hold / replay | `t1=0x2c8`; `t3=0xed` | **soaked** hold cookie t=202752; mini still `0x69` @953. Not a drained-STQ miss. Keep. |
| **G1ap** | 2-deep LSU ready (`status_cnt<2`) | NPC `0x4d0`; dest stuck `0xed` | **MINI-HANG** 400000 cy tohost=0. Reverted. Do not re-land. |
| **G1aq** | keep line: older NoCF before Branch | same line `0x4d0`/`0x4d2` | **soaked** hold cookie t=202752; mini still `0x69` @953. Keep. |
| **G1ar** | TRACE t3 RF write; poison `li t3,-1` | `t3` stuck `0xed` | **landed.** Mini `0x69` @954. `c.li t3,-1` never wrote. Keep. |
| **G1as** | leftover-RVI must not eat next-line 16-bit | `beq@0x4c6` straddle; `0x4d0` `c.li` | **HOLD-FAIL** `plat_hc=80` bootrom `0x10050`. Mini still `0x69` @953. Reverted. Do not re-land. I4ae any-later stays. |
| **G1at** | fetched `c.li t3` @`0x4d0` must issue | NPC `0x4d0`; `t3` stays `0xed` | **HOLD-FAIL** wfi-exit `7204`/6 hart1 `sp=0`. Mini still `0x69` @954 (`c.li` never in ID). Reverted. Do not re-land. |
| **G1au** | keep leftover-RVI complete slot0 until IQ | NPC `0x4d0`; `t3` stays `0xed` | **soaked** hold cookie t=202752; mini still `0x69` @954. Keep (hygiene). |
| **G1av** | leftover complete only from next line; keep leftover | `beq@0x4c6`; `0x4d0` `c.li` | **soaked** hold cookie t=202752; mini still `0x69` @954. Keep (hygiene). Not G1as drop. |
| **G1aw** | `serving_unaligned` only on leftover complete beat | stale leftover flags `0x4d0` | **soaked** hold cookie t=202752; mini still `0x69` @954. Keep (hygiene). |
| **G1ax** | leftover-RVI Branch must not stall taken-target prefix | `0x4d0`→`0x4e0`; `t3`=`0xed` | **HOLD-FAIL** `plat_hc=80` mepc `0x2cc8`/6. Mini still `0x69` @953. Reverted. Do not re-land. |
| **G1ay** | issue older NoCF before same-line taken Branch | `beq@0x4d4` before `c.li` | **soaked** hold cookie t=202752; mini still `0x69` @954. Keep (hygiene). |
| **G1az** | IQ push slot0 of new 8B line after leftover complete | NPC `0x4d0`; `c.li` not in ID | **soaked** hold cookie t=202752; mini still `0x69` @954. Keep (hygiene). |
| **G1ba** | leftover mash `{c.li, branch_lo}` expands as ALU rd=x28 | `5e7d`; `t3` stays `0xed` | **soaked** hold cookie t=202752; mini still `0x69` @952. Mash never presented. Keep (hygiene). |
| **G1bb** | hold registered I$ data while `keep_line` | `0x4d0` overwritten by `0x4e0` | **HOLD-FAIL** `plat_hc=80` mepc `0x12640`/2. Mini still `0x69` @949. Reverted. Do not re-land. |
| **G1bc** | skip empty IQ head to present pushed slot0 | NPC `0x4d0`; `t3` stays `0xed` | **soaked** hold cookie t=202752; mini still `0x69` @952. Keep (hygiene). |
| **G1bd** | replay leftover-RVI taken target if slot0 missing | `beq@0x4c6` taken → `0x4d0` | **HOLD-FAIL** mepc `0x7b0`/4 no cookie @6e6. Mini still `0x69` @953. Reverted. Do not re-land. |
| **G1be** | ID insert older same-line NoCF before Branch | NPC `0x4d0`; `t3` stays `0xed` | **soaked** hold cookie t=202752; mini still `0x69` @952. Insert did not fire. Keep (hygiene). |
| **G1bf** | leftover-pending aligned slot0 is 16-bit at `address_i` | NPC `0x4d0`; `t3` stays `0xed` | **soaked** hold cookie t=202752; mini still `0x69` @952. Keep (hygiene). |
| **G1bg** | same-line NoCF dest must retire across later Branch mispredict | `c.li@0x4d0` vs `beq@0x4d4` | **soaked** hold cookie t=202752; mini still `0x69` @952. Never issued. Keep (hygiene). |
| **G1bh** | issue older same-line NoCF dest through `unresolved_cf` | `beq` issued; `c.li` at issue | **soaked** hold cookie t=202752; mini still `0x69` @952. Never at issue. Keep (hygiene). |
| **G1bi** | IQ deliver aligned slot0 NoCF dest to ID before Branch consume | NPC `0x4d0`→`0x4e0`; `t3`=`0xed` | **HOLD-FAIL** wfi-exit t=217088 cookie `51b1c001` mepc `0xb5c8`/4. Mini still `0x69` @952. Reverted. Do not re-land. |
| **G1bj** | aligned slot0 CF class is the 16-bit at that PC | leftover mash tags slot0 Branch | **soaked** hold cookie t=202752; mini still `0x69` @952. Mash never presented. Keep (hygiene). |
| **G1bk** | first valid beat must push aligned slot0 NoCF before `bp_valid` overwrite | NPC `0x4d0`→`0x4e0`; `t3`=`0xed` | **HOLD-FAIL** no cookie-exit (soak past t=202752). Mini still `0x69` @952. Reverted. Do not re-land. |
| **G1bl** | no different-line I$ return while aligned slot0 NoCF unconsumed | `keep_line` valid; data overwritten by `0x4e0` | **soaked** hold cookie t=202752; mini still `0x69` @952. Did not fire. Keep (hygiene). |
| **G1bm** | IQ `consumed_o[0]` is architectural slot0 push | rotated consume marks slot0 done | **soaked** hold cookie t=202752; mini still `0x69` @952. Rotate already matched. Keep (hygiene). |
| **G1bn** | IQ flush on `bp_valid` keeps just-pushed aligned slot0 NoCF | `c.li` pushed then flushed | **MINI-FAIL** P3 `0x2a` @588 (`offset_ptr` NULL). Reverted. Do not re-land. |
| **G1bo** | aligned slot0 NoCF valid on the registered I$ beat | `valid[0]`=0 so G1bl never fired | **MINI-FAIL** P1 `0x10` @384 (first `load_be32`). Reverted. Do not re-land. |
| **G1bp** | `keep_line`/`G1bl` prefix is any aligned NoCF dest slot | leftover complete occupies slot0 | **soaked** hold cookie t=202752; mini still `0x69` @952. Did not fire (`0x4d0` never registered). Keep. |
| **G1bq** | leftover-RVI complete must not `kill_s2` taken-target fetch | NPC `0x4d0`→`0x4e0`; line never registered | **HOLD-FAIL** no cookie-exit (past 90s). Mini still `0x69` @960. Reverted. Do not re-land. |
| **G1br** | later-slot Branch not predicted while older same-line NoCF dest unconsumed | `beq@0x4d4` `bp_valid` before `c.li` queues | **HOLD-FAIL** non-converge rc=255 (combo loop `is_branch`→IQ consume). Mini still `0x69` @952. Reverted. Do not re-land. |
| **G1bs** | later-slot Branch not predicted while older same-line dest is valid | `c.li` consumed same beat `beq` predicts | **HOLD-FAIL** no cookie-exit (past 90s). Mini still `0x69` @952. Reverted. Do not re-land. Later-slot `is_branch` family closed. |
| **G1bt** | leftover taken Branch to next 8B line must not `kill_s2` that fetch | leftover `beq@0x4c6` kills `0x4d0` | **HOLD-FAIL** no cookie-exit (past 90s). Mini still `0x69` @952. Reverted. Do not re-land. Leftover `kill_s2` family closed. |
| **G1bu** | after leftover-complete taken Branch, reject non-target I$ returns | `0x4e0` registers before `0x4d0` | **HOLD-FAIL** no cookie-exit (past 90s). Mini still `0x69` @952. Reverted. Do not re-land. I$ barrier family closed. |
| **G1bv** | stash leftover-Branch target I$ return; present after leftover drops | `0x4d0` overwritten / never registered | **soaked** hold cookie t=202752; mini still `0x69` @952. Did not fire (`0x4d0` return never valid). Keep. |
| **G1bw** | spare `kill_s2` only if s2 is leftover-Branch target | `0x4d0` s2 killed; stash empty | **HOLD-FAIL** no cookie-exit (past 90s). Mini still `0x69` @952. Reverted. Do not re-land. Leftover `kill_s2` family closed. |
| **G1bx** | leftover-complete Branch to next 8B line is not `bp_valid` | leftover `beq@0x4c6` kills `0x4d0` | **soaked** hold cookie t=98304; mini still `0x69` @952. Did not fire (`0x4d0`→`0x4e0` is later `beq@0x4d4`). Keep. |
| **G1by** | later-slot Branch not `bp_valid` while older dest valid | `beq@0x4d4` before `c.li` queues | **HOLD-FAIL** wfi-exit t=217088 `plat_hc=80`. Mini still `0x69` @952. Reverted. Do not re-land. Later-slot `bp_valid`/`is_branch` family closed. |
| **G1bz** | leftover-complete later-slot CF is not `bp_valid` | leftover `c.j@0x4ce` kills `0x4d0` | **MINI-FAIL** P3 `0x39` @437 (`s0!=a0`). Reverted. Do not re-land. Leftover later-slot CF `bp_valid` family closed. |
| **G1ca** | prefix hold is dest-before-Branch only (drop G1bp any-slot OR) | leftover Branch then dest `g1bl` rejects `0x4d0` | **soaked** hold cookie t=98304; mini still `0x69` @952. Did not fire (`0x4d0` never registered). Keep. |
| **G1cb** | leftover-complete later-slot Jump is not `jump_unconsumed` | leftover `c.j` keep blocked `0x4d0` | **soaked** hold cookie t=98304; mini still `0x69` @952. Did not fire (`0x4d0` never registered). Keep. |
| **G1cc** | do not +8 NPC while leftover-Branch target (`g1bv_wait`) is not presented | `0x4c8`→`0x4d0`→`0x4e0` skips fill | **soaked** hold cookie t=98304; mini still `0x69` @952. Did not fire (`g1bv_wait` not armed). Keep. |
| **G1cd** | hold NPC on leftover-Branch `g1bv_arm` same cycle (G1cc wait is late) | arm-beat +8 skips `0x4d0` | **HOLD-FAIL** no cookie-exit (past 6 min). Mini still `0x69` @952. Reverted. Do not re-land. |
| **G1ce** | one-cycle +8 stall on leftover-complete (`serving_unaligned`) | leftover NT sequential skips `0x4d0` | **HOLD-FAIL** no cookie-exit (past 3 min). Mini still `0x69` @963. Reverted. Do not re-land. Leftover-complete NPC stall family closed (G1cd/G1ce). |
| **G1cf** | one-cycle I$ re-request of leftover-complete next line (vaddr only) | leftover-next never requested | **MINI-FAIL** P1 `0x10` @406 (first `load_be32`). Reverted. Do not re-land. |
| **G1cg** | leftover-complete consume restarts IQ `idx_is` so next aligned slot0 is FIFO 0 | leftover rotate puts `beq` before `c.li` | **MINI-FAIL** P1 `0x10` @384 (first `load_be32`). Reverted. Do not re-land. |
| **G1ch** | leftover-complete Branch-only IQ `idx_is` restart | leftover-Branch rotate puts `beq` before `c.li` | **HOLD-FAIL** no cookie-exit (past 3 min). Mini still `0x69` @952. Reverted. Do not re-land. Leftover `idx_is` restart family closed (G1cg/G1ch). |
| **G1ci** | leftover-complete later-slot Jump !bp_valid while leftover slot0 unconsumed | leftover `c.j@0x4ce` kills `0x4d0` | **soaked** hold cookie t=98304; mini still `0x69` @952. TRACE still `0x4d0`→`0x4e0` (sequential +8, not `c.j`). Keep. |
| **G1cj** | leftover-complete NoCF sequential-next I$ stash without `g1bv_wait` | `0x4d0` return never presented | **HOLD-FAIL** wfi-exit t=217088 `plat_hc=80`. Mini still `0x69` @952. Reverted. Do not re-land. |
| **G1ck** | do not +8 while leftover-complete NoCF NPC is already the next 8B line | `0x4d0` I$ replaced by `0x4e0` | **HOLD-FAIL** no cookie-exit (past 10 min). Mini still `0x69` @964. Reverted. Do not re-land. Leftover NPC stall family closed (G1cd/G1ce/G1ck). |
| **G1cl** | leftover-complete later slots after leftover-RVI Branch not presented | leftover `c.j` steals `0x4d0` | **MINI-FAIL** P1 `0x11` @442. Reverted. Do not re-land. |
| **G1cm** | leftover-complete later-slot Jump only not presented (keep later ALU) | leftover `c.j@0x4ce` steals `0x4d0` | **soaked** hold cookie t=83968; mini still `0x69` @949. Keep. |
| **G1cn** | one-cycle I$ req suppress after leftover-NoCF sequential next | `0x4e0` request replaces `0x4d0` s2 | **MINI-FAIL** P1 `0x10` @386. Reverted. Do not re-land. |
| **G1co** | leftover-complete next-line RVI Branch is `cf=Branch` even if static NT | leftover NT `beq` never a Branch in IQ | **HOLD-FAIL** no cookie-exit (past 10 min). Mini still `0x69` @940. Reverted. Do not re-land. |
| **G1cp** | aligned NoCF dest holds different-line I$ without a later Branch | second-pass `0x4d0` overwritten before `c.li` | **soaked** hold cookie t=83968; mini still `0x69` @949. Did not fire (`0x4d0` never registered). Keep. |
| **G1cq** | leftover-complete NoCF does not replay-kill I$ s1 | leftover IQ overflow kills `0x4d0` fill | **soaked** hold cookie t=79872; mini still `0x69` @949. Did not fire. Keep. |
| **G1cr** | mispredict to the registered I$ line (line-aligned target) does not drop that line | leftover taken resolve kills held `0x4d0` `c.li` | **soaked** hold cookie t=79872; mini still `0x69` @949. Did not fire (`0x4d0` not registered at resolve). Keep. |
| **G1cs** | do not +8 NPC until a line-aligned mispredict target is presented | mispredict reseed +8 skips the `0x4d0` fill | **soaked** hold cookie t=75776; mini still `0x69` @970. Fired (+21 cy); line presented, `c.li` still never writes. Keep. |
| **G1ct** | first presented beat of line-aligned mispredict target is dest-only to IQ | later-slot `beq@0x4d4` shared the one-cycle packet | **soaked** hold cookie t=96256; **P6 `0x69` closed.** Mini **P8 `0x18`** @2446. Keep. |
| **G1cu** | leftover-complete slot0 Jump arms G1cc +8 hold | leftover `jal@0x3f6` sequential-skips `check_node` | **MINI-FAIL** P8 `0x18` @200727. Reverted. Do not re-land. |
| **G1cv** | leftover-complete slot0 Jump holds different-line I$ | `0x400` overwrites leftover `jal@0x3f6` | **soaked** hold cookie t=96256; mini still P8 `0x18` @2446. Did not fire. Keep. |
| **G1cw** | leftover-complete slot0 jal is `cf=Jump` | leftover `jal` mash is NoCF so G1cv never arms | **soaked** hold cookie t=96256; mini still P8 `0x18` @2446. Did not fire (jal already Jump). Keep. |
| **G1cx** | leftover-complete slot0 Jump G1az block/replay (`pc[2:1]==11`) | later-slot push + `addr[shamt]` drops leftover `jal` | **soaked** hold cookie t=96256; mini still P8 `0x18` @2446. Did not fire. Keep. |
| **G1cy** | leftover-complete slot0 Jump must issue before later-slot fallthrough | leftover `jal` behind `li`/`bne` at `0x3fa` | **soaked** hold cookie t=96256; mini still P8 `0x18` @2446. Did not fire (jal not at fetch[0]). Keep. |
| **G1cz** | leftover-complete slot0 Jump is slot0-only to IQ | later-slot `li`/`bne` enter IQ on the leftover-Jump complete beat | **soaked** hold cookie t=96256; mini still P8 `0x18` @2446. TRACE unchanged. Keep. |
| **G1da** | leftover-complete slot0 Jump restarts `idx_is` | leftover `jal` valid but `idx_is` points past slot0 | **soaked** hold cookie t=96256; mini still P8 `0x18` @2454. Fired (+8 cy; later NPC `0x3fa`). Keep. |
| **G1db** | leftover-complete slot0 Jump does not +8 NPC this beat | leftover `jal` predict overwritten by sequential +8 | **HOLD-FAIL** no cookie-exit (past 6 min). Mini still P8 `0x18` @2454. Reverted. Do not re-land. |
| **G1dc** | leftover Jump in any dest FIFO is IQ head | leftover `jal` sits behind `idx_ds` and never issues | **soaked** hold cookie t=22528; mini **PASS @2692**. P8 `0x18` **closed**. Keep. |
| **G1dd** | PEEL leftover `c.lw` after mini green | PEEL `129f8/4/9` | **PEEL cookie-exit** t=22528 `51b1babe`+`51b1d000`. Pin `129f8` gone. Soft getprop stays (`plat_hc=80`). Keep. |
| **G1de** | second hart / `plat_hc` after PEEL cookie | `plat_hc=80` `sp1=0` at cookie | **TB `COOKIE_EXIT=0` honored.** Cookie is inside `SMT_COLD_EXCL=200000`. At 250k hart1 `@2e8` `sp1=0`. Keep. |
| **G1df** | COLD_EXCL lifts on boot-hart WFI | hart1 idle until 200k after cave WFI | **soaked** hold+PEEL cookie t=22528; `act=1` `@308` `ra1=0x10`. Mini PASS. Keep. |
| **G1dg** | COLD_EXCL also lifts after DRAM+grace | hart1 too late for HSM at cave | **MINI-FAIL** @1399 leftover a0 `0xd00dfeec`/`0xd00dfeed`. Reverted. Do not re-land. |
| **G1dh** | nat / HSM after G1df WFI-lift; not DRAM+grace | cookie `sp1=0` `plat_hc=80`; hold HSM stubbed | **soaked** nat cookie t=22528; `COOKIE=0` 100k still `plat_hc=80` hart1 `@2f0` `sp=0`. Keep. |
| **G1di** | late reset-vector must not re-run the lottery | `_boot_status` 2→1 at G1df WFI-lift | **soaked** hold+nat+peel cookie t=22528; status stays 2. Keep. |
| **G1dj** | `sbi_init` cave-WFI before HSM / `plat_hc==2` | cookie via hang-fallthrough; `coldboot_done=0` | **TRACE.** Isolated jalr+bnez **PASS**. Keep. |
| **G1dk** | OpenSBI lottery `bnez@752` must take (`a0=1`) | thought `752` skipped | **TRACE** `@7a2` taken; hang is `7bc`. Grown mini PASS. Keep. |
| **G1dl** | lottery tail `7bc` hang before `coldboot_done` | thought `7bc`; actually `7c0`/`jal scratch_init` | **TRACE.** No `@38e0`. Leftover-jal mini PASS. Keep. |
| **G1dm** | `jal scratch_init` must run (`hart_count` / target) | `7c8` `ra=752`; no `@38e0`/`7ca` | **TRACE.** Far leftover-jal mini PASS. Keep. |
| **G1dn** | leftover RVI jal opcode is IQ head if cf mash | `7c8` `ra=752` | **soaked** hold+nat cookie; `ra` still `752`. Did not fire. Keep. |
| **G1do** | leftover `jal@7c6` must issue / fetch `0x38e0` | after G1dn still `ra=752` | **soaked** hold+nat cookie t=22528; `ra` still `752`. Did not fire. Keep. |
| **G1dp** | leftover Jump dest FIFO 0 full drains FIFO 0 | jal never entered dest FIFO | **soaked** hold+nat cookie t=22528; `ra` still `752`. TRACE `7c0`/`7c8` one beat, no `@38e0`. Did not fire. Keep. |
| **G1dq** | leftover jal consume-to-hang (commit/`38e0`/cave) | `7c8` one beat then gone; no `@38e0` | **TRACE.** `996` fetched @20314 then leftover `7c8` @20484; no `@38e0`. Keep. |
| **G1dr** | leftover link-jal is IQ head (not jal x0) | `996` jal x0 parked G1dc | **MINI-FAIL** P8 `0x18` @2454. Reverted. Do not re-land. |
| **G1ds** | leftover Jump IQ head is oldest PC | `996` vs `jal@7c6` first-FIFO | **soaked** hold+nat cookie t=22528; `ra` still `752`. `996` then `7c8` ~100 cy later. Did not fire. Keep. |
| **G1dt** | leftover Jump through unresolved leftover Jump | `996` may stick `unresolved_cf` | **soaked** hold+nat cookie t=22528; `ra` still `752`. No `@38e0`. Did not fire. Keep. |
| **G1du** | leftover-RVI capture survives replay `kill_s2` | `7c0` jal first half lost | **soaked** hold+nat cookie t=22528; `ra` still `752`. No `@38e0`. Did not fire. Keep. |
| **G1dv** | presented leftover Jump PC ≠ G1dc FIFO leftover | `996` parks IQ; `jal@7c6` never pushes | **soaked** hold+nat cookie t=22528; `ra` still `752`. No `@38e0`. Did not fire. Keep. |
| **G1dw** | leftover-pending hold +8 at complete line | NPC +8 skips leftover-complete I$ | **HOLD-FAIL** no cookie, illegal `@780`, hang `@2d38`. Reverted. |
| **G1dx** | C\|I\|U leftover keep through replay (`valid[3]=0`) | G1du never armed on `7c0` | **soaked** hold+nat cookie t=22528; `ra` still `752`. No `@38e0`. Did not fire. Keep. |
| **G1dy** | leftover-RVI capture beat outranks `kill_s2` | G1dx replay-only; flop never lands | **MINI-FAIL** printed 23 @1134. Reverted. |
| **G1dz** | CSR rdata mux by commit hart (not fetch-active) | hart0 `csrr mhartid` → `a0=1` | **soaked** hold+nat cookie t=22528; `a0=1` at `7b0` was `71e4` return (`c.li` not retired). Keep. |
| **G1ea** | stall use while same-hart CSR to that rs is in SB | `c.mv s1,a0` forwards jalr `a0=1`; `7be` skips | **soaked** hold+nat cookie t=22528; still `s1=1` at `7c0`. Did not fire. Keep. |
| **G1eb** | stall use while older same-hart ID writer of that rs | `7ac`/`7a4` unissued; `c.mv` reads RF `a0=1` | **MINI-FAIL** hang @400000. Reverted. |
| **G1ec** | IQ head oldest PC among nonempty FIFOs | `idx_ds` rotate issues `7b4` before `7ac` | **MINI-FAIL** P1 `0x10` @412. Reverted. |
| **G1ed** | leftover-pending smash only if slot0 compressed | G1bf smashed `7a8` I\|I / `7b0` I\|C; `c.mv` never retires | **soaked** hold+nat cookie t=22528; TRACE still `s1=1` `ra=752`. Did not fire. Keep. |
| **G1ee** | IQ head older CSR over younger use of that rd | `7bc` `c.bnez a0` takes `766`/`ef4c` with `a0=1` | **soaked** hold+nat cookie t=22528; still `766`→`ef4c`. Did not fire. Keep. |
| **G1ef** | presented leftover Jump drops different leftover Jump in IQ | G1dv issued stale `jal x0@766` | **soaked** hold+nat cookie t=22528; still `766` at t=20486. Did not fire. Keep. |
| **G1eg** | leftover-pending aligned fetch drops foreign leftover Jump | `7a8` csrr never enters IQ | **soaked** hold+nat cookie t=22528; still `7b8` `a0=1`→`766`. Did not fire. Keep. |
| **G1eh** | same-line IQ head is oldest PC | `7bc` before `7b8` `c.beqz` | **MINI-FAIL** lottery hang @400000; FDT P6 `0x59` @1043. Reverted. |
| **G1ei** | aligned fetch drops leftover jal x0 from another line | `766` parks IQ through `csrr` | **soaked** hold+nat cookie t=22528; still `7b8` `a0=1`→`766`. Did not fire. Keep. |
| **G1ej** | aligned I\|I push is atomic | `addi` consume skips `csrr` | **soaked** hold+nat cookie t=22528; still `7b8` `a0=1`→`766`. Keep. |
| **G1ek** | unconsumed aligned I\|I holds different-line I$ | `7b8` overwrites `7a8` before `csrr` consumed | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1el** | unconsumed mid-line `[2:1]==01` holds different-line I$ | `7a2` `c.li`+`auipc` overwritten | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1em** | older CSR-to-a0 before younger a0-Branch | `7bc` issues with `a0=1`; `csrr` late | **soaked** hold+nat cookie t=22528; TRACE `7a2`/`7a8` then still `766`. Did not close `7bc`. Keep. |
| **G1en** | leftover jal x0 drops while CSR-to-a0 queued | G1dc parks `766` after G1ei beat | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1eo** | aligned I|I restarts idx_is | `7a8` I|I in FIFO 2/3; `csrr` never head | **MINI-FAIL** lottery hang @200678; FDT P2 `0x12` @434. Reverted. |
| **G1ep** | consumed mid-line holds non-sequential I$ | `7b0` overwrites before `7a8` I|I | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1eq** | aligned I|I slot1 CSR not hidden by G1ct/G1cz | `csrr@7ac` valid[1] cleared | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1er** | aligned I|I slot1 CSR through IQ branch_mask | taken slot0 zeros `valid[1]` | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1es** | aligned I|I overrides leftover_next | leftover_next on `7a8` smashes `csrr` | **MINI-FAIL** lottery+FDT hang @400000. Reverted. |
| **G1et** | fill missing aligned I|I slot1 CSR from I$ | realign `valid[1]=0` drops `csrr` | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1eu** | leftover jal x0 does not complete onto I|I | leftover_next `jal x0` smashes `7a8` | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1ev** | a0-Branch waits for older ALU a0 writer in ID | `7bc` before `auipc`/`addi` | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1ew** | older ALU-to-a0 is IQ head over rotate | `addi` behind rotate; `7bc` first | **MINI-FAIL** FDT P10 `0x1d` @1854. Reverted. |
| **G1ex** | unissued dest-FIFO CSR-to-a0 holds different-line I$ | `7b0`/`7b8` overwrite before `csrr` issues | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1ey** | dest-FIFO a0-Branch waits for queued CSR-to-a0 | `7bc` issues while `csrr` still queued | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1ez** | leftover-complete unconsumed NoCF dest holds different-line I$ | leftover auipc/addi releases `7b0` | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1fa** | reject I$ whose line is ahead of npc | `7b0`/`7b8` return while npc is `7a8` | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1fb** | dest-FIFO a0-Branch ahead of npc is hidden | prefetched `7bc` issues before `7a8` | **MINI-FAIL** lottery printed 4 @375; FDT hang @400000. Reverted. |
| **G1fc** | dest-FIFO a0-Branch >1 line ahead of npc is hidden | `7b8` vs npc `7a8` is +2 | **MINI-FAIL** same as G1fb (printed 4 @375; FDT hang @400000). Reverted. |
| **G1fd** | after mid-line consume, hide a0-Branch past sequential next | `7a2` pushed; `7bc` before `7a8` | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1fe** | aligned I|I CSR-to-a0 data hides dest-FIFO a0-Branch | `7a8` data is addi+csrr; `valid[1]=0` | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1ff** | registered I$ I|I CSR-to-a0 hides later dest-FIFO a0-Branch | I$ word is addi+csrr; `7bc` queued | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1fg** | TRACE commit PC from packed entry MSB | `csrrcmt` never appeared | **soaked** hold+nat cookie t=22528; **`csrrcmt@7ac` t=20463** after `7b8` t=20458. Keep. |
| **G1fh** | a0-Branch waits until seen CSR-to-a0 commits | `7bc` after CSR in IQ/ID, before commit | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1fi** | arm mid-line wait on presentation not consume | `7a2` presented; `7bc` before `7a8` | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire (`7a8` t=20450). Keep. |
| **G1fj** | hold mid-line wait through sequential next | `7a8` must not drop hide | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire (`7b0` t=20457). Keep. |
| **G1fk** | hide dest-FIFO a0-Branch until CSR-to-a0 commit | `7bc` hidden until `7ac` commits | **MINI-FAIL** FDT hang @400000. Reverted. |
| **G1fl** | hide dest-FIFO a0-Branch until next line consumed | `7a8` presented but not pushed | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1fm** | arm mid-line wait on any slot `[2:1]==01` | `7a2` is slot1 of `7a0` | **MINI-FAIL** FDT P7 `0x17` @1196. Reverted. |
| **G1fn** | TRACE `7bc` commit vs leftover `jal@766` | thought `7bc` took stale a0 | **soaked** hold+nat cookie t=22528; no `bnezcmt`; `7b8` cmt then `766` cmt. Keep. |
| **G1fo** | leftover jal x0 waits for dest-FIFO JumpR | G1dc parks `766` over `7ba` | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1fp** | leftover jal x0 waits for presented JumpR | `7ba` on `instr_i`/`cf` | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1fq** | fill missing aligned compressed slot1 c.jalr from I$ | `valid[1]=0` drops `7ba` | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1fr** | dest-only beat keeps later-slot JumpR | G1ct smashes live `7ba` | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1fs** | Branch\|JumpR keeps slot1 through IQ branch_mask | `7b8` cf zeros `valid[1]` | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1ft** | leftover-Jump slot0-only keeps later-slot JumpR | G1cz smashes live `7ba` | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1fu** | fetch pc+2 after slot0-only compressed Branch consume | npc `7b8`→`7c0` skips `7ba` | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1fv** | npc +2 when aligned compressed Branch presented slot0-only | consume too late | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1fw** | npc +2 when IQ view is slot0-only compressed Branch | frontend valid vs g1ct smash | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1fx** | IQ slot0-only +2 without `is_branch` | `7b8` cf mash | **MINI-FAIL** lottery PASS @563; FDT printed 42 (P3 `0x2a`) @584. Restore G1fw. Do not re-land. |
| **G1fy** | IQ slot0-only +2 gated on `rvc_branch` | G1bj cleared `is_branch` | **soaked** hold+nat cookie t=22528; TRACE unchanged. Did not fire. Keep. |
| **G1fz** | IQ slot0 Branch +2 even if slot1 valid | slot1 live blocks +2 | **MINI-FAIL** lottery PASS @557; FDT printed 23 (P7 `0x17`) @200633. Restore G1fy. Do not re-land. |
| **G1ga** | IQ slot0 Branch +2 only when slot1 is JumpR | `7b8`\|`7ba` | **soaked** hold+nat cookie t=22528; TRACE unchanged at OpenSBI `7b8`. Lottery 557 (mini shape fired). Keep. |
| **G1gb** | frontend Branch\|JumpR +2 (`instruction_valid`) | IQ smash hid slot1 | **soaked** hold+nat cookie t=22528; TRACE unchanged at OpenSBI `7b8`. Did not fire. Keep. |
| **G1gc** | frontend Branch\|JumpR +2 even when leftover | `serving_unaligned` blocks +2 | **soaked** hold+nat cookie t=22528; TRACE unchanged at OpenSBI `7b8`. Did not fire. Keep. |
| **G1gd** | frontend Branch\|JumpR +2 even when `bp_valid` | `bp_valid` predict `7c0` | **soaked** hold+nat cookie t=96256; TRACE **flip**: `7ba` cmt, pkt7c0, scratch `@38e0`, BANR. Keep. |
| **G1ge** | after JumpR commit accept target I$ even if leftover jal unconsumed | leftover `766` holds `71e4` | **soaked** hold+nat cookie t=96256; TRACE unchanged vs G1gd. Did not fire. Keep. |
| **G1gf** | stall jalr until rs1 is a usable pointer | `7ba` a5=0 at execute | **HOLD-FAIL** no cookie ~6 min. Restore G1ge. Do not re-land. |
| **G1gg** | jalr prefer usable RF over unusable forward (no stall) | forward a5=0, RF `71e4` | **soaked** hold+nat cookie t=96256; TRACE unchanged vs G1gd. Did not fire. Keep. |
| **G1gh** | leftover jal x0 waits for same-hart jalr commit | `766` issues beside `7ba` | **soaked** hold+nat cookie t=96256; TRACE unchanged (`766` fetch @20470). Did not fire. Keep. |
| **G1gi** | do not present leftover jal x0 while jalr in flight | `766` fetch beside `7ba` | **soaked** hold+nat cookie t=96256; TRACE unchanged (`766` @20470 before jalr presents). Did not fire. Keep. |
| **G1gj** | do not present leftover jal x0 while npc is mid-line 01 | npc `7ba` then leftover `766` | **soaked** hold+nat cookie t=96256; TRACE unchanged (npc already `766` at 20470). Did not fire. Keep. |
| **G1gk** | hold leftover jal x0 hide 3 cycles after mid-line 01 | npc left `7ba` before leftover | **soaked** hold+nat cookie t=96256; TRACE unchanged (`766` @20470). Did not fire (`g1gi_lj` miss; hangj is npc replay). Keep. |
| **G1gl** | do not reseed npc to leftover-PC replay after mid-line 01 | replay `766` after G1gd +2 | **soaked** hold+nat cookie t=96256; TRACE unchanged (`766` @20470). Did not fire. Keep. |
| **G1gm** | do not reseed npc to leftover-PC replay while jalr seen | replay after flush cleared cnt | **soaked** hold+nat cookie t=96256; TRACE unchanged (`766` @20470). Did not fire (npc is not leftover-PC replay). Keep. |
| **G1gn** | leftover-PC `bp_valid` must not reseed npc after mid-line 01 / jalr seen | predict `766` after G1gd +2 | **HOLD-FAIL** no cookie ~6 min (preload only). Restore G1gm. Do not re-land (`kill_s2` stayed). |
| **G1go** | leftover-PC is not a predicted target after mid-line 01 / jalr seen | G1gn left `kill_s2` live | **HOLD-FAIL** no cookie ~2 min (preload only). Restore G1gm. Do not re-land (leftover-PC predict is load-bearing). |
| **G1gp** | jalr resolve uses usable RF when operand_a is unusable | EX a5=0, RF `71e4` | **soaked** hold+nat cookie t=96256; TRACE unchanged (`7ba` cmt, no `@71e4`). Did not fire. Keep. |
| **G1gq** | committed JALR redirects to RF[rs1] after unusable JumpR | E2-suppressed JumpR then commit | **soaked** hold+nat cookie t=96256; TRACE unchanged. Did not fire (no JumpR pend). Keep. |
| **G1gr** | committed JALR redirects to RF[rs1] without EX JumpR pend | G1gq pend never armed | **MINI-FAIL** FDT printed 42 (P3 `0x2a`) @782. Restore G1gq. Do not re-land. |
| **G1gs** | JALR resolve is JumpR even if RAS tagged Return | `c.jalr` a5 cf stayed Return | **soaked** hold+nat cookie t=96256; TRACE unchanged. Did not fire (`7ba` not JALR at EX). Keep. |
| **G1gt** | recover high-half `c.jalr` from leftover-RVI mash | 32-bit mash at `7ba` | **MINI-FAIL** FDT hang @400000. Restore G1gs. Do not re-land (any-RVI too wide). |
| **G1gu** | recover high-half `c.jalr` only when low is RVI BRANCH | G1gt any-RVI hung FDT | **soaked** hold+nat cookie t=96256; TRACE unchanged. Did not fire. Keep. |
| **G1gv** | recover mid-line C2 `c.jalr` when `[6:2]` mashed to `c.add` | `7ba` `[2:1]==01` | **MINI-FAIL** FDT printed 46 @616. Restore G1gu. Do not re-land (real `c.add`). |
| **G1gw** | mid-line exact `c.jalr` encoding forces JALR | G1gv mash too wide | **soaked** hold+nat cookie t=96256; TRACE unchanged. Did not fire. Keep. |
| **G1gx** | mid-line slot0 is the 16-bit at that PC | leftover-complete / unshifted 32-bit at `7ba` | **soaked** hold+nat cookie t=96256 + BANR; TRACE unchanged. Did not fire. Keep. |
| **G1gy** | mid-line either-half exact `c.jalr` forces JALR | G1gw low-only; unshifted high half | **soaked** hold+nat cookie t=96256 + BANR; TRACE unchanged. Did not fire. Keep. |
| **G1gz** | mid-line slot0 is I$ +2 halfword | wrong 16-bit at `7ba` | **MINI-FAIL** lottery printed 2 @411, FDT printed 90 @1082. Restore G1gy. Do not re-land. |
| **G1ha** | I$ +2 only when exact `c.jalr` | G1gz yanked live mid-line | **soaked** hold+nat cookie t=96256 + BANR; TRACE unchanged. Did not fire. Keep. |
| **G1hb** | slot1 from I$ +2 exact `c.jalr` even if valid | G1fq `valid[1]=0` only | **soaked** hold+nat cookie t=96256 + BANR; TRACE unchanged. Did not fire. Keep. |
| **G1hc** | leftover-complete beat still presents I$ +2 `c.jalr` as slot1 | G1fq/G1hb `!serving_unaligned` | **soaked** hold+nat cookie t=96256 + BANR; TRACE unchanged. Did not fire. Keep. |
| **G1hd** | issued op is JALR when mid-line fetch has exact `c.jalr` | G1gy analog after ID | **soaked** hold+nat cookie t=96256 + BANR; TRACE unchanged. Did not fire. Keep. |
| **G1he** | mid-line CTRL_FLOW usable-RF is JumpR | `7ba` not JALR at EX | **MINI-FAIL** FDT hang @400000. Restore G1hd. Do not re-land. |
| **G1hf** | mid-line `!Branch` usable-RF is JumpR | G1he yanked live Branch | **soaked** hold+nat cookie t=96256 + BANR; TRACE unchanged. Did not fire. Keep. |
| **G1hg** | mid-line Branch orig 16-bit exact `c.jalr` is JumpR | G1hf `7ba` is Branch | **soaked** hold+nat cookie t=96256 + BANR; TRACE unchanged. Did not fire. Keep. |
| **G1hh** | any mid-line 01 slot from I$ +2 exact `c.jalr` | G1ha slot0; G1hc leftover slot1 | **soaked** hold+nat cookie t=96256 + BANR; TRACE unchanged. Did not fire. Keep. |
| **G1hi** | mid-line 01 from live I$ +2 exact `c.jalr` without same-line | G1hh same-line vs leftover `766` I$ | **soaked** hold+nat cookie t=96256 + BANR; TRACE unchanged. Did not fire. Keep. |
| **G1hj** | stash aligned I$ +2 exact `c.jalr`; fill mid-line 01 | live I$ is leftover `766` | **soaked** hold+nat cookie t=96256 + BANR; TRACE unchanged. Did not fire at `7ba`. Keep. |
| **G1hk** | present slot0 at npc from stash when npc mid-line 01 | G1hj rewrite-only; npc `7ba` not a slot | **soaked** hold+nat cookie t=96256 + BANR; TRACE unchanged. Did not fire. Keep. |
| **G1hl** | leftover-complete slot1 from stash at npc mid-line 01 | G1hk skips leftover slot0 | **soaked** hold+nat cookie t=96256 + BANR; TRACE unchanged. Did not fire. Keep. |
| **G1hm** | leftover-complete slot1 at stashed +2 PC | G1hl npc `01` vs leftover `766` different cycles | **soaked** hold+nat cookie t=96256 + BANR; TRACE unchanged. Did not fire. Keep. |
| **G1hn** | capture I$ `[31:16]` exact `c.jalr` even if vaddr not aligned | G1hj `vaddr==00` only | **soaked** hold+nat cookie t=96256 + BANR; TRACE unchanged. Did not fire. Keep. |
| **G1ho** | capture `[15:0]` exact `c.jalr` when vaddr mid-line 01 | shifted mid-line; not `750` | **soaked** hold+nat cookie t=96256 + BANR; TRACE unchanged. Did not fire. Keep. |
| **G1hp** | capture exact `c.jalr` from `g1gx_data` either half | shifted present word; not `750` | **soaked** hold TRACE cookie t=96256 + BANR; TRACE unchanged. Did not fire (`g1gx` ≡ G1hn). Keep. |
| **G1hq** | capture incoming I$ +2 exact `c.jalr` even if fill not registered | leftover-PC kills `q`; not `750` | **soaked** hold TRACE cookie t=96256 + BANR; TRACE 7ba unchanged. Lottery @567 (fired). OpenSBI 7b8 `valid=0` on `kill_s2`. Keep. |
| **G1hr** | capture incoming I$ +2 exact `c.jalr` on `kill_s2` even if valid muted | I$ `valid=~kill_s2`; not G1bb | **soaked** hold TRACE cookie t=96256 + BANR; TRACE 7ba unchanged. Did not fire on OpenSBI 7b8. Keep. |
| **G1hs** | leftover-complete Jump must not replay-kill I$ s1 | G1cq is NoCF only; not G1bq | **soaked** hold TRACE cookie t=96256 + BANR; TRACE 7ba unchanged. Did not fire. Keep. |
| **G1ht** | replay must not `kill_s1` while npc mid-line 01 | 7ba fetch outstanding; not G1gn | **soaked** hold TRACE cookie t=96256 + BANR; TRACE 7ba unchanged. Did not fire. Keep. |
| **G1hu** | leftover Jump `bp_valid` must not `kill_s2` a different-line I$ | not G1bq all leftover; not G1gn | **MINI-FAIL** FDT printed 24 (P8 `0x18`) @2479. Restore G1ht. Do not re-land. |
| **G1hv** | leftover Jump must not `flush_i`-kill s1 while npc mid-line 01 | not G1hu `kill_s2`; not G1ht | **soaked** hold TRACE cookie t=96256 + BANR; TRACE 7ba unchanged. Did not fire. Keep. |
| **G1hw** | leftover Jump must not `is_mispredict`-kill s1 while npc mid-line 01 | G1hv `flush_i` only; not G1hu | **soaked** hold TRACE cookie t=96256 + BANR; TRACE 7ba unchanged. Did not fire. Keep. |
| **G1hx** | same-line +2 duplicate compressed Branch is JALR | not G1he all mid-line; not G1hg | **soaked** hold TRACE cookie t=96256 + BANR; TRACE 7ba unchanged. Did not fire. Keep. |
| **G1hy** | aligned packet high-half `c.jalr` recovers mid-line 01 Branch | not G1hx duplicate; not G1gy | **soaked** hold TRACE cookie t=96256 + BANR; TRACE 7ba unchanged. Did not fire (7b8 high half not `c.jalr`). Keep. |
| **G1hz** | slot0-only aligned Branch keeps +2 `c.jalr` in `instruction[31:16]` | not G1fq slot1; not G1gz | **soaked** hold TRACE cookie t=96256 + BANR; TRACE 7ba unchanged. Did not fire. Keep. |
| **G1ia** | compressed +2 slot is the 16-bit at that PC, not `{+4,+2}` mash | not G1gz slot0; not G1fq | **soaked** hold TRACE cookie t=96256 + BANR; TRACE 7ba unchanged. Did not fire. Keep. |
| **G1ib** | slot0-only must not hide a live +2 `c.jalr` | not G1gz slot0; not G1fq/G1hc | **soaked** hold TRACE cookie t=96256 + BANR; TRACE 7ba unchanged. Did not fire. Keep. |
| **G1ic** | leftover-PC I$ must not present while npc is mid-line 01 | not G1el unconsumed-01; not G1gz | **soaked** hold TRACE cookie t=96256 + BANR; TRACE 7ba unchanged. Did not fire. Keep. |
| **G1id** | mid-line 01 Branch on same line as aligned compressed Branch is JALR | not G1hx same 16-bit; not G1he | **soaked** hold TRACE cookie t=96256 + BANR; TRACE 7ba unchanged. Did not fire. Keep. |
| **G1ie** | frontend latch of aligned compressed Branch recovers same-line 01 Branch as `c.jalr` | not G1id ID latch; not G1he | **soaked** hold TRACE cookie t=96256 + BANR; lottery @571 (was @567); TRACE 7ba unchanged. Fired on lottery. Keep. |
| **G1if** | same-line 01 slot is `c.jalr` even if not a Branch | not G1ie Branch gate; not G1gz | **HOLD-FAIL** no cookie @600000. Restore G1ie. Do not re-land. |
| **G1ig** | mid-line 01 Branch whose imm target is leftover-PC is JumpR | not G1he; not G1hg | **MINI-FAIL** FDT hang @400000. Restore G1ie. Do not re-land. |
| **G1ih** | IQ output recovers same-line 01 Branch as `c.jalr` | not G1ie present; not G1if any-slot | **soaked** hold TRACE cookie t=96256 + BANR; lottery @571; TRACE 7ba unchanged. Did not fire at OpenSBI 7ba. Keep. |
| **G1ii** | IQ input (`valid_i`) latches aligned Branch (encoding or `cf==Branch`) | not G1ih push-only; not G1if | **soaked** hold TRACE cookie t=96256 + BANR; TRACE 7ba unchanged. Did not fire. Keep. |
| **G1ij** | mid-line 01 Branch whose 16-bit is not a Branch encoding follows that 16-bit | not G1he; not G1ig leftover-PC | **soaked** hold TRACE cookie t=96256 + BANR; lottery @571; TRACE 7ba unchanged. Did not fire (7ba bits are Branch at ID). Keep. |
| **G1ik** | ID-visible aligned Branch arms same-line 01 recover | not G1id bits-only; not G1he; not G1if | **soaked** hold TRACE cookie t=96256 + BANR; lottery @571; TRACE 7ba unchanged. Did not fire (7b8 never aligned Branch at ID). Keep. |
| **G1il** | aligned-Branch recover latch survives `flush_i` | not G1bn FIFO; not G1if | **soaked** hold TRACE cookie t=96256 + BANR; lottery @571; TRACE 7ba unchanged. Did not fire (latch never armed). Keep. |
| **G1im** | aligned either-half compressed Branch is that Branch | not G1ij mid-line drop; not G1he | **HOLD-FAIL** no cookie @250000. Restore G1il. Do not re-land. |
| **G1in** | leftover-PC I$ must not present while npc is aligned 00 | not G1ic 01-only; not G1im | **MINI-FAIL** lottery hang @400000. Restore G1il. Do not re-land. |
| **G1io** | aligned npc + same-line I$ → slot0 is I$ `[15:0]` | not G1in mute; not G1es leftover | **soaked** hold TRACE cookie t=96256 + BANR; lottery @571; TRACE 7ba unchanged. Did not fire. Keep. |
| **G1ip** | leftover slot0 stays; slot1 is I$ `[15:0]` at aligned npc | not G1hc +2; not G1es | **soaked** hold TRACE cookie t=96256 + BANR; lottery @571; TRACE 7ba unchanged. Did not fire (leftover @20470 after npc 7b8 @20458). Keep. |
| **G1iq** | stash aligned I$ `[15:0]` compressed Branch; present at aligned npc | not G1hj +2; not G1in mute | **soaked** hold TRACE cookie t=96256 + BANR; lottery @571; FDT @2719 (was @2691); TRACE 7ba unchanged. Fired on FDT. Keep. |
| **G1ir** | G1ie arms from G1iq stash (C2 rs1' + line) | not G1if any-slot; not G1iq present-only | **soaked** hold TRACE cookie t=96256 + BANR; lottery @571; FDT @2719; TRACE 7ba identical to G1iq. Did not fire (stash not the 7b8 line). Keep. |
| **G1is** | G1iq capture `[15:0]` Branch even when I$ vaddr is not 00 | not G1hn +2; not G1in mute | **HOLD-FAIL** no cookie @250000. Restore G1ir. Do not re-land. |
| **G1it** | G1iq capture `[15:0]` Branch when I$ vaddr is mid-line 01 | not G1is any-vaddr; not leftover 11 | **soaked** hold TRACE cookie t=96256 + BANR; lottery @571; FDT @2719; TRACE 7ba identical to G1ir. Did not fire. Keep. |
| **G1iu** | G1iq capture `[15:0]` Branch when npc is mid-line 01 on same I$ line | not G1is any-vaddr; not leftover-only | **soaked** hold TRACE cookie t=96256 + BANR; lottery @571; FDT @2719; TRACE 7ba identical to G1it. Did not fire. Keep. |
| **G1iv** | 128-bit I$ other-half `[15:0]` Branch stashed as sibling line | not G1is any-vaddr; not leftover-only | **MINI-FAIL** FDT tohost 91 @948. Restore G1iu. Do not re-land. |
| **G1iw** | same-cycle sibling-half `[15:0]` Branch recovers mid-line 01 | not G1iv stash; not G1if any-slot | **soaked** hold TRACE cookie t=96256 + BANR; lottery @571; FDT @2719; TRACE 7ba identical to G1iu. Did not fire. Keep. |
| **G1ix** | `bp_valid` must not kill_s2 while npc is mid-line 01 | not G1hu leftover Jump; not G1in mute | **soaked** hold TRACE cookie t=96256 + BANR; lottery @571; FDT @2719; TRACE 7ba identical to G1iw. Did not fire. Keep. |
| **G1iy** | flush/`is_mispredict` must not kill_s1 while npc is mid-line 01 | not G1hv leftover Jump only; not G1hu | **MINI-FAIL** lottery tohost 2 @430. Restore G1ix. Do not re-land. |
| **G1iz** | I$ vaddr stays npc 8-byte line at mid-line 01 | not G1iy kill_s1; not G1in mute | **MINI-FAIL** FDT tohost 23 @1192 (P7). Restore G1ix. Do not re-land. |
| **G1ja** | different-line predict must not skip aligned-00 npc I$ | not G1iz 01 hold; not G1in mute | **MINI-FAIL** lottery tohost 4 @362. Restore G1ix. Do not re-land. |
| **G1jb** | aligned-Branch recover not replaced by a different 8-byte line until that line's mid-line 01 is presented | not G1ja 00 I$; not G1iz 01 hold | **soaked** hold TRACE cookie t=96256 + BANR; lottery @571; FDT @2719; TRACE 7ba identical to G1ix. Did not fire. Keep. |
| **G1jc** | first leftover-RVI I$ steal at npc 01 still issues npc 8-byte line once | not G1iz every-cycle; not G1ja | **soaked** hold TRACE cookie t=96256 + BANR; lottery @571; FDT @2719; TRACE 7ba identical to G1jb. Did not fire. Keep. |
| **G1jd** | sequential-next 8-byte fetch must not skip aligned-00 npc I$ | not G1ja any different line; not G1jc leftover-11 | **MINI-FAIL** FDT tohost 57 @2652 (P3 0x39). Restore G1jc. Do not re-land. |
| **G1je** | in-ID aligned-00 any op arms same-line 01 Branch recover | not G1ik Branch-only; not G1if | **MINI-FAIL** FDT hang @400000. Restore G1jc. Do not re-land. |
| **G1jf** | prev-cycle aligned-00 commit + this-cycle 01 Branch commit is JumpR | not G1je same-cycle ID; not G1gr | **MINI-FAIL** FDT hang @400000. Restore G1jc. Do not re-land. |
| **G1jg** | first sequential-next 8-byte I$ at npc 01 still issues npc 8-byte line once | not G1iz every-cycle; not G1jc leftover-11; not G1jd at 00 | **soaked** hold TRACE cookie t=96256 + BANR; lottery @571; FDT @2719; TRACE 7ba identical to G1jc. Did not fire. Keep. |
| **G1jh** | first different 8-byte-line I$ at npc 01 still issues npc 8-byte line once | not G1iz every-cycle; not G1jc leftover-11; not G1jg sequential-next; not G1ja/G1jd at 00 | **MINI-FAIL** FDT tohost 23 @1205 (P7 0x17). Restore G1jg `2e1cc9f2` / `4b824269` bit-identical. Do not re-land. |
| **G1ji** | G1ie arms from G1iw sibling-half compressed Branch (`user[16:0]`), keep-until-01 | not G1iv stash; not G1jh 01 steal | **soaked** hold TRACE cookie t=96256 + BANR; lottery @567 (fired); FDT @2719; TRACE 7ba identical to G1jg. Did not fire at OpenSBI 7ba. Keep. |
| **G1jj** | sibling-half [31:16] exact c.jalr into G1hj +2 stash | not G1iv [15:0]; not G1ji constructed jalr; not G1jh 01 steal | **MINI-FAIL** lottery tohost 2 @200615. Restore G1ji `f735925b` / `f1751d08` bit-identical. Do not re-land. |
| **G1jk** | G1hj +2 c.jalr stash present/rewrite only at the captured +2 PC | not G1jj capture; not G1hk any-01 | **soaked** hold TRACE cookie t=96256 + BANR; lottery @558 (fired); FDT @2719; TRACE 7ba identical to G1ji. Did not fire at OpenSBI 7ba. Keep. |
| **G1jl** | sibling pair (compressed Branch + [31:16] exact c.jalr) into PC-matched G1hj | not G1jj any sibling +2; not G1iv | **soaked** hold TRACE cookie t=96256 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1jk. Did not fire. Keep. |
| **G1jm** | keep registered aligned compressed-Branch I$ until that line's +2 is presented | not G1iz vaddr; not G1bb keep_line | **soaked** hold TRACE cookie t=96256 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1jl. Did not fire (7b8 never registered). Keep. |
| **G1jn** | spare kill_s2 when returning I$ is npc-00 same-line compressed Branch | not G1ja 00 steal; not G1hu leftover Jump; not G1ix npc-01 | **soaked** hold TRACE cookie t=96256 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1jm. Did not fire (in-flight s2 is previous line). Keep. |
| **G1jo** | replay must not kill_s1 while npc is aligned 00 | not G1ht npc-01; not G1iy flush/mispredict | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba same shape −20 cy. Fired; residual unchanged. Keep. |

| **G1jp** | spare bp_valid kill_s2 at all npc 00 | not G1ix npc-01; not G1jn returning-data | **MINI-FAIL** lottery tohost 2 @420, FDT 50 @545. Restore G1jo. Do not re-land. |
| **G1jq** | leftover Jump must not flush/mispredict-kill s1 while npc is aligned 00 | not G1hv npc-01; not G1iy all-01; not G1jp kill_s2 | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba same shape as G1jo +6 cy. Did not fire. Keep. |
| **G1jr** | flush_i must not kill_s1 while npc is aligned 00 | not G1iy flush+mispredict; not G1jq leftover Jump; not G1jp kill_s2 | **HOLD-FAIL** no cookie @600000 `[1000]=8000f1d0` mcause=4. Restore G1jq. Do not re-land. |
| **G1js** | flush_i must not kill_s1 at npc 00 when s1 is the npc 8-byte line | not G1jr all-00; not G1iy; not G1jp | **HOLD-FAIL** same pin as G1jr `[1000]=8000f1d0` mcause=4 @600000. Restore G1jq. Do not re-land. |
| **G1jt** | is_mispredict must not kill_s1 while npc is aligned 00 | not G1jr/G1js flush_i; not G1iy both at 01; not G1jp | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1jq. Did not fire. Keep. |
| **G1ju** | G1hj +2 c.jalr stash survives leftover Jump flush_i | not G1il G1ie latch; not G1jb replace; not G1jr kill_s1 | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1jt. Did not fire. Keep. |
| **G1jv** | G1hj capture beats flush_i clear | not G1ju leftover-only keep; not G1jr kill_s1 | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1ju. Did not fire. Keep. |
| **G1jw** | G1jl sibling-pair capture without I$ valid/kill_s2 | not G1jl valid/kill_s2; not G1jj any sibling +2 | **HOLD-FAIL** no cookie @600000 `[1000]=800071d8` mcause=4. Restore G1jv. Do not re-land. |
| **G1jx** | IDLE sibling-pair capture only when npc is the sibling +2 PC | not G1jw any-IDLE; not G1jj | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1jv. Did not fire. Keep. |
| **G1jy** | latch IDLE aligned-00 sibling pair; present only at npc +2 01 | not G1jw G1hj fill; not G1hm leftover inject | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1jx. Did not fire. Keep. |
| **G1jz** | IDLE sibling latch +2 PC from last I$ return vaddr | not G1jy current-vaddr 00; not G1jw G1hj | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1jy. Did not fire. Keep. |
| **G1ka** | present live user[33] pair at npc == last-return +2 | not G1jw G1hj; not G1hm leftover inject | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1jz. Did not fire. Keep. |
| **G1kb** | slot0-only aligned compressed keeps +2 c.jalr even if slot0 is not Branch | not G1hz Branch-only; not G1fx npc +2 | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1ka. Did not fire. Keep. |
| **G1kc** | leftover slot1 present of G1jy stash at npc-matched +2 | not G1hm leftover inject; not G1jw G1hj; not G1ka live-user | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1kb. Did not fire. Keep. |
| **G1kd** | G1jy capture without last-return; +2 PC from current I$ sibling | not G1jw G1hj; not G1jz last-return PC; not G1jx npc-already-+2 | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1kc. Did not fire. Keep. |
| **G1ke** | same-line IDLE pair into G1jy | not G1jw G1hj; not G1jj sibling; not G1hn valid G1hj | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1kd. Did not fire. Keep. |
| **G1kf** | registered I$ same-line pair into G1jy | not G1ke live dreq; not G1jw G1hj; not G1hn valid G1hj | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1ke. Did not fire. Keep. |
| **G1kg** | same-line pair on kill_s2 into G1jy | not G1jp kill_s2 spare; not G1jw G1hj; not G1hr G1hj | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1kf. Did not fire. Keep. |
| **G1kh** | kill_s2 sibling user[33] pair into G1jy | not G1jp kill_s2 spare; not G1jw G1hj; not G1jl G1hj | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1kg. Did not fire. Keep. |
| **G1ki** | I$ sticky last sibling pair on user[33] | not G1iv [15:0] stash; not G1jj any sibling +2 | **HOLD-FAIL** no cookie @600000 `[1000]=51b1c001` no BANR. Restore G1kh `229c4e51` / `f3d41166` bit-identical. Do not re-land. |
| **G1kj** | npc-matched sibling pair into G1jy with full +2 PC | not G1jx G1hj; not G1ki sticky; not G1jw | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1kh. Did not fire. Keep. |
| **G1kk** | aligned-00 RVI LOAD rd recovers sibling 01 Branch as c.jalr | not G1ie C2 rs1'; not G1je any-op | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1kj. Did not fire (no 01 Branch slot at npc 7ba). Keep. |
| **G1kl** | present G1kk c.jalr at npc 01 of the LOAD's sibling 8-byte half | not G1hm leftover inject; not G1je any-op | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1kk. Did not fire (leftover 11 skips slot0). Keep. |
| **G1km** | leftover slot1 present of G1kk c.jalr at npc sibling 01 | not G1hm leftover inject; not G1jw | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1kl. Did not fire (`g1kk_v_q` empty). Keep. |
| **G1kn** | aligned-00 RVI LOAD from I$ data into G1kk | not G1ke pair; not G1jw G1hj; not G1ki sticky | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba +3 cy vs G1km. Fired; residual unchanged. Keep. |
| **G1ko** | G1kk survives leftover Jump flush_i | not G1jr/G1js npc-00 flush kill_s1; not G1jv capture-beats-flush | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1kn. Did not fire. Keep. |
| **G1kp** | G1kk capture beats flush_i | not G1jr/G1js; not G1ko leftover-only keep | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1ko. Did not fire. Keep. |
| **G1kq** | G1kk survives leftover Jump is_mispredict | not G1iy all-01; not G1jt all npc-00 | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1kp. Did not fire. Keep. |
| **G1kr** | G1kk survives is_mispredict at npc 00 | not G1iy all-01; not G1kq leftover Jump only | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1kq. Did not fire. Keep. |
| **G1ks** | G1kk consume only at sibling 01 | not G1if any-slot | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba −16 cy vs G1kr. Fired; residual unchanged. Keep. |
| **G1kt** | G1kk keep-until-sibling-01 | not G1ki sticky | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba back to G1jo @20461. Fired; residual unchanged. Keep. |
| **G1ku** | G1kk I$ capture only when npc is on the same 16-byte line | not G1ki sticky; not G1kn any-vaddr | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1kt. Did not fire. Keep. |
| **G1kv** | present-path G1kk capture only when npc is on the same 16-byte line | not G1ki sticky; not any-ID LOAD | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1ku. Did not fire. Keep. |
| **G1kw** | G1kk from registered I$ aligned-00 RVI LOAD | not G1ki sticky; not G1kn live dreq | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1kv. Did not fire. Keep. |
| **G1kx** | npc-line LOAD recapture may replace a held different-line LOAD | not G1ki sticky; not G1kt any different-line block | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba −13 cy vs G1kw (cmt @20448). Fired; residual unchanged. Keep. |
| **G1ky** | leftover slot1 G1kk present from same-cycle I$ LOAD cap | not G1hm leftover inject; not present-path g1kk_cap | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1kx. Did not fire. Keep. |
| **G1kz** | G1kl slot0 present from same-cycle I$ LOAD cap | not G1hm leftover inject; not leftover-11 overwrite | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1ky. Did not fire. Keep. |
| **G1la** | G1kl does not skip leftover 11 when G1kk sibling 01 matches | not G1hm off-npc inject; not G1jw | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1kz. Did not fire. Keep. |
| **G1lb** | I$ LOAD may replace G1kk even when npc is off that line | not G1ki sticky; not G1ku npc-line; not G1kt keep for g1kn | **soaked** hold TRACE cookie t=206848 (was t=83968) + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1la. Fired; cookie later; residual unchanged. Keep. |
| **G1lc** | I$ LOAD recapture only when G1kk is empty | not G1ki sticky; not restore G1ku npc-line | **soaked** hold TRACE cookie t=206848 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1lb. Did not fire. Keep. |
| **G1ld** | restore G1ku npc-line on g1kn | not G1ki sticky; not G1lb off-npc | **soaked** hold TRACE cookie t=83968 restored + BANR; lottery @558; FDT @2719; bit-identical G1la `296f54ab`. Fired; cookie restored. Keep. |
| **G1le** | last I$ LOAD side-stash present at sibling 01 | not G1ki sticky; not G1lb into G1kk | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1ld. Did not fire. Keep. |
| **G1lf** | g1le keep-until-sibling-01 | not G1ki sticky; not G1lb into G1kk | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1le. Did not fire. Keep. |
| **G1lg** | npc-line recapture may replace a held different-line g1le | not G1ki sticky; not G1lb into G1kk | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1lf. Did not fire. Keep. |
| **G1lh** | present-path aligned-00 RVI LOAD into g1le | not G1ki sticky; not G1lb into G1kk; not leftover present | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1lg. Did not fire. Keep. |
| **G1li** | registered I$ aligned-00 RVI LOAD into g1le | not G1ki sticky; not G1lb into G1kk; not npc-line (G1kw) | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1lh. Did not fire. Keep. |
| **G1lj** | leftover slot1 g1le present from same-cycle I$/registered LOAD cap | not G1hm leftover inject; not present-path g1lh | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1li. Did not fire. Keep. |
| **G1lk** | G1kl slot0 from same-cycle g1le I$/registered LOAD cap | not G1ki sticky; not G1lb into G1kk; not leftover slot1 (G1lj) | **reverted** hold TRACE cookie t=206848 (was t=83968) + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1lj. Fired; cookie later. Restore G1lj `673cd1d8`. |
| **G1ll** | G1kl slot0 from same-cycle g1le I$/registered LOAD cap with npc-line | not G1lk no-npc-line; not G1ki sticky; not G1lb into G1kk | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1lj. Did not fire. Keep. |
| **G1lm** | IQ-visible aligned-00 RVI LOAD sibling 01 recover | not G1if any-slot; not G1ih Branch-bits only | **reverted** lottery @558; FDT FAIL 106 @200619. Restore G1ll `93a79414`. |
| **G1ln** | ID-visible aligned-00 RVI LOAD arms sibling 01 Branch recover | not G1je any-op; not G1lm IQ rewrite | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1ll. Did not fire. Keep. |
| **G1lo** | ID latch of aligned-00 RVI LOAD survives flush_i | not G1je any-op; not G1lm IQ rewrite | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical; j766cmt −120 cy. Fired later; residual unchanged. Keep. |
| **G1lp** | g1lo keep-until sibling 01 | not G1ki sticky; not G1lk; not G1lm | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical; j766cmt back @83345. Did not fire. Keep. |
| **G1lq** | IQ-visible aligned-00 RVI LOAD into g1lo_cap | not G1lm IQ rewrite; not G1ki sticky | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1lp. Did not fire. Keep. |
| **G1lr** | g1lq keep-until sibling 01 | not G1ki sticky; not G1lm; not G1lk | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1lq. Did not fire. Keep. |
| **G1ls** | present-path instruction_valid 00 LOAD into g1lq_cap | not G1lm IQ rewrite; not leftover present | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1lr. Did not fire. Keep. |
| **G1lt** | live I$ aligned-00 RVI LOAD into g1lq_cap | not G1lb into G1kk; not G1lm | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1ls. Did not fire. Keep. |
| **G1lu** | registered I$ aligned-00 RVI LOAD into g1lq_cap | not G1lb into G1kk; not G1lm | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1lt. Did not fire. Keep. |
| **G1lv** | leftover slot1 g1lq present at npc sibling 01 | not G1lk G1kl; not G1lm; not present-path | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1lu. Did not fire. Keep. |
| **G1lw** | G1kl slot0 from g1lq_hit | not G1lk no-npc-line; not G1lm | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1lv. Did not fire. Keep. |
| **G1lx** | g1lq overwrite of g1lo_cap gated to empty or fetch 01 line | not G1lk; not G1lm | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1lw. Did not fire. Keep. |
| **G1ly** | same-line g1lq overwrite of held g1lo | not G1lk; not G1lm | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1lx. Did not fire. Keep. |
| **G1lz** | per-hart g1lo LOAD latch; G1ln same-hart | not G1lk; not G1lm | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1ly. Did not fire. Keep. |
| **G1ma** | per-hart g1lq IQ LOAD latch + sideband | not G1lk; not G1lm | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1lz. Did not fire. Keep. |
| **G1mb** | per-hart g1le I$ LOAD side-stash | not G1lk; not G1lm | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1ma. Did not fire. Keep. |
| **G1mc** | per-hart G1kk LOAD recover latch | not G1lk; not G1lm | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1mb. Did not fire. Keep. |
| **G1md** | commit-visible aligned-00 RVI LOAD into g1lo | not G1lk; not G1lm | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1mc. Did not fire. Keep. |
| **G1me** | g1lo commit capture beats flush_i | not G1lk; not G1lm | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1md. Did not fire. Keep. |
| **G1mf** | SB result-valid aligned-00 RVI LOAD into g1lo | not G1lk; not G1lm | **soaked** hold TRACE cookie t=83968 + BANR; lottery @558; FDT @2719; TRACE 7ba identical to G1me. Did not fire. Keep. |

Leave in place: I4ak, I4bl, PMA execute lengths, reverted I4bv/I4ca/G1z/G1aa/G1ab/G1ac/G1as/G1at/G1ax/G1bb/G1bd/G1bi/G1bk/G1bn/G1bo/G1bq/G1br/G1bs/G1bt/G1bu/G1bw/G1by/G1bz/G1cd/G1ce/G1cf/G1cg/G1ch/G1cj/G1ck/G1cl/G1cn/G1co/G1cu/G1db/G1dg/G1dr/G1dw/G1dy/G1eb/G1ec/G1eh/G1eo/G1es/G1ew/G1fb/G1fc/G1fk/G1fm/G1fx/G1fz/G1gf/G1gn/G1go/G1gr/G1gt/G1gv/G1gz/G1he/G1hu/G1if/G1ig/G1im/G1in/G1is/G1iv/G1iy/G1iz/G1ja/G1jd/G1je/G1jf/G1jh/G1jj/G1jp/G1jr/G1js/G1jw/G1ki/G1lk/G1lm.

---

## Migration map — remaining G1\* → `core/smt/`

Inventory of **inlined** G1\* that can still peel. Already extracted (leave):
`g6lc_sb_keep`, `g6lc_issue_barrier`, `g6lc_jalr_usable`, `g6lc_cf_unissued`,
`g6lc_cf_pc`, U6.1 banks / `g6lc_thread_select` / `g6lc_hart_state`.

**Do not dump recover into keep / unissued / barrier.** New files, EXTRACT
rules (bit-identical, SI const-fold, one family per increment, Hold-FAIL
revert). Gate `SuperscalarEn && NrHarts>1` unless noted.

### Already a module (done)

| Code | Module | Kind |
|------|--------|------|
| I4m–cf, catalog G1–G1g | `g6lc_sb_keep` | keep predicate |
| hang-6/7, G1ag/al/fh/gh | `g6lc_issue_barrier` | issue stall |
| I4t/v usable target | `g6lc_jalr_usable` | PMA + page-0 |
| I4x/bz/ce, `keep_line` policy | `g6lc_cf_unissued` | flush / keep_line **functions**; callers still own leftover flags |
| G1r CF PC | `g6lc_cf_pc` | per-instr PC |
| U6.1 RF/CSR/PC/scheduler | `g6lc_smt_*` / `g6lc_thread_select` | banks |

LSU (`load_unit` / `store_buffer`): no living recover to peel (`g1ao` STQ
fwd_hold is keep-adjacent; leave unless a later keep extract).

### Peel next (easiest first)

| E | Home | Pull | Kind | Risk |
|---|------|------|------|------|
| **E5** | `g6lc_rvc_enc` | `g1fr_is_jalr`, `g1ha_*` encodings; `compressed_decoder` G1ba/G1gu | combo rewrite/predicate | **soaked** lottery @558 FDT @2719 cookie t=83968 |
| **E2+** | extend `g6lc_jalr_usable` | `branch_unit` G1gs/hf/hg mid-line JumpR | combo | **soaked** lottery @558 FDT @2719 cookie t=83968 |
| **E6** | `g6lc_fe_keep` | frontend hold OR (`g1bl`/`g1cv`/`g1jm`/`g1cr`/…) | combo predicate | **soaked** lottery @558 FDT @2719 cookie t=83968 |
| **E7** | `g6lc_fe_kill` | kill spare terms (`g1hv`/`g1jq`/`g1jt`/`g1jn`/`g1ix`/`g1jo`) | combo predicate; **mux stays in frontend** | **soaked** lottery @558 FDT @2719 cookie t=83968 |
| **E8** | `g6lc_iq_hide` | `instr_queue` hide / `valid[1]` keep (`g1fo`/`g1er`/`g1fs`/`g1en`) | combo predicate; **loops/mux stay in IQ** | **soaked** lottery @558 FDT @2719 cookie t=83968 |
| **E4** | `g6lc_sib_cjalr` | **ID/SB:** `g1lo`/`ln`/`lz`/`hx`/`hy`/`ik`/`id`/`ij` + G1mf scan. `decoded_hd` field writes and flops stay in host | combo predicate | **soaked** lottery @558 FDT @2719 cookie t=83968 |
| **E4 FE** | extend `g6lc_sib_cjalr` | **Frontend:** LOAD capture/hit (`g1kk`/`g1le`/`g1lq`); +2 stash encodings (G1hj/jy); G1ie inject; G1iq present | combo predicate; **flops/mux stay in FE** | **soaked** lottery @558 FDT @2719 cookie t=83968 |
| **E9** | `g6lc_present` | mid-line 16-bit present (`g1gx`/`g1fu`/`g1ha`); +2 fills (G1fq/hc); npc +2 (G1fu–gd); realign G1bf/eu/ed | combo predicate; **mux/FSM stay in host** | **soaked** lottery @558 FDT @2719 cookie t=83968 |

### Stay in the host (leftover FSM / IQ rotate / NPC)

| Family | Where | Why |
|--------|-------|-----|
| Leftover-RVI complete / `serving_unaligned` | `instr_realign.sv` FSM; classify in `g6lc_leftover` | **soaked** thin wrapper; geometry FSM + per-hart banks stay |
| g1bv leftover-Branch stash + `g1ct` dest-only + `g1cc`/`g1cs` NPC hold | `frontend.sv` | sequential leftover; closed NPC stall family |
| Leftover jal x0 hide `g1gi`–`g1gm` | `frontend.sv` | 3-cycle hide + NPC reseed block; **next residual** (`mini_sib_cjalr` P2) may extend this — peel **after** that class, into hide helper not `cf_unissued` |
| IQ leftover Jump head / `idx_is` / FIFO oldest-PC | `instr_queue.sv` `g1da`/`g1dc`/`g1ds`/`g1az`/`g1cx` | tightly coupled to rotate; closed G1cg/ch/dr/ec |
| Frontend `g1lq` **producer** + leftover slot1 present (`g1lv`/`g1lw`) | `frontend.sv` | leftover present mux; ID **sink** peels with E4 |

### Practical order (one family per increment)

```text
E5 encodings  →  E2+ mid JumpR  →  E6 keep + E7 kill predicates
    →  E8 IQ hide  →  E4 sib_cjalr (ID/SB first, then FE latches)
    →  E9 present (layer 1)  →  leftover realign last
```

New SMT2 behavior (e.g. leftover `jal x0` after taken skip) **lands in a
`g6lc_*` hook**, not a new `g1*` flop in `frontend.sv`. Bit-identical extract
does **not** share an increment with a behavior change.

---

## E0 contract

| Field | Value |
|-------|--------|
| **I1** | Extract keep predicate only |
| **I2** | `mini_fdt_a0_is_fdt` still tohost=19 on slfix (Spike 1) |
| **I3** | `core/smt/g6lc_sb_keep.sv`; both scoreboard sites call it |
| **I4** | hold `51b1babe`+`51b1d000`; nat both cookies; peel pin unchanged |
| **I5** | none (no soft retire) |
| **I6** | E1 or G0-on-E1 — not I4cg |

**Timing:** same 5-bit compares on the existing cancel cone. No new flop,
clock, or SRAM. SI: `SuperscalarEn==0` still keeps only the cont.5 LOAD path.

---

## E7 contract

| Field | Value |
|-------|--------|
| **I1** | Extract I$ `kill_s1`/`kill_s2` spare predicates only |
| **I2** | lottery PASS @558; FDT PASS @2719 (tohost=0 after a few thousand cycles) |
| **I3** | `core/smt/g6lc_fe_kill.sv`; frontend mux stays |
| **I4** | hold cookie t=83968 `51b1babe`+`51b1d000`+BANR |
| **I5** | none (no soft retire) |
| **I6** | E8 `g6lc_iq_hide` — not leftover jal-x0 squash, not G1mg, not I4cg |

**Timing:** same `npc[2:1]` / leftover-Jump / c.beqz compares already on
the I$ kill cone. No new flop, clock, or SRAM. SI: `SuperscalarEn==0` or
`NrHarts==1` const-folds the spares to 0 (kill mux unchanged). G1jp/jr/js/hu/iy
stay dead.

---

## E8 contract

| Field | Value |
|-------|--------|
| **I1** | Extract IQ hide / slot1-keep predicates only |
| **I2** | lottery PASS @558; FDT PASS @2719 |
| **I3** | `core/smt/g6lc_iq_hide.sv`; hide loops and `valid[1]` mux stay in `instr_queue` |
| **I4** | hold cookie t=83968 `51b1babe`+`51b1d000`+BANR |
| **I5** | none (no soft retire) |
| **I6** | E4 `g6lc_sib_cjalr` — not leftover jal-x0 squash, not G1mg, not I4cg |

**Timing:** same opcode / rd / `pc[2:1]` compares already on the IQ consume
cone. No new flop, clock, or SRAM. SI: `SuperscalarEn==0` or `NrHarts==1`
const-folds the keeps/hides. G1fb/fc/fk/fm stay dead.

---

## E4 contract (ID/SB)

| Field | Value |
|-------|--------|
| **I1** | Extract ID recover predicates + SB G1mf scan only |
| **I2** | lottery PASS @558; FDT PASS @2719 |
| **I3** | `core/smt/g6lc_sib_cjalr.sv`; `decoded_hd` writes / g1hx/g1hy/g1lo flops stay in `id_stage` |
| **I4** | hold cookie t=83968 `51b1babe`+`51b1d000`+BANR |
| **I5** | none (no soft retire) |
| **I6** | E4 FE frontend latches — not leftover jal-x0 squash, not G1mg, not I4cg |

**Timing:** same `pc[2:1]` / encoding / 8B+16B line compares already on the
ID recover cone. No new flop, clock, or SRAM. SI: `SuperscalarEn==0` or
`NrHarts==1` const-folds the recover. G1je/lk/lm stay dead.

---

## E4 FE contract

| Field | Value |
|-------|--------|
| **I1** | Extract FE LOAD capture/hit, +2 stash encodings, constructed c.jalr |
| **I2** | lottery PASS @558; FDT PASS @2719 |
| **I3** | extend `g6lc_sib_cjalr.sv`; FE flops and present mux stay in `frontend.sv` |
| **I4** | hold cookie t=83968 `51b1babe`+`51b1d000`+BANR |
| **I5** | none (no soft retire) |
| **I6** | E9 `g6lc_present` — not leftover jal-x0 squash, not G1mg, not I4cg |

**Timing:** same I$ opcode / npc-line / sibling-01 compares already on the
present cone. No new flop, clock, or SRAM. G1jj/jw stay dead.

---

## E9 contract

| Field | Value |
|-------|--------|
| **I1** | Extract present-at-npc / mid-line 16-bit predicates only |
| **I2** | lottery PASS @558; FDT PASS @2719 |
| **I3** | `core/smt/g6lc_present.sv`; mux and leftover FSM stay in `frontend` / `instr_realign` |
| **I4** | hold cookie t=83968 `51b1babe`+`51b1d000`+BANR |
| **I5** | none (no soft retire) |
| **I6** | leftover realign last (thin wrapper) — then leftover jal-x0 squash; not G1mg, not I4cg |

**Timing:** same `npc[2:1]` / I$ line / 16-bit compares already on the present
cone. No new flop, clock, or SRAM. G1gz/es/bo/fx/fz stay dead.

---

## leftover realign contract

| Field | Value |
|-------|--------|
| **I1** | Thin wrapper of leftover-RVI classify / next-line / serving / G1cm |
| **I2** | lottery PASS @558; FDT PASS @2719 |
| **I3** | `core/smt/g6lc_leftover.sv`; geometry FSM + per-hart banks stay in `instr_realign` |
| **I4** | hold cookie t=83968 `51b1babe`+`51b1d000`+BANR |
| **I5** | none (no soft retire) |
| **I6** | leftover jal-x0 squash soaked — not G1mg, not I4cg |

**Timing:** same `[1:0]==11` / next-8B-line compares already on the realign
cone. No new flop, clock, or SRAM. G1as/dy stay dead. Combo extract ladder
complete.

---

## leftover jal-x0 squash contract

| Field | Value |
|-------|--------|
| **I1** | Hide leftover jal x0 after taken same-group skip; leftover-complete ALU keeps later slot |
| **I2** | `mini_sib_cjalr` PASS @431 printed 0; lottery PASS @558; FDT PASS @2719 |
| **I3** | `core/smt/g6lc_lj_hide.sv` + `g6lc_leftover` skip-arm/range; `g6lc_present` hc/hh npc 01, hm Jump-only |
| **I4** | hold+nat cookie t=83968 `51b1babe`+`51b1d000`+BANR |
| **I5** | none (soft getprop stays) |
| **I6** | Off-line leftover-PC replay kept. leftover_blocks_01 + G1hj consume-PC-match hygiene. G1hj/jy is_mispredict spare hygiene. stash_keep16 hygiene. stash_keep_pc hygiene (7ba never captured). load_flush_keep hygiene. plus2_stay + line_hi8_stay hygiene. hi8_npc_fetch MINI-FAIL lottery 4 @362 (G1ja) FDT 57 @445 (G1jd) — reverted. idle_sib16 / idle_load_sib HOLD-FAIL 51b1c001 (G1jw). later_br_01 MINI-FAIL FDT 23 (G1iz). sib8_fetch MINI-FAIL FDT hang @400000 (G1jd). lo11_npc00 MINI-FAIL sib P0 fail 1 @407 / FDT 0x10 @423 — reverted (jalr-target `[2:1]==11` is not leftover 766). lo_pc_npc00 HOLD-FAIL plat_hc=80 mepc 0xb0/2 — reverted (leftover I$ load-bearing at npc 00 first 8B). ljx0_off / ljx0_pc / ljx0_bp hygiene. sib_lo_s2 MINI-FAIL G1jp — reverted. lo_ld_stay HOLD-FAIL 51b1c001 — reverted. lo_ld_lo11 hygiene. hi8_lo11 MINI-FAIL FDT 57 @445 (G1jd) — reverted. load_flush_next16 hygiene (G1kk empty at 7ba). ld_until_01 MINI-FAIL FDT 106 @409 (G1lm) — reverted. leftover_off_npc00 hygiene (realign leftover_next onto 7b0 LOAD I$ is a no-op at n7b0). leftover_slot0_off_npc00 MINI-FAIL sib printed 4 @448 / lottery hang @400000 / FDT 17 @413 — reverted (skip_next analog). load00_vs_off16 hygiene (7b0 never in icache_data_q at n7b0). leftover_nx8_npc00 hygiene (leftover occupying + fetch leftover+8 not true at n7b0). leftover_hi8_s2 MINI-FAIL FDT 24 @201516 (G1hu) — reverted. load00_vs_lj hygiene (7b0 never registers). leftover_lo8_s2 hygiene (leftover occupying + same-8B in-flight not true at n7b0). load00_lo8_s2 hygiene (7b0 not a valid same-8B LOAD return at n7b0). Capture 7ba without leftover-RVI / hw11 / leftover+8 fetch rewrite, without leftover-Jump kill_s2 spare, without 7b0 I$ keep, without 16B-sibling kill_s2 spare, without LOAD-00 fetch keep, without 7b8 vs leftover-PC fetch rewrite, without registered-LOAD keep, without leftover_next-on-7b0-LOAD override, without npc-based leftover slot0 hide. Not G1gn, not G1mg, not hi8_npc_fetch, not lo11, not lo_pc, not sib_lo_s2, not lo_ld_stay, not hi8_lo11, not ld_until_01, not skip_next, not leftover_slot0_off |

**Timing:** one flop + PC on present/`is_jump` / npc-replay, SMT+SS only. G1hc/hh npc 01; G1hm leftover-complete slot1 inject only if leftover slot0 is Jump. skip_next leftover-complete — MINI-FAIL P1 printed 2; do not re-land.
