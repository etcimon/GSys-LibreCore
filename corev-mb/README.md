# corev-mb — the CVA6 motherboard layer

`corev-mb` is the **board** around the die. Where `core/` is the CPU and
`corev_apu/` is the uncore/die, `corev-mb/` describes and (for custom boards)
designs the PCB the SoC lands on, and tethers that to core/uncore development.

Governing guide: **`AGENTS-motherboard.md`** (root). Per-board contracts:
**`AGENTS-mb-<id>.md`** (root).

## Layout

| Path | What |
|---|---|
| `architecture/` | `.md`-only **development targets** (non-compiled scaffold). One dir per board. |
| `boards/<id>/board.json` | The machine spec the `mb` command consumes (source of truth). |
| `boards/<id>/design.py` | SKiDL entry — **custom** boards only. |
| `boards/<id>/generated/` | `board_pkg.sv` + `board.mk` from `mb select` (gitignored). |
| `boards/<id>/outputs/` | netlist / BOM / ERC from `mb design` (gitignored). |
| `lib/` | flat Python modules: SKiDL flow + pcbparts.dev MCP client. |

## One-liners

```bash
cva6-build mb list                 # boards: selectable vs documented-only
cva6-build mb select genesys2      # configure step: adapt core, sync uncore IP, generate board pkg
cva6-build mb check genesys2       # CPU⇄board compatibility (no writes)
cva6-build mb create my-board      # scaffold a new custom board
cva6-build mb design my-board --online --fix   # SKiDL ERC loop via pcbparts.dev
cva6-build mb test genesys2        # tandem core+board feature set
```

## Included vs documented

- **Included / selectable:** has a `board.json` (e.g. `genesys2`).
- **Documented-only:** an `architecture/<id>/` target that is analyzed but **not yet included**
  (e.g. `bpi-f3`, `milkv-jupiter`, `milkv-titan`). Study them; promote when ready.

Nothing here is compiled or fetched implicitly — see the scaffold contract in `AGENTS-motherboard.md`.
