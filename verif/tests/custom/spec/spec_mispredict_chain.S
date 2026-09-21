# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# FSE S2 directed stress: nested branches + call/return RAS traffic under a
# deep scoreboard window. Self-check; exit 0 on pass.
# Works with DeepSpecEn=0/1 and OoOEn=0/1.

#ifndef SPEC_CHAIN_EXPECTED
#define SPEC_CHAIN_EXPECTED 18
#endif

  .globl main
main:
  addi sp, sp, -16
  sd   ra, 8(sp)
  li   t0, 0
  li   t1, 10
  li   t2, 0

1:
  # Nested taken/not-taken mix
  beq  t0, t1, 2f
  call leaf_inc
  addi t0, t0, 1
  andi t3, t0, 1
  bnez t3, 1b
  j    1b

2:
  # Expected: leaf_inc called 10 times → t2 == 10
  li   a0, 10
  bne  t2, a0, fail

  # Second wave: forward + backward branches
  li   t0, 0
  li   t1, 8
3:
  beq  t0, t1, 4f
  call leaf_inc
  addi t0, t0, 1
  j    3b
4:
  li   a0, SPEC_CHAIN_EXPECTED
  bne  t2, a0, fail

  li   a0, 0
  j    done

leaf_inc:
  addi t2, t2, 1
  ret

fail:
  li   a0, 1
done:
  ld   ra, 8(sp)
  addi sp, sp, 16
  ret
