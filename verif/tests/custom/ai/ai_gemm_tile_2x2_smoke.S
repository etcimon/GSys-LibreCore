# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# F12 software tiling: 32x32x32 INT8 as 2x2 output tiles of 16x16x32.
# A/B stay in the full 32-wide matrices (lda=ldb=32, B k-major). C is packed ldc=n=16
# per tile — the sequencer has no ldc field, so the host owns scatter.
# All-ones → each packed C element = 32.
# Tickets 31..34; claim CPL between tiles (engine is single-outstanding).

  .equ AI_BASE,     0x40000000
  .equ AI_CTL,      0x100
  .equ AI_DOORBELL, 0x108
  .equ AI_DONE,     0x10C
  .equ AI_TICKET,   0x110
  .equ AI_DSTATUS,  0x114
  .equ AI_REG0,     0x120
  .equ AI_DESC,     0x140
  .equ ST_OK,       0
  .equ TILE,        16
  .equ DIM,         32
  .equ TICKET0,     31

  .section .text.init
  .globl _start
_start:
  # g6lc64_ai has two cores and both start here: only hart 0 drives the island;
  # any other hart parks, otherwise every MMIO doorbell/claim is issued twice.
  csrr t0, mhartid
  beqz t0, 1f
2: wfi
  j    2b
1:
  li   sp, 0x80008000
  la   t0, trap_vec
  csrw mtvec, t0
  andi sp, sp, -16

  li   s0, AI_BASE
  li   t0, 1
  sw   t0, AI_CTL(s0)

  li   t0, 0x80000000
  sw   t0, AI_REG0+0x0(s0)
  sw   zero, AI_REG0+0x4(s0)
  li   t0, 0x80100000
  sw   t0, AI_REG0+0x8(s0)
  sw   zero, AI_REG0+0xC(s0)
  li   t0, 0x3
  sw   t0, AI_REG0+0x10(s0)

  la   t0, mat_c
  li   t1, 1024
0:
  sw   zero, 0(t0)
  addi t0, t0, 4
  addi t1, t1, -1
  bnez t1, 0b

  li   s1, 0                    # mi
mi_loop:
  li   s2, 0                    # nj
nj_loop:
  # ptr_a = mat_a + mi * TILE * DIM  (16*32 = 512)
  la   t0, mat_a
  slli t1, s1, 9
  add  t3, t0, t1
  # ptr_b = mat_b + nj * TILE * DIM (512): B is k-major (AI-X9), so an output
  # column tile is TILE consecutive rows of DIM k-elements each.
  la   t0, mat_b
  slli t1, s2, 9
  add  t4, t0, t1
  # ptr_c = mat_c + (mi*2+nj) * TILE * TILE * 4  (1024)
  la   t0, mat_c
  slli t1, s1, 1
  add  t1, t1, s2
  slli t1, t1, 10
  add  t5, t0, t1

  li   t0, (1 << 16) | 2
  sw   t0, AI_DESC+0x0(s0)
  sw   zero, AI_DESC+0x4(s0)
  li   t0, TILE
  sw   t0, AI_DESC+0x8(s0)      # m
  sw   t0, AI_DESC+0xC(s0)      # n
  li   t0, DIM
  sw   t0, AI_DESC+0x10(s0)     # k
  li   t0, 0x00200020           # ldb=32, lda=32
  sw   t0, AI_DESC+0x14(s0)
  sw   t3, AI_DESC+0x18(s0)
  srli t1, t3, 32
  sw   t1, AI_DESC+0x1C(s0)
  sw   t4, AI_DESC+0x20(s0)
  srli t1, t4, 32
  sw   t1, AI_DESC+0x24(s0)
  sw   t5, AI_DESC+0x28(s0)
  srli t1, t5, 32
  sw   t1, AI_DESC+0x2C(s0)
  sw   zero, AI_DESC+0x30(s0)
  sw   zero, AI_DESC+0x34(s0)
  sw   zero, AI_DESC+0x38(s0)
  sw   zero, AI_DESC+0x3C(s0)

  fence
  lw   zero, AI_CTL(s0)

  slli t1, s1, 1
  add  t1, t1, s2
  addi t1, t1, TICKET0
  slli t0, t1, 8
  sw   t0, AI_DOORBELL(s0)

  li   t2, 5000000
1:
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  bnez t0, 2f
  addi t2, t2, -1
  bnez t2, 1b
  j    fail1
2:
  lw   t0, AI_DSTATUS(s0)
  slli t0, t0, 48
  srli t0, t0, 48
  li   t1, ST_OK
  bne  t0, t1, fail2
  lw   t0, AI_TICKET(s0)
  slli t1, s1, 1
  add  t1, t1, s2
  addi t1, t1, TICKET0
  bne  t0, t1, fail3

  li   t0, 1
  sw   t0, AI_DONE(s0)
  fence
  # One claim must empty the FIFO: a second completion for the same job
  # (or an ignored pop) shows up here as a still-set sticky.
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  beqz t0, 3f
  lw   t0, AI_TICKET(s0)
  slli a0, t0, 8
  ori  a0, a0, 13
  j    fail_exit
3:

  addi s2, s2, 1
  li   t0, 2
  blt  s2, t0, nj_loop
  addi s1, s1, 1
  blt  s1, t0, mi_loop

  la   t0, mat_c
  li   t1, 1024
  li   t3, 32
8:
  lw   t2, 0(t0)
  bne  t2, t3, fail4
  addi t0, t0, 4
  addi t1, t1, -1
  bnez t1, 8b

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
4: j 4b

fail1:
  li   a0, 3
  j    fail_exit
fail2:
  li   a0, 5
  j    fail_exit
fail3:
  # Completion identity: a0 = (expected << 16) | (observed << 8) | 7 (low bytes).
  andi t0, t0, 0xFF
  slli a0, t0, 8
  andi t1, t1, 0xFF
  slli t1, t1, 16
  or   a0, a0, t1
  ori  a0, a0, 7
  j    fail_exit
fail4:
  li   a0, 9
  j    fail_exit
fail_exit:
  la   t0, tohost
  sw   a0, 0(t0)
5: j 5b

trap_vec:
  li   a0, 11
  la   t0, tohost
  sw   a0, 0(t0)
6: j 6b

  .section .data
  .align 3
  .globl mat_a
mat_a:
  .rept 1024
  .byte 1
  .endr
  .align 3
  .globl mat_b
mat_b:
  .rept 1024
  .byte 1
  .endr
  .align 3
  .globl mat_c
mat_c:
  .rept 1024
  .word 0
  .endr

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost:
  .dword 0
  .align 6
  .globl fromhost
fromhost:
  .dword 0
