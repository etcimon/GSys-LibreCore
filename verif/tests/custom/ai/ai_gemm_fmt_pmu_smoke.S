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
# Passes only when the island's per-job cycle counter AI_PMU_CY (0x188) for the INT4 job
# is strictly less than for the INT8 job.
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

  la   t0, mat_a8
  la   t1, mat_b8
  li   t2, 0                   # flags: numfmt = AI_FMT_INT (0)
  li   t3, 51                  # ticket
  jal  ra, submit

  li   a0, 3
  jal  ra, check_status
  li   a0, 7
  li   t3, 51
  jal  ra, check_ticket
  li   a0, 9
  li   t6, K
  jal  ra, check_c

  lw   s1, AI_PMU_CY(s0)       # island cycles for the INT8 job
  li   t0, 1
  sw   t0, AI_DONE(s0)         # claim, pop CPL FIFO head

  la   t0, mat_a4
  la   t1, mat_b4
  li   t2, FLAG_NUMFMT_INT4
  li   t3, 52
  jal  ra, submit

  li   a0, 11
  jal  ra, check_status
  li   a0, 13
  li   t3, 52
  jal  ra, check_ticket
  li   a0, 15
  li   t6, K
  jal  ra, check_c

  lw   s2, AI_PMU_CY(s0)       # island cycles for the INT4 job
  li   t0, 1
  sw   t0, AI_DONE(s0)         # claim

  li   a0, 17
  beqz s1, fail
  beqz s2, fail
  bgeu s2, s1, fail            # INT4 must be strictly faster

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j 1b

fail:
  la   t0, tohost
  sw   a0, 0(t0)
2: j 2b

trap_vec:
  li   a0, 5
  la   t0, tohost
  sw   a0, 0(t0)
3: j 3b

# submit: t0=ptr_a, t1=ptr_b, t2=flags, t3=ticket. Clobbers t4/t5/t6.
submit:
  li   t4, (1 << 16) | 2       # op=OP_GEMM, version=2
  sw   t4, AI_DESC+0x0(s0)
  sw   t2, AI_DESC+0x4(s0)
  li   t4, M
  sw   t4, AI_DESC+0x8(s0)
  sw   t4, AI_DESC+0xC(s0)     # N = M = 32
  li   t4, K
  sw   t4, AI_DESC+0x10(s0)
  li   t4, (K << 16) | K       # ldb=K, lda=K (ELEMENTS)
  sw   t4, AI_DESC+0x14(s0)
  sw   t0, AI_DESC+0x18(s0)
  srli t4, t0, 32
  sw   t4, AI_DESC+0x1C(s0)
  sw   t1, AI_DESC+0x20(s0)
  srli t4, t1, 32
  sw   t4, AI_DESC+0x24(s0)
  la   t4, mat_c
  sw   t4, AI_DESC+0x28(s0)
  srli t5, t4, 32
  sw   t5, AI_DESC+0x2C(s0)
  sw   zero, AI_DESC+0x30(s0)
  sw   zero, AI_DESC+0x34(s0)
  sw   zero, AI_DESC+0x38(s0)
  sw   zero, AI_DESC+0x3C(s0)

  la   t4, mat_c
  li   t5, MN
1:
  sw   zero, 0(t4)
  addi t4, t4, 4
  addi t5, t5, -1
  bnez t5, 1b

  fence
  lw   zero, AI_CTL(s0)
  slli t4, t3, 8
  sw   t4, AI_DOORBELL(s0)

  li   t4, 10000000
2:
  lw   t5, AI_DONE(s0)
  andi t5, t5, 1
  bnez t5, 3f
  addi t4, t4, -1
  bnez t4, 2b
  li   a0, 31
  j    fail
3:
  fence
  ret

check_status:
  lw   t4, AI_DSTATUS(s0)
  slli t4, t4, 48
  srli t4, t4, 48
  li   t5, ST_OK
  bne  t4, t5, fail
  ret

check_ticket:
  lw   t4, AI_TICKET(s0)
  bne  t4, t3, fail
  ret

check_c:
  la   t4, mat_c
  li   t5, MN
1:
  lw   a1, 0(t4)
  bne  a1, t6, fail
  addi t4, t4, 4
  addi t5, t5, -1
  bnez t5, 1b
  ret

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
