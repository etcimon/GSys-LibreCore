# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S-mode multicore TLB-shootdown (PTE remap + sfence.vma) — OpenWrt-boot cover.
#
# Why: a Linux/OpenWrt SMP boot constantly modifies page tables on one CPU and
# must invalidate stale translations on the others (the TLB-shootdown IPI).
# mc_smode_parallel storms sfence.vma on a FIXED mapping; this test changes the
# mapping UNDER the harts and proves every hart's sfence.vma actually drops the
# stale entry — the exact scenario g6lc_tlb_hit_onehot0 / the PTW guards.
#
# Page-table shape (shared by all harts via one satp -> root_pt):
#   root_pt[1] -> pd1            VA 0x4000_0000 region (the shootdown space)
#   root_pt[2] -> 1 GiB leaf     VA 0x8000_0000 identity (code/data/tables)
#   pd1[0]     -> pt1            VA 0x4000_0000..0x4001_FFFF (2 MiB)
#   pt1[i]     -> 4 KiB leaf     VA 0x4000_0000+i*0x1000  (i = 0..NHARTS-1)
#
# Every hart owns VA_i = 0x4000_0000 + hartid*0x1000: its own 4 KiB page, its
# own TLB entry, its own potential stale translation. All pt1[i] start mapped to
# buf_a (SEED_A); each hart preloads VA_i and confirms SEED_A, caching the old
# translation. Hart 0 then rewrites every pt1[i] to the round's target buffer,
# fences, and raises GO=round. Every hart must sfence.vma then re-read VA_i and
# observe the NEW seed; seeing the OLD seed means its TLB kept the dead
# translation -> the bug. ROUNDS shootdowns alternate buf_b/buf_a.
#
# Verdicts (tohost): 1 pass; 3 a hart saw a stale/wrong translation;
# 5 preload saw wrong data; 7 a hart never finished a round (DONE timeout);
# ((16+mcause)<<1)|1 unexpected trap.
#ifndef NHARTS
#define NHARTS 8
#endif
#  NPART = participating harts = thread0s only (one per physical core). The
#  shootdown barrier needs every participant to keep up; coarse drained-handoff
#  SMT (SmtFetchQuantum=4096) starves a sibling under a spinning primary, which
#  deadlocks an all-8-hart barrier. One independent hart/core is a clean SMP
#  shootdown surface and still exercises cross-core TLB invalidation.
#ifndef NPART
#define NPART 4
#endif
#define ROUNDS    2
#define SEED_A   0xA5A5000000000001
#define SEED_B   0xB5B5000000000002

  .equ CLINT_MSIP, 0x02000000
  # shared control-block offsets (64 B apart to avoid false sharing)
  .equ GO,       0      # shootdown round broadcast (0=idle,1..ROUNDS,ROUNDS+1=done)
  .equ SLOTS,    256    # per-hart 64 B slot: +0 preload-ready flag
  .equ RESULT,   512    # per-hart 8 B cell at RESULT+hartid*64: last round done

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
  srli  s0, t0, 1          # s0 = core index 0..NC-1 (participant id)
  li    s1, NPART
  bgeu  s0, s1, park
  bnez  s0, setup_pt
  # hart0 releases the other cores' thread0s (mhartid 2,4,..) from BOOT_HOLD.
  li    t1, 1
  li    t2, 1
  li    t4, CLINT_MSIP
  li    t5, NPART
1:
  bgeu  t2, t5, setup_pt
  slli  t3, t2, 3          # (2*t2)*4 = mhartid(thread0 of core t2)*4
  add   t3, t3, t4
  sw    t1, 0(t3)
  addi  t2, t2, 1
  j     1b

setup_pt:
  li    t0, -1
  csrw  pmpaddr0, t0
  li    t0, 0x1f
  csrw  pmpcfg0, t0
  # root_pt[1] = pointer -> pd1 ; root_pt[2] = 1 GiB identity leaf
  la    t0, root_pt
  la    t1, pd1
  srli  t1, t1, 12
  slli  t1, t1, 10
  ori   t1, t1, 0x1
  sd    t1, 8(t0)
  li    t1, 0x200000cf
  sd    t1, 16(t0)
  # pd1[0] = pointer -> pt1
  la    t0, pd1
  la    t1, pt1
  srli  t1, t1, 12
  slli  t1, t1, 10
  ori   t1, t1, 0x1
  sd    t1, 0(t0)
  # pt1[i] = 4 KiB leaf -> buf_a for i in 0..NHARTS-1
  la    t0, pt1
  la    t1, buf_a
  srli  t1, t1, 12
  slli  t1, t1, 10
  ori   t1, t1, 0xcf
  li    t2, 0
3:
  bgeu  t2, s1, 4f
  slli  t3, t2, 3
  add   t4, t0, t3
  sd    t1, 0(t4)
  addi  t2, t2, 1
  j     3b
4:
  fence
  # DIAG: M-mode physical read-back of pt1[] leaf PTEs (post-fence, pre-satp —
  # the same visibility point the S-mode PTW reads at). Reports
  # [31:28]=index [27:0]=low28 of the value actually read, to discriminate a
  # bad store from a bad PTW read. Silent when every entry reads back correct.
  la    t0, pt1
  la    t1, buf_a
  srli  t1, t1, 12
  slli  t1, t1, 10
  ori   t1, t1, 0xcf
  li    t2, 0
20:
  bgeu  t2, s1, 21f
  slli  t3, t2, 3
  add   t4, t0, t3
  ld    t5, 0(t4)
  bne   t5, t1, 22f
  addi  t2, t2, 1
  j     20b
21:
  la    t0, root_pt
  srli  t1, t0, 12
  li    t2, 8
  slli  t2, t2, 60
  or    t1, t1, t2
  csrw  satp, t1
  sfence.vma
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
  li    s4, 0x40000000
  slli  t3, s0, 12
  add   s4, s4, t3           # s4 = my shootdown VA
  # preload VA -> SEED_A x8 (fills my TLB with the OLD translation)
  li    t5, 0
1:
  ld    t1, 0(s4)
  li    t6, SEED_A
  bne   t1, t6, fail_pre
  addi  t5, t5, 1
  li    t6, 8
  blt   t5, t6, 1b
  # RDY flag in my slot
  slli  t3, s0, 6
  add   t3, s2, t3
  addi  t3, t3, SLOTS
  li    t1, 1
  sd    t1, 0(t3)
  fence rw, rw
  bnez  s0, worker_poll
  j     coord_drive

# ---- worker: poll GO, on each new round sfence + verify new translation ----
worker_poll:
  li    s5, 0                # last round seen
wp_loop:
  ld    s6, GO(s2)           # current round
  beq   s6, s5, wp_spin      # no new round -> keep polling
  li    t6, ROUNDS+1
  bge   s6, t6, wp_done      # GO==done -> park
  sfence.vma                 # THE shootdown: drop my stale TLB entry
  ld    t2, 0(s4)            # re-read VA -> must give NEW seed
  andi  t3, s6, 1
  li    t6, SEED_B
  beqz  t3, 3f               # even round -> SEED_A
  j     4f
3:
  li    t6, SEED_A
4:
  bne   t2, t6, fail_stale
  # RESULT[hartid] = round completed
  slli  t3, s0, 6
  add   t3, s2, t3
  addi  t3, t3, RESULT
  sd    s6, 0(t3)
  fence rw, rw
  mv    s5, s6
  j     wp_loop
wp_spin:
  j     wp_loop
wp_done:
  j     park_s

# ---- hart0 coordinator: remap page table each round, broadcast, verify ----
coord_drive:
  # wait until every hart (incl. self) set RDY
  li    t2, 0
1:
  li    t3, 0
  li    t4, NPART
2:
  bgeu  t3, t4, rdy_ok
  slli  t5, t3, 6
  add   t5, t5, s2
  addi  t5, t5, SLOTS
  ld    t1, 0(t5)
  beqz  t1, not_rdy
  addi  t3, t3, 1
  j     2b
not_rdy:
  addi  t2, t2, 1
  li    t6, 8000000
  blt   t2, t6, 1b
  li    a0, 7
  j     fail_common
rdy_ok:
  # precompute both leaf PPNs once. Keep them in s8/s9: t0-t6 are scratch
  # clobbered by the rdy/result wait loops (ld t1 / addi t2) inside round_loop,
  # which corrupted leaf_a to the RESULT flag (=1) on even rounds -> pt1[]=1.
  la    t0, buf_a
  srli  s8, t0, 12
  slli  s8, s8, 10
  ori   s8, s8, 0xcf         # leaf_a in s8 (survives round_loop scratch use)
  la    t0, buf_b
  srli  s9, t0, 12
  slli  s9, s9, 10
  ori   s9, s9, 0xcf         # leaf_b in s9
  # drive ROUNDS shootdowns; s5 = round
  li    s5, 1
round_loop:
  li    t6, ROUNDS+1
  bge   s5, t6, rounds_done
  # pick target leaf: odd round -> buf_b(s9), even -> buf_a(s8)
  mv    s7, s8
  andi  t3, s5, 1
  beqz  t3, 5f
  mv    s7, s9
5:
  # rewrite pt1[i] = target for all i
  la    t0, pt1
  li    t4, 0
6:
  bgeu  t4, s1, 7f
  slli  t3, t4, 3
  add   t3, t0, t3
  sd    s7, 0(t3)
  addi  t4, t4, 1
  j     6b
7:
  fence rw, rw               # PTE writes globally visible before GO
  # GO = s5  (offset 0 of shared)
  sd    s5, 0(s2)
  fence rw, rw
  # hart0's OWN shootdown check on VA_0 (0x40000000)
  sfence.vma
  li    s4, 0x40000000
  ld    t1, 0(s4)
  andi  t3, s5, 1
  li    t6, SEED_B
  beqz  t3, 8f
  j     9f
8:
  li    t6, SEED_A
9:
  bne   t1, t6, fail_stale
  # hart0 records its own round result so the uniform RESULT wait covers it
  slli  t3, s0, 6
  add   t3, t3, s2
  addi  t3, t3, RESULT
  sd    s5, 0(t3)
  fence rw, rw
  # wait until every hart's RESULT == s5 (completed this round)
  li    t2, 0
10:
  li    t3, 0
  li    t4, NPART
11:
  bgeu  t3, t4, round_done
  slli  t5, t3, 6
  add   t5, t5, s2
  addi  t5, t5, RESULT
  ld    t1, 0(t5)
  bne   t1, s5, not_done
  addi  t3, t3, 1
  j     11b
not_done:
  addi  t2, t2, 1
  li    t6, 8000000
  blt   t2, t6, 10b
  li    a0, 7
  j     fail_common
round_done:
  addi  s5, s5, 1
  j     round_loop
rounds_done:
  # signal workers to park
  li    t1, ROUNDS+1
  sd    t1, 0(s2)
  fence rw, rw
  li    a0, 1
  j     pass_out

fail_pre:
  li    a0, 5
  j     fail_common
fail_stale:
  li    a0, 3
  j     fail_common

pass_out:
  la    t0, tohost
  sw    a0, 0(t0)
  fence rw, rw
park_s:
  j     park_s

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

# DIAG mismatch handler (M-mode): tohost = [31:28]=pt1 index, [27:0]=low28 of
# the value M-mode physically read back for that leaf PTE.
22:
  slli  t6, t5, 36
  srli  t6, t6, 36          # t6 = low28 of read value
  slli  t2, t2, 28          # index -> [31:28]
  or    t2, t2, t6
  la    t0, tohost
  sw    t2, 0(t0)
  fence rw, rw
  j     park

  .section .data
  .align 12
root_pt:
  .fill 512, 8, 0
pd1:
  .fill 512, 8, 0
pt1:
  .fill 512, 8, 0

  .align 6
shared:
  .fill 512, 8, 0

  # shootdown buffers: each 4 KiB-aligned page, first qword is the pattern.
  .balign 4096
buf_a:
  .quad SEED_A
  .fill 4088, 1, 0
  .balign 4096
buf_b:
  .quad SEED_B
  .fill 4088, 1, 0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
