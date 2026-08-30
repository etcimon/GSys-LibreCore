# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S1: same-hart store then delayed load of one PA after L1 fill.
# Alias PA 0x80046ec8 (mini 2nd ld s3). Store lenp, spin ~namelen gap,
# load. Isolates WT write-around / dropped wr_ack without namelen.bin.
#
# tohost (odd => TB >>1): 1 PASS; 3 delayed load saw stale; 13 fill; 25 trap

  .option rvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, hart1
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  li   s0, 0x80046ec8
  sd   zero, 0(s0)
  ld   t1, 0(s0)
  bnez t1, fail13

  # Two stores to the same PA: 1st ra (0x12b2a) then lenp, like the alias.
  li   s2, 0x80012b2a
  sd   s2, 0(s0)
  ld   t1, 0(s0)
  li   s1, 0x80046f2c
  sd   s1, 0(s0)

  li   t0, 400
1:
  addi t0, t0, -1
  bnez t0, 1b

  ld   t2, 0(s0)
  bne  t2, s1, fail3

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

hart1:
  wfi
  j    hart1

fail3:
  li   a0, 3
  j    fail_exit
fail13:
  li   a0, 13
  j    fail_exit
fail_exit:
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

trap:
  li   a0, 25
  j    fail_exit

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
