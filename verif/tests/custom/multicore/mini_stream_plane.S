# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Bare-metal stream fill→verify (no CRT). Isolates WT ST→LD hang without
# CRT/memset noise. Default NBYTES=512 (same as mc_stream_plane fill).
# PASS tohost=1, FAIL tohost=3.

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000

  # Optional size override via a0 before entry is not used; fixed 512B.
  li   s1, 512               # nbytes
  mv   s0, sp
  sub  sp, sp, s1

  # Sequential fill
  mv   t0, sp
  mv   t1, s1
1:
  sub  t2, t0, sp
  xor  t3, t0, t2
  sd   t3, 0(t0)
  addi t0, t0, 8
  addi t1, t1, -8
  bnez t1, 1b

  # Sequential verify
  mv   t0, sp
  mv   t1, s1
2:
  sub  t2, t0, sp
  xor  t3, t0, t2
  ld   t4, 0(t0)
  bne  t3, t4, fail
  addi t0, t0, 8
  addi t1, t1, -8
  bnez t1, 2b

  li   a0, 1
  j    write_tohost
fail:
  li   a0, 3
write_tohost:
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
