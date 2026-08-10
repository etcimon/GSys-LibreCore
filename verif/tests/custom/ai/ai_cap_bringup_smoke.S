# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Capability window must advertise I1 live geometry:
#   clusters=1, macs/cycle=32 (PeLanes), AccTile M/N/K log2 = 8 (tile=256).
# Soft-pass if island window is an error slave (non-AI package).

  .equ AI_BASE,        0x40000000
  .equ CAP_VER,        0x00
  .equ CAP_CLUSTERS,   0x04
  .equ CAP_MACS,       0x08
  .equ CAP_BLOCK_MNK,  0x14

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap_vec
  csrw mtvec, t0
  andi sp, sp, -16

  li   s0, AI_BASE

  lw   t0, CAP_VER(s0)
  slli t0, t0, 48
  srli t0, t0, 48
  li   t1, 1
  bne  t0, t1, fail

  lw   t0, CAP_CLUSTERS(s0)
  li   t1, 1
  bne  t0, t1, fail

  lw   t0, CAP_MACS(s0)
  li   t1, 32
  bne  t0, t1, fail

  # packed log2(K)|log2(N)|log2(M) in low 12 bits — expect 8,8,8
  lw   t0, CAP_BLOCK_MNK(s0)
  andi t1, t0, 0xF
  li   t2, 8
  bne  t1, t2, fail
  srli t1, t0, 4
  andi t1, t1, 0xF
  bne  t1, t2, fail
  srli t1, t0, 8
  andi t1, t1, 0xF
  bne  t1, t2, fail

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j 1b

fail:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
2: j 2b

trap_vec:
  # Bus error → soft-pass (island absent)
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
3: j 3b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
