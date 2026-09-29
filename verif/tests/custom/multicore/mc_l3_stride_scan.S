// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// L3 residency probe: three passes over SCAN_BYTES of DRAM at stride 64.
//
// Pass 0 stores the line address into the first word of every line (the WT
// path writes through and does not install). Pass 1 reloads and accumulates
// checksum A — every access is a first-touch miss, installing in L2 and L3.
// Pass 2 reloads and accumulates checksum B — for SCAN_BYTES above the L2
// capacity every access misses L2 and should hit a retaining L3. Pass means
// both checksums equal the closed-form sum of the addresses stored; the
// ORACLE_NEGATIVE arm perturbs the expectation instead.
//
// tohost: 1 pass, 3 ORACLE_NEGATIVE, 5 checksum mismatch / timeout; harts
// other than 0 park in wfi.

#ifndef SCAN_BYTES
#define SCAN_BYTES 524288
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

  li   s0, BUF_BASE            // buffer base
  li   s1, SCAN_BYTES          // footprint in bytes

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

  // expected = sum over k of (base + 64k) = n*base + 32*n*(n-1)
  li   t0, SCAN_BYTES / STRIDE     // n
  li   t1, 32
  mul  t1, t0, t1                  // 32n
  addi t2, t0, -1
  mul  t1, t1, t2                  // 32n(n-1)
  mul  t2, t0, s0                  // n*base
  add  s4, t1, t2
#ifdef ORACLE_NEGATIVE
  xori s4, s4, 1
#endif
  bne  s2, s4, mismatch
  bne  s3, s4, mismatch
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
