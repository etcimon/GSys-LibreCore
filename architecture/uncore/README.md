# CVA6 uncore — controller & PHY integration outlines

This tree is a **scaffold and blueprint**, not RTL. It is the uncore counterpart to the core
extension points one level up (`architecture/README.md`): it reserves, for each desktop-class
subsystem, *where* an external controller lands in `corev_apu`, *how* it splits into on-die
controller vs board/analog PHY, and *what* gates it must pass before it is wired into a flist.

> ### Scaffold contract (read first)
> - **Nothing here is compiled.** No file under `architecture/` is referenced by any flist, synthesis,
>   or `pd/` script. These outlines cannot break elaboration, simulation, synthesis, or tape-out.
> - **No RTL is moved or added by these docs.** They describe integration seams that already exist in
>   `corev_apu/` and point at controllers fetched on demand by the `build-platform` `vendor` command.
> - **`.md` only** — out of licensing scope per `AGENTS.md` §0.4.

---

## How the three layers fit together

| Layer | File(s) | Answers |
|---|---|---|
| **Mechanism** | `AGENTS-vendor.md` | How a controller is fetched / updated / scanned. |
| **Substructure** | `AGENTS-core-platform-vendor-actives.md` | Which controllers/PHY exist and where they attach. |
| **RTL outline** | `architecture/uncore/*.md` (this tree) | Per-domain top module, bus, PHY split, config gate, verification, DTS. |
| **Uncore philosophy** | `AGENTS-corev-apu.md` | SystemVerilog preconditions for the whole uncore. |

---

## Map of uncore outlines

| Outline | Domain | Catalog ids | On-die vs board/PHY |
|---|---|---|---|
| `ddr4-controller.md` | memory | `litedram` | Controller on-die; DDR PHY = FPGA MIG / ASIC hard macro; DIMM on board |
| `ethernet-controller.md` | network | `verilog-ethernet`, `liteeth`, `corundum`, `ariane-ethernet` | MAC on-die; PHY = external chip |
| `pcie-root-complex.md` | interconnect | `verilog-pcie`, `litepcie` | Glue on-die; SerDes/link = hard IP; NVMe/GPU are endpoints |
| `storage-controllers.md` | storage | `litesata`, `litesdcard` (+ NVMe over PCIe) | Controller on-die; SerDes/level-shift external |
| `hdmi-display.md` | display | `hdmi` | TMDS encoder on-die; connector + re-driver on board |

---

## What each outline contains

Every outline follows the same one-page shape (mirroring the core extension-point READMEs):

1. **Intent** — what the subsystem adds and why.
2. **Chosen controller(s)** — upstream repo, license, catalog id, `vendor` fetch line.
3. **Controller vs PHY split** — the on-die/board boundary (the decisive fact).
4. **Integration seam** — where it attaches in `corev_apu` (AXI/NoC, board wrapper, constraints).
5. **Config gating** — the `CVA6Cfg` / board-config knobs it should sit behind.
6. **Invariants** — ordering, reset, CDC, precise-trap, and DFT rules it must honour.
7. **Verification + software** — testbench, device tree, Linux driver, cross-validation.
8. **Scan pointers** — what `vendor scan <id>` should surface before integration.

## Promotion path (scaffold → integrated)

Identical to `architecture/README.md`: `vendor sync` the controller → config-gate it → implement the
`corev_apu` wrapper at the AXI seam → register in the `corev_apu`/FPGA flist → verify/test → observe
(RVFI/PMU/DTS) → document (bump `status` to `integrated`, update `AGENTS-specs-to-impl.md`). Vendoring
the source is **step zero**, not the finish line.
