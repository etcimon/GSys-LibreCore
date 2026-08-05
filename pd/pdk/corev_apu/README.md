# `pd/pdk/corev_apu/` — Protected UNCORE (corev_apu) technology drop-in

Protected, **git-ignored** drop-in for technology adaptations of the SoC /
integration layer around the core (`corev_apu/`). Only this README and the
sibling `.gitignore` are tracked; foundry / NDA content placed here stays local
and is consumed only at synthesis / PnR behind the guard macro.

## What lands here

Macro-protected, technology-specific views for uncore blocks, dropped as
`pd/pdk/corev_apu/<technology>/…`. Typical uncore adaptation targets:

- **DRAM/HBM PHY + controller memories** — the analog/hard PHY is foundry/vendor
  IP (see `AGENTS-vendor.md`, `AGENTS-core-platform-vendor-actives.md`); controller
  RAMs go through `tc_sram`.
- **PLL / clocking / reset** — hard PLL macro + clock cells at the `corev_apu`
  clock/reset seam (`AGENTS-corev-apu.md`).
- **IO pads / level-shifters** — pad-ring + `tc_pwr_*` cells at the die boundary.
- **Boot ROM / scratchpad / AXI memory** — `corev_apu/bootrom/`,
  `corev_apu/axi_mem_if/` arrays mapped to compiled macros.

## How it is scoped

An uncore block is opted into the pass with a **`*.tech-spec.md`** doc under
`corev_apu/**` (glob: `corev_apu/**/*.tech-spec.md`). Because the uncore is where
controllers/PHY are integrated, coordinate with the vendor catalog
(`cva6-build vendor …`) and the uncore preconditions in `AGENTS-corev-apu.md`
(AXI seam, clock/reset/CDC, PHY-vs-controller split, DFT, flist/DTS).

## Guard + invariants

Adaptations are fenced behind `` `ifdef CVA6_TECH_OPT `` and must keep the AXI /
clock / reset contracts intact and equivalent to the generic path. Hard PHY /
PLL macros need their own placement region + power/clock plan (`AGENTS.md` §0.1).

See `../README.md` and `AGENTS-technology.md`.
