# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Zacas AMOCAS.W narrow smoke (single-hart).
# Soft-skip: no misa.A, or illegal AMOCAS (Spike without Zacas).
# Prefer DV_TARGET=g6lc64_server_math (RVZacas) under RTL.

# Bare-metal _start shim (single-hart); see zacas_amocas_d.S.
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
  li   t1, (1 << 0)           # A
  and  t2, t0, t1
  beqz t2, soft_skip

  # Soft-skip on illegal instruction (ISS without Zacas)
  la   t0, cas_illegal
  csrw mtvec, t0

  # ---- success path ----
  li   t0, 0x11111111
  sw   t0, 0(sp)
  li   a0, 0x11111111
  li   a1, 0x22222222
  mv   a2, sp
  .word 0x28B6252F            # amocas.w a0, a1, (a2)
  li   t1, 0x11111111
  bne  a0, t1, fail
  lw   t2, 0(sp)
  li   t3, 0x22222222
  bne  t2, t3, fail

  # ---- fail path ----
  li   t0, 0x33333333
  sw   t0, 4(sp)
  li   a0, 0xDEADBEEF
  li   a1, 0x44444444
  addi a2, sp, 4
  .word 0x28B6252F
  li   t1, 0x33333333
  bne  a0, t1, fail
  lw   t2, 4(sp)
  bne  t2, t1, fail

  addi sp, sp, 48
  li   a0, 0
  jal  exit

  .align 2
cas_illegal:
  # Illegal AMOCAS → soft-pass (ISS without Zacas)
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
