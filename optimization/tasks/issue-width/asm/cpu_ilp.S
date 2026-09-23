# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# test id: cpu_ilp
# work: 64 payload adds
# configs: alu, issue
#
# Same kernel as the coherence task's control. A soak writes mark_cycles.
# This task folder has no series.json until that soak exists.

  .option norvc
  .section .data
  .globl mark_cycles
mark_cycles:
  .dword 0

  .section .text
  .globl main
main:
  csrr s0, mcycle
  li   t0, 0
  li   t1, 1
  li   t2, 64
1:
  add  t0, t0, t1
  addi t2, t2, -1
  bnez t2, 1b
  csrr s1, mcycle
  sub  s1, s1, s0
  la   t3, mark_cycles
  sd   s1, 0(t3)
  li   a0, 64
  bne  t0, a0, fail
  li   a0, 0
  ret
fail:
  li   a0, 1
  ret
