# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Zacas AMOCAS.D narrow smoke (RV64). Soft-skip without A or on illegal AMOCAS.

# Bare-metal _start shim (single-hart): the original Spike/libc-style body is
# kept verbatim under main; _start parks sibling harts, sets sp/mtvec and
# jumps to main. exit() writes (code<<1)|1 to tohost per crt.S convention.
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, park
  li   sp, 0x80008000
  la   t0, trap_vec
  csrw mtvec, t0
  j    main

  .globl main
main:
  addi sp, sp, -48
  csrr t0, misa
  li   t1, (1 << 0)
  and  t2, t0, t1
  beqz t2, soft_skip

  la   t0, cas_illegal
  csrw mtvec, t0

  li   t0, 0x1111111111111111
  sd   t0, 0(sp)
  li   a0, 0x1111111111111111
  li   a1, 0x2222222222222222
  mv   a2, sp
  .word 0x28B6352F            # amocas.d a0, a1, (a2)
  li   t1, 0x1111111111111111
  bne  a0, t1, fail
  ld   t2, 0(sp)
  li   t3, 0x2222222222222222
  bne  t2, t3, fail

  li   t0, 0xAAAAAAAAAAAAAAAA
  sd   t0, 8(sp)
  li   a0, 0x0
  li   a1, 0xBBBBBBBBBBBBBBBB
  addi a2, sp, 8
  .word 0x28B6352F
  li   t1, 0xAAAAAAAAAAAAAAAA
  bne  a0, t1, fail
  ld   t2, 8(sp)
  bne  t2, t1, fail

  addi sp, sp, 48
  li   a0, 0
  jal  exit

  .align 2
cas_illegal:
  li   a0, 0
  jal  exit

soft_skip:
  addi sp, sp, 48
  li   a0, 0
  jal  exit

fail:
  addi sp, sp, 48
  li   a0, 1
  jal  exit

# --- bare-metal runtime (exit/park/trap_vec/tohost) ---
  .globl exit
exit:
  slli a0, a0, 1
  addi a0, a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
9:  j    9b

trap_vec:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
8:  j    8b

park:
7:  wfi
  j    7b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
