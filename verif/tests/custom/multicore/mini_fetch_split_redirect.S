# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT

#ifndef FETCH_BYTES
#define FETCH_BYTES 8
#endif

.section .text.init
.globl _start
.option norvc
.option norelax
_start:
  csrr t6, mhartid
  bnez t6, park
  addi s0, x0, 0
  addi t0, x0, 1
  beq t0, t0, split_target
  jal x0, fail
  .balign FETCH_BYTES
  .rept (FETCH_BYTES - 2) / 2
  .2byte 0x0001
  .endr
split_target:
  addi s0, s0, 1
  jal x0, check
  .balign FETCH_BYTES
check:
  addi t0, x0, 1
  bne s0, t0, fail
  addi a0, x0, 1
  jal x0, write_tohost
fail:
  addi a0, x0, 3
write_tohost:
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
