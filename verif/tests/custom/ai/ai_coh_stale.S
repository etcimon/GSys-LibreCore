# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Output coherence of island DMA writes (AiCfg.DmaInvalEn, CAP_OFF_COH bit 0).
#
# The island joins the fabric below the cluster, so a line a core already holds
# in L1/L2/L3 is NOT updated by an island write. This test makes the hazard
# happen on purpose: it READS the completion word first (allocating the line in
# every cache level it can), lets the island write it, then reads it again with
# no cache maintenance in between.
#
#   DmaInvalEn = 1  -> the second read sees the island's word (PASS)
#   DmaInvalEn = 0  -> the second read sees the stale sentinel (FAIL) unless the
#                      software arm (-DAI_COH_SW) issues cbo.inval on the line
#                      before re-reading, which must PASS on every package.
#
# The test refuses to run as a vacuous pass: the first read must return the
# sentinel (proves the line was fetched into the cache before the job), and the
# hardware arm also requires CAP_OFF_COH[0] to say the island advertises the
# contract it is being held to (a package that does not advertise it and does
# not define AI_COH_SW writes fail code 7: "hazard not covered").
# HTIF fail codes odd only.

  .equ AI_BASE,     0x40000000
  .equ AI_CAP_COH,  0x0A0
  .equ AI_CTL,      0x100
  .equ AI_DOORBELL, 0x108
  .equ AI_DONE,     0x10C
  .equ AI_TICKET,   0x110
  .equ AI_DSTATUS,  0x114
  .equ AI_REG0,     0x120
  .equ AI_DESC,     0x140
  .equ ST_OK,       0
  .equ TICKET,      11

  .section .text.init
  .globl _start
_start:
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

  # Contract check: the hardware arm needs CAP_OFF_COH[0]; the software arm does not.
  lw   t0, AI_CAP_COH(s0)
  andi t0, t0, 1
#ifndef AI_COH_SW
  beqz t0, not_covered
#endif

  # CTL[0]=enable, CTL[1]=wr_cpl_en (completion DMA)
  li   t0, 3
  sw   t0, AI_CTL(s0)

  li   t0, 0x80000000
  sw   t0, AI_REG0+0x0(s0)
  sw   zero, AI_REG0+0x4(s0)
  li   t0, 0x80100000
  sw   t0, AI_REG0+0x8(s0)
  sw   zero, AI_REG0+0xC(s0)
  li   t0, 0x3
  sw   t0, AI_REG0+0x10(s0)

  # Sentinel into the completion word, drained to memory, then READ BACK so the
  # cache line is resident in L1 (and allocated in L2/L3 where present).
  la   s1, done_word
  li   t0, 0x5A5A5A5A5A5A5A5A
  sd   t0, 0(s1)
  fence
  ld   t1, 0(s1)
  bne  t1, t0, fail                # the line must be readable (and now cached)
  ld   t1, 0(s1)                   # second touch: hit, proves residency path
  bne  t1, t0, fail

  # OP_LAYOUT spine job (no GEMM) with ptr_done = &done_word
  li   t0, (3 << 16) | 2
  sw   t0, AI_DESC+0x0(s0)
  sw   zero, AI_DESC+0x4(s0)
  li   t0, 8
  sw   t0, AI_DESC+0x8(s0)
  sw   t0, AI_DESC+0xC(s0)
  sw   t0, AI_DESC+0x10(s0)
  li   t0, 0x00080008
  sw   t0, AI_DESC+0x14(s0)
  li   t0, 0x80010000
  sw   t0, AI_DESC+0x18(s0)
  sw   zero, AI_DESC+0x1C(s0)
  li   t0, 0x80011000
  sw   t0, AI_DESC+0x20(s0)
  sw   zero, AI_DESC+0x24(s0)
  li   t0, 0x80012000
  sw   t0, AI_DESC+0x28(s0)
  sw   zero, AI_DESC+0x2C(s0)
  sw   zero, AI_DESC+0x30(s0)
  sw   zero, AI_DESC+0x34(s0)
  sw   s1, AI_DESC+0x38(s0)
  srli t1, s1, 32
  sw   t1, AI_DESC+0x3C(s0)

  fence
  lw   zero, AI_CTL(s0)

  li   t0, (TICKET << 8)
  sw   t0, AI_DOORBELL(s0)

  li   t2, 2000
1:
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  bnez t0, 2f
  addi t2, t2, -1
  bnez t2, 1b
  j    fail
2:
  lw   t0, AI_DSTATUS(s0)
  slli t0, t0, 48
  srli t0, t0, 48
  bnez t0, fail
  lw   t0, AI_TICKET(s0)
  li   t1, TICKET
  bne  t0, t1, fail

  # The hazard: re-read the completion word. No maintenance on the hardware arm.
  fence
#ifdef AI_COH_SW
  # cbo.inval (a0): MISC-MEM, funct3=010, rd=0, imm=0
  mv   a0, s1
  .insn i 0x0f, 0x2, x0, 0(a0)
  fence
#endif
  ld   t1, 0(s1)
  li   t2, TICKET
  sext.w t3, t1
  bne  t3, t2, stale
  srli t1, t1, 32
  slli t1, t1, 48
  srli t1, t1, 48
  bnez t1, stale

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
3: j 3b

stale:                             # the cached copy survived the island write
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
4: j 4b

not_covered:                       # package advertises no hardware coherence
  li   a0, 7
  la   t0, tohost
  sw   a0, 0(t0)
6: j 6b

fail:
  li   a0, 9
  la   t0, tohost
  sw   a0, 0(t0)
7: j 7b

trap_vec:
  li   a0, 5
  la   t0, tohost
  sw   a0, 0(t0)
5: j 5b

  .section .data
  .align 6
  .globl done_word
done_word:
  .dword 0
  .fill 7, 8, 0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
