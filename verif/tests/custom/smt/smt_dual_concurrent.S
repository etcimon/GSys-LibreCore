# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Pure no-WFI concurrent dual-active (live greened):
#   Primary burns (stays ready). Peer scores tohost without primary WFI.
#   RTL: cold-boot exclusive (hart 0 alone for OpenSBI temp-stack safety) then
#   first-activation exclusive + first-boot hold (core/cva6.sv).
#   Primary burn must exceed SMT_COLD_EXCL so peer still has time to score.

  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, peer_pass

  # Long dual-ready burn after cold-excl (~200k cycles); FAIL only if peer never scored
  li   t1, 400000
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
