# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Two harts, two DIFFERENT reservation addresses, interleaved LR/SC.
#
# This is the case `ai_dual_core_excl_smoke` cannot see. That test proves the
# *snoop*: hart 1 stores to hart 0's line and hart 0's sc.d must fail. A monitor
# holding a single global reservation passes it, because there is only one line
# in play. The failure mode a single reservation actually has is disjoint:
#
#   hart 0: lr.d A      -> reservation = A
#   hart 1: lr.d B      -> reservation = B   (A is silently destroyed)
#   hart 0: sc.d A      -> fails, though nothing touched A
#
# Neither hart wrote the other's address, so no amount of guest-side backoff
# helps; two spinlocks at different addresses can starve each other. That is the
# shape of every OpenSBI/Linux spinlock and of __atomic CAS, so this must hold
# before any multi-hart boot claim on a build that selects g6lc_axi_lrsc.
#
# The interleave is by delay, not by handshake, because a store between LR and
# SC on the *same* hart deadlocks issue (`lr_sc_pair_q`) -- see
# ai_dual_core_excl_smoke. Both harts start from one GO flag, then hart 1 takes
# the shorter gap so its LR lands inside hart 0's LR..SC window.
#
# Needs NrCores=2 + RVA. Not OpenSBI. Not cookie. Not 400.
# Fail: 5 GO/done timeout, 9 hart-0 sc.d failed with no store to A (the defect),
#       11 A does not hold the sc.d value, 13 hart-1 sc.d failed.
# Trap: 32+((mcause<<1)|1).

  .equ LINE_A,   0x80090200
  .equ LINE_B,   0x80090280   # distinct 64 B line, distinct DRAM stripe
  .equ GO,       0x80090300
  .equ R1,       0x80090380   # hart 1 verdict: 1 = sc ok, 2 = sc failed
  .equ SCVAL_A,  0x5a
  .equ SCVAL_B,  0xb6
  .equ H1_GAP,   200          # hart 1 reserves inside hart 0's window
  .equ H0_GAP,   4000
  .equ TIMEOUT,  2000000

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap_vec
  csrw mtvec, t1
  bnez t0, hart1

  # ---- hart 0 ----------------------------------------------------------------
  li   s1, LINE_A
  li   s2, LINE_B
  li   s3, GO
  li   s4, R1
  sd   zero, 0(s1)
  sd   zero, 0(s2)
  sd   zero, 0(s3)
  sd   zero, 0(s4)
  fence rw, rw

  li   t1, 1
  sd   t1, 0(s3)              # release hart 1
  fence rw, rw

  lr.d t0, (s1)               # reserve A

  li   t2, H0_GAP             # hold the reservation while hart 1 reserves B
1:
  addi t2, t2, -1
  bnez t2, 1b

  li   t1, SCVAL_A
  sc.d t2, t1, (s1)           # must succeed: nothing wrote A
  bnez t2, fail_lrsc

  ld   t0, 0(s1)
  li   t1, SCVAL_A
  bne  t0, t1, fail_value

  # hart 1's own disjoint sequence must also have succeeded.
  li   t2, TIMEOUT
2:
  ld   t1, 0(s4)
  bnez t1, 3f
  addi t2, t2, -1
  bnez t2, 2b
  j    fail_to
3:
  li   t0, 1
  bne  t1, t0, fail_h1

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
4: j 4b

  # ---- hart 1 ----------------------------------------------------------------
hart1:
  li   s3, GO
  li   t2, TIMEOUT
5:
  ld   t1, 0(s3)
  bnez t1, 6f
  addi t2, t2, -1
  bnez t2, 5b
  j    hart1_park
6:
  li   t2, H1_GAP
7:
  addi t2, t2, -1
  bnez t2, 7b

  li   s2, LINE_B
  lr.d t0, (s2)               # reserve B *inside* hart 0's LR..SC window
  li   t1, SCVAL_B
  sc.d t2, t1, (s2)           # must also succeed: nothing wrote B

  li   s4, R1
  li   t1, 1
  beqz t2, 8f
  li   t1, 2
8:
  sd   t1, 0(s4)
  fence rw, rw
hart1_park:
  wfi
  j    hart1_park

fail_to:
  li   a0, 5
  j    fail_store
fail_lrsc:
  li   a0, 9
  j    fail_store
fail_value:
  li   a0, 11
  j    fail_store
fail_h1:
  li   a0, 13
  j    fail_store
fail_store:
  la   t0, tohost
  sw   a0, 0(t0)
9: j 9b

trap_vec:
  csrr a0, mcause
  andi a0, a0, 0xff
  slli a0, a0, 1
  ori  a0, a0, 1
  addi a0, a0, 32
  la   t0, tohost
  sw   a0, 0(t0)
10: j 10b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
