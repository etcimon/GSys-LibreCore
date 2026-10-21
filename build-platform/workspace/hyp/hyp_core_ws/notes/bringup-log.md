# bringup-log.md — step 1: Verilator parse/elaboration of the hyp8 trees

<!-- hyp8-status -->
> **Status: indicative.** Goal of this step: both flists reach end of
> elaboration under Verilator lint. Warnings are recorded, not fixed.

Tool: `verilator_bin` 5.008 (`build-platform/workspace/tooling/verilator-v5.008-wsl`,
run under WSL — the toolchain is a Linux ELF).

**Environment note (important for future lint work):** this Verilator
build does **not** skip `pragma`/`synopsys`/`synthesis` `translate_off`
regions — it parses everything (verified with marker tests). Only
`` `ifdef `` / `` `ifndef `` fencing removes code. Consequences found so
far: `initial` blocks at package scope are illegal even inside
`translate_off` (package bodies always parse), and sim-only code inside
the fences must still be syntactically legal SystemVerilog.

Commands (expanded flists in `build-platform/workspace/lint_hyp8/`, outside
the identity-free trees — the `.vlt` files embed the absolute repo path).
`$WSL_REPO` = the WSL mount of the repository root (`/mnt/<drive>/<repo>`):

```
VL=$WSL_REPO/build-platform/workspace/tooling/verilator-v5.008-wsl/bin/verilator_bin
$VL --lint-only -Wno-fatal -Wno-PINCONNECTEMPTY -Wno-ASSIGNDLY \
    -Wno-DECLFILENAME -Wno-UNUSED -Wno-UNOPTFLAT -Wno-BLKANDNBLK -Wno-style \
    --top-module g6lc_core -f $WSL_REPO/build-platform/workspace/lint_hyp8/Flist_core.vlt
$VL --lint-only <same flags> --top-module g6lc_soc -f $WSL_REPO/build-platform/workspace/lint_hyp8/Flist_apu.vlt
```

(the `-Wno-*` set is the repo Makefile's lint set; `-Wno-SIDEEFFECT` is
omitted — unknown to 5.008.)

## Fixes applied (each row: file — error class — fix — design impact)

1. `core/include/g6lc64_hyp8_config_pkg.sv` — `initial` at package scope
   (illegal SV; package bodies parse under translate_off) — replaced the
   `initial assert` with an elaboration-time legality check: a constant
   function `hyp_cfg_check` (`$fatal` on `!hyp_cfg_ok`) evaluated in a
   `localparam` initializer — **design impact: no** (same condition,
   enforced earlier).
2. `core/csr_decode.sv` — adjacent string literals in `$fatal` (illegal
   SV concatenation) — single literal joined with `+` — **no** (inside
   the translate_off fence; sim-only).
3. `core/g6lc_decode_s2.sv` — block-item declaration after a statement
   (`fp_hit` was inserted above `automatic logic allow_replication`) —
   declaration moved to the top of the block, `automatic` kept verbatim
   from upstream `decoder.sv:625` — **no**.
4. `core/g6lc_decode_s3.sv` — `opfix` declared `fu_t`, assigned `fu_op`
   values (ENUMVALUE ×8, both directions) — declaration corrected to
   `g6lc_core_pkg::fu_op` — **no** (typo; every value used is a `fu_op`
   enumerator and the target field `.op` is `fu_op`).
5. `core/g6lc_decode_s3.sv` — `instruction_o.ex.tinst_i` member not
   found — field is `tinst` in `G6LC_EXCEPTION_T` — **no**.
6. `core/sb_lifecycle.sv` + `core/scoreboard.sv` — `writeback_t` used
   but never declared (it is a `parameter type` in the original
   scoreboard) — added `parameter type writeback_t = logic` to
   sb_lifecycle and `.writeback_t(writeback_t)` at the instantiation —
   **no** (restores the upstream injection seam; `g6lc_core` still
   defines the concrete type).
7. `core/sb_lifecycle.sv` — `smt_retired_count[sbe_hart(p)]++`
   (Inc/Dec of expression with side-effects unsupported) — rewritten as
   `= ... + 1'b1` — **no**.
8. `core/branch_unit.sv` — `fu_op`/`cf_t`/`ADD`/`NoCF` unresolved —
   added `import g6lc_core_pkg::*;` (same form as `sb_lifecycle`) —
   **no**.
9. `core/fetch_B/frontend.sv` — implicit `.rvi_*_i` / `.rvc_*_i` named
   connects pointed at nonexistent locals — explicit
   `.rvi_*_i(rvi_*)` / `.rvc_*_i(rvc_*)` (upstream style) — **no**.
10. `core/fetch_B/frontend.sv` — `'{default:'0}` on a packed struct
    containing an enum member (`ex`) — replaced with `'0` (bit-level
    reset, identical value) — **no**.
11. `tools/gen_g6lc_core.py` → `core/g6lc_core.sv` — `.HypCfg(HypCfg)`
    pinned onto `perf_counters`, which has no such parameter
    (PINNOTFOUND) — removed from the generator; module unchanged —
    **no**. Also `i_frontend.cf_type[...]` debug-window refs remapped to
    `iq_cf_type[...]` (the renamed per-slot cf array; inside the
    translate_off debug block) — **no**.
12. `core/Flist.g6lc_hyp8` + `Flist.hyp8_apu` — `g6lc_fetch_pkg.sv` was
    flisted after its consumers (`g6lc_fe_*`) → PKGNODECL — row moved
    ahead of `g6lc_fe_redirect.sv` in both flists — **no**.

## Result

- Core: `g6lc_core` — **0 errors**, 415 warnings after 5 iterations.
- APU: `g6lc_soc` — **0 errors**, 31 warnings on the first run (the APU
  flist consumes the fixed core files directly).

### Remaining warning classes

Core (415): WIDTHEXPAND 186, LITENDIAN 121, WIDTHTRUNC 52, LATCH 22,
IMPLICIT 18, MULTIDRIVEN 5, WIDTHCONCAT 4, UNSIGNED 3, SELRANGE 2,
PINMISSING 1 (`pc_commit_i` unconnected at an issue-stage instance —
deliberate draft seam), SYMRSVDWORD 1 (a `register` localname).

APU (31): WIDTHEXPAND 18, LITENDIAN 7, PINMISSING 3 (`clk_uncore` on the
legacy `g6lc_core_hb`/`g6lc_cluster` wrappers — not in the g6lc_soc cone
but flisted), WIDTHTRUNC 2, MODDUP 1 (module `g6lc_soc` vs package
`g6lc_soc` in `tb/g6lc_soc_pkg.sv` — package/module namespaces; benign).

Notable warnings to review at lint-hardening time: 22 LATCH
(mostly `g6lc_iq_bank` `upd.slot` / `any_older` — check whether the
incomplete always_comb coverage is intentional hold-state), 5
MULTIDRIVEN in `id_stage`/`g6lc_ooo_dispatch`.

## Blockers

None.

# bringup-log.md — step 2: measurement-driven structural rework (board-hyp8-r2)

<!-- hyp8-status -->
> **Status: indicative.** Structural FO4 measurement only (sv-timing
> delay-v44, 8-FO4 budget). Not STA; no simulation or synthesis.

Method: `analyze --modules` per module, rank-0 restructure (serial priority
loops / dynamic-index next-state patches -> per-entry compare vectors,
one-hot tournaments, balanced trees, masked-OR gathers, per-slot/per-field
assigns), re-measure, Verilator lint after each batch.

| file | error class | fix | design impact |
|---|---|---|---|
| core/sb_lifecycle.sv | structural billing (independent_lhs_bundle 95.4) | `mem_n` composed writer -> per-slot always_comb applying the same ordered events (alloc->fuNONE->wb(+pred)->cancel->violation->lu_replay->phys_replay->commit-free->flush) at a static index; last-writer gathers for alloc/wb ports; reclaim moved to own comb | no |
| core/sb_commit_bundle.sv | structural billing (intoout plain 135.2) | head-select reads the whole sb_mem_t through NR:1 muxes -> per-slot narrow vectors `sl_priv/sl_done/sl_issued/sl_valid/sl_cancel/sl_hart` at static indices | no |
| core/store_buffer.sv | structural billing (independent_lhs_bundle 88.4) | commit-queue ring walk (per-byte serial last-writer) -> A141 pairwise form: `rdist[i]=i-commit_read_pointer_q` as age rank, per-byte `win` = no younger candidate writes | no |
| core/issue_read_operands.sv | structural billing (independent_lhs_bundle 79.5) | FU-valid case loop -> per-bit decode assigns; stall/forward accumulate -> single-OR expressions over precomputed keep masks (G1o/G1an/G1ea/JALR/ss-RAW unchanged, CVXIF last-writer preserved); branch link-jal flush keep via `fuv_brkeep` | no |

Residuals documented in `analysis/board-hyp8-r2.md` (trigger_module
write-through FSM, sb_commit_bundle NR:1 selects, wt_dcache_wbuffer tx_stat,
multiplier P10-locked CSA recurrence, untouched modules list).

Verilator after batch: `g6lc_core` 0 errors / 439 warnings; `g6lc_soc` 0
errors. Bubble-up: 4 `drag` verdicts (NL/SEL/ARB/ISS) = architectural
decision-boundary registers, documented as accepted recurrences in the board.

# bringup-log.md — step 3: stage-guided rework toward 8 FO4 (board-hyp8-r3)

<!-- hyp8-status -->
> **Status: indicative.** Structural FO4 measurement only (sv-timing
> delay-v44, 8-FO4 budget). Not STA; no simulation or synthesis.

Policy: per-stage acceptance (`worst_in_stage <= stage_budget`,
`worst_into_stage <= (1+window)*8`); value-class rank-0 restructure first
(registered split authorized only if still >8 — deferred where it would
change wakeup distance); decision-class kernels rank 0/1 only, no new
register; residuals recorded with billed chain + artifact/real class.

| file | error class | fix | design impact |
|---|---|---|---|
| core/sb_commit_bundle.sv | structural billing (CB stage 124.8) | head one-hot masked-OR gathers already in place (r2 sl_* vectors + head_oh); residual = NR:1 select + min-tree + legality serial chain | no |
| core/trigger_module.sv | structural billing (TWR 112.3 / TMA 102.0, into 136.0) | TWR/TMA/TAC stage regions declared (r2); write-through FSM serial dependency recorded as real residual | no |
| core/cache_subsystem/wt_dcache_wbuffer.sv | structural billing (W2 122.1) | 13 `tx_stat_q[rtrn_id]` + 28 `wbuffer_q[rtrn_ptr]` dynamic reads hoisted to `rtrn_tx`/`rtrn_wb`; `use W2 on=` attribution; W3 split authorized, deferred | no |
| core/multiplier.sv | structural billing (S1 69.5, S2_5 serial) | S2_5 unrolled to explicit S2/S3/S4/S5 stage regions (one compressor level pair each); clmul serial XOR fold -> balanced pairwise XOR tree (also fixed a dead `i==XLEN` term); S1 `a_u*b_u[..]` billed atomic (model limit) | no |
| core/smt/g6lc_thread_select.sv | structural billing (88.1 -> 68.3) | RR candidate scan -> per-candidate compare vectors + first-set one-hot + masked-OR gather + pairwise strict-`>` argmax; `% NH` -> conditional wrap; composed writer -> p_policy/p_gate/p_drain/p_sel per-field assigns | no (decision-class, no register) |
| core/ooo/g6lc_iq_bank.sv | structural billing (SEL 86.7) | rank-0/1 already maxed in r2 (one-hot wakeup + masked-OR trees); residual = wakeup compare->hit-OR->arm->cnt-select cone, decision-class | no |
| core/ooo/g6lc_rename_read.sv | structural billing (77.3 -> 76.0) | pick chain -> per-port `lone_p`/`taken_lt` one-hot links; per-lane always_comb; res_br_inc/res_pick per-hart/per-port `$countones`; countones hoisted to named signals (Verilator 5.008 V3DfgPeephole internal error on `int'($countones())` inside compares) | no |
| core/ooo/g6lc_rename_recover.sv | structural billing (86.3 -> 74.7) | chained dynamic reads of ckpt_hart_q/ckpt_head_q/ckpt_cnt_q -> one-hot `lvl_oh` level decode + masked-OR gathers over transposed columns (`mis_hart_g`/`head_m`/`cnt_m`); wrap/clamp/`ckpt_slot` arithmetic unchanged | no |
| core/store_buffer.sv | structural billing (spec_fwd bundle 77.1) | commit-queue youngest-writer tree already in (r2); spec-side bundle floor 68.9 recorded | no |
| core/fetch_B/instr_realign.sv | structural billing (73.2 -> 60.9) | h->k nested match -> per-(slot,halfword) `rl_sel` crossbar + masked-OR gathers; split->carry via last-set one-hot `rl_coh`; carry continuation bank kept registered (svt-pipe no-cut, P10) | no |
| core/fetch_B/instr_queue.sv | structural billing (72.0 -> 46.1) | `gen_fifo_input` serial last-writer + popcount -> last-match one-hot `fsel_oh` + masked-OR field gathers + `$countones(valid & below_m)`; enum `|=` on `cf` -> logic-domain OR + `cf_t'` cast (ENUMVALUE) | no |
| core/load_unit.sv | structural billing (69.2) | FSM `state_d` unique-case already exclusive-billed; dep floor 69.2 = real serial FSM decode — recorded | no |
| core/csr_regfile.sv | structural billing (66.6) | 160-lhs / 540-write comb writer; per-region split pass deferred (bundle makespan billing) | no |
| core/ooo/g6lc_lsq.sv | structural billing (66.1 -> 73.2) | store-side event select/byte-enable hoisted out of the l×s pair scan (`s_sev/s_skn/s_addr/s_size/s_be` once per entry; `lbe`/`ev0_be` hoisted); physically shallower — merged cone bills +7 under the path model | no |
| core/alu.sv | structural billing (64.5) | `result_d` exclusive-case arms <=26.0; A3 registered split for LAT_ALU_FULL authorized, deferred (changes wakeup distance) | no |
| core/g6lc_decode_s3.sv | structural billing (55.8) | 69-lhs assemble/legality bundle makespan — recorded | no |
| core/sb_lifecycle.sv | structural billing (52.0) | dense_control_cone MixedSmt wdist arithmetic — recorded | no |

Whole-core `analyze --all-modules --stages` -> `boards/hyp8-core/analyze-r3.json`
(276 modules, 13846 paths; modules with paths 261, over 8 FO4 **176**,
failing paths >8 FO4 **5438**; overall worst `g6lc_ai_exec` 283.0,
AS-IS/out-of-cone). `correct --all-modules --stages --emit` ->
`emit/hyp8-core-r3`: **568 edits**, latency-neutral only
(`--allow-latency` absent), max_path 283.0->283.0, post_closes=false.

Stage acceptance: in-stage <= budget 12/45; into-stage <=(1+window)*8:
0/13 measured (all into-readings are unstaged `-` or cross-stage feeds at
window=0; no `window>0` stage carries a measured into-path violation).
Bubble-up: 26 covered / 4 absorbed (NL read-ahead verified; SEL/ISS
spec-wakeup verified; ARB spec-wakeup `unverified-cover` — countdown lives
in sibling iq_bank) / **0 drag**.

Verilator after the round (both trees, repo -Wno-* set):
`g6lc_core` 0 errors / 441 warnings (WIDTHEXPAND 218, LITENDIAN 121,
WIDTHTRUNC 54, IMPLICIT 18, LATCH 11, CMPCONST 7, WIDTHCONCAT 4,
UNSIGNED 4, SELRANGE 2, SYMRSVDWORD 1, PINMISSING 1; MULTIDRIVEN 0);
`g6lc_soc` 0 errors / 31 warnings (WIDTHEXPAND 18, LITENDIAN 7,
PINMISSING 3, WIDTHTRUNC 2, MODDUP 1).

## Step 4 — architectural round (inference-first; single whole-core measure)

Config-dead-branch guards made resolvable (rank 0): generate conditions
that referenced unresolvable localparams / package-function results were
rewritten to inline exact `G6LCCfg`/`HypCfg` expressions
(`sb_commit_bundle`/`sb_lifecycle`/`scoreboard` MixedSmt,
`store_buffer` LegacyFwd, `thread_select` MixedSmt — r3; `multiplier`
MSTAGES, `trigger_module` SDTRIG_MCH/SDTRIG_ICNT — r4). Under
`inputs/param-map-hyp8.json` the dead branches no longer bill.

| file | reading r3 -> r4 | what | cycles added |
|---|---|---|---|
| core/trigger_module.sv | 136.0 -> **79.2** | match cone reads `*_match_q` registered record copies; CSR write -> match visibility +1 (pipe serializes ahead of any fetched use); TWR write-FSM fold = real residual | +1 CSR->match visibility (fire +1 already at TAC) |
| core/multiplier.sv | 93.2 -> **52.0** | atomic tile `*` -> explicit PP generation: S1 = operand+corr capture, S2 forms 65 AND-rows + ~corr+1 (67 rows) into the same CSA ladder; LPS 2->3; MSTAGES inlined (dead branches pruned); per-row always_ff for rr_q | 0 (MultStages stays 8) |
| core/ooo/g6lc_rename_read.sv (+g6lc_rename.sv) | 76.0 -> **49.6** | banked picks FL_BANKS=HypCfg.FreelistBanks=2; per-lane static masked-OR of earlier same-bank takes; per-lane bank-miss stall | 0 |
| core/g6lc_decode_s3.sv | 55.8 -> **53.7** | exception_handling -> ex_assemble + out_assemble field groups | 0 |
| deferred with design | — | wbuffer W3, alu A3 (LAT_ALU_FULL->3), iq SEL registered CAM + ARB registered age matrix, rename_recover slot_of_level, csr_regfile per-bank split, load_unit one-hot FSM, thread_select policy register (residual 13.0 — likely unnecessary) | — |

Whole-core `analyze --all-modules --stages --param-map inputs/param-map-hyp8.json`
-> `boards/hyp8-core/analyze-r4.json` (modules with paths 262; over 8 FO4
**176**; paths >8 **4958**; paths >9.6 **4551**; overall worst
`g6lc_ai_exec` 283.0 AS-IS/out-of-cone).
`correct --all-modules --stages --emit` -> `emit/hyp8-core-r4`:
**272 edits**, latency-neutral, max_path 124.1->124.1, post_closes=false.

Stage acceptance: in-stage <= budget **13/45**; into-stage <=(1+window)*8:
0/11 measured (all into-readings unstaged or cross-stage feeds at
window=0). Bubble-up: **30 covered / 4 absorbed / 0 drag** — SEL/ISS/NL
covers verified; ARB `unverified-cover` (sibling-module countdown) as
before.

Verilator after the round (both trees, repo -Wno-* set):
`g6lc_core` 0 errors / **444 warnings** (WIDTHEXPAND 220, LITENDIAN 121,
WIDTHTRUNC 54, IMPLICIT 18, LATCH 11, CMPCONST 7, UNSIGNED 5,
WIDTHCONCAT 4, SELRANGE 2, SYMRSVDWORD 1, PINMISSING 1; MULTIDRIVEN 0);
`g6lc_soc` 0 errors / **31 warnings**. Lint repairs this round:
multiplier per-row rr_q always_ff (BLKLOOPINIT at NOPS=67),
decode_s3 `exception_t` type-parameter reference.

# bringup-log.md — step 5: the seven deferred items (board-hyp8-r5)

Correctness-seeking draft under lint-only verification, per the lead's
accepted policy: each item keeps its original cone as a `translate_off`
reference (or an equivalence assertion); contract changes recorded as
BU5 decisions rows and boot-hazards H33–H39. Whole-core analyze once at
the end only; Verilator both trees after each item.

## Per-item results

| item | file | r4 → r5 | implemented | cycles |
|---|---|---|---|---|
| 1 iq_bank SEL | `core/ooo/g6lc_iq_bank.sv` | 86.7 → 85.5 | registered wakeup CAM (`rsX_rdy`/`rsX_spec`); spec countdown −1; LAT_ALU_LOW narrow bypass; replay re-arm registered | real-WB +1, replay +1 (covered); spec select cycle unchanged |
| 2 iq_arb ARB | `core/ooo/g6lc_iq_arb.sv` | 63.1 → 65.9 | registered `older_q[i][j]` age matrix set at alloc / cleared at free; AND/OR tournament; `older_q == ooo_age_older` asserted | 0 |
| 4 rename_recover | `core/ooo/g6lc_rename_recover.sv` | 74.7 → 47.9 | `slot_of_level`/`ckpt_sel_q` push-time table; one-hot restore select; clamp-to-0 kept; arithmetic select asserted equal on `mispredict_i` | 0 |
| 6 wbuffer W3 | `core/cache_subsystem/wt_dcache_wbuffer.sv` | 124.1 → 124.1 (W3=11.6) | W2 decision/select; W3 coalesce+write; W3 record exported youngest; pending-wtag evict hold | +1 store→array; fwd +0 |
| 7 alu A3 | `core/alu.sv` + `g6lc_hyp_pkg.sv` | 58.7 → 71.1 | LAT_ALU_FULL→3; A3 shifter-2/compare-finish/result-mux; add/logic stay A2; A1-low forward unchanged | +1 shift/compare dependents (rank 5, H34) |
| 10 csr_regfile | `core/csr_regfile.sv` | 66.6 → 66.6 | two-phase writer: 15 address-exclusive `csr_wr_*` phase-A blocks → `*_w`; phase-B trap/xRET/irq/debug/counters verbatim order → `*_d`; `csr_update_ref` under translate_off, every `*_d` asserted equal | 0 |
| 11 load_unit | `core/load_unit.sv` | 92.4 → 77.2 | 10-bit one-hot FSM (`LU_B_*`/`LU_S_*`); per-state arms; encoded reference under translate_off asserted equal; `$onehot` under ifndef | 0 |

## r5 board (single end-of-round measure)

`analyze --all-modules --stages` → `boards/hyp8-core/analyze-r5.json`:
276 modules, 13,047 paths; 262 modules with paths; **176 > 8 FO4**;
failing paths (>8) **4833**, >9.6 **4420** (r4: 4958 / 4551). Worst
`g6lc_ai_exec` 283.0 (AS-IS, out of cone). Stages: **13/47** in-stage ≤
budget; 0/11 into-stage measured pass (all unstaged/cross-stage feeds at
window=0). New stages present: `alu.A3` 28.1, `wt_dcache_wbuffer.W3`
11.6. Residuals in board-hyp8-r5.md.

`correct --all-modules --stages --emit` → `emit/hyp8-core-r5`:
**275 edits**, latency-neutral, max_path 124.1→124.1, post_closes=false.

Bubble-up: **32 covered / 4 absorbed / 0 drag** (requirement met). SEL
cover re-verified after the registered CAM (cond updated to the
registered-wakeup text); NL read-ahead verified; ISS spec-wakeup
verified; ARB `unverified-cover` (sibling-module countdown) unchanged.

## Verilator after each item and at round end

Both trees linted after every item (`--top-module g6lc_core` /
`g6lc_soc`, managed Verilator 5.008, repo `-Wno-*` set). Final:
`g6lc_core` **0 errors / 444 warnings** (same total as the r4 baseline —
transient additions from csr/load_unit drafting were repaired);
`g6lc_soc` **0 errors / 31 warnings**. LATCH count 11 unchanged
(CSR PMP `index` warnings renamed). Lint repairs this round: CSR split
declaration/sideband/`rf_*` reference fixes, reference-region `logic`
prefix restoration, load-unit leftover enum literals → `LU_S_*`,
ref-region 4-bit casts for `LU_B_*` localparams.

No simulation, STA, synthesis or boot claimed. Equivalence assertions
are lint-parsed only; H38/H39 note this explicitly.

# Phase 6 — M1: mapped Yosys+OpenSTA Nangate45 board (sta-r5)

## Command

```
bun run build-platform/src/cli/index.ts timings sta-rtl \
  --target g6lc64_ooo --top g6lc_core \
  --flist build-platform/workspace/build/sta-rtl/hyp8.f \
  --platform nangate45 --target-mhz 5000 --fo4 0 \
  --remote --map-recipe streamed \
  --output workspace/build/sv-timing/hyp8-src/boards/hyp8-core/sta-r5
```

`hyp8.f` is the flattened manifest (absolute `E:/cva6/...` entries
expanded from `${HYP_CORE_DIR}`, tc_sram→stub substitution already
applied) — passing the raw `Flist.g6lc_hyp8` fails remotely because the
manifest builder does not expand `${HYP_CORE_DIR}`.

## Elaboration repairs (declaration order only — zero semantic change)

Remote slang (`--single-unit --best-effort-hierarchy`) rejected the r5
tree where Verilator did not. First remote attempt: 21 errors
(csr_regfile/ex_stage/iq_arb/lsq). An automated hoisting script then
corrupted `csr_regfile.sv`, `ex_stage.sv`, `g6lc_lsq.sv`; the three
files were restored from the remote synchronized copy via base64 (md5:
csr `2349a5f…`, ex_stage `6b67e57…`, lsq `01226f9…`) and repaired with
bounded edits instead. Fixes, iterated over local WSL `yosys
read_slang` (batch sizes 21 → 20 → 18 → 2 → 0):

- `csr_regfile.sv` — 12 `*_q/*_d`/`trap_to_*` decls above `csr_decode`
- `ex_stage.sv` — `alu_s2_a3`/`alu_s3_a3` + `ld_*_pack` above instances
- `g6lc_lsq.sv` — `ld_*_pack` projections above `g6lc_lsq_release`
- `g6lc_iq_arb.sv` — explicit cast, `bit[0:0]`→`fu_t` in struct literal
- `g6lc_ooo_dispatch.sv` — `iq_replay_v`/`iq_replay_t` above `i_iq`
  (first placement landed inside the port list — corrected)
- `wt_dcache_wbuffer.sv` — `e_*`/`w3_*` + `ni_inside`/`ni_conflict`
  decls above first use
- `g6lc_tlb.sv` — `rq_*_q` decls above `p_tlb_t1`
- `pmp_data_if.sv` — `if_fetch_vaddr_xlen` decl above use
- `instr_realign.sv` — `b_carry_ok`/`b_valid_b` decl above `b_complete`
- `g6lc_fe_nextline.sv` — `cursor_idx` multi-line decl hoisted (its
  `assign` stays after `cursor`); one transient split repaired
- `sb_head.sv` — `!rst_ni || flush_i` split to `!rst_ni` /
  `else if (flush_i)` in both `always_ff` (slang reset-condition rule)

Post-fix: local slang 0 errors; Verilator `g6lc_core` 0 errors,
`g6lc_soc` 0 errors — both trees stay lint-clean.

## Remote environment fixes

- `sudo -n chmod 1777 /tmp` on `ovh_calltorch` — /tmp had lost its
  world-write bit (`drw-r--r--`), yosys `mkdtemp` failed.
- `~/.cache/g6lc-sta/g6lc64_ooo/mapped/` kept 461 stale netlists from
  older targets (`0001_cva6.v` etc.); `mapped/*.v` count (4508) vs
  `il/modules.tsv` (4047) tripped the flow's self-check. Stale
  `.v`/`.v.sha`/`.log` removed remotely; phase B then ran all-cached
  (4.4 s, `4047 ok cached`).

## Result

- s1-yosys-map **pass** (107 s netlist + 156 s streamed map, 4047
  modules, all `ok delay`); s2-openroad-sta **pass**; s3-calibration +
  s3-adjusted-fo4 **pass**.
- 101 modules measured (9 no-path); 80/101 over the 10-FO4 adjusted
  budget; worst `g6lc_iq_arb` 171.4 adj-FO4 (3.667 ns, 29 cells);
  budget-equivalent 218 MHz nangate45 / 233 MHz @fo4_ps=20.
- Refusals recorded: `g6lc_iq_bank` (all 8 instances `link failed`),
  `g6lc_rename_read/_resolve/_publish` (no measured cone),
  `trigger_module` (config-dead `SDTRIG=0`, not elaborated).
- Full write-up + structural-vs-mapped residual table:
  `hyp_core_ws/analysis/board-hyp8-r5-sta.md`.

No functional simulation performed; this is a mapped study-liberty
measurement only.

---

# Phase 6 — M2: remote Verilator harness `hyp8` (built, not yet run)

## Shape (no adapter module)

`g6lc_testharness` already exposes the stock-compatible boundary
(`clk_i`, `rtc_i`, `rst_ni`, `exit_o[31:0]`) and instantiates
`g6lc_hart`/`g6lc_core` internally, so no `ariane`-signature adapter was
needed: the hyp APU testbench is the top. New files (all outside
`workspace/hyp` except the fault supervisor):

- `verif/regress/remote/hyp8/Flist.hyp8_sim` — hyp core + APU flists only,
  top `g6lc_testharness`; `g6lc_soc.sv` excluded (Verilator 5.008 module/
  package name collision; harness does not instantiate it);
  `tb/common/spike.sv` excluded (SPIKE_TANDEM-only, needs UVM pkgs).
- `verif/regress/remote/hyp8/hyp8-build-harness.sh` — build recipe.
- `verif/regress/remote/hyp8/hyp8_tb.cpp` — stock `g6lc_tb.cpp` adapted:
  `Vg6lc_testharness`/`g6lc_testharness__DOT__`, `gen_std` core path,
  `NrHarts=1` (banked debug paths compile-gated off),
  `hyp_fe_override1/2_o` for the predictor-redirect diagnostics.
- `verif/regress/remote/testharness_proxy.py` — `FLAVOURS["hyp8"] =
  ("work-ver-hyp8", False)` + `build hyp8` → hyp8 build script.
- `hyp_redesign_corev_apu_8fo4/corev_apu/apu/g6lc_apu_fault_sup.sv` —
  new module satisfying the unconditional `../apu/` include in
  `g6lc_testharness.sv`.

## Build fixes (all elaboration/tooling, zero RTL contract change)

- CFLAGS: `+$SPIKE_INSTALL_DIR/include` (fesvr/dtm.h),
  `corev_apu/tb` (g6lc_tb_trace.h), `corev_apu/tb/dpi`.
- Deep-hierarchy C++ probes retargeted to the generated hyp model:
  - commit bundle: `issue_stage_i.__Vcellout__i_scoreboard__commit_instr_o`
    does not exist in the hyp root — replaced by
    `__Vcellinp__i_g6lc_rvfi_probes__commit_instr_i` (the same
    `scoreboard_entry_t[NrCommitPorts]` bundle feeding the RVFI probes).
  - `i_scoreboard.mem_q` → `i_scoreboard.i_sb_lifecycle.mem_q` (the
    r5 lifecycle split moved the array).
  - `sbe_w` derivation: hyp `sb_mem_t` has 4 flag bits
    ({issued,cancelled,replay,is_rd_fpr_flag,sbe}) not 3, and
    `NR_SB_ENTRIES=32` not 16 → `(words*32)/32 - 4`.
  - latent probe names repaired for consistency (`i_g6lc_mmu`); probe
    blocks remain compile-gated (`CVA6_MC_PC_PROBE_COMPILE`,
    `G6LC_TB_BANKED`).
- `build-platform/src/cli/commands/remote.ts` — `--flavour` is the
  proxy's selector (B/legacy/hyp8/ai-*), but `parseAiFlagErrors`
  rejected any non-AI name. Now: a non-`AI_FLAVOURS` value is stripped
  from the AI-knob flags and passed through to the proxy unchanged
  (`--ai-flavour` keeps strict AI validation). Pre-existing `bun test`
  failures (2, unrelated: ai-overlay pin, isolated-L2) unchanged;
  `tsc --noEmit` clean.

## Status

- `remote build hyp8` (WSL engine): **BUILD OK** —
  `/opt/testharness/work/work-ver-hyp8/Variane_testharness`
  (16,825,744 bytes; build.log warnings=0 errors=0 per script tail).
- `remote doctor`: host OK, riscv-gcc 14.2.0, spike present, stock
  `B` harness intact (cache).
- M3 corpus built locally with xpack riscv-none-elf-gcc 14.2.0
  (`-march=rv64imac_zicsr`/`rv64imafdc_zicsr`, `-T env/p/link.ld` /
  `link_verilator.ld`): `hyp8_smoke`, H30/H31/H33/H34/H3 hazard tests,
  and 97 riscv-tests `-p` ELFs (49 ui, 13 um, 19 ua, 9 mi, 7 si) under
  `build/sv-timing/hyp8-src/tb/tests/` + `elf/`.
- **Blocked**: `remote run` refused by the proxy overlap guard — four
  other `Variane_testharness` workloads occupy `ovh_calltorch`
  (ooocoh-t53×2, t59, t38; etimes up to 5 days). They are not ours to
  kill; M3 runs wait for a free slot.
