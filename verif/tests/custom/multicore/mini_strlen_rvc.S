# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Soft-ladder iter-008 isolate: OpenSBI PEEL_CMV dies mid-sbi_strlen
# (mepc=0x80004a50 mcause=2 half into RVI `add` after RVC `addi`). This
# bare test runs an sbi_strlen-shaped RVC/RVI loop under DI without OpenSBI.
#
# Gate: g6lc64_smt2 DI; tohost=1 pass, 3 fail.

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  # Known string in .rodata-like RAM
  la   a0, msg
  # --- sbi_strlen-shaped body (mixed C + I) ---
  # lbu a5,0(a0); beqz; mv a4,a0; li a0,0;
  # loop: addi a0,a0,1; add a5,a4,a0; lbu a5,0(a5); bnez
  lbu  a5, 0(a0)
  beqz a5, empty
  mv   a4, a0
  li   a0, 0
1:
  addi a0, a0, 1
  add  a5, a4, a0
  lbu  a5, 0(a5)
  bnez a5, 1b
  # length of "hello" = 5
  li   t1, 5
  bne  a0, t1, fail

  # Run again denser (no padding) to stress dual-issue packing
  la   a0, msg
  jal  strlen_like
  li   t1, 5
  bne  a0, t1, fail

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

empty:
  j    fail

# Leaf: a0 = string, returns length in a0
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

  .section .data
  .align 3
msg:
  .asciz "hello"

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
