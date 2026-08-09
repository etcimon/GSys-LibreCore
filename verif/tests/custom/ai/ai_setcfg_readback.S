# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Xg6lcai: ai.setcfg is vsetvli-shaped — the returned grant is authoritative.
# Request M=N=K=log2(16)=4 against an 8×8×8 package → grant clamps to 8
# (log2=3) and version=1. Soft-pass on illegal (non-AI package).

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap_vec
  csrw mtvec, t0
  andi sp, sp, -16

  # ais = Initial
  csrr t0, 0x802
  li   t1, ~(0x3 << 6)
  and  t0, t0, t1
  li   t1, (0x1 << 6)
  or   t0, t0, t1
  csrw 0x802, t0

  # Request M=N=K=16 (log2=4), dtype=s8, accmode=overwrite
  # bits: M[3:0]=4, N[7:4]=4, K[11:8]=4 → 0x00000444
  li   a1, 0x00000444
  .word 0x0005855B             # ai.setcfg a0, a1

  # Granted dims must be log2(8)=3 for each (TileM/N/K=8)
  andi t0, a0, 0xf
  li   t1, 3
  bne  t0, t1, fail
  srli t0, a0, 4
  andi t0, t0, 0xf
  bne  t0, t1, fail
  srli t0, a0, 8
  andi t0, t0, 0xf
  bne  t0, t1, fail

  # version[19:16] == 1
  srli t0, a0, 16
  andi t0, t0, 0xf
  li   t1, 1
  bne  t0, t1, fail

  # CSR aicfg must match the grant
  csrr t0, 0x801
  bne  t0, a0, fail

  # getcfg returns the same
  .word 0x0200055B             # ai.getcfg a0
  bne  a0, t0, fail

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

trap_vec:
  csrr t0, mcause
  li   t1, 2
  bne  t0, t1, fail
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
