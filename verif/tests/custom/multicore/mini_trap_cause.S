# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# After 170 nops, store to tohost; if it traps, report mcause via tohost.

  .section .text.init
  .globl _start
_start:
  la   t0, trap_handler
  csrw mtvec, t0

  .rept 170
  c.nop
  .endr

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)          # may trap
1: j    1b

  .align 2
trap_handler:
  csrr a0, mcause
  # encode: (mcause << 1) | 1 so TB sees bit0=1 and non-zero exit
  slli a0, a0, 1
  ori  a0, a0, 1
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
