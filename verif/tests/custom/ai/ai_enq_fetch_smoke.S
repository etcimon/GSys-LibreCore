# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Sideband ai.enq with rs1 = DRAM desc pointer (no MMIO desc latch):
#   build good desc in .data, ai.enq a0,a1 with a1=&desc → DMA fetch → ST_OK.
#   Corrupt ptr_a in place, enq again → ST_BAD_PTR after fetch+AI-3.
# Drain protocol: fence + load island reg after DRAM stores before enq.
# HTIF fail codes odd only. Soft-pass on bus/illegal.

  .equ AI_BASE,    0x40000000
  .equ AI_CTL,     0x100
  .equ AI_DONE,    0x10C
  .equ AI_TICKET,  0x110
  .equ AI_DSTATUS, 0x114
  .equ AI_REG0,    0x120
  .equ ST_OK,      0
  .equ ST_BAD_PTR, 4

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap_vec
  csrw mtvec, t0
  andi sp, sp, -16

  li   t0, 0x61
  csrw 0x5C1, t0

  li   s0, AI_BASE
  li   t0, 1
  sw   t0, AI_CTL(s0)

  # Region [0x80000000, 0x80100000) RW covers code+data
  li   t0, 0x80000000
  sw   t0, AI_REG0+0x0(s0)
  sw   zero, AI_REG0+0x4(s0)
  li   t0, 0x80100000
  sw   t0, AI_REG0+0x8(s0)
  sw   zero, AI_REG0+0xC(s0)
  li   t0, 0x3
  sw   t0, AI_REG0+0x10(s0)

  # Build good descriptor at desc_mem
  la   a0, desc_mem
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

  fence
  # Touch last store so WT wbuf commits before DMA
  lw   t1, 0x18(a0)
  lw   zero, AI_CTL(s0)

  # ai.enq a0, a1  with a1 = &desc_mem (triggers island DMA fetch)
  la   a1, desc_mem
  .word 0x0005D55B
  mv   s1, a0

  fence
  li   t2, 500
1:
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  bnez t0, 2f
  addi t2, t2, -1
  bnez t2, 1b
  j    fail_d1
2:
  lw   t0, AI_TICKET(s0)
  bne  t0, s1, fail_tk
  lw   t0, AI_DSTATUS(s0)
  slli t0, t0, 48
  srli t0, t0, 48
  li   t1, ST_OK
  bne  t0, t1, fail_st
  # poll ticket OK
  mv   a1, s1
  .word 0x0205D55B
  li   t0, 1
  bne  a0, t0, fail_pl

  li   t0, 1
  sw   t0, AI_DONE(s0)

  # Corrupt ptr_a in DRAM, enq again
  # Load-back drains WT write buffer so DMA sees the update (fence alone may not).
  la   a0, desc_mem
  lui  t0, 0x90000
  sw   t0, 0x18(a0)
  fence
  lw   t1, 0x18(a0)
  # 32-bit compare (lw sign-extends on RV64)
  slli t1, t1, 32
  srli t1, t1, 32
  slli t2, t0, 32
  srli t2, t2, 32
  bne  t1, t2, fail_d2
  lw   zero, AI_CTL(s0)
  la   a1, desc_mem
  .word 0x0005D55B
  mv   s1, a0
  fence
  li   t2, 500
3:
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  bnez t0, 4f
  addi t2, t2, -1
  bnez t2, 3b
  j    fail_d2
4:
  lw   t0, AI_DSTATUS(s0)
  slli t0, t0, 48
  srli t0, t0, 48
  li   t1, ST_BAD_PTR
  bne  t0, t1, fail_bp

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
5: j 5b

fail_d1:
  li   a0, 11
  j    fe
fail_tk:
  li   a0, 13
  j    fe
fail_st:
  # encode status: ((st+20)<<1)|1
  addi a0, t0, 20
  slli a0, a0, 1
  ori  a0, a0, 1
  j    fe
fail_pl:
  li   a0, 15
  j    fe
fail_d2:
  li   a0, 17
  j    fe
fail_bp:
  addi a0, t0, 30
  slli a0, a0, 1
  ori  a0, a0, 1
  j    fe
fe:
  la   t0, tohost
  sw   a0, 0(t0)
6: j 6b

trap_vec:
  li   a0, 5
  la   t0, tohost
  sw   a0, 0(t0)
7: j 7b

  .section .data
  .align 6
  .globl desc_mem
desc_mem:
  .space 64

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
