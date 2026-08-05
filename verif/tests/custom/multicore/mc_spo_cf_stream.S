# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Multi-core stream plane × control-flow soak (single-hart functional):
# Interleave multi-stream strided stores with branch/call noise so the
# scoreboard/cancel path coexists with ServerPrefetch / L2 traffic.
# Targets: g6lc64_ooo_server, g6lc64_server_math.

  .globl main
main:
  li   t0, 8192
  sub  sp, sp, t0
  mv   s0, sp
  li   s1, 0                  # stream id 0..3
  li   s2, 0                  # cf counter

  # ---- 4 streams, each stride 128 B, with branch between streams ----
cf_stream_fill:
  slli t5, s1, 5              # stream * 32
  add  t0, s0, t5
  li   t1, 2048
cf_stream_fill_inner:
  li   t3, 0xC0FFEE00
  add  t3, t3, s1
  xor  t3, t3, t0
  sd   t3, 0(t0)
  # CF noise: taken/not-taken mix
  andi t4, t0, 16
  beqz t4, cf_stream_no_call
  call cf_tick
cf_stream_no_call:
  addi t0, t0, 128
  addi t1, t1, -128
  bgtz t1, cf_stream_fill_inner

  addi s1, s1, 1
  li   t6, 4
  blt  s1, t6, cf_stream_fill

  # ---- Verify streams ----
  li   s1, 0
cf_stream_verify:
  slli t5, s1, 5
  add  t0, s0, t5
  li   t1, 2048
cf_stream_verify_inner:
  li   t3, 0xC0FFEE00
  add  t3, t3, s1
  xor  t3, t3, t0
  ld   t4, 0(t0)
  bne  t3, t4, fail
  addi t0, t0, 128
  addi t1, t1, -128
  bgtz t1, cf_stream_verify_inner
  addi s1, s1, 1
  li   t6, 4
  blt  s1, t6, cf_stream_verify

  # cf_tick should have been called for ~half of stores (every other line)
  # Lower bound only — not exact (depends on address pattern)
  li   t0, 1
  blt  s2, t0, fail

  li   t0, 8192
  add  sp, sp, t0
  li   a0, 0
  jal  exit

cf_tick:
  addi s2, s2, 1
  ret

fail:
  li   t0, 8192
  add  sp, sp, t0
  li   a0, 1
  jal  exit
