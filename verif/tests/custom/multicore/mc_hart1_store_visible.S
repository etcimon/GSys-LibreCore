# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Is a store by hart 1 visible to hart 0? (And is the tohost problem the DUT or
# the harness?)
#
# Established by `mc_hart1_alive.S` + the repaired CVA6_MC_PC_PROBE: hart 1 does
# execute and does retire a store to tohost (it parks at the instruction after
# the store and the fence), yet the harness never observes it. The probe shows
# the store's address latched at the L2 in 199 consecutive samples
# (l2a=0x80001000) and NEVER presented to the DRAM backend (a2m_a only ever
# carries instruction lines). Two explanations remain and they have opposite
# consequences:
#
#   (a) the write is globally visible but simply parked in a write-back L2, and
#       the testbench's tohost poll reads the DRAM array, so it cannot see it.
#       That is a HARNESS limitation, not a silicon defect.
#   (b) the write never completes — e.g. its W data or B response is lost in the
#       coherence hub — so it is not visible to anyone. That is a real defect.
#
# This test discriminates them directly, and hart 0 does the reporting because
# hart 0's tohost writes are known to work: hart 1 stores a cookie to a shared
# cache line, then hart 0 loads it and reports what it saw. Reading the cookie
# proves (a); reading zero proves (b). (Never begin a comment with "# line" here:
# the assembler's preprocessor reads it as a #line directive and fails.)
#
# Note the addresses are deliberately NOT tohost: mixing the property under test
# with the reporting channel is what made the earlier tests uninterpretable.
#
# tohost: 1 = hart 0 observed the cookie (case a);
#         9 = hart 0 never observed it within the window (case b);
#        32+((mcause<<1)|1) on a trap.
#
# Needs NrCores >= 2. Requires +debug_disable and +tohost_addr.

  .equ SHARED,  0x80090000
  .equ COOKIE,  0x5a5a
  .equ SPIN,    40000

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap_vec
  csrw mtvec, t1
  bnez t0, hart1

  # ---- hart 0: the reporter ----
  li   s1, SHARED
  sd   zero, 0(s1)              # clear before hart 1 can publish
  fence rw, rw

  li   t2, SPIN
  li   t3, COOKIE
1:
  ld   t0, 0(s1)
  beq  t0, t3, observed
  addi t2, t2, -1
  bnez t2, 1b

  li   a0, 9                    # case (b): never observed
  j    report
observed:
  li   a0, 1                    # case (a): visible to the other core
report:
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
2: j 2b

  # ---- hart 1: the publisher, and nothing else ----
hart1:
  li   s1, SHARED
  li   t1, COOKIE
  # Let hart 0 clear the location first; a plain register countdown, so hart 1
  # issues no memory traffic during the window.
  li   t2, 2000
3:
  addi t2, t2, -1
  bnez t2, 3b
  sd   t1, 0(s1)
  fence rw, rw
4: j 4b

trap_vec:
  csrr a0, mcause
  andi a0, a0, 0xff
  slli a0, a0, 1
  ori  a0, a0, 1
  addi a0, a0, 32
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
5: j 5b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
