# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# AMOCAS.Q with odd rd (register-pair base) must illegal-trap.
# Encoding: amocas.q a1, a2, (a4) — a1 is odd → illegal.

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap_ok
  csrw mtvec, t0

  li   a1, 0
  li   a2, 0
  mv   a4, sp
  # amocas.q a1, a2, (a4)  rd=a1 odd
  # funct5=00101 aqrl=00 rs2=a2 rs1=a4 funct3=100 rd=a1 opcode=AMO
  .word 0x28C745AF

  j    fail

trap_ok:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

fail:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
