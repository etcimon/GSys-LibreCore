# APU testharness AXI4 bus adapter

**Domain:** graphics uncore · **Status:** standalone default-off leaf (P1)

AXI4 64-bit single-beat to AXI-Lite 32-bit conversion in front of
`g6lc_apu_attach`. EGL/GLES stay in client Mesa. Guest/control windows are production testharness xbar ports only under
`+define+G6LC_APU`.

## Intent

P1 step 7 of the API-neutral APU plan, bus leaf: testharness masters are
AXI4 64-bit; the APU control/guest ports are AXI-Lite 32-bit. Prove aligned
32-bit register access, PLIC source 9 splice, and default-off SLVERR
without growing `ariane_soc::NB_PERIPHERALS`.

## Seams

| Piece | Path |
|---|---|
| Converter | `corev_apu/apu/g6lc_apu_axi4_lite.sv` |
| Wrapper | `corev_apu/apu/g6lc_apu_th.sv` |
| Xbar glue | `corev_apu/apu/g6lc_apu_xbar.sv` (rules idx 10/11) |
| Firmware RAM | `corev_apu/apu/g6lc_apu_fwram.sv` (rule idx 12, `0x90000000`) |
| Load compositor | `corev_apu/apu/g6lc_apu_th_load.sv` (DRAM hole + boot PCs + hex hold) |
| Testharness | `+define+G6LC_APU` extra slaves; default topology unchanged |
| PLIC pin | `ariane_peripherals.apu_irq_i` → `irq_sources[8]` |
| Flist | `corev_apu/apu/Flist.apu_soc` |

## Invariants

- Default-off: AXI4 ports SLVERR; `irq_sources` pass through. `FeatureVirgl`
  remains illegal.
- `len=0`, `size=2`, `addr[1:0]=0` 32-bit accesses are forwarded.
  Aligned `size=3` stores (`len=0`, `addr[2:0]=0`) split into two 32-bit
  lite writes (CVA6 WT may pack paired MMIO stores). Other sizes SLVERR.
  Reads stay `size=2`.
- `addr[2]` selects the 32-bit lane on the 64-bit data bus.
- Guest/control windows do not overlap GPIO/AI `0x40000000..0x40000fff`.
- Authorization is the firmware hart ID, never AXI PROT.
- Default testharness `NB_MST = NB_PERIPHERALS`. `+define+G6LC_APU` adds
  idx 10/11/12 and instantiates `g6lc_apu_th_load` (xbar + fwram + DRAM hole
  + hart-1 boot). Testharness only stitches xbar masters. The DMA AXI master
  is exported from the compositor and tied idle (`DmaReadEn=0` on
  `ApuHarness`; testharness `dma_rsp_i='0`). FPGA/Altera `NrSlaves` is
  unchanged. A legal DMA window sits in DRAM lo/hi, never firmware RAM.
- `ApuHarness` needs two physical cores and `NrHarts=1`. Control is tagged
  as firmware hart 1 (bring-up). Cluster `PerCoreBoot` is generic; the load
  box supplies per-core PCs. Physical display stays disabled.

## Verification

`run-soc.sh` (`APU_SOC=1 APU_SYNTH=1`) and `run-dma-init.sh`. Remote
Verilator 5.008 (2026-09-15): **th** 6/32/113; **xbar** 3/17/30; **th_load**
3/21/16; **dma_init** 10/19 (DRAM lo payload `0xaabbccdd`, hole not
stolen). Xbar enabled 22,269 cells / 2,201 sequential bits; disabled 124 /
16. Firmware RAM screening synth (4 KiB) enabled 104,347 / 32,930
sequential; disabled 66 / 7.
Host `map_check` / `boot_check` / `load_check` lock the DRAM hole, hart-1
reset PC, and compositor rule table. Not mapped area or STA. Results also
live in `AGENTS-todo.md`.
