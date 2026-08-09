# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Soft-ladder B1 (cont.33): OpenSBI-style CSR expected-trap under dual-issue.
# Pattern:
#   csrrw mtvec, handler
#   csrr  <illegal/unimplemented>   # may trap
#   csrw  mtvec, old
# Handler must run (__sbi_expected_trap style: advance mepc, mret).
# If restore dual-issues/races the illegal, trap hits wrong mtvec.
#
# Gate: g6lc64_smt2 DI preferred; tohost=1 pass, 3 fail.

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  # Default fatal trap
  la   t0, fatal
  csrw mtvec, t0

  # --- expected-trap sequence (mirrors OpenSBI) ---
  la   t0, expected_handler
  csrrw t1, mtvec, t0          # t1 = old mtvec; mtvec = handler

  # Probe: read non-existent CSR (custom high number → illegal)
  # Encoding: csrr t2, 0xFFF  (csr=0xfff, rd=t2, rs1=0, funct3=CSRRS)
  .word 0xfff022f3             # csrrs t2, 0xfff, x0

  # Restore mtvec (must not race ahead of the illegal)
  csrw mtvec, t1

  # If we got here without handler, probe did not trap (optional soft pass)
  # Require handler ran: s0 set to 0xE601
  li   t3, 0xE601
  bne  s0, t3, fail

  # Second pair: trap again after restore
  la   t0, expected_handler
  csrrw t1, mtvec, t0
  .word 0xfff022f3
  csrw mtvec, t1
  li   t3, 0xE601
  bne  s0, t3, fail

  # PASS
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

# OpenSBI-like: mepc += 4; mark s0; mret
expected_handler:
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  li   s0, 0xE601
  mret

fatal:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

fail:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
