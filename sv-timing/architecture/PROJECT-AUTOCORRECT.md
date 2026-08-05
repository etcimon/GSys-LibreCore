# Multi-file / multi-module project auto-correct

> Companion to [`DESIGN.md`](DESIGN.md) and [`AUTO-CORRECT-CORE-API.md`](AUTO-CORRECT-CORE-API.md).  
> **Status:** Implemented (v0.1) — portable filelist + project emit under `--out-dir`.  
> **Independence:** package understands a **simple `.f` filelist**, not host Bender/`-F`/edaEnv.

---

## 1. Goal

Fully auto-correct **SV projects** that span **multiple files and modules**, writing a
reviewable tree under a caller-chosen **output directory**, without overwriting sources
and without depending on monorepo flist expanders.

| Capability | Package owns | Host owns |
|---|---|---|
| Flat / nested simple `.f` (`+incdir+`, `+define+`, `-f`) | **Yes** (`filelist.rs`) | May pre-expand Bender/FuseSoC/`-F` with env |
| Multi-module analyze + correct allowlist / `--all-modules` | **Yes** | Chooses roots or all |
| Emit under `--out-dir` / `--emit-dir` | **Yes** | Maps dir into workspace if desired |
| Create **new** module files (`generated/*__svt.sv`) | **Yes** (when trace requests) | Reviews / wires instances |
| Generated `svt_corrected.f` + `svt_emit_manifest.json` | **Yes** | Points downstream tools at emit root |
| Recursive EDA flist env (`$CVA6_REPO_DIR`, tech cells) | **No** (NG8) | Flatten → pass `.f` or `--file` |

---

## 2. Portable filelist (`.f`) grammar

Supported by `sv_timing_core::load_filelist`:

```text
# comment
// comment
+incdir+relative/or/abs          # '+' separates multiple dirs
+define+NAME
+define+NAME=VAL
-f nested.f                      # recursive, cycle-guarded
-F nested.f
path/to/file.sv                  # relative to the listing file's directory
```

**Not** supported **by the Rust loader** (host or package prep must expand first):
Bender packages, FuseSoC cores, `+libext+`, wildcard globs, environment-variable
substitution, OpenPiton-style `-F` with tech cells.

**Prep tools** (still package-independent, not in crates):

| Tool | Role |
|---|---|
| `python tools/svt.py flist --in … --out …` | Nested `-f`/`-F` + generic `${VAR}` → portable `.f` |
| Host `build-platform/src/tooling/timings.ts` | Monorepo `flattenFlist` / `edaEnv` → portable `.f` + argv |

Hosts flatten heavy manifests into this grammar (or a plain path list) before
`analyze` / `correct`.

---

## 3. CLI surface (project mode)

```text
sv-timing analyze \
  --files-from fixtures/project_mini/project.f \
  --all-modules \
  --target-mhz 2000 \
  --json-out report.json

sv-timing correct \
  --files-from fixtures/project_mini/project.f \
  --all-modules \
  --target-mhz 2000 \
  --allow-latency --assume-clk \
  --emit \
  --out-dir .sv-timing-out/project_mini \
  --json-out correct.json
```

| Flag | Role |
|---|---|
| `--files-from` | Portable `.f` (paths +incdir+ +define+ nested `-f`) |
| `--file` / `-f` | Extra sources (merged) |
| `--incdir` / `--define` | Merged with filelist directives |
| `--modules` / `--modules-allow` | Allowlist (required unless `--all-modules`) |
| `--all-modules` | Discover modules from parse; correct every root |
| `--out-dir` | **Preferred** project emit root (tree + flist + manifest) |
| `--emit-dir` | Legacy alias of `--out-dir` |
| `--preserve-rel` | Keep relative directory layout under out-dir (default true) |
| `--emit-unchanged` | Also copy sources with no edits as `__svt` passthrough |
| `--emit` | Write (default remains dry-run) |

---

## 4. Emit layout under `--out-dir`

```text
$OUT/
  <optional preserved dirs>/module__svt.sv   # rewritten inputs (edits only by default)
  generated/name_svt_x0__svt.sv              # brand-new modules from expand/trace
  svt_corrected.f                            # portable flist of emitted .sv
  svt_emit_manifest.json                     # source → emit_rel, edit_count, is_new
```

### Per-file edit isolation

`edits_for_source` filters the global `EditTrace` by `origin.file` (full path or
basename match) so multi-module correct **does not** inject every pipeline reg into
every file.

### New modules

When an edit uses `new_name` matching `*_svt_x*` or `rationale: new_module:<name>`,
emit creates a dense placeholder module under `generated/`. Full `synthesize_module`
from IR (real ports/body) is a later increment; the file exists so hosts can flist it.

---

## 5. Library API

| API | Crate | Role |
|---|---|---|
| `load_filelist` / `FileList` | core | Ingest `.f` |
| `write_filelist` | core | Emit portable list |
| `edits_for_source` | emit | Per-file filter |
| `synthesize_project` / `emit_project_autocorrect` | emit | Tree + write |
| `ProjectEmitOptions` / `ProjectLayout` | emit | out_dir, preserve_rel, … |

---

## 6. Integrity

1. Every emitted `.sv` reparsed with the same `sv-parser` (+ project incdirs/defines).
2. pyslang (verif regress) may lint a subset or whole `svt_corrected.f`.
3. **Never** write outside `--out-dir` (realpath containment — same KD as DESIGN).
4. **Never** auto-commit corrected trees (NG4).

---

## 7. Roadmap (project auto-correct maturity)

| Step | Status |
|---|---|
| Simple `.f` + multi-file parse | Done |
| Multi-module allow / all-modules | Done |
| out-dir tree + generated flist/manifest | Done |
| Per-file edit filter | Done |
| New module file creation (stub body) | Done (stub) |
| Cross-module paths (instance graph + series upper-bound) | **Yes (P2 first cut)** |
| Full `synthesize_module` from IR for new modules | **Yes** (ports/regions + expression AST when recovered) |
| Expression AST (`Expr` on assign RHS/LHS) | **Yes** (subset parse; denser FO4 + emit) |
| STA sign-off / SDF | **No** — see [`STA-HANDOFF.md`](STA-HANDOFF.md) |
| RHS rewrite of original clouds (not zero feeds) | Future |
| Host Bender → `.f` adapter (outside package) | Host PR |

---

## 8. Relation to independence (DESIGN NG8)

Owning **Bender / FuseSoC / env-heavy `-F`** remains a host concern. Owning a
**portable line-oriented filelist** is required for any multi-file CLI to work offline
with only `sv-timing/` fixtures — that is in-scope and is what `filelist.rs` implements.
