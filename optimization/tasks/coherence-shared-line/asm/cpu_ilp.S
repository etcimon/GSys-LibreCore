# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# test id: cpu_ilp
# work: 64 payload adds
# configs: alu, issue
#
# A soak reads the dword at mark_cycles. That is the mcycle delta around the
# 64 adds, not an FO4 estimate. A wider issue path should lower this count.
# This test is the control next to a coherence task: an RTL change that only
# touches the coherence path should leave this count alone.

  .option norvc
  .section .data
  .globl mark_cycles
mark_cycles:
  .dword 0

  .section .text
  .globl main
main:
  li   a3, 1
  csrr s0, mcycle
  .rept 8
  add  t0, s0, a3
  add  t1, s0, a3
  add  t2, s0, a3
  add  t3, s0, a3
  add  t4, s0, a3
  add  t5, s0, a3
  add  t6, s0, a3
  add  a1, s0, a3
  .endr
  csrr s1, mcycle
  sub  s1, s1, s0
  la   a4, mark_cycles
  sd   s1, 0(a4)
  add  a0, s0, a3
  bne  t0, a0, fail
  bne  t1, a0, fail
  bne  t2, a0, fail
  bne  t3, a0, fail
  bne  t4, a0, fail
  bne  t5, a0, fail
  bne  t6, a0, fail
  bne  a1, a0, fail
  li   a0, 0
  ret
fail:
  li   a0, 1
  ret
