# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Isolated checked-work kernel. Default 48 KiB sequential fill+verify so the
# working set exceeds a 32 KiB L1 D$ (stream8). Markers and checksum live in
# DRAM, not as production opcode/address exceptions.
#
# PASS tohost=1, FAIL tohost=3.
# Assemble with --defsym NBYTES=<bytes> (multiple of 8, >= 4096) and
# --defsym NWORKERS=1|2. N=2 is experimental, not a Linux SKU.
#
# The body is uncompressed: SMT2 I=2 dual-issue was observed spinning on
# 16-bit pairs (c.li/c.j at tohost; c.addi/c.addi in verify under RR-on).

#ifndef NBYTES
#define NBYTES 49152
#endif
#ifndef NWORKERS
#define NWORKERS 1
#endif

  .section .text.init
  .globl _start
  .option push
  .option norvc
_start:
  csrr s5, mhartid
  li   t1, NWORKERS
  bgeu s5, t1, park

  li   s1, NBYTES
  li   s2, 0x80100000
  mul  t2, s5, s1
  add  s0, s2, t2

  la   t3, markers
  li   t4, 0x6c630001
  sd   t4, 0(t3)

  mv   t5, s0
  mv   t6, s1
  li   s3, 0
fill:
  xor  a0, t5, t6
  sd   a0, 0(t5)
  xor  s3, s3, a0
  addi t5, t5, 8
  addi t6, t6, -8
  bnez t6, fill

  mv   t5, s0
  mv   t6, s1
  li   s4, 0
verify:
  xor  a0, t5, t6
  ld   a1, 0(t5)
  bne  a0, a1, fail
  xor  s4, s4, a1
  addi t5, t5, 8
  addi t6, t6, -8
  bnez t6, verify
  bne  s3, s4, fail

  la   t3, markers
  sd   s3, 8(t3)
  slli t4, s5, 2
  add  t4, t3, t4
  li   t5, 1
  sw   t5, 16(t4)
  li   t4, 0x6c630002
  sd   t4, 0(t3)

  bnez s5, park
  li   t1, NWORKERS
wait_workers:
  la   t3, markers
  li   t2, 0
  mv   t0, t1
count_done:
  lwu  t4, 16(t3)
  add  t2, t2, t4
  addi t3, t3, 4
  addi t0, t0, -1
  bnez t0, count_done
  bne  t2, t1, wait_workers

  addi a0, x0, 1
  jal  x0, write_tohost
fail:
  addi a0, x0, 3
write_tohost:
  la   t0, tohost
  sw   a0, 0(t0)
1: jal  x0, 1b

park:
  wfi
  jal  x0, park
  .option pop

  .section .data
  .align 6
  .globl markers
markers:
  .dword 0
  .dword 0
  .word  0
  .word  0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
