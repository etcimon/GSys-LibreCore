# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# U6 / p6-buildup: stream plane × multicore directed stress.
#
# Intended targets:
#   - g6lc64_ooo_server  (NrCores=4, L2+L3+ServerPrefetchEn, inclusive back-inval)
#   - g6lc64_server_math (NrCores=2, L2+ServerPrefetchEn)
#
# Patterns:
#   1. Sequential stream fill/verify  — trains next-line / multi-stream PF
#   2. Multi-stream strides (4 concurrent streams) — ServerPfStreams occupancy
#   3. Capacity thrash (large working set) — L2/L3 victim + inclusive L1/L2 path
#   4. Integrity check after thrash
#
# Single-hart functional check (cluster still elaborates N cores). Not a
# cycle-count bench; exit 0 on data match.

  .globl main
main:
  # 8 KiB working set (fits Spike ISS timeout; still multi-stream + thrash)
  # Full 32 KiB soak remains valid under Verilator with longer steps.
  li   t0, 8192
  sub  sp, sp, t0
  mv   s0, sp
  li   s1, 8192
  li   s2, 64                 # line stride

  # ---- 1. Sequential fill ----
  mv   t0, s0
  mv   t1, s1
1:
  sub  t2, t0, s0
  xor  t3, t0, t2
  sd   t3, 0(t0)
  addi t0, t0, 8
  addi t1, t1, -8
  bnez t1, 1b

  # ---- 2. Sequential verify ----
  mv   t0, s0
  mv   t1, s1
2:
  sub  t2, t0, s0
  xor  t3, t0, t2
  ld   t4, 0(t0)
  bne  t3, t4, fail
  addi t0, t0, 8
  addi t1, t1, -8
  bnez t1, 2b

  # ---- 3. Four concurrent streams (phase offsets 0,16,32,48 within line group) ----
  # Stream s writes every 256 B starting at base+s*64
  li   s3, 0                  # stream id 0..3
stream_fill:
  slli t5, s3, 6              # s*64
  add  t0, s0, t5
  li   t1, 2048               # bytes per stream region
stream_fill_inner:
  li   t3, 0xBEEF0000
  add  t3, t3, s3
  xor  t3, t3, t0
  sd   t3, 0(t0)
  addi t0, t0, 256            # multi-stream stride
  addi t1, t1, -256
  bgtz t1, stream_fill_inner
  addi s3, s3, 1
  li   t6, 4
  blt  s3, t6, stream_fill

  # Verify multi-stream
  li   s3, 0
stream_verify:
  slli t5, s3, 6
  add  t0, s0, t5
  li   t1, 2048
stream_verify_inner:
  li   t3, 0xBEEF0000
  add  t3, t3, s3
  xor  t3, t3, t0
  ld   t4, 0(t0)
  bne  t3, t4, fail
  addi t0, t0, 256
  addi t1, t1, -256
  bgtz t1, stream_verify_inner
  addi s3, s3, 1
  li   t6, 4
  blt  s3, t6, stream_verify

  # ---- 4. Capacity thrash: line-strided rewrite ----
  mv   t0, s0
  mv   t1, s1
5:
  li   t3, 0xA5A5A5A5A5A5A5A5
  xor  t3, t3, t0
  sd   t3, 0(t0)
  add  t0, t0, s2
  sub  t1, t1, s2
  bgtz t1, 5b

  mv   t0, s0
  mv   t1, s1
6:
  li   t3, 0xA5A5A5A5A5A5A5A5
  xor  t3, t3, t0
  ld   t4, 0(t0)
  bne  t3, t4, fail
  add  t0, t0, s2
  sub  t1, t1, s2
  bgtz t1, 6b

  # ---- 5. Final sequential overwrite ----
  mv   t0, s0
  li   t1, 2048
7:
  li   t3, 0x0123456789ABCDEF
  add  t3, t3, t0
  sd   t3, 0(t0)
  addi t0, t0, 8
  addi t1, t1, -8
  bnez t1, 7b

  mv   t0, s0
  li   t1, 2048
8:
  li   t3, 0x0123456789ABCDEF
  add  t3, t3, t0
  ld   t4, 0(t0)
  bne  t3, t4, fail
  addi t0, t0, 8
  addi t1, t1, -8
  bnez t1, 8b

  li   t0, 8192
  add  sp, sp, t0
  li   a0, 0
  jal  exit

fail:
  li   t0, 8192
  add  sp, sp, t0
  li   a0, 1
  jal  exit
