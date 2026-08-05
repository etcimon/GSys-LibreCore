# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# U10 C-light: Zicboz cbo.zero + scalar memset path.
# Requires RVZiCboz package (server_math). CBZE defaults enabled in CSR.
# Encoding: SYSTEM, funct3=2, imm=4, rs1=base  (cbo.zero (rs1))

  .globl main
main:
  addi sp, sp, -128
  mv   s0, sp

  # Dirty a cache-line-sized region (64 B) with non-zero pattern
  li   t0, 0xA5A5A5A5A5A5A5A5
  li   t1, 8
  mv   t2, s0
1:
  sd   t0, 0(t2)
  addi t2, t2, 8
  addi t1, t1, -1
  bnez t1, 1b

  # Align base for cbo.zero (line-aligned preferred; use s0 as-is if already)
  andi s1, s0, -64
  beq  s1, s0, aligned
  # if sp not 64B aligned, use s0 and still zero 64B via scalar fallback
  j    scalar_zero
aligned:
  # cbo.zero (s1)  — rs1=s1, funct3=010, imm=4, opcode=SYSTEM
  # instr = imm[11:0]<<20 | rs1<<15 | 010<<12 | 00000<<7 | 1110011
  # With rs1=s1 (x9): 0x0044A073
  .word 0x0044A073

  # Verify 64 B zeroed
  li   t1, 8
  mv   t2, s1
2:
  ld   t3, 0(t2)
  bnez t3, fail
  addi t2, t2, 8
  addi t1, t1, -1
  bnez t1, 2b
  j    pass

scalar_zero:
  # Portable memset-style zero (always correct; exercises store path)
  li   t1, 8
  mv   t2, s0
3:
  sd   zero, 0(t2)
  addi t2, t2, 8
  addi t1, t1, -1
  bnez t1, 3b
  li   t1, 8
  mv   t2, s0
4:
  ld   t3, 0(t2)
  bnez t3, fail
  addi t2, t2, 8
  addi t1, t1, -1
  bnez t1, 4b

pass:
  addi sp, sp, 128
  li   a0, 0
  jal  exit

fail:
  addi sp, sp, 128
  li   a0, 1
  jal  exit
