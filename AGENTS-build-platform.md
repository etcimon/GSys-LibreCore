# AGENTS-build-platform — command structure & workspace state

> **Top-level agent map** for the CVA6 **build-platform** (Bun + TypeScript under
> `build-platform/`). Complements the thin pointer [`AGENTS-build.md`](AGENTS-build.md)
> and the extension playbook [`build-platform/AGENTS.md`](build-platform/AGENTS.md).
>
> **Last reviewed:** 2026-08-03 (granular `clean` + **`svt` / `svt-tools`**, timings
> FO4 scale / monorepo-soak, `--from-timing` / `--use-emit` hand-off).

---

## 1. Identity & entry points

| Item | Value |
|------|--------|
| Control surface | Repo-root [`.config.ts`](.config.ts) → `schema` / `defaults` / `load` |
| CLI entry | `bun build-platform/src/cli/index.ts <cmd>` |
| Wrappers | `./build.sh` / `.\build.ps1` (bootstrap Bun) · `cva6-build` via `setenv.*` |
| Workspace | `build-platform/workspace/` (gitignored; **safe to delete**) |
| Invariants | Zero runtime npm deps · deletes allowlist-confined · LicenseRef-Proprietary |
| Authoritative how-to | `build-platform/AGENTS.md` §4 (add config / command / tool / suite) |
| Lifecycle plan | `architecture/build-platform-workspace-lifecycle.md` |

**Standing operator loop**

```text
probe / doctor  →  tools install | setup --install  →  probe install  →  diag  →  verify / test
         optional: timings compile -o <dir>  →  validate / test --from-timing <dir>
         optional: monorepo FO4 soak (package) → timings validate/sta-handoff --from-timing
         free space: clean status  →  clean <purpose> [--older-than] [--execution]
                    clean svt | rust-target   # package Cargo target (not workspace)
                    clean svt-tools --yes     # package .tools (re-setup after)
```

---

## 2. Command catalog (current registry)

Source of truth: `build-platform/src/cli/registry.ts` (`COMMANDS` order).

### 2.1 Observe / host

| Command | Subcommands / flags (high-signal) | Role |
|---------|-----------------------------------|------|
| `status` | `--json` | SoC + provisioned flags (no deep PATH scan) |
| `doctor` | | Quick PATH readiness + managed tools summary |
| `probe` | `host\|platform\|pkg\|utils\|tools\|env\|diag\|commands\|install` · `--deep` · `--json` | Categorical capability boxes + install playbook |
| `diag` | `list\|status\|run [compartment\|id…]` · `--all` · `--from-timing DIR` · `--json` | Compartmentalized gates; **per-test Verilator surfaces** |
| `man` | `[id?] [files…] query` · `--list` · `--no-open` | Human man pages via Grok headless → `workspace/man/` |
| `config` | `--json` | Dump resolved `.config.ts` merge |

**Diag compartments:** `host` · `core` · `smt2` · `ooo` · `apu` · `residual`  
(config: `diagnostics.tests[]` / `defaultCompartments`)

### 2.2 Provision

| Command | Subcommands / flags | Role |
|---------|---------------------|------|
| `setup` | `--install` · `--profile sim\|dual-hart\|opensbi\|all` · `--dry-run` | Workspace + submodules + optional tool install |
| `tools` | `install [profile\|recipe]` · list pins | Managed toolchain under `workspace/tooling/` |

**Install profiles:** `sim` / `open-source-sim` · `dual-hart` · `opensbi` · `all`  
**Recipes:** `riscv-gcc` · `verilator` · `spike` · `iverilog` · `opensbi-smt2`

### 2.3 Uncore / board / foundry

| Command | Subcommands | Role |
|---------|-------------|------|
| `vendor` | `list\|status\|sync\|add\|update\|scan` · `--all` · `--ref` · `--dry-run` | Controller/PHY catalog (`config.vendor`) |
| `mb` | `list\|select\|check\|create\|design\|expand\|parts\|test` · `--board` · `--online` | Motherboard configure (`corev-mb`) |
| `tech` | `status\|specs\|plan\|check\|init` · `--tech` · `--pdk` | Technology-optimization pass (`CVA6_TECH_OPT`) |

### 2.4 Build / test / gate

| Command | Subcommands / flags | Role |
|---------|---------------------|------|
| `build` | `--iss` · `--elf` · `--force` · `--from-timing` · `--use-emit` | Makefile verilate / sim-verilator + incremental manifests |
| `test` | `<id…>` · `--suite` · `--group` · `--all` · `--open-source` · `--list` · `--from-timing` · `--use-emit` | `verif/regress` suites (skip missing tools) |
| `verify` | `--lint` · `--formal` · `--sim` · `--synth` · `--target` · `--tools` · `--from-timing` · `--use-emit` · `--json` | AGENTS.md §0.2 multi-stage gate |
| `timings` | `status\|**doctor**\|lab-run\|sta-handoff\|fo4-golden\|…` · `-o` · `--from-timing` · `--try-tools` · `--liberty` | Host adapter; **doctor** = readiness + FO4 retune checklist; **lab-run** = offline S0 report |
| `clean` | `status\|build\|diag\|…\|timings\|sta\|**svt**\|**svt-tools**\|sim\|all` · `--older-than` · **`--execution`** · `--target` · `--yes` | Free space (allowlisted); **svt** = package Cargo target |
| `config` | (see above) | |

### 2.5 `timings` package layout (`--output` / `-o`)

```text
<output>/
  portable.f
  analyze.json | correct.json
  param-map.json
  ir.sqlite
  stamp.json              # exitCode, mtimeMs, modules, command
  soak-dashboard.json     # host FO4 summary (T3b; not STA)
  corrected/              # correct --emit only
```

```bash
./build.sh timings compile --modules alu -o workspace/build/sv-timing/alu-pack --target-mhz 1250
./build.sh timings validate --from-timing workspace/build/sv-timing/alu-pack   # + dashboard
./build.sh timings summary --from-timing workspace/build/sv-timing/alu-pack    # dashboard only
./build.sh test sv-timing-smoke --from-timing workspace/build/sv-timing/alu-pack
```

- **`--from-timing DIR`:** structural validate then export `CVA6_FROM_TIMING` (suites may skip re-compile).
- **`--use-emit`:** expert; also export `CVA6_TIMINGS_EMIT_FLIST` (default **off**; never merges into `core/`).
- Lint/synth remain on **live RTL** unless a consumer explicitly reads emit env.

### 2.6 `clean` purposes & filters

| Purpose | Path (typical) | `--yes`? |
|---------|----------------|----------|
| `build` | `workspace/build` | no |
| `diag` / `verify` / `formal` / `timings` / `sta` | leaves under `build/` | no |
| `cache` / `manifests` / `downloads` | `workspace/.cache…` | no |
| `man` / `dts` / `firmware` | workspace sessions / DTS / **workspace/** smt2-linux | firmware yes |
| **`svt`** (`rust-target`, `sv-timing-target`, …) | **`sv-timing/target`**, `.sv-timing-out`, `.sv-timing-cache` | no |
| **`svt-tools`** | **`sv-timing/.tools`** (contained rustup/cargo) | **yes** |
| `tooling` / `sim` / `workspace` (`all`) | workspace tools / `work-ver` / entire ws | **yes** |

| Filter | Effect |
|--------|--------|
| `--older-than 7d\|12h\|30m` | mtime threshold (expands children under timings/diag/…) |
| `--execution last` | keep newest **ok** `stamp.json`; delete older packages |
| `--execution failed` | only `stamp.exitCode ≠ 0` |
| `--execution ok` | only successful stamps |
| `--target` / `--compartment` | path substring |

Bare `clean` (compat) = remove `workspace/build` only.

**Do not confuse:**

| Command | Removes | Does **not** remove |
|---------|---------|---------------------|
| `clean timings` | Host packages under `workspace/build/sv-timing/` (monorepo-soak, compile `-o`) | Cargo `sv-timing/target` |
| `clean svt` / `clean rust-target` | Package Cargo **`sv-timing/target`** (+ local out/cache) | Host timings packages |
| `clean svt-tools --yes` | Package **`sv-timing/.tools`** | Workspace `tooling/` |
| `python tools/svt.py clean` (in package) | Same Cargo/out dirs via package CLI | Host workspace |

Examples:

```bash
./build.sh clean status
./build.sh clean timings sta build          # host FO4 soak + STA handoff + build tree
./build.sh clean svt                        # free ~GiB Cargo artifacts
./build.sh clean rust-target --dry-run      # alias
./build.sh clean svt-tools --yes            # re-run: cd sv-timing && python tools/svt.py setup
```

---

## 3. Workspace artifact map

```text
build-platform/workspace/
  build/
    diagnostics/          # diag flat .f
    verify/               # verify manifests
    formal/<task>/        # SymbiYosys -d
    sv-timing/            # timings packages + monorepo-soak + verif-tests/
    sta-handoff/          # OpenSTA S0 seeds / correlate (clean sta)
  tooling/                # riscv, verilator-*, spike, oss-cad-suite, python-venv
  smt2-linux/             # OpenSBI dual-hart firmware (workspace copy)
  man/<id>/               # man HTML
  linux-dts/              # sparse DTS fetch
  .cache/{downloads,manifests}

repo root (opt-in clean — allowlisted leaves only):
  work-ver/               # Makefile ver-library (clean sim --yes)
  sv-timing/target/       # Cargo build (clean svt | rust-target)
  sv-timing/.tools/       # contained rustup/cargo (clean svt-tools --yes)
  sv-timing/.sv-timing-{out,cache}/  # package defaults (clean svt)
```

---

## 4. Suite groups & residual soaks (snapshot)

Configured in `defaults.ts` `tests.suites` (not exhaustive):

| Group / area | Example suite ids | Notes |
|--------------|-------------------|--------|
| smoke | `smoke-cv64a6`, `smoke-cv32a6`, … | Fast sanity |
| directed | `mc-stream-tests`, `mc-spo-soak`, `mc-spo-spike`, **`mc-mini-veri`**, `mc-spo-veri`, `ara-vector-path` | Optional/heavy; mini = hard Zacas golden |
| residual OpenSBI/DI | **`soft-ladder-di`**, **`soft-ladder-osbi`** | Optional; cookie SUCCESS `51b1babe`; RTL-max peel; diag `diag-soft-ladder-paths` |
| timings host | `sv-timing-smoke`, `sv-timing-core-sparse`, `sv-timing-autocorrect`, `sv-timing-advanced` | `--output` packages; honor `CVA6_FROM_TIMING` |
| ai-tensor host | `tensor status\|doctor\|test\|virt-card\|frameworks\|pytorch\|virt-impl\|regress` | Spawn-only; `--board virt-ai-pcie --core g6lc64_ai [--impl soft\|hard\|full] [--rtl-hard] [--from-timing DIR] [--use-emit]`; map `architecture/ai-matrix/frameworks-virt-pcie.md` |
| linux / SMT | `smt-linux-*`, `dual-hart-ci` | R3 cosim WSL path |
| formal (verify) | `verify.formalTasks` U5 OoO `.sby` | freelist / ROB / cancel |

Full catalog: `./build.sh test --list`.

---

## 5. Status matrix (platform features)

| Area | State |
|------|--------|
| Config surface + CLI registry | **done** |
| probe / install profiles / diag | **done** |
| verify lint/formal/sim/synth | **done** (sim host-dependent) |
| vendor / mb / tech | **done** (PDK opt-in) |
| Granular clean (purpose/age/`--execution`/`sta`/`**svt**`/`svt-tools`) | **done** |
| timings compile `-o` + validate / summary / `--from-timing` | **done** (T0–T3b) |
| OpenSTA handoff S0–S2 + S4a + `lab-run` / `lab-report` | **done** (soft-skip without tools); CI runs lab-run; S3b-lab FO4 retune + S4b LEF open |
| Bench × FO4 correlate (`timings correlate --bench`) | **done** (scaffold) |
| Windows VS Build Tools provisioning | **planned** |
| PnR / OpenROAD / OpenSTA synth (S1–S4) | **planned** — `architecture/build-platform-opensta-from-timing.md` |
| Dual-ISS Spike+Verilator polish | **done** (suite `dual-iss-regress` tohost golden) |
| R3b Linux Image gate | **done** (suite `r3b-linux-image`; Image still external) |
| CRT `mc-spo-veri` | **imafdc 9/9** + **server_math L2 9/9** + **stream8 9/9** (DeepSpec STQ; Verilator 5.008); dual-hart-ci host residual green |
| Soft-ladder residual scaffold | Suites **`soft-ladder-di`** / **`soft-ladder-osbi`** cataloged optional; diag path-check; max B1 RTL peels — see `architecture/multi-threading/soft-ladder/README.md` |

---

## 6. Spec / ISA hooks related to residual soaks

| Feature | Spec | Platform / test touchpoint | Status summary |
|---------|------|----------------------------|----------------|
| **Zacas** compare-and-swap | Vol I §5.9 `#ext:zacas` · `agents/spec/riscv-spec-I-5.9-zacas.html` | `mc-mini-veri` (hard RTL) · `mc-spo-spike` / `mc-stream-tests` / `mc-spo-soak` · residual `mc-spo-veri`; `RVZacas` packages | **W/D/Q functional** (`zacas-policy` 4/4); Spike never CAS golden |
| **RVV / Ara** | Vol I ch9 `#vector` · `riscv-spec-I-9-vector.html` | suite `ara-vector-path`; `timings` structural only | **Partial:** attach + DTS + directed; `ara-vector-cosim` gate; live lmul/OpenSBI VRF lab-optional |
| Structural FO4 | package `sv-timing/` (not ISA) | `timings compile` / monorepo-soak / soaks | Screening only — not STA; see §6.1 |

### 6.1 Structural FO4 timing adjustments (host ↔ package)

FO4 from `sv-timing` is **screening**, not silicon sign-off. Host and package share a budget model:

\[
\texttt{budget\_fo4} = \frac{1000/\texttt{target\_mhz} \times 1000}{\texttt{fo4\_ps}} \times (1 - \texttt{margin})
\]

Default `fo4_ps=20`, `margin=0.2` → **~32 FO4 @ 1250 MHz**, **~20 FO4 @ 2000 MHz**.

| Layer | What to use | Notes |
|-------|-------------|--------|
| Package soak | `cd sv-timing && python tools/svt.py monorepo-soak [--target-mhz 1250\|2000] [--correct --emit --allow-latency]` | Sparse real `core/` flists; **package-first** fixes (`path_class`, BalanceMux, relocation) |
| Host package dir | `timings validate\|summary\|sta-handoff --from-timing <dir>` | Dashboard overlays `correct.json` `post_closure`; hottest list is **primary-first** (multi_cycle tagged) |
| Host compile | `timings compile … -o workspace/build/sv-timing/…` | Writes portable.f + analyze; then validate/test |
| Free space | `clean timings` vs `clean svt` | Host soak packages vs Cargo target (see §2.6) |

**Scale experiments:** raising `--target-mhz` does not change path FO4 much after path_class; it tightens the budget so more paths fail. Auto-correct can still improve primary FO4 (e.g. BalanceMux hot-arm stage) but 2 GHz (~20 FO4) typically needs multi-cycle/microarch beyond current latency-neutral rewrites. Never retune `fo4-v1` from STA **fixtures**; only from real STA + `retune-propose` (S3b-lab).

Philosophy loop: `AGENTS-coding-philosophy.md` §2.8. Package design: `sv-timing/architecture/MONOREPO-SOAK.md`, `FO4-ALGORITHM-UPGRADES.md`, `RELOCATION-ANALYSIS.md`.

Maps: `AGENTS-specs-to-impl.md` · `AGENTS-specs-to-tests.md` · `AGENTS-specs-coverage.md`.

---

## 7. Host track status + still open

### Host offline complete (do not re-open without a lab tool)

| Slice | Status |
|-------|--------|
| Clean purposes + age + execution | done |
| `--from-timing` / `--output` packages | done |
| S0 seeds.sdc + fo4_paths + correlate scaffold | done |
| S1 Yosys / S2 OpenSTA soft-skip | done |
| S3a FO4↔STA overlap + **offline fixture inject** | done (`lab-run` default) |
| S3b host FO4 golden check | done |
| S3b-lab **retune-propose** (review-only; never edits fo4-v1) | done |
| S4a OpenROAD floorplan.tcl scaffold | done |
| doctor / lab-run / lab-report / CI asserts | done |

### Still open (lab PD or residual)

1. **S3b-lab (package edit)** — retune `sv-timing` FO4 table from **real** STA using `retune-proposal.md`
   (host propose + fixture guard done; gate `s9-lab-gate`).  
2. **S4b OpenROAD + LEF** — open-PDK/NDA tech under `pd/pdk/` (scaffold already).  
3. **Full `verify --sim` on Windows CI** — preflight + Git-Bash prefer done; needs riscv-gcc/verilator (+ WSL spike).  
4. ~~AMOCAS.Q~~ **done** · ~~stream8 residual~~ **done** (CRT 9/9 + H 3/3 + stability stream8 6/6) · · dual-hart-ci residual soft lint/R3 skip when host-skewed · R3b Image (soft-skip gate) · dual-ISS · OpenSBI/Ara live still lab-optional.  
5. **Optional** Windows VS Build Tools provisioning.  

**Lab tip (offline S3a + retune propose + optional real S2):**  
```bash
./build.sh timings lab-run                 # inject fixture → overlap_score + retune-proposal
./build.sh timings retune-propose          # re-emit from latest correlate
CVA6_LIBERTY=/path/to.lib ./build.sh timings lab-run --no-sta-fixture --try-tools
```

**Plan of record:** [`architecture/build-platform-opensta-from-timing.md`](architecture/build-platform-opensta-from-timing.md).  
Live checklist: [`AGENTS-todo.md`](AGENTS-todo.md) phase 12.

---

## 8. Relationship to other AGENTS files

| File | Role |
|------|------|
| `AGENTS-build.md` | Thin entry pointer → this file + `build-platform/AGENTS.md` |
| `build-platform/AGENTS.md` | Extension playbook (add option/command/tool/suite) |
| `build-platform/README.md` | User quickstart |
| `architecture/build-platform-workspace-lifecycle.md` | Clean / timings hand-off design of record |
| `AGENTS-todo.md` | Phase checklist |
| `AGENTS.md` §0.2 | Verify gate as SoC readiness mechanism |

---

*Agents: prefer updating this file when adding a CLI command, clean purpose, timings flag, or residual suite so the top-level map stays one hop from the registry.*
