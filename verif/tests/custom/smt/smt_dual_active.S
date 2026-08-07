# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# SMT dual-hart *active* peer prove (post-grace residual):
#   - Both harts enter DRAM (bootrom no longer WFI-parks mhartid!=0).
#   - Hart 1 stores peer_marker = 0xC0DE, fence, WFI.
#   - Hart 0 burns past SMT_DRAM_GRACE, then polls peer_marker.
# Bare-metal: own _start + tohost (no CRT).

  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, secondary_active

  # ---- Hart 0: burn + poll peer marker ----
  li   t1, 800
1:
  addi t1, t1, -1
  andi t2, t1, 3
  bnez t2, 2f
  nop
2:
  bnez t1, 1b

  la   t0, peer_marker
  li   t3, 0x40000
  li   t4, 0xC0DE
3:
  fence
  ld   t1, 0(t0)
  beq  t1, t4, pass
  addi t3, t3, -1
  bnez t3, 3b
  j    fail

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
4: j    4b

fail:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
5: j    5b

secondary_active:
  la   t0, peer_marker
  li   t1, 0xC0DE
  sd   t1, 0(t0)
  fence
  fence.i
6:
  wfi
  j    6b

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
