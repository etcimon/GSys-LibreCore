# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# FSE S6 directed: FENCE / FENCE.I drain after speculative stores and
# control-flow. Spec anchors: Zifencei (4.1), RVWMO (3.1). Self-check.

  .globl main
main:
  addi sp, sp, -64

  # Outstanding stores then FENCE rw,rw — later load must see data
  li   t0, 0x1111
  sd   t0, 0(sp)
  li   t1, 0x2222
  sd   t1, 8(sp)
  fence rw, rw
  ld   t2, 0(sp)
  bne  t0, t2, fail
  ld   t2, 8(sp)
  bne  t1, t2, fail

  # Store, mispredict-friendly branch, store, fence
  li   t0, 0x3333
  sd   t0, 16(sp)
  li   t3, 0
  bnez t3, skip_never
  li   t1, 0x4444
  sd   t1, 24(sp)
skip_never:
  fence rw, rw
  ld   t2, 16(sp)
  li   t0, 0x3333
  bne  t2, t0, fail
  ld   t2, 24(sp)
  li   t1, 0x4444
  bne  t2, t1, fail

  # FENCE.I after sequential store stream (I/D coherence contract)
  li   t0, 0x5555
  sd   t0, 32(sp)
  fence.i
  ld   t2, 32(sp)
  bne  t0, t2, fail

  # Nested calls around fence (RAS + memory)
  li   t6, 0
  call bump
  fence rw, rw
  call bump
  li   t0, 2
  bne  t6, t0, fail

  addi sp, sp, 64
  li   a0, 0
  ret

bump:
  addi t6, t6, 1
  ret

fail:
  addi sp, sp, 64
  li   a0, 1
  ret
