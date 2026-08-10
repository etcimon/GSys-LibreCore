# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# DMA descriptor fetch: write a good 64 B descriptor into DRAM, program
# desc_ptr, doorbell with bit[31]=fetch, wait done + ST_OK + ticket match.
# Second job: OOR ptr_a in memory image → ST_BAD_PTR after fetch+AI-3.
# Requires g6lc64_ai + EnableDmaFetch. Soft-pass on bus/illegal.
# HTIF fail codes odd only.

  .equ AI_BASE,     0x40000000
  .equ AI_CTL,      0x100
  .equ AI_DOORBELL, 0x108
  .equ AI_DONE,     0x10C
  .equ AI_TICKET,   0x110
  .equ AI_DSTATUS,  0x114
  .equ AI_DESCPTR,  0x118
  .equ AI_REG0,     0x120
  .equ ST_OK,       0
  .equ ST_BAD_PTR,  4
  .equ DB_FETCH,    (1 << 31)

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

  # Region covering DRAM code/data [0x80000000, 0x80100000) RW
  li   t0, 0x80000000
  sw   t0, AI_REG0+0x0(s0)
  sw   zero, AI_REG0+0x4(s0)
  li   t0, 0x80100000
  sw   t0, AI_REG0+0x8(s0)
  sw   zero, AI_REG0+0xC(s0)
  li   t0, 0x3
  sw   t0, AI_REG0+0x10(s0)

  # ---- Build good desc in DRAM (desc_good) ----
  la   a0, desc_good
  li   t0, (3 << 16) | 1  /* OP_LAYOUT (spine; no GEMM) */
  sw   t0, 0x00(a0)
  sw   zero, 0x04(a0)
  li   t0, 8
  sw   t0, 0x08(a0)
  sw   t0, 0x0C(a0)
  sw   t0, 0x10(a0)
  li   t0, 0x00080008
  sw   t0, 0x14(a0)
  li   t0, 0x80010000
  sw   t0, 0x18(a0)
  sw   zero, 0x1C(a0)
  li   t0, 0x80011000
  sw   t0, 0x20(a0)
  sw   zero, 0x24(a0)
  li   t0, 0x80012000
  sw   t0, 0x28(a0)
  sw   zero, 0x2C(a0)
  sw   zero, 0x30(a0)
  sw   zero, 0x34(a0)
  li   t0, 0x80013000
  sw   t0, 0x38(a0)
  sw   zero, 0x3C(a0)

  # desc_ptr = &desc_good
  la   t0, desc_good
  sw   t0, AI_DESCPTR(s0)
  srli t1, t0, 32
  sw   t1, AI_DESCPTR+4(s0)
  fence
  lw   zero, AI_CTL(s0)

  # Doorbell: ticket=5, qid=0, fetch
  li   t0, DB_FETCH | (5 << 8)
  sw   t0, AI_DOORBELL(s0)

  li   t2, 500
1:
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  bnez t0, 2f
  addi t2, t2, -1
  bnez t2, 1b
  j    fail
2:
  lw   t0, AI_TICKET(s0)
  li   t1, 5
  bne  t0, t1, fail
  lw   t0, AI_DSTATUS(s0)
  slli t0, t0, 48
  srli t0, t0, 48
  li   t1, ST_OK
  bne  t0, t1, fail
  li   t0, 1
  sw   t0, AI_DONE(s0)

  # ---- Bad ptr_a in memory image, re-fetch ----
  la   a0, desc_good
  li   t0, 0x90000000
  sw   t0, 0x18(a0)
  fence
  lw   zero, AI_CTL(s0)
  li   t0, DB_FETCH | (6 << 8)
  sw   t0, AI_DOORBELL(s0)
  li   t2, 500
3:
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  bnez t0, 4f
  addi t2, t2, -1
  bnez t2, 3b
  j    fail
4:
  lw   t0, AI_DSTATUS(s0)
  slli t0, t0, 48
  srli t0, t0, 48
  li   t1, ST_BAD_PTR
  bne  t0, t1, fail

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
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
7: j 7b

  .section .data
  .align 6
  .globl desc_good
desc_good:
  .space 64

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
