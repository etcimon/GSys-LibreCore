# AGENTS branding policy — GSys LibreCore naming (governance)

Governs how the project is named in code, prose and silicon. Referenced from
`AGENTS.md` §0.4a. Legal backing: `TRADEMARKS.md`. Heritage: `docs/heritage.md`.

## 1. The three registers

| Register | Where it is used | Example |
|---|---|---|
| **GSys LibreCore** | Full brand. Document titles, `README`, `LICENSE*`/`NOTICE`/`TRADEMARKS.md`, marketing, **first mention** in any document. | "GSys LibreCore, a RISC-V application-class core" |
| **LibreCore** | Reader shorthand. Prose after first mention, `AGENTS*.md` body text, code comments. | "LibreCore's L2 is inclusive" |
| **G6LC** | Code identifier prefix. Module/package/file/macro/parameter names, Flists, config ids, DT node names. | `g6lc_rob`, `G6LCCfg`, `Flist.g6lc` |

`G6LC` = "GSys 6-stage LibreCore", preserving the pipeline-depth semantics that
the `A6` in CVA6 carried. `G6LC` is an identifier prefix, not a trademark.

## 2. Device nomenclature

OpenHW's `CV` prefix is a CORE-V family marker and cannot be reused. The
replacement scheme mirrors it:

| Old | New |
|---|---|
| `cv64a6_imafdc_sv39_config_pkg.sv` | `g6lc64_imafdc_sv39_config_pkg.sv` |
| `cv64a6_smt2_config_pkg.sv` | `g6lc64_smt2_config_pkg.sv` |
| `cv64a6_ooo_config_pkg.sv` | `g6lc64_ooo_config_pkg.sv` |
| `cv32a65x` | `g6lc32_65x` |

Pattern: `g6lc<XLEN>_<featureset>`.

**Renamed**: the five LibreCore-authored config packages *and their target
identifiers*. The other fourteen `cv{32,64}a6*_config_pkg.sv` files
(`cv64a6_imafdc_sv39*`, `cv64a6_spec_deep`, `cv32a65x`, `cv32a60x`, `cv64a60ax`,
…) are Thales/OpenHW-owned tier U and are deliberately untouched (§3).

### The target identifier and the filename are coupled — rename both

`build-platform/src/config/schema.ts` documents the convention
`core/include/<coreConfig>_config_pkg.sv`, and two places **construct the path
from the target string at runtime**:

- `util/user_config.py:258` — `f"core/include/{base}_config_pkg.sv"`
- `verif/regress/mc-stream-tests.sh:58` — `"core/include/${DV_TARGET}_config_pkg.sv"`

So renaming a config-package *file* without renaming its *target id* silently
produces a dead path — it fails at runtime, not at elaboration, and only on the
suites that use that target. The five LibreCore target ids were therefore renamed
in lockstep (`cv64a6_smt2` → `g6lc64_smt2`, `cv64a6_ooo` → `g6lc64_ooo`,
`cv64a6_ooo_server` → `g6lc64_ooo_server`, `cv64a6_server_math` →
`g6lc64_server_math`, `cv64a6_server_math_v` → `g6lc64_server_math_v`) across
`.config.ts`, `build-platform/src/config/defaults.ts`, `verif/regress/**`,
`verif/tests/**/*.S`, `software/**`, `architecture/**` and the `AGENTS*` maps.

**Check after any config-package rename:** every `g6lc64_<t>` target must have a
matching `core/include/g6lc64_<t>_config_pkg.sv`, and
`git grep -nE "\bcv64a6_(smt2|ooo|ooo_server|server_math|server_math_v)\b"` must
return nothing.

## 3. The boundary rule — rename at the boundary, never inside

**This is the load-bearing rule of this document.**

Legally, modifying a tier-U file is permitted: Apache-2.0 §4(b) only requires
"prominent notices stating that You changed the Files". So renaming identifiers
inside upstream files is *lawful*. It is nonetheless **forbidden here**, because:

- it permanently forfeits rebase onto upstream OpenHW CVA6;
- it forces a full-core re-verify and re-synth — `AGENTS.md` §0.3 names
  hard-coded churn across module boundaries as a cost-driver anti-pattern;
- an internal identifier is **not** a trademark-significant position, so it buys
  no legal protection. Ceasing to use "CVA6" in *branding* positions is what
  discharges the trademark obligation, and that is already done.

So: **add a boundary artifact, don't churn the interior.**

| Interior thing | Boundary artifact instead |
|---|---|
| `config_pkg::cva6_cfg_t`, `CVA6Cfg` (~5,900 sites, mostly tier U) | `core/include/g6lc_pkg.sv` → `g6lc_cfg_t`, `G6LCCfg` |
| `core/Flist.cva6` (OpenHW-owned) | `core/Flist.g6lc` (includes it via `-f`) |
| `core/cva6.sv` top module (OpenHW-owned) | *pending* — see §6 |
| `ariane_pkg` | left alone; alias via `g6lc_pkg` if ever needed |

### What was renamed
68 files and all their references — LibreCore-original (tier R) modules only:
`core/ooo/**`, `core/smt/**`, `core/g6lc_slice_*`, `core/frontend/g6lc_bp_*`,
`g6lc_ftq/fdip/loop_buffer`, `g6lc_way_predictor/rrip_repl/icache`,
`corev_apu/{coherence,l2_cache,l3_cache}/**`,
`corev_apu/src/g6lc_{axi_2to1_mux,ara_attach,cluster}.sv`, the five config
packages, the four `.sby` formal scripts, and `verif/tb/g6lc_ara_lint_top.sv`.

Verification of a rename is: **zero dangling references**, proven by grepping
every old token with word boundaries across all tracked files. Do not rely on
"it looked right".

## 4. Where `CVA6` stays — deliberately

Removing these would be wrong, not merely unnecessary:

1. **Tier-U copyright, attribution and licence notices.** Retention is a
   condition of our licence (Apache-2.0 §4(c), Solderpad §4). `E-UPSTREAMWRITE`.
2. **Device-tree fallback `compatible` strings.** `"eth,ariane-bare-dev"` is a
   Linux ABI matched by in-tree bindings. New strings are **prepended**, never
   substituted — most-specific first, fallback last:
   ```
   compatible = "gsys,g6lc64-bare-dev", "eth,ariane-bare-dev";
   ```
3. **Upstream CI workflow names** (`.github/workflows/openhw-cva6-ci-tier*.yml`)
   and `verif/core-v-verif`.
4. **`docs/heritage.md`** — the derivation statement. This is an asset, not a
   liability: it is good Apache §4(d) practice and it is why the permissive
   upstream grant is visible to auditors.
5. **`CVA6_REPO_DIR` and similar environment variables** consumed by `verif/`
   scripts and Makefiles. Renaming these breaks the toolchain contract for no
   gain; alias later if desired.
6. **Filenames of tier-U modules**: `core/cva6.sv`, `core/cva6_fifo_v3.sv`,
   `core/cva6_rvfi*.sv`, `core/cva6_mmu/**`, `core/cache_subsystem/cva6_hpdcache_*.sv`
   (CEA), `core/cache_subsystem/cva6_icache_axi_wrapper.sv`,
   `core/cva6_accel_first_pass_decoder_stub.sv`, `Flist.cva6`, `Flist.ariane`,
   `ariane.core`.

## 5. Identification registers — do not fake these

`mvendorid = 0x602` is the **OpenHW Group's** JEDEC id; `marchid = 0x3` is
allocated to **CV32A60X**. Shipping either under a GSys brand is a false vendor
claim. Neither may be changed to an arbitrary value. A GlobecSys JEDEC
manufacturer id and a RISC-V International architecture id are **release
blockers** in `AGENTS-todo.md`. `g6lc_pkg` deliberately declares brand strings
but no id values.

## 6. Known-open branding items

- **Top module still `cva6`.** `core/cva6.sv`'s declaration is 362 lines with 31
  parameter lines including inline `parameter type ... struct packed` injections.
  A hand-transcribed `g6lc` wrapper cannot be validated without a Verilator
  elaboration gate, and shipping an unvalidated 362-line wrapper violates
  `AGENTS.md` §0.2. Blocked on toolchain availability; tracked in `AGENTS-todo.md`.
- **DT `compatible` strings not yet prepended** — requires the binding doc and a
  boot test; see `AGENTS-dts-validation.md`.
- **`CVA6V-EC` project identity** in `AGENTS.md` superseded; historical
  references retained where factual.

## 7. Checklist for any new file

- Name it `g6lc_*` (RTL) or `g6lc64_*` (config package).
- Prose: "GSys LibreCore" on first mention, "LibreCore" after.
- Header per `AGENTS-licensing.md` for its tier.
- Never introduce a new `cva6_*` identifier.
- Never edit a tier-U identifier to make a name look consistent.
