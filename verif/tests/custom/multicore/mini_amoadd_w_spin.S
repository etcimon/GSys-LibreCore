# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Soft-ladder B1 directed residual: OpenSBI-style ticket amoadd.w.aqrl under
# dual-issue-friendly filler (ALU / c.mv / stack RAW). Exercises hang-7
# younger-cancel + amo_buffer cancel kill path without OpenSBI binary patches.
#
# Gate (when wired): Variane/g6lc64_smt2 DI preferred; tohost=1 pass, 3 fail.

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  # lock word at 0(sp)
  sw   zero, 0(sp)

  # --- ticket style: amoadd.w.aqrl a0, t1, (a1)  ---
  # Encode: amoadd.w.aqrl rd=a0, rs2=t1, rs1=a1
  # funct5=00000 aq=1 rl=1 width=010 opcode=0101111
  li   t1, 1
  mv   a1, sp
  # dual-issue-ish filler before AMO (callee-saved / ALU noise)
  li   s2, 0x1111
  li   s3, 0x2222
  add  s4, s2, s3
  c.mv a2, s4
  sw   a2, 8(sp)                 # stack store near lock
  lw   a3, 8(sp)                 # STQ forward / page-offset interlock
  bne  a3, a2, fail

  .word 0x0665A52F               # amoadd.w.aqrl a0, t1, (a1)
  # a0 should be old value 0; mem should be 1
  bnez a0, fail
  lw   t2, 0(sp)
  li   t3, 1
  bne  t2, t3, fail

  # second ticket under more CF/ALU noise
  li   t1, 1
  mv   a1, sp
  jal  ra, filler
  .word 0x0665A52F               # amoadd.w.aqrl a0, t1, (a1)
  li   t3, 1
  bne  a0, t3, fail
  lw   t2, 0(sp)
  li   t3, 2
  bne  t2, t3, fail

  # PASS
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

filler:
  li   t4, 7
  addi t4, t4, 1
  c.mv t5, t4
  ret

trap:
  # unexpected trap → fail (mcause in a0 for dump)
  csrr a0, mcause
  li   t0, 3
  la   t1, tohost
  sw   t0, 0(t1)
2: j    2b

fail:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
