# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# U10ᵇ directed vector memcpy (e64, m1, unit-stride).
#
# - misa.V clear  → soft-pass (exit 0) so non-_v packages stay green.
# - misa.V set    → enable mstatus.VS and run vsetvli/vle64/vse64 via *raw*
#   encodings (no V-capable assembler required).
#
# REQUIRES live Ara (CVA6_ARA_ATTACH + Ara on flist). Stub attach ties
# acc_resp idle and will hang if V ops are issued — only run this under
# live-Ara cosim (see agents/guides/AGENTS-vector.md).

#include "encoding.h"

  .globl main
main:
  csrr t0, misa
  li   t1, (1 << 21)          # V
  and  t2, t0, t1
  beqz t2, soft_skip

  # Enable vector state (VS = Dirty)
  li   t0, MSTATUS_VS
  csrs mstatus, t0

  # Stack: 256 B src + 256 B dst
  li   t0, 512
  sub  sp, sp, t0
  mv   s0, sp                 # src
  addi s1, sp, 256            # dst

  # Fill src with pattern i ^ 0xC0FFEE (8-byte steps)
  li   t1, 0
  li   t2, 256
1:
  li   t3, 0xC0FFEE
  xor  t3, t3, t1
  add  t4, s0, t1
  sd   t3, 0(t4)
  addi t1, t1, 8
  blt  t1, t2, 1b

  # Vector memcpy 256 B = 32 × e64
  mv   a1, s0                 # load base
  mv   a2, s1                 # store base
  li   a3, 32                 # remaining elements
2:
  mv   a0, a3                 # AVL
  # vsetvli t0, a0, e64, m1, ta, ma  (vtype=0xD8)
  # encoding: zimm[10:0]=0xD8, rs1=a0, funct3=111, rd=t0, opcode=OP-V
  .word 0x0D8572D7
  beqz t0, fail               # vl must be > 0
  # vle64.v v1, (a1)
  .word 0x0205F087
  # vse64.v v1, (a2)
  .word 0x020670A7
  slli t1, t0, 3              # bytes = vl * 8
  add  a1, a1, t1
  add  a2, a2, t1
  sub  a3, a3, t0
  bnez a3, 2b

  # Scalar verify
  li   t1, 0
  li   t2, 256
3:
  add  t4, s0, t1
  add  t5, s1, t1
  ld   t3, 0(t4)
  ld   t6, 0(t5)
  bne  t3, t6, fail
  addi t1, t1, 8
  blt  t1, t2, 3b

  li   t0, 512
  add  sp, sp, t0
  li   a0, 0
  jal  exit

soft_skip:
  li   a0, 0
  jal  exit

fail:
  li   t0, 512
  add  sp, sp, t0
  li   a0, 1
  jal  exit
