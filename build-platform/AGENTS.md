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
bun run src/cli/index.ts tools install all
bun run src/cli/index.ts setup --install --profile dual-hart
```

| Profile | Recipes | Notes |
|---------|---------|--------|
| `sim` / `open-source-sim` | riscv-gcc, verilator, spike, iverilog | Default for bare `setup --install` |
| `dual-hart` | riscv-gcc, opensbi-smt2 | `software/smt2-linux/scripts/build-opensbi-smt2.{ps1,sh}` |
| `opensbi` | opensbi-smt2 | Firmware only |
| `all` | sim + opensbi-smt2 | Full residual stack |
| single recipe | `riscv-gcc` \| `verilator` \| `spike` \| `iverilog` \| `opensbi-smt2` | `tools install <id>` |

- **riscv-gcc**: xPack prebuilt (win zip / linux-x64 / darwin tar.gz) → `workspace/tooling/riscv`.
- **opensbi-smt2**: Windows uses Cygwin make + xPack cygwrap; Linux uses bash script.
- **spike**: Linux native or Windows via WSL (`build-platform/scripts/install-spike.sh`);
  Cygwin unsupported. Installs Linux ELF under `workspace/tooling/spike`; adopts
  `~/tools/spike` when present. Run on Windows with `wsl …/tooling/spike/bin/spike`.
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
```

| Compartment | Typical contents |
|-------------|------------------|
| `host` | probe-cap: bun, git, bash, linux-or-wsl |
| `core` | path-check flist; verilator lint imafdc + cv32a65x |
| `smt2` | dual-hart paths, optional lint (`g6lc64_smt2`), payload, caps |
| `ooo` | formal `.sby` paths; optional ooo package lint |
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
  and non-synthesizable constructs early.
- `--target <cfg>` narrows lint/synth to one config package.
- `--tools` lists the OSS CAD Suite tools and exits `0`/`3` based on presence.

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
| Cross-OS CI (`.github/workflows/build-platform.yml`) | **done** |
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

- **Probe before install**: do not hard-code host package lists in agents —
  run `probe install` (or `probe --json`) and follow its playbook.
- **Windows bash**: the LibreCore regression scripts are bash; `test` needs Git-Bash
  or WSL bash on PATH. `doctor` / `probe utils` report this.
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
