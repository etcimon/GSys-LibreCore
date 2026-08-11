# CVA6 Motherboard Guider (corev-mb)

This is the entry point for **board-level** work: designing, selecting, and
tethering a motherboard to CVA6 core/uncore development. It is the PCB
counterpart to `AGENTS-corev-apu.md` (the die/uncore) and sits under the same
SoC prime directive as `AGENTS.md` §0.

- **`core/`** is the CPU. **`corev_apu/`** is the die/uncore around it.
- **`corev-mb/`** is the **board** the die sits on — the new layer this guide governs.
- One board is **active at a time**; selecting it adapts the whole build.

> ### Scaffold contract (read first)
> - **Nothing under `corev-mb/architecture/` is compiled.** Like `architecture/`, it is a
>   `.md`-only blueprint: it cannot break elaboration, simulation, synthesis, or tape-out.
> - **Generated RTL is not committed and not in any flist.** `mb select` writes
>   `corev-mb/boards/<id>/generated/<id>_board_pkg.sv` into a **gitignored** dir. Promoting it
>   into a real board top-level under `corev_apu/fpga/src` is a deliberate, gated step.
> - **No implicit network, no implicit fetch.** pcbparts.dev is only reached with `--online`;
>   vendor controllers are only fetched by an explicit `mb select` / `vendor sync`.

---

## 0. North star — a unified "SoC + MB configure" step

Selecting a board is meant to feel like one hardware **configure** step that spans the die and
the board: it adapts the core config, enables the right uncore controllers, fetches the vendor
IP, and lays down the board parameterization — from a single machine-readable spec. The same
step must degrade cleanly when the PCB is *not* ours to author (a third-party dev board) or does
not exist yet (a brand-new custom board).

```
              board.json  ──►  mb select <id>  ──►  overlay (.config.local.ts)  ──►  build/test
                    │                 │                     │
                    │                 ├─► vendor sync (uncore controllers)
                    │                 └─► generated/<id>_board_pkg.sv + board.mk
                    │
   architecture/<id>/README.md  (the development target: what/why, PHYs, gates)
   AGENTS-mb-<id>.md            (the per-board contract + checklist)
```

---

## 1. Directory layout

```
corev-mb/
  README.md
  .gitignore                      # generated/ + outputs/ are reproducible → untracked
  architecture/                   # .md-only development targets (NON-COMPILED scaffold)
    README.md                     # taxonomy + promotion path
    genesys2/README.md            # reference board target (implemented)
    bpi-f3/README.md              # analysis-only (SpacemiT K1) — described, not included
    milkv-jupiter/README.md       # analysis-only (SpacemiT K1) — described, not included
    milkv-titan/README.md         # analysis-only (SpacemiT M1) — described, not included
  boards/
    <id>/
      board.json                  # THE machine spec the CLI consumes (source of truth)
      design.py                   # SKiDL entry — custom boards only (omitted otherwise)
      generated/                  # board_pkg.sv + board.mk  (gitignored, from `mb select`)
      outputs/                    # netlist / BOM / ERC      (gitignored, from `mb design`)
  lib/                            # flat Python modules for the SKiDL flow + MCP client
```

Roots are configurable (`motherboard.boardsRoot`, `motherboard.architectureRoot`,
`motherboard.libRoot` in `build-platform/src/config/schema.ts`).

---

## 2. The `mb` command (build-platform)

`mb` is a first-class build-platform command (`build-platform/src/cli/commands/mb.ts`).

| Subcommand | What it does |
|---|---|
| `mb list` | Enumerate boards: **selectable** (has `board.json`) vs **documented-only** (architecture target, not yet included). |
| `mb select <id>` | The configure step: adapt `soc.*` to the board (via overlay), `vendor sync` its controllers, generate the board package + `board.mk`. |
| `mb check [id]` | Report CPU⇄board compatibility + which required controllers are checked out. No writes. |
| `mb create <id>` | Scaffold a new **custom** board (`board.json` [+ `design.py`]). |
| `mb design <id>` | Run the SKiDL schematic (custom boards only): ERC + netlist/BOM. `--online` enables pcbparts.dev, `--fix` runs the alternatives loop. |
| `mb expand <id> --add usb_host:2,pcie_x1:1` | Add interfaces; with `--online`, query PHYs. Re-run `mb select` to regenerate. |
| `mb parts --query "…" [--online]` | One-off pcbparts.dev search. |
| `mb test [id]` | Report/verify the **tandem** core+board feature set; `--run` drives `make verilate target=<coreConfig>`. |

Flags: `--online` (allow pcbparts.dev network), `--fix`, `--add`, `--query`, `--tool`,
`--no-adapt` / `--no-vendor` (scope `select`), `--dry-run`, `--json`.

---

## 3. `board.json` — the source of truth

`corev-mb/boards/<id>/board.json` is validated by `build-platform/src/tooling/motherboard.ts`.
Key fields:

- **`status`**: `reference` | `analysis` | `third-party` | `custom`.
- **`class`**: `fpga` | `asic-soc` | `custom`.
- **`skidl`**: `omitted` (no PCB authored — third-party/dev board) | `reference` (study an OSHW
  board read-only) | `custom` (design it in-tree with SKiDL; the only mode `mb design` runs).
- **`core`**: `{ config, xlen, extensions[], isaString }` — the CVA6 target config the board
  requires. This is the lever that **parameterizes the core**: `mb select` pins `soc.coreConfig`
  to it, so the existing per-target config packages (`core/include/cv*_config_pkg.sv`) drive
  elaboration. No RTL is hand-edited.
- **`apu`**: `{ axiDataWidth, noc, socket{enabled,type}, controllers[]{id,variant,enable,note} }` —
  which uncore controllers (from the `vendor` catalog) to fetch/enable, and whether the board is
  **socketed** (a PCB physical option; the RTL signal names are identical either way).
- **`interfaces[]`**: `{ id, domain, kind, controller?, phy?, count?, notes? }` — the board ports.
- **`phys[]`**: `{ ref, interface, mpn?, vendor?, package?, datasheet?, license?, status, mcp{tool,query} }` —
  the board PHYs and how to (re)discover them on pcbparts.dev.
- **`references`**: `{ spec[], vendorDocs[], oshwBoard }` — spec anchors + **licensed vendor
  documentation** references (kept as citations, never copied in violation of a license).
- **`ai` (optional)**: AI island / UIO host path. When present and not `enabled:false`, `mb select`
  emits board-local DTS fragment, ai-tensor profile TOML, `ai-tensor.env`, and `MbAi_*` package
  localparams. Schema and defaults live in `build-platform/src/tooling/ai-board.ts`
  (`AI_BOARD_DEFAULTS`: MMIO `0x40000000`, PLIC 8, AccTile 256). `uioConnectors` is an object
  **keyed by connector id** (`uio-mmio` / `eventfd` / …). Example board: `corev-mb/boards/ai-card/`.
  Host contract: `architecture/ai-matrix/board-uio-eventfd.md` §6. Scaffold with
  `mb create <id> --ai`. Genesys2 omits `ai` and keeps `MbAi_En=0`.

---

## 4. Parameterization handshake (core / corev_apu ⇄ board)

- **CPU → board (preconditions):** `board.json.core` states the required config/xlen/extensions.
  `mb check` compares them to the active `.config.ts`; `mb select` adapts them via the overlay.
- **Board → CPU/uncore (enables):** `board.json.apu.controllers[].enable` selects vendor
  controllers; `mb select` runs `vendor sync` on them. `board.json.interfaces`/`phys` drive the
  generated `<id>_board_pkg.sv` (localparams: `MbCtrl_*_En`, `MbIf_*_En/Count/Phy`, `SocketEn`,
  `AxiDataWidth`, …). That package is a **non-compiled scaffold** until promoted.
- **Promotion (manual, gated):** to actually wire a board in, add a board top-level under
  `corev_apu/fpga/src` that imports the generated package, register it in the FPGA flist, and
  pass the full §5 gate. `mb select` never edits `core/` or `corev_apu/src/ariane.sv`.

This honours `AGENTS.md` §0.2 (config-gated, synth-clean, backend-friendly) and §0.3 (no
hard-coding a feature into a module).

---

## 5. SoC-readiness gates for board work

A board change is only "done" when, in addition to `AGENTS.md` §0.2:

- **Core/uncore untouched by selection** — parameterization flows through config + the generated
  package, not by editing pipeline/`corev_apu` RTL.
- **PHY split is explicit** — controller (on-die) vs PHY (board) is stated per interface; PHYs are
  board decisions selected from pcbparts.dev, never vendored as RTL.
- **Licensed docs are cited, not copied** — vendor datasheets/manuals are referenced in
  `references.vendorDocs`; no NDA/paywalled content is committed.
- **`.dts` ↔ config ↔ spec alignment** — any interface that Linux must see maps to a device-tree
  node consistent with the core config (`AGENTS-dts-validation.md`).
- **Signal/power integrity noted** — for `custom` boards, ERC must pass; add SI/PI and
  power-sequencing notes for high-speed lanes (DDR/PCIe/USB/Ethernet).
- **Reproducible** — generated artifacts come only from `board.json` + the tools; nothing hand-patched.

---

## 6. pcbparts.dev MCP tools

The board flow uses all 14 tools (HTTP MCP at `https://pcbparts.dev/mcp`, no API key). Clients:
`build-platform/src/tooling/pcbparts.ts` (TS) and `corev-mb/lib/pcbparts_mcp.py` (Python), both
cache-first and network-gated.

| Tool | Board-flow use |
|---|---|
| `jlc_search` | Find candidate PHYs/connectors/regulators for an interface. |
| `jlc_stock_check` | Verify BOM stock before freezing outputs. |
| `jlc_get_part` | Pull MPN metadata, datasheet, footprint. |
| `jlc_get_pinout` | Check pin assignment against the SoC pinmap. |
| `jlc_find_alternatives` | Replace an ERC-failing / out-of-stock part. |
| `jlc_search_help` | Discover filters for an unfamiliar category. |
| `sensor_recommend` | Add power/thermal/environment sensors during expansion. |
| `board_search` | Find OSHW reference boards with a similar SoC/interface set. |
| `board_get` | Pull a reference board BOM, neighborhoods, design rules. |
| `mouser_get_part` / `digikey_get_part` | Cross-reference stock/pricing/datasheets. |
| `cse_search` | Find ECAD models + datasheets. |
| `cse_get_kicad` | Download KiCad symbol/footprint for SKiDL. |
| `get_design_rules` | Apply stackup/clearance/class rules to the design + constraints. |

---

## 7. Iterative design cycle (custom boards)

1. `mb create <id>` → edit `board.json`, write `architecture/<id>/README.md`.
2. `mb select <id>` → adapt config, sync vendor IP, generate the board package.
3. `mb design <id> --online` → build scaffold, run **ERC**.
4. Read ERC → `jlc_find_alternatives` / `jlc_get_pinout` / `cse_get_kicad` → fix → repeat
   (`--fix` automates a bounded loop; `motherboard.pcbParts.maxFixIterations`).
5. `mb expand <id> --add pcie_x1:1,usb_host:2 --online` → grow the design, re-`select`.
6. `mb test <id>` → verify the **tandem** core+board feature set; `--run` drives the RTL build.

For **third-party** boards (e.g. `genesys2`) skip steps 3-5: `mb select` alone configures the
core/uncore; the PCB schematic is `omitted`.

The **design-philosophy** for this phase — how to pick parts with pcbparts.dev, plan power rails,
map SoC pins to PHYs, and lay out an accurate, manufacturable board in SKiDL — is
`AGENTS-mb-skidl.md` (the PCB counterpart to `AGENTS-coding-philosophy.md`). Follow it whenever
`board.json` has `"skidl":"custom"`.

---

## 8. Per-board `AGENTS-mb-<id>.md`

Each selectable board has a root-level `AGENTS-mb-<id>.md` — the human contract + checklist that
tethers board and CPU work. It cross-references `board.json` (machine truth) and
`corev-mb/architecture/<id>/README.md` (the target). See `AGENTS-mb-genesys2.md` for the pattern.

> **Naming note:** `AGENTS-mb-skidl.md` is the exception — it is the board-**design philosophy**
> (§7), not a board contract. There is no `corev-mb/boards/skidl/`; `skidl` is never a `boardid`.

---

## 9. Licensing & governance

- **Code** (`build-platform/**` TS, `corev-mb/lib/**` Python, generated `*_board_pkg.sv`) is in
  licensing scope → LicenseRef-Proprietary © Etienne Cimon per `.licensing-policy` (see `AGENTS-licensing.md`).
- **Docs** (`AGENTS-motherboard.md`, `AGENTS-mb-*.md`, `corev-mb/**/*.md`) are `.md` → out of
  scope per `AGENTS.md` §0.4.
- Vendor controller RTL keeps its **upstream** license; vendor datasheets are **cited**, not copied.
- This guide is co-equal with the other standing disciplines and subordinate to `AGENTS.md` §0.
