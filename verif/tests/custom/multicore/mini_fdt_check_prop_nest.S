# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Soft-ladder iter-012 directed residual: OpenSBI-shaped check_node / next_tag /
# by_offset_ fail path under dual-issue (g6lc64_smt2 / work-ver-smt2-fw64).
#
# PEEL pin class: mepc=0x12eb2 sw a0,0(s2) mcause=6 mtval=0x12b2a when s2 is
# ra-residue (misaligned code addr) instead of stack lenp.
#
# Diagnostic tohost (odd → TB exit=value>>1):
#   1 SUCCESS
#   5 A s2; 7 A s3
#   9 B s2; 11 B s3
#   13 C after c.mv s2!=a2; 15 C after jal s2 bad; 17 C a0; 19 C mem
#   21 D
#   25 trap (see dump @0x80009000: mepc,mcause,mtval,s2,a2,s3,sp,ra)
#

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  # ------------------------------------------------------------------
  # Phase A: bare next_tag-like preserves caller s2/s3
  # ------------------------------------------------------------------
  li   s2, 0xaaaaaaaa
  li   s3, 0xbbbbbbbb
  addi a2, sp, -16
  sw   zero, 0(a2)
  jal  next_tag_like
  li   t0, 0xaaaaaaaa
  bne  s2, t0, fail_a_s2
  li   t0, 0xbbbbbbbb
  bne  s3, t0, fail_a_s3

  # ------------------------------------------------------------------
  # Phase B: check_node-like; namelen s2=fdt s3=lenp survive next_tag
  # ------------------------------------------------------------------
  addi sp, sp, -16             # outer: [0]=lenp word, [8]=fdt cookie
  li   s2, 0x8001e000
  sd   s2, 8(sp)
  mv   s3, sp                  # s3 = &lenp
  li   t0, 0xdeadbeef
  sw   t0, 0(s3)

  addi sp, sp, -32             # check_node frame
  sd   s0, 16(sp)
  sd   ra, 24(sp)
  addi s0, sp, 32
  li   a1, 0x38
  sw   a1, -20(s0)
  addi a2, s0, -20
  mv   a0, s2
  jal  next_tag_like
  li   a5, 1
  li   t0, 0x8001e000
  bne  s2, t0, fail_b_s2
  addi t1, sp, 32              # outer base
  bne  s3, t1, fail_b_s3
  ld   ra, 24(sp)
  ld   s0, 16(sp)
  addi sp, sp, 32

  # ------------------------------------------------------------------
  # Phase C: poison s2 with ra residue, c.mv fix, nest, fail-path store
  # ------------------------------------------------------------------
  ld   t3, 8(sp)               # fdt cookie (unused after)
  mv   a2, s3
  li   t1, 0x80012b2a          # historic mtval / check_node jal ra
  mv   s2, t1
  c.mv s2, a2                  # must stick before nest
  bne  s2, a2, fail_c_cmv

  jal  check_prop_like
  # check_prop clobbers a2 (nextoff); lenp truth is s3. s2 must still == s3.
  bne  s2, s3, fail_c_after
  li   t0, -4
  bne  a0, t0, fail_c_a0
  # fail-path store (OpenSBI 0x12eb2). If s2 still 0x12b2a → mcause=6 trap.
  sw   a0, 0(s2)
  lw   t1, 0(s3)
  bne  t1, t0, fail_c_mem

  # ------------------------------------------------------------------
  # Phase D: thrash
  # ------------------------------------------------------------------
  li   s4, 16
1:
  li   t1, 0x80012b2a
  mv   s2, t1
  c.mv s2, s3
  bne  s2, s3, fail_d
  jal  check_prop_like
  bne  s2, s3, fail_d
  li   a0, -4
  sw   a0, 0(s2)
  lw   t1, 0(s3)
  li   t2, -4
  bne  t1, t2, fail_d
  addi s4, s4, -1
  bnez s4, 1b

  addi sp, sp, 16
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

# next_tag-like — OpenSBI fdt_next_tag save/restore shape (no FDT loads)
next_tag_like:
  addi sp, sp, -64
  sd   s0, 48(sp)
  sd   s3, 24(sp)
  sd   ra, 56(sp)
  sd   s2, 32(sp)
  mv   s3, a2
  li   a5, -8
  li   t0, 0x80000000
  bltu a2, t0, 1f
  li   t0, 0x88000000
  bgeu a2, t0, 1f
  sw   a5, 0(a2)
1:
  li   s2, 9
  li   a5, 0x01020304
  srliw t1, a5, 24
  slli  t2, a5, 8
  or    s2, t1, t2
  li   s2, 3
  ld   s2, 32(sp)
  ld   ra, 56(sp)
  ld   s0, 48(sp)
  ld   s3, 24(sp)
  addi sp, sp, 64
  ret

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

fail_a_s2:
  li   a0, 5
  j    fail_exit
fail_a_s3:
  li   a0, 7
  j    fail_exit
fail_b_s2:
  ld   ra, 24(sp)
  ld   s0, 16(sp)
  addi sp, sp, 48
  li   a0, 9
  j    fail_exit
fail_b_s3:
  ld   ra, 24(sp)
  ld   s0, 16(sp)
  addi sp, sp, 48
  li   a0, 11
  j    fail_exit
fail_c_cmv:
  addi sp, sp, 16
  li   a0, 13
  j    fail_exit
fail_c_after:
  addi sp, sp, 16
  li   a0, 15
  j    fail_exit
fail_c_a0:
  addi sp, sp, 16
  li   a0, 17
  j    fail_exit
fail_c_mem:
  addi sp, sp, 16
  li   a0, 19
  j    fail_exit
fail_d:
  addi sp, sp, 16
  li   a0, 21
  j    fail_exit

# Trap: dump GPRs/CSRs to 0x80009000 then tohost=25 (TB exit 12)
trap:
  li   t0, 0x80009000
  csrr t1, mepc
  sd   t1, 0(t0)
  csrr t1, mcause
  sd   t1, 8(t0)
  csrr t1, mtval
  sd   t1, 16(t0)
  sd   s2, 24(t0)
  sd   a2, 32(t0)
  sd   s3, 40(t0)
  sd   sp, 48(t0)
  sd   ra, 56(t0)
  li   a0, 25
  j    fail_exit

fail_exit:
  la   t0, tohost
  sw   a0, 0(t0)
5: j    5b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
