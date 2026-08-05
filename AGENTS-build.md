# AGENTS-build — build-platform entry pointer

All CVA6 **build / test / toolchain automation** lives in the `build-platform/`
subdirectory: a **Bun + TypeScript** project that bootstraps a cross-platform
toolchain, manages a contained workspace, and orchestrates the SystemVerilog
build and regression flow from a single top-level `.config.ts`.

> **Command structure & current state (top-level map):**
> **[`AGENTS-build-platform.md`](AGENTS-build-platform.md)** — full CLI catalog,
> workspace artifact map, timings/`clean` flags, residual soaks, and open items.
>
> **Extension playbook** (how to add a tool/command/suite with minimal edits):
> **[`build-platform/AGENTS.md`](build-platform/AGENTS.md)**. Read that before
> modifying anything under `build-platform/`. User-facing quickstart:
> **[`build-platform/README.md`](build-platform/README.md)**.

## Quick facts

- **Single control surface**: the repo-root [`.config.ts`](.config.ts). Editing
  it is normally the *only* change needed to retarget SoC config, tool pins,
  simulators, suites, diagnostics, submodule pins, or physical-design options.
- **Entry points** (both bootstrap Bun if missing, then run the platform):
  - Linux / macOS / Git-Bash / WSL: `./build.sh <command> [options]`
  - Windows PowerShell: `.\build.ps1 <command> [options]`
  - Directly: `bun build-platform/src/cli/index.ts <command>`
- **Commands** (see [`AGENTS-build-platform.md`](AGENTS-build-platform.md) §2 for full structure):
  - **Observe / provision / docs:** `status`, `doctor`, `probe`, `diag`, `man`, `setup`, `tools`, `config`
  - **Uncore / board / foundry:** `vendor`, `mb`, `tech`
  - **Build / test / gate:** `build`, `test`, `verify`, `timings`, `clean`
  - **Structural timing host:** `timings` (`status` / `flist` / `analyze` / `correct` / `compile` / …) — spawns independent `sv-timing/` (see `sv-timing/AGENTS-host.md`; not STA sign-off)
  - **Lifecycle plan:** `architecture/build-platform-workspace-lifecycle.md`
- **Human docs:** `docs/website/` pages under Build Platform + sv-timing mirror this surface.

## Standing agent workflow — probe → install → diag → verify

Use this order on a new host, after a toolchain change, or before a residual
suite (sim / dual-hart / R3). Full detail: `AGENTS-build-platform.md` +
`build-platform/AGENTS.md` §4.6.

```text
1. probe / doctor     — what is missing? (never installs)
2. tools install …    — provision the right profile (sim | dual-hart | spike | all)
   or setup --install --profile …
3. probe install      — re-check; follow any remaining OS-package / WSL hints
4. diag status|run    — compartmentalized checks (per-test Verilator configs)
5. verify / test      — AGENTS.md §0.2 gate and/or regression suites
   optional: timings compile -o <dir> → test --from-timing <dir>
   free space: clean status | clean timings | clean svt | clean svt-tools --yes
```

Concrete examples:

```bash
./build.sh probe
./build.sh tools install dual-hart
./build.sh diag run core
./build.sh timings compile --modules alu -o workspace/build/sv-timing/alu-pack
./build.sh test sv-timing-smoke --from-timing workspace/build/sv-timing/alu-pack
./build.sh clean timings --execution last --dry-run
./build.sh clean svt                    # Cargo sv-timing/target (+ package out/cache)
./build.sh clean rust-target --dry-run   # alias for svt
./build.sh clean svt-tools --yes         # sv-timing/.tools (re-run package setup after)
./build.sh verify --lint
```

| Layer | Command | Role |
|-------|---------|------|
| Snapshot | `status` | SoC + provisioned flags |
| Deep host | `probe` | Capability boxes + install playbook |
| Install | `tools install` / `setup --install` | Profiles / recipes |
| Focused gate | `diag run` | Per-compartment Verilator surfaces |
| Structural FO4 | `timings compile\|validate\|sta-handoff` | Precompile package (`--output` / monorepo-soak packages) |
| Package FO4 soak | `cd sv-timing && python tools/svt.py monorepo-soak` | Sparse real RTL; package-first (philosophy §2.8) |
| Full gate | `verify` | Lint / formal / sim / synth |
| Free space | `clean` | Purpose + age + stamp filters; **`svt` / `svt-tools`** for package Cargo |

- **Workspace**: `build-platform/workspace/` (gitignored, reproducible, safe to delete).
- **Package Cargo bulk**: `sv-timing/target` → `clean svt` (not `clean timings`). Contained toolchain → `clean svt-tools --yes` or `python tools/svt.py clean --all`.
- **Todo tracking**: `AGENTS-todo.md` phase 12; open residual items in
  `AGENTS-build-platform.md` §7; FO4 scale notes in §6.1 there.

## Relationship to the rest of AGENTS governance

- **Licensing**: `build-platform/` follows `AGENTS-licensing.md` (LicenseRef-Proprietary
  / Etienne Cimon for net-new platform code).
- **SoC prime directive** (`AGENTS.md` §0): platform is tooling; `.config.ts` mirrors
  SoC knobs so build/PnR stay aligned.
- **Spec maps** (Zacas, RVV, …): `AGENTS-specs-to-impl.md` / `-to-tests.md` / `-coverage.md`.
- **sv-timing**: package is independent; host wiring is
  `src/tooling/timings.ts` + `commands/timings.ts` only. Package design:
  `sv-timing/AGENTS.md`.
