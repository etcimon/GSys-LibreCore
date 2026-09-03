# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S5 all-N occupancy on the striped DRAM slave (g6lc64_ai). Hart 0 reads N
# from CAP 0x38, writes cookie+i at LINE+i*64 (DramChanShift=6), then checks
# CAP 0x70+4*i write-beats nonzero for every i < N. Hart 1 parks (dual-core
# stripe is a separate ELF). Works on CLASS1 ai-d{1,2,4,8} and class-0
# ai-sc{2,4,8}. Not OpenSBI. Not cookie. Not 400 GB/s. Not I2.
# Fail: 3 general, 5 CAP N/shift, 9 occupancy.

  .equ AI_BASE,     0x40000000
  .equ CAP_CHANS,   0x38
  .equ CAP_CH_W,    0x70
  .equ LINE_BASE,   0x80090000
  .equ COOKIE_BASE, 0x51B10C10

  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap_vec
  csrw mtvec, t1
  bnez t0, nch_park

  li   s0, AI_BASE
  lw   t0, CAP_CHANS(s0)
  li   t2, 0xffff
  and  s1, t0, t2
  beqz s1, fail_ch
  li   t2, 8
  bltu t2, s1, fail_ch
  srli t1, t0, 16
  andi t1, t1, 0xff
  li   t2, 6
  bne  t1, t2, fail_ch

  li   s2, 0
  li   s3, LINE_BASE
1:
  beq  s2, s1, 2f
  li   t1, COOKIE_BASE
  add  t1, t1, s2
  sd   t1, 0(s3)
  addi s3, s3, 64
  addi s2, s2, 1
  j    1b
2:
  fence rw, rw

  li   s2, 0
  li   s3, LINE_BASE
3:
  beq  s2, s1, 4f
  ld   t0, 0(s3)
  li   t1, COOKIE_BASE
  add  t1, t1, s2
  bne  t0, t1, fail
  addi s3, s3, 64
  addi s2, s2, 1
  j    3b
4:
  fence rw, rw
  li   s2, 0
  addi s3, s0, CAP_CH_W
5:
  beq  s2, s1, pass
  lw   t0, 0(s3)
  beqz t0, fail_occ
  addi s3, s3, 4
  addi s2, s2, 1
  j    5b

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
6: j 6b

nch_park:
  wfi
  j    nch_park

fail_ch:
  li   a0, 5
  j    fail_store
fail_occ:
  li   a0, 9
  j    fail_store
fail:
  li   a0, 3
fail_store:
  la   t0, tohost
  sw   a0, 0(t0)
7: j 7b

trap_vec:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
8: j 8b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
