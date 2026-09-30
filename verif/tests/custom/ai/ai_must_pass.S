# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# POSITIVE ORACLE CONTROL (H3 / RT-H1): writes the pass word and nothing else.
# The AI suite must classify this ELF PASS on every run; if it does not, the
# harness/classifier cannot say PASS and no other verdict in the run is evidence.
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  beqz t0, 1f
2: wfi
  j    2b
1:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
3: j 3b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
