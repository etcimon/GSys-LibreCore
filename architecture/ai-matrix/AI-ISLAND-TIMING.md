# AI island timing — what stands between `g6lc_ai_*` and a high clock

Structural FO4 screening only. **Not STA sign-off**, and no silicon claim follows.
Companion to [`va-turbo.md`](va-turbo.md) (throughput / codec work) and
[`../../sv-timing/architecture/FREQUENCY-CLOSURE.md`](../../sv-timing/architecture/FREQUENCY-CLOSURE.md)
(the model, the `-O` surface, and the caveats).

Measurements: `sv-timing` `monorepo-soak --profile full_core`, `+define+G6LC_FETCH_B`
carried, g1\* recover retired, `--allow-parse-errors` (for `core/alu.sv`, see §5).

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
- **`corev_apu` does not cover the island.** Only one `ai_island` file reaches the
  `full_corev_apu` package and it contributes no analysed module, so island timing must be
  read from `full_core`.
- The `g6lc_ai_*` RTL and this document are tier **R** (`CERN-OHL-S-2.0 OR
  LicenseRef-GSys-Commercial`).

## 6. Open, in priority order

1. Fix comment content reaching operator extraction (§4), then re-run the frontier.
2. Pipeline the `g6lc_ai_exec` multiply to the stage count §3 requires for the chosen
   target, and re-check the retire ceiling in `va-turbo.md`.
3. Decide whether `SyncDpRam`'s behavioural model belongs in a timing package at all.
4. Only then widen the flist: a feature-max package inherits whatever the measurement
   gets wrong, which is how the 139-module report went unnoticed.
