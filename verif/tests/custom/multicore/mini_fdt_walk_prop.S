# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Soft-ladder iter-012: real BE FDT + s2=lenp across nested save/restore.
# Spike-green first, then DI RTL. tohost=1 pass / 3 fail. No git commit.
#

  .section .rodata
  .align 3
fdt_blob:
  .byte 0xd0,0x0d,0xfe,0xed
  .byte 0x00,0x00,0x00,0x70
  .byte 0x00,0x00,0x00,0x38
  .byte 0x00,0x00,0x00,0x60
  .byte 0x00,0x00,0x00,0x28
  .byte 0x00,0x00,0x00,0x11
  .byte 0x00,0x00,0x00,0x10
  .byte 0x00,0x00,0x00,0x00
  .byte 0x00,0x00,0x00,0x10
  .byte 0x00,0x00,0x00,0x28
  .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
  .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
  .byte 0x00,0x00,0x00,0x01
  .byte 0x00,0x00,0x00,0x00
  .byte 0x00,0x00,0x00,0x03
  .byte 0x00,0x00,0x00,0x05
  .byte 0x00,0x00,0x00,0x00
  .byte 0x74,0x65,0x73,0x74
  .byte 0x00,0x00,0x00,0x00
  .byte 0x00,0x00,0x00,0x02
  .byte 0x00,0x00,0x00,0x09
  .byte 0x00,0x00,0x00,0x00
  .ascii "compatible"
  .byte 0x00
  .ascii "test"
  .byte 0x00
  .byte 0x00,0x00

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0
  la   s10, fdt_blob

  # A: BE tags
  lbu  t0, 0x38(s10)
  lbu  t1, 0x39(s10)
  lbu  t2, 0x3a(s10)
  lbu  t3, 0x3b(s10)
  slli t0, t0, 24
  slli t1, t1, 16
  slli t2, t2, 8
  or   a0, t0, t1
  or   a0, a0, t2
  or   a0, a0, t3
  li   t0, 1
  bne  a0, t0, fail

  lbu  t0, 0x40(s10)
  lbu  t1, 0x41(s10)
  lbu  t2, 0x42(s10)
  lbu  t3, 0x43(s10)
  slli t0, t0, 24
  slli t1, t1, 16
  slli t2, t2, 8
  or   a0, t0, t1
  or   a0, a0, t2
  or   a0, a0, t3
  li   t0, 3
  bne  a0, t0, fail

  # B: s2=lenp, nest save/clobber/restore, success *lenp=5
  addi s11, sp, -24
  li   t0, 0xdeadbeef
  sw   t0, 0(s11)
  li   s2, 0x80012b2a
  mv   s2, s11
  # nest like next_tag
  addi sp, sp, -64
  sd   s2, 16(sp)
  li   s2, 9
  li   t0, 0x01020304
  srliw s2, t0, 24
  li   s2, 3
  ld   s2, 16(sp)
  addi sp, sp, 64
  bne  s2, s11, fail
  # write len 5 via BE load from blob
  lbu  t0, 0x44(s10)
  lbu  t1, 0x45(s10)
  lbu  t2, 0x46(s10)
  lbu  t3, 0x47(s10)
  slli t0, t0, 24
  slli t1, t1, 16
  slli t2, t2, 8
  or   t0, t0, t1
  or   t0, t0, t2
  or   t0, t0, t3
  sw   t0, 0(s2)
  lw   t1, 0(s11)
  li   t0, 5
  bne  t1, t0, fail

  # C: fail path sw -4 to *s2 after nest
  addi s11, sp, -28
  li   s2, 0x80012b2a
  mv   s2, s11
  addi sp, sp, -64
  sd   s2, 16(sp)
  li   s2, 9
  ld   s2, 16(sp)
  addi sp, sp, 64
  li   t0, -4
  sw   t0, 0(s2)
  bne  s2, s11, fail
  lw   t1, 0(s11)
  bgez t1, fail

  # D: thrash 32x with dual-issue-ish neighbors
  li   s4, 32
1:
  li   s1, 0x1111
  li   s3, 0x2222
  mv   a4, s1
  mv   a5, s3
  addi s11, sp, -32
  li   s2, 0x80012b2a
  mv   s2, s11
  addi sp, sp, -64
  sd   ra, 40(sp)
  sd   s2, 16(sp)
  li   s2, 9
  ld   s2, 16(sp)
  ld   ra, 40(sp)
  addi sp, sp, 64
  bne  s2, s11, fail
  li   t0, 5
  sw   t0, 0(s2)
  lw   t1, 0(s11)
  bne  t1, t0, fail

  addi s11, sp, -36
  li   s2, 0x80012b2a
  mv   s2, s11
  addi sp, sp, -64
  sd   s2, 16(sp)
  li   s2, 0
  ld   s2, 16(sp)
  addi sp, sp, 64
  li   t0, -4
  sw   t0, 0(s2)
  bne  s2, s11, fail
  lw   t1, 0(s11)
  bgez t1, fail

  addi s4, s4, -1
  bnez s4, 1b

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

trap:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

fail:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
4: j    4b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
