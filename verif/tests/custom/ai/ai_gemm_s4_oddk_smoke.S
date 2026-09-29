# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# F1 INT4 GEMM with ODD k. m=2, n=2, k=3, lda=3, ldb=3, numfmt=AI_FMT_INT4 (1).
#
# This is the nibble-MASKING test, and it is the one place F1 can be silently
# wrong. With k=3 a row occupies ceil(3/2) = 2 bytes, so the UPPER nibble of the
# second byte is padding that holds no element. `g6lc_ai_gemm_seq` must zero it:
#
#     pe_a[p] = {(e1 < k) ? data[7:4] : 4'b0000,
#                (e0 < k) ? data[3:0] : 4'b0000}
#
# If that mask is missing or inverted, the pad nibble is multiplied and added,
# and C is wrong while the job still reports ST_OK -- the same fail-silent class
# as AI-X8.
#
# So the pad nibbles here are deliberately NON-ZERO and deliberately large. A
# broken mask cannot produce the golden by accident:
#     C[0][0]  correct 5     with pad leaking  5 + 7*6   = 47
#     C[1][1]  correct -119  with pad leaking  -119 + 5*(-7) = -154
#
# Packing is low nibble first: byte = (elem[2i+1] << 4) | (elem[2i] & 0xf).
#
# A[2][3] row-major, lda=3 (2 bytes/row):
#   row 0: [ 1,  2,  3] + pad 7  -> 0x21, 0x73
#   row 1: [-1,  7, -8] + pad 5  -> 0x7F, 0x58
# B[2][3] k-major, ldb=3 (2 bytes/row):
#   j=0:   [ 1, -1,  2] + pad 6  -> 0xF1, 0x62
#   j=1:   [ 7, -8,  7] + pad -7 -> 0x87, 0x97
#
# C[i][j] = sum_{t=0..2} A[i][t] * B[j][t]:
#   C[0][0] =  1*1 + 2*(-1) + 3*2      =  1 -  2 +  6 =    5
#   C[0][1] =  1*7 + 2*(-8) + 3*7      =  7 - 16 + 21 =   12
#   C[1][0] = -1*1 + 7*(-1) + (-8)*2   = -1 -  7 - 16 =  -24
#   C[1][1] = -1*7 + 7*(-8) + (-8)*7   = -7 - 56 - 56 = -119
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
  .equ FLAG_NUMFMT_INT4, (1 << 20)

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

  li   t0, (1 << 16) | 2       # op=OP_GEMM, version=2
  sw   t0, AI_DESC+0x0(s0)
  li   t0, FLAG_NUMFMT_INT4
  sw   t0, AI_DESC+0x4(s0)     # flags: numfmt = INT4
  li   t0, 2                   # m
  sw   t0, AI_DESC+0x8(s0)
  li   t0, 2                   # n
  sw   t0, AI_DESC+0xC(s0)
  li   t0, 3                   # k  <-- ODD: last byte is half padding
  sw   t0, AI_DESC+0x10(s0)
  li   t0, 0x00030003          # ldb=3, lda=3 (ELEMENTS; ceil(3/2)=2 bytes/row)
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

  li   t0, (45 << 8)
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
  li   t1, 45
  li   a0, 7
  bne  t0, t1, fail

  fence
  la   t0, mat_c
  lw   t1, 0(t0)
  li   t2, 5
  li   a0, 9
  bne  t1, t2, fail
  lw   t1, 4(t0)
  li   t2, 12
  li   a0, 11
  bne  t1, t2, fail
  lw   t1, 8(t0)
  li   t2, -24
  li   a0, 13
  bne  t1, t2, fail
  lw   t1, 12(t0)
  li   t2, -119
  li   a0, 15
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
  # row 0: 1, 2, 3 (+pad 7)      row 1: -1, 7, -8 (+pad 5)
  .byte 0x21, 0x73
  .byte 0x7F, 0x58
  .align 3
  .globl mat_b
mat_b:
  # j=0: 1, -1, 2 (+pad 6)       j=1: 7, -8, 7 (+pad -7)
  .byte 0xF1, 0x62
  .byte 0x87, 0x97
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
