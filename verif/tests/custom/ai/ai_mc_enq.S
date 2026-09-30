# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Multi-core ai.enq through the cluster's sideband arbiter (g6lc_ai_enq_arb) with
# the island allocating the ticket stream (SbTicketAlloc).
#
#   hart 0 programs the island (region, MMIO-latched OP_LAYOUT descriptor) and
#          raises go_flag;
#   hart 1 (the SECOND core) waits for go_flag, sets its own aicfg, issues ai.enq
#          and polls until OK, then publishes {ticket, poll status} in done_flag;
#   hart 0 checks hart 1's ticket is 0 (first kick of the island's stream), claims
#          the completion, issues its own ai.enq and must receive ticket 1 -- the
#          island's stream continued across cores (a per-core counter would have
#          said 0 again) -- and polls it to OK.
#
# On a single-core package hart 1 never exists: hart 0 then does both kicks
# itself (tickets 0 and 1), so the ELF is a valid single-producer check too.
# HTIF fail codes odd only.

  .equ AI_BASE,   0x40000000
  .equ AI_CTL,    0x100
  .equ AI_DONE,   0x10C
  .equ AI_TICKET, 0x110
  .equ AI_REG0,   0x120
  .equ AI_DESC,   0x140

  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  beqz t0, hart0
  li   t1, 1
  beq  t0, t1, hart1
2: wfi
  j    2b

# ------------------------------------------------------------------ hart 1
hart1:
  li   sp, 0x80007000
  la   t0, trap_vec
  csrw mtvec, t0
  la   s2, go_flag
1:
  fence
  ld   t0, 0(s2)
  beqz t0, 1b
  # aicfg: queue enable, qid 0 (same encoding the single-core tests use)
  li   t0, 0x61
  csrw 0x5C1, t0
  fence
  li   a1, 0
  .word 0x0005D55B            # ai.enq  a0 = ticket
  mv   s1, a0
  li   t2, 4000
3:
  mv   a1, s1
  .word 0x0205D55B            # ai.poll a0 = 0 pending / 1 ok / 2 err
  bnez a0, 4f
  addi t2, t2, -1
  bnez t2, 3b
  li   a0, 3                  # never completed
4:
  # publish {status[63:32], ticket[31:0]}
  slli t0, a0, 32
  or   t0, t0, s1
  la   t1, done_flag
  sd   t0, 0(t1)
  fence
5: wfi
  j    5b

# ------------------------------------------------------------------ hart 0
hart0:
  li   sp, 0x80008000
  la   t0, trap_vec
  csrw mtvec, t0
  andi sp, sp, -16
  li   t0, 0x61
  csrw 0x5C1, t0
  li   s0, AI_BASE
  li   t0, 1
  sw   t0, AI_CTL(s0)
  li   t0, 0x80010000
  sw   t0, AI_REG0+0x0(s0)
  sw   zero, AI_REG0+0x4(s0)
  li   t0, 0x80014000
  sw   t0, AI_REG0+0x8(s0)
  sw   zero, AI_REG0+0xC(s0)
  li   t0, 0x3
  sw   t0, AI_REG0+0x10(s0)
  li   t0, (3 << 16) | 2      /* OP_LAYOUT (spine; no GEMM) */
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
  li   t0, 0x80013000
  sw   t0, AI_DESC+0x38(s0)
  sw   zero, AI_DESC+0x3C(s0)
  lw   zero, AI_CTL(s0)
  fence

  # How many harts? (mhartid of the last hart is not visible; probe the second
  # core by giving it a bounded time to answer.)
  la   s2, go_flag
  li   t0, 1
  sd   t0, 0(s2)
  fence
  la   s3, done_flag
  li   t2, 20000
1:
  fence
  ld   t0, 0(s3)
  bnez t0, second_core_answered
  addi t2, t2, -1
  bnez t2, 1b
  # No second core: single-producer form -- kick 0 ourselves.
  li   a1, 0
  .word 0x0005D55B
  bnez a0, fail               # first ticket of the stream is 0
  mv   s1, a0
  li   t2, 4000
2:
  mv   a1, s1
  .word 0x0205D55B
  bnez a0, 3f
  addi t2, t2, -1
  bnez t2, 2b
  j    fail
3:
  li   t0, 1
  bne  a0, t0, fail
  j    second_kick

second_core_answered:
  # hart 1 got ticket 0 and POLL_OK
  ld   t0, 0(s3)
  sext.w t1, t0
  bnez t1, fail               # ticket must be 0
  srli t1, t0, 32
  li   t3, 1
  bne  t1, t3, fail           # poll status OK

second_kick:
  # claim hart 1's (or our) completion so the FIFO head advances
  li   t0, 1
  sw   t0, AI_DONE(s0)
  lw   zero, AI_CTL(s0)
  fence
  li   a1, 0
  .word 0x0005D55B            # ai.enq from core 0
  li   t0, 1
  bne  a0, t0, fail           # island stream continued: ticket 1, not 0
  mv   s1, a0
  li   t2, 4000
4:
  mv   a1, s1
  .word 0x0205D55B
  bnez a0, 5f
  addi t2, t2, -1
  bnez t2, 4b
  j    fail
5:
  li   t0, 1
  bne  a0, t0, fail
  # MMIO agrees: the head completion is ticket 1
  lw   t0, AI_TICKET(s0)
  li   t1, 1
  bne  t0, t1, fail

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
6: j 6b

fail:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
7: j 7b

trap_vec:
  li   a0, 5
  la   t0, tohost
  sw   a0, 0(t0)
8: j 8b

  .section .data
  .align 6
go_flag:   .dword 0
  .align 6
done_flag: .dword 0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
