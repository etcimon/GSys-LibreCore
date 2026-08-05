# corev-mb/architecture — board development targets

This tree is a **scaffold and blueprint**, not RTL and not a netlist. Each
subdirectory is a per-board **development architectural target**: the features a
board reproduces, the core/uncore preconditions it imposes, the controller↔PHY
split, and the gates it must pass before it is promoted from "documented" to
"selectable" (has a `board.json`) and finally "integrated" (wired into a flist).

> ### Scaffold contract (read first)
> - **Nothing here is compiled.** No file under `corev-mb/architecture/` is referenced by any
>   flist, synthesis, or `pd/` script. These outlines cannot break the build.
> - **`.md` only** — out of licensing scope per `AGENTS.md` §0.4.
> - Cross-refs: `AGENTS-motherboard.md` (workflow), `AGENTS-corev-apu.md` (uncore),
>   `architecture/uncore/*.md` (per-domain controller outlines).

---

## Map

| Target | SoC | Status | Class | board.json? |
|---|---|---|---|---|
| `genesys2/` | CVA6 on Kintex-7 FPGA | reference (implemented) | fpga | yes → selectable |
| `bpi-f3/` | SpacemiT K1 (8× X60 RVA22 + RVV1.0) | analysis-only | asic-soc | no → documented |
| `milkv-jupiter/` | SpacemiT K1/M1 | analysis-only | asic-soc | no → documented |
| `milkv-titan/` | SpacemiT M1 | analysis-only | asic-soc | no → documented |

The three SpacemiT-class targets are **described but not included at this stage**: they are
studied here to derive feature sets and implementation considerations for a future CVA6-class
board, without committing a `board.json` (so they are not selectable/buildable yet).

---

## What each target contains

1. **Intent** — the board and why it is a useful CVA6 target.
2. **Reference feature set** — the interfaces/PHYs to reproduce (from public docs / OSHW).
3. **Core preconditions** — the `CVA6Cfg` target it would require (config, xlen, extensions, MMU).
4. **Uncore mapping** — which `vendor` controllers implement each interface, controller↔PHY split.
5. **PHY plan** — candidate parts + how to (re)discover them on pcbparts.dev.
6. **Gaps vs CVA6 today** — honest delta between the reference SoC and what CVA6 implements.
7. **Promotion gates** — what must be true to add a `board.json` and later integrate.

## Promotion path (documented → selectable → integrated)

1. **Documented** (this tree): the target README exists; no `board.json`.
2. **Selectable**: add `corev-mb/boards/<id>/board.json` (and `AGENTS-mb-<id>.md`). `mb select`
   now adapts config, syncs uncore IP, and generates the board package.
3. **Integrated**: add a board top-level under `corev_apu/fpga/src` importing the generated
   package, register it in the FPGA flist, and pass the `AGENTS-motherboard.md` §5 gate.

Custom (non-existent) boards start at step 2 directly via `mb create <id>` and use SKiDL.
