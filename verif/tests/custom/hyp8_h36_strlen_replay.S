// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// hyp8 H36: byte-walk strlen over bytes written by immediately-older stores.
//
// Added while investigating a possible memory-replay cause of issue 6.
// This smoke passed on the affected baseline and is general regression
// coverage; it is not a reproducer for the confirmed Zbb zero-count defect.
// This test runs the kernel's strlen shape (lbu / beqz / addi / j) over
// strings whose bytes are produced by stores that are still draining:
// sd then byte-loop at distance 0; sb-filled string; a string on a line
// that was just written and whose previous contents were NUL; and the
// consumer stores the length immediately (sd) so a wrong length is
// architecturally visible even if a replay later repairs the register.
//
// tohost: 1 pass, 0x101.. fail codes.

  .macro FAIL n
    li   a0, 0x100 + \n
    la   t0, tohost
    sw   a0, 0(t0)
    j    done
  .endm

  // strlen(a0) -> a0 ; clobbers t0, t4 (kernel arch/riscv/lib/strlen.S shape)
  .macro STRLEN
    mv   t4, a0
1:  lbu  t0, 0(t4)
    beqz t0, 2f
    addi t4, t4, 1
    j    1b
2:  sub  a0, t4, a0
  .endm

  .section .text.init
  .globl _start
_start:
  la   s0, buf
  la   s1, lens

  // 1. "earlycon=sbi" written as two sd + strlen at distance 0, 8 times
  li   s2, 8
11:
  li   t0, 0x6e6f63796c726165      // "earlycon"
  sd   t0, 0(s0)
  li   t0, 0x000000006962733d      // "=sbi\0"
  sd   t0, 8(s0)
  mv   a0, s0
  STRLEN
  sd   a0, 0(s1)                   // length escapes to memory immediately
  li   t1, 12
  bne  a0, t1, 12f
  sd   zero, 0(s0)
  sd   zero, 8(s0)
  addi s2, s2, -1
  bnez s2, 11b
  j    13f
12: FAIL 1
13:
  // 2. the name alone: "earlycon\0" from sd then strlen (expect 8), with the
  //    store to the NUL dword still draining
  li   s2, 8
21:
  sd   zero, 8(s0)
  li   t0, 0x6e6f63796c726165
  sd   t0, 0(s0)
  mv   a0, s0
  STRLEN
  sd   a0, 8(s1)
  li   t1, 8
  bne  a0, t1, 22f
  sd   zero, 0(s0)
  addi s2, s2, -1
  bnez s2, 21b
  j    23f
22: FAIL 2
23:
  // 3. byte-filled string "bootargs" (8 sb), strlen right behind the last sb
  li   s2, 8
31:
  li   t0, 0x62
  sb   t0, 16(s0)
  li   t0, 0x6f
  sb   t0, 17(s0)
  li   t0, 0x6f
  sb   t0, 18(s0)
  li   t0, 0x74
  sb   t0, 19(s0)
  li   t0, 0x61
  sb   t0, 20(s0)
  li   t0, 0x72
  sb   t0, 21(s0)
  li   t0, 0x67
  sb   t0, 22(s0)
  li   t0, 0x73
  sb   t0, 23(s0)
  sb   zero, 24(s0)
  addi a0, s0, 16
  STRLEN
  sd   a0, 16(s1)
  li   t1, 8
  bne  a0, t1, 32f
  sd   zero, 16(s0)
  addi s2, s2, -1
  bnez s2, 31b
  j    33f
32: FAIL 3
33:
  // 4. repair_env_string shape: split "earlycon=sbi" at '=', strlen(param),
  //    then restore by the length (val == param+len+1 expected)
  la   s0, buf2
  li   t0, 0x6e6f63796c726165
  sd   t0, 0(s0)
  li   t0, 0x000000006962733d
  sd   t0, 8(s0)
  sb   zero, 8(s0)                 // param="earlycon", val=buf2+9
  mv   a0, s0
  STRLEN
  addi t2, s0, 9                   // val
  add  t3, s0, a0
  addi t3, t3, 1                   // param+len+1
  bne  t2, t3, 41f
  li   t0, 0x3d
  sb   t0, 8(s0)                   // val[-1] = '='
  ld   t1, 0(s0)
  li   t4, 0x6e6f63796c726165
  bne  t1, t4, 41f
  ld   t1, 8(s0)
  li   t4, 0x000000006962733d
  bne  t1, t4, 41f
  j    42f
41: FAIL 4
42:
  // 5. verify the escaped lengths (a wrong first retire leaves a wrong sd)
  ld   t0, 0(s1)
  li   t1, 12
  bne  t0, t1, 51f
  ld   t0, 8(s1)
  li   t1, 8
  bne  t0, t1, 51f
  ld   t0, 16(s1)
  bne  t0, t1, 51f
  j    52f
51: FAIL 5
52:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
done:
  j    done

  .section .data
  .align 6
buf:
  .dword 0,0,0,0,0,0,0,0
  .align 6
buf2:
  .dword 0,0,0,0
  .align 6
lens:
  .dword 0,0,0,0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost:
  .dword 0
