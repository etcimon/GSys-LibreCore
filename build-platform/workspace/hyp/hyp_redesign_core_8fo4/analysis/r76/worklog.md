# r76 worklog (append-only)

Pass r76 of the hyp8 redesign program. Scope: A1 config spine
(LoadPubStages + reserved stage fields + Hyp8Deep), F15 load_unit
publish-port collision fix, B1 LoadPubStages==2 registered publish
record, B3 rank-0 per-output-family splits, C1 F14 discriminator
probes, remote verification.

Baseline board for comparison: boards/hyp8-core/analyze-r73-all.json
(r73 tree). analyze-r76-pre.json taken with the r76 map before RTL
edits that move structure.

## A1 — config spine

Edits:
- core/include/g6lc_hyp_pkg.sv: 12 new g6lc_hyp_cfg_t fields
  (LoadPubStages, IqSteerStages, IqSelStages, RenameReadStages,
  FreelistPickStages, StoreTransStages, TlbCtxStages, LsqVerdictStages,
  CsrReadMuxStages, CommitStages, AesStages, MissunitResultStages);
  HypDefault + Hyp8 carry the bit-identical values (all 1 except
  MissunitResultStages=2 — the r75 AMO_RESULT_FORM formed-result
  register in wt_dcache_missunit.sv is UNCONDITIONAL today: verified
  at lines ~520-555, p_amo_result_ff has no HypCfg gate and the FSM
  always routes AMO_WAIT -> AMO_RESULT_FORM -> AMO_RESULT; per brief,
  both profiles bind 2 and the RTL is not re-gated this pass).
  New localparam Hyp8Deep = Hyp8 with LoadPubStages:2 (comment notes
  the other fields stay at Hyp8 values because their RTL arms do not
  exist yet). hyp_lat_cycles LAT_LOAD += (h.LoadPubStages - 1).
  hyp_cfg_ok: inside {1,2} for each (AesStages {1,3}); no
  cross-constraints per brief.
- core/ooo/g6lc_iq.sv: WAKE_LD = 2 + DcacheHitExtra + LoadUseExtra +
  (LoadPubStages - 1).
- core/include/g6lc64_hyp8_config_pkg.sv + g6lc64_hyp8_mc_config_pkg.sv:
  `ifdef G6LC_HYP8_DEEP` -> Hyp8Deep else Hyp8 (both pkgs bind HypCfg).
- verif/regress/remote/hyp8/hyp8-build-harness.sh: target
  g6lc64_hyp8_deep -> -DG6LC_HYP8_DEEP (usage line updated).
- analysis/r76-param-map.json sha256
  1f7e106685bf390bf40398e92594dedf7ee62249768f4694f361980a26fbe41a
- analysis/r76-param-map-deep.json sha256
  58bae0d952bc41c622531870328fd3062ddf0b357c7879978c28fa57dd1ff9b3

LAT_LOAD / "2 + HypCfg.DcacheHitExtra" consumers inventory:
- g6lc_iq.sv:138 WAKE_LD — CHANGED (+LoadPubStages-1).
- g6lc_iq_bank.sv:550 LAT_LOAD case loads cnt_b=WAKE_W'(4) — spec-wakeup
  countdown, inert under IqSpecWakeup==0 (Hyp8). NOT changed (listed
  only); would want +1 under a speculative deep profile.
- g6lc_ooo_pkg.sv:106 — maps LOAD -> LAT_LOAD class (symbolic, no
  numeric consumer).
- controller.sv:179 DRAIN_CYCLES term HypCfg.DcacheHitExtra+3 — a max()
  bound for drain; LoadPubStages adds +1 WB but the bound already has
  slack vs DecodeStages+2=5 / RenameStages+RenameResolveStages=5 under
  Hyp8 (DcacheHitExtra+3=5 too). NOT changed; noted.
- load_unit.sv:302 LD_HIT_LAT — rvalid latency, NOT publish latency;
  unchanged per brief.
- wt_dcache*.sv DcacheHitExtra uses — hit-latency staging, unrelated.

Lint note: stock WSL Verilator 5.020 produces 51 pre-existing
BLKANDNBLK %Errors in vendored cvfpu fpnew_fma.sv (documented r68 fix:
pass -Wno-BLKANDNBLK) plus 16 pre-existing IMPLICIT warnings in the
translate_off debug bind fetch_B/g6lc_fetch_dbg.sv. Verified identical
on the pristine pre-r76 tree (git stash + rerun). Criterion used: 0
fatal diagnostics outside that pre-existing set / in touched files.
Both plain and -DG6LC_HYP8_DEEP lint after A1: 16 (the fetch_dbg set),
0 in touched files.

## F15 — load_unit publish-port collision (KEPT, functional fix)

Edits (core/load_unit.sv):
- New wires before rvalid_output (~L1430): head_pub_wt (WAIT_TRANSLATION
  exception arm predicate), head_pub_spec (WAIT_SPEC_LOAD mispredicted
  write-off), head_pub_fwd (= st_fwd_done), head_pub = OR of the three.
- pub_fire: pub_any && !head_pub (else-arm); under
  G6LC_MUT_LU_PUB_COLLIDE restores pub_any (mutant, verified).
- Data arm `else if (pub_any)` -> `else if (pub_fire)` (both the normal
  and G6LC_MUT_LSU_EXPEND copies). Head arms textually unchanged.
- translate_off: lu_pop_is_presented SVA (ldbuf_r && pub_fire |->
  valid_o && trans_id_o == ldbuf_q[ldbuf_rindex].trans_id) +
  lu_f15_collide_n counter printed at final
  ([equiv] load_unit F15 head_pub&pub_any: n=%0d), ungated on plusarg.
- rf_* reference FSM checked: it has NO publish arms (FSM copy only) —
  no mirror needed.

tb (verif/tb/core/tb_g6lc_hyp8_memory.sv): drivable lu_pom/lu_sfv/
lu_sfd/lu_sfbe signals (were constants), TB_HYP HypCfg select under
`ifdef G6LC_HYP8_DEEP`, new section F15 (older slot A eligible the same
cycle younger STQ-covered head B publishes — A must publish next
cycle; mutant fails by name).

Verification (local WSL Verilator 5.020 leaf runner
analysis/r76/run_hyp8_mem_local.sh):
- plain: HYP8_MEMORY_PASS checked=160, F15 counter n=1.
- mutant (-DG6LC_MUT_LU_PUB_COLLIDE): FAILS by name at cycle 744 —
  lu_pop_is_presented fires (popped rindex=0 tid=4 while tid_o=6,
  head=001 = head_pub_fwd).

## B1 — LoadPubStages==2 record: COUNTERCASE, reverted

Implemented fully (prec_v_q/prec_oh_q/prec_idx_q/claim_q record,
pub_ok claim term, ptree_sel record gather, invariants, tb deep shims),
leaf verified: deep profile HYP8_MEMORY_PASS checked=160 (F15 n=1).
Boards:
- analyze-r76-lu.json (r76 map): 42.0 FO4 rr (limiter reg-to-reg
  load_unit.sv:1053, the WPO-hold state_d arm), inst/pres 35.8. The
  +1.0 vs 41.0 pre is F15's head_pub cone (st_fwd_done is the deepest
  load_control output, now also gating the pop) — lead-settled fix cost,
  not B1 (==1 arm is tied-off wires).
- analyze-r76-lu-deep.json (deep map): 47.0 FO4 rr, same :1053 FSM
  limiter; in-stage L5 fell to inst 36.1 but module max ROSE. The
  identical-code state_d path bills differently under the deep param
  map (record registers change the IR shape) — the record did not buy
  its stage.
Reverted B1 surgically (post-F15 text restored exactly; the zip
predates F15 so byte-exact restore would have removed the fix). All
record signals/miter/invariants/tb shims removed; comment left at the
miter site. Post-revert: grep 0 dangling refs, lint clean (16
pre-existing), leaf HYP8_MEMORY_PASS checked=160 n=1. Boards kept:
analyze-r76-lu.json / analyze-r76-lu-deep.json (+ .cmd files).
LoadPubStages stays declared (A1) with no ==2 arm — deep profile
builds identical RTL; LAT_LOAD/WAKE_LD +1 is inert (IqSpecWakeup=0
sizing only, no correctness consumer).

## B3 — NOT ATTEMPTED (budget)

Rank-0 per-output-family splits (g6lc_decode_s3, g6lc_decode_s2,
csr_regfile, g6lc_mmu, g6lc_fe_redirect) not started: B1's
implement-board-revert cycle consumed the session. Deferred to the
next pass; no files touched.

## C1 — F14 probes (landed, evidence captured)

Probes (+f14_trace, translate_off, page/lock-filtered):
- wt_axi_adapter.sv: adapter_aw (AW handshake + dcache_data
  rtype/amo_op/paddr) + adapter_ar (LR side, lock).
- g6lc_testharness.sv: slv_aw/slv_ar (master[DRAM], atomics slave
  side), mst_aw/mst_ar (dram, atomics master side), dram_lat_aw.
- g6lc_ai_dram_backend.sv gen_sim_axi: sim_axi_wr (req && we,
  addr/be/data).
- hyp8_tb.cpp: "f14_trace" added to verilog_plusargs allowlist
  (initial F14 run died on the unregistered plusarg — usage text).

## Remote verification

- closure remote-runs/hyp8-r76-closure: 731 files.
- hyp8-integration-r76: lint scalar/smt2 rc=0, 0 %Error, model sha
  785f87e09f19a90c541df4403769bc9b8fff2d2ed04ec57cb44f7ca8e94f4136,
  build_complete, 357.7s.
- hyp8-r76-smokes: h34=685 h33=1011 bc=492 csr_flush_skip=2364
  amo_store_order=2199 — cycle-IDENTICAL to r75 (F15 collision never
  fires on the smokes: counter n=0 each test). amo_ready_order rc=76
  and f14_store_offset rc=86 = the two known-failure tests,
  unchanged.
- hyp8-integration-r76b (f14_trace allowlist rebuild): rc=0, 231.7s.
- hyp8-r76-f14 (+f14_trace, on r76b): all 12 [f14] lines captured:
    [f14] adapter_aw t=426 addr=80001140 lock=0 atop=00 id=1 size=3 len=00 rtype=0 amo=0 paddr=80001140
    [f14] slv_aw     t=430 addr=80001140 lock=0 atop=00 id=01 size=3 len=00
    [f14] mst_aw     t=430 addr=80001140 lock=0 atop=00 id=01 size=3 len=00
    [f14] dram_lat_aw t=430 addr=80001140 lock=0 atop=00 id=01 size=3 len=00
    [f14] sim_axi_wr  t=431 addr=80001140 be=ff data=0000000000000099
    [f14] adapter_ar t=527 addr=80001180 lock=1 id=3 size=3 len=00
    [f14] slv_ar     t=531 addr=80001180 lock=1 id=03 size=3 len=00
    [f14] adapter_aw t=554 addr=80001180 lock=1 atop=00 id=3 size=3 len=00 rtype=2 amo=2 paddr=80001180
    [f14] slv_aw     t=558 addr=80001180 lock=1 atop=00 id=03 size=3 len=00
    [f14] mst_aw     t=558 addr=80001180 lock=0 atop=00 id=03 size=3 len=00
    [f14] dram_lat_aw t=558 addr=80001180 lock=0 atop=00 id=03 size=3 len=00
    [f14] sim_axi_wr  t=559 addr=80001180 be=ff data=00000000000000ad
  FINDING: the sc.d AW is INTACT at all five points — addr 0x80001180
  survives adapter -> atomics slv -> atomics mst (lock consumed
  1->0 as expected) -> dram_lat -> axi2mem/sram write (be=ff,
  data=0xad). No corrupted 0x80001000 AW exists anywhere in the run:
  the write-address corruption hypothesis is disproven for the AW
  path. The remaining suspects are downstream of sim_axi_wr (sram
  word-index slice) or a different mechanism entirely (reservation/
  verdict, second write overwriting, or the SC's success verdict
  itself). tohost=86 unchanged.
- NOT launched (out of session budget — commands ready):
  deep integration+smokes:
    testharness_proxy.py py verif/regress/remote/run_hyp8_integration.py
      --tag hyp8-integration-r76d --data remote-runs/hyp8-r76-closure
      --env HYP8_BUILD_TARGET=g6lc64_hyp8_deep --env HYP8_ALLOW_OVERLAP=1 --pull
    then run_hyp8_smokes.py --tag hyp8-r76d-smokes
      --env HYP8_INT_TAG=hyp8-integration-r76d --pull
  remote memory leaf: run_hyp8_memory.py HYP8_LEAF=memory (plain +
    HYP8_EXTRA_DEFINES=G6LC_HYP8_DEEP + G6LC_MUT_LU_PUB_COLLIDE mutant)
  witness: run_hyp8_witness.py tag hyp8-osbi-scalar-r47b on the r76
    model, mc2e firmware linux-scalar ac36f379, tohost 0x80041730,
    100M, +stall_census +hang_dump=2000 +equiv_report.

## F15b — superset gate form (KEPT)

head_pub_fwd = st_fwd_done replaced by the shallow superset
!data_rvalid && st_fwd_covers && ld_checked_head &&
(state_q[IDLE] || state_q[WPO]) — both st_fwd_done arms are subsets
(IDLE arm adds accept/spec-gate/!busy/page_offset_matches; WPO arm IS
fwd_final && !data_rvalid). lu_fwd_superset SVA added. Leaf:
HYP8_MEMORY_PASS checked=160, F15 n=1.

## L5 one-hot presentation (KEPT, replaces the B1 move)

rvalid_output's 7-arm last-writer-wins chain -> a_* predicates +
masked-OR outputs (module-level a_pend/a_expub/a_data/a_head/a_drn
wires; presentation terms masked !a_head; pops unmasked as today;
EXPEND arm order preserved; MUT_LU_L5_ARMS drops the mask).
ref_l5_chain (old chain verbatim) + lu_l5_onehot_eq every-cycle +
lu_l5_arm_exclusive $onehot0 (pend/expub provably exclusive with
a_head via state gates — asserted, never fired) + counter.
Leaf plain: PASS checked=160, L5 onehot checked=155.
L5_ARMS alone: PASSES — the mask is unreachable in the fixed design
(a_data ⊂ !a_head by the F15 gate; pend/expub && head excluded by
state gates). L5_ARMS+LU_PUB_COLLIDE: lu_pop_is_presented fires at
744 (the ungated pick pops while head wins — discriminates as
designed).
Board analyze-r76-lu2.json: 37.2 FO4 (rr 33.5 — F15b restored the
:1053 state_d path; inst 19.2 — the block re-bills one-hot; pres
37.2 new limiter "into L5 window 0"). vs 41.0 pre / 42.0 F15.
KEEP both.

## C1b — second F14 probe round (in r76c)

- g6lc_testharness.sv: dm_req/dm_rsp (dm_master_req/gnt/r_valid),
  dm_ar/dm_r/dm_aw/dm_w/dm_b on dm_axi_m_req/resp (the SBA = slave[1]);
  slv_r/mst_r on master[DRAM]/dram gated by NEW +f14_trace_r plusarg.
- g6lc_ai_dram_backend.sv gen_sim_axi: sim_axi_rd — latched req&&!we
  addr, rdata printed next cycle, page-0x80001 filtered.
- hyp8_tb.cpp: "f14_trace_r" allowlisted.
- store-side (st_commit/wbuf) probes not added — adapter_aw already
  covers every core-boundary AW to page 0x80001 and none was
  0x80001000 in the r76b run; the DM probes target the SBA-read
  hypothesis (ii).

## B3 — bounded, 1 of 3 done

- g6lc_decode_s3 KEPT: legality block partitioned (compare nets +
  illA..illD/virA..virD chain stay in `legality`; illegal/virt/
  fix_add/opfix moved to `legality_out`; ~30 net decls hoisted).
  Board analyze-r76-ds3.json: pres 52.3 vs r73 53.7 — the targeted
  :275 bundle fell (new top locus is the assemble/ex_assemble chain,
  L378/L441). Marginal drop but a drop — kept. Lint clean.
- g6lc_fe_redirect, g6lc_mmu: NOT attempted (budget).

## Remote r76c results + C1b evidence

- hyp8-integration-r76c: rc=0, 356.0s (lint rc=0/0 %Error on the
  F15b+L5-onehot+decode_s3+C1b tree).
- hyp8-r76c-smokes: 685/1011/492/2364/2199 — CYCLE-IDENTICAL to r74/
  r75/r76 (L5 onehot + decode_s3 split are truly bit-identical);
  amo_ready_order rc=76, f14_store_offset rc=86 unchanged.
- hyp8-r76c-f14 (+f14_trace +f14_trace_r): probes fire at all points.
  Key [f14] lines (verbatim, see output/hyp8_f14_store_offset.log):
    adapter_aw t=426 addr=80001140 lock=0 rtype=0 amo=0 paddr=80001140
    slv_aw/mst_aw/dram_lat_aw t=430 addr=80001140
    sim_axi_wr t=431 addr=80001140 be=ff data=99
    slv_r/mst_r/sim_axi_rd t=491 addr=80001140 data=99 (correct readback)
    adapter_ar t=527 addr=80001180 lock=1 (LR)
    slv_r t=532 id=03 data=0 resp=1 (LR: EXOK through slv, the atomics
      answered the exclusive itself — mst_r shows resp=0 for the DRAM)
    adapter_aw t=554 addr=80001180 lock=1 rtype=2 amo=2 paddr=80001180
    slv_aw t=558 lock=1 -> mst_aw lock=0 -> dram_lat -> sim_axi_wr
      addr=80001180 be=ff data=ad
  (i) Did the core ever issue AW/W for 0x80001000? NO — not at
      adapter_aw, slv_aw, mst_aw, dram_lat_aw, or sim_axi_wr; the
      complete AW list is 0x80001140 (sd=0x99) + 0x80001180 (sc.d=0xad).
      The final sw to tohost never appeared either (tohost is outside
      page 0x80001 OR never issued).
  (ii) The DM SBA path produced ZERO transactions — no dm_ar/dm_r/
      dm_aw/dm_w/dm_b/dm_req/dm_rsp lines exist in the whole log.
      fesvr's tohost polling is host-side memory poke, not in-sim AXI;
      the hypothesis "axi_adapter SBA returns another transaction's
      data" is DISPROVEN (the path is not exercised).
  (iii) 0xAD first appears on a non-SC transaction: NEVER — 0xad only
      ever rides the SC's own AW chain, which is correct end-to-end.
  CONCLUSION: with the AW path clean at all 5 points, the DM path
  unused, and the backend's axi2mem `addr` printing 0x80001180 while
  fesvr reads 0xAD at tohost — the corruption must sit between
  `sim_axi_wr`'s printed `addr` and the physical storage/read
  element: candidates are i_sram's index slice
  `addr[$clog2(NUM_WORDS)-1+3:3]` aliasing 0x80001180 to the tohost
  word, or the host-side read of the backend array. The next probe
  should print the sram index (`addr[...]` slice value) at the write
  and the array location the host reads for tohost.
- hyp8-osbi-scalar-r47b: detached witness LAUNCHED on r76c model
  (sha ba8cb3858360…), linux-scalar elf ac36f37942ad…, tohost
  0x80041730, 100M cycles, +stall_census +hang_dump=2000
  +equiv_report, remote pid 1952306. Collect:
  testharness_proxy.py pull --tag hyp8-osbi-scalar-r47b
  (run-hyp8.log milestones when it finishes). Left running per brief.

## F14 RESOLVED — observer defect, not memory corruption

Lead verdict confirmed by Step-1 evidence line (hyp8-r76d-f14 on
r76d build — rvfi_tracer end_of_test print added):
  *** [rvfi_tracer] INFO: end_of_test pc=0000000080000030
      insn=18e838af mem_addr=0000000080001180
      mem_paddr=00000080001000 mem_wmask=ff mem_wdata=00000000000000ad
insn=sc.d (18e838af), mem_addr=its own vaddr 0x80001180,
mem_paddr=0x80001000 = the speculative STQ head = tohost (the final
sw sitting in the STQ behind the uncommitted SC), wdata=0xAD bit0=1
-> tracer declared tohost=0xAD and stopped the sim before the sw
drained — consistent with "no AW to 0x80001000 ever issued" and
"0xAD on no other transaction". amo_ready_order rc=76 is the same
shape (0x99).

## Step 2 — per-instruction store/AMO paddr in RVFI (implemented)

- store_buffer.sv: rvfi_st_push_{valid,tid,paddr}_o = the spec-queue
  accept strobe (valid_i / trans_id_i / paddr_i).
- store_unit.sv: passes those through + rvfi_amo_push_* =
  amo_buffer_valid / trans_id_q / paddr_i (the buffer's own accept;
  tid lives in store_unit — amo_buffer.sv NOT edited, deviation from
  brief: amo_buffer has no trans_id port, the push is described
  completely at the instantiation site).
- Threaded load_store_unit -> ex_stage -> g6lc_core ->
  g6lc_rvfi_probes (6 new fields in RVFI_PROBES_INSTR_T macro,
  rvfi_types.svh) -> g6lc_rvfi.sv.
- g6lc_rvfi.sv: sb_mem_t += lsu_paddr + paddr_valid; capture keyed by
  push tid; commit mem_paddr = paddr_valid ? lsu_paddr : mem_paddr
  (loads keep old bus; upstream TODO preserved + r76 note);
  lu_paddr_captured assertion (ifndef SYNTHESIS): committing
  store/AMO with lsu_wmask!=0 has paddr_valid.
- hyp8_f14_store_offset.S header rewritten to the resolved mechanism;
  test + fail-code table kept.
- rvfi_tracer.sv: end_of_test INFO line prints pc/insn/mem_addr/
  mem_paddr/wmask/wdata (always-on, one line/sim) — kept.
Local lint after all Step-2 edits: 0 new diagnostics (same 16
pre-existing fetch_dbg IMPLICIT).

## Step 2 verification — r76e (all green)

- hyp8-integration-r76e: rc=0, 358.7s (two fixes en route: adjacent
  string literals don't concat in the $error (Verilog), and the
  local name is commit_ack not commit_ack_i).
- hyp8-r76e-smokes: ALL SEVEN PASS —
  h34=685 h33=1011 bc=492 csr_flush_skip=2364 amo_store_order=2199
  amo_ready_order=1231 rc=0 (was 76) f14_store_offset=671 rc=0
  (was 86). Both former known-failures now SUCCESS at their real
  verdicts.
- hyp8-r76e-f14 (+f14_trace): the end_of_test line now shows the
  sw's own record:
    insn=00532023 mem_addr=80001000 mem_paddr=80001000 wmask=0f
    wdata=0000000000000001
  (the sw reports its own paddr=tohost with data=1 -> SUCCESS).
  The AW to 0x80001000 does NOT appear in the [f14] log: the sim
  terminates at the sw's RVFI commit, before its STQ drain issues
  the AW — exactly why the corrupted run also showed no such AW.
- hyp8-r76e-amo (+f14_trace): SUCCESS tohost=0, end_of_test shows
  insn=00532023 mem_addr=mem_paddr=80001000 wdata=1.

## Step 3 — B3 remaining

- g6lc_fe_redirect KEPT: arb_select split per output family —
  arb_select_id (valid/src skeleton + lower-source chain),
  arb_select_pc (address skeleton), arb_select_ctl (step/reseed/trap);
  arb_no_arch alias replaces the !arb_valid gate. Board
  analyze-r76-fer.json: pres 30.0 vs r73 33.1 — drop, kept.
- g6lc_mmu: NOT attempted (budget).

## Step 4 — witness r47b (alive)

stall-census at 4M cycles: ret=1,105,424, ipc=0.276, no [hang]
blocks; run continues detached (pid 1952306). [equiv] counters are
final-only — nothing to report yet. Collect:
testharness_proxy.py pull --tag hyp8-osbi-scalar-r47b

## r76 close

Batch-end board boards/hyp8-core/analyze-r76-all.json (r76 map,
--all-modules --stages): structural clock = 1.08 GHz (37.2 FO4,
load_unit, into L5 (window 0)) vs r73's 0.97 GHz (41.0, load_unit,
in-stage L5). Diff vs analyze-r73-all.json (nonzero rows):
  load_unit           41.0 -> 37.2  (FO4 -3.8; rr 33.5 inst 19.2 pres 37.2)
  wt_dcache_missunit  +13.1 dFO4 (30.0 rr; not edited in r76 — a
    billing drift vs r73 on the r75 formed-result register locus
    :512; recorded, not chased this pass)
Rows changed but absent from the FO4-column diff (no registers /
presentation-only rows):
  g6lc_decode_s3      pres 53.7 -> 52.3 (legality split, kept)
  g6lc_fe_redirect    pres 33.1 -> 30.0 (arb_select split, kept)
  g6lc_mmu            unchanged 33.6 (split not attempted — interface
    blocks' nested if-chains did not fit the budget)
Lead edit: g6lc_rvfi lu_paddr_captured antecedent tightened with
!ex_commit_valid && !commit_drop (an excepted-committing store never
pushed) — verified in r76f integration lint (rc=0, 0 %Error).

hyp8-integration-r76f: model sha
173e27c7e1cb5edb73c6b31019294de74e497b7329406fb611efd48990d38416,
lint scalar/smt2 rc=0 0 %Error. hyp8-r76f-smokes: 7/7 PASS —
685/1011/492/2364/2199 + amo_ready_order 1231 + f14_store_offset 671.

Witness hyp8-osbi-scalar-r47b at last poll: 6 stall-census prints
(~12M cycles, ret ~3.3M cum), UART bytes flowing, l1 wbuffer drop
lines, no [hang]; running detached pid 1952306. Collect:
testharness_proxy.py pull --tag hyp8-osbi-scalar-r47b

Files changed this pass:
hyp core (build-platform/workspace/hyp/hyp_redesign_core_8fo4/core):
  include/g6lc_hyp_pkg.sv — r76 config fields + Hyp8Deep + LAT_LOAD/ok.
  include/g6lc64_hyp8_config_pkg.sv — G6LC_HYP8_DEEP selects Hyp8Deep.
  include/g6lc64_hyp8_mc_config_pkg.sv — same.
  include/rvfi_types.svh — 6 push fields in RVFI_PROBES_INSTR_T.
  ooo/g6lc_iq.sv — WAKE_LD follows hyp_lat_cycles LoadPubStages.
  load_unit.sv — F15 head_pub gate (F15b superset), L5 onehot arms,
    equivalence refs/counters/assertions (B1 countercase reverted).
  store_buffer.sv — rvfi_st_push_* outputs at the spec-queue accept.
  store_unit.sv — rvfi_st_push_* pass + rvfi_amo_push_* outputs.
  load_store_unit.sv — push triplets pass-through.
  ex_stage.sv — same.
  g6lc_core.sv — push wires + lsu/probes connections.
  g6lc_rvfi_probes.sv — push fields packed into the probe struct.
  cache_subsystem/wt_axi_adapter.sv — [f14] adapter_aw/adapter_ar
    probes (+f14_trace).
  g6lc_decode_s3.sv — legality/legality_out split (kept 52.3).
  frontend/g6lc_fe_redirect.sv — arb_select 3-family split (kept 30.0).
hyp APU/tb (hyp_redesign_corev_apu_8fo4):
  corev_apu/tb/g6lc_testharness.sv — [f14] slv/mst/dram_lat AW+AR,
    dm_* SBA probes, slv_r/mst_r (+f14_trace_r).
  corev_apu/tb/rvfi_tracer.sv — end_of_test INFO prints the record.
  corev_apu/src/g6lc_ai_dram_backend.sv — sim_axi_wr + sim_axi_rd.
  third_party/core/g6lc_rvfi.sv — lsu_paddr/paddr_valid in mem_q,
    push capture, per-instruction mem_paddr, lu_paddr_captured (lead-
    tightened antecedent).
repo-side (verif/):
  verif/tb/core/tb_g6lc_hyp8_memory.sv — F15 case + drivable fwd
    signals + TB_HYP deep select.
  verif/regress/remote/hyp8/hyp8-build-harness.sh — g6lc64_hyp8_deep.
  verif/regress/remote/hyp8/hyp8_tb.cpp — f14_trace + f14_trace_r.
  verif/tests/custom/hyp8_f14_store_offset.S — header rewritten to the
    resolved mechanism (test kept).
  analysis/r76/run_hyp8_mem_local.sh — local leaf runner (plain/deep/
    mutant).
Not done: B3 g6lc_mmu; deep-profile remote integration; remote
memory leaf (local leaf is the gate: PASS 160 plain/deep/mutant).
Countercases: B1 record (deep board 47.0>42.0) — reverted.
