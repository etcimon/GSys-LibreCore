# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S4 Variane: full testharness xbar × L2 8 MSHR × island MaxAROut=8.
# Requires a library with CAP_MAX_AR_OUT=8 (G6LC_AI_DRAM_TIMING or CLASS1).
# Kicks an 8×8 GEMM (island AR budget) then eight independent 64 B line
# loads (L2 MSHR / load-buffer 8) before polling DONE. Not a cookie soak.
# Not 400 GB/s. Fail codes: 3 general, 5 MaxAROut!=8, 7 GEMM timeout.

  .equ AI_BASE,        0x40000000
  .equ CAP_MAX_AR_OUT, 0x40
  .equ AI_CTL,         0x100
  .equ AI_DOORBELL,    0x108
  .equ AI_DONE,        0x10C
  .equ AI_TICKET,      0x110
  .equ AI_DSTATUS,     0x114
  .equ AI_REG0,        0x120
  .equ AI_DESC,        0x140
  .equ ST_OK,          0
  .equ S4_LINE_BASE,   0x80080000

  .section .text.init
  .globl _start
_start:
  # Dual-core stripe is the NrCores proof. S4 parks hart 1 so GEMM/doorbell
  # is not a two-hart race on the same desc.
  csrr t0, mhartid
  bnez t0, s4_park
  li   sp, 0x80008000
  la   t0, trap_vec
  csrw mtvec, t0
  andi sp, sp, -16

  li   s0, AI_BASE
  lw   t0, CAP_MAX_AR_OUT(s0)
  li   t1, 8
  bne  t0, t1, fail_ar

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
  li   t1, 64
0:
  sw   zero, 0(t0)
  addi t0, t0, 4
  addi t1, t1, -1
  bnez t1, 0b

  li   t0, (1 << 16) | 1
  sw   t0, AI_DESC+0x0(s0)
  sw   zero, AI_DESC+0x4(s0)
  li   t0, 8
  sw   t0, AI_DESC+0x8(s0)
  sw   t0, AI_DESC+0xC(s0)
  sw   t0, AI_DESC+0x10(s0)
  li   t0, 0x00080008
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

  # Island MaxAROut=8 path live, then eight L2-line misses (NrLoadBufEntries=8).
  li   t0, (42 << 8)
  sw   t0, AI_DOORBELL(s0)

  li   s1, S4_LINE_BASE
  ld   t0, 0(s1)
  ld   t1, 64(s1)
  ld   t2, 128(s1)
  ld   t3, 192(s1)
  ld   t4, 256(s1)
  ld   t5, 320(s1)
  ld   t6, 384(s1)
  ld   a1, 448(s1)
  or   t0, t0, t1
  or   t0, t0, t2
  or   t0, t0, t3
  or   t0, t0, t4
  or   t0, t0, t5
  or   t0, t0, t6
  or   t0, t0, a1
  bnez t0, fail

  li   t2, 2000000
1:
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  bnez t0, 2f
  addi t2, t2, -1
  bnez t2, 1b
  j    fail_to
2:
  lw   t0, AI_DSTATUS(s0)
  slli t0, t0, 48
  srli t0, t0, 48
  li   t1, ST_OK
  bne  t0, t1, fail
  lw   t0, AI_TICKET(s0)
  li   t1, 42
  bne  t0, t1, fail

  fence
  la   t0, mat_c
  li   t1, 64
  li   t3, 8
3:
  lw   t2, 0(t0)
  bne  t2, t3, fail
  addi t0, t0, 4
  addi t1, t1, -1
  bnez t1, 3b

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
4: j 4b

fail_ar:
  li   a0, 5
  j    fail_store
fail_to:
  li   a0, 7
  j    fail_store
fail:
  li   a0, 3
fail_store:
  la   t0, tohost
  sw   a0, 0(t0)
5: j 5b

s4_park:
  wfi
  j    s4_park

trap_vec:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
6: j 6b

  .section .data
  .align 3
  .globl mat_a
mat_a:
  .rept 64
  .byte 1
  .endr
  .align 3
  .globl mat_b
mat_b:
  .rept 64
  .byte 1
  .endr
  .align 3
  .globl mat_c
mat_c:
  .rept 64
  .word 0
  .endr

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
