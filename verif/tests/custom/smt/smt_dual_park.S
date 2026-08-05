# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# SMT dual-hart park (R1 intermediate before rootfs):
#   - Both software harts start at the same reset entry (fine-grain SMT).
#   - Hart 1 parks in WFI forever (OpenSBI secondary model).
#   - Hart 0 verifies mhartid==0, does a short ALU self-check, exits 0.
# Requires package with NrHarts>=2 for meaningful dual-thread schedule;
# still builds on NrHarts=1 (hart 1 never runs). Self-check; a0=0 pass.

  .globl main
main:
  csrr t0, mhartid
  bnez t0, park_secondary

  # ---- Hart 0 only ----
  # mhartid must be 0
  bnez t0, fail

  li   t1, 0
  li   t2, 32
1:
  addi t1, t1, 1
  # Yield-friendly: branch mix so thread select can run peer if present
  andi t3, t1, 1
  bnez t3, 2f
  nop
2:
  addi t2, t2, -1
  bnez t2, 1b

  li   t2, 32
  bne  t1, t2, fail

  li   a0, 0
  ret

park_secondary:
  # Secondary software hart: park like OpenSBI HSM STOPPED / WFI loop
  wfi
  j    park_secondary

fail:
  li   a0, 1
  ret
