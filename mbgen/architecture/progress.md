# Progress

How to continue this tree without a Grok session. Hunt remaining **real** live-sim bugs. Do not re-plan pin-circuits. Do not invent deferred pinouts.

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

- Empty-click rest-plane **rim**: cursor off the PCB clamps to the 1.5× pad corner; look then aims at that corner (FOV 90 makes the board leave the centre fast). Options: pick along camera forward when the cursor is off-pad, or lower editor FOV toward the product 55° shots. Measure with DiagnoseNav (`cursor_rim`, `look_moved`).
- `HitWorldOnBoard` remains an unbounded PCB-top plane for **Place** (mbcore still rejects off-board). Nav must keep using `HitDeskWorld`.
- Dual-source: keep `mbcompiler/src/unreal.rs` `include_str!` in lockstep with live C++/Python.
- After C++: stop the editor, `cargo test --workspace`, UBT, relaunch, wait for `mbgen dll=mbcore_c` and `mbgen frame`.

## Verify a change

See `build.md`. Mini-ITX happy path: `mbgen dll=mbcore_c`, `mbgen frame 170 170 2`, product sections=22, placed sections=144, `mbgen board capture wrote`, DiagnoseNav `recede=0` `look_moved=0`.
