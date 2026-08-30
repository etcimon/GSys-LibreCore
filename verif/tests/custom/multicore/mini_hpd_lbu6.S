# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S4 HPD bisect: 6 lbu to one 16B D$ line (HPD rtabEntries=4). Stock
# offset_ptr does 5 lbu into fdt+8's line then ld ra; TAGE died there.
# If this HANGS, rtab depth. If PASS, need offset_ptr+jtab together.
#
# tohost: 1 PASS; 3 bad byte; 25 trap
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

  la   a0, line16
  lbu  t0, 0(a0)
  lbu  t1, 1(a0)
  lbu  t2, 2(a0)
  lbu  t3, 3(a0)
  lbu  t4, 4(a0)
  lbu  t5, 5(a0)
  li   a1, 0xa0
  bne  t0, a1, fail3
  li   a1, 0xa5
  bne  t5, a1, fail3

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

hart1:
  wfi
  j    hart1

fail3:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

trap:
  li   a0, 25
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

  .section .data
  .align 4
line16:
  .byte 0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7
  .byte 0xa8, 0xa9, 0xaa, 0xab, 0xac, 0xad, 0xae, 0xaf

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
