# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Directed zimop/zcmop/ntl smoke for g6lc64_ooo_int2_l3 (RVZimop/RVZcmop/RVZihintntl=1).
# tohost = 1 on pass, 3 if mop.r.0 did not write 0, 5 if c.mop.1 clobbered a0.
# Does not need a zcmop-aware assembler: encodings are .word/.half.
  .section .text
  .globl _start
_start:
  li   a0, 0x5a5a5a5a
  # mop.r.0 a0, x0  -> a0 = 0
  .word 0x89004573
  bnez a0, fail_mop
  li   a0, 0x11111111
  # c.mop.1 -> addi x0,x0,0
  .half 0x6081
  li   t0, 0x11111111
  bne  a0, t0, fail_cmop
  # ntl.p = add x0, x0, x2  (must not trap)
  .word 0x00200033
  li   a0, 1
  j    tohost_exit
fail_mop:
  li   a0, 3
  j    tohost_exit
fail_cmop:
  li   a0, 5
tohost_exit:
  la   t1, tohost
  sw   a0, 0(t1)
1: j 1b
  .section .tohost, "aw", @progbits
  .align 6
  .globl tohost
tohost:
  .dword 0
