# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# I3 bandwidth PMU: after a 32x32 all-ones GEMM, island MMIO must report
# non-zero R/W beats and active cycles at 0x180/184/188, and a positive
# sustained GB/s x1000 at 0x18C (integer milli-GB/s).

  .equ AI_BASE,     0x40000000
  .equ AI_CTL,      0x100
  .equ AI_DOORBELL, 0x108
  .equ AI_DONE,     0x10C
  .equ AI_TICKET,   0x110
  .equ AI_DSTATUS,  0x114
  .equ AI_REG0,     0x120
  .equ AI_DESC,     0x140
  .equ AI_PMU_R,    0x180
  .equ AI_PMU_W,    0x184
  .equ AI_PMU_CY,   0x188
  .equ AI_PMU_GBPS, 0x18C
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
  li   t1, 1024
1:
  sw   zero, 0(t0)
  addi t0, t0, 4
  addi t1, t1, -1
  bnez t1, 1b

  li   t0, (1 << 16) | 1
  sw   t0, AI_DESC+0x0(s0)
  sw   zero, AI_DESC+0x4(s0)
  li   t0, 32
  sw   t0, AI_DESC+0x8(s0)
  sw   t0, AI_DESC+0xC(s0)
  sw   t0, AI_DESC+0x10(s0)
  li   t0, 0x00200020
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

  li   t0, (30 << 8)
  sw   t0, AI_DOORBELL(s0)

  li   t2, 5000000
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
  li   t1, 30
  bne  t0, t1, fail

  fence
  # I3 PMU: R beats, W beats, cycles, milli-GB/s all must be non-zero
  lw   t0, AI_PMU_R(s0)
  beqz t0, fail
  lw   t0, AI_PMU_W(s0)
  beqz t0, fail
  lw   t0, AI_PMU_CY(s0)
  beqz t0, fail
  lw   t0, AI_PMU_GBPS(s0)
  beqz t0, fail

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
4: j 4b

fail:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
5: j 5b

trap_vec:
  li   a0, 5
  la   t0, tohost
  sw   a0, 0(t0)
6: j 6b

  .section .data
  .align 3
  .globl mat_a
mat_a:
  .rept 1024
  .byte 1
  .endr
  .align 3
  .globl mat_b
mat_b:
  .rept 1024
  .byte 1
  .endr
  .align 3
  .globl mat_c
mat_c:
  .space 4096

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
