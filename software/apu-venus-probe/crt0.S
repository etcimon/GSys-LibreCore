# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Bare-metal entry for the 3d-a Venus probe: single hart, M-mode,
# DRAM-resident.  No trap handler is needed (the probe polls
# INTERRUPT_STATUS), but park anything unexpected.

  .section .text.init
  .globl _start
_start:
  csrw  mie, zero
  csrw  mip, zero
  la    sp, _stack_top
  la    t0, trap
  csrw  mtvec, t0
  # clear .bss
  la    t0, _bss_start
  la    t1, _bss_end
1:  bgeu  t0, t1, 2f
  sd    zero, 0(t0)
  addi  t0, t0, 8
  j     1b
2:
  # enable Zicbom CMOs in M-mode
  li    t0, 3
  csrw  menvcfg, t0
  call  main
3:  j     3b

trap:
  # park: write FAIL cookie (step 0xEE) so the TB sees a bad trap
  la    t0, trap_cookie_addr
  ld    t0, 0(t0)
  li    t1, 0xBAD000EE
  sd    t1, 0(t0)
4:  j     4b

  .section .rodata
  .align 3
trap_cookie_addr:
  .quad 0x80000F00
