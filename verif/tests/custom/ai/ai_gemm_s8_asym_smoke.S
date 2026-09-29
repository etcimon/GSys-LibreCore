# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# I1-lite GEMM, deliberately ASYMMETRIC: m=2, n=4, k=6, lda=6, ldb=4.
#
# All three dims differ, and all are even, so this isolates the OPERAND LAYOUT
# question from the separate odd-`n` C-store defect that
# ai_gemm_s8_oddn_smoke.S pins (see AGENTS-todo AI-X8).
#
# This fixture exists to make the B operand LAYOUT observable. Every other AI
# GEMM golden is layout-blind:
#   * 64x64 / 128x128 / 256x256 fill mat_b with `.rept N / .byte 1`, an all-ones
#     matrix that is identical under transposition;
#   * smoke / 4x4 / lda are square, so a transposed B still yields a plausible C.
# A wrong B traversal therefore passes the entire existing suite. That is the
# real risk in the k-major operand change (numeric-formats-datapath.md §8.6),
# not the ABI edit itself, so this test lands FIRST and is proven against the
# pre-change row-major RTL before it is asked to prove anything else.
#
# m != n != k also catches a swapped row/burst cursor, which a square fixture
# cannot see.
#
# A[2][6] row-major, lda=6:
#   [ 1  2  3  4  5  6 ]
#   [ 7  8  9 10 11 12 ]
# B[6][4] row-major, ldb=4  (B[t][j] = 4t + j + 1):
#   [  1  2  3  4 ]
#   [  5  6  7  8 ]
#   [  9 10 11 12 ]
#   [ 13 14 15 16 ]
#   [ 17 18 19 20 ]
#   [ 21 22 23 24 ]
# C[2][4] = A*B, ldc = n = 4:
#   [ 301 322 343 364 ]
#   [ 697 754 811 868 ]
#
# Discrimination check: if the engine read these same bytes as a k-major B
# (B'[j][t]), row j=0 would be bytes 0..5 = [1,2,3,4,5,6] and C[0][0] would be
# 1+4+9+16+25+36 = 91, not 301. So the two layouts cannot both pass.

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

  # Clear C (8 words)
  la   t0, mat_c
  sw   zero, 0(t0)
  sw   zero, 4(t0)
  sw   zero, 8(t0)
  sw   zero, 12(t0)
  sw   zero, 16(t0)
  sw   zero, 20(t0)
  sw   zero, 24(t0)
  sw   zero, 28(t0)

  li   t0, (1 << 16) | 2       # op=OP_GEMM, version=2
  sw   t0, AI_DESC+0x0(s0)
  sw   zero, AI_DESC+0x4(s0)
  li   t0, 2                   # m
  sw   t0, AI_DESC+0x8(s0)
  li   t0, 4                   # n
  sw   t0, AI_DESC+0xC(s0)
  li   t0, 6                   # k
  sw   t0, AI_DESC+0x10(s0)
  li   t0, 0x00060006          # ldb=6 (k-major B), lda=6
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
  li   a0, 31                  # timeout waiting for DONE
  j    fail
2:
  # Distinct exit codes per check, so a failure localises itself without a
  # waveform. 3=status, 5=trap, 7=ticket, 9+2*e=C[e], 31=timeout.
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
  li   t2, 301
  li   a0, 9
  bne  t1, t2, fail
  lw   t1, 4(t0)
  li   t2, 322
  li   a0, 11
  bne  t1, t2, fail
  lw   t1, 8(t0)
  li   t2, 343
  li   a0, 13
  bne  t1, t2, fail
  lw   t1, 12(t0)
  li   t2, 364
  li   a0, 15
  bne  t1, t2, fail
  lw   t1, 16(t0)
  li   t2, 697
  li   a0, 17
  bne  t1, t2, fail
  lw   t1, 20(t0)
  li   t2, 754
  li   a0, 19
  bne  t1, t2, fail
  lw   t1, 24(t0)
  li   t2, 811
  li   a0, 21
  bne  t1, t2, fail
  lw   t1, 28(t0)
  li   t2, 868
  li   a0, 23
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
  .byte 1, 2, 3, 4, 5, 6
  .byte 7, 8, 9, 10, 11, 12
  .align 3
  .globl mat_b
mat_b:
  # k-major B'[n][k] = B'[4][6], ldb = k = 6. B'[j][t] = 4t + j + 1.
  .byte  1,  5,  9, 13, 17, 21
  .byte  2,  6, 10, 14, 18, 22
  .byte  3,  7, 11, 15, 19, 23
  .byte  4,  8, 12, 16, 20, 24
  .align 3
  .globl mat_c
mat_c:
  .word 0, 0, 0, 0, 0, 0, 0, 0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
