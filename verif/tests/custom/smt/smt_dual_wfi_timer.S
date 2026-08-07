# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Dual-WFI without software IPI:
#   Both harts enable MTIE, program CLINT mtimecmp (no MSIP), then WFI.
#   Timer (MTIP) must wake at least one hart to score tohost PASS.
#   Proves inactive-bank WFI clear is visible to thread select (hart_halt_o).

  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  # Direct-mode trap → pass (timer wake)
  la   t1, trap_entry
  csrw mtvec, t1

  # Enable M-mode timer interrupt (MTIE) + global MIE
  li   t1, (1 << 7)
  csrs mie, t1
  csrsi mstatus, 8

  # CLINT: mtime @ 0x0200bff8, mtimecmp[h] @ 0x02004000 + 8*h
  li   t1, 0x0200bff8
  ld   t2, 0(t1)
  addi t2, t2, 32          # small delta (sim RTC ticks often)

  # Program mtimecmp for both software harts (no MSIP / IPI)
  li   t1, 0x02004000
  sd   t2, 0(t1)           # hart 0
  sd   t2, 8(t1)           # hart 1

  # Both harts enter WFI; either may wake and PASS
1:
  wfi
  j    1b

trap_entry:
  # Disarm timer for this hart so we do not re-trap forever
  csrr t0, mhartid
  slli t0, t0, 3
  li   t1, 0x02004000
  add  t1, t1, t0
  li   t2, -1
  sd   t2, 0(t1)
  # PASS
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0