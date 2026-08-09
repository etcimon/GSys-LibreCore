# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Soft-ladder iter-012: fdt_get_property_by_offset_ error path shape
#   c.mv s2, a2   # lenp out-param (must stay stack pointer)
#   ... check fails ...
#   sw a0, 0(s2)  # must not store to code (historic mtval=0x80012b2a)
#
# Gate: g6lc64_smt2 DI; tohost=1 pass, 3 fail.

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  # Stack out-param slot
  addi a2, sp, -20
  li   t0, 0xdeadbeef
  sw   t0, 0(a2)

  # Capture like fdt_get_property_by_offset_: c.mv s2, a2
  c.mv s2, a2
  # Dual-issue-friendly neighbors (same class as hang-6 probes)
  li   s1, 0x1111
  li   s3, 0x2222
  c.mv a1, s1
  c.mv a0, s3
  # Force error path: negative a0
  li   a0, -4
  # beqz s2 skip; else sw a0,0(s2)
  beqz s2, fail
  sw   a0, 0(s2)

  # Check store landed on stack slot, not code
  lw   t1, 0(a2)
  li   t2, -4
  bne  t1, t2, fail
  # s2 still the stack pointer
  bne  s2, a2, fail

  # Loop thrash
  li   s4, 64
1:
  addi a2, sp, -24
  c.mv s2, a2
  li   a0, -11
  addi t3, t3, 1
  sw   a0, 0(s2)
  lw   t1, 0(a2)
  li   t2, -11
  bne  t1, t2, fail
  addi s4, s4, -1
  bnez s4, 1b

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

trap:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

fail:
  li   a0, 3
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
