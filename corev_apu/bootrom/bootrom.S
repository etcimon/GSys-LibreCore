# SPDX-License-Identifier: SolderpadHardwareLicense-0.51
# Copyright 2018 ETH Zurich and University of Bologna.
# Copyright 2026 Etienne Cimon (SMT bring-up fix)
#
.section .text.start, "ax", @progbits
.globl _start
_start:
# bootrom.sv must be functional in 64 and 32 bits.
# li s0, DRAM_BASE creates an encoding that is not compatible with both
# versions, so we use li + slli for DRAM_BASE = 0x80000000.
#
# Place csrr/auipc/addi before slli so s0 is the last register written
# before the jump. Insert nops and a fence to drain the issue pipe before
# the jr reads s0; SMT2 issue does not forward ALU results.
#
# All harts jump to DRAM at the same reset vector. Multi-core and fine-grain
# SMT secondaries are parked by *software* (OpenSBI HSM, smt_dual_park).
# Parking mhartid!=0 here permanently WFI-blocked SMT peers from DRAM and
# made dual-active bare-metal impossible (peer never left bootrom).
  # Force rs1=x0 so the SMT FDT-compensation commit filter (G1lc) does not
  # suppress the immediate load as an "addi s0, s0, 1" (rs1==rd==x8).
  addi s0, x0, 1
  csrr a0, mhartid
1: auipc a1, %pcrel_hi(_dtb)
  nop
  addi a1, a1, %pcrel_lo(1b)
  slli s0, s0, 31
  nop
  nop
  nop
  nop
  nop
  fence
  jr s0

.section .text.hang, "ax", @progbits
.globl _hang
_hang:
  # Software park target for any hart that falls through.
1:
  wfi
  j 1b

.section .rodata.dtb, "a", @progbits
.globl _dtb
.align 5, 0
_dtb:
.incbin "ariane.dtb"
