# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# CONTRACT.md Phase 1 — generic sibling c.jalr class (not OpenSBI VA 7ba).
#
# Same 16-byte line: aligned-00 RVI ld rd, then sibling 8-byte half
# pc[2:1]==01 is architectural c.jalr rd. Optional leftover jal x0 at
# pc[2:1]==11 on a taken-skip path (766-shape) so present can mash.
#
# tohost=1 pass (printed 0). Fail N is ((N<<1)|1) → printed N.
#   1  aligned c.jalr helper did not return 1
#   2  P1 sib: c.beqz taken (a5=0 / ld missed)
#   3  P1 sib: c.jalr did not jump (fallthrough — presented as Branch)
#   8  P1 sib: helper returned != 1
#   4  P2 leftover jal x0 executed (hang path; leftover completed as Jump)
#   5  P2 sib: c.jalr did not jump after leftover-skip
#   6  P2 sib: helper returned != 1
#   7  trap
#   9  P3 leftover jal x0 executed (760/766: c.jalr then leftover hang)
#  10  P3 sib: c.beqz taken (a5=0 / ld missed)
#  12  P3 sib: c.jalr did not jump (7ba presented as Branch)
#  11  P3 sib: helper returned != 1
#  13  P4 leftover jal x0 executed (next 16-byte I$ line after c.bnez@00)
#  14  P4 sib: c.beqz taken (a5=0 / ld missed)
#  16  P4 sib: c.jalr did not jump
#  15  P4 sib: helper returned != 1
# P0–P2 soaked slfix `7e280d82`. P3 752/766 PASS @518. P4: c.bnez@00
# skips leftover jal at +14 (same 16-byte I$ line, second 8B; skip_arm
# is first-8B hw11 only) PASS @597. Isolated shapes do not keep leftover
# FSM to sib 01. OpenSBI hangj 766 is leftover-PC replay 3 cy after npc
# 7ba (G1gk expire). c.jalr skip-arm HOLD-FAIL. Hart1 parks on mhartid.
# Isolated P4 / lottery / FDT stay regression.

  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, park
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0
  li   a0, 0
  la   s4, plat

  # P0: aligned c.jalr sanity (lottery already covers; keep as fail 1).
  # Check a0 only (lottery). A t1 flag after ret was fail 1 @380 on slfix
  # (t1 not callee-saved; RAW vs helper). Did-not-jump leaves a0=0.
  la   a5, helper
  li   a0, 0
  c.jalr a5
  li   t0, 1
  bne  a0, t0, fail1

  # P1: 16-byte line ld@00 + c.mv + c.ld + c.beqz@08 + c.jalr@0A.
  li   a0, 0
  .align 4
p1_sib:
  ld    a5, 96(s4)
  c.mv  s1, a0
  c.ld  a5, 8(a5)
  c.beqz a5, fail2
  c.jalr a5
  beqz a0, fail3
p1_ok:
  li   t0, 1
  bne  a0, t0, fail8

  # P2: taken c.bnez skips leftover jal x0 at [2:1]==11 (766-shape),
  # then the same sib packet. Leftover may still be pending at npc 01.
  # c.bnez rs1' only (x8–x15); t0=x5 is not legal.
  li   a2, 1
  li   a0, 0
  .align 4
p2_pred:
  c.bnez a2, p2_sib
  c.nop
  c.nop
  .option norvc
  jal   x0, fail4
  .option rvc
  .align 4
p2_sib:
  ld    a5, 96(s4)
  c.mv  s1, a0
  c.ld  a5, 8(a5)
  c.beqz a5, fail5
  c.jalr a5
  beqz a0, fail5
p2_ok:
  li   t0, 1
  bne  a0, t0, fail6

  # P3: OpenSBI 752/766/7ba. 16-byte I$ line like 750 (IcacheLineWidth
  # 128): c.jalr @00, RVI bnez @02 taken to 7a2. Leftover jal x0 is on
  # the *next* 16-byte line at +22 ([2:1]==11), 760-shape c.jalr+beqz+
  # hang, in the bnez skip range (752 < 766 < 7a2). Sequential next
  # I$ line may capture leftover before bnez resolves. Then 7a2 I|I
  # and the 7b0 sib packet. Not c.jalr skip-arm.
  la   a5, far_helper
  li   a0, 0
  .align 4
p3_750:
  c.jalr a5
  .option norvc
  bnez  a0, p3_7a2
  nop
  nop
  .option rvc
  c.nop
  c.jalr a5
  .option norvc
  beqz  a0, p3_7a2
  jal   x0, fail9
  .option rvc
  .skip 32
  .align 3
p3_7a2:
  li    a1, 1
  .option norvc
  auipc a0, 0
  addi  a0, a0, 0
  csrr  a0, mhartid
  .option rvc
  li    a0, 0
  .align 4
p3_sib:
  ld    a5, 96(s4)
  c.mv  s1, a0
  c.ld  a5, 8(a5)
  c.beqz a5, fail10
  c.jalr a5
  beqz  a0, fail12
p3_ok:
  li   t0, 1
  bne  a0, t0, fail11

  # P4: skip_arm hole. Taken c.bnez at [2:1]==00 over leftover jal x0
  # at +14 — same 16-byte I$ line, *second* 8B ([2:1]==11). skip_arm
  # only sees first-8B hw11. P2 jal is +6 (same 8B, skip_arm fires).
  # Then 7a2 I|I + 7b0 sib. Not c.jalr skip-arm.
  li   a2, 1
  li   a0, 0
  .align 4
p4_pred:
  c.bnez a2, p4_7a2
  c.nop
  c.nop
  c.nop
  c.nop
  .option norvc
  nop
  jal   x0, fail13
  .option rvc
  .align 3
p4_7a2:
  li    a1, 1
  .option norvc
  auipc a0, 0
  addi  a0, a0, 0
  csrr  a0, mhartid
  .option rvc
  li    a0, 0
  .align 4
p4_sib:
  ld    a5, 96(s4)
  c.mv  s1, a0
  c.ld  a5, 8(a5)
  c.beqz a5, fail14
  c.jalr a5
  beqz  a0, fail16
p4_ok:
  li   t0, 1
  bne  a0, t0, fail15

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

fail1:
  li   a0, 3
  j    fail
fail2:
  li   a0, 5
  j    fail
fail3:
  li   a0, 7
  j    fail
fail4:
  li   a0, 9
  j    fail
fail5:
  li   a0, 11
  j    fail
fail6:
  li   a0, 13
  j    fail
fail8:
  li   a0, 17
  j    fail
fail9:
  li   a0, 19
  j    fail
fail10:
  li   a0, 21
  j    fail
fail11:
  li   a0, 23
  j    fail
fail12:
  li   a0, 25
  j    fail
fail13:
  li   a0, 27
  j    fail
fail14:
  li   a0, 29
  j    fail
fail15:
  li   a0, 31
  j    fail
fail16:
  li   a0, 33
  j    fail
fail:
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

helper:
  li   a0, 1
  ret

  # OpenSBI 750→71e4 distance (~0x6a94). Near helper lets JumpR
  # resolve before the next 16-byte I$ (760/766) issues.
  .skip 0x6a00
far_helper:
  li   a0, 1
  ret

park:
  wfi
  j    park

trap:
  li   a0, 15
  j    fail

  .section .data
  .align 3
plat:
  .zero 96
  .dword ops
ops:
  .dword 0
  .dword helper

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
