# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Soft-ladder iter-008 OpenSBI PEEL_CMV shape:
#   ld s3,0(s4); c.mv a1,s1; c.mv a0,s2; ld a2,0(s3);
# then call a strlen-like leaf (fdt_node_check_compatible → sbi_strlen).
# Bare mini_dual_cmv_s3 is green; PEEL_CMV fails mid-sbi_strlen — this
# bridges the two.
#
# Gate: g6lc64_smt2 DI; tohost=1 pass, 3 fail.

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  # Module table: s4 → entry → payload (also use payload as "string" base)
  li   s4, 0x80007000
  li   t0, 0x80007080
  sd   t0, 0(s4)
  # Store "hello\0" at module ptr for strlen
  li   t1, 0x6f6c6c6568      # 'h''e''l''l''o' little-endian low 5 + 0
  sd   t1, 0(t0)

  li   s1, 0x1111
  li   s2, 0x80007080        # a0 will be string ptr after c.mv (like fdt path)

  # Cont.19 sequence
  ld   s3, 0(s4)
  c.mv a1, s1
  c.mv a0, s2
  ld   a2, 0(s3)             # must keep good s3

  # s3 still module; a0 = string
  li   t4, 0x80007080
  bne  s3, t4, fail
  bne  a0, t4, fail
  li   t5, 0x1111
  bne  a1, t5, fail

  # OpenSBI-like: after dual c.mv, call strlen on a0
  jal  strlen_like
  li   t1, 5
  bne  a0, t1, fail

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

strlen_like:
  lbu  a5, 0(a0)
  beqz a5, .Lzero
  mv   a4, a0
  li   a0, 0
.Lloop:
  addi a0, a0, 1
  add  a5, a4, a0
  lbu  a5, 0(a5)
  bnez a5, .Lloop
  ret
.Lzero:
  li   a0, 0
  ret

trap:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

fail:
  li   a0, 3
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
