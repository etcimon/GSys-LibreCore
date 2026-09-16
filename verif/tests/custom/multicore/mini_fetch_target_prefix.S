# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT

.section .text.init
.globl _start
.option norvc
.option norelax
_start:
  addi a0, x0, 1
  addi t2, x0, 4
  .balign 8
loop:
  addi t1, x0, 0
  jal x0, target
  addi a0, x0, 3
target:
  addi t2, t2, -1
  bnez t2, loop
  la t0, tohost
  sw a0, 0(t0)
1: jal x0, 1b
  addi x0, x0, 0

.section .tohost,"aw",@progbits
.balign 64
.globl tohost
tohost: .dword 0
.globl fromhost
fromhost: .dword 0
