# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Matrix GEMM bench for the Xg6lcai island on the SoC model (g6lc64_ai, bench SKU).
# One (format, shape, submission path, residency) point of the bench matrix per ELF:
#
#   -DFMT=<0..7>      numfmt: 0 int8, 1 int4, 3 fp8e4m3, 4 fp8e5m2, 5 fp16, 6 bf16, 7 fp32
#   -DM= -DN= -DK=    operation shape (C[M][N] = A[M][K] . B[N][K]^T, k-major B);
#                     lda = ldb = K. Shapes beyond the island box are tiled by this ELF
#                     exactly as the runtime does: N in 512-column panels, M in 1024-row
#                     panels, K in 512-deep blocks chained through flags.accmode=01
#                     (the CAP_ACCMODE grant); each (M,N) panel owns a packed C buffer.
#   -DPATH=0|1        0 "low level": MMIO latched descriptor + doorbell, DONE/TICKET/DSTATUS
#                     polled and claimed over MMIO (what a bare-metal driver does);
#                     1 "high level": descriptor in memory, `ai.enq` (ticket from the core),
#                     completion observed with `ai.poll`, then the MMIO claim (what the
#                     runtime / Python `Device.gemm_native` path lowers to).
#   -DNOFILL=0        also fill A/B with the format's all-ones pattern (default 1: skip)
#   -DKBOX=512        K per island job (flat-panel island: 1024 makes 1x256x1024 one job)
#   -DREUSE=0|1|2     0 cold: one pass; 1 / 2: two passes, the second setting FLAG_REUSE_A
#                     (bit 23) / FLAG_REUSE_B (bit 15) so an identical panel is served from
#                     the resident operand bank (VaTurboEn island). The per-job la/lb of
#                     pass 2 in the `AI_JOB` records is the residency win (decode speed).
#
# Operands are the format's all-ones pattern; arithmetic is qualified by the directed
# suites, this ELF measures cycles: every job must complete ST_OK with its own ticket
# and a non-zero PMU cycle word. The per-phase numbers come from the island's
# +ai_pmu_trace `AI_JOB` records (verif/regress/ai-matrix-veri.sh AI_MATRIX_BENCH=1 ->
# verif/regress/remote/ai_bench_report.py --soc).
#
# tohost: 1 pass, 3 status/ticket mismatch, 5 PMU cycles zero, 7 completion timeout,
#         9 ai.poll returned ERR, 13|mcause<<4 trap.

#ifndef FMT
#define FMT 0
#endif
#ifndef M
#define M 1
#endif
#ifndef N
#define N 512
#endif
#ifndef K
#define K 512
#endif
#ifndef PATH
#define PATH 0
#endif
#ifndef REUSE
#define REUSE 0
#endif
#ifndef NOFILL
#define NOFILL 1
#endif
#ifndef KBOX
#define KBOX 512                  /* K per job; a flat-panel island (CAP_BANK_*_BYTES) takes
                                     the whole row while n*pitch fits, e.g. -DKBOX=1024 */
#endif

  .equ AI_BASE,     0x40000000
  .equ AI_CTL,      0x100
  .equ AI_DOORBELL, 0x108
  .equ AI_DONE,     0x10C
  .equ AI_TICKET,   0x110
  .equ AI_DSTATUS,  0x114
  .equ AI_REG0,     0x120
  .equ AI_DESC,     0x140
  .equ AI_PMU_CY,   0x188
  .equ ST_OK,       0
  .equ TICKET0,     0x40

  .equ BOX_M, 1024
  .equ BOX_N, 512
  .equ BOX_K, KBOX
#if M < 1024
#define TM M
#else
#define TM 1024
#endif
#if N < 512
#define TN N
#else
#define TN 512
#endif
  .equ NT_M, (M + BOX_M - 1) / BOX_M
  .equ NT_N, (N + BOX_N - 1) / BOX_N
  .equ NT_K, (K + BOX_K - 1) / BOX_K

# element bytes (INT4 rows are K/2 bytes: EB=1 over-allocates, harmless) and the
# all-ones pattern per format
#if FMT == 7
  .equ EB, 4
  .equ PATTERN, 0x3F8000003F800000
#elif FMT == 5
  .equ EB, 2
  .equ PATTERN, 0x3C003C003C003C00
#elif FMT == 6
  .equ EB, 2
  .equ PATTERN, 0x3F803F803F803F80
#elif FMT == 3
  .equ EB, 1
  .equ PATTERN, 0x3838383838383838
#elif FMT == 4
  .equ EB, 1
  .equ PATTERN, 0x3C3C3C3C3C3C3C3C
#elif FMT == 1
  .equ EB, 1
  .equ PATTERN, 0x1111111111111111
#else
  .equ EB, 1
  .equ PATTERN, 0x0101010101010101
#endif

  # Operand placement: fixed DRAM windows (not .data) so a 1 MiB panel does not
  # bloat the ELF. Row stride is K elements for both A and B.
  .equ MAT_A, 0x80800000
  .equ MAT_B, 0x81000000
  .equ MAT_C, 0x81800000
  .equ DESC_MEM, 0x80700000        # 64 B aligned descriptor for the ai.enq path
  .equ ROW_BYTES, K * EB
  .equ A_BYTES, M * ROW_BYTES
  .equ B_BYTES, N * ROW_BYTES
  .equ C_PANEL_BYTES, TM * TN * 4
  .equ C_BYTES, NT_M * NT_N * C_PANEL_BYTES
  .equ FLAG_REUSE_B, (1 << 15)
  .equ FLAG_REUSE_A, (1 << 23)
  .equ FLAG_ACC01,   (1 << 10)

  .section .text.init
  .globl _start
_start:
  # g6lc64_ai has two cores and both start here: only hart 0 drives the island;
  # any other hart parks, otherwise every MMIO doorbell/claim is issued twice.
  csrr t0, mhartid
  beqz t0, 1f
2: wfi
  j    2b
1:
  li   sp, 0x80008000
  la   t0, trap_vec
  csrw mtvec, t0
  andi sp, sp, -16
  li   s0, AI_BASE
#if PATH == 1
  li   t0, 0x61                   # aiqctl: queue enable, qid 0 (ai_enq_fetch_smoke)
  csrw 0x5C1, t0
#endif

  li   t0, 1
  sw   t0, AI_CTL(s0)
  # AI-3 region 0: [0x80000000, 0x84000000) RW covers code, descriptor and operands
  li   t0, 0x80000000
  sw   t0, AI_REG0+0x0(s0)
  sw   zero, AI_REG0+0x4(s0)
  li   t0, 0x84000000
  sw   t0, AI_REG0+0x8(s0)
  sw   zero, AI_REG0+0xC(s0)
  li   t0, 0x3
  sw   t0, AI_REG0+0x10(s0)

#if NOFILL
  # Operands left as the simulator's zero-initialised DRAM: the island's cycle
  # counts do not depend on operand values (data is qualified by the directed
  # suites), and a 256 KiB store loop costs more simulated cycles than the GEMM.
  j    fill_done
#endif
  # Fill A and B with the pattern, zero C.
  li   t0, MAT_A
  li   t1, (A_BYTES + 7) / 8
  li   t2, PATTERN
1:
  sd   t2, 0(t0)
  addi t0, t0, 8
  addi t1, t1, -1
  bnez t1, 1b
  li   t0, MAT_B
  li   t1, (B_BYTES + 7) / 8
2:
  sd   t2, 0(t0)
  addi t0, t0, 8
  addi t1, t1, -1
  bnez t1, 2b
  li   t0, MAT_C
  li   t1, (C_BYTES + 7) / 8
3:
  sd   zero, 0(t0)
  addi t0, t0, 8
  addi t1, t1, -1
  bnez t1, 3b
  fence
fill_done:

  li   s1, 0                      # pass (0 cold, 1 reuse)
  li   s2, TICKET0                # next ticket
pass:
  li   s3, 0                      # mi
loop_m:
  li   s4, 0                      # nj
loop_n:
  li   s5, 0                      # kk
loop_k:
  # ---- descriptor for panel (mi, nj), K block kk ----
  li   t0, (1 << 16) | 2          # OP_GEMM, ContractVersion 2
  li   t1, (FMT << 20)
  beqz s5, 4f
  ori  t1, t1, FLAG_ACC01         # chain onto the panel's C
4:
  beqz s1, 5f
#if REUSE == 1
  li   t3, FLAG_REUSE_A
  or   t1, t1, t3
#elif REUSE == 2
  li   t3, FLAG_REUSE_B
  or   t1, t1, t3
#endif
5:
  # m, n, k of this tile
  li   t2, M
  li   t3, BOX_M
  mul  t4, s3, t3
  sub  t2, t2, t4                 # rows left
  bge  t3, t2, 6f
  mv   t2, t3
6:
  mv   s6, t2                     # tile m
  li   t2, N
  li   t3, BOX_N
  mul  t4, s4, t3
  sub  t2, t2, t4
  bge  t3, t2, 7f
  mv   t2, t3
7:
  mv   s7, t2                     # tile n
  li   t2, K
  li   t3, BOX_K
  mul  t4, s5, t3
  sub  t2, t2, t4
  bge  t3, t2, 8f
  mv   t2, t3
8:
  mv   s8, t2                     # tile k
  # pointers: A + mi*BOX_M*ROW_BYTES + kk*BOX_K*EB ; B + nj*BOX_N*ROW_BYTES + kk*BOX_K*EB
  li   t3, ROW_BYTES
  li   t4, BOX_M
  mul  t4, t4, t3
  mul  t4, t4, s3
  li   t5, BOX_K * EB
  mul  t5, t5, s5
  li   s9, MAT_A
  add  s9, s9, t4
  add  s9, s9, t5                 # ptr_a
  li   t4, BOX_N
  mul  t4, t4, t3
  mul  t4, t4, s4
  li   s10, MAT_B
  add  s10, s10, t4
  add  s10, s10, t5               # ptr_b
  li   t4, NT_N
  mul  t4, t4, s3
  add  t4, t4, s4                 # panel index
  li   t5, C_PANEL_BYTES
  mul  t4, t4, t5
  li   s11, MAT_C
  add  s11, s11, t4               # ptr_c (packed tile)

#if PATH == 0
  sw   t0, AI_DESC+0x0(s0)
  sw   t1, AI_DESC+0x4(s0)
  sw   s6, AI_DESC+0x8(s0)
  sw   s7, AI_DESC+0xC(s0)
  sw   s8, AI_DESC+0x10(s0)
  li   t2, (K << 16) | K
  sw   t2, AI_DESC+0x14(s0)
  sw   s9, AI_DESC+0x18(s0)
  srli t2, s9, 32
  sw   t2, AI_DESC+0x1C(s0)
  sw   s10, AI_DESC+0x20(s0)
  srli t2, s10, 32
  sw   t2, AI_DESC+0x24(s0)
  sw   s11, AI_DESC+0x28(s0)
  srli t2, s11, 32
  sw   t2, AI_DESC+0x2C(s0)
  sw   zero, AI_DESC+0x30(s0)
  sw   zero, AI_DESC+0x34(s0)
  sw   zero, AI_DESC+0x38(s0)
  sw   zero, AI_DESC+0x3C(s0)
  fence
  lw   zero, AI_CTL(s0)
  slli t2, s2, 8
  sw   t2, AI_DOORBELL(s0)
  mv   a2, s2                     # expected ticket
#else
  li   a1, DESC_MEM
  sw   t0, 0x00(a1)
  sw   t1, 0x04(a1)
  sw   s6, 0x08(a1)
  sw   s7, 0x0C(a1)
  sw   s8, 0x10(a1)
  li   t2, (K << 16) | K
  sw   t2, 0x14(a1)
  sd   s9, 0x18(a1)
  sd   s10, 0x20(a1)
  sd   s11, 0x28(a1)
  sd   zero, 0x30(a1)
  sd   zero, 0x38(a1)
  fence
  lw   t2, 0x38(a1)               # drain the WT write buffer before the fetch
  lw   zero, AI_CTL(s0)
  .word 0x0005D55B                # ai.enq a0, a1   (a1 = &desc) -> a0 = ticket
  # ai.enq holds VALID until the island accepts, so the returned ticket is the
  # accepted one; tickets start at 0, so 0 is a ticket, not a refusal.
  mv   a2, a0                     # expected ticket
  # ai.poll a0, a1 until non-zero: 1 OK, 2 ERR
  li   t2, 4000000
9:
  mv   a1, a2
  .word 0x0205D55B                # ai.poll a0, a1
  bnez a0, 10f
  addi t2, t2, -1
  bnez t2, 9b
  li   a0, 7
  j    exit
10:
  li   t2, 1
  bne  a0, t2, fail_poll
#endif

  # completion over MMIO (both paths): sticky DONE, ticket, status, PMU, claim
  li   t2, 4000000
11:
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  bnez t0, 12f
  addi t2, t2, -1
  bnez t2, 11b
  li   a0, 7
  j    exit
12:
  lw   t0, AI_DSTATUS(s0)
  slli t0, t0, 48
  srli t0, t0, 48
  li   t1, ST_OK
  bne  t0, t1, fail_id
  lw   t0, AI_TICKET(s0)
  slli t0, t0, 32
  srli t0, t0, 32
  bne  t0, a2, fail_id
  lw   t0, AI_PMU_CY(s0)
  beqz t0, fail_pmu
  li   t0, 1
  sw   t0, AI_DONE(s0)
  fence
  lw   zero, AI_DONE(s0)
  addi s2, s2, 1

  addi s5, s5, 1
  li   t0, NT_K
  blt  s5, t0, loop_k
  addi s4, s4, 1
  li   t0, NT_N
  blt  s4, t0, loop_n
  addi s3, s3, 1
  li   t0, NT_M
  blt  s3, t0, loop_m

  addi s1, s1, 1
#if REUSE != 0
  li   t0, 2
#else
  li   t0, 1
#endif
  blt  s1, t0, pass

  li   a0, 1
  j    exit
fail_id:
  li   a0, 3
  j    exit
fail_pmu:
  li   a0, 5
  j    exit
fail_poll:
  li   a0, 9
exit:
  la   t0, tohost
  sw   a0, 0(t0)
9: j 9b

trap_vec:
  # A trap is a bench failure (13 | mcause<<4): no soft-pass on this SKU.
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
