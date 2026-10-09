// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// T20 defect B — HPDCACHE "zombie" ways: an uncacheable request that HITS in
// the L1 D$ invalidates the line (hpdcache_ctrl_pe.sv, uncacheable-hit path)
// but, before the fix, left `st2_dir_updt_fetch_o` at its pass-through default
// (the sticky stage-2 register, = 1 after any preceding miss allocation), so
// the way was written valid=0 / fetch=1. Such a way is never offered by the
// victim selector again (hpdcache_victim_plru: unused_ways = ~fetch & ~valid)
// and nothing rewrites it (refills only target selected victims, NoC
// invalidations only hit valid ways). LR/SC are forced uncacheable by the
// G6LC adapter (cva6_hpdcache_if_adapter.sv, store/AMO port), so every
// `ld line; lr.d line` pair produced one zombie; the 8-hart server boot did
// this once per hart on the 8 sbi_scratch HSM-state words (all in D$ set 8)
// and hart 0's `ld 0x80054080` (set 8) then parked in the replay table on
// dir_unavailable with an empty MSHR -> rtab full -> core 0 wedged
// (ooocoh-t19-server-osbi-48M at 38.96 M, T20-REPORT §4.2).
//
// Shape (hart 0 only; mask 0001 on g6lc64_ooo_server — 32 KiB / 8 ways /
// 16 B lines = 256 sets, 4 KiB per way): WAYS+1 lines of the same set (stride
// 4 KiB). For each of the first WAYS lines: `ld` (cold miss: FETCHING written
// to an unused way, refill) then `lr.d` + `sc.d` (uncacheable hit: the way is
// invalidated — a zombie on the unfixed tree). Then `ld` of line WAYS: on the
// unfixed tree every way of the set is a zombie, the load parks forever on
// dir_unavailable and the hart stops retiring (harness exit 126 / +time_out,
// no tohost). With the fix the invalidated ways are reusable, the load
// completes and the checksum (word i of line i holds i+1) is published.
// A second pass over all WAYS+1 lines re-checks the data through hits/misses.
//
// tohost raw codes: 1 pass, 5 checksum mismatch, 15 unexpected trap,
// 3 ORACLE_NEGATIVE arm (hart 0 demands a wrong sum).
// tohost sits past 0x80001000: REVIEW_MC_DIRECTED_TOHOST_ADDR=auto.

#ifndef WAYS
#define WAYS 8
#endif
#ifndef WAY_STRIDE
#define WAY_STRIDE 4096
#endif
#ifndef SET_OFF
#define SET_OFF 0x800
#endif
#define NLINES (WAYS + 1)

  .equ CLINT_MSIP, 0x02000000
  .equ EXPECT, NLINES * (NLINES + 1) / 2

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
  csrr a7, mhartid
  li   t0, CLINT_MSIP
  slli t1, a7, 2
  add  t1, t0, t1
  sw   zero, 0(t1)              // clear our own msip
  csrw mie, zero
  bnez a7, park                 // harts >= 1 park at once

// ---------------------------------------------------------------------------
// hart 0
hart0:
  la   s5, region
  li   t0, SET_OFF
  add  s5, s5, t0               // line 0 of the chosen set
  li   s0, 0                    // checksum
  mv   s2, s5
  li   s3, WAYS
zombie_loop:
  ld   t0, 0(s2)                // cold miss: FETCHING on an unused way, refill
  add  s0, s0, t0
  lr.d t1, (s2)                 // uncacheable hit -> directory invalidation
  sc.d t2, t1, (s2)             // release the reservation (value unchanged)
  li   t3, WAY_STRIDE
  add  s2, s2, t3
  addi s3, s3, -1
  bnez s3, zombie_loop

  ld   t0, 0(s2)                // line WAYS: needs a victim in the set
  add  s0, s0, t0               // (unfixed tree: parks forever here)

  // second pass: every line again (hits or clean misses), same checksum
  mv   s2, s5
  li   s3, NLINES
pass2:
  ld   t0, 0(s2)
  add  s0, s0, t0
  li   t3, WAY_STRIDE
  add  s2, s2, t3
  addi s3, s3, -1
  bnez s3, pass2

  li   t0, 2 * EXPECT
#ifdef ORACLE_NEGATIVE
  addi t0, t0, 1
#endif
  bne  s0, t0, fail_sum
  li   a0, 1
  j    report

fail_sum:
#ifdef ORACLE_NEGATIVE
  li   a0, 3
#else
  li   a0, 5
#endif
  j    report
fail_trap:
  li   a0, 15
  j    report

park:
  wfi
  j    park

report:
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
  j    park

  .align 2
trap:
  j    fail_trap

  .data
  // NLINES lines of one D$ set: line i at region + SET_OFF + i*WAY_STRIDE,
  // its first word holds i+1 (the rest of each 4 KiB block is untouched)
  .balign 4096
region:
  .set i, 1
  .rept NLINES
  .skip SET_OFF
  .dword i
  .skip WAY_STRIDE - SET_OFF - 8
  .set i, i + 1
  .endr

.section ".tohost","aw",@progbits
  .balign 64
  .globl tohost
tohost: .dword 0
