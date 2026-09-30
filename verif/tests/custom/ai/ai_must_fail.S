# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# NEGATIVE ORACLE CONTROL (H3 / RT-H1): writes the failure word 3 = (1 << 1) | 1 --
# exit code 1 with the exit bit set, so both harness variants classify FAILED on the
# spot instead of running to the timeout -- and nothing else. The AI suite must classify this ELF
# FAIL on every run; a run in which it reads PASS has a pass-biased classifier
# (the 2026-08-31 class) and every PASS in that run is void.
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  beqz t0, 1f
2: wfi
  j    2b
1:
  li   a0, 3
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
