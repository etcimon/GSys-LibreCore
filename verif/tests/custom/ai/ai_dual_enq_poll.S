# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Dual sideband enq: good job then AI-3 bad-ptr job.
#
# Protocol — after any desc/region MMIO write, drain with a load of a
# *different* island register (e.g. AI_CTL) before ai.enq. Same-address
# load-back can store-buffer-forward and return the new data without the
# AXI write having updated the island latch; sideband is a core wire and
# races that write. fence alone is not enough.
# HTIF: only odd a0 (even = syscall hang on this harness).
  .equ AI_BASE, 0x40000000
  .equ AI_CTL,  0x100
  .equ AI_DONE, 0x10C
  .equ AI_DSTATUS, 0x114
  .equ AI_REG0, 0x120
  .equ AI_DESC, 0x140
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
  li   t0, 0x80010000
  sw   t0, AI_REG0+0x0(s0)
  sw   zero, AI_REG0+0x4(s0)
  li   t0, 0x80014000
  sw   t0, AI_REG0+0x8(s0)
  sw   zero, AI_REG0+0xC(s0)
  li   t0, 0x3
  sw   t0, AI_REG0+0x10(s0)
  li   t0, (3 << 16) | 1  /* OP_LAYOUT (spine; no GEMM) */
  sw   t0, AI_DESC+0x0(s0)
  sw   zero, AI_DESC+0x4(s0)
  li   t0, 8
  sw   t0, AI_DESC+0x8(s0)
  sw   t0, AI_DESC+0xC(s0)
  sw   t0, AI_DESC+0x10(s0)
  li   t0, 0x00080008
  sw   t0, AI_DESC+0x14(s0)
  li   t0, 0x80010000
  sw   t0, AI_DESC+0x18(s0)
  sw   zero, AI_DESC+0x1C(s0)
  li   t0, 0x80011000
  sw   t0, AI_DESC+0x20(s0)
  sw   zero, AI_DESC+0x24(s0)
  li   t0, 0x80012000
  sw   t0, AI_DESC+0x28(s0)
  sw   zero, AI_DESC+0x2C(s0)
  sw   zero, AI_DESC+0x30(s0)
  sw   zero, AI_DESC+0x34(s0)
  li   t0, 0x80013000
  sw   t0, AI_DESC+0x38(s0)
  sw   zero, AI_DESC+0x3C(s0)
  # Drain program stores (different-reg load)
  lw   zero, AI_CTL(s0)
  fence
  li   a1, 0
  .word 0x0005D55B
  mv   s1, a0
  fence
  li   t2, 200
1:
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  bnez t0, 2f
  addi t2, t2, -1
  bnez t2, 1b
  j    fail
2:
  mv   a1, s1
  .word 0x0205D55B
  li   t0, 1
  bne  a0, t0, fail
  li   t0, 1
  sw   t0, AI_DONE(s0)
  # OOR ptr_a
  lui  t0, 0x90000
  sw   t0, AI_DESC+0x18(s0)
  # Different-reg drain (not same-addr load-back — STLF hazard)
  lw   zero, AI_CTL(s0)
  fence
  li   a1, 0
  .word 0x0005D55B
  mv   s1, a0
  fence
  li   t2, 200
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
  mv   a1, s1
  .word 0x0205D55B
  li   t0, 2
  bne  a0, t0, fail
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
  li   a0, 5
  la   t0, tohost
  sw   a0, 0(t0)
7: j 7b
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
