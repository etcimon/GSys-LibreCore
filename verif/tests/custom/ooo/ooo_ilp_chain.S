# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Directed stress for multi-issue OoO (works with OoOEn=0 or 1):
#   1. Independent ILP block (4× unrolled ALU) — fills 4 issue ports
#   2. Dependent ADD chain — exercises rename/wakeup/bypass
#   3. Mixed WAW / WAR on arch regs — rename correctness
# Self-checks register results; exits 0 on pass, 1 on fail.

  .globl main
main:
#ifdef PMU_G1
  # M3: publish PMU group-1 in-window deltas to tohost+0x10/+0x18/+0x20
  # (mispredict / rename+ROB backpressure / IQ stall). Off by default.
  csrw 0x320, zero             # mcountinhibit: let the hpm counters run
  li   t0, 0x22
  csrw 0x323, t0               # mhpmevent3 = group 1 idx 2: mispredict
  li   t0, 0x20
  csrw 0x324, t0               # mhpmevent4 = group 1 idx 0: rename/ROB backpr.
  li   t0, 0x21
  csrw 0x325, t0               # mhpmevent5 = group 1 idx 1: IQ / issue stall
  csrr s6, 0xB03
  csrr s7, 0xB04
  csrr s8, 0xB05
#endif
  # ---- 1) Independent ILP (many free registers) ----
  li   t0, 1
  li   t1, 2
  li   t2, 3
  li   t3, 4
  li   t4, 5
  li   t5, 6
  li   t6, 7
  li   a1, 8
  li   a2, 9
  li   a3, 10
  li   a4, 11
  li   a5, 12

  # Unrolled independent adds (no RAW between adjacent ops)
  add  t0, t0, t1      # 3
  add  t2, t2, t3      # 7
  add  t4, t4, t5      # 11
  add  a1, a1, a2      # 17
  add  t0, t0, t2      # 10
  add  t4, t4, a1      # 28
  add  t6, t6, a3      # 17
  add  a4, a4, a5      # 23
  add  t0, t0, t4      # 38
  add  t6, t6, a4      # 40
  add  t0, t0, t6      # 78

  li   a0, 78
  bne  t0, a0, fail

  # ---- 2) Dependent chain (serial RAW) ----
  li   s0, 1
  add  s0, s0, s0      # 2
  add  s0, s0, s0      # 4
  add  s0, s0, s0      # 8
  add  s0, s0, s0      # 16
  add  s0, s0, s0      # 32
  add  s0, s0, s0      # 64
  add  s0, s0, s0      # 128
  li   a0, 128
  bne  s0, a0, fail

  # ---- 3) WAW / WAR pattern ----
  li   s1, 10
  li   s2, 20
  add  s3, s1, s2      # 30  (uses s1,s2)
  add  s1, s3, s2      # 50  (WAW on s1)
  add  s2, s1, s3      # 80  (WAR resolved via rename)
  li   a0, 50
  bne  s1, a0, fail
  li   a0, 80
  bne  s2, a0, fail
  li   a0, 30
  bne  s3, a0, fail

  # ---- 4) Multi-iteration ILP loop ----
  li   s4, 0
  li   s5, 64
1:
  add  s4, s4, s0      # +=128 each iter
  addi s5, s5, -1
  bnez s5, 1b
  # 64 * 128 = 8192
  li   a0, 8192
  bne  s4, a0, fail

#ifdef PMU_G1
  csrr t0, 0xB03
  sub  s6, t0, s6
  csrr t0, 0xB04
  sub  s7, t0, s7
  csrr t0, 0xB05
  sub  s8, t0, s8
  la   t0, tohost
  sd   s6, 0x10(t0)            # pmu_out0: mispredict delta
  sd   s7, 0x18(t0)            # pmu_out1: rename/ROB backpressure delta
  sd   s8, 0x20(t0)            # pmu_out2: IQ/issue-stall delta
#endif
  li   a0, 0
  jal  exit

fail:
  li   a0, 1
  jal  exit
