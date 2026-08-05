# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# U10ᵇ vector soft-skip (CI-safe on every package).
# Always exits 0: no vector opcodes. Use v_memcpy_lmul.S for functional Ara smoke.
# See agents/guides/AGENTS-vector.md.

  .globl main
main:
  csrr t0, misa
  li   t1, (1 << 21)          # V
  and  t2, t0, t1
  # t2 != 0 ⇒ hardware advertises V; still soft-pass here (no ops issued)
  li   a0, 0
  jal  exit
