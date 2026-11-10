# r115 — Execution-path tasking and caller iteration plan

Status: **analysis and tasking pass**. No RTL changed in r115. This document
complements the r96 module queue (`../r96/module-tasks.md`,
`../r96/tasks.json`) by (a) re-baselining every module touched since the r96
board freeze, (b) iterating each changed module across its callers and
execution-path classes for retirement restoration, and (c) issuing one task
card per high-FO4 execution path, in the format the reasoning methodology
requires before any edit.

Evidence basis: reasoning docs read in full this session
(`AGENTS-coding-philosophy.md`, `architecture/multi-threading/AGENTS-SMT2-
opensbi-reasoning-pattern-workflow.md`, `architecture/AGENTS-g6lc-opensbi-
dev-heuristics.md`, `AGENTS-rt-learning-philosophy-AGI.md`,
`sv-timing/ALGORITHMS-EXPERTS.md`, `sv-timing/architecture/PIPELINING-RT-
LEARNING.md`), the analysis corpus through `r100/`, the r96 task cards and
bound boards, and the production `core/` + `corev_apu/` reference. Local
verification this session: `lint_hyp8_core_local.sh` (verilator-v5.008,
g6lc_core top) on HEAD `7d7d7dc5a` — **clean of fatal classes, 0 warnings**.

## 1. Current state card

| Track | State | Evidence |
|---|---|---|
| Scalar OpenSBI/Linux witness | r114 open; model `18278962…`, fw `ac36f379…` | `implementation-log.md`; r113 reached SLUB + IRQ/clock/console; r114 corrected SC-retry verdict; userspace markers `G6LC_LINUX_INIT_UP`/`G6LC_LINUX_SHELL` not yet observed |
| io/amo RTL batch (r~Nov 4) | committed `7d7d7dc5a` | `store_buffer.sv`, `stb_fwd.sv`, `issue_read_operands.sv`; 12/12 smokes incl. `hyp8_amo_ready_order`, `hyp8_amo_store_order`, `hyp8_lrsc_store`; integrations io-01/io-02, amo-01/amo-02 `build_complete`, lint rc=0; local lint re-confirmed this session |
| port-amo-fetch lint r1 | **infrastructure failure, not RTL** | missing `/opt/testharness/runs/review-private-runtime-20260915/runtime/include/verilated_funcs.h`; rerun required |
| MC/SMT2 short runs | harness smoke only | `retired_mask=0000`, `held_mask=1110`, ROM fetches served, npc pinned `0x10040` within 1.2–6k-cycle budgets. **Not a boot verdict** — scalar needs ~17–21M cycles to kernel. A real MC witness with the canonical budget is still owed |
| r96 timing queue | 31 module tasks + 6 measurement tasks open | delay-v49 screen, fo4_ps=20, margin 0.2, budget 8 FO4; ranking corrections recorded (FMA reg-boundary model, disabled PF_TAG path, rename bank qualification, L2 guard-incompatible max, coherence sinkless counters, partial caller map) |
| Boot-check whitelist | r115 anticipated | `verif/regress/remote/run_hyp8_witness.py` accepts r113/r114/r115 tags |

## 2. Iteration over changed modules and callers

The r96 board froze before the r97–r114 correctness campaign and the Nov-4
io/amo batch. Every module below changed since that freeze (or anchors a
path the campaign proved load-bearing). For each, the caller set and the
execution-path classes that must be re-audited are listed. "Path class"
follows `retirement-plan.md`: squash, flush, forward, restore, leftover,
commit, cross-hart visibility.

### 2.1 Changed-module × caller matrix

| Module (hyp path under `core/`) | Changed in | Callers (elaboration-relevant) | Path classes to re-audit |
|---|---|---|---|
| `store_buffer.sv`, `stb_fwd.sv`, `stb_insert.sv`, `stb_drain.sv`, `stb_commit.sv`, `sb_lifecycle.sv` | io/amo batch + r100–r114 | `g6lc_core` (via `lsu`/`commit_stage`), `commit_stage.sv`, `g6lc_rvfi_probes.sv` | commit, forward (match snapshot vs slot reuse), squash (kill only speculative), leftover (committed pending records), cross-hart (MC store visibility) |
| `issue_read_operands.sv`, `issue_stage.sv`, `g6lc_ooo_dispatch.sv`, `g6lc_iq*.sv` | io/amo batch + PRF-ownership batch | `ex_stage.sv`, `g6lc_core.sv` | accepted-vs-presented (iqi_take / iss_v_q), hold-pop same-cycle, operand-capture lifetime, n-wide issue arbitration |
| `frontend/g6lc_fe_frontier.sv`, `frontend/*`, `g6lc_loop_buffer.sv`, `bp_*` | r113 restart-frontier fix | fetch_B → decode/ID → issue | redirect/restart ownership, consumed-CF-slot prediction, squash refill, loop-buffer match under flush |
| `load_unit.sv`, `g6lc_lu_result.sv`, `lsu_bypass.sv`, `g6lc_lsq*.sv` | r100–r114 (AMO, forwarding, violation work) | `ex_stage.sv`, `store_buffer.sv` (fwd), `g6lc_rvfi_probes.sv` | AMO_RESULT qualification, subword forwarding, load-publish vs squash, replay/refill, violation→replay |
| `csr_regfile.sv`, `csr_buffer.sv`, `g6lc_smt_csr_bank.sv`, `perf_counters.sv` | r95 leaf + r100+ | `commit_stage.sv`, `controller.sv`, RVFI | dispatch-alloc → commit/drop release, xRET/WFI gating, dead-slot resolution, counter rollover/inhibit |
| `g6lc_hyp_lzc.sv`/`g6lc_hyp_alu.sv` (leaf), `alu.sv`, `mult_clmul.sv`, `multiplier.sv`, `serdiv.sv` | r112 LZC/CTZ fix | `ex_stage.sv`, issue lanes | WIDTH=1/2 base-case boundary, zero-count semantics, multi-cycle latency contract |
| `g6lc_rvfi.sv`, `g6lc_rvfi_probes.sv` | probe ownership fixes | observability only — but retirement-plan requires probes never gate function | staged-frame flush preservation, lsu_ctrl_valid qualification, same-cycle stamps |
| `wt_dcache*.sv`, `std_cache_subsystem.sv`, `missunit` | r100–r114 | `load_unit.sv`, `store_buffer.sv` | miss/MSHR ordering vs squash, wbuffer commit-vs-pending, AMO through D$ |
| `g6lc_mmu.sv`, `g6lc_tlb.sv`, `pmp*` | unchanged this window but on critical boot path | `ex_stage.sv`, `load_unit.sv`, `store_buffer.sv` | page-walk vs squash, TLB shootdown on context switch (SMT2), PMA/PMP check latency |

### 2.2 Cross-cutting contracts that gate every FO4 edit

Before any stage insertion on these paths, the following must be re-proven
against current source (several were proven pre-io/amo and the batch changed
the store/issue boundary):

1. **Common retirement event**: commit-stage architectural writes come from
   the same accepted/retiring event; no stale delayed acks.
2. **CSR ownership**: allocated at dispatch, released at commit/drop; xRET/
   WFI completion gated by request validity.
3. **PRF reads**: captured only on new-issue acceptance (`iqi_take` /
   `fp_take` + `fp_pending_hold`); staged record keeps its operands while held.
4. **Store buffer**: insertion, pending-owner age, forwarding payload and
   committed-pending records staged together; forwarding data snapshotted
   with the match; flush clears speculative forwarding state only.
5. **AMO/LRSC**: SC verdict qualified by `AMO_RESULT` + held SC op (r114);
   AMO ordering through issue head (io/amo batch).
6. **Frontend**: restart frontier = prediction of last consumed CF slot (r113);
   checkpoint slot width ≥ domain width (8-bit fix).
7. **Counters/PMU**: same-cycle rollover, inhibit/freeze, dead-slot exclusion.

## 3. Per-path task index

Task IDs `E115-*`. FO4 figures are the unchanged delay-v49 screen
(fo4_ps=20, margin 0.2, budget 8) from r75 §4 / r96 cards; "bound" marks
caller-qualified numbers, unmarked are module-local screens. `→ r96` means
the module card already exists — E115 tasks add the **execution-path and
caller-iteration** dimension rather than duplicating the module strategy.\n
### 3.1 Retirement / commit path

| ID | Module/file | Screen FO4 | Callers | Mechanism | Contract note | Verify |
|---|---|---|---|---|---|---|
| E115-C1 | `commit_stage.sv`, `sb_commit_bundle.sv`, `sb_head.sv` | ~21–25 bound | `g6lc_core`, `controller.sv` | stage commit-verdict formation; per-entry ready/flush merge → one-hot head select | common retirement event; squash vs commit same-cycle; counter rollover | directed commit-order mini + r96 board re-run |
| E115-C2 | `store_buffer.sv` commit/drain side | ~50 unbound (pre-batch) | `commit_stage`, `lsu` | separate commit-verdict cone from forwarding-match cone; snapshot age at insert | pending-owner age; committed-pending survival across kill | `hyp8_amo_store_order`, `hyp8_lrsc_store` smokes |
| E115-C3 | `controller.sv` + `csr_buffer.sv` release path | ~22 | `g6lc_core` | hoist CSR release decode; parallel free/valid per entry | alloc@dispatch → release@commit/drop; dead-slot no-publish | csr leaf r95 pattern + full-caller elab |

### 3.2 Issue / dispatch path

| ID | Module/file | Screen FO4 | Callers | Mechanism | Contract note | Verify |
|---|---|---|---|---|---|---|
| E115-I1 | `g6lc_iq.sv` / `g6lc_iq_bank.sv` / `g6lc_iq_arb.sv` | 101.7 / 32.3 / ~30.6 | `g6lc_ooo_dispatch`, `issue_stage` | → r96 H96 cards: stage selection/payload; structured parallel grants; one-hot issue | n-wide issue; iqi_take accepted-vs-presented; fp_pending_hold | r96 cones + issue smokes |
| E115-I2 | `g6lc_ooo_dispatch.sv` | ~54.6 older board | `ex_stage`, `g6lc_core` | split operand-capture arm from candidate-select arm | read_enable only on accepted take; PRF port lifetime | PRF-ownership leaf tests (already landed r100+) |
| E115-I3 | `issue_read_operands.sv` | ~27–28 | `ex_stage` | per-lane operand mux → banked/local select; caller-specialized int vs FP vs mem operands | operand capture vs issue-pop same edge | io/amo smokes + operand-forwarding minis |
| E115-I4 | `g6lc_flu_reserve.sv` | (r96 order-1) | `g6lc_iq*` admission | static class/offset masks; parallel earlier-offer conflicts; state change on final accept only | admission credit vs occupancy; no new external cycle | r96 card; focused FLU leaf |
| E115-I5 | `g6lc_prf.sv` read stage | ~30.6 | `g6lc_ooo_dispatch` | keep registered read-address stage; qualify capture by read_enable_i | captured addr survives hold; zero-reg bypass | landed; re-board to confirm |

### 3.3 Rename / recovery path

| ID | Module/file | Screen FO4 | Callers | Mechanism | Contract note | Verify |
|---|---|---|---|---|---|---|
| E115-R1 | `g6lc_rename.sv` / `g6lc_rename_read.sv` | 49.6 / 35.0 | dispatch, commit (release) | → r96: stage kill/recovery; candidate select; **bound** caller = 72 int + 72 FP entries, 2 banks, 32 ckpts (53.0 screen, needs generate/guard qual) | different-bank picks cannot serialize; RAT free-list ownership across squash | bound board `current-rename-bound.json` exists — consume it |
| E115-R2 | `g6lc_rename_recover.sv`, `g6lc_freelist.sv` | 31.8 / 37.1 | commit, flush | parallel recovery decode; absolute-slot vs offset search (A136–A140: only if consumer wants slot) | recovery must restore exact pre-rename state on every squash class | rename leaf + squash minis |

### 3.4 LSU / memory path

| ID | Module/file | Screen FO4 | Callers | Mechanism | Contract note | Verify |
|---|---|---|---|---|---|---|
| E115-L1 | `load_unit.sv` | ~41–50 | `ex_stage`, `stb_fwd` | split address/perm check from data-return merge; unbuffered-load law may itself exceed 8 — calibrate before cutting | AMO_RESULT gating; subword forwarding; publish vs squash | `hyp8_amo_ready_order` + load minis |
| E115-L2 | `g6lc_lsq*.sv` | ~94 older / r96 order-1 | `ex_stage`, `store_buffer`, `load_unit` | balanced correctly-sized valid-vector popcounts for admission credits; split verdict windows | admission credit exactness; LSQ depth = derived speculative-store depth (MC fix) | r96 card; LSQ leaf |
| E115-L3 | `store_unit.sv`, `stb_fwd.sv` | ~42.3 / (r96) | `ex_stage`, `store_buffer` | per-entry match/forward equations; stable tournament select | forwarding snapshot with match; committed vs speculative sources | `hyp8_amo_store_order`, `hyp8_lrsc_store` |
| E115-L4 | `wt_dcache_wbuffer.sv` + `missunit`/`ctrl`/`mem` | ~50.2 | `load_unit`, `store_buffer` | separate collector/admission from lookup/MSHR decision (r96 order-4); write-buffer fixup search | MSHR owner stability; wbuffer commit vs pending across kill | D-cache checks (334 passed at r114) |
| E115-L5 | `lsu_bypass.sv`, `g6lc_lu_result.sv` | ~19–26 | `ex_stage` | small; audit only after L1–L4 land — avoid optimizing a path that moves, not shrinks | bypass source priority vs AMO | leaf + integration |

### 3.5 Frontend / fetch path

| ID | Module/file | Screen FO4 | Callers | Mechanism | Contract note | Verify |
|---|---|---|---|---|---|---|
| E115-F1 | `frontend/*` (fetch_B, realign, instr_queue, icache, ftq) | 142.4 whole-frontend older board; module screens 18–45 | `g6lc_core` → decode/ID | stage prefix/queue gather and tag-compare separately (r75); keep restart-frontier record whole | restart = last-consumed-CF prediction (r113); squash refill; fetch-debug bind pending rebind | frontend minis + witness PC trace |
| E115-F2 | `g6lc_fe_redirect.sv`, `g6lc_fe_frontier.sv` | 33.1 | `frontend`, `g6lc_core` | split arbitration from record formation (r75) | redirect ownership vs consumed-slot prediction; checkpoint 8-bit slot | r113 linecheck 75 regression |
| E115-F3 | `g6lc_loop_buffer.sv`, `bp_ckpt.sv`, `bp_*` | ~30.6 | `frontend` | loop-buffer match under flush; predictor checkpoint write | match must not resurrect squashed path; ckpt width vs domain | bp/loop directed tests |

### 3.6 Decode / issue-entry path

| ID | Module/file | Screen FO4 | Callers | Mechanism | Contract note | Verify |
|---|---|---|---|---|---|---|
| E115-D1 | `g6lc_decode_s3.sv` (+s1/s2 if bound) | 53.7 | `issue_stage`, `ex_stage` | priority-preserving legality selection; span/terminal facts in existing windows (r96 order-2) | decode must not speculate illegal as legal; flush on redirect | decode leaf + smoke |
| E115-D2 | `issue_stage.sv`, `ex_stage.sv` glue | ~22–28 | `g6lc_core` | caller-specialized operand classes; keep stage boundaries aligned with issue/ex contracts | valid/ID/result/flush across every boundary (P-rep completeness) | full-caller elab + smokes |

### 3.7 MMU / privilege path

| ID | Module/file | Screen FO4 | Callers | Mechanism | Contract note | Verify |
|---|---|---|---|---|---|---|
| E115-M1 | `g6lc_mmu.sv` | 33.6 | `ex_stage`, `load_unit`, `store_buffer` | split context compute from match; stage page-walk arbitration | walk vs squash; SMT2 context switch shootdown | mmu leaf + context-switch mini |
| E115-M2 | `g6lc_tlb.sv`, `pmp*` | 30.9 | `g6lc_mmu`, LSU | tag compare / permission merge staging | PMP row-local update (r96 order-1 csr_regfile PMP writes) | pmp directed + OpenSBI PMP setup path |

### 3.8 CSR / control path

| ID | Module/file | Screen FO4 | Callers | Mechanism | Contract note | Verify |
|---|---|---|---|---|---|---|
| E115-S1 | `csr_regfile.sv` | 37.4 | `commit_stage`, `controller`, `csr_buffer` | → r96 order-1: constant-entry decode + parallel row-local lock/update for PMP writes | CSR alloc@dispatch→release@commit/drop; no stale read after write | r95 nine-source leaf pattern extended to full caller |
| E115-S2 | `perf_counters.sv`, `csr_counters.sv` | ~22–25 | `commit_stage`, RVFI | counter update on retirement event only; rollover/inhibit | same-cycle rollover; dead-slot exclusion; freeze | counter minis |

### 3.9 FPU / multi-cycle path

| ID | Module/file | Screen FO4 | Callers | Mechanism | Contract note | Verify |
|---|---|---|---|---|---|---|
| E115-P1 | `cvfpu/src/fpnew_fma.sv` (+multi) | 133.26/142.72 **bound but measurement-blocked** (M96-FMA-REG) | `fpnew_opgroup_fmt_slice`, `g6lc_ai_fp_mac` | product capture in `p_fma_exp_mant` (2p-bit) inside existing exponent window; rebalance S1/S2 | NUM_MID_REGS=3 FFL boundary model must be fixed before credit; multi-cycle latency contract | M96-FMA-REG fixture first |
| E115-P2 | `multiplier.sv`, `mult_clmul.sv`, `alu.sv` | ~52 / ~27–28 | `ex_stage` | A132 tile→carry-save→final with both rows reconverging; explicit stage dials | carry companion data across every boundary | multiplier leaf (A132 precedent) |
| E115-P3 | `serdiv.sv`, `vfdsu*`, `aes*` | ~44.9 (aes) | `ex_stage`, FPU | multi-cycle: honor latency contract, don't pretend combinational; recurrence rebalance | occupancy/interval vs issue | directed latency minis |

### 3.10 APU / L2 / L3 / coherence path

| ID | Module/file | Screen FO4 | Callers | Mechanism | Contract note | Verify |
|---|---|---|---|---|---|---|
| E115-A1 | `g6lc_l2_mshr.sv`, L2 tag/top | 62.69 (guard-incompatible max — M96-GUARD) | `wt_dcache`, `g6lc_l3*` | per-entry pop/attach/complete equations; parallel free/merge select (r96 order-1) | S_IDLE write vs S_BYPASS_B consumer not sensitizable — find observable alternative | bound boards exist (`current-l2-tag-bound.json`) |
| E115-A2 | `g6lc_l3*` tag/MSHR/write/read-tracking | 41.57 disabled-PF_TAG path excluded | L2, coherence | same pattern as A1; audit generate-arm reachability (M96-GEN) | PF_TAG=0 disabled path gets no RTL priority | `current-l3-tag-bound.json` |
| E115-A3 | `coherence/*` hub, `inval_bus`, `cmo_engine` | 121.60 / 123.30 (sink/reset aggregates — M96-SINK) | `corev_apu` top, L3 | find largest *observable* alternative; slot/response/applied-invalidation ownership split | private counters rejected r94; reset/NBA aggregates excluded | observable-path audit first |

### 3.11 AI island path

| ID | Module/file | Screen FO4 | Callers | Mechanism | Contract note | Verify |
|---|---|---|---|---|---|---|
| E115-N1 | `g6lc_ai_exec.sv`, GEMM seq/norm/align, `desc_engine` | per r96 cards | `g6lc_core` (CVXIF), cluster | span/terminal facts in existing windows; normalization split (r96 order-2/4) | descriptor lifetime across flush; AI ops are non-speculative-commit? — verify contract | ai_island leaf + cvxif boundary |
| E115-N2 | AI PE dot pipeline, cluster dispatch | per r96 cards | GEMM engine | Baugh-Wooley DOT already exists — do not re-propose; rebalance only | stationary slots/age matrices need stable ordering (A138/A141) | r96 cards |

## 4. Boot-retirement restoration track (parallel, gates everything)

FO4 work is worthless if retirement is not precise. Ordered:

1. **r114 witness completion** — monitor to `G6LC_LINUX_INIT_UP` /
   `G6LC_LINUX_SHELL` or first panic; RVFI cycle stamps are the progress
   metric (285M r113 / 16.8M r114 at last check).
2. **port-amo-fetch lint rerun** — infrastructure file missing; restore
   `review-private-runtime-20260915` or repin, then rerun
   `hyp8-port-amo-fetch-lint-r1`. Local lint on HEAD is already clean.
3. **MC/SMT2 real witness** — the t6 short runs are not evidence either
   way. Queue a canonical-budget MC run (`Flist.hyp8_mc_sim`, fw_payload
   ac36f379, maxcpus=2) once the scalar witness resolves or in parallel if
   harness capacity allows. Success = same milestone ladder as scalar.
4. **SMT2 starvation/scheduling** — commit `615dfa62e` "require issue
   progress before SMT starvation switch" is in history; verify the
   scheduler cannot livelock when one hart's window is full (held_mask
   semantics under SMT2).
5. **Abstract-trace audit** — for every module in §2.1, walk
   `abstract-traces.json` + `source-callers.json` against current source;
   any caller added/removed since the trace freeze invalidates the
   affected cards (instrument-identity rule).

## 5. Methodology bindings (what each step must produce)

Per `AGENTS-coding-philosophy.md` + SMT2 workflow + heuristics:

- **Before any RTL edit**: problem statement, mechanism trace, ≥1
  alternative explanation, distinguishing check, concise analysis segment.
- **Contract first** (H2): interface, owner, state lifetime, ordering,
  accepted-vs-presented, backpressure, flush/squash/cancel, replay/refill,
  ID reuse, architectural side effects, external handshakes — recorded on
  the task card before code.
- **Ladder placement** (L0–L7): pick the cheapest faithful level; a change
  proven only at L3 does not claim L6. Firmware is a witness, not a
  controller; `tohost=0`/timeout is failure, not pass.
- **Timing honesty** (ALGORITHMS-EXPERTS + PIPELINING-RT-LEARNING):
  structural FO4 ≠ physical closure; stage insertion needs dependency
  latency + service interval + occupancy + completion-port conflicts +
  reconvergence; representation bundles cross registers together; refuse
  cuts where valid/ID/flush/result alignment cannot be proven; debug-only
  cones (RVFI probe fanout) are separated from functional timing.
- **OpenROAD preparation (no run)**: every accepted stage gets a
  `svt-pipe`-style contract note (valid/ID/result/flush semantics), a
  `.dts`/config/spec alignment note where ISA-visible, and a
  timing-impact note; boards re-run on delay-v49 after each batch.
- **Negative controls**: each experiment leaves a durable artifact
  (property, assertion, mini, lint check, control, rubric row); rejected
  variants stay recorded (A137 cached-address mux, wide-publication r90–93
  variants are the standing counterexamples).

## 6. Remote testharness reprovision (2026-11-08)

The `ovh_calltorch` testharness root was found wiped: `runs/` held only
recent storamic dirs + the failed `hyp8-port-amo-fetch-lint-r1`,
`toolchains/` contained only `apu-repo-verilator`, `src/`, `repo/`,
`work/`, `cache/` were absent, and **no verilator/spike/riscv-gcc
anywhere on the filesystem**. The r114 scalar witness (pid 2644580,
1e9-cycle budget, launched 2026-11-02) is **dead** — its run dir and
model binary are gone; it will never report userspace markers. All
remote hyp8 evidence must be re-earned; local `remote-runs/` retains
only pulled artifacts.

Reprovision executed through `testharness_proxy.py` from WSL (Git-Bash
perl lacks Pod::Usage; Windows lacks rsync — WSL has both):

1. `setup` → provision.sh: base deps, **stock verilator v5.008 source
   build** → `toolchains/verilator-v5.008` (header sha
   `8c408609…` = pinned ORIGINAL, verified), xpack gcc 14.2.0-3,
   client spike upload (1.2 GB), `env.sh`.
2. `py stage_toolchains.py` → `src/verilator-g6lc` = tools/verilator
   fork checkout at gitlink `bc8d406c3` (the `g6lc` branch HEAD).
   The wsl verilator copy lost the `toolchains/verilator-v5.008` slot
   race to provision's on-target build — same version, cleaner
   provenance.
3. `py rebuild_private_runtime.py` → **private runtime restored** at
   `runs/review-private-runtime-20260915/runtime` (canary: stock 18
   failures → fixed 0). This was the sole blocker of
   `hyp8-port-amo-fetch-lint-r1`.
4. `py run_vlt_pgo_build.py` (r2) → `install-verilator-g6lc.sh` with
   `VLT_PGO=1`, `VLT_PGO_TRAIN_TARGET=g6lc64_hyp8_mc`,
   `VLT_PGO_TRAIN_THREADS=4`, `VLT_PREFIX=toolchains/verilator-v5.008-g6lc`.
   Training repo = curated 13 MB hyp8 closure
   (`remote-runs/hyp8-port-amo-fetch-lint-r1-closure` + the missing
   `Flist.hyp8_mc_sim`) staged at `/opt/testharness/repo-pgo` — the
   full `sync` whitelist was deliberately skipped (multi-GB
   remote-runs/analysis trees; closures are the designed payload).
   Throwaway git commits satisfy the script's `set -euo pipefail`
   PIN/checkout probes (rc=128 abort on first attempt, fixed in r2).

**PGO/unroll/sim-PGO status**: compiler PGO = VLT_PGO pass1
(instrumented) → hyp8_mc verilation training (`--threads 4`,
`--unroll-count 256 --unroll-stmts 131072`, split-loops .vlt,
unroll-before-split) → pass2 `-fprofile-use -O3 -march=native`.
Loop unrolling is unconditional in `hyp8-build-harness.sh` and the
split-loops .vlt is default-on for the g6lc flavour. Verilator-side
`--prof-pgo`/`--prof-exec` (MTask profiling → profile.vlt) is a
per-build flag the fork supports; C++ PGO of generated models is a
driver recipe (T16_PGO lineage) not present in hyp8-build-harness.sh —
recorded as an available-but-unwired option, not claimed enabled.

**sb_head CMPCONST audit (resolved, benign)**: `TRANS_ID_BITS =
$clog2(NR_SB_ENTRIES)`; the flagged comparisons cast a genvar slot
constant against `commit_ptr_i`/`ptr_chunk_q`. For the boundary slot
whose cast value is all-ones within the pointer width, `>=` folds
always-true and `<` always-false — which is the *correct* hi/lo
membership (that slot is never below any valid pointer). Ring-order
merge semantics verified by hand for ptr=5 and ptr=63 cases. No RTL
change; warning is lint noise on constant-folded boundary slots.
E115-C1 retains the audit note for completeness.

Local lint cross-check (WSL verilator 5.020, `lint_hyp8_core_local.sh`,
top `g6lc_core`, HEAD `7d7d7dc5a`): clean of fatal classes, **7
`%Warning-CMPCONST` in `core/sb_head.sv`** (lines 111/115/159–162/217 —
`TRANS_ID_BITS'(S)` vs `commit_ptr_i` comparisons fold at the width
boundary). Non-fatal, but the same slot-width class as the earlier
checkpoint-truncation defect → added to E115-C1 audit scope; do not
treat as qualified-clean until reviewed.

## 7. Immediate next actions (ordered)

0. **Remote reprovision (in flight)**: await `hyp8-vlt-pgo-build-r2`
   (~1 h); verify `toolchains/verilator-v5.008-g6lc` reports
   `5.008 (mod)` with prof-pgo/unroll support; then rerun
   `run_hyp8_integration.py` on the fork via `HYP8_VERILATOR_DIR`
   (instrument switch recorded via verilatorBinSha256) — this re-earns
   the port-amo-fetch lint that died on the wiped runtime. The r114
   scalar witness must be **relaunched** (new run, same fw_payload
   `ac36f379`, same milestone ladder); treat all prior remote run
   evidence as archived, not live.
1. Re-run r96 `reboard.py` bindings against HEAD `7d7d7dc5a` to refresh
   `current-*.json` boards — the io/amo batch moved store/issue cones.
2. Execute M96-FMA-REG fixture (unblocks E115-P1, the largest bound cone).
3. Consume `current-rename-bound.json` for E115-R1 qualification.
4. Queue port-amo-fetch lint rerun (infra restore) + canonical MC witness.
5. First RTL batch candidate (r96 order-1, no new external cycle):
   E115-I4 FLU admission + E115-S1 csr_regfile PMP writes + E115-L2 LSQ
   credit reductions + E115-A1 MSHR per-entry updates — one coherent batch,
   one discriminator per invariant, then consolidated gate.
6. Only after batch 1: decoder legality (E115-D1) and AI span facts
   (E115-N1); architectural cycles last.

## 7. Limits

- No Linux userspace boot observed yet; no SMT2/MC boot evidence; no
  physical timing closure; structural 8-FO4 is a screen, not a result.
- r96 caller lists are partially lexical, not elaboration-qualified
  (M96-BIND); E115 tasks inherit that limit until bindings extend.
- The unbuffered-load law can price wide select above 8 by itself
  (M96-LOAD); do not tune calibration to green the worklist.
- `analysis/` documents are evidence records, not qualification claims.

## Order-1 batch reconciliation (r97/r98 landed state)

Cross-checked the four r96 order-1 cards against git history and the
r97/r98 receipts. Commit `40aebfee8` ("rtl: hyp8 FO4 batch — LSQ
credits, checkpoint width, APU updates", 2026-10-30) plus the r97 FLU
batch already landed the first implementation wave:

- **E115-I4 g6lc_flu_reserve** — r97 static class/offset masks +
  parallel earlier-offer conflict matrix. Functional baseline-vs-
  candidate `matched: true`, zero width diagnostics, before/after
  bound boards measured (`r97/bound-{before,after}-p{2,8}.f`).
  Status: landed-awaiting-board.
- **E115-S1 csr_regfile** — r98 constant-entry decode + parallel
  row-local PMP write-bank update retained; 7/7 scalar smokes exit0
  at r90 cycle counts (`r98/aggregate-review.json`).
  Status: landed-awaiting-board.
- **E115-L2 g6lc_lsq** — r98 balanced `$countones` free-credit masks at
  `clog2(cap+1)` widths (source `g6lc_lsq.sv:341-354`). Same commit
  resolved the MC store-reservation contract: ST_N now derives from
  speculative-store geometry instead of `NrIssuePorts*4`; commit
  validation claims MC lint rc=0 with zero USERERROR/SELRANGE.
  Status: landed-awaiting-board.
- **E115-A1 g6lc_l2_mshr** — r98 per-entry pop/attach/complete rewrite
  measured **timing-negative and was reverted** (commit message;
  baselines `r98/mshr-*.before.sv`, rejected variant
  `mshr-per-entry.rejected.sv`). The 62.69-FO4 guard-incompatible
  path stands as a structural floor candidate; a different mechanism
  is required before re-attempt. Status: reverted-timing-negative.

Checkpoint-width follow-up also landed in `40aebfee8`: lane
`ckpt_slot` widened `[5:0]`→`[7:0]`, producer/oracle casts
6-bit→8-bit, consumer part-select removed — the r98 SELRANGE
("8 bits from 6-bit record", `lint-mc.log:1392`) is closed; commit
claims a depth-128 checkpoint leaf exercised slot 127.

Net: the order-1 implementation batch is COMPLETE in source; the open
items are re-verification (remote PGO integration lint + witnesses)
and the remaining r96 queue (decoder legality/AI descriptor order-2,
cache collector/FMA arithmetic/GEMM order-3, M96 measurement repairs).

## Uncommitted working-tree batch (in-flight, pre-verification)

`git status` shows an uncommitted hyp8 timing/structure batch on top of
HEAD `89deb345c`. Contents (all consistent with the break-the-cone /
width-explicit methodology; verification state unknown — remote lint
will exercise them via working-tree sync):

- `core/cache_subsystem/g6lc_icache.sv` — `flush_d`,
  `areq_o.fetch_req`, `dreq_o.valid` moved out of `p_fsm` into
  continuous assign / `p_response_valid`; breaks the response→BP
  combinational loop (comment cites the W1 overlap accept).
- `core/cache_subsystem/wt_dcache_missunit.sv` — `mem_req_size`
  separate net; `paddrSizeAlign` no longer reads `mem_req_c.size`
  while `mem_req_c.paddr` is being driven (self-referential packet).
- `core/csr_regfile.sv` — `automatic logic DirVecOnly` lint fix.
- `core/fetch_B/instr_queue.sv` — `push_address` consumes the selected
  CF (`taken`/`fsel`) instead of `instr_data_in[f].cf`; checkpoint
  payload now feeds `consumed_o` only, not admission.
- `core/g6lc_mmu/g6lc_ptw.sv` — `shared_tlb_update_valid` /
  `is_napot_64k` split into `ptw_leaf_update` always_comb; same
  verdicts, removed from the FSM process consuming `shared_tlb_hit_i`.
- `core/sb_lifecycle.sv` — `issue_pointer[i]` expressed as offsets of
  the register rather than chained neighbour reads.
- APU (`hyp_redesign_corev_apu_8fo4`): `G6LC_SIM_DRAM_DELAY` sim-only
  axi_delayer knob (off by default); `g6lc_cluster` `MAX_OUTSTANDING`
  auto-derive 2 slots/core clamped [4,14]; `rvfi_tracer` trap lines
  now carry hart id for SMT trace attribution.

These are NOT committed and NOT yet lint/sim qualified; treat as WIP
evidence, not accepted RTL.

## r115 order-3: store_unit fused store-data path (E115-L3) — LANDED 58.0 -> 41.35 FO4

Worst non-tagged hyp8 path on the r96 `current-core-all` board was
`store_unit` 58.00 FO4 intoreg (`in0 -> reg1/D`, store_unit.sv:569):
endian byte-reverse case (op-class, `mbe`) serially feeding the
`data_align` byte-rotate barrel — two XLEN-wide selects in series.

Transform (caller-aware, value-identical): both stages are pure byte
permutations, so they are composed on the INDEX side — output byte j
reads `data[idx(j)]`, `idx(j) = endian_perm(base(j))`,
`base(j) = j` for AMO passthrough else `(j - vaddr_off) mod nbytes`.
Permutation arithmetic runs on 4-bit indices; data crosses one 8:1
byte mux per slice. Implemented as `store_data_fused` + `store_idx` +
`store_byte_at` functions in `core/store_unit.sv`; `endian_data` and
`data_align` removed (single caller). `st_be_n`, `st_data_size_n`,
`amo_op_d`, `cbo_op_d`, CBO_ZERO zero+BE override, and the same-cycle
`st_data_q` capture are untouched. wb classes mirror the former case
arms exactly, including D-variant AMOs and `SD` falling to XLEN;
`AMO_CASQ` stays in the W=32 arm (bug-compatible).

Verification of equivalence: Python model of original
(endian-permute then rotate-right) vs fused index composition —
0 mismatches / 40k cases across XLEN64+XLEN32, all wb classes, all
offsets, AMO on/off; `data_align` rotate-right model separately
verified against all 8 case arms.

sv-timing iterations (store_unit-only board, same argv as
current-core-all, `analysis/r115/boards/store-unit-fused*.json`):
- fused v1 (function + for-loop + variable part-select write):
  257.85 FO4 — analyzer emitted one opaque `logic_bit` w=64 node
  @267; part-select writes inside a function loop do not decompose.
- fused v2 (+ explicit `store_byte_at` case mux): 269.85 — same
  opaque pricing.
- fused v3/v4 (concat-of-`store_byte_at(store_idx(j))` return, no
  loop/part-select-write): 41.35 FO4 intoreg — residual cone is one
  `logic_bit` w=64 @38.5 + 2.85 input route. Analyzer still prices
  the composed permutation as opaque bit-logic but the concat form
  inlines; further gains need case-arm style.

Local lint (`lint_hyp8_core_local.sh`, WSL verilator 5.020): clean of
fatal classes, 7 known sb_head CMPCONST warnings only.

Status: `landed-awaiting-validation` — pending remote smokes
(hyp8_f14_store_offset, h33_st_fwd, h34_shift_dep) once the PGO
verilator lands; pending whole-core re-board for the new worst-path
ranking. Next worst on stale board: g6lc_decode_s3 51.97,
g6lc_rename_read 51.00.

## r115 order-4: g6lc_rename_read prd index — ATTEMPTED, REVERTED (timing-negative)

Worst-path node chain on `current-core-all`: `lowest_set` w=72
(prefix-OR isolate, 32 FO4 @:220) serially feeding `mask_to_tag`
(mask→index loop, 12 FO4 @:285) = ~44 FO4 of the 51.00 total.

Attempt: compute `prd`/`fprd` directly from the pick input mask
(`free_q_i & bank_mask & ~taken_lt`, bit0-cleared for int) via
`$countones((~ord)&(ord-1))` = lowest set index; port 1 (high) uses
the bit-reversed ordered mask + `N-1-idx`. Math verified vs
`mask_to_tag(pick_free_mask(...))` on 120k random masks (N=72/64/32,
high/low) — 0 mismatches. Lint clean.

sv-timing module board (`rename-read-pidx.json`): **79.19/66.38
FO4** — WORSE. Cause: `ord_o - 1'b1` is a 72-bit borrow chain; the
analyzer prices the subtract ~O(N) and it dominates the countones
tree. Reverted via `git checkout` (no other uncommitted changes in
file). mask_to_tag/mask_to_ftag restored.

Lesson recorded for E115-R1: wide-vector `x-1`/`x+1` are borrow/carry
chains — avoid on >~16-bit cones; the sanctioned isolate is the
prefix-OR `lowest_set` (already log-depth). Next mechanism: a
group-hierarchy priority encoder — split N into G groups of S bits
(72 = 8x9 for scalar PRF), per-group lowest-index via SHORT
countones-trick subtract (S<=9 bits), G-group pick, indexed read of
the per-group index — estimated ~12-15 FO4 vs current ~44, generic-N
needs a generate-time group-size contract (PRF_N=72, FPRF_N derived
32*NH+ROB+8 — check %8==0 or parameterize GS).

## r115 order-4b: g6lc_rename_read — ATTEMPT 2, REVERTED (timing-negative)

Implemented the documented group decomposition as a 3-slice lowest-set
encoder: slices N/3, 2N/3 of the ordered pick mask; per-slice
`countones((~s)&(s-1))` gives lowest set index inside a NONEMPTY slice;
lowest-nonempty slice wins; index composed + port-1 reversal. INT prd
inline in p_lane; FP via generate-guarded `gen_fpidx` (FPN==1 when FP
disabled — degenerate slices cannot elaborate). Math verified 0
mismatches / 150k random masks (N=72/64/40/41/42/33, high/low,
bit0-clear on/off).

Board `rename-read-slices.json`: **72.45 FO4** — WORSE than the
51.00 baseline. IR shows each `countones((~isX)&(isX-1))` collapses to
ONE `add_sub` node priced ~1 FO4/bit (23.1 for a 24-bit slice) —
slicing shrinks the borrow but the analyzer bills sub+countones as a
single wide-arithmetic node, and the added slice-select/mux nodes push
the cone longer. File fully reverted to HEAD (git diff clean).

ANALYZER RULE (binding for future cards): `countones((~s)&(s-1))` and
friends are timing-negative at ANY slice width >= ~16 in this model —
priced as add_sub ~width FO4, not as a popcount tree. Priority-encoder
replacements must be built from mux/or-reduce/compare primitives, NOT
arithmetic reductions. E115-R1 remains open; next candidate is a
balanced one-hot priority encoder (tree of 2:1 selects over group
nonempty flags) or demand-side precompute if a caller window exists.

## r115 order-5: g6lc_decode_s3 fence-override chain — LANDED 51.97→44.47

Critical path was a serial legality override chain: illA→illB→illC→illD
(and virA→virD), each stage a mux replacing the accumulated illegal/virt
set when its fence arm fired, preserving emit last-writer order.

Transform: c_sf/c_hvv/c_hgv are distinct `dec_i.op` values → mutually
exclusive by construction → the chain collapses to ONE priority select
per side: `hit_any ? (sf_hit ? sf_val : !priv_ms_rd0) : illA`, then the
arm-local tvm intercepts OR in (each implies its own hit). New
`p_fence_override` block; illB/illC/virB/virC intermediates removed.
Equivalence: 0 mismatches / 2048-case exhaustive Python over the
contracted input space (at most one fence op; all v_i/RVH/RVS/priv/tvm/
pms/illA/virA combos). Co-firing divergence exists only for impossible
inputs.

Board `decode-s3-flatov.json`: 51.97→44.47. Residual path now exits
through the exception-assembly tail: ex_fin.gva @402 (9.9 opaque),
illegal mux @289 (8.5), illA 8-way OR @258 (7.0). Next decode_s3 cuts
need exception-priority restructuring — deferred to a follow-up card;
module board also shows independent_lhs_bundle @250 still 26.02.

## r115 order-6: load_unit ex_pub decomposition — LANDED 47.40→43.20

ex_pub was a 9-term flat AND priced as ONE compare node (10.5 FO4):
response-side slot reads (ldbuf_valid_q/flushed_q[rresp_idx],
cancelled_mask_i[ldbuf_q[rresp_idx].trans_id]) + context terms
((last==rresp)||!kill_req_w, ex_i.valid, !ex_ptw_i, state_q[SEND_TAG]).
Split into ex_slot_ok && ex_ctx_ok — pure && regroup, identical
boolean function, all downstream consumers (a_expub, rkill push,
live_rpend_oh, ex_pend) unchanged.

Board `load-unit-split.json`: ex_pub path gone from top; new critical
= load_control FSM next-state cone — state_d/pop_ld_o/st_fwd_done
outputs @L1042-1180 all 43.20 (nested !page_offset_matches ->
!data_gnt -> MmuPresent&&!dtlb_hit -> !stall_ni decision chain).
Endpoint ldbuf_valid_d[ldbuf_rindex]=0 @486 = 42.90. Next candidate:
balance the FSM arm predicates or precompute page_offset/dtlb-hit
facts into the window; do NOT touch pop/publish ordering (r76/r84
one-hot arms are load-bearing for F15/F15b correctness).

## r115 order-7: wt_dcache_wbuffer coalesce mask — LANDED 44.89→41.72

fixup_coalesced ANDed `|snap_push_first` where snap_push_first =
fixup_first_from_head(snap_push_match) — a hi/lo wrap-aware lowest-set
encoder (prefix-OR isolate + select, 13.5 FO4 opaque). The encoder
output is one-hot-or-zero, so |encoder(m)| == |m| for ANY m: hi/lo
partition covers all bits (hi|lo == m) and lowest_set(x)!=0 iff x!=0.
Replaced the reduction input with |snap_push_match| (the raw CAM OR);
the encoder is still used positionally at fixup_active_coalesced
(snap_push_first[fixup_head]) which is off this path.

Board `wbuffer-cammask.json`: 44.89→41.72. Residual critical = the
8-way snap_push_match paddr CAM (58-bit compares + valid AND + OR
tree) — inherent to the coalesce content-addressed match; further
cuts need CAM width/assoc changes, not logic restructuring.

## infra: PGO fork build — training verilation killed, pass-2 running

The g6lc64_hyp8_mc training verilation (instrumented pass-1
verilator_bin, --unroll-count 256 --unroll-stmts 131072, split-loops
.vlt) ran 3h16m single-threaded at 13.7GB RSS without emitting C++ —
pathological V3 grind on the 8-issue MC model. 132 .gcda profiles were
already banked from earlier completed verilation phases. Killed
verilator_bin (SIGTERM→SIGKILL); the install script's designed fallback
("training verilation returned nonzero — profiles are still usable")
engaged: pass-2 configure -fprofile-use + make -j now compiling
(cc1plus active ~12:20 UTC). PGO quality note: profiles cover the
completed phases; the deep unroll/split coverage from the MC verilation
is absent — if profiling proves thin, rerun training later with a
smaller unroll budget for the MC target only. Unroll/split/prof-pgo
FEATURES are unaffected (source-level in the fork).

## r115 order-8: csr_regfile dpc_d trap-entry coalesce — LANDED, timing-NEUTRAL 52.60

Whole-core board `core-all-r115` put csr_regfile at 52.60 (E115-S1 card).
IR inspection of `csr-regfile-dpccoal.ir.json` revealed the analyzer's
cost model for monolithic always_comb: nodes chain in PROGRAM ORDER —
node 902 (dpc_d sext(predict_address) @3759, cum 50.5) has fanin [901]
= dcsr_d.v @3755 which fans into 900 = dcsr_d.prv @3754 which fans into
899 = dpc_d sext(pc_i) @3749 (cum 48.5). I.e. each blocking assign in
the block is billed as depending on the previous statement's cone —
the same serialization that makes hpdcache_ctrl_pe cost 75.85. TRUE
data dependence (last-writer mux DAG) is NOT what is priced.

Transform applied anyway (semantically exact, verified): the three
trap-entry debug arms (trigger/breakpoint/debug-request) all wrote the
identical `{{XLEN-VLEN{pc_i[VLEN-1]}}, pc_i}` to dpc_d. Coalesced into
one guarded assign `(SDTRIG&&debug_from_trigger)||(ex_i.valid&&cz_brk)||
(ex_i.valid&&cz_dbg)` placed after the three arms, before the
single-step arm (which remains last-writer winner). Mirrored in the
rf_dpc_d shadow block using its inline cause compares — proven identical
to cz_brk/cz_dbg (L3369-3370: `cz_brk = ex_i.cause==BREAKPOINT`,
`cz_dbg = ex_i.cause==DEBUG_REQUEST`), so the rf_dpc_d==dpc_d assertion
contract is preserved. All per-arm side effects (dcsr_d.prv/v/cause,
debug_mode_d, set_debug_pc_o, the ebreak priv-level case) untouched.

Board `csr-regfile-dpccoal.json`: 52.60 → 52.60. NEUTRAL under the
analyzer because the binding cone is the single-step arm's 4-way
priority (ctrlflow sext(predict_address) concat cum-50.5 + nested
step_val selects), not the trap arms. Two redundant 64-bit concats
removed (area/fanout benefit in real synthesis regardless).

CONCLUSION for csr_regfile + hpdcache_ctrl_pe: local expression
transforms are exhausted; the dominant cost is always_comb program-
order serialization. The real fix is DECOMPOSITION into multiple
always_comb processes partitioned by output ownership, with shared
temporaries (st1_nop/st2_nop/nop/st0_req_is_p*/cz_*) promoted to
module nets driven by their own always_comb or continuous assigns.
ctrl_pe: always_comb spans L288-1285; every output verified written
only inside it → partition feasible but st1_nop/st2_nop hazard writes
are interleaved through ~15 sites each → dedicated session required
(E115-L4). csr_update (L3391-~3960) same class → new card E115-S3.

## r115 order-9: g6lc_loop_buffer always_comb split — LANDED, timing-NEUTRAL 46.91

IR showed the L284-346 next-state always_comb (~35 statements, 12 _d
signals) serialized program-order. Split by write ownership into two
always_comb replicating the identical flush/enable skeleton:
- Group A (capturing_d, armed_d, arm_epoch_d, base_d, base_hi_p1_d,
  end_d): flush/arm/fill-close/disarm arms only.
- Group B (data_d, body_len_d, fill_ptr_d, replay_d): flush/arm/
  fill-accept/consume arms only.
Per-signal last-writer order preserved statement-for-statement; every
_d still has exactly one driver; fill-close condition duplicated into
both blocks (shared by synthesis). No _d is read inside either block.

Board `loop-buffer-splitab.json`: 46.91 -> 46.91. NEUTRAL — the binding
cone is NOT statement serialization here but the genuine fill_accept
cone @L281: `capturing_q && fill_valid_i && addr_eq(fill_vaddr_i,
fill_low_sum) && (body_len_q < NR_EXT)` where addr_eq = 6-bit low EQ +
carry-muxed 58-bit hi EQ (base_q[63:6] vs base_hi_p1_q) = 22.5 FO4,
plus fill_low_lit 7-bit add 6.1, into capturing_d/body_len_d/fill_ptr_d
flops. The hi/lo split was already an intentional wide-adder avoidance
("one EQ, no range cone").

Next-session options for the 22.5 compare (all need contract proof):
(a) registered expected-address (fill_exp_q = base_q + ptr*8 updated in
    always_ff) collapses carry-mux but keeps ~58-bit EQ — marginal;
(b) relax hi-compare under an upstream in-order-fill contract — needs
    fill-stream producer verification, correctness-risky;
(c) accept ~46.9 as near-floor for exact-match fill accept.
Split retained: correct, single-driver, and is the decomposition
pattern E115-L4/E115-S3 need at larger scale.

## r115 order-10: hpdcache_mshr + g6lc_ai_exec cone analysis (no edit yet)

hpdcache_mshr 56.55 (in0->out0): hit_comb L269-289 is already tight —
per-way (mshrWays=2) dynamic read `mshr_cache_set_q[w*mshrSets +
check_set_st1]` prices as ONE opaque compare node w=32 @44.0 FO4
(dynamic part-select = barrel mux, width-proportional). v_match_set is
load-bearing (MSHR entries at [w][mshr_set] can hold different full
cache-sets sharing low mshrSetWidth bits — NOT redundant). Options:
explicit balanced mux tree on check_set_st1 bits (parametric-mshrSets
generation problem — case labels can't come from a loop; nested
ternary on index bits is the only clean form, ugly for M=16);
set-major storage reorder doesn't reduce per-way reads; registering
hit_o changes the miss-handling contract. DEFERRED — needs a dedicated
pass or acceptance as genuine CAM cost.

g6lc_ai_exec 45.60 (intoreg): binding node = AI_MVACC arm L951
`result_n = XLEN'(acc_get(acc_r_data, idx_rs2))` — acc_get is a
variable part-select `bank[elem*32 +: 32]` into a 2048-bit accumulator
bank (AccElems=64) = genuine 64:1 32-bit barrel mux ~28.4 FO4 "other".
Latency=0 combo-read is an ISA-visible contract (MVACC) — cannot
pipeline without contract change. AI instructions are not on the
OpenSBI/Linux boot path → deprioritized vs cache-side paths.
Exec decode always_comb L822-1193 (~370 lines) is the same monolith
class as ctrl_pe/csr_update if further cuts are needed (E115 card
candidate).

## infra: remote lint #2 queued

hyp8-integration-r115b-lint (scalar+MC, HYP8_LINT_ONLY,
HYP8_VERILATOR_DIR=verilator-v5.008-g6lc PGO fork) launched via WSL
proxy with closure _closure-r115b — now covers ALL r115 RTL deltas:
store_unit, g6lc_decode_s3, load_unit, wt_dcache_wbuffer,
csr_regfile, g6lc_loop_buffer. lint#1 (hyp8-integration-r115-lint,
pre-csr/loop_buffer closure) still running in parallel.
