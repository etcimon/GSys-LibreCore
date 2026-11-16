# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# SMP bring-up and shared-memory atomics, every hart (rfix131a multi-core).
#
# The first program that runs on all harts of g6lc64_hyp8_mc (4 cores x 2
# harts, shared L2/L3, coherence hub) on purpose; the other smokes are
# single-thread programs. It isolates what an SMP Linux boot needs first:
#   - secondary-core release: hart 0 raises MSIP for every other hart (the
#     cluster's boot hold opens on the IPI); each hart clears its own MSIP;
#   - LR/SC across cores: every hart increments one shared counter ROUNDS
#     times with lr.d / sc.d (a lost reservation must fail the SC);
#   - AMO across cores: the same with amoadd.d on a second counter;
#   - coherence of plain loads/stores: every hart stores its round number to
#     its own slot and reads it back; the slots of sibling harts share cache
#     lines, and hart 0 polls a word the other harts update.
# Built with -DNHARTS=<n> (HYP8_TEST_DEFINES); the default 1 makes it a
# plain single-hart smoke. Harts numbered >= NHARTS park.
#
# tohost = 1 on success; 3: LR/SC count wrong (a lost update or a duplicate);
# 5: arrivals != NHARTS; 7: AMO count wrong; 9: a hart read back a wrong
# value from its own slot; 11: a final slot value is wrong;
# ((16 + mcause) << 1) | 1: an unexpected trap. A hart that never arrives is
# a budget-out.
#ifndef NHARTS
#define NHARTS 1
#endif
#define ROUNDS 48
#define CNT_LRSC 0
#define CNT_AMO  8
#define ARRIVED  16
#define DONE     24
#define SLOTS    64
.option norvc
.section .text.init
.globl _start
_start:
  la    t0, m_trap
  csrw  mtvec, t0
  csrw  mie, x0
  csrr  s0, mhartid
  li    s1, NHARTS
  bgeu  s0, s1, park
  la    s2, shared
  li    s6, 0x02000000        # CLINT msip[0]
  bnez  s0, worker
  # hart 0: release every other hart
  li    t1, 1
  li    t2, 1
1:
  bgeu  t2, s1, worker
  slli  t3, t2, 2
  add   t3, t3, s6
  sw    t1, 0(t3)
  addi  t2, t2, 1
  j     1b
worker:
  slli  t3, s0, 2
  add   t3, t3, s6
  sw    x0, 0(t3)             # clear my own MSIP
  li    t1, 1
  addi  a0, s2, ARRIVED
  amoadd.d x0, t1, (a0)
  li    s3, ROUNDS
  li    s4, 0
  slli  t4, s0, 3
  add   s5, s2, t4
  addi  s5, s5, SLOTS         # my slot
2:
  addi  a0, s2, CNT_LRSC
3:
  lr.d  t2, (a0)
  addi  t2, t2, 1
  sc.d  t3, t2, (a0)
  bnez  t3, 3b
  addi  a0, s2, CNT_AMO
  amoadd.d x0, t1, (a0)
  sd    s4, 0(s5)
  ld    t2, 0(s5)
  bne   t2, s4, f_slot
  addi  s4, s4, 1
  bne   s4, s3, 2b
  addi  a0, s2, DONE
  amoadd.d x0, t1, (a0)
  bnez  s0, park
  # hart 0: wait for every hart, then check
4:
  ld    t2, DONE(s2)
  bne   t2, s1, 4b
  li    t0, ROUNDS
  mul   t0, t0, s1
  ld    t2, CNT_LRSC(s2)
  bne   t2, t0, f_lrsc
  ld    t2, CNT_AMO(s2)
  bne   t2, t0, f_amo
  ld    t2, ARRIVED(s2)
  bne   t2, s1, f_arr
  li    t3, 0
  li    t4, ROUNDS - 1
5:
  slli  t5, t3, 3
  add   t5, t5, s2
  ld    t2, SLOTS(t5)
  bne   t2, t4, f_final
  addi  t3, t3, 1
  bne   t3, s1, 5b
  li    t0, 1
report:
  la    t1, tohost
  sw    t0, 0(t1)
park:
  wfi
  j     park
f_lrsc:
  li    t0, 3
  j     report
f_arr:
  li    t0, 5
  j     report
f_amo:
  li    t0, 7
  j     report
f_slot:
  li    t0, 9
  j     report
f_final:
  li    t0, 11
  j     report

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
shared:
  .fill 32, 8, 0

.section .tohost,"aw",@progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
