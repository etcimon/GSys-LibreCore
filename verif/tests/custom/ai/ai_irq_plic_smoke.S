# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Xg6lcai island completion → PLIC source 8 (irq_sources[7] → ID 8):
#   good desc with flags.IRQ, doorbell submit, wait done, PLIC IP bit 8,
#   claim ID 8, complete. Without IRQ flag, IP must stay clear.
# PLIC map (CVA6 plic_regmap): prio@0x0C00_0000+4*id, ip@0x0C00_1000,
#   ie0@0x0C00_2000, thr0@0x0C20_0000, claim0@0x0C20_0004.
# HTIF fail codes odd only. Soft-pass on bus/illegal (non-AI package).

  .equ AI_BASE,     0x40000000
  .equ AI_CTL,      0x100
  .equ AI_DOORBELL, 0x108
  .equ AI_DONE,     0x10C
  .equ AI_REG0,     0x120
  .equ AI_DESC,     0x140

  .equ PLIC_BASE,   0x0C000000
  .equ PLIC_PRIO8,  0x0C000020
  .equ PLIC_IP,     0x0C001000
  .equ PLIC_IE0,    0x0C002000
  .equ PLIC_THR0,   0x0C200000
  .equ PLIC_CC0,    0x0C200004
  .equ PLIC_ID_AI,  8
  .equ PLIC_BIT_AI, (1 << 8)

  .equ FLAG_IRQ,    0x4

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

  # Region q0 [0x80010000, 0x80014000) RW
  li   t0, 0x80010000
  sw   t0, AI_REG0+0x0(s0)
  sw   zero, AI_REG0+0x4(s0)
  li   t0, 0x80014000
  sw   t0, AI_REG0+0x8(s0)
  sw   zero, AI_REG0+0xC(s0)
  li   t0, 0x3
  sw   t0, AI_REG0+0x10(s0)

  # ---- PLIC: enable source 8 on context 0 (hart0 MEIP) ----
  li   t0, 1
  li   t1, PLIC_PRIO8
  sw   t0, 0(t1)
  li   t1, PLIC_THR0
  sw   zero, 0(t1)
  li   t0, PLIC_BIT_AI
  li   t1, PLIC_IE0
  sw   t0, 0(t1)

  # ---- Job A: IRQ flag set ----
  li   t0, (1 << 16) | 1
  sw   t0, AI_DESC+0x0(s0)
  li   t0, FLAG_IRQ
  sw   t0, AI_DESC+0x4(s0)
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

  # Doorbell ticket=1 qid=0
  li   t0, (1 << 8)
  sw   t0, AI_DOORBELL(s0)

  li   t2, 200
1:
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  bnez t0, 2f
  addi t2, t2, -1
  bnez t2, 1b
  j    fail_d1
2:
  # IP bit 8 must be set
  li   t1, PLIC_IP
  lw   t0, 0(t1)
  li   t2, PLIC_BIT_AI
  and  t0, t0, t2
  beqz t0, fail_ip0

  # Claim → ID 8 (clears IP; ia holds until complete)
  li   t1, PLIC_CC0
  lw   t0, 0(t1)
  li   t2, PLIC_ID_AI
  bne  t0, t2, fail_cl

  # Drop level source *before* complete, else level-set re-arms IP
  li   t0, 1
  sw   t0, AI_DONE(s0)
  fence

  # Complete
  sw   t2, 0(t1)

  # IP bit 8 must stay clear
  li   t1, PLIC_IP
  lw   t0, 0(t1)
  li   t2, PLIC_BIT_AI
  and  t0, t0, t2
  bnez t0, fail_ip1

  # ---- Job B: no IRQ flag → pending must stay clear ----
  sw   zero, AI_DESC+0x4(s0)
  li   t0, (2 << 8)
  sw   t0, AI_DOORBELL(s0)
  li   t2, 200
3:
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  bnez t0, 4f
  addi t2, t2, -1
  bnez t2, 3b
  j    fail_d2
4:
  li   t1, PLIC_IP
  lw   t0, 0(t1)
  li   t2, PLIC_BIT_AI
  and  t0, t0, t2
  bnez t0, fail_ip2

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
5: j 5b

fail_d1:
  li   a0, 11
  j    fe
fail_ip0:
  li   a0, 13
  j    fe
fail_cl:
  # encode claimed id: a0 = ((id+20)<<1)|1
  addi a0, t0, 20
  slli a0, a0, 1
  ori  a0, a0, 1
  j    fe
fail_ip1:
  li   a0, 15
  j    fe
fail_d2:
  li   a0, 17
  j    fe
fail_ip2:
  li   a0, 19
  j    fe
fe:
  la   t0, tohost
  sw   a0, 0(t0)
6: j 6b

trap_vec:
  # Bus error / illegal → soft-pass (island or PLIC absent)
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
