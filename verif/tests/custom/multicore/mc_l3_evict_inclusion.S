# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# L2/L3 eviction and inclusion under COH_FILTERED (T23, plan item 4).
# The server cluster is L1 (write-through, per core) over a shared inclusive
# L2 (512 KiB, 8-way, 64 B lines: one way = 64 KiB) over a shared inclusive
# L3 (4 MiB, 16-way: one way = 256 KiB). When L2/L3 replace a line that a
# core still holds in L1, g6lc_l3_inclusive_inv must back-invalidate it and
# the snoop filter must forget the sharer consistently -- otherwise a later
# remote write is not snooped to that core and its L1 serves stale data.
#
#   h2 (PEER core): reads LINE (fills its L1 with SEED), sets RDY.
#   h0: scans EVICT_LINES lines at EVICT_STRIDE (same L2 and L3 set as LINE;
#       the default 48 x 256 KiB evicts LINE from a 16-way set under LRU,
#       PLRU or random replacement), each read-then-written so the sets fill
#       with dirty lines; then stores COOKIE to LINE; sets FLAG.
#   h2: spins FLAG (own line), reads LINE: must be COOKIE. A stale SEED means
#       the L1 copy survived the eviction without an invalidation AND the
#       filter had dropped the sharer (the inclusion hole this test is for).
#       h2 then stores COOKIE2 to LINE and sets FLAG2.
#   h0: spins FLAG2, reads LINE: must be COOKIE2 (the reverse direction: h0's
#       own refetched copy must be snooped by h2's write after the churn).
#
# Fail codes (tohost): 5 RDY timeout, 6 FLAG2 timeout, 9 h2 read SEED after
# the remote write (stale L1 after eviction: the defect), 10 h0 read a stale
# LINE after h2's write, 11 setup (h2's first read was not SEED).
# Trap: 32+((mcause<<1)|1). ORACLE_NEGATIVE expects tohost 3.
#
# Needs NrCores >= 2; PEER_HART selects the peer (2 = second core under
# SMT2). Hart mask 0011 for PEER_HART=2. The scan touches
# EVICT_LINES*EVICT_STRIDE = 12 MiB above SCAN_BASE: keep the DRAM window
# >= 32 MiB (the testharness default is).

#ifndef PEER_HART
#define PEER_HART 2
#endif
#ifndef EVICT_LINES
#define EVICT_LINES 48
#endif
#ifndef EVICT_STRIDE
#define EVICT_STRIDE 0x40000
#endif
  .equ CLINT_MSIP, 0x02000000
  .equ LINE,      0x80100000    # set index bits [11:6] = 0 in both L2 and L3
  .equ SCAN_BASE, 0x80500000    # same set as LINE at every 256 KiB stride
  .equ RDY,       0x80100100
  .equ FLAG,      0x80100200
  .equ FLAG2,     0x80100300
  .equ FAIL_H2,   0x80100400    # h2 reports a stale read here (own line)
  .equ SEED,      0x5eed0001
  .equ COOKIE,    0xc00c1e02
  .equ COOKIE2,   0xc00c1e03
  .equ SPIN_TO,   600000

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap_vec
  csrw mtvec, t1
  li   t1, PEER_HART
  beq  t0, t1, peer
  bnez t0, park

  # ---- hart 0 ----
  li   s1, LINE
  li   t1, SEED
  sd   t1, 0(s1)
  li   t0, RDY
  sd   zero, 0(t0)
  li   t0, FLAG
  sd   zero, 0(t0)
  li   t0, FLAG2
  sd   zero, 0(t0)
  li   t0, FAIL_H2
  sd   zero, 0(t0)
  fence rw, rw
#if PEER_HART > 1
  li   t0, CLINT_MSIP
  li   t1, 1
  sw   t1, (4 * PEER_HART)(t0)  # release the peer's core from boot hold
#endif
  li   t0, RDY
  li   t2, SPIN_TO
1:
  ld   t1, 0(t0)
  bnez t1, 2f
  addi t2, t2, -1
  bnez t2, 1b
  j    fail_rdy
2:
  fence rw, rw
  # churn: EVICT_LINES lines in LINE's L2/L3 set, read then written
  li   s2, SCAN_BASE
  li   s3, EVICT_LINES
  li   s4, EVICT_STRIDE
3:
  ld   t1, 0(s2)
  addi t1, t1, 1
  sd   t1, 0(s2)
  add  s2, s2, s4
  addi s3, s3, -1
  bnez s3, 3b
  fence rw, rw
  # remote write to the line the peer cached before the churn
  li   t1, COOKIE
  sd   t1, 0(s1)
  fence rw, rw
  li   t0, FLAG
  li   t1, 1
  sd   t1, 0(t0)
  fence rw, rw
  li   t0, FLAG2
  li   t2, SPIN_TO
4:
  ld   t1, 0(t0)
  bnez t1, 5f
  addi t2, t2, -1
  bnez t2, 4b
  j    fail_flag2
5:
  fence rw, rw
  li   t0, FAIL_H2
  ld   t1, 0(t0)
  bnez t1, fail_stale_peer
  ld   t0, 0(s1)
  li   t1, COOKIE2
  bne  t0, t1, fail_stale_h0
#ifdef ORACLE_NEGATIVE
  li   a0, 3
#else
  li   a0, 1
#endif
  j    tohost_store

  # ---- peer core ----
peer:
  li   s1, LINE
#ifdef PEER_NO_READ
  # bisect arm: the peer never caches LINE (its L1 holds nothing of the set)
#else
  ld   t0, 0(s1)                # fill my L1 with SEED
  li   t1, SEED
  bne  t0, t1, fail_setup
#endif
  fence rw, rw
  li   t0, RDY
  li   t1, 1
  sd   t1, 0(t0)
  fence rw, rw
  li   t0, FLAG
  li   t2, SPIN_TO
6:
  ld   t1, 0(t0)
  bnez t1, 7f
  addi t2, t2, -1
  bnez t2, 6b
  j    park
7:
  fence rw, rw
  ld   t0, 0(s1)                # must see the remote write
  li   t1, COOKIE
  beq  t0, t1, 8f
  li   t0, FAIL_H2              # stale: report, hart 0 raises the verdict
  li   t1, 1
  sd   t1, 0(t0)
  fence rw, rw
8:
  li   t1, COOKIE2
  sd   t1, 0(s1)
  fence rw, rw
  li   t0, FLAG2
  li   t1, 1
  sd   t1, 0(t0)
  fence rw, rw
  j    park

fail_rdy:
  li   a0, 5
  j    tohost_store
fail_flag2:
  li   a0, 6
  j    tohost_store
fail_stale_peer:
  li   a0, 9
  j    tohost_store
fail_stale_h0:
  li   a0, 10
  j    tohost_store
fail_setup:
  li   a0, 11
  j    tohost_store
tohost_store:
  la   t0, tohost
  sw   a0, 0(t0)
9: j 9b

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
10: j 10b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
