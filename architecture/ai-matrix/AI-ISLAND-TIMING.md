# AI island timing — what stands between `g6lc_ai_*` and a high clock

Structural FO4 screening only. **Not STA sign-off**, and no silicon claim follows.
Companion to [`va-turbo.md`](va-turbo.md) (throughput / codec work) and
[`../../sv-timing/architecture/FREQUENCY-CLOSURE.md`](../../sv-timing/architecture/FREQUENCY-CLOSURE.md)
(the model, the `-O` surface, and the caveats).

## Latest carry-over: r30 subcode sequential products

subcode **60.34→49.74** (shared 32-cycle multiplier); island maximum now
pe_dot_float_pipe 50.77. See APU `analysis/worst-modules-r30.md`.

## Previous carry-over: r29 desc_engine prepared lengths

desc_engine's check-length cone is a registered fact; island DMA bench
passes. Island maximum now subcode 60.34. See APU
`analysis/worst-modules-r29.md`.

## Previous carry-over: r28 exec requant

exec **62.55→26.07** on the frozen board (wired-row carry-save product,
parallel polarities); island maximum desc_engine 63.35. See APU
`analysis/worst-modules-r28.md`.

## Previous carry-over: r27 exec dot4 row trees

dot4 products **56.0→22.4** on the frozen board; the requant multiply
stays atomic (carry-save form measured worse structurally, countercase
recorded). exec maximum 62.55; see APU `analysis/worst-modules-r27.md`.

## Previous carry-over: r26 worst-five landings

Frozen delay-v45 board: codec **59.30→39.40**, inval_queue 46.54, subcode
60.34; island maximum desc_engine 63.35. Benches pass. See APU
`analysis/worst-modules-r26.md` and the plan in `worst-five-r26-plan.md`.

## Previous carry-over: r25 subcode COST stage

Frozen delay-v45 board: subcode **78.92→62.24**; island maximum now
desc_engine 63.35 (from r19's 128.37). Policy bench passes. See APU
`analysis/worst-modules-r25.md` for the remaining owners and mechanisms.

## Previous carry-over: r24 worst non-GEMM modules

Frozen delay-v45 board: pe_dot **128.37→45.80**, policy codec
**85.80→59.30**, subcode 78.92; island maximum is now subcode. GEMM gates
and the policy bench pass. See APU `analysis/worst-modules-r24.md`.

## Previous carry-over: r23 carried receive facts

Frozen delay-v45 board: GEMM **55.80→48.70** with remaining-byte facts in
the AR slot, static bank-write routing, registered issue facts and a
registered operand-bank read stage (tile ReadLatency 1); FP stages
46.25/37.70 unchanged. Remote gates pass. Next: the C-bank read seam.
See APU `analysis/gemm-windows-r23.md`.

## Previous carry-over: r22 interleaved two-stage accumulation

Frozen delay-v45 board: GEMM **61.50→55.80**; the FP recurrence is now two
stages (align 37.70, normalize 46.25) fed by alternating column groups, so
no one-cycle FP add remains. Focused remote gates pass; shapes with a single
column group run at half rate. See APU `analysis/gemm-windows-r22.md`.

## Previous carry-over: r21 FP sign-magnitude and commit token

On the frozen r20 analyzer: GEMM **73.50→61.50**, FP32 adder **94.93→75.00**,
store plan **39.80→28.50** (delay-v45 structural maxima). The FP recurrence
remains one cycle; the next lever is a two-stage interleaved accumulator and
a registered operand read stage. Focused remote gates pass; the matched DPF=0
golden spends 1365 cycles (was 1344). See APU `analysis/gemm-windows-r21.md`.

## Previous carry-over: r20 load completion and operand wiring

Matched delay-v45/ir-v6 screening measures GEMM **98.00→73.50 FO4** after
preparing terminal-load facts and replacing dynamic operand gathers with
constant layouts. FP remains **94.93**, the larger GEMM-family cone.
Focused isolated remote gates and old-expression comparisons pass; matched
DPF=0 cycles remain 1344. Existing warning signatures remain, and generic
remote lint/synth still fail the hyp config lookup. See APU
`analysis/gemm-windows-r20.md` for full identities and limits.

## Previous carry-over: r19 GEMM functional windows

Follow-up qualification: the reported caller stitches below add representative
module paths without validating port-to-consumer connectivity or register
boundaries. They are triage summaries, not connected arrival times or reliable
upper bounds. The local 92.95 region is operand-format gathering.
The exact audit and next strategies are in APU
`analysis/gemm-internal-stitches-r19.md`; local r19 costs reproduce unchanged.

`analyze-ai-hyp-r19` measures GEMM **119.50→98.00 FO4**, with extracted
FP32, residency-span and C-store-plan leaves at **94.93 / 18.30 / 39.80**.
The previously omitted iterative multiplier is included at 20.00 in both
the final board and matched `r19-before-complete` baseline.
Dispatch→GEMM improves to 127.25 and top→GEMM to 130.50; new internal
stitches still reach 132.75, so these local reductions do not close the island.

Owned planning windows and a raw W-beat register shorten the store path.
Separate fetch/retire cursors allow full-rate refill within a burst.
The FP32 recurrence uses 26-bit arithmetic and parallel normalization without
adding a MAC cycle. Backend/accumulate, signed/backpressure, FP equivalence,
reuse slots, cluster, wide and stripe gates pass. Preparation/W-beat startup latency
increases and canonical lint/synth cannot resolve the hyp config package.
See `hyp_redesign_corev_apu_8fo4/analysis/gemm-functional-r19.md`.

## Previous carry-over: r18 worst-two reduction

Fresh `analyze-ai-hyp-r18-before` selected GEMM and cluster dispatch.
The final `analyze-ai-hyp-r18` board measures **172.2→119.5** and
**150.5→34.3 FO4** respectively. Dispatch→GEMM improves 270→153.8,
top→dispatch 188.05→71.85; the direct GEMM caller stitch remains 157.05.
GEMM captures C seeds alongside incoming partials; dispatch prepares complete
engine descriptors through owned register stages and bounded multiplication.

Assertion-enabled backend and accumulate goldens pass for DPF=0/2, and three
independent integer GEMM shapes pass for single/two/four engines. The old
integer column-slice failure is fixed (C-bank address operator precedence).
The aggregate host verify attempt failed on config/tool setup. Setup latency,
remaining cones and qualification limits are recorded in
`hyp_redesign_corev_apu_8fo4/analysis/worst-two-r18.md`.

## Previous carry-over: r17 policy split

The hyp policy proposal is implemented. `g6lc_ai_policy_steer` owns request
capture and coherent publication; new topology and PMU publisher leaves
separate shape evaluation from completion handling. Default service parameters
eliminate the product, and a bounded exact fallback preserves other settings.
Full board `analyze-ai-hyp-r17`: steer **165.0→27.25 FO4**, topology **27.8**,
publisher **8.0**. Codec/subcode remain **85.8/80.3**, island_top **43.9**.
Strict focused lint, 5,568 reference topology checks, publication/cancellation/
PMU ordering tests, and the full hyp island DMA smoke pass.
See the implementation section of `hyp_redesign_corev_apu_8fo4/analysis/
policy-steer-caller-split.md`. No whole-island 8-FO4 or physical closure.

## r16 GEMM and original policy analysis

The hyp GEMM sequencer now has functional control blocks, elastic AR/AW/W/R/B
cuts and a single-plan operand preparation window. Full board
`build-platform/workspace/build/sv-timing/hyp8-src/boards/ai-island/analyze-ai-hyp-r16.json`:
intoout 171.15→119.5 FO4, regtoout 170.3→20.25, regtoreg 170.3→172.2.
The overall maximum has not fallen; the C seed-read/FP accumulator dependency
is now the leading cone. Focused backend golden passes for nch=1/dpf=0 at
1041 cycles (historical baseline 956). Other configurations remain unqualified
for this revision.

`hyp_redesign_corev_apu_8fo4/analysis/policy-steer-caller-split.md` records
the next policy strategies: retain pulse-only job requests, join codec events
with the matching topology, repair slot-width truncation, eliminate the
service multiply when its parameter bounds prove the predicate, and evaluate
constant shape candidates in parallel. Policy RTL remains unchanged.
The JSON policy stitches in both final8 and r16 are 156.84/177.64/181.18 FO4;
the earlier prose claim that all were <=40 is superseded. These broad
structural stitches require source-level connection checking, not STA claims.

## §0 ai-hyp program (2026-10-26/28) — hyp tree of record, r7 state

Structural delay-v44 FO4, 8.0 budget, 5 GHz target. **Not STA.** Tree:
`build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4` +
`hyp_redesign_core_8fo4/cvxif_g6lc_ai`. Board of record
`boards/ai-island/analyze-ai-hyp-final3.json` (argv
`analyze-ai-hyp-final3.cmd`; r7 closes on R1 caller-purposed output
registers, R4 ST_SPAN, R5 codec window, R7 splits); per-item boards
`analyze-ai-hyp-r*`; item-by-item history + bench lines in
`hyp_redesign_corev_apu_8fo4/analysis/implementation-log.md` and the
program table in `analysis/ai-fo4-program.md` §5.

| module | final FO4 | note |
|---|---|---|
| g6lc_ai_policy_steer | 184.0 | R1 topology_q landed; R5 evaluator open |
| g6lc_ai_gemm_seq | 171.2 | R1 landed; R2 arplan deferred (module written) |
| g6lc_ai_cluster_dispatch | 150.5 | R1 landed; R9 open |
| g6lc_ai_pe_dot | 128.4 | superseded by DotPipeInt |
| g6lc_ai_policy_subcode | 96.4 | R1 landed; R5 subcode open |
| g6lc_ai_policy_codec | 85.8 | r6 split + R5 window landed |
| g6lc_ai_desc_engine | 63.3 | R1 + R4 ST_SPAN landed |
| g6lc_ai_exec | 62.6 | landed (DotPipeInt + phase); R10 open |
| g6lc_ai_inval_queue | 52.3 | G2 reverted; R6 open |
| g6lc_ai_pe_dot_float_pipe | 50.8 | C2 kept; C1 reverted; R8 open |
| g6lc_ai_pe_dot_float | 47.1 | open |
| g6lc_ai_island_top | 43.9 | E-series + R7 splits landed (1047.9 -> 43.9); `rcls` mux open |
| g6lc_ai_cap_window | 40.6 | R7 A104 landed; occupancy idx limiter |
| g6lc_ai_desc_fetch | 29.5 | G4 landed |
| g6lc_ai_pmu_rate | 28.9 | already sequential |
| g6lc_ai_dram_backend | 27.5 | open |
| g6lc_ai_fp_mac | 26.5 | open |
| g6lc_ai_dram_timing | 24.3 | open |
| g6lc_ai_mul_seq | 20.0 | WA/WB kept |
| g6lc_ai_addr_check | 8.5 | G6 landed |
| g6lc_ai_pe_dot_pipe | 14.8 | DotPipeInt landed |

Method note (P6/rule): one `always_ff` per register group, one
`always_comb` per output family — the analyzer composes a monolithic
block's writes as a serial chain; `verilator --lint-only` precedes every
board (sv-timing's parser accepted a type Verilator rejects).

## Superseded: `g6lc_ai_exec` is not the core's worst path

Re-measured with a closed input set (every file parsed, no `--allow-parse-errors`),
corrected source-origin mapping, no name-based arithmetic discounts, and
`// synthesis translate_off` regions excluded — 4000 MHz / 20 ps / 10.0 FO4, `-O3`:

| Profile | Worst path | FO4 | Structural max | Closure |
|---|---|---:|---:|---|
| `full_core` | **`g6lc_ftq`** (fetch target queue) | 70.0 | ~571.4 MHz | MISS |
| `full_corev_apu` | **`g6lc_ai_gemm_seq`** | 304.5 | ~131.4 MHz | MISS |

`SyncDpRam` 720.0 FO4 and `g6lc_ai_exec` 545.5 FO4 **do not reproduce**. The first was
a comment-lowering artifact; the second came from inflated arithmetic costs and an input
set that omitted much of the design (`full_core` 184 → 233 modules, `full_corev_apu`
1888 → 4636 paths once the inputs were closed).

The island still holds the APU's worst structural path, but it is `g6lc_ai_gemm_seq`,
not the core CVXIF execute unit — so the pipelining ask below is aimed at the wrong
module and its 6-stage figure is not current. Auto-correct moved primary FO4 by **0.0**
on both profiles across 462 and 308 edits, so no transform here has been shown to buy
frequency. Re-derive any datapath ask from `sv-timing/architecture/FREQUENCY-CLOSURE.md`
before acting on §2-§4 below.

**These island paths do appear to be real arithmetic.** A separate correction
(`delay-v4`) removed a class of false dividers created by parameter arithmetic in
constant part-select bounds — that deleted the core's 202.0 FO4 `cva6_ptw` path and 10 of
45 `atomic_over_budget` classifications, but left the island's ranking unchanged:
`g6lc_ai_gemm_seq` 304.5 / 131.0 and `g6lc_ai_pe_dot` 130.0 FO4 all survived. Real
multipliers in a dot-product datapath are the expected outcome. That justifies
*investigating* island arithmetic; it still does not supply a stage count, an area
figure, or any evidence that the surrounding control, retire and traffic ceilings admit
one — and it is a structural estimate, not STA.

## Evidence boundary: ir-v1 / delay-v3

The figures and causal claims below are **historical structural diagnostics**, superseded
by the measurements above. In particular, 545.5 FO4 is not an established physical
critical path, six idealized partitions are not a proved six-stage implementation, and
integer-dot cell counts do not measure the area of the floating-point SoC island or of
`g6lc_ai_exec`.

The audit found preprocessed offsets used against original source bytes, runtime
arithmetic discounted by identifier names, and ambiguous NBA dependencies treated as
procedural timing. Those defects affect both costs and proposed edits. Corrected source
mapping and conservative refusals now precede any attempt to optimize the datapath.
See `sv-timing/AGENTS-todo.md` and `sv-timing/architecture/DESIGN.md` from the repo root.

Keep core CVXIF (`g6lc_ai_exec`/coprocessor/accumulator) separate from the SoC island
(GEMM, native-format PE/FP dot, policy/V/A-Turbo, DMA and clustering). Both soak input
sets must be checked against the actual top, config and feature enablement. A file being
present does not prove a path is instantiated at the requested issue/core/hart count.

4 GHz remains a 0.250 ns target. No mapped netlist, reviewed PVT/SDC/parasitics, timing
closure, or emitted-RTL equivalence for the feature-max processor is established here.
QEMU software/device tests cannot substitute for those gates.

Historical measurements: `sv-timing` `monorepo-soak --profile full_core`,
`+define+G6LC_FETCH_B` carried, g1\* recover retired, `--allow-parse-errors`.

---

## 1. The island is in the timing report at all only since 2026-09-10

Two defects hid it, and both are worth knowing because either would hide it again:

- **`+define+` was dropped from every soak package.** `flist_expand` collected defines and
  the portable-flist writer never emitted them, so the analysed core was the `ifndef
  G6LC_FETCH_B` A-path rather than the shipping one.
- **`design_key` omitted `allow_parse_errors` and `package_mode`.** A cache hit returned a
  **139-module / 3,608-path** design where a cold run over byte-identical inputs produced
  **177 / 4,130**, with `design_hit=true` and `files_changed=0`. The 139-module report
  contained **zero `g6lc_*` modules** — every OoO block and all three AI-island modules
  were silently absent.

With both fixed, `full_core` reports `modules=183 paths=4208` and covers
`g6lc_ai_acc_bank`, `g6lc_ai_coprocessor`, `g6lc_ai_exec`.

## 2. `g6lc_ai_exec` is the core's worst real path

| Path | FO4 | Class | Note |
|---|--:|---|---|
| `SyncDpRam.out0` | 720.0 | `atomic_over_budget` | **not real** — comment-lowering bug, §4 |
| **`g6lc_ai_exec.out0`** | **545.5** | `atomic_over_budget` | genuine worst path |
| `cva6_mmu.out0` | 345.0 | `atomic_over_budget` | |
| `cva6_shared_tlb.out0` | 332.0 | `atomic_over_budget` | |
| `g6lc_rename.out0` | 25.1 | `independent_lhs_bundle` | OoO blocks are healthy |
| `g6lc_rob.out0` | 23.3 | `independent_lhs_bundle` | |

So the AI island, not the OoO rename set, is what limits the core. The OoO blocks all sit
at ≤ 25.1 FO4 — comfortable even at a 2 GHz-class budget.

## 3. What `g6lc_ai_exec` actually needs

The path is `atomic_over_budget`: its cost is dominated by a single indivisible `Mul` of
**56.0 FO4**, and *no cut strategy reaches inside an operator*. Measured consequence —
`-O3` over `-O2` on the whole core changed 163 more edits and moved the emitted critical
path by **exactly nothing**. Raising passes is not a fix for this class.

The actionable output is the T3 `arch_multicycle` requirement, which scales with the
target:

| Target | `fo4_ps` | Budget FO4 | Stages for a 56 FO4 multiply | Latency |
|--:|--:|--:|--:|--:|
| 1250 MHz | 20 | 32.0 | 2 | +1 cycle |
| 2000 MHz | 20 | 20.0 | 3 | +2 |
| 4000 MHz | 20 | 10.0 | **6** | **+5** |
| 4000 MHz | 12 | 16.7 | 4 | +3 |

That is the microarchitectural ask: an internally pipelined multiply in the island execute
path, with the latency reflected in whatever schedules it. §4 of `va-turbo.md` is the
throughput counterpart — note that a deeper multiply interacts with the retire ceiling
recorded there, so the two must be planned together rather than in sequence.

The isolated-synthesis numbers in `va-turbo.md` are consistent with this being the right
target: the MAC array is **78% of the engine** at 8 lanes (5,867 of 7,530 cells), so the
island's area *and* its critical path are both dominated by the same arithmetic.

## 4. Do not trust the 720 FO4 figure — or the frequency numbers derived from it

`SyncDpRam.out0` reports 720.0 FO4 as an "atomic `DivRem`". It is a lowering artefact:
`nodes=1`, `primary_loc SyncDpRam.sv:136`, and line 136 is a row of slashes. The file
contains **zero** `/` or `%` operators outside comments (348 `/` characters, all in
comments), and 720 is exactly 6 × the model's `div_rem` base of 120. Comment slashes are
being lowered as division nodes.

Scope, measured: **3 of 24** atomic paths sit on comment lines, carrying **1,577 of 29,925
FO4 (5.3%)** — narrow, but it owns the single worst path, which is what every reported
ceiling derives from. Any frequency frontier taken before that fix (including the
"emitted core floors at ~99.4 FO4 / ~503 MHz at 20 ps" figure) should be expected to move.

## 5. Standing caveats for island timing work

- **`primary_fo4` excludes `atomic_over_budget`.** Since every interesting island path is
  in that class, the IR-side `post_closure` figure is close to meaningless here. Read
  `post_analyze_sv` — the re-analysis of the emitted RTL — beside it. Measured divergence
  on the APU: IR `closes=true 4000.0` against emitted **350.9 MHz**.
- **`fo4_ps` is a process input.** The host target of record is 1.25 GHz / 12 nm; a 4 GHz
  claim needs its node stated or it is unfalsifiable.
- **`core/alu.sv` needs `--allow-parse-errors`.** Line 276 chains a select onto the result
  of a range select; `slang` agrees with the vendored parser that this is an error
  (`cannot chain select expressions after a range select`), so it is non-LRM RTL leaning on
  a Verilator extension, not a parser gap.
- **Island compute is split across two soaks.** Core CVXIF (`g6lc_ai_exec` /
  `g6lc_ai_coprocessor` / `g6lc_ai_acc_bank`) is on `full_core` via `Flist.cva6`.
  The SoC island (`corev_apu/ai_island/*`, including `g6lc_ai_island_top`, GEMM,
  policy, FP MAC/dot) is on `full_corev_apu`. Read both.
- The `g6lc_ai_*` RTL and this document are tier **R** (`CERN-OHL-S-2.0 OR
  LicenseRef-GSys-Commercial`).

## 6. Open, in priority order

1. Fix comment content reaching operator extraction (§4), then re-run the frontier.
2. Pipeline the `g6lc_ai_exec` multiply to the stage count §3 requires for the chosen
   target, and re-check the retire ceiling in `va-turbo.md`.
3. Decide whether `SyncDpRam`'s behavioural model belongs in a timing package at all.
4. Only then widen the flist: a feature-max package inherits whatever the measurement
   gets wrong, which is how the 139-module report went unnoticed.


## final6 (r10) -- module summary (5000 MHz, fo4 20ps, structural delay)

```
g6lc_ai_policy_steer      165.0   (r0 178.0 -> final5 165.0 -> final6 165.0)
g6lc_ai_gemm_seq          171.2   (r0 347.6 -> final5 170.3 -> final6 171.2, R2 reverted)
g6lc_ai_cluster_dispatch  150.5   (r0 150.5 -> final5 150.5 -> final6 150.5)
g6lc_ai_gemm_arplan       140.0   (new -- uninstantiated, R2 reverted)
g6lc_ai_pe_dot            128.4   (superseded)
g6lc_ai_policy_subcode     80.3   (r0 96.4 -> final5 80.3 -> final6 80.3)
g6lc_ai_desc_engine        63.3   (r0 111.9 -> final5 63.3 -> final6 63.3)
g6lc_ai_inval_queue        52.3   (R6 open)
g6lc_ai_pe_dot_float_pipe  50.8   (R8 open)
g6lc_ai_island_top         43.9   (r0 1047.9 -> final5 43.9 -> final6 43.9)
g6lc_ai_cap_window         40.6   (r0 40.0 -> final5 40.6 -> final6 40.6)
g6lc_ai_exec               31.6   (r0 283.0 -> earlier)
g6lc_ai_desc_fetch         29.5   g6lc_ai_pmu_rate 28.9   g6lc_ai_dram_backend 27.5
g6lc_ai_fp_mac             26.5   g6lc_ai_dram_timing 24.3 g6lc_ai_mul_seq 20.0
tile_sram 19.0 dram_channels 16.3 island_apb 14.4 enq_arb/dram_join 13.5
cmd/cpl_fifo 13.0 mem_store 11.5 coprocessor 9.3 addr_check 8.5
pe_dot_pipe 14.8 acc_bank 1.0 litedram/axi_cut 0.0
```

R2 landed-then-lost: the r2c green state was not snapshotted before
r2d; the r10 re-land's miters were silent (plan values all correct --
the fault is the receive/MAC consumer's issue-timing assumption).
Reverted; re-land needs the consumer-side trace next.
