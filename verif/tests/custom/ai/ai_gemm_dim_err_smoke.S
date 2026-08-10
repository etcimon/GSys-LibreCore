# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# I1-lite rejects m=9 (> MaxDim=8) with ST_ERR, no write to C.

  .equ AI_BASE,     0x40000000
  .equ AI_CTL,      0x100
  .equ AI_DOORBELL, 0x108
  .equ AI_DONE,     0x10C
  .equ AI_TICKET,   0x110
  .equ AI_DSTATUS,  0x114
  .equ AI_REG0,     0x120
  .equ AI_DESC,     0x140
  .equ ST_ERR,      1

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap_vec
  csrw mtvec, t0
  andi sp, sp, -16

  li   s0, AI_BASE
  li   t0, 1
  sw   t0, AI_CTL(s0)

  li   t0, 0x80000000
  sw   t0, AI_REG0+0x0(s0)
  sw   zero, AI_REG0+0x4(s0)
  li   t0, 0x80100000
  sw   t0, AI_REG0+0x8(s0)
  sw   zero, AI_REG0+0xC(s0)
  li   t0, 0x3
  sw   t0, AI_REG0+0x10(s0)

  li   t0, (1 << 16) | 1
  sw   t0, AI_DESC+0x0(s0)
  sw   zero, AI_DESC+0x4(s0)
  li   t0, 9                   # m > MaxDim
  sw   t0, AI_DESC+0x8(s0)
  li   t0, 2
  sw   t0, AI_DESC+0xC(s0)
  sw   t0, AI_DESC+0x10(s0)
  li   t0, 0x00020002
  sw   t0, AI_DESC+0x14(s0)
  li   t0, 0x80010000
  sw   t0, AI_DESC+0x18(s0)
  sw   zero, AI_DESC+0x1C(s0)
  li   t0, 0x80011000
  sw   t0, AI_DESC+0x20(s0)
  sw   zero, AI_DESC+0x24(s0)
  li   t0, 0x80012000
  sw   t0, AI_DESC+0x28(s0)
  sw   zero, AI_DESC+0x2C(s0)
  sw   zero, AI_DESC+0x30(s0)
  sw   zero, AI_DESC+0x34(s0)
  sw   zero, AI_DESC+0x38(s0)
  sw   zero, AI_DESC+0x3C(s0)

  fence
  lw   zero, AI_CTL(s0)

  li   t0, (13 << 8)
  sw   t0, AI_DOORBELL(s0)

  # Dim-err completes in a handful of cycles (no AXI traffic)
  li   t2, 5000
1:
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  bnez t0, 2f
  addi t2, t2, -1
  bnez t2, 1b
  j    fail
2:
  lw   t0, AI_DSTATUS(s0)
  slli t0, t0, 48
  srli t0, t0, 48
  li   t1, ST_ERR
  bne  t0, t1, fail
  lw   t0, AI_TICKET(s0)
  li   t1, 13
  bne  t0, t1, fail

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
3: j 3b

fail:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
4: j 4b

trap_vec:
  li   a0, 5
  la   t0, tohost
  sw   a0, 0(t0)
5: j 5b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
