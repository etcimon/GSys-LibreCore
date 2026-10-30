// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// H33 (decisions: wt_dcache_wbuffer W3): store acceptance -> array
// visibility moved to W3 (+1); forwarding visibility unchanged (+0,
// W3 record exported as youngest pending). A store must forward to a
// load at ANY distance, including the new W3 window, with byte-exact
// coalesce semantics.

  .macro FAIL n
    li   a0, 0x100 + \n
    la   t0, tohost
    sw   a0, 0(t0)
    j    done
  .endm

  .section .text.init
  .globl _start
_start:
  la   s0, scratch

  // --- same word, loads at distances 0..4 ---
  li   t0, 0x1122334455667788
  sd   t0, 0(s0)
  ld   t1, 0(s0)            // distance 0
  bne  t0, t1, 1f
  sd   t0, 8(s0)
  nop
  ld   t1, 8(s0)            // distance 1
  bne  t0, t1, 1f
  sd   t0, 16(s0)
  nop
  nop
  ld   t1, 16(s0)           // distance 2 -- W3 window edge
  bne  t0, t1, 1f
  sd   t0, 24(s0)
  nop
  nop
  nop
  ld   t1, 24(s0)           // distance 3
  bne  t0, t1, 1f
  sd   t0, 32(s0)
  nop
  nop
  nop
  nop
  ld   t1, 32(s0)           // distance 4 -- array path
  bne  t0, t1, 1f
  j    2f
1: FAIL 1
2:
  // --- byte overlap: dword store then byte/half loads, and vice versa ---
  li   t0, 0xa5a5c3c3deadbeef
  sd   t0, 40(s0)
  lbu  t1, 40(s0)           // LSB = 0xef
  li   s1, 0xef
  bne  t1, s1, 3f
  lbu  t1, 47(s0)           // MSB = 0xa5
  li   s1, 0xa5
  bne  t1, s1, 3f
  // byte layout (LE): 40:ef 41:be 42:ad 43:de 44:c3 45:c3 46:a5 47:a5
  lhu  t1, 44(s0)           // bytes 44..45 = 0xc3c3
  li   s1, 0xc3c3
  bne  t1, s1, 3f
  // byte store over a dword: sb patches one lane, lw must see the merge
  li   t0, 0x55
  sb   t0, 41(s0)
  ld   t1, 40(s0)
  li   s1, 0xa5a5c3c3dead55ef
  bne  t1, s1, 3f
  j    4f
3: FAIL 2
4:
  // --- back-to-back stores to same word then one load (coalesce) ---
  la   s0, scratch + 64
  li   t0, 0x1111
  sd   t0, 0(s0)            // bytes: 11 11 00 00 00 00 00 00
  li   t1, 0x22
  sb   t1, 1(s0)            // coalesce over byte 1
  li   t2, 0x33
  sb   t2, 7(s0)            // coalesce over byte 7
  ld   t3, 0(s0)
  li   s1, 0x3300000000002211
  bne  t3, s1, 5f
  j    6f
5: FAIL 3
6:
  // pass
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
done:
  j    done

  .section .data
  .align 4
scratch:
  .dword 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost:
  .dword 0
  .align 6
  .globl fromhost
fromhost:
  .dword 0
