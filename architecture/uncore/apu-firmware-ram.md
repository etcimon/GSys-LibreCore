# APU firmware RAM window

**Domain:** graphics uncore · **Status:** testharness-shaped SRAM leaf (P2)

AXI4-64 SRAM at `ApuHarness` `FirmwareRamBase` `0x90000000` / 256 KiB.
32-bit register cycles stay single-beat. 64-bit INCR fills cover stream8
CVA6 I$/D$ 16-byte lines (`size=3 len=1`). EGL/GLES stay in client Mesa.
A directed CVA6 fetch exists, including cluster PerCoreBoot through the
compositor DRAM-hole map and the resident TGSI compile image. OpenSBI is
not this window.

## Intent

Give hart-1 firmware a private RAM target on the opt-in `G6LC_APU`
testharness xbar so `apu_fw.hex` can live at the OpenSBI/PMP window. Guest
virtio and GPIO/AI are not this window.

## Seams

| Piece | Path |
|---|---|
| SRAM slave | `corev_apu/apu/g6lc_apu_fwram.sv` (`tc_sram`, 64-bit words) |
| Rule | idx 12, `0x90000000`..`0x90040000` |
| DRAM hole | testharness splits DRAM around that window (`apu_dram_hole_legal`) |
| Host lock | `software/apu-fw/include/g6lc_apu_th_map.h`, `test/map_check.c`, `test/boot_check.c` |
| Testharness | `+define+G6LC_APU` extra slave; hex preload; FPGA/Altera maps unchanged |
| Image | `verif/tb/apu/apu_fw.hex` |
| TB | `verif/tb/apu/tb_g6lc_apu_fwram.sv` |

## Invariants

- Default-off is an AXI4 SLVERR error slave. `FeatureVirgl` remains illegal.
- Window and SRAM index match on `addr[31:0]` (RV64 `auipc`/`lui` of
  `0x9000xxxx` sign-extend to `0xffffffff9000xxxx`).
- Reads: `size=0/1` is `len=0` (D$ `lbu`/`lhu`, any align). `size=2` is
  `len=0` and `addr[1:0]==0`. `size=3` is INCR, `addr[2]==0`, `len<=15`;
  the whole `(len+1)*8` byte span must sit in the window. Stream8 I$/D$
  lines are `size=3 len=1`. WRAP, oversize, and window-crossing fills
  SLVERR (beat count is still drained). Writes stay single-beat.
- Window does not overlap GPIO/AI `0x40000000` or control `0x40002000`.
- Default `NB_MST` is unchanged. `+define+G6LC_APU` sets `APU_NB_EXTRA=3`
  (guest/control/RAM) and `APU_NB_RULES_EXTRA=1` (DRAM high fragment).
  `ariane_soc::NB_PERIPHERALS` is not grown.
- Firmware RAM must sit strictly inside DRAM. A single DRAM rule covering
  `0x80000000` aliases `0x90000000` (`addr_decode` last-match-wins).
- SMT OpenSBI is unchanged. Testharness `+define+G6LC_APU` preloads
  `apu_fw.hex` into this SRAM (`HexFile`, `+APU_FW_HEX=`) and points hart 1
  at `0x90000000`. HexFile writes the defined image prefix only; a full
  256 KiB blocking init is Verilator BLKLOOPINIT. Unwritten words stay
  `SimInit("none")` — not a BSS-zero contract. That is a load contract, not
  a testharness boot. The compositor TB AXI-reads the reset vector; the
  directed fwram TB issues a 2-beat I$ fill of crt0; the verif mini hart
  fetches through AXI-Lite → AXI4 (still `len=0`). A directed CVA6
  (`tb_g6lc_apu_cva6_fetch`) now fetches this window.

## Verification

`run-soc.sh` (`APU_SOC=1 APU_SYNTH=1`) and `run-exec.sh` (`APU_EXEC=1`).
Remote Verilator 5.008 (2026-09-15): **`tb_g6lc_apu_fwram` 6 cases / 317
checks / 1,421 clocks** (hex, cookie, size-3, I$ 2-beat `auipc`+spin,
WRAP/len-16/window-cross SLVERR, size-0/1 and sign-ext PA). Screening
synth uses 4 KiB: enabled 105,439 cells / 32,938 sequential bits;
disabled 166 / 15. Compositor fixture (same screening): enabled 127,687
/ 35,127; disabled 275 / 27.

Host WSL gcc (2026-09-15): **`PASS map_check`**, **`PASS boot_check`**.
Punched maps send `0x90000000` to idx 12; hart 1 reset PC is that window,
hart 0 stays ROM `0x10000`; hex auipc/spin and DTSI `next-addr` match.
Results also live in `AGENTS-todo.md`.
