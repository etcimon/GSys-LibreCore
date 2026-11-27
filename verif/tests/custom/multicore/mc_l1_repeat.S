// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Load-only repeat-access L1 hit validation, dropped into the mc_l2_write_read
// slot: ITER passes of pure loads over a cache-resident buffer. Pass 0 is
// compulsory misses; passes 1..ITER-1 must hit if the L1 retains lines.
// No stores and no data check, so the WT write path cannot confound the
// measurement. Misses are read from legacy idx2 (exact per the streaming
// calibration); architectural load count is BUF_BYTES/STRIDE*ITER, computed
// externally.
//
// tohost: (hitpct<<1)|1 via the PMU_L1 channel; pmu_out0/1/2 carry the raw
// access/miss/store deltas.

#ifndef BUF_BYTES
#define BUF_BYTES 8192
#endif
#ifndef ITER
#define ITER 9
#endif

#define BUF_BASE 0x80100000
#define STRIDE   64

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap
  csrw mtvec, t1
  bnez t0, park

#ifdef PMU_L1
  csrw 0x320, zero             // mcountinhibit: let the hpm counters run
  li   t0, 5
  csrw 0x323, t0               // mhpmevent3 = legacy idx5: load accesses
  li   t0, 2
  csrw 0x324, t0               // mhpmevent4 = legacy idx2: L1 D$ misses
  li   t0, 6
  csrw 0x325, t0               // mhpmevent5 = legacy idx6: store accesses
  csrr s6, 0xB03               // mhpmcounter3 baseline: loads
  csrr s7, 0xB04               // mhpmcounter4 baseline: misses
  csrr s8, 0xB05               // mhpmcounter5 baseline: stores
#endif

  li   s0, BUF_BASE            // buffer base
  li   s1, BUF_BYTES           // footprint in bytes
  li   s5, 0                   // pass
  li   s9, 0                   // consume accumulator
pass:
  li   t2, 0
1:
  add  t3, s0, t2
  ld   t4, 0(t3)
  xor  s9, s9, t4              // consume so the loads form a real chain
  addi t2, t2, STRIDE
  bltu t2, s1, 1b
  addi s5, s5, 1
  li   t0, ITER
  bltu s5, t0, pass

#ifdef PMU_L1
  csrr t0, 0xB03
  sub  s6, t0, s6              // access delta
  csrr t0, 0xB04
  sub  s7, t0, s7              // miss delta
  csrr t0, 0xB05
  sub  s8, t0, s8              // store delta
  sub  t1, s6, s7              // load hits = load accesses - misses
  li   t2, 100
  mul  t1, t1, t2
  divu t1, t1, s6              // integer hit percent
  la   t0, tohost
  sd   s6, 0x10(t0)            // pmu_out0: load-access delta
  sd   s7, 0x18(t0)            // pmu_out1: L1 D$ miss delta
  sd   s8, 0x20(t0)            // pmu_out2: store accesses
  slli t1, t1, 1
  ori  t1, t1, 1
#endif
  li   a0, 1
#ifdef PMU_L1
  slli a0, t1, 0
#endif
  j    done

park:
1:
  wfi
  j    1b

done:
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
1:
  wfi
  j    1b

trap:
  csrr a0, mcause
  slli a0, a0, 1
  ori  a0, a0, 1
  addi a0, a0, 32
  j    done

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .globl fromhost
fromhost: .dword 0
