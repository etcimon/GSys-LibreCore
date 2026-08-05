# `pd/pdk/core/` — Protected CORE technology drop-in

Protected, **git-ignored** drop-in for technology adaptations of the CVA6 **core
pipeline IP** (`core/`). Only this README and the sibling `.gitignore` are
tracked; any foundry / NDA content placed here stays local and is consumed only
at synthesis / PnR behind the guard macro.

## What lands here

Macro-protected, technology-specific wrappers/views for core memory arrays and
special cells, generated/dropped as `pd/pdk/core/<technology>/…`. Typical core
adaptation targets and the seams they bind to:

- **L1 I$/D$ + HPDcache SRAMs** — `common/local/util/sram_cache.sv` (`TECHNO_CUT`),
  `tc_sram` (`ImplKey`), and the HPDcache `behav`/`blackbox`/`<tech>` macros under
  `core/cache_subsystem/hpdcache/rtl/src/common/macros/`.
- **Register file / small arrays** — `tc_sram` or flop-based, per macro-vs-flop
  trade-off in the target library.
- **Integrated clock gating** — `tc_clk_gating` (`IS_FUNCTIONAL`) mapped to the
  library ICG (e.g. inside `core/cva6_fifo_v3.sv`).
- **Retention / isolation / level-shifters** — `tc_pwr_*` mapped to power-kit cells
  where a core power domain is retained.

## How it is scoped

A core block is opted into the pass by placing a **`*.tech-spec.md`** doc next to
it under `core/**` (glob: `core/**/*.tech-spec.md`). That doc states the block, the
seam, the target macro geometry, and the SoC-readiness expectations. List detected
docs with `cva6-build tech specs`; preview the plan with `cva6-build tech plan`.

## Guard + invariants

Every adaptation is fenced behind `` `ifdef CVA6_TECH_OPT `` (config
`technology.guardMacro`), so the generic path is unchanged when the macro is
undefined. The wrapper **must** be port-/latency-equivalent to the generic
`tc_sram`/cell so simulation matches silicon (`AGENTS.md` §0.2, §0.3).

See `../README.md` and `AGENTS-technology.md`.
