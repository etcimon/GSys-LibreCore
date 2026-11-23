# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Same-hart AMO -> younger-load ordering with the target line L1-resident.
# RVWMO (and plain program order for one address) requires a load that
# follows an AMO to the same address to observe the AMO's write. Each round
# installs the line in the WT L1 (store, then a load that miss-allocates),
# puts a divide ahead of the AMO so the AMO (head-only) waits at the commit
# head while the younger load's address is already ready, then checks the
# younger load. Covers the Zacas AMOCAS.D local load/compare/store path and
# the ATOP path (AMOSWAP.D, AMOADD.D).
#
# Exit (crt convention, tohost = (code<<1)|1): 0 pass; 2 setup readback;
# 3 amocas old value; 4 load after amocas saw a stale value; 5 amoswap old
# value; 6 load after amoswap stale; 7 amoadd old value; 8 load after amoadd
# stale; 9 unexpected trap.

#ifndef ROUNDS
#define ROUNDS 32
#endif

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, park
  li   sp, 0x80008000
  la   t0, trap_vec
  csrw mtvec, t0

  li   s0, ROUNDS
  li   s1, 0x80009000          # target line (own 64 B line, away from stack)
  li   s2, 0                   # round counter
  li   t5, 1000
  li   t6, 7
round:
  addi s2, s2, 1
  # ---- AMOCAS.D -----------------------------------------------------------
  slli t0, s2, 32
  or   t0, t0, s2              # old = (i << 32) | i
  sd   t0, 0(s1)
  ld   t1, 0(s1)               # miss-allocate: line now L1-resident
  li   a0, 2
  bne  t1, t0, fail
  fence rw, rw
  mv   a0, t0                  # expected
  not  a1, t0                  # new
  mv   a2, s1
  div  t4, t5, t6              # hold the head-only AMO behind a divide
  .word 0x28B6352F             # amocas.d a0, a1, (a2)
  ld   t2, 0(s1)               # younger load: must see a1
  mv   t3, a0
  li   a0, 3
  bne  t3, t0, fail
  li   a0, 4
  bne  t2, a1, fail
  # ---- AMOSWAP.D ----------------------------------------------------------
  ld   t1, 0(s1)               # re-install (the CAS dropped the L1 line)
  fence rw, rw
  li   t3, 0x5555aaaa5555aaaa
  xor  t3, t3, a1              # swap-in value
  div  t4, t5, t6
  amoswap.d a3, t3, (s1)
  ld   t2, 0(s1)               # younger load: must see t3
  li   a0, 5
  bne  a3, a1, fail
  li   a0, 6
  bne  t2, t3, fail
  # ---- AMOADD.D -----------------------------------------------------------
  ld   t1, 0(s1)
  fence rw, rw
  div  t4, t5, t6
  amoadd.d a4, s2, (s1)
  ld   t2, 0(s1)               # younger load: must see t3 + i
  add  t1, t3, s2
  li   a0, 7
  bne  a4, t3, fail
  li   a0, 8
  bne  t2, t1, fail
  addi s0, s0, -1
  bnez s0, round

  li   a0, 0
  j    exit
fail:
  j    exit

exit:
  slli a0, a0, 1
  addi a0, a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
9:  j    9b

trap_vec:
  li   a0, 9
  j    exit

park:
7:  wfi
  j    7b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
