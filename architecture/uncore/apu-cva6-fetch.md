# APU CVA6 fetch of firmware RAM

**Domain:** graphics uncore · **Status:** directed CVA6 fetch leaf (P2)

CVA6 fetch of preloaded firmware RAM, including `g6lc_cluster` PerCoreBoot
through the testharness compositor DRAM-hole map, a directed mailbox
run to cookie `0x600D000A`, and the separate TGSI MOV job to
`0x600D000B`. EGL/GLES stay in client Mesa. Not full testharness OpenSBI.

## Review boundary — 2026-09-15

Results below are historical bring-up evidence from `d74010111`, except the
review rerun of `run-cva6-cookie.sh`: 14 checks / 1,835 clocks, errors=0,
cookie `0x600D000A`. That build retains five SELRANGE warnings in
`core/issue_read_operands.sv`; it is not a warning-free full-core lint pass.
Direct reset into firmware is M-mode execution unless a verified supervisor
transition establishes otherwise. No cookie test here demonstrates a protected
S-mode domain. `apu_tgsi_cc.hex` runs an opcode-only target stub plus frozen MOV
emit, not the same semantic compiler as the host suite.

Keep these tests for bus/fetch regression, but stop multiplying peripheral-stub
milestones as a proxy for Linux progress. The next boot gate is one real pinned
OpenSBI ELF launching the service in S-mode with RAM/control isolation, correct
Linux topology and fresh readiness; the next graphics gate is resource-backed
execution with genuine program dependence. A failed normal `fence` or compiler
load/store must be traced, not bypassed by weakening address/ordering semantics.

The platform loader and optional BIOS-managed loader converge on that same
service entry/ABI. Neither a checked-in hex nor the compositor preload delay
establishes image integrity, BSS initialization, readiness or warm-reset safety.
See `apu-firmware-domain.md` and `apu-resident-fw.md` for current contracts.

## Intent

Prove the firmware image at `0x90000000` is a real CVA6 instruction stream,
not only a mini-hart or an AXI peek. The I$ fill contract (`size=3 len=1`
INCR) is the one `g6lc_apu_fwram` already serves.

## Seams

| Piece | Path | Purpose |
|---|---|---|
| Core | `corev_apu/src/ariane.sv` | One hart, boot PC `0x90000000`, `hart_id=1` |
| Config | `g6lc64_stream8` (`TARGET_CFG`) | `NrHarts=1`, `DcacheIdWidth=3`, I$ line 16 B |
| SRAM | `g6lc_apu_fwram.sv` | HexFile prefix, 4 KiB screening window |
| Runner | `verif/tb/apu/run-cva6-fetch.sh` | Remote Verilator 5.008 `--binary --timing` |
| TB | `verif/tb/apu/tb_g6lc_apu_cva6_fetch.sv` | One core I$ AR + commit-PC |
| Dual TB | `verif/tb/apu/tb_g6lc_apu_cva6_dual_fetch.sv` | Core 0 ROM `0x10000`, core 1 RAM `0x90000000` |
| Dual runner | `verif/tb/apu/run-cva6-dual-fetch.sh` | Same Verilator flags; no `+APU_FW_HEX=` (would override ROM) |
| Cluster TB | `verif/tb/apu/tb_g6lc_apu_cluster_fetch.sv` | `g6lc_cluster` PerCoreBoot, shared mem split |
| Cluster runner | `verif/tb/apu/run-cva6-cluster-fetch.sh` | L2/L3 forced off |
| Compositor TB | `verif/tb/apu/tb_g6lc_apu_th_fetch.sv` | Last-match-wins ROM + DRAM lo/hi + RAM idx 12 |
| Compositor runner | `verif/tb/apu/run-cva6-th-fetch.sh` | Same Verilator flags; no `+APU_FW_HEX=` |
| Cookie TB | `verif/tb/apu/tb_g6lc_apu_cva6_cookie.sv` | Control MMIO + `g6lc_apu_fw` `ExecEn=1` to cookie |
| Cookie runner | `verif/tb/apu/run-cva6-cookie.sh` | L2/L3 off; sidecar `g6lc_apu_fw`; `ApuHarness.ExecEn` stays 0 |
| Compositor cookie TB | `verif/tb/apu/tb_g6lc_apu_cva6_th_cookie.sv` | Same image through `g6lc_apu_th_load` `gen_exec` |
| Compositor cookie runner | `verif/tb/apu/run-cva6-th-cookie.sh` | No `+APU_FW_HEX=` |
| TGSI cookie TB | `verif/tb/apu/tb_g6lc_apu_cva6_tgsi.sv` | `apu_tgsi.hex` or `apu_tgsi_cc.hex` to `0x600D000B` |
| TGSI cookie runner | `verif/tb/apu/run-cva6-tgsi.sh` | Pre-encoded MOV; no `+APU_FW_HEX=` |
| Resident compile runner | `verif/tb/apu/run-cva6-tgsi-cc.sh` | `apu_tgsi_cc.hex`; compiler + job linked |
| OpenSBI load-addr TB | `verif/tb/apu/tb_g6lc_apu_cva6_osbi_boot.sv` | Hart 0 DRAM lo `0x80000000`; hart 1 firmware RAM |
| OpenSBI load-addr runner | `verif/tb/apu/run-cva6-osbi-boot.sh` | Not a real OpenSBI ELF; default app boot stays ROM |
| UART store TB | `verif/tb/apu/tb_g6lc_apu_cva6_osbi_uart.sv` | DRAM-lo payload `sb` 0x41 to UART `0x10000000` |
| UART store runner | `verif/tb/apu/run-cva6-osbi-uart.sh` | Stub UART; not 16550/PLIC/L2 |
| CLINT store TB | `verif/tb/apu/tb_g6lc_apu_cva6_osbi_clint.sv` | DRAM-lo payload `sw` MSIP=1 to CLINT `0x02000000` |
| CLINT store runner | `verif/tb/apu/run-cva6-osbi-clint.sh` | Stub CLINT; not a real timer/PLIC/L2 |
| PLIC store TB | `verif/tb/apu/tb_g6lc_apu_cva6_osbi_plic.sv` | DRAM-lo payload `sw` priority=1 to PLIC `0x0C000004` |
| PLIC store runner | `verif/tb/apu/run-cva6-osbi-plic.sh` | Stub PLIC; not a real interrupt controller/L2 |
| ROM image | `verif/tb/apu/rom_spin.hex` | `jal x0, 0` 16-byte line |
| DPI stub | `verif/tb/apu/g6lc_dram_peek64_stub.cpp` | `id_stage` peek; testharness owns the real one |

## Invariants

- Default-off APU profiles are unchanged. `FeatureVirgl` remains illegal.
- Cluster fetch uses `PerCoreBoot` with L2/L3 off. Compositor fetch uses
  the testharness last-match-wins map (ROM, DRAM lo/hi, RAM idx 12). A full
  DRAM rule after RAM aliases `0x90000000`.
- These TBs do not instantiate OpenSBI, UART, PLIC, or testharness DRAM.
  The cookie TB adds uncached control MMIO and native exec; it is not a
  testharness `g6lc_apu_sys` attach (`ApuHarness.ExecEn=0`). The TGSI cookie
  TB uses compositor `gen_exec`. `run-cva6-tgsi.sh` loads `apu_tgsi.hex`
  (pre-encoded). `run-cva6-tgsi-cc.sh` loads `apu_tgsi_cc.hex` (compiler +
  job linked). Peek CPL0 is ordered after mailbox GO/STAT.
- SMT OpenSBI and FPGA/Altera maps are unchanged.
- Firmware RAM writes stay single-beat. Fetch TBs only need I$ reads; the
  cookie TB also stores the cookie and stack.

## Verification

Remote Verilator 5.008 (2026-09-15):

| Runner | Result |
|---|---|
| `run-cva6-fetch.sh` | **`tb_g6lc_apu_cva6_fetch` 5 checks / 279 clocks** |
| `run-cva6-dual-fetch.sh` | **`tb_g6lc_apu_cva6_dual_fetch` 4 checks / 279 clocks** (core 0 ROM commit, core 1 firmware I$ fill + commit) |
| `run-cva6-cluster-fetch.sh` | **`tb_g6lc_apu_cluster_fetch` 4 checks / 283 clocks** (shared mem ROM AR + firmware I$ fill + both commits) |
| `run-cva6-th-fetch.sh` | **`tb_g6lc_apu_th_fetch` 14 checks / 283 clocks** (compositor decode hole vs aliased steal, RAM-port I$ fill, DRAM poison not hit, both commits) |
| `run-cva6-cookie.sh` | **`tb_g6lc_apu_cva6_cookie` 14 checks / 1,835 clocks**, cookie `0x600D000A` |
| `run-cva6-th-cookie.sh` | **`tb_g6lc_apu_cva6_th_cookie` 14 checks / 1,835 clocks**, cookie `0x600D000A` (compositor `gen_exec`) |
| `run-cva6-tgsi.sh` | **`tb_g6lc_apu_cva6_tgsi` 14 checks / 2,081 clocks**, cookie `0x600D000B` (pre-encoded MOV) |
| `run-cva6-tgsi-cc.sh` | **`tb_g6lc_apu_cva6_tgsi` 14 checks / 10,511 clocks**, cookie `0x600D000B` (resident compile + frozen MOV emit) |
| `run-cva6-osbi-boot.sh` | **`tb_g6lc_apu_cva6_osbi_boot` 13 checks / 286 clocks** (hart 0 DRAM lo `0x80000000`, hart 1 firmware RAM) |
| `run-cva6-osbi-uart.sh` | **`tb_g6lc_apu_cva6_osbi_uart` 12 checks / 288 clocks**, byte `0x41` (UART stub through compositor) |
| `run-cva6-osbi-clint.sh` | **`tb_g6lc_apu_cva6_osbi_clint` 12 checks / 288 clocks**, word `0x1` (CLINT MSIP stub through compositor) |
| `run-cva6-osbi-plic.sh` | **`tb_g6lc_apu_cva6_osbi_plic` 12 checks / 290 clocks**, word `0x1` (PLIC source-1 priority stub through compositor) |

CVA6 generic synth is not this leaf. Results also live in `AGENTS-todo.md`.
