# mbgen architecture

Notes for the independent builder at `E:\cva6\mbgen`. Not RTL. This directory is the source of truth for continuing the work outside any one editor session.

| Note | Subject |
|---|---|
| `board-types.md` | Outlines (Mini-ITX / mATX / ATX / Pico-ITX / PCIe card) vs the shared simulation kernel |
| `pin-circuits.md` | Pin types, nets, pathfinder, vendor freeze, Unreal live sim, PR 1–10 plan |
| `live-sim.md` | CATIA nav, rest plane, Place/Turn, chrome/sqlite, DiagnoseNav |
| `build.md` | cargo, mbcore_c DLL, UBT, editor launch, ready markers |
| `progress.md` | Landed vs deferred vs next leftover (v1) |
| `board-workspace.md` | **Successor plan**: generated profiles, one nav law, monotonic identity, revisioned session, verified ingest; stage status |

`Template` is the outline. Pin/net/path/gesture/library code is board-agnostic. Live Unreal routing loads `mbcore_c` (`cargo rustc -p mbcore_c -- -C panic=abort`); UBT does not build that crate. `LiveRouting` defaults off. USB Type-A is a pinless D-gap; the CPU socket is an unnamed land grid.

v1 live sim landed on `E:\cva6` `master` (`df9aff1`). Deferred pinouts stay in `pin-circuits.md`.
