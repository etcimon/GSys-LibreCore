# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Soft-ladder iter-012: nest check_node/check_prop + next_tag shape then
# by_offset_ fail-path sw a0,0(s2). After PEEL bisects (dual-commit, STQ-nofwd,
# force SI, ALU-cancel-exempt) all failed OpenSBI, this mini forces the
# call/stack shape without a real FDT blob.
#
# Shape:
#   1) next_tag-like: save s2/s3/ra, clobber, restore
#   2) check_node-like: sw offset, jal next_tag-like, li a5,1 (ra pattern)
#   3) by_offset_: c.mv s2,a2 (lenp), jal check_prop-like (returns -4),
#      sw a0,0(s2) must hit stack
#
# tohost=1 pass, 3 fail/trap. No git commit required.
#

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  # --- Prior next_tag-like (may leave ra-like residue in temps) ---
  li   s2, 0xaaaaaaaa
  li   s3, 0xbbbbbbbb
  jal  next_tag_like

  # --- check_node-like: create ra = return after jal next_tag_like ---
  addi sp, sp, -32
  sd   s0, 16(sp)
  sd   ra, 24(sp)
  addi s0, sp, 32
  li   a1, 0x38
  sw   a1, -20(s0)
  addi a2, s0, -20
  jal  next_tag_like
  # ^^^ after return, ra was here (like 0x12b2a pattern relative)
  li   a5, 1
  ld   ra, 24(sp)
  ld   s0, 16(sp)
  addi sp, sp, 32

  # --- by_offset_ fail path ---
  # poison s2 with the historic bad value, then c.mv from stack lenp
  li   s2, 0x80012b2a
  addi a2, sp, -20
  li   t0, 0xdeadbeef
  sw   t0, 0(a2)
  c.mv s2, a2
  # nest: check_prop-like returns -4 and clobbers s2 working via next_tag_like
  jal  check_prop_like
  # a0 should be -4; s2 must still be lenp
  li   t0, -4
  bne  a0, t0, fail
  beqz s2, fail
  sw   a0, 0(s2)
  lw   t1, 0(a2)
  bne  t1, t0, fail
  bne  s2, a2, fail

  # thrash 16x with poison between
  li   s4, 16
1:
  li   s2, 0x80012b2a
  addi a2, sp, -24
  c.mv s2, a2
  jal  check_prop_like
  li   a0, -4
  sw   a0, 0(s2)
  lw   t1, 0(a2)
  li   t2, -4
  bne  t1, t2, fail
  bne  s2, a2, fail
  addi s4, s4, -1
  bnez s4, 1b

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

# next_tag-like: save/restore s2,s3,ra; clobber s2 as tag work
next_tag_like:
  addi sp, sp, -64
  sd   s0, 48(sp)
  sd   s3, 24(sp)
  sd   ra, 56(sp)
  sd   s2, 32(sp)
  mv   s3, a2
  li   a5, -8
  # only store if a2 looks like a pointer in stack window
  li   t0, 0x80000000
  bltu a2, t0, 1f
  sw   a5, 0(a2)
1:
  li   s2, 9
  srliw s2, s2, 0
  li   s2, 3
  ld   s2, 32(sp)
  ld   ra, 56(sp)
  ld   s0, 48(sp)
  ld   s3, 24(sp)
  addi sp, sp, 64
  ret

# check_prop-like: returns -4; calls next_tag_like with stack nextoff
check_prop_like:
  addi sp, sp, -32
  sd   s0, 16(sp)
  sd   ra, 24(sp)
  addi s0, sp, 32
  li   a1, 0x10
  sw   a1, -20(s0)
  addi a2, s0, -20
  jal  next_tag_like
  li   a0, -4
  ld   ra, 24(sp)
  ld   s0, 16(sp)
  addi sp, sp, 32
  ret

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
