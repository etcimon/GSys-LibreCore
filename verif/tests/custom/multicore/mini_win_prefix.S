# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S4: OpenSBI 12970 +16 / ret sits in the same 8B window as next_tag@12974.
# same_win bp_pend accepts the sequential HIT of that window after jal to
# 12974 and must not issue the prefix (L2 live[] pc>=tgt).
# tohost 1 PASS; 3 sp clobber; 5 a0 not 1; 25 trap.
#

  .option rvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, hart1
  li   sp, 0x80008000
  mv   s0, sp
  la   t0, trap
  csrw mtvec, t0

  li   s11, 32
loop:
  jal  offset_tail
  jal  tgt
  bne  sp, s0, fail3
  li   t0, 1
  bne  a0, t0, fail5
  addi s11, s11, -1
  bnez s11, loop

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

# ret at +6 of an 8B window so sequential next is prefix+tgt.
  .align 3
offset_tail:
  c.nop
  c.nop
  c.nop
  ret

  .align 3
prefix:
  c.addi16sp sp, 16
  ret
tgt:
  li   a0, 1
  ret

hart1:
  wfi
  j    hart1

fail3:
  li   a0, 3
  j    fail_exit
fail5:
  li   a0, 5
fail_exit:
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
