# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S4 HPD bisect: one stock offset_ptr (16B + 6 header lbu + ld ra) then
# frame32 P2 jtab c.lw+jr. frame32 P2 (jtab only) PASSES; stock hangs on
# the 2nd next_tag's jtab lw after offset_ptr. One pair isolates poison.
#
# tohost: 1 PASS; 3 s3; 5 s2; 9 bad jtab; 25 trap
#

  .option rvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, hart1
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  la   a0, fdt_hdr
  li   a1, 8
  jal  offset_ptr
  la   t0, fdt_hdr
  addi t0, t0, 8
  bne  a0, t0, fail9

  li   s2, 0x11111111
  li   s3, 0x22222222
  lla  a4, jtab
  li   a5, 3
  slli a5, a5, 2
  add  a5, a5, a4
  lw   a5, 0(a5)
  add  a5, a5, a4
  jr   a5

nt_prop:
  li   t0, 0x11111111
  bne  s2, t0, fail5
  li   t0, 0x22222222
  bne  s3, t0, fail3
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

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

  .align 2
jtab:
  .word nt_prop - jtab
  .word nt_prop - jtab
  .word nt_prop - jtab
  .word nt_prop - jtab
  .word nt_prop - jtab
  .word nt_prop - jtab
  .word nt_prop - jtab
  .word nt_prop - jtab
  .word nt_prop - jtab
  .word nt_prop - jtab

hart1:
  wfi
  j    hart1

fail3:
  li   a0, 3
  j    fail_exit
fail5:
  li   a0, 5
  j    fail_exit
fail9:
  li   a0, 9
fail_exit:
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

trap:
  li   a0, 25
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

  .section .rodata
  .align 3
fdt_hdr:
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
