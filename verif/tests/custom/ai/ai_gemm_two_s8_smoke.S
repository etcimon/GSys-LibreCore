# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Two INT8 32x32 jobs with AI_DONE claim. Diagnostic for ai_gemm_fmt_pmu_smoke.
#
# Fully in-line: the g6lc64_ai Verilator harness currently fails to complete
# any job that is wrapped in a function or even a shared jump block (jal/ret
# or j to a common body).  The identical logic, fully unrolled in-line, passes.

  .equ M, 32
  .equ N, 32
  .equ K, 32
  .equ MN, (M * N)
  .equ A8_SIZE, (M * K)
  .equ B8_SIZE, (N * K)

  .equ AI_BASE,     0x40000000
  .equ AI_CTL,      0x100
  .equ AI_DOORBELL, 0x108
  .equ AI_DONE,     0x10C
  .equ AI_TICKET,   0x110
  .equ AI_DSTATUS,  0x114
  .equ AI_REG0,     0x120
  .equ AI_DESC,     0x140
  .equ ST_OK,       0

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

  # region 0: 0x80000000-0x80100000 r/w
  li   t0, 0x80000000
  sw   t0, AI_REG0+0x0(s0)
  sw   zero, AI_REG0+0x4(s0)
  li   t0, 0x80100000
  sw   t0, AI_REG0+0x8(s0)
  sw   zero, AI_REG0+0xC(s0)
  li   t0, 0x3
  sw   t0, AI_REG0+0x10(s0)

  # ===== First INT8 job, ticket 51 =====
  la   t0, mat_c
  li   t1, MN
1:
  sw   zero, 0(t0)
  addi t0, t0, 4
  addi t1, t1, -1
  bnez t1, 1b

  sw   zero, AI_DESC+0x4(s0)
  li   t0, (1 << 16) | 2
  sw   t0, AI_DESC+0x0(s0)
  li   t0, M
  sw   t0, AI_DESC+0x8(s0)
  sw   t0, AI_DESC+0xC(s0)
  sw   t0, AI_DESC+0x10(s0)
  li   t0, (K << 16) | K
  sw   t0, AI_DESC+0x14(s0)
  la   t0, mat_a
  sw   t0, AI_DESC+0x18(s0)
  srli t1, t0, 32
  sw   t1, AI_DESC+0x1C(s0)
  la   t0, mat_b
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
  bne  t0, t1, fail_status
  lw   t0, AI_TICKET(s0)
  li   t1, 51
  bne  t0, t1, fail_ticket

  # check C = K
  la   t0, mat_c
  li   t1, MN
4:
  lw   t2, 0(t0)
  li   t3, K
  bne  t2, t3, fail_c
  addi t0, t0, 4
  addi t1, t1, -1
  bnez t1, 4b

  # claim first completion
  li   t0, 1
  sw   t0, AI_DONE(s0)

  # ===== Second INT8 job, ticket 52 =====
  la   t0, mat_c
  li   t1, MN
5:
  sw   zero, 0(t0)
  addi t0, t0, 4
  addi t1, t1, -1
  bnez t1, 5b

  sw   zero, AI_DESC+0x4(s0)
  li   t0, (1 << 16) | 2
  sw   t0, AI_DESC+0x0(s0)
  li   t0, M
  sw   t0, AI_DESC+0x8(s0)
  sw   t0, AI_DESC+0xC(s0)
  sw   t0, AI_DESC+0x10(s0)
  li   t0, (K << 16) | K
  sw   t0, AI_DESC+0x14(s0)
  la   t0, mat_a
  sw   t0, AI_DESC+0x18(s0)
  srli t1, t0, 32
  sw   t1, AI_DESC+0x1C(s0)
  la   t0, mat_b
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
  bne  t0, t1, fail_status
  lw   t0, AI_TICKET(s0)
  li   t1, 52
  bne  t0, t1, fail_ticket

  # check C = K
  la   t0, mat_c
  li   t1, MN
8:
  lw   t2, 0(t0)
  li   t3, K
  bne  t2, t3, fail_c
  addi t0, t0, 4
  addi t1, t1, -1
  bnez t1, 8b

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

fail_status:
  li   a0, 3
  j    fail

fail_ticket:
  li   a0, 7
  j    fail

fail_c:
  li   a0, 9
  j    fail

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
