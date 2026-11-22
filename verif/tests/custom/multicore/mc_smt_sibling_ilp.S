# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# SMT sibling-liveness probe -- instruction-level-parallelism variant.
#
# mc_smt_sibling_both_present showed core0 thread1 (mhartid1) starves while
# hart0 spins: [smt-drain] FINAL ret={29884,0,0,0} req=0 switches=0. The delay
# loop there is a *serially dependent* countdown (addi s1,-1; bnez s1), which
# saturates the OoO backend so the IF->ID fetch accept (smt_fetch_fire) stalls
# and the SMT_RR quantum counter never reaches SmtFetchQuantum -> the quantum
# switch never requests a drain -> the sibling never runs.
#
# This variant keeps the SAME "hart0 stays ready, hart1 must win a quantum
# switch" structure but replaces the dependent countdown with a 4-way
# independent-counter delay: four decrement chains per iteration give the
# backend ILP so fetch keeps flowing. If hart1 then stores flags[1] and parks,
# the starvation is confirmed to be backend-pressure freezing the fetch-based
# quantum rather than an eligibility/seen bug.
#
# tohost: 1 -> all present, 0x100|mask -> missing (mask bit i = flags[i]==0).

#ifndef NHARTS
#define NHARTS 8
#endif
#ifndef DELAY
#define DELAY 12000          # iterations; ~4 indep ops each -> many quanta
#endif
  .equ CLINT_MSIP, 0x02000000

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap_vec
  csrw mtvec, t1
  csrw mie, x0

  # hart0 releases every other hart via CLINT msip.
  csrr t0, mhartid
  bnez t0, rel_done
  li   t1, 1
  li   t2, 1
  li   t4, CLINT_MSIP
  li   t5, NHARTS
rel_loop:
  bgeu  t2, t5, rel_done
  slli  t3, t2, 2
  add   t3, t3, t4
  sw    t1, 0(t3)
  addi  t2, t2, 1
  j     rel_loop
rel_done:

  # Every hart publishes itself: flags[mhartid] = mhartid+1.
  csrr t0, mhartid
  slli t0, t0, 2
  la   t1, flags
  add  t0, t0, t1
  csrr t2, mhartid
  addi t2, t2, 1
  sw   t2, 0(t0)
  fence rw, rw

  # hart 0 is the census reader; all others park.
  csrr t0, mhartid
  bnez t0, park

  # Independent-counter delay: 4 chains give the OoO backend ILP so the
  # frontend keeps accepting fetches (unlike the serially-dependent probe).
  # All four start at DELAY and are decremented together; s1 alone feeds the
  # exit branch, so s2/s3/s4 are independent work the backend can overlap.
  li   s1, DELAY
  li   s2, DELAY
  li   s3, DELAY
  li   s4, DELAY
delay:
  addi s1, s1, -1
  addi s2, s2, -1
  addi s3, s3, -1
  addi s4, s4, -1
  bnez s1, delay

  # Single census pass: whatever flags[] holds NOW is the steady-state answer.
  li   s0, NHARTS
  li   s2, 0
  li   s3, 0
  la   s4, flags
1:
  slli s5, s3, 2
  add  s5, s4, s5
  lw   s6, 0(s5)
  bnez s6, 2f
  li   t3, 1
  sll  t3, t3, s3
  or   s2, s2, t3
2:
  addi s3, s3, 1
  bltu s3, s0, 1b

  la   t0, result
  sw   s2, 0(t0)
  fence rw, rw

  bnez s2, giveup
  li   a0, 1
  j    done

giveup:
  li   a0, 0x100
  or   a0, a0, s2
  j    done

park:
  wfi
  j    park

done:
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
3: j 3b

trap_vec:
  csrr a0, mcause
  andi a0, a0, 0xff
  slli a0, a0, 1
  ori  a0, a0, 1
  addi a0, a0, 32
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
4: j 4b

  .section .data,"aw",@progbits
  .align 3
  .globl flags
flags:  .fill NHARTS,4,0
  .globl result
result: .dword 0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
