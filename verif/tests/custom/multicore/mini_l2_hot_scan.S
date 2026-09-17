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

#ifdef G6LC_LOCALITY_PROBE
#ifndef LOCAL_NODES
#define LOCAL_NODES 1024
#endif
#ifndef LOCAL_STEPS
#define LOCAL_STEPS 8192
#endif
#if LOCAL_NODES < 128 || LOCAL_NODES > 8192 || (LOCAL_NODES & (LOCAL_NODES - 1))
#error LOCAL_NODES_must_be_a_power_of_two_in_128_to_8192
#endif
#if LOCAL_STEPS < LOCAL_NODES || LOCAL_STEPS % LOCAL_NODES
#error LOCAL_STEPS_must_be_a_positive_multiple_of_LOCAL_NODES
#endif

  .section .text.init
  .globl _start
  .option push
  .option norvc
_start:
  csrr t0, mhartid
  bnez t0, park
  li s0, 0x80100000
  li s1, LOCAL_NODES
  li s2, LOCAL_NODES-1
  li t0, 0
.Llocal_fill:
  addi t1, t0, 37
  and t1, t1, s2
  slli t1, t1, 3
  add t1, t1, s0
  slli t2, t0, 3
  add t2, t2, s0
  sd t1, 0(t2)
  addi t0, t0, 1
  bltu t0, s1, .Llocal_fill
  fence rw, rw

  li s3, 0
  mv s4, s0
  mv s5, s1
  jal ra, .Llocal_walk
  bne s4, s0, fail
  fence rw, rw

  li t0, 0x44
  csrw mhpmevent3, t0
  li t0, 0x02
  csrw mhpmevent4, t0
  li t0, 0x05
  csrw mhpmevent5, t0
  li t0, 0x06
  csrw mhpmevent6, t0
  li t0, 0x11
  csrw mhpmevent7, t0
  li t0, 0x01
  csrw mhpmevent8, t0
  li s5, LOCAL_STEPS
  csrr s7, mhpmcounter3
  csrr s8, mhpmcounter4
  csrr s9, mhpmcounter5
  csrr s10, mhpmcounter6
  csrr s11, mhpmcounter7
  csrr t3, mhpmcounter8
  csrr s6, mcycle
  .globl locality_roi_begin
locality_roi_begin:
  jal ra, .Llocal_walk
  bne s4, s0, fail
  .globl locality_roi_end
locality_roi_end:
  csrr t0, mcycle
  sub t0, t0, s6
  csrr s0, mhpmcounter3
  sub s0, s0, s7
  csrr s1, mhpmcounter4
  sub s1, s1, s8
  csrr s2, mhpmcounter5
  sub s2, s2, s9
  csrr s3, mhpmcounter6
  sub s3, s3, s10
  csrr s4, mhpmcounter7
  sub s4, s4, s11
  csrr s5, mhpmcounter8
  sub s5, s5, t3
  li t1, LOCAL_STEPS
  bne s2, t1, fail
  la t4, report
  sd t0, 0(t4)
  sd s0, 8(t4)
  sd s1, 16(t4)
  sd s2, 24(t4)
  sd s3, 32(t4)
  sd s4, 40(t4)
  sd s5, 48(t4)
  fence rw, rw
  li t6, 16384
.Llocal_report_wait:
  addi t6, t6, -1
  bnez t6, .Llocal_report_wait
  li a0, 1
  j write_tohost
fail:
  li a0, 3
write_tohost:
  la t0, tohost
  sw a0, 0(t0)
.Llocal_done:
  j .Llocal_done
park:
  wfi
  j park

.Llocal_walk:
  ld t0, 0(s4)
  addi s3, s3, 37
  and s3, s3, s2
  slli t1, s3, 3
  add t1, t1, s0
#ifdef LOCAL_NEGATIVE
  addi t1, t1, 8
#endif
  bne t0, t1, fail
  mv s4, t0
  addi s5, s5, -1
  bnez s5, .Llocal_walk
  ret
  .option pop
#else
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
#endif

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
