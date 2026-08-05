# bpi-f3 — development target (analysis-only, NOT included at this stage)

Banana Pi BPI-F3, built on the **SpacemiT K1** (8× SpacemiT X60 RISC-V, RVA22 +
RVV 1.0). This is studied to derive a CVA6-class board feature set and the
implementation deltas it implies. **No `board.json` is committed** — it is a
documented target, not selectable/buildable yet.

> **Status: analysis-only.** Figures below are from public BPI/SpacemiT documentation and should
> be re-confirmed via pcbparts.dev (`board_search`/`board_get`) and vendor datasheets before any
> promotion. Nothing here is compiled, fetched, or wired into a flist.

## 1. Intent

Understand what a desktop/SBC-class RISC-V board around the K1 exposes, then map each interface
to a CVA6 uncore controller + board PHY, and record honestly where CVA6 does not yet reach the
reference SoC's capability.

## 2. Reference feature set (per public docs — confirm before use)

| Domain | BPI-F3 / K1 reference |
|---|---|
| Compute | 8× X60, RVA22 profile, RVV 1.0, ~2 TOPS AI |
| Memory | LPDDR4/4x (2/4/8/16 GB) |
| PCIe | PCIe 2.1 (M.2) |
| USB | USB 3.0 + USB 2.0 |
| Networking | 2× GbE |
| Storage | eMMC, microSD, (SATA on some variants) |
| Display | HDMI, MIPI-DSI/CSI |
| Expansion | 40-pin GPIO header |

## 3. Core preconditions (target `CVA6Cfg`) — and the honest delta

A faithful reproduction would want an RVA22-class 64-bit config. Mapping to CVA6:

| Requirement | CVA6 today | Gap |
|---|---|---|
| RV64GC base | `cv64a6_imafdc_sv39` ✓ | none |
| Sv39 (min for RVA22) | ✓ | Sv48/Sv57 absent (RVA22 needs Sv39 only) |
| Zicbom/Zicboz/Zicbop (CMOs) | Zicbom present; Zicboz/Zicbop partial/absent | verify against `AGENTS-specs-to-impl.md` |
| RVV 1.0 (vector) | **not implemented** | see `architecture/spec-extensions/` |
| 8-core SMP | single core in-core | see `architecture/multi-core/` |

So a first CVA6 bring-up on a K1-class board would be **single-core, scalar** (`cv64a6_imafdc_sv39`),
explicitly *not* matching the K1's 8×vector compute — that delta is the point of this analysis.

## 4. Uncore mapping (interface → controller → PHY)

| Interface | Candidate controller (`vendor` id) | Controller/PHY split |
|---|---|---|
| LPDDR4 | `litedram` (DDR3/4 today) | **LPDDR4 PHY is a gap** — MIG/hard-PHY on ASIC; litedram needs an LPDDR4 variant |
| PCIe 2.1 | `verilog-pcie` / `litepcie` (planned) | glue on-die; SerDes = hard IP |
| USB 3.0 | *(none catalogued)* | **USB3 controller is a gap** |
| GbE ×2 | `verilog-ethernet` / `liteeth` | MAC on-die; PHY external |
| SATA | `litesata` | controller on-die; SerDes external |
| eMMC/SD | `litesdcard` | controller on-die; slot on board |
| HDMI | `hdmi` (TMDS) | encoder on-die; connector/re-driver on board |

## 5. PHY plan (pcbparts.dev)

Discover candidates without committing parts, e.g.:
`jlc_search "gigabit ethernet rgmii phy"`, `jlc_search "USB 3.0 hub controller"`,
`jlc_search "HDMI re-driver"`, `board_search "risc-v k1"` → `board_get` for a reference BOM.

## 6. Gaps vs CVA6 today (summary)

RVV, multi-core SMP, LPDDR4 PHY, and a USB3 controller are the blocking deltas. GbE, SATA, SD,
HDMI, and PCIe glue have catalogued controllers (mostly `planned`).

## 7. Promotion gates (to become selectable)

1. Decide the honest first-target config (likely single-core scalar `cv64a6_imafdc_sv39`).
2. Confirm the reference BOM/interfaces via `board_get` + vendor docs.
3. Add `corev-mb/boards/bpi-f3/board.json` + `AGENTS-mb-bpi-f3.md` capturing only what CVA6 can
   actually drive; mark the rest as documented gaps.
4. Pass the `AGENTS-motherboard.md` §5 gate before any `corev_apu` integration.
