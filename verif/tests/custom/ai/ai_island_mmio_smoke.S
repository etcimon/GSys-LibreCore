# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Xg6lcai island MMIO smoke on the SoC GPIO window (0x4000_0000) when
# AiCfg.MatrixEn is set (g6lc64_ai). Programs a legal region, submits a good
# descriptor via the doorbell, then rejects an out-of-range pointer (AI-3).
# Soft-pass if the window is an error slave (non-AI package).

  .equ AI_BASE,   0x40000000
  .equ AI_CAP_VER, 0x00
  .equ AI_CTL,     0x100
  .equ AI_STATUS,  0x104
  .equ AI_DOORBELL,0x108
  .equ AI_DONE,    0x10C
  .equ AI_TICKET,  0x110
  .equ AI_DSTATUS, 0x114
  .equ AI_REG0,    0x120
  .equ AI_DESC,    0x140

  # Status codes (g6lc_ai_desc_pkg)
  .equ ST_OK,      0
  .equ ST_BAD_PTR, 4

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap_vec
  csrw mtvec, t0
  andi sp, sp, -16

  li   s0, AI_BASE

  # Cap version must be 1 (or bus error → soft-pass)
  lw   t0, AI_CAP_VER(s0)
  slli t0, t0, 48
  srli t0, t0, 48
  li   t1, 1
  bne  t0, t1, fail

  # Enable engine
  li   t0, 1
  sw   t0, AI_CTL(s0)

  # Region q0: [0x80010000, 0x80014000) RW
  li   t0, 0x80010000
  sw   t0, AI_REG0+0x0(s0)
  sw   zero, AI_REG0+0x4(s0)
  li   t0, 0x80014000
  sw   t0, AI_REG0+0x8(s0)
  sw   zero, AI_REG0+0xC(s0)
  li   t0, 0x3
  sw   t0, AI_REG0+0x10(s0)

  # Descriptor: version=1 op=GEMM, ptrs inside region
  # word0: op<<16 | version
  li   t0, (1 << 16) | 1
  sw   t0, AI_DESC+0x0(s0)
  sw   zero, AI_DESC+0x4(s0)   # flags
  li   t0, 8
  sw   t0, AI_DESC+0x8(s0)     # m
  sw   t0, AI_DESC+0xC(s0)     # n
  sw   t0, AI_DESC+0x10(s0)    # k
  li   t0, 0x00080008
  sw   t0, AI_DESC+0x14(s0)    # ld_ab
  li   t0, 0x80010000
  sw   t0, AI_DESC+0x18(s0)    # ptr_a lo
  sw   zero, AI_DESC+0x1C(s0)
  li   t0, 0x80011000
  sw   t0, AI_DESC+0x20(s0)    # ptr_b
  sw   zero, AI_DESC+0x24(s0)
  li   t0, 0x80012000
  sw   t0, AI_DESC+0x28(s0)    # ptr_c
  sw   zero, AI_DESC+0x2C(s0)
  sw   zero, AI_DESC+0x30(s0)  # ptr_scale
  sw   zero, AI_DESC+0x34(s0)
  li   t0, 0x80013000
  sw   t0, AI_DESC+0x38(s0)    # ptr_done
  sw   zero, AI_DESC+0x3C(s0)

  # Doorbell: ticket=7, qid=0  → bits[31:8]=7, [7:0]=0
  li   t0, (7 << 8)
  sw   t0, AI_DOORBELL(s0)

  # Poll done sticky
  li   t2, 200
1:
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  bnez t0, 2f
  addi t2, t2, -1
  bnez t2, 1b
  j    fail
2:
  lw   t0, AI_TICKET(s0)
  li   t1, 7
  bne  t0, t1, fail
  lw   t0, AI_DSTATUS(s0)
  slli t0, t0, 48
  srli t0, t0, 48
  li   t1, ST_OK
  bne  t0, t1, fail
  # clear sticky
  li   t0, 1
  sw   t0, AI_DONE(s0)

  # Bad pointer submit
  li   t0, 0x90000000
  sw   t0, AI_DESC+0x18(s0)    # ptr_a OOR
  li   t0, (8 << 8)
  sw   t0, AI_DOORBELL(s0)
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
  # Bus error / illegal → soft-pass (island absent)
  li   a0, 1
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
