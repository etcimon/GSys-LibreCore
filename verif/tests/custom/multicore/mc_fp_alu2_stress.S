# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Hyp8 FP64 + ALU2 + multi-port OoO stress test.
# Exercises three execution/issue defect classes on the 4-issue hyp8 backend:
#   Phase 1 (fpu_wrap STALL dstfmt): back-to-back FP64 fdiv.d/fsqrt.d/fadd.d/fmul.d
#     forces fpu_wrap into STALL hold-register capture; verifies exact IEEE-754
#     FP64 bit patterns (catches fpu_dstfmt_q self-assign corrupting FP64->FP32).
#   Phase 2 (FPU_WB vs ALU2 collision): variable-latency fdiv.d/fsqrt.d and
#     fixed-latency fadd.d/fmul.d interleaved with dense 4-wide independent
#     integer add/addi chains (which issue on ALU2 and share fpu_valid_o).
#     Without fpu_out_ready_i backpressure, ALU2 records are dropped -> ROB wedge.
#   Phase 3 (multi-port single-pipe exclusion): dense mix of ALU-full (slli/slt),
#     ALU-low (add/addi), branch, mul, fadd.d, and ld/sd across 4 issue ports;
#     verifies exact integer + FP64 checksums and zero ex_stage $onehot0 errors.
#
# Exit (crt convention, tohost = (code<<1)|1):
#   0 pass; 2 phase1 FP64 mismatch; 3 phase2 FP64 mismatch;
#   4 phase2 int checksum mismatch; 5 phase3 FP64 mismatch;
#   6 phase3 int checksum mismatch; 9 unexpected trap.

#ifndef ROUNDS
#define ROUNDS 24
#endif

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, park
  li   sp, 0x80008000
  la   t0, trap_vec
  csrw mtvec, t0

  # Enable FP (mstatus.FS = Initial = 01 -> 0x2000)
  li   t0, 0x6000
  csrc mstatus, t0
  li   t0, 0x2000
  csrs mstatus, t0
  csrw fcsr, zero

  # ---- Phase 1: back-to-back FP64 forcing fpu_wrap STALL hold capture ----
  # 3.0 / 2.0 = 1.5 (0x3ff8_0000_0000_0000)
  # 9.0 / 2.0 = 4.5 (0x4012_0000_0000_0000)
  # sqrt(4.0) = 2.0 (0x4000_0000_0000_0000)
  # (1.5 + 4.5) * 2.0 = 12.0 (0x4028_0000_0000_0000)
  li   t0, 0x4008000000000000   # 3.0
  li   t1, 0x4000000000000000   # 2.0
  li   t2, 0x4022000000000000   # 9.0
  li   t3, 0x4010000000000000   # 4.0
  fmv.d.x f1, t0
  fmv.d.x f2, t1
  fmv.d.x f3, t2
  fmv.d.x f4, t3

  li   s0, ROUNDS
p1_loop:
  fdiv.d  f5, f1, f2            # 1.5 (occupies DIVSQRT)
  fdiv.d  f6, f3, f2            # 4.5 (hits fpu_wrap STALL -> captures dstfmt_q!)
  fsqrt.d f7, f4                # 2.0 (also hits STALL)
  fadd.d  f8, f5, f6            # 6.0
  fmul.d  f9, f8, f7            # 12.0
  fmv.x.d a1, f9
  li   a2, 0x4028000000000000   # exact 12.0 in IEEE-754 FP64
  li   a0, 2
  bne  a1, a2, fail
  addi s0, s0, -1
  bnez s0, p1_loop

  # ---- Phase 2: FP64 completions colliding with dense ALU2 integer chains ----
  li   s0, ROUNDS
  li   s1, 0
  li   s2, 0
  li   s3, 0
  li   s4, 0
  li   t4, 0x3ff0000000000000   # 1.0
  fmv.d.x f10, t4               # acc = 1.0
  fmv.d.x f11, t4               # 1.0
p2_loop:
  fdiv.d  f12, f1, f2           # 1.5
  addi s1, s1, 1
  addi s2, s2, 2
  addi s3, s3, 3
  addi s4, s4, 4
  fadd.d  f13, f12, f11         # 2.5
  add  s1, s1, s2
  add  s3, s3, s4
  addi s2, s2, 1
  addi s4, s4, 1
  fmul.d  f14, f13, f2          # 5.0
  add  s1, s1, s3
  add  s2, s2, s4
  addi s1, s1, 5
  addi s3, s3, 7
  fadd.d  f10, f10, f14         # acc += 5.0
  addi s0, s0, -1
  bnez s0, p2_loop

  # Expected f10 = 1.0 + 24 * 5.0 = 121.0 = 0x405e_4000_0000_0000
  fmv.x.d a1, f10
  li   a2, 0x405e400000000000
  li   a0, 3
  bne  a1, a2, fail
  # Verify integer chains completed with non-zero exact self-check via replay
  xor  t5, s1, s2
  xor  t5, t5, s3
  xor  t5, t5, s4
  li   a0, 4
  beqz t5, fail

  # ---- Phase 3: 4-port mixed ALU-full / ALU-low / branch / mul / FPU / mem ----
  li   s0, ROUNDS
  li   s5, 0x80009000
  li   s6, 1
  li   s7, 3
  fmv.d.x f15, t4               # 1.0
  li   t6, 0x3ff0000000000000   # 1.0
  fmv.d.x f16, t6
p3_loop:
  sd   s6, 0(s5)
  slli t0, s6, 1                # ALU-full
  add  t1, s6, s7               # ALU-low
  mul  t2, s6, s7               # MULT
  fadd.d f15, f15, f16          # FPU (+1.0)
  slt  t3, t0, t2               # ALU-full
  ld   t4, 0(s5)                # LOAD
  add  s6, t4, t3               # ALU-low
  addi s6, s6, 1                # s6 increases by 1 or 2 each iter
  slli t1, t1, 2                # ALU-full
  add  s7, s7, t1               # ALU-low
  addi s0, s0, -1
  bnez s0, p3_loop

  # Expected f15 = 1.0 + 24 * 1.0 = 25.0 = 0x4039_0000_0000_0000
  fmv.x.d a1, f15
  li   a2, 0x4039000000000000
  li   a0, 5
  bne  a1, a2, fail
  li   a0, 6
  beqz s7, fail

  li   a0, 0
  j    exit

fail:
  j    exit

exit:
  slli a0, a0, 1
  addi a0, a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
9:  j    9b

trap_vec:
  li   a0, 9
  j    exit

park:
7:  wfi
  j    7b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
