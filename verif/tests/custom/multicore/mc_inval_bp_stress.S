# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Force the external-invalidation retention slot to actually FILL.
#
# mc_two_inval_backpressure.S delivers two invalidations to an idle observer and
# both land, but the instrumentation in cva6_hpdcache_subsystem.sv reported
# `backpressured=0`: the slot drained before the next invalidation arrived, so the
# one-entry depth was never exercised. An end-to-end pass cannot distinguish a
# retention that fills and drains correctly from one that never fills — so this
# test targets the only condition that keeps the slot occupied.
#
# The idea: injection steals a read-response cycle, and a REAL response always
# wins that channel (`inv_inject = pend & ~axi_rresp_valid`). So an observer that
# is streaming cache misses keeps the response channel busy and defers injection,
# leaving the slot full when the next invalidation arrives. Hart 0 therefore walks
# a large array — every load a miss — while hart 1 writes four shared lines
# back-to-back. Success requires `backpressured` > 0 in the counters AND all four
# values observed; the verdict alone is not the point of this test.
#
# STREAM must exceed the D$ so the walk keeps missing rather than settling into
# hits: 32 KiB cache, so a 256 KiB walk at 64 B stride is 4096 misses.
#
# tohost: 1 = all four observed; 9/11/13/15 = the Nth line stale;
#         5 = handshake timeout; 32+((mcause<<1)|1) on a trap.
#
# Needs NrCores >= 2. Requires +debug_disable and +tohost_addr.

  .equ L0,      0x80090000
  .equ L1,      0x80090100
  .equ L2,      0x80090200
  .equ L3,      0x80090300
  .equ GO,      0x80090400
  .equ STREAM,  0x80100000        # 256 KiB walk region, disjoint from the lines
  .equ STRIDE,  64
  .equ STEPS,   4096
  .equ C0,      0x1111
  .equ C1,      0x2222
  .equ C2,      0x3333
  .equ C3,      0x4444
  .equ SPIN,    40000

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap_vec
  csrw mtvec, t1
  bnez t0, hart1

  # ---- hart 0: streams misses so the response channel stays busy ----
  li   s1, L0
  li   s2, L1
  li   s3, L2
  li   s4, L3
  li   s5, GO
  sd   zero, 0(s1)
  sd   zero, 0(s2)
  sd   zero, 0(s3)
  sd   zero, 0(s4)
  sd   zero, 0(s5)
  fence rw, rw

  # Cache all four shared lines, so hart 1's writes must invalidate them.
  ld   t0, 0(s1)
  ld   t0, 0(s2)
  ld   t0, 0(s3)
  ld   t0, 0(s4)

  li   t1, 1
  sd   t1, 0(s5)                  # GO
  fence rw, rw

  # Miss stream. Each iteration touches a new line in a region far larger than the
  # D$, so the read-response channel is occupied and injection is deferred.
  li   s6, STREAM
  li   t2, STEPS
1:
  ld   t0, 0(s6)
  addi s6, s6, STRIDE
  addi t2, t2, -1
  bnez t2, 1b

  # Now check every shared line. The stream must not have refreshed them: STREAM is
  # 0x80100000, far from 0x80090000, and the walk never touches those addresses.
  ld   t0, 0(s1)
  li   t1, C0
  bne  t0, t1, fail0
  ld   t0, 0(s2)
  li   t1, C1
  bne  t0, t1, fail1
  ld   t0, 0(s3)
  li   t1, C2
  bne  t0, t1, fail2
  ld   t0, 0(s4)
  li   t1, C3
  bne  t0, t1, fail3

  li   a0, 1
  j    report

  # ---- hart 1: four writes back-to-back ----
hart1:
  li   s1, L0
  li   s2, L1
  li   s3, L2
  li   s4, L3
  li   s5, GO
  li   t2, SPIN
2:
  ld   t0, 0(s5)
  bnez t0, 3f
  addi t2, t2, -1
  bnez t2, 2b
  j    hart1_park
3:
  li   t1, C0
  li   t3, C1
  li   t4, C2
  li   t5, C3
  sd   t1, 0(s1)
  sd   t3, 0(s2)
  sd   t4, 0(s3)
  sd   t5, 0(s4)
  fence rw, rw
hart1_park:
4: j 4b

fail0:
  li   a0, 9
  j    report
fail1:
  li   a0, 11
  j    report
fail2:
  li   a0, 13
  j    report
fail3:
  li   a0, 15
report:
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
5: j 5b

trap_vec:
  csrr a0, mcause
  andi a0, a0, 0xff
  slli a0, a0, 1
  ori  a0, a0, 1
  addi a0, a0, 32
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
6: j 6b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
