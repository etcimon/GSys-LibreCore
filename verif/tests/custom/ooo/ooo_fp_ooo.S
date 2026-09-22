# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Staged FP probes for the out-of-order FP SKU (g6lc64_ooo, single hart).
# Each stage isolates one FP behaviour that only exists once FP ops issue and
# complete out of program order; ooo_fp_rename.S covers the register-class
# split itself and runs unchanged on both backends.
#
#   -DSTAGE=1  cancelled long-latency FP op under a mispredicted branch: the
#              wrong-path fdiv/fsqrt result must never reach the correct-path
#              owner of the same destination (FPU owner tables, TID reuse)
#   -DSTAGE=2  fflags are accumulated in COMMIT order: a csrr between an older
#              slow flag-setter and a younger fast one sees only the older flags
#   -DSTAGE=3  rs3 of an FMA waits on a long-latency producer (fdiv)
#   -DSTAGE=4  FP store whose ADDRESS is late with a younger fld of the same
#              address: bypass, alias validation and replay on the FP class
#   -DSTAGE=5  mstatus.FS=Off: an FP op traps illegal (cause 2) precisely,
#              younger issued work is discarded, FP state re-enabled afterwards
#   -DSTAGE=6  fmv.x.d / fmv.d.x cross-class moves interleaved with integer work
#   -DSTAGE=7  NV flag from fcvt.w.d on NaN with an integer consumer of the
#              converted value in the same window
#   -DSTAGE=8  FP store whose DATA is late (fdiv) with a younger fld of the
#              same address: store-to-load ordering on FP data
#   -DSTAGE=9  scoreboard-slot reuse under a cancelled divide: a fast
#              correct path allocates past the window so a stale result that
#              escapes FPU ownership lands on a live owner
#   -DSTAGE=10 as 9, with the branch brought to the commit head first so the
#              cancelled divide is dropped at once and its slot is reused
#              (integer owners) while the divide is still in flight
#
# Exit codes: 0 pass; 1..10 the stage's own check failed; 15 an unexpected
# trap in stage 5.
# -DFP_NEGATIVE inverts the stage's final comparison so the harness can prove
# the check is live (expected tohost != 0).

#ifndef STAGE
#define STAGE 1
#endif

  .globl main
main:
  addi sp, sp, -64
#if STAGE != 11
  # Enable the FPU: mstatus.FS = Initial(01).
  li   t0, 0x00002000
  csrs mstatus, t0
  # Constants.
  li   t0, 1
  fcvt.d.w f1, t0            # 1.0
  li   t0, 2
  fcvt.d.w f2, t0            # 2.0
  li   t0, 3
  fcvt.d.w f3, t0            # 3.0
  fmv.d.x f0, zero           # 0.0
#endif

#if STAGE == 1
  # A data-dependent branch driven by an LCG bit the predictor cannot learn
  # quickly. BOTH paths produce f20 with a long-latency divide of different
  # value and consume it at once: whichever way the predictor guesses wrongly,
  # a cancelled divide is in the FPU while the correct path's divide into the
  # same destination reuses its scoreboard slot and its consumer waits. A
  # stale cancelled result that escapes ownership wakes that consumer with
  # the other path's value; the fsqrt adds a second cancelled long op.
  li   t0, 12
  fcvt.d.w f4, t0              # 12.0
  li   s0, 0x9E3779B97F4A7C15   # LCG state
  li   s1, 64                   # iterations
  li   s2, 0                    # fall-through count, the reference
  li   s3, 0                    # accumulated correct results
1:
  li   t1, 0x2545F4914F6CDD1D
  mul  s0, s0, t1
  addi s0, s0, 1
  srli t2, s0, 40
  andi t2, t2, 1
  beqz t2, 2f
  # fall-through path
  fdiv.d f20, f4, f2           # 6.0
  fsqrt.d f21, f4              # 3.46..., cancelled when this path is wrong
  addi s2, s2, 1
  j    3f
2:
  # branch path
  fdiv.d f20, f3, f2           # 1.5
  fsqrt.d f21, f3              # 1.73..., cancelled when this path is wrong
3:
  fcvt.w.d t3, f20, rtz        # 6 on the fall-through path, 1 on the branch path
  add  s3, s3, t3
  addi s1, s1, -1
  bnez s1, 1b
  # Expected sum: fallthrough*6 + (64-fallthrough)*1 = 64 + 5*fallthrough
  slli t4, s2, 2
  add  t4, t4, s2
  addi t4, t4, 64
#ifdef FP_NEGATIVE
  addi t4, t4, 1
#endif
  bne  s3, t4, fail1

#elif STAGE == 2
  csrw fflags, zero
  fdiv.d f10, f1, f0           # 1/0 -> DZ (8), long latency
  csrr t1, fflags              # program order: only DZ may be visible
  li   t0, 0x7FEFFFFFFFFFFFFF
  fmv.d.x f11, t0              # DBL_MAX
  fadd.d f12, f11, f11         # overflow -> OF|NX (4|1), fast, completes first
  csrr t2, fflags              # both retired: 8|4|1 = 13
  li   a0, 8
  bne  t1, a0, fail2
  li   a0, 13
#ifdef FP_NEGATIVE
  li   a0, 12
#endif
  bne  t2, a0, fail2

#elif STAGE == 3
  li   t0, 7
  fcvt.d.w f4, t0              # 7.0
  fdiv.d f6, f4, f1            # 7.0, long latency: rs3 producer
  fmadd.d f7, f2, f3, f6       # 2*3 + 7 = 13.0, waits on f6 through rs3
  fmadd.d f8, f7, f1, f6       # 13*1 + 7 = 20.0, rs1 and rs3 both renamed
  fcvt.w.d t1, f8, rtz
  li   a0, 20
#ifdef FP_NEGATIVE
  li   a0, 21
#endif
  bne  t1, a0, fail3

#elif STAGE == 4
  # The FP store's ADDRESS is late (a divide feeds its base), its data is
  # ready: the younger fld to the same address issues past the unresolved
  # store, reads the committed 42.0 from memory, and must be replayed when
  # the store's address resolves to the same bytes (mirror of ooo_mem_min
  # stage 35 on the FP register class).
  la   t0, fp_scratch
  li   t1, 0x4045000000000000     # 42.0 as bits
  sd   t1, 0(t0)                  # committed 42.0 at [0]
  li   t3, 7
  mul  t4, t0, t3
  divu t5, t4, t3                 # t5 = t0, ~40 cycles late
  fsd  f3, 0(t5)                  # 3.0 to fp_scratch, address late
  fld  f10, 0(t0)                 # younger load of the same address
  fcvt.w.d t2, f10, rtz
  li   a0, 3
#ifdef FP_NEGATIVE
  li   a0, 42
#endif
  bne  t2, a0, fail4

#elif STAGE == 8
  # The FP store's DATA is late (fdiv), its address is ready: the younger fld
  # must observe the store's value whichever way the LSQ orders them.
  la   t0, fp_scratch
  li   t1, 0x4045000000000000     # 42.0 as bits
  sd   t1, 0(t0)                  # committed 42.0 at [0]
  fdiv.d f9, f3, f1               # 3.0, late data for the store below
  fsd  f9, 0(t0)
  fld  f10, 0(t0)
  fcvt.w.d t2, f10, rtz
  li   a0, 3
#ifdef FP_NEGATIVE
  li   a0, 42
#endif
  bne  t2, a0, fail8

#elif STAGE == 5
  la   t0, trap_vec
  csrw mtvec, t0
  li   s4, 0                      # trap counter
  li   s5, 0                      # sentinel written by younger wrong work
  li   t0, 0x00006000
  csrc mstatus, t0                # FS = Off
  la   s6, fp_trap_pc             # expected mepc
fp_trap_pc:
  fadd.d f4, f1, f2               # must trap: illegal instruction
  li   s5, 1                      # younger than the trapping op: must never retire
resume5:
  li   a0, 1
  bne  s4, a0, fail5              # exactly one trap
  bnez s5, fail5                  # the handler resumed past the li, so a visible
                                  # s5=1 means younger work retired before the trap
  li   a0, 2
#ifdef FP_NEGATIVE
  li   a0, 3
#endif
  bne  s7, a0, fail5              # handler ran with the precise mepc
  fadd.d f4, f1, f2               # FS back on: 3.0
  fcvt.w.d t1, f4, rtz
  li   a0, 3
  bne  t1, a0, fail5

#elif STAGE == 6
  li   s0, 0x400921FB54442D18     # pi bits
  fmv.d.x f5, s0
  addi s1, s0, 1
  fmv.x.d t1, f5
  fadd.d f6, f5, f0               # pi + 0
  fmv.x.d t2, f6
  bne  t1, s0, fail6
  bne  t2, s0, fail6
  addi t3, s1, -1
#ifdef FP_NEGATIVE
  addi t3, t3, 1
#endif
  bne  t3, s0, fail6

#elif STAGE == 7
  csrw fflags, zero
  li   t0, 0x7FF8000000000000     # canonical qNaN
  fmv.d.x f5, t0
  fcvt.w.d t1, f5, rtz            # NV, result 0x7FFFFFFF
  addi t2, t1, 1                  # integer consumer of the converted value
  csrr t3, fflags
  li   a0, 0x80000000
  bne  t2, a0, fail7
  li   a0, 16
#ifdef FP_NEGATIVE
  li   a0, 17
#endif
  bne  t3, a0, fail7
#elif STAGE == 9
  # Scoreboard-slot REUSE under a cancelled divide. A cancelled entry is
  # dropped when it reaches the commit head and its slot is reallocated
  # NrScoreboardEntries allocations later, so the correct path here allocates
  # fast: 24 independent FP adds into distinct registers plus the loop
  # bookkeeping, more than the 32-entry window, all of them consumed at the
  # end of the iteration. A stale wrong-path fdiv/fsqrt result that escapes
  # FPU ownership lands on whichever live entry now owns its tag and corrupts
  # that destination; the per-iteration sum then misses 120.
  li   s0, 0x9E3779B97F4A7C15
  li   s1, 64
  li   s3, 0
  li   t0, 5
  fcvt.d.w f10, t0
  fmv.d f11, f10
  fmv.d f12, f10
  fmv.d f13, f10
  fmv.d f14, f10
  fmv.d f15, f10
  fmv.d f16, f10
  fmv.d f17, f10
  fmv.d f18, f10
  fmv.d f19, f10
  fmv.d f20, f10
  fmv.d f21, f10
  fmv.d f22, f10
  fmv.d f23, f10
  fmv.d f24, f10
  fmv.d f25, f10
  fmv.d f26, f10
  fmv.d f27, f10
  fmv.d f28, f10
  fmv.d f29, f10
  fmv.d f30, f10
  fmv.d f31, f10
  fmv.d f8, f10
  fmv.d f9, f10
1:
  li   t1, 0x2545F4914F6CDD1D
  mul  s0, s0, t1
  addi s0, s0, 1
  srli t2, s0, 40
  andi t2, t2, 1
  beqz t2, 2f
  # fall-through path: 24 independent producers, 2.0 + 3.0 each
  fadd.d f10, f2, f3
  fadd.d f11, f2, f3
  fadd.d f12, f2, f3
  fadd.d f13, f2, f3
  fadd.d f14, f2, f3
  fadd.d f15, f2, f3
  fadd.d f16, f2, f3
  fadd.d f17, f2, f3
  fadd.d f18, f2, f3
  fadd.d f19, f2, f3
  fadd.d f20, f2, f3
  fadd.d f21, f2, f3
  fadd.d f22, f2, f3
  fadd.d f23, f2, f3
  fadd.d f24, f2, f3
  fadd.d f25, f2, f3
  fadd.d f26, f2, f3
  fadd.d f27, f2, f3
  fadd.d f28, f2, f3
  fadd.d f29, f2, f3
  fadd.d f30, f2, f3
  fadd.d f31, f2, f3
  fadd.d f8, f2, f3
  fadd.d f9, f2, f3
  j    3f
2:
  # branch path: long-latency wrong-path candidates writing two of the
  # registers the other path produces
  fdiv.d f20, f3, f2           # 1.5
  fsqrt.d f21, f3              # 1.73...
  fadd.d f20, f2, f3           # restore 5.0 on the correct branch path
  fadd.d f21, f2, f3
3:
  # consume every register: sum must be 24 * 5 = 120 each iteration
  fadd.d f4, f10, f11
  fadd.d f5, f12, f13
  fadd.d f6, f14, f15
  fadd.d f7, f16, f17
  fadd.d f4, f4, f5
  fadd.d f6, f6, f7
  fadd.d f4, f4, f6
  fadd.d f5, f18, f19
  fadd.d f6, f20, f21
  fadd.d f7, f22, f23
  fadd.d f5, f5, f6
  fadd.d f4, f4, f7
  fadd.d f4, f4, f5
  fadd.d f5, f24, f25
  fadd.d f6, f26, f27
  fadd.d f7, f28, f29
  fadd.d f5, f5, f6
  fadd.d f4, f4, f7
  fadd.d f4, f4, f5
  fadd.d f5, f30, f31
  fadd.d f6, f8, f9
  fadd.d f5, f5, f6
  fadd.d f4, f4, f5
  fcvt.w.d t3, f4, rtz
  add  s3, s3, t3
  addi s1, s1, -1
  bnez s1, 1b
  li   t4, 7680                 # 64 * 120
#ifdef FP_NEGATIVE
  addi t4, t4, 1
#endif
  bne  s3, t4, fail9

#elif STAGE == 10
  # Slot reuse while a cancelled divide is still in flight. The cancelled
  # entry's `cancelled` flag is sticky until it is dropped at the commit head,
  # so the branch is brought to the head first (fence drains everything older);
  # the wrong-path fdiv/fsqrt then sit directly behind it, are dropped within a
  # cycle of the resolve, and the correct path allocates 64 independent integer
  # adds (16 registers x 4 rounds) at full rate so their scoreboard slots are
  # reused and reused again while the divide (~20-35 cycles) is still in the
  # FPU. A stale result that escapes ownership lands on a live integer owner
  # and its register misses the final count.
  li   s0, 0x9E3779B97F4A7C15
  li   s1, 64
  li   a2, 0
  li   a3, 0
  li   a4, 0
  li   a5, 0
  li   a6, 0
  li   a7, 0
  li   s4, 0
  li   s5, 0
  li   s6, 0
  li   s7, 0
  li   s8, 0
  li   s9, 0
  li   s10, 0
  li   s11, 0
  li   t5, 0
  li   t6, 0
1:
  fence
  li   t1, 0x2545F4914F6CDD1D
  mul  s0, s0, t1
  addi s0, s0, 1
  srli t2, s0, 40
  andi t2, t2, 1
  beqz t2, 2f
  j    3f
2:
  fdiv.d f20, f3, f2           # cancelled when "taken" was the wrong guess
  fsqrt.d f21, f3
3:
  addi a2, a2, 1
  addi a3, a3, 1
  addi a4, a4, 1
  addi a5, a5, 1
  addi a6, a6, 1
  addi a7, a7, 1
  addi s4, s4, 1
  addi s5, s5, 1
  addi s6, s6, 1
  addi s7, s7, 1
  addi s8, s8, 1
  addi s9, s9, 1
  addi s10, s10, 1
  addi s11, s11, 1
  addi t5, t5, 1
  addi t6, t6, 1
  addi a2, a2, 1
  addi a3, a3, 1
  addi a4, a4, 1
  addi a5, a5, 1
  addi a6, a6, 1
  addi a7, a7, 1
  addi s4, s4, 1
  addi s5, s5, 1
  addi s6, s6, 1
  addi s7, s7, 1
  addi s8, s8, 1
  addi s9, s9, 1
  addi s10, s10, 1
  addi s11, s11, 1
  addi t5, t5, 1
  addi t6, t6, 1
  addi a2, a2, 1
  addi a3, a3, 1
  addi a4, a4, 1
  addi a5, a5, 1
  addi a6, a6, 1
  addi a7, a7, 1
  addi s4, s4, 1
  addi s5, s5, 1
  addi s6, s6, 1
  addi s7, s7, 1
  addi s8, s8, 1
  addi s9, s9, 1
  addi s10, s10, 1
  addi s11, s11, 1
  addi t5, t5, 1
  addi t6, t6, 1
  addi a2, a2, 1
  addi a3, a3, 1
  addi a4, a4, 1
  addi a5, a5, 1
  addi a6, a6, 1
  addi a7, a7, 1
  addi s4, s4, 1
  addi s5, s5, 1
  addi s6, s6, 1
  addi s7, s7, 1
  addi s8, s8, 1
  addi s9, s9, 1
  addi s10, s10, 1
  addi s11, s11, 1
  addi t5, t5, 1
  addi t6, t6, 1
  addi s1, s1, -1
  bnez s1, 1b
  # every register counted 4 per iteration: 16 * 256 = 4096
  add  t3, a2, a3
  add  t3, t3, a4
  add  t3, t3, a5
  add  t3, t3, a6
  add  t3, t3, a7
  add  t3, t3, s4
  add  t3, t3, s5
  add  t3, t3, s6
  add  t3, t3, s7
  add  t3, t3, s8
  add  t3, t3, s9
  add  t3, t3, s10
  add  t3, t3, s11
  add  t3, t3, t5
  add  t3, t3, t6
  li   t4, 4096
#ifdef FP_NEGATIVE
  addi t4, t4, 1
#endif
  bne  t3, t4, fail10
  # and the divide itself, when it was the correct path, produced 1.5 -> 1
  fcvt.w.d t3, f20, rtz
  li   t4, 1
  bne  t3, t4, fail10

#elif STAGE == 11
  # Integer twin of stage 10 (no FP anywhere): the same fence / LCG branch /
  # wrong-path long divide / 64 fast adds shape with divu in place of fdiv, so
  # it runs on integer-only and in-order models. It exists to partition a
  # fetch-side loss of a committer-path window (seen first in stage 10) from
  # the FP backend.
  li   s0, 0x9E3779B97F4A7C15
  li   s1, 64
  li   a2, 0
  li   a3, 0
  li   a4, 0
  li   a5, 0
  li   a6, 0
  li   a7, 0
  li   s4, 0
  li   s5, 0
  li   s6, 0
  li   s7, 0
  li   s8, 0
  li   s9, 0
  li   s10, 0
  li   s11, 0
  li   t5, 0
  li   t6, 0
  li   t0, 3
  li   t3, 0
1:
  fence
  li   t1, 0x2545F4914F6CDD1D
  mul  s0, s0, t1
  addi s0, s0, 1
  srli t2, s0, 40
  andi t2, t2, 1
  beqz t2, 2f
  j    3f
2:
  divu t3, t1, t0              # long-latency wrong-path candidate
  remu t4, t1, t0
3:
  addi a2, a2, 1
  addi a3, a3, 1
  addi a4, a4, 1
  addi a5, a5, 1
  addi a6, a6, 1
  addi a7, a7, 1
  addi s4, s4, 1
  addi s5, s5, 1
  addi s6, s6, 1
  addi s7, s7, 1
  addi s8, s8, 1
  addi s9, s9, 1
  addi s10, s10, 1
  addi s11, s11, 1
  addi t5, t5, 1
  addi t6, t6, 1
  addi a2, a2, 1
  addi a3, a3, 1
  addi a4, a4, 1
  addi a5, a5, 1
  addi a6, a6, 1
  addi a7, a7, 1
  addi s4, s4, 1
  addi s5, s5, 1
  addi s6, s6, 1
  addi s7, s7, 1
  addi s8, s8, 1
  addi s9, s9, 1
  addi s10, s10, 1
  addi s11, s11, 1
  addi t5, t5, 1
  addi t6, t6, 1
  addi a2, a2, 1
  addi a3, a3, 1
  addi a4, a4, 1
  addi a5, a5, 1
  addi a6, a6, 1
  addi a7, a7, 1
  addi s4, s4, 1
  addi s5, s5, 1
  addi s6, s6, 1
  addi s7, s7, 1
  addi s8, s8, 1
  addi s9, s9, 1
  addi s10, s10, 1
  addi s11, s11, 1
  addi t5, t5, 1
  addi t6, t6, 1
  addi a2, a2, 1
  addi a3, a3, 1
  addi a4, a4, 1
  addi a5, a5, 1
  addi a6, a6, 1
  addi a7, a7, 1
  addi s4, s4, 1
  addi s5, s5, 1
  addi s6, s6, 1
  addi s7, s7, 1
  addi s8, s8, 1
  addi s9, s9, 1
  addi s10, s10, 1
  addi s11, s11, 1
  addi t5, t5, 1
  addi t6, t6, 1
  addi s1, s1, -1
  bnez s1, 1b
  add  t3, a2, a3
  add  t3, t3, a4
  add  t3, t3, a5
  add  t3, t3, a6
  add  t3, t3, a7
  add  t3, t3, s4
  add  t3, t3, s5
  add  t3, t3, s6
  add  t3, t3, s7
  add  t3, t3, s8
  add  t3, t3, s9
  add  t3, t3, s10
  add  t3, t3, s11
  add  t3, t3, t5
  add  t3, t3, t6
  li   t4, 4096
#ifdef FP_NEGATIVE
  addi t4, t4, 1
#endif
  bne  t3, t4, fail11
#else
#error "unknown STAGE"
#endif

  li   a0, 0
  jal  exit

fail1:
  li   a0, 1
  jal  exit
fail2:
  li   a0, 2
  jal  exit
fail3:
  li   a0, 3
  jal  exit
fail4:
  li   a0, 4
  jal  exit
fail5:
  li   a0, 5
  jal  exit
fail6:
  li   a0, 6
  jal  exit
fail7:
  li   a0, 7
  jal  exit
fail8:
  li   a0, 8
  jal  exit
fail9:
  li   a0, 9
  jal  exit
fail10:
  li   a0, 10
  jal  exit
fail11:
  li   a0, 11
  jal  exit

#if STAGE == 5
  .align 2
trap_vec:
  csrr t5, mcause
  li   t6, 2
  bne  t5, t6, trap_bad           # only illegal instruction expected
  csrr t5, mepc
  bne  t5, s6, trap_bad           # precise: mepc is the FP op
  addi s4, s4, 1
  li   s7, 2                      # visible only via the handler
  li   t6, 0x00002000
  csrs mstatus, t6                # FS = Initial again
  la   t5, resume5
  csrw mepc, t5                   # resume past the li s5,1
  mret
trap_bad:
  li   a0, 15
  jal  exit
#endif

  .data
  .align 3
fp_scratch:
  .dword 0
  .dword 0
