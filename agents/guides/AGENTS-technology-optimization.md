# Guide: Technology-optimization pass (agentic playbook)

**Cross-cutting guide.** How an agent runs the opt-in technology-optimization
pass end to end: bind a foundry's proprietary, high-level abstraction layers
(memory compilers, ICG / retention / level-shifter cells, power kits, hard
macros) at CVA6's PDK-swap seam, **behind a guard macro**, driven by a
**build-platform flag** + the **presence of `*.tech-spec.md` docs**, with the
proprietary PDK **omitted (NDA) and never committed**.

Governance: `AGENTS-technology.md`. Prime directive: `AGENTS.md` §0 +
`agents/guides/AGENTS-soc-readiness.md`. This guide is the *procedure*; that file
is the *contract*.

---

## When to run

Only when both ignition keys are (or are being) set: the build flag
`technology.optimizationPass: true` **and** a `*.tech-spec.md` doc under a scoped
`core/**` or `corev_apu/**` area. Otherwise the pass is inert — do nothing.

## Preconditions

- `pd/pdk/` protected root present (READMEs + `.gitignore` + `manifest.example.json`).
- A local PDK drop-in (`pd/pdk/<technology>/`) for a real synth/PnR run — or
  `pdkMode: "omitted"` for a plan-only / equivalence run.
- Never edit anything outside the protected roots except (a) a guarded RTL wrapper
  at a sanctioned seam and (b) the `*.tech-spec.md` scoping doc.

## The workflow (detect → author → plan → adapt → wire → verify → document)

1. **Detect.** `cva6-build tech status` (flag + PDK presence + arming), then
   `cva6-build tech specs` to see which blocks are scoped.
2. **Author the scoping doc.** Add a `*.tech-spec.md` next to the block to be
   optimized (template below). This is *key 2* and the human-readable intent.
3. **Plan.** `cva6-build tech plan` — read-only; prints, per doc, the seam, the
   guard macro, and the git-ignored output dir. **No RTL is edited by the tool.**
4. **Adapt behind the guard.** At the seam, add a `` `ifdef <guardMacro> `` branch
   that instantiates the technology wrapper; keep the `` `else `` (generic) branch
   intact and equivalent (worked example below). Prefer parameter/`generate`
   (`TECHNO_CUT`) for structure; use `` `ifdef `` only for the proprietary leaf.
5. **Wire the build.** Point the synth flow at the drop-in (`pd/synth/Makefile`:
   `FOUNDRY_PATH`/`TECH_NAME`/`LOCAL_LIB_PATH`), add `+define+<guardMacro>`, and
   select the leaf tech-cell file via the flist fragment (behav → blackbox →
   foundry macro). Simulation defines nothing and reads no PDK.
6. **Verify.** `cva6-build tech check` (hard gates) + the `AGENTS.md` §0.2
   carry-over checklist for the target library (equivalence, DFT/MBIST, timing,
   power/UPF, area). Keep the compliance regression green.
7. **Document.** Update the `*.tech-spec.md`, `pd/pdk/<technology>/manifest.json`
   (`socReadiness`), and the relevant area README.

## Template — `*.tech-spec.md`

```markdown
# Tech-spec: <block> for <technology>

- **Area:** core | corev_apu
- **Block / instance:** e.g. wt_dcache_mem data SRAM
- **Seam:** tc_sram (ImplKey) | sram_cache TECHNO_CUT | hpdcache macro | tc_clk_gating | tc_pwr
- **Guard macro:** CVA6_TECH_OPT
- **Target macro geometry:** words × width × ports × latency (+ byte-enable)
- **Drop-in:** pd/pdk/<area>/<technology>/...
- **Equivalence:** generic model this must match (ports, latency)
- **SoC-readiness:** MBIST/BISR, scan, timing target, power domain / retention, area budget
- **Notes / risks:** placement region, high-fanout, CDC, etc.
```

## Worked example — macro-protecting an SRAM at the seam

```systemverilog
// Guarded technology cut. Generic path (`else`) is byte-for-byte the OSS design.
`ifdef CVA6_TECH_OPT
  tech_sram_<technology>_1rw #(       // wrapper from pd/pdk/core/<technology>/ (gitignored)
    .NumWords (NumWords), .DataWidth (DataWidth)
  ) i_macro (
    .clk_i, .rst_ni, .req_i, .we_i, .be_i, .addr_i, .wdata_i, .rdata_o
  );
`else
  tc_sram #(                          // generic behavioural model (vendor/.../tc_sram.sv)
    .NumWords (NumWords), .DataWidth (DataWidth), .ByteWidth (8),
    .NumPorts (1), .Latency (1)
  ) i_generic (
    .clk_i, .rst_ni, .req_i, .we_i, .be_i, .addr_i, .wdata_i, .rdata_o
  );
`endif
```

The wrapper module lives **only** in the git-ignored `pd/pdk/<area>/<technology>/`
drop-in; it must expose the exact ports + latency of `tc_sram` so the two arms are
interchangeable (sim == silicon).

## Do

- Keep the guard at the leaf; keep the pipeline technology-agnostic.
- Make selection config-driven (`cva6_cfg_t` + `check_cfg`) where it is structural.
- Plan MBIST + scan for every macro; map ICG via `tc_clk_gating` (`IS_FUNCTIONAL`).
- Re-run STA + area/power per technology; record results in the manifest.

## Don't

- Commit any `.lib/.db/.lef/.gds`, cell deck, encrypted model, or filled-in manifest.
- Bake a specific vendor cell into pipeline RTL, or add an unguarded adaptation.
- Let the wrapper diverge from the generic model's ports/latency.
- Add a new clock/reset or lengthen a critical path without CDC/timing analysis.

## Cross-references

- `AGENTS-technology.md` (governance), `pd/pdk/README.md` (+ `core/`, `corev_apu/`).
- `AGENTS.md` §0.1(4) (PDK-swap seam), §0.2 (carry-over checklist), §0.3 (anti-patterns).
- `agents/guides/AGENTS-soc-readiness.md` §4 (backend), `AGENTS-corev-apu.md`, `AGENTS-vendor.md`.
- Seam code: `vendor/pulp-platform/tech_cells_generic/src/rtl/{tc_sram.sv,tc_clk.sv}`,
  `common/local/util/sram_cache.sv`, `pd/synth/Makefile`.
