# AI island timing — what stands between `g6lc_ai_*` and a high clock

Structural FO4 screening only. **Not STA sign-off**, and no silicon claim follows.
Companion to [`va-turbo.md`](va-turbo.md) (throughput / codec work) and
[`../../sv-timing/architecture/FREQUENCY-CLOSURE.md`](../../sv-timing/architecture/FREQUENCY-CLOSURE.md)
(the model, the `-O` surface, and the caveats).

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
