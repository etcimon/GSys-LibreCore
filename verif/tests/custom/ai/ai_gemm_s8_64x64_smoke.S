# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Full AccTile GEMM: 64x64x64 INT8 (PeLanes=16 ⇒ 4 PE steps per C).
#   A,B all-ones → C[i,j] = 64 for all 4096 elements.

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
  li   t1, 4096
1:
  sw   zero, 0(t0)
  addi t0, t0, 4
  addi t1, t1, -1
  bnez t1, 1b

  li   t0, (1 << 16) | 1
  sw   t0, AI_DESC+0x0(s0)
  sw   zero, AI_DESC+0x4(s0)
  li   t0, 64
  sw   t0, AI_DESC+0x8(s0)
  sw   t0, AI_DESC+0xC(s0)
  sw   t0, AI_DESC+0x10(s0)
  li   t0, 0x00400040
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

  li   t0, (25 << 8)
  sw   t0, AI_DOORBELL(s0)

  li   t2, 10000000
2:
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  bnez t0, 3f
  addi t2, t2, -1
  bnez t2, 2b
  j    fail
3:
  lw   t0, AI_DSTATUS(s0)
  slli t0, t0, 48
  srli t0, t0, 48
  li   t1, ST_OK
  bne  t0, t1, fail
  lw   t0, AI_TICKET(s0)
  li   t1, 25
  bne  t0, t1, fail

  fence
  la   t0, mat_c
  li   t1, 4096
  li   t3, 64
4:
  lw   t2, 0(t0)
  bne  t2, t3, fail
  addi t0, t0, 4
  addi t1, t1, -1
  bnez t1, 4b

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
5: j 5b

fail:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
6: j 6b

trap_vec:
  li   a0, 5
  la   t0, tohost
  sw   a0, 0(t0)
7: j 7b

  .section .data
  .align 3
  .globl mat_a
mat_a:
  .rept 4096
  .byte 1
  .endr
  .align 3
  .globl mat_b
mat_b:
  .rept 4096
  .byte 1
  .endr
  .align 3
  .globl mat_c
mat_c:
  .rept 4096
  .word 0
  .endr

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
