// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// hyp8 Zicclsm: a misaligned load/store that crosses the natural 8-byte
// word boundary is split into two bus beats instead of raising
// LD/ST_ADDR_MISALIGNED. Only meaningful with RVZicclsm=1 — with the
// knob off the same accesses trap and this test never reaches tohost.
//
// scratch[i] is filled with byte value i (little-endian index), so a
// misaligned access at offset k assembles a known value. Only offsets
// that genuinely wrap the 8-byte boundary are exercised:
//   lh/lhu/sh (2B) wrap iff (addr&7)==7 ; lw/lwu/sw (4B) iff (addr&7)>4 ;
//   ld/sd (8B) iff (addr&7)!=0.
//
// tohost: 1 pass, 0x1nn fail codes.

  .macro FAIL n
    li   a0, 0x100 + \n
    la   t0, tohost
    sw   a0, 0(t0)
    j    done
  .endm

  .section .text.init
  .globl _start
_start:
  // fill scratch[0..63] with byte[i] = i
  la   s1, scratch
  li   t1, 64
  li   t0, 0
1:sb   t0, 0(s1)
  addi s1, s1, 1
  addi t0, t0, 1
  addi t1, t1, -1
  bnez t1, 1b
  la   s1, scratch

  // ---- misaligned loads crossing the 8-byte boundary ----
  // lw +5: bytes5,6,7,8 = 05 06 07 08 -> LE 0x08070605
  lw   t2, 5(s1)
  li   s2, 0x08070605
  bne  t2, s2, 2f
  j    3f
2: FAIL 1
3:
  // lw +6: bytes6,7,8,9 -> LE 0x09080706
  lw   t2, 6(s1)
  li   s2, 0x09080706
  bne  t2, s2, 4f
  j    5f
4: FAIL 2
5:
  // lw +7: bytes7,8,9,10 -> LE 0x0a090807
  lw   t2, 7(s1)
  li   s2, 0x0a090807
  bne  t2, s2, 6f
  j    7f
6: FAIL 3
7:
  // ld +1: bytes1..8 -> LE 0x0807060504030201
  ld   t2, 1(s1)
  li   s2, 0x0807060504030201
  bne  t2, s2, 8f
  j    9f
8: FAIL 4
9:
  // ld +3: bytes3..10 -> LE 0x0a09080706050403
  ld   t2, 3(s1)
  li   s2, 0x0a09080706050403
  bne  t2, s2, 10f
  j    11f
10: FAIL 5
11:
  // lh +7: bytes7,8 -> 0x0807 (bit15 clear)
  lh   t2, 7(s1)
  li   s2, 0x0807
  bne  t2, s2, 12f
  j    13f
12: FAIL 6
13:
  // lhu +7: bytes7,8 unsigned -> 0x0807
  lhu  t2, 7(s1)
  li   s2, 0x0807
  bne  t2, s2, 14f
  j    15f
14: FAIL 7
15:
  // lwu +5: bytes5,6,7,8 unsigned -> 0x08070605
  lwu  t2, 5(s1)
  li   s2, 0x08070605
  bne  t2, s2, 16f
  j    17f
16: FAIL 8
17:
  // ---- sign extension through the 2-beat path ----
  // plant high bytes: scratch[16]=0x80 17=0x81 18=0x82 19=0x83 20=0x84
  li   t0, 0x80
  sb   t0, 16(s1)
  li   t0, 0x81
  sb   t0, 17(s1)
  li   t0, 0x82
  sb   t0, 18(s1)
  li   t0, 0x83
  sb   t0, 19(s1)
  li   t0, 0x84
  sb   t0, 20(s1)

  // lh +15: bytes15(0x0f),16(0x80) -> 0x800f, bit15 set -> sext 0xffff...800f
  lh   t2, 15(s1)
  li   s2, -32753                 // 0xffffffffffff800f
  bne  t2, s2, 18f
  j    19f
18: FAIL 9
19:
  // lw +21: bytes21,22,23,24 = idx 21,22,23,24 -> 0x18171615 (bit31 clear)
  //   off=21&7=5 >4 wraps. sanity that index bytes still assemble.
  lw   t2, 21(s1)
  li   s2, 0x18171615
  bne  t2, s2, 20f
  j    21f
20: FAIL 10
21:
  // lw +22 crossing with a high byte: set scratch[25]=0x85 then
  //   lw +22 reads bytes22,23,24,25. Do a dedicated store instead:
  //   simpler: lwu +23 reads bytes23,24,25,26 (all index) -> 0x1a191817
  lwu  t2, 23(s1)
  li   s2, 0x1a191817
  bne  t2, s2, 22f
  j    23f
22: FAIL 11
23:
  // ---- misaligned stores crossing the boundary ----
  // sw +45 (45&7=5>4 wraps) of 0x11223344 -> bytes45,46,47,48
  //   before: byte40..47 = idx; sw+40 sanity first (aligned, bytes40-43)
  li   t2, 0xAABBCCDD
  sw   t2, 40(s1)                 // aligned sw: bytes40=DD 41=CC 42=BB 43=AA
  li   t2, 0x11223344
  sw   t2, 45(s1)                 // bytes45=44 46=33 47=22 48=11
  ld   t2, 40(s1)                 // bytes40..47
  //   byte40=DD 41=CC 42=BB 43=AA 44=idx44(0x2c) 45=44 46=33 47=22
  //   LE qword = 22 33 44 2c aa bb cc dd -> 0x2233442caabbccdd
  li   s2, 0x2233442caabbccdd
  bne  t2, s2, 24f
  j    25f
24: FAIL 12
25:
  // sd +41 (41&7=1!=0 wraps) of 0x0102030405060708 -> bytes41..48
  //   overwrites 41-48: byte41=08 42=07 43=06 44=05 45=04 46=03 47=02 48=01
  li   t2, 0x0102030405060708
  sd   t2, 41(s1)
  ld   t2, 40(s1)                 // bytes40..47: 40=DD 41=08..47=02
  //   LE = byte40=DD | 08<<8 | 07<<16 | 06<<24 | 05<<32 | 04<<40 | 03<<48 | 02<<56
  //      = 0x02030405060708dd
  li   s2, 0x02030405060708dd
  bne  t2, s2, 26f
  j    27f
26: FAIL 13
27:
  // sh +47 (47&7=7==7 wraps) of 0xBEEF -> byte47=EF byte48=BE
  li   t2, 0xBEEF
  sh   t2, 47(s1)
  lbu  t2, 47(s1)
  li   s2, 0xEF
  bne  t2, s2, 28f
  j    29f
28: FAIL 14
29:  lbu  t2, 48(s1)
  li   s2, 0xBE
  bne  t2, s2, 30f
  j    31f
30: FAIL 15
31:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
done:
  j    done

  .section .data
  .align 6                             // scratch is 64-byte aligned
scratch:
  .zero 64
  .align 6

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost:
  .dword 0
