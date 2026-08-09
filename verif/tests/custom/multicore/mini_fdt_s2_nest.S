# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Soft-ladder iter-012: nest next_tag-shaped s2 save/restore then by_offset_
# fail-path store. Catches callee-saved s2 clobber across jal (hang-6 family).
# tohost=1 pass, 3 fail.
#

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  # --- Phase A: next_tag-shaped s2 save/restore ---
  li   s2, 0x11111111        # incoming callee-saved value
  addi sp, sp, -64
  sd   s0, 48(sp)
  sd   s2, 32(sp)            # save like fdt_next_tag
  sd   ra, 56(sp)
  li   s2, 9                 # clobber working s2 (tag)
  # dual-issue-ish neighbors
  li   a0, 1
  li   a1, 2
  add  a0, a0, a1
  ld   s2, 32(sp)            # restore
  ld   ra, 56(sp)
  ld   s0, 48(sp)
  addi sp, sp, 64
  li   t0, 0x11111111
  bne  s2, t0, fail

  # --- Phase B: by_offset_ shape with nested jal that clobbers s2 ---
  addi a2, sp, -20           # lenp on stack
  li   t0, 0xdeadbeef
  sw   t0, 0(a2)
  # poison s2 then mv from a2 (must stick)
  li   s2, 0x80012b2a
  c.mv s2, a2
  # call nested that saves/restores s2 like next_tag
  jal  nest_clobber_s2
  # fail-path store (sw a0,0(s2))
  li   a0, -4
  beqz s2, fail
  sw   a0, 0(s2)
  lw   t1, 0(a2)
  li   t2, -4
  bne  t1, t2, fail
  bne  s2, a2, fail

  # --- Phase C: thrash nest 32x ---
  li   s4, 32
1:
  addi a2, sp, -24
  li   s2, 0x80012b2a
  c.mv s2, a2
  jal  nest_clobber_s2
  li   a0, -11
  sw   a0, 0(s2)
  lw   t1, 0(a2)
  li   t2, -11
  bne  t1, t2, fail
  bne  s2, a2, fail
  addi s4, s4, -1
  bnez s4, 1b

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

# Callee: clobber s2, must restore (next_tag shape)
nest_clobber_s2:
  addi sp, sp, -64
  sd   s2, 32(sp)
  sd   ra, 56(sp)
  li   s2, 9
  # work that looks like load/or chain
  li   a5, 0x01020304
  srliw s2, a5, 24
  slli  a1, a5, 8
  or    s2, s2, a1
  li   s2, 9
  ld   s2, 32(sp)
  ld   ra, 56(sp)
  addi sp, sp, 64
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
