# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S4: two jtab lw+jr with no offset_ptr (frame32 P2 twice). If PASS,
# 2nd jr hang needs offset_ptr leftover. If HANG, the jr itself twice.
#

  .option rvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, hart1
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  li   s2, 0x11111111
  li   s3, 0x22222222
  jal  do_jr
  li   t0, 1
  bne  a0, t0, fail9
  jal  do_jr
  li   t0, 3
  bne  a0, t0, fail9
  li   t0, 0x11111111
  bne  s2, t0, fail5
  li   t0, 0x22222222
  bne  s3, t0, fail3
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

do_jr:
  addi sp, sp, -16
  sd   ra, 8(sp)
  lla  a4, jtab
  mv   a5, a0
  # first call a0 unused; use ra slot: s2 pick 1 then 3 via t3 counter
  la   t0, phase
  lw   t1, 0(t0)
  addi t2, t1, 1
  sw   t2, 0(t0)
  slli a5, t1, 2
  add  a5, a5, a4
  lw   a5, 0(a5)
  add  a5, a5, a4
  jr   a5

jr_one:
  li   a0, 1
  ld   ra, 8(sp)
  addi sp, sp, 16
  ret
jr_three:
  li   a0, 3
  ld   ra, 8(sp)
  addi sp, sp, 16
  ret

  .align 2
jtab:
  .word jr_one - jtab
  .word jr_three - jtab

hart1:
  wfi
  j    hart1

fail3:
  li   a0, 3
  j    fail_exit
fail5:
  li   a0, 5
  j    fail_exit
fail9:
  li   a0, 9
fail_exit:
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

trap:
  li   a0, 25
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

  .section .data
  .align 2
phase:
  .word 0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
