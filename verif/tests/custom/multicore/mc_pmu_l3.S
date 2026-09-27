// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// PMU group-2 cross-check for the L3 counters. Hart 0 selects L3 miss
// (mhpmevent3 = {3'b010,5'd0} = 0x40), L3 hit (mhpmevent4 = 0x41) and cluster
// L2 miss (mhpmevent5 = 0x44), runs the same three-pass stride scan as
// mc_l3_stride_scan.S over SCAN_BYTES, and reports the counter deltas on the
// HTIF console as:
//
//   PMU l3miss=<hex> l3hit=<hex> l2miss=<hex>
//
// The deltas are stored to pmu_out{0,1,2} (three words after fromhost in the
// .tohost section, addresses tohost+0x10/+0x18/+0x20); the runner recovers
// them from the `mem <addr> <data>` store lines in the RVFI dasm trace. HTIF
// console output is not usable here: the directed runs pass +debug_disable,
// so nothing services the magic_mem/fromhost handshake.
//
// The testbench counts [mc_cache] events from reset, so the runner compares
// deltas: pmu_l3hit must equal the tb l3_hit total exactly (setup produces
// no L3 hits), pmu_l3miss/pmu_l2miss must be <= the tb totals.
//
// tohost: 1 pass, 3 ORACLE_NEGATIVE, 5 checksum mismatch; harts other than 0
// park in wfi.

#ifndef SCAN_BYTES
#define SCAN_BYTES 524288
#endif

#define BUF_BASE 0x80100000
#define STRIDE   64

#define CSR_MCOUNTINHIBIT 0x320
#define CSR_MHPMEVENT3    0x323
#define CSR_MHPMEVENT4    0x324
#define CSR_MHPMEVENT5    0x325
#define CSR_MHPMCOUNTER3  0xB03
#define CSR_MHPMCOUNTER4  0xB04
#define CSR_MHPMCOUNTER5  0xB05

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap
  csrw mtvec, t1
  bnez t0, park

  csrw CSR_MCOUNTINHIBIT, zero // let the hpm counters run
  li   t0, 0x40
  csrw CSR_MHPMEVENT3, t0      // group 2 index 0: L3 miss
  li   t0, 0x41
  csrw CSR_MHPMEVENT4, t0      // group 2 index 1: L3 hit
  li   t0, 0x44
  csrw CSR_MHPMEVENT5, t0      // group 2 index 4: L2 miss

  // window start
  csrr s6, CSR_MHPMCOUNTER3
  csrr s7, CSR_MHPMCOUNTER4
  csrr s8, CSR_MHPMCOUNTER5

  li   s0, BUF_BASE
  li   s1, SCAN_BYTES

  // pass 0: one store per line, word 0 = its address
  li   t2, 0
1:
  add  t3, s0, t2
  sd   t3, 0(t3)
  addi t2, t2, STRIDE
  bltu t2, s1, 1b
  fence rw, rw

  // pass 1: load word 0 of every line, checksum into s2
  li   t2, 0
  li   s2, 0
2:
  add  t3, s0, t2
  ld   t4, 0(t3)
  add  s2, s2, t4
  addi t2, t2, STRIDE
  bltu t2, s1, 2b

  // pass 2: identical loads, checksum into s3
  li   t2, 0
  li   s3, 0
3:
  add  t3, s0, t2
  ld   t4, 0(t3)
  add  s3, s3, t4
  addi t2, t2, STRIDE
  bltu t2, s1, 3b

  // window end; s6/s7/s8 become the deltas
  csrr t0, CSR_MHPMCOUNTER3
  sub  s6, t0, s6
  csrr t0, CSR_MHPMCOUNTER4
  sub  s7, t0, s7
  csrr t0, CSR_MHPMCOUNTER5
  sub  s8, t0, s8

  // publish the deltas before the exit code consumes tohost
  la   t0, tohost
  sd   s6, 0x10(t0)            // pmu_out0: L3 miss delta
  sd   s7, 0x18(t0)            // pmu_out1: L3 hit delta
  sd   s8, 0x20(t0)            // pmu_out2: L2 miss delta
  fence rw, rw

  // expected = sum over k of (base + 64k) = n*base + 32*n*(n-1)
  li   t0, SCAN_BYTES / STRIDE
  li   t1, 32
  mul  t1, t0, t1
  addi t2, t0, -1
  mul  t1, t1, t2
  mul  t2, t0, s0
  add  s4, t1, t2
#ifdef ORACLE_NEGATIVE
  xori s4, s4, 1
#endif
  bne  s2, s4, mismatch
  bne  s3, s4, mismatch
  li   a0, 1
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
// pmu_out{0,1,2}: delta slots harvested from the RVFI dasm mem-store lines.
  .globl pmu_out0
pmu_out0: .dword 0
  .globl pmu_out1
pmu_out1: .dword 0
  .globl pmu_out2
pmu_out2: .dword 0
