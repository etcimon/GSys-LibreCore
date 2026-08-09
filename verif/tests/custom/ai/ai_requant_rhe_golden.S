# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Xg6lcai requant round-half-to-even golden (seam B).
# Pack in rs2 GPR: [15:0]=s16 scale, [23:16]=s8 zp, [27:24]=shift.
# y = clamp_s8( RHE(acc * scale, shift) + zp )
#
# Case A: acc=7, scale=1, shift=1 → RHE(3.5)=4
# Case B: acc=5, scale=1, shift=1 → RHE(2.5)=2
# Case C: relu(-3)=0
# Observe tiles via 1x1 mma * 1 then mvacc (no tile→GPR on seam B).

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap_vec
  csrw mtvec, t0
  andi sp, sp, -16

  csrr t0, 0x802
  li   t1, ~(0x3 << 6)
  and  t0, t0, t1
  li   t1, (0x1 << 6)
  or   t0, t0, t1
  csrw 0x802, t0

  # setcfg: M=N=K log2 = 0 → 1×1×1
  li   a1, 0x00000000
  .word 0x0005855B

  # ---- A: 7 → 4 ----
  .word 0x0400005B             # relacc 0
  li   a1, 7
  .word 0x0605A05B             # mvta t0 = 7
  li   a1, 1
  .word 0x0605A0DB             # mvta t1 = 1
  .word 0x0010105B             # mma acc0,t0,t1 → 7
  li   a1, 0x01000001          # scale=1, zp=0, shift=1
  .word 0x02B0415B             # requant.t t2, acc0, a1
  .word 0x040000DB             # relacc 1
  .word 0x001110DB             # mma acc1,t2,t1 → 4
  .word 0x0400A55B             # mvacc a0, acc1
  li   t0, 4
  bne  a0, t0, fail

  # ---- B: 5 → 2 ----
  .word 0x0400005B
  li   a1, 5
  .word 0x0605A05B
  li   a1, 1
  .word 0x0605A0DB
  .word 0x0010105B
  li   a1, 0x01000001
  .word 0x02B0415B
  .word 0x040000DB
  .word 0x001110DB
  .word 0x0400A55B
  li   t0, 2
  bne  a0, t0, fail

  # ---- C: relu(-3) → 0 ----
  li   a1, 0xFD                # -3
  .word 0x0605A15B             # mvta t2 = -3
  .word 0x040141DB             # act.relu t3, t2
  .word 0x0400005B             # relacc 0
  li   a1, 1
  .word 0x0605A0DB             # t1 = 1
  .word 0x0011905B             # mma acc0,t3,t1
  .word 0x0400255B             # mvacc a0, acc0
  bnez a0, fail

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
