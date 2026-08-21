# SPDX-License-Identifier: MIT
# smoke2 but D-style regs: amocas.q a0, a1, (a2)
  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap_soft
  csrw mtvec, t0
  andi sp, sp, -16
  addi sp, sp, 64

  li   t0, 0x1111111111111111
  li   t1, 0x2222222222222222
  sd   t0, 0(sp)
  sd   t1, 8(sp)
  li   a0, 0x1111111111111111
  li   a1, 0xAAAAAAAAAAAAAAAA
  mv   a2, sp
  .word 0x28B6452F

  li   t0, 0x3333333333333333
  li   t1, 0x4444444444444444
  sd   t0, 16(sp)
  sd   t1, 24(sp)
  li   a0, 0xDEADBEEFCAFEBABE
  li   a1, 0x5555555555555555
  addi a2, sp, 16
  .word 0x28B6452F

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j 1b
trap_soft:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
2: j 2b
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
