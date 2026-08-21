# SPDX-License-Identifier: MIT
# smoke2 with rs1=a3 instead of a4
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
  li   a1, 0x2222222222222222
  li   a2, 0xAAAAAAAAAAAAAAAA
  li   a3, 0  # will set to sp
  mv   a3, sp
  # amocas.q a0, a2, (a3): rs2=a2 rs1=a3 rd=a0 funct3=100
  # 00101 00 01100 01101 100 01010 0101111 = 0x28C6C52F
  .word 0x28C6C52F

  li   t0, 0x3333333333333333
  li   t1, 0x4444444444444444
  sd   t0, 16(sp)
  sd   t1, 24(sp)
  li   a0, 0xDEADBEEFCAFEBABE
  li   a1, 0x0123456789ABCDEF
  li   a2, 0x5555555555555555
  addi a3, sp, 16
  .word 0x28C6C52F

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
