# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# All-set hot + rotating scan (leaf hot_scan, at the core). Stream8 infers
# L2 256 KiB / 8-way / 64 B → 512 sets, idx addr[14:6]. Hot is one 64 B line
# per set (32 KiB). Each round re-reads hot then a fresh 32 KiB scan tag so
# the working set exceeds the 32 KiB L1 D$ and L2 replacement (RR vs way-0)
# can differ. PASS tohost=1, FAIL tohost=3. Experimental, not a Linux SKU.

#ifndef NSETS
#define NSETS 512
#endif
#ifndef NROUNDS
#define NROUNDS 16
#endif

  .section .text.init
  .globl _start
  .option push
  .option norvc
_start:
  csrr t0, mhartid
  bnez t0, park

  li   s0, 0x80008000
  li   s1, 64
  li   s2, 32768
  li   s3, NSETS
  li   s4, NROUNDS

  // DRAM unique fill: hot tag 1 and scan tags 16..16+NROUNDS-1, every set.
  li   t0, 0
1:
  mul  t2, t0, s1
  add  t2, s0, t2
  add  t2, t2, s2
  sd   t0, 0(t2)
  addi t0, t0, 1
  blt  t0, s3, 1b
  li   t5, 0
2:
  li   t0, 0
  addi t6, t5, 16
  mul  t3, t6, s2
3:
  mul  t2, t0, s1
  add  t2, s0, t2
  add  t2, t2, t3
  xor  t4, t5, t0
  sd   t4, 0(t2)
  addi t0, t0, 1
  blt  t0, s3, 3b
  addi t5, t5, 1
  blt  t5, s4, 2b
  fence rw, rw

  // PMU select (whole-kernel report): hpm3=L2 miss (group2 idx4), hpm4=L1 D$
  // miss (idx2), hpm5=load accesses (idx5), hpm6=store accesses (idx6),
  // hpm7=L1 D$ data_req accesses (idx17), hpm8=L1 I$ miss (idx1).
  li   t0, 0x44
  csrw mhpmevent3, t0
  li   t0, 0x02
  csrw mhpmevent4, t0
  li   t0, 0x05
  csrw mhpmevent5, t0
  li   t0, 0x06
  csrw mhpmevent6, t0
  li   t0, 0x11
  csrw mhpmevent7, t0
  li   t0, 0x01
  csrw mhpmevent8, t0

  // Snapshot everything up front: report = whole-kernel counters (fill +
  // ROI), the strongest check that the L1/L2 events fire at all.
  la   t0, snap_mem
  csrr t1, mcycle
  sd   t1, 0(t0)
  csrr t1, mhpmcounter3
  sd   t1, 8(t0)
  csrr t1, mhpmcounter4
  sd   t1, 16(t0)
  csrr t1, mhpmcounter5
  sd   t1, 24(t0)
  csrr t1, mhpmcounter6
  sd   t1, 32(t0)
  csrr t1, mhpmcounter7
  sd   t1, 40(t0)
  csrr t1, mhpmcounter8
  sd   t1, 48(t0)

  // Fill L2: hot + 7 neighbour tags (set full).
  li   t5, 1
4:
  mul  t3, t5, s2
  li   t0, 0
5:
  mul  t2, t0, s1
  add  t2, s0, t2
  add  t2, t2, t3
  ld   t4, 0(t2)
  addi t0, t0, 1
  blt  t0, s3, 5b
  addi t5, t5, 1
  li   t6, 9
  blt  t5, t6, 4b

  // ROI: re-read hot, then one scan tag.
  li   t5, 0
  li   s5, 0
6:
  add  t3, s0, s2
  li   t0, 0
7:
  mul  t2, t0, s1
  add  t2, t3, t2
  ld   t4, 0(t2)
  add  s5, s5, t4
  addi t0, t0, 1
  blt  t0, s3, 7b
  addi t6, t5, 16
  mul  t3, t6, s2
  li   t0, 0
8:
  mul  t2, t0, s1
  add  t2, s0, t2
  add  t2, t2, t3
  ld   t4, 0(t2)
  addi t0, t0, 1
  blt  t0, s3, 8b
  addi t5, t5, 1
  blt  t5, s4, 6b

  // ROI counter deltas -> report (DRAM, read host-side via `log mem` rules;
  // the harness never services HTIF syscalls, so no print path exists).
  la   t5, snap_mem
  la   t4, report
  csrr t0, mcycle
  ld   t1, 0(t5)
  sub  t0, t0, t1
  sd   t0, 0(t4)
  csrr t0, mhpmcounter3
  ld   t1, 8(t5)
  sub  t0, t0, t1
  sd   t0, 8(t4)
  csrr t0, mhpmcounter4
  ld   t1, 16(t5)
  sub  t0, t0, t1
  sd   t0, 16(t4)
  csrr t0, mhpmcounter5
  ld   t1, 24(t5)
  sub  t0, t0, t1
  sd   t0, 24(t4)
  csrr t0, mhpmcounter6
  ld   t1, 32(t5)
  sub  t0, t0, t1
  sd   t0, 32(t4)
  csrr t0, mhpmcounter7
  ld   t1, 40(t5)
  sub  t0, t0, t1
  sd   t0, 40(t4)
  csrr t0, mhpmcounter8
  ld   t1, 48(t5)
  sub  t0, t0, t1
  sd   t0, 48(t4)
  fence rw, rw

  // The harness samples `report` via `log mem` rules on ~2048-cycle polls;
  // hold here so the final values are observed before tohost exits.
  li   t6, 16384
1: addi t6, t6, -1
  bnez t6, 1b

  // Hot values were the set index; NROUNDS copies of sum 0..511.
  li   t0, NSETS
  addi t0, t0, -1
  mul  t0, t0, t0
  addi t0, t0, NSETS
  srli t0, t0, 1
  li   t1, NROUNDS
  mul  t0, t0, t1
  bne  s5, t0, fail

  addi a0, x0, 1
  jal  x0, write_tohost
fail:
  addi a0, x0, 3
write_tohost:
  la   t0, tohost
  sw   a0, 0(t0)
1: jal  x0, 1b
park:
  wfi
  jal  x0, park

  .option pop

  .section .data
  .align 6
snap_mem:
  .dword 0, 0, 0, 0, 0, 0, 0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
  .align 6
  .globl report
report: .dword 0, 0, 0, 0, 0, 0, 0
