# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Cross-core coherence with PROVEN residency and an idle observer.
#
# mc_shared_line_quiet.S shows an idle hart still observing a remote write, but
# its verdict rests on an assumption: that hart 0's load actually ALLOCATED the
# cache line. (Do not begin a comment with "# line" here — the assembler's
# preprocessor reads it as a #line directive and fails the build.) If this
# D-cache never held the line, that test — and the polling one — would pass
# vacuously, proving nothing about invalidation.
#
# Why this measures MISSES and not TIME. Two timing attempts failed, and the way
# they failed is the reason for the present shape:
#   * a single csrr/ld/csrr window costs 16 cycles whether or not the line is
#     resident, because csrr is serialising and its overhead swamps the
#     difference (measured: first 16, reload 16);
#   * amortised over 64 loads, the same line costs 793 cycles and 64 DISTINCT
#     never-touched lines — guaranteed misses — cost 779. Identical, with the
#     all-miss loop marginally cheaper. On this model a miss costs no more than a
#     hit, so timing has no resolution here at all.
# That second result is why a guessed threshold would have been worthless: it
# would have "proved" residency or refuted it purely by choice of constant.
#
# So residency is now read from the architecture: mhpmevent 2 in the legacy group
# is "L1 D-Cache misses" (core/perf_counters.sv). The same-line loop should show
# almost no misses if the line is resident.
#
# The counter is itself validated before it is believed, which is the point of
# the distinct-line loop: those REPS loads are guaranteed misses, so the counter
# MUST report about REPS of them. If it reports far fewer, the event is not wired
# on this configuration and the run says so (code 15) instead of mistaking a dead
# counter for a resident line.
#
# Order matters: the distinct-line baseline runs AFTER the coherence check,
# because it walks 64 lines and would evict LINE (set 0 is inside its range).
#
# Fail codes: 5 READY timeout, 9 STALE LINE, 11 initial read was not SEED,
# 13 NOT RESIDENT (same-line loop missed too often — coherence result is void),
# 15 COUNTER NOT WIRED (the guaranteed-miss loop did not register misses).
# Codes 13 and 15 carry their measurements: a0 = same<<18 | base<<4 | code.
# Trap: 32+((mcause<<1)|1).
#
# Needs NrCores=2. Not OpenSBI, not a cookie test.

  .equ LINE,     0x80090000
  .equ READY,    0x80090100
  .equ GO2,      0x80090400
  .equ BASE,     0x800A0000     # 64 never-touched lines for the miss baseline
  .equ SEED,     0x11
  .equ COOKIE,   0x22
  .equ SPIN_TO,  20000
  .equ D0,       60000
  .equ REPS,     64
  .equ MISS_MIN, 32             # baseline must show at least this many misses
  .equ HIT_MAX,  16             # resident line may miss at most this often

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap_vec
  csrw mtvec, t1
  bnez t0, hart1

  # ---- hart 0: the measuring, then quiet, observer ----
  csrw 0x320, zero              # mcountinhibit = 0, let the counters run
  li   t0, 2                    # legacy group, index 2 = L1 D-Cache misses
  csrw 0x323, t0                # mhpmevent3

  li   s1, LINE
  li   s4, READY
  li   s5, GO2
  sd   zero, 0(s4)
  sd   zero, 0(s5)
  fence rw, rw

  li   t2, SPIN_TO
1:
  ld   t1, 0(s4)
  bnez t1, 2f
  addi t2, t2, -1
  bnez t2, 1b
  j    fail_ready
2:
  fence rw, rw
  ld   t0, 0(s1)                # first touch; allocates if the cache allocates
  li   t1, SEED
  bne  t0, t1, fail_seed

  # Same-line loop: REPS loads of one line. Few misses => resident.
  li   t2, REPS
  csrr s6, 0xB03                # mhpmcounter3
3:
  ld   t0, 0(s1)
  and  t3, t0, t0               # consume, so the access really happens
  addi t2, t2, -1
  bnez t2, 3b
  csrr s7, 0xB03
  sub  s7, s7, s6               # s7 = misses over the same-line loop

  li   t1, 1
  sd   t1, 0(s5)                # GO2: hart 1 overwrites LINE
  fence rw, rw

  # Quiet window: registers only. No load, store or fence, so this hart's cache
  # produces no read response for an invalidation to ride on.
  li   t2, D0
4:
  addi t2, t2, -1
  bnez t2, 4b

  ld   t0, 0(s1)                # the observation under test
  li   t1, COOKIE
  bne  t0, t1, fail_stale

  # Baseline: identical loop over REPS distinct, never-touched lines. Every
  # iteration must miss, so this both calibrates the comparison and proves the
  # counter is alive.
  # The walk order is SHUFFLED, and that is essential. A sequential BASE+i*64 walk
  # is the ideal case for a stride prefetcher, and hpdcache excludes prefetch-driven
  # allocations from this very event (`evt_cache_read_miss_o =
  # ~st2_mshr_alloc_is_prefetch_i`, hpdcache_ctrl_pe.sv). A sequential baseline
  # therefore reports ~0 misses on a perfectly healthy counter — which is exactly
  # what it did, and it nearly cost a false "the PMU event is dead" defect report.
  # Stepping by 37 lines (mod 64) visits the same 64 lines with no constant delta.
  li   s10, 0                   # shuffled line index
  li   t2, REPS
  csrr s8, 0xB03
5:
  slli s9, s10, 6               # index -> byte offset
  li   t5, BASE
  add  s9, s9, t5
  ld   t0, 0(s9)
  and  t3, t0, t0
  addi s10, s10, 37             # co-prime with 64: visits every line, no fixed stride
  andi s10, s10, 63
  addi t2, t2, -1
  bnez t2, 5b
  csrr t6, 0xB03
  sub  s8, t6, s8               # s8 = misses over the distinct-line loop

  li   t4, MISS_MIN
  bltu s8, t4, fail_nocounter   # counter dead or event unwired: believe nothing

  li   t4, HIT_MAX
  bgeu s7, t4, fail_noresident  # resident lines do not miss on every access

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
6: j 6b

  # ---- hart 1 ----
hart1:
  li   s1, LINE
  li   s4, READY
  li   s5, GO2
  li   t1, SEED
  sd   t1, 0(s1)
  fence rw, rw
  li   t1, 1
  sd   t1, 0(s4)
  fence rw, rw

  li   t2, SPIN_TO
7:
  ld   t1, 0(s5)
  bnez t1, 8f
  addi t2, t2, -1
  bnez t2, 7b
  j    hart1_park
8:
  li   t1, COOKIE
  sd   t1, 0(s1)                # remote write while hart 0 is silent
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
fail_noresident:
  li   a0, 13
  j    fail_measured
fail_nocounter:
  li   a0, 15
fail_measured:
  # Carry both measurements out with the code so a failure is diagnosable:
  # a0 = same<<18 | base<<4 | code. The harness prints tohost>>1.
  slli t5, s7, 18
  or   a0, a0, t5
  slli t5, s8, 4
  or   a0, a0, t5
fail_store:
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
9: j 9b

trap_vec:
  csrr a0, mcause
  andi a0, a0, 0xff
  slli a0, a0, 1
  ori  a0, a0, 1
  addi a0, a0, 32
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
10: j 10b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
