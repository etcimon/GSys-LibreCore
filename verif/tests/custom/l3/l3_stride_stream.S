# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Directed L2/L3 hierarchy stress (works with L2En/L3En SoC configs):
#   1. Sequential stream write+read (next-line / sequential PF friendly)
#   2. Large-stride access pattern (line-size multiples) to force capacity misses
#   3. Verify data integrity after multi-pass
#
# Buffer: 16 KiB on stack (within typical L1 for small N, still exercises
# L2 when strided; larger systems use DRAM via the same access patterns).
# Functional check only — not a cycle-count bench.

  .globl main
main:
  # 16 KiB buffer
  li   t0, 16384
  sub  sp, sp, t0
  mv   s0, sp              # base
  li   s1, 16384           # bytes
  li   s2, 64              # stride ≈ cache line (L1 often 16B, L2/L3 64B)

  # ---- Pass 1: sequential fill with address-based pattern ----
  mv   t0, s0
  mv   t1, s1
1:
  # store (base ^ offset) pattern
  sub  t2, t0, s0
  xor  t3, t0, t2
  sd   t3, 0(t0)
  addi t0, t0, 8
  addi t1, t1, -8
  bnez t1, 1b

  # ---- Pass 2: sequential verify ----
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

  # ---- Pass 3: large-stride write (every 64 B) ----
  mv   t0, s0
  mv   t1, s1
3:
  li   t3, 0xA5A5A5A5A5A5A5A5
  xor  t3, t3, t0
  sd   t3, 0(t0)
  add  t0, t0, s2
  sub  t1, t1, s2
  bgtz t1, 3b

  # ---- Pass 4: large-stride verify ----
  mv   t0, s0
  mv   t1, s1
4:
  li   t3, 0xA5A5A5A5A5A5A5A5
  xor  t3, t3, t0
  ld   t4, 0(t0)
  bne  t3, t4, fail
  add  t0, t0, s2
  sub  t1, t1, s2
  bgtz t1, 4b

  # ---- Pass 5: second sequential overwrite + verify (reuse lines) ----
  mv   t0, s0
  li   t1, 4096            # first 4 KiB only
5:
  li   t3, 0x0123456789ABCDEF
  add  t3, t3, t0
  sd   t3, 0(t0)
  addi t0, t0, 8
  addi t1, t1, -8
  bnez t1, 5b

  mv   t0, s0
  li   t1, 4096
6:
  li   t3, 0x0123456789ABCDEF
  add  t3, t3, t0
  ld   t4, 0(t0)
  bne  t3, t4, fail
  addi t0, t0, 8
  addi t1, t1, -8
  bnez t1, 6b

  li   t0, 16384
  add  sp, sp, t0
  li   a0, 0
  jal  exit

fail:
  li   t0, 16384
  add  sp, sp, t0
  li   a0, 1
  jal  exit
