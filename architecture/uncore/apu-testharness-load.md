# APU testharness load compositor

**Domain:** graphics uncore · **Status:** testharness-only composition leaf (P2)

Owns the opt-in `G6LC_APU` testharness load contract: guest/control xbar,
firmware RAM, DRAM-hole rules, hart-1 boot PC, hex preload hold, and an AXI
read of the preloaded reset vector. A directed cluster fetch now uses those
rules. The testharness 14-rule addr_map is the OpenSBI-visible decode.
EGL/GLES stay in client Mesa. Does not instantiate OpenSBI firmware.

## Intent

Keep `ariane_testharness` as a bus stitcher. APU address rules, firmware
image preload, and the firmware-hart reset PC live in one default-off box
so the cluster stays generic (`PerCoreBoot`) and SRAM stays in `g6lc_apu_fwram`.

## Seams

| Piece | Path | Purpose |
|---|---|---|
| Compositor | `corev_apu/apu/g6lc_apu_th_load.sv` | Instantiates xbar + fwram; exports DRAM lo/hi + boot PCs + `fw_ready` |
| Guest/control | `g6lc_apu_xbar.sv` | AXI4 windows idx 10/11 |
| Firmware RAM | `g6lc_apu_fwram.sv` | SRAM idx 12 + optional hex |
| Boot legality | `apu_core_boot_addr` / `apu_boot_split_legal` | Hart 1 → RAM, hart 0 → ROM |
| Host lock | `software/apu-fw/test/load_check.c` | Compositor rule table + boot PCs |
| Testharness | `+define+G6LC_APU` stitches xbar masters only | FPGA/Altera maps unchanged |
| TB | `verif/tb/apu/tb_g6lc_apu_th_load.sv` | Directed rules/boot/`fw_ready`/AXI hex fetch |
| Cluster fetch TB | `verif/tb/apu/tb_g6lc_apu_th_fetch.sv` | CVA6 through compositor DRAM-hole map |
| OpenSBI-visible map TB | `verif/tb/apu/tb_g6lc_apu_th_osbi.sv` | Testharness 14-rule last-match + domain/boot |
| Exec bind TB | `verif/tb/apu/tb_g6lc_apu_th_exec.sv` | Compositor AXI4 mailbox exec; `ExecEn && !MemEn` |
| DMA initiator | `dma_req_o` / `dma_rsp_i` | Idle on `ApuHarness`; directed DRAM-lo read |

## Invariants

- Default-off still publishes the same addr_map rules. `FeatureVirgl` remains
  illegal.
- DRAM is two fragments around firmware RAM. Last-match-wins aliasing is the
  reason for the hole, not an extra decode policy in this box.
- Application cores keep ROM `0x10000`. Firmware hart resets at
  `0x90000000`. Overlay DTSI is still not in default trees.
- Hex preload stays in `g6lc_apu_fwram` (image prefix only; not BSS-zero).
  This box holds cluster reset for one time unit (`fw_ready_o`, `#1`).
  Verilator 5.008 rejects `#0` Inactive scheduling.
- SMT OpenSBI is unchanged. Full testharness UART/PLIC/DRAM/L2 and an
  OpenSBI firmware payload are not this leaf. The directed cluster TB proves
  CVA6 I$ fills through the compositor map. `tb_g6lc_apu_th_osbi` locks the
  testharness 14-rule OpenSBI-visible decode without booting OpenSBI.

## Verification

Host WSL gcc: **`PASS load_check`** / **`PASS osbi_check`**. Remote
Verilator 5.008 (2026-09-15), `run-soc.sh` (`APU_SOC=1 APU_SYNTH=1`) rc=0:
**`tb_g6lc_apu_th_load` 3 cases / 20 checks / 16 clocks** (DRAM-hole rules,
hart 0 ROM / hart 1 RAM, AXI-read `auipc` `0x0003f117` at `0x90000000` and
spin `0x0000006f` at `+12`). `run-cva6-th-fetch.sh` rc=0:
**`tb_g6lc_apu_th_fetch` 14 checks / 283 clocks**. `run-th-osbi.sh` rc=0:
**`tb_g6lc_apu_th_osbi` 27 checks / 4 clocks** (testharness 14-rule
last-match + domain/boot). `run-th-exec.sh` rc=0: **`tb_g6lc_apu_th_exec`
24 cases / 175 checks / 1,019 clocks** (AXI4 mailbox TID+IADD peek 10/11).
Screening synth uses 4 KiB: `ExecEn=0` enabled 127,687 / 35,127 sequential;
`ExecEn=1` 154,321 / 39,966; disabled 275 / 27. Results also live in
`AGENTS-todo.md`.
