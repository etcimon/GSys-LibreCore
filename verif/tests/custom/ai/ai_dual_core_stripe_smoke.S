# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S3 NrCores=2 on the striped DRAM slave (g6lc64_ai). Both harts leave
# bootrom (all-hart jr DRAMBase). Hart 0 writes stripe 0, hart 1 writes
# stripe 1 (addr[6] = DramChanShift default), then hart 0 checks both
# cookies. Then S5 occupancy: CAP 0x70/0x74 (ch0/ch1 write beats) both
# nonzero. Requires CAP 0x38 channels>=2 and shift=6 (ai-d2/d4/d8).
# Not OpenSBI. Not cookie. Not 400 GB/s. Not I2.
# Fail: 3 general, 5 CAP channels/shift, 7 hart1 timeout, 9 occupancy.

  .equ AI_BASE,     0x40000000
  .equ CAP_CHANS,   0x38
  .equ CAP_CH0_W,   0x70
  .equ CAP_CH1_W,   0x74
  .equ LINE0,       0x80090000
  .equ LINE1,       0x80090040
  .equ FLAG,        0x80090080
  .equ COOKIE0,     0x51B10C00
  .equ COOKIE1,     0x51B10C01

  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap_vec
  csrw mtvec, t1
  bnez t0, hart1

  li   s0, AI_BASE
  lw   t0, CAP_CHANS(s0)
  li   t2, 0xffff
  and  t1, t0, t2
  li   t2, 2
  bltu t1, t2, fail_ch
  srli t1, t0, 16
  andi t1, t1, 0xff
  li   t2, 6
  bne  t1, t2, fail_ch

  li   t0, LINE0
  li   t1, COOKIE0
  sd   t1, 0(t0)
  fence rw, rw

  li   t2, 2000000
  li   t0, FLAG
1:
  ld   t1, 0(t0)
  bnez t1, 2f
  addi t2, t2, -1
  bnez t2, 1b
  j    fail_to
2:
  fence rw, rw
  li   t0, LINE0
  ld   t1, 0(t0)
  li   t2, COOKIE0
  bne  t1, t2, fail
  li   t0, LINE1
  ld   t1, 0(t0)
  li   t2, COOKIE1
  bne  t1, t2, fail

  fence rw, rw
  lw   t0, CAP_CH0_W(s0)
  beqz t0, fail_occ
  lw   t0, CAP_CH1_W(s0)
  beqz t0, fail_occ

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
3: j 3b

hart1:
  li   t0, LINE1
  li   t1, COOKIE1
  sd   t1, 0(t0)
  fence rw, rw
  li   t0, FLAG
  li   t1, 1
  sd   t1, 0(t0)
4:
  wfi
  j    4b

fail_ch:
  li   a0, 5
  j    fail_store
fail_to:
  li   a0, 7
  j    fail_store
fail_occ:
  li   a0, 9
  j    fail_store
fail:
  li   a0, 3
fail_store:
  la   t0, tohost
  sw   a0, 0(t0)
5: j 5b

trap_vec:
  li   a0, 3
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
