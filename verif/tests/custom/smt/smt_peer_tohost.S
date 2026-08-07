# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Diagnostic: only hart 1 writes tohost PASS. Hart 0 burns then WFI so the
# scheduler must switch to the peer after SMT_DRAM_GRACE. Proves peer runs.

  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, peer_pass

  # Hart 0: enough DRAM commits for grace, then WFI so peer is preferred.
  li   t1, 500
1:
  addi t1, t1, -1
  bnez t1, 1b
2:
  wfi
  j    2b

peer_pass:
  li   a0, 1
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
