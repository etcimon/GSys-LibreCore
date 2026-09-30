# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Xg6lcai two-hart boot-load bench (WP4, SMT2+AI): HARTS software harts each own a T2
# queue (aiqctl qid = hartid) and push JOBS decode GEMM jobs (1 x N x K, format FMT) at
# the island concurrently -- shared A/B panels, a private C tile and descriptor per hart,
# completion through `ai.enq`/`ai.poll` (the sideband, never the global MMIO DONE word).
#
#   -DFMT=0|1|3..7   numeric format      -DN=512 -DK=512   decode panel (one island box)
#   -DJOBS=8         jobs per hart        -DHARTS=1|2       1 = single-hart control run
#
# Result (T0 convention): tohost = (wall_cycles << 1) | 1, where wall_cycles is the
# hart-0 rdcycle span from "both harts armed" to "every hart's last completion". The
# harness prints it as `*** FAILED *** (tohost = N)` by design; the harvester decodes
# it. Per-job island cycles come from `+ai_pmu_trace` AI_JOB records. Distribution:
# compare HARTS=2 (JOBS each) against HARTS=1 (JOBS) -- a well-distributed island serves
# 2*JOBS jobs in about the single-hart wall time of JOBS when the job is bytes-bound.
# Failure codes (even, exit bit clear -> classified FAIL): 3 | hart<<4 poll status !=
# OK, 7 | hart<<4 completion timeout, 13 | mcause<<4 trap.
#ifndef FMT
#define FMT 0
#endif
#ifndef N
#define N 512
#endif
#ifndef K
#define K 512
#endif
#ifndef JOBS
#define JOBS 8
#endif
#ifndef HARTS
#define HARTS 2
#endif
  .equ AI_BASE,   0x40000000
  .equ AI_CTL,    0x100
  .equ AI_REG0,   0x120
  .equ ST_OK,     0
#if FMT == 7
  .equ EB, 4
#elif FMT == 5 || FMT == 6
  .equ EB, 2
#else
  .equ EB, 1
#endif
  .equ ROW_BYTES, K * EB
  .equ AI_REGQ1,  0x1A0             # queue-1 region (REG_OFF_QUEUE_TAIL)
  .equ MAT_A,     0x80800000
  .equ MAT_B,     0x81000000
  .equ MAT_C,     0x81800000        # + hart * 0x100000
  .equ DESC_MEM,  0x80700000        # + hart * 0x40 (64 B aligned descriptors)
  .equ SYNC,      0x80710000        # [0] hart-0 setup done, [8] hart-1 done, [16] hart-1 cycles

  .section .text.init
  .globl _start
_start:
  csrr s1, mhartid                # s1 = hart
  li   t0, HARTS
  bge  s1, t0, park
  li   sp, 0x80008000
  slli t0, s1, 12
  sub  sp, sp, t0                 # private 4 KiB stack per hart
  la   t0, trap_vec
  csrw mtvec, t0
  li   s0, AI_BASE
  li   s2, SYNC
  bnez s1, wait_setup
  # hart 0: island enable + region 0 once, then release the others
  li   t0, 1
  sw   t0, AI_CTL(s0)
  li   t0, 0x80000000
  sw   t0, AI_REG0+0x0(s0)
  sw   zero, AI_REG0+0x4(s0)
  li   t0, 0x84000000
  sw   t0, AI_REG0+0x8(s0)
  sw   zero, AI_REG0+0xC(s0)
  li   t0, 0x3
  sw   t0, AI_REG0+0x10(s0)
#if HARTS > 1
  # hart 1 kicks on qid 1: its region lives at REG_OFF_QUEUE_TAIL (0x1A0 + (qid-1)*0x20);
  # an unprogrammed queue region refuses the descriptor (ST_BAD_PTR -> poll ERR, code 0x13).
  li   t0, 0x80000000
  sw   t0, AI_REGQ1+0x0(s0)
  sw   zero, AI_REGQ1+0x4(s0)
  li   t0, 0x84000000
  sw   t0, AI_REGQ1+0x8(s0)
  sw   zero, AI_REGQ1+0xC(s0)
  li   t0, 0x3
  sw   t0, AI_REGQ1+0x10(s0)
#endif
  fence
  li   t0, 1
  sd   t0, 0(s2)
  fence
  j    armed
wait_setup:
  ld   t0, 0(s2)
  beqz t0, wait_setup
armed:
  # per-hart queue: enable | qid = hart
  li   t0, 0x61
  slli t1, s1, 8
  or   t0, t0, t1
  csrw 0x5C1, t0
  # private descriptor and C tile
  li   s3, DESC_MEM
  slli t0, s1, 6
  add  s3, s3, t0
  li   s4, MAT_C
  slli t0, s1, 20
  add  s4, s4, t0
  rdcycle s5                      # start
  li   s6, JOBS
job:
  li   t0, (1 << 16) | 2          # OP_GEMM, ContractVersion 2
  li   t1, (FMT << 20)
  sw   t0, 0x00(s3)
  sw   t1, 0x04(s3)
  li   t2, 1
  sw   t2, 0x08(s3)               # m = 1 (decode)
  li   t2, N
  sw   t2, 0x0C(s3)
  li   t2, K
  sw   t2, 0x10(s3)
  li   t2, (K << 16) | K          # lda | ldb (elements)
  sw   t2, 0x14(s3)
  li   t2, MAT_A
  sd   t2, 0x18(s3)
  li   t2, MAT_B
  sd   t2, 0x20(s3)
  sd   s4, 0x28(s3)
  sd   zero, 0x30(s3)
  sd   zero, 0x38(s3)
  fence
  lw   t2, 0x38(s3)               # drain the write buffer before the fetch
  lw   zero, AI_CTL(s0)
  mv   a1, s3
  .word 0x0005D55B                # ai.enq a0, a1 -> ticket
  mv   a2, a0
  li   t2, 8000000
poll:
  mv   a1, a2
  .word 0x0205D55B                # ai.poll a0, a1
  bnez a0, done_job
  addi t2, t2, -1
  bnez t2, poll
  li   a0, 7
  j    fail_h
done_job:
  li   t2, 1
  bne  a0, t2, fail_status
  addi s6, s6, -1
  bnez s6, job
  rdcycle s7
  sub  s7, s7, s5                 # this hart's span
  bnez s1, hart1_done
  # hart 0: wait for hart 1 (HARTS == 2), take the max span, publish
#if HARTS > 1
wait_h1:
  ld   t0, 8(s2)
  beqz t0, wait_h1
  ld   t1, 16(s2)
  bge  s7, t1, 1f
  mv   s7, t1
1:
#endif
  slli a0, s7, 1
  ori  a0, a0, 1
  j    exit
hart1_done:
  sd   s7, 16(s2)
  fence
  li   t0, 1
  sd   t0, 8(s2)
  fence
park:
  wfi
  j    park
fail_status:
  li   a0, 3
  j    fail_h
fail_h:
  slli t0, s1, 4
  or   a0, a0, t0
exit:
  la   t0, tohost
  sw   a0, 0(t0)
9: j 9b

trap_vec:
  csrr a0, mcause
  slli a0, a0, 4
  ori  a0, a0, 13
  j    exit

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
