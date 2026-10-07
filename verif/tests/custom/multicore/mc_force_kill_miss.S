// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// T19 defect 2 — SMT bounded-drain force killing an in-flight HPDCACHE miss
// (T19-ANALYSIS §2 / §5(c'): core 0 of the ooocoh-t18 server boot stopped
// granting its load port after three DF_MAX=256-cycle forces each killed hart
// 0's cold-miss `ld 0x80054080` while its request was in the cache; both harts
// then sat in WAIT_GNT (`ldu st=1 dreq=1 rvld=0`) with an idle uncore).
//
// Shape for the drained-handoff SMT profiles (g6lc64_ooo_server: harts 0/1 on
// core 0, SmtFetchQuantum 4, SmtDrainForceCycles 256), built with the TB knob
// -GDramLatency=320 so every DRAM round trip exceeds the force bound:
//   hart 1  spins on cached hits (`ld` of one hot line + branch), so the
//           hybrid selector keeps requesting quantum switches;
//   hart 0  walks NLINES distinct 64 B lines (one `ld` each, plus a
//           dependent `add` into a checksum). Each cold `ld` is at the commit
//           head when the switch to hart 1 is requested, cannot commit within
//           256 cycles, and is force-killed while its miss is in flight in
//           HPDCACHE (MSHR allocated / replay-table parked / st0-st1); the
//           hart is rewound to the load and re-issues it after hart 1's
//           quantum. REPS passes over the region.
//   -DWITH_LRSC  hart 0 also does an lr.d/sc.d pair on the previous (now
//           cached) line before each cold load — the HSM `atomic_cmpxchg`
//           pattern of the boot (seven sibling lines of the stuck load's MSHR
//           set carried LR/SC pairs).
// Expected: progress and checksum == REPS * NLINES*(NLINES+1)/2 (word i of the
// region holds i+1). A stock-tree wedge shows as the harness' "a core ran and
// then stopped retiring" (exit 126) with no tohost.
//
// tohost raw codes: 1 pass, 5 checksum mismatch, 13 spin timeout,
// 15 unexpected trap, 3 ORACLE_NEGATIVE arm (hart 0 demands a wrong sum).
// tohost sits past 0x80001000: REVIEW_MC_DIRECTED_TOHOST_ADDR=auto; run with
// mask 0001 on g6lc64_ooo_server (harts 2..7 park at once).

#ifndef NLINES
#define NLINES 512
#endif
#ifndef REPS
#define REPS 2
#endif
#ifndef SPIN_TO
#define SPIN_TO 4000000
#endif

  .equ CLINT_MSIP, 0x02000000
  .equ EXPECT, REPS * (NLINES * (NLINES + 1) / 2)

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
  bnez a7, 2f
  li   t1, 1
  sw   t1, 4(t0)                // msip[1]: the sibling is "seen" at once
2:
  slli t1, a7, 2
  add  t1, t0, t1
  sw   zero, 0(t1)              // clear our own msip
  csrw mie, zero
  li   t2, 2
  bge  a7, t2, park             // harts >= 2 park at once
  li   t2, 1
  beq  a7, t2, hart1

// ---------------------------------------------------------------------------
// hart 0: cold-line walk
hart0:
  li   s0, 0                    // checksum
  li   s1, REPS
  la   s5, region
rep:
  mv   s2, s5                   // line cursor
  li   s3, NLINES
  mv   s6, s5                   // "previous line" for the LR/SC mimic
walk:
#ifdef WITH_LRSC
  lr.d t0, (s6)
  sc.d t1, t0, (s6)
#endif
  ld   t0, 0(s2)                // cold miss (DramLatency > DF_MAX)
  add  s0, s0, t0               // dependent use: the load is the commit head
  mv   s6, s2
  addi s2, s2, 64
  addi s3, s3, -1
  bnez s3, walk
  addi s1, s1, -1
  bnez s1, rep

  li   t0, EXPECT
#ifdef ORACLE_NEGATIVE
  addi t0, t0, 1
#endif
  bne  s0, t0, fail_sum
  la   t0, done
  li   t1, 1
  sd   t1, 0(t0)
  fence rw, rw
  li   a0, 1
  j    report

// ---------------------------------------------------------------------------
// hart 1: cached-hit spin until hart 0 is done (bounded)
hart1:
  la   t0, hot
  la   t1, done
  li   t3, SPIN_TO
1:ld   t2, 0(t0)
  add  t2, t2, t3
  sd   t2, 8(t0)
  ld   t4, 0(t1)
  bnez t4, park
  addi t3, t3, -1
  bnez t3, 1b
  li   a0, 13
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
  .balign 64
hot:       .dword 0x1234
           .dword 0
  .balign 64
done:      .dword 0
  // NLINES 64 B lines, word i (0-based) holds i+1
  .balign 64
region:
  .set i, 1
  .rept NLINES
  .dword i
  .skip 56
  .set i, i + 1
  .endr

.section ".tohost","aw",@progbits
  .balign 64
  .globl tohost
tohost: .dword 0
