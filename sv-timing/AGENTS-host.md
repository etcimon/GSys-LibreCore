# AGENTS-host — Import / interaction boundary

> Companion to [`AGENTS.md`](AGENTS.md). Full design: [`architecture/DESIGN.md`](architecture/DESIGN.md) § Independence & Host Integration.

## Rule

**Hosts prepare inputs and consume outputs.** They do not link monorepo code into this package.

## Interaction modes

| Mode | How |
|---|---|
| **CLI + JSON** (v1 required) | Spawn `sv-timing` / `cargo run -p sv-timing-cli` with file list argv |
| **Rust library** | Path/crates dependency on `sv-timing-core` only |
| **Bun FFI** (post-v1) | `dlopen` cdylib; same DTO schema as JSON |
| **Host adapter module** | Lives **outside** `sv-timing/` (e.g. monorepo `build-platform/src/tooling/timings.ts`) |

## Inputs hosts may pass

`--file` / `--files-from`, `--incdir`, `--define`, `--modules` or `--all-modules`,
`--target-mhz`, `--fo4-ps`, `--package-mode off|packages`, `--param-map`, `--assume-xlen`,
`--multi-cycle-modules`, `--refuse-path-prefix`, `--refuse-instance-types`,
`--cache` (SQLite IR path; CRC-32C design hit on re-analyze), `--json-out`,
**`--out-dir`** / `--emit-dir` (corrected project tree).

### Portable `--files-from` (package-owned)

The package understands a **simple `.f` filelist**: paths, `#`/`//` comments,
`+incdir+`, `+define+`, nested `-f`/`-F` (cycle-guarded). Relative paths resolve
against the listing file’s directory. See
[`architecture/PROJECT-AUTOCORRECT.md`](architecture/PROJECT-AUTOCORRECT.md).

### Host-owned expansion

Bender, FuseSoC, env-heavy EDA `-F` (e.g. `$CVA6_REPO_DIR`) remain **host** duties.
Flatten those into a portable `.f` or pass `--file` paths.

### Package-owned generic expand (`svt.py flist`)

For nested lists and **generic** `${VAR}` / `$VAR` expansion (no monorepo names baked
in), use the package tool:

```bash
python tools/svt.py flist --in path/to/entry.f --set ROOT=/abs/project --out portable.f
python tools/svt.py flist --selftest
```

Implementation: `tools/flist_expand.py`. Output is a portable `.f` suitable for
`--files-from`. Hosts may still use their own expander when they already own env maps.

## Host responsibilities

1. Expand project manifests (Bender/FuseSoC/env flists) → portable `.f` or path list.
2. Supply defines/incdirs (or embed in `.f`), target MHz, module roots (**or `--all-modules`**).
3. Optional: write `param-map.json` for package typedef / config field substitutions.
4. Map `--out-dir` / cache into host workspace if desired (CLI flags only).
5. Review emit tree + `svt_corrected.f`; **never auto-commit** corrected RTL.

## Example (conceptual)

```text
host: flatten flist + env → analyze.f
host: write param-map.json
host: run  sv-timing analyze --files-from analyze.f --modules alu --target-mhz 1250 \
           --json-out report.json
host: run  sv-timing correct --files-from analyze.f --all-modules --allow-latency \
           --emit --out-dir build/svt-corrected --json-out correct.json
host: point sim/synth at build/svt-corrected/svt_corrected.f (after review)
```

## Monorepo soak (package-owned, preferred for tool development)

When this package sits next to a monorepo `core/` tree, develop against **real SV** without
build-platform:

```bash
python tools/svt.py monorepo-soak --list
python tools/svt.py monorepo-soak --profile sparse_ex
# Auto-correct + from-timing package (emit review-only):
python tools/svt.py monorepo-soak --profile sparse_ex --correct --emit --allow-latency
# Tighter FO4 budget (~20 FO4 @ 2000 MHz vs ~32 @ 1250):
python tools/svt.py monorepo-soak --target-mhz 2000 --profile sparse_ex --correct --emit --allow-latency
```

**Fix priority:** package first, RTL rare. See [`architecture/MONOREPO-SOAK.md`](architecture/MONOREPO-SOAK.md)
and monorepo `AGENTS-coding-philosophy.md` §2.8. Budget model and path_class / BalanceMux notes:
package [`AGENTS.md`](AGENTS.md) §3.2.

Typical soak package path (host workspace, gitignored):

```text
build-platform/workspace/build/sv-timing/monorepo-soak/<profile>/
```

Host may then:

```bash
./build.sh timings validate --from-timing build-platform/workspace/build/sv-timing/monorepo-soak/sparse_ex
./build.sh timings sta-handoff --from-timing …/sparse_ex --try-tools
bash verif/regress/monorepo-soak-from-timing.sh
```

## Monorepo CVA6 note (informative)

When used from CVA6V-EC, the optional adapter is
`build-platform/src/tooling/timings.ts`:

| API | Role |
|---|---|
| `writePortableTimingsFlist(ctx, opts)` | `flattenFlist` + write portable `.f` under `paths.build/sv-timing/` |
| `writeVerifyPortableFlist(ctx, env, target)` | Convenience over `verify.flist` |
| `portableFromFlatManifest(ctx, manifest)` | Reuse an existing `FlatManifest` |
| `buildSvTimingAnalyzeArgs` / `buildSvTimingCorrectArgs` | Argv builders (host spawns CLI) |
| `resolveSvTimingRoot(ctx)` | Locate `sv-timing/` package root |
| `buildSvtRunCommand` / `timingsRepoEnv` | Spawn helpers for `tools/svt.py run` |

### CLI entry (build-platform)

```text
bun run src/cli/index.ts timings status
bun run src/cli/index.ts timings doctor
bun run src/cli/index.ts timings flist --target cv64a6_imafdc_sv39
bun run src/cli/index.ts timings compile --modules alu -o workspace/build/sv-timing/alu-pack --target-mhz 1250
bun run src/cli/index.ts timings analyze --modules alu --target-mhz 1250
bun run src/cli/index.ts timings correct --modules alu --allow-latency --emit
bun run src/cli/index.ts timings validate --from-timing workspace/build/sv-timing/alu-pack
bun run src/cli/index.ts timings summary --from-timing workspace/build/sv-timing/alu-pack
bun run src/cli/index.ts test sv-timing-smoke --from-timing workspace/build/sv-timing/alu-pack
```

That module reuses `flattenFlist` / `edaEnv` **only in host TypeScript**. It must not
appear under `sv-timing/crates/**`. Package-side expand stays generic (`flist_expand.py`).

Host command map and FO4 scale notes: monorepo `AGENTS-build-platform.md` §2.5 / §2.6 / §6.1,
`AGENTS-build.md`, lifecycle plan `architecture/build-platform-workspace-lifecycle.md`.

### Clean: host packages vs package Cargo (do not mix)

| Host command | Removes | Does **not** remove |
|--------------|---------|---------------------|
| `./build.sh clean timings` | `workspace/build/sv-timing/**` soak/compile packages | `sv-timing/target` |
| `./build.sh clean svt` (alias `rust-target`) | Package `sv-timing/target`, `.sv-timing-out`, `.sv-timing-cache` | Host soak packages |
| `./build.sh clean svt-tools --yes` | Package `sv-timing/.tools` | Workspace `tooling/` |
| `./build.sh clean sta` | STA handoff seeds under build | Package or soak packages |

Package-side equivalent of `clean svt` / `clean svt-tools --yes`:

```bash
cd sv-timing && python tools/svt.py clean          # Cargo + local out/cache
cd sv-timing && python tools/svt.py clean --all    # + .tools/ (re-setup after)
```

## STA handoff

Structural FO4 reports feed design review and optional auto-correct; **sign-off stays
with STA**. See [`architecture/STA-HANDOFF.md`](architecture/STA-HANDOFF.md) for
artifact mapping, SDC seed rules, and the sim → synth → STA sequence. Analyze JSON
includes `sta_hints[]` (review-only seeds). Host `timings sta-handoff --from-timing DIR`
and `lab-run` consume packages; never retune package `fo4-v1` from synthetic STA fixtures.

## Monorepo verif gates

Sparse host suites live under `verif/sv-timing-tests/` and are registered in
build-platform `tests.suites` as `sv-timing-smoke`, `sv-timing-core-sparse`,
`sv-timing-autocorrect`, `sv-timing-advanced`. Run:

```text
bun run --cwd build-platform src/cli/index.ts test sv-timing-smoke
bun run --cwd build-platform src/cli/index.ts test --suite sv-timing-autocorrect
# Or rehydrate a prior package:
bun run --cwd build-platform src/cli/index.ts test sv-timing-smoke --from-timing workspace/build/sv-timing/alu-pack
```

Outputs: `build-platform/workspace/build/sv-timing/verif-tests/<suite>/`.
