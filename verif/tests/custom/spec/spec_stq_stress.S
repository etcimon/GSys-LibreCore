# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# FSE S6 directed: fill a deep speculative STQ / load window, then verify
# architectural store data. Stresses MaxOutstandingStores / DeepSpecEn STQ
# depth without relying on OoO. Self-check; a0=0 pass, a0=1 fail.

  .globl main
main:
  addi sp, sp, -128

  # Burst of independent stores (many STQ entries if DeepSpecEn)
  li   t0, 0
  li   t1, 16
1:
  sd   t0, 0(sp)
  sd   t0, 8(sp)
  sd   t0, 16(sp)
  sd   t0, 24(sp)
  addi t0, t0, 1
  addi t1, t1, -1
  bnez t1, 1b

  # Last store wave overwrites slots with unique values
  li   t0, 0xA0
  sd   t0, 0(sp)
  li   t0, 0xA1
  sd   t0, 8(sp)
  li   t0, 0xA2
  sd   t0, 16(sp)
  li   t0, 0xA3
  sd   t0, 24(sp)
  li   t0, 0xB0
  sd   t0, 32(sp)
  li   t0, 0xB1
  sd   t0, 40(sp)
  li   t0, 0xB2
  sd   t0, 48(sp)
  li   t0, 0xB3
  sd   t0, 56(sp)

  # Loads must observe architectural values (not cancelled wrong-path)
  ld   t1, 0(sp)
  li   t2, 0xA0
  bne  t1, t2, fail
  ld   t1, 8(sp)
  li   t2, 0xA1
  bne  t1, t2, fail
  ld   t1, 16(sp)
  li   t2, 0xA2
  bne  t1, t2, fail
  ld   t1, 24(sp)
  li   t2, 0xA3
  bne  t1, t2, fail
  ld   t1, 32(sp)
  li   t2, 0xB0
  bne  t1, t2, fail
  ld   t1, 40(sp)
  li   t2, 0xB1
  bne  t1, t2, fail
  ld   t1, 48(sp)
  li   t2, 0xB2
  bne  t1, t2, fail
  ld   t1, 56(sp)
  li   t2, 0xB3
  bne  t1, t2, fail

  # Interleave stores with forward branches (mispredict window + STQ)
  li   t0, 0
  li   t1, 8
2:
  beq  t0, t1, 3f
  sd   t0, 64(sp)
  ld   t2, 64(sp)
  bne  t0, t2, fail
  addi t0, t0, 1
  j    2b
3:
  ld   t2, 64(sp)
  li   t3, 7
  bne  t2, t3, fail

  addi sp, sp, 128
  li   a0, 0
  ret

fail:
  addi sp, sp, 128
  li   a0, 1
  ret
