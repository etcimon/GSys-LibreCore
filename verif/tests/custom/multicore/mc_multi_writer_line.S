# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Multi-writer cache line under COH_FILTERED (T23, plan item 4: directed
# coherence breadth). The cross-core evidence before this test had one
# writer per line at a time (mc_shared_line_coherence PEER 2/4/6, the CBO
# and CAS tests). Here FOUR cores write the SAME line at once.
#
#   Phase A (false sharing, plain stores): every core increments ITS OWN
#   dword slot of LINE with ld / addi / sd, ITERS times, no atomics. A dropped
#   invalidation, a stale line written back whole, or a lost ownership
#   transfer between the hub and a core shows up as a slot below ITERS (or
#   another core's slot clobbered).
#   Phase B (true sharing, AMO): every core amoadd.d 1 to the same dword
#   COUNTER, ITERS times. The counter must end at NR_WRITERS * ITERS: an AMO
#   that executes on a stale copy, or two cores holding the line writable at
#   once, loses increments.
#
# Roles: hart 0 (core 0) orchestrates AND writes slot 0; harts 2, 4, 6 (one
# per other core, SMT siblings park) write slots 1..3 after hart 0 releases
# their cores through CLINT msip (MIE clear: the pending IPI never traps).
# Every control word (GO, GO2, DONE_A[c], DONE_B[c]) sits on its own line.
#
# Fail codes (tohost): 5 DONE_A timeout, 6 DONE_B timeout, 9 a slot != ITERS
# (phase A, the coherence defect), 10 COUNTER != NR_WRITERS*ITERS (phase B),
# 12 a slot was disturbed by phase B (slots must still read ITERS after B).
# Trap: 32+((mcause<<1)|1). ORACLE_NEGATIVE expects tohost 3.
#
# Needs NrCores=4 (hart mask 1111 with SMT2). ITERS defaults to 1500: four
# cores times two phases is ~0.5 M cycles on the server model.

#ifndef ITERS
#define ITERS 1500
#endif
#ifndef NR_WRITERS
#define NR_WRITERS 4
#endif
  .equ CLINT_MSIP, 0x02000000
  .equ LINE,     0x80090000     # slots at +0, +8, +16, +24; COUNTER at +32
  .equ COUNTER,  0x80090020
  .equ GO,       0x80090100
  .equ GO2,      0x80090140
  .equ DONE_A,   0x80090200     # + core*64
  .equ DONE_B,   0x80090400     # + core*64
  .equ SPIN_TO,  400000

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap_vec
  csrw mtvec, t1
  andi t1, t0, 1
  bnez t1, park                 # SMT sibling harts park
  srli s0, t0, 1                # s0 = core index
  li   t1, NR_WRITERS
  bgeu s0, t1, park
  bnez s0, writer

  # ---- hart 0: clear the control words and the line, release the cores ----
  li   s1, LINE
  sd   zero, 0(s1)
  sd   zero, 8(s1)
  sd   zero, 16(s1)
  sd   zero, 24(s1)
  sd   zero, 32(s1)
  li   t0, GO
  sd   zero, 0(t0)
  li   t0, GO2
  sd   zero, 0(t0)
  li   t0, DONE_A
  li   t1, DONE_B
  li   t2, NR_WRITERS
1:
  sd   zero, 0(t0)
  sd   zero, 0(t1)
  addi t0, t0, 64
  addi t1, t1, 64
  addi t2, t2, -1
  bnez t2, 1b
  fence rw, rw
  li   t0, GO
  li   t1, 1
  sd   t1, 0(t0)
  fence rw, rw
  li   t0, CLINT_MSIP
  li   t2, 1
2:                              # msip for harts 2, 4, 6 (core c -> hart 2c)
  li   t3, NR_WRITERS
  bgeu t2, t3, 3f
  slli t3, t2, 3                # 4 bytes * hart (2c) = 8c
  add  t3, t3, t0
  sw   t1, 0(t3)
  addi t2, t2, 1
  j    2b
3:
  # hart 0 is writer 0 too
  j    writer_go

  # ---- every writer (incl. hart 0): wait GO, phase A, DONE_A, wait GO2, phase B, DONE_B ----
writer:
  li   t0, GO
  li   t2, SPIN_TO
4:
  ld   t1, 0(t0)
  bnez t1, writer_go
  addi t2, t2, -1
  bnez t2, 4b
  j    park
writer_go:
  li   s1, LINE
  slli t0, s0, 3
  add  s1, s1, t0               # s1 = my slot
  li   s2, ITERS
5:                              # phase A: plain RMW of my own slot
  ld   t1, 0(s1)
  addi t1, t1, 1
  sd   t1, 0(s1)
  addi s2, s2, -1
  bnez s2, 5b
  fence rw, rw
  li   t0, DONE_A
  slli t1, s0, 6
  add  t0, t0, t1
  li   t1, 1
  sd   t1, 0(t0)
  fence rw, rw
  bnez s0, 7f
  # hart 0: wait every DONE_A, check phase A, then GO2
  jal  ra, wait_all_done_a
  jal  ra, check_slots
  li   t0, GO2
  li   t1, 1
  sd   t1, 0(t0)
  fence rw, rw
  j    8f
7:
  li   t0, GO2
  li   t2, SPIN_TO
6:
  ld   t1, 0(t0)
  bnez t1, 8f
  addi t2, t2, -1
  bnez t2, 6b
  j    park
8:
  li   s3, COUNTER
  li   s2, ITERS
  li   t1, 1
9:                              # phase B: everyone amoadd.d the same dword
  amoadd.d zero, t1, (s3)
  addi s2, s2, -1
  bnez s2, 9b
  fence rw, rw
  li   t0, DONE_B
  slli t1, s0, 6
  add  t0, t0, t1
  li   t1, 1
  sd   t1, 0(t0)
  fence rw, rw
  bnez s0, park
  # hart 0: wait every DONE_B, check the counter and that the slots survived
  jal  ra, wait_all_done_b
  fence rw, rw
  li   s3, COUNTER
  ld   t0, 0(s3)
  li   t1, ITERS * NR_WRITERS
  bne  t0, t1, fail_counter
  li   s1, LINE
  li   t2, NR_WRITERS
  li   t1, ITERS
10:
  ld   t0, 0(s1)
  bne  t0, t1, fail_disturbed
  addi s1, s1, 8
  addi t2, t2, -1
  bnez t2, 10b
#ifdef ORACLE_NEGATIVE
  li   a0, 3
#else
  li   a0, 1
#endif
  j    tohost_store

# wait for DONE_A[c] of every core (hart 0 only)
wait_all_done_a:
  li   t3, DONE_A
  li   t4, NR_WRITERS
  li   t2, SPIN_TO
11:
  fence rw, rw
  ld   t1, 0(t3)
  beqz t1, 12f
  addi t3, t3, 64
  addi t4, t4, -1
  beqz t4, 13f
  j    11b
12:
  addi t2, t2, -1
  bnez t2, 11b
  j    fail_done_a
13:
  ret

wait_all_done_b:
  li   t3, DONE_B
  li   t4, NR_WRITERS
  li   t2, SPIN_TO
14:
  fence rw, rw
  ld   t1, 0(t3)
  beqz t1, 15f
  addi t3, t3, 64
  addi t4, t4, -1
  beqz t4, 16f
  j    14b
15:
  addi t2, t2, -1
  bnez t2, 14b
  j    fail_done_b
16:
  ret

# every slot must read ITERS after phase A (hart 0 only)
check_slots:
  fence rw, rw
  li   t3, LINE
  li   t4, NR_WRITERS
  li   t1, ITERS
17:
  ld   t0, 0(t3)
  bne  t0, t1, fail_slot
  addi t3, t3, 8
  addi t4, t4, -1
  bnez t4, 17b
  ret

fail_done_a:
  li   a0, 5
  j    tohost_store
fail_done_b:
  li   a0, 6
  j    tohost_store
fail_slot:
  li   a0, 9
  j    tohost_store
fail_counter:
  li   a0, 10
  j    tohost_store
fail_disturbed:
  li   a0, 12
  j    tohost_store
tohost_store:
  la   t0, tohost
  sw   a0, 0(t0)
18: j 18b

park:
  wfi
  j    park

trap_vec:
  csrr a0, mcause
  andi a0, a0, 0xff
  slli a0, a0, 1
  ori  a0, a0, 1
  addi a0, a0, 32
  la   t0, tohost
  sw   a0, 0(t0)
19: j 19b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
