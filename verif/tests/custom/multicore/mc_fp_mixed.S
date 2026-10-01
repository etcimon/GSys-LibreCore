// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// FP-2 mixed-residency FP context check for the SMT OoO profile with FP
// (g6lc64_smt2_ooo_int + RVF/RVD, one physical core x two SMT threads,
// SmtDrainedHandoff=0 — both harts genuinely co-resident in the pipeline).
//
// The defect under test: the FPU's dynamic rounding mode / Xf precision came
// from the ACTIVE hart's CSR bank while the issuing op may belong to the
// resident peer (pre-FP-2 fpu_frm_i/fpu_prec_i scalars). With hart 0 on frm
// RTZ and hart 1 on frm RUP, a peer op issued under the wrong active-hart
// window rounds 1.0 + 2^-60 the wrong way and is caught below.
//
//   Phase A — frm isolation: hart 0 fsrm=RTZ, hart 1 fsrm=RUP; both loop
//     fadd.d(1.0, 2^-60, DYN). RTZ must give 0x3FF0000000000000 every round,
//     RUP 0x3FF0000000000001. The barrier before the loop plus the loop's
//     length keep both harts issuing inside each other's active windows.
//   Phase B — fflags isolation: hart 1 clears fflags and runs exact ops while
//     hart 0 keeps producing NX; hart 1's fflags must stay 0, hart 0's == NX.
//   Phase C — FS lazy-state isolation: hart 1 sets mstatus.FS=Off, one fadd.d
//     must take exactly one illegal-instruction trap (mcause 2, handler skips
//     it); hart 0's concurrent FP stream must take no trap and end FS=Dirty;
//     hart 1 then sets FS=Clean and, with no further FP op, reads Clean.
//
// tohost raw codes: 1 pass, 3 ORACLE_NEGATIVE arm, 5/7 hart0/hart1 frm
// mismatch, 9/11 fflags, 13/15 trap counts, 17/19 FS readback, 21 barrier.

#ifndef N
#define N 128
#endif

  .equ SPIN_TO,    400000
  .equ MSTATUS_FS, 0x6000
  .equ D_A,        0x3FF0000000000000   // 1.0
  .equ D_B,        0x3C30000000000000   // 2^-60

// Set SYN[x][hart]=1 then wait for both slots (or fail_bar on spin timeout).
.macro BAR syn
  la   t0, \syn
  slli t1, s11, 3
  add  t1, t0, t1
  li   t2, 1
  sd   t2, 0(t1)
  fence rw, rw
  li   t3, SPIN_TO
1:ld   t4, 0(t0)
  ld   t5, 8(t0)
  and  t6, t4, t5
  bnez t6, 2f
  addi t3, t3, -1
  bnez t3, 1b
  j    fail_bar
2:
.endm

  .option norvc
  .section .text.init
  .globl _start
_start:
  // norelax: without it `la` may relax to gp-relative and gp is never set.
  .option push
  .option norelax
  la   gp, __global_pointer$
  .option pop
  la   t1, trap
  csrw mtvec, t1
  csrr s11, mhartid          // 0 or 1 — kept for the whole program
  slli t1, s11, 5            // per-hart save area for the trap handler
  la   t0, save
  add  t0, t0, t1
  csrw mscratch, t0

  // FS=Initial (FP ops will drive Dirty), clean fflags, FP constants.
  li   t0, MSTATUS_FS
  csrc mstatus, t0
  li   t0, 0x2000
  csrs mstatus, t0
  csrw fflags, zero
  li   t2, D_A
  fmv.d.x f30, t2            // 1.0
  li   t2, D_B
  fmv.d.x f31, t2            // 2^-60
  li   t2, 0x4000000000000000
  fmv.d.x f29, t2            // 2.0

  // Per-hart rounding mode and expected sum. The csrr readback orders the
  // banked frm write ahead of the loop's DYN-mode ops.
  bnez s11, 1f
  li   t1, 1                 // RNE=0 RTZ=1
  j    2f
1:li   t1, 3                 // RUP=3
2:csrw frm, t1
  csrr t4, frm
  bne  t4, t1, fail_bar
  li   s9, D_A               // hart 0: RTZ truncates to 1.0
  bnez s11, 3f
  j    4f
3:
#ifdef ORACLE_NEGATIVE
  li   s9, D_A               // arm: demand the RTZ result on the RUP hart
#else
  li   s9, 0x3FF0000000000001 // hart 1: RUP rounds to 1.0 + ulp
#endif
4:

  // ---- phase A: concurrent DYN-mode rounding on both harts ---------------
  BAR  syncA
  li   s5, N
aloop:
  fadd.d f4, f30, f31        // rm=DYN — uses the ISSUING op's hart's frm
  fmv.x.d t4, f4
  bne  t4, s9, fail_frm
  // integer filler keeps both harts busy across several select quanta
  addi t3, t3, 1
  xor  t5, t3, t4
  add  t6, t5, s5
  sub  t5, t6, t3
  addi s5, s5, -1
  bnez s5, aloop

  // ---- phase B: fflags isolation -----------------------------------------
  BAR  syncB
  bnez s11, b_hart1
  // hart 0 keeps producing NX while the peer's fflags must stay clear.
  li   s5, N
bloop0:
  fadd.d f4, f30, f31
  addi s5, s5, -1
  bnez s5, bloop0
  csrr t4, fflags
  li   t5, 1                 // exactly NX — the peer's flags must not leak in
  bne  t4, t5, fail_ff0
  j    c_entry
b_hart1:
  csrw fflags, zero
  li   s5, N
bloop1:
  fadd.d f4, f29, f29        // 2.0+2.0 = 4.0 exact, no flags
  addi s5, s5, -1
  bnez s5, bloop1
  csrr t4, fflags
  bnez t4, fail_ff1          // peer's NX must not land in this bank

  // ---- phase C: FS lazy-state isolation ----------------------------------
c_entry:
  BAR  syncC
  bnez s11, c_hart1
  // hart 0 keeps running FP while hart 1 toggles FS; it must not trap and
  // must end Dirty.
  li   s5, 2*N
cloop0:
  fadd.d f4, f30, f31
  addi s5, s5, -1
  bnez s5, cloop0
  j    final_checks
c_hart1:
  li   t0, MSTATUS_FS
  csrc mstatus, t0           // FS=Off
  fadd.d f4, f30, f31        // illegal instruction -> trap, handler skips
  // exactly one trap, mcause 2
  slli t1, s11, 3
  la   t0, trapcnt
  add  t0, t0, t1
  ld   t4, 0(t0)
  li   t5, 1
  bne  t4, t5, fail_tr1
  la   t0, trapcause
  add  t0, t0, t1
  ld   t4, 0(t0)
  li   t5, 2
  bne  t4, t5, fail_tr1
  // restore FS then leave it Clean with no further FP op
  li   t0, MSTATUS_FS
  csrc mstatus, t0
  li   t0, 0x4000            // FS=Clean
  csrs mstatus, t0
  csrr t4, mstatus
  srli t4, t4, 13
  andi t4, t4, 3
  li   t5, 2
  bne  t4, t5, fail_fs1

final_checks:
  BAR  syncD
  bnez s11, park
  // hart 0: no trap may have arrived during the peer's FS=Off window.
  la   t0, trapcnt
  ld   t4, 0(t0)
  bnez t4, fail_tr0
  csrr t4, mstatus
  srli t4, t4, 13
  andi t4, t4, 3
  li   t5, 3                 // Dirty — hart 0 wrote FP state throughout
  bne  t4, t5, fail_fs0
  li   a0, 1
  j    done

fail_frm:
#ifdef ORACLE_NEGATIVE
  li   a0, 3
#else
  slli a0, s11, 1            // hart 0 -> 5, hart 1 -> 7
  addi a0, a0, 5
#endif
  j    done
fail_ff1:
  li   a0, 9
  j    done
fail_ff0:
  li   a0, 11
  j    done
fail_tr1:
  li   a0, 13
  j    done
fail_tr0:
  li   a0, 15
  j    done
fail_fs1:
  li   a0, 17
  j    done
fail_fs0:
  li   a0, 19
  j    done
fail_bar:
  li   a0, 21
  j    done

park:
  wfi
  j    park

done:
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
  j    park

  // M-mode trap vector (shared). Counts the trap and records mcause per
  // hart, then skips the instruction — an unexpected hart-0 trap is caught
  // by the final trapcnt[0]==0 check rather than diagnosed in-line.
  .align 2
trap:
  csrrw a0, mscratch, a0     // a0 <- save area; mscratch <- old a0
  sd    t0, 0(a0)
  sd    t1, 8(a0)
  sd    t2, 16(a0)
  csrr  t0, mhartid
  slli  t0, t0, 3
  la    t1, trapcnt
  add   t1, t1, t0
  ld    t2, 0(t1)
  addi  t2, t2, 1
  sd    t2, 0(t1)
  la    t1, trapcause
  add   t1, t1, t0
  csrr  t2, mcause
  sd    t2, 0(t1)
  csrr  t0, mepc
  addi  t0, t0, 4
  csrw  mepc, t0
  ld    t0, 0(a0)
  ld    t1, 8(a0)
  ld    t2, 16(a0)
  csrrw a0, mscratch, a0
  mret

  .data
  .align 3
syncA:    .dword 0, 0
syncB:    .dword 0, 0
syncC:    .dword 0, 0
syncD:    .dword 0, 0
trapcnt:  .dword 0, 0
trapcause: .dword 0, 0
save:     .dword 0, 0, 0, 0, 0, 0, 0, 0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .globl fromhost
fromhost: .dword 0
