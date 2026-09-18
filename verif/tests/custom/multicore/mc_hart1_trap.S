# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Minimal probe: does the SECOND hart FETCH at all? (trap variant)
#
# Every two-hart test in this directory has hart 0 poll for something hart 1
# publishes, so "hart 1 never ran" and "hart 1 ran but the shared line was not
# observed" both surface as the same timeout on hart 0. This test removes that
# ambiguity by inverting the roles: hart 0 parks immediately and does nothing,
# and ONLY hart 1 writes tohost. A SUCCESS therefore cannot be produced by hart 0
# and is direct proof that hart 1 fetched, executed and reached a store.
#
# It also avoids the trap that cost real time here: the testbench's "[boot]"
# trace reports core 0 only, and only for main_time < 64
# (corev_apu/tb/g6lc_tb.cpp:676), so its npc value says nothing whatever about
# the secondary core. Read this test's verdict instead of that trace.
#
# Needs NrCores >= 2. Requires +debug_disable and +tohost_addr on the harness.

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap_vec
  csrw mtvec, t1
  bnez t0, hart1

  # ---- hart 0: park. It must not be able to satisfy the test. ----
  # A plain branch loop, deliberately NOT wfi: wfi is a core stall and could
  # itself be the reason a second hart appears dead, so it must not be a variable
  # in a probe whose whole purpose is to decide whether hart 1 executes.
0:
  j    0b

  # ---- hart 1: the only writer ----
hart1:
  # Deliberate illegal instruction BEFORE any store. This separates the two
  # remaining explanations for "hart 1 never publishes": if hart 1 FETCHES at all,
  # the trap handler writes 32+((mcause<<1)|1) and the harness reports a distinctive
  # non-watchdog value; if we still see the watchdog (2147483647) then hart 1 never
  # executes an instruction, and no store-visibility theory is needed.
  unimp
1:
  j    1b

trap_vec:
  # Distinguish a hart-1 trap from silence: 32 + ((mcause<<1)|1).
  csrr a0, mcause
  andi a0, a0, 0xff
  slli a0, a0, 1
  ori  a0, a0, 1
  addi a0, a0, 32
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
2: j 2b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
