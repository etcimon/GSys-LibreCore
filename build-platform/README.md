# LibreCore build-platform

A **Bun + TypeScript** build platform for **GSys LibreCore** (G6LC). It
bootstraps a cross-platform toolchain, manages a fully-contained workspace, and
orchestrates the build + regression flow — all driven by a single top-level
[`.config.ts`](../.config.ts). Brand-forward CLI: **`g6lc-build`** (permanent
alias: **`cva6-build`**).

- **Zero runtime dependencies.** `bun run` works with no prior `bun install`
  (the only dependencies are dev-time type packages).
- **Cross-platform.** Windows (PowerShell + Chocolatey), Linux (bash + apt),
  macOS (zsh + brew). Commands are dispatched into the right shell per OS.
- **Contained.** Everything installed or produced lives under `workspace/`
  (gitignored). Nothing leaks into your global environment.

## Quick start

From the repository root, follow **probe → install → diag → verify** (never
guess which tools are missing — let the platform tell you).

```bash
# Linux / macOS / Git-Bash / WSL
./build.sh probe              # in-depth capability boxes + install playbook
./build.sh probe install      # what to run next for missing pieces
./build.sh tools install sim  # or dual-hart / all / spike (see profiles)
./build.sh diag run           # default compartments (host + core)
./build.sh setup              # workspace + submodules (add --install if needed)
./build.sh verify --lint      # AGENTS.md §0.2 gate (subset: --lint/--formal/…)
./build.sh test --list
```

```powershell
# Windows PowerShell / pwsh
.\build.ps1 probe
.\build.ps1 probe install
.\build.ps1 tools install dual-hart
.\build.ps1 tools install spike          # Spike via WSL → workspace/tooling/spike
.\build.ps1 diag status
.\build.ps1 diag run host core
.\build.ps1 verify --lint
```

Both wrappers install Bun automatically if it is missing, then run
`build-platform/src/cli/index.ts`. You can also invoke the CLI directly:

```bash
bun build-platform/src/cli/index.ts config --json
```

## Operator workflow (probe → install → diag → verify)

| Step | Command | Installs? | Purpose |
|------|---------|-----------|---------|
| 1 | `probe` / `doctor` | No | Discover host, pkg managers, managed tools, command matrix |
| 2 | `probe install` | No (prints only) | Concrete `tools install` / choco\|brew\|apt / WSL hints |
| 3 | `tools install <profile\|recipe>` or `setup --install --profile …` | Yes | Provision workspace/tooling |
| 4 | `diag status` / `diag run …` | No | Compartmentalized checks; **each Verilator diag has its own config** |
| 5 | `verify` / `test` | No | Full §0.2 gate and/or regression suites |

```
probe (observe) ──► tools install / setup --install ──► diag run ──► verify / test
       │                         │
       └──── probe install ◄─────┘   (re-probe after provisioning)
```

## Commands

| Command  | What it does |
|----------|--------------|
| `status` | One-glance SoC target + managed provisioning snapshot. |
| `doctor` | Quick host PATH readiness + managed-tool summary (points to `probe`). |
| `probe`  | **In-depth** capability boxes (tabs): host, platform, pkg, utils, tools, env, **diag**, commands, **install**. Flags: `--deep`, `--json`. |
| `diag`   | **Compartmentalized diagnostics** with **per-test Verilator configs** (`config.diagnostics`): `list` / `status` / `run [host\|core\|smt2\|ooo\|apu\|residual\|id]`. |
| `man`    | **Human man-page Q&A** via Grok headless (`grok -p` / `-r`, model `grok-build`): `[id?] [files…] [query]`; continues session by id; writes `workspace/man/<id>/answer.html` and opens the browser. |
| `setup`  | Create workspace + submodules; `--install --profile <sim\|dual-hart\|all>` provisions tools (ends with a tools probe snapshot). |
| `tools`  | List managed tools; `tools install <sim\|dual-hart\|opensbi\|all\|recipe>` installs stacks. |
| `build`  | Build the RTL simulation model (Verilator on the open-source path). |
| `test`   | Run regression suite(s) from `verif/regress`: `--list`, `<id...>`, `--suite a,b`, `--group <g>`, `--all`, `--open-source`. |
| `verify` | Per-change gate: `--lint` / `--formal` / `--sim` / `--synth` / `--target`. |
| `vendor` / `mb` / `tech` | Uncore catalog, motherboard, PDK optimization. |
| `clean`  | Free space: `status` inventory; purpose subcommands (`diag`/`timings`/…); `--older-than 7d`; `sim`/`tooling`/`all` need `--yes`. Legacy `--tooling`/`--cache`/`--all` still work. |
| `timings`| Host adapter for `sv-timing/`: `compile|analyze|correct -o|--output <dir>`, `validate`/`summary --from-timing <dir>` (FO4 soak dashboard). |
| `config` | Print the resolved configuration (`--json` for the full tree). |

### Probe tabs

```bash
./build.sh probe              # all tabs
./build.sh probe tools        # managed workspace/tooling only
./build.sh probe env          # residual WSL/oss-cad roots + env vars
./build.sh probe diag         # diagnostic readiness (does not run Verilator)
./build.sh probe commands     # CLI → required/optional capability matrix
./build.sh probe install      # install playbook for missing pieces
./build.sh probe --json       # machine-readable full report
./build.sh probe pkg --deep   # full package-manager PREREQS scan
```

### Man pages (human browser docs via Grok)

Interactive documentation for **human readers**. Each `man-*` id is bound to a
Grok session so follow-ups accumulate context.

```bash
./build.sh man "How does tools install dual-hart work?"
# → workspace/man/man-<random>/answer.html  (opens in browser)
./build.sh man man-a1b2c3d4 "And how does spike install on Windows?"
./build.sh man man-a1b2c3d4 build-platform/AGENTS.md "Summarize §4.6"
./build.sh man --list
./build.sh man --no-open --print "What is probe install?"
```

Requires the **Grok Build** CLI (`~/.grok/bin/grok` on PATH). Uses
`-m grok-build`, read-only tools, `--output-format json`. CI/non-TTY skips
browser open unless `--force`. TUI alternative: `.grok/workflows/man.rhai`.

### Diagnostics (own Verilator surface per test)

Configured in `.config.ts` / `defaults.ts` as `diagnostics.tests[]`. Each
`verilator-lint` entry can set `target`, `top`, `flist`, `extraFlists`,
`lintArgs`, `defines`, and `warningBudget` independently of the full `verify`
sweep.

| Compartment | Role |
|-------------|------|
| `host` | bun / git / bash / WSL (probe-cap) |
| `core` | imafdc + cv32a65x lint surfaces, flist paths |
| `smt2` | dual-hart package lint (budget 600), payload, R3 paths |
| `ooo` | formal prop paths + ooo package lint |
| `apu` | Ara flist + `g6lc_ara_lint_top` surface |
| `residual` | managed Spike / residual Verilator caps |

```bash
./build.sh diag list
./build.sh diag status
./build.sh diag run                 # default: host + core (non-optional)
./build.sh diag run smt2 --all      # include optional smt2 tests
./build.sh diag run diag-smt2-lint  # single id
```

### Install profiles (sim + dual-hart)

| Profile | Recipes | Use case |
|---------|---------|----------|
| `sim` (default for `setup --install`) | riscv-gcc, verilator, spike, iverilog | Open-source sim / suites |
| `dual-hart` | riscv-gcc, opensbi-smt2 | SMT2 OpenSBI `fw_payload.elf` (calls `software/smt2-linux/scripts/build-opensbi-smt2.{ps1,sh}`) |
| `opensbi` | opensbi-smt2 | Firmware only (needs riscv-gcc already) |
| `all` | sim + dual-hart | Full residual software stack |
| recipes | `riscv-gcc`, `verilator`, `spike`, `iverilog`, `opensbi-smt2` | Single install |

```bash
./build.sh tools install                 # list profiles
./build.sh tools install dual-hart       # xPack + OpenSBI SMT2
./build.sh tools install spike           # Linux native / Windows via WSL
./build.sh setup --install --profile all
```

```powershell
.\build.ps1 tools install dual-hart
.\build.ps1 setup --install --profile sim
```

Windows OpenSBI needs **Cygwin `make`** on PATH (Git Bash alone is not enough); the PS1
script path-wraps xPack for `/cygdrive` paths. Spike is built under **Linux or WSL**
only (Cygwin `addr_t` clash): `tools install spike` on Windows drives
`build-platform/scripts/install-spike.sh` via `wsl` into `workspace/tooling/spike`
(Linux ELF; run with `wsl`). It adopts `~/tools/spike` when present. See
`software/smt2-linux/README.md` and `AGENTS.md` §4.6.

Global options: `-h/--help`, `-n/--dry-run`, `-v/--verbose`, `-q/--quiet`,
`--log-level <lvl>`, `--config <path>`, `--json`. Run `./build.sh help` or
`./build.sh help <command>` for details.

## Configuration

Edit the repo-root [`.config.ts`](../.config.ts) — the single control surface.
Any value you omit falls back to
[`src/config/defaults.ts`](src/config/defaults.ts). The full, documented option
catalog is [`src/config/schema.ts`](src/config/schema.ts) and covers: SoC
target (core config, XLEN, extensions, frequency, voltage, process), toolchain
pins, simulators, test suites, submodule pins, physical-design flow, per-OS
package managers, and logging.

```ts
import { defineBuildConfig } from "./build-platform/src/config/schema.ts";

export default defineBuildConfig({
  soc: { coreConfig: "cv64a6_imafdc_sv39", targetFrequencyMHz: 100 },
  simulation: { default: "verilator" },
  tests: { defaultSuites: ["smoke-cv64a6"] },
});
```

## Workspace layout (managed, gitignored)

```
build-platform/workspace/
  build/                 all build / simulation / PnR outputs
  tooling/
    bin/                 aggregated bin dir prepended to child PATH
    riscv/               RISC-V GCC toolchain
    verilator-<ver>/     Verilator install
    spike/               Spike ISS
    iverilog-<ver>/      Icarus Verilog
    python-venv/         contained pip environment
  .cache/
    downloads/           fetched archives
    manifests/           change-detection fingerprints
```

## Testing

Every non-vendored script under `verif/regress` is catalogued as a **suite** in
[`src/config/defaults.ts`](src/config/defaults.ts), tagged with a group
(`smoke`, `arch`, `directed`, `benchmark`, `uvm`, `generated`, `pk`, `linux`),
its required tools, and whether it runs on the open-source toolchain. List them
with their runnable status:

```bash
./build.sh test --list
```

Select what to run — explicit ids, a whole family, or a broad set:

```bash
./build.sh test smoke-cv64a6              # one or more ids
./build.sh test --group arch              # every suite in a family
./build.sh test --open-source             # all suites runnable on the OSS toolchain
./build.sh test --all --include-optional  # everything, incl. heavy/optional suites
```

Suites whose tools, submodule (e.g. `riscv-dv`), or — for UVM suites — a
commercial simulator are missing are **skipped, not failed**, so a broad run
validates cleanly on a partially-provisioned host. The same suites run under
`bun test`; the hardware runs are opt-in:

```bash
./build.sh probe install         # see what is still missing
./build.sh setup --install --profile sim
./build.sh diag run
CVA6_BUILD_RUN_HW=1 bun test     # run the default suite(s) for real
```

Continuous integration ([`.github/workflows/build-platform.yml`](../.github/workflows/build-platform.yml))
verifies the platform on Windows, Ubuntu and macOS, with an on-demand Ubuntu job
that provisions the toolchain and runs the open-source smoke suites.

## Status

The **open-source simulation** path is implemented end-to-end and validated
(`bunx tsc --noEmit` clean, `bun test` green): host detection, **probe/diag**,
config resolution, workspace management, submodule sync, OS-package bootstrap
(apt/dnf/brew/choco), the Python venv, tool install recipes and **install
profiles**, regression discovery + grouping + preflight, and the cross-OS CI
workflow. Commercial EDA (VCS/Questa/Vivado) and PnR (OpenROAD/SiliconCompiler) are
currently **detect-only**. See [`AGENTS.md`](AGENTS.md) for the full status
matrix and extension playbook.

## License

Proprietary © Etienne Cimon (`MIT`). See [`LICENSE`](LICENSE).
This subproject is tooling and
does not alter the CVA6 RTL's Solderpad/Apache licensing.
