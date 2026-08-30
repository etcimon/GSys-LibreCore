# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S4: fdt_get_name 80B sd ra,72(sp) + check_node 32B whose c.addi16sp +32
# sits at +8 of a 16B line (stock 0x12ad8). TRACE s4-chksp: sd ra committed
# at 46ec8; ld ra used sp 32B low and loaded s3/FDT at 46ea8. 12ad8 fetched
# but +32 never retired.
#
# tohost (odd => TB exit=value>>1):
#   1  SUCCESS
#   3  P0 packed: ld 72(sp) == MAGIC (s3 slot)
#   7  P0 packed: sp != s0-80 after check_node
#   9  P1 packed+jr: sp leak
#   11 P1 packed+jr: MAGIC in ra slot
#   13 P2 unpacked+jr: sp leak
#   15 P2 unpacked+jr: MAGIC in ra slot
#   25 trap
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

  # P0: packed 12ad0-line epi, next_tag no jr
  li   s3, 0x8001e000
  li   a7, 0
  jal  get_name
  # P1: packed + next_tag jr a5 + stock ret-line tail; 8 calls (subnode)
  li   s5, 8
p1:
  li   s3, 0x8001e000
  li   a7, 1
  jal  get_name
  addi s5, s5, -1
  bnez s5, p1
  # P2: unpacked check_node + jr (frame32-class control)
  li   s3, 0x8001e000
  li   a7, 2
  jal  get_name

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

# 80B get_name: ra@72, s3@40. MAGIC in s3 at entry is the poison.
get_name:
  addi sp, sp, -80
  sd   s0, 64(sp)
  sd   s1, 56(sp)
  sd   s3, 40(sp)
  sd   s4, 32(sp)
  sd   ra, 72(sp)
  sd   s2, 48(sp)
  addi s0, sp, 80
  mv   s4, a7
  jal  check_node
  addi t0, s0, -80
  bne  sp, t0, leak
  ld   t0, 72(sp)
  li   t1, 0x8001e000
  beq  t0, t1, mag
  ld   ra, 72(sp)
  ld   s0, 64(sp)
  ld   s1, 56(sp)
  ld   s3, 40(sp)
  ld   s4, 32(sp)
  ld   s2, 48(sp)
  addi sp, sp, 80
  ret

leak:
  beqz s4, fail7
  li   t0, 1
  beq  s4, t0, fail9
  j    fail13
mag:
  beqz s4, fail3
  li   t0, 1
  beq  s4, t0, fail11
  j    fail15

# a7==2 → unpacked (P2). else stock 12ab0/12ac0 packing:
#   andi at +12 of previous 16B line; bnez/addi/jal/c.li/bne on 12ac0.
check_node:
  addi sp, sp, -32
  sd   s0, 16(sp)
  sd   ra, 24(sp)
  addi s0, sp, 32
  sw   zero, -20(s0)
  li   t0, 2
  beq  a7, t0, chk_unpacked
  li   a1, 0
  .align 4
  c.nop
  c.nop
  c.nop
  c.nop
  c.nop
  c.nop
  andi a5, a1, 3
  bnez a5, chk_fail
  addi a2, s0, -20
  jal  next_tag
  c.li a5, 1
  bne  a0, a5, chk_fail
chk_epi:
  lw   a0, -20(s0)
  ld   ra, 24(sp)
  ld   s0, 16(sp)
  addi sp, sp, 32
  ret
  c.li a0, -4
  j    chk_epi
chk_fail:
  c.li a0, -4
  j    chk_epi

chk_unpacked:
  jal  next_tag
  ld   ra, 24(sp)
  ld   s0, 16(sp)
  addi sp, sp, 32
  ret

# 64B next_tag. a7==0: restore a0=1. else: name-loop jal offset_ptr then jr.
next_tag:
  addi sp, sp, -64
  sd   s0, 48(sp)
  sd   s3, 24(sp)
  sd   s4, 16(sp)
  sd   s5, 8(sp)
  sd   ra, 56(sp)
  sd   s2, 32(sp)
  beqz a7, nt_ok
  li   s5, 32
nt_loop:
  jal  offset_ptr
  addi s5, s5, -1
  bnez s5, nt_loop
  lla  a4, jtab
  li   a5, 3
  slli a5, a5, 2
  add  a5, a5, a4
  lw   a5, 0(a5)
  add  a5, a5, a4
  jr   a5

# 16B offset_ptr (stock jal@129f8 name scan).
offset_ptr:
  addi sp, sp, -16
  sd   ra, 8(sp)
  sd   s0, 0(sp)
  ld   s0, 0(sp)
  ld   ra, 8(sp)
  addi sp, sp, 16
  ret

nt_prop:
  lw   t3, 48(sp)
  j    nt_ok
  # Stock 12a00 line: 16B of restores then 12a10 addi+ret+live tail
  # (li a2,4; jal offset_ptr). Mini PASS without the tail; OpenSBI
  # TRACE skipped 12aca and fetched 12ad0 after this line.
  .align 4
nt_ok:
  li   s2, 1
  ld   ra, 56(sp)
  ld   s0, 48(sp)
  ld   s3, 24(sp)
  ld   s4, 16(sp)
  ld   s5, 8(sp)
  mv   a0, s2
  ld   s2, 32(sp)
  addi sp, sp, 64
  ret
  li   a2, 4
  mv   a1, s5
  mv   a0, s4
  jal  offset_ptr
  beqz a0, nt_ok
  j    nt_ok

  .align 2
jtab:
  .word nt_ok - jtab
  .word nt_ok - jtab
  .word nt_ok - jtab
  .word nt_prop - jtab
  .word nt_ok - jtab
  .word nt_ok - jtab
  .word nt_ok - jtab
  .word nt_ok - jtab
  .word nt_ok - jtab
  .word nt_ok - jtab

hart1:
  wfi
  j    hart1

fail3:
  li   a0, 3
  j    fail_exit
fail7:
  li   a0, 7
  j    fail_exit
fail9:
  li   a0, 9
  j    fail_exit
fail11:
  li   a0, 11
  j    fail_exit
fail13:
  li   a0, 13
  j    fail_exit
fail15:
  li   a0, 15
fail_exit:
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

trap:
  li   a0, 25
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
