# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# COMPLETION.md stage 0 — one directed mini for PEEL c.lw@129f8 / a0=9.
# OpenSBI fdt_offset_ptr / fdt_next_tag / getprop-caller shape under DI.
#
# tohost=1 pass. Phase fail N is written as ((N<<1)|1). Variane prints
# *** FAILED *** (tohost = N) with N = value>>1 **decimal**. So printed
# 19 is P3 0x13, printed 25 is P9 0x19. Trap dump @0x80007000 (not
# tohost @0x80001000). Hart1 parks on mhartid.
#
#   P0 0x10  blob magic / off_dt_struct
#   P1 0x11  a0 at offset_ptr entry is fdt (high bits), not 0/9
#   P2 0x12  4×lbu header from that a0
#   P3 0x13  success c.addiw / add → a0 == fdt+off_dt_struct+offset
#   P3 0x2a  offset_ptr returned 0 (NULL / magic reject)
#   P3 0x2b  offset_ptr returned 0x28 (header word, not fdt)
#   P3 0x2c  offset_ptr returned 0x50 (0x28+0x28)
#   P3 0x2d  offset_ptr returned page-0 other
#   P3 0x2e  offset_ptr returned fdt (a1 add dropped)
#   P3 0x2f  offset_ptr returned fdt+8 (addi +8, no s0 restore)
#   P3 0x32  2nd load_be32 != 0x28 (header garbage / wrong addr)
#   P3 0x33  after mv a0,s0, a0 != s0
#   P3 0x38  after c.mv s0,a0, s0 is _start (copy of boot)
#   P3 0x39  after c.mv s0,a0, s0 != a0 (copy dropped)
#   P3 0x3a  s0 became _start during first load_be32 (smash)
#   P3 0x35  leftover a0 high32 == 0 (32-bit assemble, not DRAM+x)
#   P3 0x36  leftover a0 high32 == 1 (64-bit 0x1_xxxx overflow)
#   P3 0x37  leftover a0 high32 == -1 (sign-ext 32-bit)
#   P3 dump  leftover other: store a0|1; printed (a0|1)>>1
#            1535148160 = 0x5b808080 => a0_lo = 0xb7010100 (BE B7 01 01 00)
#   P3 0x80+d  a0==s2+d for d<0x1000 (printed tohost = 0x80+d)
#   P4 0x14  c.lw 0(a0) does not fault; word is BEGIN_NODE
#   P4 0x3b  P4 offset_ptr a0 != s2+0x28
#   P4 0x3c  c.lw returned 0
#   P4 0x3d  c.lw returned 9
#   P4 0x3e  c.lw returned 0x28
#   P4 dump  c.lw other: store a5|1; G1j slfix printed 8847222
#            => a5_lo = 0x010dfeec (not 1; DRAM at fdt+0x28 is 1)
#   P4 isol. Isolated c.lw s2+0x28 (no 2nd offset_ptr) is GREEN @1161
#            on G1n. 200k leftover was the 2nd offset_ptr, not the 0x70 line.
#   P5 0x15  NULL c.li a0,0 stays 0
#   P6 0x16  after committed a0=9, rewrite then address-use sees fdt
#   P6 0x40  after c.mv a0,s2, a0==0
#   P6 0x41  after c.mv a0,s2, a0 still 9 (restore dropped)
#   P6 0x42  after c.mv a0,s2, a0 page-0 other
#   P6 dump  after c.mv a0,s2, a0 != s2 (high bits): store a0|1
#   P6 0x43  load_be32 after restore returned 0
#   P6 0x44  load_be32 after restore returned 9
#   P6 dump  load_be32 after restore leftover: store a0|1
#   P6 0x50  2nd shot: s2 != fdt (smashed by first load_be32)
#   P6 0x51  2nd shot: after c.mv a0,s2, a0==0
#   P6 0x52  2nd shot: a0 still 9
#   P6 0x53  2nd shot: a0 page-0 other
#   P6 dump  2nd shot: a0 != s2 (high bits): store a0|1
#   P6 0x54  2nd shot: load_be32 returned 0
#   P6 0x55  2nd shot: load_be32 returned 9
#   P6 dump  2nd shot: load leftover: store a0|1
#   P6 0x56  offset_ptr window: after c.mv, a0==0
#   P6 0x57  offset_ptr window: a0 still 9
#   P6 0x58  offset_ptr window: a0 page-0 other
#   P6 dump  offset_ptr window: a0 != s2: store a0|1
#   P6 0x59  offset_ptr returned 0 (NULL)
#   P6 0x5a  offset_ptr returned page-0 non-zero
#   P6 0x5b  offset_ptr a0 != s2+0x28
#   P6 0x5c  c.lw tag 0
#   P6 0x5d  c.lw tag 9
#   P6 0x5e  c.lw tag 0x28
#   P6 dump  c.lw other: store a5|1
#   P6 0x62  fail_phase with pre-jal s11 (ra smash / unset path)
#   P6 0x63  offset_ptr entry a0 page-0 (c.mv did not stick for callee)
#   P6 0x64  offset_ptr entry a0 != s2 (high bits, wrong pointer)
#   P6 0x65  P6 ret ra low12 == P5 return 0x14c (stale frame)
#   P6 0x66  P6 ret ra == 0
#   P6 0x67  P6 ret ra low12 == fail_phase
#   P6 0x68  after sd ra, ld != RF ra (store stale / STQ fwd; jal wrote)
#   P6 0x69  2nd ld 8(sp) != t1 (0x68 forwarded; slot disagrees)
#   P6 G1ar  li t3,-1 before 2nd ld so a dest write is a TRACE edge
#   P6 0x6a  offset_ptr entry t2 != 0x51 (caller tail / jal never issued)
#   P7 0x17  strlen-like 9, c.mv a0,s5, jal getprop-shaped; a0 is fdt
#   P8 0x18  s1/s2/s4/s5 survive check_node / next_tag nest
#   P9 0x19  next_tag(0) returns BEGIN_NODE
#   P9b 0x1a offset_ptr(fdt, 9) returns fdt+off_dt_struct+9 (not a load)
#   P10 0x1d PEEL: strlen 9, c.mv a0,s2, next_tag_peel (no high-bit skip)
#   P11 0x21 two clean next_tag_peel(fdt,0) before the a0=9 window
#   P9e 0x1f s2 still fdt after P10
#   P9e 0x20 mv a0,s2 took (a0==s2) before the post-P10 peel
#   P9e 0x22 peel returned an unknown tag (not 1 / 9 / 0x1b / 0x1c)
#   P9e 0x25 a0 page-0 after c.mv a0,s4 (peel prologue)
#   P9e 0x26 a0 page-0 at offset_ptr_raw entry (after frame save)
#   P9e 0x28 a0 != s4 at offset_ptr_raw entry (wrong pointer, high bits)
#   P9e 0x29 a0 != s2 after c.mv a0,s4
#

  .option rvc
  .section .text.init
  .globl _start
_start:
  # SMT2 both harts fetch reset. Spike is one hart. Park non-zero
  # mhartid before touching the shared stack / tohost.
  csrr t0, mhartid
  bnez t0, .Lpark
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0
  la   s2, fdt_blob
  mv   s5, s2

  # ------------------------------------------------------------------
  # P0: magic + off_dt_struct via 4×lbu (header is BE)
  # ------------------------------------------------------------------
  li   s11, 0x10
  mv   a0, s2
  jal  load_be32
  li   t0, 0xd00dfeed
  bne  a0, t0, fail_phase
  mv   a0, s2
  addi a0, a0, 8
  jal  load_be32
  li   t0, 0x28
  bne  a0, t0, fail_phase

  # ------------------------------------------------------------------
  # P1: a0 at offset_ptr-shaped entry is fdt, not 0 / not 9
  # ------------------------------------------------------------------
  li   s11, 0x11
  mv   a0, s2
  li   a1, 0
  beqz a0, fail_phase
  li   t0, 9
  beq  a0, t0, fail_phase
  srli t0, a0, 12
  beqz t0, fail_phase
  bne  a0, s2, fail_phase

  # ------------------------------------------------------------------
  # P2: 4×lbu header from that a0 (totalsize at +4)
  # ------------------------------------------------------------------
  li   s11, 0x12
  mv   a0, s2
  addi a0, a0, 4
  jal  load_be32
  li   t0, 0x48
  bne  a0, t0, fail_phase

  # ------------------------------------------------------------------
  # P3: success path c.addiw a5,0 / c.add a1,a5 / c.add a0,a1
  # ------------------------------------------------------------------
  li   s11, 0x13
  mv   a0, s2
  li   a1, 0
  jal  offset_ptr
  beqz a0, 20f
  li   t0, 0x28
  beq  a0, t0, 21f
  li   t0, 0x50
  beq  a0, t0, 22f
  srli t0, a0, 12
  beqz t0, 23f
  beq  a0, s2, 25f
  li   a1, 8
  c.add a1, s2
  beq  a0, a1, 26f
  # Compare to s2+0x28 via kept c.add a1,s2 (not la t0).
  li   a1, 0x28
  c.add a1, s2
  beq  a0, a1, 24f
  # G1j leftover hung mid-RVI on `beq a0,sp` @0xb6 (straddles 8B).
  # Dump a0|1 on an 8B line so the store is not that straddle.
  .p2align 3
  ori  a0, a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
9: j    9b
26:
  li   s11, 0x2f
  j    fail_phase
20:
  li   s11, 0x2a
  j    fail_phase
21:
  li   s11, 0x2b
  j    fail_phase
22:
  li   s11, 0x2c
  j    fail_phase
23:
  li   s11, 0x2d
  j    fail_phase
25:
  li   s11, 0x2e
  j    fail_phase
24:

  # ------------------------------------------------------------------
  # P4: c.lw 0(a0) — aligned tag, must not fault
  # ------------------------------------------------------------------
  li   s11, 0x14
  # Isolate the 0x70 line from a second offset_ptr (G1j–n P4 dump
  # was 8847222 @200649). P3 already proved offset_ptr returns s2+0x28.
  li   a1, 0x28
  c.add a1, s2
  mv   a0, a1
  c.lw a5, 0(a0)
  li   t0, 1
  beq  a5, t0, 32f
  beqz a5, 33f
  li   t0, 9
  beq  a5, t0, 34f
  li   t0, 0x28
  beq  a5, t0, 35f
  .p2align 3
  ori  a5, a5, 1
  la   t0, tohost
  sw   a5, 0(t0)
36: j    36b
35:
  li   s11, 0x3e
  j    fail_phase
34:
  li   s11, 0x3d
  j    fail_phase
33:
  li   s11, 0x3c
  j    fail_phase
31:
  li   s11, 0x3b
  j    fail_phase
32:

  # ------------------------------------------------------------------
  # P5: NULL path c.li a0,0 stays 0 (do not invent a pointer)
  # ------------------------------------------------------------------
  li   s11, 0x15
  li   a0, 9
  la   a0, not_fdt
  li   a1, 0
  jal  offset_ptr
  bnez a0, fail_phase
  li   a0, 9
  c.li a0, 0
  bnez a0, fail_phase

  # ------------------------------------------------------------------
  # P6: committed small a0=9, then rewrite, then address-use
  #     (PEEL class is c.lw of a0=9; rewrite must win)
  # Isolated-P4: this is the first fail (22 = 0x16 @1161). Split the
  # first shot so we see copy-dropped vs load-of-fdt-garbage.
  # ------------------------------------------------------------------
  li   s11, 0x16
  c.li a0, 9
  c.mv a0, s2
  beq  a0, s2, 40f
  beqz a0, 41f
  li   t0, 9
  beq  a0, t0, 42f
  srli t0, a0, 12
  beqz t0, 43f
  .p2align 3
  ori  a0, a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
44: j    44b
41:
  li   s11, 0x40
  j    fail_phase
42:
  li   s11, 0x41
  j    fail_phase
43:
  li   s11, 0x42
  j    fail_phase
40:
  li   s11, 0x60
  jal  load_be32
  li   t0, 0xd00dfeed
  beq  a0, t0, 45f
  beqz a0, 46f
  li   t0, 9
  beq  a0, t0, 47f
  .p2align 3
  ori  a0, a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
48: j    48b
46:
  li   s11, 0x43
  j    fail_phase
47:
  li   s11, 0x44
  j    fail_phase
45:
  # First restore+load_be32 was green (isolated-P4 P6 0x16 was
  # the *second* trip). Check s2, then one more shot.
  la   t0, fdt_blob
  bne  s2, t0, 60f
  c.li a0, 9
  c.mv a0, s2
  beq  a0, s2, 50f
  beqz a0, 51f
  li   t0, 9
  beq  a0, t0, 52f
  srli t0, a0, 12
  beqz t0, 53f
  .p2align 3
  ori  a0, a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
54: j    54b
60:
  li   s11, 0x50
  j    fail_phase
51:
  li   s11, 0x51
  j    fail_phase
52:
  li   s11, 0x52
  j    fail_phase
53:
  li   s11, 0x53
  j    fail_phase
50:
  li   s11, 0x61
  jal  load_be32
  li   t0, 0xd00dfeed
  beq  a0, t0, 55f
  beqz a0, 56f
  li   t0, 9
  beq  a0, t0, 57f
  .p2align 3
  ori  a0, a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
58: j    58b
56:
  li   s11, 0x54
  j    fail_phase
57:
  li   s11, 0x55
  j    fail_phase
55:

  # Same window through offset_ptr: restore fdt before the jal
  # (PEEL shape). Both standalone load_be32 shots after a0=9 were green.
  c.li a0, 9
  c.mv a0, s2
  beq  a0, s2, 70f
  beqz a0, 71f
  li   t0, 9
  beq  a0, t0, 72f
  srli t0, a0, 12
  beqz t0, 73f
  .p2align 3
  ori  a0, a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
74: j    74b
71:
  li   s11, 0x56
  j    fail_phase
72:
  li   s11, 0x57
  j    fail_phase
73:
  li   s11, 0x58
  j    fail_phase
70:
  li   s11, 0x62
  li   a1, 0
  # G1ad: pack li t2 + jal in one 8B block (no leftover JAL).
  # G1q: if offset_ptr runs without this li, jal was never issued.
  .p2align 3
  li   t2, 0x51
  jal  offset_ptr
  beqz a0, 75f
  srli t0, a0, 12
  beqz t0, 76f
  li   a1, 0x28
  c.add a1, s2
  bne  a0, a1, 77f
  c.lw a5, 0(a0)
  li   t0, 1
  beq  a5, t0, 80f
  beqz a5, 78f
  li   t0, 9
  beq  a5, t0, 79f
  li   t0, 0x28
  beq  a5, t0, 81f
  .p2align 3
  ori  a5, a5, 1
  la   t0, tohost
  sw   a5, 0(t0)
82: j    82b
75:
  li   s11, 0x59
  j    fail_phase
76:
  li   s11, 0x5a
  j    fail_phase
77:
  li   s11, 0x5b
  j    fail_phase
78:
  li   s11, 0x5c
  j    fail_phase
79:
  li   s11, 0x5d
  j    fail_phase
81:
  li   s11, 0x5e
  j    fail_phase
80:

  # ------------------------------------------------------------------
  # P7: strlen-like 9, wrapper c.mv a0,s5, jal getprop-shaped
  # ------------------------------------------------------------------
  li   s11, 0x17
  li   s4, 16
2:
  mv   s5, s2
  jal  strlen_like
  li   t0, 9
  bne  a0, t0, fail_phase
  c.mv a0, s5
  jal  getprop_like
  addi s4, s4, -1
  bnez s4, 2b

  # ------------------------------------------------------------------
  # P11: two clean peels before the a0=9 window. Isolates "second
  # walk" from P10 poison. Fail 0x21 = second-walk without strlen-9.
  # ------------------------------------------------------------------
  li   s11, 0x21
  mv   a0, s2
  li   a1, 0
  jal  next_tag_peel
  li   t0, 1
  bne  a0, t0, fail_phase
  mv   a0, s2
  li   a1, 0
  jal  next_tag_peel
  li   t0, 1
  bne  a0, t0, fail_phase

  # ------------------------------------------------------------------
  # P10: PEEL pin — a0=9 (strlen), restore fdt, next_tag_peel does
  # c.lw with no high-bit skip. If restore is cancelled, a0 stays 9
  # and c.lw faults (mcause=4 mtval=9).
  # ------------------------------------------------------------------
  li   s11, 0x1d
  li   s4, 4
10:
  c.li a0, 9
  jal  11f
11:
  c.mv a0, s2
  li   a1, 0
  jal  next_tag_peel
  li   t0, 1
  bne  a0, t0, fail_phase
  addi s4, s4, -1
  bnez s4, 10b

  # P9-early: one more peel-walk before the nest (isolates P8 poison).
  # Distinguish: s2 clobber (0x1f), mv a0,s2 dropped (0x20), peel
  # returned 9 (0x1e) / 0x1b / 0x1c, else 0x19 (trap or unknown tag).
  li   s11, 0x1f
  la   t0, fdt_blob
  bne  s2, t0, fail_phase
  li   s11, 0x20
  mv   a0, s2
  bne  a0, s2, fail_phase
  li   s11, 0x19
  li   a1, 0
  jal  next_tag_peel
  li   t0, 0x1b
  beq  a0, t0, fail_from_a0
  li   t0, 0x1c
  beq  a0, t0, fail_from_a0
  li   t0, 9
  bne  a0, t0, 13f
  li   s11, 0x1e
  j    fail_phase
13:
  li   t0, 0x25
  beq  a0, t0, fail_from_a0
  li   t0, 0x26
  beq  a0, t0, fail_from_a0
  li   t0, 0x28
  beq  a0, t0, fail_from_a0
  li   t0, 0x29
  beq  a0, t0, fail_from_a0
  li   t0, 1
  beq  a0, t0, 14f
  li   s11, 0x22
  j    fail_phase
14:

  # ------------------------------------------------------------------
  # P8: callee-saved s1/s2/s4/s5 survive a namelen / next_tag nest
  # ------------------------------------------------------------------
  li   s11, 0x18
  mv   s1, s2
  mv   s4, s2
  mv   s5, s2
  li   a1, 0
  mv   a0, s2
  jal  check_node_like
  li   t0, 1
  bne  a0, t0, fail_phase
  bne  s1, s2, fail_phase
  la   t0, fdt_blob
  bne  s2, t0, fail_phase
  bne  s4, t0, fail_phase
  bne  s5, t0, fail_phase

  # ------------------------------------------------------------------
  # P9: next_tag(0) → BEGIN_NODE (c.lw inside callee; PEEL shape)
  # ------------------------------------------------------------------
  li   s11, 0x19
  mv   a0, s2
  li   a1, 0
  jal  next_tag_peel
  li   t0, 0x1b
  beq  a0, t0, fail_from_a0
  li   t0, 0x1c
  beq  a0, t0, fail_from_a0
  li   t0, 9
  bne  a0, t0, 12f
  li   s11, 0x1e
  j    fail_phase
12:
  li   t0, 1
  bne  a0, t0, fail_phase

  # P9b: offset_ptr(fdt, 9) → fdt+0x28+9; lbu only (9 is not word-aligned)
  li   s11, 0x1a
  mv   a0, s2
  li   a1, 9
  jal  offset_ptr
  la   t0, fdt_blob
  addi t0, t0, 0x31
  bne  a0, t0, fail_phase
  srli t1, a0, 12
  beqz t1, fail_phase
  lbu  a5, 0(a0)

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

# load_be32(a0) → a0. Four lbu + shift/or (offset_ptr header assemble).
load_be32:
  lbu  t0, 0(a0)
  lbu  t1, 1(a0)
  lbu  t2, 2(a0)
  lbu  t3, 3(a0)
  slli t0, t0, 24
  slli t1, t1, 16
  slli t2, t2, 8
  or   a0, t0, t1
  or   a0, a0, t2
  or   a0, a0, t3
  ret

# offset_ptr(a0=fdt, a1=offset) → a0 = fdt+off_dt_struct+offset or 0
# OpenSBI success mix: 4×lbu header, c.addiw a5,0, c.add a1,a5, c.add a0,a1.
# Magic mismatch → c.li a0,0 (NULL).
offset_ptr:
  # P6: caller beq saw a0==s2, then jal. If issue a0 is still 9,
  # the restore was cancelled after the compare forwarded.
  # P5 passes not_fdt (high bits) — only reject page-0 here.
  # G1q: t2==0x51 means the caller tail ran; else never-issued.
  li   t0, 0x62
  bne  s11, t0, 95f
  li   t0, 0x51
  beq  t2, t0, 95f
  li   s11, 0x6a
  j    fail_phase
95:
  srli t0, a0, 12
  beqz t0, .Lentry0
  addi sp, sp, -16
  sd   ra, 8(sp)
  sd   s0, 0(sp)
  # P6: if jal wrote RF but the slot is not RF, the store (or STQ
  # forward) is the miss. If this check passes and 0x65 still fires,
  # RF was already P5's ra (jal link never committed).
  li   t0, 0x62
  bne  s11, t0, 94f
  ld   t1, 8(sp)
  beq  t1, ra, 96f
  li   s11, 0x68
  j    fail_phase
  # G1am: same slot, dest not ra/t1. 0x68 can forward jal/RF;
  # a second load that disagrees means the slot is not RF ra.
96:
  # G1ar: poison t3 so a dest write is a value-change (0xed was stale).
  li   t3, -1
  ld   t3, 8(sp)
  beq  t3, t1, 94f
  li   s11, 0x69
  j    fail_phase
94:
  mv   s0, a0
  # Split: boot already in s0 vs smash during first load_be32.
  lui  t0, 0x80000
  beq  s0, t0, .Lboot
  bne  s0, a0, .Lcmv
  jal  load_be32
  li   t0, 0xd00dfeed
  bne  a0, t0, .Lnull
  lui  t0, 0x80000
  beq  s0, t0, .Lsmash
  mv   a0, s0
  addi a0, a0, 8
  jal  load_be32
  # P0 already proved standalone load_be32(fdt+8)==0x28. If this
  # in-frame load is not 0x28, s0+8 is wrong or the assemble is.
  li   t0, 0x28
  bne  a0, t0, .Lhdr
  mv   a5, a0
  mv   a0, s0
  bne  a0, s0, .Lnos0
  c.addiw a5, 0
  c.add  a1, a5
  c.add  a0, a1
  j    .Lret
.Lhdr:
  # 2nd load_be32 != 0x28. Lab: s0 was 0x80000000 (_start), so
  # the load assembled instruction bytes at _start+8 (0xB7010100).
  li   s11, 0x32
  j    fail_phase
.Lboot:
  li   s11, 0x38
  j    fail_phase
.Lcmv:
  li   s11, 0x39
  j    fail_phase
.Lsmash:
  li   s11, 0x3a
  j    fail_phase
.Lnos0:
  li   s11, 0x33
  j    fail_phase
.Lnull:
  c.li a0, 0
.Lret:
  ld   s0, 0(sp)
  ld   ra, 8(sp)
  # P6 only (s11==0x62): name a stale-ra ret (P5 site is bnez→fail).
  li   t0, 0x62
  bne  s11, t0, 90f
  beqz ra, 91f
  li   t0, 0xfff
  and  t1, ra, t0
  li   t0, 0x14c
  beq  t1, t0, 92f
  li   t0, 0x668
  beq  t1, t0, 93f
90:
  addi sp, sp, 16
  ret
91:
  li   s11, 0x66
  j    fail_phase
92:
  li   s11, 0x65
  j    fail_phase
93:
  li   s11, 0x67
  j    fail_phase
.Lentry0:
  li   s11, 0x63
  j    fail_phase

# next_tag(a0=fdt, a1=offset) → a0 = tag word
# OpenSBI: c.li a2,4; c.mv s4,a0; c.mv s5,a1; jal offset_ptr; beqz; c.lw
next_tag:
  srli t0, a0, 12
  beqz t0, .Lbad_entry
  addi sp, sp, -32
  sd   ra, 24(sp)
  sd   s4, 16(sp)
  sd   s5, 8(sp)
  c.li a2, 4
  c.mv s4, a0
  c.mv s5, a1
  mv   a0, s4
  mv   a1, s5
  jal  offset_ptr
  beqz a0, .Ltag_end
  srli t0, a0, 12
  beqz t0, .Lbad_ptr
  c.lw a5, 0(a0)
  mv   a0, a5
  ld   s5, 8(sp)
  ld   s4, 16(sp)
  ld   ra, 24(sp)
  addi sp, sp, 32
  ret
.Lbad_entry:
  li   a0, 0x1c
  ret
.Lbad_ptr:
  li   a0, 0x1b
  ld   s5, 8(sp)
  ld   s4, 16(sp)
  ld   ra, 24(sp)
  addi sp, sp, 32
  ret
.Ltag_end:
  li   a0, 9
  ld   s5, 8(sp)
  ld   s4, 16(sp)
  ld   ra, 24(sp)
  addi sp, sp, 32
  ret

# offset_ptr_raw: OpenSBI success mix only (no magic reject).
# a0=fdt → fdt+off_dt_struct+offset. a0=9 → lbu zeros, return 9+offset.
offset_ptr_raw:
  addi sp, sp, -16
  sd   ra, 8(sp)
  sd   s0, 0(sp)
  srli t0, a0, 12
  beqz t0, .Lraw_page0
  bne  a0, s4, .Lraw_nots4
  mv   s0, a0
  addi a0, a0, 8
  jal  load_be32
  mv   a5, a0
  mv   a0, s0
  c.addiw a5, 0
  c.add  a1, a5
  c.add  a0, a1
  ld   s0, 0(sp)
  ld   ra, 8(sp)
  addi sp, sp, 16
  ret
.Lraw_page0:
  li   a0, 0x26
  ld   s0, 0(sp)
  ld   ra, 8(sp)
  addi sp, sp, 16
  ret
.Lraw_nots4:
  li   a0, 0x28
  ld   s0, 0(sp)
  ld   ra, 8(sp)
  addi sp, sp, 16
  ret

# next_tag_peel: same CF/c.lw as OpenSBI; no high-bit skip (PEEL 129f8).
next_tag_peel:
  addi sp, sp, -32
  sd   ra, 24(sp)
  sd   s4, 16(sp)
  sd   s5, 8(sp)
  c.li a2, 4
  c.mv s4, a0
  c.mv s5, a1
  mv   a0, s4
  mv   a1, s5
  bne  a0, s2, .Lpeel_nots2
  srli t0, a0, 12
  beqz t0, .Lpeel_pro
  jal  offset_ptr_raw
  beqz a0, .Lpeel_end
  srli t0, a0, 12
  beqz t0, .Lpeel_page0
  c.lw a5, 0(a0)
  mv   a0, a5
  ld   s5, 8(sp)
  ld   s4, 16(sp)
  ld   ra, 24(sp)
  addi sp, sp, 32
  ret
.Lpeel_end:
  li   a0, 9
  ld   s5, 8(sp)
  ld   s4, 16(sp)
  ld   ra, 24(sp)
  addi sp, sp, 32
  ret
.Lpeel_page0:
  li   a0, 0x1b
  ld   s5, 8(sp)
  ld   s4, 16(sp)
  ld   ra, 24(sp)
  addi sp, sp, 32
  ret
.Lpeel_pro:
  li   a0, 0x25
  ld   s5, 8(sp)
  ld   s4, 16(sp)
  ld   ra, 24(sp)
  addi sp, sp, 32
  ret
.Lpeel_nots2:
  li   a0, 0x29
  ld   s5, 8(sp)
  ld   s4, 16(sp)
  ld   ra, 24(sp)
  addi sp, sp, 32
  ret

fail_from_a0:
  mv   s11, a0
  j    fail_phase

# check_node-like: save s1, jal next_tag, restore. Caller holds s2=fdt.
check_node_like:
  addi sp, sp, -16
  sd   ra, 8(sp)
  sd   s1, 0(sp)
  c.mv s1, a0
  li   a1, 0
  mv   a0, s1
  jal  next_tag
  ld   s1, 0(sp)
  ld   ra, 8(sp)
  addi sp, sp, 16
  ret

strlen_like:
  li   a0, 9
  ret

# getprop-shaped: a0 must be fdt (high bits + exact), not 0/9
getprop_like:
  beqz a0, .Lgfail
  li   t0, 9
  beq  a0, t0, .Lgfail
  srli t0, a0, 12
  beqz t0, .Lgfail
  la   t0, fdt_blob
  bne  a0, t0, .Lgfail
  ret
.Lgfail:
  li   s11, 0x17
  j    fail_phase

.Lpark:
  wfi
  j    .Lpark

fail_phase:
  mv   a0, s11
  slli a0, a0, 1
  ori  a0, a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
4: j    4b

trap:
  # Do not store the dump at tohost (0x80001000). Use stack-below scratch.
  li   t0, 0x80007000
  csrr t1, mepc
  sd   t1, 0(t0)
  csrr t1, mcause
  sd   t1, 8(t0)
  csrr t1, mtval
  sd   t1, 16(t0)
  sd   a0, 24(t0)
  sd   s2, 32(t0)
  sd   s5, 40(t0)
  sd   sp, 48(t0)
  csrr t1, mepc
  sd   t1, 56(t0)
  # tohost prints ((mcause&0xf)<<12)|(mepc&0xfff). Covers sign-ext DRAM.
  csrr a0, mepc
  li   t1, 0xfff
  and  a0, a0, t1
  csrr t1, mcause
  andi t1, t1, 0xf
  slli t1, t1, 12
  or   a0, a0, t1
  slli a0, a0, 1
  ori  a0, a0, 1
6:
  la   t0, tohost
  sw   a0, 0(t0)
7: j    7b

  .section .rodata
  .align 3
fdt_blob:
  .byte 0xd0, 0x0d, 0xfe, 0xed
  .byte 0x00, 0x00, 0x00, 0x48
  .byte 0x00, 0x00, 0x00, 0x28
  .byte 0x00, 0x00, 0x00, 0x40
  .byte 0x00, 0x00, 0x00, 0x28
  .byte 0x00, 0x00, 0x00, 0x11
  .byte 0x00, 0x00, 0x00, 0x10
  .byte 0x00, 0x00, 0x00, 0x00
  .byte 0x00, 0x00, 0x00, 0x08
  .byte 0x00, 0x00, 0x00, 0x18
  /* 0x28 structure — LE words so c.lw sees the tag value */
  .word 1
  .word 0
  .word 3
  .word 0
  .word 0
  .word 9
  /* 0x40 strings */
  .word 0
  .word 0

  .align 3
not_fdt:
  .word 0
  .word 0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
