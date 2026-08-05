# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Bare-metal: exercise taken jumps across I$ lines, then PASS tohost.
# No CRT — single PHDR friendly for Verilator preload.

  .section .text.init
  .globl _start
_start:
  # line 0
  li   a0, 1
  j    L1
  .align 4
  .rept 8
  nop
  .endr

  .align 6                 # force new I$ line (~64B)
L1:
  li   a1, 2
  j    L2
  .align 6
L2:
  li   a2, 3
  # taken branch (always)
  li   t0, 1
  bnez t0, L3
  j    fail
  .align 6
L3:
  li   a3, 4
  # call/return style
  jal  ra, leaf
  # self-ish forward then back
  j    L4
  .align 6
L4:
  # check registers
  li   t0, 1
  bne  a0, t0, fail
  li   t0, 2
  bne  a1, t0, fail
  li   t0, 3
  bne  a2, t0, fail
  li   t0, 4
  bne  a3, t0, fail
  li   t0, 5
  bne  a4, t0, fail

  # PASS
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

leaf:
  li   a4, 5
  ret

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
