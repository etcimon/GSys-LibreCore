# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# hyp8 r68: head-only issue order under OoO readiness.
#
# Contract (no address, register or firmware symbol in it): an operation of
# a head-only class (AMO, LR, SC) is granted by the issue queue only while
# it is the commit head, however early its operands become ready, and
# whatever record its queue slot held before it.
#
# Each variant places an OLDER head-only op whose operand arrives late
# (behind a dependent load chain) directly in front of a YOUNGER head-only
# op whose operands are ready at dispatch. If the younger one is granted
# first it reaches the single-entry AMO buffer (or opens the issue stage's
# LR/SC window) ahead of the head, and the head can never complete: the
# run budgets out (no tohost) -- the kernel-spinlock wedge of
# hyp8-osbi-scalar-r31/r33/r36 in twenty instructions. With the contract
# held, every variant completes and the memory/register values below are
# the only possible ones.
#
# v1  amoadd (late data)  then amoadd (ready)          -- AMO buffer order
# v2  lr.d  (late address) then sc.d (ready, same word) -- buffer + reservation
# v3  lr.d  (late address) then lr.d + sc.d (ready)     -- LR/SC window owner
#
# tohost = 1 on success; (2*k+1) names the first failing variant; a wedge
# shows as a budget-out (no tohost).
.option norvc
.section .text.init
.globl _start
_start:
  la    s0, data
  li    s7, 0

# ---------------------------------------------------------------- v1
v1:
  li    a4, 1
  la    a5, lockw
  ld    a0, 0(s0)          # -> slot A
  ld    a0, 0(a0)          # -> slot B
  ld    a0, 0(a0)          # -> slot C
  ld    a1, 0(a0)          # = 5, late
  amoadd.w a3, a1, (a5)    # older: data late      lockw 0 -> 5
  amoadd.w a6, a4, (a5)    # younger: ready        lockw 5 -> 6
  fence
  lw    t3, 0(a5)
  li    t4, 6
  bne   t3, t4, fail1
  bne   a3, zero, fail1    # older saw 0
  li    t4, 5
  bne   a6, t4, fail1      # younger saw the older's result
  j     v2
fail1:
  li    s7, 1
  j     report

# ---------------------------------------------------------------- v2
v2:
  li    a4, 0x77
  la    a5, lockd
  ld    a0, 0(s0)
  ld    a0, 0(a0)
  ld    a0, 0(a0)
  ld    a2, 8(a0)          # = &lockd through memory, late
  lr.d  a3, (a2)           # older: address late   reserves lockd
  sc.d  a6, a4, (a5)       # younger: ready        must succeed (same word)
  fence
  bne   a6, zero, fail2    # sc succeeded
  bne   a3, zero, fail2    # lr saw 0
  ld    t3, 0(a5)
  li    t4, 0x77
  bne   t3, t4, fail2
  j     v3
fail2:
  li    s7, 2
  j     report

# ---------------------------------------------------------------- v3
v3:
  li    a4, 0x99
  la    a5, lockq
  ld    a0, 0(s0)
  ld    a0, 0(a0)
  ld    a0, 0(a0)
  ld    a2, 16(a0)         # = &lockq through memory, late
  lr.d  a3, (a2)           # older LR: address late
  lr.d  a6, (a5)           # younger LR: ready -- must not own the window
  sc.d  a7, a4, (a5)       # pairs with the younger LR
  fence
  bne   a7, zero, fail3    # sc succeeded
  bne   a3, zero, fail3
  bne   a6, zero, fail3
  ld    t3, 0(a5)
  li    t4, 0x99
  bne   t3, t4, fail3
  j     report
fail3:
  li    s7, 3

# ---------------------------------------------------------------- verdict
report:
  beqz  s7, pass
  slli  t0, s7, 1
  addi  t0, t0, 1
  la    t1, tohost
  sw    t0, 0(t1)
  j     done
pass:
  li    t0, 1
  la    t1, tohost
  sw    t0, 0(t1)
done:
  j     done

.section .data
.align 6
data:
  .dword data+64          # [0]  -> slot A
  .dword 0, 0, 0, 0, 0, 0, 0
  .dword data+72          # [64] slot A -> slot B
  .dword data+80          # [72] slot B -> slot C
  .dword 5                # [80] slot C: v1 late data
  .dword lockd            # [88] slot C+8: v2 late address
  .dword lockq            # [96] slot C+16: v3 late address
  .dword 0, 0, 0
.align 6
lockw: .word 0
.align 3
lockd: .dword 0
.align 6
lockq: .dword 0

.section .tohost,"aw",@progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
