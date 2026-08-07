# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Pure no-WFI concurrent dual-active (live greened):
#   Primary burns (stays ready). Peer scores tohost without primary WFI.
#   RTL: first-activation exclusive window + first-boot hold (core/cva6.sv).

  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, peer_pass

  # Long dual-ready burn; FAIL only if peer never scored
  li   t1, 20000
1:
  addi t1, t1, -1
  andi t2, t1, 7
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
