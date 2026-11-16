# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Wrong-path loads and stores do not walk the page table (rfix131a-03).
#
# Reproduces the `[ptw-err] vaddr=0 / 3 / 4 / 8 / 0x220 ... instr=0` class of
# the Linux witness (hyp8-osbi-scalar-r127m: 5,389 records, 2,933 of them for
# address 0): S-mode code under Sv39 mispredicts a branch whose fall-through
# dereferences a pointer that is null (or a small offset from null) on the
# taken path. The squashed load / store misses the DTLB and its walk ends in
# a fault nobody takes.
#
# S-mode runs at the kernel-image alias (root entry 510 -> 1 GiB leaf at
# 0x8000_0000); nothing else is mapped. The branch is trained not-taken on
# valid pointers and probed with 0, 8, 0x220 and a non-canonical value.
# No page fault is architectural here: the log must hold no `[ptw-err]` and
# no `[mmu-ife]` (run_hyp8_smokes.py grades `*_clean` programs on it).
# tohost = 1 on success; 3: load sum wrong; 5: the fall-through executed on
# a probe round; ((16 + mcause) << 1) | 1: an unexpected trap.
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
  csrw  medeleg, x0
  csrw  mideleg, x0
  la    t0, root_pt
  li    t1, 0x200000cf        # 1 GiB leaf at PA 0x8000_0000, V|R|W|X|A|D
  li    t2, 510*8
  add   t2, t2, t0
  sd    t1, 0(t2)
  fence
  srli  t1, t0, 12
  li    t2, 8
  slli  t2, t2, 60
  or    t1, t1, t2
  csrw  satp, t1
  sfence.vma
  li    t0, 0x1800
  csrc  mstatus, t0
  li    t0, 0x0800
  csrs  mstatus, t0           # MPP = S
  la    t0, s_entry
  li    t1, -1
  slli  t1, t1, 32
  or    t0, t0, t1            # kernel-image alias
  csrw  mepc, t0
  mret

s_entry:
  la    s0, tbl
  li    s1, 4*49              # 4 x (48 training rounds + a probe round)
  li    s2, 0                 # sum of loaded values
  li    s7, 0                 # fall-through executions
  li    t1, 1
1:
  ld    a0, 0(s0)             # pointer
  ld    a1, 8(s0)             # 1: dereference it
  div   a2, a1, t1            # resolve the branch late
  div   a2, a2, t1
  div   a2, a2, t1
  beqz  a2, 2f                # trained not-taken; taken on the probe rounds
  addi  s7, s7, 1
  ld    t0, 0(a0)             # wrong path on the probe rounds
  add   s2, s2, t0
  sd    t0, 8(a0)             # a wrong-path store translates as well
2:
  addi  s0, s0, 16
  addi  s1, s1, -1
  bnez  s1, 1b
  li    t0, 4*48
  bne   s7, t0, f_cnt
  li    t2, 0x0123456789abcdef
  mul   t0, t0, t2
  bne   s2, t0, f_sum
  li    t0, 1
report:
  la    t1, tohost            # the alias of tohost (pc-relative, mapped)
  sw    t0, 0(t1)
s_done:
  j     s_done
f_sum:
  li    t0, 3
  j     report
f_cnt:
  li    t0, 5
  j     report

.align 4
m_trap:
  csrr  t0, mcause
  addi  t0, t0, 16
  slli  t0, t0, 1
  addi  t0, t0, 1
  la    t1, tohost
  sw    t0, 0(t1)
m_done:
  j     m_done

.section .data
.align 12
root_pt:
  .fill 512, 8, 0
.align 12
dat:
  .dword 0x0123456789abcdef
  .dword 0
.align 6
tbl:
  .macro rounds probe
  .rept 48
  .dword dat + 0xffffffff00000000
  .dword 1
  .endr
  .dword \probe
  .dword 0
  .endm
  rounds 0
  rounds 8
  rounds 0x220
  rounds 0x00ffffff80003000   # non-canonical

.section .tohost,"aw",@progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
