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

## Verilator of record (since 2026-10-13): the g6lc fork, split-loops `.vlt`, multi-threaded

- **Default flavour `g6lc`** (`toolchain.verilatorFlavour` in `.config.ts`, env
  `SOFT_LADDER_VERILATOR_FLAVOUR`, installer `VERILATOR_FLAVOUR`): the LibreCore fork pinned
  as the submodule `tools/verilator` (v5.008 + the compiler work recorded in
  `agents/guides/AGENTS-verilator-performance.md` §7), built by
  `./build.sh tools install verilator` into `workspace/tooling/verilator-g6lc` (builder prefix:
  `build-platform/scripts/install-verilator-g6lc.sh` → `/opt/testharness/toolchains/verilator-v5.008-g6lc`,
  `VERILATOR_ROOT=<prefix>/runtime`). `verif/regress/soft-ladder-build-harness.sh` resolves that
  prefix itself and adds `build-platform/scripts/verilator-split-loops.vlt` (the `split_var`
  controls) by default for this flavour. Measured on the 8-hart `g6lc64_ooo_server` 300 k boot
  segment, MT4, `-O2`: **3,131 / 3,109 cycles/s** without PGO, **6,612 / 6,593 with the default
  PGO round** (guide §7.4a) against ~2,100 for the pinned upstream build of the same RTL; RVFI per
  core identical. The review runners
  (`run_ooo_fp_review.py`, `run_mc_int2_review.py`, `run_opensbi_source_review.py`) treat this
  runtime as **qualified** (keyed by the sha256 of its `include/verilated_funcs.h` at the gitlink;
  a fork bump that touches that header must update their `qualified` tables) and record
  `runtimeFlavour`.
- **OpenROAD of record: the g6lc fork `tools/openroad`** (etcimon/OpenROAD, branch `g6lc`;
  nested pins `src/sta` = etcimon/OpenSTA, `third-party/abc` = etcimon/abc). Same shape as the
  Verilator fork: `./build.sh tools install openroad` (or the `timing` profile = formal Yosys +
  openroad) runs `build-platform/scripts/install-openroad-g6lc.sh`, which `git submodule
  update --init --depth 1`s the gitlink and its two nested submodules (clones the fork when the
  repo is not a checkout), builds with `-march` per `toolchain.openroad.march` (`auto` →
  `x86-64-v3` where the host has AVX2+BMI2; the fork's Steiner decoder and ABC word simulator
  carry AVX2 paths), `JOBS` = every core, and `OPENROAD_PGO=1` by default (two full builds,
  trained on the fork's `test/aes_nangate45.tcl`), into `workspace/tooling/openroad-g6lc`
  (builder prefix `/opt/testharness/toolchains/openroad-g6lc`; Windows builds through WSL).
  Every flow metric of the fork is identical to upstream `9b7414e`
  (`tools/openroad/AGENTS-openroad/architecture/OPPORTUNITIES.md` "Flow-metric parity"); the
  two `aes_*` metric-limit misses the fork's regression reports are reproduced by unmodified
  upstream in this toolchain. PGO: `repair_design` 4.30 → 3.53 s, CTS + `repair_timing`
  38.9 → 29.3 s, results unchanged.
- **`pinned`**: the upstream `v5.008` tag + `verif/regress/verilator-*.patch`, the qualification
  cross-check and the fallback the harness takes (with a log line) when no fork prefix exists.
  CI's lint gate pins this flavour in its `.config.local.ts` overlay because the fork commit must be
  reachable (submodule or `etcimon/verilator`) — pushing the gitlink is part of a fork bump.
- **PGO is on by default** (`SOFT_LADDER_BUILD_PGO=1`; `simulation.verilator.pgo`): the harness
  builds the generated C++ instrumented (`-fprofile-generate`), compiles the in-repo training
  probe (`verif/tests/custom/ooo/ooo_fp_ooo.S` with `common/crt.S`, `syscalls.c`,
  `link_verilator.ld`), runs it once to completion and once to the cycle cap (idle/spin paths),
  then recompiles the same sources with `-fprofile-use -fprofile-correction
  -fprofile-partial-training` (`__Syms` at `-O1` first — it carries no hot code and takes hours at
  `-O2` with a profile on the server). Layout only: every battery in the guide was run on PGO
  models and they retire the same RVFI stream; measured with this exact default on the 300 k
  server boot segment **3,044 → 6,612 cycles/s (×2.2, 2.3× less CPU, per-core RVFI identical)**
  and +30 % on the single-core spin (guide §7.4a). It roughly doubles the C++ compile time;
  `SOFT_LADDER_BUILD_PGO=0` / `build --no-pgo` skips it, `SOFT_LADDER_BUILD_PGO_TRAIN=<elf>` and
  `SOFT_LADDER_BUILD_PGO_CYCLES` change the workload.
- **`-O2`** (`SOFT_LADDER_BUILD_OPT`; `simulation.verilator.opt`) overrides `verilated.mk`'s
  `OPT_FAST = -Os` for the generated C++ (the PGO recipe was measured at `-O2`). The slow classes
  (`VM_*_SLOW`: the 30 MB `__Syms` unit, init/settle code — no hot code) always compile at `-O1`
  (`SOFT_LADDER_BUILD_OPT_SLOW`): at `-O2` that unit alone takes 30+ min, two overlapping server
  builds OOM-killed cc1plus on the 125 GB builder (instrumented or not), and with a profile it runs
  for hours for nothing; the RVFI stream does not depend on it.
- **Host ISA `x86-64-v3` by default for `g6lc`** (`SOFT_LADDER_BUILD_MARCH`;
  `simulation.verilator.march`, `auto` = this rule): the harness appends `-march=x86-64-v3`
  (AVX2+BMI2, every 2013+ x86) to the generated C++ when the build host has `avx2`+`bmi2`; the
  pinned flavour stays at baseline so the qualification reference recipe is unchanged. Measured on
  `g6lc64_ooo`, same tree, RVFI byte-identical on the s11 and wrong-path probes (guide §10.4,
  §10.6): host instructions per cycle **874,598 → 424,291 (−51 %)** from the ISA floor alone,
  I1 misses −39 %; the single-core spin **3,571 → 16,644 cycles/s** before PGO. `native` binds
  the model to the build host (AVX-512 on the builder; `-DVL_SIMD_PREFER_512` in
  `SOFT_LADDER_BUILD_CXXFLAGS` for 16-word kernels), `none` is the pre-§10 recipe. A model built
  with this default must run on an AVX2 host.
- **Fork compiler defaults at the current pin** (on at `-O1`+, `-fno-…` / `VERILATOR_FNO=…` to
  disable): `-ftrigger-words` (region guards over one trigger vector become one
  `wordAny(word, mask)` per 64-bit word; −7.8 % Ir/cycle on `g6lc64_ooo`, guide §10.5) and
  `-ffield-split`; the runtime headers carry the word-vector kernels of guide §10.2 (SSE2/AVX2/
  AVX-512 by `-march`, `VL_DISABLE_SIMD` for scalar) and the `_vl_insert_WI/WW` bounds fix of
  guide §9.4. `-fclock-skip` stays **opt-in** (exact but +10 % Ir on the dense core, §9.7).
  **Runtime qualification status:** the fork header at this pin (`include/verilated_funcs.h`
  sha256 `e900ec45…`) is **not yet in the review runners' `qualified` tables** (they still list
  `g6lc-fork@453031b66` = `83b7f47b…`); the two probes retire the reference RVFI stream, but the
  11-probe / FP-suite / anchor battery has not been re-run on it, so the runners treat it as
  experimental until `REVIEW_EXPERIMENTAL_RUNTIME_SHA256` declares it or the battery passes and
  the tables are updated (owed, `AGENTS-todo.md`).
- **4 model threads** by default (`SOFT_LADDER_VERILATOR_THREADS`; `simulation.verilator.threads`,
  0 = this default): the measured point for the 8-hart server — the partition is
  synchronisation-bound (1.9–2.0× of 4), more threads did not pay (guide §4b.2). The review
  runners pass 1: their qualification compare needs a single-thread model.
- **`./build.sh build` uses the harness** (`simulation.verilator.recipe: "harness"`), so a local
  build gets the same flavour / split `.vlt` / `-O2` / PGO as the builder; `--make` (or
  `recipe: "make"`) is the plain `make verilate` upstream path (`-Os`, no controls, no PGO) and
  the fallback when no bash is available. With `--elf` the built `work-ver/Variane_testharness`
  runs the ELF.
- Other knobs: `SOFT_LADDER_BUILD_SPLIT_VLT=0|1` (default on for `g6lc`, off for `pinned` — the
  upstream compiler refuses most entries), `VLT_HOME` / `VERILATOR_ROOT` (explicit prefix, always
  wins). The hierarchical core (`SOFT_LADDER_BUILD_DEFINES=G6LC_CORE_HB`) stays opt-in: exact and
  a third faster to build, 2.1× slower to run (guide §7.5). Verilator's own `--prof-pgo`
  (`profile.vlt` MTask re-partition) measured no gain and is **not** part of the default (§4b.2).
- **Qualification cross-check builds stay pinned, single-thread, no PGO**: the review runners'
  internal rebuilds (`run_mc_int2_review.py`, `run_checked_work_review.py`,
  `run_l2_size_review.py`) set `SOFT_LADDER_BUILD_PGO=0` and `VERILATOR_ROOT=<pinned runtime>`
  explicitly; their timeouts are sized for that build.

## Standing agent workflow — probe → install → diag → verify

Use this order on a new host, after a toolchain change, or before a residual
suite (sim / dual-hart / R3). Full detail: `AGENTS-build-platform.md` +
`build-platform/AGENTS.md` §4.6.

```text
1. probe / doctor     — what is missing? (never installs)
2. tools install …    — provision the right profile (sim | dual-hart | spike | timing | all)
   or setup --install --profile …
3. probe install      — re-check; follow any remaining OS-package / WSL hints
4. diag status|run    — compartmentalized checks (per-test Verilator configs)
5. verify / test      — AGENTS.md §0.2 gate and/or regression suites
   optional: timings compile -o <dir> → test --from-timing <dir>
   manual redesign output: --from-timing out_rtl   (local link → workspace/hyp; not a stamp package)
   gate-level STA: timings sta-rtl --target <cfg> [--platform nangate45|sky130hd] [--remote]
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
./build.sh tools install timing          # formal Yosys + tools/openroad fork (-march, PGO)
./build.sh timings sta-rtl --target g6lc64_ooo --platform nangate45          # yosys map + openroad STA, here
./build.sh timings sta-rtl --target g6lc64_ooo_server --remote --target-mhz 1250  # same two steps on the builder
./build.sh timings sta-rtl --target g6lc64_ooo --platform nangate45 --fo4 10 --allow-over-budget --remote --map-recipe streamed
                                          # the integrated route: sv-timing at 10 FO4 → emitted tree → streamed yosys map → STA (STUDY on a miss)
```

**Gate-level STA of the LibreCore RTL (`timings sta-rtl`).** Yosys (the managed formal build,
integrated slang) reads the target's flattened manifest (`core/` + `corev_apu/`), `synth
-flatten`s the synth top (`verify.synthTopByTarget`, default `cva6`), maps it onto a liberty
with `dfflibmap` + `abc`, and the fork runs `build-platform/scripts/openroad-timing.tcl` on the
netlist against a generated SDC: one clock on `--clock-port` (default `clk_i`) at `--target-mhz`
(default `soc.targetFrequencyMHz`), I/O delays at 20 % of the period. The fork's **`sta`**
binary is preferred (it links from the liberty alone); its `openroad` binary needs the
platform LEF (`OR_LEF`; `link_design` is ODB-backed, ORD-2010 otherwise) and gets
`set_thread_count` = `toolchain.openroad.threads`. The liberty is `--liberty` /
`physicalDesign.pdk.liberty` / `CVA6_LIBERTY`, else the fork's free study library for
`--platform` (default `soc.process`: `nangate45`, `sky130hd`, `sky130hs`, per the fork's
`test/<platform>.vars`) — a study library ranks paths, it is not sign-off. `--remote` runs
both steps as one script on `ovh_calltorch` through the testharness proxy (`sync` first),
building the fork prefix there when it is missing (`install-openroad-g6lc.sh`,
`OPENROAD_SRC=/opt/testharness/src/openroad-g6lc` at the local gitlink, `-march`/PGO from the
config, `nproc` jobs; `--rebuild-openroad` forces it) and reporting
`wns_max`/`tns_max`/`wns_min`/`tns_min` plus `reports/paths-{max,min}.rpt`.
`timings sta-handoff` is the package-driven path (S0–S2/S4) and resolves the same managed fork
(`sta`, then `openroad`) before a PATH `sta`.

**sv-timing first — on by default (`physicalDesign.structural`).** `timings sta-rtl` runs the
structural pass before synthesis: `timings correct --all-modules --allow-latency --emit` on the
target's flist at `fo4Budget` (10) — turned into the clock sv-timing derives it from
(`targetMhzForFo4Budget`: 10 FO4 = 4000 MHz at `fo4_ps` 20, margin 0.2; `fo4_ps` is a process
input, quote it with every number) — with `optLevel` `3` and `svtArgs`
`--opt-max-stages-per-region 13 --real-cut-feeds --assume-clk`, then synthesizes the emitted
tree (`writeFlatManifest` emit overlay). `--fo4 N` overrides, `--fo4 0` runs the live RTL,
`--from-timing <pkg>` reuses an existing emit, `--svt-args "..."` appends raw dials
(`--emit-balance-mux-rtl` stays opt-in), `--map-recipe lean|synth` picks the yosys lowering
(`lean` skips the `opt_merge`/`check` passes that ran past an hour on the whole core). The emit
under `build-platform/workspace/build/sta-rtl/` is part of the proxy `sync`, so `--remote`
synthesizes it too. The same knob is on `timings compile|correct|area` (`--budget-fo4`,
`--fo4-ps`, `--budget-margin`, `--opt-level`, `--svt-args`), which forward
`--fo4-ps`/`--budget-margin` on `correct` and no longer pass `--cache` to it (analyze-only in
the CLI; `correct` exited 2 at argument parsing before).

**The integrated route and its studies (state 2026-10-16).** `--map-recipe streamed` (remote) is
the only recipe whose memory is bounded by the word-level design: phase A dumps RTLIL and the
module list (and `width-map.json`, hashed against the live sources so a stale map is never
consumed), phase B maps one module per yosys process in parallel with the delay-oriented ABC
script and a content-keyed resume cache, then the whole core links in the fork's `sta`.
`--allow-over-budget` lets a budget **MISS** map anyway and labels the result **STUDY**; a
run without a complete validated emitted analysis is **INCONCLUSIVE**, never an optimistic
fallback. On the streamed artifacts, `build-platform/scripts/openroad-module-board.tcl` reports
each module's worst register-to-register path (ns, cells, RTL start/end nets) with children
black-boxed and broadcast drivers disabled, and `scripts/sta_module_delta.py <live run>
<emitted run>` the per-module area/depth delta. Read cells, not single ns (identical RTLIL maps
to ±1 % area / ±6 cells across runs). The structural model is calibrated against those cells
(sv-timing delay-v37: iq 16.5 FO4 / 47 cells, store_buffer 38.5 / 49, wbuffer 18.6 / 21); the
live `g6lc64_ooo` board reads **38.5 FO4 worst, 673 of 1628 reg→reg over 10 FO4** — the OoO
control cones, not arithmetic — and 10 FO4 is not closed. Flags, stages and labels:
`AGENTS-build-platform.md` §7.1; numbers and their provenance: `sv-timing/ALGORITHMS-EXPERTS.md`
A97–A103 and `sv-timing/architecture/FREQUENCY-CLOSURE.md`.

Why those three dials, measured on `g6lc64_ooo` at 10 FO4 (264 files, 234 modules, 10,858
paths, ~2 min release build) on 2026-10-15: `-O2` → 451 annotate edits, nothing structural.
`-O3` + 13 stages → 32 BalanceMux rewrites, but 47 of the 62 refusals were `incomplete_gate` —
no default clock/edge resolved, so no register ever landed and the worst path stayed at
31.0 FO4; `--assume-clk` (every LibreCore module gates on `posedge clk_i`/`negedge rst_ni`;
the package's own soak default) lets the trial's `CriticalChain` registers land: **82 InsertReg
+ 32 BalanceMux, failing endpoints 389 → 333, worst 31.0 → 23.5 FO4 (`scoreboard.reg1/D`),
max ≈ 1290 → 1702 MHz**. `--real-cut-feeds` is what turns those edits into the origin RHS
rewrite yosys can see; its emit failed elaboration four ways on this core and the package fixes
all four (`sv-timing/AGENTS-todo.md` 2026-10-15: block-local hoist, enum/struct LHS type, pipe
declared after its first read, generate-local cut) — the fixed emit elaborates under
`read_slang`. The residual above 10 FO4 is the package's documented gap
(`sv-timing/ALGORITHMS-EXPERTS.md` Part VII): atomic operators, real handshakes (P10),
multi-cycle tags, dense cones a balance cannot close, and cuts refused downstream of the trial
(`cleanliness_set`); the 407 relocation cards' T3 multi-cycle options are manual.

**Follow-up measurement, delay-v26 (2026-10-15).** The final scope-safe snapshot has
33 InsertReg records and 351 failing paths under delay-v25; the 82/333 numbers above
describe an earlier trial. A loop-origin coordinate fix remeasures the same emitted
SV at **21.5 FO4** (349 failing paths), with the scoreboard cone 23.5 → 14.5:
measurement correction, not a physical speedup. Small-cone SAT/STA found useful
two-port constant-increment and width-4 FIFO-delta candidates, while carry-save and
popcount-tree generalizations regressed. `sv-timing/ALGORITHMS-EXPERTS.md` Part LI
records the actual source loci, conditions, area tradeoffs and next RTL work.

`sta-rtl` writes an elaborated `CVA6Cfg` snapshot (yosys-slang probe) into the
sv-timing param-map, substitutes a registered study stub for `tc_sram`
(`--no-sram-stub`), maps with a delay-oriented ABC script, and offers
`--map-recipe streamed` for whole-core mapping within the builder's memory.
sv-timing measurement is `delay-v31` (width-scaled, cast-transparent,
carry-save sums); see `sv-timing/ALGORITHMS-EXPERTS.md` Part LIII.

`sta-rtl` now stops before mapping if the emitted pre-pass misses its budget.
`--allow-over-budget` (or `physicalDesign.structural.allowOverBudget=true`) is an
explicit study override, not a closure result. Missing/incomplete evidence still
fails. The latest planner corrections and review candidates are in
`sv-timing/ALGORITHMS-EXPERTS.md` Part LII; they supersede earlier fresh-run claims.

| Layer | Command | Role |
|-------|---------|------|
| Snapshot | `status` | SoC + provisioned flags |
| Deep host | `probe` | Capability boxes + install playbook |
| Install | `tools install` / `setup --install` | Profiles / recipes |
| Focused gate | `diag run` | Per-compartment Verilator surfaces |
| Structural FO4 | `timings compile\|validate\|sta-handoff` | Precompile package (`--output` / monorepo-soak packages) |
| Gate-level STA | `timings sta-rtl [--remote]` | Yosys liberty map + `tools/openroad` fork report (study liberty unless yours) |
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
- **The lint gate's Verilator is the pinned v5.008 with the repo's custom fixes** (the overlay sets
  `toolchain.verilatorFlavour: "pinned"`; the simulation build of record is the g6lc fork, see
  "Verilator of record" above). Ubuntu's `verilator`
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
