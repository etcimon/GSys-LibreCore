# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Directed memory dependence / store-to-load stress for OoO LSQ path:
#   1. Store then load same address (RAW mem) — must see store data
#   2. Store A, store B, load A — youngest/correct data
#   3. Independent loads interleaved with ALU
# Passes on both in-order and OoOEn configs (functional correctness).

  .globl main
main:
  # Scratch in .bss-style stack-relative area
  addi sp, sp, -64

  # ---- 1) Store-to-load same address ----
  li   t0, 0x1111222233334444
  sd   t0, 0(sp)
  ld   t1, 0(sp)
  bne  t0, t1, fail

  # ---- 2) Two stores, load first address ----
  li   t0, 0xAAAAAAAABBBBBBBB
  li   t1, 0xCCCCCCCCDDDDDDDD
  sd   t0, 8(sp)
  sd   t1, 16(sp)
  ld   t2, 8(sp)
  bne  t0, t2, fail
  ld   t3, 16(sp)
  bne  t1, t3, fail

  # ---- 3) Overwrite then load (WAW mem) ----
  li   t0, 0x1
  sd   t0, 24(sp)
  li   t0, 0x2
  sd   t0, 24(sp)
  ld   t1, 24(sp)
  li   t2, 0x2
  bne  t1, t2, fail

  # ---- 4) Interleaved ALU + mem ----
  li   a1, 0
  li   a2, 16
  li   t0, 0
2:
  add  t0, t0, a1
  sd   t0, 32(sp)
  ld   t1, 32(sp)
  bne  t0, t1, fail
  addi a1, a1, 1
  addi a2, a2, -1
  bnez a2, 2b
  # sum 0..15 = 120
  li   a0, 120
  bne  t0, a0, fail

  # ---- 5) Word/half sizes ----
  li   t0, 0xDEADBEEF
  sw   t0, 40(sp)
  lwu  t1, 40(sp)
  bne  t0, t1, fail
  li   t0, 0xBEEF
  sh   t0, 44(sp)
  lhu  t1, 44(sp)
  bne  t0, t1, fail

  addi sp, sp, 64
  li   a0, 0
  jal  exit

fail:
  addi sp, sp, 64
  li   a0, 1
  jal  exit
