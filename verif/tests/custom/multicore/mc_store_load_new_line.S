// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// M1c R1-cost isolator for L2PostedWriteEn: NLINES fresh lines, each written
// once (store to word 0) then read back immediately. The store is a
// write-around — the line was never resident — so its tracker entry is live
// when the load's read miss arrives, and the read either holds at the L2
// (R1, counted in l2_hold_r1 / split write-around vs write-update by
// l2_hold_r1_wu) or is serialized upstream at the hub's ar_wr_line_live
// gate. Either way each iteration pays the posted write's B round-trip.
// The fence is load-bearing: without it the store buffer forwards the load
// and no L2 read is ever issued — the drain puts the store's tracker entry
// live at the L2 before the miss arrives.
//
// tohost: 1 pass, 3 ORACLE_NEGATIVE, 5 data mismatch; harts other than 0
// park in wfi.

#ifndef NLINES
#define NLINES 4096
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

  li   s0, BUF_BASE            // buffer base
  li   s1, NLINES              // fresh lines
  li   t2, 0                   // line index
1:
  slli t3, t2, 6               // line offset = i * STRIDE
  add  t3, s0, t3
  sd   t3, 0(t3)               // store: data = line address (self-checking)
  fence rw, rw                 // drain the store to the L2 (tracker entry live)
  ld   t4, 0(t3)               // read miss behind the live tracked write (R1)
#ifdef ORACLE_NEGATIVE
  xori t5, t3, 1                // arm: demand corrupted data so the check fails
#else
  mv   t5, t3
#endif
  bne  t4, t5, mismatch
  addi t2, t2, 1
  bltu t2, s1, 1b
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
