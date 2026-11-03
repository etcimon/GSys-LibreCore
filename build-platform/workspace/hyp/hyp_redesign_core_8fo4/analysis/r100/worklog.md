# r100 — Linux boot witness on the r99 tree: trace-side defects on the boot path

Scope: run the pinned OpenSBI + Linux firmware (`linux-scalar`, `fw_payload.elf`
`ac36f379…`) on the r99 scalar model, classify from positive milestones only,
and fix every defect that stops the witness. Instrument: remote testharness
(`ovh_calltorch`), pinned `verilator-causal` (5.008 mod, bin `3e622e33…`),
`-O3`, `+time_out=` raised above the 40 M `rvfi_tracer` default.

## Payload identity (what "OpenWRT boot" means for this witness)

`/opt/testharness/runs/linux-payload-l1s2/payload.bin` (sha `da38306f…`,
65,943,552 B) = OpenWRT-built kernel `Image` (19,774,464 B, byte-identical to
`openwrt/build_dir/target-riscv64_riscv64_musl/linux-sifiveu_generic/Image`,
`linux-6.6.93`) padded to 0x3E00000 + `initrd.cpio` (931,840 B). The initrd is
a **busybox** init: `/init` mounts proc/sys/dev, prints `G6LC_LINUX_INIT_UP`,
`uname -a`, cpuinfo, uptime, then `exec /bin/sh` after `G6LC_LINUX_SHELL`.
Bootargs `console=ttyS0,115200 earlycon=sbi maxcpus=2 nokaslr rdinit=/init
loglevel=7`. The strongest userspace milestone this payload can prove is
`G6LC_LINUX_INIT_UP`; a procd/OpenWRT rootfs boot is not in the payload.

Symbols: `linux-6.6.93/{vmlinux,System.map}` are from the later
`Image-initramfs` build of the same tree; `.text` symbols are expected to
match but every symbolized PC must be spot-checked (code bytes at that
address in `Image` vs `vmlinux`) before being trusted.

Milestone ladder: OpenSBI banner → `Domain0 Next Address` → kernel PC ≥
0x80200000 → `Linux version` (earlycon=sbi) → `G6LC_LINUX_INIT_UP` →
`G6LC_LINUX_SHELL`.

## Issue 1 — stale LSU-bypass head re-captured as a store mask (cycle 24,288)

- Witness `hyp8-osbi-scalar-r99` (model `d4b061a0…`): `gen_paddr_chk[1]
  .lu_paddr_captured tid=16 wmask=ff` — commit **port 1**, which never
  retires stores, so the record was a non-store carrying a store mask.
- Mechanism: `g6lc_rvfi.sv` derived `lsu_rmask/lsu_wmask` from
  `lsu_ctrl.fu/be` without `lsu_ctrl.valid`. The hyp8 registered bypass head
  (`lsu_bypass.sv` `lsu_ctrl_o = head_q`) keeps a popped request's
  `fu/be/trans_id` with `valid=0`; after `_bss_zero` (last `sd zero` →
  0x80044fe8 = `_bss_end`) ~130 memory-free cycles re-wrote `wmask=ff` onto
  the stale tid every cycle, and the 32nd following instruction
  (`NR_SB_ENTRIES=32`) inherited it after its issue-clear.
- Fix: probe struct `+lsu_ctrl_valid`; both masks qualified. Commit
  `8fa21e7fd`.

## Issue 2 — staged probe frames zeroed on flush (cycle 1,160,947)

- Witness `hyp8-osbi-scalar-r100b` (model `dd393845…`): `gen_paddr_chk[0]
  .lu_paddr_captured tid=13 wmask=ff` at `$time` 1,160,959 in
  `sbi_scratch_alloc_offset`.
- Diagnostic rerun `hyp8-osbi-scalar-r100d` (`+stq_trace +smt_flow_trace
  +trace_from=1160840 +trace_to=1160970`): id 13 = `sd ra,40(sp)`
  @0x80003916 — STQ push at 1160942, younger `bnez` mispredict at 1160943
  (`flush_ctrl_if`), legitimate retire at 1160944. `$time` = core cycle + 12.
- Mechanism: `g6lc_rvfi_probes.sv` zeroed staged frames without a retire on
  `flush_i`; the frame holding the push strobe was dropped. Same clear loses
  any older in-flight instruction's address/mask capture, operand re-capture
  and branch record staged across a younger redirect.
- Fix: frames are never cleared on `flush_i` (superset of r59b). Verified by
  r101 (below).

## Issue 3 — foreign instruction PTW error attached to the mret-target fetch (RTL)

- Witness `hyp8-osbi-scalar-r101` (model `b8ad69a1…`): OpenSBI complete,
  kernel entered at cycle 21,403,879, then `panic → machine_restart` spin
  before earlycon. Oops recovered from the RVFI store records into the
  printk ring buffer (`tmp/r101_ringbuf.py`): instruction page fault,
  `sepc == stval == __sbi_base_ecall+0x1a`, on the kernel's first `ecall`.
- Mechanism (`[ptw-err]`/`[mmu-ife]` always-on probes): after `mret` the CSR
  context switches before the registered redirect reaches the frontend; the
  still-presented M-mode window 0x800004f0 is walked under the kernel's satp,
  faults ~25 cycles later, and `g6lc_mmu.sv` attached any active instruction
  walk's error to the pending fetch (the data side already had T42).
- Fix: `ptw_walk_is_fetch` (page-granular `update_vaddr == fetch_vaddr`)
  gates the ITLB-miss error arm; `G6LC_MUT_MMU_PTW_FOREIGN` restores the
  pre-fix shape. Commit `9d563e41f`. r102 printed `Linux version 6.6.93` —
  the first kernel console text on any hyp8 model.

## Issue 4 — abort-path drain before the head-arm publish (assertion legality)

- Witness `hyp8-osbi-scalar-r102` (model `0d899b57…`): kernel at
  `Initmem setup node 0`, then `load_unit.sv misaligned_entry_excepts`
  slot 5 (`rkill=1 valid_o=0 flushed=0 canc=0`) at cycle 32,048,297.
- Diagnostic `hyp8-osbi-scalar-r103d2` (windowed `+ld_state +smt_flow_trace
  +stq_trace +trace_from/to +smt_flow_lo/hi`): `ld a5,0(a0)` at
  `set_pfnblock_flags_mask+0x6` executed speculatively with stale `a0=1`
  (VA 0x1, misaligned, DTLB miss) → granted → ABORT_TRANSACTION; the killed
  tag's 1-cycle-hit response landed in the kill cycle → slot marked `rkill`
  → drained one cycle before the WAIT_TRANSLATION head arm re-presented
  `ex_i` and published the exception. No architectural loss: the completion
  is owed and delivered by the FSM head.
- r104 (derived ex_pend_set/tombstone hardening) reproduced the identical
  failure — that mechanism is real but was not the live path; it is kept.
- Fix: the assertion accepts an `rkill` drain while the bypass head still
  owns the slot's tid; `ex_pend_set` no longer double-pushes under
  `LoadExPubStages==1`; the dead-record tombstone is tid-guarded. The five
  unbounded `+smt_flow_trace` printers take `+trace_from/+trace_to`; the
  memory leaf list gains `g6lc_lu_result.sv`. Commit `b12a2d1f1`.

## Evidence

| run | model | result |
|---|---|---|
| `hyp8-r99-aggregate-c2` | `d4b061a0…` | r99 build of record |
| `hyp8-osbi-scalar-r99` | `d4b061a0…` | abort @24,288 (issue 1) |
| `hyp8-r100-aggregate-c1` / `-smokes-c1` | `dd393845…` | lint rc=0 `%Error=0`, census identical (602/623/688); smokes 7/7 cycle-identical |
| `hyp8-osbi-scalar-r100b` | `dd393845…` | abort @1,160,947 (issue 2); `-r100d` windowed rerun deterministic |
| `hyp8-r101-aggregate-c1` / `-smokes-c1` | `b8ad69a1…` | identical census; 7/7 |
| `hyp8-osbi-scalar-r101` | `b8ad69a1…` | OpenSBI complete, kernel entry @21,403,879, panic on first ecall (issue 3) |
| `hyp8-r102-aggregate-c1` / `-smokes-c1` | `0d899b57…` | identical census; 7/7 |
| `hyp8-osbi-scalar-r102` | `0d899b57…` | `Linux version 6.6.93` + early console; abort @32,048,297 (issue 4) |
| `hyp8-r103-aggregate-c1`, `hyp8-osbi-scalar-r103d2` | `52d4b233…` | windowed diagnostic, deterministic reproduction |
| `hyp8-r104-aggregate-c1`, `hyp8-osbi-scalar-r104` | `c8ff2079…` | hardening only; same abort (mechanism not live) |
| `hyp8-r105-aggregate-c1` / `-smokes-c1` / `-memleaf-c2` | `7516426f…` | identical census; 7/7; `HYP8_MEMORY_PASS checked=160` |
| `hyp8-osbi-scalar-r105` | `7516426f…` | past 32.8 M cycles, kernel console live; running toward `G6LC_LINUX_INIT_UP` |

All sims: remote testharness, pinned `verilator-causal` 5.008 (bin `3e622e33…`),
`-O3`, ≈3.2–3.4 kcycles/s; `+time_out=` must be raised above the 40 M
`rvfi_tracer` default or the run ends as "(tohost = 0x7FFFFFFF)".

Issues 1, 2 and 4 are trace/assertion-side; issue 3 is an RTL translation
hazard in the fetch interface. No boot claim beyond the UART milestones
listed above is made by this worklog.

Issue 5 was corrected in `492c9959c`: the IQ arbiter's sticky-kill
carry matched an unowned zero record by TID alone. The r107 witness
passed the previous 42,042,920-cycle stopping point. r107 then reached
memory initialization but panicked creating the `kmalloc-1k` slab; r109
reproduced the 156-line UART failure using the qualified PGO compiler.
Neither run reached userspace.

## Issue 6 — Zbb zero-count correction (r112)

The prior issue-6 claim that a load retired and replayed after retirement
was not established by the byte-loop trace. Its proposed LSQ fix is
withdrawn. Extra result records in that trace remain unclassified. H36
and H37 pass on the affected baseline and provide ordering regression
coverage, not a reproduction of this kernel failure.

The decisive evidence is in the later, runtime-patched Zbb `strlen`.
Frozen r107 RVFI line 20,332,120 records `ctz t1,t1` (`0x60131313`, PC
`0xffffffff80657f68`) returning 63 after the preceding `not t1,t1` at
`0xffffffff80657f64` writes zero. Seven further sampled calls agree.
RISC-V Zbb requires `ctz(0) == XLEN`, which is 64 on this model. The
old assumption that the firmware's `acdfim` string excluded execution of
Zbb instructions was incorrect; the retired instruction encodings show
the kernel using its Zbb alternative.

The hyp8 LZC cell recursively split WIDTH=2 into WIDTH=1 leaves. A
standalone WIDTH=1 cell reports count 1 when empty; adding that to the
half-width in the pair's one-bit count overflowed to zero. The WIDTH=64
tree consequently returned 62 while empty, and the ALU incremented it to
63. Dividing by eight made `strlen` return seven for a nonzero full word.
The r112 correction terminates recursion at WIDTH=2 with the direct
leading/trailing-bit predicate and an independent empty reduction. It
preserves the standalone WIDTH=1 interface and the larger balanced tree.

| Remote qualification | Observed result |
|---|---|
| `hyp8-r112-aggregate-c1` | Build complete; model SHA256 `29752206111032213223befaec07ccc116b96c91cbe9aadee4546863e7aca286`; scalar/SMT2/MC lint errors and USERERRORs zero; warning totals 602/623/688 |
| `hyp8-r112-aluleaf-c3` | `HYP8_ALU_PASS checked=19508`; CLZ/CTZ zero, one-hot and all-ones; CTZW/CLZW controls; generic cell widths 1–9/32/64 and both directions |
| `hyp8-r112-smokes-c1` | 11/11 pass; cycles 685/1011/492/2364/2199/1231/671/3038/9095/5959/883 |
| `hyp8-r112-h38-baseline-c1` | Old r111 model `d80efeb5e80414b1049ef9e0ffd673e83528b440646226c625a3d3137386de97` on the same H38 ELF `d1280ed9f6dba83f8c4d8f2e849cb26ddb1691a0e25121e4497fc8a2124e5132`: **FAILED** exit 128 after 444 cycles, RVFI `end_of_test` `mem_wdata=0x101` (FAIL 1) — the unfixed cell reproduces the defect on the frozen smoke |
| `hyp8-r112-memleaf-c1` | `HYP8_MEMORY_PASS checked=160` |
| H38 executable | SHA256 `d1280ed9f6dba83f8c4d8f2e849cb26ddb1691a0e25121e4497fc8a2124e5132`; raw Zbb instruction encodings exercise zero counts and `orc.b/not/ctz` string boundaries |

The first two r112 ALU-leaf attempts failed because of testbench syntax
and an incorrectly specified high-half operand; they are not failing
baseline RTL evidence. The corrected-model results above stand on c3.



Correction confirmed on the actual kernel Zbb `strlen`: `tmp/r107_zbb_zero.py`
run against the r112 RVFI shows the first eight zero-input `ctz` samples —
trace lines 20,332,120 / 20,338,506 / 20,816,798 / 20,820,200 / 20,846,374 /
20,849,750 / 20,852,498 / 20,853,976 — all returning `0x40` (64). The first is
the SAME line 20,332,120 and PC `0xffffffff80657f68` that returned `0x3f` (63)
in the frozen r107 model; the preceding `not t1,t1` at `0xffffffff80657f64`
writes `x6=0` in both. The `g6lc_hyp_lzc` WIDTH=2 base case now yields the
architectural `ctz(0)==XLEN` on the kernel's live `strlen` path.

Timing/configuration review: this is a combinational base-case
correction; the direct pair avoids the overflowing leaf addition; no
measured FO4 or silicon timing claim follows. Existing RVB gating, ISA
discovery and DTS are unchanged. Tests check architectural count values
and result-owner identity. The canonical local `verify --lint --sim
--synth` invocation could not start because managed Verilator was
missing; the remote qualification above does not replace synthesis or
physical sign-off. The Linux witness must still demonstrate whether this
correction clears the percpu/kmalloc failure and reaches the payload's
userspace markers.


### r112 witness terminal outcome (hyp8-osbi-scalar-r112)

The corrected model's Linux witness was stopped at 68,138,680 cycles after:
`Kernel panic - not syncing: Creation of kmalloc slab kmalloc-2k
size=2048 failed. Reason -22`. Full kallsyms names are now correct
(`dump_backtrace`, `create_kmalloc_caches`, `new_kmalloc_cache`,
`create_boot_cache`, `kmem_cache_init`, `mm_core_init`, `start_kernel` —
no 7-character truncation), and the `ctz` zero-count is fixed on the live
`strlen` path — so the arithmetic/string defect is resolved. The allocator
still fails: `percpu: allocation failed` precedes a `kmalloc-2k` panic one
allocation-size later than r107's `kmalloc-1k` panic. Issue 6's string/
arithmetic symptom is closed by r112; the boot does NOT reach userspace —
the remaining percpu/kmalloc failure (cause unclassified) remains open. r112 fixed the
confirmed Zbb zero-count defect; it did not close the boot.


### Next discriminator — r112diag (hyp8-osbi-scalar-r112diag)

Observed at the r112 `pcpu_alloc` slot-iteration exit (RVFI line 24,818,860
onward): `LW a5,0(a5)` at `0xffffffff8011edd4` returns 16; `C.ADDIW s11,1`
at `0xffffffff8011edd6` returns 6; `BGE a5,s11,0xffffffff8011ed20` at
`0xffffffff8011edd8` records cycle 51,446,577 followed by a FALLTHROUGH at
`0xffffffff8011eddc` in the same cycle. Architecturally `16>=6` must take
the back-branch to slot 6, not attempt a new chunk. Wrong operands, branch
resolution/prediction, or a downstream redirect are all unproven. No
allocator-bitmap path executes in this failing call. This is recorded as a
next discriminator, not a causal conclusion. The windowed
`smt-flow`/`win`/`disp`/`commit` trace (`trace_from/to=51,443,000–51,448,000`)
is scheduled to resolve operand provenance and the redirect.


## r113 — front-end predicted-successor frontier correction

Diagnosed from the r112diag windowed trace: `BGE a5,s11` at
`0xffffffff8011edd8` was accepted with `cf=Branch` and a queued predicted
target `0xffffffff8011ed20`, but a prediction-only OV1 restart re-seeded
the frontier to the sequential `0xffffffff8011eddc` — the front-end's
successor unconditionally computed `last_consumed_addr + pc_ilen`,
discarding the CF metadata that survives the override. Root is the
accepted-stream successor, not the branch comparator or the allocator.

Fix: `core/frontend/g6lc_fe_frontier.sv` (new) extracts the frontier —
a consumed CF slot leaves the queue's `predict_address_i`, a NoCF slot
advances `addr + pc_ilen`, unconsumed slots cannot move the frontier.
`frontend.sv` instantiates it in place of the inline add; resume_d mux,
resume_pc_q and all redirect priority/state are unchanged.

| r113 gate | result |
|---|---|
| `hyp8-r113-linecheck-c2` | `HYP8_LINECHECK_PASS checked=75` — the real frontier DUT under 4 CF-type cases + 6 combinational seam cases |
| `hyp8-r113-linecheck-negative-c1` | `G6LC_MUT_FE_FRONTIER_FALLTHROUGH` → `CHKFAIL G_BRANCH_OV1_TARGET` `ov1pc=ffffffff8011eddc` — the mutation reproduces the defect, isolating the seam |
| `hyp8-r113-aggregate-c1` | `build_complete`, model SHA256 `a4c092e9ddea2c29781bade49b9b8df16cf1e4e8529af9983fd4dc47d003d2d5`, lints 0 err, warnings 602/623/688 |
| `hyp8-r113-smokes-c1` | 11/11 pass, cycles identical |

No new ISA/config/CSR/state/clock; a per-slot target mux added on an
existing combinational cone, no timing sign-off claim. Boot remains open;
this corrects the confirmed front-end successor defect. The full diff was
reviewed and committed: RTL `a5fc9e4e6`, verification/flists/licensing
`f943858cf`. The corrected witness is `hyp8-osbi-scalar-r113`, with the
same frozen firmware and a 300M-cycle budget; userspace still requires
both `G6LC_LINUX_INIT_UP` and `G6LC_LINUX_SHELL`.

Diagnostic receipt: `hyp8-osbi-scalar-r112diag` completed at its
51,450,000-cycle budget with no fatal error. The last observed retirement
was at 51,449,979. Its local `output/run-hyp8.log` contains the decisive
records: line 840952 has OV1 (`src=9`) restarting at `0xffffffff8011eddc`;
841729 has BGE tid22 operands `a=16`, `b=6`, forwarding disabled;
841756 has the correct taken resolution to `0xffffffff8011ed20` with no
mispredict; 841761–841762 commit that branch and its fall-through load
without a drop or replay. `[win]` cycle counters and the RVFI cycle stamp
use different offsets; the latter records the branch at 51,446,577.
These observations reject the arithmetic/operand and load-replay
explanations for this event. They do not certify unrelated allocator
or memory-order paths.

### r113 boot progress beyond allocator creation

The corrected frontier follows the allocator BGE to `0xffffffff8011ed20`
instead of the erroneous fall-through. The witness passes the former
percpu/kmalloc panic point and prints `SLUB: HWalign=64, Order=0-3,
MinObjects=0, CPUs=1, Nodes=1` by RVFI cycle 247079205. By approximately
262M cycles it has printed RCU setup, interrupt-controller setup,
clocksource setup, console handover, delay calibration and `pid_max`.
Neither userspace marker has been observed at that checkpoint.

The long interval after `Memory:` was traced to
`init_freelist_randomization` / `cache_random_seq_create`, whose
Fisher–Yates loop calls `get_random_u32_below`. Successive cache pointers
and decreasing shuffle counters establish progress at the sampled points.
For example, a 512-entry sequence begins at 208312985, followed by distinct
128- and 16-entry caches at 236827607 and 243915140. Cycle advancement
alone is not evidence against a livelock.

The 87 `[hang]` lines are three 29-line dumps at cycles 245151461,
245152461 and 245153461. They show an LR.W at `0xffffffff8065f9ca`
(`_raw_spin_trylock`) waiting with the D-cache miss unit in `AMO`, empty
write buffer and no live MSHR. Later retirement and console progress show
that this stall recovered. The source's LR retry-backoff gate motivated
the investigation below; these dumps do not directly capture its counter
or SC verdict. Local bounded artifacts are under
`remote-runs/hyp8-osbi-scalar-r113/output/`; the full trace remains remote.

## r114 — SC retry verdict aligned with the staged response

`wt_dcache_missunit.sv` classified SC success/failure on
`DCACHE_ATOMIC_ACK`, but read `amo_resp_o.result`, selected from
`amo_result_q`. The incoming raw word is captured at that edge, formed
at the next edge, then presented in `AMO_RESULT`. Thus the old verdict
could consume older or invalid-bus data. The code's comment claiming a
live SC verdict did not match its implementation.

The correction qualifies `sc_fail` / `sc_pass` with `AMO_RESULT` and the
held SC operation, so the retry policy observes the same owned result as
the client. A non-SC atomic cannot change the retry exponent. This moves
internal verdict timing to the existing completion stage and leaves
architectural AMO latency unchanged.

The directed test drives arbitrary payloads before and after the valid
atomic reply. On frozen r113, a successful SC.D returns zero correctly
but grows the retry mask: `SC_D_SUCCESS_MASK` fails at simulation time
2656 (bench cycle 265). This establishes a backoff bookkeeping defect;
it does not establish that every Linux stall or boot delay has that cause.

| r114 gate | Result |
|---|---|
| `hyp8-r114-sc-baseline-c1` | Frozen r113 module plus new bench: successful compile, correct returned SC result, then `FAIL SC_D_SUCCESS_MASK` |
| `hyp8-r114-sc-fixed-c1` | `HYP8_SC_BACKOFF_PASS checked=44` |
| `hyp8-r114-dcache-c1` | `HYP8_DCACHE_PASS checked=334 dchx=2 stores=88` |
| `hyp8-r114-aggregate-c1` | `build_complete`; scalar/SMT2/MC lint has zero errors/USERERRORs and warning totals 602/623/688 |
| `hyp8-r114-smokes-c1` | All 11 pass, cycle counts unchanged |

The isolated source starts from r113's verified manifest and overlays only
the D-cache bench and miss-unit RTL. Concurrent worktree changes are not
part of that model. Model SHA256:
`18278962b6c0523cedf2cc6e9f7c0cb08fff1ad1f5e1ed25ab82c554345d2f97`.
The recorded compiler is Verilator 5.008, `v5.008-19-gf7fa71520`,
binary SHA256
`d27a5af858d652e2202f1719d1ff909933f952aa451705ad61094493b9b15281`,
selected through `/opt/testharness/toolchains/verilator-v5.008-g6lc-pgo`.
This is a different compiler binary from the earlier `6b7cd2ad…` build;
the recorded identity, rather than the prefix name, defines this run.
The corresponding `/opt/testharness/src/verilator-g6lc-pgo-src/make.log`
records `-fprofile-use -fprofile-correction` and its `pgo-profile` directory;
`config.log` and `install.log` provide the build/install provenance.
The leaf runner now supports the same `HYP8_VERILATOR_DIR` override as
the aggregate runner and records its driver and compiler hashes.

Timing/review: retry classification reads registered data and the matching
state/operation, removing incoming return-valid from that decision.
No new state, clock, reset, latch, SRAM, ISA capability, config field or
PMU event is introduced; existing RVA gating and widths apply. No physical
timing improvement or sign-off is claimed. The canonical
`./build.sh verify --lint --sim --synth` invocation reached the upstream
`smoke-cv64a6` suite and failed its ISS step on `I-ADD-01`. Its
`make veri-testharness` build cannot compile `corev_apu/tb/ariane_tb.cpp`
against the generated model: the referenced SRAM, SMT and banked-register
hierarchy members are absent. The compiler log is
`verif/sim/out_2026-11-02/veri-testharness_sim/rv32i-I-ADD-01.cv64a6_imafdc_sv39.log.iss`.
The invocation ended, and its orphaned Spike process was stopped.
That gate is not a pass; the harness/model compatibility issue remains open.

The corrected Linux witness is a separate required gate and must reach
both `G6LC_LINUX_INIT_UP` and `G6LC_LINUX_SHELL`. The frozen payload
contains a BusyBox `/init`, not a procd/OpenWrt root filesystem.
Reviewed commits: RTL `a9c90bece`, tests/runner `5f6e3740b`.
`hyp8-osbi-scalar-r114` launched as PID 2644580 with the model above,
unchanged firmware SHA256
`ac36f37942ad52ae7f59c23cfaa3afbe2d1d4bc168cdbb74771ee5eda23b2fe1`,
and a 1,000,000,000-cycle budget. r113 continues separately to its
300M-cycle limit or a terminal boot outcome. Comment-only cleanup after
qualification corrected the AMO_WAIT explanation and test labels; the
compiled model retains the qualified functional source.

## r114 continuation: boot monitoring and canonical verification

At **2026-11-03 02:09:36 UTC**, direct remote reads confirmed both owned
simulation processes and their output directories:

| Witness | PID | Latest complete RVFI cycle | UART milestone |
|---|---:|---:|---|
| `hyp8-osbi-scalar-r113` | 2588789 | 285042210 | `pid_max`, after SLUB, IRQ, clock and console setup |
| `hyp8-osbi-scalar-r114` | 2644580 | 16784637 | OpenSBI banner |

Neither UART contains either userspace marker or a kernel panic/Oops.
The sampled model-log tails contain no fatal assertion. These are
progress observations, not completed boot qualifications. r113 retains
its 300M-cycle budget; the corrected r114 model retains its 1B-cycle budget.
The firmware, model and PGO Verilator identities above remain unchanged.
The sampled r113 PCs `0xffffffff802c0a5e` and `0xffffffff802be15a`
resolve in the payload-matched kernel to `ror32` in `include/linux/bitops.h`
and `chacha_block_generic` in `lib/crypto/chacha.c`. This locates the
quiet interval in random-number computation; no new defect is established.

The canonical verification failures exposed additional issues outside
the frozen hyp8 models:

- **Harness selection:** all core targets now share the SoC's
  `i_dram_backend` hierarchy, but the Makefile still chose the stale
  `ariane_tb.cpp` implementation for `cv*` targets. The default now uses
  `g6lc_tb.cpp`, which already follows that hierarchy and distinguishes
  scalar/SMT CSR and register banks. Explicit `TB_CPP` overrides remain.
  Commit: `774f9cc6f`.
- **Load ID capacity:** `cv64a6_imafdc_sv39` had eight load-buffer entries
  but one cache request-ID bit. The initial load-unit assertion correctly
  rejected it. `CVA6ConfigDcacheIdWidth` now derives from the load-buffer
  depth, giving three bits while retaining eight entries.
- **Testbench geometry:** the shared harness used optional package-level
  aliases absent from `cv32a65x`. Its injected parameter is the built
  `cva6_cfg_t`; the correct members are `DCACHE_LINE_WIDTH` and
  `ICACHE_LINE_WIDTH`. The former lowercase-member error was not evidence
  of a Verilator defect.
- **Optional diagnostics:** `TvalEn=0` removes the internal `mtval_q`
  storage from the generated RV32 model. The C++ diagnostic now reports
  unavailable storage explicitly and reads present storage normally.
  Its register-file dump also derives the number of array words per
  register, preserving RV64 values and zero-extending RV32 values.

The seven `smoke-cv64a6` comparisons passed after the harness/load-ID
corrections. With the corrected Spike below, `smoke-cv32a65x` passed its
single `hello_world` comparison (**719 matched**). The cumulative
`8 PASSED` report includes the preceding seven RV64 comparisons; it is
not eight separate RV32 tests. The optional diagnostic formatting was
compiled for both configurations; runtime dump output was not captured
in the reported RV32 run. The final canonical
`./build.sh verify --lint --sim --synth` gate passed **all eight steps**
at **2026-11-03 02:47:17 UTC**, exit code 0. Both targets passed lint,
elaboration, their simulation suite and synthesis smoke. The durable log
and result are
`build-platform/workspace/build/r114-canonical-final-20261103T022156Z.log`
and the adjacent `.result.json`. Warning totals were 265/4 for RV64
lint/elaboration, 61/4 for RV32, and 32/5 for synthesis respectively.
The final simulations used the promoted fixed Spike.

Two preceding WSL-host attempts returned exit 3 because the configured
`linux-eda-suite` contains Windows executables. The successful invocation
used the Windows host context, with simulation delegated to WSL by the
existing platform adapter. No tool-discovery source change was needed.
This is the canonical gate's result; it does not replace the separate
hyp8 Linux witness or establish physical timing closure.

Timing/config review: the load-ID correction adds two internal ID payload
bits without increasing queue depth or introducing a pipeline stage.
The testbench reads the same configured cache geometry and changes only
simulation diagnostics. No ISA capability, address map, DTS value, clock,
reset, SRAM boundary, DFT path or PMU event is added. Physical timing,
area and synthesis sign-off are not inferred from these tests.

### Spike: completion and budget ownership

A bounded replay of the canonical RV32 `hello_world` executable showed
the guest writing **1 to `tohost` at PC `0x80003560`**, then spinning at
`0x8000356a`. The executable SHA256 is
`b2bfe13303f8925283894764bc071f44b02d1d396c9378d8c50c203b81cce7c8`;
the diagnostic trace is `/tmp/r114-spike-rv32.BVS6Dm.log` in WSL.
The standalone simulation loop advanced processors without resuming the
HTIF coroutine, while `done()` only read a completion flag. It therefore
failed to consume a real guest completion. Separately, YAML application
overrode an explicit CLI step limit, and the exhausted-budget exception
handler returned success.

The corrected loop resumes HTIF only when a command is pending. It
retains the direct stepping path for firmware without host commands and
keeps round-robin hart scheduling. Explicit CLI limits now apply after
YAML defaults, and budget exhaustion returns **124**, not success.
Fork commit `79d81357` was transported as the same two-file change to
the tracked child (`74d780f1`); root gitlink commit: `b2e1ee422`.
The two parent checkouts had identical Spike source trees
(`a4ba10a0ccd562d62abe8f9b0e898b0e8cbf1efa`).

Directed results on the isolated `spike-r114-htif` installation:

| Case | Observed exit |
|---|---:|
| Frozen RV32 hello, original YAML, CLI 2M steps | 0, real completion |
| Same executable/YAML, CLI 10 steps | 124, internal budget exhaustion |
| YAML 10-step limit enabled, CLI 2M steps | 0, CLI override honored |
| Same 10-step YAML without a CLI limit | 124, YAML default honored |
| Two-hart readiness handshake, successful guest | 0 |
| Same handshake with guest exit code 1 | 1 |
| Frozen old Spike on the successful two-hart fixture | Budget message followed by false exit 0 |

The first attempted multicore fixture, `mc_smt2_boot_release.S`, was
inapplicable: it lacks the `fromhost` symbol required by HTIF and assumes
secondary-hart boot-ROM release semantics. Its exhaustion did not prove
that a larger budget was the solution. The corrected standalone fixture
is `build-platform/workspace/build/r114-spike-htif-dual.S`; both harts must
advance before hart 0 can report its result.

The fixed install was copied into the managed `tooling/spike` prefix
after checking for active users. The old install is retained as
`tooling/spike-pre-r114-backup`; the isolated prefix remains in place for
its embedded runtime paths. Frozen identities:

- `bin/spike`: `124a967c520bf244c7aa211d1ea63127e13832cbf927dd1de11fb4b4b25215d5`
- `lib/libfesvr.so`: `1992ebf39f613597dea1875556ee339d85d7ca976d31c3536adf93c4e5bb5435`
- `lib/libriscv.so`: `e043b395da623f35222413247339bca848941a43f7d2c2c5c3b21858de3e3449`

### Evidence retention and monitor corrections

Eight closed-run traces (the hart and RVFI traces for r107, r109, r112
and r112diag) were compressed to `.zst`. Each archive was decoded and
checked against the original byte count and SHA256 before the original
was removed. The validated receipts record 11,357,196,006 original bytes
and 391,055,983 archive bytes, releasing **10,966,140,023 bytes**.
Receipts were pulled to each corresponding
`remote-runs/hyp8-osbi-scalar-*/output/compression-r114.json`.
Future trace readers must decompress the `.zst` files; their content and
the original line references are unchanged. Active r113/r114 data was
not compressed or removed.

The old one-off monitor parsed leading privilege numbers as cycle
counts, could mistake either userspace marker for completion, and masked
a failed `pgrep` behind `head`. The replacement checker uses complete
`@cycle` stamps, verifies the PID's output directory, and requires both
userspace markers. It distinguishes running, completed, ended-without-
markers, kernel/model errors and transport failures. Source artifacts:
`build-platform/workspace/build/hyp8-boot-check.py` and
`hyp8-boot-monitor.sh`. The checker was exercised against both live
witnesses; the observations in the table above came from it.

The client-side monitor files stopped advancing after their first
02:16 records. Monitoring was therefore moved onto the remote host
using the same checker and `hyp8-boot-monitor-remote.sh`, detached with
`nohup` and redirected standard streams. The observer PIDs are 2677911
(r113) and 2677910 (r114); the simulation PIDs are unchanged. JSONL and
stderr are in each witness's `output/`, named
`hyp8-osbi-scalar-rNNN.monitor.{jsonl,stderr}`. Scripts and observer
PID/exit files are under `output/boot-monitor-r114/`.
The first detached records at **2026-11-03 02:51:52 UTC** report
**289841724** RVFI cycles for r113 and **22112436** for r114, with both
process identities verified and both userspace markers absent.

Reviewed commits: config/SV testbench `54528988c`, C++ diagnostic
`d07d3c632`, shared harness selection `774f9cc6f`, Spike pin `b2e1ee422`.
The licensing pass retained the upstream Solderpad/Apache notices and
vendor headers verbatim; new workspace helper scripts carry the MIT
header and Etienne Cimon attribution. No upstream file was relicensed.

## r113 final outcome; r114 continues

r113 consumed its full **300,000,000-cycle budget**. The final RVFI
cycle stamp is **299999987**, and its observer exited **4**. The kernel
advanced to the mount-cache and mountpoint-cache hash tables, with no
kernel panic/Oops or fatal model assertion observed, but neither
userspace marker appeared. Its outcome is **incomplete**.

The harness's terminal line says
`*** SUCCESS *** (tohost = 0) after 300000000 cycles [cycle budget reached: no tohost verdict]`.
This reports completion of a bounded capture, not guest success or a
Linux boot pass. The marker-based observer correctly kept those outcomes
separate. No new RTL defect is established by this budget exhaustion,
and the older model was not relaunched.

After producer PID 2588789 had exited, the two r113 traces were archived
with the lead-authored `r113-archive-traces.py`. Each archive's complete
decode matched the source byte count and SHA256, with decoder exit 0
and unchanged source fingerprints. Originals were retained until the
receipt was reviewed; removal then required that exact receipt hash,
unchanged source fingerprints and unchanged archive metadata.

| Closed trace | Original bytes | Archive bytes |
|---|---:|---:|
| `trace_hart_0.dasm` | 5913670144 | 326313722 |
| `trace_rvfi_hart_00.dasm` | 10744446039 | 1029964593 |

The `.zst` archives contain **16,658,116,183** original bytes in
**1,356,278,315** archive bytes, a logical storage reduction of
**15,301,837,868 bytes**. The updated receipt, including per-file hashes,
the reviewed receipt hash and removal flags, is
`remote-runs/hyp8-osbi-scalar-r113/output/compression-r113-final.json`.
The archives, final UART, model log, observer records and model remain
preserved. Read archived traces through `zstd -dc`; do not repeat the
derivation merely to reformat these recorded results.

The corrected r114 witness remains active. At **2026-11-03 04:41:41 UTC**,
its complete RVFI stamp was **33836506**, and the UART had reached
`Initmem setup node 0`. Both userspace markers were absent, with no
reported kernel error. PID 2644580 and its detached observer 2677910
continue under the original 1B-cycle budget. Its live traces were
neither compressed nor removed.
