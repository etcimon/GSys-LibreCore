# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Speculative loads must not reach the bus outside idempotent memory (rfix131a).
#
# Reproduces, in a few thousand cycles, the two load patterns behind the
# 18,131 `R Response Errored` (AXI DECERR) warnings and the bulk of the
# data-side `[ptw-err]` records of the Linux witnesses
# (hyp8-osbi-scalar-r127m/r128b/r131):
#
#  A. OpenSBI sbi_get_insn / unaligned-access emulation (witness cycles
#     352.5M..368.1M): `csrrs mstatus, MPRV; lhu a0, 0(va); csrw mstatus`.
#     The load younger than the CSR write is issued under the pre-write
#     translation context (M-mode bare): its virtual address, truncated to
#     PLEN, goes to the bus as a physical address nothing decodes. The load
#     younger than the restoring CSR write is translated under the stale
#     MPRV context and walks the S-mode table for a physical address.
#  B. A wrong-path load behind a mispredicted branch whose base register
#     holds a device-space address (witness cycle 5,570,552: OpenSBI
#     `ld ..,0x468(s3)` with s3 = 0x1000_1000, the end of the UART window).
#     Two probe rounds: one past the UART window (nothing decodes it), and
#     the UART receive register itself (a read with a side effect).
#
# Architecturally the test checks data and that the wrong-path fall-through
# never executes (tohost = 1); the property under test is the log: the run
# must contain no `Response Errored` and no UART bus read
# (run_hyp8_probe.py, HYP8_PROBE_CLEAN). tohost = 3: an A data compare
# failed; 5: the B load sum is wrong; 7: the B fall-through count is wrong
# (a wrong-path instruction took architectural effect);
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
  # Sv39 root: entry 510 (VA 0xffff_ffff_8000_0000, the Linux kernel image
  # alias) -> 1 GiB leaf at PA 0x8000_0000, V|R|W|X|A|D. Entry 2 (the
  # identity alias) is deliberately left invalid: a physical address walked
  # under the stale MPRV context faults in the PTW, as in the witness.
  la    t0, root_pt
  li    t1, 0x200000cf
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
  # mstatus.MPP = S: MPRV loads translate with S-mode privilege.
  li    t0, 0x1800
  csrc  mstatus, t0
  li    t0, 0x0800
  csrs  mstatus, t0

  # ---- A: MPRV window, 64 rounds --------------------------------------
  li    a7, 0x20000           # mstatus.MPRV
  la    s3, dat               # physical
  li    t0, -1
  slli  t0, t0, 32
  or    a6, s3, t0            # kernel-alias VA of dat
  li    s1, 64
  li    s4, 0x7788
  li    s5, 0x5566
  li    s6, 0x1122334455667788
a_loop:
  csrrs a5, mstatus, a7       # MPRV on
  lhu   a0, 0(a6)             # translated: must not issue under bare
  lhu   a4, 2(a6)
  csrw  mstatus, a5           # MPRV off
  ld    a3, 0(s3)             # physical: must not walk under stale MPRV
  bne   a0, s4, fail
  bne   a4, s5, fail
  bne   a3, s6, fail
  addi  s1, s1, -1
  bnez  s1, a_loop

  # ---- B: wrong-path load with a device-space base ---------------------
  la    s0, tbl
  li    s1, 98                # 2 x (48 training rounds + a probe round)
  li    s2, 0
  li    s7, 0
  li    t1, 1
b_loop:
  ld    a0, 0(s0)             # base
  ld    a1, 8(s0)             # take-the-load flag
  div   a2, a1, t1            # resolve the branch late
  div   a2, a2, t1
  div   a2, a2, t1
  beqz  a2, b_skip            # trained not-taken; taken on the probe rounds
  addi  s7, s7, 1             # architectural executions of the fall-through
  ld    t0, 0x468(a0)         # wrong path on the probe rounds
  add   s2, s2, t0
b_skip:
  addi  s0, s0, 16
  addi  s1, s1, -1
  bnez  s1, b_loop
  li    t0, 96
  bne   s7, t0, fail_cnt
  mul   t0, t0, s6
  bne   s2, t0, fail_sum

  li    t0, 1
  la    t1, tohost
  sw    t0, 0(t1)
done:
  j     done
fail:
  li    t0, 3
  j     report
fail_sum:
  li    t0, 5
  j     report
fail_cnt:
  li    t0, 7
report:
  la    t1, tohost
  sw    t0, 0(t1)
  j     done

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
  .rept 256
  .dword 0x1122334455667788
  .endr
.align 6
tbl:
  .rept 48
  .dword dat - 0x468 + 0x400  # 0x468(base) lands on an initialized dword
  .dword 1
  .endr
  .dword 0x10001000           # one past the UART window: nothing decodes it
  .dword 0
  .rept 48
  .dword dat - 0x468 + 0x400
  .dword 1
  .endr
  .dword 0x10000000 - 0x468   # 0x468(base) is the UART receive register
  .dword 0

.section .tohost,"aw",@progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
