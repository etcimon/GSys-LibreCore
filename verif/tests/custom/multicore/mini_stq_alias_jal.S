# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S1 STQ same-PA without FDT tags. 32B check_node / 64B next_tag nest so
# 1st sd ra,56(sp) aliases 2nd ld s3,24(sp). 1st call does 16 thunk16
# (offset_ptr-shaped 16B frames + lbu); 2nd call does 2. OpenSBI 1st
# BEGIN_NODE is many jal offset_ptr; 2nd PROP is few.
#
# tohost (odd => TB >>1): 1 PASS; 3 s3 clobber; 5 s2 clobber; 7 check_node; 25 trap
# Hart1 must park: smt2 both harts enter _start; shared SP races (200k cap hang).
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
  jal  namelen
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

hart1:
  wfi
  j    hart1

namelen:
  addi sp, sp, -16
  sd   ra, 8(sp)
  li   s2, 0x11111111
  li   s3, 0x22222222
  li   a7, 16
  jal  check_node
  li   t0, 0x11111111
  bne  s2, t0, fail7
  li   t0, 0x22222222
  bne  s3, t0, fail7
  li   a7, 2
  jal  next_tag
  li   t0, 0x11111111
  bne  s2, t0, fail5
  li   t0, 0x22222222
  bne  s3, t0, fail3
  ld   ra, 8(sp)
  addi sp, sp, 16
  ret

check_node:
  addi sp, sp, -32
  sd   s0, 16(sp)
  sd   ra, 24(sp)
  jal  next_tag
  ld   ra, 24(sp)
  ld   s0, 16(sp)
  addi sp, sp, 32
  ret

thunk16:
  addi sp, sp, -16
  sd   s0, 0(sp)
  sd   ra, 8(sp)
  la   t0, dummy
  lbu  t1, 0(t0)
  lbu  t2, 4(t0)
  lbu  t3, 8(t0)
  lbu  t4, 12(t0)
  lbu  t5, 20(t0)
  ld   ra, 8(sp)
  ld   s0, 0(sp)
  addi sp, sp, 16
  ret

next_tag:
  addi sp, sp, -64
  sd   s0, 48(sp)
  sd   s3, 24(sp)
  sd   s4, 16(sp)
  sd   s5, 8(sp)
  sd   ra, 56(sp)
  sd   s2, 32(sp)
  mv   s4, a7
2:
  beqz s4, 3f
  jal  thunk16
  addi s4, s4, -1
  j    2b
3:
  ld   ra, 56(sp)
  ld   s0, 48(sp)
  ld   s3, 24(sp)
  ld   s4, 16(sp)
  ld   s5, 8(sp)
  ld   s2, 32(sp)
  addi sp, sp, 64
  ret

fail3:
  li   a0, 3
  j    fail_exit
fail5:
  li   a0, 5
  j    fail_exit
fail7:
  li   a0, 7
  j    fail_exit
fail_exit:
  la   t0, tohost
  sw   a0, 0(t0)
4: j    4b

trap:
  li   a0, 25
  la   t0, tohost
  sw   a0, 0(t0)
5: j    5b

  .align 3
dummy:
  .byte 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
  .byte 16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
