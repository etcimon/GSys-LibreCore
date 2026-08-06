# SPDX-License-Identifier: LicenseRef-Proprietary
# Copyright (c) 2026 Etienne Cimon
#
# Stream fill + AMOCAS handoff + integrity.
# Working set kept compact (512 B data + 8 B lock): WT D$ write-through makes
# multi-KiB loops multi-million-cycle on bare Variane; pattern is unchanged.
# Soft-skip CAS only if illegal (ISS without Zacas).

  .globl main
main:
  # frame: 512 B stream + 16 B pad/lock (aligned)
  li   t0, 544
  sub  sp, sp, t0
  mv   s0, sp
  addi s1, sp, 512            # CAS lock word (past stream)

  mv   t0, s0
  li   t1, 512
1:
  sub  t2, t0, s0
  xor  t3, t0, t2
  sd   t3, 0(t0)
  addi t0, t0, 8
  addi t1, t1, -8
  bnez t1, 1b

  csrr t0, misa
  li   t1, (1 << 0)
  and  t2, t0, t1
  beqz t2, skip_cas

  la   t0, cas_illegal
  csrw mtvec, t0

  sw   zero, 0(s1)
  li   a0, 0
  li   a1, 1
  mv   a2, s1
  .word 0x28B6252F
  bnez a0, fail
  lw   t0, 0(s1)
  li   t1, 1
  bne  t0, t1, fail

  li   a0, 1
  li   a1, 0
  mv   a2, s1
  .word 0x28B6252F
  li   t1, 1
  bne  a0, t1, fail

skip_cas:
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

  li   t0, 544
  add  sp, sp, t0
  li   a0, 0
  jal  exit

  .align 2
cas_illegal:
  # Continue without CAS — jump to verify
  j    skip_cas

fail:
  li   t0, 544
  add  sp, sp, t0
  li   a0, 1
  jal  exit
