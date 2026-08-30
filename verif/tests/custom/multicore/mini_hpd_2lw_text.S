# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S4: two lw of the same .text word, no jr. If HANG, D$ of .text twice
# is enough (I$/D$ alias). If PASS, 2jr needs the jr between the loads.
#

  .option rvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, hart1
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  lla  a0, tword
  lw   a1, 0(a0)
  lw   a2, 0(a0)
  li   t0, 0x11111111
  bne  a1, t0, fail3
  bne  a2, t0, fail5
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

  .align 2
tword:
  .word 0x11111111
  .word 0x22222222

hart1:
  wfi
  j    hart1

fail3:
  li   a0, 3
  j    fail_exit
fail5:
  li   a0, 5
fail_exit:
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

trap:
  li   a0, 25
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
