# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Combined FDT walk (I4cc): namelen_ keeps s2=fdt / s3=lenp across
# check_node -> natural next_tag (4xlbu + name-skip bnez), then by_offset
# `c.mv s2,a2; sw a0,0(s2)` with no extra refresh. Existing minis either
# c.mv before the store or omit the namelen live-s3 window.
#
# tohost (odd => TB exit=value>>1):
#   1 SUCCESS
#   5/7  one next_tag lost s2/s3
#   9/11 namelen s2/s3 after check_node
#   13   c.mv s2,a2 did not stick
#   15   sw missed lenp
#   17   thrash
#   25   trap (s2/s3 was code residue — historic 0x12b2a class)
#

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  # ---- P0: one next_tag preserves caller s2/s3 ----
  # nextoff must not sit at 56(sp) of a 64-byte next_tag frame (that is ra).
  addi sp, sp, -16
  li   s2, 0x11111111
  li   s3, 0x22222222
  la   a0, fdt_blob
  li   a1, 0
  mv   a2, sp
  sw   zero, 0(a2)
  jal  next_tag
  li   t0, 0x11111111
  bne  s2, t0, fail5
  li   t0, 0x22222222
  bne  s3, t0, fail7
  addi sp, sp, 16

  # ---- P1: namelen live s2/s3 across check_node, then by_offset store ----
  addi sp, sp, -16
  la   s2, fdt_blob
  mv   s3, sp
  li   t0, 0xdeadbeef
  sw   t0, 0(s3)
  li   s5, 0
  jal  check_node
  la   t0, fdt_blob
  bne  s2, t0, fail9
  mv   t1, sp
  bne  s3, t1, fail11
  mv   a2, s3
  c.mv s2, a2
  bne  s2, a2, fail13
  li   a0, -4
  sw   a0, 0(s2)
  lw   t1, 0(s3)
  li   t2, -4
  bne  t1, t2, fail15

  # ---- P2: thrash — BHT period change inside next_tag name skip ----
  li   s4, 32
1:
  la   s2, fdt_blob
  mv   s3, sp
  li   t0, 0x0badf00d
  sw   t0, 0(s3)
  addi s5, s5, 1
  jal  check_node
  la   t0, fdt_blob
  bne  s2, t0, fail17
  mv   t1, sp
  bne  s3, t1, fail17
  mv   a2, s3
  c.mv s2, a2
  bne  s2, s3, fail17
  li   a0, -11
  sw   a0, 0(s2)
  lw   t1, 0(s3)
  li   t2, -11
  bne  t1, t2, fail17
  addi s4, s4, -1
  bnez s4, 1b

  addi sp, sp, 16
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

# namelen's check_node: two natural next_tag calls (BEGIN_NODE then PROP).
check_node:
  addi sp, sp, -32
  sd   s0, 16(sp)
  sd   ra, 24(sp)
  addi s0, sp, 32
  mv   a0, s2
  li   a1, 0
  addi a2, s0, -20
  jal  next_tag
  mv   a0, s2
  lw   a1, -20(s0)
  addi a2, s0, -20
  jal  next_tag
  ld   ra, 24(sp)
  ld   s0, 16(sp)
  addi sp, sp, 32
  ret

# OpenSBI fdt_next_tag shape: s3@24 s2@32 ra@56; 4xlbu tag; BEGIN_NODE name skip.
next_tag:
  addi sp, sp, -64
  sd   s0, 48(sp)
  sd   s3, 24(sp)
  sd   s4, 16(sp)
  sd   s5, 8(sp)
  sd   ra, 56(sp)
  sd   s2, 32(sp)
  mv   s3, a2
  li   a5, -8
  sw   a5, 0(a2)
  mv   s4, a0
  mv   s5, a1
  add  a0, s4, s5
  lbu  a3, 0(a0)
  lbu  a4, 1(a0)
  lbu  a5, 2(a0)
  lbu  a6, 3(a0)
  slli a3, a3, 24
  slli a4, a4, 16
  slli a5, a5, 8
  or   s2, a3, a4
  or   s2, s2, a5
  or   s2, s2, a6
  addi a1, s5, 4
  # BEGIN_NODE (1): skip name bytes. Cap 64 so a missing NUL cannot spin.
  li   t1, 1
  bne  s2, t1, 4f
  add  a0, s4, a1
  li   t2, 64
3:
  beqz t2, 4f
  lbu  t0, 0(a0)
  addi a0, a0, 1
  addi a1, a1, 1
  addi t2, t2, -1
  bnez t0, 3b
  addi a1, a1, 3
  andi a1, a1, -4
4:
  # mispredicting branch (stq_flush_fwd period) between work and restore
  andi t0, s5, 3
  beqz t0, 5f
  lw   t1, 32(sp)
  add  t1, t1, t0
5:
  andi t0, s5, 1
  bnez t0, 6f
  c.nop
6:
  sw   a1, 0(s3)
  mv   a0, s2
  ld   s2, 32(sp)
  ld   ra, 56(sp)
  ld   s0, 48(sp)
  ld   s3, 24(sp)
  ld   s4, 16(sp)
  ld   s5, 8(sp)
  addi sp, sp, 64
  ret

fail5:
  li   a0, 5
  j    fail_exit
fail7:
  li   a0, 7
  j    fail_exit
fail9:
  addi sp, sp, 16
  li   a0, 9
  j    fail_exit
fail11:
  addi sp, sp, 16
  li   a0, 11
  j    fail_exit
fail13:
  addi sp, sp, 16
  li   a0, 13
  j    fail_exit
fail15:
  addi sp, sp, 16
  li   a0, 15
  j    fail_exit
fail17:
  addi sp, sp, 16
  li   a0, 17
  j    fail_exit
fail_exit:
  la   t0, tohost
  sw   a0, 0(t0)
7: j    7b

trap:
  li   a0, 25
  la   t0, tohost
  sw   a0, 0(t0)
8: j    8b

  .align 3
# Keep the blob in .text so Spike/Variane share one DRAM page with the code.
# BEGIN_NODE "cpus" + pad, PROP, END
fdt_blob:
  .byte 0x00, 0x00, 0x00, 0x01
  .asciz "cpus"
  .byte 0x00, 0x00, 0x00
  .byte 0x00, 0x00, 0x00, 0x03
  .byte 0x00, 0x00, 0x00, 0x00
  .byte 0x00, 0x00, 0x00, 0x00
  .byte 0x00, 0x00, 0x00, 0x09

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
