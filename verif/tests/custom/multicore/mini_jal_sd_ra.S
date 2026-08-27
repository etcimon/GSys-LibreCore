# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S4: predicted jal then callee sd ra before jal link WBs.
# Commit TRACE: 12a00 then 13312 — check_node epi skipped. G1o (A-only)
# stalled STORE rs2==ra on still_issued jal; B uses general RAW.
# Warm BTB: 64 calls. tohost 1 PASS; 3 P0; 5 P1; 7 P2; 9 P3 straddle jal; 25 trap.
#

  .option rvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, hart1
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  # P0: 64x jal / sd ra,8(sp) / ret
  li   s10, 0
  li   s11, 64
p0:
  jal  cal0
  addi s10, s10, 1
  addi s11, s11, -1
  bnez s11, p0
  li   t0, 64
  bne  s10, t0, fail3

  # P1: jal at +6 of 16B line (stock 12ac6), 32B callee
  li   s10, 0
  li   s11, 64
p1:
  .align 4
  c.nop
  c.nop
  c.nop
  jal  cal1
  addi s10, s10, 1
  addi s11, s11, -1
  bnez s11, p1
  li   t0, 64
  bne  s10, t0, fail5

  # P2: c.sdsp ra
  li   s10, 0
  li   s11, 64
p2:
  jal  cal2
  addi s10, s10, 1
  addi s11, s11, -1
  bnez s11, p2
  li   t0, 64
  bne  s10, t0, fail7

  # P3: jal straddles 16B line (starts +14). leftover drop -> no link write.
  li   s10, 0
  li   s11, 64
p3:
  .align 4
  c.nop
  c.nop
  c.nop
  c.nop
  c.nop
  c.nop
  c.nop
  jal  cal0
  addi s10, s10, 1
  addi s11, s11, -1
  bnez s11, p3
  li   t0, 64
  bne  s10, t0, fail9

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

cal0:
  addi sp, sp, -16
  sd   ra, 8(sp)
  ld   ra, 8(sp)
  addi sp, sp, 16
  ret

cal1:
  addi sp, sp, -32
  sd   s0, 16(sp)
  sd   ra, 24(sp)
  addi s0, sp, 32
  ld   ra, 24(sp)
  ld   s0, 16(sp)
  addi sp, sp, 32
  ret

# Stock next_tag: 5 sds then sd ra,56(sp) (1297e).
cal2:
  addi sp, sp, -64
  sd   s0, 48(sp)
  sd   s3, 24(sp)
  sd   s4, 16(sp)
  sd   s5, 8(sp)
  sd   ra, 56(sp)
  sd   s2, 32(sp)
  ld   s2, 32(sp)
  ld   ra, 56(sp)
  ld   s0, 48(sp)
  ld   s3, 24(sp)
  ld   s4, 16(sp)
  ld   s5, 8(sp)
  addi sp, sp, 64
  ret

hart1:
  wfi
  j    hart1

fail3:
  li   a0, 3
  j    fail_exit
fail5:
  li   a0, 5
  j    fail_exit
fail7:
  li   a0, 7
  j    fail_exit
fail9:
  li   a0, 9
fail_exit:
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

trap:
  li   a0, 25
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
