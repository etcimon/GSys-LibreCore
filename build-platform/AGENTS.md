# build-platform — Agent guide

This is the authoritative guide for agents working on the CVA6 **build
platform** (the Bun + TypeScript project under `build-platform/`). It explains
the architecture, the invariants you must preserve, and — most importantly —
the **exact minimal edit** required to add a config option, command, tool
recipe, or test suite. The design goal is *file discovery + minimal
customization*: new features should be additive, discovered automatically, and
require touching as few files as possible.

Root pointer: `AGENTS-build.md` defers here. User-facing usage: `README.md`.

**Standing loop for agents (host / residual software):**
`probe` → `tools install` / `setup --install` → `probe install` → `diag` → `verify` / `test`
(§4.6). Do not invent package or toolchain install steps without re-running `probe`.

---

## 1. Non-negotiable invariants

Preserve these in every change (they are why the platform is reliable):

1. **Zero runtime dependencies.** `bun run` must work with no `bun install`.
   Only `devDependencies` (type packages) are allowed. Do not `import` npm
   runtime packages; use Bun/Web/Node built-ins (`Bun.*`, `node:*`, Web APIs).
2. **Single control surface.** All tunables live in the repo-root `.config.ts`,
   typed by `src/config/schema.ts`, defaulted by `src/config/defaults.ts`.
   Commands read resolved config from the `PlatformContext`; they never hardcode
   toolchain versions, paths, or targets.
3. **Contained workspace.** Everything installed/produced goes under
   `workspace/` (gitignored). Never write outside the repo or into global dirs.
   Deletions are confined to `workspace/` **plus explicit allowlisted leaves**
   (`clean sim` → repo-root `work-ver/`; `clean svt` → `sv-timing/target` and
   package out/cache; `clean svt-tools` → `sv-timing/.tools`). Never walk the
   whole repo or touch `core/` / crates / NDA PDK.
4. **Cross-platform by construction.** No OS-specific assumptions outside
   `src/platform/`. Use `platform/os.ts`, `platform/exec.ts`, `platform/shell.ts`
   for anything that touches the host.
5. **Licensing = MIT (tier T).** Per the repo `.licensing-policy` +
   `.licensing-tiers`, net-new files here are **MIT**, attributed to Etienne Cimon
   (concise SPDX header; full text in `LICENSE` / repo-root `LICENSE.MIT`).
   Contributions here are MIT inbound = outbound and need **no CLA** — unlike the
   RTL, which is `CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial` and does. Any
   header this platform *generates* into an output file must also be MIT.
   See §9. `*.md` files take no header.
6. **Type-clean + tested.** `bunx tsc --noEmit` must pass (strict) and
   `bun test` must stay green before you call a change done (§8).

---

## 2. Directory map

```
build-platform/
  package.json          bun project (scripts; CLI entry at src/cli/index.ts), MIT
  tsconfig.json         strict TS, bundler resolution, .ts extensions allowed
  bunfig.toml           bun runtime/test config
  LICENSE               MIT (Etienne Cimon)
  AGENTS.md             this guide
  README.md             user quickstart
  src/
    cli/
      index.ts          entrypoint: parse argv, help/version, dispatch
      args.ts           tiny argv parser (flags/positionals)
      command.ts        Command interface + requireContext()
      help.ts           general + per-command help renderers
      registry.ts       << the command registry (add commands here)
      commands/         one file per command (status, doctor, probe, diag, man,
                        setup, tools, vendor, mb, tech, build, test, verify,
                        timings, clean, config)
    config/
      schema.ts         << the typed option catalog + defineBuildConfig()
      defaults.ts       << the complete resolved baseline (add option defaults)
      load.ts           merge defaults + .config.ts + local overlay; validate
    context.ts          PlatformContext + childEnv() for CVA6 child processes
    platform/
      os.ts             OS detection + per-OS conventions
      exec.ts           process runner (Bun.spawn), which(), capture()
      shell.ts          pwsh/bash/zsh dispatch + runBashScript()
    workspace/
      layout.ts         resolve + create workspace dirs
      discovery.ts      file discovery + incremental change detection
      clean.ts          << granular clean inventory + allowlist (timings/svt/…)
    tooling/
      locations.ts      << canonical install paths for managed tools
      detect.ts         << host tool probes (doctor/tools)
      probe.ts          << in-depth capability gather (probe CLI)
      diagnostics.ts    << compartmentalized diags + per-test Verilator surfaces
      timings.ts        << host adapter: portable flist → spawn sv-timing CLI
      man.ts            << human man pages via grok headless sessions
      submodules.ts     git-focused submodule sync (cargo-like pull)
      vendor.ts         uncore controller/PHY fetch/update/scan engine
      motherboard.ts    corev-mb board engine (board.json -> config + board pkg)
      pcbparts.ts       pcbparts.dev MCP client (14 tools, cache-first)
      packageManagers.ts OS package-manager detect + prerequisite install
      recipes.ts        tool install recipes (verilator/spike/iverilog/riscv-gcc)
    python/
      venv.ts           contained pip venv provisioner
    tests/
      runner.ts         run verif/regress suites with the managed env
  test/
    config.test.ts      fast config/deepMerge unit tests (always run)
    regress.test.ts     bun test → LibreCore regression suites (opt-in via env)
  workspace/            (gitignored) managed tools + build outputs
```

The repo-root companions: `.config.ts` (control surface), `build.sh` /
`build.ps1` (bootstrap wrappers that install Bun then run `src/cli/index.ts`).

---

## 3. Architecture / data flow

```
argv ─▶ cli/index.ts ─▶ registry.findCommand()
                         │
                         ├─ needsContext? ─▶ createContext()
                         │                     └─ loadConfig(): defaults
                         │                        ⊕ .config.ts ⊕ overlay → validate
                         │                     └─ getHostInfo(), resolveWorkspacePaths(),
                         │                        toolLocations(), Logger
                         └─ command.run({ ctx, positionals, flags, logger })
```

- `PlatformContext` (`context.ts`) is the one object commands receive. It has
  `config`, `repoRoot`, `host`, `paths`, `tools`, `derived`, `logger`, `dryRun`.
- `childEnv(ctx)` builds the environment for CVA6 child processes: it prepends
  the managed tool bin dirs to `PATH` and exports the variables the CVA6
  Makefile / verif scripts expect (`RISCV`, `CVA6_REPO_DIR`,
  `VERILATOR_INSTALL_DIR`, `SPIKE_INSTALL_DIR`, `TARGET_CFG`, `NUM_JOBS`).

---

## 4. Extension playbook (the important part)

### 4.1 Add a configuration option
1. Add the field (typed, with a doc comment) to the right interface in
   `src/config/schema.ts`.
2. Add its default value in `src/config/defaults.ts`.
3. (Optional) surface it in `commands/config.ts` output and validate it in
   `load.ts` `validateConfig`.

That's it — because the user config is a `DeepPartial` merged over defaults, the
new option is **automatically optional** for every existing `.config.ts`. No
existing config breaks. This is the core "minimal customization" mechanism.

### 4.2 Add a CLI command
1. Create `src/cli/commands/<name>.ts` exporting a `Command`
   (`name`, `summary`, `usage`, `needsContext`, `run`).
2. Import it in `src/cli/registry.ts` and append to `COMMANDS`.

Help text and dispatch pick it up automatically (registry is the single source).

For a pass-through command that delegates to a Python package, see
`src/cli/commands/g6q.ts` as the canonical example: it resolves the package
script from the repo root, picks a Python interpreter, forwards raw `argv`,
and supports an internal `--remote` flag to switch between `g6q.py` and
`g6q_remote.py`.

### 4.3 Add a managed tool
1. Add its install path convention to `src/tooling/locations.ts` (`ToolLocations`).
2. Add a version pin to `schema.ts` `ToolVersions` + `defaults.ts`.
3. Add a host probe to `src/tooling/detect.ts` `HOST_PROBES` (so `doctor` /
   `probe utils` see it). For package-manager coverage, extend
   `PKG_MANAGER_PROBES` / `UTILS_PROBES` in `tooling/probe.ts` when relevant.
4. Add an `installX` recipe to `src/tooling/recipes.ts` (build-from-source or
   download) using `platform/exec.ts` + `platform/shell.ts`, installing into the
   `locations.ts` path, and add it to `installOpenSourceSimTools` **and** the
   right install profile in `installProfiles.ts` (`sim` / `dual-hart` / `all`).
5. Wire it into `commands/setup.ts` (and `childEnv` in `context.ts` if it needs
   to be on the child PATH — the common tools already are).
6. If the tool gates a residual path, add a capability to the `probe` command
   matrix (`tooling/probe.ts` `buildCommandMatrix`) and an install playbook
   entry in `buildInstallActions` so `probe install` stays accurate.

### 4.4 Add a regression/test suite
1. Add a `TestSuite` entry to `defaults.ts` `tests.suites` (or `.config.ts`) with:
   `id`, `description`, `script` (repo-relative `verif/regress/*.sh`), `group`
   (`smoke|benchmark|arch|directed|uvm|generated|pk|linux`), `target`,
   `dvSimulators`, `tools` (managed tools it needs, for preflight), and
   `openSource`. Optionally: `dvTarget`, `testSuiteInstallers`,
   `requiresSubmodule` (e.g. `"riscv-dv"`), `requiresUvm`, `optional`.
2. Reference its id in `tests.defaultSuites` to include it in the default run.

Both `bun run src/cli/index.ts test` and `bun test` discover suites from config — no code
change needed. Preflight (`tools` / `requiresSubmodule` / `requiresUvm`) decides
whether the suite runs or is skipped-with-reason, so it self-integrates into
`--all` / `--open-source` runs and `test --list`.

### 4.5 Add a vendored uncore controller / PHY
1. Add a `VendorControllerSpec` entry to `defaults.ts` `vendor.controllers` (or
   `.config.ts`) with: `id`, `description`, `domain`, `kind`, `mechanism`,
   `url`, `path`, `license`, `status` (`planned`), `enabled` (`false`), plus the
   `scanPaths` / `integrationSeam` / `phyNote` / `architectureDoc` pointers.
2. (Optional) add a per-domain outline under `architecture/uncore/` and a row in
   `AGENTS-core-platform-vendor-actives.md`.

The `vendor` command discovers it automatically (`list` / `status` / `sync` /
`add` / `update` / `scan`); `load.ts` validates unique ids + paths. Nothing is
fetched until the id is named (or `--all`). See `AGENTS-vendor.md` for behaviour,
mechanisms (submodule vs snapshot), and when scanning is required.

### 4.6 Add / design a motherboard (`corev-mb`)
1. Create `corev-mb/boards/<id>/board.json` (or `mb create <id>` to scaffold a
   custom board) declaring `core` (target config), `apu.controllers`,
   `interfaces`, and `phys`. Write the target under `corev-mb/architecture/<id>/`
   and a contract `AGENTS-mb-<id>.md`.
2. `mb select <id>` is the SoC+MB configure step: it adapts `soc.*` via the
   gitignored overlay, `vendor sync`s the board's controllers, and generates a
   non-compiled `<id>_board_pkg.sv` + `board.mk` under `boards/<id>/generated/`.
3. Custom boards run `mb design <id> [--online] [--fix]` (SKiDL + pcbparts.dev,
   `corev-mb/lib/`); third-party/reference boards set `"skidl":"omitted"`.

The engine is `src/tooling/motherboard.ts`; the MCP client is
`src/tooling/pcbparts.ts` (network only with `--online`). See
`AGENTS-motherboard.md` for the full flow, schema, and SoC-readiness gates.

### 4.6 Probe, install profiles, and compartmentalized diagnostics

Standing **agent / operator loop** on a new host or after a toolchain change:

```
probe / doctor  →  tools install | setup --install  →  probe install  →  diag  →  verify / test
```

#### 4.6.1 Observe — `probe` and `doctor`

| Command | Role |
|---------|------|
| `status` | SoC + provisioned flags only (no deep PATH scan) |
| `doctor` | Quick PATH readiness + managed-tool summary; points to `probe` |
| `probe` | Full categorical boxes (tabs) + command capability matrix + install playbook |

```
bun run src/cli/index.ts probe              # all tabs
bun run src/cli/index.ts probe tools        # managed workspace/tooling
bun run src/cli/index.ts probe env          # residuals (WSL oss-cad, home spike, …)
bun run src/cli/index.ts probe diag         # diagnostic readiness (no heavy lint)
bun run src/cli/index.ts probe commands     # CLI → required/optional caps
bun run src/cli/index.ts probe install      # print install playbook (does not install)
bun run src/cli/index.ts probe pkg --deep   # full package-manager PREREQS scan
bun run src/cli/index.ts probe --json
```

**Tabs** (`tooling/probe.ts` `PROBE_CATEGORIES`): `host`, `platform`, `pkg`,
`utils`, `tools`, `env`, `diag`, `commands`, `install`. Missing counts show as
`(N↓)` on the tab strip. Residual roots (managed spike, WSL `~/tools/*`) satisfy
capabilities even when PATH lacks the binary — e.g. R3 cosim Verilator under WSL.

**Never invent install steps** — always re-read `probe install` after provisioning.

Implementation: `src/tooling/probe.ts` (gather), `src/cli/commands/probe.ts`
(render boxes via `util/box.ts`), `src/tooling/detect.ts` (PATH probes).

#### 4.6.2 Install profiles — `tools install` / `setup --install --profile`

Cross-platform provisioning for residual sim + dual-hart stacks lives in
`src/tooling/installProfiles.ts` (recipes in `src/tooling/recipes.ts`).

```
bun run src/cli/index.ts tools install              # list profiles
bun run src/cli/index.ts tools install dual-hart    # riscv-gcc + OpenSBI SMT2
bun run src/cli/index.ts tools install sim          # open-source sim path
bun run src/cli/index.ts tools install spike        # Spike (Linux / WSL)
bun run src/cli/index.ts tools install formal       # Yosys>=0.67 + SymbiYosys
bun run src/cli/index.ts tools install all
bun run src/cli/index.ts setup --install --profile dual-hart
```

| Profile | Recipes | Notes |
|---------|---------|--------|
| `sim` / `open-source-sim` | riscv-gcc, verilator, spike, iverilog | Default for bare `setup --install` |
| `dual-hart` | riscv-gcc, opensbi-smt2 | `software/smt2-linux/scripts/build-opensbi-smt2.{ps1,sh}` |
| `opensbi` | opensbi-smt2 | Firmware only |
| `formal` | formal | Bounded-proof toolchain for `verify --formal` |
| `all` | sim + opensbi-smt2 + formal | Full residual stack |
| single recipe | `riscv-gcc` \| `verilator` \| `spike` \| `iverilog` \| `opensbi-smt2` \| `formal` | `tools install <id>` |

- **formal**: source-builds **Yosys (>= v0.67)** with the *integrated* sv-elab/slang
  frontend, plus SymbiYosys, into `workspace/tooling/formal`
  (`scripts/install-formal.sh`; CMake+Ninja, `NUM_JOBS` cores). It first tries to
  **adopt** an existing install that already has `read_slang`, which is minutes
  cheaper than rebuilding. Windows delegates to **WSL** (`platform/wsl.ts`),
  the same rule as Spike, and installs Linux ELFs into the managed prefix.
  A distro Yosys is *not* sufficient: Ubuntu 24.04 ships 0.33, whose classic
  frontend cannot parse `core/include/config_pkg.sv` (`ai_cfg_t'(0)` →
  `TOK_USER_TYPE`) and rejects package-to-package `import`. Below v0.67 there is
  no `read_slang` at all.

#### 4.6.2a Running the formal gate

```
bun run src/cli/index.ts verify --formal
bun run src/cli/index.ts verify --formal --formal-jobs 2 --formal-tasks 4
```

`eda.ts` resolves the toolchain **oss-cad → workspace/tooling/formal → PATH**
and prints which it chose. It decides integrated-vs-plugin slang from the
artifact on disk (no `share/yosys/plugins/slang.so` ⇒ integrated), so a suite
that drops the plugin keeps working and `-m` is never passed to a Yosys that
would reject it.

Parallelism is two-level and configured by `verify.formal`:
`jobs` is `sby -j` (solver processes inside one task, which matters because the
`.sby` files race two engines) and `taskJobs` is how many tasks run at once.
Defaults are cores and `cores / jobs`. These proofs are small and numerous, so
wall time is dominated by task concurrency, not by any single solver call.

**Do not let a solver work on `/mnt`.** DrvFs is slow for the many small files
sby writes, and an 8-core build plus a solver was observed to destabilise the
WSL VM outright. `verify.formal.workdirRoot` exists for this; the WSL path
already uses a `$HOME` workdir.

#### 4.6.2b Remote formal — putting the solver on the builder

```
bun run src/cli/index.ts verify --formal --formal-remote
bun run src/cli/index.ts verify --formal --formal-host <alias>
```

Reuses the MT evidence transport (`verif/regress/remote-testharness.sh`, which
owns the SSH ControlMaster). The whole suite is **one** remote shell, not one per
task: `sync`, then a single script that provisions the toolchain if absent,
runs every task with `sby -j $(nproc)`, and emits one `RESULT <task> rc= status=`
line each. Measured **10 tasks in ~11 s** on a 12-core builder.

Four things this had to get right, each of which failed first:

| Trap | Fix |
|---|---|
| `build-platform/scripts/` was not in the proxy's `SYNC_INCLUDE`, so the remote had no installer | Added that one entry to `SYNC_INCLUDE` |
| `shell` has a **60 s** default safety net (`DEFAULT_SHELL_TIMEOUT`), so a longer suite was cut off and every task after the cutoff reported "no RESULT line" | Pass a large **global** `--timeout` *before* the subcommand. `--timeout 0` does **not** disable it for `shell`: `cmd_shell` treats a non-positive value as "use the default" |
| Credentials must not reach argv or the repo | The variable names are forwarded through `WSLENV`; the value crosses as an environment variable. The proxy still falls back to its untracked pass file |
| Transport exit code says nothing about a proof (an SSH drop is 255) | Classify only from the `RESULT` lines; no lines at all is itself the error |

Remote provisioning is a one-time ~5 min source build on 12 cores; afterwards the
script adopts it and the step is a no-op.

- **riscv-gcc**: xPack prebuilt (win zip / linux-x64 / darwin tar.gz) → `workspace/tooling/riscv`.
- **opensbi-smt2**: Windows uses Cygwin make + xPack cygwrap; Linux uses bash script.
- **spike**: Linux native or Windows via WSL (`build-platform/scripts/install-spike.sh`);
  Cygwin unsupported. Installs Linux ELF under `workspace/tooling/spike`; adopts
  `~/tools/spike` when present. Run on Windows with `wsl …/tooling/spike/bin/spike`.
- **verilator**: Linux native or Windows via WSL (`build-platform/scripts/install-verilator.sh`)
  → `workspace/tooling/verilator-<pin>` (pin: `toolchain.versions.verilator`, v5.008). **The
  installed tool is always the pinned tag PLUS every `verif/regress/verilator-*.patch`**: the
  script applies each patch with `git apply --check` (a patch that does not apply is a hard
  error, unlike the upstream `verif/regress/install-verilator.sh` whose `git apply || true`
  silently builds a stock tool), skips Verilator's own `make test`, and after `make install`
  verifies that every added header line is present under `share/verilator/include` and that
  `--version` reports `(mod)`. A prefix is adopted (`VERILATOR_ADOPT_FROM`, or an OSS CAD
  drop-in under `workspace/tooling/oss-cad-suite`) only if it passes the same check. The
  check itself is `src/tooling/verilatorPatch.ts` and is shared by `tools install verilator`
  ("already installed (patched …)" vs. rebuild), `diag status` / `verify --tools`
  (`verilator-patch` row), the `diag run` lint preflight (warns — the fixes are runtime headers
  that `--lint-only` never compiles) and the sim preflight (**required** — regress compiles
  the runtime). CI's `rtl-lint` lane is the same `./build.sh tools install verilator` behind an
  `actions/cache` of the prefix.
- **`setup --install`** ends with a post-setup tools probe snapshot; failures point at
  `probe install`.

#### 4.6.3 Compartmentalized diagnostics — `diag`

Diagnostics are **not** a substitute for full `verify`. They are small,
self-contained gates from `config.diagnostics.tests[]` (schema + defaults).
Each `verilator-lint` / `verilator-elab` entry owns its surface via
`DiagnosticVerilatorConfig` (`target`, `top`, `flist`, `extraFlists`, `lintArgs`,
`defines`, `warningBudget`) so e.g. smt2 can use budget 600 while core keeps the
verify baseline.

```
bun run src/cli/index.ts diag list
bun run src/cli/index.ts diag status
bun run src/cli/index.ts diag run                 # defaultCompartments (host+core)
bun run src/cli/index.ts diag run core smt2
bun run src/cli/index.ts diag run diag-smt2-lint
bun run src/cli/index.ts diag run smt2 --all      # include optional
bun run src/cli/index.ts diag run ai              # Xg6lcai (like ooo)
bun run src/cli/index.ts test --ai --channels 4 --ai-dram 1
bun run src/cli/index.ts test --ai-remote --from-timing <pkg>
```

| Compartment | Typical contents |
|-------------|------------------|
| `host` | probe-cap: bun, git, bash, linux-or-wsl |
| `core` | path-check flist; verilator lint imafdc + cv32a65x |
| `smt2` | dual-hart paths, optional lint (`g6lc64_smt2`), payload, caps |
| `ooo` | formal `.sby` paths; optional ooo package lint |
| `ai` | Xg6lcai config/island/DRAM/tensor/QEMU paths; optional `g6lc64_ai` lint. CLI: `diag run ai`, `test --ai`, `test --ai-remote`, `test --ai-qemu`, `--channels`/`--ai-dram`/`--from-timing` |
| `apu` | Ara flist; optional `g6lc_ara_lint_top` + `Flist.ara` |
| `residual` | spike / verilator residual caps |

**Add a diagnostic:** append a `DiagnosticTest` to `defaults.ts`
`diagnostics.tests` (or `.config.ts`). For Verilator kinds set `verilator.target`
(required by `load.ts` validation). Runner: `tooling/diagnostics.ts` →
`eda.lintWithSurface`. Flat manifests land under `workspace/build/diagnostics/`.

#### 4.6.4 Human man pages — `man` (Grok headless)

For **human readers** (browser), not CI agents. Wraps the local **Grok Build**
CLI (`grok`, model `grok-build`) in a short man-session id so answers chain:

```
bun run src/cli/index.ts man [id?] [files…] <query>
bun run src/cli/index.ts man --list
```

| Piece | Behavior |
|-------|----------|
| **id** | Optional `man-<hex>`. Omitted → random `man-********`. Stored under `workspace/man/<id>/`. |
| **files** | Existing paths among positionals (or `--file`); grounded via read-only tools. |
| **query** | Remaining words, `--query`, or stdin. |
| **Grok** | New: `grok -p … -s <uuid> -m grok-build --output-format json`. Resume: `grok -r <uuid> -p …`. |
| **Tools** | Allowlist read/search/fetch only (no shell/edit). |
| **Output** | `answer.md` + `answer.html`; browser open for TTY humans (skip CI/`--no-open`). |
| **Continuity** | `index.json` maps man id → Grok session UUID; follow-ups resume. |

TUI workflow twin: [`.grok/workflows/man.rhai`](../.grok/workflows/man.rhai)
(`args.query`, optional `args.files`, `args.id`). Prefer the CLI for HTML + id
resume. Requires `grok` on PATH (`~/.grok/bin`).

### 4.7 Run the per-change verification gate (`verify`)

`verify` is the concrete, runnable form of `AGENTS.md` §0.2 and
`AGENTS-coding-philosophy.md` §2.4: every RTL change must prove it is
lint-clean, formally sound, simulated, and synthesizable before it is called
done. The command is registered in `src/cli/registry.ts` and implemented in
`src/cli/commands/verify.ts`. Prefer **`diag run`** for focused, per-package
smoke before the multi-target verify sweep.

Help-style usage:

```
bun run src/cli/index.ts verify [--lint] [--formal] [--sim] [--synth]
                                [--target <cfg>] [--json] [--dry-run]
                                [--tools]
```

- With no stage flag, `verify.stages` from `.config.ts` decides which stages run.
- `--lint` runs Verilator `--lint-only` plus strict slang elaboration over every
  target in `verify.targets`; this is the gate that enforces "minimal configs
  still elaborate".
- `--formal` runs the SymbiYosys tasks listed in `verify.formalTasks`.
- `--sim` runs the regression suites in `verify.simSuites`.
- `--synth` runs a Yosys + yosys-slang synthesis smoke to catch inferred latches
  and non-synthesizable constructs early. The top is `verify.synthTopByTarget[target]`
  when set (synth may use a smaller unit than lint's `topByTarget`: the four-core
  `g6lc64_ooo_server` cluster synthesizes as the core-only `cva6`), and
  `verify.synthSlangArgsByTarget[target]` appends `read_slang` arguments (the server
  needs `--unroll-limit=262144`). `verify.synthPassesByTarget[target]` overrides the
  pass tail after `hierarchy -check` — the server runs `proc; opt_clean; stat;
  check -latchonly -assert` because `opt -fast`'s `OPT_MERGE` is asymptotic on it
  (≈11 merges/min from ~273k cells, cut at a 6 h cap) and the full `check -assert`
  on the un-merged 287k-cell netlist is OOM-killed at 118 GB (bit-level loop
  TopoSort). Measured: 286,763 cells, `$dlatch`/`$sr` 0, 2,934 s, 99.5 GB peak. The
  loop/driver check for the server is owed on a larger host; per-block synthesis via
  `verif/regress/remote/run_cluster_synth_review.py` remains the uncore evidence path.
- `--target <cfg>` narrows lint/synth to one config package.
- `--tools` lists the OSS CAD Suite tools and exits `0`/`3` based on presence.
- `--sim --qualification <profile>` switches the sim stage to **strict
  qualification** over `verify.qualifications[profile]`: each listed target
  must be covered by a `tests.suites` entry with `execution: "remote-proxy"`,
  the declared `buildManifest` must exist and re-verify against the live tree
  (produced by `testharness_proxy.py build <flavour> --manifest-out <path>`),
  and the suite must print exactly one terminal `G6LC_EVIDENCE` JSON record
  matching suite/target/top/kind/runId and all three sha256 digests. Skips,
  lint fallbacks, stale binaries, zero-work runs and diagnostic failures are
  all hard failures. Incompatible with `--dry-run` and other stage flags; it
  qualifies *simulation evidence*, not full RTL/PPA sign-off. Producer example:
  `verif/regress/remote/qualify-soft-ladder-osbi.sh` (suite
  `qual-soft-ladder-osbi`, profile `smt2-cookie`).

Add a new formal task by extending `verify.formalTasks` in `.config.ts`; add a
new simulation suite by extending `tests.suites` (§4.4). `verify` consumes both
without code changes.

---

## 5. File discovery & change detection

`src/workspace/discovery.ts` provides the "auto-detect files + skip unchanged
work" mechanism:

```ts
import { discoverFiles, detectChanges, commitManifest } from "./workspace/discovery.ts";

const files = await discoverFiles(["core/**/*.sv", "core/include/*.svh"], { cwd: ctx.repoRoot });
const report = await detectChanges(ctx.paths.manifests, "verilate-inputs", files);
if (report.changed) {
  // ...run the build step...
  await commitManifest(report);   // persist fingerprints on success
} else {
  ctx.logger.info("inputs unchanged — skipping verilate");
}
```

Fingerprints are `size:mtime` (fast, make-like) stored as JSON under
`workspace/.cache/manifests/`. Use a stable `key` per build step. Prefer glob
patterns over hardcoded file lists so new sources are picked up automatically.

---

## 6. Platform / shell conventions

- **Run a process**: `run(cmd, args, { cwd, env, logger })` from `platform/exec.ts`
  (throws `CommandError` on non-zero unless `allowFailure`). `capture()` for
  stdout, `which()`/`hasBinary()` to resolve executables.
- **Run a shell script string**: `runScript()` (auto-selects pwsh/bash/zsh).
- **Run a CVA6 bash regression**: `runBashScript(scriptRelPath, [], { cwd: repoRoot, env })`
  — always bash; on Windows requires Git-Bash/WSL bash on PATH.
- **Never** shell out with a raw string concatenation of untrusted input; pass
  argv arrays.

---

## 7. `childEnv` and the CVA6 flow

Commands that invoke the repo `Makefile` or `verif/regress/*.sh` must pass
`childEnv(ctx, extra)` as the process env so the managed toolchain is used. The
CVA6 env contract (mirrored from `verif/sim/setup-env.sh` and the `Makefile`):
`RISCV`, `CVA6_REPO_DIR`, `VERILATOR_INSTALL_DIR`, `SPIKE_INSTALL_DIR`,
`TARGET_CFG`, `NUM_JOBS`, plus `DV_SIMULATORS`/`UVM_VERBOSITY` for suites.

---

## 7.1 Granular `clean` and structural FO4 (`timings` / package `svt`)

**Top-level map (agents start here):** repo-root
[`AGENTS-build-platform.md`](../AGENTS-build-platform.md) §2.6 (`clean` purposes) and
§6.1 (FO4 scale). Lifecycle plan:
[`architecture/build-platform-workspace-lifecycle.md`](../architecture/build-platform-workspace-lifecycle.md).
Coding loop: [`AGENTS-coding-philosophy.md`](../AGENTS-coding-philosophy.md) §2.8.

| Purpose / alias | Implementation | Notes |
|-----------------|----------------|-------|
| `timings` / `sta` | `workspace/build/sv-timing/`, STA seeds | Host soak packages from monorepo-soak / `timings compile -o` |
| **`svt`** (`rust-target`, `sv-timing-target`) | **repo** `sv-timing/target`, `.sv-timing-out`, `.sv-timing-cache` | Not under `workspace/`; allowlisted leaf only |
| **`svt-tools`** | **repo** `sv-timing/.tools` | Requires `--yes`; re-run package `python tools/svt.py setup` |
| Filters | `--older-than`, `--execution last\|failed\|ok`, `--target` | Stamp-aware selection for timings packages |

```bash
bun run src/cli/index.ts clean status
bun run src/cli/index.ts clean timings --older-than 14d --dry-run
bun run src/cli/index.ts clean svt
bun run src/cli/index.ts clean svt-tools --yes
```

**`timings` host adapter** (`src/tooling/timings.ts`): expand flists → portable `.f`,
spawn package CLI via `tools/svt.py run`, write packages under
`workspace/build/sv-timing/`. `--from-timing DIR` validates and exports
`CVA6_FROM_TIMING` for suites; `--use-emit` is expert/off by default. FO4 is
**screening only** (shared budget with package: ~32 FO4 @ 1250 MHz, ~20 FO4 @
2000 MHz at default `fo4_ps`/`margin`). Do not retune package `fo4-v1` from
synthetic STA fixtures. Package independence: never import monorepo modules into
`sv-timing/crates/**`.

When extending clean: add targets only in `src/workspace/clean.ts` allowlists +
tests in `test/clean.test.ts`; never recursive repo deletes.

---

## 8. Validation (run before declaring done)

```bash
cd build-platform
bun install            # once, to fetch dev type packages
bunx tsc --noEmit      # strict type-check must pass
bun test               # unit + (skipped) regression specs must be green
bun run src/cli/index.ts doctor   # smoke the CLI
bun run src/cli/index.ts probe    # full capability boxes
bun run src/cli/index.ts diag list
```

`bun run` itself needs no install; `tsc`/editor types need `bun install`.

---

## 9. Licensing (code files here)

Governed by repo-root `AGENTS-licensing.md` + `.licensing-policy` (the source of
truth). Current policy → net-new files authored by the active contributor are
**MIT / Etienne Cimon**. Header convention for new
`.ts`/`.sh`/`.ps1` files:

```ts
// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
```

`*.md` files (this guide, README) take **no** license header. Never rewrite a
third-party or pre-existing non-contributor license. Full MIT text is in
`LICENSE` (and repo-root `LICENSE.MIT`).

Generated artifacts inherit tier T: the board-package emitter
(`src/tooling/motherboard.ts`) and the sv-timing emitter
(`sv-timing/crates/sv-timing-emit/src/lib.rs`) write `SPDX-License-Identifier: MIT`
into their outputs. Do not emit `LicenseRef-Proprietary` or a CERN-OHL identifier
from tooling — claiming the RTL licence over machine-generated glue is a
`E-TIERCONFLICT` waiting to happen.

---

## 10. Status matrix

| Area | State |
|------|-------|
| Config surface (`.config.ts` + schema + defaults + load) | **done** |
| CLI (status, doctor, probe, diag, man, config, clean, tools, setup, vendor, mb, tech, build, test, verify, timings) | **done** |
| Granular `clean` (purpose/age/`sim`/`svt`/`svt-tools`/`--yes`/`--execution`) | **done** — `workspace/clean.ts` (C0–C2 + T3a + package Cargo leaves) |
| `timings` compile/validate/summary/sta-handoff/correlate/retune-propose | **done** (T0–T3b + OpenSTA S0–S3a + S3b host propose); S3b-lab package edit + S4b open |
| Top-level command map | **done** — repo `AGENTS-build-platform.md` |
| Host adapter `timings` + `tooling/timings.ts` (portable flist → sv-timing) | **done** |
| Host detection (`detect.ts`) + in-depth `probe` (boxes, install playbook, residuals) | **done** |
| Compartmentalized `diag` + `config.diagnostics` (per-test Verilator surfaces) | **done** |
| Install profiles (`installProfiles.ts`: sim / dual-hart / opensbi / all + recipes) | **done** |
| Workspace layout + change detection (`discovery.ts`) | **done** |
| Git submodule sync (`submodules.ts`) | **done** |
| Vendor catalog: uncore controllers/PHY (`vendor.controllers`) + `vendor` cmd | **done** (validated dry-run) |
| Motherboard layer (`corev-mb/`) + `mb` cmd + pcbparts.dev MCP client | **done** (validated; genesys2 reference) |
| `bun test` → regression bridge (`tests/runner.ts`) | **done** (opt-in exec) |
| Tool install recipes (`recipes.ts`; spike WSL/Linux; riscv-gcc prebuilt) | **done** |
| OS package bootstrap (`packageManagers.ts`), gated | **done** |
| Python venv provisioner (`python/venv.ts`) | **done** |
| `setup --install` orchestration (+ post-setup tools probe) | **done** |
| Regression catalog + suite selection + preflight | **done** |
| CI lanes through the CLI (`.github/workflows/ci.yml`; see `AGENTS-build.md`) | **done** |
| Windows VS Build Tools provisioning | **planned** (config flag present) |
| SV source discovery change-detection wired into `build` | **done** |
| U5 OoO formal tasks in `verify.formalTasks` | **done** |
| SoC envelope vs `AGENTS-configuration.md` §1.1 | **done** |
| Production suites catalog (ooo/server-math/kvm/smt/…) | **done** (optional; not default) |
| R3 WSL cosim path (`smt-linux-r3-cosim.sh`) | **done** (RTL SUCCESS on lab host) |
| Commercial EDA (VCS/Questa/Vivado) | **detect-only** |
| Physical design (OpenROAD/SiliconCompiler/PDK) off `pd/synth` | **detect-only / planned** |
| Ara vendor + live attach lint (`CVA6_ARA_ATTACH`) | **done** (`Flist.ara` + shims; cosim open) |

The open-source-sim path is implemented end-to-end (`probe` → `tools install` /
`setup --install` → `diag` → `test`/`verify`) and verified across
Windows/Ubuntu/macOS by the `build-platform` workflow. Priority for residual
work: R3b Linux image lab; dual-ISS tandem polish; optional Windows VS Build
Tools; then the PnR flow off `pd/synth`.

---

## 11. Gotchas

- **Legacy smoke is destructive to local artifacts:** the default
  `smoke-tests-cv64a6_imafdc_sv39.sh` invokes root `make clean` and simulation
  `make clean_all`, including work directories, traces and generated FPGA
  bootrom files. A 2026-09-14 full-verify attempt reached this cleanup before
  being stopped; no tracked deletions were found, but ignored-artifact loss
  could not be inventoried retroactively. Do not run full/default simulation
  verification in a shared worktree without explicit cleanup approval or an
  isolated disposable checkout. Strict remote qualification and isolated leaf
  checks are different paths; a host-ready probe does not make smoke safe.
  L2-specific safe route: `verif/tb/l2/run-l2-tb.sh` now creates a fresh `run-*`
  artifact directory and compiles copied sources. Proxy `l2-leaf <source-dir>`
  uploads only ten inputs to a unique remote run, verifies hashes and classifies
  pulled logs without shared sync or cleanup. It emits a leaf diagnostic record,
  not strict core/SMT qualification. This does not isolate the legacy full smoke
  suites. Explicit `verify --lint --synth` avoids their simulation/cleanup stage.
  `L2TB_MODE=equiv bash verif/tb/l2/run-l2-tb.sh` is a separate bounded L2
  equivalence diagnostic (default 512 B/four ways, 120 seconds). It compares a
  pinned pre-RR Git blob plus only the validated bypass repair against RR-off,
  preserving inputs, reference hashes and proof logs. A hit-output mutation
  (`L2TB_EQ_NEGATIVE=1`) must fail. Small-fixture proofs are not production
  geometry or whole-core qualification; timeouts stay failed/incomplete.
  See `architecture/l2-l3-cache/README.md` for exact coverage and run identities.

- **Probe before install**: do not hard-code host package lists in agents —
  run `probe install` (or `probe --json`) and follow its playbook.
- **Windows bash**: the LibreCore regression scripts are bash; `test` needs Git-Bash
  or WSL bash on PATH. `doctor` / `probe utils` report this.
  Native Bun gateway calls launched by Git Bash with Linux `--env PATH=...` or
  `--dest /mnt/...` arguments need process-local `MSYS_NO_PATHCONV=1` and
  `MSYS2_ARG_CONV_EXCL=*`. Otherwise Git Bash rewrites those arguments to Windows
  paths before the gateway forwards them to WSL/SSH. The AI-spine review first
  failed before Python execution for this reason; the corrected invocation leaves
  credentials in the existing cache and uses a fresh remote tag. Do not change
  global shell or repository configuration to work around argument conversion.
- **Spike / R3 on Windows**: use WSL (`tools install spike`, `smt-linux-r3-cosim.sh`);
  Cygwin cannot build Spike (`addr_t`). `probe env` shows residual WSL tool roots.
- **diag vs verify**: `diag` uses per-test Verilator surfaces and warning budgets;
  `verify --lint` sweeps all `verify.targets` against `warningBaseline`. Do not
  raise a baseline without a commit note.
- **`return` in regression scripts**: they are designed to be `source`d; the
  runner executes `bash <script>` from `repoRoot` so relative `source ./...`
  paths and the `cd verif/sim` steps resolve. The env guards (`RISCV` etc.) are
  satisfied by `childEnv`, so their early `return`s don't fire.
- **Case-sensitive env keys**: `Bun.spawn` env keys are case-sensitive;
  `childEnv` sets both `PATH` and `Path` on Windows.
- **JSON import**: `index.ts` imports `package.json` for the version; keep
  `resolveJsonModule` on.
- **Verilator vthreads is not bit-exact on this netlist (2026-09-15):**
  `SOFT_LADDER_VERILATOR_THREADS=12` builds of the smt2 testharness produced
  two different non-functional outcomes on identical RTL+input —
  `Active region did not converge` at t=287 in one netlist and a stable
  fetch livelock in another — while `SOFT_LADDER_VERILATOR_THREADS=1` builds
  of the same trees pass identically. This is a Verilator 5.008 MTask
  scheduling artifact, not an RTL defect (a comb-path perturbation flips the
  partition). For smt2 (and any kernel-level qualification) use
  `SOFT_LADDER_VERILATOR_THREADS=1`; never attribute a vthreads=12 anomaly
  to RTL before a vt=1 control.
