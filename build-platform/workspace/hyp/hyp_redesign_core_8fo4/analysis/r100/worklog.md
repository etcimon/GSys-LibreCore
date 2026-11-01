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
