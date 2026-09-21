# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Directed stress for the U6 Phase-5 SPLIT FP register class (works with
# OoOEn=0 or 1). Each block targets a property of the split that a shared or
# absent FP namespace would get wrong:
#
#   1. FP dependency chain      -- FP rename + FP busy table + wakeup
#   2. FMA (rs3)                -- the third source, whose architectural number
#                                  rides in the imm field, and the op_c path
#   3. f0 is an ordinary register -- unlike x0 it is renamed, written and read
#   4. Int/FP same register NUMBER -- x5 and f5 are different registers; a
#                                  shared namespace or a class-blind bypass
#                                  hands one to the other
#   5. FP load/store            -- is_rd_fpr on LOAD, FP value through memory
#   6. FP WAW / WAR             -- repeated writes to one FP register
#
# Integer-only comparisons are used for the checks (fmv.x.d / feq.d), so a
# failure reports through the same exit path as the other directed tests.
# Self-checks results; exits 0 on pass, 1 on fail.

  .globl main
main:
  # Enable the FPU: mstatus.FS = Initial(01). Without this every FP op traps.
  li   t0, 0x00002000
  csrs mstatus, t0

  # ---- 1) FP dependency chain (rename + busy/wakeup) ----
  # Each fadd depends on the previous result, so every one must wait for its
  # producer through the FP busy table rather than reading a stale physical.
  fcvt.d.w f1, x0          # f1 = 0.0
  li   t0, 1
  fcvt.d.w f2, t0          # f2 = 1.0
  fadd.d f3, f2, f2        # 2.0
  fadd.d f3, f3, f2        # 3.0
  fadd.d f3, f3, f3        # 6.0
  fadd.d f3, f3, f2        # 7.0
  fadd.d f3, f3, f3        # 14.0
  fcvt.w.d t1, f3, rtz
  li   a0, 14
  bne  t1, a0, fail1

  # ---- 2) FMA: the rs3 operand ----
  # fmadd.d rd, rs1, rs2, rs3 -> rs3's register number travels in the imm
  # field, so a core that does not rename it reads a stale f-register.
  li   t0, 3
  fcvt.d.w f4, t0          # 3.0
  li   t0, 5
  fcvt.d.w f5, t0          # 5.0
  li   t0, 7
  fcvt.d.w f6, t0          # 7.0
  fmadd.d f7, f4, f5, f6   # 3*5 + 7 = 22.0
  fcvt.w.d t1, f7, rtz
  li   a0, 22
  bne  t1, a0, fail2

  # Chain an FMA onto its own previous result: rs3 is now a renamed producer,
  # not an architectural value that happened to be sitting in the regfile.
  fmadd.d f7, f4, f5, f7   # 3*5 + 22 = 37.0
  fcvt.w.d t1, f7, rtz
  li   a0, 37
  bne  t1, a0, fail2

  # ---- 3) f0 is a real register (x0 is not) ----
  # Writing f0 must stick, and a consumer of f0 must see the written value.
  # A core that carries the integer "rd==0 means no destination" rule into the
  # FP class drops this write and reads whatever f0 held before.
  li   t0, 9
  fcvt.d.w f0, t0          # f0 = 9.0   (legal: f0 is writable)
  fadd.d f8, f0, f2        # 9.0 + 1.0 = 10.0
  fcvt.w.d t1, f8, rtz
  li   a0, 10
  bne  t1, a0, fail3

  # ...and f0 as a renamed producer feeding an FMA's rs3.
  fmadd.d f9, f2, f2, f0   # 1*1 + 9 = 10.0
  fcvt.w.d t1, f9, rtz
  li   a0, 10
  bne  t1, a0, fail3

  # ---- 4) x5 and f5 are DIFFERENT registers ----
  # Same architectural number, different class. A shared rename map, or an
  # intra-group bypass that matches on the number without the class, hands the
  # integer producer's tag to the FP consumer (or vice versa).
  li   t0, 123
  mv   x5, t0              # x5 = 123          (f5 still holds 5.0)
  fcvt.w.d t1, f5, rtz     # must still be 5
  li   a0, 5
  bne  t1, a0, fail4
  li   a0, 123
  bne  x5, a0, fail4        # and x5 must be untouched by the FP traffic

  # Interleave them tightly so both are in flight in the same window.
  li   t0, 50
  fcvt.d.w f5, t0          # f5 = 50.0
  li   x5, 60              # x5 = 60
  fadd.d f5, f5, f2        # f5 = 51.0
  addi x5, x5, 1           # x5 = 61
  fcvt.w.d t1, f5, rtz
  li   a0, 51
  bne  t1, a0, fail4
  li   a0, 61
  bne  x5, a0, fail4

  # ---- 5) FP load / store (is_rd_fpr on LOAD) ----
  la   t0, fp_scratch
  fsd  f7, 0(t0)           # store 37.0
  fld  f10, 0(t0)          # FP load: destination is an f-register
  fcvt.w.d t1, f10, rtz
  li   a0, 37
  bne  t1, a0, fail5

  # Store/load round trip with an FP consumer immediately after, so the load's
  # renamed destination must wake the consumer.
  fsd  f8, 8(t0)           # 10.0
  fld  f11, 8(t0)
  fadd.d f12, f11, f10     # 10 + 37 = 47.0
  fcvt.w.d t1, f12, rtz
  li   a0, 47
  bne  t1, a0, fail5

  # ---- 6) FP WAW / WAR on one architectural register ----
  # Repeated writes to f13 with a reader between them: rename must give each
  # write its own physical register and the reader must see the older value.
  li   t0, 2
  fcvt.d.w f13, t0         # 2.0
  fadd.d f14, f13, f13     # reads the 2.0  -> 4.0
  li   t0, 100
  fcvt.d.w f13, t0         # WAW: f13 = 100.0
  fadd.d f15, f14, f2      # 4.0 + 1.0 = 5.0
  fcvt.w.d t1, f15, rtz
  li   a0, 5
  bne  t1, a0, fail6
  fcvt.w.d t1, f13, rtz
  li   a0, 100
  bne  t1, a0, fail6

  # ---- 7) Longer mixed window ----
  # Independent FP work interleaved with integer work, then joined, so the two
  # classes are allocating from their own pools concurrently.
  li   s2, 0
  li   s3, 20
1:
  fadd.d f16, f2, f2       # independent FP, 2.0 each iteration
  addi s2, s2, 3           # independent integer
  fadd.d f17, f16, f2      # 3.0
  addi s3, s3, -1
  bnez s3, 1b
  li   a0, 60              # 20 * 3
  bne  s2, a0, fail7
  fcvt.w.d t1, f17, rtz
  li   a0, 3
  bne  t1, a0, fail7

#ifdef FP_RECOVERY_CHECK
  li   t0, 17
  fcvt.d.w f0, t0
  li   t0, 23
  fcvt.d.w f18, t0
  fence.i
  fcvt.w.d t1, f0, rtz
  li   a0, 17
  bne  t1, a0, fail8
  fcvt.w.d t1, f18, rtz
  li   a0, 23
  bne  t1, a0, fail8
#endif
#ifdef FP_STATUS_CHECK
  csrw fflags, zero
  li   t0, 1
  fcvt.d.w f1, t0
  fmv.d.x f2, zero
  fdiv.d f3, f1, f2
  csrr t1, fflags
  addi t2, t1, 0
  li   a0, 8
  bne  t2, a0, fail9
  csrw fflags, zero
  csrr t1, fflags
  bnez t1, fail9
#endif

  li   a0, 0
  jal  exit

#ifdef FP_STATUS_CHECK
fail9:
  li   a0, 9
  jal  exit
#endif
#ifdef FP_RECOVERY_CHECK
fail8:
  li   a0, 8
  jal  exit
#endif

# One exit per block. The id is materialised HERE rather than carried in a
# register, because this test hunts register corruption and a corrupted
# carrier would make the verdict misreport which block failed.
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


  .data
  .align 3
fp_scratch:
  .dword 0
  .dword 0
