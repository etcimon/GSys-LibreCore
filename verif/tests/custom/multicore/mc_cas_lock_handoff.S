# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# CAS ticket handoff stress. Soft-skip without A or illegal AMOCAS (Spike).

  .globl main
main:
  addi sp, sp, -32
  csrr t0, misa
  li   t1, (1 << 0)
  and  t2, t0, t1
  beqz t2, soft_skip

  la   t0, cas_illegal
  csrw mtvec, t0

  sw   zero, 0(sp)
  li   s0, 8
1:
  li   a0, 0
  li   a1, 1
  mv   a2, sp
  .word 0x28B6252F
  bnez a0, fail
  lw   t0, 0(sp)
  li   t1, 1
  bne  t0, t1, fail

  li   a0, 1
  li   a1, 0
  mv   a2, sp
  .word 0x28B6252F
  li   t1, 1
  bne  a0, t1, fail
  lw   t0, 0(sp)
  bnez t0, fail

  addi s0, s0, -1
  bnez s0, 1b

  addi sp, sp, 32
  li   a0, 0
  jal  exit

  .align 2
cas_illegal:
  li   a0, 0
  jal  exit

soft_skip:
  addi sp, sp, 32
  li   a0, 0
  jal  exit

fail:
  addi sp, sp, 32
  li   a0, 1
  jal  exit
