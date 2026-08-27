# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S4: stock 12ac0 line — 8B window splits jal@+6. Train bnez TAKEN
# (a1&3!=0) then NT (a1=0). If BHT taken-kill drops jal leftover,
# cal sd ra saves outer link and ret skips addi s10.
# tohost 1 PASS; 3 skip after train; 25 trap.
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
  addi s0, sp, 0

  # Train BHT TAKEN on the 12ac0 bnez.
  li   s11, 48
train:
  li   a1, 1
  jal  chk
  addi s11, s11, -1
  bnez s11, train

  li   s9, 0
  li   s10, 0
  li   s11, 16
live:
  li   a1, 0
  jal  chk
  addi s10, s10, 1
  addi s11, s11, -1
  bnez s11, live
  li   t0, 16
  bne  s10, t0, fail3
  bne  s9, t0, fail5

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

# Same packing as fdt_check_node_offset_ 12ac0-12ada.
chk:
  addi sp, sp, -32
  sd   s0, 16(sp)
  sd   ra, 24(sp)
  addi s0, sp, 32
  sw   zero, -20(s0)
  andi a5, a1, 3
  .align 4
  bnez a5, chk_fail
  addi a2, s0, -20
  jal  cal
  c.li a5, 1
  bne  a0, a5, chk_fail
chk_epi:
  lw   a0, -20(s0)
  ld   ra, 24(sp)
  ld   s0, 16(sp)
  addi sp, sp, 32
  ret
  c.li a0, -4
  j    chk_epi
chk_fail:
  c.li a0, 1
  ld   ra, 24(sp)
  ld   s0, 16(sp)
  addi sp, sp, 32
  ret

cal:
  addi sp, sp, -16
  sd   ra, 8(sp)
  addi s9, s9, 1
  li   a0, 1
  ld   ra, 8(sp)
  addi sp, sp, 16
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
