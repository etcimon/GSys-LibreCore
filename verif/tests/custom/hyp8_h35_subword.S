// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// hyp8 H35: sub-word store/load shapes around byte 7 of an aligned dword.
//
// Linux 6.6.93 on the r107 model printed `earlyco=sbi` for the bootargs
// `earlycon=sbi` (byte index 7 lost) and every kallsyms name truncated at
// exactly 7 characters (byte 7 read as NUL): the MSB byte of an aligned
// 64-bit word is corrupted somewhere between a byte-copy loop's `sb`s and
// the later `lbu`/`ld`. h33 covers one `sb 7` coalesce after an `sd`; this
// test covers the kernel's shapes: eight consecutive `sb` filling a word
// (ascending and descending), a byte-copy loop across a dword and a cache
// line boundary, `sh 6`, `sw 4` + `sb 7`, byte 7 forwarded at distance 0/1
// while the stores are still pending, and `lbu 7` of a fresh line.
//
// tohost: 1 pass, 0x101.. fail codes.

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

  // 1. eight ascending sb into a zeroed dword, then ld
  li   t0, 0x11
  sb   t0, 0(s0)
  li   t0, 0x22
  sb   t0, 1(s0)
  li   t0, 0x33
  sb   t0, 2(s0)
  li   t0, 0x44
  sb   t0, 3(s0)
  li   t0, 0x55
  sb   t0, 4(s0)
  li   t0, 0x66
  sb   t0, 5(s0)
  li   t0, 0x77
  sb   t0, 6(s0)
  li   t0, 0x88
  sb   t0, 7(s0)
  ld   t1, 0(s0)
  li   s1, 0x8877665544332211
  bne  t1, s1, 11f
  lbu  t1, 7(s0)
  li   s1, 0x88
  bne  t1, s1, 11f
  j    12f
11: FAIL 1
12:
  // 2. eight descending sb, then forwarded reads at distance 0
  li   t0, 0xf8
  sb   t0, 15(s0)
  li   t0, 0xf7
  sb   t0, 14(s0)
  li   t0, 0xf6
  sb   t0, 13(s0)
  li   t0, 0xf5
  sb   t0, 12(s0)
  li   t0, 0xf4
  sb   t0, 11(s0)
  li   t0, 0xf3
  sb   t0, 10(s0)
  li   t0, 0xf2
  sb   t0, 9(s0)
  li   t0, 0xf1
  sb   t0, 8(s0)
  lbu  t1, 15(s0)
  li   s1, 0xf8
  bne  t1, s1, 21f
  lhu  t1, 14(s0)
  li   s1, 0xf8f7
  bne  t1, s1, 21f
  lwu  t1, 12(s0)
  li   s1, 0xf8f7f6f5
  bne  t1, s1, 21f
  ld   t1, 8(s0)
  li   s1, 0xf8f7f6f5f4f3f2f1
  bne  t1, s1, 21f
  j    22f
21: FAIL 2
22:
  // 3. byte-copy loop (lbu/sb/addi/bne), 24 bytes, source and destination
  //    both straddling a dword boundary; destination also straddles a
  //    64-byte line (scratch+120 .. +143).
  la   a0, src_str
  la   a1, scratch + 120
  la   a2, src_str + 24
31:
  lbu  t0, 0(a0)
  sb   t0, 0(a1)
  addi a0, a0, 1
  addi a1, a1, 1
  bne  a0, a2, 31b
  la   a0, src_str
  la   a1, scratch + 120
  la   a2, src_str + 24
32:
  lbu  t0, 0(a0)
  lbu  t1, 0(a1)
  bne  t0, t1, 33f
  addi a0, a0, 1
  addi a1, a1, 1
  bne  a0, a2, 32b
  // whole-word view of the copy: bytes 120..127 = "earlycon"
  la   a1, scratch + 120
  ld   t1, 0(a1)
  li   s1, 0x6e6f63796c726165      // "earlycon" little-endian
  bne  t1, s1, 33f
  ld   t1, 8(a1)
  li   s1, 0x706370206962733d      // "=sbi pcp" little-endian
  bne  t1, s1, 33f
  j    34f
33: FAIL 3
34:
  // 4. sh at offset 6 and sw at 4 + sb at 7 over a seeded dword
  la   s0, scratch + 32
  li   t0, 0x0102030405060708
  sd   t0, 0(s0)
  li   t0, 0xbeef
  sh   t0, 6(s0)
  ld   t1, 0(s0)
  li   s1, 0xbeef030405060708
  bne  t1, s1, 41f
  li   t0, 0xcafe1234
  sw   t0, 4(s0)
  li   t0, 0x9a
  sb   t0, 7(s0)
  ld   t1, 0(s0)
  li   s1, 0x9afe123405060708
  bne  t1, s1, 41f
  lbu  t1, 7(s0)
  li   s1, 0x9a
  bne  t1, s1, 41f
  lb   t1, 7(s0)
  li   s1, -102                    // 0x9a sign-extended
  bne  t1, s1, 41f
  j    42f
41: FAIL 4
42:
  // 5. byte 7 forwarded at distance 1 and after an unrelated load
  la   s0, scratch + 48
  sd   zero, 0(s0)
  li   t0, 0x5a
  sb   t0, 7(s0)
  nop
  lbu  t1, 7(s0)
  li   s1, 0x5a
  bne  t1, s1, 51f
  li   t0, 0xa5
  sb   t0, 7(s0)
  ld   t2, 8(s0)                   // unrelated dword between store and load
  lbu  t1, 7(s0)
  li   s1, 0xa5
  bne  t1, s1, 51f
  lhu  t1, 6(s0)
  li   s1, 0xa500
  bne  t1, s1, 51f
  j    52f
51: FAIL 5
52:
  // 6. strlen-style walk over the copied string: stop at NUL, expect 24
  la   a0, scratch + 120
  li   t3, 0
61:
  lbu  t0, 0(a0)
  beqz t0, 62f
  addi a0, a0, 1
  addi t3, t3, 1
  j    61b
62:
  li   s1, 24
  bne  t3, s1, 63f
  j    64f
63: FAIL 6
64:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
done:
  j    done

  .section .data
  .align 6                             // scratch+128 is a line boundary
scratch:
  .dword 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
  .align 3
  .byte 0, 0, 0, 0, 0                  // misalign src_str by 5 within its dword
src_str:
  .ascii "earlycon=sbi pcpu_zalloc"      // 24 bytes
  .byte 0
  .align 3

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost:
  .dword 0
