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
