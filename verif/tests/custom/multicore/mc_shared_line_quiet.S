# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Cross-core coherence with a QUIET observer — the decisive variant.
#
# mc_shared_line_coherence.S passes, but it cannot distinguish two very
# different designs, because hart 0 POLLS a flag while it waits. Polling
# generates its own memory traffic, and in HPDcache an external invalidation is
# only sampled while a memory read response is present
# (`if (mem_resp_read_valid_i)` in hpdcache.sv's demux, fed by the AXI arbiter's
# `mem_resp_read_valid_arb[1]`, which is asserted only for real read responses).
# So a polling observer may be rescuing the invalidation with its own refills.
#
# This file is deliberately mc_shared_line_coherence.S with EXACTLY ONE change:
# hart 0's final FLAG poll is replaced by a register-only wait. Every handshake
# that is known to work is kept verbatim, and hart 1 is untouched (it still sets
# FLAG; hart 0 simply never looks at it). Two earlier from-scratch attempts at a
# quiet observer both ended in harness cycle timeouts rather than a verdict, so
# this version bisects from the known-good program instead of rewriting it.
#
# The property under test: during hart 0's quiet window it issues no load, store
# or fence, so its cache produces no read responses. If an invalidation can be
# lost when the observer is idle, hart 0 reads the stale value here and fails
# with code 9 where the polling version passes.
#
# Fail codes: 5 READY timeout, 9 STALE LINE, 11 initial read was not SEED.
# Trap: 32+((mcause<<1)|1).
#
# Needs NrCores=2. Not OpenSBI, not a cookie test.

  .equ LINE,     0x80090000
  .equ READY,    0x80090100
  .equ FLAG,     0x80090200
  .equ GO,       0x80090300
  .equ GO2,      0x80090400
  .equ SEED,     0x11
  .equ COOKIE,   0x22
  .equ SPIN_TO,  20000
  .equ D0,       60000           # hart 0 quiet window, register-only

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap_vec
  csrw mtvec, t1
  bnez t0, hart1

  # ---- hart 0 ----
  li   s1, LINE
  li   s4, READY
  li   s2, FLAG
  li   s3, GO
  li   s5, GO2
  sd   zero, 0(s4)
  sd   zero, 0(s2)
  sd   zero, 0(s3)
  sd   zero, 0(s5)
  fence rw, rw

  li   t1, 1
  sd   t1, 0(s3)                # GO: hart 1 publishes SEED
  fence rw, rw

  li   t2, SPIN_TO
1:
  ld   t1, 0(s4)                # spin on READY (its own line)
  bnez t1, 2f
  addi t2, t2, -1
  bnez t2, 1b
  j    fail_ready
2:
  fence rw, rw
  ld   t0, 0(s1)                # genuine fill: hart 0 never writes LINE
  li   t1, SEED
  bne  t0, t1, fail_seed

  li   t1, 1
  sd   t1, 0(s5)                # GO2: hart 1 overwrites LINE
  fence rw, rw

  # THE ONE CHANGE from mc_shared_line_coherence.S: instead of polling FLAG,
  # wait in registers. No load, no store, no fence — so this hart's cache
  # produces no read response for an invalidation to ride on.
  li   t2, D0
3:
  addi t2, t2, -1
  bnez t2, 3b

  ld   t0, 0(s1)
  li   t1, COOKIE
  bne  t0, t1, fail_stale

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
5: j 5b

  # ---- hart 1: identical to mc_shared_line_coherence.S ----
hart1:
  li   s1, LINE
  li   s3, GO
  li   s4, READY
  li   s5, GO2
  li   s2, FLAG

  li   t2, SPIN_TO
6:
  ld   t1, 0(s3)
  bnez t1, 7f
  addi t2, t2, -1
  bnez t2, 6b
  j    hart1_park
7:
  li   t1, SEED
  sd   t1, 0(s1)                # publish the initial value
  fence rw, rw
  li   t1, 1
  sd   t1, 0(s4)                # READY
  fence rw, rw

  li   t2, SPIN_TO
8:
  ld   t1, 0(s5)
  bnez t1, 9f
  addi t2, t2, -1
  bnez t2, 8b
  j    hart1_park
9:
  li   t1, COOKIE
  sd   t1, 0(s1)                # remote write while hart 0 is silent
  fence rw, rw
  li   t1, 1
  sd   t1, 0(s2)                # FLAG (hart 0 ignores it in this variant)
  fence rw, rw
hart1_park:
  wfi
  j    hart1_park

fail_ready:
  li   a0, 5
  j    fail_store
fail_stale:
  li   a0, 9
  j    fail_store
fail_seed:
  li   a0, 11
  j    fail_store
fail_store:
  la   t0, tohost
  sw   a0, 0(t0)
10: j 10b

trap_vec:
  csrr a0, mcause
  andi a0, a0, 0xff
  slli a0, a0, 1
  ori  a0, a0, 1
  addi a0, a0, 32
  la   t0, tohost
  sw   a0, 0(t0)
11: j 11b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
