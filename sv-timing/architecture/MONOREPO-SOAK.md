# Monorepo structural FO4 soak (real `core/` RTL)

| Field | Value |
|---|---|
| **Status** | Package-owned opt-in cycle |
| **Primary fix target** | **`sv-timing/`** (parser, lower, FO4, emit, param-map UX) |
| **Secondary fix target** | Real RTL under monorepo `core/` / uncore — **rare**, only for proven logic bugs |
| **Not** | STA sign-off, build-platform required, full-core flist |
| **Related** | `STA-HANDOFF.md`, `CVA6-STYLE-SV.md`, monorepo `AGENTS-coding-philosophy.md` §2.8 |

---

## 1. Why this cycle exists

Package fixtures (`fixtures/`, `verif/tests/`) keep **independence** and deterministic goldens.
They cannot catch every CVA6-shaped construct on real `alu.sv` / frontend / uncore glue.

When this package sits inside a monorepo that has a `core/` tree, agents and humans run an
**opt-in soak** that analyzes sparse real SystemVerilog. Failures almost always mean:

1. the **tool** does not yet understand a language shape, or  
2. the **param-map / flist** is incomplete, or  
3. (rarely) the **RTL** has a real timing or coding-philosophy issue.

Default bias: **fix the tool and its fixtures first.** Do not churn production RTL to silence a
structural FO4 false positive.

---

## 2. Independence rules (KD0)

| Allowed | Forbidden |
|---------|-----------|
| Runtime discovery of monorepo root via env / parent `core/` | `crates/**` depending on monorepo paths |
| Generic flist expand (`${CVA6_REPO_DIR}`) | Baking monorepo package names into Rust |
| Host flists under monorepo `verif/sv-timing-tests/` | Requiring monorepo for `cargo test` / `svt.py check` |
| Opt-in `svt.py monorepo-soak` | Soft-failing CI that must stay package-only |

`tools/check_independence.py` still applies. This soak is **not** part of default `svt.py test`.

---

## 3. Commands (no build-platform)

From `sv-timing/`:

```bash
python tools/svt.py setup          # once
python tools/svt.py monorepo-soak --list
python tools/svt.py monorepo-soak
python tools/svt.py monorepo-soak --profile sparse_ex
# Multi-slice best-measure (EX + frontend + issue/LSU + optional APU glue):
python tools/svt.py monorepo-soak \
  --profile sparse_ex --profile sparse_frontend \
  --profile sparse_issue_lsu --profile sparse_uncore_glue
# Auto-correct validity + from-timing package (review-only emit):
python tools/svt.py monorepo-soak --profile sparse_ex \
  --correct --allow-latency --emit
# Scale experiment (~32 FO4 @ 1250 → ~20 @ 2000 → ~16 @ 2500):
python tools/svt.py monorepo-soak --profile sparse_ex --target-mhz 2000 \
  --correct --emit --allow-latency
python tools/svt.py monorepo-soak --profile sparse_ex --target-mhz 2500 \
  --correct --emit --allow-latency
# Optional host OpenSTA handoff (needs bun + build-platform):
python tools/svt.py monorepo-soak --profile sparse_ex \
  --correct --emit --allow-latency --sta-handoff --use-emit --try-tools
```

**CLI resolution:** prefers package `target/debug/sv-timing` (or `release`) when present;
else `cargo run -p sv-timing-cli` via contained / `CARGO_HOME` cargo. Rebuild after
transform/emit changes: `cargo build -p sv-timing-cli` (WSL or native toolchain).

**Clean bulk (do not mix):** package `python tools/svt.py clean` or host
`./build.sh clean svt` → Cargo `target/`; host `./build.sh clean timings` → soak packages
under `workspace/build/sv-timing/`. See monorepo `AGENTS-build-platform.md` §2.6.

Monorepo one-shot (analyze+correct+emit+validate):

```bash
bash verif/regress/monorepo-soak-from-timing.sh
SVT_STA_HANDOFF=1 bash verif/regress/monorepo-soak-from-timing.sh
```

Env (optional):

| Variable | Role |
|----------|------|
| `SVT_MONOREPO_ROOT` | Explicit monorepo root |
| `CVA6_REPO_DIR` | Same (flist placeholders) |
| `CVA6_LIBERTY` | Real liberty for OpenSTA S2 (else soft-skip / fixture) |

When the package lives at `<repo>/sv-timing` next to `<repo>/core`, root is auto-detected.

Outputs (default under monorepo workspace if present):

```text
build-platform/workspace/build/sv-timing/monorepo-soak/
  sparse_ex/
    portable.f
    analyze.json
    correct.json          # with --correct
    corrected/            # with --emit (review-only)
    stamp.json            # from-timing package metadata
    param-map.json
    from-timing-recipe.json
    ir.sqlite
  soak-summary.md
  soak-summary.json
```

---

## 4. Built-in sparse profiles

Driven by monorepo flists under `verif/sv-timing-tests/flists/` (when the tree is present):

| Profile id | Flist | Modules (default) |
|------------|-------|-------------------|
| `sparse_ex` | `sparse_ex_units.f` | alu, mult, multiplier, serdiv, branch_unit |
| `sparse_frontend` | `sparse_frontend.f` | instr_scan, instr_queue, g6lc_ftq |
| `sparse_issue_lsu` | `sparse_issue_lsu.f` | issue_read_operands, scoreboard, load/store units |
| `sparse_uncore_glue` | `sparse_apu_glue.f` | thin AXI mux (soft missing files) |

Optional extra TOML profiles: `verif/sv-timing-tests/soak-profiles/*.toml`.

Example TOML:

```toml
id = "my_slice"
flist = "verif/sv-timing-tests/flists/sparse_ex_units.f"
modules = ["alu", "mult"]
param_map = "verif/sv-timing-tests/param-maps/cv64a6_imafdc_xlen64.json"
target_mhz = 1250.0
soft_missing = true
notes = "example"
```

---

## 5. Development cycle (normative)

```text
┌─────────────────────────────────────────────────────────────┐
│ 1. Edit sv-timing (or add fixture that reproduces a shape)  │
│ 2. python tools/svt.py test / check                         │
│ 3. monorepo-soak [--correct --emit]   # real core/*.sv      │
│ 4. Read soak-summary.md (primary FO4 before→after, fo4Δᵖ)   │
│ 5. Classify failure (see §6)                                │
│ 6. Fix package → re-soak; only then consider RTL            │
│ 7. timings validate --from-timing <pkg>                     │
│ 8. timings sta-handoff --from-timing <pkg> [--use-emit]     │
│    --try-tools   # OpenSTA soft; liberty for real S2        │
│ 9. correlate / retune-propose — never retune from fixture   │
└─────────────────────────────────────────────────────────────┘
```

### 5.1 Auto-correct validity toward OpenSTA

| Gate | What “valid” means |
|------|-------------------|
| Correct dry-run | CLI exits 0; `correct.json` has paths; no panic on real modules |
| FO4 delta | `worst_fo4` / `max_freq_mhz` move in the intended direction **or** stay stable with documented no-op |
| Emit tree | `corrected/svt_corrected.f` (+ manifest); review-only — not merged to `core/` |
| from-timing package | `stamp.json` + `portable.f` + report → host `timings validate` passes |
| STA S0 | `sta-handoff` writes review-only `seeds.sdc` + `fo4_paths.csv` from package ranks |
| STA S1–S2 | Soft-skip without tools; with yosys+liberty, netlist + paths.rpt |
| Correlate | Real STA: trust WNS over FO4; if emit improves FO4 but not STA → **do not trust emit** |

Structural FO4 remains **screening**, not silicon sign-off (`STA-HANDOFF.md`).

---

## 6. Failure classification

| Symptom | First action | Avoid |
|---------|--------------|--------|
| Parse / lower panic or empty modules | Minimal fixture under `fixtures/` + crate fix | Editing production RTL |
| Hierarchical dims / package typedefs wrong | Param-map + package-mode; fixture like `issue_style` | Hardcoding monorepo cfg packages in crates |
| Absurd FO4 ranks on real alu | FO4 table / expression tree; re-golden fixtures | Tuning RTL “to make FO4 happy” |
| Missing files in uncore glue | Soft drop + flist hygiene | Failing the whole soak |
| Real combo loop / async reset / non-synth | **RTL fix** under coding philosophy + §0 SoC checklist | Hiding with `translate_off` without review |

---

## 7. Relation to monorepo host gates

| Path | Tooling | Purpose |
|------|---------|---------|
| **This soak** | `svt.py monorepo-soak` only | Package development against real SV |
| `verif/regress/sv-timing-*.sh` | Often via build-platform `timings` | Host CI integration |
| `timings lab-run` / OpenSTA | build-platform | PD handoff (optional) |

Agents working **on sv-timing** should prefer this soak over build-platform for the inner loop.

---

## 8. Coding philosophy binding

Monorepo `AGENTS-coding-philosophy.md` §2.8 makes this cycle a **standing practice** for
timing-aware RTL work: structural FO4 soak on sparse real modules, package-first fixes,
RTL only when the tool is already trustworthy on that shape.

---

## 9. Validated soak results (package algorithms)

Budget model: \(B = (1000/f_{\mathrm{MHz}} \cdot 1000 / t_{\mathrm{FO4,ps}}) \cdot (1-m)\) with
defaults \(t_{\mathrm{FO4}}=20\,\mathrm{ps}\), \(m=0.2\) → **~32 FO4 @ 1250 MHz**, **~20 FO4 @ 2000 MHz**, **~16 FO4 @ 2500 MHz**.

| Profile | Target | Correct+emit | Primary FO4 | Notes |
|---------|--------|--------------|-------------|--------|
| `sparse_ex` | 1250 | reparse_ok | **37.9 → 30.9**, closes | BalanceMux stage_hot_arm; dens≈234; relocation cards (exclusive + atomic) |
| `sparse_ex` | 2000 | reparse_ok | **37.9 → 20.0**, **closes** | multi-arm stage + residual onehot; dens≈270; max_mhz=2000 |
| `sparse_ex` | 2500 | reparse_ok | **37.9 → 16.0**, **closes** | + half-split/fo4_locked InsertReg, residual correct loop, case-label emit; dens≈277; max_mhz=2500 |
| `sparse_frontend` | 1250 | reparse_ok | **28.0**, closes | No edits needed (under budget after path_class) |
| `sparse_frontend` | 2000 | reparse_ok | **23.5 → 20.0**, **closes** | InsertReg multi-cut on instr_scan + queue plains; dens≈55 |
| `sparse_frontend` | 2500 | reparse_ok | **23.5 → 16.0**, **closes** | + independent-LHS BalanceMux credit close; dens≈55; max_mhz=2500 |
| `full_core` | 2500 -O3 | emit (integrity soft defines) | **95 → 16.0**, **closes** | CorrectScale + BalanceMux-first; runtime-stable lean dense emit |
| `full_corev_apu` | 2500 -O3 | emit (residual integrity soft) | **141.6 → 16.0***, **closes*** | *may reopen if credit snap tightened to 2.5×; prefer structural fix |

**Large-codebase scale (full_core):** `scale_correct_budget` → `CorrectScale` (width, passes, idle, apply_cap, batch_size); relocation cards stratify by pattern **and module**; worklist batch-applies distinct modules before remeasure so InsertReg thrash on one FPU tree cannot starve exclusive residual elsewhere. Soak prefers release CLI over debug.

**Runtime stability:** [`RUNTIME-STABILITY-AUTOCORRECT.md`](RUNTIME-STABILITY-AUTOCORRECT.md) — lean dense (default), exact basename match, FO4 credit snap ≤2.5× budget. Host **`--use-emit` does not remap Verilator flists** (exports `CVA6_TIMINGS_EMIT_FLIST` only).

**BalanceMux emit order (latency-neutral):**

1. **stage_hot_arm** — deep exclusive-arm expr → intermediate wires + origin RHS rewrite  
2. **onehot_or_tree** — if stage N/A **or** path FO4 still over budget: parallel arm compare-mux +
   balanced OR (`svt_bm_oh_p{id}_*`); multi-arm exclusive LHS wire (`emit_rhs` + extras);
   preserve case labels; skip `$clog2`/unsafe arms only  
3. **sticky credit** — residual exclusive FO4 when no structural rewrite (snap ≤ **2.5×** budget @ tight)  

IR: `IrNode.case_labels` / `case_is_default` / `case_selector` from lower CST CaseItem (prefer over
source scan). Fixtures: `fixtures/exclusive_case_mux.sv`, `fixtures/alu_nested_case.sv`.

Design detail: [`FO4-ALGORITHM-UPGRADES.md`](FO4-ALGORITHM-UPGRADES.md) §6–7,
[`RELOCATION-ANALYSIS.md`](RELOCATION-ANALYSIS.md).

---

*Last updated: 2026-08-03 — target-mhz soaks, residual onehot, emit integrity, clean/CLI notes.*

