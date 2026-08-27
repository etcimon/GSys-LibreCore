# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# SL-C control: same as mini_ipi_hart1_sp but no CLINT MSIP. Hart0 WFI
# lifts COLD_EXCL (G1df); G1di should still keep unseen hart1 !ready.
# Expect cap hang (tohost=0). PASS would mean G1di is not the residual.

  .option rvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, hart1
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0
1: wfi
  j    1b

hart1:
  li   sp, 0x80007000
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
2: wfi
  j    2b

trap:
  li   a0, 25
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
