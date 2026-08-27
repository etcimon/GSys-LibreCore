# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S4 hang recipe: leftover jal into next_tag-like frame (sds + sd ra),
# then jal+beqz in one 8B window. IQ address-FIFO head of the leftover
# jal must not false-mispredict the inner jal (cancels frame sds;
# beqz retires a0=FDT). tohost 1 PASS; 3 skip; 5 a0; 25 trap.
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

  li   s9, 0
  li   s10, 0
  li   s11, 32
loop:
  jal  chk
  addi s10, s10, 1
  addi s11, s11, -1
  bnez s11, loop
  li   t0, 32
  bne  s10, t0, fail3
  bne  s9, t0, fail5

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

# leftover jal at +6 of an 8B window (stock 12ac6).
chk:
  addi sp, sp, -16
  sd   ra, 8(sp)
  .align 3
  c.nop
  c.nop
  c.nop
  jal  nt
  ld   ra, 8(sp)
  addi sp, sp, 16
  ret

# Stock next_tag packing: frame sds, then jal@0 + c.beqz@+4 of 8B.
nt:
  addi sp, sp, -64
  sd   s0, 48(sp)
  sd   s3, 24(sp)
  sd   s4, 16(sp)
  sd   s5, 8(sp)
  sd   ra, 56(sp)
  .align 3
  jal  cal
  c.beqz a0, nt_bad
  ld   ra, 56(sp)
  ld   s0, 48(sp)
  ld   s3, 24(sp)
  ld   s4, 16(sp)
  ld   s5, 8(sp)
  addi sp, sp, 64
  ret
nt_bad:
  li   a0, 5
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

cal:
  .rept 48
  c.nop
  .endr
  addi s9, s9, 1
  li   a0, 1
  ret

hart1:
  wfi
  j    hart1

fail3:
  li   a0, 3
  j    fail_exit
fail5:
  li   a0, 5
fail_exit:
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

trap:
  li   a0, 25
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
