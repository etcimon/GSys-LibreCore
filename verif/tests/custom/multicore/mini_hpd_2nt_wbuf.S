# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S4: 8 sd to a scratch line (HPD wbufDirEntries=8) between 2 next_tag,
# no fence. If PASS, filling wbuf drains the 1st frame's stores. If HANG,
# leftover is not wbuf occupancy (FDT-line load replay or other).
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

  li   s2, 0x11111111
  li   s3, 0x22222222
  la   a0, fdt_hdr
  li   a1, 0
  jal  next_tag
  li   t0, 1
  bne  a0, t0, fail9

  la   t0, scratch
  sd   t0, 0(t0)
  sd   t0, 16(t0)
  sd   t0, 32(t0)
  sd   t0, 48(t0)
  sd   t0, 64(t0)
  sd   t0, 80(t0)
  sd   t0, 96(t0)
  sd   t0, 112(t0)

  la   a0, fdt_hdr
  li   a1, 8
  jal  next_tag
  li   t0, 3
  bne  a0, t0, fail9
  li   t0, 0x11111111
  bne  s2, t0, fail5
  li   t0, 0x22222222
  bne  s3, t0, fail3
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

next_tag:
  addi sp, sp, -64
  sd   s0, 48(sp)
  sd   s3, 24(sp)
  sd   s4, 16(sp)
  sd   s5, 8(sp)
  sd   ra, 56(sp)
  sd   s2, 32(sp)
  mv   s4, a0
  mv   s5, a1
  li   a2, 4
  jal  offset_ptr
  beqz a0, nt_fail
  lw   a5, 0(a0)
  srliw s2, a5, 24
  lla  a4, jtab
  slli a5, s2, 2
  add  a5, a5, a4
  lw   a5, 0(a5)
  add  a5, a5, a4
  jr   a5

nt_begin:
  li   s2, 1
  j    nt_restore
nt_prop:
  li   s2, 3
  j    nt_restore
nt_end:
  li   s2, 9
nt_fail:
nt_restore:
  mv   a0, s2
  ld   ra, 56(sp)
  ld   s0, 48(sp)
  ld   s3, 24(sp)
  ld   s4, 16(sp)
  ld   s5, 8(sp)
  ld   s2, 32(sp)
  addi sp, sp, 64
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

  .section .data
  .align 4
scratch:
  .zero 128

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
