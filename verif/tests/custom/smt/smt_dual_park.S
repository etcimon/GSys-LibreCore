# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# SMT dual-hart park (R1 intermediate before rootfs):
#   - Both software harts start at the same reset entry (fine-grain SMT).
#   - Hart 1 parks in WFI forever IMMEDIATELY (before stack/BSS — CRT parks
#     secondaries in a tight spin which can starve under some SMT policies).
#   - Hart 0 does a short ALU self-check and writes tohost PASS.
# Requires package with NrHarts>=2 for dual-thread schedule; still builds on
# NrHarts=1 (hart 1 never runs). Bare-metal: own _start + tohost (no CRT).

  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, park_secondary

  # ---- Hart 0 only ----
  li   t1, 0
  li   t2, 32
1:
  addi t1, t1, 1
  # Yield-friendly branch mix so thread select can run peer if present
  andi t3, t1, 1
  bnez t3, 2f
  nop
2:
  addi t2, t2, -1
  bnez t2, 1b

  li   t2, 32
  bne  t1, t2, fail

  # PASS
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

park_secondary:
  # Secondary: OpenSBI-like HSM STOPPED / WFI loop (not a tight branch spin)
  wfi
  j    park_secondary

fail:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
4: j    4b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
