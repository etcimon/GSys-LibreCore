# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# No fetch under the new context across a trap entry (rfix131a-04).
#
# Reproduces the S-mode `[mmu-ife] cause=12` class of the Linux witness
# (hyp8-osbi-scalar-r127m: 490 records; 272 of them ITLB *hits* on user
# addresses): when a trap is taken from U-mode the privilege switches at the
# commit edge, and the frontend still presents its user window for a cycle
# before the redirect lands. That window is looked up under S-mode: a U
# page fetched in S-mode is a page fault, presented to a fetch nobody owns.
# No instruction announces this context switch, so the dispatch barrier of
# rfix131a-02 does not cover it.
#
# U-mode code (root entry 0: 1 GiB leaf with U at VA 0) traps 128 times
# into an S-mode handler at the kernel-image alias (root entry 510, no U)
# which returns with sret:
#   phase 1: 64 ecalls -- a CSR-class instruction, so the context barrier of
#            rfix131a-02 already holds the frontend behind it;
#   phase 2: 64 illegal instructions -- a trap no instruction class
#            announces (as an interrupt or a page fault would be).
# No page fault is architectural: the log must hold no `[mmu-ife]` and no
# `[ptw-err]`.
# tohost = 1 on success; 3: unexpected scause; 5: phase-2 trap count wrong;
# ((16 + mcause) << 1) | 1: an unexpected M-mode trap.
.option norvc
.section .text.init
.globl _start
_start:
  la    t0, m_trap
  csrw  mtvec, t0
  li    t0, -1
  csrw  pmpaddr0, t0
  li    t0, 0x1f
  csrw  pmpcfg0, t0
  li    t0, 0x104             # delegate ecall-from-U and illegal instruction
  csrw  medeleg, t0
  csrw  mideleg, x0
  la    t0, root_pt
  li    t1, 0x200000cf        # entry 510: S leaf at PA 0x8000_0000
  li    t2, 510*8
  add   t2, t2, t0
  sd    t1, 0(t2)
  li    t1, 0x200000df        # entry 0: U leaf at PA 0x8000_0000
  sd    t1, 0(t0)
  fence
  srli  t1, t0, 12
  li    t2, 8
  slli  t2, t2, 60
  or    t1, t1, t2
  csrw  satp, t1
  sfence.vma
  la    t0, s_trap
  li    t1, -1
  slli  t1, t1, 32
  or    t0, t0, t1            # kernel-image alias
  csrw  stvec, t0
  li    t0, 0x1800
  csrc  mstatus, t0           # MPP = U
  la    t0, u_entry
  li    t1, 1
  slli  t1, t1, 31
  sub   t0, t0, t1            # user alias (VA = PA - 0x8000_0000)
  csrw  mepc, t0
  li    a7, 0
  mret

# ---- U-mode (runs at the user alias) ------------------------------------
.align 4
u_entry:
  li    s1, 64
  li    s2, 0
1:
  addi  s2, s2, 3
  ecall
  addi  s2, s2, 5
  addi  s1, s1, -1
  bnez  s1, 1b
  li    s1, 64
  li    a5, 0                 # the handler counts phase-2 traps here
2:
  addi  s2, s2, 3
  .word 0                     # illegal instruction
  addi  s2, s2, 5
  addi  s1, s1, -1
  bnez  s1, 2b
  li    a7, 1
  li    t0, 64
  beq   a5, t0, 3f
  li    a7, 5
3:
  ecall
u_hang:
  j     u_hang

# ---- S-mode handler (kernel-image alias) ---------------------------------
.align 4
s_trap:
  csrr  t0, scause
  li    t1, 2
  bne   t0, t1, 1f
  addi  a5, a5, 1             # illegal instruction: count and skip
  j     2f
1:
  li    t1, 8
  bne   t0, t1, s_bad
  bnez  a7, s_exit
2:
  csrr  t0, sepc
  addi  t0, t0, 4
  csrw  sepc, t0
  sret
s_exit:
  mv    a6, a7
  ecall                       # to M-mode: report
s_bad:
  li    a6, 3
  ecall

# ---- M-mode --------------------------------------------------------------
.align 4
m_trap:
  csrr  t0, mcause
  li    t1, 9                 # ecall from S-mode: the report
  bne   t0, t1, m_bad
  mv    t0, a6
  j     m_report
m_bad:
  addi  t0, t0, 16
  slli  t0, t0, 1
  addi  t0, t0, 1
m_report:
  la    t1, tohost
  sw    t0, 0(t1)
m_done:
  j     m_done

.section .data
.align 12
root_pt:
  .fill 512, 8, 0

.section .tohost,"aw",@progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
