# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Right-path device loads and stores complete, in order (rfix131a-01/-08).
#
# With the PMA non-idempotent regions declared, a load from a device runs
# only as the commit head with the store pipe drained; one that reaches the
# load unit earlier is handed back and refetched at commit. None of the other
# smokes reads a device, so this path had never run. The program interleaves
# CLINT loads/stores with memory traffic and branches:
#   - mtimecmp (hart 0) written with a per-round value, read back at once and
#     again after memory stores: the device store is seen by the device load
#     behind it, and no value from another round is seen;
#   - mtime read twice per round: never decreases;
#   - msip written 1 then 0 and read back each time.
# tohost = 1 on success; 3 mtimecmp readback, 5 late mtimecmp readback,
# 7 mtime went backwards, 9 msip readback, 11 memory compare;
# ((16 + mcause) << 1) | 1 = an unexpected trap. A wedge is a budget-out.
# Log grade (run_hyp8_smokes.py): no bus error, no UART read.
.option norvc
.section .text.init
.globl _start
_start:
  la    t0, m_trap
  csrw  mtvec, t0
  csrw  mie, x0
  li    s0, 0x02000000        # CLINT: msip hart 0
  li    s1, 0x02004000        # CLINT: mtimecmp hart 0
  li    s2, 0x0200bff8        # CLINT: mtime
  la    s3, dat
  li    s4, 64                # rounds
  li    s5, 0x1000
  ld    s6, 0(s2)             # previous mtime
1:
  sd    s5, 0(s1)             # device store
  ld    t0, 0(s1)             # device load right behind it
  bne   t0, s5, f_cmp
  sd    s5, 0(s3)             # memory traffic between the device accesses
  sd    t0, 8(s3)
  ld    t1, 0(s3)
  ld    t2, 8(s3)
  bne   t1, s5, f_mem
  bne   t2, s5, f_mem
  ld    t3, 0(s2)             # mtime
  bltu  t3, s6, f_time
  mv    s6, t3
  li    t4, 1
  sw    t4, 0(s0)             # msip = 1
  lw    t5, 0(s0)
  bne   t5, t4, f_msip
  sw    x0, 0(s0)             # msip = 0
  lw    t5, 0(s0)
  bnez  t5, f_msip
  ld    t0, 0(s1)             # mtimecmp again, behind all of the above
  bne   t0, s5, f_late
  addi  s5, s5, 0x111
  addi  s3, s3, 16
  addi  s4, s4, -1
  bnez  s4, 1b
  li    t0, -1
  sd    t0, 0(s1)             # leave no timer pending
  li    t0, 1
report:
  la    t1, tohost
  sw    t0, 0(t1)
done:
  j     done
f_cmp:
  li    t0, 3
  j     report
f_late:
  li    t0, 5
  j     report
f_time:
  li    t0, 7
  j     report
f_msip:
  li    t0, 9
  j     report
f_mem:
  li    t0, 11
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
.align 6
dat:
  .fill 160, 8, 0

.section .tohost,"aw",@progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
