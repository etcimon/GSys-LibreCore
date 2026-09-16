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
> - **`.md` only** — tier T (MIT) per `DOCS_UNDER_TIER`; no inline SPDX header, no code contract changed.

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
| `dram-channel-scaling.md` | memory (I3) | `litedram` × N | **Shared** N-channel stripe on the DRAM slave: core pipelines, L2/L3, `NrCores`, and island DMA. Stability plan for `DramChannels`. |
| `ethernet-controller.md` | network | `verilog-ethernet`, `liteeth`, `corundum`, `ariane-ethernet` | MAC on-die; PHY = external chip |
| `pcie-root-complex.md` | interconnect | `verilog-pcie`, `litepcie` | Glue on-die; SerDes/link = hard IP; NVMe/GPU are endpoints |
| `pcie-endpoint.md` | interconnect | `verilog-pcie`, `litepcie` | **Inverse role:** LibreCore *is* the endpoint (CPU+AI card); BAR/config target on-die; SerDes = hard IP |
| `storage-controllers.md` | storage | `litesata`, `litesdcard` (+ NVMe over PCIe) | Controller on-die; SerDes/level-shift external |
| `hdmi-display.md` | display | `hdmi` | TMDS encoder on-die; connector + re-driver on board |
| `apu-native-exec.md` | graphics APU | (in-tree `corev_apu/apu`) | Native exec leaf: one FPnew lane, four lockstep quad contexts, `LDC` 32-bit payload, uniform BR, local LSU; default-off |
| `apu-testharness-attach.md` | graphics APU | (in-tree `corev_apu/apu`) | PLIC splice + opt-in diagnostic xbar windows; trusted production source/RAM protection still open |
| `apu-fw-exec.md` | graphics APU | (in-tree `corev_apu/apu`) | Firmware mailbox bound to native exec; testharness `ExecEn && !MemEn` |
| `apu-testharness-bus.md` | graphics APU | (in-tree `corev_apu/apu`) | AXI4-64 adapter + opt-in testharness xbar ports + idle DMA export (`+define+G6LC_APU`) |
| `apu-testharness-load.md` | graphics APU | (in-tree `corev_apu/apu`) | Testharness load compositor: DRAM hole + hart-1 boot PC + 14-rule OpenSBI-visible map |
| `apu-firmware-domain.md` | graphics APU | (in-tree `corev_apu/apu`) | OpenSBI domain / PMP NAPOT + opt-in `ariane-g6lc-apu.dts`; not SMT2 firmware |
| `apu-resident-fw.md` | graphics APU | `software/apu-fw` | Hart-1 mailbox client; TID+IADD microjob; mini-hart image; not EGL |
| `apu-firmware-ram.md` | graphics APU | (in-tree `corev_apu/apu`) | Testharness firmware RAM at `0x90000000` / 256 KiB; idx 12; I$ INCR fills |
| `apu-cva6-fetch.md` | graphics APU | (in-tree `corev_apu/apu`) | CVA6 fetch of `apu_fw.hex`; cluster PerCoreBoot; cookies `0x600D000A` / `0x600D000B`; resident `apu_tgsi_cc.hex`; DRAM-lo OpenSBI load-addr fetch |
| `apu-tgsi.md` | graphics APU | `software/apu-fw` | TGSI text subset → native exec; `IMM[n]` via `LDC`; separate `apu_tgsi_fw` image; not TEX; not in `apu_fw.elf` |

---

## APU completion review (2026-09-15)

The APU outlines now distinguish committed bring-up evidence from deployment
requirements. `apu-firmware-domain.md` owns the persistent S-mode service,
platform-managed versus optional BIOS-managed loading, and the narrow Linux/
BIOS boot-health interoperability contract. It does not add a BIOS dependency
or a joint code-update cycle. Firmware-instance health, client/queue ownership
and Linux-attempt health remain separate.

`apu-native-exec.md` and `apu-tgsi.md` identify prototype storage/ISA and
host-versus-target compiler gaps; `apu-fw-exec.md` owns the missing combined
memory/exec path. `apu-firmware-ram.md` and `apu-testharness-bus.md` distinguish
review fixes from the remaining physical-address, source, AXI and reset gates.
Cookies/DMEM fills and stub peripheral stores are not Linux/Mesa GLES2 proof.
Root implementation/test/coverage maps and `AGENTS-todo.md` own current evidence.

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
