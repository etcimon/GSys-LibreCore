# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# I1-lite GEMM with lda > k (row padding). 2x2x2, lda=4, ldb=2.
# A rows: [1,2, pad,pad] [3,4, pad,pad]
# B: [[5,6],[7,8]]  →  C = [[19,22],[43,50]]  (same as dense)

  .equ AI_BASE,     0x40000000
  .equ AI_CTL,      0x100
  .equ AI_DOORBELL, 0x108
  .equ AI_DONE,     0x10C
  .equ AI_TICKET,   0x110
  .equ AI_DSTATUS,  0x114
  .equ AI_REG0,     0x120
  .equ AI_DESC,     0x140
  .equ ST_OK,       0

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

  la   t0, mat_c
  sw   zero, 0(t0)
  sw   zero, 4(t0)
  sw   zero, 8(t0)
  sw   zero, 12(t0)

  li   t0, (1 << 16) | 1
  sw   t0, AI_DESC+0x0(s0)
  sw   zero, AI_DESC+0x4(s0)
  li   t0, 2
  sw   t0, AI_DESC+0x8(s0)
  sw   t0, AI_DESC+0xC(s0)
  sw   t0, AI_DESC+0x10(s0)
  li   t0, 0x00020004          # ldb=2, lda=4
  sw   t0, AI_DESC+0x14(s0)
  la   t0, mat_a
  sw   t0, AI_DESC+0x18(s0)
  srli t1, t0, 32
  sw   t1, AI_DESC+0x1C(s0)
  la   t0, mat_b
  sw   t0, AI_DESC+0x20(s0)
  srli t1, t0, 32
  sw   t1, AI_DESC+0x24(s0)
  la   t0, mat_c
  sw   t0, AI_DESC+0x28(s0)
  srli t1, t0, 32
  sw   t1, AI_DESC+0x2C(s0)
  sw   zero, AI_DESC+0x30(s0)
  sw   zero, AI_DESC+0x34(s0)
  sw   zero, AI_DESC+0x38(s0)
  sw   zero, AI_DESC+0x3C(s0)

  fence
  lw   zero, AI_CTL(s0)

  li   t0, (12 << 8)
  sw   t0, AI_DOORBELL(s0)

  li   t2, 200000
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
  li   t1, ST_OK
  bne  t0, t1, fail
  lw   t0, AI_TICKET(s0)
  li   t1, 12
  bne  t0, t1, fail

  fence
  la   t0, mat_c
  lw   t1, 0(t0)
  li   t2, 19
  bne  t1, t2, fail
  lw   t1, 4(t0)
  li   t2, 22
  bne  t1, t2, fail
  lw   t1, 8(t0)
  li   t2, 43
  bne  t1, t2, fail
  lw   t1, 12(t0)
  li   t2, 50
  bne  t1, t2, fail

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

  .section .data
  .align 3
  .globl mat_a
mat_a:
  .byte 1, 2, 0x7f, 0x7f
  .byte 3, 4, 0x7f, 0x7f
  .align 3
  .globl mat_b
mat_b:
  .byte 5, 6
  .byte 7, 8
  .align 3
  .globl mat_c
mat_c:
  .word 0, 0, 0, 0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
