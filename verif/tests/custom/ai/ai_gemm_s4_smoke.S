# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# F1 INT4 GEMM golden. m=2, n=2, k=4, lda=4, ldb=4, numfmt=AI_FMT_INT4 (1).
#
# First test of a second numeric format in the island datapath. It exercises all
# three F1 pieces at once:
#   * g6lc_ai_pe_dot unpacks two sign-extended nibbles per byte and reduces
#     2*Lanes products through the existing signed 8x8 cell;
#   * g6lc_ai_gemm_seq advances t by 2*PeLanes and reads byte (t/2)+p;
#   * both loaders count t in BYTES against k_bytes = ceil(k/2), so a packed row
#     is fetched at its real length (2 bytes here) rather than over-fetched.
#
# Operands are chosen to stay inside signed INT4 (-8..7) AND to make a sign error
# visible. -8 and 7 are the range endpoints; -8*-8 = +64 is where a sign-extension
# slip shows up as a negative product.
#
# Packing: low nibble first, so byte = (elem[2i+1] << 4) | (elem[2i] & 0xf).
# That matches g6q-vm numfmt.rs read_elem and the host runtime.
#
# A[2][4], row-major, lda=4:
#   row 0: [ 1,  2,  3,  4]  -> bytes 0x21, 0x43
#   row 1: [-1, -2,  7, -8]  -> bytes 0xEF, 0x87
# B[2][4], k-major (AI-X9: ldb strides j, elements run along t), ldb=4:
#   j=0:   [ 1, -1,  2, -2]  -> bytes 0xF1, 0xE2
#   j=1:   [ 7,  7, -8, -8]  -> bytes 0x77, 0x88
#
# C[i][j] = sum_t A[i][t] * B[j][t]:
#   C[0][0] = 1*1 + 2*(-1) + 3*2 + 4*(-2) =  1 - 2 + 6 - 8  = -3
#   C[0][1] = 1*7 + 2*7 + 3*(-8) + 4*(-8) =  7 + 14 - 24 - 32 = -35
#   C[1][0] = -1*1 + -2*(-1) + 7*2 + -8*(-2) = -1 + 2 + 14 + 16 = 31
#   C[1][1] = -1*7 + -2*7 + 7*(-8) + -8*(-8) = -7 - 14 - 56 + 64 = -13
#
# Negative C values are deliberate: they prove the i32 accumulator and the store
# path sign-extend, which an all-positive golden cannot show.
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
  # flags.numfmt = flags[22:20]; AI_FMT_INT4 == 1
  .equ FLAG_NUMFMT_INT4, (1 << 20)

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

  li   t0, (1 << 16) | 2       # op=OP_GEMM, version=2
  sw   t0, AI_DESC+0x0(s0)
  li   t0, FLAG_NUMFMT_INT4
  sw   t0, AI_DESC+0x4(s0)     # flags: numfmt = INT4
  li   t0, 2                   # m
  sw   t0, AI_DESC+0x8(s0)
  li   t0, 2                   # n
  sw   t0, AI_DESC+0xC(s0)
  li   t0, 4                   # k (elements, not bytes)
  sw   t0, AI_DESC+0x10(s0)
  li   t0, 0x00040004          # ldb=4, lda=4 (ELEMENTS; 2 bytes packed)
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

  li   t0, (44 << 8)
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
  # A granted format must NOT come back ST_BAD_FMT (8). If it does, the mask and
  # the datapath disagree, which is the exact lie AiIslandPeImplMask exists to
  # prevent -- so this check is as load-bearing as the C values.
  lw   t0, AI_DSTATUS(s0)
  slli t0, t0, 48
  srli t0, t0, 48
  li   t1, ST_OK
  li   a0, 3
  bne  t0, t1, fail
  lw   t0, AI_TICKET(s0)
  li   t1, 44
  li   a0, 7
  bne  t0, t1, fail

  fence
  la   t0, mat_c
  lw   t1, 0(t0)
  li   t2, -3
  li   a0, 9
  bne  t1, t2, fail
  lw   t1, 4(t0)
  li   t2, -35
  li   a0, 11
  bne  t1, t2, fail
  lw   t1, 8(t0)
  li   t2, 31
  li   a0, 13
  bne  t1, t2, fail
  lw   t1, 12(t0)
  li   t2, -13
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
  # row 0: 1, 2, 3, 4      row 1: -1, -2, 7, -8
  .byte 0x21, 0x43
  .byte 0xEF, 0x87
  .align 3
  .globl mat_b
mat_b:
  # j=0: 1, -1, 2, -2      j=1: 7, 7, -8, -8
  .byte 0xF1, 0xE2
  .byte 0x77, 0x88
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
