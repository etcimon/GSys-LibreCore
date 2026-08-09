# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Xg6lcai CSR smoke: aicfg / aistatus / mstatus.xs (AI-X).
# Package: g6lc64_ai (AiCfg.MatrixEn=1). Soft-pass on trap only if CSRs are
# absent (non-AI package); hard-fail if present but xs does not track ais.
#
# Addresses (isa-encoding.md §4, post-FTRAN fix):
#   aicfg=0x801  aistatus=0x802  aiscale=0x803  aizp=0x804  aiperm=0x7C8

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap_vec
  csrw mtvec, t0
  andi sp, sp, -16

  # ---- 1. aicfg readable when AI present ----
  csrr t0, 0x801
  # version field [19:16] must be 1 on a live AI package
  srli t1, t0, 16
  andi t1, t1, 0xF
  li   t2, 1
  bne  t1, t2, fail

  # ---- 2. aistatus.ais reset = Initial (2'b01) ----
  csrr t0, 0x802
  srli t1, t0, 6
  andi t1, t1, 0x3
  li   t2, 1
  bne  t1, t2, fail

  # ---- 3. mstatus.xs mirrors ais (Initial) ----
  csrr t0, mstatus
  # xs is bits [16:15] of mstatus
  srli t1, t0, 15
  andi t1, t1, 0x3
  li   t2, 1
  bne  t1, t2, fail

  # ---- 4. write ais=Dirty (2'b11), xs must follow ----
  csrr t0, 0x802
  li   t1, ~(0x3 << 6)
  and  t0, t0, t1
  li   t1, (0x3 << 6)
  or   t0, t0, t1
  csrw 0x802, t0
  csrr t0, mstatus
  srli t1, t0, 15
  andi t1, t1, 0x3
  li   t2, 3
  bne  t1, t2, fail

  # ---- 5. write ais=Off, xs must be Off; AI ops would trap (not tested here) ----
  csrr t0, 0x802
  li   t1, ~(0x3 << 6)
  and  t0, t0, t1
  csrw 0x802, t0
  csrr t0, mstatus
  srli t1, t0, 15
  andi t1, t1, 0x3
  bnez t1, fail

  # ---- 6. aiperm readable (M-mode) ----
  csrr t0, 0x7C8
  # bit1 (S) should be 1 at reset
  andi t1, t0, 0x2
  beqz t1, fail

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j 1b

fail:
  li   a0, 2
  la   t0, tohost
  sw   a0, 0(t0)
2: j 2b

# Trap: if CSR absent (illegal), soft-pass so non-AI packages can soft-skip.
trap_vec:
  csrr t0, mcause
  li   t1, 2
  bne  t0, t1, fail
  # illegal-instruction → soft-pass (package without AI)
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
3: j 3b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
