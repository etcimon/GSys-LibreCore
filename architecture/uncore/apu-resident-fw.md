# APU resident firmware

**Domain:** graphics uncore · **Status:** mailbox client leaf (P2)

Hart-1 firmware that programs `g6lc_apu_fw` through `ACTRL_MAIL_*`. EGL/GLES
stay in client Mesa. This hart never executes per-pixel work.

## Intent

A resident control program at `ApuHarness` RAM `0x90000000` loads a native
`TID`+`IADD` microjob and peeks `r3`. TGSI compilation lives in a **separate**
image (`apu_tgsi_fw`). Not a Linux service loop.

## Seams

| Piece | Path |
|---|---|
| Client | `software/apu-fw/src/apu_fw.c` |
| Encodings | `software/apu-fw/include/g6lc_apu_exec.h` (packed layout of `apu_exec_inst_t`) |
| Mailbox | `software/apu-fw/include/g6lc_apu_mbox.h` |
| Link | `software/apu-fw/link.ld` at `0x90000000` / 256 KiB |
| Image | `verif/tb/apu/apu_fw.hex` (RV64I, 640 bytes) |
| Mini hart | `verif/tb/apu/g6lc_apu_mini_hart.sv` (MIT, not a CVA6) |
| Adapter | `verif/tb/apu/g6lc_apu_lite_to_axi4.sv` |
| RAM | `corev_apu/apu/g6lc_apu_fwram.sv` (idx 12) |
| TB | `verif/tb/apu/tb_g6lc_apu_resident.sv`, `tb_g6lc_apu_hart.sv` |

## Invariants

- Firmware uses the protected control window only. Guest virtio is not mapped
  here. Cookie at `0x9003FF00`.
- Encodings in C must equal SV `apu_exec_enc` (`enc_check` + TB word checks).
- The mini hart fetches the image from `g6lc_apu_fwram` over AXI, not from a
  private `$readmemh` array.
- `FeatureVirgl` remains illegal. No DRAM DMA in this leaf.
- SMT OpenSBI build is unchanged.
- The mini hart is a directed fetch/MMIO stand-in. It is not a CVA6 and is
  not instantiated on the testharness. A separate directed CVA6 TB
  (`tb_g6lc_apu_cva6_cookie`) now runs the same image to the cookie.

## Verification

`run-exec.sh` (`APU_EXEC=1 APU_SYNTH=1`). Remote Verilator 5.008 (2026-09-15):
**`enc_check` PASS**; **`tgsi_check` PASS**; **`tb_g6lc_apu_resident` 179
checks / 739 clocks**; **`tb_g6lc_apu_hart` 186 checks / 3,077 clocks**,
cookie `0x600D000A` in the hart snoop and at `0x9003FF00`, TB peek 10/11.
`run-cva6-cookie.sh` rc=0: **`tb_g6lc_apu_cva6_cookie` 14 checks / 1,835
clocks**, cookie `0x600D000A` (CVA6 hart 1, control MMIO, `ExecEn=1`).
RISC-V cross-compile skipped on the builder (no gcc on PATH); the hex image
is checked in. Results also live in `AGENTS-todo.md`.
