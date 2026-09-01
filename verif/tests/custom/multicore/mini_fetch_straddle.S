# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Directed reproducer for the fetch_B 32-bit RVI straddle at a 2-byte aligned
# address. The failing OpenSBI path lands with `npc0=0x800138d8` (second half
# of 32-bit `beqz s4` at `0x800138d6` in `fdt_getprop_by_offset`). This test
# places a 32-bit `beqz` at `0x80012006` (addr[1:0]=10, crossing the 64-bit
# fetch word at `0x80012008`) and checks that it executes correctly.

  .option rvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, hart1
  li   sp, 0x80046ef0
  la   t0, trap
  csrw mtvec, t0

  # Cache / STQ occupancy like the real OpenSBI path.
  jal  warmup

  # Set a0=0 so the straddled beqz should be taken.
  li   a0, 0
  li   a1, 0x80012000
  jalr a1

  # If the branch target returns, a0 should be 1.
  beqz a0, bad
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j    1b

bad:
  li   t0, 3
  la   t1, tohost
  sw   t0, 0(t1)
2: j    2b

hart1:
  li   sp, 0x80048000
  li   t1, 0x80047e00
3:
  sd   t1, 0(t1)
  sd   t1, 64(t1)
  ld   t2, 0(t1)
  j    3b

# STQ/D$ occupancy on the TRACE alias line and a same-set neighbour.
warmup:
  li   t0, 800
  li   t1, 0x80045e00
  li   t4, 0x80046e00
4:
  sd   t0, 0(t1)
  sd   t0, 8(t1)
  sd   t0, 0(t4)
  sd   t0, 0x20(t4)
  sd   t0, 0x38(t4)
  ld   t2, 0(t1)
  ld   t3, 0x38(t4)
  addi t0, t0, -1
  bnez t0, 4b
  ret

trap:
  li   a0, 25
  la   t0, tohost
  sw   a0, 0(t0)
5: j    5b

# The straddle function: start 0x80012000, 32-bit beqz at 0x80012006.
  .section .text.straddle, "ax"
  .align 1
  .globl straddle_fn
straddle_fn:
  # Three 2-byte instructions to advance to 0x80012006.
  c.nop
  c.nop
  c.nop
  # 32-bit branch at 0x80012006 (addr[1:0]=10), straddles 0x80012008.
  beqz a0, taken
  # If the branch is not taken, a0 stays 0; signal fail.
  li   a0, 2
  j    straddle_end
taken:
  li   a0, 1
straddle_end:
  ret

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
