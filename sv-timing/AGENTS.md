# sv-timing — Agent Guider (package root)

> **Scope:** This file is the entry point for agents working **inside `sv-timing/`**.  
> The package is **project-independent**: it must build, test, and analyze SystemVerilog with
> only this tree + fixtures. Host monorepos (e.g. CVA6V-EC `build-platform`) are **optional
> consumers** that spawn the CLI or rehydrate JSON — they never become crate dependencies.

| Artifact | Path | Role |
|---|---|---|
| **This guider** | `AGENTS.md` | Navigation, invariants, extension playbook |
| **Live todo / state** | [`AGENTS-todo.md`](AGENTS-todo.md) | Phase checklist; update every pass |
| **Architecture design** | [`architecture/DESIGN.md`](architecture/DESIGN.md) | Full multi-step design (IR, cache, hosts, PRs) |
| **Architecture index** | [`architecture/README.md`](architecture/README.md) | Short map of architecture docs |
| **Relocation FO4 plan** | [`architecture/RELOCATION-ANALYSIS.md`](architecture/RELOCATION-ANALYSIS.md) | Pattern → T0–T3 relocation options for bottlenecks |
| **Optimization levels** | [`architecture/OPTIMIZATION-LEVELS.md`](architecture/OPTIMIZATION-LEVELS.md) | L0–L5 measure → path_class → BalanceMux → InsertReg |
| **PERF-CACHE** | [`architecture/PERF-CACHE.md`](architecture/PERF-CACHE.md) | IR-only SQLite analyze cache (CRC + design/module hits) |
| **Toolchain / setup** | [`AGENTS-toolchain.md`](AGENTS-toolchain.md) | Contained rustup/cargo + Python venv; **Python-first** CLI |
| **Vendor parser** | [`AGENTS-vendor-sv-parser.md`](AGENTS-vendor-sv-parser.md) | Integral in-tree `crates/sv-parser` |
| **Host integration** | [`AGENTS-host.md`](AGENTS-host.md) | How external tools import/interact (no monorepo hardcoding) |
| **Auto-correct passes** | [`AGENTS-auto-correct.md`](AGENTS-auto-correct.md) | Multi-pass IR transforms; integrity tests |
| **Core function catalog** | [`architecture/AUTO-CORRECT-CORE-API.md`](architecture/AUTO-CORRECT-CORE-API.md) | Naming, rank, pipeline, emit, debug APIs |
| **Optimization levels** | [`architecture/OPTIMIZATION-LEVELS.md`](architecture/OPTIMIZATION-LEVELS.md) | Design delta: measurement-truth fixes (M1–M7) + `-O0..-O3/-Os/-Oz` and the ten dials |
| **Throughput / cache** | [`architecture/PERF-CACHE.md`](architecture/PERF-CACHE.md) | Design delta: bottlenecks (B1–B9), cache defects (C1–C3), pre-compiled `units` tier, calibration |
| **TypeScript / Bun** | [`AGENTS-js.md`](AGENTS-js.md) | `js/` client + connection tests (`.ts` only) |
| **JS architecture** | [`architecture/JS-TYPESCRIPT.md`](architecture/JS-TYPESCRIPT.md) | DTO contracts, Bun test flow |
| **Licensing** | [`AGENTS-licensing.md`](AGENTS-licensing.md) | First-party vs vendored licenses |

When this package is checked into a larger repo, also respect that repo’s SoC/licensing guides for
**host-side** glue only. Never import monorepo modules into Rust crates here.

---

## 0. Prime directive — independence + Python-first tooling

1. **Independence (KD0).** `cargo test --workspace` and fixture analyze must succeed with only
   `sv-timing/`. No compile- or link-time dependency on `build-platform`, flists, `edaEnv`,
   `ariane_pkg`, or monorepo `workspace/` paths. Enforce with `tools/check_independence.py`.
2. **Design is law.** Behavior, stages, cache algorithm, and host boundary are defined in
   [`architecture/DESIGN.md`](architecture/DESIGN.md). Update the design (or open a design delta
   in `AGENTS-todo.md`) before large structural code changes.
3. **Python-first tooling.** Package automation lives under `tools/*.py`. The single entry is
   **`tools/svt.py`** (setup, doctor, vendor, cargo, test, check). Thin `svt.sh` / `svt.ps1`
   wrappers exist only to invoke that Python entry on Unix/Windows; **do not** grow logic in
   shell/PowerShell — port it to Python.
4. **Contained environment.** Toolchain state under `.tools/` only:
   - `RUSTUP_HOME=.tools/rustup`, `CARGO_HOME=.tools/cargo` (rustup + cargo via official installers)
   - Python venv `.tools/python-venv` for tooling scripts and `requirements.txt`
   - Never require a pre-installed global Rust; host Python is a bootstrap seed for the venv only.
5. **Integral sv-parser.** Parser source is vendored under `crates/sv-parser/` (not crates.io for
   production path deps). Refresh with `python tools/svt.py vendor-sv-parser`. See
   `AGENTS-vendor-sv-parser.md`.
6. **Licensing.** First-party code: `MIT` + Etienne Cimon when under the
   monorepo policy. Vendored parser: MIT OR Apache-2.0 unchanged. See `AGENTS-licensing.md`.
7. **State.** Every implementation pass updates `AGENTS-todo.md` (check off done work, add next).

---

## 1. Directory map

```
sv-timing/
  AGENTS.md                 ← this file
  AGENTS-todo.md            ← live phase/todo state
  AGENTS-toolchain.md
  AGENTS-vendor-sv-parser.md
  AGENTS-host.md
  AGENTS-licensing.md
  architecture/
    README.md
    DESIGN.md               ← authoritative multi-step architecture
  tools/
    svt.py                  ← PRIMARY CLI (setup/doctor/build/test/vendor/…)
    refresh_sv_parser.py
    check_independence.py
    env_common.py
    sv-parser.rev
  svt.sh / svt.ps1          ← thin wrappers → tools/svt.py (no business logic)
  Cargo.toml                ← workspace (first-party crates only)
  rust-toolchain.toml
  requirements.txt          ← venv pins
  crates/
    sv-parser/              ← VENDORED upstream (integral copy)
    sv-timing-core/         ← loc, parse, IR (growing)
    sv-timing-cache/
    sv-timing-transform/
    sv-timing-emit/
    sv-timing-cli/          ← binary name: sv-timing
  fixtures/                 ← only RTL default tests need
  schemas/  resources/  js/ patches/sv-parser/
  .tools/                   ← gitignored: rustup, cargo, venv
```

---

## 2. Multi-step pipeline (summary)

Full detail: `architecture/DESIGN.md` § Multi-Step Architecture.

| Stage | Owner | Notes |
|---|---|---|
| 0 Host discovery | **Host only** | Flists → file list; not in this package |
| 0b Ingest | CLI | `--files` / `--files-from`, defines, modules |
| 1 Parse | core + vendored sv-parser | Location adapter |
| 2 Scope | core | P1 local; P1.5 packages + host param-map |
| 3–4 Lower + FO4 | core | `resources/fo4-v1.toml` |
| 5–7 Paths / rank / opportunities | core | Explicit `--modules` or `--all-modules` |
| 8 Correct | transform + emit | Opt-in, allowlist |
| 9–10 Report + SQLite CRC cache | cli + cache | Default `./.sv-timing-cache/` |

---

## 3. Daily commands (Python entry)

From `sv-timing/`:

```bash
# Bootstrap contained rustup/cargo + venv; vendor parser if missing
python tools/svt.py setup
# or:  py -3 tools/svt.py setup

python tools/svt.py doctor
python tools/svt.py vendor-sv-parser
python tools/svt.py build
python tools/svt.py test
python tools/svt.py check          # independence + fmt + clippy + test
python tools/svt.py cargo clippy --workspace
python tools/svt.py run -- --help  # cargo run -p sv-timing-cli
python tools/svt.py js-test        # TypeScript Bun package: typecheck + connection tests
python tools/svt.py verif-regress  # heavy .sv → correct emit → pyslang lint
# When checked into a monorepo with core/ (opt-in; not part of default test):
python tools/svt.py monorepo-soak --list
python tools/svt.py monorepo-soak              # sparse real core/*.sv; fix package first
# Scale experiment (~32 FO4 @ 1250 MHz → ~20 FO4 @ 2000 MHz; fo4_ps=20, margin 0.2):
python tools/svt.py monorepo-soak --target-mhz 2000 --profile sparse_ex --correct --emit --allow-latency
python tools/svt.py clean                      # cargo clean + target / .sv-timing-out / cache
python tools/svt.py clean --all                # also remove .tools/ (re-run setup after)
```

Thin wrappers (optional):

```bash
./svt.sh setup
.\svt.ps1 setup
```

**Monorepo soak (package-first):** see [`architecture/MONOREPO-SOAK.md`](architecture/MONOREPO-SOAK.md)
and monorepo `AGENTS-coding-philosophy.md` §2.8. Failures default to fixing **this package**; RTL
edits are rare and still require the host SoC checklist.

---

## 3.1 Clean (package CLI vs monorepo host)

| What | Package command (from `sv-timing/`) | Monorepo host (repo root) |
|------|-------------------------------------|---------------------------|
| Cargo `target/` + `.sv-timing-out` + `.sv-timing-cache` | `python tools/svt.py clean` | `./build.sh clean svt` (alias: `rust-target`, `sv-timing-target`) |
| Contained `.tools/` (rustup/cargo/venv) | `python tools/svt.py clean --all` | `./build.sh clean svt-tools --yes` |
| Host monorepo-soak / `timings compile -o` packages | *(not package)* | `./build.sh clean timings` under `workspace/build/sv-timing/` |

**Do not confuse:** host `clean timings` never deletes package Cargo `sv-timing/target`; package
`clean` never deletes monorepo workspace soaks. Inventory: `./build.sh clean status`. Full map:
monorepo `AGENTS-build-platform.md` §2.6 and `architecture/build-platform-workspace-lifecycle.md`.

---

## 3.2 Structural FO4 budgets (screening, not STA)

Shared model with host `timings`:

```text
budget_fo4 = (1000 / target_mhz × 1000 / fo4_ps) × (1 − margin)
```

Defaults: `fo4_ps=20`, `margin=0.2` → **~32 FO4 @ 1250 MHz**, **~20 FO4 @ 2000 MHz**.

| Mechanism | Role |
|-----------|------|
| `path_class` | Deflates raw statement-order sums (exclusive mux, independent LHS, dense, atomic) |
| BalanceMux | Latency-neutral hot-arm stage + optional one-hot OR tree; sticky FO4 credit |
| Relocation T0–T3 | JSON cards for correct worklist; T3 multi-cycle is suggest-only |
| Emit | Review-only under `corrected/`; never auto-merge into production RTL |

**Rules:** fix **package first** on real-core soak failures; never retune `resources/fo4-v1.toml`
from synthetic STA fixtures—only real STA + host `timings retune-propose` (S3b-lab). Raising
`--target-mhz` tightens the budget; residual exclusive/LSU cones may still estimate ~1.4–1.7 GHz
after latency-neutral rewrites (need microarch / multi-cycle, not FO4 credit games). Design:
`architecture/FO4-ALGORITHM-UPGRADES.md`, `RELOCATION-ANALYSIS.md`, `FREQUENCY-CLOSURE.md`.

---

## 4. Extension playbook

| Task | Where |
|---|---|
| Change architecture | Edit `architecture/DESIGN.md` + note in `AGENTS-todo.md` |
| Add toolchain command | Implement in `tools/svt.py` (not shell) |
| Refresh parser | `tools/refresh_sv_parser.py` via `svt.py vendor-sv-parser` |
| New IR / cost / path logic | `crates/sv-timing-core` |
| Cache | `crates/sv-timing-cache` |
| Auto-correct | `crates/sv-timing-transform` + `emit` |
| CLI subcommand | `crates/sv-timing-cli` |
| Real monorepo SV soak | `tools/monorepo_soak.py` / `svt.py monorepo-soak` — **package-first** fixes |
| Free package Cargo bulk | `svt.py clean` (or host `clean svt`); `.tools` → `clean --all` / host `clean svt-tools --yes` |
| Host adapter (build-platform etc.) | **Outside** this tree — see `AGENTS-host.md` |
| Independence regression | `tools/check_independence.py` |

---

## 5. Standing checklist (every code pass)

- [ ] `AGENTS-todo.md` updated
- [ ] First-party crates still independence-clean
- [ ] SPDX headers on net-new code files (`MIT`, Etienne Cimon)
- [ ] No new business logic in `svt.sh` / `svt.ps1`
- [ ] Fixtures-only success criteria for package tests
- [ ] Design doc still accurate for user-visible behavior changes

---

## 6. Non-goals (package)

- Replacing STA / sign-off
- Owning flist / Bender / FuseSoC expansion (hosts convert to file lists)
- Absolute FO4 CI gates in v1
- Hardcoding monorepo paths or SoC config packages
- Deleting host workspace artifacts (`clean timings` is host-only)

---

*Last updated: 2026-08-03 — clean map (package ↔ host `svt` / `svt-tools`), FO4 budget/scale notes.*
