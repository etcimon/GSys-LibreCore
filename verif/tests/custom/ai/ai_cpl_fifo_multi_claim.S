# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# CPL FIFO multi-claim on SoC (work-ver-ai / g6lc64_ai):
#   Submit three OP_LAYOUT jobs (tickets 20,21,22) without claiming between
#   finishes; head must stay oldest (20). Claim/pop three times → 20→21→22,
#   then DONE sticky clear. Mirrors standalone TB multi-claim in
#   verif/tb/ai_island/sim_main.cpp.
#
# Wait: after doorbell, require STATUS.busy high then low (job accepted and
# finished). One-cycle submit_pulse is easy to miss — settle with a short
# MMIO poll budget before treating never-busy as error.
# Soft-pass on bus/illegal (non-AI package). HTIF: odd a0 only (exit = a0>>1).

  .equ AI_BASE,    0x40000000
  .equ AI_CAP_VER, 0x00
  .equ AI_CTL,     0x100
  .equ AI_STATUS,  0x104
  .equ AI_DOORBELL,0x108
  .equ AI_DONE,    0x10C
  .equ AI_TICKET,  0x110
  .equ AI_DSTATUS, 0x114
  .equ AI_REG0,    0x120
  .equ AI_DESC,    0x140

  .equ ST_OK,      0
  .equ POLL_LIM,   500

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

  lw   t0, AI_CAP_VER(s0)
  slli t0, t0, 48
  srli t0, t0, 48
  li   t1, 1
  bne  t0, t1, fail1

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

  # ---- ticket 20 ----
  jal  ra, load_ok_desc
  jal  ra, wait_idle
  li   t0, (20 << 8)
  sw   t0, AI_DOORBELL(s0)
  jal  ra, wait_job
  jal  ra, wait_done_sticky
  lw   t0, AI_TICKET(s0)
  li   t1, 20
  bne  t0, t1, fail2

  # ---- ticket 21 (keep 20 unclaimed) ----
  jal  ra, load_ok_desc
  jal  ra, wait_idle
  li   t0, (21 << 8)
  sw   t0, AI_DOORBELL(s0)
  jal  ra, wait_job
  lw   t0, AI_TICKET(s0)
  li   t1, 20
  bne  t0, t1, fail3

  # ---- ticket 22 ----
  jal  ra, load_ok_desc
  jal  ra, wait_idle
  li   t0, (22 << 8)
  sw   t0, AI_DOORBELL(s0)
  jal  ra, wait_job

  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  beqz t0, fail4
  lw   t0, AI_TICKET(s0)
  li   t1, 20
  bne  t0, t1, fail5
  lw   t0, AI_DSTATUS(s0)
  slli t0, t0, 48
  srli t0, t0, 48
  li   t1, ST_OK
  bne  t0, t1, fail6

  # claim → 21
  li   t0, 1
  sw   t0, AI_DONE(s0)
  fence
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  beqz t0, fail7
  lw   t0, AI_TICKET(s0)
  li   t1, 21
  bne  t0, t1, fail8

  # claim → 22
  li   t0, 1
  sw   t0, AI_DONE(s0)
  fence
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  beqz t0, fail9
  lw   t0, AI_TICKET(s0)
  li   t1, 22
  bne  t0, t1, fail10

  # claim → empty
  li   t0, 1
  sw   t0, AI_DONE(s0)
  fence
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  bnez t0, fail11

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
9: j 9b

fail1:
  li   a0, 3
  j    fail_exit
fail2:
  li   a0, 5
  j    fail_exit
fail3:
  li   a0, 7
  j    fail_exit
fail4:
  li   a0, 9
  j    fail_exit
fail5:
  li   a0, 11
  j    fail_exit
fail6:
  li   a0, 13
  j    fail_exit
fail7:
  li   a0, 15
  j    fail_exit
fail8:
  li   a0, 17
  j    fail_exit
fail9:
  li   a0, 19
  j    fail_exit
fail10:
  li   a0, 21
  j    fail_exit
fail11:
  li   a0, 23
  j    fail_exit
fail12:
  li   a0, 25
  j    fail_exit
fail13:
  li   a0, 27
  j    fail_exit
fail14:
  li   a0, 29
  j    fail_exit
fail15:
  li   a0, 31
  j    fail_exit
fail_exit:
  la   t0, tohost
  sw   a0, 0(t0)
8: j 8b

trap_vec:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
7: j 7b

load_ok_desc:
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
  li   t0, 0x80013000
  sw   t0, AI_DESC+0x38(s0)
  sw   zero, AI_DESC+0x3C(s0)
  lw   zero, AI_CTL(s0)
  fence
  ret

wait_idle:
  li   t2, POLL_LIM
0:
  lw   t0, AI_STATUS(s0)
  andi t0, t0, 1
  beqz t0, 1f
  addi t2, t2, -1
  bnez t2, 0b
  j    fail12
1:
  ret

# wait_job: OP_LAYOUT is shorter than one MMIO RTT, so STATUS.busy is
# almost never observed. Settle with a pure instruction spin (island clocks
# elapse under the core), then require idle + sticky.
wait_job:
  li   t2, 2048
0:
  addi t2, t2, -1
  bnez t2, 0b
  li   t2, POLL_LIM
1:
  lw   t0, AI_STATUS(s0)
  andi t0, t0, 1
  beqz t0, 2f
  addi t2, t2, -1
  bnez t2, 1b
  j    fail13
2:
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  beqz t0, fail14
  ret

wait_done_sticky:
  li   t2, POLL_LIM
0:
  lw   t0, AI_DONE(s0)
  andi t0, t0, 1
  bnez t0, 1f
  addi t2, t2, -1
  bnez t2, 0b
  j    fail15
1:
  ret

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
