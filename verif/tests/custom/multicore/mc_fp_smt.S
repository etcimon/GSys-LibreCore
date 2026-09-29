// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Four-hart FP/SMT residency check for the drained-handoff OoO profile
// (g6lc64_ooo_int2_l3: two physical cores x two SMT threads, COH_OOO, FP on).
//
// Every hart (mhartid 0..3 = core*2 + thread) fills f0-f30 with a hart-unique
// bit pattern plus a per-hart fcsr (frm = hart, fflags = 1 << hart), then
// ping-pongs the physical core with its SMT sibling through msip+wfi forced
// switches. Between rounds it re-checks the whole FP context: any leakage of
// the sibling's FP registers, fcsr or a lost in-flight fdiv.d result is a
// cross-hart isolation failure.
//
// The switch is the drained handoff: wfi blocks the active hart, the selector
// drains the scoreboard (the in-flight fdiv.d commits before the switch) and
// hands the core to the peer, which the pending msip then wakes.
//
// Phase B runs on the two thread-0 harts (0 on core 0, 2 on core 1): the peer
// core publishes a double with fsd on a shared line, this hart consumes it
// with fld twice — once cold, once after a remote overwrite — so the COH_OOO
// invalidation/replay path is exercised on the FP load class.
//
// Phase C checks mstatus.FS == Dirty per hart (lazy-FS attribution) and a
// four-way done barrier aggregates into a single tohost exit.
//
// tohost: 1 pass, 3 ORACLE_NEGATIVE, 5 context mismatch, 7 FS wrong,
//         9 stale shared-line fld, 11 barrier/spin timeout.

#ifndef ROUNDS
#define ROUNDS 6
#endif

  .equ CLINT_MSIP, 0x02000000
  .equ LINE,   0x80090000
  .equ READY,  0x80090100
  .equ FLAG,   0x80090200
  .equ GO,     0x80090300
  .equ GO2,    0x80090400
  .equ DONE,   0x80090500     // +8*hart
  .equ SPIN_TO, 200000
  .equ MSTATUS_FS, 0x6000

// Fill f<i> with the hart-unique pattern word s8 + \n.
.macro FILL i
  addi t2, s8, \i
  fmv.d.x f\i, t2
.endm
// Check f<i> still holds s8 + \n (integer compare on the raw bits).
.macro CHK i
  fmv.x.d t4, f\i
#ifdef ORACLE_NEGATIVE
  addi t5, s8, (\i + 1)     // arm: demand a corrupted pattern, must fail
#else
  addi t5, s8, \i
#endif
  bne  t4, t5, fail_ctx
.endm

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr s11, mhartid          // hart id, kept for the whole program
  la   t1, trap
  csrw mtvec, t1
  li   t0, CLINT_MSIP

  // Hart 0 releases the secondary core from its boot clock gate and marks all
  // sibling threads "seen" for the selector (ipi_i sets smt_hart_seen_q).
  bnez s11, 1f
  li   t1, 1
  sw   t1, 4(t0)             // msip[1]: thread 1 of core 0
  sw   t1, 8(t0)             // msip[2]: core 1 boot hart (releases its gate)
  sw   t1, 12(t0)            // msip[3]: thread 1 of core 1
1:
  // Clear a pending msip aimed at this hart, then arm MSIE so a peer msip
  // wakes this hart's wfi (wake needs mip & mie; mstatus.MIE stays 0 so the
  // pending software interrupt never traps).
  slli t1, s11, 2
  add  t1, t0, t1
  sw   zero, 0(t1)
  li   t2, 0x8
  csrw mie, t2

  // Enable the FPU and install the per-hart fcsr (frm = hart, fflags = 1<<hart).
  li   t0, MSTATUS_FS
  csrs mstatus, t0
  slli t2, s11, 5
  li   t3, 1
  sll  t3, t3, s11
  or   s6, t2, t3
  csrw fcsr, s6

  // Context: f0..f28 = (PATTERN + hart*2^40) + i; f29 = 2.0; f30 = 1.0;
  // f31 = 0.5 via an exact divide (its expected bits live in s7).
  li   s8, 0x3FF0000000000000
  slli t2, s11, 40
  or   s8, s8, t2
  FILL 0
  FILL 1
  FILL 2
  FILL 3
  FILL 4
  FILL 5
  FILL 6
  FILL 7
  FILL 8
  FILL 9
  FILL 10
  FILL 11
  FILL 12
  FILL 13
  FILL 14
  FILL 15
  FILL 16
  FILL 17
  FILL 18
  FILL 19
  FILL 20
  FILL 21
  FILL 22
  FILL 23
  FILL 24
  FILL 25
  FILL 26
  FILL 27
  FILL 28
  li   t2, 0x4000000000000000
  fmv.d.x f29, t2            // 2.0
  li   t2, 0x3FF0000000000000
  fmv.d.x f30, t2            // 1.0
  fdiv.d f31, f30, f29       // 0.5, exact — no fflags side effect
  fmv.x.d s7, f31

  // ---- phase A: ROUNDS ping-pong switches against the SMT sibling ----
  li   s5, ROUNDS
round:
  CHK 0
  CHK 1
  CHK 2
  CHK 3
  CHK 4
  CHK 5
  CHK 6
  CHK 7
  CHK 8
  CHK 9
  CHK 10
  CHK 11
  CHK 12
  CHK 13
  CHK 14
  CHK 15
  CHK 16
  CHK 17
  CHK 18
  CHK 19
  CHK 20
  CHK 21
  CHK 22
  CHK 23
  CHK 24
  CHK 25
  CHK 26
  CHK 27
  CHK 28
  li   t5, 0x4000000000000000
  fmv.x.d t4, f29
  bne  t4, t5, fail_ctx
  li   t5, 0x3FF0000000000000
  fmv.x.d t4, f30
  bne  t4, t5, fail_ctx
  fmv.x.d t4, f31            // last round's in-flight divide landed as 0.5
  bne  t4, s7, fail_ctx
  csrr t4, fcsr
  bne  t4, s6, fail_ctx

  // Flag-free FP traffic on the scratch register, then a slow divide issued
  // just before wfi: the drained handoff must commit it before switching.
  fsgnj.d f31, f31, f30
  fmax.d  f31, f31, f29
  fdiv.d  f31, f30, f29

  // Wake the sibling and park: wfi blocks -> drain -> handoff to the peer.
  li   t0, CLINT_MSIP
  xori t1, s11, 1            // same-core sibling
  slli t1, t1, 2
  add  t1, t0, t1
  li   t2, 1
  sw   t2, 0(t1)
  fence rw, rw
  wfi
  addi s5, s5, -1
  bnez s5, round

  // One more context check after the last wake.
  fmv.x.d t4, f0
  bne  t4, s8, fail_ctx
  csrr t4, fcsr
  bne  t4, s6, fail_ctx

  // ---- phase B: thread-0 harts exchange a double over a shared line ----
  li   t1, 2
  bne  s11, t1, not_pub

  // hart 2 (core 1): publish P1, wait, overwrite with P2.
  li   s1, LINE
  li   s2, READY
  li   s3, GO
  li   s4, FLAG
  li   t2, SPIN_TO
2: ld   t1, 0(s3)
  bnez t1, 3f
  addi t2, t2, -1
  bnez t2, 2b
  j    fail_barrier
3:li   t2, 0x3FF8000000000000  // P1 = 1.5
  fmv.d.x f31, t2
  fsd  f31, 0(s1)
  fence rw, rw
  li   t1, 1
  sd   t1, 0(s2)
  fence rw, rw
  li   s3, GO2
  li   t2, SPIN_TO
4: ld   t1, 0(s3)
  bnez t1, 5f
  addi t2, t2, -1
  bnez t2, 4b
  j    fail_barrier
5:li   t2, 0x4000000000000000  // P2 = 2.0
  fmv.d.x f31, t2
  fsd  f31, 0(s1)              // WT write to a line hart 0 holds resident
  fence rw, rw
  li   t1, 1
  sd   t1, 0(s4)
  fence rw, rw
  j    peer_done

not_pub:
  bnez s11, peer_done          // harts 1/3: phase A only

  // hart 0 (core 0): consume the shared line with fld, twice.
  li   s1, LINE
  li   s2, READY
  li   s3, GO
  li   s4, FLAG
  li   s5, GO2
  li   t1, 1
  sd   t1, 0(s3)               // GO: hart 2 publishes P1
  fence rw, rw
  li   t2, SPIN_TO
6: ld   t1, 0(s2)
  bnez t1, 7f
  addi t2, t2, -1
  bnez t2, 6b
  j    fail_barrier
7:fence rw, rw
  fld  f31, 0(s1)
  fmv.x.d t4, f31
  li   t5, 0x3FF8000000000000
  bne  t4, t5, fail_line       // cold fill must carry P1
  li   t1, 1
  sd   t1, 0(s5)               // GO2: overwrite the resident line
  fence rw, rw
  li   t2, SPIN_TO
8: ld   t1, 0(s4)
  bnez t1, 9f
  addi t2, t2, -1
  bnez t2, 8b
  j    fail_barrier
9:fence rw, rw
  fld  f31, 0(s1)              // replay/invalidation path on the FP load class
  fmv.x.d t4, f31
  li   t5, 0x4000000000000000
  bne  t4, t5, fail_line

peer_done:
  // ---- phase C: per-hart FS attribution + done barrier ----
  csrr t4, mstatus
  srli t4, t4, 13
  andi t4, t4, 3
  li   t5, 3                   // FS must be Dirty on this hart (it wrote fregs)
  bne  t4, t5, fail_fs

  csrw mie, zero               // parked harts must not wake on stale msips
  li   t0, DONE
  slli t1, s11, 3
  add  t0, t0, t1
  li   t2, 1
  sd   t2, 0(t0)
  fence rw, rw

  bnez s11, park
  // hart 0 aggregates: all four done flags must be set.
  li   t2, SPIN_TO
  li   t0, DONE
10: ld   t1, 0(t0)
  beqz t1, 11f
  ld   t1, 8(t0)
  beqz t1, 11f
  ld   t1, 16(t0)
  beqz t1, 11f
  ld   t1, 24(t0)
  beqz t1, 11f
  li   a0, 1
  j    done
11: addi t2, t2, -1
  bnez t2, 10b
  j    fail_barrier

fail_ctx:
#ifdef ORACLE_NEGATIVE
  li   a0, 3
#else
  li   a0, 5
#endif
  j    done
fail_fs:
  li   a0, 7
  j    done
fail_line:
  li   a0, 9
  j    done
fail_barrier:
  li   a0, 11
  j    done

park:
  wfi
  j    park

done:
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
  j    park

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
