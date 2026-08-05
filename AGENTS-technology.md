# AGENTS-technology.md — Technology-optimization pass (foundry PDK adaptation)

**Standing workflow rule** (opt-in; applies only when the pass is armed). This
file governs how an agentic **technology-optimization pass** adapts CVA6 to a
specific process technology by binding a foundry's **proprietary, high-level
abstraction layers** (memory compilers, ICG / retention / level-shifter cells,
power-management kits, PLL / IO / SerDes hard macros) at CVA6's existing
**PDK-swap seam** — while the proprietary PDK itself stays **omitted, under NDA,
and never committed**.

It is **subordinate to `AGENTS.md` §0** (SoC / tape-out readiness prime
directive) and **co-equal-when-applicable** with the other standing disciplines
(licensing §0.4, coding-philosophy §0.5, spec traceability §0.6). It is the
*process-technology counterpart* to the uncore rule `AGENTS-corev-apu.md` and the
board rule `AGENTS-motherboard.md`: additive, opt-in, and it **never churns the
working RTL hierarchy or breaks a flist**.

---

## 0. TL;DR

- The pass is **inert by default.** Arming needs a **two-key ignition**: the build
  flag `technology.optimizationPass: true` **and** a `*.tech-spec.md` doc in a
  scoped `core/**` or `corev_apu/**` area.
- Proprietary PDK views live only under the git-ignored **`pd/pdk/`** root
  (`pd/pdk/core/`, `pd/pdk/corev_apu/`, per-technology drops). Only READMEs +
  templates are committed. **Never commit foundry / NDA content.**
- Every RTL adaptation is **fenced behind a guard macro** (`CVA6_TECH_OPT`), so
  the generic path is byte-for-byte unchanged when the macro is undefined.
- Drive it with **`cva6-build tech`** (`status` / `specs` / `plan` / `check` /
  `init`). Detailed playbook: `agents/guides/AGENTS-technology-optimization.md`.

## 1. Why (motivation)

CVA6 is silicon IP (`AGENTS.md` §0). A tape-out must map the design onto a real
process; foundries deliver that mapping as high-level abstraction layers under
NDA. This pass lets an agent *optimize the core for a technology* — swap
behavioural arrays for compiled macros, map clock-gates/retention to library
cells, attach power intent — **without** the open repository ever carrying
licensed data, and **without** disturbing simulation or open-source CI.

## 2. The seam it binds to (do not invent a new one)

Bind proprietary views at the seams CVA6 already ships (`AGENTS.md` §0.1(4)):

| Seam | File(s) | Role |
|---|---|---|
| `tech_cells_generic` | `vendor/pulp-platform/tech_cells_generic/src/rtl/{tc_sram.sv,tc_clk.sv}`, `.../src/tc_pwr.sv` | SRAM macro (`ImplKey`), ICG (`tc_clk_gating`, `IS_FUNCTIONAL`), power/level-shift/isolation cells |
| Cache SRAM cut | `common/local/util/sram_cache.sv` (`TECHNO_CUT`), `tc_sram_wrapper_cache_techno.sv` | Config-selected technology cut vs generic path |
| HPDcache macros | `core/cache_subsystem/hpdcache/rtl/src/common/macros/{behav,blackbox}/`, `rtl/syn/srams/<tech>/` | Same module name, swapped by flist (behav → blackbox → foundry) |
| Synthesis flow | `pd/synth/Makefile` (`FOUNDRY_PATH`, `TECH_NAME`, `LOCAL_LIB_PATH`) | Where the local PDK drop-in is linked |

## 3. Macro-protected adaptation (the core convention)

Adaptations are **optional and config-gated**, per `AGENTS.md` §0.2:

```systemverilog
`ifdef CVA6_TECH_OPT
  // technology-specific: compiled macro / library cell (from pd/pdk/<tech>/)
`else
  // generic tech_cells_generic path — UNCHANGED (what sim & OSS CI build)
`endif
```

Rules:

- **Guard everything.** The guard macro is `technology.guardMacro` (default
  `CVA6_TECH_OPT`). Undefined ⇒ generic path. Never let an adaptation leak into
  the unguarded elaboration.
- **Confine `` `ifdef `` to leaves.** Keep the pipeline technology-agnostic;
  prefer parameter/`generate` selection (the `TECHNO_CUT` pattern) for structure
  and `` `ifdef `` only for the proprietary leaf cell file (`AGENTS.md` §0.3).
- **Equivalence.** A technology wrapper must be **port-/latency-equivalent** to
  the generic cell so simulation == silicon.
- **Config first.** Any new selection knob goes through `config_pkg::cva6_cfg_t`
  + `check_cfg` (`core/include/config_pkg.sv`), never hard-coded in a module.

## 4. Protected paths & activation

- **Protected root:** `pd/pdk/` (git-ignored except READMEs + templates + the
  per-dir `.gitignore` + `manifest.example.json`). Per-area: `pd/pdk/core/`,
  `pd/pdk/corev_apu/`. Real drops: `pd/pdk/<technology>/` (created by
  `cva6-build tech init <technology>`, entirely git-ignored).
- **Key 1 — the build flag:** `technology.optimizationPass` in the repo-root
  `.config.ts` (schema `build-platform/src/config/schema.ts`, defaults `false`).
- **Key 2 — spec docs in relevant areas:** a `*.tech-spec.md` under `core/**`
  or `corev_apu/**` (globs `technology.specGlobs`) declares *what to optimize*.
- **PDK presence:** `technology.pdkMode` is `omitted` (default; generic path),
  `open` (sky130 / nangate45 / FakeRAM, trackable), or `nda` (drop under `pdkRoot`).

## 5. `core` / `corev_apu` support

- **`core/` (pipeline IP):** L1 I$/D$ + HPDcache SRAMs, register file / small
  arrays, ICG in FIFOs, retention/isolation for core power domains. Seam: §2 rows
  1-3. Drop-in: `pd/pdk/core/<technology>/`. Details: `pd/pdk/core/README.md`.
- **`corev_apu/` (uncore/SoC):** DRAM/HBM PHY + controller RAMs, PLL/clocking, IO
  pads, boot ROM / AXI memory. Coordinate with `AGENTS-corev-apu.md` (AXI/clock/
  reset/CDC, PHY-vs-controller split, DFT) and the vendor catalog
  (`AGENTS-vendor.md`). Drop-in: `pd/pdk/corev_apu/<technology>/`.

## 6. SoC-readiness gates (carry-over checklist for an armed pass)

A technology adaptation is only "done" when — beyond functional equivalence — it
also satisfies `AGENTS.md` §0.2 for the target library. `cva6-build tech check`
gates the hard items; `manifest.json.socReadiness` records them:

- **Config-gated & guarded:** behind `CVA6_TECH_OPT` + a `cva6_cfg_t` knob; minimal/omitted configs still elaborate the generic path.
- **Verified equivalent:** wrapper ports/latency == generic; compliance regression stays green.
- **DFT:** MBIST/BISR planned for every new macro; `test_en_i`/`testmode_i` preserved; scan-wrapped.
- **Timing:** closed on the target `.lib`; no new long combinational path.
- **Power:** UPF/CPF domains, retention, ICG (`IS_FUNCTIONAL`) mapping; area/power reported.
- **Backend:** arrays via `tc_sram`, gating via `tc_clk_gating`, power via `tc_pwr`; hard macros get a placement/power plan.
- **Documented:** the `*.tech-spec.md`, this manifest, and area READMEs updated.

## 7. Commands (`cva6-build tech`)

| Sub | Purpose | Notes |
|---|---|---|
| `status` | Flag + PDK presence + arming summary | default; read-only |
| `specs` | List `*.tech-spec.md` docs scoping the pass | `--json` |
| `plan` | Read-only adaptation plan (seam + guard + output dir per doc) | **never edits RTL** |
| `check` | Verify SoC-readiness gates | exit `3` if *enabled but not ready*; `0` if disabled |
| `init <tech-id>` | Scaffold a git-ignored per-technology drop-in (README only) | `--dry-run` |

## 8. Licensing (see `AGENTS-licensing.md`, `AGENTS.md` §0.4)

- **NDA / foundry content is never committed** — no license question arises for it.
- Build-platform code added for the pass (`build-platform/src/**`) is
  `SPDX-License-Identifier: LicenseRef-Proprietary` © Etienne Cimon per `.licensing-policy`.
- Any RTL *wrapper* an author adds to bind the seam inherits the edited file's
  license (or proprietary for a net-new authored file) and must contain **no** NDA data.
- This file and all `pd/pdk/**` READMEs are documentation — out of code scope.

## 9. Relationship to the other standing rules

- **`AGENTS.md` §0** — overriding SoC prime directive; this pass never violates it.
- **`AGENTS-coding-philosophy.md`** — any RTL wrapper follows it (timing note, review checklist, trade-off log).
- **`AGENTS-corev-apu.md`** — uncore preconditions for `corev_apu/` adaptations.
- **`AGENTS-vendor.md`** — PHY / controller hard IP that a technology drop pairs with.
- **`AGENTS-motherboard.md`** — the board layer; a board may pin a target process, but board ≠ PDK.

## 10. High-level workflow

The step-by-step agentic playbook (detect → plan → adapt behind the guard →
verify SoC-readiness → document) lives in
`agents/guides/AGENTS-technology-optimization.md`. Start there for any armed pass;
this file is the governance/contract it operates under.
