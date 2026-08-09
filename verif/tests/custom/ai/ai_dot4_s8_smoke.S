# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Xg6lcai T0 smoke: ai.dot4.s8 via custom-2 encoding.
# Requires g6lc64_ai (CvxifEn + COPRO_G6LC_AI + AiCfg.MatrixEn).
# Soft-pass on illegal-instruction (non-AI package).
#
# Encoding (isa-encoding.md §3.4):
#   funct7=0000000 | rs2 | rs1 | funct3=011 | rd | opcode=1011011
# ai.dot4.s8 a0, a1, a2  → rd=a0=10, rs1=a1=11, rs2=a2=12
#   0000000 01100 01011 011 01010 1011011
#   = 0x00C5B55B

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap_vec
  csrw mtvec, t0
  andi sp, sp, -16

  # Ensure ais is Initial/Clean/Dirty so the unit is not Off (CSR path).
  # On packages without AI this traps → soft-pass.
  csrr t0, 0x802
  li   t1, ~(0x3 << 6)
  and  t0, t0, t1
  li   t1, (0x1 << 6)          # Initial
  or   t0, t0, t1
  csrw 0x802, t0

  # a1 = four s8 lanes: 2, 3, 4, 5
  # a2 = four s8 lanes: 6, 7, 8, 9
  # expected s32 = 2*6 + 3*7 + 4*8 + 5*9 = 12+21+32+45 = 110
  li   a1, 0x05040302
  li   a2, 0x09080706
  li   a0, 0
  .word 0x00C5B55B             # ai.dot4.s8 a0, a1, a2

  li   t0, 110
  bne  a0, t0, fail

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j 1b

fail:
  li   a0, 2
  la   t0, tohost
  sw   a0, 0(t0)
2: j 2b

trap_vec:
  csrr t0, mcause
  li   t1, 2
  bne  t0, t1, fail
  li   a0, 1                    # soft-pass: AI not present
  la   t0, tohost
  sw   a0, 0(t0)
3: j 3b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
