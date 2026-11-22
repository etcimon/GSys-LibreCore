# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# SMT sibling-liveness probe for the 4-core x 2-thread (8-hart) model.
#
# Motivation: mc_all_harts_present times out with flags[1]==0 -- hart1, the
# SMT sibling of the polling hart0 on core0, never commits its flag store.
# mc_smt_sibling_yield passes only because hart0 parks first and frees core0.
# This probe removes the memory-poll variable: hart0 runs a register-only
# delay loop (no load dependency stalls) for a bounded window, THEN does a
# single census read. If hart1 is merely starved by the census poll it still
# gets SMT_RR quanta during the delay and stores flags[1]. If flags[1] stays
# 0, hart1 is never eligible -- the smt_hart_seen_q / ipi_i[1] unlock is broken.
#
# tohost: 1 -> all present, 0x100|mask -> missing (mask bit i = flags[i]==0).

#ifndef NHARTS
#define NHARTS 8
#endif
#ifndef DELAY
#define DELAY 40000          # ~register-only spin; many SMT_RR quanta
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

  # hart0 releases every other hart via CLINT msip (same as mc_all_harts_present).
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

  # Register-only delay: no loads, so no D$ dependency stalls. Each iteration
  # is ~3 cycles; DELAY iterations give hart1 many SMT_RR quanta to run.
  li   s1, DELAY
delay:
  addi s1, s1, -1
  bnez s1, delay

  # Single census pass (no retry loop): whatever flags[] holds NOW is the
  # steady-state answer. result published before tohost.
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
