# Progress

How to continue this tree without a Grok session. Hunt remaining **real** live-sim bugs. Do not invent deferred pinouts.

> **2026-10-15:** the "do not re-plan pin-circuits" rule is superseded by the approved successor
> plan — see `board-workspace.md`. v1 notes below stay as history. The "next leftover" rim clamp is
> **resolved** (`nav::pick_nav_pivot`, shared through `mb_nav_pick_pivot` to both hosts).

## Landed (`E:\cva6` master `df9aff1`)

PR 1–10 in `pin-circuits.md` plus post-plan UI:

- XY `Place` / `Turn` `yaw_q`, arrow keys 1 mm / 0.1 mm
- CATIA nav, mathematical rest plane, `PinView` look-at on the pick
- Chrome + sqlite undo/save/copy; undo keeps the camera
- `FindLive`, GAP badges, `mb_anchors`, first-open thumbs, SetOutline, compile keeps the editable preview
- DiagnoseNav through the editor viewport (`Saved/mbgen-navdiag.json` / `.png`)

## Deferred (do not invent)

From `pin-circuits.md`:

- USB Type-A / CPU socket named pinouts; HDMI/LAN mesh contacts until freeze+footprint
- Off-edge XY (parts stay on the PCB AABB)
- Rail `Path` strips until a Footprint exists; A* only for 2-pin pad XY
- DIMM/NVMe EasyEDA freeze files (cache miss)
- `LiveRouting` default stays off; coarsen-to-500 µm drag preview; Niagara GPU hits
- `board.net` sexp stays a sketch; `g6lc_bios` is not edited here
- Card-edge CEM pinout; invented USB/MMIO/PHY identities

## Next leftover (in scope)

- ~~Empty-click rest-plane **rim**~~ — resolved: the pivot is the desk hit when inside the pad, else a point **on the cursor ray** at the last focus depth (`mbcore::pick_nav_pivot`). The old clamp survives only as the `desk=` / `cursor=` columns of DiagnoseNav, which now runs only as a CallInEditor command (never on a click).
- `HitWorldOnBoard` remains an unbounded PCB-top plane for **Place** (mbcore still rejects off-board). Nav uses `NavPickPivotWorld`, not `HitDeskWorld`.
- Dual-source: keep `mbcompiler/src/unreal.rs` `include_str!` in lockstep with live C++/Python.
- After C++: stop the editor, `cargo test --workspace`, UBT, relaunch, wait for `mbgen dll=mbcore_c` and `mbgen frame`.

## Verify a change

See `build.md`. Mini-ITX happy path: `mbgen dll=mbcore_c`, `mbgen nav=mbcore_c`, `mbgen frame 170 170 2`, product sections=22, placed sections=144, `mbgen board capture wrote`, DiagnoseNav (command) `recede=0` `look_moved=0`. A `mbgen nav=local (reduced …)` line means the DLL predates ABI v2 — rebuild it.
