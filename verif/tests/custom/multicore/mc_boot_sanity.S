# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Minimal boot sanity control for the multi-core testharness.
#
# Purpose: decide whether a model can run ANY program to completion, separately
# from whatever a real test is measuring. Hart 0 writes the pass code and stops;
# every other hart parks immediately. There is no shared memory, no polling, no
# handshake and no bounded spin, so the only way this fails is if the machine
# cannot fetch, execute and retire a handful of instructions and land a store.
#
# It exists because a run that ends in the harness cycle timeout is ambiguous —
# a broken model, a program whose bounded loops are simply slower than the cycle
# budget, and a mis-compiled ELF all look identical from the outside. Run this
# first; interpret nothing else on a model where this does not pass.
#
# Self-contained on purpose: `_start` in .text.init, its own mtvec, and no
# dependency on crt.S. (A previous control attempt used a test written as `main`
# and compiled it with -nostartfiles, so it never reached its own code — the
# resulting timeout said nothing about the model.)
#
# tohost=1 pass. Trap: 32+((mcause<<1)|1).

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap_vec
  csrw mtvec, t1
  bnez t0, park

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
  # The fence is not decoration. Without it this store executed (the hart stalled
  # at the branch below, i.e. past the sw) yet HTIF never observed tohost and the
  # DUT watchdog fired. A hart that goes completely quiet after a store gives its
  # write buffer no reason to drain, so the value never becomes visible.
  fence rw, rw
1: j 1b

park:
  wfi
  j    park

trap_vec:
  csrr a0, mcause
  andi a0, a0, 0xff
  slli a0, a0, 1
  ori  a0, a0, 1
  addi a0, a0, 32
  la   t0, tohost
  sw   a0, 0(t0)
2: j 2b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
