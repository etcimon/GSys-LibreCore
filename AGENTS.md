# GSys LibreCore Agent Guider (main)

> **Agent note — project identity:** This repository is **GSys LibreCore** (short name
> **LibreCore**, code prefix **`G6LC`**), a derivative of the **OpenHW Group CVA6** RISC-V core
> (formerly tracked here as `CVA6V-EC`). CVA6 remains the reference/base model and the upstream
> rebase target. Naming is governed by **`AGENTS-branding.md`**: `GSys LibreCore` is the full brand,
> `LibreCore` the prose shorthand, `G6LC` the code identifier prefix. Where `CVA6`, `cva6_*`,
> `CVA6Cfg`, `CVA6_REPO_DIR` or `Flist.cva6` still appear, that is **deliberate** — either upstream
> attribution that must be preserved, a Linux/device-tree ABI string, or an interior identifier that
> `AGENTS-branding.md` §3 forbids churning. Do not "finish" the rename by editing tier-U files.
>
> **Licensing is dual and tier-directed** (`AGENTS-licensing.md`, `.licensing-tiers`): LibreCore
> RTL is `CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial`; tooling/docs/reference software are `MIT`;
> upstream material keeps its own terms **verbatim**; the FPGA bootrom is a separate GPL work.

This is the **entry point** for agents adding features to CVA6. It exists to make the
question *"where in the spec, and where in the code, does this feature live?"* answerable
in one hop. It reasons about a **sub-file substructure** (under `agents/`) so that a prompt
about **branch prediction**, **L2/L3 caching**, **RAM support**, or **speculative execution**
is routed to a small, exact set of spec anchors and `file:line` code loci instead of a
whole-repository scan.

- Spec of record: `specs/riscv-spec.html` (RISC-V ISA Manual, Asciidoctor, ~93k lines, version 20260717).
- Three Parts: **I** Unprivileged (`#vol:unpriv`, src line 1172), **II** Privileged (`#vol:priv`, 67256), **III** Profiles (`#vol:profiles`, 89395).
- Core RTL: `core/` (the pipeline IP). SoC/integration: `corev_apu/`. Config surface: `core/include/`, `config/`.

---

## 0. Prime directive — SoC / tape-out readiness (read before any edit)

CVA6 is **silicon IP, not a software model**. It is fabricated on real processes, integrated into
SoCs, booted into Linux, and taped out. Therefore the spec-to-code mapping in the rest of this file
(sections 1-8) establishes *functional correctness*, which is **necessary but never sufficient**. A
change is only "done" when it is *also* synthesizable, parameterized, verified, testable, observable,
power-aware, and documented. **Author every change as if the SoC tapes out in 3-6 months** — the cost
of repairing a badly integrated feature after the surrounding SoC is frozen is 3-10x, and it is the
single fastest way to turn a ~$15k MPW shuttle into a $100k+, many-month slip. This section is the
overriding philosophy; where it conflicts with expedience, it wins. The detailed playbook lives in
`agents/guides/AGENTS-soc-readiness.md`.

### 0.1 Ranked principles (most critical first), each anchored in real CVA6 mechanisms

1. **Synthesizability and timing closure come first.** Write clean synthesizable SystemVerilog: strict
   `always_ff`/`always_comb` separation, no simulation-only constructs in the logic path, and no new
   `always_latch` (the *only* sanctioned latch is inside the ICG cell `tc_clk_gating` at
   `vendor/pulp-platform/tech_cells_generic/src/rtl/tc_clk.sv:47-49`). Respect the **single reset
   strategy**: asynchronous-active-low, `always_ff @(posedge clk_i or negedge rst_ni)` (pervasive,
   e.g. `core/cva6_fifo_v3.sv:207-213`). Never add a new clock or asynchronous reset without explicit
   CDC/reset-sync analysis. Keep combinational cones short and add pipeline stages for complex units
   rather than lengthening a critical path. Fence every sim-only construct with `//pragma translate_off`
   / `//pragma translate_on` (see `core/cva6.sv:1884-1889`).
2. **Everything is parameterized through `CVA6Cfg`.** Extend `config_pkg::cva6_cfg_t` and its
   `check_cfg` assertions (`core/include/config_pkg.sv`) and the per-target packages
   (`core/include/cv{32,64}a6*_config_pkg.sv`, 13 of them); never hard-code a feature into a module.
   Every new feature must be **optional** so minimal configs still elaborate and synthesize. Structural
   types enter modules via `parameter type ...` injection — keep that seam.
3. **Verify and test in lockstep with the RTL, not after.** Extend the `verif/` flow
   (`verif/core-v-verif/`, `verif/regress/`, `verif/tb/`, `verif/tests/`), keep the RISC-V compliance
   regression green, update formal properties, and add DFT hooks *while* writing the feature. Scan
   enable is already threaded as `test_en_i` (tied to `1'b0` in-core, e.g.
   `core/issue_read_operands.sv:924`) and `testmode_i` to bypass clock gates
   (`core/cva6_fifo_v3.sv:29`) — new stateful logic must preserve scan/ATPG observability, not break it.
4. **Design for the backend from day one.** New memories go through the SRAM macro boundary
   `tc_sram` (`vendor/.../tech_cells_generic/src/rtl/tc_sram.sv`), gating through `tc_clk_gating`, and
   power cells through `tc_pwr.sv` — these are the **PDK-swap seam**; do not instantiate raw flops for
   arrays or bake in a vendor cell. Avoid high fan-in/fan-out and routing hotspots; large blocks
   (vector/matrix/accel) need their own placement region and clock-gate/power-domain plan. Keep
   hierarchy clean for floorplanning.
5. **Do not break the software/ecosystem contract.** New instructions/CSRs must have a real encoding,
   a discovery mechanism (config bit → `misa`/ISA string), and toolchain/SBI/Linux visibility. Keep
   the `.dts` ↔ config ↔ spec triple aligned (section 6). Prefer adding custom compute at the **CVXIF
   coprocessor boundary** (`core/cvxif_fu.sv`, `core/acc_dispatcher.sv`, ports at `core/cva6.sv:337-340`)
   so the core pipeline and its verification are untouched; `CvxifEn` and `EnableAccelerator` are
   mutually exclusive by assertion (`core/cva6.sv:850-852`).
6. **Keep it observable.** New pipeline stages/units must be visible to trace and debug: RVFI probes
   (`core/cva6_rvfi.sv`, `core/cva6_rvfi_probes.sv`, `rvfi_probes_o` at `core/cva6.sv:336`), debug
   triggers (`core/trigger_module.sv`, `debug_req_i`), and PMU counters (`core/perf_counters.sv`). Add
   a PMU event for every new feature and keep exception/mispredict paths precise.
7. **Account for power, area, and security.** Budget area/power with early synthesis reports; add
   clock-gating (functional vs `IS_FUNCTIONAL==0` power-only, `tc_clk.sv:31-37`), and honor the
   existing protection model (PMP `core/pmp/`, PMA/region rules in `check_cfg`) for any change that
   touches memory permissions or address masking.
8. **Document and keep it reproducible.** Update `docs/03_cva6_design/`, the affected guide under
   `agents/guides/`, and any constraints/scripts so a partner or foundry team can integrate cleanly.

### 0.2 Carry-over checklist (binds *every* implementation change)

Before proposing any RTL edit, and again before calling it complete, confirm each item or state why it
does not apply:

- **Config-gated**: new behavior sits behind a `cva6_cfg_t` field with a `check_cfg` legality assert;
  minimal configs still elaborate.
- **Synth-clean**: `always_ff`/`always_comb` split; async-active-low reset only; no new latch/clock;
  sim-only code under `translate_off`.
- **Timing-aware**: no new long combinational path; complex logic is pipelined; critical/new high-activity nets noted.
- **Backend-friendly**: arrays via `tc_sram`, gating via `tc_clk_gating`; no raw vendor cells; large blocks have a placement/power note.
- **Verified**: directed test + compliance regression + formal/coverage updated; runs added under `verif/`. **Mechanism**: run `./build.sh verify` / `.\build.ps1 verify` (or `bun build-platform/src/cli/index.ts verify`) after every RTL change; it sweeps lint across all configured targets, runs configured formal tasks, executes simulation suites, and performs a synthesis smoke so no single change can regress elaboration or synth-cleanliness. **Tooling preflight** (when the host or residual stack is in doubt): `./build.sh probe` → `tools install …` / `probe install` → optional `diag run` (compartmentalized Verilator surfaces) before full `verify` — see `AGENTS-build.md` and `build-platform/AGENTS.md` §4.6.
- **Testable (DFT)**: `test_en_i`/`testmode_i` propagated; scan/ATPG observability preserved.
- **Observable**: RVFI/trace + debug trigger + a PMU event for the feature.
- **Ecosystem-safe**: encoding/discovery defined; `.dts`↔config↔spec aligned; toolchain/SBI/Linux impact stated; custom compute prefers CVXIF.
- **Documented**: design docs + relevant `agents/` guide updated; area/power/timing impact recorded.
- **Philosophy-checked**: the change follows `AGENTS-coding-philosophy.md` (timing impact note, review checklist, trade-off log). The `./build.sh verify --lint --sim --synth` (or `bun build-platform/src/cli/index.ts verify --lint --sim --synth`) flags are the concrete, runnable form of that checklist for the lint/formal/sim/synth axes.

### 0.3 Cost-driver anti-patterns (never do these)

Hard-coded constants instead of `CVA6Cfg` (forces full-core re-verify/re-synth); breaking module
boundaries or coupling pipeline stages (kills timing closure and floorplanning); skipping verification,
compliance, DFT, or gate-level/power-aware checks (bugs surface post-silicon at maximal cost);
high-fanout nets / long combinational paths / no early-synthesis loop (P&R respins, larger die,
un-routable); new instructions/CSRs with no encoding, discovery, or docs (breaks OpenSBI/Linux/toolchain);
over-scoped OoO/wide-vector/heavy-speculation additions without a micro-arch and verification plan
(3-10x effort, project risk). When in doubt, add at a sanctioned seam (CVXIF, `tech_cells_generic`,
the config struct) rather than inside a pipeline stage.

### 0.4 Contributor licensing (standing workflow rule — see `AGENTS-licensing.md`)

Every edit to **actual code** is governed by `AGENTS-licensing.md`, driven by the repo-root config
files `.active-contributor` and `.licensing-policy` (templates: `.active-contributor.example`,
`.licensing-policy.example`). This rule is **co-equal** with the project's other standing
disciplines — keeping `agents/spec/INDEX.md` statuses current, logging todos in `AGENTS-todo.md`, and
following `AGENTS-coding-philosophy.md` — and is applied **at most passes, depending on
applicability**: a pass that touches code *must* run the licensing pass; a pass that touches only
docs/specs skips it. It sits beside (never above) the section-0 SoC prime directive.

- **Scope**: **tier-directed, not in/out.** Every file resolves to a tier via `.licensing-tiers`
  (last matching glob wins; the default rule is `U **`, so anything unclassified is treated as
  someone else's property). Markdown follows its tier but takes **no inline header**
  (`DOCS_UNDER_TIER`) — so `AGENTS*.md` and `agents/**` are now *in* scope for licensing, unlike the
  retired in/out model.
- **Error on missing config**: if a code edit is needed and `.active-contributor`,
  `.licensing-policy` or `.licensing-tiers` is absent (or self-conflicting), the agent must **halt
  and report**, not silently proceed.
- **Shipped policy** (source of truth: `.licensing-policy` + `.licensing-tiers`): active contributor
  `Etienne Cimon`; `DEFAULT_TO_FILE_LICENSE` + `TIER_DIRECTED_LICENSING` + `DOCS_UNDER_TIER` +
  `CLA_REQUIRED_TIERS=R` + `DE_MINIMIS_GUARD` + `ADD_CONTRIBUTOR_NAME` +
  `SELECT_MOST_PERMISSIVE` (fallback). Tiers:
  **R** LibreCore RTL → `CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial`;
  **T** tooling/docs/software → `MIT`;
  **U** upstream → **unchanged, verbatim**;
  **F** FPGA bootrom → `GPL-2.0-or-later` (separate work);
  **P** NDA/PDK → `LicenseRef-Proprietary`.
- **Three hard guards.** (1) `E-UPSTREAMWRITE` — never alter a tier-U copyright line, SPDX
  identifier, attribution or `NOTICE` content; retention is a *condition* of our licence
  (Apache-2.0 §4(c), Solderpad §4). (2) `E-DEMINIMIS` — never assert the tier-R licence over a
  third-party file on the strength of a trivial delta; two files are pinned as deliberate exclusions
  in `.licensing-tiers` and `REUSE.toml`. (3) `E-GPLLINK` — never let GPL material, especially the
  `GPL-2.0-only` `dma-mapping.h`, into a link set with Apache/CERN-OHL material.
- **Case B outbound offers** use a prose `Outbound-License:` tag plus `REUSE.toml`, never a second
  `SPDX-License-Identifier` (that is `E-TIERCONFLICT`).
- **Branding** is governed co-equally by `AGENTS-branding.md` (see §0.4a below).

### 0.4a Branding (standing workflow rule — see `AGENTS-branding.md`)

Naming is a licensing-adjacent obligation: neither Apache-2.0 §6 nor Solderpad §6 grants trademark
rights, so the project must not brand itself `CVA6`/`CORE-V`. New code is `g6lc_*` / `g6lc64_*`;
prose is "GSys LibreCore" then "LibreCore". The **boundary rule** is binding: rename at the boundary,
never inside a tier-U file — add `core/include/g6lc_pkg.sv` (the `g6lc_cfg_t` / `G6LCCfg` alias seam)
or `core/Flist.g6lc`, rather than churning ~5,900 `CVA6Cfg` sites for zero legal benefit.
`mvendorid`/`marchid` must never be faked; they are release blockers in `AGENTS-todo.md`.

### 0.5 Coding philosophy (standing workflow rule — see `AGENTS-coding-philosophy.md`)

Every **code change** must be authored and reviewed against `AGENTS-coding-philosophy.md` and the
target SoC context in `AGENTS-configuration.md`. The philosophy codifies the thought patterns that
turn a feature idea into synthesizable, timing-clean, verifiable, and SoC-ready SystemVerilog:
correctness before performance, timing as a first-class citizen, modularity through `CVA6Cfg`,
verification parity, silicon reality, explicit over implicit, and documented trade-offs. The
configuration file supplies the concrete numbers (frequency, voltage, power, process, memory,
software, DFT) against which those patterns are applied. Both are **co-equal** with the licensing
discipline and the SoC prime directive. For non-trivial changes, attach a timing-impact note and tick
the review & validation checklist in the PR.

- **Scope**: code and code-generating scripts (`.sv/.svh/.v`, `.c/.h/.cpp`, `.py`, `.S`, `.tcl`,
  `Makefile`, `.sh`, etc.). It never overrides `AGENTS-licensing.md`; a pass must satisfy both.
- **Practical requirement**: include a short timing-impact note, a review-checklist statement, and a
  `.dts`/spec/config alignment note when the change touches timing, ISA-visible behavior, or SoC
  integration.
- **Evolution**: exceptions to the philosophy are allowed only with senior review and are recorded in
  this file or in `AGENTS-coding-philosophy.md` if they become patterns.
- **Uncore counterpart**: for changes to the SoC-integration layer (`corev_apu/**`, board wrappers,
  vendored controllers/PHY), `AGENTS-corev-apu.md` carries the SystemVerilog **preconditions** (AXI
  seam, clock/reset/CDC, PHY-vs-controller separation, DFT, flist/DTS), and `AGENTS-vendor.md` +
  `AGENTS-core-platform-vendor-actives.md` govern how controller/PHY IP is fetched, scanned, and
  mapped onto the die. They extend this philosophy to the uncore around the core.
- **Board counterpart**: for the board *around* the die (`corev-mb/**`), `AGENTS-motherboard.md`
  governs the single-active-board `mb` flow — selecting a board adapts `soc.coreConfig` + syncs
  vendor controllers + generates a **non-compiled** board package; per-board contracts live in
  `AGENTS-mb-<id>.md`, and development targets in `corev-mb/architecture/<id>/`. It is subordinate
  to this section 0 and never edits `core/**` or `corev_apu/src/**` by selection.

### 0.6 Spec-to-implementation & spec-to-test traceability (standing workflow rule)

The repo maintains four **living** cross-reference files at the repo root, co-equal with the other
standing disciplines (licensing, coding-philosophy, `agents/spec/INDEX.md` upkeep, todo logging):

- `AGENTS-specs-to-impl.md` — RISC-V spec chapter ⇄ the SystemVerilog that implements it. **Any edit to
  ISA-visible RTL under `core/**` / `corev_apu/**` must update the matching row** (status and/or loci).
- `AGENTS-specs-to-tests.md` — spec chapter ⇄ the test suites that exercise it. **Any change to a test
  suite or a `verif/tests/testlist_*.yaml` must update the matching row.**
- `AGENTS-specs-coverage.md` — a **derived**, status-only summary (no file refs). Re-derive the affected
  rows whenever either source map changes; never hand-edit a status without a source-map change.
- `AGENTS-dts-validation.md` — Linux RISC-V device-tree bindings ⇄ CVA6 `.dts`/RTL cross-validation.
  **Any edit that changes a device-tree-visible capability** (ISA string, CSR, interrupt controller,
  timer, cache, memory map) **must update the matching row** and run the cross-validation procedure in
  that file.

Applicability mirrors §0.4: a pass that touches ISA-visible RTL runs the impl-map + coverage update; a
pass that touches tests runs the tests-map + coverage update; a docs/spec-only pass may skip them. Future
feature *directories* are reserved and documented under `architecture/` — a **non-compiled scaffold**
(not referenced by any flist; see `architecture/README.md`); promoting one into real RTL follows the
checklist there plus §0.2.

### 0.7 Technology optimization — foundry PDK adaptation (opt-in workflow rule — see `AGENTS-technology.md`)

An **opt-in** pass adapts CVA6 to a specific process by binding a foundry's proprietary, high-level
abstraction layers (memory compilers, ICG / retention / level-shifter cells, power kits, hard macros) at
the existing **PDK-swap seam** (`tech_cells_generic`; `common/local/util/sram_cache.sv` `TECHNO_CUT`;
hpdcache `behav`/`blackbox`/`<tech>` macros). It is **subordinate to this section 0** and additive — it
never churns the RTL hierarchy or breaks a flist. Governance: `AGENTS-technology.md`; agentic playbook:
`agents/guides/AGENTS-technology-optimization.md`.

- **Two-key ignition (high-level workflow).** The pass is inert unless BOTH `technology.optimizationPass`
  is true AND a `*.tech-spec.md` doc exists under a scoped `core/**` / `corev_apu/**` area. Drive it with
  `build-platform`'s `cva6-build tech` (`status` → `specs` → `plan` → adapt behind the guard → `check` →
  document; `init <tech>` scaffolds a drop-in).
- **Macro-protected.** Every adaptation is fenced behind the guard macro `CVA6_TECH_OPT` (config
  `technology.guardMacro`); undefined ⇒ the generic path elaborates byte-for-byte as today. `` `ifdef ``
  stays at the leaf; structure is config-gated via `cva6_cfg_t` (§0.2, §0.3).
- **Omitted PDK under NDA.** Proprietary views live only under the git-ignored `pd/pdk/` root (per-area
  `pd/pdk/{core,corev_apu}/`); only READMEs + templates are committed. **Never commit foundry content.**
- **SoC-readiness.** An armed pass must still satisfy §0.2 for the target library (equivalence, DFT/MBIST,
  timing, power/UPF, area); `cva6-build tech check` gates the hard items.
- **Applicability.** Only when armed. A guarded RTL wrapper runs the licensing (§0.4) + coding-philosophy
  (§0.5) passes on that wrapper; the NDA PDK itself is never in-repo, so it has no license footprint here.

---

## 1. Why this substructure exists (reasoning)

The RISC-V specification mandates *architectural semantics, not microarchitecture*. That single
fact dictates the whole layout of `agents/`. Features split into two populations. The first are
**spec-anchored**: their correctness is pinned to normative text (memory ordering, physical-memory
attributes, page-table formats, atomics, fences). For these, the highest-value artifact is a
faithful summary of the exact subchapter, deep-linked to the canonical anchor, paired with the
`file:line` that implements it. The second are **microarchitectural**: branch prediction and the
existence of an L2/L3 cache are *not* described by the spec at all; the spec only constrains what
they must remain transparent to (control-flow results, coherence, ordering, precise traps). For
these, the artifact must state the *indirect* spec constraints and locate the *microarchitectural*
code, while flagging that "adding" them is an integration act, not a spec-conformance act.

The substructure therefore separates three file families: **spec summaries** (`agents/spec/*.html`,
one small file per `X.y` subchapter, Logisplain prose + pseudo-SystemVerilog), **purpose guides**
(`agents/guides/AGENTS-*.md`, one per feature domain, aggregating the relevant spec summaries and
code loci into a feature-addition playbook), and **this guider** plus the spec index
(`agents/spec/INDEX.md`). Small single-topic files are deliberate: they keep each retrieval unit
below a page, let a prompt load only the 3-6 files it needs, and make the map extensible one
subchapter at a time without rewriting a monolith.

---

## 2. Substructure map

| Path | Role |
|---|---|
| `AGENTS.md` (this file) | Main guider: reasoning, navigation, dev patterns, spec-to-code master map, `.dts` linkage. |
| `AGENTS-coding-philosophy.md` | **Standing governance** (co-equal w/ licensing + spec-status + todo upkeep): coding philosophy, timing-analysis practices, review checklist, and trade-off documentation for all code changes. |
| `AGENTS-configuration.md` | **Standing governance** (co-equal w/ coding-philosophy + licensing): target SoC context (frequency, voltage, power, process, memory, software, DFT) that every code change must respect. |
| `AGENTS-licensing.md` | **Standing governance** (co-equal w/ coding-philosophy + spec-status + todo upkeep): license/attribution policy for **code only**, driven by `.active-contributor` + `.licensing-policy` (see section 0.4). |
| `AGENTS-specs-to-impl.md` | **Standing traceability** (§0.6): RISC-V spec ⇄ CVA6 RTL map; updated on every ISA-visible `.sv` change. |
| `AGENTS-specs-to-tests.md` | **Standing traceability** (§0.6): RISC-V spec ⇄ test-suite map; updated on every test-suite / testlist change. |
| `AGENTS-specs-coverage.md` | **Standing traceability** (§0.6): derived, status-only spec coverage summary (no file refs). |
| `AGENTS-dts-validation.md` | **Standing traceability** (§0.6): Linux RISC-V device-tree bindings ⇄ upstream reference DTS ⇄ CVA6 `.dts` ⇄ CVA6 RTL cross-validation. Fetched via `build-platform/scripts/fetch-linux-dts.{sh,ps1}`. |
| `architecture/` (+ `README.md`) | Non-compiled **scaffold** + target-layout blueprint: extension points for future growth (branch prediction, speculation, SMT, multi-core, L2/L3, more spec features). Not in any flist. Live RTL summary + upgrade programs live here too. |
| `architecture/sv-timing/` | **Pointer only** → package design under `sv-timing/architecture/`. |
| `architecture/uncore/` (+ `README.md`) | Non-compiled **scaffold**: per-domain uncore controller/PHY integration outlines (DDR4, Ethernet, PCIe, storage, HDMI). Not in any flist. |
| `AGENTS-build.md` | Thin pointer → **`build-platform/AGENTS.md`** (Bun + TypeScript automation spine: probe/tools/diag/verify/vendor/mb/tech/timings). |
| `sv-timing/AGENTS.md` | Package guider for the **standalone** structural FO4 timing AST + auto-correct tool. Host adapter: `cva6-build timings` (never link monorepo into crates). |
| `riscv-compilers/` (+ `README.md`) | **Bootstrap scaffold** (self-contained; not part of the SoC flow): promotes a non-agentic compiler/toolchain submodule to an *in-tree* agentic surface — Logisplain analysis → `<id>/architecture/` notes → `<id>/AGENTS.md`. Terminal state is **independence**: after emancipation the scaffold is contextually insignificant to that submodule. RISC-V is an inert affinity dossier, governing nothing. Nothing in `core/**` / `corev_apu/**` is touched. |
| `riscv-dev/` (+ `README.md`) | **Bootstrap scaffold** (sibling of `riscv-compilers/`, same ladder) for library/runtime submodules: interface promise, dependency/environment surface, build+test matrix. Optional backing-compiler relation by recorded pin + invocation only (`AGENTS-toolchain-link.md`). |
| `docs/website/` | Published human docs (Next.js + Nextra): worktree, layers, build-platform, sv-timing. Sphinx under `docs/01_…` remains OpenHW-lineage manuals. |
| `corev-mb/` (+ `README.md`) | The **board layer** around the die. `boards/<id>/board.json` = machine spec the `mb` command consumes; `boards/<id>/generated/` (board package + `board.mk`) and `outputs/` are gitignored; `lib/` holds the SKiDL flow + pcbparts.dev MCP client. |
| `corev-mb/architecture/` (+ `README.md`) | Non-compiled **scaffold**: per-board development targets (`genesys2` reference; `bpi-f3`, `milkv-jupiter`, `milkv-titan` analysis-only). Not in any flist. |
| `AGENTS-motherboard.md` | **Standing governance** (board counterpart to coding-philosophy): the single-active-board `mb` configure flow, `board.json` schema, core⇄board parameterization handshake, pcbparts.dev tools, and SoC-readiness gates for board work. |
| `AGENTS-mb-<id>.md` | Per-board **contract + checklist** tethering one board to core/uncore development (e.g. `AGENTS-mb-genesys2.md`). Cross-refs `board.json` + `corev-mb/architecture/<id>/`. |
| `AGENTS-mb-skidl.md` | **Board design-philosophy** (PCB counterpart to `AGENTS-coding-philosophy.md`): SKiDL + pcbparts.dev part selection, power-rail planning, SoC-pin↔PHY mapping, physical-positioning/layout intent, and the ERC design loop for `custom` boards. Not a board (no `boardid` named `skidl`). |
| `AGENTS-corev-apu.md` | **Standing governance** (uncore counterpart to coding-philosophy): SystemVerilog preconditions for `corev_apu` controllers/wrappers before they enter a flist. Binds every uncore/integration change. |
| `AGENTS-technology.md` | **Standing workflow rule** (opt-in; process-technology counterpart to `AGENTS-corev-apu.md`): the technology-optimization pass — omitted-PDK-under-NDA, macro-protected (`CVA6_TECH_OPT`) adaptation at the `tech_cells_generic` seam, armed by the `cva6-build tech` flag + `*.tech-spec.md` presence (§0.7). |
| `pd/pdk/` (+ `README.md`) | **Protected** (git-ignored) foundry / NDA PDK drop-in root: memory-compiler / cell / power / hard-macro views bound at the PDK-swap seam. Only READMEs + `manifest.example.json` committed; per-area `pd/pdk/{core,corev_apu}/`. Not in any flist. |
| `AGENTS-vendor.md` | **Standing workflow rule**: how uncore controller/PHY IP is fetched/updated/scanned via the `build-platform` `vendor` command + `config.vendor` catalog. |
| `AGENTS-core-platform-vendor-actives.md` | The controller/PHY **substructure** feeding `corev_apu` (on-die controller vs board/analog PHY split, AXI seams, status). Data view paired with `AGENTS-vendor.md`. |
| `AGENTS-vendor-code-agents.md` | **Standing workflow rule**: meta-spec + template for per-vendor self-aware guides — how each vendored tree carries `agents/vendor/AGENTS-vendor-<id>.md`, self-versions against the catalog, self-updates, and maps itself onto the core platform. |
| `agents/vendor/AGENTS-vendor-<id>.md` | Per-vendor **code-agent** guide: an `AGENTS.md`-equivalent for one checked-out controller/PHY (provenance/pin, interface map, connectivity to CVA6, exploration + integration plan). Governed by `AGENTS-vendor-code-agents.md`. |
| `agents/spec/INDEX.md` | Spec substructure guider: every Part/chapter/`X.y` anchor, domain tag, and its sub-file + status. |
| `agents/spec/riscv-spec-<Vol>-<X.y>-<slug>.html` | One Logisplain summary per subchapter + pseudo-SystemVerilog + deep link to canonical anchor. |
| `agents/guides/AGENTS-soc-readiness.md` | **Cross-cutting** guide: SoC/tape-out discipline (synth, config, verif/DFT, backend, ecosystem, observability, power/security, docs). Expands section 0; binds every change. |
| `agents/guides/AGENTS-branch-prediction.md` | Feature guide: branch prediction / control-flow speculation. |
| `agents/guides/AGENTS-l2l3-cache.md` | Feature guide: L1 subsystem + adding an L2/L3 (integration). |
| `agents/guides/AGENTS-ram-memory.md` | Feature guide: memory, PMA, virtual memory, AXI/RAM bring-up. |
| `agents/guides/AGENTS-speculation.md` | Feature guide: speculative execution, flush/recovery, memory ordering. |
| `agents/guides/AGENTS-vector.md` | Feature guide: RVV 1.0 / Ara accelerator attach (U10ᵇ), DTS/SBI/Linux, directed vector tests. |
| `agents/guides/AGENTS-controller-readiness.md` | Feature guide: adding vendored uncore controllers/PHY via the `build-platform` vendor catalog and wiring them into `corev_apu`. |
| `agents/guides/AGENTS-technology-optimization.md` | Feature guide: the agentic technology-optimization playbook (detect → plan → adapt behind the `CVA6_TECH_OPT` guard → verify SoC-readiness → document). |

Deep-link convention: a spec reference is always `specs/riscv-spec.html#<anchor>` (canonical) and,
where useful, the source line `specs/riscv-spec.html:<n>`. A code reference is always
`path/to/file.sv:<start>-<end>`.

---

## 3. Navigate by intent

| If the prompt is about... | Open this guide | Then these spec sub-files (canonical anchors) | Primary code |
|---|---|---|---|
| **Any** feature/RTL edit, tape-out, synth, DFT, timing, power, verif, integration | `agents/guides/AGENTS-soc-readiness.md` (+ section 0) | (cross-cutting; not spec-bound) | `core/include/config_pkg.sv`, `vendor/pulp-platform/tech_cells_generic/src/rtl/{tc_sram.sv,tc_clk.sv}`, `core/cvxif_fu.sv`, `verif/` |
| Branch prediction, BTB/BHT/RAS, mispredict | `agents/guides/AGENTS-branch-prediction.md` | `#ext:zifencei` (4.1), `#unpriv-cfi` (4.17), `#priv-cfi` (6.9), `#smctr` (6.8) | `core/frontend/{bht.sv,bht2lvl.sv,btb.sv,ras.sv,frontend.sv}`, `core/branch_unit.sv` |
| L2/L3 cache, cache blocks, CMO, coherence | `agents/guides/AGENTS-l2l3-cache.md` | `#memorymodel` (3.1), `#pma` (3.6), `#ext:zic64b` (4.15), `#cmo` (4.20) | `core/cache_subsystem/*`, `core/cva6.sv:1400-1560` |
| RAM, DRAM regions, MMU, address translation | `agents/guides/AGENTS-ram-memory.md` | `#sec:intro-memory` (1.4), `#pma` (3.6), `#pmp` (3.7), `#sv39` (4.4) | `core/load_store_unit.sv`, `core/cva6_mmu/`, `core/pmp/`, `corev_apu/axi_mem_if/` |
| Speculative execution, flush, recovery, ordering | `agents/guides/AGENTS-speculation.md` | `#memorymodel` (3.1), `#ext:zifencei` (4.1), `#ext:a` (5.1), `#ext:zawrs` (5.5) | `core/scoreboard.sv`, `core/commit_stage.sv`, `core/controller.sv`, `core/frontend/frontend.sv` |
| RVV / vector, Ara attach, `misa.V`, AVX-like memcpy | `agents/guides/AGENTS-vector.md` | `#ext:v` (I-9), `#_vector_extension_overview`, `#memorymodel` | `core/acc_dispatcher.sv`, `core/csr_regfile.sv` (`misa.V`), `corev_apu/src/g6lc_ara_attach.sv`, `vendor/ara/` |
| Vendored uncore controllers/PHY (DDR4, PCIe, Ethernet, HDMI, SATA/SD), `vendor sync/scan`, `corev_apu` integration | `agents/guides/AGENTS-controller-readiness.md` | (not ISA-normative; see `AGENTS-vendor.md` + `architecture/uncore/*`) | `build-platform/src/config/defaults.ts`, `build-platform/src/tooling/vendor.ts`, `corev_apu/src/ariane.sv:67-68`, `core/include/config_pkg.sv` |
| **Foundry PDK / technology optimization**, memory compilers, tech-cell macros, ASIC tape-out mapping | `agents/guides/AGENTS-technology-optimization.md` (+ `AGENTS-technology.md`) | (not ISA-normative; PDK-swap seam) | `vendor/pulp-platform/tech_cells_generic/src/rtl/{tc_sram.sv,tc_clk.sv}`, `common/local/util/sram_cache.sv`, `pd/synth/Makefile`, `pd/pdk/` |
| **Build / test / probe / verify / toolchain** | `AGENTS-build.md` → `build-platform/AGENTS.md` | (tooling; not ISA) | `build-platform/`, `.config.ts`, `build.sh` / `build.ps1` |
| **Structural FO4 timing / auto-correct** (`sv-timing`) | `sv-timing/AGENTS.md` (+ `AGENTS-host.md`, `architecture/DESIGN.md`) | (not ISA; not STA sign-off) | `sv-timing/crates/*`, host `build-platform/src/tooling/timings.ts` |

---

## 4. Development patterns (deduced from the codebase)

CVA6 is parametrized IP with **configuration as the single source of truth**. Every module is
elaborated against one `config_pkg::cva6_cfg_t CVA6Cfg` object; feature bits and microarchitectural
enums inside that struct gate everything. A feature is "enabled" by extending the struct and the
per-target packages, not by editing modules ad hoc. Modules additionally receive structural types
via `parameter type ...` injection to break package dependency cycles, and every port is annotated
with its producing/consuming stage (`SUBSYSTEM`, `CONTROLLER`, `COMMIT`, `EXECUTE`, `CSR`, `CACHES`,
`ID_STAGE`) so inter-stage contracts are readable in-source. Design docs mirror the pipeline under
`docs/03_cva6_design/`. The single most important rule for edits: **change behavior through the
config struct and its `check_cfg` assertions first, then in the gated module**.

Config knobs that gate the four domains (all in `core/include/config_pkg.sv`):

| Knob | Line | Meaning / domain |
|---|---|---|
| `cache_type_t` enum (`WB,WT,HPDCACHE_*`) | 30-36 | Selects D$ subsystem (CACHE) |
| `bp_type_t` enum (`BHT,PH_BHT`) | 39-42 | Branch predictor kind (BP) |
| `vm_mode_t` enum (`ModeSv32/39/48/57`) | 45-52 | Virtual-memory mode (RAM/MMU) |
| `DCacheType` | 186 | Concrete D$ selection (CACHE) |
| `Icache{ByteSize,SetAssoc,LineWidth}` | 180-184 | I$ geometry (CACHE) |
| `Dcache{ByteSize,SetAssoc,LineWidth}` | 190-194 | D$ geometry (CACHE) |
| `DcacheFlushOnFence{,I}`, `DcacheInvalidateOnFlush` | 213-215 | Coherence policy; see rationale 195-212 (CACHE/RAM) |
| `WtDcacheWbufDepth` | 219 | WT write-buffer depth (CACHE/SPEC) |
| `NrScoreboardEntries` | 241 | In-flight window (SPEC) |
| `NrLoadBufEntries`, `MaxOutstandingStores` | 243,245 | Memory speculation depth (SPEC/RAM) |
| `RASDepth`, `BTBEntries`, `BPType`, `BHTEntries`, `BHTHist` | 247-255 | Predictor sizing (BP) |
| `InstrTlbEntries`, `DataTlbEntries` | 257-258 | TLB sizing (RAM) |
| `Axi{Addr,Data,Id,User}Width` | 168-176 | Memory-side bus (CACHE/RAM) |
| `check_cfg(...)` asserts | 446-453 | Legality (`RASDepth>0`, power-of-two BTB/BHT, region-rule counts) |

Cache subsystem is selected structurally in `core/cva6.sv`: `DCacheType==WT` -> `wt_cache_subsystem`
(OpenPiton-compatible) at `1400-1449`; `HPDCACHE_*` -> `cva6_hpdcache_subsystem` at `1450-1515`;
else -> `std_cache_subsystem` (deprecated write-back) at `1516+`. All bind instance `i_cache_subsystem`.

---

## 5. Spec-to-code master map

**Branch prediction (microarchitectural; no normative section).** Spec constrains only control-transfer
semantics (JAL/JALR/branches in `#base`/`#rv32`), fetch fence `#ext:zifencei` (4.1), and optionally CFI
`#unpriv-cfi`/`#priv-cfi` and control-transfer records `#smctr` (6.8). Code: predictor structures in
`core/frontend/frontend.sv:71-91`, control-flow classification `frontend.sv:210-221` (branch->BHT,
call/return->RAS, jalr->BTB), resolution `frontend.sv:236-294`, mispredict `frontend.sv:308`; resolve in
`core/branch_unit.sv`. Sizing via `BPType/BTBEntries/BHTEntries/BHTHist/RASDepth`.

**L2/L3 cache.** Spec: RVWMO `#memorymodel` (3.1), PMA `#pma` (3.6), `Zic64b` 64-byte blocks
`#ext:zic64b` (4.15), CMOs `#cmo` (4.20), `Zicbom` via `RVZiCbom`. Code: L1 only in
`core/cache_subsystem/*`; selection `core/cva6.sv:1400-1560`. **There is no in-core L2/L3.** An L2/L3 is
added at the memory-side boundary behind the AXI adapters (`cache_subsystem/axi_adapter.sv`,
`wt_axi_adapter.sv`) or at the SoC layer in `corev_apu/` (the OpenPiton `wt_l15_adapter.sv` path already
hands off to an external L1.5/L2).

**RAM / memory.** Spec: address space `#sec:intro-memory` (1.4), PMA `#pma` (3.6), PMP `#pmp` (3.7),
paging `#sv39` (4.4) and Sv32/48/57. Code: `core/load_store_unit.sv`, `load_unit.sv`, `store_unit.sv`,
`store_buffer.sv`, MMU `core/cva6_mmu/`, PMP `core/pmp/`, memory-side `cache_subsystem/axi_adapter.sv`;
SoC RAM/boot `corev_apu/axi_mem_if/`, `corev_apu/bootrom/`. Config: `Axi*Width`, `*TlbEntries`,
cacheable/executable/non-idempotent region rules (see `check_cfg` 451-453).

**Speculative execution.** Spec: RVWMO `#memorymodel` (3.1), `#ext:zifencei` (4.1), LR/SC + AMO
`#ext:a` (5.1), `#ext:zawrs` (5.5), precise traps (Priv ch3). Code: prediction (frontend) ->
in-flight tracking `core/scoreboard.sv` -> in-order retire `core/commit_stage.sv` -> flush
`core/controller.sv` -> redirect via `resolved_branch_i` (`frontend.sv:48,308`); memory speculation in
`load_store_unit.sv`/`store_buffer.sv`. Config: `NrScoreboardEntries`, `NrLoadBufEntries`,
`MaxOutstandingStores`.

---

## 6. Linux / RISC-V `.dts` linkage

Device-tree properties are the SoC-visible contract of what the core implements; each maps to a
config knob and a spec anchor, and keeping the three aligned is the definition of "the spec is followed
properly" for bring-up. Use this when a feature must be visible to Linux.

For a working cross-validation procedure and the upstream Linux binding `compatible`/property
references, see `AGENTS-dts-validation.md` (maintained in lockstep with this table). Run
`build-platform/scripts/fetch-linux-dts.{sh,ps1}` to populate the git-ignored
`build-platform/workspace/linux-dts/` source used by that validation.

| `.dts` property (cpu / soc node) | Config knob | Spec anchor |
|---|---|---|
| `riscv,isa = "rv64imafdc..."` | extension bits `RVA/RVC/RVF/...` in `cva6_cfg_t` | Vol I base `#base`, extension chapters |
| `mmu-type = "riscv,sv39"` | `vm_mode_t`/MMU config | `#sv39` (4.4) |
| `i-cache-size`, `i-cache-block-size` | `Icache{ByteSize,LineWidth}` | `#ext:zic64b` (4.15), `#pma` (3.6) |
| `d-cache-size`, `d-cache-block-size` | `Dcache{ByteSize,LineWidth}` | `#ext:zic64b`, `#cmo` (4.20) |
| `next-level-cache = <&l2>` + `l2-cache { ... }` | (no in-core knob) external L2 integration | `#memorymodel` (3.1), `#pma` |
| `memory@<base> { reg = <...>; }` | `Axi*Width` + cacheable region rules | `#sec:intro-memory` (1.4), `#pma` |
| `clint@`, `plic@`, `timebase-frequency` | `corev_apu/clint`, `corev_apu/rv_plic` | Priv ch3 (CLINT/timers), interrupts |

For an L2/L3, the DT `l2-cache`/`next-level-cache` nodes must describe a cache instantiated in
`corev_apu/` (or external), since the core exposes only L1 + an AXI/L15 port.

---

## 7. Conventions for sub-files

Each `agents/spec/*.html` file contains, in order: a one-line canonical link to the anchor; a Logisplain
summary (cohesive paragraphs, no lists, balancing spec quotation, mechanical dissection, and conceptual
linkage); a **Pseudo-SystemVerilog synthesis notes** block giving the skeletal module/params/signals the
subchapter implies, cross-referenced to the real CVA6 locus; and a **CVA6 status** line (implemented /
partial / absent + `file:line`). Filenames are `riscv-spec-<Vol>-<X.y>-<slug>.html`
(e.g. `riscv-spec-II-3.6-pma.html`). Guides aggregate these and never restate them.

---

## 8. Status and backfill

First increment is **domain-first**: this guider, the spec `INDEX.md`, the four purpose guides, and an
exemplar batch of `agents/spec/*.html` for the subchapters the four domains touch. Remaining subchapters
(~150) are enumerated in `agents/spec/INDEX.md` with status `pending` and are backfilled in later passes
without changing this file's structure. When adding a sub-file, update its row in `INDEX.md` only.
