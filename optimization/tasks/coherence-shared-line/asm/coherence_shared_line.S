# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# test id: coherence_shared_line
# work: 2 payload observations (SEED, then COOKIE)
# configs: coherence, l2, cores
#
# Hart 1 publishes a cacheable line. Hart 0 fills on SEED, then must observe
# COOKIE after hart 1 overwrites the line. The only correct way to observe
# COOKIE is for the coherence path to drop hart 0's stale copy.
#
# mark_cycles is hart 0's mcycle from the first line load through the load
# that returns COOKIE. A faster coherence module lowers that count. A stale
# line fails the test instead of reporting a timeout as a throughput win.
# Control words sit on their own 64-byte lines so a spin load cannot refill
# the shared line by accident.

  .equ LINE,  0x80090000
  .equ READY, 0x80090100
  .equ FLAG,  0x80090200
  .equ GO,    0x80090300
  .equ SEED,  0x11
  .equ COOKIE, 0x22
  .equ SPIN,  20000

  .option norvc
  .section .data
  .globl mark_cycles
mark_cycles:
  .dword 0

  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, hart1

  li   s0, LINE
  li   s1, READY
  li   s2, FLAG
  li   s3, GO
  li   t1, 1
  sd   t1, 0(s3)
  li   t2, SPIN
wait_ready:
  ld   t3, 0(s1)
  bnez t3, see_seed
  addi t2, t2, -1
  bnez t2, wait_ready
  li   a0, 5
  ret
see_seed:
  csrr s4, mcycle
  ld   t4, 0(s0)
  li   t5, SEED
  bne  t4, t5, fail_seed
  sd   t1, 0(s2)
  li   t2, SPIN
wait_cookie:
  ld   t3, 0(s2)
  beq  t3, t1, wait_cookie_spin
  j    see_cookie
wait_cookie_spin:
  addi t2, t2, -1
  bnez t2, wait_cookie
  li   a0, 6
  ret
see_cookie:
  ld   t4, 0(s0)
  csrr s5, mcycle
  sub  s5, s5, s4
  la   t6, mark_cycles
  sd   s5, 0(t6)
  li   t5, COOKIE
  bne  t4, t5, fail_stale
  li   a0, 0
  ret
fail_seed:
  li   a0, 11
  ret
fail_stale:
  li   a0, 9
  ret

hart1:
  li   s0, LINE
  li   s1, READY
  li   s2, FLAG
  li   s3, GO
  li   t2, SPIN
wait_go:
  ld   t3, 0(s3)
  bnez t3, publish
  addi t2, t2, -1
  bnez t2, wait_go
  li   a0, 0
  ret
publish:
  li   t4, SEED
  sd   t4, 0(s0)
  li   t1, 1
  sd   t1, 0(s1)
wait_flag:
  ld   t3, 0(s2)
  beq  t3, t1, overwrite
  j    wait_flag
overwrite:
  li   t4, COOKIE
  sd   t4, 0(s0)
  li   t5, 2
  sd   t5, 0(s2)
  li   a0, 0
  ret
