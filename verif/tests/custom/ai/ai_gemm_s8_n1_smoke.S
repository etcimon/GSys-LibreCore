# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# n=1 INT8 GEMM (matrix-vector): m=2, n=1, k=4, lda=4, ldb=1.
#
# Diagnostic companion to ai_gemm_s8_oddn_smoke.S (AI-X8). With n=1,
# `can_pair = !stc_j[0] && (stc_j + 1 < n)` is FALSE for every row, so the C
# store uses the single-i32 tail path exclusively and never the pair path.
#
# That makes this the discriminator:
#   * n=1 FAILS  -> the single-i32 tail path itself is broken;
#   * n=1 PASSES -> the tail path is fine in isolation and the odd-n defect is
#                   in the pair -> single transition (cursor/`stc_elem`
#                   accounting when the last pair does not divide the row).
#
# n=1 is also a legitimate shape in its own right: every `nn.Linear` with a
# single output unit, and every matrix-vector product, lands here.
#
# A[2][4] row-major, lda=4:      B[4][1], ldb=1:
#   [ 1  2  3  4 ]                 [ 1 ] [ 2 ] [ 3 ] [ 4 ]
#   [ 5  6  7  8 ]
# C[2][1] = A*B, ldc = n = 1:
#   C[0][0] = 1+4+9+16   = 30
#   C[1][0] = 5+12+21+32 = 70
#
# Exit codes: 1=pass, 3=status, 5=trap, 7=ticket, 9+2*e=C[e], 31=timeout.

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
  # g6lc64_ai has two cores and both start here: only hart 0 drives the island;
  # any other hart parks, otherwise every MMIO doorbell/claim is issued twice.
  csrr t0, mhartid
  beqz t0, 1f
2: wfi
  j    2b
1:
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

  li   t0, (1 << 16) | 2       # op=OP_GEMM, version=2
  sw   t0, AI_DESC+0x0(s0)
  sw   zero, AI_DESC+0x4(s0)
  li   t0, 2                   # m
  sw   t0, AI_DESC+0x8(s0)
  li   t0, 1                   # n  <-- single column
  sw   t0, AI_DESC+0xC(s0)
  li   t0, 4                   # k
  sw   t0, AI_DESC+0x10(s0)
  li   t0, 0x00040004          # ldb=4 (k-major B), lda=4
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

  li   t2, 200000
1:
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  bnez t0, 2f
  addi t2, t2, -1
  bnez t2, 1b
  li   a0, 31
  j    fail
2:
  lw   t0, AI_DSTATUS(s0)
  slli t0, t0, 48
  srli t0, t0, 48
  li   t1, ST_OK
  li   a0, 3
  bne  t0, t1, fail
  lw   t0, AI_TICKET(s0)
  li   t1, 21
  li   a0, 7
  bne  t0, t1, fail

  fence
  la   t0, mat_c
  lw   t1, 0(t0)
  li   t2, 30
  li   a0, 9
  bne  t1, t2, fail
  lw   t1, 4(t0)
  li   t2, 70
  li   a0, 11
  bne  t1, t2, fail

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
3: j 3b

fail:
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
  .byte 1, 2, 3, 4
  .byte 5, 6, 7, 8
  .align 3
  .globl mat_b
mat_b:
  .byte 1
  .byte 2
  .byte 3
  .byte 4
  .align 3
  .globl mat_c
mat_c:
  .word 0, 0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
