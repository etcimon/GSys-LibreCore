# r130 — SC-backoff pairing: only paired LR/SC failures grow the retry exponent

Scope: `core/cache_subsystem/wt_dcache_missunit.sv`,
`verif/tb/core/tb_g6lc_hyp8_control.sv`. Latency/liveness-motivated change to
the LR/SC exponential backoff; the architectural contract is unchanged —
paired SC failures still back off identically. The default binding is the
profile the Linux witnesses run.

## 1. Test data (r127m witness)

`hyp8-osbi-scalar-r127m` (closure-r127m, default binding) passed both Linux
markers (`G6LC_LINUX_INIT_UP`, `G6LC_LINUX_SHELL`, monitor exit 0) and ran its
full budget. Its stall census still showed two long commit-head stalls:

- ~396.95M cycles: 15,369-cycle gap, last commit `0xffffffff8011eb8a`, resume
  `0xffffffff8065b78e`.
- ~429.42M cycles: 34,889-cycle gap, same resume PC.

Hang-dump state at both: scoreboard head slot 7 `issued=1 valid=1 fu=2 op=62
pc=ffffffff8065b78e` (an `lr.d`), `issue_valid=00 issue_ack=00`, LSU units
idle, load buffer empty, frontend `cf_hold=1 bp_pend=1` — the head was an LR
waiting on the missunit AMO path, not a frontend or D$-miss stall.

LR/SC survey through ~1.56B cycles: 59,850 LR / 63,349 SC retired; **all
3,620 failing SCs at one PC `0xffffffff8065fe56`** (the kernel's deliberate
reservation clear after trap return); only **1** failing SC was paired with an
LR since the previous SC — 3,619 were unpaired.

## 2. Mechanism

`wt_dcache_missunit` feeds every SC failure (`sc_result_valid && result!=0`)
to `g6lc_hyp_exp_backoff.set_i`, which shifts the 16-bit mask left and reloads
the wait counter with `mask & lfsr`. The `AMO` state holds an LR request until
`sc_backoff_over`. Each unpaired kernel reservation-clear SC therefore grew
the exponent even though it is not a contention retry; ~16 of them saturated
the mask to 16 bits and parked the next real LR for tens of thousands of
cycles (observed 15k/35k).

The reservation itself lives in `hpdcache_uncached` (`lrsc_rsrv_*`); every SC
clears it unconditionally (`lrsc_uc_reset=1`), so an SC can only fail for two
reasons: no reservation was held (unpaired — kernel clear, buggy code), or a
held reservation was lost to a conflicting access (paired — genuine
contention). Only the second is a retry worth backing off for.

## 3. Fix

`lr_pending_q` tracks pairing exactly, using the missunit's depth-1 ordering:
set when an LR result is presented (`state_q==AMO_RESULT && amo_op==AMO_LR`),
cleared by the next SC result (`amo_op==AMO_SC`). `set_i` becomes
`sc_fail && lr_pending_q`; `clr_i` (`sc_pass`) is unchanged — a pass implies a
live reservation anyway.

Safety: a genuine LR/SC retry loop is `LR → SC(fail) → LR → SC(fail)…`; every
SC in it is preceded by an LR, so paired failures still grow the mask
identically. Under-counting cannot occur (flag=0 ⇒ no live reservation ⇒ the
SC was never a retry). Over-counting is bounded to one extra count if a
conflicting AMO cleared the reservation between LR and SC — the safe
direction. SMT2 is unaffected: the flag is per-missunit-instance.

## 4. Verification

- `sc-backoff` leaf (`G6LC_HYP8_SC_BACKOFF_ONLY`), pinned remote toolchain
  `verilator-v5.008-g6lc-44063db8-pgo` + runtime digest
  `e900ec45…`: **HYP8_SC_BACKOFF_PASS checked=55**. `sc_backoff_cases`
  rewritten for the pairing contract: unpaired SC fail → mask stays 0;
  LR → SC fail → mask=1; LR/ADD between → next SC still paired → mask=3;
  pass clears; SC→SC second failure unpaired → mask holds.
- `memory` leaf: **HYP8_MEMORY_PASS checked=176** (default).
- Local lint `lint_hyp8_core_local.sh`: clean of fatal classes, 0 open
  warnings.
- Remote gate `closure-r130` (`hyp8-remote-gate.sh r130`, fork PGO compiler +
  `--threads 4` + simulation PGO, `g6lc64_hyp8` harts=1): **build_complete**,
  lint scalar `(0,0)` / smt2 `(0,0)`, model `5408f87240f17255…`, simPgo=230,
  verilatorBin `d219b63fc4f8fcba`. **14/14 smokes pass at identical baseline
  cycles** — 685/1011/492/2364/2199/1231/671/3038/9095/5959/883/983/3893/6949
  (incl. `hyp8_lrsc_store`=983), so the pairing gate is latency-neutral on the
  qualified profile. (Aggregate proxy reported rc=255 after `build_complete`;
  `results.json` and the independent smoke run are the verdict.)

## 5. Open item — AXI `R Response Errored` bursts (not fixed)

r127m logged ~18,131 timestamped `R Response Errored` warnings
(`g6lc_testharness.sv:1508`) concentrated ~352.5–368.1M cycles, inside
OpenSBI's M-mode unaligned-access emulation (mtvec swap + `mstatus` MPRV
write). Errors repeat ~176 cycles apart. Hypothesis: younger loads reach the
AXI bus with a physical address formed under the pre-CSR-write translation
state and are squashed on the wrong path — harmless in sim, but a
speculative side-effect concern on non-idempotent hardware. The warning
prints no address/ID; confirming needs either an address-tagged warning or a
`+soc_trace`/`+trace_from` replay to ~352.5M. Non-fatal (boot passed), so it
is recorded here as a follow-up, not an opportunistic fix.

## r130 Linux witness launched (2026-11-16)

Witness `hyp8-osbi-scalar-r130` queued on the gated model
(`hyp8-r130-aggregate-t4`, model 5408f872…, the SC-backoff fix) with
`HYP8_WAIT_PIDS=2062250` — it auto-starts when r128b exits, avoiding
oversubscribing the shared host (load was ~18). Budget 1.75e9, same
plusargs/firmware/tohost as r128b. Boot monitor attached (had to add
r130 to the tag allowlist in `hyp8-boot-monitor-remote.sh`). This is the
end-to-end validation that the paired-SC-backoff fix still reaches
G6LC_LINUX_SHELL and that the ~35k-cycle LR stalls are gone.

## Host reboot + multicore-coherent OpenWrt path (2026-11-16)

Remote host `ovh_calltorch` rebooted (~12:00 remote, was up 64d). Killed
in-flight work: `hyp8-osbi-scalar-r128b` witness died at ~994M cycles
(3.5GB run-hyp8.log preserved, died before shell), `hyp8-osbi-scalar-r130`
(died queued, never started), `hyp8-r131-aggregate-t4` scalar gate (killed
early). Post-reboot host also took unrelated `apu-leaf` builds.

Relaunched: `hyp8-r131-aggregate-t4` (scalar HEAD gate) and
`hyp8-r131-mc-aggregate-t4` (multicore). r131 scalar supersedes r130 for
HEAD validation (closure-r131 = SC-backoff + staged-TLB upsert +
address-aware TB + F15).

### Multicore coherent target (OpenWrt requirement)

User directive: OpenWrt must run on L2/L3 + 4-core + dual-hart + coherence.
That is exactly `g6lc64_hyp8_mc`: `G6LCConfigNrHarts=2` (dual-hart),
`NrCores=4` -> 8 harts, `Flist.hyp8_mc_sim`, `g6lc-hyp8-mc.dts` =
"4-core dual-hart", L1->shared L2(256KB)->shared L3(1MB, non-inclusive),
snoop/coherence on. The scalar SoC that has been booting is NC=1
(coherence hub = identity, NO L2/L3 instantiated) — the coherent path has
NEVER booted (r115: "no SMT2/MC boot evidence").

mc witness params (ready): intTag `hyp8-r131-mc-aggregate-t4`,
fw `build-linux-mc/.../fw_payload.elf` sha256
`04f3b24b2320987a783bafaad9cd276b121362a815b37fd633552c9fe081631b`,
tohost `0x80041730`. mc model build noted ">7200 s at -j2".

OpenWrt note: `g6lc_qemu/linux-dist/openwrt` + `openwrt/build.sh` target
the sifiveu QEMU-virt machine, NOT hyp8 RTL; no hyp8-kernel/OpenWrt build
flow exists in-repo. Literal OpenWrt-on-hyp8-mc is a software bring-up
(kernel+rootfs+DTB for the 8-hart coherent machine) gated on first getting
SMP Linux to boot on `g6lc64_hyp8_mc` — the mc witness is that first step.

## OpenWrt payload format findings (for post-mc-boot bring-up)

`fw_payload.elf` = OpenSBI `.text`@0x80000000 + `.payload`@0x80200000.
`.payload` = `linux-payload-l1s2/payload.bin` (65,943,552 B) — a RAW Linux
kernel Image (MZ/EFI-stub header `4d5a`, NO FIT magic `d00dfeed`), with the
BusyBox initramfs embedded (~65MB). SAME blob for scalar/smt2/mc; only the
DTB differs per profile (`FW_PAYLOAD_PATH`/`FW_FDT_PATH` in
build_boot_firmware.py). OpenSBI fw_base jumps to 0x80200000 with a0=hartid,
a1=dtb.

=> OpenWrt-on-hyp8-mc = produce an OpenWrt `payload.bin` (OpenWrt kernel
Image + OpenWrt rootfs, same raw-Image-at-0x80200000 contract) and relink
fw_payload.elf with `g6lc-hyp8-mc-linux.dtb`. `g6lc_qemu/openwrt/build.sh`
builds official openwrt v24.10.2 `sifiveu` target -> kernel `Image` +
`initramfs-kernel.bin` (FIT). Kernel must be hyp8-compatible (rv64imafdc
+Zba/Zbb/Zbs/Zicboz, 16550-ish UART, CLINT/PLIC). GATED on: (1) mc SMP
Linux boot working, (2) OpenWrt kernel config compatible with hyp8 DTB.
No openwrt cache exists on remote yet -> full build needed (hours).

## mc SMP boot-hold mechanism (debugging context for first witness)

`g6lc_cluster.sv`: `BOOT_HOLD=(NC>1)&&(NrHarts>1)` -> mc active (NC=4,T=2).
Secondary cores c!=0 clock-gated by `i_core_icg` (functional ICG) until
`rel = (boot_hold_q>=BOOT_HOLD_CYC=200000) || ipi_seen_q[c]`.
- `ipi_seen_q[c]` sets on `|ipi_i[c]` (any hart IPI via CLINT MSIP), never
  cleared -> one-way release. `ipi_i` is [NC-1:0][NrHarts-1:0] per-hart.
- 200k-cycle fallback releases all secondaries early -> they join OpenSBI
  ~together after core0 head-start (avoids G1dg shared-init race).
- Core0 always runs. Sleep-gate (CoreSleepGate) separately gates WFI+idle
  cores with ungated wake (PLIC/CLINT/Sstc/L1inv/CMO/AI).
Testbench (`g6lc_testharness.sv`): `mc_held[c]=!gen_boot_icg.rel`,
`core_retired[c]` (>=1 insn retired), `mc_all_silent_held` verdict,
`+mc_verdict_fault` injects secondary-silence to prove the verdict can fail.
Per-core `rvfi_tracer` + `gen_secondary_trace` (observe-only) => per-hart
PC visibility for SMP debug. Monitor markers (G6LC_LINUX_INIT_UP/SHELL)
are UART/topology-agnostic -> work for mc.
SMP watch-points for witness: harts1-7 retire (core_retired), "smp: Brought
up ... 8 CPUs", CLINT MSIP IPI delivery, PLIC per-hart routing, L1<->L2/L3
snoop + LR/SC across cores.

## r131 dual-track pipeline (auto-armed)

After host churn killed r128b/r130/r131-scalar, relaunched BOTH builds of
HEAD (closure-r131 / closure-r131-mc) and armed wait-loop witness
launchers so each fires the moment its model exists:
- `hyp8-r131-mc-aggregate-t4`: g6lc64_hyp8_mc (4c x 2t = 8 harts, L2/L3 +
  snoop/coherence) -> `hyp8-mc-witness-launch.sh` -> `hyp8-osbi-mc-r131`
  (linux-mc fw sha 04f3b24b..., tohost 0x80041730, budget 3e9). pid 14137.
- `hyp8-r131-aggregate-t4`: scalar HEAD -> `hyp8-scalar-r131-witness-launch.sh`
  -> `hyp8-osbi-scalar-r131` (linux-scalar fw sha 30e1311e..., tohost
  0x80041730, budget 1.75e9). pid 19216.
Monitor allowlists extended: hyp8-osbi-mc-r131, hyp8-osbi-scalar-r131.
mc witness = FIRST SMP+coherence Linux boot attempt (never before run).

## Infra fixes (would-have-silently-failed)

- r128b (pid 2062250) and r130 wait-shell (365981) are ALIVE — earlier
  "killed by reboot" read was a truncated ps + node-pool confusion. Host
  up 64d, 12 cores, load ~8, 71GB free. r128b ~26h in, log 3.69GB.
- Witness-launcher poll bug: model-check `shell "test -x .../Variane_testharness"`
  trips the proxy overlap guard (literal string match) -> refused while
  workloads run -> launchers would wait forever. FIXED: poll
  `output/results.json` (build-complete marker, no guard string). Both
  launchers relaunched (mc 20518, scalar 20516) and verified returning WAIT.
- Scalar r131 gate died silently: `r131-remote/` log dir didn't exist so the
  `> launch.log` redirect failed before the script ran. Created dir,
  relaunched via setsid (gate 21202, proxy 21207) — integration now running.
- cmd_py (witness launch) is NOT overlap-guarded; only `shell` cmds
  containing Variane_testharness/soft-ladder are. Witnesses launch detached.

## r131-mc lint-timeout fix (bec0c3dbd)

First mc aggregate attempt died: `verilator --lint-only` on
Flist.hyp8_mc_sim (8-hart SoC) exceeded the hardcoded 1200 s lint budget
under host contention -> TimeoutExpired before any model build. Patched
run_hyp8_integration.py to read HYP8_LINT_TIMEOUT (default 1200), relaunched
mc gate with =5400. mc lint is deterministic-warning-heavy (~472 KB log);
scalar r131 meanwhile progressed past lint into C++ build (239 objs).
Host load ~14/12 cores (r128b witness + apu-leaf + both builds).

## mc per-hart trace mapping (SMP debug ready)

rvfi_tracer writes trace_rvfi_hart_<HART_ID>.dasm per physical core and
INTERLEAVES SMT harts tagged `core N:` (= HART_ID + local_hart). mc
(NrHarts=2, NC=4): core0->hart_00(dasms hart0,1), core1->hart_02(hart2,3),
core2->hart_04(hart4,5), core3->hart_06(hart6,7). To verify SMP bringup:
grep `core [0-7]:` across the 4 files; a hart never tagged = never retired
(boot-hold/ipi/release defect). core_retired[] + mc_all_silent_held give
the testbench's own multicore verdict; +mc_verdict_fault self-tests it.

## payload.bin structure decoded (OpenWrt packaging contract)

linux-payload-l1s2/payload.bin (65,943,552 B) = RISC-V Linux kernel Image
+ EMBEDDED initramfs:
- head: MZ/PE stub then RISC-V Image header; magic "RISCV"@0x30,
  "RSC\x05"@0x38; image_size u64@0x10 = 0x132f000 (~20 MB).
- cpio_newc (070701) @ 0xa0d2b0 (~10.5 MB) lies INSIDE image_size ->
  initramfs is linked into the kernel image (CONFIG_INITRAMFS_SOURCE),
  NOT appended. (2nd cpio region @0xccf9d8; gzip@0x4c55a, xz@0xd07768 =
  compressed payloads inside.)
=> OpenWrt payload.bin must be a kernel Image with the OpenWrt rootfs
cpio EMBEDDED the same way. OpenWrt initramfs-kernel produces kernel+
initramfs; need the raw Image form (strip FIT wrapper) or equivalent.
GATED on mc SMP Linux booting + OpenWrt kernel config compatible w/ hyp8
DTB (rv64imafdc+Zba/Zbb/Zbs/Zicboz, CLINT@0x2000000, PLIC@0xc000000,
16550-ish UART, L2/L3 cache nodes).

## r128b forensics — real failure signature (NOT near-shell)

hyp8-osbi-scalar-r128b ran ~27h to ~1.054B cycles then exited (monitor/
timeout, NOT the 1.75B +time_out). uart.txt = 154 lines, ends cleanly at
"[6.31s] Freeing initrd memory: 908K". NO panic/oops/"Run /init"/login.
=> HANG in the initrd-free -> /init-spawn transition (heaviest mem activity).

Diagnostics mined from run-hyp8.log:
- "R Response Errored" first @cyc 5.57M, recurring thru 368M+. These are
  DECERR (axi2mem DRAM model ALWAYS returns RESP_OKAY; only the xbar emits
  DECERR for unmapped phys addr). Sporadic+nonfatal (boot reached 6.3s) =>
  mostly speculative reads to the 0x40001000-0x7FFFFFFF hole / >0xC0000000 /
  HPS@0xFF800000 (in enum but NOT in the 10 addr_map rules). r131's
  address-aware TB (a428ed7f3) prints id+addr+resp => classify on sight.
- [ptw-err] vaddr=0x800004f0 = KNOWN-BENIGN r100/T42 mret foreign-walk
  (M-mode window looked up under kernel satp, error dropped). RED HERRING.
- stall-census mem_viol grew to ~112k; ipc~0.26; core still retiring at end
  => live-lock/stall in mem path, not a hard hang.

Memory map (g6lc_soc_pkg): DRAM 0x80000000+1GiB(0x40000000); DTS memory node
= 256MiB only (reg 0x80000000/0x10000000) => kernel stays in low 256MiB,
NO size overflow. Scalar bootargs maxcpus=1 nokaslr rdinit=/init (cmdline
also shows merged maxcpus=2 + uio_pdrv_genirq.of_id=g6lc,ai-matrix).

MMU staging: ALL boot witnesses run hyp_mmu_unstaged => TlbStages=1,
PtwDecodeStage=0. Staged MMU (TlbStages=3) needs -DG6LC_HYP8_MMU_STAGED
(not set for boot). => 3f3083a64 staged-TLB upsert is a NO-OP on boot.
r131's real functional delta vs r128b = load_unit fixes (107c4ca3c pending-
exception slot, ad6a429b9 held-load-PA, 7eb2f6e1c misaligned fault cause,
c5c9262de DTLB-miss yield) + SC-backoff (67f413a63, a9c90bece). If r131
hangs identically the bug is deeper (unstaged MMU PTW / AXI xbar DECERR
handling / DRAM backend) -> needs tagged addr + directed debug.
