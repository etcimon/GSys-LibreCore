# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Xg6lcai AI-X: ais==Off rejects AI issue as illegal-instruction.
# Soft-pass if AI CSRs are absent.
#
#   1. csrr aicfg  — proves the plane exists
#   2. write ais=Off
#   3. ai.getcfg   — must trap (mcause=2); mepc advanced in handler
#   4. restore ais=Initial
#   5. ai.getcfg   — must succeed

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap_vec
  csrw mtvec, t0
  andi sp, sp, -16
  li   s0, 0                   # trap counter

  # Presence: illegal on aicfg → soft-pass
  csrr t0, 0x801

  # ais = Off
  csrr t0, 0x802
  li   t1, ~(0x3 << 6)
  and  t0, t0, t1
  csrw 0x802, t0

  # Must trap
  .word 0x0200055B             # ai.getcfg a0
  # If no trap, fail (we would still be here with s0==0)
  beqz s0, fail
  # Exactly one trap so far
  li   t0, 1
  bne  s0, t0, fail

  # Restore ais = Initial
  csrr t0, 0x802
  li   t1, ~(0x3 << 6)
  and  t0, t0, t1
  li   t1, (0x1 << 6)
  or   t0, t0, t1
  csrw 0x802, t0

  # Must NOT trap
  .word 0x0200055B             # ai.getcfg a0
  li   t0, 1
  bne  s0, t0, fail            # trap count must stay 1

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
  # Skip faulting instruction
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  addi s0, s0, 1
  mret

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
