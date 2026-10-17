# AGENTS-build-platform — command structure & workspace state

> **Top-level agent map** for the LibreCore **build-platform** (Bun + TypeScript under
> `build-platform/`). Complements the thin pointer [`AGENTS-build.md`](AGENTS-build.md)
> and the extension playbook [`build-platform/AGENTS.md`](build-platform/AGENTS.md).
>
> **Last reviewed:** 2026-10-09 — registry now 21 commands (`tensor`, `remote`, `g6q`,
> `g6b`, `ai-overlay` added); repo-level `clean traces|runs|repo-cache|regen|stale`
> with evidence holds; `verify --qualification|--ai-overlay|--remote`; per-target synth
> pass recipes; patched-Verilator check; CI lanes driven through `./build.sh`.

---

## 1. Identity & entry points

| Item | Value |
|------|--------|
| Control surface | Repo-root [`.config.ts`](.config.ts) → `schema` / `defaults` / `load` (top-level keys: `meta workspace soc toolchain simulation tests dependencies vendor motherboard physicalDesign technology verify diagnostics platform logging`) |
| CLI entry | `bun build-platform/src/cli/index.ts <cmd>` |
| Wrappers | `./build.sh` / `.\build.ps1` (bootstrap Bun) · `cva6-build` via `setenv.*` |
| Workspace | `build-platform/workspace/` (gitignored; **safe to delete**) |
| Invariants | Zero runtime npm deps · deletes allowlist-confined · strict TS + `bun test` green · **MIT** (tier T; generated headers MIT too) |
| Authoritative how-to | `build-platform/AGENTS.md` §4 (add config / command / tool / suite) |
| Lifecycle plan | `architecture/build-platform-workspace-lifecycle.md` |

**Standing operator loop**

```text
probe / doctor  →  tools install | setup --install  →  probe install  →  diag  →  verify / test
         optional: timings compile -o <dir>  →  validate / test --from-timing <dir>
         optional: monorepo FO4 soak (package) → timings validate/sta-handoff --from-timing
         remote:   remote <proxy-subcommand>   (SSH + rsync + Verilator on a big host)
         packages: g6b <type> · g6q <sub> · tensor <sub>   (spawn-only gateways)
         free space: clean status  →  clean stale --dry-run  →  clean <purpose> [--yes]
```

---

## 2. Command catalog (current registry)

Source of truth: `build-platform/src/cli/registry.ts` (`COMMANDS` order); per-command
`usage` strings are authoritative for flags (`<cmd> --help`).

### 2.1 Observe / host

| Command | Subcommands / flags (high-signal) | Role |
|---------|-----------------------------------|------|
| `status` | `--json` | SoC target, toolchain, workspace, subsystems (no deep PATH scan) |
| `doctor` | `--json` | Quick PATH readiness + managed tools summary |
| `probe` | `host\|platform\|pkg\|utils\|tools\|env\|diag\|commands\|install\|list` · `--deep` · `--json` | Categorical capability boxes + command matrix + install playbook |
| `diag` | `list\|status\|run [compartment\|id…]` · `--ai` · `--all` · `--from-timing DIR` · `--json` | Compartmentalized gates; **per-test Verilator surfaces** (36 tests) |
| `man` | `[id?] [files…] [query…]` · `--list` · `--no-open` · `--print` | Human man pages via Grok headless → `workspace/man/` |
| `config` | `--json` | Dump resolved `.config.ts` merge |

**Diag compartments:** `host` · `core` · `smt2` · `residual` · `ooo` · `ai` · `apu`
(default run: `host` + `core`; config `diagnostics.tests[]` / `defaultCompartments`).
`diag status` also reports whether the managed Verilator carries the LibreCore patches.

### 2.2 Provision

| Command | Subcommands / flags | Role |
|---------|---------------------|------|
| `setup` | `--install` · `--profile sim\|dual-hart\|opensbi\|all` · `--allow-system-install` · `--skip-submodules` · `--dry-run` | Workspace + submodules + optional tool install |
| `tools` | `list\|install [profile\|recipe]` · `--json` | Managed toolchain under `workspace/tooling/` |

**Install profiles:** `sim` / `open-source-sim` · `dual-hart` · `opensbi` · `formal` · `all`
**Recipes:** `riscv-gcc` · `verilator` · `spike` · `iverilog` · `opensbi-smt2` · `formal` (Yosys ≥ 0.67 from the `tools/yosys` submodule, integrated slang + SymbiYosys; Windows via WSL). Builder prefix: `build-platform/scripts/install-yosys-g6lc.sh`, same role as `install-verilator-g6lc.sh`.

**Patched Verilator.** The gate's Verilator is the pinned tag **plus** every
`verif/regress/verilator-*.patch` (today `verilator-v5.patch`). `tooling/verilatorPatch.ts`
verifies by content (added lines present under `share/verilator/include/`, `--version`
"(mod)") and is shared by `tools install verilator`, `diag status` and the sim preflight,
so an unpatched tool cannot pass silently.

### 2.3 Uncore / board / foundry

| Command | Subcommands | Role |
|---------|-------------|------|
| `vendor` | `list\|status\|sync\|add\|update\|scan` · `--all` · `--ref` · `--dry-run` | Controller/PHY catalog (`config.vendor`) |
| `mb` | `list\|select\|check\|create\|design\|expand\|parts\|test\|ingest` · `--board` · `--from <platform.json>` · `--online` · `--fix` | Motherboard configure (`corev-mb`); AI-island boards emit DTS/profile/env + `MbAi_*` |
| `tech` | `status\|specs\|plan\|check\|init [tech-id]` | Technology-optimization pass (`CVA6_TECH_OPT`) |
| `ai-overlay` | `pin\|check\|list` · `--target <g6lc64_pkg>` · `--int` · `--island-cfg` | Pin the island overlay as generated `<pkg>_ai` packages + DTS; `check` = drift test |

### 2.4 Build / test / gate

| Command | Subcommands / flags | Role |
|---------|---------------------|------|
| `build` | `--iss` · `--elf` · `--force` · `--from-timing` · `--use-emit` | Makefile verilate / sim-verilator + incremental manifests |
| `test` | `<id…>` · `--suite` · `--group` · `--all` · `--open-source` · `--list` · `--ai` · `--ai-remote` · `--ai-qemu` · `--channels N` · `--ai-dram 0\|1` · `--from-timing` · `--use-emit` | `verif/regress` suites (preflight skips missing tools) |
| `verify` | `--lint` · `--formal` · `--sim` · `--synth` · `--target` · `--qualification smt2-cookie\|perf-foundation` · `--ai` · `--ai-overlay [--ai-overlay-int]` · `--remote` · `--allow-skips` · `--from-timing` · `--use-emit` · `--json` | AGENTS.md §0.2 multi-stage gate |
| `timings` | `status\|doctor\|flist\|compile\|analyze\|area\|correct\|validate\|summary\|dashboard\|sta-handoff\|sta-rtl\|correlate\|fo4-golden\|retune-propose\|parse-bench-log\|lab-run` · `-o` · `--from-timing` · `--budget-fo4 N\|--fo4 N` · `sta-rtl`: `--target --platform\|--liberty --remote --map-recipe --allow-over-budget --svt-args --no-sram-stub --rebuild-openroad` | sv-timing host adapter; **doctor** = readiness + FO4 retune checklist; **lab-run** = offline S0 report; **sta-rtl** = the integrated structural→gate-level route (§7.1) |
| `tools install openroad` / profile `timing` | `toolchain.openroad.{flavour,march,pgo,jobs,threads,cmakeArgs}` | Managed `tools/openroad` fork (submodule init of `src/sta` + `third-party/abc`, `-march`, PGO) into `workspace/tooling/openroad-g6lc` (`openroad` + `sta`); WSL on Windows |
| `tensor` | `status\|doctor\|probe\|test\|golden\|cosim\|queue-soak\|rtl\|rtl-hard\|virt-card\|frameworks\|pytorch\|virt-impl\|regress\|check` · `--board` · `--core` · `--impl soft\|hard\|full` · `--suite` · `--backend sim\|mmio\|virt-card` | Spawn-only adapter for `ai-tensor/` |
| `remote` | `[--remote-ssh <host>] [--ai] [--channels N] <proxy-subcommand> …` | Gateway to `verif/regress/remote/testharness_proxy.py` (SSH + rsync + Verilator); pulls land in `remote-runs/<tag>/` |
| `g6q` | `[--remote] [--ai] [--from-timing DIR] <subcommand> …` | Gateway to `g6lc_qemu/tools/g6q.py` (`--remote` → `g6q_remote.py`) |
| `g6b` | `zealcli\|browser\|libwasm\|full\|test\|check\|all` | Gateway to `g6lc_bios/tools/build.py` (auto-provisions cargo/bun/LDC; falls back to `tools install`) |
| `clean` | see §2.6 | Free space (allowlisted) |

**`verify` configuration** (`config.verify`): `targets` (default `cv64a6_imafdc_sv39`,
`cv32a65x`), `stages`, `simSuites`, `formalTasks` (16 `.sby`; `formal.jobs` / `taskJobs`
/ `remote`), `qualifications`, and per-target overrides `topByTarget`, `synthTopByTarget`,
`synthSlangArgsByTarget`, `extraFlistsByTarget`, **`synthPassesByTarget`** (e.g.
`g6lc64_ooo_server` drops `opt -fast`, whose OPT_MERGE does not finish at that size).
`warningBaseline` / `warningBaselineRemote` gate lint regressions.

**SI knobs** (`tooling/aiTesting.ts`, shared by `test` / `diag` / `verify` / `remote` /
`g6q`): `--ai`, `--channels N`, `--ai-dram 0|1`, `--ai-remote`, `--ai-qemu`; resolved
values are stamped onto the child env (`AI_ISLAND_DRAM_*`, `S4_FLAVOUR`).

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

**Workspace + package leaves**

| Purpose | Path (typical) | `--yes`? |
|---------|----------------|----------|
| `build` | `workspace/build` | no |
| `diag` / `verify` / `formal` / `timings` / `sta` | leaves under `build/` | no |
| `cache` / `manifests` / `downloads` | `workspace/.cache…` | no |
| `man` / `dts` / `firmware` | workspace sessions / DTS / **workspace/** smt2-linux | firmware yes |
| **`svt`** (`rust-target`, `sv-timing-target`, …) | **`sv-timing/target`**, `.sv-timing-out`, `.sv-timing-cache` | no |
| **`svt-tools`** | **`sv-timing/.tools`** (contained rustup/cargo) | **yes** |
| `tooling` / `sim` / `workspace` (`all`) | workspace tools / `work-ver` / entire ws | **yes** |

**Repo-level leaves** (`workspace.clean` in `.config.ts`; selection applies *holds*)

| Purpose (alias) | Removes | Keeps | `--yes`? |
|-----------------|---------|-------|----------|
| **`traces`** (`remote-traces`) | `.dasm` / `.traces` / `.vcd` / `.fst` / `.fsdb` inside `remote-runs/<tag>/` | logs, `results.json`, summaries, the run dir | **yes** |
| **`runs`** (`remote-runs`) | whole runs superseded in their tag family (tag minus `-rN`, `-YYYYMMDDTHHMMSS-<hash>`, `-old/-new`) | newest `keepRunsPerFamily` (2) per family | **yes** |
| **`repo-cache`** | stale children of repo-root `.cache/` | recently modified entries | **yes** |
| **`regen`** (`regenerable`) | `regenerableDirs`: `g6lc_qemu/target`, `g6lc_bios/target`, `ai-tensor/target`, `mbgen/target`, `quantum_ai/intuition_synthetics/target`, `mbgen/mbsim/MbgenSim/Intermediate/Build`, `docs/website/.next` | recently used dirs | no |
| **`stale`** | all four above | holds still apply | per purpose |

Holds: **active** (modified within `activeAgeDays`, default 3 — live sims/caches),
**cited** (run tag referenced by any tracked file of `citationExtensions` = evidence for a
recorded result), **kept** (newest-N per family). `--include-active` / `--include-cited`
lift them. `remote-runs/builds/` (manifests referenced by `verify.qualifications`) is
never listed. `clean status` shows reclaimable bytes after holds plus held counts;
`traces` and `runs` overlap (a removed run takes its traces with it).

| Filter | Effect |
|--------|--------|
| `--older-than 7d\|12h\|30m` | mtime threshold (expands children under timings/diag/…; applies to repo-level parts) |
| `--execution last` | keep newest **ok** `stamp.json`; delete older packages |
| `--execution failed` | only `stamp.exitCode ≠ 0` |
| `--execution ok` | only successful stamps |
| `--target` / `--compartment` | path substring |
| `--include-active` / `--include-cited` | lift repo-level holds |

Bare `clean` (compat) = remove `workspace/build` only. The repo-level scan (remote-runs
walk + citation grep of `git ls-files`) runs only for `status` or a repo-level purpose.

**Do not confuse:**

| Command | Removes | Does **not** remove |
|---------|---------|---------------------|
| `clean timings` | Host packages under `workspace/build/sv-timing/` (monorepo-soak, compile `-o`) | Cargo `sv-timing/target` |
| `clean svt` / `clean rust-target` | Package Cargo **`sv-timing/target`** (+ local out/cache) | Host timings packages |
| `clean svt-tools --yes` | Package **`sv-timing/.tools`** | Workspace `tooling/` |
| `clean regen` | Other packages' Cargo/UE/Next outputs | `sv-timing/target` (that is `svt`) |
| `clean traces --yes` | Trace dumps only | Run logs / results (evidence) |
| `python tools/svt.py clean` (in package) | Same Cargo/out dirs via package CLI | Host workspace |

Examples:

```bash
./build.sh clean status
./build.sh clean stale --dry-run               # review every repo-level candidate + holds
./build.sh clean traces --yes                  # largest win: remote-run trace dumps
./build.sh clean runs --older-than 14d --dry-run
./build.sh clean timings sta build             # host FO4 soak + STA handoff + build tree
./build.sh clean svt                           # free ~GiB Cargo artifacts
./build.sh clean svt-tools --yes               # re-run: cd sv-timing && python tools/svt.py setup
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
  tooling/                # riscv, verilator-* (patched), spike, formal, oss-cad-suite, python-venv
  smt2-linux/             # OpenSBI dual-hart firmware (workspace copy)
  man/<id>/               # man HTML
  linux-dts/              # sparse DTS fetch
  .cache/{downloads,manifests}

repo root (opt-in clean — allowlisted leaves only):
  work-ver/               # Makefile ver-library (clean sim --yes)
  sv-timing/target/       # Cargo build (clean svt | rust-target)
  sv-timing/.tools/       # contained rustup/cargo (clean svt-tools --yes)
  sv-timing/.sv-timing-{out,cache}/  # package defaults (clean svt)
  remote-runs/<tag>/      # remote proxy pulls (clean traces | runs --yes); builds/ protected
  .cache/<entry>/         # repo-root scratch (clean repo-cache --yes)
  <pkg>/target/ …         # regenerable build outputs (clean regen)
```

---

## 4. Suite groups & residual soaks (snapshot)

Configured in `defaults.ts` `tests.suites` — 86 suites; default run `smoke-cv64a6`.

| Group (count) | Example suite ids | Notes |
|---------------|-------------------|--------|
| smoke (3) | `smoke-cv64a6`, `smoke-cv32a6`, `smoke-cv32a65x` | Fast sanity |
| arch (5) | `riscv-tests`, `riscv-arch-test`, `riscv-compliance`, `csr-access`, `mmu-sv32` | Compliance |
| directed (56) | `mc-stream-tests`, `mc-spo-soak`, `mc-spo-spike`, **`mc-mini-veri`**, `mc-spo-veri`, `zacas-policy`, `ara-vector-path`, `ooo-l3-tests`, `kvm-h-*`, `stream8-smoke`, `dual-hart-ci`, `stability-regress` | Optional/heavy; mini = hard Zacas golden |
| directed — AI island | `ai-config-smoke`, `ai-matrix-directed`, `ai-matrix-veri`, `ai-island-veri`, `ai-policy-*`, `ai-native-eval`, `ai-desc-formats`, `ai-fp-mac`, `ai-dram-*`, `ai-litedram-wrap`, `ai-s4-mshr-xbar` | `--ai` / `--channels` / `--ai-dram` knobs |
| directed — residual OpenSBI/DI | **`soft-ladder-di`**, **`soft-ladder-osbi`**, **`smt2-ai-tensor-track`**, `smt-linux-boot-path`, `qual-*` | Cookie SUCCESS `51b1babe`; qualification profiles |
| directed — timings host | `sv-timing-smoke`, `sv-timing-core-sparse`, `sv-timing-autocorrect`, `sv-timing-advanced`, `timings-sta-handoff`, `s9-lab-gate` | `--output` packages; honor `CVA6_FROM_TIMING` |
| benchmark (7) | `dhrystone`, `coremark`, `ai-ops-bench`, `ai-scale-ladder`, `ai-ops-bench-soc` | Cycle counts at the built geometry, not timing closure |
| linux (6) | `ai-qemu-linux`, `smt-linux-rootfs`, `r3b-linux-image`, `linux`, `u-boot-build`, `edk2-build` | R3 cosim WSL path |
| pk / uvm / generated | `pk-tests` · `interrupt`, `pmp`, `cvxif`, … · `smoke-gen`, `generated-xif` | Upstream-derived |
| formal (verify) | `verify.formalTasks` (16 `.sby`) | OoO freelist / ROB / cancel / rename / age, fetch frontend (align/order/redirect/SMT/IQ/…), AI-island flat-panel GEMM |

Full catalog: `./build.sh test --list`. ai-tensor host track: `tensor …` (spawn-only;
HARD catalog `architecture/ai-matrix/hard-tests.md`).

---

## 5. Status matrix (platform features)

| Area | State |
|------|--------|
| Config surface + CLI registry (21 commands) | **done** |
| probe / install profiles (incl. `formal`) / diag (7 compartments) | **done** |
| Patched-Verilator content check (install / diag / preflight) | **done** |
| verify lint/formal/sim/synth + qualifications + per-target synth passes | **done** (sim host-dependent) |
| vendor / mb / tech / ai-overlay pin + drift | **done** (PDK opt-in) |
| Granular clean (purpose/age/`--execution`/`sta`/`svt`/`svt-tools`) | **done** |
| Repo-level clean (`traces`/`runs`/`repo-cache`/`regen`/`stale`, holds) | **done** |
| timings compile `-o` + validate / summary / `--from-timing` | **done** (T0–T3b) |
| OpenSTA handoff S0–S2 + S4a + `lab-run` / `lab-report` | **done** (soft-skip without tools); CI runs lab-run; S3b-lab FO4 retune + S4b LEF open |
| Bench × FO4 correlate (`timings correlate --bench`) | **done** (scaffold) |
| Package gateways `remote` / `g6q` / `g6b` / `tensor` | **done** (spawn-only) |
| CI lanes through `./build.sh` (GitHub + GitLab, §5.1) | **done**; BIOS regress lane residual |
| Windows VS Build Tools provisioning | **planned** |
| Gate-level STA with the `tools/openroad` fork (`tools install openroad\|timing`, `timings sta-rtl [--remote]`) | **done** — yosys liberty map + `openroad-timing.tcl`; study liberties from the fork's `test/` platforms; builder route builds the fork with `-march`/PGO |
| PnR / OpenROAD place-and-route (S4b, LEF) | **planned** — `architecture/build-platform-opensta-from-timing.md` |
| Dual-ISS Spike+Verilator polish | **done** (suite `dual-iss-regress` tohost golden) |
| R3b Linux Image gate | **done** (suite `r3b-linux-image`; Image still external) |
| CRT `mc-spo-veri` | **imafdc 9/9** + **server_math L2 9/9** + **stream8 9/9** (DeepSpec STQ; Verilator 5.008); dual-hart-ci host residual green |
| Soft-ladder residual scaffold | Suites **`soft-ladder-di`** / **`soft-ladder-osbi`** cataloged optional; diag path-check — see `architecture/multi-threading/soft-ladder/README.md` |
| SMT2 × ai-tensor track | Suite **`smt2-ai-tensor-track`** (default profile **fast**); map `architecture/multi-threading/smt2-ai-tensor-linux.md` |

### 5.1 CI lanes (build-platform is the control surface)

`.github/workflows/ci.yml` and `.gitlab-ci.yml` mirror each other; each lane checks out
only the submodules it needs and calls `./build.sh` wherever a surface exists.

| Lane | Commands |
|------|----------|
| platform | `bun test` + `tsc` · `config` · `status` · `test --list` · `test --open-source --dry-run` · `diag list` · `diag run host` · `timings doctor` · `timings lab-run` |
| rtl-lint | `tools install verilator` (v5.008 + `verilator-v5.patch`) · `diag status` · `diag run core …` (core / SMT2 / OoO / AI packages) |
| sv-timing | `svt.py setup/doctor/test` · `test sv-timing-smoke` · `svt.py check` (informational) |
| bios | `g6b check --rust-only` + `bios-regress` |
| qemu | `g6q doctor` · `g6q check` |
| ai-tensor | `tensor doctor` · `tensor test` + python unit tests |
| smoke | optional heavy Verilator smoke |

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

Default `fo4_ps=20`, `margin=0.2` → **~32 FO4 @ 1250 MHz**, **~20 FO4 @ 2000 MHz**.

| Layer | What to use | Notes |
|-------|-------------|--------|
| Package soak | `cd sv-timing && python tools/svt.py monorepo-soak [--target-mhz 1250\|2000] [--correct --emit --allow-latency]` | Sparse real `core/` flists; **package-first** fixes (`path_class`, BalanceMux, relocation) |
| Host package dir | `timings validate\|summary\|sta-handoff --from-timing <dir>` | Dashboard overlays `correct.json` `post_closure`; hottest list is **primary-first** (multi_cycle tagged) |
| Host compile | `timings compile … -o workspace/build/sv-timing/…` | Writes portable.f + analyze; then validate/test |
| Free space | `clean timings` vs `clean svt` | Host soak packages vs Cargo target (see §2.6) |

**Scale experiments:** raising `--target-mhz` does not change path FO4 much after path_class; it tightens the budget so more paths fail. Auto-correct can still improve primary FO4 (e.g. BalanceMux hot-arm stage) but 2 GHz (~20 FO4) typically needs multi-cycle/microarch beyond current latency-neutral rewrites. Never retune `fo4-v1` from STA **fixtures**; only from real STA + `retune-propose` (S3b-lab).

Philosophy loop: `AGENTS-coding-philosophy.md` §2.8. Package design: `sv-timing/architecture/MONOREPO-SOAK.md`, `FO4-ALGORITHM-UPGRADES.md`, `RELOCATION-ANALYSIS.md`.

Maps: `AGENTS-specs-to-impl.md` · `AGENTS-specs-to-tests.md` · `AGENTS-specs-coverage.md`.

---

## 7. Host track status + still open

### Host offline complete (do not re-open without a lab tool)

| Slice | Status |
|-------|--------|
| Clean purposes + age + execution | done |
| Repo-level clean + evidence holds | done |
| `--from-timing` / `--output` packages | done |
| S0 seeds.sdc + fo4_paths + correlate scaffold | done |
| S1 Yosys / S2 OpenSTA soft-skip | done |
| S3a FO4↔STA overlap + **offline fixture inject** | done (`lab-run` default) |
| S3b host FO4 golden check | done |
| S3b-lab **retune-propose** (review-only; never edits fo4-v1) | done |
| S4a OpenROAD floorplan.tcl scaffold | done |
| Managed `openroad` recipe (tools/openroad fork, submodule init, `-march`, PGO) + `sta-rtl` local/remote | done |
| doctor / lab-run / lab-report / CI asserts | done |

### 7.1 The integrated route — `timings sta-rtl` (structural → gate-level, one command)

**A118 provenance correction:** a live `--fo4 0` run no longer joins a
leftover `svt/correct.json` from an earlier emitted tree. Its calibration
has mapped values and missing structural columns. Reused or newly emitted
packages carry their own paired report path. Cell/FO4 and ns/FO4
correlations are screening aids, not alternative definitions of 10 FO4.

**A119 placement discriminator:** `scripts/openroad-module-place-study.tcl`
adds a fixed, paired IQ floorplan/placement/repair experiment to the isolated
`verif/regress/remote/run_fo4_control_review.py` runner. `CONTROL_MODE=placed-iq`
and `CONTROL_REFERENCE=<completed paired run output>` reuse immutable mapped
netlists; upload the Tcl alongside the source archive. It reports uncut
pre-CTS timing, repaired area, buffer count, placement checks and electrical
violations. It is a standalone module experiment, not a change to the default
whole-core flow or a routed sign-off gate. A119 evidence is under
`workspace/build/sv-timing/selection-a119/placed-margin/`.

A120 generalizes that same discriminator to `CONTROL_MODULE=g6lc_rename`
or `store_buffer` (default remains `g6lc_iq`). The paired source snapshots
and fixed placement recipe remain explicit. It selected the rename write-mask
candidate and rejected the IQ count-bank and store-gather trials; artifacts
are under `workspace/build/sv-timing/precompute-a120c/`.

```bash
./build.sh timings sta-rtl --target g6lc64_ooo --platform nangate45 --fo4 10 --allow-over-budget --remote --map-recipe streamed
```

One command, five labelled stages (`tooling/rtlTiming.ts`); every stage reports
PASS / FAIL / SKIP / STUDY and the host classifies from `RESULT`/`STA_RESULT`
lines, never from an exit code:

| Stage | What runs | Produces |
|---|---|---|
| **s0-width-map** (remote, A113) | when `svt/width-map.json` does not hash to this tree's sources: phase A of the **live** tree on the builder (slang + word-level lowering, own run dir `<target>-widthmap`) and `rtlil_width_map.py` with the host's source hash recorded, pulled back before the pre-pass. The pre-pass therefore always plans on elaborated widths and knows which modules the target instantiates; without this the fresh map served only the *next* run | `svt/width-map.json`, `widthmap-remote.log` |
| **s0-svt-correct** | sv-timing `correct --all-modules --allow-latency --emit` on the target's portable flist at the budget (`--fo4 N` → the clock sv-timing derives: 10 FO4 = 4000 MHz at `fo4Ps` 20, margin 0.2); the cfg snapshot (`svt/cfg-snapshot.json`, 222 elaborated `CVA6Cfg` fields) is merged into `svt/param-map.json`; with the width map only the **instantiated** modules are planned (`--include-uninstantiated` restores all), and the verdict is the live design's — the dead modules' worst is reported beside it | `workspace/build/sta-rtl/<target>/svt/{portable.f, correct.json, corrected/, svt_corrected.f}`; the completion gate: a budget **MISS stops before mapping** unless `--allow-over-budget` (result labelled **STUDY**); the stage detail says `elaborated widths` or `heuristic widths` |
| **s1-yosys-map** | Yosys (managed formal build) on the live tree or the emitted overlay (`emitFlist`), `tc_sram` replaced by the registered macro stub unless `--no-sram-stub`; `--map-recipe lean` (default), `hierarchical`, `synth`, or **`streamed`** (remote: phase A word-level RTLIL + module list + `width-map.json`; phase B one yosys per module in parallel, delay-oriented ABC `&st; &dch -f; &nf -D <period>` then plain then `-fast` under `timeout`, resume cache keyed on the module RTLIL's sha256) | `netlist.v`, `mapped/*.v`, `maplog/*.log`, `SYNTH_STREAM_FALLBACK plain= fast= cached= fail=`; pulls `svt/width-map.json` (`s1-width-map`) |
| **s2-openroad-sta** | the fork's `sta` (liberty-only link; `openroad` needs `OR_LEF`) runs `scripts/openroad-timing.tcl` against the generated SDC (`--clock-port`, default `clk_i`, at `--target-mhz`, default `soc.targetFrequencyMHz`; I/O delays 20 % of the period) | `reports/paths-{max,min}.rpt`, `summary.txt`, `STA_RESULT top= wns_max= tns_max= wns_min= tns_min= ignored_fanout_drivers=` |
| **s3-calibration** (streamed, A113) | the per-module board (`openroad-module-board.tcl`, one `sta` per mapped module in parallel, RTL net names) and its join with the pre-pass's emitted re-analysis, **worst mapped path of any kind first** (`mapped_any_ns`: an in→reg product such as the multiplier's is a reg→reg path of the flat core that a reg→reg ranking never shows), then the reg→reg cells calibration: `cells_per_fo4` and a reading (`tracks` 0.6–2.0, `over-read`, `under-read`, `boundary path`; cones under 8 cells unclassified) — the structural model is checked against OpenSTA on every run | `module-board.tsv`, `calibration.tsv`, the stage detail (`N track, M over-read, K under-read of T; worst mapped: …`) |

**Flags and config** — `--max-cells-per-fo4 N` / `physicalDesign.structural.maxCellsPerFo4` (16; sv-timing Dial 11: a register cut or select is refused when its preliminary cells per FO4 of gain exceed N; the previous run's `calibration.tsv` is passed as `--feedback` and scales the limit per module by the measured cells/FO4), `--tradeoffs N` / `tradeoffRows` (24; the area/depth ledger printed after the run, largest preliminary cell estimate first), `--fo4 N|--budget-fo4 N` (default `physicalDesign.structural.fo4Budget` 10; `--fo4 0` = live RTL), `--from-timing <pkg>` (reuse an emit), `--svt-args "…"` (raw sv-timing dials appended to `physicalDesign.structural.svtArgs` = `--opt-max-stages-per-region 13 --real-cut-feeds --assume-clk`; do not repeat a dial the config already sets), `--allow-over-budget` / `physicalDesign.structural.allowOverBudget`, `--platform nangate45|sky130hd|sky130hs` (study liberty from the fork's `test/`; `--liberty`, `physicalDesign.pdk.liberty`, `CVA6_LIBERTY` win), `--remote` (proxy `sync` + one script on the builder; builds the fork there when absent — `toolchain.openroad.{march,pgo,jobs}`, `nproc` threads; `--rebuild-openroad` forces), `--threads` / `toolchain.openroad.threads` (0 = every core → `set_thread_count`).

**Environment knobs of the Tcl** — `OR_THREADS`, `OR_REPORT_DIR`, `OR_LEF`, and `OR_IGNORE_FANOUT_ABOVE=N` (disable the leaf drivers of nets with more than N flat loads: a **labelled logic-depth study** of an unbuffered netlist, never sign-off — the whole-core `wns` is broadcast fanout until `repair_design`).

**Per-module study scripts** (on a streamed run's artifacts):

| Script | Purpose | Output |
|---|---|---|
| `scripts/openroad-module-board.tcl` | one `sta` per `mapped/*.v`, children black-boxed, inputs ideal, broadcast drivers > 64 loads disabled; the worst register-to-register path per module | `module-board.tsv`: `module instances clock worst_reg2reg_ns cells_on_path startpoint endpoint worst_any_ns broadcast_drivers_disabled start_net end_net trace` — **cells** is the depth metric that survives the fanout model; `end_net`/`trace` name RTL registers and nets |
| `scripts/sta_module_delta.py <run_a> <run_b>` | per-module area (yosys `stat -liberty`) and board delta between two runs, largest area increase first | TSV + `TOTAL`/`SUMMARY` lines (the performance/area question of ALGORITHMS-EXPERTS A102) |

**Reading the numbers** (ALGORITHMS-EXPERTS A97–A103): structural FO4 is screening; a streamed study netlist is unplaced and unbuffered; identical RTLIL maps to ±1 % area / ±6 cells across runs (autoidx-dependent ABC order) — compare whole-tree totals and cell counts, not single ns; `STUDY` means the budget was missed and mapping was requested anyway; `INCONCLUSIVE` means no complete validated emitted analysis. Current state of record: `sv-timing/architecture/FREQUENCY-CLOSURE.md`.

### Still open (lab PD or residual)

1. **S3b-lab (package edit)** — retune `sv-timing` FO4 table from **real** STA using `retune-proposal.md`
   (host propose + fixture guard done; gate `s9-lab-gate`). The real STA is now one command
   away: `timings sta-rtl --target <cfg> --platform nangate45 [--remote]` (study liberty,
   §7.1). The structural model is now calibrated against the per-module netlist
   (ALGORITHMS-EXPERTS A103, delay-v37); the retune of `fo4-v1` from that
   calibration is the next S3b-lab step.
2. **S4b OpenROAD + LEF** — open-PDK/NDA tech under `pd/pdk/` (scaffold already); the fork
   binary and its `test/<platform>` LEF/lib sets are installed, the floorplan step still needs
   a real die/LEF plan.
3. **Full `verify --sim` on Windows CI** — preflight + Git-Bash prefer done; needs riscv-gcc/verilator (+ WSL spike).
4. **CI residuals** — BIOS `bios-regress` `http_standalone_frames`; GitLab BIOS wasm-opt `try_table` probe; `svt.py check` hygiene (rustfmt drift, KD0 fixture strings) still informational.
5. ~~AMOCAS.Q~~ **done** · ~~stream8 residual~~ **done** (CRT 9/9 + H 3/3 + stability stream8 6/6) · dual-hart-ci residual soft lint/R3 skip when host-skewed · R3b Image (soft-skip gate) · dual-ISS · OpenSBI/Ara live still lab-optional.
6. **Optional** Windows VS Build Tools provisioning.

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
| `build-platform/AGENTS.md` | Extension playbook (add option/command/tool/suite); invariants incl. clean allowlist |
| `build-platform/README.md` | User quickstart |
| `architecture/build-platform-workspace-lifecycle.md` | Clean / timings hand-off design of record |
| `AGENTS-todo.md` | Phase checklist |
| `AGENTS.md` §0.2 | Verify gate as SoC readiness mechanism |

---

*Agents: prefer updating this file when adding a CLI command, clean purpose, timings flag, or residual suite so the top-level map stays one hop from the registry.*
