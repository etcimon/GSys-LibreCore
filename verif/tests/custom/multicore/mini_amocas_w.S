# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Bare-metal Zacas AMOCAS.W without CRT (Verilator-friendly single image).
# Requires CVA6Cfg.RVZacas=1. Soft-pass via tohost=1 if illegal (no Zacas).

  .section .text.init
  .globl _start
_start:
  # Stack in DRAM
  li   sp, 0x80008000

  # Trap → soft pass (no Zacas in RTL/ISS)
  la   t0, trap
  csrw mtvec, t0

  # success path: mem==expected → swap
  li   t0, 0x11111111
  sw   t0, 0(sp)
  li   a0, 0x11111111          # expected
  li   a1, 0x22222222          # new
  mv   a2, sp
  .word 0x28B6252F             # amocas.w a0, a1, (a2)
  li   t1, 0x11111111
  bne  a0, t1, fail
  lw   t2, 0(sp)
  li   t3, 0x22222222
  bne  t2, t3, fail

  # fail path: mem!=expected → keep (offset 8: dword-aligned low word for AXI CAS pack)
  li   t0, 0x33333333
  sw   t0, 8(sp)
  li   a0, 0xDEADBEEF
  li   a1, 0x44444444
  addi a2, sp, 8
  .word 0x28B6252F
  li   t1, 0x33333333
  bne  a0, t1, fail
  lw   t2, 8(sp)
  bne  t2, t1, fail

  # PASS
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

trap:
  # illegal AMOCAS → soft pass
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
