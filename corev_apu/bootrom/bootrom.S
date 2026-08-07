# SPDX-License-Identifier: SolderpadHardwareLicense-0.51
# Copyright 2018 ETH Zurich and University of Bologna.
# Copyright 2026 Etienne Cimon (SMT bring-up fix)
#
.section .text.start, "ax", @progbits
.globl _start
_start:
# bootrom.sv need to be functional in 64 and 32 bits,
# li s0, DRAM_BASE creates instructions not compatible with both
# versions. That is why we use li + slli for DRAM_BASE = 0x80000000.
#
# All harts jump to DRAM at the same reset vector. Multi-core and fine-grain
# SMT secondaries are parked by *software* (OpenSBI HSM, smt_dual_park).
# Parking mhartid!=0 here permanently WFI-blocked SMT peers from DRAM and
# made dual-active bare-metal impossible (peer never left bootrom).
  li s0, 1
  slli s0, s0, 31
  csrr a0, mhartid
  la a1, _dtb
  jr s0

.section .text.hang, "ax", @progbits
.globl _hang
_hang:
  # Optional software park target (not taken from _start).
  csrr a0, mhartid
  la a1, _dtb
1:
  wfi
  j 1b

.section .rodata.dtb, "a", @progbits
.globl _dtb
.align 5, 0
_dtb:
.incbin "ariane.dtb"
