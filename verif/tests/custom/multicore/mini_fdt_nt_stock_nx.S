# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S4: stock next_tag with FDT at 0x80020000 (cached, non-execute).
# OpenSBI .rodata/FDT starts 0x8001e000, outside execute 0x1e000.
# mini_fdt_nt_stock places fdt_hdr at 0x80001048 inside execute, so
# execute-region D$ uncached also uncached the FDT lbus. If this PASS
# and stock still HANG @140, the residual is uncached FDT lbu not jtab.

  .option rvc
  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  la   t0, fdt_src
  li   t1, 0x80020000
  li   t2, 36
1: lb   t3, 0(t0)
  sb   t3, 0(t1)
  addi t0, t0, 1
  addi t1, t1, 1
  addi t2, t2, -1
  bnez t2, 1b

  jal  namelen

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

namelen:
  addi sp, sp, -16
  sd   ra, 8(sp)
  li   s2, 0x80020000
  la   s3, lenp
  sw   zero, 0(s3)
  jal  check_node
  li   t0, 0x80020000
  bne  s2, t0, fail7
  la   t0, lenp
  bne  s3, t0, fail7
  li   a0, 0x80020000
  li   a1, 8
  la   a2, nextoff
  sw   zero, 0(a2)
  jal  next_tag
  li   t0, 3
  bne  a0, t0, fail9
  li   t0, 0x80020000
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
  lbu  t2, 9(a0)
  lbu  t3, 10(a0)
  lbu  t4, 11(a0)
  lbu  t5, 20(a0)
  add  a0, a0, a1
  ld   ra, 8(sp)
  ld   s0, 0(sp)
  addi sp, sp, 16
  ret

next_tag:
  addi sp, sp, -64
  sd   s0, 48(sp)
  sd   s3, 24(sp)
  sd   s4, 16(sp)
  sd   s5, 8(sp)
  sd   ra, 56(sp)
  sd   s2, 32(sp)
  addi s0, sp, 64
  mv   s3, a2
  li   a5, -8
  sw   a5, 0(a2)
  li   a2, 4
  mv   s4, a0
  mv   s5, a1
  jal  offset_ptr
  beqz a0, nt_fail
  sd   s1, 40(sp)
  lw   a5, 0(a0)
  srliw s2, a5, 24
  li   a5, -11
  sw   a5, 0(s3)
  addi s1, s5, 4
  li   a5, 9
  bgeu s2, a5, nt_end
  lla  a4, jtab
  slli a5, s2, 2
  add  a5, a5, a4
  lw   a5, 0(a5)
  add  a5, a5, a4
  jr   a5

nt_begin:
  addi a0, a0, 4
  lbu  a5, 0(a0)
  bnez a5, nt_pad
nt_pad:
  li   a2, 4
  mv   a1, s5
  mv   a0, s4
  jal  offset_ptr
  addi s1, s1, 3
  andi s1, s1, -4
  sw   s1, 0(s3)
  ld   s1, 40(sp)
  j    nt_restore

nt_prop:
  li   a2, 4
  mv   a1, s5
  mv   a0, s4
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

  .align 2
jtab:
  .word nt_end - jtab
  .word nt_begin - jtab
  .word nt_end - jtab
  .word nt_prop - jtab
  .word nt_end - jtab
  .word nt_end - jtab
  .word nt_end - jtab
  .word nt_end - jtab
  .word nt_end - jtab
  .word nt_end - jtab

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
fail_exit:
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

trap:
  li   a0, 25
  la   t0, tohost
  sw   a0, 0(t0)
4: j    4b

  .section .data
  .align 3
lenp:
  .word 0
nextoff:
  .word 0
fdt_src:
  .byte 0x00, 0x00, 0x00, 0x01
  .byte 0x00, 0x00, 0x00, 0x00
  .byte 0x00, 0x00, 0x00, 0x03
  .byte 0x00, 0x00, 0x00, 0x00
  .byte 0x00, 0x00, 0x00, 0x00
  .byte 0x00, 0x00, 0x00, 0x09
  .byte 0x00, 0x00, 0x00, 0x00
  .byte 0x00, 0x00, 0x00, 0x00
  .byte 0x00, 0x00, 0x00, 0x00

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
