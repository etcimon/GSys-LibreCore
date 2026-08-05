# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Bare-metal store→load forward (same-core RAW). No CRT/memset.
# PASS tohost=1, FAIL tohost=3 (odd, bit0 set).

  .section .text.init
  .globl _start
_start:
  # DRAM stack (same as mini_amocas_*); avoid .bss end-of-image edge
  li   sp, 0x80008000

  li   t0, 0xCAFEBABEDEADBEEF
  sd   t0, 0(sp)
  li   t1, 1
  add  t1, t1, t1
  add  t1, t1, t1
  ld   t2, 0(sp)
  bne  t0, t2, fail
  li   t3, 4
  bne  t1, t3, fail

  li   t0, 0x0123456789ABCDEF
  sd   t0, 16(sp)
  ld   t2, 16(sp)
  bne  t0, t2, fail

  # tohost=1 → harness exit_code 0 (SUCCESS)
  li   a0, 1
  j    write_tohost

fail:
  li   a0, 3

write_tohost:
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
