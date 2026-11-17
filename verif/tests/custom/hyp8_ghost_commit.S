# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# rfix131a-09: nothing behind a mispredicted branch retires.
#
# A branch that resolves late (its condition hangs off a divide / multiply
# chain) is trained not-taken and then taken. The instruction behind it has
# long since executed when the branch resolves; the branch is committable in
# its resolve cycle, so that instruction sits on the second commit port in
# the same cycle the mispredict cancels it. It must be dropped, not retired:
#
#   A. an integer instruction behind the branch: minstret between two reads
#      is exactly the number of architecturally executed instructions
#      (r131 / rfix131a-08 models: +1 per probe round);
#   B. a floating-point instruction behind the branch, inexact only on the
#      probe rounds: fflags stays clear (a retired wrong-path FP instruction
#      accrues its flags).
#
# tohost: 1 pass; 3: minstret delta is wrong (the delta is left in a6);
# 5: fflags is not clear (the flags are left in a6); 7: the fall-through
# count is wrong; ((16 + mcause) << 1) | 1: an unexpected trap.
.option norvc
.equ TRAIN, 48
.equ ROUNDS, 2 * (TRAIN + 1)
.equ TAKEN, 2
# instructions retired between the two minstret reads: the first read
# itself, 23 per not-taken round, 21 per taken round
.equ EXPECT_A, 1 + (ROUNDS - TAKEN) * 23 + TAKEN * 21

.section .text.init
.globl _start
_start:
  la    t0, m_trap
  csrw  mtvec, t0
  li    t0, 0x2000
  csrs  mstatus, t0           # FS = initial: the FPU is on
  csrw  fcsr, x0
  csrw  mcountinhibit, x0

  # ---- A: minstret ------------------------------------------------------
  la    s0, tbl_a
  li    s1, ROUNDS
  li    s7, 0
  li    s6, 0
  li    t1, 1
  csrr  s8, minstret
a_loop:
  ld    a1, 0(s0)             # the take-the-fall-through flag
  mul   a2, a1, t1            # resolve the branch late
  mul   a2, a2, t1
  mul   a2, a2, t1
  mul   a2, a2, t1
  mul   a2, a2, t1
  mul   a2, a2, t1
  mul   a2, a2, t1
  mul   a2, a2, t1
  div   a2, a2, t1
  div   a2, a2, t1
  div   a2, a2, t1
  div   a2, a2, t1
  div   a2, a2, t1
  div   a2, a2, t1
  div   a2, a2, t1
  div   a2, a2, t1
  beqz  a2, a_skip            # trained not-taken; taken on the probe rounds
  addi  s7, s7, 1             # wrong path on the probe rounds
  addi  s6, s6, 3
a_skip:
  addi  s0, s0, 8
  addi  s1, s1, -1
  bnez  s1, a_loop
  csrr  s9, minstret
  sub   a6, s9, s8
  li    t0, EXPECT_A
  bne   a6, t0, fail_instret
  li    t0, ROUNDS - TAKEN
  bne   s7, t0, fail_cnt

  # ---- B: fflags --------------------------------------------------------
  la    s0, tbl_b
  li    s1, ROUNDS
  la    t2, one
  fld   f0, 0(t2)
  csrw  fflags, x0
b_loop:
  ld    a1, 0(s0)
  fld   f1, 8(s0)             # 1.0, or 2^-60 on the probe rounds
  mul   a2, a1, t1
  mul   a2, a2, t1
  mul   a2, a2, t1
  mul   a2, a2, t1
  mul   a2, a2, t1
  mul   a2, a2, t1
  mul   a2, a2, t1
  mul   a2, a2, t1
  div   a2, a2, t1
  div   a2, a2, t1
  div   a2, a2, t1
  div   a2, a2, t1
  div   a2, a2, t1
  div   a2, a2, t1
  div   a2, a2, t1
  div   a2, a2, t1
  beqz  a2, b_skip
  fadd.d f2, f0, f1           # exact (2.0) when executed; inexact on the wrong path
b_skip:
  addi  s0, s0, 16
  addi  s1, s1, -1
  bnez  s1, b_loop
  csrr  a6, fflags
  bnez  a6, fail_fflags

  li    t0, 1
report:
  la    t1, tohost
  sw    t0, 0(t1)
done:
  j     done
fail_instret:
  li    t0, 3
  j     report
fail_fflags:
  li    t0, 5
  j     report
fail_cnt:
  li    t0, 7
  j     report

.align 4
m_trap:
  csrr  t0, mcause
  addi  t0, t0, 16
  slli  t0, t0, 1
  addi  t0, t0, 1
  j     report

.section .data
.align 6
one:
  .double 1.0
.align 6
tbl_a:
  .rept TRAIN
  .dword 0x12345
  .endr
  .dword 0
  .rept TRAIN
  .dword 0x12345
  .endr
  .dword 0
.align 6
tbl_b:
  .rept TRAIN
  .dword 0x12345
  .double 1.0
  .endr
  .dword 0
  .dword 0x3c30000000000000   # 2^-60: 1.0 + 2^-60 is inexact
  .rept TRAIN
  .dword 0x12345
  .double 1.0
  .endr
  .dword 0
  .dword 0x3c30000000000000

.section .tohost,"aw",@progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
