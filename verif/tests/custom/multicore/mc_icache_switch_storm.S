// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// I$ miss / SMT-switch storm for the drained-handoff OoO profiles
// (g6lc64_ooo_int2_l3, g6lc64_ooo_server: two SMT threads per physical core,
// one shared g6lc_icache per core, shared L2/L3 behind the coherence hub).
//
// The defect under test (T17): after OpenSBI's fence.i (`_reset_regs`) every
// fetch of every hart missed, the hybrid selector switched between the two
// harts of a core every few dozen cycles, each switch's smt_restore_flush
// killed the active hart's in-flight I$ miss, and g6lc_icache discarded the
// killed refill (KILL_MISS never wrote the line). Whenever the refill latency
// exceeded the switch cadence no line was ever installed and all eight
// server harts stopped fetching for 18 M cycles — a fetch livelock behind an
// empty scoreboard. The fix installs a refilled cacheable line even when the
// requesting stream was killed (only a pending I$ flush forbids it).
//
// Shape: MC_ICS_NHARTS participating harts (default 2 = harts 0 and 1, both
// on core 0; 8 on g6lc64_ooo_server covers all four cores) rendezvous on an
// amoadd barrier, execute fence.i, then each walks a straight-line region of
// 96 64-byte-aligned blocks (6 KiB, 16 instructions per block; the I$ line
// is 16 B on both profiles, so a region spans 384 distinct lines) that folds
// an order-sensitive checksum, then compares the checksum and the block
// count against the assembly-time expectation. The fence.i + walk repeats
// REPS (4) times so the cold misses recur after the I$ was warm.
//   default            — even harts walk region0, odd harts region1 (hart
//                        private on core 0; region1 sits 16 KiB past
//                        region0), seed differs by parity;
//   -DMC_ICS_SHARED    — every participant walks region0 with the same seed:
//                        all harts (and all cores) miss on the same lines,
//                        the OpenSBI `_reset_regs` shape.
// Hart 0 writes msip[1..N-1] so the siblings are "seen" by the selector at
// once (no 200 k-cycle cold exclusive window) and the secondary cores leave
// their boot clock gate; every hart clears its own msip afterwards. Harts
// with mhartid >= MC_ICS_NHARTS park in WFI immediately.
//
// Discrimination (pre-fix g6lc64_ooo_server model 3ee0184c…): the two-hart
// shapes on one core complete (an L2-hit refill returns inside the switch
// cadence), but with all four cores contending — `-DMC_ICS_NHARTS=8`, with
// or without MC_ICS_SHARED — every core stops retiring at the first region
// line after the fence.i (`[mc_verdict] FAIL: a core ran and then stopped
// retiring`, exit 126): the hub/L2 queueing of eight killed-and-reissued
// refills pushes the latency past the cadence and nothing is ever
// installed. That is the OpenSBI `_reset_regs` shape (all harts leave
// `_wait_for_boot_hart` together). Run the 8-hart arm with mask 1111.
//
// Checksum per block n (H = 0 for region0, 256 for region1; mod 2^64):
//   s0 = 3*s0 + n + H;  s1 += 1;  s0 ^= s1;  s0 ^= s0 >> 7;  s0 += s0 << 13
// from s0 = 0x9E3779B97F4A7C15 (+1 for region1), s1 = 0.
//
// tohost raw codes: 1 pass, 3 ORACLE_NEGATIVE arm (odd harts' expectation
// flipped), 5/7 region0/region1-hart checksum mismatch, 9/11 region0/region1-
// hart block-count mismatch, 13 barrier/completion spin timeout, 15
// unexpected trap.
//
// tohost moves past 0x80001000 (the regions exceed the 4 KiB first page):
// run with REVIEW_MC_DIRECTED_TOHOST_ADDR=auto. Needs Zifencei in -march.

#ifndef REPS
#define REPS 4
#endif
#ifndef MC_ICS_NHARTS
#define MC_ICS_NHARTS 2
#endif
#ifndef SPIN_TO
#define SPIN_TO 400000             // barrier spin iterations before code 13
#endif

  .equ CLINT_MSIP, 0x02000000
  .equ NBLK,       96
  .equ SEED,       0x9E3779B97F4A7C15
  .equ EXP0,       0xf91ec14afabb9ff9   // region0 checksum after 96 blocks
  .equ EXP1,       0x3b912207759be00c   // region1 checksum after 96 blocks

// N-way barrier on the counter at (t0): arrive, then wait until N arrived.
.macro BARRIER_T0
  li   t2, 1
  amoadd.d zero, t2, (t0)
  fence rw, rw
  li   t3, SPIN_TO
  li   t5, MC_ICS_NHARTS
1:ld   t4, 0(t0)
  bge  t4, t5, 2f
  addi t3, t3, -1
  bnez t3, 1b
  j    fail_bar
2:
.endm

// One 64-byte region block: exactly 16 four-byte instructions (norvc), so
// consecutive blocks are contiguous and every 16 B I$ line is distinct code.
.macro BLOCK n, h
  .balign 64
  slli t0, s0, 1
  add  s0, s0, t0            // s0 = 3*s0
  addi s0, s0, (\n + \h)     // + n + H
  addi s1, s1, 1             // block counter
  xor  s0, s0, s1
  srli t1, s0, 7
  xor  s0, s0, t1
  slli t2, s0, 13
  add  s0, s0, t2
  addi t3, t3, 1             // unchecked scratch traffic
  andi t4, s0, 0xff
  add  s2, s2, t4
  addi t5, zero, \n
  sub  t6, t5, s1
  or   t5, t5, t6
  nop
.endm

  .option norvc
  .section .text.init
  .globl _start
_start:
  .option push
  .option norelax
  la   gp, __global_pointer$
  .option pop
  la   t1, trap
  csrw mtvec, t1
  csrr s11, mhartid          // kept for the whole program

  // Hart 0 marks every other participant "seen" for its core's selector
  // (ipi_i sets smt_hart_seen_q and lifts the cold exclusive window) and
  // releases the secondary cores' boot clock gates: msip[1..N-1].
  li   t0, CLINT_MSIP
  bnez s11, 2f
  li   t1, 1
  li   t2, 1
  li   t3, MC_ICS_NHARTS
1:bge  t2, t3, 2f
  slli t4, t2, 2
  add  t4, t0, t4
  sw   t1, 0(t4)
  addi t2, t2, 1
  j    1b
2:
  // Clear a pending msip aimed at this hart; mstatus.MIE stays 0 so a pending
  // software interrupt never traps; mie stays 0 so a parked wfi sleeps.
  slli t1, s11, 2
  add  t1, t0, t1
  sw   zero, 0(t1)
  csrw mie, zero
  li   t2, MC_ICS_NHARTS
  bge  s11, t2, park         // non-participants park at once

  // Region / seed / expectation by parity (shared storm: region0 for all).
#ifdef MC_ICS_SHARED
  li   s7, 0                 // region select
  li   s6, SEED
  li   s9, EXP0
#ifdef ORACLE_NEGATIVE
  andi t1, s11, 1
  beqz t1, 3f
  li   s9, EXP0 ^ 1          // arm: odd harts demand a wrong checksum
3:
#endif
#else
  andi s7, s11, 1
  li   s6, SEED
  add  s6, s6, s7
  li   s9, EXP0
  beqz s7, 3f
#ifdef ORACLE_NEGATIVE
  li   s9, EXP1 ^ 1
#else
  li   s9, EXP1
#endif
3:
#endif
  li   s10, REPS
  la   s8, sync_cnt          // barrier counters advance by 8 B per rep
rep:
  // All participants: rendezvous, invalidate the I$, walk the cold region.
  mv   t0, s8
  BARRIER_T0
  fence.i
  mv   s0, s6
  li   s1, 0
  bnez s7, 4f
  jal  ra, region0
  j    5f
4:jal  ra, region1
5:bne  s0, s9, fail_sum
  li   t4, NBLK
  bne  s1, t4, fail_cnt
  addi s8, s8, 8
  addi s10, s10, -1
  bnez s10, rep

  // Completion barrier; hart 0 reports, everybody else parks.
  la   t0, done_cnt
  BARRIER_T0
  bnez s11, park
  li   a0, 1
  j    done

fail_sum:
#ifdef ORACLE_NEGATIVE
  li   a0, 3
#else
  slli a0, s7, 1             // region0 hart -> 5, region1 hart -> 7
  addi a0, a0, 5
#endif
  j    done
fail_cnt:
  slli a0, s7, 1             // region0 hart -> 9, region1 hart -> 11
  addi a0, a0, 9
  j    done
fail_bar:
  li   a0, 13
  j    done
fail_trap:
  li   a0, 15
  j    done

park:
  wfi
  j    park

done:
  // The harness stops at the first non-zero tohost store, so the first
  // verdict wins (a peer's later barrier timeout cannot overwrite it). Plain
  // sw: an sc.w here never reached the HTIF poller on the WT/L2 profiles.
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
  j    park

  // M-mode trap vector (shared): any trap is a failure here.
  .align 2
trap:
  j    fail_trap

  // ---- region0: 96 contiguous 64 B blocks (6 KiB) ------------------------
  .balign 64
region0:
  .altmacro
  .set i, 0
  .rept NBLK
  BLOCK %i, 0
  .set i, i + 1
  .endr
  .noaltmacro
  ret

  // ---- region1: 16 KiB further, same shape, H = 256 ----------------------
  .balign 16384
region1:
  .altmacro
  .set i, 0
  .rept NBLK
  BLOCK %i, 256
  .set i, i + 1
  .endr
  .noaltmacro
  ret

  .data
  .align 3
sync_cnt: .dword 0, 0, 0, 0, 0, 0, 0, 0   // one counter per rep (REPS <= 8)
done_cnt: .dword 0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .globl fromhost
fromhost: .dword 0
