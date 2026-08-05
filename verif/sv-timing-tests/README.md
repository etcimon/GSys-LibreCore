# verif/sv-timing-tests — host integration of `sv-timing`

Sparse flists and param-maps for **real monorepo SystemVerilog** (`core/`, thin uncore).

### Preferred development cycle (no build-platform)

Fix **`sv-timing` first** when analyze fails on these files; RTL only when proven.
Bound in monorepo `AGENTS-coding-philosophy.md` §2.8 and
`sv-timing/architecture/MONOREPO-SOAK.md`.

```bash
cd sv-timing
python tools/svt.py monorepo-soak --list
python tools/svt.py monorepo-soak --profile sparse_ex
# Auto-correct + from-timing package (toward OpenSTA --use-emit):
python tools/svt.py monorepo-soak --profile sparse_ex --correct --emit --allow-latency
# summary: build-platform/workspace/build/sv-timing/monorepo-soak/soak-summary.md

# Repo-root one-shot (validate package; optional handoff):
bash verif/regress/monorepo-soak-from-timing.sh
SVT_STA_HANDOFF=1 bash verif/regress/monorepo-soak-from-timing.sh
```

### Optional host CI via build-platform `timings`

Suites below drive the **build-platform `timings`** command (flattens flists and
spawns `sv-timing/tools/svt.py`). Outputs land under:

```text
build-platform/workspace/build/sv-timing/verif-tests/<suite>/
```

**Not STA sign-off.** Structural FO4 + optional auto-correct dry-run/emit only.
See `sv-timing/architecture/STA-HANDOFF.md` and monorepo
`architecture/build-platform-opensta-from-timing.md`.

### STA smoke fixture (`fixtures/sta_smoke/`)

| File | Role |
|------|------|
| `comb_adder.v` | Minimal clocked adder for `read_verilog` |
| `analyze.json` | Hand-authored FO4-ish report for S0 seeds |

```bash
./build.sh timings sta-handoff --from-timing <materialized-pkg> --try-tools --top comb_adder
# Optional: CVA6_LIBERTY=/path/to.lib for S2
```

## Suites (via `cva6-build test`)

| Suite id | Script | What it does |
|---|---|---|
| `sv-timing-smoke` | `verif/regress/sv-timing-smoke.{sh,ps1}` | package fixture project_mini analyze |
| `sv-timing-core-sparse` | `verif/regress/sv-timing-core-sparse.{sh,ps1}` | sparse `core/` EX units (packages + alu/mult) |
| `sv-timing-autocorrect` | `verif/regress/sv-timing-autocorrect.{sh,ps1}` | correct dry-run + optional emit on sparse core |
| `sv-timing-advanced` | `verif/regress/sv-timing-advanced.{sh,ps1}` | frontend + EX sparse, emit, slang/pyslang smoke |
| `timings-sta-handoff` | `verif/regress/timings-sta-handoff.sh` | S0–S2 OpenSTA handoff: pure-Verilog `sta_smoke` fixture → seeds.sdc + optional Yosys/OpenSTA |

```bash
# From repo root (Bun):
bun run --cwd build-platform src/cli/index.ts test sv-timing-smoke
bun run --cwd build-platform src/cli/index.ts test timings-sta-handoff
bun run --cwd build-platform src/cli/index.ts test --suite sv-timing-core-sparse,sv-timing-autocorrect
bun run --cwd build-platform src/cli/index.ts test --group directed --list | grep sv-timing

# Direct scripts:
bash verif/regress/sv-timing-smoke.sh
bash verif/regress/timings-sta-handoff.sh
pwsh -File verif/regress/sv-timing-smoke.ps1
```

## Flists (sparse)

Under `flists/`:

| File | Scope |
|---|---|
| `fixture_project_mini.f` | In-package multi-module fixture (always independent) |
| `sta_smoke.f` | Pure-Verilog `comb_adder` for Yosys S1 CI (no SystemVerilog packages) |
| `sparse_ex_units.f` | `config`/`riscv`/`ariane` packages + alu/mult/multiplier/serdiv |
| `sparse_frontend.f` | packages + frontend FTQ/instr_queue slice |
| `sparse_apu_glue.f` | packages + thin `corev_apu` cluster-facing files if present |

Paths use `${CVA6_REPO_DIR}` so host `timings` / `flattenFlist` expand them.

## Out directory

```text
SVT_VERIF_OUT   default: build-platform/workspace/build/sv-timing/verif-tests
SVT_TARGET_MHZ  default: from soc / 1250
SVT_PARAM_MAP   default: verif/sv-timing-tests/param-maps/cv64a6_imafdc_xlen64.json
SVT_MODULES     comma list for sparse EX (default alu,mult,…)
DV_TARGET       config package name (cv64a6_imafdc_sv39)
```

## Param map

Host timings auto-writes a param-map next to JSON outputs (from `soc.xlen`) unless
`--no-param-map`. Sparse suites also pass
`verif/sv-timing-tests/param-maps/cv64a6_imafdc_xlen64.json` explicitly so
`CVA6Cfg.XLEN` hierarchical dims resolve without monorepo coupling in crates.

## Independence

Package unit tests stay under `sv-timing/` only. This tree is a **host** consumer
and may reference `core/` + `corev_apu/` sparsely.
