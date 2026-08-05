# corev-mb/lib — SKiDL design flow + pcbparts.dev client

Flat Python modules (no package name, because `corev-mb` has a hyphen). The
build-platform `mb design` command puts this directory on `PYTHONPATH`, and a
generated `design.py` also bootstraps `sys.path`, so either invocation works.

| Module | Role |
|---|---|
| `pcbparts_mcp.py` | Dependency-free MCP client for pcbparts.dev (mirrors `build-platform/src/tooling/pcbparts.ts`). Cache-first, network only when `PCBPARTS_ALLOW_NETWORK=1`. |
| `interfaces.py` | SKiDL interface templates built "from scratch" (no external KiCad lib needed to import). |
| `soc.py` | `build_board(boardid)` — load `board.json`, assemble a scaffold circuit, run ERC, emit netlist + BOM. |
| `erc.py` | `run_erc()` — wraps `skidl.ERC()` and captures messages for the fix loop. |

## When this runs

Only for **custom** boards (`"skidl": "custom"` in `board.json`). Third-party
and reference boards (e.g. `genesys2`) set `"skidl": "omitted"` and never touch
this code — `mb select` still configures the core/uncore for them.

## Environment (exported by `mb design`)

- `CVA6_REPO_DIR` — repo root (used to locate `board.json`).
- `CVA6_MB_BOARD` — active board id.
- `CVA6_MB_OUTPUTS` — output dir for netlist/BOM.
- `PCBPARTS_MCP_URL`, `PCBPARTS_CACHE_DIR`, `PCBPARTS_ALLOW_NETWORK` — MCP client.
- `ERC_FIX`, `ERC_MAX_ITER` — ERC → alternatives fix loop.

## Design loop

1. `build_board` assembles a scaffold from `board.json` interfaces.
2. `run_erc()` reports errors/warnings.
3. With `ERC_FIX=1 --online`, `soc._attempt_fixes` queries `jlc_find_alternatives`
   for the declared PHYs.
4. Refine `interfaces.py` / `board.json` with real footprints
   (`cse_get_kicad`, `jlc_get_pinout`) and repeat.

Install: `pip install -r corev-mb/lib/requirements.txt` (only `skidl`; the MCP
client is stdlib-only).

## Design philosophy

How to actually pick parts, plan power rails, map SoC pins to PHYs, and lay out
an accurate/manufacturable board with these modules is in **`AGENTS-mb-skidl.md`**
(repo root) — the PCB counterpart to `AGENTS-coding-philosophy.md`. Read it before
authoring a `custom` board's `design.py`.
