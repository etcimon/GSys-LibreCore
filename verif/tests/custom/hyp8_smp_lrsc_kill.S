# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# rfix131a RFIX-131a-14 probe: cross-core LR/SC reservation-kill discriminator.
#
# hyp8_smp_lrsc fails f_lrsc (shared LR/SC counter != ROUNDS*NHARTS) on the 8-hart
# mc model while SMT2 (one core) passes. This isolates the mechanism: does a
# remote store kill a local LR reservation across cores?
#
#   hart 0 (core 0)  : lr.d X ; flag LR_DONE ; wait B_WROTE ; sc.d X -> MUST FAIL
#   hart 2 (core 1)  : wait LR_DONE ; sd X (plain store) ; flag B_WROTE ; park
#   all other harts  : park immediately
#
# A correct machine: hart0's SC fails (reservation killed by hart2's store) ->
# sc.d returns nonzero -> tohost = 1 (pass). If hart0's SC succeeds, the remote
# write did not kill the reservation -> the exclusive monitor / coherence kill
# path is broken -> tohost = 3.
#
# tohost raw: 1 pass, 3 SC wrongly succeeded, 5 sync timeout, 7 unexpected trap,
# 9 stored value clobbered.
#ifndef NHARTS
#define NHARTS 8
#endif
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
  # hart 0 releases every other hart, then is the LR/SC probe
  bnez  s0, maybe_worker
  li    t1, 1
  li    t2, 1
1:
  bgeu  t2, s1, worker0
  slli  t3, t2, 2
  add   t3, t3, s6
  sw    t1, 0(t3)
  addi  t2, t2, 1
  j     1b
maybe_worker:
  # non-zero harts: only hart 2 is the remote writer; others park
  li    t2, 2
  bne   s0, t2, park
worker2:
  # hart 2 (core 1): clear own MSIP, wait for LR_DONE, store X, flag B_WROTE
  slli  t3, s0, 2
  add   t3, t3, s6
  sw    x0, 0(t3)
  li    t4, 400000             # sync budget
w2_wait_lr:
  ld    t3, 0(s2)
  bnez  t3, w2_go
  addi  t4, t4, -1
  beqz  t4, f_sync
  j     w2_wait_lr
w2_go:
  la    t3, probe_val
  li    t5, 0xA5A5A5A5A5A5A5A5
  sd    t5, 0(t3)              # plain store to the reserved line's word
  fence
  li    t1, 1
  sw    t1, 8(s2)
  j     park
worker0:
  # hart 0 (core 0): clear own MSIP, LR, flag, wait B_WROTE, SC (must fail)
  slli  t3, s0, 2
  add   t3, t3, s6
  sw    x0, 0(t3)
  fence
  la    a0, probe_val
  li    t1, 0x1111111111111111
  sd    t1, 0(a0)              # init the probe word
  fence
  lr.d  a1, 0(a0)              # reserve
  fence
  li    t1, 1
  sw    t1, 0(s2)        # tell hart2 to write
  li    t4, 400000
w0_wait_bw:
  ld    t3, 8(s2)
  bnez  t3, w0_sc
  addi  t4, t4, -1
  beqz  t4, f_sync
  j     w0_wait_bw
w0_sc:
  fence                         # ensure hart2's store is globally visible first
  li    t1, 0x2222222222222222
  sc.d  t2, t1, 0(a0)          # must FAIL: hart2 wrote after our LR
  bnez  t2, sc_failed_ok       # sc.d nonzero = failed = correct
  # SC wrongly succeeded -> reservation kill broken
  li    t0, 3
  j     report
sc_failed_ok:
  # also verify the stored value is hart2's (our SC did not clobber it)
  ld    t3, 0(a0)
  li    t5, 0xA5A5A5A5A5A5A5A5
  bne   t3, t5, f_val           # if SC failed, word must still be hart2's value
  li    t0, 1
report:
  la    t1, tohost
  sw    t0, 0(t1)
park:
  wfi
  j     park
f_sync:
  li    t0, 5
  j     report
f_val:
  li    t0, 9
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
  .fill 16, 8, 0
# byte offsets inside `shared` (s2 = &shared): +0 LR_DONE, +8 B_WROTE
probe_val:
  .dword 0

.section .tohost,"aw",@progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
