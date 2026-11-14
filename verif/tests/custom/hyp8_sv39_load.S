# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Translated loads and stores in S-mode under Sv39 (r127). The other hyp8
# smokes run in M-mode with translation off, so none of them reaches the
# ITLB / DTLB / PTW; the first translated load of the Linux witness is ~22 M
# cycles in. This test gets there in a few thousand cycles: M-mode opens the
# PMP, maps the 1 GiB page at 0x8000_0000 onto itself (one root PTE), turns
# on satp, and drops to S-mode, where a store/load loop runs over a data
# page (first access misses the DTLB, the rest hit) followed by sub-word
# accesses and a load that depends on a just-translated store.
#
# tohost = 1 on success; 3 = a data compare failed in S-mode;
# ((16 + mcause) << 1) | 1 = an unexpected trap (written from M-mode).
# A wedge shows as a budget-out.
.option norvc
.section .text.init
.globl _start
_start:
  la    t0, m_trap
  csrw  mtvec, t0
  # PMP entry 0: NAPOT over the whole address space, RWX, for S/U.
  li    t0, -1
  csrw  pmpaddr0, t0
  li    t0, 0x1f
  csrw  pmpcfg0, t0
  # Root page table: entry 2 (VA 0x8000_0000) -> 1 GiB leaf at PA 0x8000_0000,
  # V|R|W|X|A|D.
  la    t0, root_pt
  li    t1, 0x200000cf
  sd    t1, 16(t0)
  fence
  srli  t1, t0, 12
  li    t2, 8
  slli  t2, t2, 60
  or    t1, t1, t2
  csrw  satp, t1
  sfence.vma
  # mstatus.MPP = S, then mret into the translated region.
  li    t0, 0x1800
  csrc  mstatus, t0
  li    t0, 0x0800
  csrs  mstatus, t0
  la    t0, s_entry
  csrw  mepc, t0
  mret

s_entry:
  la    a5, dat
  li    a6, 64                # dwords
  li    t0, 0x0123456789abcdef
  mv    a4, a5
  mv    a3, a6
1:
  sd    t0, 0(a4)
  addi  t0, t0, 0x111
  addi  a4, a4, 8
  addi  a3, a3, -1
  bnez  a3, 1b
  li    t0, 0x0123456789abcdef
  mv    a4, a5
  mv    a3, a6
2:
  ld    t1, 0(a4)
  bne   t1, t0, s_fail
  addi  t0, t0, 0x111
  addi  a4, a4, 8
  addi  a3, a3, -1
  bnez  a3, 2b
  # sub-word store, then loads that must see it (forward or memory)
  li    t0, 0xa5
  sb    t0, 3(a5)
  lbu   t1, 3(a5)
  bne   t1, t0, s_fail
  li    t0, 0x5aa5
  sh    t0, 10(a5)
  lhu   t1, 10(a5)
  bne   t1, t0, s_fail
  lw    t1, 8(a5)             # word around the half store
  srli  t1, t1, 16
  li    t2, 0xffff
  and   t1, t1, t2
  bne   t1, t0, s_fail
  # pointer chase through a just-stored address
  addi  t0, a5, 256
  sd    t0, 128(a5)
  ld    t1, 128(a5)
  li    t2, 0x77
  sd    t2, 0(t1)
  ld    t3, 256(a5)
  bne   t3, t2, s_fail
  li    t0, 1
  la    t1, tohost
  sw    t0, 0(t1)
s_done:
  j     s_done
s_fail:
  li    t0, 3
  la    t1, tohost
  sw    t0, 0(t1)
  j     s_done

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
  .fill 128, 8, 0

.section .tohost,"aw",@progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
