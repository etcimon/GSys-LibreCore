# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT

.section .text.init
.globl _start
.option norvc
.option norelax
_start:
  csrr t6, mhartid
  bnez t6, park
  addi a0, x0, 3
  addi s1, x0, 4
  .balign 8
outer:
  addi s1, s1, -1
  addi t0, x0, 2
inner:
  addi t0, t0, -1
  addi x0, x0, 0
  .balign 8
  bnez t0, inner
  bnez s1, outer
  addi a0, x0, 1
  la t0, tohost
  sw a0, 0(t0)
1: jal x0, 1b
park:
  wfi
  jal x0, park

.section .tohost,"aw",@progbits
.balign 64
.globl tohost
tohost: .dword 0
.globl fromhost
fromhost: .dword 0
