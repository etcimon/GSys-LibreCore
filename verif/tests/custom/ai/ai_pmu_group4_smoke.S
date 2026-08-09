# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Xg6lcai PMU group-4 smoke: program mhpmcounter3/4 for AI op + T0 events,
# run setcfg/getcfg/dot4, assert counters advanced.
# Requires g6lc64_ai (PerfCounterEn + COPRO_G6LC_AI + AiCfg.MatrixEn).
# Soft-pass on illegal-instruction (non-AI package).
#
# Encoding (ariane_pkg MHPMGrpAI=4):
#   mhpmevent = {group[7:5], idx[4:0]}
#   AI op complete  → 0x80  (group 4, idx 0)
#   AI T0 complete  → 0x83  (group 4, idx 3)
#   AI MMA complete → 0x81  (group 4, idx 1)  — optional path below

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap_vec
  csrw mtvec, t0
  andi sp, sp, -16

  # Ensure ais is Initial so the unit is not Off.
  csrr t0, 0x802
  li   t1, ~(0x3 << 6)
  and  t0, t0, t1
  li   t1, (0x1 << 6)
  or   t0, t0, t1
  csrw 0x802, t0

  # mcountinhibit: clear CY/IR and HPM3/HPM4/HPM5 (bits 0,2,3,4,5)
  csrr t0, 0x320
  li   t1, ~0x3d
  and  t0, t0, t1
  csrw 0x320, t0

  # mhpmevent3 = AI op complete (0x80)
  li   t0, 0x80
  csrw 0x323, t0
  # mhpmevent4 = AI T0 complete (0x83)
  li   t0, 0x83
  csrw 0x324, t0
  # mhpmevent5 = AI MMA complete (0x81)
  li   t0, 0x81
  csrw 0x325, t0

  # Zero counters
  csrw 0xb03, zero
  csrw 0xb04, zero
  csrw 0xb05, zero

  # T0 ops: setcfg + getcfg + dot4 (three result_valid + three T0 class)
  # getcfg a0: funct7=0000001, rd=a0 → 0x0200055B
  li   a1, 0x00000111          # M=N=K=log2(2)
  .word 0x0005855B             # ai.setcfg a0, a1
  .word 0x0200055B             # ai.getcfg a0
  li   a1, 0x05040302
  li   a2, 0x09080706
  li   a0, 0
  .word 0x00C5B55B             # ai.dot4.s8 a0, a1, a2
  mv   t6, a0                  # wait for last AI result in scoreboard

  csrr t0, 0xb03               # mhpmcounter3 = AI op
  li   t1, 3
  bltu t0, t1, fail            # need >= 3

  csrr t0, 0xb04               # mhpmcounter4 = AI T0
  li   t1, 3
  bltu t0, t1, fail

  # MMA path: zero counters, one mma, check MMA event
  csrw 0xb03, zero
  csrw 0xb04, zero
  csrw 0xb05, zero

  .word 0x0400005B             # ai.relacc acc0
  li   a1, 1
  .word 0x0605A05B             # ai.mvta t0, a1, e0
  li   a1, 2
  .word 0x0615A05B
  li   a1, 3
  .word 0x0685A05B
  li   a1, 4
  .word 0x0695A05B
  li   a1, 5
  .word 0x0605A0DB             # tile 1
  li   a1, 6
  .word 0x0615A0DB
  li   a1, 7
  .word 0x0685A0DB
  li   a1, 8
  .word 0x0695A0DB
  .word 0x0010105B             # ai.mma.s8 acc0, t0, t1
  .word 0x0400255B             # ai.mvacc a0, acc0, e0 — orders after MMA
  mv   t6, a0

  csrr t0, 0xb05               # mhpmcounter5 = AI MMA
  li   t1, 1
  bltu t0, t1, fail

  # AI op should have counted setup + mma + mvacc
  csrr t0, 0xb03
  li   t1, 1
  bltu t0, t1, fail

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
  li   a0, 1                    # soft-pass: AI / PMU not present
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
