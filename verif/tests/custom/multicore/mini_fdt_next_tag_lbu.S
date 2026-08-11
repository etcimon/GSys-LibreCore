# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Soft-ladder iter-012 P1: OpenSBI fdt_next_tag **structure-load** shape.
# Stack-only nests PASS; PEEL pin needs multi-lbu + shift/or tag assemble under DI.
#
# Implements a stripped next_tag over a tiny in-image FDT structure:
#   [FDT_BEGIN_NODE=1]["" pad][FDT_PROP=3][len][nameoff][data…][FDT_END=9]
# Callee saves s2/s3 like OpenSBI; caller holds s2=fdt s3=lenp across check_node-like.
#
# tohost=1 pass, 3 fail.
#

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  # Outer: s2 = fdt base, s3 = &lenp
  addi sp, sp, -32
  la   s2, fdt_struct
  addi s3, sp, 0
  sw   zero, 0(s3)

  # check_node-like: jal next_tag_lbu with nextoff on stack
  addi sp, sp, -32
  sd   s0, 16(sp)
  sd   ra, 24(sp)
  addi s0, sp, 32
  li   a1, 0                   # start offset 0
  sw   a1, -20(s0)
  addi a2, s0, -20             # &nextoff
  mv   a0, s2                  # fdt
  mv   a1, a1                  # offset
  jal  next_tag_lbu
  # expect BEGIN_NODE (1)
  li   t0, 1
  bne  a0, t0, fail_pop
  # s2/s3 must still be fdt / lenp (PEEL failure mode if s3==ra residue)
  la   t0, fdt_struct
  bne  s2, t0, fail_pop
  addi t1, sp, 32
  bne  s3, t1, fail_pop

  # second tag from updated nextoff
  lw   a1, -20(s0)
  addi a2, s0, -20
  mv   a0, s2
  jal  next_tag_lbu
  li   t0, 3                   # FDT_PROP
  bne  a0, t0, fail_pop
  la   t0, fdt_struct
  bne  s2, t0, fail_pop
  addi t1, sp, 32
  bne  s3, t1, fail_pop

  # third → END
  lw   a1, -20(s0)
  addi a2, s0, -20
  mv   a0, s2
  jal  next_tag_lbu
  li   t0, 9
  bne  a0, t0, fail_pop
  bne  s2, s2, fail_pop        # keep s2 live
  la   t0, fdt_struct
  bne  s2, t0, fail_pop
  addi t1, sp, 32
  bne  s3, t1, fail_pop

  # by_offset fail-path shape: poison s2 with 0x12b2a, c.mv from s3, sw
  li   t1, 0x80012b2a
  mv   s2, t1
  c.mv s2, s3
  li   a0, -4
  sw   a0, 0(s2)
  lw   t2, 0(s3)
  li   t3, -4
  bne  t2, t3, fail_pop

  ld   ra, 24(sp)
  ld   s0, 16(sp)
  addi sp, sp, 64
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

# next_tag_lbu(a0=fdt, a1=offset, a2=&nextoff) → a0=tag
# Mirrors OpenSBI: save s2-s5/ra/s0; *nextoff=-8; load BE tag via 4×lbu; restore.
next_tag_lbu:
  addi sp, sp, -64
  sd   s0, 48(sp)
  sd   s3, 24(sp)
  sd   s4, 16(sp)
  sd   s5, 8(sp)
  sd   ra, 56(sp)
  sd   s2, 32(sp)
  mv   s3, a2                  # s3 = &nextoff (OpenSBI)
  li   a5, -8
  sw   a5, 0(a2)
  mv   s4, a0                  # fdt
  mv   s5, a1                  # offset
  # p = fdt + offset
  add  a0, s4, s5
  # load big-endian tag (4 lbu) into s2 — OpenSBI assemble class
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
  # advance nextoff = offset+4 (simplified; no name skip)
  addi a1, s5, 4
  sw   a1, 0(s3)
  mv   a0, s2                  # return tag
  # restore callee-saved (must return original caller s2/s3 from *outer*)
  ld   s2, 32(sp)
  ld   ra, 56(sp)
  ld   s0, 48(sp)
  ld   s3, 24(sp)
  ld   s4, 16(sp)
  ld   s5, 8(sp)
  addi sp, sp, 64
  ret

fail_pop:
  ld   ra, 24(sp)
  ld   s0, 16(sp)
  addi sp, sp, 64
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

trap:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

  .section .rodata
  .align 8
# Tags only at +0/+4/+8 (simplified walk: +4 per call; stresses 4×lbu assemble)
fdt_struct:
  .byte 0x00, 0x00, 0x00, 0x01   # BEGIN_NODE
  .byte 0x00, 0x00, 0x00, 0x03   # PROP
  .byte 0x00, 0x00, 0x00, 0x09   # END
  .byte 0x00, 0x00, 0x00, 0x00

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
