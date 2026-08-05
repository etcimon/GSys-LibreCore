# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# FSE S6.2 directed RVWMO / A subset (single-hart, same-core):
#   1. Coherence: two stores to same address, load sees youngest
#   2. RAW mem with ALU between (no fence) — program order
#   3. FENCE between W and R
#   4. AMOADD.D returns old, memory holds sum
#   5. LR.D / SC.D success path on uncontended location
# Spec: RVWMO §3.1, A §5.1, Zalrsc. Not a multi-hart litmus suite.
# Self-check; a0=0 pass.

  .globl main
main:
  addi sp, sp, -64

  # ---- 1) Coherence / youngest store ----
  li   t0, 1
  sd   t0, 0(sp)
  li   t0, 2
  sd   t0, 0(sp)
  ld   t1, 0(sp)
  li   t2, 2
  bne  t1, t2, fail

  # ---- 2) RAW store-to-load with ALU noise ----
  li   t0, 0xCAFE
  sd   t0, 8(sp)
  li   t3, 1
  add  t3, t3, t3
  ld   t1, 8(sp)
  bne  t0, t1, fail
  li   t2, 2
  bne  t3, t2, fail

  # ---- 3) Fence between W and R ----
  li   t0, 0x10
  sd   t0, 16(sp)
  fence rw, rw
  ld   t1, 16(sp)
  bne  t0, t1, fail
  li   t0, 0x20
  sd   t0, 24(sp)
  fence r, rw
  ld   t1, 24(sp)
  bne  t0, t1, fail

  # ---- 4) AMOADD.D ----
  addi t4, sp, 40
  li   t0, 100
  sd   t0, 0(t4)
  li   t1, 7
  amoadd.d t2, t1, (t4)
  li   t3, 100
  bne  t2, t3, fail
  ld   t2, 0(t4)
  li   t3, 107
  bne  t2, t3, fail

  # ---- 5) LR.D / SC.D uncontended ----
  addi t4, sp, 48
  li   t0, 0x55
  sd   t0, 0(t4)
  lr.d t1, (t4)
  bne  t1, t0, fail
  li   t2, 0x66
  sc.d t3, t2, (t4)       # t3==0 success
  bnez t3, fail
  ld   t1, 0(t4)
  bne  t1, t2, fail

  addi sp, sp, 64
  li   a0, 0
  ret

fail:
  addi sp, sp, 64
  li   a0, 1
  ret
