# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# hyp8 arch-redirect skip probe (r59). r30 showed each flushing CSR write
# drop exactly one instruction after the commit-redirect resume:
#   csrw mstatus @ef8c -> resume @ef94 (csrw mepc @ef90 never fetched)
#   csrwi satp   @efde -> resume @efe6 (j @efe2 and malloc-entry @efe4
#                                    never fetched)
# For every redirect source this test places TWO markers immediately after
# the redirecting instruction (or at the redirect target for exceptions/
# xRET) and counts them. Each marker is an independent register bump, so a
# fail reveals both that a skip happened and how wide it was.
#
# Registers:
#   t2 = marker A count (instruction directly after the redirect source,
#        or the redirect target's first instruction)
#   t3 = marker B count (second instruction after)
#   s8 = aggregate mask: bits [2k+1:2k] = case k's missing-marker mask
#        (bit0 of the pair = marker A missing, bit1 = marker B missing)
#   s7 = first failing case number
#
# tohost verdict:
#   1                        -> every marker retired exactly once
#   (s8 << 8) | (2*s7 + 1)   -> low byte: first failing case odd code,
#                              bits[25:8]: per-case missing-marker masks
#                              (harness prints tohost>>1:
#                               reported & 0x7f = first failing case,
#                               reported >> 7  = aggregate masks)
#
#   k: 1 csrw mstatus   2 csrw satp      3 csrw sie (control)
#      4 fence.i        5 sfence.vma    6 ecall->mtvec
#      7 mret->mepc     8 c.addi marker after flushing csr
#      9 flushing csr mid-window (pc[1:0]==2), marker mid-window
#
# CHK k: fold t2/t3 marker counts into s8 bits [2k+1:2k] and remember the
# first failing case in s7. t2/t3 must hold 1 each if both markers retired.
.macro CHK k
  li    t4, 1
  li    t5, 0
  bne   t2, t4, 91f
  j     92f
91:ori   t5, t5, 1
92:bne   t3, t4, 93f
  j     94f
93:ori   t5, t5, 2
94:beqz  t5, 95f
  li    t4, (2*(\k-1))
  sll   t5, t5, t4
  or    s8, s8, t5
  bnez  s7, 95f
  li    s7, \k
95:
.endm

.option norvc
.section .text.init
.globl _start
_start:
  li    s7, 0
  li    s8, 0

# ---------------------------------------------------------------- case 1
# csrw mstatus raises flush_csr (mstatus is in the flush set). The two
# markers directly after must both retire.
  li    t2, 0
  li    t3, 0
  csrw  mstatus, zero
c1_mA:
  addi  t2, t2, 1
c1_mB:
  addi  t3, t3, 1
  CHK 1

# ---------------------------------------------------------------- case 2
# csrw satp raises flush_csr (address-translation change).
  li    t2, 0
  li    t3, 0
  csrw  satp, zero
c2_mA:
  addi  t2, t2, 1
c2_mB:
  addi  t3, t3, 1
  CHK 2

# ---------------------------------------------------------------- case 3
# csrw sie does NOT flush (control): markers must retire back-to-back.
  li    t2, 0
  li    t3, 0
  csrw  sie, zero
c3_mA:
  addi  t2, t2, 1
c3_mB:
  addi  t3, t3, 1
  CHK 3

# ---------------------------------------------------------------- case 4
# fence.i forces an icache refill / refetch of the following window.
  li    t2, 0
  li    t3, 0
  fence.i
c4_mA:
  addi  t2, t2, 1
c4_mB:
  addi  t3, t3, 1
  CHK 4

# ---------------------------------------------------------------- case 5
# sfence.vma flushes the TLB; in M-mode it is legal (mstatus.TVM=0 after
# the case-1 write).
  li    t2, 0
  li    t3, 0
  sfence.vma
c5_mA:
  addi  t2, t2, 1
c5_mB:
  addi  t3, t3, 1
  CHK 5

# ---------------------------------------------------------------- case 6
# ecall -> SRC_EX redirect: the trap handler's first two instructions are
# the markers. The handler bumps mepc by 4 and returns.
  li    t2, 0
  li    t3, 0
  la    t4, trap_handler
  csrw  mtvec, t4
  nop
  nop
  ecall
c6_ret:
  CHK 6

# ---------------------------------------------------------------- case 7
# mret -> SRC_ERET redirect: the return target's first two instructions
# are the markers. mstatus.MPP is set to M (11) so we stay in M-mode.
  li    t2, 0
  li    t3, 0
  la    t4, mret_target
  csrw  mepc, t4
  csrr  t5, mstatus
  li    t4, 0x1800
  or    t5, t5, t4
  csrw  mstatus, t5      # itself flushing -> nops absorb any skip
  nop
  nop
  nop
  nop
  mret
  # unreachable
mret_target:
  addi  t2, t2, 1        # marker A
  addi  t3, t3, 1        # marker B
  CHK 7

# ---------------------------------------------------------------- case 8
# compressed markers directly after a flushing csr (the OpenSBI shape:
# csrwi satp followed by a 2-byte c.j).
  .option push
  .option rvc
  .balign 4
  li    t2, 0
  li    t3, 0
  csrw  satp, zero
c8_mA:
  c.addi t2, 1
c8_mB:
  c.addi t3, 1
  .option pop
  CHK 8

# ---------------------------------------------------------------- case 9
# flushing csr placed at pc[1:0]==2 (mid-fetch-window): the resume target
# marker at pc+4 is also mid-window. One compressed pad shifts alignment.
  .option push
  .option rvc
  .balign 4
  li    t2, 0
  li    t3, 0
  c.nop                  # csr lands at pc[1:0]==2
  csrw  mstatus, zero
  .option pop
  .option push
  .option norvc
c9_mA:
  addi  t2, t2, 1        # 4B marker at pc[1:0]==2, mid-window
c9_mB:
  addi  t3, t3, 1
  .option pop
  CHK 9

# ---------------------------------------------------------------- verdict
  beqz  s8, pass
  slli  t0, s8, 8
  slli  t1, s7, 1
  addi  t1, t1, 1
  or    t0, t0, t1
  la    t1, tohost
  sw    t0, 0(t1)
  j     done

pass:
  li    t0, 1
  la    t1, tohost
  sw    t0, 0(t1)
  j     done

# ---------------------------------------------------------------- handler
# mtvec handler for case 6: markers are the first two instructions.
.balign 4
trap_handler:
  addi  t2, t2, 1        # marker A
  addi  t3, t3, 1        # marker B
  csrr  t5, mepc
  addi  t5, t5, 4
  csrw  mepc, t5
  mret

done:
  j     done

.section .tohost,"aw",@progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
