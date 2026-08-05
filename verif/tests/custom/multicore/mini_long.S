# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Stretch code past several I$ lines then write tohost=1.
# Diagnoses I$ fills beyond the first line under Variilator preload.

  .section .text.init
  .globl _start
_start:
  # ~1 KiB of nops then pass
  .rept 256
  addi x0, x0, 0
  .endr
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
