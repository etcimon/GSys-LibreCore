// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Write-then-read discriminator for L2WriteUpdateEn: ITER rounds of
// {store (iter ^ addr) into word 0 of every line of the buffer; reload word 0
// of every line and check}. The WT write path self-invalidates the resident
// L2/L3 line instead of updating it, so today every read-back misses and
// refetches from DRAM — measured through [mc_cache] l2_hit / l2_selfinv.
//
// tohost: 1 pass, 3 ORACLE_NEGATIVE, 5 data mismatch; harts other than 0
// park in wfi.

#ifndef BUF_BYTES
#define BUF_BYTES 131072
#endif
#ifndef ITER
#define ITER 4
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

#ifdef PMU_G1
  // M3: publish PMU group-1 in-window deltas to pmu_out{0,1,2}
  // (mispredict / rename+ROB backpressure / IQ stall) for the uplift
  // before-after comparison. Off by default; the cycle count is unchanged.
  csrw 0x320, zero             // mcountinhibit: let the hpm counters run
  li   t0, 0x22
  csrw 0x323, t0               // mhpmevent3 = group 1 idx 2: mispredict
  li   t0, 0x20
  csrw 0x324, t0               // mhpmevent4 = group 1 idx 0: rename/ROB backpr.
  li   t0, 0x21
  csrw 0x325, t0               // mhpmevent5 = group 1 idx 1: IQ / issue stall
  csrr s6, 0xB03
  csrr s7, 0xB04
  csrr s8, 0xB05
#endif

#ifdef PMU_L1
  // Publish architectural PMU L1 D$ access/miss deltas and integer hit percent
  // to pmu_out{0,1,2}. Events 5/2/6 are the legacy load-access, L1 D$ miss,
  // and store-access events (core/perf_counters.sv). The recovery path is
  // the same RVFI mem-store slot mechanism as PMU_G1; no RTL or tohost protocol
  // change is needed. Off by default, so normal directed runs are unchanged.
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
  li   s5, 0                   // iter
iter:
  // stores: word 0 of each line = iter ^ addr
  li   t2, 0
1:
  add  t3, s0, t2
  xor  t4, t3, s5
  sd   t4, 0(t3)
  addi t2, t2, STRIDE
  bltu t2, s1, 1b
  fence rw, rw
  // loads: expect iter ^ addr
  li   t2, 0
2:
  add  t3, s0, t2
  ld   t4, 0(t3)
  xor  t5, t3, s5
#ifdef ORACLE_NEGATIVE
  xori t5, t5, 1                // arm: demand corrupted data so the check fails
#endif
  bne  t4, t5, mismatch
  addi t2, t2, STRIDE
  bltu t2, s1, 2b
  addi s5, s5, 1
  li   t0, ITER
  bltu s5, t0, iter
#ifdef PMU_G1
  csrr t0, 0xB03
  sub  s6, t0, s6
  csrr t0, 0xB04
  sub  s7, t0, s7
  csrr t0, 0xB05
  sub  s8, t0, s8
  la   t0, tohost
  sd   s6, 0x10(t0)            // pmu_out0: mispredict delta
  sd   s7, 0x18(t0)            // pmu_out1: rename/ROB backpressure delta
  sd   s8, 0x20(t0)            // pmu_out2: IQ/issue-stall delta
#endif
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
  divu t1, t1, s6              // integer hit percent (div-by-zero -> all ones)
  la   t0, tohost
  sd   s6, 0x10(t0)            // pmu_out0: load-access delta
  sd   s7, 0x18(t0)            // pmu_out1: L1 D$ miss delta
  sd   s8, 0x20(t0)            // pmu_out2: store accesses
  slli t1, t1, 1               // fast no-RVFI channel: tohost=(pct<<1)|1,
  ori  t1, t1, 1               // so tracer program-exit bits carry the percent
#endif
  li   a0, 1
#ifdef PMU_L1
  slli a0, t1, 0               // PMU_L1 overrides the pass token above
#endif
  j    done
mismatch:
#ifdef ORACLE_NEGATIVE
  li   a0, 3
#else
  li   a0, 5
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
