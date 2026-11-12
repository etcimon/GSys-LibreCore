# r127 — implementation worklog (uncommitted working tree on HEAD `e41453510`)

Companion to `fo4-census.md` (analysis). Structural screen: delay-v50 binary of record,
fo4_ps=20, margin 0.2, budget 8.0, argv of `r115/boards/core-all-r115` replayed by
`reboard_current.py`. Not STA. No boot claim. Nothing committed.

## Instrument

- `analysis/timing/hyp8-core.f`: `core/frontend/g6lc_fe_frontier.sv` added (live, was unmeasured).
  `reboard_current.py` appends `g6lc_fe_frontier` to the r115 module list by default
  (`--add-modules`), and replays any other board log with `--argv-from` (used for the APU groups).
- `run_hyp8_leaf_local.sh <leaf> [tag]`: local full-flist leaf for every `tb_g6lc_hyp8_<leaf>` top
  of `tb_g6lc_hyp8_control.sv`; `run_leaves.sh <tag> <leaf>...` runs several.
- `elab_three.sh <tag>` + `elab_check.py`: elaborate default / `G6LC_HYP8_MMU_STAGED` /
  `G6LC_HYP8_DEEP` and compare cell sets, `HypCfg` constants and staging localparams.
- Remote harness: `testharness_proxy.py doctor` reports no hyp8 model/toolchain slot (`hyp8: -`);
  no remote smokes were run in this pass. Local gates only.
- `tb_g6lc_hyp8_memory` (local Verilator 5.020) fails `FWD_RSP_POSSIBLE` at cycle 152 on a pristine
  `git archive HEAD` copy of the core as well — pre-existing on this toolchain, not usable as a gate here.

## Landed (hyp core), each with its board and gate

| Item | File | Board (module row) | Gate |
|---|---|---|---|
| orc.b per byte lane | `core/alu.sv` | 40.6 → 32.9 (next: word shift L946, 26.0) | `HYP8_ALU_PASS checked=19508` |
| return-decoder priority on raw requests | `core/cache_subsystem/wt_axi_adapter.sv` | 40.3 → 32.0 | `g6lc_r127_rtrn_eq` (old chain every cycle); dcache leaf pending |
| NH≤1 frontier hart index constant | `core/ooo/g6lc_iq_legal.sv` | 31.3 → 18.6 (rr 15.2) | `HYP8_IQLEG_PASS checked=23`; NH=2 lint clean; `g6lc_r127_iqleg_hart` |
| fixup "active coalesced" = head slot matches | `core/cache_subsystem/wt_dcache_wbuffer.sv` | rr 41.7 → 32.9 (module now 39.5 reg→out, the forward presentation L1294/L1308) | `g6lc_r127_fixup_head_eq`; dcache leaf pending |
| commit winner in slot order | `core/stb_fwd.sv` | 36.9 → 25.6 (rr 19.0) | `tb_g6lc_hyp8_cwin_eq` exhaustive at D=4 and D=8: `HYP8_CWIN_EQ_PASS checked=525312` (`verif/regress/remote/hyp8/run_cwin_eq.sh`); in-module `g6lc_r127_cwin_eq` keeps the old form every cycle |
| drain rank by constant mask | `core/id_stage.sv` | 30.7 → 14.7 | same value by construction; dispatch leaf |

| availability bits registered with the captured address (A134) | `core/fetch_B/instr_realign.sv` | 40.5 → 34.5 (next: carry select L504→L569, slot gather L532) | `HYP8_REALIGN_PASS checked=59` with `g6lc_r127_rl_avail_eq` / `_nz_eq` active (`--assert`) |

Measured and reverted: `g6lc_iq` steer in slot order (hint thermometer + two isolates instead of
rotate / `x & -x` / rotate back): 36.0 → 36.5 on `rl-iq-r127`, restored with `git checkout`.
The steer row is the lane-serial `nused` dependence, not the rotate.

Final local gate `gate-r127d.log` (WSL Verilator 5.020, `--assert`, all r127 edits in the tree):
lint clean of fatal classes (7 known `sb_head` CMPCONST) · `HYP8_IQLEG_PASS 23` · NH=2 lint clean ·
`HYP8_CWIN_EQ_PASS 525312` · `HYP8_ALU_PASS 19508` · `HYP8_DISPATCH_PASS 125` ·
`HYP8_REALIGN_PASS 59` · `HYP8_QUEUE_PASS 126` · `HYP8_LSQ_PASS 2826` ·
`HYP8_DCACHE_PASS 334 dchx=2 stores=88`. The `mmu` leaf does not build locally
(`-Werror-LATCH` on `g6lc_tlb.sv:597`, a file this pass did not touch).
Board `core-all-r127-final` vs `core-all-r127-v50`: alu 40.6 → 32.9 · iq_legal 31.3 → 18.6 ·
id_stage 30.7 → 14.7 · instr_realign 40.5 → 34.5 · stb_fwd 36.9 → 25.6 · wt_axi_adapter
40.3 → 32.0 · wt_dcache_wbuffer rr 41.7 → 32.9 (any 39.5) · `g6lc_fe_frontier` now measured
(21.5 in→out). Board worst unchanged: csr_regfile 52.6. Clock rule now: csr_regfile 52.6,
loop_buffer 46.9, load_unit 44.3, ptw 36.0, missunit 36.0, realign 34.5, tlb 34.1.

Limits of this evidence: local leaves only; no smoke set, no boot witness, no pinned remote
runtime. `stb_fwd`'s exhaustive bench compares transcribed copies of the two forms (the in-module
assertion checks the module itself in any simulation that elaborates the store buffer; none was
run). The `id_stage`, `alu` and `wt_axi_adapter` edits rest on construction plus lint; their
in-module assertions were not shown to be exercised by a passing leaf.

## Not done in this pass

- Latency-changing contracts: wbuffer versioned pending writes, realign per-position targets,
  `IqSteerStages` / `IqSelStages`. They need the smoke set and a witness, which this host cannot run.
- Any APU RTL change (boards only).
- Remaining core rank-0 items with probe evidence: rename_read pick, instr_queue placement,
  per-byte sliced selects (csr_regfile, dispatch/prf, mmu), loop_buffer fill, load_unit pop,
  store_unit lanes.

Full-core lint after the first three (`lint_hyp8_core_local.sh`, `OUT_DIR` under workspace/build):
clean of fatal classes, 7 known `sb_head` CMPCONST. Dispatch leaf on that tree:
`HYP8_DISPATCH_PASS checked=125 pop_take_same=0 opasm_int=1 opasm_fp=1`.

## Profile threading (functional seam, default netlist unchanged)

- `load_store_unit.sv` passes `.HypCfg` to `g6lc_mmu`; `ex_stage.sv` passes it to
  `load_store_unit`; `wt_cache_subsystem` gained a `HypCfg` parameter threaded from
  `g6lc_core` to `wt_dcache`.
- `g6lc_hyp_pkg::hyp_mmu_unstaged(h)` returns `h` with `TlbStages=1`, `PtwDecodeStage=0` — the
  MMU staging every integration build and boot witness has actually elaborated. Both config
  packages bind `HypCfg = hyp_mmu_unstaged(HypCfgSel)` by default and `HypCfgSel` as declared
  under `-DG6LC_HYP8_MMU_STAGED`.
- Evidence (`elab_three.sh r127b`, 0 %Error and 0 fatal-class in all three):
  default = **same 2499 cells** as before the edit, `TLB_STAGED=0 PDEC=0 STLB_DLY=0`, MMU now
  carries the core's profile constant (only the unused `scoreboard` default differs);
  `G6LC_HYP8_MMU_STAGED` = 2498 cells (`g6lc_ptw_leg_decode` gone), `TLB_STAGED=1 PDEC=1
  STLB_DLY=2`; `G6LC_HYP8_DEEP` = `load_unit LU_EXPEND=1` (the deep profile reaches the LSU for
  the first time).
- Decision recorded: the staged MMU is NOT the default. It has never run in the integrated core;
  it needs its own smokes and boot witness before it replaces the unstaged binding.
- Owed: a param map of record with `HypCfg.TlbStages=1`, `HypCfg.PtwDecodeStage=0` for boards of
  the default binding (`params-mmu-hypdefault.json` has those two among other HypDefault values;
  use a Hyp8 map with only those two overridden).

## APU boards (current tree, same argv as r96 `current-*`)

`boards/apu-{ai,coh,l2,l3}-r127.json`. Worst rows: ai — `g6lc_ai_fp_dot` 271.5 io bundle,
`g6lc_ai_gemm_arplan` 149.0 rr (L210 three-operand address + L218 `dram_beats_in_stripe`),
`g6lc_ai_cluster_set` 71.5 (L67 behavioural `a0*b0+a1*b1`, P4 atomic), `g6lc_ai_gemm_seq` 52.0
(L3164 `store_reset` → `state_d`), `g6lc_ai_desc_engine` 46.5 (L284 span select); coh —
`g6lc_inval_bus` 123.3, `g6lc_coherence_hub` 121.6 (the r94/r96 sink/reset aggregates);
l2 — `g6lc_l2_top` 59.9 (collector → `wr_b_done_d`), `g6lc_l2_mshr` 39.8, `g6lc_l2_tag` 36.0;
l3 — `g6lc_l2_top` 62.7, `g6lc_l2_tag` 41.6. Liveness of these rows under the APU top is not
established in this pass (r96 M96-GEN/M96-SINK notes apply).

## Goal state (continuation ledger; update every step)

Goal: finish every "not done" item, implement all census items, reduce FO4 on all APU groups.
Inferred decisions: (1) latency-changing contracts are implemented as HypCfg-gated arms whose
Hyp8 default keeps today's netlist; new arms are qualified by local leaves, and by remote
smokes/witness when the harness accepts a run; (2) the staged MMU stays behind
`G6LC_HYP8_MMU_STAGED` until a witness passes; (3) keep-only-on-measured-drop, revert byte-exact.
Tools: `reboard_current.py <tag> --modules a,b` (core argv) / `--argv-from ../r96/boards/current-<g>.log`
(APU groups ai|coh|l2|l3); `census.py top|path`; `run_gate.sh <tag> [leaves]`
(default alu dispatch realign queue lsq dcache); `elab_three.sh <tag>`; probes under `probes/`.
Order: A remote integration of the r127 tree · B core rank-0 (rename_read pick, instr_queue
placement, csr_regfile/dispatch/prf/mmu sliced selects, loop_buffer fill, load_unit pop,
store_unit lanes) · C staged contracts (IqSteerStages, wbuffer, realign) · D APU (ai: fp_dot,
gemm_arplan, cluster_set, gemm_seq, desc_engine, fp32_norm, island_top; coh: inval_bus,
coherence_hub, snoop_filter; l2/l3: l2_top, l2_mshr, l2_tag).

| Step | Status |
|---|---|
| A remote integration | DONE for closure-r127 (7 exact edits + HypCfg threading, BEFORE the rename_read pick): `hyp8-r127-aggregate-t1` lint scalar/smt2 rc=0, 0 %Error, model `0c9b121543d24e75`; `hyp8-r127-smokes-t1` **12/12 pass, cycle counts identical to r126** (685/1011/492/2364/2199/1231/671/3038/9095/5959/883/983). Summary: `build-platform/workspace/build/r127-remote/r127.summary.txt`. Re-run `remote_gate.sh <tag>` after each batch (build closure first). |
| B core rank-0 remainder | IN PROGRESS. KEPT+GATED: `g6lc_rename_read` group-hierarchy pick 51.0 -> 40.2 (`gate-r127e.log`: lint clean, `HYP8_DISPATCH_PASS 125`, `[equiv] g6lc_rename r127 pick: checked=619`). REVERTED: `ck_slot_w` generate arm for the checkpoint slot (board `rr-ckslot` 40.2 -> 49.3, worse; the function form stays). BOARDED (csr-lanes: module 52.6 -> 52.1, limiter moved from dpc_d L3759 to pmpaddr L2957; dpc/mepc/sepc rows gone from the top), `gate-r127f.log`: full lint clean (7 known), `HYP8_DISPATCH_PASS 125`; the `csr` leaf did NOT build under run_hyp8_leaf_local.sh (needs `mut_commit_stage_delayed.sv` + `mut_csr_buffer_gated.sv`, see run_hyp8_memory.py LEAFS['csr'] sources) so the rf_* dpc/mepc/sepc assertions are NOT yet exercised — next: locate the two mut files, run the csr leaf with them appended, else rely on remote smokes (--assert): `csr_regfile` dpc/mepc/sepc per-byte-lane selects (`dpc_s`/`mepc_trap_s`/`sepc_trap_s` written in csr_update, lane muxes in `gen_epc_lane` before it; rf_* asserts are the check; revert = `git checkout core/csr_regfile.sv`). Next for csr_regfile: pmpaddr 52.1 (L2957). Remaining: instr_queue placement, dispatch/prf/mmu per-byte selects, loop_buffer fill, load_unit pop, store_unit lanes. Remote closure-r127 predates the rename_read pick edit. |
| C staged contracts | pending |
| D APU reductions | pending |

### Remote recipe (verified 2026-11-11: harness alive, toolchains present, r126 witness pid 726659 running — never kill it)

`testharness_proxy.py shell` needs `--allow-overlap` while the witness runs. Integration of a tree:
`python verif/regress/remote/hyp8/build_closure.py build-platform/workspace/build/closure-<tag>` then (WSL)
`python3 verif/regress/remote/testharness_proxy.py --timeout 0 py --tag hyp8-<tag>-aggregate-t1 --threads 1`
`--env HYP8_ALLOW_OVERLAP=1 --env HYP8_VERILATOR_DIR=/opt/testharness/toolchains/verilator-v5.008-g6lc-44063db8-pgo`
`--env HYP8_RUNTIME_DIR=/opt/testharness/toolchains/verilator-v5.008-g6lc-44063db8-pgo/runtime`
`--env HYP8_RUNTIME_DIGEST=e900ec451629715860e4faffdce5127f5f118ddcaa433125b79f12d3cbb718f8`
`--env HYP8_VERILATOR_FLAVOUR=g6lc --env HYP8_VERILATOR_THREADS=1 --env HYP8_BUILD_JOBS=6 --env HYP8_BUILD_TIMEOUT=14400`
`--data build-platform/workspace/build/closure-<tag> --pull --dest remote-runs/hyp8-<tag>-aggregate-t1 verif/regress/remote/run_hyp8_integration.py`
(`remote-runs` is a WSL-only symlink to ~/cva6-remote-runs; read results through WSL.) Smokes:
same proxy with `--env HYP8_INT_TAG=hyp8-<tag>-aggregate-t1 ... verif/regress/remote/run_hyp8_smokes.py`.
Baseline of record (r126, 12/12): h34 685, h33 1011, branch_cancel 492, csr_flush_skip 2364,
amo_store_order 2199, amo_ready_order 1231, f14 671, h35 3038, h36 9095, h37 5959, h38 883, lrsc_store 983.
The r126 build used PGO + 4 model threads (witness model); a smoke gate needs neither.

### B notes (so the next step does not re-derive them)

- `instr_queue` L268: `valid` is NOT dense from slot 0 (the frontend prefix filter can drop leading
  slots), so the probe's `therm = valid` shortcut is not exact. The exact form is
  `fifo_pos = rotl(thermometer(popcount(valid)), idx_is_q)`; `slot_fifo` must stay for
  `consumed_o` (L291) and `fsel_hit` (L355). Probe the popcount-thermometer form before editing;
  the 11.7 at L268 is a width-defaulted 2-bit add (over-billed), so the real gain may be small.
- `g6lc_rename_read` next limiter L437 `ckpt_slot_n` (22.5, function call) + L428 three-operand
  sum (9.2); a generate arm for the power-of-two slot measured worse and was reverted.

- `csr_regfile` dpc/mepc/sepc plan (NOT yet edited): all three `_d` are written only inside
  `csr_update` (L3391; default `csr_apply ? x_w : x_q` at L3409/3436/3459, overrides at
  L3634 sepc, L3653 mepc, L3749 + L3759-3771 dpc) and never read there; the `rf_*` shadow
  (`csr_update_ref` L4029, asserts L5789/5861/5911 `rf_x_d == x_d`) re-derives them, so a
  rewrite is self-checked by any sim with assertions (remote smokes build with `--assert`).
  Form to apply (probe B7, 27.5 -> 13.1): move the three final writes out of `csr_update`
  into per-byte-lane generates whose one-hot select predicates are recomputed per lane
  (dpc: hold / pc_i sext (trap arms, `G6LCCfg.DebugEn && !debug_mode_q`) / single-step arm
  tgt|tvec|epc|pc+2/4 with step winning; mepc/sepc: hold vs sext(pc_i) under `take_ex_w` and
  the trap-target-privilege test). Verify the enclosing conditions at L3606-3660 and
  L3686-3780 before editing; board with `--modules csr_regfile`; gate = lint + remote smokes.

- csr leaf locally: `run_gate.sh <tag> csr` now appends `core/neg/mut_commit_stage_delayed.sv` and
  `core/neg/mut_csr_buffer_gated.sv` after the flist (`LEAF_EXTRA_SRCS`); first attempt failed only
  on compile order. Status of the csr-lane edit gate: run `run_gate.sh r127g csr` and read
  `gate-r127g.log` (pass token `HYP8_CSR_PASS`; any `two-phase split mismatch` = revert csr_regfile.sv).

- csr leaf result on the r127 tree (`gate-r127g.log`): FAIL `CSRTAB_LEGAL_FIRE_1` at tick 408
  (tb_g6lc_hyp8_control.sv:257) — a csr_buffer table check, not a `two-phase split mismatch`.
  Discriminator in flight: same leaf with HEAD `csr_regfile.sv` swapped in (tag `r127g-headcsr`).
  The r127 lane edit is saved at `build-platform/workspace/build/r127-whatif/csr_regfile.r127.sv`;
  if the working file is found equal to HEAD, copy that back. Same failure with HEAD csr_regfile
  => pre-existing on local Verilator 5.020 (keep the edit, rely on remote smokes); pass with HEAD
  => the lane edit is wrong: revert it.

- csr leaf A/B DONE (`csr_ab_head.sh`, flist substitution, working tree untouched): with HEAD's
  `csr_regfile.sv` the leaf fails the SAME way (rc=134, `$stop` at tb_g6lc_hyp8_control.sv:257).
  => the csr leaf failure is pre-existing on local Verilator 5.020, not caused by the lane edit.
  The csr-lane edit is KEPT (board 52.6 -> 52.1, limiter now pmpaddr L2957); its functional gate
  is the next remote smoke run (`--assert`, `rf_x_d == x_d` asserts). The r127 lane version is
  the working file (verified restored).

- Remote gate LAUNCHED for closure-r127b (= r127 + rename_read group pick + csr_regfile epc lanes):
  `remote_gate.sh r127b`; result in `build-platform/workspace/build/r127-remote/r127b.summary.txt`.
  Expect 12/12 at the r126 cycle counts. Any `two-phase split mismatch` or `equiv free-list pick`
  in `remote-runs/hyp8-r127b-smokes-t1/*.log` (read via WSL) = revert that edit.

- NEXT STEPS (in order): (1) read `build-platform/workspace/build/r127-remote/r127b.summary.txt`
  (12/12 expected) and mark rename_read pick + csr epc lanes as remotely gated; (2) `g6lc_mmu`
  L936 `lsu_paddr_o` PPN select: with RVH=0 the `(chk_en_ld_st_g_translation && G6LCCfg.RVH)`
  select is constant-false — replace by an `if (G6LCCfg.RVH)` generate/constant arm so no
  64-load select is built (board `--modules g6lc_mmu`, was 31.6); (3) `g6lc_prf` L71/L72 and
  `g6lc_ooo_dispatch` L1287 per-byte replicated bypass selects (probe B8 25.1 -> 5.5);
  (4) `g6lc_loop_buffer` L281/L353 unconditional slot write (probe 31.5 -> 20.7);
  (5) `load_unit` L1639/L486 one-hot pop mask; (6) `store_unit` L598 per-byte lanes;
  (7) `instr_queue` placement (probe the popcount-thermometer form first); then C and D.

- `g6lc_mmu` PPN select (step 2) EDITED + BOARDED: `lsu_ppn_sel` generate (RVH arm / no-RVH
  wire) replaces the constant-false 64-load select at the `lsu_paddr_o` concat; board `mmu-ppn`
  **31.6 -> 24.6** (new limiter L1079, the exception bundle). NOT yet lint-gated and NOT in
  closure-r127b (edited after that closure was built): run `run_gate.sh r127h dispatch` for
  lint, and include it in the next remote closure (r127c). Revert = `git checkout
  core/g6lc_mmu/g6lc_mmu.sv` (the file had no other r127 edit).

- `gate-r127h.log` (tree = r127b + mmu PPN generate): full lint clean of fatal classes (7 known),
  iqleg 23/23, cwin-eq pass; dispatch leaf was still running when this line was written — read
  the log tail for `HYP8_DISPATCH_PASS`. Remote r127b aggregate still building at 22:34.

- `gate-r127h.log` COMPLETE: lint clean, iqleg 23/23, cwin-eq pass, `HYP8_DISPATCH_PASS 125`,
  `[equiv] g6lc_rename r127 pick: checked=619`. mmu PPN generate is KEPT (31.6 -> 24.6); it is
  NOT in closure-r127b, include in closure-r127c. Step 3 next: `g6lc_prf` L55-72 read mux
  (`rdata_o[r] = |byp_hit ? masked-OR(wdata_q) : mem_q[raddr_q[r]]`) — replicate the
  `!(|byp_hit[r])` select and the `byp_pri` masks per byte lane (probe B8: 25.1 -> 5.5).

- `g6lc_prf` read mux per byte lane (step 3a) EDITED + BOARDED: board `prf-lanes` **35.6 -> 15.6**
  (reg->out L94). In-module reference `rf_rdata` + `g6lc_r127_prf_rd_eq` (old whole-word form,
  every cycle). NOT in closure-r127b. Gate launched: `run_gate.sh r127i dispatch` (dispatch leaf
  instantiates g6lc_prf with --assert). Revert = `git checkout core/ooo/g6lc_prf.sv`.
  After it: step 3b `g6lc_ooo_dispatch` L1280-1300 (`sel_if_a/b`, `!(|hit_a)` driving 64-bit
  AND-OR) per byte lane; then steps 4-7 of the NEXT STEPS list; then closure-r127c + remote gate.

- `gate-r127i.log` (tree = r127b + mmu PPN + prf lanes): lint clean of fatal classes (7 known);
  dispatch leaf still running when written — check the log for `HYP8_DISPATCH_PASS` and that no
  `equiv read lanes` line exists before treating the prf edit as kept. Remote r127b aggregate
  still building at 22:41 (summary file not yet present).

- `gate-r127i.log` COMPLETE: lint clean, `HYP8_DISPATCH_PASS 125`, no `equiv read lanes` error.
  `g6lc_prf` per-byte read lanes KEPT (35.6 -> 15.6). Kept-but-not-yet-remote-gated set (for
  closure-r127c): mmu PPN generate, prf lanes. Next: check r127b.summary.txt, then step 3b.

- REMOTE GATE r127b DONE: `hyp8-r127b-aggregate-t1` lint scalar/smt2 rc=0, 0 %Error, model
  `aeb268336bed2d5b`; `hyp8-r127b-smokes-t1` **12/12 pass, cycle counts identical to r126**.
  => rename_read group pick and csr_regfile epc lanes are remotely gated (smokes build with
  --assert; no `two-phase split mismatch`, no `equiv free-list pick`). Pending remote gate
  (closure-r127c): mmu PPN generate, prf lanes, plus whatever step 3b..7 keeps.

| Step | Status (authoritative, supersedes the table above) |
|---|---|
| A remote integration | r127 and r127b both 12/12 identical; next closure = r127c |
| B core rank-0 | kept: alu, wt_axi_adapter, iq_legal, wbuffer head-match, stb_fwd, id_stage, instr_realign, rename_read pick, csr epc lanes, mmu PPN, prf lanes. Reverted: iq steer slot-order, rename ckpt-slot arm. Open: dispatch L1287 lanes, loop_buffer fill, load_unit pop, store_unit lanes, instr_queue placement, csr pmpaddr L2957 |
| C staged contracts | not started |
| D APU reductions | not started (boards only: `boards/apu-{ai,coh,l2,l3}-r127.json`) |

- Step 3b `g6lc_ooo_dispatch` op_a/op_b per-byte quadrant selects EDITED (L1292-1299 -> `gen_op_lane`;
  `sel_*` nets left in place, existing `g6lc_opasm_eq_a/b` asserts are the check). NOT yet
  boarded/gated when written: board `disp-lanes` (`--modules g6lc_ooo_dispatch`, was 40.5),
  gate `run_gate.sh r127j dispatch` (needs `opasm_int=1 opasm_fp=1` and no `flat/AND-OR diverged`).
  Revert = `git checkout core/ooo/g6lc_ooo_dispatch.sv` (no other r127 edit in that file).

- Step 3b BOARDED: `disp-lanes` g6lc_ooo_dispatch **40.5 -> 28.3** (new limiter L372
  `wb_value_valid`, reg->out). Gate `run_gate.sh r127j dispatch` LAUNCHED; keep only if
  `gate-r127j.log` shows lint clean + `HYP8_DISPATCH_PASS ... opasm_int=1 opasm_fp=1` and no
  `flat/AND-OR diverged`. Then: step 4 loop_buffer fill, 5 load_unit pop, 6 store_unit lanes,
  7 instr_queue placement, csr pmpaddr; build closure-r127c and run `remote_gate.sh r127c`.

- `gate-r127j.log` COMPLETE: lint clean (7 known), `HYP8_DISPATCH_PASS checked=125 opasm_int=1
  opasm_fp=1`, no `flat/AND-OR diverged`. Step 3b `g6lc_ooo_dispatch` per-byte quadrant selects
  KEPT (40.5 -> 28.3). Kept-but-not-yet-remote-gated set for closure-r127c: mmu PPN generate,
  prf read lanes, dispatch op lanes. NEXT: step 4 `g6lc_loop_buffer` fill (L281 `fill_accept`
  gates `data_d[fill_ptr_q]` at L353: write the slot under `capturing_q && fill_valid_i` only,
  keep the address compare on the pointer/len/capturing updates; needs the proof that a slot
  written without acceptance is never read: replay reads `data_q[replay_q]` only below
  `body_len_q`, and a non-accepted fill leaves `fill_ptr_q`/`body_len_q` unchanged).

- REMOTE GATE r127c LAUNCHED (closure-r127c = r127b + mmu PPN generate + prf read lanes +
  dispatch op lanes; loop_buffer NOT edited yet). Result: `build-platform/workspace/build/
  r127-remote/r127c.summary.txt` (expect 12/12 at r126 cycle counts; `equiv read lanes` or
  `flat/AND-OR diverged` in `remote-runs/hyp8-r127c-smokes-t1/*.log` = revert that file).
- Step 4 loop_buffer: NOT edited. Caution recorded: writing the slot without the address compare
  changes `data_q` state of an uncounted slot (not bit-identical state, only outputs), so it
  needs a read-side proof (`data_q[replay_q]` only for replay_q < body_len_q; fill_ptr_q ==
  body_len_q[IDX_W-1:0] during capture) and the `lbuf` leaf (`run_gate.sh <tag> lbuf`) before keeping.

- While r127c builds remotely: START OF D (APU). First item `g6lc_ai_desc_engine` L270-284
  (46.5 rr: `span_a_sum` 65-bit add -> `a_over` -> `span_a_c` 64-bit three-way AND-OR whose
  selects each drive 64 loads): candidate = per-byte-lane select copies (probe B7 form).
  APU file root: `build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/ai_island/`;
  board one module with `reboard_current.py <tag> --argv-from ../r96/boards/current-ai.log
  --modules g6lc_ai_desc_engine`; APU leaves/benches live under `verif/tb/ai_island/` (run-*.sh).

- D item 1 `g6lc_ai_desc_engine` span clamps per byte lane EDITED (hyp APU tree,
  `gen_span_lane`, reference `rf_span_*` + `g6lc_r127_span_eq`); board tag `apu-desc-lanes`
  (was 46.5 rr) — read `boards/apu-desc-lanes.json` with `census.py top`; keep only on a drop,
  else `git checkout` the file. No APU sim gate run yet (find the desc_engine bench under
  `verif/tb/ai_island/`). Remote r127c core gate still building when written.

- D item 1 BOARDED: `apu-desc-lanes` g6lc_ai_desc_engine **46.5 -> 34.8** (rr 29.4; new limiter
  L398 in->out). KEPT on the board; functional gate still owed: no APU sim was run for it
  (in-module `g6lc_r127_span_eq` compares the whole-word form every cycle in any sim that
  elaborates the engine). Next D items in order: `g6lc_ai_gemm_seq` L3164 `store_reset`->`state_d`
  (52.0), `g6lc_ai_gemm_arplan` L210/L218 (149.0), `g6lc_ai_cluster_set` L67 (71.5, behavioural
  mul), `g6lc_l2_top` L966-L1585 collector (59.9/62.7), coh `g6lc_inval_bus` 123.3 /
  `g6lc_coherence_hub` 121.6 (r96: sink/reset aggregates — verify observability before editing).
  Also still owed: read `build-platform/workspace/build/r127-remote/r127c.summary.txt`.

- APU bench hook: `verif/tb/ai_island/run-*.sh` honour `G6LC_AI_RTL_DIR` (point it at
  `build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/ai_island`), plus
  `G6LC_AI_INC_DIR` / `G6LC_AI_SRC_DIR`. They do not pass `--assert`, so the in-module
  `g6lc_r127_span_eq` is only checked if a wrapper adds it. Gate for D item 1 = run
  `G6LC_AI_RTL_DIR=<hyp ai_island> AI_DESC_ISLAND_OUT=<workspace/build dir> bash
  verif/tb/ai_island/run-desc-island.sh` (and run-desc-stripe/run-desc-reuse) in WSL and
  require the PASS line; A/B against the production tree if it fails.

- D item 1 sim gate ATTEMPT: `run-desc-island.sh` with `G6LC_AI_RTL_DIR=<hyp ai_island>` fails to
  compile in the PRODUCTION tree source it also pulls (`corev_apu/src/g6lc_ai_dram_backend.sv:49`
  imports `g6lc_storamic_pkg`, not on the script's file list) — unrelated to the desc_engine edit
  (the user's uncommitted storamic work). Next: also set `G6LC_AI_SRC_DIR`/`G6LC_AI_INC_DIR` to the
  hyp APU tree (`.../hyp_redesign_corev_apu_8fo4/corev_apu/{src,include}`) and retry; if it still
  cannot build, the desc_engine edit stays board-only (46.5 -> 34.8) with its in-module assertion.
- STATE AT THIS POINT (all uncommitted): core kept edits = alu, wt_axi_adapter, iq_legal, wbuffer
  head-match, stb_fwd, id_stage, instr_realign, rename_read pick, csr epc lanes, mmu PPN, prf
  lanes, dispatch op lanes (+ HypCfg threading). APU kept = desc_engine span lanes (board only).
  Remote: r127 and r127b 12/12 identical to r126; r127c (adds mmu/prf/dispatch) launched —
  read `build-platform/workspace/build/r127-remote/r127c.summary.txt`.

- APU gate of record FOUND: `build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/analysis/
  tools/run_nine_gate.sh <mode> <unique-tag>` (WSL; modes float|intpipe|int|intcpp|floatcomb|
  policy|subcode|inval|island|gemm|wide; copies the hyp ai_island to an immutable dir under
  `build-platform/workspace/build/ai-gemm/<tag>`, builds with `--assert`, hyp include/src/cvxif).
  The plain `verif/tb/ai_island/run-*.sh` do NOT work against the hyp tree without it (production
  TB has drifted: `storamic_ctrl_req_i` pin). Prior APU FO4 program: `.../hyp_redesign_corev_apu_8fo4/
  analysis/ai-fo4-program.md` (r16-r41; read its top + `nine-module-r31-plan.md` before picking
  the next APU module — several forms were already measured as countercases there).
  LAUNCHED: `run_nine_gate.sh island r127-desc-island` for the desc_engine span lanes; log
  `build-platform/workspace/build/r127-apu-island-gate.log` (need `PASS focused-gate island`;
  NOTE `$` in `wsl bash -c "..."` strings is expanded by the outer shell — always use script files).

- csr_regfile pmp EDITED (not yet boarded/gated when written): (A) `gen_pmp_write` row writes as
  flat enables, address word per byte lane (`gen_addr_lane`); (B) the `write` always_comb loop
  -> `gen_pmp_next` generate (NrPMPEntries / PMPEntryReadOnly as generate constants). Board tag
  `csr-pmp` (`--modules csr_regfile`, was 52.1 at L2957/L6568). The epc-lane version of the file
  is saved at `build-platform/workspace/build/r127-whatif/csr_regfile.r127.sv` — if the pmp edit
  must be reverted, copy that file back (do NOT `git checkout`, it would drop the epc lanes).

- csr pmp BOARDED: `csr-pmp` csr_regfile **52.1 -> 41.4** (module max now reg->out `csr_rdata_o`
  L1800 26.5; rr 35.3 = fp_live chain -> mstatus_d.sd; 34.9 = take_ex_w -> trap_to_priv ->
  mepc lanes). Whole-board worst is no longer csr_regfile rr. Gate owed: lint (`run_gate.sh r127k
  dispatch`) + next remote closure (r127d). Saved copy for selective revert:
  `build-platform/workspace/build/r127-whatif/csr_regfile.r127pmp.sv` (to be written next).

- Step 4 `g6lc_loop_buffer` EDITED + BOARDED (exact form chosen instead of the unconditional-write
  idea, which is NOT bit-identical at `data_o` when hit_o=0): `data_d` moved out of Group B into
  `gen_fill_slot` (accept strobe -> per-slot decode -> per-byte-lane select copies). Board
  `lbuf-fanout` **46.9 -> 37.8** (rr, new limiter L299). Gate owed: `run_gate.sh r127k lbuf
  dispatch` (lbuf leaf = tb_g6lc_hyp8_lbuf) + remote closure r127d. Revert = `git checkout
  core/frontend/g6lc_loop_buffer.sv` (no other r127 edit in that file).

- loop_buffer lanes REWORKED: literal `8*l +: 8` lanes + elaboration `$error` for DATA_W%8!=0
  (the analyzer mis-resolves `LO +: LW` with a ternary localparam LW as a ~39-bit lane, and does
  not fold a `DATA_W % 8 == 0` generate-if: both arms were billed). Board `lbuf-fanout3`
  **46.9 -> 26.9** rr (limiter now fill_low_lit -> fill_accept 11.7 -> capturing_d / data lane).
  LESSON for all lane rewrites: use literal `8*l +: 8` slices; re-check prf (`LO +: LW` there).

- prf + csr pmpaddr lanes switched to literal `8*l +: 8` slices (faithful widths): board
  `prf-csr-literal` g6lc_prf **19.2** (35.6 before r127; the 15.6 seen with `LO +: LW` was an
  under-counted lane width), csr_regfile 41.4 unchanged. Saved copy refreshed:
  `build-platform/workspace/build/r127-whatif/csr_regfile.r127pmp.sv`.
- Local gate LAUNCHED: `run_gate.sh r127k lbuf dispatch` (tree = r127c + csr pmp + loop_buffer
  fan-out + prf literal lanes). Read `gate-r127k.log`: need lint clean, `HYP8_LBUF_PASS`,
  `HYP8_DISPATCH_PASS`, no `equiv read lanes`.

- csr PMPADDR read EDITED + BOARDED: 2-bit index increment instead of the 12-bit subtract, mode
  bit concatenated instead of a 64-bit two-arm select. Board `csr-pmprd` csr_regfile
  **41.4 -> 35.3** (ro 41.4 -> 19.2; module max now rr L1073 fp_live -> mstatus_d.sd, then 34.9
  take_ex_w -> trap_to_priv_lvl -> mepc lanes, 33.5/32.5 in->reg tval_zero L3386/7). csr_regfile
  total this pass: 52.6 -> 35.3. Saved: `r127-whatif/csr_regfile.r127pmprd.sv`. This edit landed
  AFTER `run_gate.sh r127k` started -> needs its own lint (next gate) + remote closure r127d.

- Step 5 `load_unit` EDITED (not yet boarded/gated when written): (a) publish arms `a_data`,
  `a_drn` rewritten on the raw requests (pend/ex_pub/pub_fire/drn_any) — exact by the algebra in
  the comment, mutant `G6LC_MUT_LSU_EXPEND` branch keeps the old serial a_drn; (b) one-hot
  `ldbuf_pop_oh` + AND clear in `ldbuf_comb`. In-module asserts `g6lc_r127_lu_arms_eq`,
  `g6lc_r127_lu_pop_eq`. Board tag `lu-pop` (`--modules load_unit`, was 44.3). Gate = lint +
  remote smokes (h33/h35/h36/h37 exercise it; local memory leaf is pre-existing-broken).
  Revert = `git checkout core/load_unit.sv` (no other r127 edit in that file).

- load_unit BOARDED: `lu-pop` **44.3 -> 43.2** (rr 44.3 -> 42.2; the pop path left the top; new
  rr limiter ex_pub -> ex_pend_set -> pend_d -> pend_dead_d L661/L1436, ir limiter the IDLE
  decision nest `state_d` L1069 29.8). Small but a drop: KEPT pending the gate. The rest of
  load_unit needs registered verdicts (rank 1), not more rank-0.
- `gate-r127k.log` so far: lint clean, `HYP8_LBUF_PASS checked=22` (loop_buffer fan-out KEPT:
  46.9 -> 26.9), dispatch leaf pending.

- `gate-r127k.log` COMPLETE (tree before csr PMPADDR-read + load_unit edits): lint clean,
  `HYP8_LBUF_PASS 22`, `HYP8_DISPATCH_PASS 125`. KEPT: loop_buffer fan-out (46.9 -> 26.9),
  csr pmp lanes/generate, prf literal lanes (19.2).
- Full local gate LAUNCHED on the CURRENT tree (adds csr PMPADDR read + load_unit arms/pop):
  `run_gate.sh r127l lbuf dispatch queue realign alu lsq dcache` -> `gate-r127l.log`. When green:
  `python verif/regress/remote/hyp8/build_closure.py build-platform/workspace/build/closure-r127d`
  then `remote_gate.sh r127d` (WSL). r127c remote + APU island gate still running when written.
- Deferred census items with a written plan (NOT implemented): `store_unit` L598 (explode
  store_data_fused per output byte: constant-index AMO candidates + offset-keyed byte muxes for
  wb in {1,2,4,8}, late-select by {is_amo, wb class} one-hot, CBO zero folded into the select;
  keep the function as the translate_off reference); `instr_queue` placement (popcount
  thermometer rotated by a one-hot write pointer; `valid` is not dense).
- C plan: B2 `IqSteerStages=2` settled design is in `analysis/r76-program.md` §6 (early steer
  from rename R3 outputs, registered with grp_*_q, per-lane recheck `bank_free[asgn_q] > used_q`).

- REMOTE GATE r127c DONE: `hyp8-r127c-aggregate-t1` lint scalar/smt2 rc=0, 0 %Error, model
  `eb34fd2320f0e30d`; `hyp8-r127c-smokes-t1` **12/12 pass, cycle counts identical to r126**.
  => mmu PPN generate, prf read lanes, dispatch op lanes are remotely gated.
  Remotely gated so far (r127/r127b/r127c): alu, wt_axi_adapter, iq_legal, wbuffer head-match,
  stb_fwd, id_stage, instr_realign, HypCfg threading, rename_read pick, csr epc lanes, mmu PPN,
  prf lanes, dispatch op lanes. NOT yet remotely gated (closure-r127d): csr pmp lanes/generate,
  csr PMPADDR read, loop_buffer fan-out, prf literal-lane respin, load_unit arms + pop mask.

- `gate-r127l.log` (current tree): lint clean, lbuf 22, dispatch 125, queue 126, realign 59,
  alu 19508, lsq 2826 PASS (dcache pending when written).
- REMOTE GATE r127d LAUNCHED (closure-r127d = r127c + csr pmp lanes/generate + csr PMPADDR read +
  loop_buffer fan-out + prf literal lanes + load_unit arms/pop). Result:
  `build-platform/workspace/build/r127-remote/r127d.summary.txt`; expect 12/12 at r126 counts.
  A failure names the edit through its in-module assert (`equiv publish arms`, `equiv pop mask`,
  `equiv read lanes`, `two-phase split mismatch`).

- APU island gate DONE: `run_nine_gate.sh island r127-desc-island` -> `PASS tb_g6lc_ai_island_dma`,
  `PASS focused-gate island`, GATE_RC=0 (built with --assert, so `g6lc_r127_span_eq` was live).
  D item 1 `g6lc_ai_desc_engine` span lanes KEPT + GATED (46.5 -> 34.8).
- APU census reading (boards apu-*-r127 + r96 module-tasks): several top rows are analyzer
  region-sum chains, not cones: `g6lc_ai_gemm_arplan` 149.0 and `g6lc_inval_bus` 123.3 chain the
  independent NBA writes of one always_ff; `g6lc_coherence_hub` 121.6 is the `aw_ot_cnt_d` serial
  decrement of a counter with NO functional reader (`*_ot_cnt_q` feed only themselves + a TB
  probe in hyp8_tb.cpp) ; `g6lc_l2_top` 59.9/62.7 chains through a non-sensitizable
  `wr_b_done_d` default. `g6lc_ai_fp_dot`/`cluster_set`/`cluster_tile`/`fp_mac` are the
  behavioural cluster-SKU reference arithmetic. Plan D2..: (a) arplan: split the s1 always_ff by
  register ownership (d/q), (b) inval_bus: same per register group, (c) coherence_hub: fence the
  sinkless ot counters as sim-only diagnostics (translate_off; Verilator still simulates them),
  (d) l2_top: wr_b_done_d in its own process; then lanes/flat forms on the real cones.
  Gates: `run_nine_gate.sh gemm <tag>` (arplan/gemm_seq), coherence/L2 benches under verif/tb
  (find run scripts: `ls verif/tb | grep -i "coh\|l2"`).

- D item 2 `g6lc_ai_gemm_arplan` S1 group EDITED + BOARDED: next-state terms hoisted to
  module-scope assigns (`s1_*_s`), data registers and `s1_vld_q` in separate always_ff. Board
  `apu-arplan-s1` **149.0 -> 97.0** (rr; new limiter L138 `s3_elems_w`/S3 group). NOT gated yet
  (`run_nine_gate.sh gemm <tag>` owed). Same hoist pattern to apply to the S2a/S2/S3 groups.
  Revert = `git checkout` of corev_apu/ai_island/g6lc_ai_gemm_arplan.sv in the hyp APU tree.

- D item 2b `g6lc_ai_gemm_arplan` S3 EDITED + BOARDED: `elems_for_burst` replaced by the closed
  form min(max(nb,1)*BytesPerBeat - lane0, rem) (one narrow subtract + one compare giving both
  elems and row_last; derivation in the RTL comment; elaboration check on the beat geometry;
  the function kept as `rf_s3_elems` + `g6lc_r127_arplan_elems_eq`). Board `apu-arplan-s3`
  **97.0 -> 59.0** (149.0 at the start; limiter now the L283 register bundle). NOT gated yet:
  `run_nine_gate.sh gemm r127-arplan` (WSL, --assert) must PASS before this is kept.

- APU LIVENESS (new tool `inst_closure.py`: textual instantiation closure over a closure flist, a
  SUPERSET of the elaborated hierarchy; `soc-reachable.txt`, `soc-mc-reachable.txt`; local
  Verilator 5.020 crashes on `--xml-only` of the SoC top, `elab_soc.sh` kept for a better host):
  * `g6lc_ai_gemm_arplan` is instantiated NOWHERE (hyp or production; only in
    `analysis/tools/zips/gemm_seq-r2c-candidate.sv`). Its board row (149.0, now 59.0 after the
    r127 S1 hoist + closed-form elems) is a dead module: no bench exercises it. The edits are
    exact by proof (see RTL comment); keep them but claim nothing functional.
  * NOT in the hyp8 SoC sim flist at all (so not reachable from g6lc_testharness):
    ai_fp_dot 272, ai_cluster_set 72, ai_gemm_fp32_norm 44, ai_gemm_fp32_align 37,
    ai_cluster_tile 32, ai_fp_mac 32, ai_gemm_store_plan 31. The hyp `g6lc_ai_gemm_seq`
    instantiates gemm_span/store_plan/mul_seq, which the sim flist lacks, and the remote lint
    is clean => the AI island is not elaborated in the hyp8 SoC sim; it is its own design unit
    with its own benches (`run_nine_gate.sh`).
  * coh / l2 / l3 group modules are all textually reachable from the SoC top.
- r127d remote gate still running when written; r127l local gate: all leaves PASS so far.

- arplan closed form CHECKED out of module (the module is dead, no bench reaches it):
  `verif/tb/ai_island/tb_g6lc_ai_arplan_eq.sv` + `run-arplan-eq.sh` -> `HYP8_AI_ARPLAN_EQ_PASS
  checked=39223296` (every lane0 x every nb x 2,394 rem values incl. all beat-multiple
  neighbourhoods and 32-bit corners); negative control `run-arplan-eq-mut.sh`
  (`-DG6LC_MUT_ARPLAN_EQ`, nb==0 clamp dropped) -> `..._FAIL bad=151103`. The bench carries
  transcribed copies of both forms. arplan edits KEPT (149.0 -> 59.0 on a dead module).
- `gate-r127l.log` COMPLETE: lint clean + lbuf/dispatch/queue/realign/alu/lsq/dcache all PASS on
  the tree that is closure-r127d.

- REMOTE GATE r127d DONE: `hyp8-r127d-aggregate-t1` lint scalar/smt2 rc=0, 0 %Error, model
  `2aaa5aa6649a0384`; `hyp8-r127d-smokes-t1` **12/12 pass, cycle counts identical to r126**.
  => csr pmp lanes/generate, csr PMPADDR read, loop_buffer fan-out, prf literal lanes,
  load_unit arms + pop mask are remotely gated. EVERY core edit of r127 so far is now
  remotely gated (r127, r127b, r127c, r127d all 12/12 identical).
- Coherence group facts: scalar SoC has NC=1 -> `g6lc_coherence_hub.gen_identity`; the
  multi-core arm (`gen_cluster`, `g6lc_inval_bus.gen_multi`) is only in the MC target, which has
  no passing sim (r115: MC harness smoke only). `ar/aw_ot_cnt_q` have no functional reader
  (only `verif/regress/remote/hyp8/hyp8_tb.cpp:1638` probes ar_ot_cnt_q). Verilator does NOT
  honor `//pragma translate_off` (r127 equivalence code inside such regions ran), so fencing a
  diagnostic under the pragma keeps it in simulation while synthesis/sv-timing drop it.
  Planned coh edits (exact, MC-lint gated via `HYP8_LINT_MC=1`): (1) inval_bus: do_push/do_pop
  as wires + one always_ff per register group; (2) hub `pick_rr` in slot order (no modulo;
  exhaustive standalone bench for NC in {2,3,4,5,8}); (3) hub ot counters fenced as
  diagnostics.

- APU LIVENESS, MEASURED (pinned remote Verilator `--xml-only` of `g6lc_testharness` on the
  r127d closure; script `build-platform/workspace/build/r127-remote/elab-soc.cmd`, module list
  saved as `soc-live-modules.txt`): the scalar hyp8 SoC elaborates 263 modules / 3204 cells and
  **none of the APU-group rows**: no AI island module except `g6lc_ai_enq_arb` (14 FO4) and
  `g6lc_ai_dram_backend`; no `g6lc_coherence_hub` internals (NC=1 identity), no
  `g6lc_inval_bus`, no snoop filters, no L2/L3 cache (`g6lc_l2_*`), only `g6lc_l1_inv_adapter`
  and `g6lc_l3_inclusive_inv`. The APU boards therefore describe OTHER targets
  (g6lc64_hyp8_l3 / _mc / AI SKUs), which have no boot witness; the MC flist is not even in the
  integration closure (`Flist.hyp8_mc_sim` missing there -> HYP8_LINT_MC cannot run as is).
  Consequence for D: APU edits can only be gated by (a) the AI benches (`run_nine_gate.sh`),
  (b) the uncore unit benches under `verif/tb/uncore`, (c) the L2 formal harness
  `verif/tb/l2/formal`, (d) local lint tops `verif/tb/g6lc_uncore_lint_tops.sv`, (e) standalone
  old-vs-new miters. No SoC smoke covers them.

- D item 3 `g6lc_inval_bus` EDITED + BOARDED + GATED: per-core events as wires (`ev_take/merge/
  push/pop`), one clocked process per register group (`gen_regs`). Board `apu-invbus`
  **123.3 -> 33.9** (rr 29.9; module max now reg->out L99 can_accept). Gate
  `run_invbus_bench.sh` (new; `verif/tb/l2/tb_g6lc_inval_bus.sv`, --assert, CORES 1..4 x DEPTH
  1/2/4): 12/12 `INVBUS_PASS`, negative oracle detected, and the 12 statistics lines
  (cycles/accepted/pops/merges/stalls) are IDENTICAL to the same bench on HEAD's file
  (`build/r127-apu/a.txt` vs `b.txt`, cmp clean). KEPT. Module is not elaborated in the scalar
  SoC (NC=1); this is unit-bench evidence only.
- NEXT in D (coh): `g6lc_coherence_hub` (a) `pick_rr` L373-381 (68-70 FO4 function, modulo scan)
  -> slot-order rotate-free form with a standalone exhaustive miter; (b) fence the sinkless
  `ar/aw_ot_cnt` counters; (c) the inv_ot_d L1372-1376 chain (76). Bench of record for the hub:
  `verif/tb/l2/tb_g6lc_coherence_hub.sv` (see `run_inval_review.py` hub_review for the file list
  and -G params: sources config_pkg, g6lc_coherence_pkg, g6lc_inval_bus, g6lc_snoop_filter,
  g6lc_lr_sc_tracker, g6lc_coherence_hub, tb_g6lc_l2.sv, tb_g6lc_coherence_hub.sv; top
  tb_g6lc_coherence_hub, -GOT=4). Then snoop_filter 41, l2_top 60/63, l2_mshr 40, l2_tag 36/42
  (bench `verif/tb/l2/run-l2-tb.sh` with `L2TB_RTL=build-platform/workspace/hyp/
  hyp_redesign_corev_apu_8fo4/corev_apu`), then AI: gemm_seq 52, island_top 44, pe_dot_float_pipe 39.

- Hub bench runner `run_hub_bench.sh [tag] [alt hub file]` (new; top tb_g6lc_coherence_hub,
  --assert, hub_review scenario sets). BASELINE on the unmodified hub
  (`build/r127-apu-hub-base.txt`): OT=4/NC=2 and OT=1/NC=2 all scenarios ok; OT=4 with NC=3 or
  NC=4 FAILS scenario 5 on the baseline (tb line 424) — pre-existing at those geometries (the
  review of record only runs NC=2), so they are NOT a gate; use `HUB_GEOMS="4:2 1:2"` plus the
  per-scenario result lines of NC=3/4 compared against the baseline.

- D item 4a `g6lc_coherence_hub.pick_rr` EDITED: slot-order form (pointer thermometer, two
  prefix-OR isolates, OR encode). The standalone miter `verif/tb/l2/tb_g6lc_hub_pick_rr_eq.sv`
  (`run-hub-pick-rr-eq.sh`, NC=1..8, every reqs x every CID_W start) FAILED the first version
  (67 cases: start >= NC on NC=5,6,7 — the old scan wraps start % NC); fixed by wrapping start
  once; now `HYP8_HUB_PICK_RR_EQ_PASS checked=3948`, negative control `..._FAIL bad=383`.
  NOT yet boarded / hub-bench gated when written: board tag `apu-hub-pick`
  (`--argv-from ../r96/boards/current-coh.log --modules g6lc_coherence_hub`, was 121.6 with
  ar_winner 93.6 / aw_winner 75.1), gate `HUB_GEOMS="4:2 1:2" run_hub_bench.sh pick` + NC=3/4
  lines compared with `build/r127-apu-hub-base.txt`.

- D item 4a/4b `g6lc_coherence_hub` BOARDED: `apu-hub-pick` (pick_rr slot order only) left the
  module max at 121.6 (the max was the ot-counter chain, not pick_rr; ar/aw_winner rows 93.6/75.1
  left the top list). `apu-hub-cnt` (13 writes to the sinkless `ar/aw_ot_cnt` fenced with
  `//pragma translate_off/on`; they stay in simulation, Verilator ignores the pragma)
  **121.6 -> 75.4** (rr L772; next rows: inv_ot_d chain ~76/65 via aw_fire, hub_aw_hold_* 66.1 ro).
  Gate LAUNCHED: `run_hub_bench.sh r127` -> compare `HUB ...` lines with
  `build/r127-apu-hub-base.txt` (must be identical incl. the pre-existing NC=3/4 scenario-5 FAIL).

- Hub gate DONE: `run_hub_bench.sh r127` result lines are IDENTICAL to the baseline
  (`build/hub-a.txt` vs `hub-b.txt`, cmp clean): OT=4/NC=2 9/9 ok, OT=1/NC=2 5/5 ok, NC=3/4 same
  pre-existing scenario-5 failure as HEAD. `g6lc_coherence_hub` pick_rr slot order + ot-counter
  fence KEPT (121.6 -> 75.4). Unit-bench evidence only (module not in the scalar SoC).

| APU group | Module | Before -> now | Evidence |
|---|---|---|---|
| ai | g6lc_ai_desc_engine | 46.5 -> 34.8 | island gate PASS (--assert) |
| ai | g6lc_ai_gemm_arplan (dead: instantiated nowhere) | 149.0 -> 59.0 | sweep miter 39.2M cases + negative control |
| coh | g6lc_inval_bus | 123.3 -> 33.9 | inval_bus bench 12 geometries, stats identical to HEAD |
| coh | g6lc_coherence_hub | 121.6 -> 75.4 | hub bench lines identical to HEAD; pick_rr miter 3948 + negative |

NEXT (D): hub inv_ot_d / inv_pend chain (aw_fire L763 -> ... 76/65), hub_aw_hold_* 66.1 ro;
`g6lc_snoop_filter` 41.1; then l2/l3 (`g6lc_l2_top` 59.9/62.7 `wr_b_done_d` chain, mshr 39.8,
tag 36.0/41.6) with `verif/tb/l2/run-l2-tb.sh` (L2TB_RTL=hyp APU tree; modes sim|units);
then AI gemm_seq 52.0 / island_top 43.9 / pe_dot_float_pipe 38.8 with `run_nine_gate.sh`.

- C (IQ steer) reading before any edit: `g6lc_ooo_dispatch` drives `i_iq.disp_valid_i =
  grp_v_q & {NP{grp_go}}` (L931) and `steer_hint_i = steer_q + p` (L889-892, registered);
  `can_go` (L316) serializes groups (`!grp_pend_q && !(|grp_v_q)`); `grp_v_q` next state =
  `ren_group_valid & dispatch_valid_i` at ren_pub (L608), cleared on kill/done. In `g6lc_iq`
  (L228-262) every steer output is gated by `disp_valid_i[p]` (steer_found, asgn, group_fits),
  so the lane-serial `nused` term may use the pre-go registered valids (exact: when grp_go=0
  nothing is observable). B2 proper (r76-program.md §6): evaluate the steer in the cycle
  before and register `asgn_q/fits_q`, re-evaluated every cycle while the group is held, with a
  per-lane recheck; needs `steer_pre_valid/hint` from dispatch; the r69 `ref_asgn` equivalence
  must then become a legality check (bank choice may differ after a hold). Gate: dispatch leaf
  + remote smokes; default `IqSteerStages` stays 1 until both pass.
- L2 reading: `g6lc_l2_top` 59.9/62.7 path = collector (L966-974) -> rdtrk_wants -> r_fsm_start_ok
  -> `wr_b_done_d = 0` (L1585, inside the S_IDLE AW-accept arm of the big next-state case) ->
  `state_d` (L1943 `if (state_q==S_BYPASS_B && wr_b_done_d && ...)`). The L1585 write happens
  only in S_IDLE and the L1943 read only in S_BYPASS_B: not sensitizable (r96 M96-GUARD).
  Exact fix candidate: L1943 may read `wr_b_done_q || <the two S_BYPASS_B set terms>` instead of
  `wr_b_done_d` (in S_BYPASS_B the only writes to wr_b_done_d are the sets at L1933 and L2117).

- L2 bench runner `run_l2_bench.sh [tag]` (new): `verif/tb/l2/run-l2-tb.sh` with
  `L2TB_RTL=<hyp APU tree>`, configs sim-default / sim-posted / sim-wupdate / sim-posted-wu /
  units; needs `L2TB_EXTRA=-Wno-fatal` on the local Verilator 5.020 (the bench is -Wall-fatal
  for the pinned 5.008). BASELINE run tag `base2` -> `build/r127-apu-l2-base.txt` (sim-default
  PASS seen; the rest was still running when written — read the file before comparing).

- L2 BASELINE (`build/r127-apu-l2-base.txt`, unmodified hyp tree): sim-default, sim-posted,
  sim-wupdate, sim-posted-wu all `[l2-tb] PASS`, units `UNITS PASS`.
- D item 5 `g6lc_l2_top` EDITED (not yet boarded/gated when written): the S_BYPASS_B exit test
  reads `wr_b_done_now` (= wr_b_done_q || the B-accept event) instead of the next-state variable
  `wr_b_done_d`; reference `rf_wr_b_done_mid` + `g6lc_r127_l2_b_done_eq` (checked only in
  S_BYPASS_B). Board tags `apu-l2top` (l2 argv) / `apu-l3top` (l3 argv), was 59.9 / 62.7.
  Gate: `run_l2_bench.sh r127` must give the same five PASS lines. Revert = `git checkout` of
  corev_apu/l2_cache/g6lc_l2_top.sv in the hyp APU tree.

- D item 5 BOARDED: `apu-l2top` g6lc_l2_top **59.9 -> 52.7** (rr, new limiter L1032). L2 gate
  LAUNCHED: `run_l2_bench.sh r127` -> `build/r127-apu-l2-r127.txt` (need the same 5 PASS lines
  as the baseline; the `g6lc_r127_l2_b_done_eq` assert is live under --assert).

- L2 gate DONE: `run_l2_bench.sh r127` = same five PASS lines as the baseline (sim-default,
  sim-posted, sim-wupdate, sim-posted-wu, units; --assert build so `g6lc_r127_l2_b_done_eq` was
  compiled in). D item 5 `g6lc_l2_top` wr_b_done_now KEPT (59.9 -> 52.7 on the l2 argv; l3 argv
  board `apu-l3top` owed). Next l2_top limiter: collector (L979-987, 23 FO4: fifo_wrap add ->
  fifo_q[collect_pos] -> fill_state_q[collect_idx] compare -> is_fill_beat) feeding
  fsm_in_r/rdtrk_grant/r_turn_d and wr_r_pending_d/state_d. r96 strategy: cache the collector
  owner (collect_idx / collect_active) at the FIFO/counter update edge (A134).

- `apu-l3top` (l3 argv) g6lc_l2_top **62.7 -> 55.5** (rr L1250) with the same wr_b_done_now edit.
- APU status table (supersedes the earlier one):

| APU group | Module | Before -> now | Evidence |
|---|---|---|---|
| ai | g6lc_ai_desc_engine | 46.5 -> 34.8 | island gate PASS (--assert) |
| ai | g6lc_ai_gemm_arplan (dead) | 149.0 -> 59.0 | sweep miter 39.2M + negative control |
| coh | g6lc_inval_bus | 123.3 -> 33.9 | bench 12 geometries, stats identical to HEAD |
| coh | g6lc_coherence_hub | 121.6 -> 75.4 | hub bench identical to HEAD; pick_rr miter + negative |
| l2 | g6lc_l2_top | 59.9 -> 52.7 | L2 bench 5 configs PASS (same as baseline) |
| l3 | g6lc_l2_top | 62.7 -> 55.5 | same edit |

OPEN in D: ai gemm_seq 52.0, island_top 43.9, pe_dot_float_pipe 38.8, cluster_dispatch 34.3;
coh hub 75.4 (aw_fire -> inv_* chain), snoop_filter 41.1; l2 mshr 39.8, tag 36.0/41.6, top 52.7.

- D item 6 `g6lc_l2_mshr` EDITED (not yet boarded/gated when written): free-entry pick as a
  prefix-OR isolate + OR encode in its own process (was a serial first-found chain in the merge
  CAM loop); reference `rf_free_*` + `g6lc_r127_mshr_free_eq`. Board tag `apu-mshr`
  (l2 argv, `--modules g6lc_l2_mshr`, was 39.8). Gate = `run_l2_bench.sh <tag>` (5 PASS lines).
  Revert = `git checkout` of corev_apu/l2_cache/g6lc_l2_mshr.sv in the hyp APU tree.

- D item 6 `g6lc_l2_mshr` free pick: board `apu-mshr` 39.8 -> **44.1** (worse). REVERTED with
  `git checkout` (file back at HEAD). Do not retry the isolate form there; the row is the
  alloc -> mem_d[free_idx] -> complete chain, which needs the alloc/complete writes separated
  per entry (one-hot enables), not a different free pick.
- Uncommitted APU edits now in the hyp APU tree: ai_island/g6lc_ai_desc_engine.sv,
  ai_island/g6lc_ai_gemm_arplan.sv, coherence/g6lc_inval_bus.sv, coherence/g6lc_coherence_hub.sv,
  l2_cache/g6lc_l2_top.sv (verify with `git status --short -- build-platform/workspace/hyp/
  hyp_redesign_corev_apu_8fo4`).

- `g6lc_l2_tag` 36.0/41.6 row = `pf_d[index_i] <= pf_q[index_i] & ~hit_way` (L233/L437, the
  `gen_pf` update): r96 M96-GEN says that arm is disabled (PF_TAG=0) and the analyzer does not
  fold it — measurement artifact, not edited.
- PLAN for the rest of this goal (in order): (1) qualify the already-implemented staged MMU
  (`G6LC_HYP8_MMU_STAGED`): remote build + smokes with the define, then a boot witness;
  (2) final boards: core whole (`core-all-r127-final2`) + APU groups (`apu-*-r127-final`) and
  refresh `fo4-census.md`; (3) B2 `IqSteerStages=2` staged arm (r76-program.md §6);
  (4) snoop_filter exact predicate hoist (alloc/clear tests read mem_q + the alloc event);
  (5) store_unit lanes, instr_queue placement; (6) wbuffer / realign contracts.

- STAGED MMU qualification step 1 LAUNCHED: new harness target `g6lc64_hyp8_mmu_staged`
  (`verif/regress/remote/hyp8/hyp8-build-harness.sh`, `-DG6LC_HYP8_MMU_STAGED`); closure-r127s =
  current tree (r127d core + APU coh/l2 edits + harness target); `remote_gate.sh r127s --env
  HYP8_BUILD_TARGET=g6lc64_hyp8_mmu_staged`. Result: `build/r127-remote/r127s.summary.txt`.
  NOTE the lint step of the integration still lints the DEFAULT binding (scalar/smt2); only the
  model build carries the define. Smokes are bare-metal M-mode (little MMU activity): 12/12 here
  shows only that the staged arm builds and does not break the non-MMU paths; cycle counts may
  differ. The MMU proof needs the OpenSBI/Linux witness (step 2).

- WHOLE-CORE BOARD `core-all-r127-final2` (same argv as `core-all-r127-v50`, + fe_frontier):
  board worst 52.6 (csr_regfile) -> **42.2 (load_unit.reg1/D)**. Rows moved this pass:
  csr_regfile 52.6->35.3 · rename_read 51.0->40.2 · loop_buffer 46.9->26.9 · load_unit 44.3->43.2
  (rr 42.2) · wbuffer 41.7->39.5 (rr 32.9) · alu 40.6->32.9 · ooo_dispatch 40.5->28.3 ·
  instr_realign 40.5->34.5 · wt_axi_adapter 40.3->32.0 · stb_fwd 36.9->25.6 · prf 35.6->19.2 ·
  mmu 31.6->24.6 · iq_legal 31.3->18.6 · id_stage 30.7->14.7. Top table saved as
  `boards/core-all-r127-final2.top.txt`.
  Live any-kind now: decode_s3 44.5, instr_queue 43.2, load_unit 43.2, store_unit 41.4,
  rename_read 40.2, aes 39.9, wbuffer 39.5, ptw_leg_decode 38.2, ptw 36.0, iq 36.0, missunit 36.0.
  Live clock rule now: load_unit 42.2, ptw 36.0, missunit 36.0, csr_regfile 35.3, realign 34.5,
  tlb 34.1, wbuffer 32.9, alu 32.9, fe_override 32.5, bp_ckpt 32.3, iq_arb 32.2, axi_adapter 32.0.
  CAVEAT: the ptw/tlb rows use the r95 param map (TlbStages=3, PtwDecodeStage=1 = the staged
  arms); the default binding elaborates the unstaged arms -> re-board them with
  `params-hyp8-default.json` (created next).

- `params-hyp8-default.json` (r95 map with TlbStages=1, PtwDecodeStage=0) written; board
  `mmu-default-binding` gives the SAME rows as the staged map (ptw_leg_decode 38.2, ptw 36.0,
  tlb 34.1, mmu 24.6): the analyzer does not fold those generate arms from the param map, so the
  MMU rows cannot be attributed to one binding by this instrument (both arms are billed).

- D item 7 `g6lc_snoop_filter` EDITED (not yet boarded/gated when written): update predicates
  `al_hit` / `cl_match` hoisted onto mem_q (+ same-cycle install case `al_cl_same`); exact by the
  argument in the RTL comment (invalidation clears write only presence bits). Board tag
  `apu-sf` (coh argv, `--modules g6lc_snoop_filter`, was 41.1). Gate: `run_sf_bench.sh` (to
  write: tb_g6lc_snoop_filter scenarios 0/1/2 + oracle_negative, sources config_pkg,
  g6lc_coherence_pkg, g6lc_snoop_filter, tb; --assert) on HEAD file vs edited + hub bench.
  Revert = `git checkout` of corev_apu/coherence/g6lc_snoop_filter.sv in the hyp APU tree.

- D item 7 `g6lc_snoop_filter` BOARDED + GATED: board `apu-sf` **41.1 -> 27.2** (rr L145).
  `sf_ab.sh` (new; `run_sf_bench.sh` on HEAD's file vs the working tree, --assert): result lines
  IDENTICAL (`build/sf-a.txt` vs `sf-b.txt`): NC=2/NE=4 and NC=4/NE=16 scenarios 0/1/2 ok and
  both injected-oracle trials `SF_NEGATIVE_CAUGHT`; NC=3/NE=8 does not compile on EITHER file
  (generated-C++ `lvalue required`, local Verilator, pre-existing). Hub bench with the edited
  filter: lines identical to the baseline (`hub-a.txt` vs `hub-c.txt`). KEPT.
- APU status table (current):

| APU group | Module | Before -> now | Evidence |
|---|---|---|---|
| ai | g6lc_ai_desc_engine | 46.5 -> 34.8 | island gate PASS (--assert) |
| ai | g6lc_ai_gemm_arplan (dead) | 149.0 -> 59.0 | sweep miter 39.2M + negative control |
| coh | g6lc_inval_bus | 123.3 -> 33.9 | bench 12 geometries, stats identical to HEAD |
| coh | g6lc_coherence_hub | 121.6 -> 75.4 | hub bench identical to HEAD; pick_rr miter + negative |
| coh | g6lc_snoop_filter | 41.1 -> 27.2 | SF bench + hub bench identical to HEAD |
| l2 | g6lc_l2_top | 59.9 -> 52.7 | L2 bench 5 configs PASS (same as baseline) |
| l3 | g6lc_l2_top | 62.7 -> 55.5 | same edit |
| l2 | g6lc_l2_mshr | 39.8 (attempt 44.1 reverted) | — |

- gemm_seq reading (NOT edited): 52.0 = `store_reset` (L3164: state test + `i_q >= m_q` 32-bit
  compare + 6 flags, 20.8 with load) -> `state_d = ST_STC` (L3367). Candidate (A134): register
  the predicate `i_ge_m_q <= (i_d >= m_d)` (reset value 1 since 0 >= 0) and use it at L3164 and
  L3365; needs the i_q/m_q next-state names and the `run_nine_gate.sh gemm <tag>` gate
  (AI_GEMM_DPF_LIST default "0 2"). Second row 51.6 = store_b_fire -> `stc_j_d` 32-bit add
  (L3322, 28.3); third 50.3 = store plan -> rd_sel_pair -> c_rx read.
- r127s (staged MMU target) remote gate still building when written.

- STAGED MMU step 1 DONE: `hyp8-r127s-aggregate-t1` built with `SOFT_LADDER_BUILD_TARGET=
  g6lc64_hyp8_mmu_staged` (model `457cb8a70e70ee8a`; the model has NO `i_leg_dec` symbol while
  the r127d default model has it => the staged PTW arm is really what was built);
  `hyp8-r127s-smokes-t1` **12/12 pass, cycle counts identical to r126** (bare-metal M-mode, so
  this proves build + non-MMU paths only). Step 2 = OpenSBI/Linux witness on that model.

- WITNESSES LAUNCHED (detached, r126 recipe: fw sha 30e1311e..., tohost 0x80041730, 3e9-cycle
  budget; scripts `remote_witness.sh <int-tag> <witness-tag>` and `remote_witness_status.sh
  <tags...>`): `hyp8-osbi-scalar-r127d` (pid 875698, default binding, model 2aaa5aa6) and
  `hyp8-osbi-scalar-r127s-mmustaged` (pid 875845, staged MMU, model 457cb8a7). Both are
  single-thread non-PGO smoke models -> SLOW (the r126 witness, PGO + 4 threads, is at
  cyc=362M / ret=100M after ~6 h with `Linux version` on its uart and no INIT_UP yet). Console
  milestones live in `<run>/output/uart.txt`, not run-hyp8.log. Classify only from positive
  milestones; the staged-MMU verdict is the comparison of the two r127 witnesses at equal
  cycle counts (first divergence in retired PCs / uart text).

- gemm_seq `i_q >= m_q` caching NOT attempted: `i_q` has ~9 scattered non-blocking write sites in
  one always_ff (L4612-4727) and no single next-state name; a registered predicate would need
  every site touched. Left as a rank-1 item for the AI program (r31-r39 owner list).
- Launching final APU boards `apu-{ai,coh,l2,l3}-r127-final` (same argv as r96 `current-*`).

- Core `wt_dcache_missunit` EDITED (not yet boarded/gated when written): AMO result word/dword
  select per byte lane (`gen_amo_res_lane`, L513). Board tag `mu-lanes` (`--modules
  wt_dcache_missunit`, was 36.0 rr). Gate: lint + dcache leaf + remote smokes (amo tests).
  Revert = `git checkout core/cache_subsystem/wt_dcache_missunit.sv`.

- Core `wt_dcache_missunit` BOARDED: `mu-lanes` (AMO result lanes) 36.0 -> 34.9; `mu-lanes2`
  (+ CAS data select per byte lane behind a fan-out copy of `cas_eq`, `gen_cas_lane`)
  **36.0 -> 29.6** (io L602; rr 27.7, ir 15.2). Local gate LAUNCHED: `run_gate.sh r127m dcache
  dispatch` -> `gate-r127m.log` (need lint clean + `HYP8_DCACHE_PASS`). Then closure-r127e +
  `remote_gate.sh r127e` (amo smokes exercise it). Revert = `git checkout
  core/cache_subsystem/wt_dcache_missunit.sv`.

- FINAL APU BOARDS `apu-{ai,coh,l2,l3}-r127-final` (same argv as the r96 `current-*` boards):
  * ai: board worst 149.0 -> 71.5 (g6lc_ai_cluster_set.reg1/D); changed: ai_desc_engine 46.5->34.8; ai_gemm_arplan 149.0->59.0; top now: ai_fp_dot 271.5, ai_cluster_set 71.5, ai_gemm_arplan 59.0, ai_gemm_seq 52.0, ai_gemm_fp32_norm 44.1, ai_island_top 43.9, ai_pe_dot_float_pipe 38.8, ai_gemm_fp32_align 36.7
  * coh: board worst 123.3 -> 75.4 (g6lc_coherence_hub.reg1/D); changed: coherence_hub 121.6->75.4; inval_bus 123.3->33.9; snoop_filter 41.1->27.2; top now: coherence_hub 75.4, inval_bus 33.9, cmo_engine 29.5, snoop_filter 27.2, ooo_snoop_filter 22.3, lr_sc_tracker 11.6, l1_inv_adapter 4.5
  * l2: board worst 59.9 -> 52.7 (g6lc_l2_top.reg1/D); changed: l2_top 59.9->52.7; top now: l2_top 52.7, l2_mshr 39.8, l2_tag 36.0, l2_wtrk 27.9, l2_data 27.0, l2_rdtrk 18.6
  * l3: board worst 62.7 -> 55.5 (g6lc_l2_top.reg1/D); changed: l2_top 62.7->55.5; top now: l2_top 55.5, l2_tag 41.6, l2_mshr 39.8, l2_wtrk 27.9, l2_data 27.0, l2_rdtrk 18.6

- `gate-r127m.log` COMPLETE (tree = r127d + missunit lanes + APU edits): lint clean (7 known),
  `HYP8_DCACHE_PASS 334`, `HYP8_DISPATCH_PASS 125`. missunit lanes KEPT locally (36.0 -> 29.6).
- REMOTE GATE r127e LAUNCHED (closure-r127e = current tree: r127d core + missunit lanes + APU
  coh/l2/ai edits + harness mmu_staged target). Result: `build/r127-remote/r127e.summary.txt`
  (expect 12/12 at r126 counts). Two r127 witnesses (r127d default, r127s staged MMU) are
  running detached on the same host — check with `remote_witness_status.sh hyp8-osbi-scalar-r127d
  hyp8-osbi-scalar-r127s-mmustaged`.

- Step 6 `store_unit` EDITED (not yet boarded/gated when written): `store_data_fused` replaced on
  the datapath by per-byte lanes (`gen_st_byte`: per-lane offset one-hot AND-OR over wired
  source bytes for each reversal class {1,2,4,XLEN/8}, constant AMO source, one-hot class
  select, Zicboz zero folded in); the function stays as the reference `rf_st_data` +
  `g6lc_r127_st_data_eq`. Board tag `su-lanes` (`--modules store_unit`, was 41.4 ir). Owed:
  standalone sweep `verif/tb/core/tb_g6lc_hyp8_stdata_eq.sv` (all op x off x mbe x amo), lint,
  remote smokes. Revert = `git checkout core/store_unit.sv` (no other r127 edit in that file).

- Step 6 `store_unit` BOARDED: `su-lanes` **41.4 -> 22.4** (module max now rr L420 22.4; the
  store-data in->reg row is gone from the top). Gate owed (in this order): generated sweep
  bench (extract the three functions + the `gen_st_byte` block from the module text, sweep every
  fu_op x offset x mbe x amo with distinct-byte data), full lint, then closure-r127f +
  `remote_gate.sh r127f` (in-module `g6lc_r127_st_data_eq` live under --assert).

- store_unit sweep bench `verif/regress/remote/hyp8/run_stdata_eq.sh` (GENERATED from the module
  text; plain + mutant) currently reports `[plain] ..._FAIL bad=21714/22272`. Diagnosis so far:
  the lanes output is STALE in the bench (debug print: `st_d64` keeps the first data word while
  `lsu_ctrl_i.data` has changed; `cand`/`term` are consistent with the stale `st_d64`), i.e. the
  local simulator is not re-evaluating the lane logic after the testbench writes struct MEMBERS
  of `lsu_ctrl_i` from an initial block — NOT yet shown to be a bench artifact rather than an
  RTL error. Next discriminator: drive the DUT port from plain variables through one
  `assign lsu_ctrl_i = '{...}` (no member writes). If that passes -> bench artifact, keep the
  store_unit edit pending the remote smokes (in-module `g6lc_r127_st_data_eq` is the real
  check); if it still fails -> revert `core/store_unit.sv` with `git checkout`.
  store_unit is NOT in closure-r127e (edited after that closure was built).

- store_unit sweep RESOLVED as a bench artifact: with the stimulus in plain variables and the
  struct port driven by ONE continuous assignment (as the real port is), `run_stdata_eq.sh`
  gives `[plain] HYP8_STDATA_EQ_PASS ops=232 checked=22272` (every fu_op x 8 offsets x mbe x 6
  data words, AMO flag from the op) and `[mut] ..._FAIL bad=22141` (negative control). The
  earlier FAIL came from procedural writes to struct MEMBERS in an initial block, which the
  local Verilator did not propagate into the generate lanes. `st_d64` is now a size cast
  (no zero-width replication at XLEN=64). store_unit lanes KEPT locally (41.4 -> 22.4);
  still owed: full lint (`run_gate.sh r127n dispatch lsq dcache`) and the remote gate
  (closure-r127f) where `g6lc_r127_st_data_eq` runs inside the SoC.

- `gate-r127n.log` COMPLETE (tree = r127e + store_unit lanes): lint clean (7 known),
  `HYP8_DISPATCH_PASS 125`, `HYP8_LSQ_PASS 2826`, `HYP8_DCACHE_PASS 334`. store_unit lanes pass
  the local gate; remote gate owed as closure-r127f once r127e (missunit lanes) has reported.

- REMOTE GATE r127e DONE: `hyp8-r127e-aggregate-t1` lint scalar/smt2 rc=0, 0 %Error, model
  `17ab4acc1b12b86b`; `hyp8-r127e-smokes-t1` **12/12 pass, cycle counts identical to r126**.
  => `wt_dcache_missunit` AMO/CAS byte lanes are remotely gated (36.0 -> 29.6). The closure also
  carried the APU coh/l2/ai edits (not elaborated in the scalar SoC, lint-clean there).
- REMOTE GATE r127f LAUNCHED (closure-r127f = r127e + store_unit per-byte lanes). Result:
  `build/r127-remote/r127f.summary.txt` (expect 12/12 at r126 counts; `equiv store data lanes`
  in `remote-runs/hyp8-r127f-smokes-t1/*.log` = revert `core/store_unit.sv`).

- WITNESS STATUS (06:13 remote): `hyp8-osbi-scalar-r127d` alive, OpenSBI banner on uart, cyc=12M
  ret=3.31M ipc 0.276, 0 fatal / 0 equiv errors; `hyp8-osbi-scalar-r127s-mmustaged` alive,
  OpenSBI banner, cyc=10M ret=2.74M ipc 0.274, 0 fatal / 0 equiv errors. Rate ~0.4M cyc/min
  (single thread): Linux `init` needs hundreds of M cycles => many hours. Host load 17 on 12
  cores while r127f builds.
- `instr_queue` placement (census step 7) CLOSED WITHOUT AN EDIT: `valid` is not dense, so the
  exact thermometer needs a popcount or a threshold network in front of the rotate; estimated
  popcount 9.2 + compare ~2 + rotate ~10 = ~21 vs the current 11.7 + 3.5 = 15.2 for the same two
  nodes. The probe's 27.5 -> 12.0 was for the inexact `therm = valid` shortcut. No exact form
  with a measured drop is known; left as is.

- alu remaining rows (32.9 SLLIUW shift L949, 32.4 L974, 31.4 czero L955) are A3 case arms whose
  cost is the `unique case (s3_op)` arm-select broadcast over 64 bits, not the operators: a
  per-byte-lane copy of the op decode would be needed; not attempted.
- `fo4-census.md` §6 now holds the per-item implementation status table (done / reverted /
  not done) — keep it in sync with this ledger.
- OPEN when written: r127f remote gate (store_unit lanes); two detached witnesses; C items
  (IqSteerStages B2, wbuffer versioned writes, realign per-position targets, IqSelStages,
  csr trap record, FreelistPickStages, decode legality table, LoadPubStages, AesStages) are
  NOT implemented; APU rows not reduced are listed in fo4-census.md §6.

- REMOTE GATE r127f DONE: `hyp8-r127f-aggregate-t1` lint scalar/smt2 rc=0, 0 %Error, model
  `83356ee1cffd3afa`; `hyp8-r127f-smokes-t1` **12/12 pass, cycle counts identical to r126**.
  => `store_unit` per-byte store-data lanes are remotely gated (41.4 -> 22.4; the in-module
  `g6lc_r127_st_data_eq` ran under --assert in every store of the 12 smokes).
  ALL kept core edits of r127 are now remotely gated (tags r127, r127b, r127c, r127d, r127e,
  r127f: six integrations, each lint-clean and 12/12 at the r126 cycle counts).

- WITNESS STATUS (06:38 remote): both alive, 0 fatal / 0 equiv errors, OpenSBI banner on uart.
  At cyc=20,000,000 BOTH report ret=5557886, ack_cyc=3629003, ack_full=1928883 (identical): the
  staged-MMU model and the default model retire the same instruction count through the first
  20M cycles (M-mode firmware, translation off, so the MMU staging is not exercised yet). The
  discriminating window starts when Linux enables paging (r126 reference: `Linux version` on
  uart well before cyc=362M). Re-check with `remote_witness_status.sh hyp8-osbi-scalar-r127d
  hyp8-osbi-scalar-r127s-mmustaged`; a staged-MMU defect would show as a divergence in `ret=`
  at equal `cyc=`, a %Fatal/equiv line, or a uart panic.
- NEXT candidates (exact, small): `g6lc_fe_override` L393 `predict_address |= pred_win[i] ?
  slot_pred[i] : '0` (per-byte lanes), `alu` A3 arm selects, hub inv chain; staged contracts
  remain as listed under OPEN.

- Core `load_unit` EDITED (not yet boarded/gated when written): `ex_ctx_ok` no longer reads
  `kill_req_w` (exact: its other three terms imply kill_send=1; derivation in the RTL comment;
  reference `rf_ex_ctx_ok` + `g6lc_r127_lu_exctx_eq`). Board tag `lu-exctx` (`--modules
  load_unit`, was 43.2 any / 42.2 rr, the whole-board worst). Gate: lint + remote smokes
  (closure-r127g). If it must be reverted, remove only that hunk (the file also carries the
  kept r127 arms/pop-mask edit).

- `load_unit` ex_ctx_ok BOARDED: `lu-exctx` rr **42.2 -> 36.9** (module any stays 43.2 = the
  in->reg IDLE decision nest L1069; ro 40.3). Local gate LAUNCHED `run_gate.sh r127o dispatch
  lsq dcache` -> `gate-r127o.log`; then closure-r127g + `remote_gate.sh r127g`.

- `gate-r127o.log` COMPLETE (tree = r127f + load_unit ex_ctx_ok): lint clean (7 known),
  `HYP8_DISPATCH_PASS 125`, `HYP8_LSQ_PASS 2826`, `HYP8_DCACHE_PASS 334`.
- REMOTE GATE r127g LAUNCHED (closure-r127g = r127f + load_unit `ex_ctx_ok` without the kill
  cone). Result: `build/r127-remote/r127g.summary.txt` (expect 12/12 at r126 counts;
  `equiv ex_ctx_ok` in `remote-runs/hyp8-r127g-smokes-t1/*.log` = remove that hunk).
  NOTE: the two detached witnesses run the r127d / r127s models, i.e. WITHOUT missunit lanes,
  store_unit lanes and this load_unit hunk.

- wbuffer reading (NOT edited): the remaining rr 32.9 is `snap_push_first` (positional encoder,
  13.5) -> `fixup_d[k] = merge_fixup(...)` (L1050). Exact candidate: at most ONE valid slot can
  hold a given word address (a push that matches coalesces instead of allocating), so
  `snap_push_first[k]` == `snap_push_match[k]` whenever the queue invariant "no two valid slots
  with the same word address" holds; that needs an invariant assertion + the wbuf-fixup bench
  (`verif/tb/uncore/run-wt-wbuf-fixup.sh`) before the encoder can leave the merge select.
  The versioned-write contract (rank 2) is not implemented.

- r127g remote gate still building at 1623 s (host is loaded: r126 witness + the two r127
  witnesses + this build). Nothing else was launched. When `build/r127-remote/r127g.summary.txt`
  exists: 12/12 at the r126 counts => load_unit `ex_ctx_ok` hunk is remotely gated (rr 42.2 ->
  36.9); otherwise remove that hunk only.

- REMOTE GATE r127g DONE: `hyp8-r127g-aggregate-t1` lint scalar/smt2 rc=0, 0 %Error, model
  `c4bf32cb9a64...`; `hyp8-r127g-smokes-t1` **12/12 pass, cycle counts identical to r126**.
  => load_unit `ex_ctx_ok` hunk is remotely gated (rr 42.2 -> 36.9). Seven integrations
  (r127, b, c, d, e, f, g) + the staged-MMU build r127s: all lint-clean and 12/12 identical.
  CURRENT TREE == closure-r127g for the core. Whole-core board `core-all-r127-final3` launched
  (supersedes final2; adds missunit, store_unit, load_unit ex_ctx_ok).

- WHOLE-CORE BOARD `core-all-r127-final3` (tree == closure-r127g): board worst (all modules) 52.6 -> 36.9 (load_unit.reg1/D).
  live any-kind: g6lc_decode_s3 44.5, instr_queue 43.2, load_unit 43.2, g6lc_rename_read 40.2, aes 39.9, wt_dcache_wbuffer 39.5, g6lc_ptw_leg_decode 38.2, g6lc_ptw 36.0, g6lc_iq 36.0, csr_regfile 35.3, instr_realign 34.5, g6lc_tlb 34.1.
  live clock rule: load_unit 36.9, g6lc_ptw 36.0, csr_regfile 35.3, instr_realign 34.5, g6lc_tlb 34.1, wt_dcache_wbuffer 32.9, alu 32.9, g6lc_fe_override 32.5, g6lc_bp_ckpt 32.3, g6lc_iq_arb 32.2, wt_axi_adapter 32.0, g6lc_iq_bank 30.1.

- **STAGED MMU VERDICT (witness, positive discriminator):** at equal cycle counts the two r127
  witnesses agree up to cyc=22,000,000 (ret=5,925,327 both), then
  `hyp8-osbi-scalar-r127s-mmustaged` STOPS RETIRING at ret=5,985,483 (cyc 24M, 26M, 28M all
  5,985,483; uart ends at the OpenSBI "Boot HART MEDELEG" line), while the default-binding
  `hyp8-osbi-scalar-r127d` continues (cyc=34M ret=8,384,323, `Linux version` + early kernel
  memory setup on uart, 0 fatal / 0 equiv errors). => `G6LC_HYP8_MMU_STAGED` (TlbStages=3,
  PtwDecodeStage=1) WEDGES the integrated core at the hand-off into the kernel (first use of
  translation). It is NOT qualified; the unstaged default binding stays. Root cause not
  investigated (next: hang dump / last retired PC of the staged run around ret 5,985,483;
  suspects: load_store_unit / load_unit timing assumptions on dtlb_hit / lsu_valid latency
  with STLB_DLY=2, PTW PDEC verdict state).

- Staged-MMU wedge EVIDENCE (saved: `build-platform/workspace/build/r127-remote/
  staged-mmu-wedge-evidence.txt`): harness hang dump at cyc=22,258,830 `since_ack=2000
  sb_empty=0 lsu_ready=0`; SB head slot 6 `issued=1 valid=0 fu=1 op=37 pc=ffffffff80802cb0`
  (a LOAD at a kernel VIRTUAL pc, i.e. right after paging is enabled) never completes;
  commit_ptr=6; younger IQ entries wait on it; last retired pc 0xffffffff80001152 @22,256,686.
  => with TlbStages=3 / PtwDecodeStage=1 the first translated load issued to the LSU never
  publishes. The staged arm needs LSU-side work (the 2-cycle DTLB answer is not honoured by
  the load path) before it can be enabled. Default binding unaffected (r127d witness keeps
  retiring through the same point).
- The wedged staged witness (pid 875845, my own run) is being stopped to free the shared host.

- Staged-MMU witness (pid 875845, mine) STOPPED after the cmdline check; the r126 witness
  (pid 726659) and the r127d default witness (pid 875698) keep running. A build that is not
  mine (`work-ver-srvmath-qf`) is active on the host: do not touch it.
- STATE (authoritative): core tree == closure-r127g, every kept core edit remotely gated
  (r127..r127g, 12/12 identical); whole-core board `core-all-r127-final3` worst 52.6 -> 36.9.
  APU boards `apu-*-r127-final`: ai 149.0 -> 71.5, coh 123.3 -> 75.4, l2 59.9 -> 52.7,
  l3 62.7 -> 55.5 (unit-bench / miter evidence; not in the scalar SoC).
  Staged MMU: builds, 12/12 smokes, WEDGES at the first translated load in the Linux witness ->
  stays off. Default-binding witness r127d: alive, `Linux version` printed, no fatal.
  NOT DONE: staged contracts (IqSteerStages B2, IqSelStages, wbuffer versioned writes, realign
  per-position targets, csr trap record, FreelistPickStages, decode legality table,
  LoadPubStages, AesStages), staged-MMU LSU fix, APU rows listed in fo4-census.md §6.

- Core `wt_dcache_wbuffer` EDITED (not yet boarded/gated when written): merge select uses
  `snap_push_match[k]` instead of `snap_push_first[k]`, relying on the invariant "at most one
  valid fixup slot per word address", asserted every cycle by `g6lc_r127_fixup_match_onehot`
  (also checks first === match). Board tag `wbuf-match` (`--modules wt_dcache_wbuffer`, was rr
  32.9 / any 39.5). Gate: dcache leaf (`run_gate.sh r127p dcache`) + remote smokes
  (closure-r127h). If the invariant assertion fires anywhere -> revert THIS hunk only (the file
  also carries the kept head-match edit).

- wbuffer merge-select BOARDED: `wbuf-match` rr 32.9 -> 31.4 (any 39.5 unchanged = the reg->out
  forward presentation L1316). Small drop that rests on the one-match invariant. Local gate
  LAUNCHED: `run_gate.sh r127p dcache` -> `gate-r127p.log`. KEEP only if `HYP8_DCACHE_PASS`
  and no `fixup CAM match not one-hot` line; then it still needs closure-r127h + remote smokes.

- `gate-r127p.log` COMPLETE (tree = r127g + wbuffer merge select on the CAM bit): lint clean
  (7 known), `HYP8_DCACHE_PASS 334 stores=88`, no `fixup CAM match not one-hot` line (the
  invariant assertion ran under --assert in the dcache leaf).
- REMOTE GATE r127h LAUNCHED (closure-r127h = r127g + that wbuffer hunk). Result:
  `build/r127-remote/r127h.summary.txt` (expect 12/12 at r126 counts; a `not one-hot` or
  `equiv fixup` line in `remote-runs/hyp8-r127h-smokes-t1/*.log` = revert that hunk only).
  The dcache leaf and the 12 smokes exercise few fixup coalesces, so the one-match invariant
  is asserted, not proven: it also stays armed in every later witness build.

- REMOTE GATE r127h DONE: `hyp8-r127h-aggregate-t1` lint scalar/smt2 rc=0, 0 %Error;
  `hyp8-r127h-smokes-t1` **12/12 pass, cycle counts identical to r126**. => wbuffer merge
  select on the CAM bit (rr 32.9 -> 31.4) is remotely gated; its one-match invariant assertion
  stays armed. CURRENT CORE TREE == closure-r127h. Eight integrations (r127, b, c, d, e, f, g,
  h) all lint-clean and 12/12 identical; staged-MMU build r127s separately (wedges in Linux).

## RESUME HERE (state after r127h)

Done + remotely gated (core, uncommitted): alu orc.b, wt_axi_adapter priority, iq_legal NH
fold, wbuffer head-match + merge-select, stb_fwd slot winner, id_stage rank, instr_realign
availability bits, HypCfg threading (default = unstaged MMU), rename_read group pick,
csr_regfile epc lanes + pmp lanes/generate + PMPADDR read, g6lc_mmu PPN generate, g6lc_prf
lanes, g6lc_ooo_dispatch op lanes, loop_buffer fill fan-out, load_unit arms/pop/ex_ctx_ok,
wt_dcache_missunit lanes, store_unit byte lanes. Board `core-all-r127-final3`: 52.6 -> 36.9.
Done (APU, unit-bench/miter evidence): desc_engine, gemm_arplan (dead module), inval_bus,
coherence_hub (pick_rr + ot-counter fence), snoop_filter, l2_top. Boards `apu-*-r127-final`.
Reverted (measured worse): iq steer slot order, rename ckpt-slot arm, l2_mshr free pick.
Staged MMU: implemented behind `G6LC_HYP8_MMU_STAGED`, wedges at the first translated load
(evidence file in build/r127-remote) -> off. Default witness `hyp8-osbi-scalar-r127d` running
(check: `remote_witness_status.sh hyp8-osbi-scalar-r127d`).
NOT DONE (goal still open): IqSteerStages (B2, r76-program.md §6), IqSelStages, wbuffer
versioned writes, realign per-position targets, csr trap-write record, FreelistPickStages,
decode legality table, LoadPubStages, AesStages, staged-MMU LSU fix; APU: gemm_seq 52.0,
island_top 43.9, pe_dot_float_pipe 38.8, hub 75.4 inv chain, l2_top collector 52.7,
l2_mshr 39.8, ai_fp_dot / cluster_set (behavioural). Nothing is committed.

- rename_read ckpt slot, 2nd attempt EDITED (not boarded when written): `ck_slot_w` as a CONCAT
  `LVL_W'({hart_i[gp], ck_sum[CPH_W-1:0]})` under `if (CPH_POW2)` (the 1st attempt used a shift
  and measured 49.3). Board tag `rr-ckcat` (was 40.2). Keep only on a drop; else restore the two
  hunks (`gen_ck_pow2` block + the `8'(ck_slot_w)` line back to the ckpt_slot_n call).

- rename_read ckpt slot 2nd attempt: board `rr-ckcat` 40.2 -> **49.3** (worse, same as the shift
  form). REVERTED; the file is byte-identical (modulo line endings) to the copy in
  closure-r127h. Lesson: any generate arm around `ckpt_slot_n` raises the row — the analyzer
  bills both arms; do not retry. CORE TREE == closure-r127h again.

## B2 `IqSteerStages=2` — implementation plan (grounded in the code read at r127h; NOT yet edited)

Facts read: `g6lc_iq.sv` steer = L186-257 (`ge[k][b]` continuous compares off registered
`bank_free`; per lane `nused` -> `elig` -> rotr/x&-x/rotl -> `pick_oh[p]`; `steer_found[p] =
disp_valid_i[p] & |pick_oh[p]`; `asgn[p]`; `group_fits = &(~disp_valid_i | steer_found)`);
consumers `balloc` L384, `disp_ack_o` L390-391, `wr_bank` L572, `wr_v_i` L588; reference
`ref_steer` + `g6lc_r69_steer_eq` L261-289. `g6lc_ooo_dispatch.sv`: `disp_valid_i = grp_v_q &
{NP{grp_go}}` (L931), `steer_hint[p] = steer_q + p` (L889-892), `grp_v_q` next state at
L575-620 (`ren_group_valid & dispatch_valid_i` under `ren_pub`), dispatch serialized by
`can_go` (L316).
Design (safe by construction, no reliance on monotonic bank_free for correctness):
1. dispatch exports `steer_pre_valid = ren_pub ? (ren_group_valid & dispatch_valid_i) : grp_v_q`
   and `steer_pre_hint[p] = <next steer_q> + p` (read the steer_q update first).
2. `g6lc_iq`: `localparam bit STEER2 = (HypCfg.IqSteerStages == 2)`; the existing lane logic
   computes `c_found/c_asgn/c_used` from `sv/sh` (= pre inputs when STEER2, else
   disp_valid_i/steer_hint_i). STEER1 arm: `steer_found = c_found`, `asgn = c_asgn` (today's
   netlist). STEER2 arm: registers `found_q/asgn_q/used_q` every cycle; at use
   `steer_found[p] = disp_valid_i[p] & found_q[p] & ge[used_q[p]+1][asgn_q[p]]` (recheck on the
   CURRENT counts), `asgn[p] = disp_valid_i[p] ? asgn_q[p] : 0`. A stale/mismatched record can
   only make the group wait one cycle, never allocate without room (all-or-nothing ack).
3. `g6lc_r69_steer_eq` stays for STEER1; STEER2 gets a legality assertion (each live lane's bank
   has room after the earlier live lanes on the same bank).
4. New ports must be connected in EVERY `g6lc_iq` instance (remote lint is -Werror-PINMISSING):
   grep `g6lc_iq #` in core + verif/tb.
5. Gates: dispatch leaf with default (STEER1: must stay `HYP8_DISPATCH_PASS 125`, r69 steer
   equivalence intact) and with a `-DG6LC_HYP8_IQSTEER2` profile define selecting
   IqSteerStages=2 (add next to G6LC_HYP8_DEEP in both config packages + a harness target);
   board `--modules g6lc_iq` with a param map `HypCfg.IqSteerStages=2`; remote smokes on the
   staged target (cycle counts may differ by a few cycles). Default Hyp8 stays 1 until a
   witness passes.

- B2 facts added (still NOT edited): `steer_q <= steer_q + BW'(NP)` at the `ren_pub` edge
  (g6lc_ooo_dispatch.sv L618, same edge that loads `grp_v_q <= ren_group_valid &
  dispatch_valid_i`, L608; kill edges clear grp_v_q at L599-600; `grp_go && grp_done` clears it
  at L619-620). So the pre-cycle inputs are: `steer_pre_valid = (mispredict_i|flush_i|
  flush_unissued_i) ? '0 : ren_pub ? (ren_group_valid & dispatch_valid_i) : (grp_go && grp_done)
  ? '0 : grp_v_q` and `steer_pre_hint[p] = (ren_pub ? steer_q + NP : steer_q) + p`.
  `g6lc_iq` instances: core `g6lc_ooo_dispatch.sv:916` (the only one in the hyp8 flist); the
  three verif/tb/core benches (`tb_g6lc_iq_cvxif_head`, `tb_g6lc_iq_store_age`,
  `tb_g6lc_rtl_review`) instantiate the PRODUCTION g6lc_iq (`.CVA6Cfg`), not the hyp one, so
  only the dispatch instance needs the new ports. Give the new ports defaults-free explicit
  connections there; the dispatch leaf (`run_gate.sh <tag> dispatch`) is the first gate.

- **B2 `IqSteerStages` EDIT APPLIED (uncommitted, NOT yet linted/gated when written)** in
  `core/ooo/g6lc_iq.sv` (ports `steer_pre_valid_i/steer_pre_hint_i`; `STEER2` localparam; lane
  logic on `sv/sh`; `gen_steer1` = today's direct use, `gen_steer2` = registered
  found/lane/asgn/used + per-lane recheck `ge[used_q+1][asgn_q]` and `lane_q == disp_valid_i`;
  `g6lc_r69_steer_eq` bypassed when STEER2) and `core/ooo/g6lc_ooo_dispatch.sv`
  (`steer_pre_valid/steer_pre_hint` = next-state of grp_v_q/steer_q, connected). Hyp8 default
  IqSteerStages=1 -> `gen_steer1`, intended to be the same netlist as closure-r127h.
  CAUTION: in the steer_q update the kill branch does NOT block `steer_q <= steer_q + NP`?
  (L599-618: kill -> `grp_v_q <= 0`, `else if (ren_pub)` -> steer_q advances; so on a kill
  steer_q holds: the pre_hint expression matches). NEXT: `run_gate.sh r127q dispatch` (must be
  `HYP8_DISPATCH_PASS 125` + `[equiv] r69 steer` unchanged), then board `--modules
  g6lc_iq,g6lc_ooo_dispatch` (default map: expect ~36.0 unchanged), then add a
  `G6LC_HYP8_IQSTEER2` profile define + harness target to exercise STEER2 (dispatch leaf with
  the define, remote smokes). To back out: `git checkout core/ooo/g6lc_iq.sv` and remove the
  B2 hunks from g6lc_ooo_dispatch.sv (it also carries the kept op-lane edit).

- `gate-r127q.log` COMPLETE (tree = r127h + B2 IqSteerStages arms, default IqSteerStages=1):
  full lint clean (7 known), `HYP8_IQLEG_PASS 23`, `HYP8_DISPATCH_PASS checked=125`. The STEER1
  arm (default) is functionally intact locally. STILL OWED for B2: (a) board `--modules
  g6lc_iq,g6lc_ooo_dispatch` (default map; expect ~36.0 / 28.3 unchanged — if a row ROSE, the
  analyzer is billing the STEER2 arm too: note it, the default netlist is what matters);
  (b) remote gate of the default binding (closure-r127i) for cycle-identical smokes;
  (c) a `G6LC_HYP8_IQSTEER2` define in both config packages (`HypCfgSel` variant with
  IqSteerStages=2) + harness target `g6lc64_hyp8_iqsteer2`, dispatch leaf with the define,
  remote smokes on that target; only then consider enabling it.

- B2 profile seam ADDED: `g6lc_hyp_pkg::hyp_iq_steer2()`; both config packages bind
  `HypCfg = hyp_iq_steer2(HypCfgMmu)` under `-DG6LC_HYP8_IQSTEER2` (default unchanged);
  harness target `g6lc64_hyp8_iqsteer2`; dispatch bench (`tb_g6lc_hyp8_dispatch`) takes the
  same define for its profile `H`. LAUNCHED: dispatch leaf with the define
  (`run_hyp8_leaf_local.sh dispatch r127q-steer2 -DG6LC_HYP8_IQSTEER2`) -> log
  `leaf-dispatch-steer2.log`. Expect `HYP8_DISPATCH_PASS` (the `checked=` count may differ).

- B2 dispatch leaf WITH `-DG6LC_HYP8_IQSTEER2`: `leaf-dispatch-steer2.log` -> `LEAF
  dispatch-r127q-steer2 rc=0`, `HYP8_DISPATCH_PASS checked=125`. NOT YET VERIFIED that the
  STEER2 arm was the one elaborated in that leaf (same `checked=` as the default): check for
  `gen_steer2` in `build-platform/workspace/build/hyp8-leaf-r127/dispatch-r127q-steer2/model/*.h`
  (present => live). Then: closure-r127i + `remote_gate.sh r127i` (default binding, expect
  cycle-identical), `remote_gate.sh r127i2 --env HYP8_BUILD_TARGET=g6lc64_hyp8_iqsteer2`
  (staged steer; cycle counts may differ), board `--modules g6lc_iq` for both.
  CURRENT UNGATED-REMOTELY EDITS: B2 (g6lc_iq.sv, g6lc_ooo_dispatch.sv, g6lc_hyp_pkg.sv, both
  config pkgs, tb_g6lc_hyp8_control.sv dispatch profile switch, harness target).

- B2 STEER2 arm CONFIRMED LIVE in the define leaf (`gen_steer2` present in the model headers of
  `dispatch-r127q-steer2`, absent from the default leaf) and `HYP8_DISPATCH_PASS checked=125`.
- REMOTE GATE r127i LAUNCHED (closure-r127i = r127h + B2 arms, DEFAULT binding IqSteerStages=1):
  `build/r127-remote/r127i.summary.txt`, expect 12/12 at the r126 cycle counts (proves the
  default netlist is behaviourally unchanged by the B2 plumbing). AFTER it: `remote_gate.sh
  r127i2 --env HYP8_BUILD_TARGET=g6lc64_hyp8_iqsteer2` on the same closure dir copy
  (closure tag must match: build `closure-r127i2` first) for the staged steer.

- B2 BOARDS (`iq-b2-default`, `iq-b2-steer2` with `params-hyp8-iqsteer2.json`): BOTH show
  g6lc_iq any **52.5 (in->reg L278)**, io 36.7 (was 36.0 any before B2); g6lc_ooo_dispatch 28.3
  unchanged. The analyzer does not fold the `STEER2` generate arms from the param map, so it
  bills the STEER2 arm's early in->reg steer cone (incl. my `c_used` nested loop) in both runs:
  the row cannot be attributed to a binding. Under the keep-only-on-a-drop rule B2 shows NO
  measured drop. DECISION PENDING (do next, in this order):
  1. per-arm what-if boards: scratch copies of g6lc_iq.sv with `localparam bit STEER2 = 1'b0;`
     and `= 1'b1;` substituted in a what-if flist (`reboard_current.py <tag> --modules g6lc_iq
     --files-from <flist>`, pattern used for `whatif-rank0-b`: scratch dir
     `build-platform/workspace/build/r127-whatif`, flist = `analysis/timing/hyp8-core.f` with
     `../../` -> absolute hyp root and the one file replaced);
  2. if the STEER2 arm's in->out (allocation cycle) is clearly lower AND its in->reg is not above
     the old 36.0, simplify `c_used` (select the per-bank `nused` by `pick_oh[p]` instead of the
     nested loop) and keep B2 as an off-by-default knob; otherwise REVERT B2 entirely:
     `git checkout core/ooo/g6lc_iq.sv`, remove the two B2 hunks in g6lc_ooo_dispatch.sv
     (`steer_pre_*` block + the two port connections), `hyp_iq_steer2` in g6lc_hyp_pkg.sv, the
     `HypCfgMmu`/`G6LC_HYP8_IQSTEER2` block in both config pkgs (restore `HypCfg` directly from
     the MMU ifdef), the bench profile switch in tb_g6lc_hyp8_control.sv, the harness target.
  3. r127i remote gate (default binding with B2 plumbing) is running: read
     `build/r127-remote/r127i.summary.txt`.

- B2 per-arm what-if with a LITERAL `STEER2 = 1'b0` / `1'b1` (boards `iq-b2-arm0`, `iq-b2-arm1`):
  both still 52.5 in->reg L278 — the analyzer does not fold `if (STEER2)` generate arms even
  on a literal. NEXT (in flight): structural what-if copies with the other arm's TEXT deleted
  (`r127-whatif/steer1only`, `steer2only`; boards `iq-b2-only1`, `iq-b2-only2`). Decision rule:
  keep B2 (off by default) only if `only2` in->out is clearly below `only1` in->out (36.0) and
  its in->reg is not above 36; otherwise revert B2 per the list in the previous entry.

- B2 STRUCTURAL what-if (other arm's text deleted): `iq-b2-only1` (same-cycle steer) g6lc_iq
  **36.4 in->out**; `iq-b2-only2` (early steer) **in->out 27.4, reg->out 12.3, in->reg 52.5
  (L278)**. So B2 moves the allocation-cycle cone 36.4 -> 27.4 but the early cone lands at 52.5
  in->reg (deep `steer_pre_valid` + my `c_used` loop). APPLIED since: `c_used` rewritten as
  "earlier live lanes with the same one-hot pick" (`lane_used` block, exact). NEXT: regenerate
  the `steer2only` what-if copy (script in the previous ledger entry: cut `gen_steer2`/
  `gen_steer1`, set sv/sh) and re-board `iq-b2-only2b`; KEEP B2 (off by default) only if
  in->reg <= ~36, else REVERT B2 per the revert list above. Also re-run `run_gate.sh r127r
  dispatch` + `run_dispatch_steer2.sh` after any B2 change, and read
  `build/r127-remote/r127i.summary.txt` (default binding with the pre-simplification B2 text).

- B2 after the `c_used` simplification, structural what-if `iq-b2-only2b` (early-steer arm only):
  g6lc_iq **in->reg 32.3, in->out 27.4, reg->out 12.3** vs the same-cycle arm `iq-b2-only1`
  36.4 in->out. => B2 has a measured drop on its own arm (36.4 -> 32.3 any; allocation cycle
  36.4 -> 27.4). DECISION: KEEP B2 as an off-by-default knob (`IqSteerStages`, define
  `G6LC_HYP8_IQSTEER2`, harness target `g6lc64_hyp8_iqsteer2`). The default board row for
  g6lc_iq reads 36.7/52.5 only because the analyzer bills both generate arms.
  OWED (c_used changed after gate r127q and after closure-r127i was built): `run_gate.sh r127r
  dispatch` + `run_dispatch_steer2.sh r127r-steer2`; then closure-r127j (default) and
  `remote_gate.sh r127j`, and closure-r127j2 + `remote_gate.sh r127j2 --env
  HYP8_BUILD_TARGET=g6lc64_hyp8_iqsteer2` for the staged steer. r127i (older B2 text, default
  binding) was still building when written.

- B2 local gates on the FINAL B2 text (c_used simplified): `gate-r127r.log` lint clean (7 known)
  + `HYP8_DISPATCH_PASS 125` (default arm); `leaf-dispatch-steer2.log` `HYP8_DISPATCH_PASS 125`
  with `gen_steer2` live in the model. NEXT: read `build/r127-remote/r127i.summary.txt` (older
  B2 text, default binding); then `build_closure.py .../closure-r127j` + `remote_gate.sh r127j`
  (default) and `build_closure.py .../closure-r127j2` + `remote_gate.sh r127j2 --env
  HYP8_BUILD_TARGET=g6lc64_hyp8_iqsteer2` (staged steer; run them one after the other, the
  host is shared).

- WAITING: r127i remote gate (default binding, older B2 text) at ~770 s. No other remote job of
  mine is running except the default witness `hyp8-osbi-scalar-r127d` (pid 875698). When
  `build/r127-remote/r127i.summary.txt` exists, proceed with closure-r127j / r127j2 as listed.

- REMOTE GATE r127i DONE (closure-r127i = r127h + B2 plumbing with the OLDER c_used text, DEFAULT
  binding IqSteerStages=1): lint scalar/smt2 rc=0, 0 %Error, model `6627621fcdedce14`, 12/12
  pass — cycle counts printed in the tool output must equal 685 1011 492 2364 2199 1231 671
  3038 9095 5959 883 983 (r126) for "default netlist behaviourally unchanged".
- REMOTE GATE r127j LAUNCHED on the STAGED-STEER target: closure-r127j = current tree (final B2
  text), `remote_gate.sh r127j --env HYP8_BUILD_TARGET=g6lc64_hyp8_iqsteer2`. NOTE the lint
  step lints the default binding of this same tree (so it also covers the final c_used text in
  the default arm); the MODEL is IqSteerStages=2. Result `build/r127-remote/r127j.summary.txt`:
  12/12 pass required; cycle counts may differ from r126 (early steer can make a group wait).
  Still owed after it: a default-binding smoke run of the final B2 text (closure-r127k,
  plain `remote_gate.sh r127k`) for cycle-identity.

- r127i cycle counts READ: 685 1011 492 2364 2199 1231 671 3038 9095 5959 883 983 = identical to
  r126. The B2 plumbing leaves the default binding cycle-identical (older c_used text; the
  final text is only different inside the STEER2-only `lane_used` block, re-checked by r127k).

- WAITING on r127j (STAGED-STEER target `g6lc64_hyp8_iqsteer2`, closure-r127j = current tree) at
  ~800 s. When `build/r127-remote/r127j.summary.txt` exists: count `pass cycles` lines (need 12)
  and list the cycle counts (`grep -o "cycles=[0-9]*"`); they MAY differ from r126 (685 1011 492
  2364 2199 1231 671 3038 9095 5959 883 983). Then build closure-r127k and run plain
  `remote_gate.sh r127k` (default binding, final B2 text) for cycle-identity. After both: B2 is
  an implemented, smoke-gated, off-by-default knob; record it in fo4-census.md §6 (row
  "IQ steer": IqSteerStages=2 arm in->out 36.4 -> 27.4, in->reg 32.3, behind
  G6LC_HYP8_IQSTEER2; default unchanged).

- REMOTE GATE r127j DONE (target `g6lc64_hyp8_iqsteer2`, closure-r127j = current tree, final B2
  text): 12/12 pass, cycle counts 685 1011 492 2364 2199 1231 671 3038 9095 5959 883 983 =
  IDENTICAL to r126. NOT YET VERIFIED that the remote model really elaborated `gen_steer2`
  (identical counts are what the B2 design predicts — latency-neutral in the serialized
  dispatch regime — but could also mean the define did not reach the build). CHECK NEXT:
  `grep -l gen_steer2 /opt/testharness/runs/hyp8-r127j-aggregate-t1/output/model/*.h | wc -l`
  (must be >= 1) and SOFT_LADDER_BUILD_TARGET in
  `remote-runs/hyp8-r127j-aggregate-t1/command-build.json`. Then closure-r127k + plain
  `remote_gate.sh r127k` (default binding, final B2 text).

- B2 STAGED STEER VERIFIED IN THE REMOTE MODEL: `hyp8-r127j-aggregate-t1` was built with
  `SOFT_LADDER_BUILD_TARGET=g6lc64_hyp8_iqsteer2` and its model headers contain `gen_steer2`
  (1 file; the default r127i model has none). 12/12 smokes pass at the r126 cycle counts =>
  the early registered steer is latency-neutral on the smoke set, as the r76 design predicted.
  No boot witness on the staged steer yet -> it stays OFF by default (knob `IqSteerStages`,
  define `G6LC_HYP8_IQSTEER2`, target `g6lc64_hyp8_iqsteer2`).
- REMOTE GATE r127k LAUNCHED: closure-r127k = current tree (final B2 text), DEFAULT binding,
  plain `remote_gate.sh r127k` -> `build/r127-remote/r127k.summary.txt`; need 12/12 at the r126
  counts. After it the core tree == closure-r127k and B2 is done as an off-by-default knob;
  then update fo4-census.md §6 row "IQ steer" and the RESUME block.

- APU `g6lc_coherence_hub` EDITED again (not yet boarded/gated when written): `inv_others` /
  `inv_wr_cand` hoisted beside the grant (the write's candidate invalidation set no longer
  forms behind `aw_fire`; exact: `{NC{1'b1}} & X == X`, both policy arms kept). Board tag
  `apu-hub-cand` (coh argv, `--modules g6lc_coherence_hub`, was 75.4). Gate: `run_hub_bench.sh
  cand` lines must equal `build/hub-a.txt`. If it has to go: restore the `unique case (POLICY)`
  block (see `git diff` of the file; the pick_rr + ot-counter hunks are separate and kept).

- APU hub `inv_wr_cand` hoist BOARDED + GATED: `apu-hub-cand` g6lc_coherence_hub **75.4 -> 66.1**
  (rr 62.6; module max now in->out L939). `run_hub_bench.sh cand`: result lines IDENTICAL to the
  baseline (`build/hub-a.txt` vs `hub-d.txt`). KEPT. Hub total this pass: 121.6 -> 66.1.

- APU `g6lc_ai_island_top` EDITED (not yet boarded/gated when written): register read data —
  the per-queue cone (`rd_que`, own always_comb) now joins the class OR with one OR under the
  same `rcls == 0` test instead of being accumulated after it. Board tag `apu-itop`
  (`--argv-from ../r96/boards/current-ai.log --modules g6lc_ai_island_top`, was 43.9). Gate:
  `run_nine_gate.sh island r127-itop` (WSL; GATE_RC=0 + `PASS focused-gate island`). Revert =
  restore that always_comb (git diff of the file; no other r127 edit in it).

- `apu-itop` board: g6lc_ai_island_top 43.9 -> **43.2** (the read-cone path left the top; the new
  limiter is the 3-way submit mux L880 `submit_src_sb_mux`, a wide-descriptor arm-select
  broadcast — not edited). Island gate LAUNCHED: `run_island_gate.sh r127-itop` -> log
  `build-platform/workspace/build/r127-apu-island-r127-itop.log` (need `PASS focused-gate
  island` + `GATE_RC=0`); keep the read-cone split only if it passes.

- REMOTE GATE r127k DONE (closure-r127k = final B2 text, DEFAULT binding): lint scalar/smt2 rc=0,
  12/12 pass, cycle counts 685 1011 492 2364 2199 1231 671 3038 9095 5959 883 983 = identical
  to r126. CORE TREE == closure-r127k. B2 `IqSteerStages` is complete as an off-by-default knob
  (default cycle-identical: r127i/r127k; staged target `g6lc64_hyp8_iqsteer2` 12/12: r127j with
  `gen_steer2` confirmed in the model). Ten default-binding integrations (r127, b..i, k) all
  lint-clean and 12/12 identical.

- Island gate DONE for the island_top read-cone split: `r127-apu-island-r127-itop.log` ->
  `PASS focused-gate island r127-itop`, `GATE_RC=0`. KEPT (43.9 -> 43.2).
- Default witness `hyp8-osbi-scalar-r127d` (r127d model): alive at cyc=72M ret=18.58M ipc 0.258,
  `Linux version` on uart, 0 fatal / 0 equiv errors, no INIT_UP yet (r126 reference reached
  362M cycles without INIT_UP either; that milestone needs hundreds of M cycles).
- Regenerating the ai/coh group boards as `apu-ai-r127-final2`, `apu-coh-r127-final2` (hub
  inv_wr_cand + island_top edits landed after the `-final` boards).

- GROUP BOARDS `apu-{ai,coh}-r127-final2`:
  * ai: worst 149.0 -> 71.5 (g6lc_ai_cluster_set.reg1/D); changed: ai_desc_engine 46.5->34.8; ai_gemm_arplan 149.0->59.0; ai_island_top 43.9->43.2
  * coh: worst 123.3 -> 62.6 (g6lc_coherence_hub.reg1/D); changed: coherence_hub 121.6->66.1; inval_bus 123.3->33.9; snoop_filter 41.1->27.2

- Core `g6lc_mmu/g6lc_tlb.sv` EDITED (not yet gated when written): the three per-entry flush
  match terms `tl_vmid_ok/tl_asid_ok/tl_gvmid_ok` hoisted from block-local initialized
  variables inside `update_flush` to module-scope per-entry assigns (`gen_tl_match`); same
  expressions (8 uses rewritten to `[i]`). Purpose: the local Verilator read them as latches
  (`-Werror-LATCH`), which kept the mmu leaf from building. THIS FILE IS IN THE DEFAULT
  BINDING -> the core tree is closure-r127k + this hunk until re-gated: `run_gate.sh r127za mmu
  dispatch` (lint + mmu leaf), then closure-r127m + `remote_gate.sh r127m` (12/12 identical).
  A consolidated local gate `r127z` (lbuf dispatch queue realign alu lsq dcache) was launched
  ~2 min BEFORE this edit: its lint may or may not have seen the hunk.
  Revert = `git checkout core/g6lc_mmu/g6lc_tlb.sv` IF that file has no other r127 edit (check
  `git diff --stat` first).

- `gate-r127z.log` (consolidated local gate on the final tree, before the tlb hoist): lint clean,
  IQLEG 23, lbuf 22, dispatch 125, queue 126, realign 59, alu 19508, lsq 2826, dcache 334: ALL PASS.
- `gate-r127za.log` (tlb hoist in): full lint clean; **the mmu leaf now BUILDS locally** (the
  `-Werror-LATCH` stop is gone) and runs to `FAIL MMU_MITER_EQ` ([7366], sim.log line 1845;
  1844 `MMU_MITER_G0/G1 d2|d3|d64` mismatch lines from cyc19 on).
- A/B `mmu_ab_head.sh` (HEAD's g6lc_mmu.sv + g6lc_tlb.sv substituted, `-Wno-LATCH`): the sim.log
  is BYTE-IDENTICAL to the r127 run (`cmp` clean). => (1) the tlb hoist and the r127 mmu PPN
  generate edit are behaviour-neutral in this bench; (2) `MMU_MITER_EQ` already fails at HEAD on
  the LOCAL Verilator 5.020. NOT established: whether it fails on the pinned 5.008 (the leaf
  of record) — the local simulator has produced bench artifacts before (struct-member
  stimulus). This miter (staged d2/d3 vs reference d64, G0 / G1 = RVH) is the tool for the
  staged-MMU wedge. NEXT: `remote_leaf.sh r127m mmu` (new script; pinned toolchain) once the
  r127m integration finishes.
- REMOTE GATE r127m LAUNCHED (closure-r127m = r127k + tlb hoist; default binding):
  `build/r127-remote/r127m.summary.txt`, expect 12/12 at the r126 counts.

- REMOTE LEAF INFRA: `verif/regress/remote/run_hyp8_memory.py` now honours `HYP8_RUNTIME_DIR` /
  `HYP8_RUNTIME_DIGEST` (same contract and defaults as run_hyp8_integration.py). Reason: its
  default compiler `/opt/testharness/src/verilator-causal` no longer exists on the host
  (`managed verilator missing`), and the integration toolchain could not be used with the
  hard-coded private runtime (`VlTriggerVec::wordAny` compile error). `remote_leaf.sh
  <closure-tag> <leaf>` passes the integration toolchain + its runtime + digest; a REUSED run
  tag keeps the previously uploaded runner script, so use `LEAF_RUN=<suffix>` for a fresh tag.
  (Shell note: `\` typed inside a heredoc Python string reaches Python as ONE backslash here —
  never rely on backslash-newline in such strings; slice by index instead.)
- **mmu leaf ON THE REMOTE TOOLCHAIN** (`hyp8-r127m-leaf-mmu-t2`, pinned 5.008-g6lc + its
  runtime, closure-r127m): builds, then `FAIL MMU_MITER_EQ` — the same failure as the local
  run. CORRECTION of my first reading: per the bench header (tb_g6lc_hyp8_control.sv L6990+,
  "r45 MMU leaves") `MMU_MITER_EQ` is the **ROUTER MITER**: the real `g6lc_shared_tlb` built
  with `UseSharedTlb=0` (old bypass arm, the `o*` signals) beside `g6lc_tlb_miss_router` (the
  `n*` signals) on identical inputs, matrix HYP_EXT {0,1} x SharedTlbDepth {2,3,64}. It is NOT
  the staged-TLB/PTW check (those are the later "TLB ROW PREDICATES" checks, never reached
  because the leaf stops at the router miter). So this failure says NOTHING about
  `G6LC_HYP8_MMU_STAGED`; do not link it to the Linux wedge.
  What IS established: (1) the failure reproduces on two simulators (local 5.020, pinned
  5.008-g6lc) for the current tree; (2) locally the sim.log is byte-identical with HEAD's
  g6lc_mmu.sv + g6lc_tlb.sv substituted and the bench's mmu module is HEAD's, so r127 did not
  cause it; (3) first mismatch cyc19 on every depth and both profiles: `acc 1/0`,
  `va 0x80004800/0x80005000`; 1844 mismatch cycles (va 1812, acc 430, du 56, iu 19).
  NOT established: which side drifted (the reference `g6lc_shared_tlb` bypass arm is not
  instantiated in the hyp8 core; the router is live and the default binding boots Linux into
  the kernel), or when it last passed (r45 on the retired `verilator-causal` toolchain).
  Consequence: the mmu leaf is not a usable gate until the router miter is repaired or its
  reference re-derived; the staged-MMU row checks behind it are unexercised.

- DIAGNOSTIC (not a gate) `mmu_rows_probe.sh`: mmu leaf with the two router-miter verdict checks
  neutralized in a SCRATCH copy of the bench (`build/r127-whatif/tb_control_mmu_rows.sv`; the
  tracked bench is untouched; runner gained `LEAF_BENCH=<file>`): everything behind the router
  miter passes — `HYP8_MMU_PASS checked=714 miter=771`, incl. the TLB row predicates over
  {entries 4/16} x {HYP_EXT 0/1} x {TlbStages 1/3}. So at unit level the staged TLB rows meet
  the bench's independent expectations; the only red item in the mmu leaf is the
  shared_tlb(UseSharedTlb=0)-vs-router miter. This points the staged-MMU Linux wedge at the
  INTEGRATION (LSU/PTW handshake around the 2-cycle DTLB answer), not at the TLB rows — a lead,
  not a proof.

- REMOTE GATE r127m DONE (closure-r127m = r127k + g6lc_tlb flush-match hoist, default binding):
  lint scalar/smt2 rc=0, 12/12 pass at the r126 cycle counts. The hoist is remotely gated at the
  smoke level (the smokes barely use the TLB flush rules; its stronger evidence is the mmu-leaf
  A/B: sim.log byte-identical to HEAD's file, and the row checks pass in the diagnostic copy).
  **CORE TREE == closure-r127m.**

## RESUME HERE (state after r127m) — supersedes the earlier RESUME block

Uncommitted working tree (nothing committed, by instruction). Evidence index:
- Core default binding: 11 remote integrations r127, b, c, d, e, f, g, h, i, k, m — each lint
  scalar/smt2 0 %Error and 12/12 smokes at the r126 cycle counts. Local consolidated gate
  `gate-r127z.log` all leaves PASS. Board `core-all-r127-final3`: worst 52.6 -> 36.9.
- Knobs added, both OFF by default:
  * `IqSteerStages=2` (`-DG6LC_HYP8_IQSTEER2`, target `g6lc64_hyp8_iqsteer2`): smoke-gated
    (r127j, 12/12 identical, `gen_steer2` in the model); arm-only boards 36.4 -> 27.4 in->out,
    32.3 in->reg. No boot witness.
  * staged MMU (`-DG6LC_HYP8_MMU_STAGED`, target `g6lc64_hyp8_mmu_staged`): 12/12 smokes but
    WEDGES in Linux at the first translated load (evidence file under build/r127-remote).
- APU (unit-bench / miter evidence; not in the scalar SoC): boards `apu-{ai,coh}-r127-final2`,
  `apu-{l2,l3}-r127-final`: ai 149.0 -> 71.5, coh 123.3 -> 62.6 (hub 121.6 -> 66.1),
  l2 59.9 -> 52.7, l3 62.7 -> 55.5.
- Witness: `hyp8-osbi-scalar-r127d` (default binding, r127d model = WITHOUT missunit/store_unit
  lanes, load_unit ex_ctx_ok, wbuffer merge-select, B2 plumbing, tlb hoist) alive, in the Linux
  kernel, no fatal. No witness has run on the final tree (closure-r127m).
- mmu leaf: builds now; its router miter (`g6lc_shared_tlb` bypass arm vs
  `g6lc_tlb_miss_router`) is red at HEAD on two simulators; not usable as a gate.
NOT DONE: IqSelStages, wbuffer versioned writes, realign per-position targets, csr trap-write
record, FreelistPickStages, decode legality table, LoadPubStages, AesStages, staged-MMU LSU
repair, router-miter repair; APU: gemm_seq 52.0, island_top submit mux 43.2, pe_dot_float_pipe
38.8, cluster_dispatch 34.3, l2_top collector 52.7, l2_mshr 39.8, hub 66.1 residual chain,
ai_fp_dot / cluster_set / cluster_tile / fp_mac (behavioural reference arithmetic).
NEXT CHEAP STEP: boot witness on the final tree — `remote_witness.sh hyp8-r127m-aggregate-t1
hyp8-osbi-scalar-r127m` (host is shared; the r127d witness can be stopped first, pid 875698,
after checking its cmdline as in `build/r127-remote/stop-staged.cmd`).

- FINAL-TREE WITNESS LAUNCHED: `hyp8-osbi-scalar-r127m` (pid 994343, model of
  `hyp8-r127m-aggregate-t1` = closure-r127m = the current core tree, default binding; r126
  recipe). The r127d witness keeps running beside it (pid 875698: cyc=88M ret=23.43M ipc 0.266,
  in the kernel, 0 fatal / 0 equiv errors, uart unchanged since "Kernel command line").
  Check both: `remote_witness_status.sh hyp8-osbi-scalar-r127m hyp8-osbi-scalar-r127d`.
  Verdict rule for r127m: same `ret=` as r127d at equal `cyc=` (the r127 edits after r127d are
  latency-neutral, so the two traces must agree cycle for cycle; compare with the per-cyc
  query in `build/r127-remote/probe5.cmd`), no %Fatal / `equiv ...` / `not one-hot` line.

- FINAL-TREE WITNESS first agreement point: at cyc=2,000,000 `hyp8-osbi-scalar-r127m` reports
  ret=537393 ack_cyc=353291 ack_full=184102 — identical to `hyp8-osbi-scalar-r127d` at the same
  cycle; 0 %Fatal / equiv / not-one-hot lines. (r127d reference points: 4M ret=1105424,
  6M ret=1657928, 20M ret=5557886, 22M ret=5925327, 34M ret=8384323, 72M ret=18576657,
  88M ret=23427325.) Re-run `build/r127-remote/probe8.cmd` (edit the cycle list) to extend
  the comparison; it is the cheapest strong check of the post-r127d edits.

- WHOLE-CORE BOARD `core-all-r127-final4` (tree == closure-r127m, the final tree): board worst (clock rule) 36.9 (load_unit.reg1/D).
  live any-kind: g6lc_decode_s3 44.5, instr_queue 43.2, load_unit 43.2, g6lc_rename_read 40.2, aes 39.9, wt_dcache_wbuffer 39.5, g6lc_ptw_leg_decode 38.2, g6lc_iq 37.1, g6lc_ptw 36.0, csr_regfile 35.3.
  live clock rule: load_unit 36.9, g6lc_ptw 36.0, csr_regfile 35.3, instr_realign 34.5, g6lc_tlb 34.1, alu 32.9, g6lc_fe_override 32.5, g6lc_bp_ckpt 32.3.
  NOTE g6lc_iq reads **37.1** on this board (36.0 before the B2 knob existed; 52.5 was the
  figure with the first `c_used` text and no longer applies). The +1.1 is not a drop: the
  analyzer bills the off-by-default `gen_steer2` arm with the default arm, and the default arm
  itself gained one alias hop (`steer_found = c_found`; arm-only default board 36.4). The
  knob's benefit exists only when enabled (arm-only STEER2: 32.3 in->reg, 27.4 in->out).
  If a strictly non-rising default row is required, B2 must be reverted (revert list above).


## /goal continuation (after the r127m report)

- Witness check: `hyp8-osbi-scalar-r127m` == `hyp8-osbi-scalar-r127d` at cyc=4M too
  (ret=1105424 ack_cyc=723600 ack_full=381824), 0 fatal/equiv lines; both alive.
- KNOB INVENTORY (grep of `core/` outside `include/`): implemented in RTL = `IqArbStages`
  (g6lc_iq_arb), `LoadPubStages` (g6lc_lu_result, load_unit, g6lc_iq), `LoadExPubStages`
  (load_unit), `LsqReduceStages` (g6lc_lsq, g6lc_lsq_reduce), `IqSteerStages` (g6lc_iq, r127),
  `TlbStages`/`PtwDecodeStage` (MMU). Declared in g6lc_hyp_pkg but with NO RTL arm:
  `IqSelStages`, `FreelistPickStages`, `RenameReadStages`, `StoreTransStages`, `TlbCtxStages`,
  `LsqVerdictStages`, `CsrReadMuxStages`, `CommitStages`, `AesStages`, `MissunitResultStages`.
- DEEP PROFILE (LoadPubStages=2 / LoadExPubStages=2, `-DG6LC_HYP8_DEEP`, target
  `g6lc64_hyp8_deep`) remote gate LAUNCHED: closure-r127n (= closure-r127m tree),
  `remote_gate.sh r127n --env HYP8_BUILD_TARGET=g6lc64_hyp8_deep` ->
  `build/r127-remote/r127n.summary.txt`. First run of the deep profile since HypCfg reaches the
  LSU. 12/12 pass (cycle counts may differ) => candidate for a witness; a failure names the
  owner through the in-module asserts.

- AI GROUP LIVENESS (textual instantiation closure from `g6lc_ai_island_top` over the hyp APU
  tree; a superset of the elaborated hierarchy): on-board AND reachable = gemm_seq 52.0,
  gemm_fp32_norm 44.1, island_top 43.2, pe_dot_float_pipe 38.8, gemm_fp32_align 36.7,
  desc_engine 34.8, cluster_dispatch 34.3, gemm_store_plan 31, policy_subcode 30, desc_fetch 30,
  pmu_rate 29, cap_window 29, policy_topology 28, inval_queue 26, dram_timing 25, mul_seq 20 ...
  NOT instantiated by any RTL: `g6lc_ai_fp_dot` 271.5 (sim-only FP model, used only inside the
  `FP_REAL_MODEL` generate of cluster_set / cluster_tile), `g6lc_ai_cluster_set` 71.5 and
  `g6lc_ai_cluster_tile` 32 and `g6lc_ai_fp_mac` 32 (SKU models instantiated only by
  `verif/tb/ai_island/tb_g6lc_ai_throughput.sv`; headers say "AS-IS production copy"),
  `g6lc_ai_gemm_arplan` 59 (nowhere), `g6lc_ai_island_apb` 14 (wrapper top), `g6lc_ai_enq_arb`
  14 (in g6lc_cluster). => the AI design unit's worst row is gemm_seq 52.0, not 271.5/71.5;
  fp_dot / cluster_set / cluster_tile / fp_mac are bench-only models and are EXCLUDED from the
  AI ranking (same rule as the core's non-elaborated rows). No RTL edit to them.

- Cluster-dispatch gate runner `run_cluster_dispatch_gate.sh <unique-tag>` (new): the production
  script/bench do not fit the hyp tree (Storamic-typed `corev_apu/src/g6lc_ai_dram_*`, a
  `storamic_ctrl_req_i` tie-off), so the runner makes scratch copies under
  `build/ai-gemm/cdisp-<tag>/` pointing at the hyp `src`/`include` and dropping that one pin.
  BASELINE (tag base3, unmodified hyp RTL): `PASS tb_g6lc_ai_cluster_dispatch`, `GATE_RC=0`.
- APU `g6lc_ai_cluster_dispatch` EDITED (not yet boarded/gated when written): `e_rem_q` /
  `e_lt_q` captured in DP_MUL_START (col0_q final since the DP_OFFSETS edge; n_q, slice_q job
  constants), DP_ADDR only compares+selects; reference assert `g6lc_r127_cdisp_rem_eq` in
  DP_ADDR. No latency change (existing phases). Board tag `apu-cdisp` (ai argv, `--modules
  g6lc_ai_cluster_dispatch`, was 34.3). Gate: `run_cluster_dispatch_gate.sh r127a`.
  Revert = `git checkout` of corev_apu/ai_island/g6lc_ai_cluster_dispatch.sv (hyp APU tree).

- APU `g6lc_ai_cluster_dispatch` BOARDED + GATED: `apu-cdisp` **34.3 -> 25.6** (rr 24.6; module
  max now in->out L625). `run_cluster_dispatch_gate.sh r127a`: `PASS tb_g6lc_ai_cluster_dispatch`,
  `GATE_RC=0`, 0 `equiv early remainder` lines (the assertion's $error string is present in the
  generated model, i.e. it was compiled in). KEPT.

- SETTLED DESIGNS already written (read `analysis/r76-program.md` §6, lines 165-209) for the
  unimplemented knobs: B4 `StoreTransStages=2` (register paddr with trans_id at the store unit;
  store->load forward +1 for the first cycle), B5 `TlbCtxStages=2` (per-entry cached context
  match at update edges, VPN equality live; EXACT with an equivalence assertion; obligation: no
  lookup consumes the cached bit in the cycle asid/vmid changes), B9 `RenameReadStages=2`
  (cycle 1 ckpt slot/count, cycle 2 lane assembly; rename +1), P9 `IqSelStages=2` (+1 issue
  latency for every class; r47 sticky kill must cover the new edge; last).
  `pe_dot_float_pipe` 38.8 reading: S2 `exp_min` tail tree over `group_min_q` (EXP_TAIL_LEVELS
  levels of 16-bit signed compare-select) in one stage; r94 already moved 3 levels into S1.

- Core `g6lc_mmu/g6lc_tlb.sv` EDITED again (not yet boarded/gated when written): PLRU victim
  select `replace_en[i]` as elaboration-time masks over the tree (`plru_ent_nodes`,
  `gen_replace_en`), the per-entry level walk kept as `rf_replace_en` + assertion
  `g6lc_r127_tlb_replace_eq`. Board tag `tlb-rep` (`--modules g6lc_tlb`, was rr 34.1). Gates:
  `run_gate.sh r127s2 dispatch` (full lint), `mmu_rows_probe.sh` (diagnostic copy of the mmu
  leaf — exercises TLB updates with the assertion live; expect `HYP8_MMU_PASS checked=714`),
  then a remote integration + witness. The file now carries two r127 hunks (flush-match hoist,
  remotely gated in r127m; this one is NOT). CORE TREE = closure-r127m + this hunk.

- `g6lc_tlb` replace_en masks BOARDED + locally checked: board `tlb-rep` rr **34.1 -> 22.9**
  (module max now L675 22.9); `mmu_rows_probe.sh` (diagnostic mmu-leaf copy, --assert, TLB
  sizes 4 and 16): `HYP8_MMU_PASS checked=714 miter=771`, `[equiv] g6lc_tlb plru: checked=771`,
  no `equiv replace_en masks` line. Full lint launched (`run_gate.sh r127s2 dispatch`).
  Still owed: remote integration (closure-r127o) + it rides the next witness.

- `gate-r127s2.log`: full lint clean (7 known) + `HYP8_DISPATCH_PASS 125` with the tlb
  replace_en masks in. (r127n deep-profile remote gate still building at ~920 s.)

- APU `g6lc_ai_pe_dot_float_pipe` EDITED (not yet boarded/gated when written): S2 block-exponent
  minimum over the registered group roots as a tournament (pairwise compares, one-hot winner =
  lowest index among equals, AND-OR of the roots) instead of the EXP_TAIL_LEVELS-deep
  compare-select tree. Self-checked by the existing `gexp_chk` assertion ("grouped
  exponent-min identity"). NOTE: the tail tree only exists for Lanes >= 16 (EXP_GROUPS > 1); the
  `run_nine_gate.sh float` mode runs lanes 1 and 3 (no tail) -> the gate must ALSO run lanes 16
  and 64. Board tag `apu-pdf` (ai argv, `--modules g6lc_ai_pe_dot_float_pipe`, was 38.8).
  Revert = `git checkout` of corev_apu/ai_island/g6lc_ai_pe_dot_float_pipe.sv (hyp APU tree).

- `g6lc_ai_pe_dot_float_pipe` tournament minimum: board `apu-pdf` 38.8 -> **80.2** (worse; the
  nested pairwise loop is billed as a serial chain). REVERTED with `git checkout` (file at
  HEAD). Do not retry a pairwise/tournament form; the remaining exact option is moving one more
  tree level into S1 (r94 pattern: `EXP_GROUP_LEVELS` 3 -> 4), which changes what S1 carries.

- REMOTE GATE r127n DONE (target `g6lc64_hyp8_deep`, closure-r127n = closure-r127m tree): lint
  rc=0, 12/12 pass, cycle counts IDENTICAL to r126, model `9e93afca44b7c4d6` (differs from the
  default r127m model, so the define changed the netlist). Reading of the profile
  (g6lc_hyp_pkg.sv L245-256 + load_unit.sv L596-601, L2099-2103): `Hyp8Deep` differs from Hyp8
  only by LoadPubStages=2 and LoadExPubStages=2. `LoadPubStages=2` has NO RTL arm (the r76
  registered publish record measured 42.0 -> 47.0 and was reverted; only the WAKE_LD sizing
  term reads it, inert with IqSpecWakeup=0). `LoadExPubStages=2` IS live (`LU_EXPEND`:
  exception completions go through the pending record) — and, since the r127 HypCfg threading,
  this is the first build in which it reaches the LSU. The 12 smokes take few load exceptions,
  so this is build + non-exception evidence only; a witness is needed.

- WITNESS BOOKKEEPING: `hyp8-osbi-scalar-r127d` (pid 875698, mine) STOPPED after the cmdline
  check to free a core; its last state: cyc=104,000,000 ret=28,281,265 ack_cyc=19,814,735
  ack_full=8,466,530, uart at "Memory: 235848K/262144K available ..." (kernel progressing, no
  fatal). Its log stays on the host as the reference trace for r127m (compare `ret=` at equal
  `cyc=` with `build/r127-remote/probe8.cmd`, reference points up to 104M).
  LAUNCHED `hyp8-osbi-scalar-r127n-deep` (model of `hyp8-r127n-aggregate-t1`, target
  `g6lc64_hyp8_deep`, i.e. LoadExPubStages=2 live in the LSU). Running witnesses of mine now:
  r127m (final default tree at launch time) and r127n-deep. The r126 witness (pid 726659) is
  from an earlier round and is left alone.
- REMOTE GATE r127o LAUNCHED (closure-r127o = closure-r127m + g6lc_tlb replace_en masks; default
  binding): `build/r127-remote/r127o.summary.txt`, expect 12/12 at the r126 counts.

- NEW SMOKE `verif/tests/custom/hyp8_sv39_load.S` (added to `TESTS` in
  `verif/regress/remote/run_hyp8_integration.py`; the closure glob `hyp8_*.S` picks it up ->
  closure-r127p has 745 files): M-mode opens PMP, installs one identity Sv39 gigapage at
  0x8000_0000, sets satp, mrets to S-mode; S-mode runs a 64-dword store/load loop, sub-word
  store->load, a pointer chase, then writes tohost. Codes: 1 pass, 3 S-mode data mismatch,
  ((16+mcause)<<1)|1 unexpected trap, budget-out = wedge. PURPOSE: the 12 older smokes never
  enable translation, so they cannot see ITLB/DTLB/PTW behaviour; the Linux witness needs 22 M
  cycles to reach the first translated load. This test is the fast gate for the r127 TLB
  edits (flush-match hoist, replace_en masks) and the fast REPRODUCER candidate for the
  staged-MMU wedge.
  QUEUE (one remote integration at a time): r127o (in flight, 12 tests, default + replace_en
  masks) -> `remote_gate.sh r127p` (closure-r127p, default binding, 13 tests: sv39 must PASS) ->
  `build_closure.py .../closure-r127q` + `remote_gate.sh r127q --env
  HYP8_BUILD_TARGET=g6lc64_hyp8_mmu_staged` (expect sv39 to wedge/fail = reproducer).

- `hyp8_sv39_load.S` pre-checked off the RTL: assembles with the integration's GCC flags and
  linker script (tohost at 0x80001000 as declared), and on spike (`--isa=rv64gc`, script
  `build/r127-whatif/build_sv39.sh`) it ends with `mem 0x80001000 0x00000001` (pass code 1),
  rc=0. So the test itself is architecturally valid; any RTL failure is the RTL's.

- APU hub EDITED again (not yet boarded/gated when written): `aw_fire_inv` = a dedicated copy of
  the AW fire event (same expression as the grant process's `aw_grant && aw_ready`; assertion
  `g6lc_r127_hub_aw_fire_copy`) used only by the invalidation cone (inv_new, sf_hit/over,
  inv_ot stamp). Board tag `apu-hub-fire` (coh argv, was 66.1 any / 62.6 rr). Gate:
  `run_hub_bench.sh fire` lines == `build/hub-a.txt`. Revert = remove the copy + the five uses.

- Hub `aw_fire_inv` copy: board `apu-hub-fire` rr 62.6 -> 61.9, module max unchanged 66.1.
  REMOVED (a 0.7 gain does not justify a duplicated grant expression); the hub file is
  byte-identical (modulo line endings) to the copy in closure-r127o, i.e. the gated
  `inv_wr_cand` state. Hub stays at 66.1.

- REMOTE GATE r127o DONE (closure-r127o = closure-r127m + g6lc_tlb replace_en masks; default
  binding): lint rc=0, 12/12 pass, cycle counts identical to r126. CORE TREE == closure-r127o.
  (`g6lc_tlb` rr 34.1 -> 22.9; its strongest evidence so far is the mmu-leaf diagnostic copy
  with the assertion live; the sv39 smoke and the next witness add to it.)
- REMOTE GATE r127p LAUNCHED (closure-r127p = closure-r127o tree + the new `hyp8_sv39_load`
  smoke, default binding, 13 tests): `build/r127-remote/r127p.summary.txt`. Need 13/13;
  `hyp8_sv39_load: pass` is the first translated-load evidence at smoke speed for the r127 TLB
  edits. Then closure-r127q + `remote_gate.sh r127q --env
  HYP8_BUILD_TARGET=g6lc64_hyp8_mmu_staged` (expect the sv39 test to wedge/fail = reproducer).

- Core `g6lc_rename_read.ckpt_slot_n` EDITED (not yet boarded when written): the GENERAL
  (non-power-of-two slice) arm of the function — three serial conditional subtractions — as
  three parallel thresholds + one-hot select (exactly v - C*min(3, v/C)). In both hyp8
  bindings CKPT_PER_HART is a power of two (8 scalar, 4 SMT2), so this arm is DEAD there and
  the elaborated netlist cannot change; the board row (40.2, hot node L437 22.5) was billing
  that dead arm. Board tag `rr-ckflat`. Owed: a standalone miter of old-loop vs flat for
  C in 1..12 over all SUM_W values (the in-module T1 reference `ckpt_slot` only runs when the
  arm is live), full lint. Revert = restore the two-line loop (git diff of the file shows it;
  the file also carries the kept r127 group pick).

- `rr-ckflat`: g6lc_rename_read 40.2 -> 40.2 (no change; the 22.5 node is the function CALL
  site, not the dead arm's subtract chain). REVERTED; file byte-identical (modulo line endings)
  to closure-r127o. Third null/negative attempt on `ckpt_slot_n` (shift form 49.3, concat form
  49.3, flat general arm 40.2): the row needs the registered form (B9 `RenameReadStages=2`:
  slot/count in cycle 1, lane assembly in cycle 2), not another rank-0 rewrite.
  CORE TREE == closure-r127o.

- REMOTE GATE r127p DONE (closure-r127p = closure-r127o tree + `hyp8_sv39_load`, default
  binding): lint rc=0, **13/13 pass**; the 12 older tests at the r126 cycle counts and
  `hyp8_sv39_load: pass cycles=3893`. First smoke-speed evidence that translated S-mode
  loads/stores work on the default binding with the r127 TLB edits (flush-match hoist,
  replace_en masks). The smoke set of record is now 13 tests.
- REMOTE GATE r127q LAUNCHED: same tree, target `g6lc64_hyp8_mmu_staged`
  (`build/r127-remote/r127q.summary.txt`). If `hyp8_sv39_load` wedges/fails there while the 12
  others pass, it is the 4k-cycle reproducer of the staged-MMU Linux wedge; the per-test log is
  `remote-runs/hyp8-r127q-smokes-t1/hyp8_sv39_load.log` (in WSL: ~/cva6-remote-runs/...).

- STAGED-MMU READING (code facts, no edit): `g6lc_tlb` TLB_STAGED: T1 registers the request
  (`rq_*_q`, `t1_vld_q <= lu_access_i & ~any_tlb_flush`, L204-228), the compares run the next
  cycle on the registered request, T2 registers the verdict (`rsp_hit_q <= rsp_hit & t1_vld_q &
  ~any_tlb_flush`, L497-510): `lu_hit_o` answers TWO cycles after the request. `g6lc_mmu`
  data interface (L892-972): `lsu_dtlb_hit_o = dtlb_lu_hit` (combinational from the staged
  verdict), and `lsu_req_q / lsu_vaddr_q / dtlb_hit_q / dtlb_pte_q` are captured TOGETHER one
  cycle after the request (`dtlb_hit_n = dtlb_lu_hit`), i.e. the code pairs the request of
  cycle N with the TLB answer of cycle N — which under staging is the answer to cycle N-2's
  request. Correct only while the LSU holds the same request for >= 3 cycles. The shared-TLB /
  miss-router side is aligned by `dtlb_acc_dly[STLB_DLY]` (L415-470). `load_unit` uses
  `dtlb_hit_i` in LU_B_IDLE (issue D$ request; `!dtlb_hit_i` after a grant ->
  ABORT_TRANSACTION), in WAIT_TRANSLATION (`if (dtlb_hit_i) -> WAIT_GNT`, L1276-1285) and in
  `tr_idle_ok` / `load_pa_now_v`; no `TlbStages` awareness anywhere in the LSU (grep: only
  g6lc_tlb, g6lc_mmu, a comment in g6lc_shared_tlb). Suspects, in order: (1) after a PTW
  update the held request still reads "miss" for two cycles, so the miss router can start a
  second walk for the same page (repeat = livelock or a stale `lsu_valid_o` pairing);
  (2) `dtlb_hit_q`/`dtlb_pte_q` paired with a request that changed inside the 2-cycle window
  (a store and a load alternating on the single DTLB port); (3) the first-cycle D$ request in
  LU_B_IDLE is always aborted under staging (hit can never be seen in the request cycle).
  The r127q run (staged target + `hyp8_sv39_load`) decides whether this reproduces in ~4k cycles.

- APU `g6lc_ai_gemm_seq` EDITED (not yet boarded/gated when written): `stc_j_next` (= stc_j_q +
  retire elems) and `stc_row_done` (= stc_j_next >= n_q) formed once from registers and shared
  by `store_rows_done`, the store plan's `retire_row_i` and the column update under
  `store_b_fire` (which used to form its own add + compare behind the B handshake). Pure
  common-subexpression hoist, same values. Board tag `apu-gseq` (ai argv, `--modules
  g6lc_ai_gemm_seq`, was 52.0; second row 51.6 was this add). Gate: `run_island_gate.sh
  r127-gseq gemm` (run_nine_gate.sh gemm: backends dpf 0/2 + review cases) and island.
  Revert = `git checkout` of corev_apu/ai_island/g6lc_ai_gemm_seq.sv (hyp APU tree; no other
  r127 edit in that file).

- gemm_seq boards: `apu-gseq` (stc_j_next/stc_row_done hoist) module 52.0 unchanged (limiter =
  store_reset -> state_d) but the 51.6 `stc_j_d` row is gone and `stc_i_d` 43.8 -> 40.1;
  `apu-gseq2` (+ `!rows_left_q` instead of `i_q >= m_q` in `store_reset` and the ST_MAC done
  test; rows_left_q is the r23 registered fact with its own assertion) module **52.0 -> 51.0**.
  NOT gated yet: `run_island_gate.sh r127-gseq gemm` owed (the r23 assertion
  `state_q == ST_MAC |-> rows_left_q == (i_q < m_q)` is what makes the substitution exact).

- GEMM gate LAUNCHED for the gemm_seq edits: `run_island_gate.sh r127-gseq gemm` -> log
  `build-platform/workspace/build/r127-apu-gemm-r127-gseq.log` (need `GATE_RC=0`; any
  `rows_left_q` / assertion failure line = revert `g6lc_ai_gemm_seq.sv` with git checkout).

- `run_island_gate.sh r127-gseq gemm` FAILED TO BUILD, not on RTL: the production bench
  `verif/tb/ai_island/tb_g6lc_ai_gemm_backend.sv` (changed 2026-11-04, d465cc28c) ties off
  `storamic_ctrl_req_i`, a pin the hyp DRAM join does not have (`PINNOTFOUND`), so the
  `gemm` mode of run_nine_gate.sh no longer works against the hyp tree. NEW runner
  `run_gemm_gate.sh <unique-tag> [name.sv=/abs/replacement.sv]`: same gemm mode (golden C for
  nch x dpf 0/2, then the five review cases, --assert, hyp include/src) with a scratch bench
  copy that drops that one connection; the optional argument substitutes one RTL file for an
  A/B against HEAD. LAUNCHED on the working tree: tag r127a -> log
  `build/r127-apu-gemm-r127a.log` (+ `.out`). Need `GATE_RC=0`. If it fails, run the baseline
  `run_gemm_gate.sh head g6lc_ai_gemm_seq.sv=<HEAD copy>` before blaming the edit.

- **STAGED-MMU REPRODUCER CONFIRMED** — REMOTE GATE r127q (target `g6lc64_hyp8_mmu_staged`,
  closure-r127q = closure-r127p tree, model `1574c6b93c25170c`): the 12 older smokes pass;
  `hyp8_sv39_load: fail cycles=400000 rc=120` (budget-out = wedge). The same test passes in
  3,893 cycles on the default binding (r127p). So `verif/tests/custom/hyp8_sv39_load.S` is the
  fast reproducer of the staged-MMU Linux wedge. Per-test log (WSL):
  `~/cva6-remote-runs/hyp8-r127q-smokes-t1/hyp8_sv39_load.log`; rerun with traces:
  `HYP8_ONLY=hyp8_sv39_load` + `HYP8_PLUSARGS="+hang_dump=2000 +stall_census"` through
  run_hyp8_smokes.py on `hyp8-r127q-aggregate-t1`.
- GEMM gate `run_gemm_gate.sh r127b` (working tree incl. the gemm_seq stc_j_next/stc_row_done
  hoist and the `!rows_left_q` substitution; --assert): `GATE_RC=0` (PASS lines in
  `build/r127-apu-gemm-r127b.log`). gemm_seq edits KEPT (52.0 -> 51.0; second row 51.6 gone).

- REPRODUCER DIAG 1 (`remote_smoke_one.sh hyp8-r127q-aggregate-t1 hyp8_sv39_load
  hyp8-r127q-sv39-diag1`, new script: one smoke of an existing integration with plusargs;
  reader `build/r127-whatif/read_sv39_diag.sh`): under the staged MMU the 64 translated STORES
  retire (stall-census `st=65`, 378 instructions retired), then the FIRST translated LOAD
  (`ld t1,0(a4)` pc 0x800000e4, tid/slot 25, vaddr 0x80003000) is issued and never completes:
  hang dump cyc=4370 `SB head slot=25 issued=1 valid=0 fu=1 op=37`, `lsu_rdy=0`, `retired ld=0`,
  LSQ ld[0] id=25 addr_v=1 done=0 (+3 younger loads queued behind it). So: stores translate
  and commit under TlbStages=3; the load path does not. Next: `+ld_state +trace_from/_to` run
  to read the load FSM states around cyc 2300-2460.

- **STAGED-MMU WEDGE ROOT CAUSE (from the load FSM trace, diag2 = `remote_smoke_one.sh
  hyp8-r127q-aggregate-t1 hyp8_sv39_load hyp8-r127q-sv39-diag2 '+ld_state +trace_from=2250
  +trace_to=2480' 3000`, reader `build/r127-whatif/read_ldst.sh`):** a 3-cycle livelock in
  `load_unit` for the first translated load (tid 25, va 0x80003000):
    c=2350 IDLE          treq=1 dtlb=0 dreq=1 gnt=1  -> grant without a hit -> ABORT_TRANSACTION
    c=2351 ABORT         treq=0 (the FSM drops translation_req_o for this one cycle) kill=1
    c=2352 WAIT_TRANSL.  treq=1 dtlb=1 (= the answer to c=2350's request)      -> WAIT_GNT
    c=2353 WAIT_GNT      dreq=1 gnt=1 dtlb=0 (= the answer to c=2351, a NON-request cycle)
                         -> grant without a hit -> ABORT_TRANSACTION, and the loop repeats.
  With TlbStages=3 every cycle's `dtlb_hit_i` answers the request of two cycles earlier; the
  one-cycle hole the FSM leaves in `translation_req_o` during ABORT lands exactly on the
  WAIT_GNT sampling cycle. The unstaged TLB answers in the request cycle, so the hole is
  invisible there. Stores are unaffected (their request is held). `load_pa_q` is captured
  correctly (0x80003000) — the TLB itself is right.
  FIX DIRECTION (config-gated, default netlist untouched): under `HypCfg.TlbStages >= 2` keep
  `translation_req_o` asserted through ABORT_TRANSACTION so a held load presents a continuous
  request; update the `rf_translation_req_o` reference FSM (load_unit.sv L2170+) the same way.
  Gate: target `g6lc64_hyp8_mmu_staged` 13/13 with `hyp8_sv39_load` passing, default 13/13
  unchanged, then the staged witness.

- **STAGED-MMU FIX APPLIED (uncommitted, NOT yet linted/gated when written)** — both hunks are
  constant-folded away when TlbStages == 1 (the default binding):
  1. `core/load_unit.sv`: `LU_TLB_STAGED` localparam; `tr_abort_hold` keeps
     `translation_req_o` asserted in ABORT_TRANSACTION under the staged TLB (closes the
     3-cycle livelock); the reference FSM `rf_translation_req_o` gets the same term.
  2. `core/g6lc_mmu/g6lc_mmu.sv`: `itlb_ans_cur` / `dtlb_ans_cur` — the staged verdict counts as
     a hit for the fetch / LSU consumers only when it belongs to the request presented now
     (an access STLB_DLY cycles ago for the same VPN, ASID, VMID, hart); used by
     `lsu_dtlb_hit_o`, `dtlb_hit_n` and the ITLB-hit test. The miss router keeps the
     unqualified verdict with its own delayed request record. Reason: the unstaged code pairs
     the answer with the CURRENT vaddr; under staging that answer is two requests old, so a
     page change used the previous page's PTE for two cycles.
  NEXT: `run_gate.sh r127t dispatch lsq dcache` (full lint, default arm leaves), then
  closure-r127r: `remote_gate.sh r127r` (default, 13/13 at the same counts) and
  `remote_gate.sh r127r2 --env HYP8_BUILD_TARGET=g6lc64_hyp8_mmu_staged` (closure-r127r2;
  need 13/13 incl. `hyp8_sv39_load`), then a staged witness. Revert = remove the two hunks
  (`git diff` of the two files; load_unit.sv and g6lc_mmu.sv also carry kept r127 edits).

- `gate-r127t.log` (staged-MMU fix in; default binding): full lint clean (7 known),
  `HYP8_DISPATCH_PASS 125`, `HYP8_LSQ_PASS 2826`, `HYP8_DCACHE_PASS 334`.
- REMOTE GATE r127r LAUNCHED on the STAGED target (`g6lc64_hyp8_mmu_staged`, closure-r127r =
  current tree with the staged-MMU fix): `build/r127-remote/r127r.summary.txt`. Decisive
  line: `hyp8_sv39_load` (r127q without the fix: fail cycles=400000). After it: closure-r127s2
  + plain `remote_gate.sh r127s2` for the default binding (expect 13/13 at the r127p counts:
  685 1011 492 2364 2199 1231 671 3038 9095 5959 883 983 3893).

- Board `mmu-stagedfix` (default param map): g6lc_mmu any 24.6 -> 30.4 (reg->out L811), rr 4.5 ->
  11.0; load_unit unchanged (43.2 / rr 36.9). The rise is the staged-only `*_ans_cur` VPN
  compare, which the analyzer bills although `STLB_DLY == 0` folds it to a constant in the
  default netlist (same both-arms billing as `gen_steer2`). Under the staged profile the cost
  is real: a ~27-bit equality in front of the registered verdict; a cheaper staged form
  (registered "same page as last cycle" bit) is a follow-up, correctness first.

## RESUME HERE (state while r127r is building) — supersedes earlier RESUME blocks

Nothing is committed. Core tree = closure-r127r (= closure-r127o + new smoke + staged-MMU fix).
Remote smoke set of record = 13 tests (12 + `hyp8_sv39_load`, 3,893 cycles on the default).
IN FLIGHT: `remote_gate.sh r127r --env HYP8_BUILD_TARGET=g6lc64_hyp8_mmu_staged`
(`build/r127-remote/r127r.summary.txt`): need 13/13 with `hyp8_sv39_load` PASS (it wedged at
400000 without the fix, r127q). THEN: `build_closure.py .../closure-r127s2` + plain
`remote_gate.sh r127s2` (default binding; expect 685 1011 492 2364 2199 1231 671 3038 9095
5959 883 983 3893). If the staged target passes: launch a staged witness
(`remote_witness.sh hyp8-r127r-aggregate-t1 hyp8-osbi-scalar-r127r-mmustaged`) and compare
with the default trace (r127d reference points in this ledger; staged cycle counts WILL
differ, so the criterion is positive milestones: `Linux version` on uart, no hang dump).
Witnesses of mine running: `hyp8-osbi-scalar-r127m` (default, final-at-launch tree) and
`hyp8-osbi-scalar-r127n-deep` (LoadExPubStages=2). Check: `remote_witness_status.sh <tags>`.
Since the r127m report, DONE: cluster_dispatch 34.3 -> 25.6 (gated), g6lc_tlb replace_en masks
rr 34.1 -> 22.9 (r127o + mmu rows probe), gemm_seq 52.0 -> 51.0 (gemm gate), deep profile
smoke-gated (r127n), sv39 smoke added, staged-MMU wedge root-caused + fix applied.
REVERTED (measured worse/null): pe_dot_float_pipe tournament (80.2), hub aw_fire copy, rename
ckpt general-arm flatten. AI liveness: fp_dot / cluster_set / cluster_tile / fp_mac /
gemm_arplan are instantiated by no RTL (excluded from the AI ranking).
STILL NOT DONE: IqSelStages, RenameReadStages (B9), FreelistPickStages, StoreTransStages (B4),
TlbCtxStages (B5), wbuffer versioned writes, realign per-position targets, csr trap-write
record, decode legality table, AesStages; APU: gemm_seq 51.0 (store_reset -> state_d),
gemm_fp32_norm 44.1 / align 36.7, island_top submit mux 43.2, pe_dot_float_pipe 38.8,
l2_top collector 52.7, l2_mshr 39.8, hub 66.1; mmu-leaf router miter red at HEAD.

- **STAGED-MMU FIX VERIFIED AT SMOKE LEVEL** — REMOTE GATE r127r (target
  `g6lc64_hyp8_mmu_staged`, closure-r127r = tree with the fix): lint rc=0, **13/13 pass**;
  `hyp8_sv39_load: pass cycles=4219` (r127q, same target without the fix: wedged at 400000;
  default binding: 3893 cycles). The 12 M-mode tests keep the r126 counts.
- LAUNCHED: (1) default-binding gate `remote_gate.sh r127s2` (closure-r127s2 = same tree) ->
  `build/r127-remote/r127s2.summary.txt`, expect 13/13 at 685 1011 492 2364 2199 1231 671 3038
  9095 5959 883 983 3893 (the fix must fold away under TlbStages=1); (2) staged witness
  `hyp8-osbi-scalar-r127r-mmustaged` on the model of `hyp8-r127r-aggregate-t1` (r126 recipe).
  The pre-fix staged witness wedged at cyc 22,258,830 / ret 5,985,483: the new one must pass
  that point and print `Linux version` on uart. Check with
  `remote_witness_status.sh hyp8-osbi-scalar-r127r-mmustaged`.

- WITNESS AGREEMENT (probe8, 11:58 remote): `hyp8-osbi-scalar-r127m` (final default tree at
  launch = closure-r127m) reports the SAME `ret / ack_cyc / ack_full` as the r127d reference
  at cyc = 10M, 20M, 30M, 40M and 50M (50M: ret=12095520 ack_cyc=8217651 ack_full=3877869),
  0 fatal/equiv lines, `Linux version` on uart. => the edits made after r127d (missunit lanes,
  store_unit lanes, load_unit ex_ctx_ok, wbuffer merge select, B2 plumbing, tlb flush hoist)
  are cycle-exact through OpenSBI and 28M cycles of translated kernel execution.
  `hyp8-osbi-scalar-r127n-deep` (LoadExPubStages=2) at cyc=40M: ret=9940875 ack_cyc=6710647
  ack_full=3230228 — also identical to the reference, in the kernel, no fatal.
  `hyp8-osbi-scalar-r127r-mmustaged` (staged MMU + fix): just started.

- REMOTE GATE r127s2 DONE (default binding, closure-r127s2 = tree with the staged-MMU fix):
  lint rc=0, **13/13 pass** at 685 1011 492 2364 2199 1231 671 3038 9095 5959 883 983 3893 —
  identical to r127p, so both fix hunks fold away under TlbStages=1 as intended.
  CORE TREE == closure-r127s2. Default-binding integrations so far: r127, b..i, k, m, o, p, s2.

- Staged witness `hyp8-osbi-scalar-r127r-mmustaged` (pid 1041613) at 12:19 remote: alive,
  OpenSBI banner, cyc=8M ret=2,205,976 ipc 0.276, 0 fatal/equiv. Its decisive point is the
  pre-fix wedge at cyc 22,258,830 / ret 5,985,483 (first translated kernel load) — it must
  retire past it and print `Linux version`. Rate ~0.4M cyc/min => ~35 min after this entry.

- Staged witness at 12:21 remote: still at the cyc=8M census line (next line at 10M); r127m at
  58M and r127n-deep at 46M, both in the kernel (uart at "Memory: ... available"), 0 fatal.
- Reading of the rename_read 22.5 node (L437, IR node 12778): it is the GUARDED assignment
  `ckpt_slot = ckpt_slot_n(...)` whose guard is `cnt + sb_cnt < CKPT_PER_HART` — the add +
  compare behind sb_cnt is billed on that node (which is why rewriting the function body three
  times moved nothing). EDITED (not yet boarded when written): the room test as constant
  compares of the registered counter (`ck_room_k[k] = cnt < CPH - k`) selected by sb_cnt
  (`gen_room_k`, assertion `g6lc_r127_ckroom_eq`). Board tag `rr-room` (was 40.2). Keep only
  on a drop; revert = remove the `gen_room_k` block + restore the 3-line guard.

- `rr-room`: g6lc_rename_read 40.2 -> 40.5 (null/worse). REVERTED; file byte-identical (modulo
  line endings) to closure-r127s2. FOURTH null on this row (shift 49.3, concat 49.3, flat
  general arm 40.2, room hoist 40.5). Stop rank-0 attempts on g6lc_rename_read: the remaining
  path is in->out through `ck_sum` -> guarded slot write -> lane assembly, and only the
  registered split (B9 `RenameReadStages=2`) removes it. CORE TREE == closure-r127s2.

- **mmu-leaf ROUTER MITER — owner found.** A/B `mmu_ab_stlb.sh` (the pre-r86
  `g6lc_shared_tlb.sv` of commit 3cf1087f1 substituted in the flist, everything else the
  current tree): the mmu leaf PASSES in full — `HYP8_MMU_PASS checked=716 miter=771`, 0
  `MMU_MITER_G*` mismatch lines. So the red miter comes from the r86-r90 change to
  `g6lc_shared_tlb.sv` (commit 9966c06c2, +29/-6), i.e. the REFERENCE arm
  (`UseSharedTlb=0` bypass) moved while `g6lc_tlb_miss_router` (last touched in 3cf1087f1)
  did not. Not yet decided which side is right: read `git diff 3cf1087f1 9966c06c2 --
  .../g6lc_mmu/g6lc_shared_tlb.sv` (F17/F18 fix vs cone reduction). Note the leaf's
  `checked=716` here vs 714 in the neutralized-probe run (the two miter verdict checks).

- Router-miter cause READ: r90 (9966c06c2) gated the flush walk of `g6lc_shared_tlb` with
  `G6LCCfg.UseSharedTlb &&` (5 sites). With UseSharedTlb=0 that module is ONLY the reference of
  the mmu leaf's router miter (hyp8 instantiates `g6lc_tlb_miss_router` instead, g6lc_mmu.sv
  L499/L558), and the router keeps the flush quiet window, so reference and DUT diverged.
  EDITED (not yet run when written): the 5 gates removed in
  `core/g6lc_mmu/g6lc_shared_tlb.sv` (constant 1 when UseSharedTlb=1; the r90 one-hot flush
  kind is kept). Not live in hyp8 -> no closure/witness impact, but it is in the flist: run
  `run_gate.sh r127u mmu dispatch` (full lint + the REAL mmu leaf: expect `HYP8_MMU_PASS
  checked=716`, 0 MMU_MITER lines). Revert = `git checkout core/g6lc_mmu/g6lc_shared_tlb.sv`.

- **mmu LEAF GREEN AGAIN** — `gate-r127u.log` (5 `UseSharedTlb &&` gates removed from the
  `g6lc_shared_tlb` flush walk): full lint clean (7 known), `LEAF mmu-r127u rc=0`,
  `HYP8_MMU_PASS checked=716 miter=771`, 0 `MMU_MITER_G*` mismatch lines. The mmu leaf is a
  usable local gate again (incl. the staged TLB row predicates and the r127 `replace_en`
  assertion). KEPT. `g6lc_shared_tlb` is not elaborated in hyp8 (UseSharedTlb=0 instantiates
  the miss router), so closures/witnesses are unaffected; it rides the next closure for lint.
  Remote leaf of record: `LEAF_RUN=t3 remote_leaf.sh <closure-tag> mmu` once a closure with
  this file exists.

- **mmu LEAF GREEN ON THE REMOTE TOOLCHAIN TOO**: `LEAF_RUN=t1 remote_leaf.sh r127v mmu`
  (closure-r127v = current tree incl. the shared_tlb gate removal; pinned 5.008-g6lc + its
  runtime): `HYP8_MMU_PASS checked=716 miter=771`, `HYP8_MMU_LEAF_PASS warnings=none`.
  The mmu leaf is a gate of record again, locally and remotely. CORE TREE == closure-r127v
  (= closure-r127s2 + the non-elaborated g6lc_shared_tlb.sv change).
- Staged witness at 12:28 remote: cyc=12M ret=3,309,988 (identical to the default trace at
  12M), 0 fatal. Decisive point 22.26M still ahead.
- Knob triage against the CURRENT board (what each unimplemented knob could still move):
  TlbCtxStages -> g6lc_tlb lookup is not a board row any more (module 22.9, update path):
  NOT WORTH implementing. StoreTransStages -> store_unit is 22.4 after the byte lanes: not a
  top row. Remaining rows that need a contract: decode_s3 44.5 (legality), instr_queue 43.2,
  load_unit 43.2/36.9, rename_read 40.2 (B9), aes 39.9, wbuffer 39.5, ptw 36.0, csr 35.3,
  realign 34.5, alu 32.9, fe_override 32.5, bp_ckpt 32.3, iq_arb 32.2 / iq_bank 30.1.

- HOT-NODE LIST of the final board (live rows >= 28 with a node >= 12; from
  `core-all-r127-final4`): load_unit ir 43.2 (L1069/L1072 `state_d` 29.8, IDLE decision nest);
  rename_read io 40.2 (L437 guarded slot write, 4 nulls — needs B9); aes ro 39.9 (L276
  `mix_inv_rot` 32.5 — an RV32-only arm, dead on RV64 but billed) and ir 39.3 (L194 S-box 24.0
  behind the 15.3 `aes_subw_in` select); wbuffer ro 39.5 (exp_pick 13.2 + user lanes);
  ptw_leg_decode io 38.2 (only in the unstaged binding); g6lc_ptw io 36.0 (dec_d.invalid 15.4);
  csr ir 33.5 (L3407 `tval_zero_m` 24.0 select fan-out; module max stays 35.3/34.9 anyway);
  alu rr 32.9 (L949 SLLIUW shift 26.0, L974 25.5); fe_override rr 32.5; iq_arb ro 31.8
  (issue_spec_o 20.3); realign rr 31.2; lsq ir 29.6 (vv_dist_d 22.1); missunit io 29.6
  (tmp_paddr 23.2); perf_counters io 29.4; multiplier io 28.2.
- NEXT (exact, self-contained): `aes.sv` — (a) the four `*_rot` expressions as one
  mixcolumn call + a 4-way byte-rotate select (they are rol32 by 8*orig_q[5:4]; RV32-only
  arms), (b) `aes_subw_in` per byte lane with its own copy of the rnum test. Gate: standalone
  miter (old vs new) + lint; no smoke covers AES.
- Staged-MMU default decision (inferred, not flipped): keep the unstaged binding as default
  even if the staged witness reaches the kernel — no witness in this round reached Linux init,
  and a flip changes the smoke baseline; recommend the flip to the user with the evidence.

- Core `aes.sv` EDITED (not yet boarded/linted when written): (a) the four aes32 `*_rot`
  expressions as a 4-way byte-rotate select (`aes_rol8x`) over one MixColumns call each
  (were a variable shift pair with the MixColumns formed twice); (b) `aes_subw_in` per byte
  lane with its own copy of the round test (`gen_subw_lane`). Miter
  `verif/tb/core/tb_g6lc_hyp8_aes_eq.sv` + `verif/regress/remote/hyp8/run_aes_eq.sh`:
  `[plain] HYP8_AES_EQ_PASS checked=33024` (rotates exhaustive over byte x index; subword over
  every round value x 2000 words), `[mut] ..._FAIL bad=32255`. Board tag `aes-rot`
  (`--modules aes`, was ro 39.9 / ir 39.3). No smoke exercises AES: evidence = miter + lint.
  Revert = `git checkout core/aes.sv`.

- `aes.sv` BOARDED: `aes-rot` module **39.9 -> 35.5** (reg->out L292), in->reg 39.3 -> 29.5,
  rr 26.0. Miter passes (above). Full lint LAUNCHED: `run_gate.sh r127w dispatch` ->
  `gate-r127w.log`. Then it rides the next closure (default binding) for the remote lint.

- `gate-r127w.log` (aes.sv edit in): full lint clean (7 known), `HYP8_DISPATCH_PASS 125`.
  aes KEPT (39.9 -> 35.5; in->reg 39.3 -> 29.5). Remaining aes rows are the MixColumns
  itself (`aes_mixcolumn_inv` 26.5 in one stage: aes32dsmi 35.5, aes64im 32.9).
  CORE TREE = closure-r127v + aes.sv (rides the next closure).
- Staged witness at ~12:40 remote: cyc=14M ret=3,879,492 (default trace has the same count at
  14M? reference points known: 12M 3,309,988; 16M 4,445,014), 0 fatal. Decisive: 22.26M.

- alu reading (NOT edited): the A3 rows are op arms that bypass the staged shifter — SLLIUW
  (L949, a full 64-bit variable shift in A3, 26.0), PACK_W (L974), CZERO (L955/957). Moving
  SLLIUW onto the staged shift places needs its A1/A2 pre-stage terms (shl_q, zero-extended
  operand) — an ALU-internal rank-1 change with the alu leaf (19,508 checks) as gate; not done.

- Staged witness `hyp8-osbi-scalar-r127r-mmustaged`: cyc=16M ret=4,445,014 ack_cyc=2,904,535
  ack_full=1,540,479 — identical to the default trace at 16M (M-mode/OpenSBI part, translation
  off). 0 fatal. Decisive point: must retire past ret 5,985,483 (pre-fix wedge at cyc
  22,258,830) and print `Linux version`.
- REMOTE GATE r127w LAUNCHED (closure-r127w = current tree: closure-r127s2 + shared_tlb flush
  gates removed + aes.sv rotate/subword rewrite; DEFAULT binding, 13 tests):
  `build/r127-remote/r127w.summary.txt`, expect 13/13 at 685 1011 492 2364 2199 1231 671 3038
  9095 5959 883 983 3893. Neither edit is exercised by the smokes (AES unused; shared_tlb not
  elaborated) — this run is their remote lint + a no-regression check.

- APU `g6lc_l2_top` EDITED again (not yet boarded/gated when written): collector position
  `collect_pos` (= fifo_wrap(fifo_rd_q + collect_cnt_q)) as a registered pointer
  `collect_pos_q`, advanced only by the collect-done event (`collect_done`, set where
  collect_cnt_d gets its +1; default 0 beside the other defaults); both head-retire sites move
  rd and collect_cnt together so the position is unchanged there. Reference assertion
  `g6lc_r127_l2_collect_pos_eq` every cycle. Board tags `apu-l2pos` (l2 argv) / `apu-l3pos`
  (l3 argv), was 52.7 / 55.5 with the collector add+wrap (8.5) at the head of the top paths.
  Gate: `run_l2_bench.sh r127c` (5 PASS lines, --assert). Revert = remove the block, restore
  the one-line assign, drop the two `collect_done` lines (git diff of the file; it also
  carries the kept wr_b_done_now edit).

- `apu-l2pos` board: g6lc_l2_top **52.7 -> 49.5** (rr; reg->out 48.5) with the registered
  collector position. L2 gate LAUNCHED: `run_l2_bench.sh r127c` ->
  `build/r127-apu-l2-r127c.txt` (need the five PASS lines + no `equiv collector position`
  line; marker `L2_R127C_DONE`). Keep only if it passes; the l3-argv board `apu-l3pos` is owed.

- L2 gate DONE for the registered collector position: `run_l2_bench.sh r127c` = five PASS lines
  (sim-default, sim-posted, sim-wupdate, sim-posted-wu, units), `fail=0`, no
  `equiv collector position` line in the run logs (the assertion was compiled under --assert).
  KEPT: g6lc_l2_top 59.9 -> 52.7 -> **49.5** on the l2 argv (l3 board `apu-l3pos` next).

- `apu-l3pos` (l3 argv): g6lc_l2_top 55.5 unchanged (its limiter there is rr L1269, a
  different cone; reg->out 52.3 -> 50.5). So l2 board 59.9 -> 49.5, l3 board 62.7 -> 55.5.

- Staged witness at cyc=20M: ret=5,557,886 ack_cyc=3,629,003 ack_full=1,928,883 (identical to
  the default trace at 20M), uart 1601 bytes, 0 fatal. The pre-fix wedge point (cyc 22.26M,
  ret 5,985,483) is ~6 min ahead. r127w remote gate building (367 s).

- **STAGED WITNESS STOPPED ON AN ASSERTION (my fix is incomplete):**
  `hyp8-osbi-scalar-r127r-mmustaged` died at sim time 22,264,368 (cyc ~22.26M, the first
  translated kernel load; last census cyc=22M ret=5,925,327 == default trace) with
  `load_unit.sv:2122 g6lc_pa_now_eq: load_pa_now_v diverged from translation_req_o decode`.
  Cause (by reading): the r45 identity `load_pa_now_v === valid_i && translation_req_o &&
  dtlb_hit_i` assumed translation_req_o is 0 in ABORT_TRANSACTION; my `tr_abort_hold` makes it
  1 there under the staged TLB, and `load_pa_now_v` (a direct state decode, L750) has no ABORT
  term. The sv39 smoke never had a hit visible in the ABORT cycle, so it passed. NEXT: read
  L739-775 (what `load_pa_now_v` captures) and extend the direct decode with the same staged
  ABORT term so the identity holds again; re-run staged target + witness.

- STAGED-MMU FIX, part 3 (applied, NOT yet gated when written): `pa_capture_state` gains the
  staged ABORT term (`LU_TLB_STAGED && state_q[LU_B_ABORT_TRANSACTION] && MmuPresent`) so
  `g6lc_pa_now_eq` (load_pa_now_v === valid_i && translation_req_o && dtlb_hit_i) holds with
  the held request; `LU_TLB_STAGED` moved up beside `LU_EXPEND`. Folds away at TlbStages=1.
  The r127w remote gate (default binding, closure built BEFORE this hunk) is still running.
  NEXT: `run_gate.sh r127x dispatch lsq dcache` (lint) -> closure-r127x:
  `remote_gate.sh r127x --env HYP8_BUILD_TARGET=g6lc64_hyp8_mmu_staged` (13/13) -> staged
  witness `hyp8-osbi-scalar-r127x-mmustaged` (must pass sim time 22,264,368) -> default gate.

- `gate-r127x.log` (staged-MMU fix part 3 in; default binding): full lint clean (7 known),
  `HYP8_DISPATCH_PASS 125`, `HYP8_LSQ_PASS 2826`, `HYP8_DCACHE_PASS 334`.
  r127w remote gate (closure built BEFORE part 3; default; aes + shared_tlb) still building at
  ~1260 s. QUEUE after it (one remote integration at a time):
  (1) `build_closure.py .../closure-r127x` + `remote_gate.sh r127x --env
      HYP8_BUILD_TARGET=g6lc64_hyp8_mmu_staged` -> need 13/13;
  (2) `remote_witness.sh hyp8-r127x-aggregate-t1 hyp8-osbi-scalar-r127x-mmustaged` -> must pass
      sim time 22,264,368 (g6lc_pa_now_eq) and ret 5,985,483, then print `Linux version`;
  (3) `build_closure.py .../closure-r127y` + plain `remote_gate.sh r127y` (default, 13/13 at
      685 1011 492 2364 2199 1231 671 3038 9095 5959 883 983 3893).

- REMOTE GATE r127w DONE (default binding; closure-r127w = closure-r127s2 + shared_tlb flush
  gates removed + aes.sv rewrite): lint rc=0, 13/13 pass at 685 1011 492 2364 2199 1231 671
  3038 9095 5959 883 983 3893. aes.sv and g6lc_shared_tlb.sv are remotely linted and
  regression-clean (neither is exercised by the smokes).
- REMOTE GATE r127x LAUNCHED on the STAGED target (closure-r127x = current tree incl. staged-MMU
  fix part 3 and the l2_top / gemm_seq / cluster_dispatch APU edits):
  `build/r127-remote/r127x.summary.txt`, need 13/13. Then the staged witness (queue above).

- APU `g6lc_ai_island_top` EDITED again (not yet boarded/gated when written): the submit
  select (fetch > sideband > doorbell) per output — `submit_arm_a/b/c` wires, valid/src/qid/
  ticket as separate assigns, the wide descriptor per byte lane behind lane-local copies of the
  one-hot arm selects (`gen_sdesc_lane`); the former single always_comb kept as
  `p_rf_submit` + assertion `g6lc_r127_submit_mux_eq`. Board tag `apu-itop2` (ai argv,
  `--modules g6lc_ai_island_top`, was 43.2 with L880 the limiter). Gate:
  `run_island_gate.sh r127-itop2` (island, --assert). Revert = restore the always_comb from
  the `p_rf_submit` text (or `git diff`; the file also carries the kept read-cone split).

- `apu-itop2` (submit select per output + descriptor byte lanes): g6lc_ai_island_top 43.2 ->
  42.9 only. REVERTED (0.3 does not justify the rewrite); the file is byte-identical (modulo
  line endings) to the copy gated in `build/ai-gemm/gemm-r127b/rtl` (i.e. it keeps only the
  read-cone split). island_top stays 43.2; its limiter is the submit arm condition itself.


## RESUME HERE (state while r127x is building) — supersedes earlier RESUME blocks

Nothing is committed. Working tree = closure-r127x (core: closure-r127w + staged-MMU fix
part 3 in load_unit.sv; APU: cluster_dispatch, gemm_seq, l2_top collector position kept).
IN FLIGHT: `remote_gate.sh r127x --env HYP8_BUILD_TARGET=g6lc64_hyp8_mmu_staged`
(`build/r127-remote/r127x.summary.txt`; need 13/13, `REMOTE_GATE_DONE` marker in the file).
THEN, in order:
 1. `remote_witness.sh hyp8-r127x-aggregate-t1 hyp8-osbi-scalar-r127x-mmustaged`; decisive
    checks with `build/r127-remote/probe9.cmd` (edit the tag inside): no `%Error` at sim time
    22,264,368 (`g6lc_pa_now_eq`), `ret` passes 5,985,483, `Linux version` on uart.
 2. `build_closure.py .../closure-r127y` + plain `remote_gate.sh r127y` (default, expect
    685 1011 492 2364 2199 1231 671 3038 9095 5959 883 983 3893).
 3. Final boards: `reboard_current.py core-all-r127-final5`; `apu-{ai,l2}-r127-final3`.
 4. Update `fo4-census.md` §6 + `../implementation-log.md` r127 section with: g6lc_tlb 22.9,
    aes 35.5, cluster_dispatch 25.6, gemm_seq 51.0, l2_top 49.5, staged-MMU fix (3 hunks),
    mmu leaf green again (shared_tlb flush gates), sv39 smoke, deep profile gated.
Witnesses of mine alive: `hyp8-osbi-scalar-r127m` (default) and `hyp8-osbi-scalar-r127n-deep`;
the staged one `hyp8-osbi-scalar-r127r-mmustaged` died on the assertion (expected, see above).
STILL NOT DONE: IqSelStages, RenameReadStages (B9), FreelistPickStages, wbuffer versioned
writes, realign per-position targets, csr trap-write record, decode legality table,
AesStages (MixColumns stage), alu SLLIUW onto the staged shifter; APU: gemm_seq 51.0
(store_reset -> state_d), gemm_fp32_norm 44.1 / align 36.7, island_top 43.2 (two nulls),
pe_dot_float_pipe 38.8 (tournament was worse), l2_mshr 39.8, hub 66.1.

- REMOTE GATE r127x DONE (STAGED target, closure-r127x incl. fix part 3): lint rc=0, **13/13
  pass**, `hyp8_sv39_load: pass cycles=4219`.
- LAUNCHED: staged witness `hyp8-osbi-scalar-r127x-mmustaged` (model of
  `hyp8-r127x-aggregate-t1`); decisive checks via `build/r127-remote/probe9.cmd` (now pointing
  at this tag): no `%Error` at sim time 22,264,368, `ret` beyond 5,985,483, `Linux version`.
  Also LAUNCHED the default-binding gate `remote_gate.sh r127y` (closure-r127y = same tree;
  expect 13/13 at 685 1011 492 2364 2199 1231 671 3038 9095 5959 883 983 3893).

- WHOLE-CORE BOARD `core-all-r127-final5` (tree == closure-r127y): board worst (clock rule) 37.0 (load_unit.reg1/D).
  live any-kind: g6lc_decode_s3 44.5, instr_queue 43.2, load_unit 43.2, g6lc_rename_read 40.2, wt_dcache_wbuffer 39.5, g6lc_ptw_leg_decode 38.2, g6lc_iq 37.1, g6lc_ptw 36.0, aes 35.5, csr_regfile 35.3, instr_realign 34.5, issue_read_operands 33.5.
  live clock rule: load_unit 37.0, g6lc_ptw 36.0, csr_regfile 35.3, instr_realign 34.5, alu 32.9, g6lc_fe_override 32.5, g6lc_bp_ckpt 32.3, g6lc_iq_arb 32.2, wt_axi_adapter 32.0, wt_dcache_wbuffer 31.4.
  (g6lc_mmu / g6lc_iq rows include the off-by-default staged arms the analyzer bills.)

- GROUP BOARDS `apu-{ai,l2}-r127-final3` (current tree):
  * ai: board worst 149.0 -> 71.5; changed: ai_cluster_dispatch 34.3->25.6; ai_desc_engine 46.5->34.8; ai_gemm_arplan 149.0->59.0; ai_gemm_seq 52.0->51.0; ai_island_top 43.9->43.2; design rows now: ai_gemm_seq 51.0, ai_gemm_fp32_norm 44.1, ai_island_top 43.2, ai_pe_dot_float_pipe 38.8, ai_gemm_fp32_align 36.7, ai_desc_engine 34.8
  * l2: board worst 59.9 -> 49.5; changed: l2_top 59.9->49.5; design rows now: l2_top 49.5, l2_mshr 39.8, l2_tag 36.0, l2_wtrk 27.9, l2_data 27.0, l2_rdtrk 18.6

- STATE at 08:31 local: r127y (default gate, closure-r127y) building; staged witness
  `hyp8-osbi-scalar-r127x-mmustaged` alive, just started (decisive point ~55 min after launch:
  sim time 22,264,368). `probe9.cmd` / `probe8.cmd` in `build/r127-remote/` now point at the
  r127x staged witness. Boards of record: core `core-all-r127-final5` (clock rule 37.0),
  APU `apu-{ai,l2}-r127-final3`, `apu-coh-r127-final2`, `apu-l3-r127-final` (+ `apu-l3pos`).
  AI design rows now: gemm_seq 51.0, gemm_fp32_norm 44.1, island_top 43.2,
  pe_dot_float_pipe 38.8, gemm_fp32_align 36.7, desc_engine 34.8. L2: l2_top 49.5, mshr 39.8.

- WAITING (08:58 local): r127y default-binding gate at ~1830 s (host loaded, slower than the
  usual ~25 min); staged witness `hyp8-osbi-scalar-r127x-mmustaged` running. Nothing else of
  mine is in flight except witnesses r127m (default) and r127n-deep. When
  `build/r127-remote/r127y.summary.txt` holds REMOTE_GATE_DONE: expect 13 `pass cycles` lines
  at 685 1011 492 2364 2199 1231 671 3038 9095 5959 883 983 3893 => CORE TREE == closure-r127y
  is remotely gated on the default binding. Then read the staged witness with
  `timeout 200 python3 verif/regress/remote/testharness_proxy.py shell --allow-overlap
  --no-hang --cmd-file build-platform/workspace/build/r127-remote/probe9.cmd` (from WSL, repo
  root): want no %Error line, alive, `ret` > 5,985,483, `Linux version` on uart.

- REMOTE GATE r127y DONE (default binding, closure-r127y = current tree incl. all three
  staged-MMU hunks, aes, shared_tlb, tlb masks): lint rc=0, **13/13 pass** at 685 1011 492
  2364 2199 1231 671 3038 9095 5959 883 983 3893. CORE TREE == closure-r127y, remotely gated
  on the default binding. Default-binding integrations: r127, b..i, k, m, o, p, s2, w, y.

- Staged witness `hyp8-osbi-scalar-r127x-mmustaged` at 09:0x local: alive, cyc=8M
  ret=2,205,976 (== default trace), 0 %Error. Host is slow (~0.25M cyc/min): the decisive
  point (sim time 22,264,368 / ret 5,985,483) is ~50 min away. Re-check with probe9.cmd.

## RESUME HERE (after r127y) — supersedes earlier RESUME blocks

Nothing is committed. CORE TREE == closure-r127y (default binding 13/13, staged target 13/13 as
r127x). Boards of record: `core-all-r127-final5` (clock rule 37.0, was 52.6),
`apu-{ai,l2}-r127-final3`, `apu-coh-r127-final2`, `apu-l3-r127-final`.
OPEN RUNS (mine): witnesses `hyp8-osbi-scalar-r127m` (default; cycle-identical to the r127d
reference through 50M), `hyp8-osbi-scalar-r127n-deep` (LoadExPubStages=2), and
`hyp8-osbi-scalar-r127x-mmustaged` (staged MMU + 3-hunk fix; DECISIVE: must pass sim time
22,264,368 without `g6lc_pa_now_eq`, retire past 5,985,483, print `Linux version`).
IF the staged witness dies again: read the %Error line (probe9.cmd), fix under
`LU_TLB_STAGED` / `STLB_DLY > 0` only, re-gate with `remote_gate.sh <tag> --env
HYP8_BUILD_TARGET=g6lc64_hyp8_mmu_staged` (sv39 smoke) then the default gate.
IF it reaches the kernel: record it; the staged MMU stays OFF by default (recommend the flip
to the user; no witness of this round reached Linux init).
NEXT CANDIDATES (not started): alu SLLIUW onto the staged shifter (rank 1, alu leaf);
gemm_fp32_norm 44.1 / align 36.7 (AI FP32 add pipeline, gemm gate `run_gemm_gate.sh`);
load_unit in->reg 43.2 (IDLE decision nest); wbuffer reg->out 39.5; B9 RenameReadStages;
IqSelStages; csr trap-write record; decode legality table; realign per-position targets;
wbuffer versioned writes; l2_mshr per-entry enables; hub 66.1.

- AI FP32 add reading (NOT edited): `g6lc_ai_gemm_fp32_align` (36.7) and `..._norm` (44.1) are
  the two combinational leaves of `g6lc_ai_gemm_fp32_add_p2` (file
  `ai_island/g6lc_ai_gemm_fp32_add.sv`): align -> `align_q` register -> norm. Each row is one
  pipeline stage of an accumulator recurrence that "adds one partial every other cycle per
  element" (r22). Lowering them needs a third stage inside the recurrence (interleave 2 -> 3),
  i.e. a contract change of the FP32 accumulate path with the gemm gate's `review_fp32_add`
  (100,000 vectors) as its check. Not a rank-0 item; not done.

- Staged witness `hyp8-osbi-scalar-r127x-mmustaged`: alive at cyc=12M ret=3,309,988 (== default
  trace), 0 %Error. Decisive point (sim time 22,264,368) still ahead; poll with probe9.cmd.

- Staged witness `hyp8-osbi-scalar-r127x-mmustaged`: alive at cyc=18M ret=5,011,707, 0 %Error.
  Decisive point: sim time 22,264,368 (pre-part-3 assertion) / ret 5,985,483 (pre-fix wedge).

- Staged witness `hyp8-osbi-scalar-r127x-mmustaged`: alive at cyc=20M ret=5,557,886, uart at
  "Boot HART MEDELEG" (end of the OpenSBI banner), 0 %Error. The kernel hand-off (decisive
  point, sim time 22,264,368) is the next 2M cycles; poll probe9.cmd.

- **STAGED MMU REACHES THE LINUX KERNEL** — witness `hyp8-osbi-scalar-r127x-mmustaged` (model
  of `hyp8-r127x-aggregate-t1`, target `g6lc64_hyp8_mmu_staged`, 3-hunk fix): alive at
  cyc=24M ret=6,332,538 — past the pre-fix wedge (ret 5,985,483 / cyc 22,258,830) and past
  the part-2 assertion point (sim time 22,264,368); 0 %Error / equiv lines; uart shows
  `Linux version 6.6.93 ...` and `Machine model: GSys LibreCore hyp8 sim`. (Default trace at
  24M: ret=6,342,152 — the staged TLB costs ~0.15 % retired instructions over the first 2M
  translated cycles.) The staged MMU is now boot-capable into the kernel on this evidence;
  it stays OFF by default (no witness of this round has reached Linux init on either
  binding). Keep polling with `build/r127-remote/probe9.cmd`.

- NEXT ITEM STARTED: alu SLLIUW onto the staged shifter (clock-rule row alu 32.9 = L949
  `{32'b0, s3_a[31:0]} << s3_b[5:0]`, a full variable shift inside A3). Plan: (1) `shift_left`
  (alu.sv L366) also true for SLLIUW so `shl_q`/`s3_shl` = 1; (2) a registered flag `sllu_q`
  (A1 register block L394-412) zeroes the LOW 32 bits of `a_sh_rev` (the bit-reversed operand,
  L566) so the staged logical shifter sees zext32(a) reversed; (3) the A3 arm at L948-949
  becomes `a3_d = shift_result`. Checks: in-module `alu A3: full-result cone != retimed
  original` assertion (ref_d is the original function) through the alu leaf
  (`run_gate.sh <tag> alu`, 19,508 checks) — FIRST confirm the leaf drives SLLIUW
  (grep SLLIUW in verif/tb/core/tb_g6lc_hyp8_control.sv alu bench); if not, add vectors.
  Revert = `git diff core/alu.sv` (the file also carries the kept r127 orc.b edit).

- alu SLLIUW item — bench finding BEFORE any RTL edit: `tb_g6lc_hyp8_alu`
  (verif/tb/core/tb_g6lc_hyp8_control.sv L3602-3838) never drives SLLIUW (0 occurrences) and has
  no general op sweep (directed SLL / invalid-pred / bitcount / lzc-cell cases; helper
  `drive(op, a, b, tid, valid)` at L3671, `check(cond, name)`, A3 result visible 3 ticks after
  the drive, see the "VS_RES72" case at L3783-3791). So the rewrite has NO existing gate.
  ORDER OF WORK: (1) add directed SLLIUW vectors to that bench (shamt 0, 1, 31, 32, 33, 63 with
  a = 64'hFFFF_FFFF_8000_0001 and a random word; expected = {32'b0, a[31:0]} << shamt), run
  `run_gate.sh <tag> alu` on the CURRENT RTL: must pass (bench-only change, proves the
  vectors); (2) only then the RTL change (plan in the previous entry), same leaf + the
  in-module A3 assertion; (3) board `--modules alu` (was rr 32.9; next arms PACK_W L974 25.5,
  CZERO L955/957 24.5 will then lead), lint, default remote gate.
  NOTHING of this item is applied yet; core tree is still closure-r127y.

- alu item step (1) APPLIED (bench only): 12 directed SLLIUW vectors (`slliuw_cases`, 24 checks)
  added to `tb_g6lc_hyp8_alu` before the PASS line. LAUNCHED on the CURRENT RTL:
  `run_gate.sh r127aa alu` -> `gate-r127aa.log`; expect `HYP8_ALU_PASS checked=19532`
  (19508 + 24). If it FAILS on current RTL the vectors' timing is wrong (fix the bench, not
  the RTL). RTL step (2) not started.

- alu item step (1) DONE: `gate-r127aa.log` on the CURRENT RTL with the new bench vectors: lint
  clean, `HYP8_ALU_PASS checked=19532` (= 19508 + 24 SLLIUW checks). The vectors are valid;
  the leaf now covers SLLIUW. Bench change kept (`verif/tb/core/tb_g6lc_hyp8_control.sv`,
  block `slliuw_cases`). RTL step (2) is next and NOT applied: in `core/alu.sv`
  (a) L366 `shift_left` |= `(G6LCCfg.IS_XLEN64 && fu_data_i.operation == SLLIUW)`;
  (b) the staged left shift must see zext32(a): mask the reversed operand — in
  `a_sh = shl_q ? a_sh_rev : a_q` (L566) use `a_sh_rev` with bits [31:0] zeroed when
  `op_q == SLLIUW` (a_sh_rev[k] = a_q[63-k], so the HIGH half of a lands in a_sh_rev[31:0]);
  (c) A3 arm L948-949 `a3_d = shift_result` for SLLIUW. Gate = `run_gate.sh <tag> alu`
  (19532) + the in-module "alu A3: full-result cone != retimed original" assertion; then
  board `--modules alu` (rr 32.9 before), default remote gate.

- alu item step (2) APPLIED (not yet gated when written): `core/alu.sv` staged arm —
  `shift_left` includes SLLIUW; `sllu_q` zeroes `a_sh_rev[31:0]` (= rs1[63:32] reversed) so the
  staged logical shifter sees zext32(rs1); the A3 arm takes `shift_result`. LAUNCHED
  `run_gate.sh r127ab alu` -> `gate-r127ab.log`: need lint clean + `HYP8_ALU_PASS
  checked=19532` (the 24 SLLIUW checks + the in-module A3-vs-original assertion). Then board
  tag `alu-sllu` (`--modules alu`, rr 32.9 before). If the leaf fails: `git diff core/alu.sv`,
  remove the three r127 SLLIUW hunks (the orc.b edit in that file is separate and kept).

- alu item step (2) LOCALLY GATED: `gate-r127ab.log` — full lint clean (7 known),
  `LEAF alu-r127ab rc=0`, `HYP8_ALU_PASS checked=19532` with SLLIUW on the staged shifter
  (12 directed vectors x 2 checks pass; shamt 0/1/31/32/33/63). Board `alu-sllu` next, then the
  default remote gate (closure-r127z). CORE TREE = closure-r127y + alu.sv SLLIUW hunks +
  bench vectors.

- alu SLLIUW on the staged shifter: board `alu-sllu` rr 32.9 -> **48.9** (L570: the zext mask
  mux sits in front of the first shift stage, and A1->A2 becomes the limiter). COUNTERCASE,
  RTL REVERTED; `core/alu.sv` is byte-identical (modulo line endings) to closure-r127y. The
  bench vectors (`slliuw_cases`, HYP8_ALU_PASS checked=19532 on the original RTL) are KEPT as
  new coverage. Do not retry by masking at `a_sh`; a registered pre-masked operand (A1 flop
  writing zext32 for SLLIUW) is the only form left, and it widens the A1 input mux.
  CORE TREE == closure-r127y RTL (+ bench-only change in verif/tb/core).

## RESUME HERE (latest) — supersedes earlier RESUME blocks

Nothing is committed. CORE RTL == closure-r127y (default 13/13 r127y; staged-MMU target 13/13
r127x). Bench-only delta since: 12 SLLIUW vectors in `tb_g6lc_hyp8_alu` (alu leaf 19532).
Boards of record: `core-all-r127-final5` (clock rule 37.0; 52.6 at the start),
`apu-{ai,l2}-r127-final3`, `apu-coh-r127-final2`, `apu-l3-r127-final`.
Witnesses (mine, detached): `hyp8-osbi-scalar-r127m` (default; cycle-identical to the r127d
reference through 50M), `hyp8-osbi-scalar-r127n-deep` (LoadExPubStages=2, in the kernel),
`hyp8-osbi-scalar-r127x-mmustaged` (staged MMU + 3-hunk fix: PAST the old wedge, `Linux
version` on uart at cyc 24M). Poll: `remote_witness_status.sh <tags>` or
`build/r127-remote/probe9.cmd` through the proxy `shell --cmd-file`.
Knobs, all OFF by default: IqSteerStages=2 (`G6LC_HYP8_IQSTEER2`), staged MMU
(`G6LC_HYP8_MMU_STAGED`, now boots into the kernel), deep (`G6LC_HYP8_DEEP`).
Gates that work: `run_gate.sh <tag> <leaves>` (lint + leaves incl. mmu again),
`remote_gate.sh <tag> [--env HYP8_BUILD_TARGET=...]` (13 smokes), `remote_leaf.sh`,
`run_gemm_gate.sh`, `run_island_gate.sh`, `run_cluster_dispatch_gate.sh`, `run_l2_bench.sh`,
`run_hub_bench.sh`, `run_invbus_bench.sh`, `sf_ab.sh`, miters under verif/.
NOT DONE (each needs a contract change; none started): IqSelStages, RenameReadStages (B9),
FreelistPickStages, wbuffer versioned writes, realign per-position targets, csr trap-write
record, decode legality table, AES MixColumns stage, FP32 add third stage (AI), l2_mshr
per-entry enables, hub residual chain. Rank-0 attempts that measured null/worse are listed
in this ledger (do not repeat them).

- WITNESS STATUS (all three alive, 0 fatal / 0 equiv errors, `Linux version` on every uart):
  `hyp8-osbi-scalar-r127m` (default) cyc=106M ret=28,888,155;
  `hyp8-osbi-scalar-r127n-deep` (LoadExPubStages=2) cyc=92M ret=24,640,707;
  `hyp8-osbi-scalar-r127x-mmustaged` (staged MMU + fix, pid 1070375) cyc=24M ret=6,332,538,
  uart 3243 bytes (kernel banner + early boot lines). No witness has reached INIT_UP.

- wbuffer reg->out 39.5 reading (final5 board, NOT edited): ufifo index (4.1) -> `fwd_ent[i]`
  (5.1) -> `exp_free[i]` (2.0) -> `exp_pick = (|exp_hit) ? fwd_lowest(exp_hit) :
  fwd_lowest(exp_free)` (L1316, 13.2) -> per-byte overlay `fixup_wbuffer_o[i].user/data`
  (L1330, 12.0). Candidate (exact, untried): form `pick_hit = fwd_lowest(exp_hit)` and
  `pick_free = fwd_lowest(exp_free)` as separate wires and give each overlay byte lane its own
  copy of the `|exp_hit` select (same lane pattern that worked in prf / dispatch / missunit);
  gate = dcache leaf (`run_gate.sh <tag> dcache`, 334 checks, stores=88) + default remote gate.

- Core `wt_dcache_wbuffer` EDITED (not yet boarded/gated when written): `exp_pick` as two
  side-by-side isolates (`exp_pick_hit`, `exp_pick_free`) + per-slot select with a slot-local
  copy of `|exp_hit` (`gen_exp_pick`). Board tag `wbuf-pick` (`--modules wt_dcache_wbuffer`,
  was any 39.5 / rr 31.4). Keep only on a drop; gate `run_gate.sh <tag> dcache` + default
  remote gate. Revert = restore the one-line `assign exp_pick = ...` (git diff of the file;
  it also carries the kept head-match and merge-select edits).

- `wbuf-pick` board: wt_dcache_wbuffer any **39.5 -> 37.7** (reg->out L1340; rr 31.4 unchanged).
  Local gate LAUNCHED: `run_gate.sh r127ac dcache` -> `gate-r127ac.log` (need lint clean +
  `HYP8_DCACHE_PASS checked=334`). Then closure-r127z + plain `remote_gate.sh r127z` (default,
  13/13 at 685 1011 492 2364 2199 1231 671 3038 9095 5959 883 983 3893). CORE TREE =
  closure-r127y + this wbuffer hunk (+ the bench-only SLLIUW vectors).

- `gate-r127ac.log` (wbuffer `exp_pick` split in): full lint clean (7 known),
  `HYP8_DCACHE_PASS checked=334 dchx=2 stores=88`, no `not one-hot` / `equiv fixup` line.
- REMOTE GATE r127z LAUNCHED (default binding; closure-r127z = closure-r127y + wbuffer
  `exp_pick` split + the SLLIUW bench vectors): `build/r127-remote/r127z.summary.txt`, expect
  13/13 at 685 1011 492 2364 2199 1231 671 3038 9095 5959 883 983 3893 (marker
  REMOTE_GATE_DONE). If it passes: wbuffer any 39.5 -> 37.7 is remotely gated and
  CORE TREE == closure-r127z. If a `fixup` assertion fires in
  `~/cva6-remote-runs/hyp8-r127z-smokes-t1/*.log`: restore the one-line `assign exp_pick`.

- WAITING (10:13 local): r127z default gate (closure-r127z = closure-r127y + wbuffer `exp_pick`
  split + SLLIUW bench vectors) at ~1600 s, not finished. When
  `build/r127-remote/r127z.summary.txt` has REMOTE_GATE_DONE: 13 `pass cycles` at 685 1011 492
  2364 2199 1231 671 3038 9095 5959 883 983 3893 => wbuffer 39.5 -> 37.7 kept and
  CORE TREE == closure-r127z; otherwise restore the one-line `assign exp_pick`.
  After that: regenerate `core-all-r127-final6`, update fo4-census.md §6 (wbuffer any 37.7),
  poll the three witnesses, then continue with the NOT DONE list in the latest RESUME block.

- REMOTE GATE r127z DONE (default binding, closure-r127z): lint rc=0, **13/13 pass** at 685 1011
  492 2364 2199 1231 671 3038 9095 5959 883 983 3893. wbuffer `exp_pick` split KEPT (any 39.5
  -> 37.7). **CORE TREE == closure-r127z** (default-binding integrations: r127, b..i, k, m, o,
  p, s2, w, y, z). NEXT: `reboard_current.py core-all-r127-final6`; fo4-census.md §6 wbuffer
  row -> 37.7; poll witnesses (`remote_witness_status.sh hyp8-osbi-scalar-r127x-mmustaged
  hyp8-osbi-scalar-r127m hyp8-osbi-scalar-r127n-deep`); then the NOT DONE list in the latest
  RESUME block (contract items; rank-0 nulls listed in this ledger must not be repeated).

- WHOLE-CORE BOARD `core-all-r127-final6` (tree == closure-r127z): board worst (clock rule) 37.0 (load_unit.reg1/D).
  live any-kind: g6lc_decode_s3 44.5, instr_queue 43.2, load_unit 43.2, g6lc_rename_read 40.2, g6lc_ptw_leg_decode 38.2, wt_dcache_wbuffer 37.7, g6lc_iq 37.1, g6lc_ptw 36.0, aes 35.5, csr_regfile 35.3.
  live clock rule: load_unit 37.0, g6lc_ptw 36.0, csr_regfile 35.3, instr_realign 34.5, alu 32.9, g6lc_fe_override 32.5, g6lc_bp_ckpt 32.3, g6lc_iq_arb 32.2.


## RESUME HERE (after r127z + final6) — supersedes earlier RESUME blocks

Nothing is committed. CORE TREE == closure-r127z (default 13/13 r127z; staged-MMU target 13/13
r127x on the same RTL minus the wbuffer exp_pick split). Board of record
`core-all-r127-final6`: clock rule 37.0 (load_unit), any-kind top decode_s3 44.5,
instr_queue 43.2, load_unit 43.2, rename_read 40.2, ptw_leg_decode 38.2, wbuffer 37.7.
APU boards: `apu-{ai,l2}-r127-final3`, `apu-coh-r127-final2`, `apu-l3-r127-final`.
Witnesses (mine, detached): r127m (default), r127n-deep, r127x-mmustaged (staged MMU, in the
kernel). Poll: `remote_witness_status.sh hyp8-osbi-scalar-r127x-mmustaged
hyp8-osbi-scalar-r127m hyp8-osbi-scalar-r127n-deep`.
NOT DONE (contract items, none started): IqSelStages, RenameReadStages (B9),
FreelistPickStages, wbuffer versioned writes, realign per-position targets, csr trap-write
record, decode legality table, AES MixColumns stage, AI FP32 add third stage, l2_mshr
per-entry enables, hub residual chain, load_unit IDLE decision nest (in->reg 43.2).
Measured null/worse (do NOT repeat): rename ckpt (4 forms), alu SLLIUW via a_sh mask (48.9),
pe_dot_float_pipe tournament (80.2), island_top submit lanes, hub aw_fire copy, l2_mshr free
pick isolate, IQ steer slot order, instr_queue thermometer (no exact form).

- WITNESS STATUS (after r127z): all three alive, 0 fatal / 0 equiv errors, `Linux version` on
  each uart, no INIT_UP yet.
  * `hyp8-osbi-scalar-r127m` (default): cyc=116M ret=31,917,336.
  * `hyp8-osbi-scalar-r127n-deep` (LoadExPubStages=2): cyc=104M ret=28,281,271 ack_cyc=19,814,735
    ack_full=8,466,536 — the default reference at 104M is ret=28,281,265 / ack_full=8,466,530:
    6 retirements apart at the same cycle. First visible effect of the exception-publish
    stage (a +1 cycle on load-exception completions shifts which instructions have retired at
    a sample point); not an error by itself, but it means the deep trace is no longer
    cycle-identical and must be judged on its own milestones.
  * `hyp8-osbi-scalar-r127x-mmustaged` (staged MMU + fix): cyc=34M ret=8,261,713 (default at 34M:
    8,384,323, i.e. ~1.5 % fewer retirements under the two-cycle TLB), uart 3984 bytes,
    kernel early boot.

- load_unit in->reg 43.2 reading (final6, NOT edited): fwd_byte_ok (2.0) -> st_fwd_covers (4.4)
  -> st_pipeline_busy (6.0) -> `state_d = LU_S_WAIT_GNT` (L1084, 29.8 = the IDLE arm's nested
  decision billed on one 10-bit one-hot write). Candidate (exact, untried): decide the IDLE
  arm's target with a flat one-hot of precomputed predicates (busy / fwd-done / issue-no-gnt /
  issue-miss / issue-hit / ni / wait) and write `state_d` once from it, keeping the nested
  form as the `rf_state_d` reference that already exists (assert at "one-hot FSM next-state
  mismatch"). Gate: lsq + dcache leaves, default remote gate (13), then witness comparison.
  This is the next item to try; nothing applied. CORE TREE == closure-r127z.

- load_unit IDLE arm READ (load_unit.sv L1060-1106, nothing edited). Decision order under
  `accept_req`: (0) spec gate `!SpeculativeSb || !spec_ld || (dtlb_hit_i && !paddr_ni)` else
  WAIT_SPEC_LOAD; (1) `st_pipeline_busy` -> WAIT_PAGE_OFFSET; (2) `page_offset_matches_i &&
  st_fwd_covers && !data_rvalid && ld_checked_head` -> IDLE + pop_ld_o + st_fwd_done;
  (3) `!page_offset_matches_i && !(st_fwd_covers && !ld_checked_head)`: !gnt -> WAIT_GNT;
  gnt && MmuPresent && !dtlb_hit -> ABORT_TRANSACTION; gnt && hit && !stall_ni -> SEND_TAG +
  pop_ld_o; gnt && hit && stall_ni && NonIdemPotenceEn -> ABORT_TRANSACTION_NI;
  (4) else WAIT_PAGE_OFFSET. The same nest is repeated in the SEND_TAG arm (L1190+) and in
  the reference FSM (`rf_state_d`, L2190+/L2334+), which already asserts
  `state_d == (10'(1) << rf_state_d)` every cycle — so a flat one-hot form of the IDLE arm is
  self-checked by the existing assertion. NEXT ACTION: write the IDLE-arm targets as mutually
  exclusive predicates (p_spec, p_busy, p_fwd, p_wgnt, p_abort, p_tag, p_ni, p_wpo), OR the
  literal one-hot targets, board `--modules load_unit` (ir 43.2 / rr 37.0 before), gate with
  `run_gate.sh <tag> dispatch lsq dcache`, then default remote gate + staged target gate.

- Core `load_unit.sv` EDITED (NOT yet linted/gated/boarded when written): the IDLE case item is
  now a flat one-hot OR of module-level predicates `idle_p_{spec,wpo,fwd,wgnt,abort,tag,ni,keep}`
  (declared after `assign accept_req_w`), with `pop_ld_o` on fwd|tag and `st_fwd_done` on fwd.
  Self-check = the existing reference FSM assertions (`one-hot FSM next-state mismatch`,
  rf_pop_ld_o / rf_st_fwd_done compares). ASSUMPTION to verify by the leaves: the default
  before the case is `state_d = state_q` (so "keep" == LU_S_IDLE in this arm).
  NEXT: `run_gate.sh r127ad dispatch lsq dcache` (need lint clean + the three PASS lines; a
  `$fatal ... one-hot FSM` line = revert this hunk), board tag `lu-idle`
  (`--modules load_unit`, ir 43.2 / rr 37.0 before), then closure + default remote gate (13)
  and the staged-MMU target gate. Revert = `git diff core/load_unit.sv` (remove the
  `idle_*` wires block and restore the nested IDLE arm; other r127 hunks in the file are kept).
  CORE TREE = closure-r127z + this hunk.

- `gate-r127ad.log` (flat IDLE arm in load_unit): full lint clean (7 known),
  `HYP8_DISPATCH_PASS 125`, `HYP8_LSQ_PASS 2826`, `HYP8_DCACHE_PASS 334`. Defaults confirmed
  by reading (load_unit.sv L1065-1074: `state_d = state_q`, `pop_ld_o = 0`, `st_fwd_done = 0`)
  and the reference compares exist for all three (`one-hot FSM next-state mismatch`,
  `rf_pop_ld_o == pop_ld_o`, `rf_st_fwd_done == st_fwd_done`). NOTE: none of these local
  leaves instantiates load_unit — the real check is the remote smokes (assertions are active
  in the remote model: the staged witness died on one). Board `lu-idle` next.

- Board `lu-idle` (flat IDLE arm only): load_unit ir 43.2 -> 45.2, rr 37.0 -> 37.5 — the limiter
  just moved to the SEND_TAG arm, which repeats the same nest (L1207/L1225) and now carries the
  extra predicate fan-out. EXTENDED (not yet gated/boarded when written): shared wires
  `idle_next_w` / `idle_pop_w` (one flat next-state value) used by BOTH the IDLE and SEND_TAG
  case items (SEND_TAG's own default target was LU_S_IDLE, same as IDLE's keep). Board tag
  `lu-idle2`. DECISION RULE: keep only if load_unit ir < 43.2 AND rr <= 37.0; otherwise revert
  both arms (restore the nested IDLE and SEND_TAG arms from `git diff`/closure-r127z copy of
  load_unit.sv: `build/closure-r127z/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core/load_unit.sv`).

- Board `lu-idle2` (shared module-level wires, both arms): load_unit ir 43.2 -> 41.6, io -> 30.1,
  FSM step `state_q -> state_d` 34.8 -> **13.8**, BUT rr 37.0 -> 40.5 and ro 40.6 -> 42.0:
  the analyzer bills `st_pipeline_busy` 6.0 -> 10.35 although its node fan-out fell 24 -> 8
  (each new continuous-assign consumer is billed as a separate load; the old reads were inside
  one process). FORM C APPLIED (not yet boarded/gated when written): the same predicates as
  `automatic` locals INSIDE `load_control` (computed once after `accept_req`, before the
  case), no module-level wires — so no new process reads the shared terms. Board tag
  `lu-idle3`. DECISION RULE unchanged: keep only if ir < 43.2 AND rr <= 37.0 AND ro <= 40.6;
  else restore load_unit.sv's IDLE/SEND_TAG arms from the closure-r127z copy.

- Board `lu-idle3` (form C, locals inside load_control) == `lu-idle2`: rr 40.5 / ir 41.6 /
  ro 42.0 (ro was already 42.0 on final6; my earlier "40.6" was a pre-part-3 number) / io 30.1.
  The rr regression is `st_pipeline_busy` billed 6.0 -> 10.35 once it feeds AND terms instead
  of if-conditions; the ir path is busy(10.3) -> idle_base -> idle_p_tag(6.8) ->
  idle_p_keep(8.1, the complement in series) -> idle_next(7.0, 7-way AND-OR).
  FORM D APPLIED (not yet boarded/gated when written): (1) `st_busy_fsm` = FSM-private copy of
  the busy expression (assertion `g6lc_r127_lu_busy_copy`), (2) `idle_p_keep` formed in
  parallel (= !accept || fwd || granted-hit-held-by-stall without the NI arm), (3) `idle_next`
  as a positional concatenation, one predicate per state bit (positions checked by
  `g6lc_r127_lu_state_bits`). Board tag `lu-idle4`. DECISION RULE: keep only if rr <= 37.0 and
  ir < 43.2; else restore load_unit.sv from
  `build/closure-r127z/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core/load_unit.sv`.

- Board `lu-idle4` (form D): load_unit rr 40.1 / **ir 34.2** (was 43.2) / ro 42.0 / io 29.4.
  rr still above 37.0: `st_pipeline_busy` billed 9.65 with only 6 consumers (data_req + the
  WAIT_PAGE_OFFSET arm's writes), while the identical-expression copy `st_busy_fsm` is billed
  3.0 with 2 logic consumers — the analyzer bills the remaining if-condition uses of the
  original net heavily once the big nest is gone. STEP E APPLIED (not yet boarded/gated):
  every FSM read inside `load_control` uses `st_busy_fsm` (2 more sites, WAIT_PAGE_OFFSET
  arm), so `st_pipeline_busy` feeds only the D$ request decode. Board tag `lu-idle5`. Same
  decision rule (rr <= 37.0 and ir < 43.2).

- Board `lu-idle5` (form D + step E): load_unit **rr 37.0 (unchanged) / ir 43.2 -> 34.2 /
  ro 42.0 (unchanged) / io 43.2 -> 29.4**; module any-kind 43.2 -> 42.0 (now the reg->out
  `load_pa_now_v` select fan-out, L756). Decision rule met. FINAL SHAPE of the edit in
  `core/load_unit.sv`: `st_busy_fsm` copy + 2 translate_off checks after `st_pipeline_busy`;
  locals `idle_*` in `load_control` (decision formed once after `accept_req`); IDLE and
  SEND_TAG arms assign `idle_next` (+ pop / fwd_done); WAIT_PAGE_OFFSET arm reads
  `st_busy_fsm`. Self-checks: reference FSM compares (state_d / pop_ld_o / st_fwd_done /
  translation_req_o, `$fatal`), `g6lc_r127_lu_busy_copy`, `g6lc_r127_lu_state_bits`.
  LAUNCHED `run_gate.sh r127ae dispatch lsq dcache` -> `gate-r127ae.log` (lint is the local
  value; no local leaf instantiates load_unit). THEN closure-r127ae + `remote_gate.sh r127ae`
  (default, 13 smokes with the reference FSM live) and `remote_gate.sh r127af --env
  HYP8_BUILD_TARGET=g6lc64_hyp8_mmu_staged`. Revert = copy load_unit.sv back from
  `build/closure-r127z/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core/load_unit.sv`.

- `gate-r127ae.log` (load_unit flat new-request decision, final shape): full lint clean (7
  known, no new warning), `HYP8_DISPATCH_PASS 125`, `HYP8_LSQ_PASS 2826`,
  `HYP8_DCACHE_PASS 334`.
- REMOTE GATE r127ae LAUNCHED (default binding; closure-r127ae = closure-r127z + the load_unit
  decision rewrite): `build/r127-remote/r127ae.summary.txt`; need REMOTE_GATE_DONE + 13 pass
  at 685 1011 492 2364 2199 1231 671 3038 9095 5959 883 983 3893 (an exact rewrite must not
  move a cycle; any `one-hot FSM` / `pop_ld_o` / `st_fwd_done` $fatal in
  `~/cva6-remote-runs/hyp8-r127ae-smokes-t1/*.log` = revert from the closure-r127z copy).
  After it: closure-r127af + `remote_gate.sh r127af --env
  HYP8_BUILD_TARGET=g6lc64_hyp8_mmu_staged` (13/13, sv39 4219 cycles expected).

- NEW SMOKE `verif/tests/custom/hyp8_zkn_kat.S` (14th test; added to `TESTS` in
  `run_hyp8_integration.py`, picked up by the closure glob): Zkn known-answer test — aes64es /
  esm / ds / dsm / ks2 / im / ks1i (rnum 0..10), sha256 sig0/sig1/sum0/sum1, sha512
  sig0/sig1/sum0/sum1 over 8 operand pairs + two dependent pairs, all results folded into a
  checksum compared with Spike's (`expected` = 0x47cd2d7d1c5040a6). Instructions are emitted
  with `.insn` (the integration's -march has no Zk*). Codes: 1 pass, 3 checksum mismatch,
  ((16+mcause)<<1)|1 trap. Regeneration: `verif/regress/remote/hyp8/regen_zkn_kat.sh
  [--patch]` (tracked; spike `--isa=rv64gc_zknd_zkne_zknh`) — verified: spike writes
  tohost=1 with the patched checksum. WHY: ZKN is enabled in the hyp8 config (the AES unit is
  live) but no smoke issued to it, so the r127 `aes.sv` rewrite (the RV64-live part is the
  aes64ks1i subword input lanes) had only miter + lint evidence. FIRST RTL RUN = the next
  remote integration (r127af, staged target) — a `fail` there is information about the AES
  unit / decode, not a harness break. The in-flight r127ae run predates the test (13 tests).

- HUB 66.1 ANATOMY (board `apu-coh-r127-final2`, nothing edited): three independent families
  sit at 62-66, so the row only moves if all three are cut.
  (A) in->out 66.1 = dependency floor of the grant/response process on `aw_ot_d`: chain
      L860 `bs = OT_W'(b.id)` 16.9 > L862 `bc = aw_ot_q[bs].core` 18.8 > L878
      `aw_ot_d[bs].b_done = 1` 16.2 > L971 (R-demux ATOP arm reads `aw_ot_d[rs].b_done`) 14.2.
      The read-after-write of `b_done` (same-cycle B then R on one ATOP slot) is the only
      OT-table read-after-write in the process (held-R L~925 and R-demux L~971).
  (B) reg->out 64.0 / 63.0 = `rs = OT_W'(r.id)` 23.5 > `rc = aw_ot_q[rs].core` 19.8 >
      `core_resp_o[rc].r.id = aw_ot_q[rs].orig_id` 14.2 (variable-index read, read, write).
  (C) reg->reg 62.6 / 62.1 = slot_used > aw_ot_full > aw_grant 7.7 > aw_fire 12.2 >
      inv_new_target 6.7 > ... > coh_inv_fire_o > do_stamp > `inv_ot_d[ss].*`.
  DESIGN for the next hub step (rank 0, exact, not started): slot-centric B/R demux —
  `bs_oh[s] = (b.id == s)`, `rs_oh[s] = (r.id == s)`; table fields read by one-hot AND-OR
  (constant indices); `bc_oh` / `rc_oh` per core; table writes as `for s: if (hit[s]) ...`;
  per-slot `b_done_now[s] = aw_ot_q[s].b_done | (b_complete_now[s] & aw_ot_q[s].expect_r)`
  replacing the `aw_ot_d[..].b_done` read-back; the present process kept verbatim under
  translate_off as the every-cycle reference (all of mem_req_o / core_resp_o / *_ot_d /
  w_* / *_rr_d / starve). Gate: `run_hub_bench.sh` lines vs `build/hub-a.txt` with --assert.
  (C) needs the invalidation stamp decoupled from `aw_fire` (stamp on the grant, cancel on a
  missing ready) — a contract item inside the hub, separate from the demux.

- Core `load_unit.sv` EDITED again (not yet boarded/gated when written; NOT in closure-r127ae,
  which is in flight with only the new-request decision rewrite): `pend_state_ok`'s two
  state-only parts as registers written from `state_d` (`pend_st_set_q`, `pend_st_nwpo_q`),
  assertion `g6lc_r127_lu_pend_state_eq`. Target = the module's clock-rule path (37.0:
  state_q -> pend_state_ok -> ex_pend_sel -> a_data -> ldbuf_pop_oh -> ldbuf_valid_d; ~11.6 of
  it is the start cost of the widely read state vector). Board tag `lu-pend`. Keep only if
  rr < 37.0 with ir/ro/io not above 42.0. Revert = restore the 5-line `assign pend_state_ok`.

- Board `lu-pend` (registered `pend_state_ok` parts): load_unit rr 37.0 -> 36.1, ro 42.0 -> 39.9
  (the state vector's start cost fell for the PA-capture path too), ir 34.2, io 29.4; module
  any-kind 42.0 -> 39.9. KEPT pending gates.
- Core `load_unit.sv` EDITED again (not yet boarded/gated when written): `ldbuf_pop_oh[gi]`
  takes the publish / drain pick bits directly (`a_data && pub_oh[gi]`, `a_drn && drn_oh[gi]`)
  instead of one-hot -> index tree -> per-slot compare; exact because a_data => pub_any and
  a_drn => drn_any (lowest-set one-hot). Self-check = existing `g6lc_r127_lu_pop_eq` (pop mask
  vs the indexed reference, every cycle). Board tag `lu-pop` (rr 36.1 before via
  pub_ok > pub_oh > pub_itree > pub_idx_w > ldbuf_pop_oh > ldbuf_valid_d).

- Board `lu-pop2` (pop mask from the one-hot picks; tag `lu-pop` was taken by an earlier
  round): load_unit rr 36.1 -> **34.8**, ir 34.2, ro 39.9, io 29.4. KEPT pending gates.
- Core `load_unit.sv` EDITED again (not yet boarded/gated when written): the 56-bit key
  register `load_pa_q` gets one copy of the exact capture qualifier per 14-bit lane
  (`load_pa_en[gl]`, generate `gen_pa_lane`, assertion `g6lc_r127_lu_pa_en_copy`);
  `load_pa_now_v` keeps the valid bit and the output selects. Target = ro 39.9
  (`load_pa_now_v` billed 23.95, i.e. the 56 flop enables). The r48/r126 comment block is
  preserved (moved above the generate). Board tag `lu-paen`. Keep only if ro drops and rr
  does not rise above 34.8.

- Board `lu-paen` (lane enables for `load_pa_q`): load_unit ro 39.9 -> **35.5**, rr 34.8,
  ir 34.2, io 29.4 => module any-kind 43.2 (final6) -> 35.5, clock rule 37.0 -> 34.8.
  KEPT pending gates. load_unit.sv now carries FOUR r127 hunks beyond closure-r127z:
  (1) new-request decision (in closure-r127ae, remote gate in flight), (2) registered
  `pend_state_ok` parts, (3) pop mask from the one-hot picks, (4) `load_pa_q` lane enables —
  (2)-(4) are NOT in closure-r127ae. NEXT: `run_gate.sh r127ag dispatch lsq dcache`, then
  closure-r127af (staged target, 14 tests incl. zkn) and closure-r127ag (default, 14 tests).
  Revert of (2)-(4) = copy load_unit.sv from
  `build/closure-r127ae/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core/load_unit.sv`;
  revert of all four = the closure-r127z copy.

## r127-t — APU continuation (gemm_seq / pe_dot / l2_mshr / dead-row census)

- `g6lc_ai_gemm_seq.sv` EDITED x2, boarded `apu-gseq-t1`/`t2` (params-ai.json):
  (a) `mac_quiet` shared predicate — the ST_MAC->ST_DONE terminal test and the
  `store_reset` ST_MAC arm repeated the same six-term quiet condition; now one
  `assign mac_quiet` feeds both. rr **51.0 -> 49.6**. KEPT.
  (b) `w_fetch_needed` — `store_pair ? w_fetch_q < store_beats[8:0] : w_fetch_q == 0`
  collapsed to one 9-bit compare against a muxed threshold (`==0` == `<1`
  unsigned; w_fetch_q and store_beats[8:0] are both 9-bit). Row-neutral (49.6),
  exact; KEPT as local-depth reduction, documented neutral-on-row.
  New limiter L2534 = the rd_sel chain (w_fetch_needed -> rd_sel_store ->
  rd_sel_pair -> c_r1_req -> c_rx_req -> c_rx_bank demux write): protocol-serial
  (fetch-needed qualifies the select which qualifies the bank write enables);
  no exact transform found — floor for latency-neutral edits.
- `g6lc_ai_pe_dot_float_pipe.sv` EDITED, boarded `apu-pedot-t1`: the S1->S2
  flag accumulation (any_nan/any_inf/any_finite/has_pos_inf/has_neg_inf) was a
  serial loop over the unpacked lane arrays with set-only flags; recast as a
  parallel gather to packed vectors + reduction ops (`|(inf_v & ~sgn_v)` etc.).
  Row-neutral (rr 37.2 / ir 38.8 / io 38.8 — the L571 exp_min tournament +
  independent_lhs_bundle remains the limiter). Exact; KEPT, neutral-on-row.
- `g6lc_l2_mshr.sv` — TWO countercases, both REVERTED to HEAD:
  (a) earlier free-entry pick rewrite 39.8 -> 44.1 (prior session).
  (b) r127-t priority-tree rewrite: serial alloc/CAM scans recast as parallel
      match vectors + packed shift-doubling suffix/prefix ORs + one-hot idx
      encode (first attempt with function-local unpacked `lv` arrays billed
      **760.4**; packed-vector variant billed **64.8**). The analyzer bills
      function calls / non-constant loop bounds pessimistically on this module;
      serial scan stays. METHOD LESSON (APU boards): packed shift-doubling and
      one-hot-tree priority encodes bill WORSE than the serial scan here —
      opposite of the core-board selection rewrites that moved (r68b, P1).
      APU wins so far came from predicate sharing / process splits
      (mac_quiet, wr_b_done_d, inval_bus), not priority-encode rewrites.
- DEAD-ROW census correction (ai board, params-ai.json): `g6lc_ai_gemm_arplan`
  (59.0), `g6lc_ai_gemm_fp32_add`, `g6lc_ai_gemm_fp32_norm` (44.1 io),
  `g6lc_ai_gemm_fp32_align` (36.7 io) are instantiated NOWHERE in
  ai_island/ — unit-board rows only, not SoC timing. `ai_fp_dot` 271.5 stays
  behavioral (real-arithmetic `/`,`*` cones; architectural/modeling limit).
  `ai_cluster_set` 71.5 remains P10-handshake-locked.
- `g6lc_coherence_hub` 66.1 io (exclusive_case_mux L939): worst cone = R
  demux `mem_resp_i.r.id -> rs -> {ar_ot_q[rs],aw_ot_q[rs]} -> rc ->
  core_resp_o[rc]` double variable-index (table read then table write).
  Slot-centric one-hot rewrite per earlier design NOT attempted — correctness-
  critical coherence path, needs dedicated session + run_hub_bench.sh.
- Remote gate r127ag (default profile, load_unit 4-hunk tree): first launch
  from Git Bash failed — no rsync/python3 on PATH (proxy needs WSL, /mnt/e
  paths). Relaunched under WSL; aggregate in progress at write time.
  Local leaf gate r127ag PASSED earlier: lint clean, HYP8_IQLEG 23,
  CWIN_EQ 525312, dispatch 125, LSQ 2826, DCACHE 334.
- `g6lc_l2_top.sv` EDITED + KEPT: the fifo head entry was re-read ~15x per
  evaluation (`fifo_q[fifo_rd_q]` into fill_state/fill_pf/fill_addr/fill_len
  plus the `fill_act_d` clear and four serve blocks). Shared `head_idx` /
  `head_state` / `head_pf_bit` / `head_addr` / `head_len` continuous assigns
  (pure CSE, same-cycle regs). Board `apu-l2top-t1` (same argv as
  `apu-l2top`): rr **52.7 -> 50.1** (ir 25.6 -> 41.8 noted; ro 49.5 -> 49.1,
  io 38.6). L2 bench `r127t-headcse`: all 5 configs PASS (sim-default,
  sim-posted, sim-wupdate, sim-posted-wu, units). New limiter L1736 = the
  S_TAG serve-pend block; the remaining depth is the double-indexed
  `fill_*_q[head_idx]` reads themselves + `rdtrk_probe_match`/`r_fsm_start_ok`
  qualifiers — the fifo-snapshot variant was assessed and deferred (fill
  state is dynamic; addr/len/pf snapshot is exact but only saves the data
  side, audit cost vs ~2-4 FO4).
- PDEC note: `g6lc_ptw` dec_d capture cone (~36.0) is DEAD under the default
  hyp8 profile — `PtwDecodeStage=0` in HypDefault selects `gen_legacy_dec`;
  the live PTW path is `g6lc_ptw_leg_decode` (38.2). PDEC items belong to the
  staged/deep profile only.
- `csr_regfile` `fp_live` (~35.3 head-of-path): registered-predicate form is
  a CONTRACT change (mstatus.fs/vsstatus.fs writes must be seen next cycle by
  12 consumer sites); not exact — deferred to the contract-change batch.
- `g6lc_l2_top` head-CSE FULL-BOARD verdict (boards of record): l2 params
  rr 49.5 -> 50.1 (+0.6), l3 params rr 55.5 -> 54.5 (-1.0); isolated module
  52.7 -> 50.1. Worst-config improves 55.5 -> 54.5; KEPT on that basis with
  the l2-params regression recorded (path moved L1722 -> L1736; sibling
  serve-pend cone now marginally deeper). Revert = remove the five head_*
  assigns and restore the ~15 `fifo_q[fifo_rd_q]` sites (git diff).
- `g6lc_ai_gemm_fp32_norm`/`fp32_align` CORRECTION: they ARE live —
  `g6lc_ai_gemm_fp32_add_p2` (gemm_seq:1730) instantiates both. fp32_norm
  44.1 io is a real row; likely cone = `subnormal_fraction = magnitude <<
  (ec-8'd1)` barrel shift (L181) — candidate exact clamp (shift amount is
  provably <=22 whenever |subnormal_hit, so `ec-1` can be clamped to 5 bits
  without changing any consumed value). NOT yet edited — needs node-level
  path confirmation first. `g6lc_ai_gemm_arplan` 59.0 remains the only
  confirmed dead ai row.
- `g6lc_ai_gemm_fp32_norm` EDITED x2, boards `apu-fp32n-t1/t2`: the 44.1 io
  path (7 nodes, L181) was the `subnormal_fraction` barrel shift. (a) shift
  amount clamped to 5 bits — consumed only under |subnormal_hit which needs
  ec <= 23 (ec-1 <= 22); larger ec mask the term to zero. 44.1 -> 42.4 KEPT.
  (b) magnitude truncated to [22:0] (bits 23:24 provably never reach the
  23-bit result) — neutral, KEPT (exact, no cost). Residual 42.4 likely the
  magnitude adder chain (diff_yx carry-save) + shift; module is one comb
  cloud inside fp32_add_p2 — pipelining would be a contract change.

## r127u — coherence_hub slot-centric B/R demux attempt (REVERTED, parser-blocked)

- Goal: break the 66.1 io cone (`mem_resp_i.{b,r}.id` -> `bs/rs` variable index ->
  `aw_ot_q/ar_ot_q[slot]` -> `bc/rc` variable index -> `core_resp_o[core]` +
  `mem_req_o.{b,r}_ready`) by iterating slots/cores as constant-index pairs.
- Form written: `for s { if (id==s && ot[s].valid) { b_hit[s]=1; for c {
  if (ot[s].core==c) { fast-path | park } } } }` for B; same + ar/aw arm
  priority (`!ar_ot_q[s].valid` guard) for R. Semantics preserved incl.
  park/withhold/safety-drain, `aw_ot_d[s].b_done` read-after-B-write ordering,
  `b_offer_slot` lock, held replay precedence (`!held_found[c]` /
  `!r_held_found[c]`).
- FUNCTIONAL: `run_hub_bench.sh r127u-slot` (WSL verilator 5.020) — result lines
  IDENTICAL to HEAD baseline: all scenarios pass except the known pre-existing
  nc=3/nc=4 scenario-5 `HUB_INV_LOSS` failure that HEAD also exhibits
  (worklog r127 note, tb line 424). No regression introduced.
- PARSE BLOCKER (new finding): sv-timing rejects the nested procedural
  `for s { if { for c { if/else } } }` inside the big response always_comb —
  `error: parse error ... Parse(Some((file,16552)))` at a fixed early offset
  (misleading; real cause is the loop nest). Bisect evidence:
  * decl-only (`logic [OT_MAX-1:0] b_hit,r_ar_hit,r_aw_hit` + defaults): rc 0.
  * single-level `for s` + trivial body + `b_hit[s]`/`!|b_hit`: rc 0
    (`apu-hub-dup`).
  * `for s { if { for c { if } } }` even with a ONE-STATEMENT inner body:
    rc 1 (`apu-hub-dupn2`). The identical nest parses fine inside the small
    `hub_aw_sc_collide_o` always_comb — so the limit is contextual to the big
    always_comb (depth/instance budget), not the construct per se.
- Documented path forward (NOT DONE): flat-vector formulation — compute
  `b_match_s[s]`/`r_*_hit[s]` in single-level loops, gather `core_id[s]` /
  per-slot fields into packed vectors, then per-core `for c` bodies use pure
  bitwise ops (`|(match & (core_id==c))`, field muxes) with NO nested for.
  Uncertain FO4 payoff; the (s,c) field-gather muxes remain OT_MAX-way per
  core. Alternative: split demux into a separate always_comb computing
  intermediates (adds a comb layer — likely FO4-negative).
- File restored to pre-attempt state (noslot = 66.1 board-of-record content);
  attempt artifacts under `build/r127-apu/hub_{mine,noslot,bonly,bonly2,b1,bc,
  declonly,dupname,dupnest,dupn2,head,pickrr_only}.sv`.

## r127v — coherence_hub slot-centric B/R demux (LANDED)

- Same rewrite as r127u but split across dedicated prep always_comb blocks
  (binding/fast/park/fire decisions) + single-level consumer loops in the big
  response always_comb. Decls: `b_hit_p/b_park_p/b_fire_p/b_fwd_c/b_fwd_slot_c[]/
  b_fwd_orig_c[]/b_ready_p` and `r_ar_hit_p/r_aw_hit_p/r_aw_park_p/r_ar_fire_p/
  r_aw_fire_p/r_fwd_c/r_fwd_orig_c[]/r_ready_p` (module level, gen_cluster).
- FUNCTIONAL: `run_hub_bench.sh r127v-final` — result lines IDENTICAL to HEAD
  baseline: OT4/NC2 + OT1/NC2 all pass; OT4/NC3 + NC4 only pre-existing
  scenario-5 `HUB_INV_LOSS` (tb:424) that HEAD also shows. No regression.
- BOARD `apu-hub-r127v`: **exclusive_case_mux 66.1 -> 38.8** (the 27-arm
  `aw_ot_d` demux collapsed to per-slot constant-index writes); plain worst
  64.0 -> 62.2; overall worst ~62.2 (was 66.1 any-kind). New limiter is a
  `plain` path on `aw_fire/aw_grant/aw_ot_full/coh_inv_fire_o/do_stamp` —
  the AW-grant -> invalidation-fire REQUEST path, not the response demux.
- PARSE-GOTCHA (corrects r127u): the r127u "nested-for depth budget" hypothesis
  was WRONG. Real cause = `if (!|b_hit_p)` — sv-parser (dalance fork) cannot
  tokenize unparenthesized `!` + reduction-`|`. `!(|x)` parses; `!|x` fails and
  the error surfaces misleadingly at the generate `else` (~byte 16552/7231).
  Bisect: minparse15 `!|b_hit_p` rc1 vs minparse16 `!(|b_hit_p)` rc0; all other
  constructs (nested for->if->for->if, unpacked-array-of-logic decls+writes,
  struct-member-through-unpacked-array `aw_ot_q[s].core`, `arr[struct.mem]`,
  if/else generate, `final`, module instantiations w/ implicit .port) parse.
  RULE: never write `!` immediately before a reduction operator; parenthesize.
- KEPT. Response demux no longer on the critical cone; request-side AW->inval
  grant path (62.2) is the next hub target.

## r127-u — APU exact-frontier survey (systematic node-level read of every live row)

Read each live APU board row's binding cone (apu-ai/l2/l3-r127t + apu-hub-r127v +
apu-coh). Result: **the latency-neutral FO4 frontier in the APU is reached.**
No remaining live row has a binding `exclusive_case_mux`/selection-structure
cone — every worst path is `plain` (serial dependency) or `independent_lhs_bundle`,
i.e. the class that only pipelining/data-structure contracts move. Per-row:

- `g6lc_coherence_hub` 62.2 — AW-grant -> `inv_ot_d` invalidation stamp. P10
  handshake-locked (same-edge pulse+index; InsertReg refused). Contract =
  registered invalidation stamp; verify `run_hub_bench.sh`. Highest live APU row.
- `g6lc_l2_top` ~54.5 worst-config — `collect_idx=fifo_q[collect_pos]` ->
  `fill_state_q[collect_idx]` double dynamic-index into `collect_active`/
  `is_fill_beat`/`r_ready`/`rdtrk_grant` (same shape at `issue_idx`). Contract =
  parallel `fifo_state_q[pos]` snapshot or registered resolve (needs mshr->pos
  reverse map); verify `run_l2_bench.sh` 5 configs.
- `g6lc_ai_gemm_seq` 49.6 — protocol-serial `w_fetch_needed->rd_sel_*->c_rx_*->
  bank` qualify chain + store handshake. Contract = registered read-select /
  bank prefetch; verify `run_gemm_gate.sh`.
- `g6lc_ai_gemm_fp32_norm` 44.1 — `corr->diff_yx(_carry)->magnitude->leading[b]->
  normal_hit->gen_normal_or->finite_result` serial chain (24-bit subtract +
  25-way leading-one priority + 5-level masked-OR). `fraction[b]` b<24 is a
  constant shift (free); only b=24 uses `rounded`. Barrel-shift clamp already
  landed. No exact rewrite found; contract = registered leading-pos or shared
  prefix-OR (changes align->norm latency).
- `g6lc_ai_island_top` 43.2 — submit-source priority mux (`l_sb_imm->sb_imm_
  submit->submit_src_sb_mux->submit_*_mux`) + `cpl_push_ticket/cpl_room_free`.
  Contract = registered submit-source; verify `run_island_gate.sh`. The
  `rdata_n` exclusive_case_mux deflates 89.5->24.3 but makespan floor 43.9.
- `g6lc_l2_mshr` 39.8 — free-entry priority pick; TWO priority-tree rewrites
  already countercased (->64.8/760). Treat as exact floor unless a free-list
  stack data-structure is chosen (contract).
- `g6lc_ai_pe_dot_float_pipe` 38.8 — `exp_min` tail tournament -> `s2_block_
  exp_d`; already group-pre-reduced balanced log tree = pipeline floor.
  Contract = fold tail into S1 group_min, or accept floor.
- Dead/non-synth (not design targets): `ai_fp_dot` 271.5 (behavioral `real`),
  `ai_cluster_set` 71.5 (no instantiator/P10), `gemm_arplan` 59.0 (no
  instantiator), `gemm_fp32_add`/`_align` thin wrappers.

DECISION: no contract change landed this pass — every remaining reduction moves
a same-cycle consumer (L2 fill collect, hub invalidation stamp, GEMM read
select, island submit, fp32 align->norm), i.e. changes cycle-accurate latency.
Per the verify-in-lockstep rule these need their module bench AND a remote
smoke/witness before landing; unit benches alone do not qualify a latency
change on the coherence/L2 critical path. Specs recorded per-row above and in
fo4-census.md so each is a self-contained next task. Exact-transform work on
the APU is COMPLETE; the board now stands at hub 62.2 / l2_top 54.5 / gemm_seq
49.6 / fp32_norm 44.1 / island_top 43.2 / l2_mshr 39.8 / pe_dot 38.8 (live rows).

## r127-y/z — unmeasured-live-module sweep: g6lc_l2_pf + g6lc_server_prefetcher

CONTINUATION of the r127-u APU frontier. The prior boards omitted live leaf
prefetchers; board `apu-unmeas-r127a` (params-coh, same toolchain/argv as the
r127 cohort) measured them for the first time:

    172.9  g6lc_l2_pf            <- was the HIGHEST FO4 in the whole APU
     76.5  g6lc_server_prefetcher
     15.6  g6lc_l3_inclusive_inv  (under budget)
      9.9  g6lc_axi_lrsc          (under budget)

Liveness confirmed by instantiation: `g6lc_l2_pf` under `if (PF_EN)` in
corev_apu/l2_cache/g6lc_l2_top.sv (~L1288); `g6lc_server_prefetcher` in
corev_apu/src/g6lc_cluster.sv (~L714). Both are production prefetch units.

### g6lc_l2_pf 172.9 -> 143.1  (board apu-unmeas-r127y) — LANDED + VERIFIED

Two exact (latency-neutral) rewrites on the emit path, both proven by
exhaustive Verilator miters and the dedicated `L2TB_MODE=pf` bench
(`RTL_REVIEW_PASS l2_pf`, metrics issue=7 useful=2 drop=5, oracle_negative
diverges as designed — ran twice, on the shift-add-only and the final
shift-add+in_page forms):

1. `em_base = last + LINE_BITS'($signed(stride) * $signed({1'b0,ahead}))`
   The `*` billed an atomic Mul ~87 FO4. Replaced by a per-bit shift-add:
   `ahead` is PW bits so `stride*ahead = SUM_{b in ahead} stride*2^b`; `es`
   sign-extends stride to EM_W=DLT_W+PW+2 before shifting (bare `stride<<<b`
   wraps at DLT_W). **Multiply-semantics gotcha (important, recorded):**
   `LINE_BITS'($signed(stride)*$signed({1'b0,ahead}))` is evaluated at the
   cast's LINE_BITS(=58) context -> the TRUE product, NOT a self-determined
   max(DLT_W,PW+1) truncation. A first PROD_W=7 attempt produced +50 where the
   original gives -78 (stride=-26,ahead=3) — WRONG; caught by the miter.
   EM_W=DLT_W+PW+2 signed holds |product| with margin and `LINE_BITS'(em_prod)`
   sign-extends identically. Miter: 2048 cases, 0 err.
   Also fixed a Verilator LATCH: `es`/`em_prod`/`xs` are block-scope temps
   assigned only inside the emit `if` — defaulted `'0` at the top of the
   always_comb per the file's hoisted-local convention.

2. `in_page(em_base,last)` = `page_of(em_base)==page_of(last)` (52-bit field
   compare, ~34 FO4, dependent on the 58-bit em_base add) -> within-page range
   test on `xs = sext(last[PAGE_LBITS-1:0]) + em_prod`: since em_base=last+P,
   page_of equality holds iff the 6-bit within-page offset + signed product
   stays in [0,2^PAGE_LBITS). xs is EM_W+1 bits so `xs[EM_W:PAGE_LBITS]==0`
   is exactly that — a reduction-OR that bypasses em_base entirely.
   `!(|xs[EM_W:PAGE_LBITS])` (parser-safe form; `!|` is rejected). Dead
   `in_page()` helper removed. Miters: 196,608 + 262,144 cases, 0 err
   (swept all stride bit-patterns x ahead x offset x page incl. wrap edges).
   Gain was small (~3) because the binding cone is the emit GUARD
   (`!cnd_vld_d && valid && pend && !(train_hit_idx==em_s retrain)`) + the
   serial match->emit->st_d-update chain, not the page compare itself.

Residual 143.1 = plain serial chain: `train_hit` match-scan (20.4) -> `es`
sign-extend (12) -> `em_prod` shift-add (28.3) -> `xs` add (16.7) -> emit-guard
(33.7) -> `st_d[em_s]` demux write (31.7). Contract-limited — would need a
registered train_hit_idx / emit-select (latency change); deferred.

### g6lc_server_prefetcher 76.5 -> 74.5  (board apu-unmeas-r127z) — exact

`delta = signed'(demand_line - st_q[s].addr)` was a 64-bit subtract though
`delta` is signed[31:0]; narrowed to `demand_line[31:0] - st_q[s].addr[31:0]`
— `(a-b) mod 2^32` needs only the low 32 operand bits, bit-identical, halves
the carry chain on the match path. The `stride*PF_DISTANCE`/`LINE_BYTES*
PF_DISTANCE` terms are constant-parameter multiplies already folded off the
critical path (no Mul node in the top cone). Residual 74.5 = serial
demand_ar->demand_line->per-stream delta/compare/alloc->pf_addr->pf_addr_d
(contract-limited). `tb_g6lc_pf` (run_pf_review.py) covers response
ownership, not delta; change exact by construction. NB assumes
AXI_ADDR_WIDTH>=32 (default 64; de-facto AXI invariant).

### Updated live APU board (worst-first, post-r127z)

    l2_pf 143.1   coherence_hub 62.2   server_prefetcher 74.5
    l2_top 54.5   gemm_seq 49.6   fp32_norm 44.1   island_top 43.2
    l2_tag 41.6/36.0   l2_mshr 39.8   pe_dot 38.8   desc_engine 34.8
    store_plan 30.6   ...   l3_inclusive_inv 15.6   axi_lrsc 9.9

NOTE: **g6lc_l2_pf 143.1 is now the worst live APU module** (was 172.9, the
single highest FO4 anywhere before this sweep). Its residual is the
match->emit->update serial chain = contract item (registered train_hit_idx /
emit-select, a latency change). coherence_hub 62.2 is second.

## r127-aa — g6lc_l2_pf parallel emit-eval  (143.1 -> 138.8, latency-neutral)

Replaced the serial early-exit `for k` emit walk with parallel per-stream
evaluation. Old form: `em_s=(rr_q+k)%NR_STREAMS` then dynamic `st_q[em_s]`
(125-bit record) read + emit arithmetic + dynamic `st_d[em_s]` write, gated by
`!cnd_vld_d` so the winner's depth stacked on up-to-N guard checks. New form:
`for s` (constant index, `st_q[s]` flop reads) computes per-stream
armed/in-page/candidate-line/rr-position into `em_ok/em_pc/em_bs/em_ps`;
a position-priority picks the winner (`em_ps` = forward distance from rr_q,
a bijection so exactly one emitter has no earlier-position emitter); `st_d`
updates are per-stream constant-index. Semantics identical: first
armed+in-page stream in rr-order emits; armed page-bound streams before it get
pend=0; streams after it untouched; retrained stream never a candidate; the
compare+add `em_ps` is exact for any NR_STREAMS (no pow2 assume).

Verification (the reason this is landable):
- MITER `analysis/r127/probes/miter_l2pf_emit.sv` — OLD serial walk vs NEW
  parallel block on identical randomized inputs (full stream_t table, rr_q,
  train_i/hit/hit_idx, cnd_vld entry, quiet_d). Compares cnd_vld_d,
  cnd_line_d, rr_d and the WHOLE st_d array. **11M cases, 0 mismatches**
  (NR_STREAMS=4: 8M; NR_STREAMS=3 non-pow2: 3M).
- `L2TB_MODE=pf`: `RTL_REVIEW_PASS l2_pf`, metrics issue=7 useful=2 drop=5
  identical to the serial baseline; `+oracle_negative` still detected.
- Full `run_l2_bench.sh r127aa`: **5/5 configs PASS** (default/posted/wupdate/
  posted-wu/units) — l2_top integration clean.
- Board `apu-unmeas-r127aa`: **138.8** reg_to_reg (was 143.1).

Honest gain note: only -4.3 FO4. The emit arithmetic (`es->em_prod->xs->em_bs`,
~56 FO4) is inherent per-stream and now sits on the path once for the winner;
the removed dynamic-index barrel muxes were ~4 FO4. This is still a real win —
it deletes N dynamic-index structures (better for P&R/floorplan) at equal
latency — but l2_pf remains the worst live APU module. Residual 138.8 =
match-scan -> per-stream emit arithmetic -> winner-priority -> apply; the
board's own opportunities list offers only `insert_reg` (latency change) or
~1.7-FO4 `split_assign`/`balance_mux` crumbs. True reduction = registered
emit-select / candidate pipeline stage = contract item, deferred.

## r127-ab — `g6lc_ai_pe_dot_float_pipe` exponent-min tree rebalance (LANDED, verified)

**Census correction first:** the "pe_dot_float_pipe 38.8" figure came from
`apu-pedot-t1` (a small-Lanes board). The production-params board `apu-pdf`
(`analysis/r94/params-ai.json`: `Lanes=512` = `AI_LIVE_MACS`, `IslandFpEn` live,
`.DotPipeFloat(1'b1)`) measures the module at **80.2 FO4** — it was the #3
worst live APU row (after l2_pf 138.8, ahead of server_prefetcher 74.5), not
38.8. `g6lc_ai_pe_dot_pipe` (int) is only 14.8 at the same params — the float
exponent normalization is the unique cost.

**Root cause:** the block-minimum-exponent search is a LEVELS-deep (9 for
Lanes=512) signed-min tree over 512 lanes, split across the S1/S2 pipeline
boundary by `EXP_GROUP_LEVELS`. r94 capped S1's share at 3 levels
(`(LEVELS<3)?LEVELS:3`), leaving S2 to walk a 6-level tail tournament over 64
group roots -> the 80.2 makespan (region-13 `blk_min`, deepest op ~64 FO4).
S1's makespan is set by the per-lane `fp_dot_product` multiply (~27 FO4), NOT
the exponent cone, so S1 had ~50 FO4 of slack the exponent tree wasn't using.

**Fix (latency-neutral work redistribution):**
`EXP_GROUP_LEVELS = (LEVELS<=6) ? ((LEVELS<3)?LEVELS:3) : ((LEVELS+1)/2)`
-> 5 at LEVELS=9 (GROUP_SIZE=32, GROUPS=16, TAIL=4). Even split for deep
trees; r94 cap preserved for LEVELS<=6 (already balanced). Same pipeline
depth, same `s2_block_exp_q` capture edge, identical min value -> NOT a
contract change. Guarded by the existing `gexp_chk` assertion
(`s2_block_exp_d == ref_min`, brute-force over all lanes).

**Sweep:** EGL=4/5/6 all give 37.2 top (the exponent cone drops below the new
limiter); =5 chosen for tightest secondary paths and the even-split formula.
Boards `apu-pdf-r127ab{,4,5,6}`.

**Verification:**
- `run-pe-dot-float-pipe.sh` (Verilator, hyp APU tree via G6LC_AI_RTL_DIR):
  **PASS Lanes=512 transactions=5028 checks=5028 latency=13** — exercises the
  EGL=5 path incl. the live `gexp_chk` assertion.
  **PASS Lanes=256 transactions=5028 checks=5028 latency=12** — EGL=4 path.
  (Lanes=8 default -> LEVELS=3 -> EGL=3, unchanged code path.)
- Latency unchanged: `LATENCY`/`vld` shift register untouched; only comb
  logic redistributed within existing stages. group_min_q count drops
  64->16 (area bonus).

**New 37.2 limiter:** `final_result` -> `bfp_mant_exp_to_fp32` output pack
(normalize+pack, separate floor). Residual secondary: 28.6 exclusive_case_mux
L756, 27.4 L580.

**Prior-art note:** worklog r127 (lines ~1430-1442) records a reverted
tournament rewrite (80.2, serial-billed) whose own next-step note read
"moving one more tree level into S1 (EXP_GROUP_LEVELS 3->4)" — exactly what
landed here, taken further to the balanced split. Do NOT retry pairwise/
tournament min forms.

## r127-ac — latency-neutral frontier closed on core + APU

Post-APU-sweep, turned to the **core** board `core-all-r127-final6` to check for
any remaining reducible path class. Built the module-name map (`modules[].id`)
and worst-path-per-module table.

**Finding:** the only `exclusive_case_mux` rows left are all
*dependency-floor-bound* — `dependency floor makespan == total_fo4` while the
`deflated` mux value is 30-60% lower. `balance_mux` cannot move the makespan:

- `g6lc_ptw_leg_decode` 38.2 (floor 38.2 / deflated 20.1) — MMU PTE_LOOKUP
  leg decode, 10 priority arms over nested pte/stage conditions. Correctness-
  critical (translation); restructuring risks wrong decode for ~0 net gain.
- `bht` 36.6 (floor 36.6 / deflated 13.2), `rename_read` 35.7, `load_unit`
  34.8 (34 arms, floor 34.8 / deflated 29.8), `axi_adapter_arbiter` 31.4,
  `fe_redirect` 30.0, `multiplier` 28.2, `rob` 27.1 — all floor-bound.
- `alu` `a3_d` (35 arms, dom 0.92) and `load_unit` `state_d` (34 arms) are
  mux-dominated by `dom` but still floor-bound on the serial arm-prep chain.

APU side re-confirmed: `g6lc_server_prefetcher` path 14 makespan 67.0 >
deflated 24.8; its 74.5/71.7 plain paths are the `st_q->match->st_d->st_q`
stream-update cone (exclusive_case_mux floor) + `pf_addr` capture — a
*speculative* prefetcher (pf_issue/pf_train feed only PMU group-2 observability,
verified at `g6lc_cluster.sv:372-373`), but its worst path is the stream-state
update, not the input->match path, so input pipelining would NOT split it.
Match-semantics analysis: an input-register pipeline preserves demand[N]-sees-
post-demand[N-1] ordering exactly (only +1 cycle issue latency), but leaves the
st_q->st_d floor as the new limiter — net gain poor vs contract risk.

**Status:** latency-neutral FO4 work is exhausted on both trees. All residual
reduction = contract changes (insert_reg pipelines, free-list/snapshot/reverse-
map data structures, P10 handshake changes), each specified per-row in
`fo4-census.md`. NOT DONE — needs dedicated sessions + remote gating.
