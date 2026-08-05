# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# U10 discovery smoke (server_math package):
#   misa.B (bit 1), misa.H (bit 7), optional misa.V (bit 21)
# Self-skips individual checks if extension bits clear (baseline packages).

  .globl main
main:
  csrr t0, misa

  # ---- B (bitmanip) ----
  li   t1, (1 << 1)
  and  t2, t0, t1
  beqz t2, no_b
  # Smoke Zbb ANDN: a = ~b & c  via andn (if assembler lacks andn, use .word)
  li   a0, 0x0F0F0F0F0F0F0F0F
  li   a1, 0x00FF00FF00FF00FF
  # andn a2, a0, a1  => a0 & ~a1
  .word 0x40B57533           # andn a0, a0, a1  (rd=a0, rs1=a0, rs2=a1)
  li   t3, 0x0F000F000F000F00
  bne  a0, t3, fail
  j    b_ok
no_b:
b_ok:

  # ---- H (hypervisor) ----
  li   t1, (1 << 7)
  and  t2, t0, t1
  beqz t2, no_h
  # hstatus readable
  la   t4, h_trap
  csrw mtvec, t4
  csrr t5, 0x600             # hstatus
  j    h_ok
h_trap:
  j    fail
no_h:
h_ok:

  # ---- V (vector) optional ----
  li   t1, (1 << 21)
  and  t2, t0, t1
  # If V set, only record — full vector needs Ara
  # fall through either way

  li   a0, 0
  jal  exit

fail:
  li   a0, 1
  jal  exit
