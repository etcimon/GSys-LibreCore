# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Zkn known-answer smoke (r127). Runs every RV64 scalar-crypto instruction
# served by the AES/SHA functional unit -- aes64es, aes64esm, aes64ds,
# aes64dsm, aes64ks2, aes64im, aes64ks1i (round numbers 0..10), sha256sig0/1,
# sha256sum0/1, sha512sig0/1, sha512sum0/1 -- over a table of operand pairs
# and folds all results into one checksum. The checksum is compared with the
# value the Spike ISA simulator computes for this same program (`expected`
# below; regenerate with verif/regress/remote/hyp8/regen_zkn_kat.sh --patch
# after changing the table or the instruction list). None of the other hyp8
# smokes issues an instruction to that unit.
#
# The instructions are emitted with .insn, so the test assembles with the
# integration's -march (which has no Zk* extension).
#
# tohost = 1 on success; 3 = checksum mismatch;
# ((16 + mcause) << 1) | 1 = an unexpected trap. A wedge shows as a budget-out.
.option norvc

.macro FOLD
  slli  t3, s2, 5
  srli  t4, s2, 59
  or    s2, t3, t4
  xor   s2, s2, a2
.endm

.macro RR f7
  .insn r 0x33, 0, \f7, a2, a0, a1
  FOLD
.endm

.macro RI imm
  .insn i 0x13, 1, a2, a0, \imm
  FOLD
.endm

.section .text.init
.globl _start
_start:
  la    t0, m_trap
  csrw  mtvec, t0
  la    s0, tab
  li    s1, 8                 # operand pairs
  li    s2, 0                 # checksum
loop:
  ld    a0, 0(s0)
  ld    a1, 8(s0)
  RR    0x19                  # aes64es
  RR    0x1b                  # aes64esm
  RR    0x1d                  # aes64ds
  RR    0x1f                  # aes64dsm
  RR    0x3f                  # aes64ks2
  RI    0x300                 # aes64im
  RI    0x310                 # aes64ks1i rnum 0..10
  RI    0x311
  RI    0x312
  RI    0x313
  RI    0x314
  RI    0x315
  RI    0x316
  RI    0x317
  RI    0x318
  RI    0x319
  RI    0x31a
  RI    0x102                 # sha256sig0
  RI    0x103                 # sha256sig1
  RI    0x100                 # sha256sum0
  RI    0x101                 # sha256sum1
  RI    0x106                 # sha512sig0
  RI    0x107                 # sha512sig1
  RI    0x104                 # sha512sum0
  RI    0x105                 # sha512sum1
  # a dependent pair: the result of one round feeds the next (back-to-back
  # issue to the same unit with a forwarded operand)
  .insn r 0x33, 0, 0x19, a3, a0, a1
  .insn r 0x33, 0, 0x1b, a2, a3, a0
  FOLD
  .insn i 0x13, 1, a3, a1, 0x315
  .insn r 0x33, 0, 0x3f, a2, a3, a1
  FOLD
  addi  s0, s0, 16
  addi  s1, s1, -1
  bnez  s1, loop

  la    t1, chk_out
  sd    s2, 0(t1)
  la    t1, expected
  ld    t2, 0(t1)
  bne   s2, t2, fail
  li    t0, 1
  la    t1, tohost
  sw    t0, 0(t1)
done:
  j     done
fail:
  li    t0, 3
  la    t1, tohost
  sw    t0, 0(t1)
  j     done

.align 4
m_trap:
  csrr  t0, mcause
  addi  t0, t0, 16
  slli  t0, t0, 1
  addi  t0, t0, 1
  la    t1, tohost
  sw    t0, 0(t1)
m_done:
  j     m_done

.section .data
.align 6
tab:
  .dword 0x0000000000000000, 0x0000000000000000
  .dword 0xffffffffffffffff, 0xffffffffffffffff
  .dword 0x0123456789abcdef, 0xfedcba9876543210
  .dword 0x8000000000000001, 0x00000000ffffffff
  .dword 0xa5a5a5a55a5a5a5a, 0x3c3c3c3cc3c3c3c3
  .dword 0x0011223344556677, 0x8899aabbccddeeff
  .dword 0x2b7e151628aed2a6, 0xabf7158809cf4f3c
  .dword 0x6bc1bee22e409f96, 0xe93d7e117393172a
.align 6
expected:
  .dword 0x47cd2d7d1c5040a6
chk_out:
  .dword 0

.section .tohost,"aw",@progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
