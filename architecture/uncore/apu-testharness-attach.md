# APU testharness-shaped attach

**Domain:** graphics uncore · **Status:** standalone default-off leaf (P1)

PLIC source splice and xbar window exports for `g6lc_apu_soc`. EGL/GLES stay
in client Mesa. Not instantiated on the production testharness xbar.

## Intent

P1 step 7 of the API-neutral APU plan, first leaf: prove guest/control
placement next to (not inside) the GPIO/AI 4 KiB window, and splice guest
virtio IRQ onto PLIC source 9 without touching AI source 8.

## Seams

| Piece | Path |
|---|---|
| Config | `MmioBase=0x40001000`, `ControlBase=0x40002000`, `IrqSource=9` |
| RTL | `corev_apu/apu/g6lc_apu_attach.sv` wraps `g6lc_apu_soc` |
| PLIC | `irq_sources[IrqSource-1]`; source 8 / `irq_sources[7]` is AI |
| Flist | `corev_apu/apu/Flist.apu_soc` (not production / testharness) |

## Invariants

- Default-off: `Enable=0` passes `irq_sources` through and keeps the SoC box
  inert. `FeatureVirgl` remains illegal.
- Guest and control windows do not overlap GPIO/AI `0x40000000..0x40000fff`.
- Authorization is the firmware hart ID, never AXI PROT.
- Physical display stays disabled. No OpenSBI domain/PMP programming here.
- Production `ariane_testharness` / `ariane_soc_pkg` / `ariane_peripherals`
  topology is unchanged.

## Verification

`APU_SOC=1 APU_EXEC=1 APU_SYNTH=1` on `verif/tb/apu/run-virtio-mmio.sh`.
Remote Verilator 5.008 (2026-09-15): **`tb_g6lc_apu_attach` 4 cases / 32
checks / 77 clocks / errors=0**. Enabled generic synth 21,447 cells / 2,287
sequential bits (identical to `g6lc_apu_soc`; the splice is wires);
disabled 522 / 162 (AXI-lite bookkeeping). Directed cases: window placement,
guest virtio magic, hart-0 control deny, firmware-hart control, AI source 8
preserved, APU source 9 after a virtio config event. Not mapped area or STA.
Results also live in `AGENTS-todo.md`.
