# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# TRACE 2026-08-24: 2nd fdt_next_tag `ld s3,24(sp)` retired 0x12b2a because
# check_node's 32B frame aliases 1st `sd ra,56(sp)` onto that slot.
# Existing mini_fdt_namelen_walk issues BOTH next_tag calls *inside*
# check_node (same SP) — no 32B offset. mini_stq_flush_fwd uses two 32B
# frames. This mini matches stock: 64B next_tag nested in 32B check_node,
# return, then a second 64B next_tag from namelen SP.
#
# tohost (odd => TB exit=value>>1):
#   1  SUCCESS
#   3  P0 short: s3 got 1st-call ra
#   5  P0 short: s2 clobber
#   7  P1 delay: s3 got 1st-call ra
#   9  P1 delay: s2 clobber
#   11 P2 jr a5: s3 got 1st-call ra
#   13 P2 jr a5: s2 clobber
#   25 trap
#

  .option rvc
  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  jal  namelen_p0
  jal  namelen_p1
  jal  namelen_p2

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

# ---- shared 32B check_node: one 64B next_tag, then return ----
check_node:
  addi sp, sp, -32
  sd   s0, 16(sp)
  sd   ra, 24(sp)
  addi s0, sp, 32
  addi a2, s0, -20
  sw   zero, -20(s0)
  mv   a0, s2
  li   a1, 0
  jal  next_tag
  ld   ra, 24(sp)
  ld   s0, 16(sp)
  addi sp, sp, 32
  ret

# P0: alias only (no delay, no jr).
namelen_p0:
  addi sp, sp, -16
  sd   ra, 8(sp)
  li   s2, 0x11111111
  li   s3, 0x22222222
  jal  check_node
  li   t0, 0x11111111
  bne  s2, t0, fail3
  li   t0, 0x22222222
  bne  s3, t0, fail3
  addi a2, sp, 0
  sw   zero, 0(a2)
  mv   a0, s2
  li   a1, 0
  li   a7, 0                 # phase: short
  jal  next_tag
  li   t0, 0x11111111
  bne  s2, t0, fail5
  li   t0, 0x22222222
  bne  s3, t0, fail3
  ld   ra, 8(sp)
  addi sp, sp, 16
  ret

# P1: 400 dummy loads between 2nd prologue and restore (STQ drain / D$).
namelen_p1:
  addi sp, sp, -16
  sd   ra, 8(sp)
  li   s2, 0x11111111
  li   s3, 0x22222222
  jal  check_node
  addi a2, sp, 0
  sw   zero, 0(a2)
  mv   a0, s2
  li   a1, 0
  li   a7, 1                 # phase: delay
  jal  next_tag
  li   t0, 0x11111111
  bne  s2, t0, fail9
  li   t0, 0x22222222
  bne  s3, t0, fail7
  ld   ra, 8(sp)
  addi sp, sp, 16
  ret

# P2: jr a5 jump table (stock fdt_next_tag PROP path).
namelen_p2:
  addi sp, sp, -16
  sd   ra, 8(sp)
  li   s2, 0x11111111
  li   s3, 0x22222222
  jal  check_node
  addi a2, sp, 0
  sw   zero, 0(a2)
  mv   a0, s2
  li   a1, 0
  li   a7, 2                 # phase: jr
  jal  next_tag
  li   t0, 0x11111111
  bne  s2, t0, fail13
  li   t0, 0x22222222
  bne  s3, t0, fail11
  ld   ra, 8(sp)
  addi sp, sp, 16
  ret

# Stock 64B layout: s5@8 s4@16 s3@24 s2@32 s0@48 ra@56.
# a7 selects extra work between save and restore.
next_tag:
  addi sp, sp, -64
  sd   s0, 48(sp)
  sd   s3, 24(sp)
  sd   s4, 16(sp)
  sd   s5, 8(sp)
  sd   ra, 56(sp)
  sd   s2, 32(sp)
  li   s2, 3                 # working tag = PROP
  li   s3, 9
  beqz a7, nt_restore
  li   t0, 1
  beq  a7, t0, nt_delay
  # a7==2: auipc+lw+jr a5 (stock 12a36..12a48)
  lla   a4, jtab
  li    a5, 3
  slli  a5, a5, 2
  add   a5, a5, a4
  lw    a5, 0(a5)
  add   a5, a5, a4
  jr    a5

nt_delay:
  li   t2, 400
2:
  lw   t3, 48(sp)
  addi t2, t2, -1
  bnez t2, 2b
  j    nt_restore

nt_prop:
  # PROP handler: a few loads then restore (stock gap jr→epilogue).
  lw   t3, 48(sp)
  lw   t3, 32(sp)
  j    nt_restore

nt_restore:
  ld   s2, 32(sp)
  ld   ra, 56(sp)
  ld   s0, 48(sp)
  ld   s3, 24(sp)
  ld   s4, 16(sp)
  ld   s5, 8(sp)
  addi sp, sp, 64
  ret

  .align 2
jtab:
  .word nt_restore - jtab    # 0
  .word nt_restore - jtab    # 1 BEGIN_NODE
  .word nt_restore - jtab    # 2
  .word nt_prop - jtab       # 3 PROP
  .word nt_restore - jtab    # 4
  .word nt_restore - jtab    # 5
  .word nt_restore - jtab    # 6
  .word nt_restore - jtab    # 7
  .word nt_restore - jtab    # 8
  .word nt_restore - jtab    # 9 END

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
fail11:
  li   a0, 11
  j    fail_exit
fail13:
  li   a0, 13
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

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
