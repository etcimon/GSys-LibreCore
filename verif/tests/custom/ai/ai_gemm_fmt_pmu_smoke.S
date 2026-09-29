# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# INT4-vs-INT8 island-cycle comparison, 32x32x32, self-contained oracle.
#
# Why 32x32x32: the 64x64 twin would need a 3M-cycle sim timeout, which runs for
# an hour. This version is the same structure at 1/8 the size and completes in
# seconds, while still being large enough that the load share is observable.
#
# Same invariants as the original design: byte-identical descriptors except
# flags.numfmt, same all-ones operands, same golden C = k. The test passes only
# when the island's per-job cycle counter AI_PMU_CY (0x188) for the INT4 job
# is strictly less than for the INT8 job.
#
# This version is fully in-line (no jal/ret) because the current g6lc64_ai
# Verilator harness mis-handles the jal/ret pattern in these AI tests: the
# identical code, fully in-line, completes in 20,178 cycles, while the same
# logic wrapped in a 'submit' function hangs.  The in-line form is the
# regression gate until the function-call interaction is root-caused.
#
# Exit codes: 1=pass, 3=status8, 5=trap, 7=ticket8, 9=C8 wrong, 11=status4,
#             13=ticket4, 15=C4 wrong, 17=INT4 not faster than INT8, 31=timeout.

  .equ M, 32
  .equ N, 32
  .equ K, 32
  .equ MN, (M * N)                # elements in C
  .equ A8_SIZE, (M * K)            # bytes for INT8 A
  .equ A4_SIZE, (M * (K / 2))      # bytes for INT4 A (K even)
  .equ B8_SIZE, (N * K)
  .equ B4_SIZE, (N * (K / 2))

  .equ AI_BASE,     0x40000000
  .equ AI_CTL,      0x100
  .equ AI_DOORBELL, 0x108
  .equ AI_DONE,     0x10C
  .equ AI_TICKET,   0x110
  .equ AI_DSTATUS,  0x114
  .equ AI_REG0,     0x120
  .equ AI_DESC,     0x140
  .equ AI_PMU_CY,   0x188
  .equ ST_OK,       0
  .equ FLAG_NUMFMT_INT4, (1 << 20)

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

# ===== Job 1: INT8, ticket 51 =====
  la   t0, mat_c
  li   t1, MN
1:
  sw   zero, 0(t0)
  addi t0, t0, 4
  addi t1, t1, -1
  bnez t1, 1b

  li   t0, (1 << 16) | 2
  sw   t0, AI_DESC+0x0(s0)
  sw   zero, AI_DESC+0x4(s0)
  li   t0, M
  sw   t0, AI_DESC+0x8(s0)
  sw   t0, AI_DESC+0xC(s0)
  li   t0, K
  sw   t0, AI_DESC+0x10(s0)
  li   t0, (K << 16) | K
  sw   t0, AI_DESC+0x14(s0)
  la   t0, mat_a8
  sw   t0, AI_DESC+0x18(s0)
  srli t1, t0, 32
  sw   t1, AI_DESC+0x1C(s0)
  la   t0, mat_b8
  sw   t0, AI_DESC+0x20(s0)
  srli t1, t0, 32
  sw   t1, AI_DESC+0x24(s0)
  la   t0, mat_c
  sw   t0, AI_DESC+0x28(s0)
  srli t1, t0, 32
  sw   t1, AI_DESC+0x2C(s0)
  sw   zero, AI_DESC+0x30(s0)
  sw   zero, AI_DESC+0x34(s0)
  sw   zero, AI_DESC+0x38(s0)
  sw   zero, AI_DESC+0x3C(s0)

  fence
  lw   zero, AI_CTL(s0)
  li   t0, (51 << 8)
  sw   t0, AI_DOORBELL(s0)

  li   t2, 10000000
2:
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  bnez t0, 3f
  addi t2, t2, -1
  bnez t2, 2b
  li   a0, 31
  j    fail
3:
  lw   t0, AI_DSTATUS(s0)
  slli t0, t0, 48
  srli t0, t0, 48
  li   t1, ST_OK
  bne  t0, t1, fail3
  lw   t0, AI_TICKET(s0)
  li   t1, 51
  bne  t0, t1, fail7

  # check C8 = K for all MN elements
  la   t0, mat_c
  li   t1, MN
4:
  lw   t2, 0(t0)
  li   t3, K
  bne  t2, t3, fail9
  addi t0, t0, 4
  addi t1, t1, -1
  bnez t1, 4b

  # record PMU and claim
  lw   s1, AI_PMU_CY(s0)
  li   t0, 1
  sw   t0, AI_DONE(s0)

# ===== Job 2: INT4, ticket 52 =====
  la   t0, mat_c
  li   t1, MN
5:
  sw   zero, 0(t0)
  addi t0, t0, 4
  addi t1, t1, -1
  bnez t1, 5b

  li   t0, (1 << 16) | 2
  sw   t0, AI_DESC+0x0(s0)
  li   t0, FLAG_NUMFMT_INT4
  sw   t0, AI_DESC+0x4(s0)
  li   t0, M
  sw   t0, AI_DESC+0x8(s0)
  sw   t0, AI_DESC+0xC(s0)
  li   t0, K
  sw   t0, AI_DESC+0x10(s0)
  li   t0, (K << 16) | K
  sw   t0, AI_DESC+0x14(s0)
  la   t0, mat_a4
  sw   t0, AI_DESC+0x18(s0)
  srli t1, t0, 32
  sw   t1, AI_DESC+0x1C(s0)
  la   t0, mat_b4
  sw   t0, AI_DESC+0x20(s0)
  srli t1, t0, 32
  sw   t1, AI_DESC+0x24(s0)
  la   t0, mat_c
  sw   t0, AI_DESC+0x28(s0)
  srli t1, t0, 32
  sw   t1, AI_DESC+0x2C(s0)
  sw   zero, AI_DESC+0x30(s0)
  sw   zero, AI_DESC+0x34(s0)
  sw   zero, AI_DESC+0x38(s0)
  sw   zero, AI_DESC+0x3C(s0)

  fence
  lw   zero, AI_CTL(s0)
  li   t0, (52 << 8)
  sw   t0, AI_DOORBELL(s0)

  li   t2, 10000000
6:
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  bnez t0, 7f
  addi t2, t2, -1
  bnez t2, 6b
  li   a0, 31
  j    fail
7:
  lw   t0, AI_DSTATUS(s0)
  slli t0, t0, 48
  srli t0, t0, 48
  li   t1, ST_OK
  bne  t0, t1, fail11
  lw   t0, AI_TICKET(s0)
  li   t1, 52
  bne  t0, t1, fail13

  # check C4 = K for all MN elements
  la   t0, mat_c
  li   t1, MN
8:
  lw   t2, 0(t0)
  li   t3, K
  bne  t2, t3, fail15
  addi t0, t0, 4
  addi t1, t1, -1
  bnez t1, 8b

  # record PMU and claim
  lw   s2, AI_PMU_CY(s0)
  li   t0, 1
  sw   t0, AI_DONE(s0)

  li   a0, 17
  beqz s1, fail
  beqz s2, fail
  bgeu s2, s1, fail            # INT4 must be strictly faster

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
9: j 9b

fail:
  la   t0, tohost
  sw   a0, 0(t0)
10: j 10b

trap_vec:
  li   a0, 5
  la   t0, tohost
  sw   a0, 0(t0)
11: j 11b

fail3:
  li   a0, 3
  j    fail

fail7:
  li   a0, 7
  j    fail

fail9:
  li   a0, 9
  j    fail

fail11:
  li   a0, 11
  j    fail

fail13:
  li   a0, 13
  j    fail

fail15:
  li   a0, 15
  j    fail

  .section .data
  .align 3
  .globl mat_a8
mat_a8:
  .rept A8_SIZE
  .byte 1
  .endr
  .align 3
  .globl mat_b8
mat_b8:
  .rept B8_SIZE
  .byte 1
  .endr
  .align 3
  .globl mat_a4
mat_a4:
  .rept A4_SIZE
  .byte 0x11
  .endr
  .align 3
  .globl mat_b4
mat_b4:
  .rept B4_SIZE
  .byte 0x11
  .endr
  .align 3
  .globl mat_c
mat_c:
  .rept MN
  .word 0
  .endr

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
