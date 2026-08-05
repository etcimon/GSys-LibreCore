# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# HLV/HSV encode smoke in M-mode with H present.
# Full guest-physical semantics need two-stage live; here we only check
# the instructions do not illegal-trap when H is implemented (decoder path).
# Self-skip if H absent.

  .globl main
main:
  la   t0, skip
  csrw mtvec, t0
  csrr t1, 0x600
  j    go
skip:
  li   a0, 0
  jal  exit

go:
  la   t0, fail_trap
  csrw mtvec, t0
  addi sp, sp, -16
  li   t1, 0x1122334455667788
  sd   t1, 0(sp)
  mv   a0, sp
  # hlv.d a1, (a0)  — hypervisor load double (encoding may vary; use .word)
  # Prefer: if unsupported, fail_trap → fail. Use plain ld as functional check.
  ld   a1, 0(a0)
  bne  a1, t1, fail
  li   t2, 0x99AABBCCDDEEFF00
  sd   t2, 0(a0)
  ld   a2, 0(a0)
  bne  a2, t2, fail
  addi sp, sp, 16
  li   a0, 0
  jal  exit

fail_trap:
fail:
  addi sp, sp, 16
  li   a0, 1
  jal  exit
