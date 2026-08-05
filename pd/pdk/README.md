# `pd/pdk/` — Protected PDK drop-in root (foundry / NDA abstraction layers)

This directory is the **protected, git-ignored drop-in point** for a foundry's
proprietary, high-level abstraction layers — memory compilers, standard-cell
special cells (ICG / retention / level-shifter / isolation), power-management
kits (UPF/CPF), and hard macros (PLL, IO pads, SerDes) — that a real ASIC
tape-out of CVA6 needs but that are almost always **under NDA** and therefore
**must never enter this repository**.

It exists so an agentic **technology-optimization pass** (`cva6-build tech`) can
*optimize the core for a specific process* by binding those proprietary views at
CVA6's existing **PDK-swap seam**, while the open-source tree keeps building the
generic, behavioural path unchanged.

> **THE ONE RULE:** never commit foundry / NDA content here. Everything under
> `pd/pdk/**` is git-ignored except the tracked READMEs, per-area/example
> `.gitignore` files, and `manifest.example.json`. See the `.gitignore` in this
> directory and in each sub-directory.

---

## 1. Why this exists

CVA6 is silicon IP, not a software model (see `AGENTS.md` §0). Functional
correctness in simulation is necessary but not sufficient; a tape-out also needs
the design mapped onto a **specific process technology**. Foundries and memory-IP
vendors ship that mapping as *high-level abstraction layers* — compiled SRAM
macros, Liberty timing/power, LEF/GDS, UPF power intent, and library special
cells — delivered under NDA. This root is where those artifacts land locally so
the build can consume them, **without** the open repo ever carrying licensed data.

The design principle is the same "omitted vs present" pattern the board layer
uses (`corev-mb`, `MotherboardSkidlMode`): the **default is "omitted"** (no PDK,
generic path), and a technology is only ever *dropped in*, never *checked in*.

## 2. The PDK-swap seam this binds to

The technology pass does **not** invent a new abstraction. It binds proprietary
views at the seams CVA6 already ships:

- **`tech_cells_generic`** — `tc_sram.sv` (SRAM macro; note its `ImplKey`
  parameter), `tc_clk.sv` (`tc_clk_gating` ICG with `IS_FUNCTIONAL`), `tc_pwr.sv`
  (level-shifter / isolation / power-gating cells).
- **`common/local/util/sram_cache.sv`** — the `TECHNO_CUT` parameter already
  selects a technology cut (`tc_sram_wrapper_cache_techno`) vs the generic path.
- **HPDcache macros** — `core/cache_subsystem/hpdcache/rtl/src/common/macros/`
  ships `behav/`, `blackbox/`, and a real `rtl/syn/srams/<tech>/` mapping, all
  under the same module name, selected by which file the flist compiles.

## 3. Layout

```
pd/pdk/
  README.md                 # this file (tracked)
  .gitignore                # ignores everything but the tracked scaffold
  manifest.example.json     # TEMPLATE manifest a real (gitignored) manifest.json copies
  core/                     # protected drop-in for CORE adaptations (README tracked)
  corev_apu/                # protected drop-in for UNCORE (corev_apu) adaptations
  technology.example/       # committed TEMPLATE per-technology layout
  <technology>/             # GITIGNORED real drop, created by `cva6-build tech init <technology>`
    manifest.json           #   filled-in manifest (NDA)
    lib/ db/ lef/ gds/      #   timing/power/layout views (NDA)
    macros/ cells/ views/   #   compiled macros + cell wrappers + UPF/CPF (NDA)
```

## 4. Activation — the two-key ignition

The pass is **inert by default**. Nothing here is consumed, and no RTL behaviour
changes, unless **both** keys are turned:

1. **Build flag** — `technology.optimizationPass: true` in the repo-root
   `.config.ts` (schema: `build-platform/src/config/schema.ts`).
2. **A spec document in a relevant area** — at least one `*.tech-spec.md` under a
   scoped `core/**` or `corev_apu/**` path (globs in `technology.specGlobs`). This
   is how a designer *declares which block to optimize* for the technology.

If either key is absent — or the PDK views are simply not present — the generic,
macro-protected path elaborates exactly as it does today, so simulation and
open-source CI never depend on this directory.

## 5. Macro-protected adaptation

Any RTL adaptation the pass drives is **fenced behind a guard macro**
(`technology.guardMacro`, default `CVA6_TECH_OPT`):

```systemverilog
`ifdef CVA6_TECH_OPT
  // technology-specific wrapper: bind the compiled macro / library cell
`else
  // generic tech_cells_generic path (unchanged — what sim & OSS CI build)
`endif
```

When the macro is undefined (the default), the design is **byte-for-byte** the
open-source design. The macro is defined only for a synthesis/PnR run that also
has the matching NDA drop-in present. This keeps the adaptation *optional and
config-gated*, per `AGENTS.md` §0.2.

## 6. How the build consumes a drop-in

At synthesis / PnR (see `pd/synth/Makefile`, which already takes `FOUNDRY_PATH`,
`TECH_NAME`, `LOCAL_LIB_PATH`), the flow: (a) points at the local drop-in, (b)
defines the guard macro, (c) swaps the leaf tech-cell file (behav → blackbox →
foundry macro) via the flist fragment, and (d) links the compiled `.lib`/`.lef`.
Simulation never defines the macro and never reads this directory.

## 7. Commands

```
cva6-build tech status          # flag + PDK presence + arming summary
cva6-build tech specs           # list the *.tech-spec.md docs that scope the pass
cva6-build tech plan            # read-only adaptation plan (no RTL edits)
cva6-build tech check           # verify SoC-readiness gates (exit 3 if enabled-but-not-ready)
cva6-build tech init <tech-id>  # scaffold a gitignored per-technology drop-in (README only)
```

## 8. SoC-readiness gates (must hold before an armed pass is "done")

Per `AGENTS.md` §0 and `agents/guides/AGENTS-soc-readiness.md`, a technology
adaptation is only complete when it is also: **MBIST-inserted** for every macro,
**scan-wrapped** (`test_en_i`/`testmode_i` preserved), **timing-closed** on the
target library, **power-aware** (UPF/CPF domains, retention, ICG mapping), and
**verified equivalent** to the generic model (same ports/latency so sim == silicon).
`manifest.json.socReadiness` tracks these; `cva6-build tech check` gates them.

## 9. Licensing

- This README and the per-area READMEs are documentation — out of the
  code-licensing scope (`AGENTS.md` §0.4).
- **Foundry / NDA content is never committed**, so no license question arises for it.
- Any *wrapper* source an author adds to bind the seam is `SPDX-License-Identifier: LicenseRef-Proprietary` © Etienne Cimon per `.licensing-policy`, and must contain **no** NDA data.

## 10. See also

- `AGENTS-technology.md` — governance for the whole pass.
- `agents/guides/AGENTS-technology-optimization.md` — the step-by-step agentic playbook.
- `AGENTS.md` §0.1(4), §0.3 — the PDK-swap seam + anti-patterns.
- `core/` + `corev_apu/` per-area drop-ins: `pd/pdk/core/README.md`, `pd/pdk/corev_apu/README.md`.
