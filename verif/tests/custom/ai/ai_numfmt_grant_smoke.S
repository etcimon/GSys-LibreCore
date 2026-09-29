# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Numeric-format grant enforcement (AI-X2). The island publishes the formats it
# implements at CAP_OFF_DTYPE_MASK and must REFUSE a descriptor asking for one
# it does not, with ST_BAD_FMT.
#
# Refusing rather than demoting is the whole point. A descriptor outlives the
# thread that wrote it and may arrive from a host process across the PCIe
# transport, so there is nobody left to read a downgraded grant word. Computing
# INT8 over BF16 bits would return numerically plausible results that nothing
# downstream can detect -- strictly worse than an error.
#
# The test is two-sided on purpose, which is what makes it an oracle:
#   1. numfmt=AI_FMT_INT (0)   -> ST_OK      (the check must not over-reject;
#                                             flags==0 is also what every
#                                             pre-numfmt image writes)
#   2. numfmt=AI_FMT_BF16 (6)  -> ST_BAD_FMT (the check fires)
#   3. numfmt=AI_FMT_FP32 (7)  -> ST_BAD_FMT (not just one hard-coded value)
#   4. numfmt=AI_FMT_INT (0)   -> ST_OK      (refusal is not sticky)
# A run that reports ST_OK for step 2 means the grant check did not fire.
#
# numfmt is flags[22:20] (isa-encoding.md §3.1a / FLAG_NUMFMT_SHIFT). Live
# g6lc64_ai grants dense INT8 only (AiIslandDtypeMask = 16'h0001), so every
# non-zero numfmt above must be refused.
#
# Soft-pass if the window is an error slave (non-AI package). HTIF fail codes
# odd only. Not OpenSBI. Not cookie.

  .equ AI_BASE,    0x40000000
  .equ AI_CAP_VER, 0x00
  .equ AI_CTL,     0x100
  .equ AI_DOORBELL,0x108
  .equ AI_DONE,    0x10C
  .equ AI_TICKET,  0x110
  .equ AI_DSTATUS, 0x114
  .equ AI_REG0,    0x120
  .equ AI_DESC,    0x140

  # g6lc_ai_desc_pkg
  .equ ST_OK,      0
  .equ ST_BAD_FMT, 8

  # config_pkg::AI_FMT_*, placed at flags[22:20]
  .equ FMT_SHIFT,  20
  .equ FMT_INT,    0
  .equ FMT_BF16,   6
  .equ FMT_FP32,   7

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

  # Cap version must be 1 (or bus error -> trap_vec soft-pass)
  lw   t0, AI_CAP_VER(s0)
  slli t0, t0, 48
  srli t0, t0, 48
  li   t1, 1
  bne  t0, t1, fail_nocap

  li   t0, 1
  sw   t0, AI_CTL(s0)

  # Region q0: [0x80010000, 0x80014000) RW
  li   t0, 0x80010000
  sw   t0, AI_REG0+0x0(s0)
  sw   zero, AI_REG0+0x4(s0)
  li   t0, 0x80014000
  sw   t0, AI_REG0+0x8(s0)
  sw   zero, AI_REG0+0xC(s0)
  li   t0, 0x3
  sw   t0, AI_REG0+0x10(s0)

  # Descriptor body, valid in every field except flags.numfmt below.
  # OP_LAYOUT (spine; no GEMM datapath needed to reach PARSE).
  li   t0, (3 << 16) | 2
  sw   t0, AI_DESC+0x0(s0)
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
  li   t0, 0x80013000
  sw   t0, AI_DESC+0x38(s0)
  sw   zero, AI_DESC+0x3C(s0)

  # ---- 1. granted format (INT) must be accepted -----------------------------
  li   a1, (FMT_INT << FMT_SHIFT)
  li   a2, 1
  li   a3, ST_OK
  li   a4, 3
  jal  ra, submit_expect

  # ---- 2. ungranted BF16 must be refused ------------------------------------
  li   a1, (FMT_BF16 << FMT_SHIFT)
  li   a2, 2
  li   a3, ST_BAD_FMT
  li   a4, 5
  jal  ra, submit_expect

  # ---- 3. ungranted FP32 must also be refused -------------------------------
  li   a1, (FMT_FP32 << FMT_SHIFT)
  li   a2, 3
  li   a3, ST_BAD_FMT
  li   a4, 7
  jal  ra, submit_expect

  # ---- 4. refusal is not sticky ---------------------------------------------
  li   a1, (FMT_INT << FMT_SHIFT)
  li   a2, 4
  li   a3, ST_OK
  li   a4, 9
  jal  ra, submit_expect

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j 1b

# submit_expect(a1=flags, a2=ticket, a3=expected status, a4=fail code)
# Clobbers t0-t2, a5. Returns via ra.
submit_expect:
  mv   a5, ra
  sw   a1, AI_DESC+0x4(s0)     # flags (carries numfmt)
  # Drain the descriptor stores before the doorbell: a same-address load-back
  # can store-buffer-forward and report the new data before the AXI write has
  # reached the island latch. Load a *different* register (ai_dual_enq_poll.S).
  lw   zero, AI_CTL(s0)
  fence
  slli t0, a2, 8               # doorbell: [31:8]=ticket, [7:0]=qid 0
  sw   t0, AI_DOORBELL(s0)
  li   t2, 200
2:
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  bnez t0, 3f
  addi t2, t2, -1
  bnez t2, 2b
  mv   a0, a4                  # timeout: no completion at all
  j    fail_store
3:
  lw   t0, AI_TICKET(s0)
  bne  t0, a2, 4f
  lw   t0, AI_DSTATUS(s0)
  slli t0, t0, 48
  srli t0, t0, 48
  bne  t0, a3, 4f
  li   t0, 1                   # clear sticky done
  sw   t0, AI_DONE(s0)
  mv   ra, a5
  ret
4:
  mv   a0, a4
  j    fail_store

fail_nocap:
  li   a0, 11
  j    fail_store
fail_store:
  la   t0, tohost
  sw   a0, 0(t0)
5: j 5b

trap_vec:
  # NOT a soft-pass, deliberately. Siblings such as ai_island_mmio_smoke.S
  # answer a0=1 here so they pass on packages without the island -- but that
  # makes a trap indistinguishable from success, and this test's whole claim is
  # "the refusal path executed". A bus error on the first MMIO access would
  # otherwise report SUCCESS having exercised nothing.
  #
  # This test is only ever run on AI flavours, where the island is present, so
  # a trap is a real failure. Package gating belongs to the runner, not to a
  # code that lies.
  li   a0, 13
  la   t0, tohost
  sw   a0, 0(t0)
6: j 6b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
