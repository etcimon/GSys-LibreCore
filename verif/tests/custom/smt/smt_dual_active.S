# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# SMT dual-hart concurrent marker (post-grace):
#   - Both harts enter DRAM (bootrom does not WFI-park secondaries).
#   - Hart 1 stores peer_marker = 0xC0DE then spins (stays ready; not WFI).
#   - Hart 0 burns past SMT_DRAM_GRACE, then polls without per-iter fence.
#   - PASS only if primary observes the peer store (true dual-active prove).
# Bare-metal: own _start + tohost (no CRT). Spike: use -p2.

  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, secondary_active

  # ---- Hart 0: burn for grace + quantum slots for peer, then poll ----
  # ~SMT_DRAM_GRACE (200) commits + headroom for peer quantum windows.
  li   t1, 2000
1:
  addi t1, t1, -1
  # Mix control flow so fetch_fire ages quantum / can switch
  andi t2, t1, 7
  bnez t2, 2f
  nop
  nop
2:
  bnez t1, 1b

  la   t0, peer_marker
  li   t3, 0x10000          # poll budget (no fence — keep iterations cheap)
  li   t4, 0xC0DE
3:
  ld   t1, 0(t0)
  beq  t1, t4, pass
  # Yield-friendly: branch mix so peer keeps getting quantum while we poll
  andi t2, t3, 3
  bnez t2, 4f
  nop
4:
  addi t3, t3, -1
  bnez t3, 3b
  j    fail

pass:
  # One fence before tohost so any prior peer store is ordered for TB
  fence
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
5: j    5b

fail:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
6: j    6b

secondary_active:
  # Hart 1: prove scheduled after grace; publish marker; stay ready (spin).
  la   t0, peer_marker
  li   t1, 0xC0DE
  sd   t1, 0(t0)
  fence
7:
  # Spin (not WFI): dual-WFI without IPI deadlocks the scheduler ready mask.
  j    7b

  .section .data
  .align 3
  .globl peer_marker
peer_marker:
  .dword 0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
