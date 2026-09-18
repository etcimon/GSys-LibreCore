# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Back-pressure on the external-invalidation retention slot.
#
# The repair in cva6_hpdcache_subsystem.sv holds ONE external invalidation and
# reports occupancy through inval_ready_o, so a second invalidation arriving
# while the slot is full must be HELD by the inval bus rather than dropped. That
# was argued from the handshake and not measured; this test measures it.
#
# Why two lines and an idle observer. A single invalidation can be delivered by
# luck if the observer happens to have a read response in flight, and a polling
# observer generates exactly that traffic. So hart 0 caches BOTH lines, then
# waits in a register-only loop with no load, store or fence, which is the case
# that needs the injected response cycle. Hart 1 then writes both lines
# back-to-back, so two invalidations target one core with no cycles to spare. If
# the retention drops the second, hart 0 reads one new value and one stale one —
# which is why the two failure codes are distinct: a single "it failed" verdict
# could not tell a dropped second invalidation from a broken first one.
#
# The addresses sit in different sets (A at set 0, B at set 4 for a 32 KiB
# 4-way) so neither eviction nor a conflict refill can refresh the other copy.
#
# tohost: 1 = both observed (retention holds under back-pressure);
#         9 = A stale (first invalidation lost);
#        11 = B stale (SECOND invalidation lost — the back-pressure case);
#        13 = the initial reads did not see the cleared values (setup failure);
#         5 = handshake timeout;
#        32+((mcause<<1)|1) on a trap.
#
# Needs NrCores >= 2. Requires +debug_disable and +tohost_addr.

  .equ LINE_A,  0x80090000
  .equ LINE_B,  0x80090100
  .equ GO,      0x80090400
  .equ COOK_A,  0x0a0a
  .equ COOK_B,  0x0b0b
  .equ SPIN,    40000
  .equ IDLE,    20000

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap_vec
  csrw mtvec, t1
  bnez t0, hart1

  # ---- hart 0: the observer ----
  li   s1, LINE_A
  li   s2, LINE_B
  li   s3, GO
  sd   zero, 0(s1)
  sd   zero, 0(s2)
  sd   zero, 0(s3)
  fence rw, rw

  # Cache both lines. These loads must MISS and fill, so hart 0 genuinely holds
  # copies that hart 1's writes have to invalidate.
  ld   t0, 0(s1)
  bnez t0, fail_setup
  ld   t0, 0(s2)
  bnez t0, fail_setup

  li   t1, 1
  sd   t1, 0(s3)                # GO: hart 1 may now write both lines
  fence rw, rw

  # Idle window: registers only. No load, store or fence, so this hart's cache
  # produces no read response for an invalidation to ride on.
  li   t2, IDLE
1:
  addi t2, t2, -1
  bnez t2, 1b

  ld   t0, 0(s1)
  li   t1, COOK_A
  bne  t0, t1, fail_a
  ld   t0, 0(s2)
  li   t1, COOK_B
  bne  t0, t1, fail_b

  li   a0, 1
  j    report

  # ---- hart 1: writes both lines back-to-back ----
hart1:
  li   s1, LINE_A
  li   s2, LINE_B
  li   s3, GO
  li   t2, SPIN
2:
  ld   t0, 0(s3)
  bnez t0, 3f
  addi t2, t2, -1
  bnez t2, 2b
  j    hart1_park                # hart 0 will report its own timeout
3:
  li   t1, COOK_A
  li   t3, COOK_B
  # Adjacent stores, deliberately with no fence between them: two invalidations
  # to the same core as close together as the pipeline will issue them.
  sd   t1, 0(s1)
  sd   t3, 0(s2)
  fence rw, rw
hart1_park:
4: j 4b

fail_a:
  li   a0, 9
  j    report
fail_b:
  li   a0, 11
  j    report
fail_setup:
  li   a0, 13
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
