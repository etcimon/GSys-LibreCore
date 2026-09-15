# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# All-set hot + rotating scan (leaf hot_scan, at the core). Stream8 infers
# L2 256 KiB / 8-way / 64 B → 512 sets, idx addr[14:6]. Hot is one 64 B line
# per set (32 KiB). Each round re-reads hot then a fresh 32 KiB scan tag so
# the working set exceeds the 32 KiB L1 D$ and L2 replacement (RR vs way-0)
# can differ. PASS tohost=1, FAIL tohost=3. Experimental, not a Linux SKU.

#ifndef NSETS
#define NSETS 512
#endif
#ifndef NROUNDS
#define NROUNDS 16
#endif

  .section .text.init
  .globl _start
  .option push
  .option norvc
_start:
  csrr t0, mhartid
  bnez t0, park

  li   s0, 0x80008000
  li   s1, 64
  li   s2, 32768
  li   s3, NSETS
  li   s4, NROUNDS

  // DRAM unique fill: hot tag 1 and scan tags 16..16+NROUNDS-1, every set.
  li   t0, 0
1:
  mul  t2, t0, s1
  add  t2, s0, t2
  add  t2, t2, s2
  sd   t0, 0(t2)
  addi t0, t0, 1
  blt  t0, s3, 1b
  li   t5, 0
2:
  li   t0, 0
  addi t6, t5, 16
  mul  t3, t6, s2
3:
  mul  t2, t0, s1
  add  t2, s0, t2
  add  t2, t2, t3
  xor  t4, t5, t0
  sd   t4, 0(t2)
  addi t0, t0, 1
  blt  t0, s3, 3b
  addi t5, t5, 1
  blt  t5, s4, 2b
  fence rw, rw

  // Fill L2: hot + 7 neighbour tags (set full).
  li   t5, 1
4:
  mul  t3, t5, s2
  li   t0, 0
5:
  mul  t2, t0, s1
  add  t2, s0, t2
  add  t2, t2, t3
  ld   t4, 0(t2)
  addi t0, t0, 1
  blt  t0, s3, 5b
  addi t5, t5, 1
  li   t6, 9
  blt  t5, t6, 4b

  // ROI: re-read hot, then one scan tag.
  li   t5, 0
  li   s5, 0
6:
  add  t3, s0, s2
  li   t0, 0
7:
  mul  t2, t0, s1
  add  t2, t3, t2
  ld   t4, 0(t2)
  add  s5, s5, t4
  addi t0, t0, 1
  blt  t0, s3, 7b
  addi t6, t5, 16
  mul  t3, t6, s2
  li   t0, 0
8:
  mul  t2, t0, s1
  add  t2, s0, t2
  add  t2, t2, t3
  ld   t4, 0(t2)
  addi t0, t0, 1
  blt  t0, s3, 8b
  addi t5, t5, 1
  blt  t5, s4, 6b

  // Hot values were the set index; NROUNDS copies of sum 0..511.
  li   t0, NSETS
  addi t0, t0, -1
  mul  t0, t0, t0
  addi t0, t0, NSETS
  srli t0, t0, 1
  li   t1, NROUNDS
  mul  t0, t0, t1
  bne  s5, t0, fail

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

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
