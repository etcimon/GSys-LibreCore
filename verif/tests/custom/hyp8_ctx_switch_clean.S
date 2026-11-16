# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Nothing executes under a stale privilege / translation context (rfix131a).
#
# Reproduces the two largest `[ptw-err]` sub-classes of the Linux witness
# (hyp8-osbi-scalar-r127m: 29,141 records, ~2.2k of them architectural):
#
#  1. 16,553 x `[ptw-err] vaddr=00000000800004f0 instr=1`: at `mret` the
#     privilege/translation context switches before the fetch redirect, so
#     the M-mode return window is looked up under the S-mode `satp`, misses
#     and starts a walk nobody owns (r100/T42 "foreign walk").
#  2. 4,635 x `[ptw-err] vaddr=000000008004xxxx instr=0`: OpenSBI
#     sbi_get_insn -- `csrrw mtvec; csrrs mstatus,MPRV; lhu; csrw mstatus;
#     csrw mtvec; ld (sp)` -- the load behind the restoring CSR write is
#     translated under the stale MPRV context and walks the S-mode table for
#     a physical address. (Its mirror image, the `lhu` issued under the
#     pre-MPRV bare context, is the bus-error class of
#     hyp8_spec_bus_clean.S.)
#
# Layout mirrors the witness: M-mode firmware runs at physical addresses the
# S-mode page table does not map (root entry 2 invalid); the S-mode payload
# runs at the kernel-image alias 0xffff_ffff_8000_0000 (root entry 510).
# S-mode makes 64 ecalls; the M-mode handler reads the trapping instruction
# through the MPRV window and returns.
#
# No page fault is architectural in this test, so the log must contain no
# `[ptw-err]`, no `[mmu-ife]` and no `Response Errored`
# (run_hyp8_probe.py HYP8_PROBE_CLEAN). tohost = 1 on success; 3: the MPRV
# read of the trapping instruction is wrong; 5: S-mode data compare failed;
# ((16 + mcause) << 1) | 1: an unexpected trap.
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
  la    sp, m_stack_top
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

# ---- S-mode payload (runs at the alias) ---------------------------------
s_entry:
  la    s3, dat
  li    s1, 64
  li    s6, 0x0123456789abcdef
  li    a7, 0
s_loop:
  sd    s6, 0(s3)
  ld    a0, 0(s3)
  bne   a0, s6, s_fail
  addi  s6, s6, 0x111
  ecall
  addi  s1, s1, -1
  bnez  s1, s_loop
  li    a7, 1                 # done
  ecall
s_hang:
  j     s_hang
s_fail:
  li    a7, 5
  ecall
  j     s_hang

# ---- M-mode firmware (physical; not mapped for S-mode) -------------------
.align 4
m_trap:
  csrr  t0, mcause
  li    t1, 9                 # ecall from S-mode
  bne   t0, t1, m_bad
  csrr  t0, mepc
  # sbi_get_insn: read the trapping instruction through the MPRV window
  la    t2, m_bad
  csrrw t2, mtvec, t2
  li    t3, 0x20000
  csrrs t4, mstatus, t3       # MPRV on
  lhu   t5, 0(t0)
  andi  t6, t5, 3
  addi  t6, t6, -3
  bnez  t6, 1f                # 32-bit encoding: read the upper half too
  lhu   t6, 2(t0)
1:
  # a slow older instruction keeps the restoring CSR write from committing
  # while the loads behind it are already in the pipeline (in the witness
  # the same window is opened by cache misses)
  li    t1, 1
  div   t3, t5, t1
  div   t3, t3, t1
  csrw  mstatus, t4           # MPRV off
  csrw  mtvec, t2
  ld    t1, -8(sp)            # physical loads right behind the context restore
  ld    t3, -16(sp)
  li    t1, 0x73              # ecall = 0x00000073
  bne   t5, t1, m_insn
  bnez  t6, m_insn
  bnez  a7, m_exit
  addi  t0, t0, 4
  csrw  mepc, t0
  # trap-exit register restore, as in the firmware: the frontend runs ahead
  # of the mret through the code that follows it
  ld    t1, -8(sp)
  ld    t2, -16(sp)
  ld    t3, -24(sp)
  ld    t4, -32(sp)
  ld    t5, -40(sp)
  ld    t6, -48(sp)
  ld    t1, -56(sp)
  ld    t2, -64(sp)
  ld    t3, -72(sp)
  ld    t4, -80(sp)
  ld    t5, -88(sp)
  ld    t6, -96(sp)
  # the firmware's trap exit: `csrw mstatus` ends a fetch line, the line
  # behind it holds two loads and the mret (0x800004ec..0x800004f6 in the
  # witness firmware)
  csrr  t4, mstatus
  .align 4
  nop
  nop
  nop
  csrw  mstatus, t4
  ld    t1, -8(sp)
  ld    t2, -16(sp)
  mret
  nop
  .align 4
m_exit:
  mv    t0, a7                # 1 = pass, 5 = S-mode data compare failed
  j     m_report
m_insn:
  li    t0, 3
  j     m_report
m_bad:
  csrr  t0, mcause
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
.align 12
dat:
  .fill 16, 8, 0
.align 6
m_stack:
  .fill 64, 8, 0
m_stack_top:

.section .tohost,"aw",@progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
