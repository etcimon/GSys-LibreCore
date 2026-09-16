# APU testharness-shaped attach

**Domain:** graphics uncore · **Status:** standalone default-off leaf (P1)

PLIC source splice and xbar window exports for `g6lc_apu_soc`. EGL/GLES stay
in client Mesa. Reached through the opt-in `G6LC_APU` testharness compositor;
default topology stays unchanged. This is not a protected production attachment.

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
| Flist | `corev_apu/apu/Flist.apu_soc`; opt-in diagnostic testharness composition |

## Invariants

- Default-off: `Enable=0` passes `irq_sources` through and keeps the SoC box
  inert. `FeatureVirgl` remains illegal.
- Guest and control windows do not overlap GPIO/AI `0x40000000..0x40000fff`.
- Authorization requires a trusted supplied source/hart ID, never AXI PROT.
  The testharness's constant tag is bring-up only. The AXI4 wrapper now retains
  source metadata at handshake; actual provenance/RAM protection remain open.
- Physical display stays disabled. No OpenSBI domain/PMP programming here.
- Default topology is unchanged; `+define+G6LC_APU` adds guest/control/RAM
  ports and the firmware DRAM hole in the diagnostic testharness only.
- Optional BIOS loading/health is an independent supervisor adapter, not
  permission for Linux or the BIOS UI to share private mailbox ownership.
  See `apu-firmware-domain.md` and `apu-testharness-bus.md` for the reviewed
  deployment and remaining bus/source/reset gates.

## Verification

`APU_SOC=1 APU_EXEC=1 APU_SYNTH=1` on `verif/tb/apu/run-virtio-mmio.sh`.
Remote Verilator 5.008 (2026-09-15): **`tb_g6lc_apu_attach` 4 cases / 32
checks / 77 clocks / errors=0**. Enabled generic synth 21,447 cells / 2,287
sequential bits (identical to `g6lc_apu_soc`; the splice is wires);
disabled 522 / 162 (AXI-lite bookkeeping). Directed cases: window placement,
guest virtio magic, hart-0 control deny, firmware-hart control, AI source 8
preserved, APU source 9 after a virtio config event. Not mapped area or STA.
Results also live in `AGENTS-todo.md`.
