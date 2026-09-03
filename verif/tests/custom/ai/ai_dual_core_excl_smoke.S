# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Dual-core exclusive snoop on the unified DRAM slave (g6lc_axi_atomics_wrap).
# Hart 0: lr.d, spin on FLAG (loads only), sc.d must fail. Hart 1: after GO
# (set before LR), delay, store LINE, set FLAG. H1_DELAY=4000 (was 100000 /
# 400666 cy / 81 min wall); LR is a few hundred cycles after GO. Same-hart
# store between LR/SC deadlocks issue lr_sc_pair_q. Needs NrCores=2 + RVA
# (ai-dt). Not OpenSBI. Not cookie. Not 400. Fail: 5 FLAG timeout, 9 SC
# succeeded or LINE != cookie. Trap: 32+((mcause<<1)|1).

  .equ LINE,        0x80090000
  .equ GO,          0x80090100
  .equ FLAG,        0x80090180
  .equ COOKIE1,     99
  .equ SCVAL,       4
  .equ H1_DELAY,    4000
  .equ FLAG_TO,     2000000

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap_vec
  csrw mtvec, t1
  bnez t0, hart1

  li   s1, LINE
  li   s2, GO
  li   s3, FLAG
  sd   zero, 0(s1)
  sd   zero, 0(s2)
  sd   zero, 0(s3)
  fence rw, rw

  li   t1, 1
  sd   t1, 0(s2)
  fence rw, rw

  lr.d t0, (s1)

  li   t2, FLAG_TO
1:
  ld   t1, 0(s3)
  bnez t1, 2f
  addi t2, t2, -1
  bnez t2, 1b
  j    fail_to
2:
  li   t1, SCVAL
  sc.d t2, t1, (s1)
  beqz t2, fail_lrsc
  ld   t0, 0(s1)
  li   t1, COOKIE1
  bne  t0, t1, fail_lrsc

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
3: j 3b

hart1:
  li   s2, GO
  li   t2, FLAG_TO
4:
  ld   t1, 0(s2)
  bnez t1, 5f
  addi t2, t2, -1
  bnez t2, 4b
  j    hart1_park
5:
  li   t2, H1_DELAY
6:
  addi t2, t2, -1
  bnez t2, 6b

  li   s1, LINE
  li   t1, COOKIE1
  sd   t1, 0(s1)
  fence rw, rw
  li   s3, FLAG
  li   t1, 1
  sd   t1, 0(s3)
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
fail_store:
  la   t0, tohost
  sw   a0, 0(t0)
7: j 7b

trap_vec:
  csrr a0, mcause
  andi a0, a0, 0xff
  slli a0, a0, 1
  ori  a0, a0, 1
  addi a0, a0, 32
  la   t0, tohost
  sw   a0, 0(t0)
8: j 8b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
