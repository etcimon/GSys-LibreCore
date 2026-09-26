# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Cross-core coherence of a CACHEABLE shared line.
#
# Why this test exists: nothing in the tree covered it. The other mc_* tests are
# single-hart programs run under a multi-core configuration (mc_cas_lock_handoff
# CASes its own stack), and ai_dual_core_excl_smoke touches its shared line only
# through lr.d/sc.d — the UNCACHED path. So a dropped cacheable invalidation was
# invisible to the whole suite.
#
# IMPORTANT (v2): hart 0 must never write LINE. The first version had hart 0
# store SEED and read it back to "confirm" it had cached the line, but HPDcache
# can satisfy that load from the WRITE BUFFER without allocating a cache line —
# so the check meant to prove the line was cached is what allowed it not to be,
# and the test passed on a design whose invalidation path was under suspicion.
# Here hart 1 initialises LINE, so hart 0's load is a genuine miss-and-fill.
#
# Sequence:
#   h0: GO=1                      ask hart 1 to publish SEED
#   h1: LINE=SEED, READY=1
#   h0: spin READY, ld LINE       must be SEED — this fills hart 0's cache line
#   h0: GO2=1                     ask hart 1 to overwrite
#   h1: LINE=COOKIE, FLAG=1
#   h0: spin FLAG, ld LINE        must be COOKIE, else hart 0 kept a stale copy
#
# Every control word is on its own line (>= 64 B apart) so hart 0's spin loads
# can never refill LINE as a side effect. The only thing that can make hart 0
# observe COOKIE is invalidation of its cached copy.
#
# Fail codes: 5 READY timeout, 6 FLAG timeout, 9 STALE LINE (the defect),
# 11 initial read was not SEED (setup broken — not a coherence result).
# Trap: 32+((mcause<<1)|1).
#
# Needs NrCores=2. Not OpenSBI, not a cookie test.
#
# PEER_HART selects the publishing hart (default 1). With SMT2 cores the hart
# ids are core*NrHarts+thread, so PEER_HART=2 puts the publisher on the second
# physical core; hart 1 would share hart 0's L1 and never exercise the hub.
# Every other hart parks. g6lc_cluster clock-gates the secondary cores of a
# multi-core SMT configuration until they receive an IPI (or 200000 cycles
# pass), so when the publisher lives on another core hart 0 releases it by
# writing its CLINT msip word before waiting; MIE is clear at reset, so the
# pending software interrupt never traps.
#ifndef PEER_HART
#define PEER_HART 1
#endif
  .equ CLINT_MSIP, 0x02000000

  .equ LINE,     0x80090000
  .equ READY,    0x80090100
  .equ FLAG,     0x80090200
  .equ GO,       0x80090300
  .equ GO2,      0x80090400
  .equ SEED,     0x11
  .equ COOKIE,   0x22
# Simulation-sized bound. 2000000 iterations is ~20M cycles and did not finish
# within 900s of wall time on the stream8 model, which made a failure
# indistinguishable from a hang.
  .equ SPIN_TO,  20000

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap_vec
  csrw mtvec, t1
  li   t1, PEER_HART
  beq  t0, t1, hart1
  bnez t0, hart1_park

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
#if PEER_HART > 1
  li   t0, CLINT_MSIP
  sw   t1, (4 * PEER_HART)(t0)  # release the publisher's core from boot hold
#endif

  li   t2, SPIN_TO
1:
  ld   t1, 0(s4)                # spin on READY (its own line)
  bnez t1, 2f
  addi t2, t2, -1
  bnez t2, 1b
  j    fail_ready
2:
  fence rw, rw
  ld   t0, 0(s1)                # genuine miss: hart 0 never wrote LINE
  li   t1, SEED
  bne  t0, t1, fail_seed        # setup failure, not a coherence verdict

  li   t1, 1
  sd   t1, 0(s5)                # GO2: hart 1 overwrites LINE
  fence rw, rw

  li   t2, SPIN_TO
3:
  ld   t1, 0(s2)                # spin on FLAG (its own line)
  bnez t1, 4f
  addi t2, t2, -1
  bnez t2, 3b
  j    fail_flag
4:
  # FLAG was written after LINE with a fence between, so a coherent machine that
  # observes FLAG must observe the new LINE.
  fence rw, rw
  ld   t0, 0(s1)
  li   t1, COOKIE
  bne  t0, t1, fail_stale

#ifdef ORACLE_NEGATIVE
  li   a0, 3
#else
  li   a0, 1
#endif
  la   t0, tohost
  sw   a0, 0(t0)
5: j 5b

  # ---- hart 1 ----
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
  sd   t1, 0(s1)                # remote write to the line hart 0 has cached
  fence rw, rw
  li   t1, 1
  sd   t1, 0(s2)                # FLAG
  fence rw, rw
hart1_park:
  wfi
  j    hart1_park

fail_ready:
  li   a0, 5
  j    fail_store
fail_flag:
  li   a0, 6
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
