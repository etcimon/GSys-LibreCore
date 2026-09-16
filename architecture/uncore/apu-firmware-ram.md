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

## Remaining blocking review findings

1. `in_win` and SRAM indexing truncate physical addresses to 32 bits. The
   leaf accepts arbitrary upper-bit aliases, not just the sign-extended
   addresses used by its diagnostic. This disagrees with the 64-bit xbar
   and PMP view. Deployment requires full-width physical containment and
   overflow-safe spans. Fix compiler/linker/VA-to-PA assumptions at their
   source; never normalize arbitrary AXI physical addresses to make a
   cookie pass. Existing alias-success tests are diagnostic debt, not ABI.
2. RAM has no trusted source/domain authorization. A DRAM hole reserves
   decode space but does not stop application or other DMA accesses.
   Protection must exist before access, with matched read/write provenance.
3. The RAM write-drain/strobe correction does not repair `g6lc_apu_axi4_lite`.
   That separate bridge still needs invalid-burst draining and split-write error
   aggregation. Integrate quarantine reporting and supervisor recovery without
   resetting a target underneath outstanding fabric transactions.
4. Narrow-read span/alignment and AXI lock/atomic/4-KiB policies need a full
   audit; successful fill/cookie tests do not establish all AXI semantics.

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
reproduced 170 failed checks before repair; the expanded suite now passes
**49 cases / 5,699 checks / 5,372 clocks**. It covers 2/16/256-beat rejected
writes, AW/W skew, live AW metadata changes, B stalls, missing data, malformed
WLAST quarantine, reset recovery and sparse/zero/illegal strobes with guard bytes.
The 4-KiB enabled/disabled lint and generic synthesis screens pass; a pre-map
`memory_collect` assertion retains exactly one `$mem_v2` enabled and zero disabled.
This is RAM-array retention evidence, not protected loading or a mapping-table proof.
The same focused run revalidates the CVA6 cookie: 14 checks / 1,835 clocks,
`0x600D000A`; five existing core SELRANGE warnings remain. No new firmware build
or protected S-mode/Linux boot was performed.

Rerun `run-fwram-only.sh` and `APU_SOC=1 APU_SYNTH=1`
on `run-virtio-mmio.sh` through the remote proxy. Current revalidation is
recorded in `AGENTS-todo.md` and `AGENTS-specs-to-tests.md`. Keep the upstream
unreset-SRAM read-data warning visible. No protected loader, S-mode domain,
actual DRAM, cache-coherent Linux execution or rendered surface follows.
