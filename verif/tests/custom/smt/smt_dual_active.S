# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Dual-active prove: dual-ready burn (both ready post-grace), then primary
# WFI-yields so peer can score tohost. Pure no-WFI concurrent remains open.

  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, peer_pass

  li   t1, 2000
1:
  addi t1, t1, -1
  andi t2, t1, 3
  bnez t2, 2f
  nop
2:
  bnez t1, 1b
3:
  wfi
  j    3b

peer_pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
4: j    4b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
