# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# ODD-n INT8 GEMM: m=2, n=3, k=4, lda=4, ldb=3.
#
# Regression for AI-X8, now FIXED. Keep it: it is the only fixture with an odd n.
#
# It was found while building the layout oracle and originally failed like this:
#
#   C[0][0] = 70   correct
#   C[0][1] = 80   correct
#   C[0][2] = 90   WRONG  -> exited with tohost = 13
#
# The engine accepted the descriptor (ST_OK, correct ticket) and returned a C in
# which only the trailing element of an odd-length row was wrong. That is the
# worst failure class for a tensor engine and the one the descriptor package is
# explicit about avoiding: numerically plausible garbage is worse than a clean
# failure status.
#
# Fixed by making the C store decide pair-vs-single per ROW (`can_pair = !n_q[0]`)
# instead of per position, so a row never transitions pair -> single midway and
# never needs two AW transactions. PASSES at 1369 cy.
#
# Why nothing caught it before: EVERY other AI GEMM golden has an even n
# (2, 4, 16, 64, 128, 256). `ST_CHK` does not require n to be even -- it checks
# only n != 0, n <= MaxDim and ldb >= n -- so odd n is accepted and computed
# wrongly rather than refused.
#
# How it was scoped, on ONE unchanged netlist (all four still in the suite):
#   * ai_gemm_s8_n1_smoke   (n=1, single-i32 path ONLY, never pairs)  PASSED
#   * ai_gemm_s8_asym_smoke (m=2 n=4 k=6, pair path only)             PASSED
#   * ai_gemm_s8_m1n3_smoke (m=1 n=3: transition, but no trail store) PASSED
#   * this test             (m=2 n=3: transition WITH trail store)    FAILED
# So neither store path was wrong alone, and ST_STC's identical transition was
# fine -- only the trail store racing an active MAC broke. A read-latency
# argument was excluded: both paths present `w.data` in the same cycle as the C
# tile read, so the even-n pair path would have failed too.
#
# The race itself was never root-caused to a line. The fix removes the construct
# (one AW per row, always) rather than explaining it, which is exactly why all
# four fixtures stay in the suite: if the underlying hazard is still live it will
# resurface the next time the store path is reshaped.
#
# Do NOT "fix" a future recurrence by forbidding odd n; that would hide a
# datapath defect behind a legality check.
#
# A[2][4] row-major, lda=4:
#   [ 1  2  3  4 ]
#   [ 5  6  7  8 ]
# B[4][3] row-major, ldb=3:
#   [  1  2  3 ]
#   [  4  5  6 ]
#   [  7  8  9 ]
#   [ 10 11 12 ]
# C[2][3] = A*B, ldc = n = 3:
#   [  70  80  90 ]
#   [ 158 184 210 ]
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
  sw   zero, 8(t0)
  sw   zero, 12(t0)
  sw   zero, 16(t0)
  sw   zero, 20(t0)

  li   t0, (1 << 16) | 2       # op=OP_GEMM, version=2
  sw   t0, AI_DESC+0x0(s0)
  sw   zero, AI_DESC+0x4(s0)
  li   t0, 2                   # m
  sw   t0, AI_DESC+0x8(s0)
  li   t0, 3                   # n  <-- odd
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
  li   t2, 70
  li   a0, 9
  bne  t1, t2, fail
  lw   t1, 4(t0)
  li   t2, 80
  li   a0, 11
  bne  t1, t2, fail
  lw   t1, 8(t0)
  li   t2, 90
  li   a0, 13
  bne  t1, t2, fail
  lw   t1, 12(t0)
  li   t2, 158
  li   a0, 15
  bne  t1, t2, fail
  lw   t1, 16(t0)
  li   t2, 184
  li   a0, 17
  bne  t1, t2, fail
  lw   t1, 20(t0)
  li   t2, 210
  li   a0, 19
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
  # k-major B'[n][k] = B'[3][4], ldb = k = 4. B'[j][t] = 3t + j + 1.
  .byte 1, 4, 7, 10
  .byte 2, 5, 8, 11
  .byte 3, 6, 9, 12
  .align 3
  .globl mat_c
mat_c:
  .word 0, 0, 0, 0, 0, 0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
