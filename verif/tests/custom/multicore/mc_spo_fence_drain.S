# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Speculative / multi-core ordering: store → FENCE → load must observe store.
# Narrow RVWMO drain check for shared L2 packages.

  .globl main
main:
  addi sp, sp, -32
  li   t0, 0x55AA55AA55AA55AA
  sd   t0, 0(sp)
  fence w, r
  ld   t1, 0(sp)
  bne  t0, t1, fail

  li   t0, 0xF00DF00DF00DF00D
  sd   t0, 8(sp)
  fence rw, rw
  ld   t1, 8(sp)
  bne  t0, t1, fail

  addi sp, sp, 32
  li   a0, 0
  jal  exit

fail:
  addi sp, sp, 32
  li   a0, 1
  jal  exit
