# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S1: 32B check_node / 64B next_tag nest (b1-frame32 PASS) + stock
# offset_ptr 16B + 4xlbu tag (not lw/srliw — that path took nt_end) +
# BEGIN_NODE "cpus" per-byte jal offset_ptr (stock 12a4a) + PROP 2nd call
# from namelen SP. Combined OpenSBI 1st call is named BEGIN_NODE; empty
# name (b1-nt-stock) was green.
#
# tohost (odd => TB exit=value>>1):
#   1  SUCCESS
#   3  s3 clobber after 2nd next_tag (pin class)
#   5  s2 clobber after 2nd next_tag
#   7  s2/s3 lost across check_node
#   9  bad tag
#   25 trap
#

  .option rvc
  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0
  jal  namelen
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

namelen:
  addi sp, sp, -16
  sd   ra, 8(sp)
  la   s2, fdt_blob
  la   s3, lenp
  sw   zero, 0(s3)
  jal  check_node
  la   t0, fdt_blob
  bne  s2, t0, fail7
  la   t0, lenp
  bne  s3, t0, fail7
  la   a0, fdt_blob
  li   a1, 12                # PROP after BEGIN_NODE + "cpus\0" pad
  la   a2, nextoff
  sw   zero, 0(a2)
  jal  next_tag
  li   t0, 3
  bne  a0, t0, fail9
  la   t0, fdt_blob
  bne  s2, t0, fail5
  la   t0, lenp
  bne  s3, t0, fail3
  ld   ra, 8(sp)
  addi sp, sp, 16
  ret

check_node:
  addi sp, sp, -32
  sd   s0, 16(sp)
  sd   ra, 24(sp)
  addi s0, sp, 32
  sw   zero, -20(s0)
  mv   a0, s2
  li   a1, 0
  addi a2, s0, -20
  jal  next_tag
  li   t0, 1
  bne  a0, t0, fail9
  ld   ra, 24(sp)
  ld   s0, 16(sp)
  addi sp, sp, 32
  ret

offset_ptr:
  addi sp, sp, -16
  sd   s0, 0(sp)
  sd   ra, 8(sp)
  lbu  t0, 4(a0)
  lbu  t1, 8(a0)
  lbu  t4, 9(a0)
  add  a0, a0, a1
  ld   ra, 8(sp)
  ld   s0, 0(sp)
  addi sp, sp, 16
  ret

# 4xlbu tag (mini_fdt_next_tag_lbu). No jr/jtab.
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
  li   a2, 4
  jal  offset_ptr
  beqz a0, nt_fail
  sd   s1, 40(sp)
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
  addi s1, s5, 4
  li   t0, 1
  beq  s2, t0, nt_begin
  li   t0, 3
  beq  s2, t0, nt_prop
  j    nt_end

nt_begin:
  li   t3, 64
2:
  beqz t3, nt_pad
  mv   a0, s4
  mv   a1, s1
  li   a2, 1
  jal  offset_ptr
  beqz a0, nt_pad
  lbu  a5, 0(a0)
  addi s1, s1, 1
  addi t3, t3, -1
  bnez a5, 2b
nt_pad:
  addi s1, s1, 3
  andi s1, s1, -4
  sw   s1, 0(s3)
  ld   s1, 40(sp)
  j    nt_restore

nt_prop:
  mv   a0, s4
  mv   a1, s5
  li   a2, 4
  jal  offset_ptr
  addi s1, s1, 3
  andi s1, s1, -4
  sw   s1, 0(s3)
  ld   s1, 40(sp)
  j    nt_restore

nt_end:
  li   s2, 9
nt_fail:
nt_restore:
  ld   ra, 56(sp)
  ld   s0, 48(sp)
  ld   s3, 24(sp)
  ld   s4, 16(sp)
  ld   s5, 8(sp)
  mv   a0, s2
  ld   s2, 32(sp)
  addi sp, sp, 64
  ret

fail3:
  li   a0, 3
  j    fail_exit
fail5:
  li   a0, 5
  j    fail_exit
fail7:
  li   a0, 7
  j    fail_exit
fail9:
  li   a0, 9
  j    fail_exit
fail_exit:
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

trap:
  li   a0, 25
  la   t0, tohost
  sw   a0, 0(t0)
4: j    4b

# Same page as code (namelen_walk). BEGIN_NODE "cpus" + pad, PROP at +12.
  .align 3
fdt_blob:
  .byte 0x00, 0x00, 0x00, 0x01
  .asciz "cpus"
  .byte 0x00, 0x00, 0x00
  .byte 0x00, 0x00, 0x00, 0x03
  .byte 0x00, 0x00, 0x00, 0x00
  .byte 0x00, 0x00, 0x00, 0x00
  .byte 0x00, 0x00, 0x00, 0x09

  .section .data
  .align 3
lenp:
  .word 0
nextoff:
  .word 0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
