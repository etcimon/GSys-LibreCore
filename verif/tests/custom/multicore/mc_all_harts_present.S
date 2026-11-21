# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# All-hart presence census for the 4-core x 2-thread (8-hart) model.
#
# Motivation: the cycprog heartbeat is clock-gated per core, so a core whose
# harts are all in WFI emits no [cycprog] line and is indistinguishable from a
# core that was never released. This test removes that ambiguity in the
# bare-metal context: every hart stores its mhartid into flags[hartid], then
# hart 0 polls until all 8 slots are non-zero.
#
# The missing-hart mask is published to `result` on EVERY census pass, so even
# when the harness cycle budget kills hart 0 mid-spin, the mask is already in
# memory and readable from the trace / a post-mortem dump.
#
# tohost encoding:
#   1            -> all 8 harts present (PASS)
#   0x100 | mask -> census budget exhausted; mask bit i = flags[i] still zero
#   32+trap      -> a hart trapped (mcause-derived)

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
  # CLINT msip (same trick as mc_smode_*): skip the ~200k-cycle hold so the
  # census does not have to out-spin it. MIE=0 keeps the MSI benign.
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

  # Every hart publishes itself. mhartid is 0..7 across the 4x2 machine.
  csrr t0, mhartid
  slli t0, t0, 2
  la   t1, flags
  add  t0, t0, t1
  csrr t2, mhartid
  addi t2, t2, 1
  sw   t2, 0(t0)
  fence rw, rw

  # hart 0 is the census reader; all others park.
  csrr t0, mhartid
  bnez t0, park

  li   s0, 8            # expected hart count
  # Census budget must OUTLAST the cluster BOOT_HOLD: g6lc_cluster gates every
  # core c!=0 until boot_hold_q>=200000 (no IPI in bare metal), so secondary
  # cores only run _start ~c200k. ~10000 passes ~= ~700k cycles, ample margin.
  li   s1, 10000        # census passes before giving up
census:
  li   s2, 0            # mask of missing harts
  li   s3, 0            # cursor
  la   s4, flags
1:
  slli s5, s3, 2
  add  s5, s4, s5
  lw   s6, 0(s5)
  bnez s6, 2f
  li   t3, 1
  sll  t3, t3, s3
  or   s2, s2, t3       # record missing hart s3
2:
  addi s3, s3, 1
  bltu s3, s0, 1b

  # publish the mask every pass (survives a harness kill mid-spin)
  la   t0, result
  sw   s2, 0(t0)
  fence rw, rw

  # any missing?
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
