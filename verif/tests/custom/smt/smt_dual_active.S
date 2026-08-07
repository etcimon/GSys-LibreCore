# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Concurrent dual-active (post-grace): peer writes tohost PASS while primary
# stays ready (no WFI). Proves quantum/miss can schedule the peer under
# dual-ready. Spike -p2 greened; live may still fail if peer is not selected
# before primary times out (see smt2-bringup.md). Hard dual-active gate remains
# smt_peer_tohost (primary WFI yield).

  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, peer_pass

  # Hart 0: long burn, then FAIL if peer never scored
  li   t1, 50000
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
