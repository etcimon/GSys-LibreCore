# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# U10 AVX-like *scalar* memcpy stream (stand-in until RVV/Ara):
#   copy 256 B src→dst with unrolled SD/LD pairs, then verify.
# Exercises dual-issue store/load + L1/L2 hierarchy on server packages.

  .globl main
main:
  li   t0, 512
  sub  sp, sp, t0
  mv   s0, sp              # src
  addi s1, sp, 256         # dst

  # Fill src with pattern i ^ 0xC0FFEE
  li   t1, 0
  li   t2, 256
1:
  li   t3, 0xC0FFEE
  xor  t3, t3, t1
  add  t4, s0, t1
  sd   t3, 0(t4)
  addi t1, t1, 8
  blt  t1, t2, 1b

  # Memcpy 256 B (unrolled x2)
  li   t1, 0
2:
  add  t4, s0, t1
  add  t5, s1, t1
  ld   t3, 0(t4)
  ld   t6, 8(t4)
  sd   t3, 0(t5)
  sd   t6, 8(t5)
  addi t1, t1, 16
  li   t2, 256
  blt  t1, t2, 2b

  # Verify
  li   t1, 0
3:
  add  t4, s0, t1
  add  t5, s1, t1
  ld   t3, 0(t4)
  ld   t6, 0(t5)
  bne  t3, t6, fail
  addi t1, t1, 8
  li   t2, 256
  blt  t1, t2, 3b

  li   t0, 512
  add  sp, sp, t0
  li   a0, 0
  jal  exit

fail:
  li   t0, 512
  add  sp, sp, t0
  li   a0, 1
  jal  exit
