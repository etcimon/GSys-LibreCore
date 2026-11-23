# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S-mode multicore translated-work + sfence.vma stress (OpenWrt-boot coverage).
#
# Why this test exists: every existing multicore mini runs in M-mode with
# translation off, so none reaches the ITLB/DTLB/PTW under SMP concurrency —
# exactly the path a Linux/OpenWrt SMP boot exercises once the kernel is up
# (secondary harts running translated kernel code, taking sfence.vma
# shootdowns, doing AMOs and fences). hyp8_sv39_load proves S-mode SV39 on ONE
# hart; this proves it on all NHARTS harts at once and hammers the TLB
# invalidate/refill path that g6lc_tlb_hit_onehot0 guards.
#
# All harts run the SAME M-mode prologue (PMP + a shared 1 GiB identity Sv39
# leaf, the proven hyp8_sv39_load encoding), then mret into S-mode with
# mhartid preserved in s0. Hart 0 first raises MSIP for every other hart — the
# cluster boot-hold opens on the IPI, the same release hyp8_smp_lrsc uses.
#
# In S-mode every hart loops ITER times: a translated store->load verify on
# its own 64-byte slot, an AMO on a shared counter, a SHOTDOWN poll (any move
# -> sfence.vma, the software model of an IPI-driven shootdown since sfence is
# local), and a periodic unconditional sfence.vma to force PTW refills. Hart 0
# periodically raises SHOTDOWN so all harts flush together.
#
# Verdicts (tohost): 1 pass; 3 CNT_AMO count wrong; 5 ARRIVED != NHARTS;
# 7 a worker done-marker missing; 9 DONE timeout; 11 translated ld!=st;
# ((16+mcause)<<1)|1 unexpected trap. A wedge is a budget-out.
#
# Needs the hyp8 multicore model (g6lc64_hyp8_mc). Build with -DNHARTS=<n>;
# the suite passes NHARTS=8. Harts >= NHARTS park.
#ifndef NHARTS
#define NHARTS 8
#endif
#  NPART = participating harts = thread0s only (one per physical core). The
#  ARRIVED/DONE barrier needs every participant to finish ITER; coarse
#  drained-handoff SMT (SmtFetchQuantum=4096) starves a sibling under a
#  spinning/looping primary and can stall the barrier. One independent
#  hart/core is a clean SMP translated-work + AMO + sfence surface.
#define NPART 4
// ITER bounds wall time: every hart does ITER AMOs on ONE shared line, which
// serializes under coherence (~100+ cyc each worst case). Under a contended
// remote host the shared-line AMO rate is ~10 iters/min wall, so ITER must stay
// well under the 7200 s per-test subprocess timeout. 500*NPART = 2000 AMOs
// still gives each hart ~2 unconditional sfence.vma + SHOTDOWN-triggered
// flushes — a solid SMP translated-work + TLB + coherence surface. Override
// with -DITER=N via HYP8_TEST_DEFINES for a deeper/shorter run.
#ifndef ITER
#define ITER      500
#endif
#define SF_EVERY  211          # iterations between unconditional sfence.vma
#define SHOT_EVERY 509         # hart0 SHOTDOWN bump stride (prime-ish)
#define SEED      0x5a5a1234

  .equ CLINT_MSIP, 0x02000000

  # shared control-block offsets (each on its own 64 B line where it matters)
  .equ CNT_AMO,   0
  .equ ARRIVED,   64
  .equ DONE,      128
  .equ SHOTDOWN,  192
  .equ SLOTS,     256         # per-hart 64 B slot: +0 arr, +8 data, +16 cksum, +24 done

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr  t0, mhartid
  la    t1, m_trap
  csrw  mtvec, t1
  csrw  mie, x0
  # SMT siblings (odd mhartid) park: only thread0s participate (see NPART note).
  andi  t2, t0, 1
  bnez  t2, park
  srli  s0, t0, 1              # s0 = core index 0..NC-1 (survives mret)
  li    s1, NPART
  bgeu  s0, s1, park

  # hart 0 releases the other cores' thread0s (mhartid 2,4,..) via CLINT msip.
  bnez  s0, setup_pt
  li    t1, 1
  li    t2, 1
  li    t4, CLINT_MSIP         # 0x02000000 needs lui+addi; keep in a reg
  li    t5, NPART
1:
  bgeu  t2, t5, setup_pt
  slli  t3, t2, 3              # (2*t2)*4 = mhartid(thread0 of core t2)*4
  add   t3, t3, t4
  sw    t1, 0(t3)              # msip -> opens that core's boot-hold
  addi  t2, t2, 1
  j     1b

setup_pt:
  # PMP entry 0: NAPOT whole address space RWX for S/U (hyp8_sv39_load).
  li    t0, -1
  csrw  pmpaddr0, t0
  li    t0, 0x1f
  csrw  pmpcfg0, t0
  # Shared root page table: entry 2 (VA 0x8000_0000) -> 1 GiB leaf at the same
  # PA, V|R|W|X|A|D. Every hart writes the identical PTE -> benign identical
  # concurrent stores.
  la    t0, root_pt
  li    t1, 0x200000cf
  sd    t1, 16(t0)
  fence
  srli  t1, t0, 12
  li    t2, 8
  slli  t2, t2, 60             # satp MODE = Sv39 (8)
  or    t1, t1, t2
  csrw  satp, t1
  sfence.vma
  # mstatus.MPP = S, mepc = s_entry, drop to translated S-mode.
  li    t0, 0x1800
  csrc  mstatus, t0
  li    t0, 0x0800
  csrs  mstatus, t0
  la    t0, s_entry
  csrw  mepc, t0
  mret

# ---------------- S-mode ----------------
s_entry:
  fence rw, rw
  la    s2, shared
  slli  t3, s0, 6              # hartid * 64 -> own cache line
  add   s5, s2, t3
  addi  s5, s5, SLOTS          # s5 = my 64 B slot
  li    t1, 1
  sd    t1, 0(s5)              # arrived flag
  addi  a0, s2, ARRIVED
  amoadd.d x0, t1, (a0)        # ARRIVED++

  li    s3, ITER
  li    s4, 0                  # iteration counter
  li    s6, -1                 # last SHOTDOWN value seen (force first sfence)
  li    s7, SEED
  xor   s7, s7, s0             # per-hart running value / checksum seed
  li    s8, SF_EVERY           # sfence countdown

s_loop:
  # translated store -> dependent translated load on my own slot (TLB + fwd)
  sd    s7, 8(s5)
  ld    t1, 8(s5)
  bne   t1, s7, fail_data
  addi  s7, s7, 0x111
  # shared AMO counter: every hart hammers the same line (coherence)
  li    t1, 1
  addi  a0, s2, CNT_AMO
  amoadd.d x0, t1, (a0)
  # SHOTDOWN poll: a move means another hart broadcast a shootdown -> flush
  ld    t1, SHOTDOWN(s2)
  beq   t1, s6, no_shot
  sfence.vma
  mv    s6, t1
no_shot:
  # hart 0 periodically raises SHOTDOWN (the IPI source)
  bnez  s0, skip_bump
  li    t5, SHOT_EVERY
  rem   t2, s4, t5
  bnez  t2, skip_bump
  li    t1, 1
  addi  a0, s2, SHOTDOWN
  amoadd.d x0, t1, (a0)
skip_bump:
  # periodic unconditional sfence.vma: invalidate + force a PTW refill
  addi  s8, s8, -1
  bnez  s8, no_sf
  sfence.vma
  li    s8, SF_EVERY
no_sf:
  addi  s4, s4, 1
  blt   s4, s3, s_loop

  # finished: publish done-marker + checksum, count DONE
  li    t1, 0xC0DE
  sd    t1, 24(s5)
  sd    s7, 16(s5)
  li    t1, 1                  # DONE counts arrivals; coord_wait compares NPART
  addi  a0, s2, DONE
  amoadd.d x0, t1, (a0)
  fence rw, rw
  bnez  s0, park_s
  j     coord_wait

fail_data:
  li    a0, 11
  j     fail_common

# hart0 waits for every hart, then verifies counts and per-hart done markers.
coord_wait:
  li    t2, 8000000
1:
  ld    t1, DONE(s2)
  li    t3, NPART
  beq   t1, t3, coord_verify
  addi  t2, t2, -1
  bnez  t2, 1b
  li    a0, 9                  # DONE timeout -> a hart never finished
  j     fail_common
coord_verify:
  # ARRIVED must equal NHARTS
  ld    t1, ARRIVED(s2)
  li    t2, NPART
  bne   t1, t2, fail_arrived
  # CNT_AMO must equal ITER * NHARTS (every hart did ITER AMOs)
  li    t1, ITER
  li    t2, NPART
  mul   t1, t1, t2
  ld    t2, CNT_AMO(s2)
  bne   t2, t1, fail_amo
  # every worker (and hart0) must have left its 0xC0DE done-marker
  li    t3, 0
  li    t4, NPART
2:
  bgeu  t3, t4, coord_pass
  slli  t5, t3, 6
  add   t5, t5, s2
  addi  t5, t5, SLOTS
  ld    t1, 24(t5)
  li    t2, 0xC0DE
  bne   t1, t2, fail_cksum
  addi  t3, t3, 1
  j     2b
coord_pass:
  li    a0, 1
  j     pass_out

fail_arrived:
  li    a0, 5
  j     fail_common
fail_amo:
  li    a0, 3
  j     fail_common
fail_cksum:
  li    a0, 7
  j     fail_common

pass_out:
  la    t0, tohost
  sw    a0, 0(t0)
  fence rw, rw
park_s:
  j     park_s                  # S-mode park: plain loop (zero WFI-in-S risk)

fail_common:
  la    t0, tohost
  sw    a0, 0(t0)
  fence rw, rw
  j     park_s

park:
  wfi
  j     park

m_trap:
  csrr  a0, mcause
  andi  a0, a0, 0xff
  slli  a0, a0, 1
  ori  a0, a0, 1
  addi  a0, a0, 32
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
  j    park

  .section .data
  .align 12
root_pt:
  .fill 512, 8, 0

  # shared control block: .data + .fill -> the zeros are loaded, never .bss.
  .align 6
shared:
  .fill 512, 8, 0           # 4 KiB of defined zeros

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
