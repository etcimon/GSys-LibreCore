# mbgen architecture

Scaffold notes for the independent builder at `E:\cva6\mbgen`. Not RTL.

| Note | Subject |
|---|---|
| `board-types.md` | Outlines (Mini-ITX / mATX / ATX / Pico-ITX / PCIe card) vs the shared simulation kernel |
| `pin-circuits.md` | Pin types, nets, pathfinder, vendor freeze, Unreal live sim, PR plan |

`Template` is the outline. Pin/net/path/gesture/library code is board-agnostic. Live Unreal routing loads `mbcore_c` (`cargo rustc -p mbcore_c -- -C panic=abort`); UBT does not build that crate. `LiveRouting` defaults off. USB Type-A is a pinless D-gap; the CPU socket is an unnamed land grid. v1 live sim is complete in the working tree (uncommitted); see `pin-circuits.md` deferred list.
