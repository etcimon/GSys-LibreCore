# r127 — FO4 census of the live hyp8 core and inferred strategies (analysis only)

No RTL changed. Nothing committed. Structural screen only: delay-v50 binary of record
(delay-v51 source rebuilt to a scratch target gives identical rows), fo4_ps=20, margin 0.2,
budget 8.0, argv of `r115/boards/core-all-r115` replayed on HEAD `e41453510`
(`reboard_current.py`). Not STA, not a boot result.

## 1. Ground facts established this pass

| Fact | Evidence | Consequence |
|---|---|---|
| 153 of the 283 board modules are elaborated in `g6lc_core`/hyp8 | `elab_hierarchy.sh` (Verilator `--xml-only`), `live-modules.txt` | 122 rows are board floor, not clock: `hpdcache_ctrl_pe` 75.8, `hpdcache_mshr` 56.5, `g6lc_ai_exec` 45.6, `bht` 42.2, `copro_alu`, `fpnew_fma_multi`, `g6lc_freelist`, `macro_decoder`, `g6lc_shared_tlb`, `g6lc_slice_*` |
| The MMU subtree is elaborated under `HypDefault`, not `Hyp8` | `load_store_unit.sv:423` instantiates `g6lc_mmu` without `.HypCfg`; XML: `g6lc_tlb TLB_STAGED=0`, `g6lc_ptw PDEC=0`, `g6lc_mmu STLB_DLY=0`, cell `i_ptw.gen_legacy_dec.i_leg_dec`; true since the first check-in | `TlbStages=3` / `PtwDecodeStage=1` have never run in the integrated core or any witness; `g6lc_ptw_leg_decode` (38.2, stitched 74.2 with `g6lc_ptw`) is live; the board's param map (`TlbStages 3`, `PtwDecodeStage 1`) describes arms the core does not elaborate |
| The deep profile does not reach the LSU or the D$ | `ex_stage.sv:1203` (`load_store_unit`) and `g6lc_core.sv:4107` (`wt_cache_subsystem`, which has no `HypCfg` parameter) pass none; with `+define+G6LC_HYP8_DEEP` eight modules keep the Hyp8 constant and `load_unit LU_EXPEND=0` | the r84d "deep" integration did not exercise `LoadExPubStages=2`; only the leaf did |
| `g6lc_fe_frontier.sv` (live) is not in `analysis/timing/hyp8-core.f` | flist diff vs `core/Flist.g6lc_hyp8` | unmeasured module |
| 32.6 % of live nodes are width-defaulted (billed at the 32-bit reference) | IR census | with an elaborated width map (`xml_width_map.py`, new and unvalidated producer) the defaulted share is 15.5 % and the ranking changes: `stb_fwd` 77.4, `g6lc_tlb` 60.8, `g6lc_fe_override` 55.5, `alu` 53.9 (xperm4), `g6lc_icache` 45.9, `fpnew_*` 49.0 rise; `g6lc_ptw` rr 36.0 → 21.6 and `controller` fall. Sensitivity run, not a board of record |
| Two row classes | what-if board with `load_per_fanout = 0` (`core-all-r127-v50-noload`) | **L** rows are select broadcast under the unbuffered load law: csr_regfile 52.6 → 21.0, loop_buffer 46.9 → 21.7, alu 40.6 → 16.1, ooo_dispatch 40.5 → 19.5, prf 35.6 → 12.6, ptw 36.0 → 19.5, iq_legal 31.3 → 15.5, multiplier 28.2 → 8.0. **D** rows are logic depth and do not move: rename_read 48.0, store_unit 41.0, decode_s3 40.3, instr_queue 38.0, stb_fwd 36.2, g6lc_iq 35.7, wbuffer 34.5, issue_read_operands 33.5, aes 33.5, wt_axi_adapter 31.5, load_unit 31.0, bp_ckpt 30.1, id_stage 30.0 |

Corrections to earlier records: r69 listed `g6lc_ptw_leg_decode` as not elaborated — it is, for
the reason above. The r68–r74 F14 "memory corruption" reading was already superseded in r76.

## 2. Live board (current tree, delay-v50, no width map)

Clock rule (live reg→reg): csr_regfile 52.6 · g6lc_loop_buffer 46.9 · load_unit 44.3 ·
wt_dcache_wbuffer 41.7 · alu 40.6 · instr_realign 40.5 · wt_axi_adapter 40.3 · stb_fwd 36.9 ·
g6lc_ptw 36.0 · wt_dcache_missunit 36.0 · g6lc_tlb 34.1 · g6lc_fe_override 32.5 ·
g6lc_bp_ckpt 32.3 · g6lc_iq_arb 32.2 · g6lc_iq_legal 31.3 · id_stage 30.7 · g6lc_iq_bank 30.1.
Presentation (in/out) rows above 35: g6lc_rename_read 51.0 · g6lc_decode_s3 44.5 ·
instr_queue 43.2 · store_unit 41.4 · g6lc_ooo_dispatch 40.5 · aes 39.9 ·
g6lc_ptw_leg_decode 38.2 · g6lc_iq 36.0 · g6lc_prf 35.6.
Largest stitched parent+child sums (upper bounds, `core-all-r127-v50.cross.txt`):
ptw.i_leg_dec 74.2 · csr_regfile.i_csr_counters 69.8 · mmu.i_ptw 67.7 · rename.u_read 67.0 ·
rename.u_recover 66.2 · iq.i_legal 62.7 · load_unit.i_lu_result 61.8 · dispatch.i_prf 57.8.

## 3. Forms measured on the instrument before any edit (`probes/*.sv`, same binary)

| Shape (source locus) | Current form | Candidate form | Reading |
|---|---|---|---|
| orc.b (`alu` L803/808) | concat of replicated reductions | per-byte generate | 35.2 → 2.4 |
| nested 64-bit guards, comb predicates (`csr_regfile` dpc/mepc/sepc) | nested `if` | one-hot selects, predicate replicated per byte lane | 27.5 → 13.1 |
| same, flat one-hot with ONE copy of each comb select | — | — | 31.7 (worse: each select still drives 64 loads) |
| 64-bit 2:1 with a comb compare select (`g6lc_mmu` L936, `g6lc_prf` L72, dispatch L1287) | `s ? a : b` | select replicated per byte | 25.1 → 5.5 |
| free-list pick (`g6lc_rename_read` L220/285) | reverse/select/isolate/reverse/select + mask→tag | lane-specialised lowest only | 43.4 → 28.4 |
| same | — | 9×8 group hierarchy, OR encodes | 43.4 → 18.3 |
| rank of a slot (`id_stage` L1508, `instr_queue` L268) | `$countones(v[i-1:0])` | `$countones(v & mask)` | 19.0 → 10.2 |
| slot→FIFO placement (`instr_queue` L268–275) | pointer + rank add per slot, indexed set | thermometer rotated by a one-hot pointer | 27.5 → 12.0 |
| ring winner (`stb_fwd` L336–349) | rotate, highest-set, `ptr + countones(hi-1)`, indexed read | slot order: split prefix isolates, one-hot read (A136/A144) | 46.3 → 21.9 |
| lowest-set index (`stb_fwd` L347) | `countones(hi - 1)` | OR encode of the one-hot | 19.2 → 3.5 |
| 5-deep 1-bit priority (`wt_axi_adapter` L762–767) | chained `!g` terms | flat prefix terms | 15.2 → 4.8 |
| predicate enabling a wide array write (`g6lc_loop_buffer` L281→353) | compare gates data and pointer | data written under the early terms, compare gates the pointer only | 31.5 → 20.7 |
| buffer pop (`load_unit` L1639→486) | muxed index, indexed clear | one-hot pop mask | 14.5 → 8.4 |
| privilege legality (`g6lc_decode_s3` L161–289) | recomputed per instruction | class one-hot × table cached on the CSR side (A134) | 22.8 → 3.0 |
| store data placement (`store_unit` L598) | function return (billed opaque 38.5 in the module) | per-byte one-hot AND-OR | 9.5 / 8.7 in isolation |
| register-file read | index | registered one-hot AND-OR | 5.5 → 35.0 (do not) |
| bypass select predecoded into a flop | late compare 15.2 | registered select | 26.0 (do not: a registered 64-load select is billed as launch) |

Confirmed on the real modules, on scratch copies outside the tree (`whatif-rank0-b`, same argv,
three files substituted in the flist; exactness argued by construction, no simulation run):
`alu` 40.6 → 32.9 (orc.b per byte; next limiter the 32-bit word shift L946, 26.0),
`wt_axi_adapter` 40.3 → 32.0 (flat return priority), `g6lc_iq_legal` 31.3 → 18.6, rr 15.2
(`h` folded to 0 under NH ≤ 1 at the L383 site; needs the `hart < NH` assertion).
Every other row of this table is a reading on an isolated shape, not yet on its module.

Instrument caveat: `{64{s}} & x` crosses the 64-load cap and is billed as buffered while
`s ? a : b` is not (`sv-timing/AGENTS-todo.md` open item (b)). Only the per-lane forms above
reduce real fanout; a whole-word AND-OR rewrite is a cliff artifact and earns no credit.

## 4. Strategies by execution path (caller → module), in order of value per effort

Rank 0 = representation, exact, existing leaves suffice. Rank 1 = one register with both-end
ownership. Rank 2 = caller contract change (knob + legality + latency table + witness).

**Configuration first (wiring, but a new functional configuration).** Pass `.HypCfg(HypCfg)`
at `load_store_unit.sv:423`, `ex_stage.sv:1203`, and add the parameter to
`wt_cache_subsystem`. Removes `g6lc_ptw_leg_decode` from the design (the 74.2 stitched cone)
and makes the TLB/PTW rows on the board the rows of the design. It moves the DTLB/ITLB
answer two cycles and the PTE verdict one cycle in the integrated core for the first time:
smokes plus a boot witness are required; do not fold it into a timing batch.

**Commit → CSR (csr_regfile 52.6, class L).** Callers: `commit_stage`, `controller`,
`csr_buffer`. (0) Split `csr_update` by output family (E115-S3) and replicate the trap/debug
select predicates per byte lane for the 64-bit registers (mepc/sepc/dpc/mtval/stval/pmpaddr):
52.6 → ≈ 25–30 expected. (1) Trap-write record: register `{take_ex, target-priv one-hot, pc,
cause, tval}` at the trap edge and write xEPC/xCAUSE/xTVAL/dpc one cycle later (A105 item 3
argument: the handler cannot read them sooner than the redirect latency); declared knob
`CommitStages`.

**Rename R1 (g6lc_rename_read 51.0, stitched 67.0, class D).** Callers: `g6lc_rename` →
resolve → publish → dispatch. (0) Lane-specialise the pick direction (the constant `high`
still builds both orders) and replace the 72-wide isolate + mask→tag by a group hierarchy of
OR encodes (no arithmetic: the r115 countones forms are the countercase). (1)
`FreelistPickStages=2`: registered pre-picked tag per lane, two candidates deep so
back-to-back allocation is served (A107 "registered free-list head", A119 `(any, many)`).

**Fetch (instr_queue 43.2, instr_realign 40.5, loop_buffer 46.9, fe_override 32.5).**
(0) instr_queue: one-hot write pointer + thermometer placement; id_stage rank masks.
(0) loop_buffer: unconditional slot write, compare gates the pointer. (2) realign: target per
halfword position (A108 option) only if the fetch rows still set the clock afterwards.

**Decode (g6lc_decode_s3 44.5, stitched 55.1 into id_stage).** (0) legality as predecoded
class one-hot × CSR-side cached table; needs the proof that every CSR write changing the
table flushes younger decode. (1) exception payload assembled after the id register.

**LSU (load_unit 44.3, store_unit 41.4, stb_fwd 36.9, wbuffer 41.7, missunit 36.0,
wt_axi_adapter 40.3).** (0) stb_fwd slot-order winner; store_unit per-byte lanes;
wt_axi_adapter flat return priority; load_unit one-hot pop and flat per-target-state terms
for the IDLE decision nest (the 29.8 `state_d` write is guard broadcast). (1) registered
store-forward coverage verdict under `StoreFwdCycles>1`; `LoadPubStages=2` as a
caller-selected module (r80 rule). (2) wbuffer versioned pending writes (Batch E).

**Issue/operands (g6lc_ooo_dispatch 40.5 + g6lc_prf 35.6, stitched 57.8; g6lc_iq 36.0;
iq_arb 32.2; iq_bank 30.1; iq_legal 31.3).** (0) per-byte replicated bypass selects in
dispatch and prf; `g6lc_iq_legal` L383 `h = info_hart_i[b][e]` is a constant for NH=1 —
fold it under NH ≤ 1 (measured 31.3 → 18.6 on a scratch copy). (1) `IqSteerStages=2` (r76 §B2). (2)
`IqSelStages` last, IPC-gated.

**Execute (alu 40.6, aes 39.9).** (0) orc.b per-byte; xperm as per-nibble one-hot lanes
(the width-map run puts xperm4 at 43.0). (1) `AesStages` (declared 1|3) with the FLU
distance table; ZKN is off the boot path.

## 5. Order and gates

1. Instrument: add `g6lc_fe_frontier.sv` to the timing flist; decide the width map of record
   (validate `xml_width_map.py` against `tools/rtlil_width_map.py` on one module first).
2. Rank-0 batch, one board per item, keep only on a measured drop: alu orc.b · iq_legal NH
   fold · wt_axi_adapter priority · stb_fwd winner · instr_queue placement + id_stage rank ·
   rename_read pick · store_unit lanes · dispatch/prf/mmu sliced selects · loop_buffer fill ·
   load_unit pop. Gate: existing leaves, lint, the 12 smokes cycle-identical.
3. HypCfg propagation as its own functional step with a witness.
4. Rank 1: csr trap-write record · decode table · FreelistPickStages · IqSteerStages.
5. Rank 2 only if the board still asks: IqSelStages, wbuffer Batch E, realign per-position.

Files of this pass: `reboard_current.py`, `census.py`, `elab_hierarchy.sh`,
`xml_width_map.py`, `params-mmu-hypdefault.json`, `params-hyp8-full.json`,
`params-hyp8-expub2.json`, `width-map-elab.json`, `live-modules.txt`, `probes/`, `boards/`
(untracked; the v51 board and the what-if IR dumps were pruned after their top tables were
saved, since v51 equals v50 row for row). Scratch outside the tree (gitignored):
`build-platform/workspace/build/{svt-v51-target,svt-noload,hyp8-elab-r127,hyp8-elab-r127-deep}`.

## 6. Implementation status (r127 working tree, uncommitted) — details in `worklog.md`

Boards: `core-all-r127-final5` (tree == closure-r127y) vs `core-all-r127-v50` (same argv); the
final5 clock-rule worst is 37.0 (load_unit; +0.1 from the staged-MMU term the analyzer bills
although it folds away at TlbStages=1). Whole-board worst
52.6 (csr_regfile) → 36.9 (load_unit reg→reg). Live clock rule now: load_unit 36.9, ptw 36.0,
csr_regfile 35.3, instr_realign 34.5, tlb 34.1, wbuffer 32.9, alu 32.9, fe_override 32.5. Every kept core edit passed the remote integration
(lint scalar/smt2 0 %Error, 12/12 smokes at the r126 cycle counts: tags r127, r127b, r127c,
r127d, r127e, r127f, r127g, r127h, r127i, r127k, r127m).

| Census item | Status | Row before → after |
|---|---|---|
| Config: HypCfg to MMU/LSU/D$ | done; default binding keeps the unstaged MMU. Staged MMU (`G6LC_HYP8_MMU_STAGED`): wedged in Linux at the first translated load; root cause = a 3-cycle load-FSM livelock (the ABORT state's one-cycle hole in `translation_req_o` against a TLB that answers two cycles late) plus an answer/request pairing gap; FIXED in `load_unit.sv` + `g6lc_mmu.sv` (both hunks fold away at TlbStages=1). New smoke `hyp8_sv39_load` reproduces it in 4k cycles: staged target 13/13 after the fix (r127r), wedge before (r127q). Staged witness running; stays off by default until it boots | — |
| csr_regfile lanes/split (rank 0) | done: epc lanes, pmp write lanes, pmp generate, PMPADDR read | 52.6 → 35.3 |
| csr trap-write record (rank 1) | not done | — |
| rename_read pick (rank 0) | done (group hierarchy); checkpoint-slot arm reverted (worse) | 51.0 → 40.2 |
| FreelistPickStages (rank 1) | not done | — |
| loop_buffer fill (rank 0) | done as an exact enable fan-out (the unconditional write is not bit-exact at `data_o`) | 46.9 → 26.9 |
| instr_queue placement (rank 0) | closed without edit: no exact form with a drop | 43.2 |
| id_stage rank | done | 30.7 → 14.7 |
| instr_realign (rank 0 part) | done (registered availability); per-position targets (rank 2) not done | 40.5 → 34.5 |
| decode_s3 legality table | not done (needs the CSR-write flush proof) | 44.5 |
| stb_fwd slot-order winner | done | 36.9 → 25.6 |
| store_unit per-byte lanes | done (sweep 22,272 cases + negative control; remote gate r127f 12/12) | 41.4 → 22.4 |
| wt_axi_adapter priority | done | 40.3 → 32.0 |
| wt_dcache_missunit lanes | done | 36.0 → 29.6 |
| load_unit pop / arms / ex_ctx_ok (rank 0) | done | rr 44.3 → 36.9 (any 43.2, in→reg nest) |
| load_unit registered verdicts, LoadPubStages (rank 1) | not done | — |
| wt_dcache_wbuffer | head-match + merge-select on the CAM bit done (one-match invariant asserted) + forward pick split; versioned writes (rank 2) not done | rr 41.7 → 31.4 (any 39.5 → 37.7) |
| dispatch / prf / mmu sliced selects | done | 40.5 → 28.3 · 35.6 → 19.2 · 31.6 → 24.6 |
| iq_legal NH fold | done | 31.3 → 18.6 |
| IQ steer | rank-0 slot-order attempt reverted (worse). `IqSteerStages=2` implemented as an off-by-default knob (`G6LC_HYP8_IQSTEER2`, target `g6lc64_hyp8_iqsteer2`): arm-only boards in→out 36.4 → 27.4, in→reg 32.3; smokes 12/12 on both bindings; no boot witness. IqSelStages not done | default board row 36.0 → 37.1 (both arms billed + one alias hop; arm-only default 36.4) — a rise, kept only for the knob |
| alu orc.b | done; xperm lanes not done | 40.6 → 32.9 |
| AesStages | not done | 39.9 |

APU groups (`apu-*-r127-final` vs `apu-*-r127`; none of these modules is elaborated in the
scalar hyp8 SoC — measured on the pinned toolchain — so the evidence is unit benches and
miters, not SoC smokes): ai board worst 149.0 → 71.5 (desc_engine 46.5 → 34.8; gemm_arplan
149.0 → 59.0, a module instantiated nowhere); coh 123.3 → 62.6 (clock rule; inval_bus 123.3 → 33.9,
coherence_hub 121.6 → 66.1, snoop_filter 41.1 → 27.2); l2 59.9 → 52.7 and l3 62.7 → 55.5
(l2_top). cluster_dispatch 34.3 → 25.6. Excluded as non-design (instantiated by no RTL; bench-only SKU
models or a sim-only FP model): ai_fp_dot 271.5, ai_cluster_set 71.5, ai_cluster_tile, ai_fp_mac,
ai_gemm_arplan. Not reduced: gemm_seq 52.0, island_top 43.9, l2_mshr 39.8 (attempt reverted), l2_tag
(disabled `gen_pf` arm the analyzer does not fold).

Later additions (after the r127m report; all in `worklog.md`): `g6lc_tlb` PLRU victim masks rr
34.1 → 22.9 (r127o); `g6lc_ai_cluster_dispatch` 34.3 → 25.6; `g6lc_ai_gemm_seq` 52.0 → 51.0;
deep profile (`LoadExPubStages=2`) smoke-gated (r127n) with a witness running; smoke set of
record is 13 tests (adds `hyp8_sv39_load`, the only one that enables translation).

Status after closure-r127y (see `worklog.md` "RESUME HERE (state while r127x is building)" and
later entries): additional kept edits — `g6lc_tlb` PLRU victim masks (rr 34.1 → 22.9), `aes`
rotate/subword forms (39.9 → 35.5, miter-checked), `g6lc_ai_cluster_dispatch` (34.3 → 25.6),
`g6lc_ai_gemm_seq` (52.0 → 51.0), `g6lc_l2_top` collector position (l2 board 52.7 → 49.5),
`g6lc_shared_tlb` flush-walk gates removed (mmu leaf green again, locally and on the pinned
toolchain: `HYP8_MMU_PASS checked=716`). Staged-MMU fix = three hunks (`load_unit.sv`
`tr_abort_hold` + PA-capture window, `g6lc_mmu.sv` answer/request pairing); staged target
13/13 (r127x) with the new `hyp8_sv39_load` smoke; the first staged witness after hunk 2
stopped on `g6lc_pa_now_eq` at the first translated kernel load; hunk 3 fixed it and the
staged witness `hyp8-osbi-scalar-r127x-mmustaged` now runs into the Linux kernel (`Linux version`
on uart, past the old wedge, no error). The staged MMU stays off by default. Reverted as null/worse since: pe_dot_float_pipe tournament (80.2),
hub fire copy, rename ckpt general arm and room hoist, island_top submit lanes.

r127-t update (APU continuation; details in `worklog.md` "r127-t"): `g6lc_ai_gemm_seq`
51.0 → **49.6** (shared `mac_quiet` predicate; `w_fetch_needed` threshold-compare
neutral-kept; new limiter = protocol-serial rd_sel→bank-demux chain, exact floor).
`g6lc_ai_pe_dot_float_pipe` flag loops → packed reductions, row-neutral 38.8
(L571 exp_min tournament remains). `g6lc_l2_mshr` priority-tree rewrite
**countercase** (39.8 → 64.8 packed / 760 unpacked-array variant) — reverted;
APU boards bill priority-encode rewrites worse than serial scans (opposite of
core-board selection wins). Dead rows confirmed: `g6lc_ai_gemm_arplan` 59.0,
`g6lc_ai_gemm_fp32_add`/`_norm` 44.1/`_align` 36.7 — no instantiator, unit-board
evidence only. `g6lc_coherence_hub` — r127v slot-centric B/R demux **LANDED**: exclusive_case_mux
66.1 -> **38.8**, plain worst 64.0 -> 62.2 (overall ~62.2); bench = baseline.
Prep always_comb computes (slot->core) binding + fast/park/fire; consumer loops
are single-level constant-index. New limiter = plain 62.2 on the AW-grant ->
invalidation-fire request path (`aw_fire/aw_grant/aw_ot_full/coh_inv_fire_o/
do_stamp`). Parse lesson: sv-parser rejects unparenthesized `!|` (use `!(|x)`) —
that, not nested-for depth, was the r127u blocker.
`ai_fp_dot` 271.5 behavioral; `ai_cluster_set` 71.5 P10-locked — both stand.
- r127-t (cont.): `g6lc_l2_top` head-entry CSE rr **52.7 -> 50.1** (5/5 l2 bench
  configs PASS). `g6lc_ptw` PDEC arm confirmed dead at `PtwDecodeStage=0`
  (default); live target is `g6lc_ptw_leg_decode` 38.2. `csr_regfile` fp_live
  registered form = contract change, deferred.
- r127-t (final boards `apu-ai/l2/l3-r127t`): gemm_seq 51.0 -> 49.6;
  l2_top worst-config 55.5 -> 54.5 (l2 params +0.6 recorded); fp32_norm 44.1
  confirmed LIVE via fp32_add_p2 (only arplan 59.0 is dead). fp32_norm barrel
  shift = next ai target.
- r127-t (fp32_norm barrel shift): the `subnormal_fraction = magnitude <<
  sub_shift` clamp was already landed (5-bit `sub_shift`, ec>=24 -> 22; term is
  masked to zero whenever `|subnormal_hit` is false). The residual 44.1 limiter
  is NOT the shift — it is the `corr -> diff_yx(_carry) -> magnitude ->
  leading[b] -> normal_hit -> gen_normal_or -> finite_result` serial chain: a
  24-bit subtract (`diff_yx_xor + diff_yx_carry`) feeding a 25-way
  leading-one priority (`leading[b] = magnitude[b] && !(|magnitude[24:b+1])`)
  feeding a 5-level masked-OR tree. `fraction[b]` for b<24 is a *constant*
  shift (free wiring); only b=24 uses `rounded`. No exact latency-neutral
  rewrite found that does not re-bill the suffix-OR / adder depth — candidate
  contract = registered leading-position or a shared prefix-OR (changes the
  align->norm boundary latency). Deferred with the other contracts.
- r127-u APU exact-frontier survey (systematic, all live rows read at node
  level): the latency-neutral FO4 frontier in the APU is **reached**. Every
  remaining live row is one of: (a) a serial `plain` dependency/qualify chain
  whose only fix is a pipeline stage (contract); (b) P10 handshake-locked
  (coherence_hub `inv_ot_d` AW->inval stamp 62.2); (c) a dependency floor
  (island_top `rdata_n` exclusive_case_mux deflates 89.5->24.3 but makespan
  floor 43.9); or (d) dead/non-synthesizable (`ai_fp_dot` 271.5, `ai_cluster_set`
  71.5, `gemm_arplan` 59.0). Per-row contract spec for the not-done set:
  - `l2_top` ~54.5 worst-config: `collect_idx=fifo_q[collect_pos]` ->
    `fill_state_q[collect_idx]` double dynamic-index into `collect_active`/
    `is_fill_beat`/`mst_req_o.r_ready`/`rdtrk_grant`, and the same shape at
    `issue_idx`. Contract = parallel `fifo_state_q[pos]` snapshot OR registered
    fill-state resolve; needs an mshr->position reverse map or write-back —
    data-structure change, verify with `run_l2_bench.sh` (5 configs).
  - `gemm_seq` 49.6: protocol-serial `w_fetch_needed -> rd_sel_store ->
    rd_sel_pair -> c_rx_req/c_r1_req -> c_rx_bank -> c_rx_data -> bank read`
    qualify chain + store handshake. Contract = registered read-select or bank
    prefetch; verify with `run_gemm_gate.sh`.
  - `island_top` 43.2: submit-source priority mux (`sb_imm_submit/l_sb_imm ->
    submit_src_sb_mux -> submit_*_mux`) + `cpl_push_ticket/cpl_room_free`.
    Contract = registered submit-source; verify with `run_island_gate.sh`.
  - `pe_dot_float_pipe` **80.2 -> 37.2** (r127-ab, board `apu-pdf`/`params-ai.json`
    Lanes=512 = production `AI_LIVE_MACS`): the exponent-min tree is LEVELS=9
    deep over 512 lanes and was split S1=3 / S2=6 levels; S1's makespan is the
    per-lane FP multiply (~27), not the exponent cone, so it had slack while
    S2's 6-level tail tournament was the 80-FO4 bottleneck. Fix = rebalance
    `EXP_GROUP_LEVELS` to an even split for deep trees
    (`(LEVELS<=6)?min(LEVELS,3):(LEVELS+1)/2` -> 5 at LEVELS=9; keeps r94 cap
    for shallow trees). **LATENCY-NEUTRAL**: same pipeline depth, same
    `s2_block_exp_q` capture edge, identical min value — guarded by the
    `s2_block_exp_d == ref_min` assertion. Verified `run-pe-dot-float-pipe.sh`
    **PASS Lanes=512 transactions=5028 checks=5028 latency=13** (latency
    unchanged; `LATENCY`/`vld` untouched). New 37.2 limiter = `final_result` ->
    `bfp_mant_exp_to_fp32` output pack (separate floor). NOTE the prior
    "38.8" census figure came from `apu-pedot-t1` (small-Lanes board); the
    production-params board `apu-pdf` was always 80.2 — this row was
    UNDERSTATED. A prior tournament rewrite was reverted (80.2, serial-billed);
    the worklog's own next-step note ("move tree levels into S1 via
    EXP_GROUP_LEVELS") is exactly what landed here.
  - `l2_mshr` 39.8: free-entry priority pick — TWO priority-tree rewrites
    already countercased (39.8 -> 64.8/760); treat as exact floor unless a
    different structure (e.g. free-list stack) is chosen — that is a
    data-structure contract.
  - `coherence_hub` 62.2: AW-grant -> `inv_ot_d` invalidation stamp, P10-locked
    (same-edge pulse+index). Contract = registered invalidation stamp; needs
    hub bench re-run (`run_hub_bench.sh`) — highest remaining APU row.
- r127-y/z **unmeasured-live-module sweep** (board `apu-unmeas-r127a` -> `-r127z`):
  the earlier APU boards omitted four live leaf modules. Confirmed instantiated:
  `g6lc_l2_pf` inside `g6lc_l2_top` `if (PF_EN)` (l2_cache/g6lc_l2_top.sv:~1288),
  `g6lc_server_prefetcher` inside `g6lc_cluster.sv:~714`, plus
  `g6lc_l3_inclusive_inv` 15.6 and `g6lc_axi_lrsc` 9.9 (both under budget).
  Baseline worsts: **`g6lc_l2_pf` 172.9** (was the single highest FO4 anywhere in
  the APU) and **`g6lc_server_prefetcher` 76.5**.
  - `g6lc_l2_pf` **172.9 -> 143.1** (board `apu-unmeas-r127y`), two exact
    transforms, both Verilator-miter proven then `L2TB_MODE=pf` bench
    `RTL_REVIEW_PASS l2_pf` (issue=7 useful=2 drop=5; oracle_negative diverges
    as designed):
    (a) emit-path `stride * ahead` atomic Mul (~87 FO4) -> per-bit shift-add.
        `ahead` is PW bits so the product is the sum of `stride*2^b` over set
        bits; `es` sign-extends stride to EM_W=DLT_W+PW+2 *before* shifting
        (a bare `stride<<<b` wraps at DLT_W). **Multiply-semantics lesson:**
        `LINE_BITS'($signed(stride)*$signed({1'b0,ahead}))` is evaluated at the
        cast's 58-bit context -> the *true* product, NOT a self-determined
        PROD_W truncation (Verilator-verified: stride=-26,ahead=3 gives -78,
        not +50). A first PROD_W=7 attempt was wrong and is what the miters
        caught. Product miter: 2048 cases 0 err.
    (b) `in_page(em_base,last)` 52-bit page-field compare -> within-page range
        test `!(|xs[EM_W:PAGE_LBITS])` on `xs = sext(last[PAGE_LBITS-1:0]) +
        em_prod` — does not wait on the 58-bit `em_base` add. ipage miters:
        196,608 + 262,144 cases 0 err (incl. LINE_BITS wrap edges).
    Residual 143.1 = serial `train_hit` match-scan -> `es`/`em_prod` -> `xs` ->
    emit-guard (`!cnd_vld_d && valid && pend && !(retrain)`) -> `st_d[em_s]`
    demux write. Contract-limited: needs registered `train_hit_idx`/emit-select
    (latency change) — deferred with the other contracts.
  - `g6lc_l2_pf` **143.1 -> 138.8** (board `apu-unmeas-r127aa`), r127-aa
    PARALLEL EMIT-EVAL rewrite (still latency-neutral): the serial early-exit
    `for k` walk (`em_s=(rr_q+k)%N`, dynamic `st_q[em_s]`/`st_d[em_s]` barrel
    muxes) replaced by constant-index per-stream evaluation (`for s`,
    `st_q[s]` flop reads) + rr-position winner priority + per-stream
    constant-index `st_d` writes. Semantics preserved exactly: first
    armed+in-page stream in rr-order emits; armed page-bound streams before it
    get pend=0; streams after it untouched; retrained stream never a
    candidate; works for any NR_STREAMS (compare+add position, no pow2
    assume). **Miter-verified: 11M randomized cases (NR_STREAMS=4: 8M, =3:
    3M), 0 mismatches on cnd_vld_d/cnd_line_d/rr_d/full st_d**
    (`analysis/r127/probes/miter_l2pf_emit.sv`). Gates: `L2TB_MODE=pf`
    `RTL_REVIEW_PASS l2_pf` (issue=7 useful=2 drop=5 = baseline) + full l2
    bench **5/5 configs PASS** (r127aa). Gain is modest (-4.3): the emit
    arithmetic (`es->em_prod->xs->em_bs`, ~56 FO4) is inherent per-stream and
    now on the path once for the winner — the dynamic-index muxes were only
    ~4 FO4. Residual 138.8 = match-scan -> per-stream emit arithmetic ->
    winner-priority -> apply chain; the real reduction needs a registered
    emit-select / candidate pipeline stage (contract, `insert_reg` per the
    board's own opportunities list).
  - `g6lc_server_prefetcher` **76.5 -> 74.5** (board `apu-unmeas-r127z`):
    `delta = signed'(demand_line - st_q[s].addr)` 64-bit subtract narrowed to
    `demand_line[31:0] - st_q[s].addr[31:0]` — `(a-b) mod 2^32` needs only the
    low 32 bits, bit-identical, halves the carry chain on the match path.
    Residual 74.5 = serial demand_ar -> demand_line -> per-stream
    delta/compare/alloc -> pf_addr -> pf_addr_d chain (contract-limited).
    Dedicated `tb_g6lc_pf` (run_pf_review.py) tests response-ownership, not the
    delta arithmetic; change is exact by construction (mod-2^32 narrowing).
    NB: `demand_line[31:0]`/`addr[31:0]` assume AXI_ADDR_WIDTH>=32 (default 64;
    de-facto invariant for an AXI address bus).

## r127-ac — latency-neutral frontier: analytical closure (core + APU)

Swept **every** `exclusive_case_mux` path in the live boards for a remaining
`balance_mux` win. Result: **none exists.** For each path the analyzer's own
`dependency floor makespan` equals `total_fo4` while the `deflated` mux value is
far lower — i.e. the critical path is a *serial dependency chain*, not the mux
cone, so balancing the mux cannot move the makespan:

| module (core-all-r127-final6) | total | floor | deflated |
|---|---|---|---|
| g6lc_ptw_leg_decode L154 | 38.2 | 38.2 | 20.1 |
| bht L230                    | 36.6 | 36.6 | 13.2 |
| g6lc_rename_read L437       | 35.7 | 35.7 | 25.0 |
| load_unit L1084             | 34.8 | 34.8 | 29.8 |
| axi_adapter_arbiter L769    | 31.4 | 31.4 | 19.2 |
| g6lc_fe_redirect L184       | 30.0 | 30.0 | 16.8 |
| multiplier L678             | 28.2 | 28.2 | 26.5 |
| g6lc_rob L118               | 27.1 | 27.1 | 12.0 |

Same signature on the APU (`g6lc_server_prefetcher` path 14: makespan 67.0 >
deflated 24.8; `g6lc_l2_pf` residual is a serial match->emit chain). The only
non-floor `exclusive_case_mux` rows left are sub-20-FO4 crumbs.

**Conclusion:** latency-neutral (exact) FO4 reduction is *complete* on both the
core and APU live boards. Every residual worst path is `plain` serial
dependency, `independent_lhs_bundle` makespan, a dependency floor, or a P10
handshake lock. All further reduction is contract work — pipeline stages
(`insert_reg`), data-structure redesigns (free-list/snapshot/reverse-map), or
handshake changes — each specified per-row above and in the module notes. These
move same-cycle consumers on correctness-critical paths and require dedicated
implementation + remote smoke/witness gating; they are **not done**.

## r127-ad — live/dead census refinement + contract-boundary trace

Re-derived the live APU row set from the freshest boards
(`apu-ai-r127-final3`, `apu-l2-r127-final3`, `apu-coh-r127-final2`,
`apu-unmeas-r127aa`) and traced each high row to its register boundary.

**Refined live high-FO4 rows (all contract/floor — none latency-neutral):**

| module | FO4 | class | contract obstacle (traced) |
|---|---|---|---|
| `g6lc_l2_pf` | 138.8 | plain | emit+train+candidate share one `st_q` snapshot, disjoint-but-coupled `st_d` writes; split breaks atomicity (stale `pend`/`ahead`) → registered emit-select/candidate pipeline |
| `g6lc_server_prefetcher` | 74.5 | plain | worst path is `st_q→match→st_d→st_q` stream-state update (exclusive_case_mux floor 67), NOT input→match — input pipeline doesn't split it |
| `g6lc_coherence_hub` | 62.2 | plain | AW-grant→`inv_ot_d` invalidation stamp, P10 same-edge pulse+index lock |
| `g6lc_l2_top` | ~50 | plain | S_TAG miss-commit → `fifo_q[collect_pos]`→`collect_idx`→`fill_state_q[collect_idx]`/`fill_buf_d[collect_idx]` double dynamic-index; fix = fifo_state snapshot / mshr→pos reverse map (data-structure) |
| `g6lc_ai_gemm_seq` | 49.6 | plain | C-bank `ReadLatency=0` read seam real but capture scattered across a dozen+ sv-timing factor stages in a ~5000-line sequencer |
| `g6lc_ai_island_top` | 43.2 | plain | submit 3-source priority (fetch>sb>db) + wide `desc_bits_t` select is atomic; skid just moves same comb to a flop; source-clear deferral (db/sb/fetch) risks lost-job livelock. `submit_ready=ST_IDLE&&enable` is engine-state-only (clean in principle) but the resolution is the deep cone |
| `g6lc_ai_gemm_fp32_norm` | 44.1 | plain | LIVE via `fp32_add_p2`@`gemm_seq.sv:1730`; 25-way candidate + 6-level OR-tree ≈ msb_pos+barrel depth (likely wash); FP-correctness-critical |
| `g6lc_l2_mshr` | 39.8 | plain | TWO priority-tree rewrites already countercased (39.8→64.8/760); real depth = inherent `mem_d[free_idx]` dynamic-write demux; free-list only shaves scan ~10 FO4 with sync risk |
| `g6lc_ai_pe_dot_float_pipe` | 37.2 | — | r127-ab landed; new limiter `bfp_mant_exp_to_fp32` output pack (floor) |
| `g6lc_ai_exec` | 45.6 | plain | all paths P10 handshake-locked ("InsertReg refuse") |
| `g6lc_ooo_snoop_filter` | 57.5 | parallel-timing | P10 handshake lock |
| `g6lc_l2_wtrk` | 27.9 | plain | P10 handshake lock (the 38.6 `independent_lhs_bundle` was a different intoout path) |

**`independent_lhs_bundle` discriminator:** rows where `makespan == max_field`
are single-deep-field floor-bound (e.g. `g6lc_ai_cmd_fifo` 38.8, lhs=12);
rows where `makespan > max_field` are dependency chains (`g6lc_l2_wtrk` 38.6
bundle) — both need pipelining, not balancing.

**Confirmed dead / non-production rows** (do not chase):
`g6lc_ai_fp_dot` 271.5, `g6lc_ai_cluster_set` 71.5 (`FP_REAL_MODEL` sim-only),
`g6lc_ai_policy_topology`/`policy_steer`/`policy_subcode`/`policy_codec`/
`pmu_rate`/`dram_timing`/`cap_window`/`gemm_arplan`/`tile_sram` (uninstantiated
or policy/sim units), `g6lc_ai_cluster_set`, `hpdcache_ctrl_pe` 75.8 /
`hpdcache_mshr` 56.5 (CEA Apache-2.0/SHL-2.1 vendor IP — out of g6lc scope).
`g6lc_ai_fp32_add`/`fp32_norm`/`fp32_align` are unit-board only EXCEPT
`fp32_add_p2` which is live inside `gemm_seq`.

**Net:** after r127-ab (`pe_dot_float_pipe` 80.2→37.2) + r127-aa (`l2_pf`
parallel emit-eval) + r127-y/z (unmeasured-module sweep) + r127-v (hub demux)
+ r127 server_pf narrowing, the live APU worst is `l2_pf` 138.8 and every
remaining row ≥~28 FO4 is contract/floor/dead as tabulated. Contract batch =
the not-done set; each needs dedicated implementation + module bench +
remote gating.
