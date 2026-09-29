# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# T0/T1 instruction bench (low level): cycles per operation of the in-core Xg6lcai ops,
# measured with rdcycle over ITER back-to-back issues, reported through tohost.
#
#   -DOP=0   ai.dot4.s8  rd, rs1, rs2        (4 x s8 lanes -> s32, GPR only)
#   -DOP=1   ai.dot4a.s8 rd, rs1, rs2        (accumulating form, 3 GPR reads)
#   -DOP=2   ai.mma.s8   acc0, t0, t1        (2x2x2 tile MMA; relacc + mma per iteration)
#   -DOP=3   ai.mvta / ai.mvacc round trip   (tile load + accumulator read)
#   -DITER=N iterations (default 256)
#
# Result: tohost = (cycles << 1) | 1, i.e. HTIF exit code == measured cycles for ITER
# operations (the harvester divides by ITER). A wrong dot4 result exits with code 3,
# a wrong mma result with code 5, a trap with 13 | mcause << 4.

#ifndef OP
#define OP 0
#endif
#ifndef ITER
#define ITER 256
#endif

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
  la   t0, trap_vec
  csrw mtvec, t0
  # ais = Initial (aistatus bits 7:6 = 01), as the golden tests do
  csrr t0, 0x802
  li   t1, ~(0x3 << 6)
  and  t0, t0, t1
  li   t1, (0x1 << 6)
  or   t0, t0, t1
  csrw 0x802, t0

#if OP == 0 || OP == 1
  li   a1, 0x01020304             # lanes 4,3,2,1
  li   a2, 0x01010101             # lanes 1,1,1,1 -> dot = 10
  li   a0, 0
  li   s1, ITER
  rdcycle s2
1:
#if OP == 0
  .word 0x00C5B55B                # ai.dot4.s8  a0, a1, a2
#else
  .word 0x04C5B55B                # ai.dot4a.s8 a0, a1, a2 (accumulate into a0)
#endif
  addi s1, s1, -1
  bnez s1, 1b
  rdcycle s3
  sub  s3, s3, s2
#if OP == 0
  li   t0, 10
#else
  li   t0, 10 * ITER
#endif
  bne  a0, t0, fail_dot
  j    report

#elif OP == 2 || OP == 3
  # setcfg: M=N=K=log2(2)=1, dtype=s8, accmode=overwrite (ai_mma_s8_golden)
  li   a1, 0x00000111
  .word 0x0005855B                # ai.setcfg a0, a1
  .word 0x0400005B                # ai.relacc acc0
  li   a1, 1
  .word 0x0605A05B                # ai.mvta t0, a1, e0
  li   a1, 2
  .word 0x0615A05B                # e1
  li   a1, 3
  .word 0x0685A05B                # e8
  li   a1, 4
  .word 0x0695A05B                # e9
  li   a1, 5
  .word 0x0605A0DB                # ai.mvta t1, a1, e0
  li   a1, 6
  .word 0x0615A0DB
  li   a1, 7
  .word 0x0685A0DB
  li   a1, 8
  .word 0x0695A0DB
  li   s1, ITER
  rdcycle s2
2:
#if OP == 2
  .word 0x0400005B                # ai.relacc acc0
  .word 0x0010105B                # ai.mma.s8 acc0, t0, t1
#else
  li   a1, 1
  .word 0x0605A05B                # ai.mvta t0, a1, e0
  .word 0x0400255B                # ai.mvacc a0, acc0, e0
#endif
  addi s1, s1, -1
  bnez s1, 2b
  rdcycle s3
  sub  s3, s3, s2
#if OP == 2
  .word 0x0400255B                # ai.mvacc a0, acc0, e0 -> 1*5 + 2*7 = 19
  li   t0, 19
  bne  a0, t0, fail_mma
#endif
  j    report
#else
#error "OP must be 0..3"
#endif

report:
  slli a0, s3, 1
  ori  a0, a0, 1
  j    exit
fail_dot:
  li   a0, 3
  j    exit
fail_mma:
  li   a0, 5
exit:
  la   t0, tohost
  sd   a0, 0(t0)
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
