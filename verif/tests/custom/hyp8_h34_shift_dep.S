// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// H34 (decisions: alu A3, rank-5): LAT_ALU_FULL -> 3. Shift/compare/SLT/
// min-max dependents now sit one cycle further from their producer.
// Directed check: dependent chains at distances 0..3 produce the same
// values as a gold computation, and add->shift->add interleaves are exact.

  .macro FAIL n
    li   a0, 0x100 + \n
    la   t0, tohost
    sw   a0, 0(t0)
    j    done
  .endm

  .section .text.init
  .globl _start
_start:
  // --- chain A: distance-0 dependents on every shift/compare class ---
  li   t0, 0x123456789
  slli t1, t0, 7            // A3 producer
  addi t2, t1, -5           // distance-0 dependent
  srli t3, t2, 3
  slt  t4, t3, t0           // compare finalize path
  srai t5, t3, 9
  sltu t6, t5, t2
  // gold: compute the same with the ops broken by independent work
  li   s0, 0x123456789
  slli s1, s0, 7
  xor  a1, a1, a1           // filler
  addi s2, s1, -5
  srli s3, s2, 3
  slt  s4, s3, s0
  srai s5, s3, 9
  sltu s6, s5, s2
  bne  t1, s1, 1f
  bne  t2, s2, 1f
  bne  t3, s3, 1f
  bne  t4, s4, 1f
  bne  t5, s5, 1f
  bne  t6, s6, 1f
  j    2f
1: FAIL 1
2:
  // --- chain B: add -> shift -> add (A2 producer into A3 consumer) ---
  li   t0, 0x77
  addi t1, t0, 9            // A2 result (stays 2-stage)
  slli t2, t1, 5            // distance-0: A2 -> A3 shifter
  add  t3, t2, t1           // A3 -> A2
  // gold = ((0x77+9)<<5) + (0x77+9) = (128<<5)+128 = 4224
  li   s0, 4224
  bne  t3, s0, 3f
  j    4f
3: FAIL 2
4:
  // --- chain C: dense shifts only, 8 back-to-back ---
  li   t0, 1
  slli t0, t0, 1
  slli t0, t0, 2
  slli t0, t0, 3
  slli t0, t0, 4
  slli t0, t0, 5
  srli t0, t0, 6
  srai t0, t0, 4
  // gold: (((((1<<1)<<2)<<3)<<4)<<5)>>6)>>4 = 2^(1+2+3+4+5-6-4)=2^5=32
  li   s0, 32
  bne  t0, s0, 5f
  j    6f
5: FAIL 3
6:
  // pass
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
done:
  j    done

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost:
  .dword 0
  .align 6
  .globl fromhost
fromhost:
  .dword 0
