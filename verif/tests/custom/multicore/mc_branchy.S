// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Data-dependent branch stress for the M3 frontend/window uplift: ITER rounds
// of an xorshift64 stream feeding three conditional branches per round (bits
// 0, 7 and 19 of the running state — ~50% taken rate, so a real predictor
// cannot memoize the stream). The checksum accumulates the per-branch
// outcomes and must match a closed-form value computed in the same binary.
//
// PMU group-1 (mhpmevent[7:5]==1) is published to pmu_out{0,1,2} =
// tohost+0x10/+0x18/+0x20 as in-window deltas:
//   pmu_out0: index 2  (0x22) — resolved mispredicted branches
//   pmu_out1: index 0  (0x20) — rename/ROB backpressure (sb_full|rename|rob)
//   pmu_out2: index 1  (0x21) — IQ / issue stall
// The runner recovers them from the `mem <addr> <data>` store records in the
// RVFI dasm trace; REVIEW_MC_PMU_KEYS names the slots in results.json.
//
// tohost: 1 pass, 3 ORACLE_NEGATIVE, 5 checksum mismatch; harts other than 0
// park in wfi.

#ifndef ITER
#define ITER 65536
#endif

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
  li   t0, 0x22
  csrw CSR_MHPMEVENT3, t0      // group 1 index 2: mispredicted branches
  li   t0, 0x20
  csrw CSR_MHPMEVENT4, t0      // group 1 index 0: rename/ROB backpressure
  li   t0, 0x21
  csrw CSR_MHPMEVENT5, t0      // group 1 index 1: IQ / issue stall

  // window start
  csrr s6, CSR_MHPMCOUNTER3
  csrr s7, CSR_MHPMCOUNTER4
  csrr s8, CSR_MHPMCOUNTER5

  li   s0, 0x9e3779b97f4a7c15 // xorshift64 state (nonzero seed)
  li   s1, ITER               // rounds remaining
  li   s2, 0                  // checksum accumulator

1:
  // xorshift64: x ^= x<<13; x ^= x>>7; x ^= x<<17
  slli t0, s0, 13
  xor  s0, s0, t0
  srli t0, s0, 7
  xor  s0, s0, t0
  slli t0, s0, 17
  xor  s0, s0, t0

  // branch 1: bit 0 of the state
  andi t1, s0, 1
  beqz t1, 2f
  addi s2, s2, 1
  j    3f
2:
  addi s2, s2, 2
3:
  // branch 2: bit 7 of the state
  andi t1, s0, 0x80
  beqz t1, 4f
  addi s2, s2, 4
  j    5f
4:
  addi s2, s2, 8
5:
  // branch 3: bit 19 of the state
  li   t1, 0x80000
  and  t1, s0, t1
  beqz t1, 6f
  addi s2, s2, 16
  j    7f
6:
  addi s2, s2, 32
7:
  addi s1, s1, -1
  bnez s1, 1b

  // window end; s6/s7/s8 become the deltas
  csrr t0, CSR_MHPMCOUNTER3
  sub  s6, t0, s6
  csrr t0, CSR_MHPMCOUNTER4
  sub  s7, t0, s7
  csrr t0, CSR_MHPMCOUNTER5
  sub  s8, t0, s8

  // publish the deltas before the exit code consumes tohost
  la   t0, tohost
  sd   s6, 0x10(t0)            // pmu_out0: mispredicted-branch delta
  sd   s7, 0x18(t0)            // pmu_out1: rename/ROB backpressure delta
  sd   s8, 0x20(t0)            // pmu_out2: IQ/issue-stall delta
  fence rw, rw

  // recompute the expected checksum by replaying the same stream: the loop
  // cost is one extra pass over 64K rounds, far below the retire bound, and
  // it keeps the oracle data-independent of the predictor.
  li   s0, 0x9e3779b97f4a7c15
  li   s1, ITER
  li   s3, 0                  // expected checksum
11:
  slli t0, s0, 13
  xor  s0, s0, t0
  srli t0, s0, 7
  xor  s0, s0, t0
  slli t0, s0, 17
  xor  s0, s0, t0
  andi t1, s0, 1
  beqz t1, 12f
  addi s3, s3, 1
  j    13f
12:
  addi s3, s3, 2
13:
  andi t1, s0, 0x80
  beqz t1, 14f
  addi s3, s3, 4
  j    15f
14:
  addi s3, s3, 8
15:
  li   t1, 0x80000
  and  t1, s0, t1
  beqz t1, 16f
  addi s3, s3, 16
  j    17f
16:
  addi s3, s3, 32
17:
  addi s1, s1, -1
  bnez s1, 11b

#ifdef ORACLE_NEGATIVE
  xori s3, s3, 1
#endif
  bne  s2, s3, mismatch
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
