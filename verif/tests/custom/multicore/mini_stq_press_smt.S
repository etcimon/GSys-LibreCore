# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# R4 residual, pressure variant: getprop s2/s3 frame-reuse shape
# (mini_stq_flush_fwd) plus (a) write-buffer pressure bursts around the
# prologue/epilogue and (b) a live second hart doing store bursts + AMOs on
# its own region, so SMT switches land between the callee `sd` and `ld`.
# Catches an STQ/wbuf flush or hart-switch that drops or bypasses a
# non-cancelled prologue store (I16/I17, I22). tohost=1 pass, 3 fail.
#

  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, hart1

  # ---------------- hart 0: checker ----------------
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  li   s5, 0                 # loop index
  li   s4, 64                # iterations
1:
  li   s3, 0x33330000
  add  s3, s3, s5
  li   s2, 0x22220000
  add  s2, s2, s5

  # wbuf pressure: burst of stores to a scratch line before the calls
  li   t2, 0x80009000
  sd   s5, 0(t2)
  sd   s5, 8(t2)
  sd   s5, 16(t2)
  sd   s5, 24(t2)
  sd   s5, 32(t2)
  sd   s5, 40(t2)
  sd   s5, 48(t2)
  sd   s5, 56(t2)

  jal  f1                    # leaves ra residue at the shared slot
  jal  f2                    # prologue sd s3 -> same slot; branch; ld s3

  li   t0, 0x33330000
  add  t0, t0, s5
  bne  s3, t0, fail
  li   t1, 0x22220000
  add  t1, t1, s5
  bne  s2, t1, fail

  addi s5, s5, 1
  addi s4, s4, -1
  bnez s4, 1b

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

# f1: minimal frame, saves ra at 24(sp) -- the shared slot after return.
f1:
  addi sp, sp, -32
  sd   ra, 24(sp)
  li   a5, 0x20
  add  a5, a5, sp
  ld   ra, 24(sp)
  addi sp, sp, 32
  ret

# f2: prologue stores s2/s3 over f1's residue; wbuf burst + mispredicting
# branch in the shadow; epilogue reloads.
f2:
  addi sp, sp, -32
  sd   s3, 24(sp)            # same address as f1's ra slot
  sd   s2, 16(sp)
  li   s3, 9
  li   s2, 9
  # wbuf pressure inside the shadow (same cache line as the frame slots)
  sd   zero, 0(sp)
  sd   zero, 8(sp)
  # alternating data-dependent branch (BHT mispredicts on period change)
  andi t0, s5, 3
  beqz t0, 3f
  lw   t1, 16(sp)
  add  t1, t1, t0
3:
  andi t0, s5, 1
  bnez t0, 4f
  c.nop
4:
  ld   s3, 24(sp)            # must see f2's own prologue store
  ld   s2, 16(sp)
  addi sp, sp, 32
  ret

  # ---------------- hart 1: pressure generator ----------------
hart1:
  li   sp, 0x8000A000
  la   t0, trap1
  csrw mtvec, t0
  li   t2, 0x8000B000
  li   t3, 1
5:
  # store burst on its own region (fills wbuf, forces SMT switch-on-miss)
  sd   t3, 0(t2)
  sd   t3, 8(t2)
  sd   t3, 16(t2)
  sd   t3, 24(t2)
  sd   t3, 32(t2)
  sd   t3, 40(t2)
  sd   t3, 48(t2)
  sd   t3, 56(t2)
  # AMO on its own lock word for D$ / switch pressure
  li   t4, 1
  mv   a1, t2
  .word 0x0665A5AF           # amoadd.w.aqrl a1, t1, (a1)
  addi t3, t3, 1
  j    5b

trap:
  csrr a0, mcause
  li   t0, 3
  la   t1, tohost
  sw   t0, 0(t1)
6: j    6b

trap1:
  # hart1 traps must not end the test; park
7: j    7b

fail:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
8: j    8b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
