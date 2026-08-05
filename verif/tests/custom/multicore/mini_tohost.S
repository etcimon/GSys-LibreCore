# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Minimal bare-metal: write PASS (1) to tohost and spin.
# Single contiguous text+data for Verilator preload debug.

  .section .text.init
  .globl _start
_start:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
