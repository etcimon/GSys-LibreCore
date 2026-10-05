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
- Authorization compares the supplied trusted source/hart ID, never AXI PROT.
  The review captures AW and AR source IDs at AXI4 handshake in `g6lc_apu_th`
  and retains them through conversion. A live later source must neither upgrade
  a denied request nor revoke an already accepted grant. Tests vary both source
  directions, including delayed W. This fixes metadata retention, not provenance.
- `g6lc_apu_axi4_lite` captures the live admission epoch when AW or AR is
  accepted. While that beat is presented on AXI-Lite, the wrapper stamps the
  captured epoch, so a later reset or queue-stop cannot retag it. A split
  64-bit store keeps the same captured epoch for both halves. Direct lite
  masters leave the hold low and stamp the live epoch.
- `g6lc_apu_xbar` exports `backend_reset_req_o` and
  `backend_queue_stop_req_o`, and takes `backend_reset_done_i` and
  `backend_idle_i`. Control already withholds reset ACK until teardown is
  done and every queue is idle, and withholds each queue-stop ACK until that
  queue is idle. The requests stay asserted until those inputs release them.
  Enable=0 holds both requests at 0. `g6lc_apu_th_load` still drives done
  and idle high and sinks the requests, so the cookie path is unchanged.
  This is the platform drain, not a mapping or program lease.
- Default testharness `NB_MST = NB_PERIPHERALS`. `+define+G6LC_APU` adds
  idx 10/11/12 and instantiates `g6lc_apu_th_load` (xbar + fwram + DRAM hole
  + hart-1 boot). Testharness only stitches xbar masters. The DMA AXI master
  is exported from the compositor onto xbar `slave[2]` through
  `g6lc_apu_tdma` under `+define+G6LC_APU` (Enable=1 so AI still
  forwards; `ApuHarness.DmaReadEn=0` keeps the APU side idle).
  FPGA/Altera `NrSlaves` stays 3. A legal DMA window sits in DRAM
  lo/hi, never firmware RAM.
- `ApuHarness` needs two physical cores and `NrHarts=1`. Control is tagged
  as firmware hart 1 (bring-up). Cluster `PerCoreBoot` is generic; the load
  box supplies per-core PCs. Physical display stays disabled.

## Remaining boundary gates — 2026-09-15

Control and firmware RAM admit only the reserved hart. RAM captures that
decision at AW/AR accept, so a later hart pin does not retag the beat. AXI
id and PROT are not authority. Remote 2026-09-22: `tb_g6lc_apu_grant` 18
checks / 12 clocks; `tb_g6lc_apu_fwram` **52 cases / 5,739 checks / 5,479
clocks**, errors=0. The 4 KiB RAM screen has no latches: Enable=0 is 245
cells / 16 flip-flops; Enable=1 is 106,018 cells / 32,941 flip-flops, with
one `$mem_v2` before mapping. `g6lc_apu_src_guard` stops a non-firmware
core before the hub (2026-09-22, 4 cases / 31 checks / 60 clocks). The
firmware hart is wires: 6 ports, no cells. The application hart is 2,193
cells / 29 flip-flops, no latches. `g6lc_apu_xbar_hart` reads the
crossbar's prepended port index (5 checks). The cluster port is the
firmware hart. Debug and DMA are hart 0. The low ID bits are not a hart.
Narrow reads are one aligned beat. A 64-bit fill that crosses a 4 KiB page
is SLVERR. Exclusive lock and ATOP do not modify SRAM and never return
EXOKAY. `fault_o` stays high, with no response, while a mismatched WLAST
is still outstanding, and reset is the release. Remote 2026-09-22:
`tb_g6lc_apu_fwram` **56 cases / 5,799 checks / 5,631 clocks**, errors=0.
The 4 KiB screen has no latches: Enable=0 is 274 cells / 17 flip-flops;
Enable=1 is 106,176 cells / 32,943 flip-flops, with one `$mem_v2` before
mapping. `g6lc_apu_th_load` forwards `ram_fault_o`. `g6lc_apu_fault_sup`
watches it from the pad clock and the pad reset. While the pin is high,
`reset_o` gates `rstgen`, so `ndmreset_n` resets the crossbar and the RAM
together. The request stays asserted until the pin drops. There is no
timeout. Remote 2026-09-22: `tb_g6lc_apu_fault_sup` **3 cases / 18 checks
/ 54 clocks**, errors=0. Fixture synth, no latches: Enable=0 is 4 ports
and no cells; Enable=1 is 1 cell / 1 flip-flop. The supervisor's own
reset is not `ndmreset_n`. The CVA6 cookie was not re-run.
Quiesce buffered transactions before changing ownership or restarting firmware.
Full-width firmware-RAM checks, hardware-valid mapping storage, an exec
cancel that still completes, and xbar reset/queue-stop pins held until the
platform reports idle are in. Truthful exec geometry, the idle lease pin,
and AXI4-Lite burst/error handling are in. `g6lc_apu_sched` runs memory
and exec under one mailbox (2026-09-22, 4 cases / 107 checks / 161
clocks). An op is presented to one client. Exec does not read the
mapping. Fixture synth, no latches: Enable=0 is 10 ports and no cells;
Enable=1 is 28,966 cells / 4,839 flip-flops. `ApuHarness` keeps both
off. Command DMA reads the published slot, not the mailbox base
(2026-09-22, mem 10/19/227). A missing or stale handle issues no read.
Scatter-gather and the used ring still take raw maps. The CVA6 cookie
was not re-run.

`g6lc_apu_axi4_lite` drains a rejected write for every `AWLEN+1` beat before
B, and a rejected read for every `ARLEN+1` beat with RLAST only on the last.
B is not offered while write data is still outstanding. A WLAST that does
not match the remaining count enters quarantine until reset, with no
response and no further accept. A split 64-bit store keeps an earlier
half's error when the later half returns OKAY. The bridge still accepts
only aligned single-beat words and one aligned 64-bit store. Remote
2026-09-22: **9 cases / 47 checks / 95 clocks**, errors=0. Fixture synth,
no latches: Enable=0 is 234 cells / 16 flip-flops; Enable=1 is 1,606 cells
/ 266 flip-flops. This is not a general downsizer and not a source grant.

The source retention fix adds two `HartIdWidth` register banks, only when enabled,
with no new clock/CDC or additional transaction latency. Disabled synthesis must
retain only existing error response machinery. Upstream FPnew packed-range lint
is scoped to `fpnew_pkg.sv` in `apu_axi.vlt`; first-party checks remain active.

The optional BIOS manager uses the supervisor loading/status seam, never this
private port concurrently with the service. Linux retains ordinary virtio-gpu
ownership. See `apu-firmware-domain.md` for the three independent lifetimes.

## Verification

`run-soc.sh` (`APU_SOC=1 APU_SYNTH=1`) and `run-dma-init.sh`. Historical remote
Verilator 5.008 (2026-09-15): **th** 6/32/113; **xbar** 3/17/30 (historical;
the 2026-09-22 drain-pin run is below); **th_load**
3/21/16; **dma_init** 10/19 (DRAM lo payload `0xaabbccdd`, hole not
stolen). Historical xbar screen: enabled 22,269 cells / 2,201 sequential
bits; disabled 124 / 16. Firmware RAM screening synth (4 KiB) enabled
104,347 / 32,930 sequential; disabled 66 / 7.
Host `map_check` / `boot_check` / `load_check` lock the DRAM hole, hart-1
reset PC, and compositor rule table. Not mapped area or STA. Results also
live in `AGENTS-todo.md`.

Review source-retention regression supersedes the earlier th count: **12 cases /
60 checks / 221 clocks**, errors=0. The AXI4 admission-epoch run on 2026-09-22
includes that coverage and one split control write admitted before a guest
reset: **13 cases / 73 checks / 271 clocks**, errors=0. B is SLVERR and the
queue select is unchanged; a later control read still returns the magic value.
Same remote run: sys 5/148/669, soc 16 checks/44 clocks, attach 4/32/77,
axi-lite 318 checks/1601 clocks. `g6lc_apu_th_fixture` synth has no latches.
Enable=0 is 124 cells / 16 flip-flops; Enable=1 is 24,294 cells / 2,797
flip-flops. Current compositor/native/CVA6 evidence and remaining warning
limitations are recorded in the root review test map.

The xbar drain-pin run on 2026-09-22 supersedes the 3/17/30 xbar count.
`tb_g6lc_apu_xbar`: **5 cases / 29 checks / 84 clocks**, errors=0. Queue 0
stays stopped while `backend_idle` is `2'b10`, including after a firmware
queue-stop ACK, and drops after idle is `2'b11`. Device reset stays
asserted through a firmware reset ACK and through idle while teardown is
still 0, and drops only after idle and `backend_reset_done`. The disabled
instance holds both request pins at 0. `g6lc_apu_xbar_fixture` synth has no
latches. Enable=0 is 124 cells / 16 flip-flops; Enable=1 is 23,361 cells /
2,477 flip-flops. Lint of `g6lc_apu_th_load_fixture` passes with
`--timing` because of the compositor's existing `#1` hex hold. The CVA6
cookie was not re-run.
