# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Dual-active prove: dual-ready burn (both ready post-grace), then primary
# WFI-yields so peer can score tohost. Pure no-WFI concurrent remains open.
#
# Modes (selected by the reviewer, one at a time):
#   SMT_BALANCE          fixed-work service measurement; balance_active masks the
#                        workers so a solo arm keeps the shared instruction bytes
#   SMT_ASYM             asymmetric roles: one hart computes in registers while the
#                        other walks a 64 KiB stride-1024 buffer, so the load port is
#                        actually exercised. ASYM_ROLES picks each hart's role and
#                        ASYM_ACTIVE masks the workers; both are data, so every arm
#                        keeps identical instruction bytes
#   SMT_PMU              counter-ownership probe: each hart writes a distinct
#                        mhpmevent3 selector in a handshaked order and reports what
#                        its peer's write left behind, with mscratch as the known
#                        per-hart control. PMU_EXP_H0/PMU_EXP_H1 state the expected
#                        semantics, so a shared and a banked counter are separable
#   SMT_PMUEVT           event-attribution probe: both harts count "load accesses" in
#                        their own mhpmcounter3 while executing very different load
#                        quotas across many context switches. Bounds are used, not an
#                        exact count, because the event ORs the commit ports so two
#                        loads retiring together increment once
#   SMT_PMUMISS          cross-switch attribution: hart0 takes D$ misses while hart1
#                        executes only register work for long enough to be scheduled
#                        throughout. A miss must never be charged to the successor
#   SMT_LOCK             lock holder vs spinning sibling: both harts contend for one
#                        lock and do identical critical-section work. The oracle checks
#                        the sections never overlap and measures what a sibling that
#                        produces nothing while spinning costs the holder
#   SMT_LRSC_DEP         LR result -> dependent consumer (rs1/SMT_LRSC_RS2/_ALU)
#   SMT_BOOT_RENDEZVOUS  reset-time election and release rendezvous
#   SMT_BOOT_FAULT       oracle negative: corrupts the checked value only

  .section .text.init
  .globl _start
_start:
#ifdef SMT_IPI
  la   t0, ipi_fail
  csrw mtvec, t0
  csrr s2, mhartid
  li   t0, 2
  bgeu s2, t0, ipi_fail
  la   t0, ipi_active
  ld   s6, 0(t0)
  li   t0, 1
  sll  t0, t0, s2
  and  t0, t0, s6
  beqz t0, ipi_park
  la   s5, ipi_state
  slli t0, s2, 6
  add  s0, s5, t0
  bnez s2, ipi_hart1
  # hart0: wait until the peer has armed and entered WFI, so the measured body
  # really does run beside a halted sibling rather than a starting one.
  andi t0, s6, 2
  beqz t0, ipi_body
ipi_wait_armed:
  ld   t1, 64(s5)
  beqz t1, ipi_wait_armed
  fence r, rw
ipi_body:
ipi_begin0:
  nop
  li   s1, 512
  li   s3, 0
ipi_loop:
  addi s3, s3, 1
ipi_dec:
  addi s1, s1, -1
ipi_branch:
  bnez s1, ipi_loop
ipi_end0:
  nop
  andi t0, s6, 2
  beqz t0, ipi_h0_pub
  # Wake the peer through its own CLINT MSIP slot.
  li   t1, 0x02000004
  li   t2, 1
  sw   t2, 0(t1)
  fence rw, rw
  # Per-hart routing: our own MSIP must stay clear.
  csrr t3, mip
  andi t3, t3, 8
  bnez t3, ipi_fail
ipi_wait_wake:
  ld   t1, 72(s5)
  li   t2, 0x5A
  bne  t1, t2, ipi_wait_wake
ipi_h0_pub:
  sd   s3, 8(s0)
  fence rw, rw
  li   t0, 1
  sd   t0, 16(s0)
  j    ipi_finish
ipi_hart1:
  # MSIE on, mstatus.MIE left 0 so WFI resumes in place instead of trapping.
  li   t0, 8
  csrs mie, t0
  li   t0, 1
  sd   t0, 0(s0)
  fence rw, rw
ipi_h1_wait:
  wfi
  csrr t1, mip
  andi t1, t1, 8
  beqz t1, ipi_h1_wait
  li   t1, 0x02000004
  sw   zero, 0(t1)
  fence rw, rw
  li   t0, 0x5A
  sd   t0, 8(s0)
  fence rw, rw
  li   t0, 1
  sd   t0, 16(s0)
ipi_finish:
  la   t0, ipi_done
  li   t1, 1
  sll  t1, t1, s2
  amoor.w.aqrl t2, t1, (t0)
  or   t2, t2, t1
  bne  t2, s6, ipi_park
  ld   t1, 16(s5)
  li   t2, 1
  bne  t1, t2, ipi_fail
  ld   t1, 8(s5)
  li   t2, 512
#ifdef SMT_BOOT_FAULT
  addi t2, t2, 1
#endif
  bne  t1, t2, ipi_fail
  andi t0, s6, 2
  beqz t0, ipi_pass
  ld   t1, 80(s5)
  li   t2, 1
  bne  t1, t2, ipi_fail
  ld   t1, 72(s5)
  li   t2, 0x5A
  bne  t1, t2, ipi_fail
ipi_pass:
  li   a0, 1
  j    ipi_exit
  .balign 4
ipi_fail:
  li   a0, 3
ipi_exit:
  la   t0, tohost
  sw   a0, 0(t0)
ipi_park:
  wfi
  j    ipi_park
#elif defined(SMT_LOCK)
  la   t0, lock_fail
  csrw mtvec, t0
  csrr s2, mhartid
  li   t0, 2
  bgeu s2, t0, lock_fail
  la   t0, lock_active
  ld   s6, 0(t0)
  li   t0, 1
  sll  t0, t0, s2
  and  t0, t0, s6
  beqz t0, lock_park
  la   s0, lock_state
  slli t0, s2, 6
  add  s0, s0, t0
  la   s7, lock_word
  li   t0, 1
  sd   t0, 0(s0)
  fence rw, rw
  la   t0, lock_state
lock_barrier:
  ld   t1, 0(t0)
  ld   t2, 64(t0)
  slli t2, t2, 1
  or   t1, t1, t2
  and  t1, t1, s6
  bne  t1, s6, lock_barrier
  fence r, rw
lock_acquire:
  li   t0, 1
  amoswap.w.aq t1, t0, (s7)
  beqz t1, lock_held
#ifdef LOCK_PAUSE
  # Zihintpause PAUSE = fence w,0 = 0x0100000F. Emitted raw so the test does not
  # depend on the assembler advertising the zihintpause extension.
  .word 0x0100000F
#endif
  j    lock_acquire
lock_held:
  bnez s2, lock_begin1
lock_begin0:
  nop
  j    lock_body
lock_begin1:
  nop
lock_body:
  li   s1, 512
  li   s3, 0
lock_loop:
  addi s3, s3, 1
lock_dec:
  addi s1, s1, -1
lock_branch:
  bnez s1, lock_loop
  bnez s2, lock_end1
  j    lock_end0
lock_end0:
  nop
  j    lock_release
lock_end1:
  nop
lock_release:
  amoswap.w.rl zero, zero, (s7)
  li   t0, 512
#ifdef SMT_BOOT_FAULT
  addi t0, t0, 1
#endif
  bne  s3, t0, lock_fail
  sd   s3, 8(s0)
  fence rw, rw
  li   t0, 1
  sd   t0, 16(s0)
  la   t0, lock_done
  li   t1, 1
  sll  t1, t1, s2
  amoor.w.aqrl t2, t1, (t0)
  or   t2, t2, t1
  bne  t2, s6, lock_park
  la   t0, lock_state
  li   t5, 1
lock_verify:
  and  t6, s6, t5
  beqz t6, lock_verify_next
  ld   t1, 16(t0)
  li   t2, 1
  bne  t1, t2, lock_fail
  ld   t1, 8(t0)
  li   t2, 512
  bne  t1, t2, lock_fail
lock_verify_next:
  addi t0, t0, 64
  slli t5, t5, 1
  li   t6, 4
  bltu t5, t6, lock_verify
  li   a0, 1
  j    lock_exit
  .balign 4
lock_fail:
  li   a0, 3
lock_exit:
  la   t0, tohost
  sw   a0, 0(t0)
lock_park:
  wfi
  j    lock_park
#elif defined(SMT_PMUMISS)
  la   t0, pmumiss_fail
  csrw mtvec, t0
  csrr s2, mhartid
  li   t0, 2
  bgeu s2, t0, pmumiss_fail
  la   s0, pmumiss_state
  slli t0, s2, 6
  add  s0, s0, t0
  la   s8, pmumiss_buf
  li   t0, 2                 # group 0 index 2 = L1 D-cache misses
  csrw 0x323, t0
  li   t0, 1
  sd   t0, 0(s0)
  fence rw, rw
  la   t0, pmumiss_state
pmumiss_barrier:
  ld   t1, 0(t0)
  ld   t2, 64(t0)
  slli t2, t2, 1
  or   t1, t1, t2
  li   t3, 3
  bne  t1, t3, pmumiss_barrier
  fence r, rw
  csrr s4, 0xB03
  bnez s2, pmumiss_reg
  # hart0: stride past the 32 KiB D$ so each access allocates an MSHR
  li   s1, 64
  li   s6, 1024
  mv   a0, s8
pmumiss_loop:
  ld   a1, 0(a0)
  add  a0, a0, s6
  addi s1, s1, -1
  bnez s1, pmumiss_loop
  j    pmumiss_done
pmumiss_reg:
  # hart1: no memory access at all, but long enough to be active across hart0's misses
  li   s1, 4096
  li   s3, 0
pmumiss_regloop:
  addi s3, s3, 1
  addi s1, s1, -1
  bnez s1, pmumiss_regloop
pmumiss_done:
  csrr s5, 0xB03
  sub  s5, s5, s4
  sd   s5, 8(s0)
  fence rw, rw
  li   t0, 1
  sd   t0, 16(s0)
  la   t0, pmumiss_done_mask
  li   t1, 1
  sll  t1, t1, s2
  amoor.w.aqrl t2, t1, (t0)
  or   t2, t2, t1
  li   t3, 3
  bne  t2, t3, pmumiss_park
  la   t0, pmumiss_state
  ld   t1, 16(t0)
  li   t2, 1
  bne  t1, t2, pmumiss_fail
  ld   t1, 80(t0)
  li   t2, 1
  bne  t1, t2, pmumiss_fail
  # hart0 must see its own misses
  ld   t1, 8(t0)
  li   t2, PMUMISS_LO0
  bltu t1, t2, pmumiss_fail
  li   t2, PMUMISS_HI0
  bgtu t1, t2, pmumiss_fail
  # hart1 never touched memory: any count here is a foreign miss
  ld   t1, 72(t0)
  li   t2, PMUMISS_LO1
  bltu t1, t2, pmumiss_fail
  li   t2, PMUMISS_HI1
  bgtu t1, t2, pmumiss_fail
  li   a0, 1
  j    pmumiss_exit
  .balign 4
pmumiss_fail:
  li   a0, 3
pmumiss_exit:
  la   t0, tohost
  sw   a0, 0(t0)
pmumiss_park:
  wfi
  j    pmumiss_park
#elif defined(SMT_PMUEVT)
  la   t0, pmuevt_fail
  csrw mtvec, t0
  csrr s2, mhartid
  li   t0, 2
  bgeu s2, t0, pmuevt_fail
  la   s0, pmuevt_state
  slli t0, s2, 6
  add  s0, s0, t0
  la   s8, pmuevt_buf
  li   t0, 5
  csrw 0x323, t0
  li   s1, 256
  beqz s2, pmuevt_have_n
  li   s1, 768
pmuevt_have_n:
  li   t0, 1
  sd   t0, 0(s0)
  fence rw, rw
  la   t0, pmuevt_state
pmuevt_barrier:
  ld   t1, 0(t0)
  ld   t2, 64(t0)
  slli t2, t2, 1
  or   t1, t1, t2
  li   t3, 3
  bne  t1, t3, pmuevt_barrier
  fence r, rw
  # Measured window: the counted loads are the only memory accesses between the
  # two counter reads. The quotas are large enough to span many handoffs, so a
  # peer's loads really do execute inside this window.
  csrr s4, 0xB03
pmuevt_loop:
  ld   a1, 0(s8)
  addi s1, s1, -1
  bnez s1, pmuevt_loop
  csrr s5, 0xB03
  sub  s5, s5, s4
  sd   s5, 8(s0)
  fence rw, rw
  li   t0, 1
  sd   t0, 16(s0)
  la   t0, pmuevt_done
  li   t1, 1
  sll  t1, t1, s2
  amoor.w.aqrl t2, t1, (t0)
  or   t2, t2, t1
  li   t3, 3
  bne  t2, t3, pmuevt_park
  la   t0, pmuevt_state
  ld   t1, 16(t0)
  li   t2, 1
  bne  t1, t2, pmuevt_fail
  ld   t1, 8(t0)
  li   t2, PMUEVT_LO0
  bltu t1, t2, pmuevt_fail
  li   t2, PMUEVT_HI0
  bgtu t1, t2, pmuevt_fail
  ld   t1, 80(t0)
  li   t2, 1
  bne  t1, t2, pmuevt_fail
  ld   t1, 72(t0)
  li   t2, PMUEVT_LO1
  bltu t1, t2, pmuevt_fail
  li   t2, PMUEVT_HI1
  bgtu t1, t2, pmuevt_fail
  li   a0, 1
  j    pmuevt_exit
  .balign 4
pmuevt_fail:
  li   a0, 3
pmuevt_exit:
  la   t0, tohost
  sw   a0, 0(t0)
pmuevt_park:
  wfi
  j    pmuevt_park
#elif defined(SMT_PMU)
  la   t0, pmu_fail
  csrw mtvec, t0
  csrr s2, mhartid
  li   t0, 2
  bgeu s2, t0, pmu_fail
  la   s0, pmu_state
  slli t0, s2, 6
  add  s0, s0, t0
  la   s1, pmu_step
  # mscratch is an architecturally per-hart CSR, so it is the control that shows
  # the bank itself works; mhpmevent3 is the register under test.
  li   t0, 0x100
  add  t0, t0, s2
  csrw mscratch, t0
  bnez s2, pmu_hart1
  li   t0, 1
  csrw 0x323, t0
  fence rw, rw
  li   t0, 1
  sw   t0, 0(s1)
pmu_h0_wait:
  lw   t1, 0(s1)
  li   t2, 2
  bne  t1, t2, pmu_h0_wait
  fence r, rw
  csrr t3, 0x323
  j    pmu_publish
pmu_hart1:
  lw   t1, 0(s1)
  li   t2, 1
  bne  t1, t2, pmu_hart1
  fence r, rw
  csrr t3, 0x323
  li   t0, 2
  csrw 0x323, t0
  fence rw, rw
  li   t0, 2
  sw   t0, 0(s1)
pmu_publish:
  sd   t3, 8(s0)
  csrr t4, mscratch
  sd   t4, 16(s0)
  fence rw, rw
  li   t0, 1
  sd   t0, 24(s0)
  la   t0, pmu_done
  li   t1, 1
  sll  t1, t1, s2
  amoor.w.aqrl t2, t1, (t0)
  or   t2, t2, t1
  li   t5, 3
  bne  t2, t5, pmu_park
  la   t0, pmu_state
  ld   t1, 24(t0)
  li   t2, 1
  bne  t1, t2, pmu_fail
  ld   t1, 8(t0)
  li   t2, PMU_EXP_H0
  bne  t1, t2, pmu_fail
  ld   t1, 16(t0)
  li   t2, 0x100
#ifdef SMT_BOOT_FAULT
  addi t2, t2, 1
#endif
  bne  t1, t2, pmu_fail
  ld   t1, 88(t0)
  li   t2, 1
  bne  t1, t2, pmu_fail
  ld   t1, 72(t0)
  li   t2, PMU_EXP_H1
  bne  t1, t2, pmu_fail
  ld   t1, 80(t0)
  li   t2, 0x101
  bne  t1, t2, pmu_fail
  li   a0, 1
  j    pmu_exit
  .balign 4
pmu_fail:
  li   a0, 3
pmu_exit:
  la   t0, tohost
  sw   a0, 0(t0)
pmu_park:
  wfi
  j    pmu_park
#elif defined(SMT_ASYM)
  la   t0, asym_fail
  csrw mtvec, t0
  csrr s2, mhartid
  li   t0, 2
  bgeu s2, t0, asym_fail
  la   t0, asym_active
  ld   s6, 0(t0)
  li   t0, 1
  sll  t0, t0, s2
  and  t0, t0, s6
  beqz t0, asym_park
  la   s0, asym_state
  slli t0, s2, 6
  add  s0, s0, t0
  la   t0, asym_roles
  ld   t1, 0(t0)
  srl  t1, t1, s2
  andi s7, t1, 1
  la   s8, asym_buf
  li   s4, 1024
  beqz s7, asym_ready
#ifndef SMT_DEP
  # Memory role seeds one distinct value per touched line before the measured
  # region, so the later loads have a checkable expected sum rather than zeroes.
  mv   a0, s8
  li   t1, 0
  li   t2, ASYM_MEM_ITERS
asym_seed:
  sd   t1, 0(a0)
  add  a0, a0, s4
  addi t1, t1, 1
  blt  t1, t2, asym_seed
  fence rw, rw
#endif
asym_ready:
  li   t0, 1
  sd   t0, 0(s0)
  fence rw, rw
  la   t0, asym_state
asym_barrier:
  ld   t1, 0(t0)
  ld   t2, 64(t0)
  slli t2, t2, 1
  or   t1, t1, t2
  and  t1, t1, s6
  bne  t1, s6, asym_barrier
  li   s3, 0
  bnez s2, asym_begin1
asym_begin0:
  nop
  j    asym_role
asym_begin1:
  nop
asym_role:
  bnez s7, asym_mem_setup
#ifndef SMT_DEP
  li   s1, 512
asym_cmp_add:
  addi s3, s3, 1
asym_cmp_xor:
  xori s5, s3, 0x55
asym_cmp_dec:
  addi s1, s1, -1
asym_cmp_branch:
  bnez s1, asym_cmp_add
  li   t0, 512
  bnez s2, asym_end1
  j    asym_end0
asym_mem_setup:
  mv   a0, s8
  li   s1, ASYM_MEM_ITERS
asym_mem_load:
  ld   a1, 0(a0)
asym_mem_add:
  add  s3, s3, a1
asym_mem_step:
  add  a0, a0, s4
asym_mem_dec:
  addi s1, s1, -1
asym_mem_branch:
  bnez s1, asym_mem_load
  li   t0, ASYM_MEM_SUM
  bnez s2, asym_end1
  j    asym_end0
#else
  # dep: three multiplies chained through s3 (s4 == 1, so s3 stays 1)
  li   s3, 1
  li   s4, 1
  li   s1, 512
asym_dep_a:
  mul  s3, s3, s4
asym_dep_b:
  mul  s3, s3, s4
asym_dep_c:
  mul  s3, s3, s4
asym_dep_d:
  addi s1, s1, -1
asym_dep_br:
  bnez s1, asym_dep_a
  li   t0, 1
  bnez s2, asym_end1
  j    asym_end0
asym_mem_setup:
  # ind: same instruction count, independent destinations
  li   s1, 512
  li   t3, 0
  li   t4, 0
asym_ind_a:
  addi s3, s3, 1
asym_ind_b:
  addi t3, t3, 1
asym_ind_c:
  addi t4, t4, 1
asym_ind_d:
  addi s1, s1, -1
asym_ind_br:
  bnez s1, asym_ind_a
  li   t0, 512
  bnez s2, asym_end1
  j    asym_end0
#endif
asym_end0:
  nop
  j    asym_check
asym_end1:
  nop
asym_check:
#ifdef SMT_BOOT_FAULT
  addi t0, t0, 1
#endif
  bne  s3, t0, asym_fail
  sd   s3, 8(s0)
  fence rw, rw
  li   t0, 1
  sd   t0, 16(s0)
  la   t0, asym_done
  li   t1, 1
  sll  t1, t1, s2
  amoor.w.aqrl t2, t1, (t0)
  or   t2, t2, t1
  bne  t2, s6, asym_park
  la   t0, asym_state
  la   t4, asym_roles
  ld   t4, 0(t4)
  li   t5, 1
asym_verify:
  and  t6, s6, t5
  beqz t6, asym_verify_next
  ld   t1, 16(t0)
  li   t2, 1
  bne  t1, t2, asym_fail
  and  t6, t4, t5
  # role bit clear = compute (or dep); set = memory (or ind)
#ifdef SMT_DEP
  li   t2, 1
  beqz t6, asym_verify_sum
  li   t2, 512
#else
  li   t2, 512
  beqz t6, asym_verify_sum
  li   t2, ASYM_MEM_SUM
#endif
asym_verify_sum:
  ld   t1, 8(t0)
  bne  t1, t2, asym_fail
asym_verify_next:
  addi t0, t0, 64
  slli t5, t5, 1
  li   t6, 4
  bltu t5, t6, asym_verify
asym_pass:
  li   a0, 1
  j    asym_exit
  .balign 4
asym_fail:
  li   a0, 3
asym_exit:
  la   t0, tohost
  sw   a0, 0(t0)
asym_park:
  wfi
  j    asym_park
#elif defined(SMT_BALANCE)
  la   t0, balance_fail
  csrw mtvec, t0
  csrr s2, mhartid
  li   t0, 2
  bgeu s2, t0, balance_fail
  la   t0, balance_active
  ld   s6, 0(t0)
  li   t0, 1
  sll  t0, t0, s2
  and  t0, t0, s6
  beqz t0, balance_park
  la   s0, balance_state
  slli t0, s2, 6
  add  s0, s0, t0
  li   t0, 1
  sd   t0, 0(s0)
  fence rw, rw
  la   t0, balance_state
balance_barrier:
  ld   t1, 0(t0)
  ld   t2, 64(t0)
  slli t2, t2, 1
  or   t1, t1, t2
  and  t1, t1, s6
  bne  t1, s6, balance_barrier
  li   s1, 512
  li   s3, 0
  addi s4, s2, 1
  bnez s2, balance_begin1
balance_begin0:
  nop
  j    balance_loop
balance_begin1:
  nop
balance_loop:
  add  s3, s3, s4
balance_xor:
  xori s5, s3, 0x55
balance_dec:
  addi s1, s1, -1
balance_branch:
  bnez s1, balance_loop
balance_loop_end:
  bnez s2, balance_end1
balance_end0:
  nop
  j    balance_check
balance_end1:
  nop
balance_check:
  li   t0, 512
  beqz s2, balance_expected
  slli t0, t0, 1
balance_expected:
#ifdef SMT_BOOT_FAULT
  addi t0, t0, 1
#else
  addi t0, t0, 0
#endif
  bne  s3, t0, balance_fail
  xori t1, t0, 0x55
  bne  s5, t1, balance_fail
  sd   s3, 8(s0)
  fence rw, rw
  li   t0, 1
  sd   t0, 16(s0)
  li   t0, 3
  bne  s6, t0, balance_pass
  bnez s2, balance_park
  la   t0, balance_state
balance_wait:
  ld   t1, 80(t0)
  beqz t1, balance_wait
  fence r, rw
  ld   t1, 8(t0)
  li   t2, 512
  bne  t1, t2, balance_fail
  ld   t1, 72(t0)
  li   t2, 1024
  bne  t1, t2, balance_fail
balance_pass:
  li   a0, 1
  j    balance_exit
  .balign 4
balance_fail:
  li   a0, 3
balance_exit:
  la   t0, tohost
  sw   a0, 0(t0)
balance_park:
  wfi
  j    balance_park
#elif defined(SMT_LRSC_DEP)
  la   t0, lr_fail
  csrw mtvec, t0
  csrr s2, mhartid
  la   s0, lr_words
  slli t0, s2, 6
  add  s0, s0, t0
  li   t0, 32
lr_retry:
  mv   a0, s0
  li   a1, 2
  li   a2, 3
  mv   a5, a0
  lr.d.aqrl a0, (a5)
#ifdef SMT_LRSC_RS2
  bne  a1, a0, lr_fail
#elif defined(SMT_LRSC_ALU)
  addi t3, a0, 1
  li   t4, 3
  bne  t3, t4, lr_fail
#else
  bne  a0, a1, lr_fail
#endif
  sc.d.rl a4, a2, (a5)
  beqz a4, lr_done
  addi t0, t0, -1
  bnez t0, lr_retry
  j    lr_fail
lr_done:
  li   t1, 3
  ld   t2, 0(s0)
#ifdef SMT_BOOT_FAULT
  xori t1, t1, 1
#else
  xori t1, t1, 0
#endif
  bne  t2, t1, lr_fail
  la   t0, lr_seen
  li   t1, 1
  sll  t1, t1, s2
  amoor.w.aqrl zero, t1, (t0)
  bnez s2, lr_park
lr_wait:
  lw   t1, 0(t0)
  li   t2, 3
  bne  t1, t2, lr_wait
  li   a0, 1
  j    lr_exit
lr_fail:
  li   a0, 3
lr_exit:
  la   t0, tohost
  sw   a0, 0(t0)
lr_park:
  wfi
  j    lr_park
#elif defined(SMT_BOOT_RENDEZVOUS)
  la   t0, boot_fail
  csrw mtvec, t0
  csrr s2, mhartid
  li   t0, 2
  bgeu s2, t0, boot_fail
  la   s0, rendezvous
  li   t1, 1
  sll  t2, t1, s2
  addi t3, s0, 4
  amoor.w.aqrl zero, t2, (t3)
  amoswap.w.aqrl s1, t1, (s0)
  bnez s1, boot_loser
boot_winner_wait:
  lw   t2, 8(s0)
  beqz t2, boot_winner_wait
  li   t2, 0x13572468
  sw   t2, 16(s0)
  fence rw, rw
  li   t2, 2
  sw   t2, 0(s0)
boot_done_wait:
  lw   t2, 12(s0)
  beqz t2, boot_done_wait
  fence r, rw
  lw   t2, 4(s0)
  li   t3, 3
  bne  t2, t3, boot_fail
  li   a0, 1
  j    boot_exit
boot_loser:
  li   t2, 1
  bne  s1, t2, boot_fail
  sw   t2, 8(s0)
boot_release_wait:
  lw   t2, 0(s0)
  li   t3, 2
  bne  t2, t3, boot_release_wait
  fence r, rw
  lw   t2, 16(s0)
  li   t3, 0x13572468
#ifdef SMT_BOOT_FAULT
  xori t3, t3, 1
#else
  xori t3, t3, 0
#endif
  bne  t2, t3, boot_fail
  li   t2, 1
  sw   t2, 12(s0)
boot_park:
  wfi
  j    boot_park
boot_fail:
  li   a0, 3
boot_exit:
  la   t0, tohost
  sw   a0, 0(t0)
  j    boot_park
#else
  csrr t0, mhartid
  bnez t0, peer_pass

  li   t1, 2000
1:
  addi t1, t1, -1
  andi t2, t1, 3
  bnez t2, 2f
  nop
2:
  bnez t1, 1b
3:
  wfi
  j    3b

peer_pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
4: j    4b
#endif

#ifdef SMT_IPI
  .section .data
  .align 6
ipi_state:
  .zero 128
ipi_active:
  .dword IPI_ACTIVE
ipi_done:
  .word 0
#endif
#ifdef SMT_LOCK
  .section .data
  .align 6
lock_state:
  .zero 128
lock_active:
  .dword LOCK_ACTIVE
lock_done:
  .word 0
  .align 6
lock_word:
  .word 0
#endif
#ifdef SMT_PMUMISS
  .section .data
  .align 6
pmumiss_state:
  .zero 128
pmumiss_done_mask:
  .word 0
  .section .bss
  .align 12
pmumiss_buf:
  .zero 65536
#endif
#ifdef SMT_PMUEVT
  .section .data
  .align 6
pmuevt_state:
  .zero 128
pmuevt_done:
  .word 0
  .section .bss
  .align 6
pmuevt_buf:
  .zero 64
#endif
#ifdef SMT_PMU
  .section .data
  .align 6
pmu_state:
  .zero 128
pmu_step:
  .word 0
pmu_done:
  .word 0
#endif
#ifdef SMT_ASYM
  .section .data
  .align 6
asym_state:
  .zero 128
asym_roles:
  .dword ASYM_ROLES
asym_active:
  .dword ASYM_ACTIVE
asym_done:
  .word 0
  .section .bss
  .align 12
asym_buf:
  # Sized for the deepest swept miss count at stride 1024 (256 x 1 KiB).
  .zero 262144
#endif
#ifdef SMT_BALANCE
  .section .data
  .align 6
balance_state:
  .zero 128
balance_active:
#ifdef SMT_BALANCE_SOLO
  .dword (1 << SMT_BALANCE_SOLO)
#else
  .dword 3
#endif
#endif
#ifdef SMT_LRSC_DEP
  .section .data
  .align 6
lr_words:
  .dword 2
  .zero 56
  .dword 2
  .zero 56
lr_seen:
  .word 0
#endif
#ifdef SMT_BOOT_RENDEZVOUS
  .section .data
  .align 6
rendezvous:
  .word 0, 0, 0, 0, 0
#endif

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
