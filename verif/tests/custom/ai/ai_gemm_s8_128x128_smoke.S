# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# 128x128x128 INT8 under MaxDim=256 (PeLanes=64 => 2 PE steps per C).
#   A,B all-ones → C[i,j] = 128 for all 16384 elements.
# Spot-check corners + mid to keep SW check time low.

  .equ AI_BASE,     0x40000000
  .equ AI_CTL,      0x100
  .equ AI_DOORBELL, 0x108
  .equ AI_DONE,     0x10C
  .equ AI_TICKET,   0x110
  .equ AI_DSTATUS,  0x114
  .equ AI_REG0,     0x120
  .equ AI_DESC,     0x140
  .equ ST_OK,       0
  .equ N,          128
  .equ NN,         16384

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

  # Zero a few C slots we will check (full zero optional — GEMM overwrites)
  la   t0, mat_c
  sw   zero, 0(t0)
  li   t1, 127
  slli t1, t1, 2
  add  t1, t0, t1
  sw   zero, 0(t1)
  li   t1, (64*128+64)
  slli t1, t1, 2
  add  t1, t0, t1
  sw   zero, 0(t1)
  li   t1, (127*128+127)
  slli t1, t1, 2
  add  t1, t0, t1
  sw   zero, 0(t1)

  li   t0, (1 << 16) | 1
  sw   t0, AI_DESC+0x0(s0)
  sw   zero, AI_DESC+0x4(s0)
  li   t0, N
  sw   t0, AI_DESC+0x8(s0)
  sw   t0, AI_DESC+0xC(s0)
  sw   t0, AI_DESC+0x10(s0)
  li   t0, 0x00800080
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

  li   t0, (26 << 8)
  sw   t0, AI_DOORBELL(s0)

  li   t2, 20000000
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
  li   t1, 26
  bne  t0, t1, fail

  fence
  # Spot-check C corners + mid == 128
  la   t0, mat_c
  li   t3, 128
  lw   t2, 0(t0)
  bne  t2, t3, fail
  li   t1, 127
  slli t1, t1, 2
  add  t1, t0, t1
  lw   t2, 0(t1)
  bne  t2, t3, fail
  li   t1, (64*128+64)
  slli t1, t1, 2
  add  t1, t0, t1
  lw   t2, 0(t1)
  bne  t2, t3, fail
  li   t1, (127*128+127)
  slli t1, t1, 2
  add  t1, t0, t1
  lw   t2, 0(t1)
  bne  t2, t3, fail

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
  .rept 16384
  .byte 1
  .endr
  .align 3
  .globl mat_b
mat_b:
  .rept 16384
  .byte 1
  .endr
  .align 3
  .globl mat_c
mat_c:
  .space 65536

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
