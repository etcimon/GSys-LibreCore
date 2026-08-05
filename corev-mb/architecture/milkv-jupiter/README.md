# milkv-jupiter — development target (analysis-only, NOT included at this stage)

Milk-V Jupiter, a **Mini-ITX** RISC-V board built on the **SpacemiT K1/M1** (8×
X60, RVA22 + RVV 1.0). Studied to derive a desktop-form-factor CVA6 board target.
**No `board.json` is committed** — documented target only.

> **Status: analysis-only.** Public Milk-V/SpacemiT documentation; confirm via pcbparts.dev
> (`board_search`/`board_get`) and vendor datasheets before promotion. Nothing here is compiled.

## 1. Intent

Jupiter is the "desktop" expression of the K1/M1: Mini-ITX, standard PC connectors, PCIe slot +
M.2. It is the best template for a **socketed / desktop-class** CVA6 board (`apu.socket.enabled`),
so this target focuses on the interconnect/expansion surface a PC-like board needs.

## 2. Reference feature set (per public docs — confirm before use)

| Domain | Jupiter / K1-M1 reference |
|---|---|
| Compute | 8× X60, RVA22, RVV 1.0 |
| Memory | LPDDR4/4x (down to board; up to 16 GB) |
| PCIe | PCIe x4 slot + M.2 (NVMe / Wi-Fi) |
| Networking | 2× GbE |
| USB | USB 3.0 ×n + USB 2.0 |
| Display | HDMI |
| Storage | eMMC, microSD, M.2 NVMe |
| Form factor | Mini-ITX (PC PSU / case compatible) |

## 3. Core preconditions (target `CVA6Cfg`) — and the honest delta

Same base mapping as `bpi-f3` (`cv64a6_imafdc_sv39` as the realistic first target). Additional
Mini-ITX implications:

| Requirement | CVA6 today | Gap |
|---|---|---|
| PCIe root complex (x4 + M.2) | `verilog-pcie`/`litepcie` planned | integration + SerDes/hard-IP |
| Desktop boot (SPI-NOR + PC-style) | SPI present | boot flow/OpenSBI board port |
| RVV 1.0 / 8-core | absent / single-core | `architecture/spec-extensions/`, `architecture/multi-core/` |

## 4. Uncore mapping (interface → controller → PHY)

| Interface | Candidate controller | Split |
|---|---|---|
| LPDDR4 | `litedram` (needs LPDDR4 variant) | PHY = hard macro (gap on ASIC) |
| PCIe x4 + M.2 | `verilog-pcie` / `litepcie` | glue on-die; SerDes hard IP; NVMe/Wi-Fi are endpoints |
| GbE ×2 | `verilog-ethernet` / `liteeth` | MAC on-die; PHY external |
| USB 3.0 | *(none catalogued)* | **gap** |
| HDMI | `hdmi` | encoder on-die; connector/re-driver on board |
| NVMe | via PCIe | endpoint over the PCIe root |

## 5. PHY / expansion plan (pcbparts.dev)

`board_search "milk-v jupiter"` / `board_search "mini-itx risc-v"` → `board_get` for the
neighborhoods + design rules; `get_design_rules class=…` for a PCIe-capable stackup;
`jlc_search "M.2 key-M connector"`, `jlc_search "PCIe x4 slot"`.

## 6. Gaps vs CVA6 today (summary)

PCIe integration, LPDDR4 PHY, USB3 controller, RVV, and multi-core are the blocking deltas for a
faithful reproduction. A first CVA6 Jupiter-class board would expose a scalar single-core SoC over
the same board interconnect, with vector/SMP marked as gaps.

## 7. Promotion gates (to become selectable)

1. Choose the socket vs soldered decision (Jupiter favours **socketed/desktop** — set
   `apu.socket.enabled` when promoted).
2. Confirm interconnect (PCIe lanes, M.2 keys) via `board_get` + vendor docs.
3. Add `board.json` + `AGENTS-mb-milkv-jupiter.md` scoped to what CVA6 can drive.
4. Pass `AGENTS-motherboard.md` §5 (incl. PCIe SI/PI + power-sequencing notes).
