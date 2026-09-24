# APU firmware RAM window

**Domain:** graphics uncore · **Status:** default-off testharness SRAM; not a protected boot store

`g6lc_apu_fwram.sv` provides a `tc_sram` AXI4-64 target at the configured
firmware window. `ApuHarness` uses `0x90000000` / 256 KiB, testharness rule
12. The window sits between DRAM lo/hi fragments; neither GPIO/AI nor guest
virtio is part of it. See `apu-firmware-domain.md` for the target ownership
contract and optional BIOS-managed loading.

## Implemented interface and review corrections

- Disabled configurations are AXI error responders, not writable memories.
- Byte/halfword reads are single-beat. Word reads are single-beat and
  word-aligned. 64-bit reads require INCR, eight-byte alignment, `len<=15`
  and a contained span. Stream8 I$/D$ 16-byte fills use `size=3,len=1`.
- Unsupported reads return SLVERR for **all `ARLEN+1` accepted beats**, with
  RLAST only on the last response. The 16-beat data-path limit is not an
  error-response limit. Review tests cover 17- and 256-beat rejections,
  including the disabled responder, and all seven misaligned 64-bit offsets.
- Writes support aligned single-beat words/doublewords only. Word WSTRB must
  be a subset of the addressed four-byte lane; sparse and zero strobes are legal.
  Out-of-lane strobes return SLVERR with no SRAM write.
- Unsupported writes, including disabled RAM, accept all **AWLEN+1** data beats
  before returning SLVERR. AW-first, W-first and simultaneous arrivals share
  that rule. AW metadata is retained; response ID/status remain stable under
  B backpressure. Missing data cannot complete or admit another transaction.
- Early or missing WLAST relative to accepted AWLEN enters fail-closed quarantine:
  no address/data acceptance or response until coordinated fabric reset. No
  timeout-success, guessed burst boundary or local firmware reset may reuse it.
  These policies do not make this a complete CVA6/Linux memory target.
- No new clock/reset or SRAM macro is introduced. The existing full-width LEN
  counter also tracks rejected writes; captured lane-mask state and an eight-bit
  strobe check protect delayed W. Legal write latency is unchanged. Synthesis
  remains a screen, not timing closure.
- The window is the full physical range `[FirmwareRamBase, FirmwareRamBase +
  FirmwareRamBytes)`. `in_win` and the SRAM index use that 64-bit offset.
  A sign-extended address and any other upper-bit alias are outside the
  window and complete as SLVERR without an SRAM write. A 64-bit fill whose
  last byte falls outside the window, including a span that wraps the top
  of the physical space, is rejected for every accepted beat. Canonical
  `0x90000000` accesses are unchanged. A reserved firmware hart is captured
  at AW/AR accept. AXI id and PROT do not authorize the beat.
- A narrow read is one beat, aligned to its size. A byte store or a
  halfword burst is SLVERR and does not write. A 64-bit INCR that would
  leave its 4 KiB page is SLVERR for every accepted beat. A fill that ends
  on the page boundary still completes. Exclusive `AxLOCK` and every ATOP
  are rejected, SRAM is unchanged, and the response is never EXOKAY. An
  AtomicLoad, AtomicSwap, or AtomicCompare also returns one R so the
  master can finish. AtomicStore returns B only.
- `fault_o` is high only while a mismatched WLAST is quarantined. B and R
  stay low, and no new address is accepted, so the transaction is still
  outstanding. Reset clears the pin. The rejected store does not land, and
  a later legal store completes. `g6lc_apu_th_load` forwards the pin as
  `ram_fault_o`. `g6lc_apu_fault_sup` watches that pin. Its own reset is
  the pad `rst_ni`, not the `ndmreset_n` it requests. The request stays
  high until the pin drops. There is no timeout.

## Remaining blocking review findings

1. The module denies a supplied hart other than the reserved firmware hart.
   The decision is captured at AW/AR accept, so a later pin change does not
   retag that beat. AXI id and PROT are not authority. The DRAM hole still
   does not identify the master. `ariane_testharness` ties both RAM hart
   ports from the crossbar port index. The cluster port is the firmware
   hart because the per-core guard already stopped every other hart.
   Debug and DMA ports are hart 0. The low ID bits are not a hart.
2. `g6lc_apu_axi4_lite` drains rejected bursts and keeps a split store's
   earlier error (2026-09-22, 9/47/95). A mismatched WLAST quarantines
   that bridge until reset. Firmware RAM now reports the same kind of
   stall on `fault_o` and releases it on reset. `g6lc_apu_fault_sup`
   requests a fabric reset while `ram_fault_o` is high and holds that
   request until the pin drops (2026-09-22, 3 cases / 18 checks / 54
   clocks). The supervisor's own reset is the pad `rst_ni`. `ndmreset_n`
   resets the master and the RAM together. There is no timeout. Enable=0
   is 4 ports and no cells. Enable=1 is 1 cell / 1 flip-flop, no latches.
3. Narrow, exclusive, ATOP, and 4 KiB checks are in for this RAM
   (2026-09-22, fwram 56/5799/5631). The slave does not perform the atomic.
   It is not an exclusive monitor.

## Load and restart contract

`HexFile` / `+APU_FW_HEX=` and the compositor's simulation `#1` preload hold
are test utilities only. Synthesis does not load a file and ties `fw_ready`
high. Unwritten SRAM words are not guaranteed zero; scanning a hex prefix
for nonzero words is not an image length/authentication check.

The platform or optional BIOS supervisor adapter must validate an image
manifest, initialize code/data/BSS/stack, synchronize caches and instruction
fetch, install protection, and release only the reserved firmware hart.
Image replacement requires admission stopped and all DMA/command/program/
surface leases retired. Software reset does not erase SRAM or establish
new mapping validity. A real boot controller and readiness state are still
required; do not synthesize a time delay as a loader.

Linux FDT/memory discovery must reserve the entire private window (and any
private DMA pool) and exclude it from ordinary RAM allocation; the supervisor
must enforce permissions independently. Provisioning grants are narrower
than runtime control grants and revoked before serving guest input. Exact
image/ABI/epoch identity is part of health, not a magic word at `0x9003ff00`.

## Evidence and regressions

Historical `d74010111` evidence: `tb_g6lc_apu_fwram` 6 cases / 317 checks /
1,421 clocks; CVA6 fetch and cookie suites described in `apu-cva6-fetch.md`.
Generic 4-KiB screening formerly reported 105,439 cells / 32,938 sequential
bits enabled and 166 / 15 disabled; these are not 256-KiB SRAM-macro area.

The read review first reproduced six failures. The write follow-through initially
reproduced 170 failed checks before repair; that suite passed
**49 cases / 5,699 checks / 5,372 clocks**. The full-physical-address run on
2026-09-22 passes **49 cases / 5,710 checks / 5,389 clocks**, errors=0.
Sign-extended `0xffffffff90000000` and bit-32 `0x190000000` reads and writes
are SLVERR and leave the canonical word unchanged. A wrapping 64-bit span is
rejected. It covers 2/16/256-beat rejected
writes, AW/W skew, live AW metadata changes, B stalls, missing data, malformed
WLAST quarantine, reset recovery and sparse/zero/illegal strobes with guard bytes.
The 4-KiB enabled/disabled generic synthesis screen on 2026-09-22 passes,
with no latches. Pre-map `memory_collect` retains exactly one `$mem_v2`
enabled and zero disabled. Enable=0 is 245 cells / 16 flip-flops. Enable=1
is 105,946 cells / 32,940 flip-flops; the 4 KiB array is flops, not a macro.
This is RAM-array retention evidence, not protected loading or a mapping-table proof.
The earlier write follow-through revalidated the CVA6 cookie at 14 checks /
1,835 clocks, `0x600D000A`, with five existing core SELRANGE warnings. The
2026-09-22 physical-window run did not re-run that hart. The reserved-hart
run on 2026-09-22 passes **52 cases / 5,739 checks / 5,479 clocks**,
errors=0. Hart 0 reads and writes of the canonical word are SLVERR and
leave `0x0003f117` unchanged. A hart pin that changes after AW or AR
accept does not retag the beat. PROT `3'b111` with a nonzero AXI id still
completes for hart 1, and privileged PROT does not admit hart 0. The 4 KiB
screen has no latches. Pre-map `memory_collect` keeps one `$mem_v2` when
enabled and none when disabled. Enable=0 is 245 cells / 16 flip-flops.
Enable=1 is 106,018 cells / 32,941 flip-flops. `tb_g6lc_apu_grant` passes
18 checks / 12 clocks on the shared hart compare. This run did not re-run
the CVA6 cookie. The narrow and atomic run on 2026-09-22 passes **56 cases
/ 5,799 checks / 5,631 clocks**, errors=0. An aligned halfword completes.
A misaligned halfword, a narrow burst, and a byte store are SLVERR and
leave the word unchanged. A 16-byte fill that ends on a 4 KiB boundary
completes, and the next longer fill is SLVERR. Exclusive lock and ATOP
swap/store do not write and never return EXOKAY. Swap also returns one R.
`fault_o` stays high with no B while a mismatched WLAST is outstanding.
Reset clears it, the store has not landed, and the next store completes.
The 4 KiB screen has no latches. Pre-map `memory_collect` keeps one
`$mem_v2` when enabled and none when disabled. Enable=0 is 274 cells / 17
flip-flops. Enable=1 is 106,176 cells / 32,943 flip-flops. This run did
not re-run the CVA6 cookie. No new firmware build or protected S-mode/Linux
boot was performed.

Rerun `run-fwram-only.sh` and `APU_SOC=1 APU_SYNTH=1`
on `run-virtio-mmio.sh` through the remote proxy. Current revalidation is
recorded in `AGENTS-todo.md` and `AGENTS-specs-to-tests.md`. Keep the upstream
unreset-SRAM read-data warning visible. No protected loader, S-mode domain,
actual DRAM, cache-coherent Linux execution or rendered surface follows.
