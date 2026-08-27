# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# SL-C: I4dn IPI-wake. Hart0 writes CLINT MSIP[1] then WFI (G1df lifts
# SMT_COLD_EXCL). Hart1 was unseen (G1di) until ipi_i[1]; after unmask it
# runs _start, sets sp, writes tohost. No IPI → G1di keeps hart1 off.
#
# tohost (odd => TB >>1): 1 PASS (hart1 ran, sp set); 25 trap.
# Cap tohost=0 with no rvfi terminate is hang.

  .option rvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, hart1
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  # CLINT MSIP: smp_resume shape (sw 1 at +0 and +4). Drain via DRAM ld
  # then a short spin so AXI completes before WFI (G1df).
  li   t0, 0x02000000
  li   t1, 1
  sw   t1, 0(t0)
  sw   t1, 4(t0)
  fence
  la   t2, tohost
  ld   t3, 0(t2)
  li   t4, 2000
1: addi t4, t4, -1
  bnez t4, 1b

  # Halt hart0 so G1df drops COLD_EXCL; I4dn should have seen ipi_i[1].
2: wfi
  j    2b

hart1:
  li   sp, 0x80007000
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
2: wfi
  j    2b

fail_exit:
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

trap:
  li   a0, 25
  j    fail_exit

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
