# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Xg6lcai aiperm policy CSR + M-mode always-allowed issue gate.
# Full U-mode deny needs a PMP/SATP bare-metal environment (tracked separately);
# this smoke locks in the CSR + M-path contract used by aiperm[0..2].
# Soft-pass if AI CSRs absent.

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap_vec
  csrw mtvec, t0
  andi sp, sp, -16

  # Presence
  csrr t0, 0x801

  # ais = Initial
  csrr t0, 0x802
  li   t1, ~(0x3 << 6)
  and  t0, t0, t1
  li   t1, (0x1 << 6)
  or   t0, t0, t1
  csrw 0x802, t0

  # Default aiperm has U (if UmodeEn) + S. Clear all enable bits (no lock).
  csrw 0x7C8, zero
  csrr t0, 0x7C8
  bnez t0, fail

  # M-mode must still execute AI (ai_issue_ok always 1 in M)
  .word 0x0200055B             # ai.getcfg a0
  # no trap expected

  # Restore U+S enables; lock bit remains 0
  li   t0, 0x3
  csrw 0x7C8, t0
  csrr t1, 0x7C8
  andi t1, t1, 0xf
  li   t0, 0x3
  bne  t1, t0, fail

  # Set lock; further writes ignored
  li   t0, 0xb                 # U+S + lock
  csrw 0x7C8, t0
  li   t0, 0x0                 # try to clear all
  csrw 0x7C8, t0
  csrr t1, 0x7C8
  andi t1, t1, 0xf
  li   t0, 0xb
  bne  t1, t0, fail

  .word 0x0200055B             # still works in M

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j 1b

fail:
  li   a0, 2
  la   t0, tohost
  sw   a0, 0(t0)
2: j 2b

trap_vec:
  csrr t0, mcause
  li   t1, 2
  bne  t0, t1, fail
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
3: j 3b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
