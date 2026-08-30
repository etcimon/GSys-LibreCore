# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S2 hold printf shape: la a0, lock (auipc+addi) then amoadd.w acquire.
# Hang pc 0xa990 is the addi of la console_out_lock. Isolates DI la vs
# OpenSBI occupancy. tohost 1 PASS; 25 trap.

  .option rvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, hart1
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  # Same la-then-use shape as sbi_printf @a98c (auipc+addi a0, then op).
  la   a0, lock
  # Ticket lock acquire like OpenSBI spin_lock (amoadd.w.aqrl)
  li   a5, 0x10000
  amoadd.w.aqrl a3, a5, (a0)
  srli a2, a3, 16
  li   t0, 0xffff
  and  a2, a2, t0
  and  a1, a3, t0
  beq  a2, a1, got
1:
  lw   a3, 0(a0)
  fence r, rw
  srli a2, a3, 16
  and  a2, a2, t0
  and  a1, a3, t0
  bne  a2, a1, 1b
got:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

hart1:
  wfi
  j    hart1

trap:
  li   a0, 25
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0

  .section .data
  .align 6
lock: .dword 0
