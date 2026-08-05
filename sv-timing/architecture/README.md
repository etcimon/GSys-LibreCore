# sv-timing / architecture

Authoritative design for this package lives here (not under the monorepo `architecture/` tree,
except as a pointer).

## Current state (2026-08-03)

| Area | State |
|------|--------|
| Independence (KD0) | **done** — fixtures + `svt.py check`; monorepo soak opt-in only |
| Measure / path_class | **done** — exclusive, independent-LHS, dense, atomic soft multi-cycle |
| Latency-neutral correct | **done** — rebalance, BalanceMux **stage_hot_arm → residual onehot → credit** |
| Exclusive LHS wire-up | **done** — `svt_bm_oh_*_top` multi-arm emit; CaseItem labels in lower IR |
| Emit integrity | **done** — reparse on sparse_ex / sparse_frontend (incl. multi-line ternary/AND) |
| IR-only PERF cache | **done** — design + module-granular SQLite (`PERF-CACHE.md`) |
| Optimization levels L0–L5 | **documented** — map of measure → T0–T3 (`OPTIMIZATION-LEVELS.md`) |
| sparse_ex @ 1250 MHz | **closes** primary ~30.9 FO4 after correct |
| sparse_ex @ 2000 MHz | **closes** — primary **37.9 → 20.0 FO4** (multi-arm stage) |
| Host OpenSTA / Yosys S1 | open (build-platform; soft-skip without tools) |

Live checklist: [`../AGENTS-todo.md`](../AGENTS-todo.md). Soak playbook + numbers: [`MONOREPO-SOAK.md`](MONOREPO-SOAK.md) §9.

| Doc | Purpose |
|---|---|
| [`DESIGN.md`](DESIGN.md) | Full architecture: independence, stages, IR, FO4, CRC+SQLite, auto-correct, host boundary, PR plan |
| [`OPTIMIZATION-LEVELS.md`](OPTIMIZATION-LEVELS.md) | **L0–L5** aggressiveness: measure → path_class → T1 BalanceMux → T2 InsertReg → T3 suggest |
| [`PERF-CACHE.md`](PERF-CACHE.md) | **IR-only** SQLite analyze cache: design/module hits, CRC-32C, path_class hints |
| [`AUTO-CORRECT-CORE-API.md`](AUTO-CORRECT-CORE-API.md) | Multi-pass library functions (naming, rank, pipeline, emit, integrity, debug) |
| [`JS-TYPESCRIPT.md`](JS-TYPESCRIPT.md) | Bun + **TypeScript** client (`js/`), JSON contracts, connection tests |
| [`FREQUENCY-CLOSURE.md`](FREQUENCY-CLOSURE.md) | Startpoint/endpoint path kinds, FO4 budget, precompiler + verif regress |
| [`STA-HANDOFF.md`](STA-HANDOFF.md) | Structural FO4 → STA/SDC handoff contract (not sign-off) |
| [`PROJECT-AUTOCORRECT.md`](PROJECT-AUTOCORRECT.md) | Multi-file/module projects: portable `.f`, `--out-dir`, new modules, emit flist |
| [`OPTIMIZATION-LEVELS.md`](OPTIMIZATION-LEVELS.md) | **Design delta (P14–P15, P19):** measurement-truth corrections + `-O0..-O3/-Os/-Oz` presets and the ten optimization dials |
| [`PERF-CACHE.md`](PERF-CACHE.md) | **Design delta (P16–P18):** analyze-throughput bottlenecks, pre-compiled per-file `units` cache tier, frequency sweep / calibration |
| [`CVA6-STYLE-SV.md`](CVA6-STYLE-SV.md) | Package/localparam/function + named always_ff (load_unit/scoreboard patterns) |
| [`MONOREPO-SOAK.md`](MONOREPO-SOAK.md) | Opt-in real-`core/` FO4 soak; package-first fix cycle; validated soak table |
| [`FO4-ALGORITHM-UPGRADES.md`](FO4-ALGORITHM-UPGRADES.md) | Research map + **validated** BalanceMux / path_class / emit stack |
| [`RELOCATION-ANALYSIS.md`](RELOCATION-ANALYSIS.md) | Relocation plan: patterns → T0–T3 options → JSON cards |
| [`../AGENTS.md`](../AGENTS.md) | Agent entry + playbook |
| [`../AGENTS-auto-correct.md`](../AGENTS-auto-correct.md) | Auto-correct agent rules |
| [`../AGENTS-js.md`](../AGENTS-js.md) | TypeScript package agent rules |
| [`../AGENTS-todo.md`](../AGENTS-todo.md) | Implementation state |

When changing behavior, update `DESIGN.md` / `AUTO-CORRECT-CORE-API.md` / the FO4–soak docs and log the pass in `AGENTS-todo.md`.
