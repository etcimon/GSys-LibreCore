# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Concurrent dual-active residual (soft): peer writes tohost while primary
# stays ready (no WFI). Live still open under some hold schedules; hard dual-
# active gate is smt_peer_tohost (primary WFI yield). Spike -p2 greened.

  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, peer_pass

  li   t1, 8000
1:
  addi t1, t1, -1
  andi t2, t1, 3
  bnez t2, 2f
  nop
2:
  bnez t1, 1b
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

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
