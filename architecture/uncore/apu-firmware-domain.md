# APU firmware domain (OpenSBI / PMP)

**Domain:** graphics uncore · **Status:** contract + opt-in DTS leaf (P2)

OpenSBI domain and PMP numbers for the APU firmware hart. EGL/GLES stay in
client Mesa. Not applied to the SMT2 OpenSBI build. A directed CVA6 fetch
from DRAM lo `0x80000000` (OpenSBI load address) exists; not a full
testharness OpenSBI ELF/UART/PLIC/L2 boot.

## Intent

Encode the firmware-private RAM and control window as an OpenSBI domain
memregion pair, with RISC-V PMP NAPOT encodings that match `ApuHarness`.
Guest virtio at `0x40001000` stays in the application domain.

## Seams

| Piece | Path |
|---|---|
| Checks | `apu_domain_legal`, `apu_region_order`, `apu_pmp_napot` in `g6lc_apu_cfg_pkg` |
| Overlay | `corev_apu/bootrom/g6lc-apu-domain.dtsi` (not included by default) |
| Opt-in DTS | `corev_apu/bootrom/ariane-g6lc-apu.dts` (stream8 + overlay + CPU1 harts) |
| Profile | `ApuHarness`: hart 1, RAM `0x90000000` / 256 KiB, control `0x40002000` |
| Testharness map | 14-rule `+define+G6LC_APU` addr_map (OpenSBI-visible decode) |
| Boot split | `apu_core_boot_addr` / `apu_boot_split_legal`; testharness `PerCoreBoot` |
| Host lock | `software/apu-fw/test/boot_check.c`, `osbi_check.c` |
| TB | `verif/tb/apu/tb_g6lc_apu_th_osbi.sv`, `tb_g6lc_apu_cva6_osbi_boot.sv`, `tb_g6lc_apu_cva6_osbi_uart.sv`, `tb_g6lc_apu_cva6_osbi_clint.sv`, `tb_g6lc_apu_cva6_osbi_plic.sv` |

## Invariants

- Two physical cores, `NrHarts=1`. SMT service-domain partitioning is out of
  scope. Do not patch `build-opensbi-smt2.sh`.
- Firmware RAM is `2^order` aligned, `order >= 18` (256 KiB). Control and
  guest are `order >= 12` (4 KiB).
- Firmware RAM and control are firmware-private. Guest virtio is not.
- GPIO/AI `0x40000000..0x40000fff` is never an APU region.
- Testharness DRAM hole: firmware RAM sits strictly inside DRAM
  (`apu_dram_hole_legal`). Empty lo/hi fragments are illegal.
- Firmware hart reset PC is `FirmwareRamBase`. Application cores keep ROM
  `0x10000`. Overlay `next-addr` matches. Not applied to SMT2.
- Opt-in `ariane-g6lc-apu.dts` is not in `bootrom/Makefile` `LINUX_DTBS`.
  FPGA/Altera maps do not grow. `FeatureVirgl` remains illegal. Physical
  display stays disabled.

## Verification

`run-soc.sh` (`APU_SOC=1`), `run-th-osbi.sh`, `run-cva6-osbi-boot.sh`,
`run-cva6-osbi-uart.sh`, `run-cva6-osbi-clint.sh`, and
`run-cva6-osbi-plic.sh`.
Remote Verilator 5.008 (2026-09-15): **`tb_g6lc_apu_domain` 26 checks /
errors=0**. Directed **`tb_g6lc_apu_th_osbi` 27 checks / 4 clocks** locks
the testharness 14-rule last-match to compositor DRAM lo/hi + guest/ctrl/RAM
and the hart-1 boot split. **`tb_g6lc_apu_cva6_osbi_boot` 13 checks / 286
clocks**: hart 0 I$ fill + commit at DRAM lo `0x80000000`, hart 1 firmware
RAM; default testharness app boot stays ROM `0x10000`.
**`tb_g6lc_apu_cva6_osbi_uart` 12 checks / 288 clocks**, byte `0x41` at
UART `0x10000000` (stub, not 16550).
**`tb_g6lc_apu_cva6_osbi_clint` 12 checks / 288 clocks**, word `0x1` at
CLINT `0x02000000` (stub MSIP, not a real timer).
**`tb_g6lc_apu_cva6_osbi_plic` 12 checks / 290 clocks**, word `0x1` at
PLIC `0x0C000004` (stub source-1 priority, not a real interrupt
controller). Host `osbi_check`
refuses default-tree includes and SMT2 script edits. th_load screening synth
4 KiB enabled 127,297 / 35,275 sequential; disabled 275 / 27. Results also
live in `AGENTS-todo.md`.
