# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S4: two lw of the same .data word with a jal between them (not jr a5
# of loaded data). If HANG, any CF between two loads of one line is
# enough. If PASS, 2jr needs jr-of-the-loaded-pointer.
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

  la   a0, word
  lw   a1, 0(a0)
  jal  bump
  lw   a2, 0(a0)
  li   t0, 0x11111111
  bne  a1, t0, fail3
  bne  a2, t0, fail5
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

bump:
  ret

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

  .section .data
  .align 3
word:
  .word 0x11111111

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
