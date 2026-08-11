# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Soft-ladder stock peel (post-I4g): OpenSBI sbi_hart_init CSR probe shape.
#
# OpenSBI __sbi_expected_trap uses **a3** as pointer to a stack trap_info:
#   csrrw mtvec, handler
#   csrw  pmpcfg0 / pmpaddr0 / csrr pmpaddr0   # may trap
#   csrw  mtvec, old
#   ld    flag, 0(trap_info)   # handler wrote mcause here
#
# mini_csr_expected_trap only covers simple illegal + restore without a3
# trap_info or multi-probe. This mini matches the multi-step pmp probe loop.
#
# tohost=1 pass, 3 fail. Prefer g6lc64_smt2 / work-ver-smt2-slfix DI.

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, fatal
  csrw mtvec, t0

  # Frame for OpenSBI-like trap_info at s0-88 (keep 128B frame).
  addi sp, sp, -128
  addi s0, sp, 128

  # Clear trap_info slots (mcause, mtval, …) like OpenSBI sdzero -88..-56
  sd   zero, -88(s0)
  sd   zero, -80(s0)
  sd   zero, -72(s0)
  sd   zero, -64(s0)
  sd   zero, -56(s0)

  # --- Probe 1: pmpcfg0 write with a1=0 (often legal; still exercise serialize) ---
  la   a2, expected_handler
  addi a3, s0, -88             # trap_info *
  li   a1, 0
  csrrw a2, mtvec, a2          # install; a2 = old mtvec
  csrw pmpcfg0, a1             # probe
  csrw mtvec, a2               # restore
  # a3 must still be trap_info; if handler ran, [0] has mcause
  # Either trap or legal is OK if we did not take fatal mtvec
  # Force a3 liveness + stack integrity
  addi t0, s0, -88
  bne  a3, t0, fail

  # --- Probe 2: illegal high CSR via expected trap (must trap) ---
  sd   zero, -88(s0)
  la   a2, expected_handler
  addi a3, s0, -88
  csrrw a2, mtvec, a2
  .word 0xfff022f3             # csrrs t2, 0xfff, x0  (illegal)
  csrw mtvec, a2
  addi t0, s0, -88
  bne  a3, t0, fail
  ld   t1, -88(s0)             # mcause from handler
  beqz t1, fail                # must have trapped (illegal)
  li   t2, 2
  bne  t1, t2, fail            # illegal instruction = 2

  # --- Probe 3: pmpaddr0 write then read (OpenSBI second/third probes) ---
  sd   zero, -88(s0)
  la   a2, expected_handler
  addi a3, s0, -88
  li   a1, -1
  srli a1, a1, 10              # OpenSBI shape: a1 = -1 >> 10
  csrrw a2, mtvec, a2
  csrw pmpaddr0, a1
  csrw mtvec, a2
  addi t0, s0, -88
  bne  a3, t0, fail

  sd   zero, -88(s0)
  la   a2, expected_handler
  addi a3, s0, -88
  csrrw a2, mtvec, a2
  csrr a4, pmpaddr0
  csrw mtvec, a2
  addi t0, s0, -88
  bne  a3, t0, fail
  # a4 may be 0 if trap cleared; just ensure we survived

  # --- Probe 4: two illegals back-to-back (stress unresolved_csr after flush) ---
  sd   zero, -88(s0)
  la   a2, expected_handler
  addi a3, s0, -88
  csrrw a2, mtvec, a2
  .word 0xfff022f3
  csrw mtvec, a2
  ld   t1, -88(s0)
  li   t2, 2
  bne  t1, t2, fail

  sd   zero, -88(s0)
  la   a2, expected_handler
  addi a3, s0, -88
  csrrw a2, mtvec, a2
  .word 0xfff032f3             # second illegal encoding variant
  csrw mtvec, a2
  ld   t1, -88(s0)
  li   t2, 2
  bne  t1, t2, fail

  # PASS
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

# OpenSBI __sbi_expected_trap shape: use a3 as trap_info base.
# Store mcause @0(a3), mtval @8(a3), advance mepc, mret.
expected_handler:
  csrr t0, mcause
  sd   t0, 0(a3)
  csrr t0, mtval
  sd   t0, 8(a3)
  sd   zero, 16(a3)
  sd   zero, 24(a3)
  sd   zero, 32(a3)
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  mret

fatal:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
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
