# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Bare-metal Zacas AMOCAS.D without CRT.
# Requires CVA6Cfg.RVZacas=1. Soft-pass via tohost=1 if illegal (no Zacas).
# WT path: local uncached load-compare-store in missunit (no 128b AXI burst).

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  # success: mem==expected → swap
  li   t0, 0x1111111111111111
  sd   t0, 0(sp)
  li   a0, 0x1111111111111111
  li   a1, 0x2222222222222222
  mv   a2, sp
  .word 0x28B6352F             # amocas.d a0, a1, (a2)
  li   t1, 0x1111111111111111
  bne  a0, t1, fail
  ld   t2, 0(sp)
  li   t3, 0x2222222222222222
  bne  t2, t3, fail

  # mismatch: keep mem
  li   t0, 0x3333333333333333
  sd   t0, 16(sp)
  li   a0, 0xDEADBEEFCAFEBABE
  li   a1, 0x4444444444444444
  addi a2, sp, 16
  .word 0x28B6352F
  li   t1, 0x3333333333333333
  bne  a0, t1, fail
  ld   t2, 16(sp)
  bne  t2, t1, fail

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

trap:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

fail:
  li   a0, 3
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
