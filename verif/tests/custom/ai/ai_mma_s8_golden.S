# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Xg6lcai T1 golden: 2x2x2 s8 MMA via tile RF + multi-cycle ai.mma.s8.
# Package: g6lc64_ai. Soft-pass on illegal (non-AI).
#
# A = [[1,2],[3,4]]  B = [[5,6],[7,8]]
# C = A*B = [[19,22],[43,50]]  (accmode=overwrite)
#
# Tile layout (elab TileN=8): A[m,k] @ m*8+k, B[k,n] @ k*8+n

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap_vec
  csrw mtvec, t0
  andi sp, sp, -16

  # ais = Initial
  csrr t0, 0x802
  li   t1, ~(0x3 << 6)
  and  t0, t0, t1
  li   t1, (0x1 << 6)
  or   t0, t0, t1
  csrw 0x802, t0

  # setcfg: M=N=K=log2(2)=1, dtype=s8, accmode=overwrite
  li   a1, 0x00000111
  .word 0x0005855B             # ai.setcfg a0, a1

  # Zero acc 0
  .word 0x0400005B             # ai.relacc acc0

  # Load A into tile 0
  li   a1, 1
  .word 0x0605A05B             # ai.mvta t0, a1, e0
  li   a1, 2
  .word 0x0615A05B             # e1
  li   a1, 3
  .word 0x0685A05B             # e8
  li   a1, 4
  .word 0x0695A05B             # e9

  # Load B into tile 1
  li   a1, 5
  .word 0x0605A0DB             # ai.mvta t1, a1, e0
  li   a1, 6
  .word 0x0615A0DB
  li   a1, 7
  .word 0x0685A0DB
  li   a1, 8
  .word 0x0695A0DB

  # mma.s8 acc0, tile0, tile1
  .word 0x0010105B

  # Read C
  .word 0x0400255B             # mvacc a0, acc0, e0 → 19
  li   t0, 19
  bne  a0, t0, fail

  .word 0x0410255B             # e1 → 22
  li   t0, 22
  bne  a0, t0, fail

  .word 0x0480255B             # e8 → 43
  li   t0, 43
  bne  a0, t0, fail

  .word 0x0490255B             # e9 → 50
  li   t0, 50
  bne  a0, t0, fail

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j 1b

fail:
  li   a0, 2
  la   t0, tohost
  sw   a0, 0(t0)
2: j 2b

trap_vec:
  csrr t0, mcause
  li   t1, 2
  bne  t0, t1, fail
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
