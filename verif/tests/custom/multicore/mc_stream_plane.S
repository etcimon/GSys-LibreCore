# SPDX-License-Identifier: LicenseRef-Proprietary
# Copyright (c) 2026 Etienne Cimon
#
# Stream plane integrity: sequential 512B + 4 non-overlapping stream heads.

  .globl main
main:
  li   t0, 512
  sub  sp, sp, t0
  mv   s0, sp

  # Sequential fill 512B
  mv   t0, s0
  li   t1, 512
1:
  sub  t2, t0, s0
  xor  t3, t0, t2
  sd   t3, 0(t0)
  addi t0, t0, 8
  addi t1, t1, -8
  bnez t1, 1b

  # Sequential verify
  mv   t0, s0
  li   t1, 512
2:
  sub  t2, t0, s0
  xor  t3, t0, t2
  ld   t4, 0(t0)
  bne  t3, t4, fail
  addi t0, t0, 8
  addi t1, t1, -8
  bnez t1, 2b

  # Four stream heads at +0,+64,+128,+192 — single store each (no overlap)
  li   s3, 0
3:
  slli t5, s3, 6
  add  t0, s0, t5
  li   t3, 0x100
  add  t3, t3, s3
  xor  t3, t3, t0
  sd   t3, 0(t0)
  addi s3, s3, 1
  li   t6, 4
  blt  s3, t6, 3b

  li   s3, 0
4:
  slli t5, s3, 6
  add  t0, s0, t5
  li   t3, 0x100
  add  t3, t3, s3
  xor  t3, t3, t0
  ld   t4, 0(t0)
  bne  t3, t4, fail
  addi s3, s3, 1
  li   t6, 4
  blt  s3, t6, 4b

  # Line-strided thrash over 512B stride 64
  li   s2, 64
  mv   t0, s0
  li   t1, 512
5:
  li   t3, 0x55
  xor  t3, t3, t0
  sd   t3, 0(t0)
  add  t0, t0, s2
  sub  t1, t1, s2
  bgtz t1, 5b

  mv   t0, s0
  li   t1, 512
6:
  li   t3, 0x55
  xor  t3, t3, t0
  ld   t4, 0(t0)
  bne  t3, t4, fail
  add  t0, t0, s2
  sub  t1, t1, s2
  bgtz t1, 6b

  li   t0, 512
  add  sp, sp, t0
  li   a0, 0
  jal  exit

fail:
  li   t0, 512
  add  sp, sp, t0
  li   a0, 1
  jal  exit
