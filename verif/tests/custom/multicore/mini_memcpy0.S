# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
  .section .text.init
  .globl _start
_start:
  la   sp, _stack_top
  la   a0, buf
  la   a1, buf
  li   a2, 0
  jal  ra, memcpy
  la   a0, buf
  li   a1, 0
  li   a2, 0
  jal  ra, memset
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j 1b

  .align 1
  .globl memcpy
memcpy:
  addi sp, sp, -80
  sd   ra, 72(sp)
  sd   s0, 64(sp)
  addi s0, sp, 80
  sd   a0, -56(s0)
  sd   a1, -64(s0)
  sd   a2, -72(s0)
  ld   a4, -56(s0)
  ld   a5, -64(s0)
  or   a4, a4, a5
  ld   a5, -72(s0)
  or   a5, a5, a4
  andi a5, a5, 7
  bnez a5, .Lbyte
  ld   a5, -64(s0)
  sd   a5, -24(s0)
  ld   a5, -56(s0)
  sd   a5, -32(s0)
  j    .Lword_chk
.Lword_loop:
  ld   a4, -24(s0)
  addi a5, a4, 8
  sd   a5, -24(s0)
  ld   a5, -32(s0)
  addi a3, a5, 8
  sd   a3, -32(s0)
  ld   a4, 0(a4)
  sd   a4, 0(a5)
.Lword_chk:
  ld   a4, -56(s0)
  ld   a5, -72(s0)
  add  a5, a5, a4
  ld   a4, -32(s0)
  bltu a4, a5, .Lword_loop
  j    .Ldone
.Lbyte:
  ld   a5, -64(s0)
  sd   a5, -40(s0)
  ld   a5, -56(s0)
  sd   a5, -48(s0)
  j    .Lbyte_chk
.Lbyte_loop:
  ld   a4, -40(s0)
  addi a5, a4, 1
  sd   a5, -40(s0)
  ld   a5, -48(s0)
  addi a3, a5, 1
  sd   a3, -48(s0)
  lbu  a4, 0(a4)
  sb   a4, 0(a5)
.Lbyte_chk:
  ld   a4, -56(s0)
  ld   a5, -72(s0)
  add  a5, a5, a4
  ld   a4, -48(s0)
  bltu a4, a5, .Lbyte_loop
.Ldone:
  ld   a5, -56(s0)
  mv   a0, a5
  ld   ra, 72(sp)
  ld   s0, 64(sp)
  addi sp, sp, 80
  ret

  .globl memset
memset:
  addi sp, sp, -80
  sd   ra, 72(sp)
  sd   s0, 64(sp)
  addi s0, sp, 80
  sd   a0, -56(s0)
  mv   a5, a1
  sd   a2, -72(s0)
  sw   a5, -60(s0)
  ld   a0, -56(s0)
  ld   ra, 72(sp)
  ld   s0, 64(sp)
  addi sp, sp, 80
  ret

  .section .data
  .align 6
buf: .space 64
  .space 4096
  .globl _stack_top
_stack_top:

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
