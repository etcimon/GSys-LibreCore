# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Single-hart bisect for mc_l3_evict_inclusion: hart 0 alone performs the same
# set-conflict churn (EVICT_LINES lines at EVICT_STRIDE = one L2/L3 way apart,
# each read then written) and reports. No peer, no shared line: a hang here is
# the uncore's set-conflict path by itself, not an inclusion interaction.
#
# tohost: 1 pass (ORACLE_NEGATIVE 3), 9 the read-back sum is wrong,
# trap 32+((mcause<<1)|1). Other harts park.

#ifndef EVICT_LINES
#define EVICT_LINES 48
#endif
#ifndef EVICT_STRIDE
#define EVICT_STRIDE 0x40000
#endif
  .equ SCAN_BASE, 0x80500000

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap_vec
  csrw mtvec, t1
  bnez t0, park

  li   s2, SCAN_BASE
  li   s3, EVICT_LINES
  li   s4, EVICT_STRIDE
  li   s5, 0                    # sum of the values written
  li   s6, 1
1:
  ld   t1, 0(s2)                # first touch: fill
  add  t1, zero, s6             # write a known value (iteration number)
  sd   t1, 0(s2)
  add  s5, s5, s6
  addi s6, s6, 1
  add  s2, s2, s4
  addi s3, s3, -1
  bnez s3, 1b
  fence rw, rw
  # read everything back (second pass: the lines were evicted in between)
  li   s2, SCAN_BASE
  li   s3, EVICT_LINES
  li   s7, 0
2:
  ld   t1, 0(s2)
  add  s7, s7, t1
  add  s2, s2, s4
  addi s3, s3, -1
  bnez s3, 2b
  bne  s5, s7, fail_sum
#ifdef ORACLE_NEGATIVE
  li   a0, 3
#else
  li   a0, 1
#endif
  j    tohost_store
fail_sum:
  li   a0, 9
tohost_store:
  la   t0, tohost
  sw   a0, 0(t0)
3: j 3b

park:
  wfi
  j    park

trap_vec:
  csrr a0, mcause
  andi a0, a0, 0xff
  slli a0, a0, 1
  ori  a0, a0, 1
  addi a0, a0, 32
  la   t0, tohost
  sw   a0, 0(t0)
4: j 4b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
