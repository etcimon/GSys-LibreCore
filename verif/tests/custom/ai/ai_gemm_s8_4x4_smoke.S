# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# I1 multi-step PE GEMM: 4x4x8 INT8, PeLanes=4 ⇒ 2 MAC cycles per C element.
#   A all-ones (4x8), B all-ones (8x4) → C[i,j] = 8 for all 16 elements.
# Exercises banked tile load + multi-step reduction. HTIF fail codes odd.

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

  # Zero C (16 x i32)
  la   t0, mat_c
  li   t1, 16
1:
  sw   zero, 0(t0)
  addi t0, t0, 4
  addi t1, t1, -1
  bnez t1, 1b

  # version=1 op=GEMM, m=n=4 k=8, lda=8 ldb=4
  li   t0, (1 << 16) | 1
  sw   t0, AI_DESC+0x0(s0)
  sw   zero, AI_DESC+0x4(s0)
  li   t0, 4
  sw   t0, AI_DESC+0x8(s0)     # m
  sw   t0, AI_DESC+0xC(s0)     # n
  li   t0, 8
  sw   t0, AI_DESC+0x10(s0)    # k
  li   t0, 0x00040008          # ldb=4, lda=8
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

  li   t0, (21 << 8)
  sw   t0, AI_DOORBELL(s0)

  li   t2, 500000
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
  li   t1, 21
  bne  t0, t1, fail

  fence
  # Every C element must be 8
  la   t0, mat_c
  li   t1, 16
  li   t3, 8
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
  # 4 rows × 8 cols of 1
  .byte 1,1,1,1,1,1,1,1
  .byte 1,1,1,1,1,1,1,1
  .byte 1,1,1,1,1,1,1,1
  .byte 1,1,1,1,1,1,1,1
  .align 3
  .globl mat_b
mat_b:
  # 8 rows × 4 cols of 1
  .byte 1,1,1,1
  .byte 1,1,1,1
  .byte 1,1,1,1
  .byte 1,1,1,1
  .byte 1,1,1,1
  .byte 1,1,1,1
  .byte 1,1,1,1
  .byte 1,1,1,1
  .align 3
  .globl mat_c
mat_c:
  .word 0,0,0,0
  .word 0,0,0,0
  .word 0,0,0,0
  .word 0,0,0,0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
