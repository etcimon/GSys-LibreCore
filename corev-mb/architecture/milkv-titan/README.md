# milkv-titan — development target (analysis-only, NOT included at this stage)

Milk-V Titan, a RISC-V board on the **SpacemiT K1/M1** family aimed at a
higher-expansion desktop/workstation profile. Studied to derive the widest
CVA6-class board interface set. **No `board.json` is committed** — documented
target only.

> **Status: analysis-only.** Public Milk-V/SpacemiT material; several Titan specifics vary by
> revision — confirm via pcbparts.dev (`board_search`/`board_get`) and vendor datasheets before
> promotion. Nothing here is compiled, fetched, or wired into a flist.

## 1. Intent

Titan is the "maximum surface" template: more PCIe/M.2, more USB, richer display/IO than Jupiter.
It stresses the corev-mb model the hardest (many concurrent high-speed lanes), so it is the best
target for validating the **expansion + PHY-parameterization** story end to end.

## 2. Reference feature set (per public docs — confirm before use)

| Domain | Titan / K1-M1 reference |
|---|---|
| Compute | 8× X60, RVA22, RVV 1.0 |
| Memory | LPDDR4/4x |
| PCIe | multiple PCIe / M.2 (NVMe, add-in) |
| Networking | 2× GbE (2.5 GbE on some revs — confirm) |
| USB | multiple USB 3.0 / 2.0 |
| Display | HDMI (+ MIPI on some revs) |
| Storage | eMMC, microSD, M.2 NVMe |

## 3. Core preconditions (target `CVA6Cfg`) — and the honest delta

Same realistic first target as the other K1/M1 boards (`cv64a6_imafdc_sv39`, scalar single-core).
Titan's extra lanes increase the **integration** delta, not the ISA delta:

| Requirement | CVA6 today | Gap |
|---|---|---|
| Many PCIe lanes / multi-slot | `verilog-pcie`/`litepcie` planned | multi-root/switch integration + SerDes |
| 2.5 GbE (if present) | `verilog-ethernet` is 1G-oriented | MAC/PHY rate support |
| RVV 1.0 / 8-core | absent / single-core | `architecture/spec-extensions/`, `architecture/multi-core/` |

## 4. Uncore mapping (interface → controller → PHY)

| Interface | Candidate controller | Split |
|---|---|---|
| LPDDR4 | `litedram` (LPDDR4 variant) | PHY = hard macro (gap on ASIC) |
| PCIe ×N / M.2 | `verilog-pcie` / `litepcie` | glue on-die; SerDes hard IP; switch fabric if multi-slot |
| GbE / 2.5 GbE | `verilog-ethernet` / `liteeth` | MAC on-die; PHY external (rate TBD) |
| USB 3.0 ×N | *(none catalogued)* | **gap** |
| HDMI | `hdmi` | encoder on-die; connector/re-driver on board |
| NVMe ×N | via PCIe | endpoints over PCIe roots |

## 5. PHY / expansion plan (pcbparts.dev)

`board_search "milk-v titan"` → `board_get` for neighborhoods/design rules;
`get_design_rules` for a multi-lane PCIe stackup; `jlc_search "PCIe switch"`,
`jlc_search "2.5GbE phy"`, `jlc_search "USB 3.0 host controller"`. Use `mb expand` to grow the
interface set incrementally and re-`mb select`.

## 6. Gaps vs CVA6 today (summary)

The blocking deltas are the same class as Jupiter but wider: multi-lane PCIe integration, LPDDR4
PHY, USB3, optional 2.5 GbE rate support, plus RVV and multi-core. Titan should be promoted
**after** Jupiter validates the socketed desktop flow.

## 7. Promotion gates (to become selectable)

1. Confirm the exact lane/port map for the target revision via `board_get` + vendor docs.
2. Stage the interfaces (start minimal, `mb expand` outward) to keep each `mb select` closable.
3. Add `board.json` + `AGENTS-mb-milkv-titan.md` scoped to CVA6-drivable interfaces.
4. Pass `AGENTS-motherboard.md` §5 with explicit SI/PI + power budgets for every high-speed lane.
