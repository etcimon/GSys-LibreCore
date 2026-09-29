// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Pointer-chase probe: one node per 64-byte line over CHASE_BYTES of DRAM,
// word 0 of each node holds the absolute address of the next node. The chain
// order is a maximal 13-bit Fibonacci LFSR (x^13+x^4+x^3+x+1, taps
// {12,3,2,0}, period 8191): node (s-1) points at node (lfsr(s)-1), so the
// walk covers every node exactly once before returning to node 0.
//
// Data-dependent addressing is the prefetcher's worst case: no stream and no
// constant stride exists, so an enabled prefetcher must neither help nor hurt.
//
// tohost: 1 pass, 3 ORACLE_NEGATIVE, 5 checksum mismatch / timeout; harts
// other than 0 park in wfi.

#ifndef CHASE_BYTES
#define CHASE_BYTES 524288
#endif

#define BUF_BASE    0x80100000
#define CHASE_NODES 8191           // 2^13-1; 8191*64 = 524224 <= CHASE_BYTES
#define LFSR_TAPS   0x100D         // x^13+x^4+x^3+x+1 (bits 12,3,2,0)
#define LFSR_MASK   0x1FFF

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap
  csrw mtvec, t1
  bnez t0, park

  li   s0, BUF_BASE            // buffer base = node 0

  // init pass: node (s-1) sits at s0 + 64*(s-1) for each LFSR state s;
  // word 0 = s0 + 64*(lfsr(s)-1). s1 walks the 13-bit LFSR starting at 1;
  // the period-8191 cycle visits each node exactly once.
  li   t5, CHASE_NODES
  li   t2, 0                   // iteration count
  li   s1, 1                   // LFSR state
  li   t6, LFSR_TAPS
  li   a2, LFSR_MASK
1:
  addi t3, s1, -1
  slli t3, t3, 6
  add  t3, s0, t3              // node (s1-1) address
  // fb = parity(s1 & TAPS)
  and  t4, s1, t6
  srli a1, t4, 8
  xor  t4, t4, a1
  srli a1, t4, 4
  xor  t4, t4, a1
  srli a1, t4, 2
  xor  t4, t4, a1
  srli a1, t4, 1
  xor  t4, t4, a1
  andi t4, t4, 1               // feedback bit
  slli s1, s1, 1
  or   s1, s1, t4
  and  s1, s1, a2              // next state, still nonzero
  addi t4, s1, -1
  slli t4, t4, 6
  add  t4, s0, t4              // successor address
  sd   t4, 0(t3)
  addi t2, t2, 1
  bltu t2, t5, 1b
  fence rw, rw

  // chase pass: follow the chain until it returns to node 0
  mv   t3, s0
  li   s2, 0                   // hop count
  li   s3, 0                   // checksum = sum of visited node addresses
3:
  ld   t3, 0(t3)
  add  s3, s3, t3
  addi s2, s2, 1
  bne  t3, s0, 3b

  // expected: hops = CHASE_NODES; sum = n*base + 64*sum(0..n-1)
  li   s4, CHASE_NODES
#ifdef ORACLE_NEGATIVE
  xori s4, s4, 1
#endif
  bne  s2, s4, mismatch
  li   t0, CHASE_NODES
  mul  s5, t0, s0              // n*base
  addi t1, t0, -1
  mul  t1, t0, t1              // n*(n-1)
  slli t1, t1, 5               // *32  -> 64*n*(n-1)/2
  add  s5, s5, t1
#ifdef ORACLE_NEGATIVE
  xori s5, s5, 1
#endif
  bne  s3, s5, mismatch

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
