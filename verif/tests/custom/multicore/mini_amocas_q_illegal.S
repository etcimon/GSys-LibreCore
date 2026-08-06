# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# AMOCAS.Q is intentionally NOT implemented (AGENTS-todo §8 deferred).
# On RV64 with Zacas W/D, AMOCAS.Q (funct3=100) must illegal-trap.
# Bare-metal: trap → PASS (tohost=1); fallthrough / success without trap → FAIL.

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap_ok
  csrw mtvec, t0

  # AMOCAS.Q a0, a1, (a2) — funct5=00101, funct3=100 (128-bit)
  # Encoding: 0x28B6452F (same as amocas.w but funct3=4)
  li   a0, 0
  li   a1, 0
  mv   a2, sp
  .word 0x28B6452F

  # Must not reach here if illegal works
  j    fail

trap_ok:
  # Illegal-instruction path is the golden for deferred Q
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

fail:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
