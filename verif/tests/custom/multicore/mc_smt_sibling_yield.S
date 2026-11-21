# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# SMT-sibling liveness probe: does core0's thread-1 (mhartid 1) execute when
# the primary thread (mhartid 0) is NOT spinning?
#
# mc_all_harts_present showed mask stuck at 0x02: every hart stores its flag
# except mhartid 1 (core0 thread-1). On cores 1..3 BOTH SMT threads completed
# because their thread-0s hit `park:wfi` and yielded. Core0's hart0 instead
# spins in the census loop forever, so hart1 never got a switch slot.
#
# This test removes the confound: hart0 stores its flag then PARKS (wfi), so
# core0's issue slots go entirely to hart1. hart1 then becomes the census
# reader. If hart1 runs and sees all 8 flags -> the sibling is fine and the
# earlier miss was pure starvation-under-busy-primary. If hart1 still never
# stores/runs -> the sibling is never activated (seen/enable/reset bug).
#
# tohost: 1 = all 8 present (PASS); 0x100|mask = timeout (bit i = flags[i]==0);
#         32+mcause = trap.
#
#ifndef NHARTS
#define NHARTS 8
#endif
  .equ CLINT_MSIP, 0x02000000

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap_vec
  csrw mtvec, t1
  csrw mie, x0            # pending MSIs from the release below never trap

  # hart0 releases every other hart's core from BOOT_HOLD immediately via the
  # CLINT msip (same trick as mc_smode_* / mc_all_harts_present).
  csrr t0, mhartid
  bnez t0, rel_done
  li   t1, 1
  li   t2, 1
  li   t4, CLINT_MSIP
  li   t5, NHARTS
rel_loop:
  bgeu  t2, t5, rel_done
  slli  t3, t2, 2
  add   t3, t3, t4
  sw    t1, 0(t3)
  addi  t2, t2, 1
  j     rel_loop
rel_done:

  # Every hart publishes itself: flags[mhartid] = mhartid+1.
  csrr t0, mhartid
  slli t0, t0, 2
  la   t1, flags
  add  t0, t0, t1
  csrr t2, mhartid
  addi t2, t2, 1
  sw   t2, 0(t0)
  fence rw, rw

  # Role split: hart0 PARKS (yields core0 to hart1). hart1 is the census
  # reader. All other harts park.
  csrr t0, mhartid
  li   t1, 1
  beq   t0, t1, census_role      # mhartid==1 -> reader
  j     park

census_role:
  li   s0, NHARTS
  li   s1, 20000                 # generous: secondaries already released
census:
  li   s2, 0                     # missing mask
  li   s3, 0                     # cursor
  la   s4, flags
1:
  slli s5, s3, 2
  add  s5, s4, s5
  lw   s6, 0(s5)
  bnez s6, 2f
  li   t3, 1
  sll  t3, t3, s3
  or   s2, s2, t3
2:
  addi s3, s3, 1
  bltu s3, s0, 1b

  la   t0, result
  sw   s2, 0(t0)
  fence rw, rw

  bnez s2, giveup
  li   a0, 1
  j    done

giveup:
  addi s1, s1, -1
  bnez s1, census
  li   a0, 0x100
  or   a0, a0, s2
  j    done

park:
  wfi
  j    park

done:
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
3: j 3b

trap_vec:
  csrr a0, mcause
  andi a0, a0, 0xff
  slli a0, a0, 1
  ori  a0, a0, 1
  addi a0, a0, 32
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
4: j 4b

  .section .data,"aw",@progbits
  .align 3
  .globl flags
flags:  .fill 8,4,0
  .globl result
result: .dword 0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
