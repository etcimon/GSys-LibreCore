# Build-platform workspace lifecycle — clean granularity & timings hand-off

| Field | Value |
|---|---|
| **Status** | Plan of record (guides development; no RTL / flist impact) |
| **Owner surface** | `build-platform/` (host tooling only) |
| **Related** | `AGENTS-build.md`, `build-platform/AGENTS.md`, `architecture/sv-timing/`, `sv-timing/AGENTS-host.md` |
| **Scaffold contract** | **Nothing here is compiled.** This document never enters a flist. |

---

## 1. Why this exists

Long residual loops (compartmentalized `diag`, Verilator soaks, formal tasks, `sv-timing` analyze/correct, `make verilate` → `work-ver/`) leave **reproducible but bulky** artifacts. Today `cva6-build clean` only deletes coarse roots (`workspace/build`, optionally `tooling` / `.cache` / entire workspace). That is too blunt for day-to-day development:

- Operators need to free **old diagnostic Verilator surfaces** without wiping a just-installed OSS CAD suite.
- Soaks leave `work-ver/` at the **repo root** (Makefile `ver-library`), outside `workspace/` — the current clean never touches them.
- Timings precompile outputs (`workspace/build/sv-timing/**`) are a **cache-like** intermediate that should be age- and purpose-selectable, and later **reused** by test/diag/sim via `--from-timing`.

This plan specifies a **proper `clean` command** (subcommands + filters) and a **`--from-timing` host path** that keeps `sv-timing/` package-independent while letting build-platform soaks validate post-precompile logical structure.

---

## 2. Architectural bounds (must not break)

| Bound | Rule |
|---|---|
| **Contained deletions** | Prefer deletes under `build-platform/workspace/`. Repo-root sim libraries (`work-ver/`, legacy `obj_dir/`) are **opt-in** via explicit subcommands (`clean sim` / `clean verilator-out`) and documented allowlists — never recursive repo walks. |
| **Never delete source** | No path under `core/`, `corev_apu/`, `verif/tests/`, `sv-timing/crates/`, `architecture/`, `agents/`, `specs/` is a clean target. |
| **Never delete NDA PDK** | `pd/pdk/**` is out of scope for `clean` (gitignored; operator-managed). |
| **sv-timing independence** | Package does not know monorepo layout. Host maps cache/out-dir into workspace; package SQLite default `./.sv-timing-cache/` is only cleaned when host discovers it under an allowlisted path or an explicit `--path`. |
| **architecture/ scaffold** | This file stays documentation-only; promotion of any clean/timings code is only under `build-platform/src/**`. |
| **Config surface** | New knobs (clean retention defaults, timings hand-off dirs) land in `.config.ts` / `schema.ts` / `defaults.ts` — no hard-coded host paths in commands beyond `WorkspacePaths`. |
| **Zero runtime npm deps** | Clean inventory uses Bun/`node:fs` only. |

---

## 3. Artifact taxonomy (what accumulates)

### 3.1 Managed workspace (`build-platform/workspace/`)

```
workspace/
  build/                         # default clean target (ephemeral outputs)
    diagnostics/                 # diag run: flat .f manifests (per-test Verilator surface)
    verify/                      # verify lint/elab/synth flat manifests
    formal/<task>/               # SymbiYosys -d workdirs
    sv-timing/
      host-<target>/             # timings flist | analyze.json | correct.json | corrected/
      verif-tests/<suite>/       # regress suite outs (smoke/sparse/autocorrect/advanced)
      param-map.json
    # future: sim logs, synth yosys dumps, soak run stamps
  tooling/                       # provisioned tools — expensive; clean only on demand
    riscv/  verilator-<ver>/  spike/  iverilog-<ver>/  oss-cad-suite/  python-venv/  bin/
  smt2-linux/                    # OpenSBI SMT2 fw_payload (profile dual-hart)
  man/<id>/                      # human man sessions (HTML)
  linux-dts/                     # sparse DTS fetch (AGENTS-dts-validation)
  .cache/
    downloads/                   # tool archives
    manifests/                   # discovery size:mtime fingerprints (incremental build)
```

**Purpose labels** (for clean filters and `clean status`):

| Purpose id | Paths (relative to workspace or repo) | Typical producer |
|---|---|---|
| `diag` | `build/diagnostics/` | `diag run` |
| `verify` | `build/verify/` | `verify --lint/--synth` |
| `formal` | `build/formal/` | `verify --formal` |
| `timings` | `build/sv-timing/` | `timings *`, `test sv-timing-*` |
| `man` | `man/` | `man` |
| `dts` | `linux-dts/` | fetch-linux-dts scripts |
| `manifests` | `.cache/manifests/` | `build` incremental |
| `downloads` | `.cache/downloads/` | `tools install` / recipes |
| `tooling` | `tooling/**` | `setup --install`, `tools install` |
| `firmware` | `smt2-linux/` | dual-hart / opensbi profile |
| `sim-out` | repo `work-ver/` (Makefile `ver-library`) | `build` / `make verilate` / soak scripts |
| `svt-package-cache` | host-chosen `--cache` or package-local `.sv-timing-cache/` under workspace only | `sv-timing` CLI |

### 3.2 Repo-root / residual (outside workspace)

| Path | Notes |
|---|---|
| `work-ver/` | Default Verilator library (`Makefile` `ver-library ?= work-ver`). Large object trees; soak scripts (`mc-spo-veri`, `mc-mini-veri`) rebuild with `rm -rf work-ver`. |
| `sv-timing/target/` | Cargo build dir (package-local). **Not** workspace. `clean svt` / `clean rust-target` (allowlisted leaf only). |
| Package `.sv-timing-cache/` / `.sv-timing-out/` | Package CWD defaults when CLI run bare; also cleaned by `clean svt`. Host soaks pin `--cache` under `workspace/build/sv-timing/` (`clean timings`). |
| `sv-timing/.tools/` | Contained rustup/cargo from `svt.py setup`. `clean svt-tools --yes` (re-run setup after). |

---

## 4. Command design — `cva6-build clean`

### 4.1 UX shape (match `diag` / `vendor` / `timings`)

```text
cva6-build clean --help
cva6-build clean status [--json] [--human-size]
cva6-build clean <purpose|subcommand> [filters…]
cva6-build clean all [--tooling] [--firmware] [--sim]   # explicit escalation
```

**Subcommands / purposes** (positional after `clean`):

| Subcommand | Default action | Safety |
|---|---|---|
| `status` / `list` | Inventory sizes + ages by purpose; no delete | always safe |
| `build` | Remove entire `workspace/build` | default of bare `clean` today |
| `diag` | `build/diagnostics/` | |
| `verify` | `build/verify/` | |
| `formal` | `build/formal/` | |
| `timings` | `build/sv-timing/` | |
| `cache` | `.cache/` (or split `manifests` / `downloads`) | |
| `manifests` | `.cache/manifests/` only (forces rebuild re-fingerprint) | |
| `downloads` | `.cache/downloads/` | |
| `man` | `workspace/man/` | |
| `dts` | `workspace/linux-dts/` | |
| `tooling` | `workspace/tooling/` | requires confirm or `--yes` in non-dry-run |
| `firmware` | `workspace/smt2-linux/` | expensive rebuild |
| `sim` | repo-root `work-ver/` (allowlist) | **opt-in**; never implied by bare `clean` |
| `svt` / `rust-target` | `sv-timing/target`, `.sv-timing-out`, `.sv-timing-cache` | **opt-in**; never crates/source |
| `svt-tools` | `sv-timing/.tools` | **opt-in** + `--yes` |
| `all` | whole workspace root; flags add `sim` / never PDK | same as today's `--all` + optional sim |

Bare `clean` (no subcommand): **preserve current behaviour** — remove `workspace/build` only — and print a one-line hint: `see clean status | clean --help`.

### 4.2 Filters (granularity)

| Flag | Meaning |
|---|---|
| `--older-than <duration>` | Only remove entries whose mtime (dir tree max or stamp file) is older than `Nd` / `Nh` / `Nm` (e.g. `7d`, `12h`). Default: no age filter (delete matching purpose entirely). |
| `--newer-than <duration>` | Inverse (rare; for “wipe fresh failed soaks”). |
| `--purpose <id[,id…]>` | When using `clean select` or multi-purpose; alias for multiple positionals. |
| `--compartment <c>` | For `diag`: only tags matching compartment (`core`, `smt2`, …) if filenames encode tag. |
| `--target <cfg>` | Limit timings/verify/diag artifacts tagged with that config package. |
| `--execution last\|failed\|all` | Prefer stamp files (`*.stamp.json` or suite exit logs) when present; **v1** may implement `all` only and stub `last`/`failed` until stamps exist. |
| `--dry-run` / `-n` | Print planned deletes + sizes (global flag already). |
| `--yes` / `-y` | Required for `tooling` / `all` / `sim` when not dry-run (interactive safety). |
| `--json` | Machine inventory or delete plan. |

### 4.3 Implementation sketch (minimal files)

Per `build-platform/AGENTS.md` §4.2:

1. Expand `src/cli/commands/clean.ts` into subcommand dispatch (like `diag.ts` / `vendor.ts`).
2. Add pure helpers `src/workspace/clean.ts` (or `src/tooling/clean.ts`):
   - `listCleanTargets(ctx) → CleanTarget[]` with `{ purpose, path, bytes, mtimeMs, removable }`
   - `selectTargets(targets, filters) → …`
   - `removeTargets(targets, { dryRun, yes })` — `rm` only if `path` is under an **allowlisted root** (`paths.root` or explicit repo allowlist for `work-ver`).
3. Optional config `workspace.clean` in `schema.ts` / `defaults.ts`:
   ```ts
   clean: {
     defaultPurposes: ["build"],           // bare clean
     retentionDays: { diag: 7, timings: 14, formal: 7, man: 30 },
     allowRepoSimOut: true,                // enable clean sim
     repoSimOutDirs: ["work-ver"],         // relative to repoRoot
   }
   ```
4. Tests: `build-platform/test/clean.test.ts` with temp dirs (no real workspace required).
5. Docs: `build-platform/README.md` + `AGENTS-build.md` one-liner; this architecture file remains the plan of record.

### 4.4 Safety algorithm (normative)

```text
for each candidate path P:
  resolve absolute(P)
  if not under allowlisted root → refuse (log error, non-zero)
  if P equals paths.tooling or paths.root → require --yes
  if age filter set → skip if mtime newer than threshold
  if dry-run → print only
  else rm -rf P (recursive)
```

Never follow symlinks outside allowlist (refuse if realpath escapes).

---

## 5. Timings integration — `--from-timing`

### 5.1 Goal

Continue **soaks / diag / sim / bench** on RTL that has passed through the structural precompile path (`sv-timing` analyze ± correct emit), **without** coupling package crates to monorepo flists. The host validates that a precompiled **output directory** is structurally sound, then optionally points downstream tools at:

- portable filelist + JSON reports (always), and/or
- corrected emit tree (`svt_corrected.f` / emit sources) after human or CI policy allows.

### 5.2 Precompile artifact contract (host-visible)

A **timings out-dir** (example: `workspace/build/sv-timing/host-cv64a6_imafdc_sv39/` or suite dir under `verif-tests/`) is valid when:

| Artifact | Required | Role |
|---|---|---|
| `portable.f` | yes | Host-flattened sources the package analyzed |
| `analyze.json` (or `correct.json`) | yes | Versioned `analyze-result.v1` (schema in `sv-timing/schemas/`) |
| `param-map.json` | recommended | Host param substitutions used for packages mode |
| `corrected/` + emit flist | only if correct `--emit` | Rewritten SV tree; **not** auto-merged into `core/` |
| stamp (optional v1.1) | optional | `{ command, target, mhz, exitCode, mtime, modules[] }` for clean `--execution` |

**Post-precompile structural validation** (host TypeScript, no Rust changes required for v1):

1. Directory exists and is readable.
2. `portable.f` parses (non-empty paths; files exist or soft-warn missing).
3. JSON parses; `schema` / version field matches supported `v0`/`v1`.
4. If `--require-emit`: corrected tree present; `svt_corrected.f` or equivalent lists existing files.
5. Optional: module list in JSON intersects `--modules` request.
6. Optional soft checks: `sta_hints` present; no package independence violations (host does not reimplement FO4).

Exit codes: `0` valid, `2` usage, `1` invalid structure, `3` tools missing (if validation would spawn package).

### 5.3 CLI surface

```text
# Produce a self-contained precompile package (--output / -o)
cva6-build timings compile --modules alu --target-mhz 1250 --output workspace/build/sv-timing/alu-pack
cva6-build timings compile --all-modules -o build/my-timings
cva6-build timings correct --modules alu --allow-latency --emit -o build/my-timings
# Layout: portable.f analyze.json|correct.json param-map.json ir.sqlite stamp.json [corrected/]

cva6-build timings validate --from-timing build/my-timings [--require-emit] [--json]

# Consume in gates / soaks
cva6-build diag run core --from-timing build/my-timings
cva6-build test sv-timing-smoke --from-timing build/my-timings
cva6-build test mc-spo-soak --from-timing build/my-timings
cva6-build verify --lint --from-timing build/my-timings       # structure gate; lint = live RTL
cva6-build build --from-timing build/my-timings --use-emit    # expert emit env only
```

| Flag | Scope | Behaviour |
|---|---|---|
| `--from-timing <dir>` | diag, test, verify, build, timings validate | Resolve dir (absolute or repo-/workspace-relative); run structural validation first. |
| `--use-emit` | build / sim suites that accept alternate flist | After validate, set child env `CVA6_TIMINGS_EMIT_FLIST` / pass alternate `-f` **only** when emit tree exists. Default **off** so soaks stay on live RTL unless operator opts in. |
| `--require-emit` | validate | Fail if correct emit missing. |

**Independence:** validation and env wiring live in `build-platform/src/tooling/timings.ts` (+ thin flags in each command). No monorepo imports inside `sv-timing/crates/**`.

### 5.4 Soak / suite integration plan

| Layer | How `--from-timing` participates |
|---|---|
| **sv-timing-* suites** | Already write under `workspace/build/sv-timing/verif-tests/`. Extend scripts to accept `CVA6_FROM_TIMING` / `FROM_TIMING` env (set by test runner from flag) and re-validate that dir before analyze; skip re-analyze if stamp fresh. |
| **diag** | Preflight: if flag set, validate dir; attach summary to diag JSON; do **not** replace Verilator flist with emit unless `--use-emit` (diag is about live RTL surfaces). |
| **verify --lint/--synth** | Preflight validate only by default (documents that timing precompile was considered). `--use-emit` is expert and must stay config-gated / non-default. |
| **verify --sim / test soaks** | Structure gate + optional soft metrics from `analyze.json` (path count, opportunity count) logged for soak dashboards; functional sim remains on live RTL unless `--use-emit`. |
| **bench** | Future: FO4 summary columns from analyze JSON next to Dhrystone/CoreMark — no STA claim. |

### 5.5 Config hooks (optional)

```ts
// schema fragment
timingsHost?: {
  defaultOutDir?: string;          // default under workspace/build/sv-timing
  validateOnTest?: boolean;        // if suite has timings tools, auto-validate last out-dir
  allowUseEmitInCi?: boolean;      // default false
};
```

Defaults keep CI byte-stable: no emit flist swap unless explicit.

---

## 6. Operator workflows

### Free space after a week of diags/soaks

```bash
./build.sh clean status --json
./build.sh clean diag --older-than 3d
./build.sh clean formal --older-than 7d
./build.sh clean timings --older-than 14d
./build.sh clean sim --yes              # repo work-ver only
./build.sh clean svt                    # sv-timing/target (+ package out/cache)
./build.sh clean rust-target --dry-run  # alias for svt
./build.sh clean svt-tools --yes        # sv-timing/.tools (re-setup after)
# keep tooling + downloads
```

### Nuclear (reprovision)

```bash
./build.sh clean all --yes
./build.sh clean tooling --yes
./build.sh setup --install --profile sim
```

### Timing-aware soak loop

```bash
./build.sh timings analyze --modules alu,mult --target-mhz 1250
OUT=build-platform/workspace/build/sv-timing/host-cv64a6_imafdc_sv39
./build.sh timings validate --from-timing "$OUT"
./build.sh test sv-timing-smoke --from-timing "$OUT"
./build.sh diag run core --from-timing "$OUT"
# optional expert emit path after review:
# ./build.sh timings correct --modules alu --allow-latency --emit
# ./build.sh verify --lint --from-timing "$OUT" --use-emit   # non-default
```

---

## 7. Phased delivery (guides AGENTS-todo)

| Phase | Deliverable | Done when |
|---|---|---|
| **C0** | Inventory: `clean status` + purpose map + allowlist guard | **done** (`workspace/clean.ts`, `test/clean.test.ts`) |
| **C1** | Purpose subcommands + `--older-than` + bare-clean compat | **done** |
| **C2** | `clean sim` (work-ver) + `tooling`/`all` `--yes` | **done** |
| **T0** | `timings validate --from-timing` + shared resolver | **done** (`validateTimingsOutDir`) |
| **T1** | Plumb `--from-timing` into `test` / `diag` (env + preflight) | **done** (host gate + `CVA6_FROM_TIMING`; suites consume) |
| **T1b** | `timings compile` / `analyze` / `correct` **`--output`/`-o`** package layout | **done** (`resolveTimingsOutputDir` + stamp) |
| **T2** | Optional `--use-emit` on build/verify/test (default off) | **done** (`applyFromTimingFlags`; lint stays live RTL) |
| **T3a** | Suite stamps + `clean --execution last\|failed\|ok` | **done** (`stamp.json` + select filter) |
| **T3b** | Soak dashboards from analyze JSON | **done** (`timings summary`, `soak-dashboard.json`) |

Do **not** start T2 until T0/T1 and human review policy for emit trees are accepted (aligns with `sv-timing` NG4: never auto-commit corrected RTL).

---

## 8. Relationship to AGENTS-todo / package todo

- **Monorepo `AGENTS-todo.md` phase 12** (build-platform): extend with C0–C2 and T0–T2 rows under the existing build-platform checklist.
- **`sv-timing/AGENTS-todo.md`**: stays package-only (param-map richness, etc.). Host clean/from-timing work **must not** add monorepo paths to crates; optional package note under P8/P12 “host consume validate” is documentation-only.
- **architecture/sv-timing/**: remains the redirect to package design; **this file** owns host workspace lifecycle + hand-off.

---

## 9. Non-goals

- Replacing STA or claiming FO4 as sign-off.
- Auto-deleting `vendor/`, `pd/pdk/`, or git objects.
- Moving `work-ver` into workspace in the same pass (nice follow-up; would need Makefile/`childEnv` coordination).
- Implementing full `--execution failed` without stamp files.
- Couping `clean` to Graphite/CI cache keys beyond documenting workspace paths.

---

*Last updated: 2026-08-03 — plan of record for granular clean (`svt` / `svt-tools` package leaves) + `--from-timing` soak integration; FO4 scale notes in monorepo `AGENTS-build-platform.md` §6.1.*
