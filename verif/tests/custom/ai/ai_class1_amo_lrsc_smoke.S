# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S4/CLASS1 exclusive on the unified DRAM slave (g6lc_axi_atomics_wrap).
# Hart 0: amoadd.d (ATOP), then lr.d/sc.d success. If CAP 0x38 N>=2, a
# second amoadd.d on the next 64 B stripe. Hart 1 parks.
# Same-hart store between LR/SC deadlocks: issue lr_sc_pair_q blocks
# non-SC STORE until SC, and in-order issue cannot reach SC. Intervening
# snoop is the wrap TB (SC fail, no downstream write).
# L2 must forward AR.lock (LDEX) or the DRAM monitor never arms.
# Needs RVA + g6lc wrap (ai-dt / ai-d*). Not OpenSBI. Not cookie. Not 400.
# Fail: 7 amoadd, 9 lr.d/sc.d. Trap: 32+((mcause<<1)|1) (odd so rvfi bit0 stops).

  .equ AI_BASE,     0x40000000
  .equ CAP_CHANS,   0x38
  .equ LINE0,       0x80090000
  .equ LINE1,       0x80090040

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap_vec
  csrw mtvec, t1
  bnez t0, amo_park

  li   s1, LINE0
  sd   zero, 0(s1)
  fence rw, rw

  li   t1, 1
  amoadd.d t0, t1, (s1)
  bnez t0, fail_amo
  ld   t0, 0(s1)
  li   t1, 1
  bne  t0, t1, fail_amo

  lr.d t0, (s1)
  li   t1, 2
  sc.d t2, t1, (s1)
  bnez t2, fail_lrsc
  ld   t0, 0(s1)
  li   t1, 2
  bne  t0, t1, fail_lrsc

  li   s0, AI_BASE
  lw   t0, CAP_CHANS(s0)
  li   t2, 0xffff
  and  t1, t0, t2
  li   t2, 2
  bltu t1, t2, pass

  li   s2, LINE1
  sd   zero, 0(s2)
  fence rw, rw
  li   t1, 5
  amoadd.d t0, t1, (s2)
  bnez t0, fail_amo
  ld   t0, 0(s2)
  li   t1, 5
  bne  t0, t1, fail_amo

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j 1b

amo_park:
  wfi
  j    amo_park

fail_amo:
  li   a0, 7
  j    fail_store
fail_lrsc:
  li   a0, 9
  j    fail_store
fail_store:
  la   t0, tohost
  sw   a0, 0(t0)
2: j 2b

trap_vec:
  csrr a0, mcause
  andi a0, a0, 0xff
  slli a0, a0, 1
  ori  a0, a0, 1
  addi a0, a0, 32
  la   t0, tohost
  sw   a0, 0(t0)
3: j 3b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
