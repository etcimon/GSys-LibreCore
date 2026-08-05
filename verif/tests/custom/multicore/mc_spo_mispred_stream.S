# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Mispredict chain interleaved with stream stores — stresses cancel vs
# store buffer under multi-core packages (single-hart). Branch direction
# depends on a running counter; stores must still verify.

  .globl main
main:
  li   t0, 2048
  sub  sp, sp, t0
  mv   s0, sp
  li   s1, 0                  # loop index
  li   s2, 32                 # iterations
  li   s3, 0                  # taken count

1:
  # Stream store at s0 + s1*8
  slli t0, s1, 3
  add  t1, s0, t0
  xor  t2, t1, s1
  sd   t2, 0(t1)

  # Mispredict-friendly: alternate taken/not-taken via andi
  andi t3, s1, 1
  beqz t3, 2f
  addi s3, s3, 1              # taken path
  j    3f
2:
  addi s3, s3, 0              # not-taken (nop-ish)
3:
  addi s1, s1, 1
  blt  s1, s2, 1b

  # Expect taken count == 16 (half of 32)
  li   t0, 16
  bne  s3, t0, fail

  # Verify stores
  li   s1, 0
4:
  slli t0, s1, 3
  add  t1, s0, t0
  xor  t2, t1, s1
  ld   t3, 0(t1)
  bne  t2, t3, fail
  addi s1, s1, 1
  blt  s1, s2, 4b

  li   t0, 2048
  add  sp, sp, t0
  li   a0, 0
  jal  exit

fail:
  li   t0, 2048
  add  sp, sp, t0
  li   a0, 1
  jal  exit
