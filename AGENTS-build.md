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
  - **Build / test / gate:** `build`, `test`, `verify`, `timings`, `clean`, `g6q`, `g6b`
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

## Remote testharness

For hosts where local Verilator builds are impractical, `verif/regress/remote/testharness_proxy.py`
(or `verif/regress/remote-testharness.sh`) runs simulations on a remote builder (`ovh_calltorch` by
default) while keeping the per-test payload minimal.

**Multi-threading / soft-ladder:** the proxy is the **harness of record**, not an opt-in when WSL
is slow. Spike ISS, soaks, peels, TRACE, and I4dp Linux-cap evidence go through it only.
Classify from `runs/<tag>/run-*.log`. Plan: `architecture/multi-threading/testharness-proxy.md`.

### First-time flow

```bash
bash verif/regress/remote-testharness.sh doctor    # probe local + remote
bash verif/regress/remote-testharness.sh setup     # provision toolchains once
bash verif/regress/remote-testharness.sh sync      # rsync minimal repo subset
bash verif/regress/remote-testharness.sh build B                   # build stock (fetch_B) harness
bash verif/regress/remote-testharness.sh build legacy              # build smt_legacy oracle
bash verif/regress/remote-testharness.sh build B --output-cache    # seed/restore cached Mdir
```

### Per-test run (only the ELF is uploaded)

```bash
bash verif/regress/remote-testharness.sh run /path/to/mini.elf --flavour B
```

### A/B OpenSBI cookie soak

```bash
bash verif/regress/remote-testharness.sh soak --flavour B
bash verif/regress/remote-testharness.sh soak --flavour legacy
```

### Remote Python scripts (multi-threaded)

Upload one or more local Python scripts and run them on the builder with a
remote `concurrent.futures.ThreadPoolExecutor`:

```bash
bash verif/regress/remote-testharness.sh py --threads 4 script1.py script2.py
```

Each script runs in its own `python3` process; the runner collects
`output/<stem>.log`, `summary.json`, and `summary.txt`. Options:

| Option | Meaning |
|--------|---------|
| `--threads N` | worker count for the remote thread pool (default 1) |
| `--data PATH` | upload a file or directory for scripts to read (repeatable) |
| `--env KEY=VALUE` | set an env var for every script (repeatable) |
| `--pull` | copy `output/` back to `remote-runs/<tag>/output/` |

Inside the scripts, useful env vars are set:

- `TH_PROXY_THREADS`
- `TH_PROXY_TAG`
- `TH_RUN_DIR`
- `TH_DATA_DIR`
- `TH_OUT_DIR`
- `TH_SCRIPT` / `TH_SCRIPT_NAME`

### Build caching

`build` automatically enables `ccache` and `mold` when they are present on the remote host:

| Flag | Effect |
|------|--------|
| `--cache` (default) | Detect and use `ccache` / `mold` if available. |
| `--no-cache` | Force the system linker and disable `ccache` auto-detection. |
| `--output-cache` | Seed the full Verilator `Mdir` from a content-keyed cache under `/opt/testharness/cache/builds/` and archive it after a successful build. The cache key is a SHA-256 of the RTL/TB sources, `Makefile`, flists, and `verilator_config.vlt`, so switching branches invalidates it safely. |

Relevant environment variables:

| Variable | Meaning |
|----------|---------|
| `TH_SSH_BIN` / `TH_RSYNC_BIN` | Override the `ssh` / `rsync` binaries (e.g. Windows Git-Bash, WSL wrapper). |
| `TH_SSH_CONFIG` / `TH_SSH_KEY` / `TH_SSH_PASSPHRASE*` | SSH config file, identity, or passphrase source. |
| `TH_REMOTE_HOST` | Default `ovh_calltorch`; passed to `--host`. |
| `TH_REMOTE_ROOT` | Remote root directory (default `/opt/testharness`). |
| `TH_TARGET` | Default Verilator target (default `g6lc64_smt2`). |
| `TH_BUILD_JOBS` | Parallel build jobs during `setup` toolchain provisioning (capped to 8). |
| `build --jobs N` | Parallel `make -j` value for `build` (default `$(nproc)`). |

### Logging and debugging

- `-v` / `--verbose` prints every remote command, rsync invocation, and key timing.
- `-d` / `--debug` adds sub-second timing, ssh-agent state, and ControlMaster setup.

### Credentials

The SSH key passphrase is read from `$TH_SSH_PASSPHRASE`, then `~/.config/librecore/th-remote.pass`,
then `~/.ssh/th-remote.pass`. The default `ovh_calltorch` key is `~/.ssh/id_ed25519`. The passphrase
is loaded into `ssh-agent` once per invocation; a persistent ControlMaster socket is used for all
subsequent traffic. Nothing is committed to the repository.

### Layout on the remote host

```text
/opt/testharness/
  toolchains/          verilator, riscv-gcc, spike (provisioned once)
  repo/                rsync'd RTL + build sources
  work/                verilator --Mdir libraries (one per flavour)
  runs/<tag>/          per-test ELF + log
  cache/               downloads
```

For the soft-ladder execution rule, see `architecture/multi-threading/testharness-proxy.md`.
A/B blame: `architecture/firmware-boot-principles.md`.

### Build-platform `remote` command

The build-platform also exposes the proxy through the `remote` command, with
passphrase caching in a gitignored file.

```bash
bun run src/cli/index.ts remote --remote-ssh ovh_calltorch doctor
bun run src/cli/index.ts remote setup
bun run src/cli/index.ts remote sync
bun run src/cli/index.ts remote build B
bun run src/cli/index.ts remote soak --flavour B
bun run src/cli/index.ts remote shell
```

First use for a host prompts for the SSH key passphrase (or password) and stores
it in `build-platform/.remote-ssh-creds` (mode `0600`, gitignored). You can also
seed the cache non-interactively:

```bash
bun run src/cli/index.ts remote --remote-ssh ovh_calltorch --remote-ssh-pass pwrd128 build B
```

The command reads `~/.ssh/config` to resolve the host, user, and `IdentityFile`
when they are not supplied on the command line.

## Continuous integration (`.github/workflows/ci.yml`)

CI is the same platform loop, run in parallel lanes on `ubuntu-latest` (plus a Windows leg for
the platform itself). Every lane finishes in minutes, provisions **only** what it needs, and calls
the package's own green gate through `./build.sh` where a surface exists:

| Lane | Provisioning | Command(s) |
|---|---|---|
| `platform` (ubuntu, windows) | Bun | `bunx tsc --noEmit`, `bun test`, `config` / `status` / `test --list` / `test --open-source --dry-run` / `diag run host` / `timings doctor` / `timings lab-run` |
| `rtl-lint` | submodules `core/cvfpu`, `core/cache_subsystem/hpdcache`; pinned Verilator v5.008 built into `build-platform/workspace/tooling/verilator-v5.008` (cached) | `diag run core diag-smt2-lint diag-smt2-comb-loops diag-ooo-int-lint diag-smt2-ooo-int-lint diag-ooo-int2-lint diag-ooo-int2-l3-lint diag-smt2-l3-lint diag-ai-lint` |
| `sv-timing` | submodule `sv-timing/crates/sv-parser`; `svt.py setup` (contained toolchain, cached) | `svt.py test`, `test sv-timing-smoke`; `svt.py check` informational until rustfmt/KD0 drift is fixed |
| `bios` | Rust 1.85.0; `g6b.py spec-sync` (kernel-spec + botan vectors) | `g6b check --rust-only` (browser-ui bun lane needs the libwasm/svelte-d submodules + LDC, so it stays local) |
| `qemu` | Rust 1.85.0 | `g6q doctor`, `g6q check` |
| `ai-tensor` | Rust 1.85.0; `pytest numpy` | `tensor doctor`, `tensor test`, `pytest ai-tensor/python/tests` |
| `smoke` | `setup --install --allow-system-install` (Verilator + Spike + RISC-V GCC) | `test --group smoke` — **workflow_dispatch only** (`smoke: true`) |

Design rules the workflow follows:

- **Checkout is `submodules: false`.** Each lane inits the exact submodules it needs. A full
  recursive checkout does work (every nested pointer is published, including the
  `etcimon/postgres-pglite` fork under `g6lc_bios/pglite`), but the lazily-used heavy trees
  (`vendor/ara/upstream`, `g6lc_qemu/linux-dist/*` — ~2.6 GB, 21 nested submodules, ~4 of the
  ~6 minutes) are `update = none` in `.gitmodules`, so recursive inits skip them and the explicit
  syncs (`vendor sync`, `linux-dist/init-submodules.sh`) pass `--checkout` (see `AGENTS-vendor.md` §4.1).
- **The gate's Verilator is the pinned v5.008 with the repo's custom fixes.** Ubuntu's `verilator`
  5.020 lints the core packages but segfaults on the cluster lint top (`g6lc_ooo_int2*`, `*_l3`),
  and any stock tool lacks `verif/regress/verilator-*.patch`. CI therefore runs
  `./build.sh tools install verilator` — the platform recipe
  (`build-platform/scripts/install-verilator.sh`) that clones the pinned tag, applies every patch
  strictly, skips Verilator's own `make test` and verifies the installed headers carry each
  patched line — behind an `actions/cache` of the prefix, then re-checks `(mod)` + the patched
  header, and points the gate at it through the gitignored overlay `build-platform/.config.local.ts`
  (`verify.suite.root: "verilator-v5.008"`). See `build-platform/AGENTS.md` §4.6.2 (verilator).
- **Rust lanes cache with `Swatinem/rust-cache` + `git restore-mtime`.** The workspaces have no
  crates.io dependencies (KD0), so the cache is only useful if unchanged workspace crates keep their
  fingerprints — which needs source mtimes restored from git history.
- **`G6LC_NO_TOOL_PROMPT=1`** so `test` never waits on the "install missing tools?" prompt.
- Heavy upstream regressions (`openhw-cva6-ci-tier1/2.yml`) are `workflow_dispatch` only; docs are
  built and published by `deploy-docs.yml`.
- **GitLab mirror** (`https://gitlab.com/etcimon/GSys-LibreCore`): the repo-root `.gitlab-ci.yml`
  is the same six lanes for gitlab.com shared runners (2 vCPU; GitLab `cache:` for the Verilator
  prefix, `sv-timing/.tools` + `target`, and the Rust `target/` dirs; `GIT_SUBMODULE_PATHS` per lane;
  pipelines on the default branch, MRs, web and schedules, `interruptible`). The upstream
  OpenHW/Thales pipeline — a private `$CI_PROJECT_NAMESPACE/setup-ci` include and VCS/Questa/Vivado
  runners, which on gitlab.com failed at configuration with zero jobs — is kept verbatim at
  `.gitlab-ci/openhw-thales-pipeline.yml` for a mirror that has that infrastructure.

## Relationship to the rest of AGENTS governance

- **Licensing**: `build-platform/` follows `AGENTS-licensing.md` (LicenseRef-Proprietary
  / Etienne Cimon for net-new platform code).
- **SoC prime directive** (`AGENTS.md` §0): platform is tooling; `.config.ts` mirrors
  SoC knobs so build/PnR stay aligned.
- **Spec maps** (Zacas, RVV, …): `AGENTS-specs-to-impl.md` / `-to-tests.md` / `-coverage.md`.
- **sv-timing**: package is independent; host wiring is
  `src/tooling/timings.ts` + `commands/timings.ts` only. Package design:
  `sv-timing/AGENTS.md`.
