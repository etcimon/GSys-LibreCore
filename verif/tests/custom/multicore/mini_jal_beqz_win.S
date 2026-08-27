# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S4: next_tag jal@12990 + beqz@12994 in one 8B window. RAS return to the
# beqz must not retire it with stale a0 (offset_ptr never wrote). Callee
# is long so the call window HIT can still be in-flight at ret.
# tohost 1 PASS; 3 beqz not taken; 25 trap.
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

  li   s11, 16
loop:
  li   a0, 0x5a
  .align 3
  jal  callee
  beqz a0, ok
  j    fail3
ok:
  addi s11, s11, -1
  bnez s11, loop

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

callee:
  .rept 48
  c.nop
  .endr
  li   a0, 0
  ret

hart1:
  wfi
  j    hart1

fail3:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

trap:
  li   a0, 25
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
