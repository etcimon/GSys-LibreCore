# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S1 hold bisect: INIT at 0x80040518, one node at ecall_time 0x800405a0.
# All addresses in s-regs before any sd (freelist shape).
#
# tohost: 1 PASS; 5 NULL walk; 7 bad ptr; 25 trap

  .option rvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, hart1
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  li   s0, 0x80040518
  li   s1, 0x800405a0
  mv   t6, s0
  mv   t5, s1
  sd   t6, 0(s0)
  sd   t6, 8(s0)
  sd   t5, 0(s1)
  sd   t5, 8(s1)
  ld   a5, 8(s0)
  sd   t6, 0(s1)
  sd   a5, 8(s1)
  sd   t5, 0(a5)
  sd   t5, 8(s0)

  ld   a5, 0(s0)
  beqz a5, fail5
  beq  a5, s0, fail7
  bne  a5, s1, fail7
  ld   a5, 0(a5)
  beqz a5, fail5
  bne  a5, s0, fail7

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

hart1:
  wfi
  j    hart1

fail5:
  li   a0, 5
  j    fail_exit
fail7:
  li   a0, 7
  j    fail_exit
fail_exit:
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

trap:
  li   a0, 25
  j    fail_exit

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
