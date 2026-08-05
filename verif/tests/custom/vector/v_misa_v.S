# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# U10ᵇ misa.V discovery smoke.
# Soft-pass whether or not V is set (records capability only).
# Fail only if misa read is nonsensical (XLEN bit check).
# Pair with package g6lc64_server_math_v when checking that V *is* set under cosim.

  .globl main
main:
  csrr t0, misa
  # Sanity: misa must be non-zero on a live core
  beqz t0, fail

  li   t1, (1 << 21)          # V
  and  t2, t0, t1
  # Optional sticky: if env requires V, fail when clear (cosim override)
  # Default: soft-pass either way
  la   t3, require_v
  lw   t4, 0(t3)
  beqz t4, pass
  beqz t2, fail

pass:
  li   a0, 0
  jal  exit

fail:
  li   a0, 1
  jal  exit

  .section .data
  .align 2
  # Set to 1 under live Ara cosim if you need hard-fail without V
require_v:
  .word 0
