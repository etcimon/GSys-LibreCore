# SPDX-License-Identifier: MIT
# Same as mini_amocas_d but Q encoding (funct3=100) — with decoder alias should match D
  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  li   t0, 0x1111111111111111
  sd   t0, 0(sp)
  li   a0, 0x1111111111111111
  li   a1, 0x2222222222222222
  mv   a2, sp
  # amocas.q a0, a1, (a2)  — note rs2=a1 like D; encoding funct3=100
  # funct5=00101 aqrl=00 rs2=a1=11 rs1=a2=12 funct3=100 rd=a0 opcode
  # 00101 00 01011 01100 100 01010 0101111 = 0x28B6452F
  .word 0x28B6452F

  li   t1, 0x1111111111111111
  bne  a0, t1, fail
  ld   t2, 0(sp)
  li   t3, 0x2222222222222222
  bne  t2, t3, fail

  li   t0, 0x3333333333333333
  sd   t0, 16(sp)
  li   a0, 0xDEADBEEFCAFEBABE
  li   a1, 0x4444444444444444
  addi a2, sp, 16
  .word 0x28B6452F
  li   t1, 0x3333333333333333
  bne  a0, t1, fail
  ld   t2, 16(sp)
  bne  t2, t1, fail

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j 1b
trap:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
2: j 2b
fail:
  li   a0, 3
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
