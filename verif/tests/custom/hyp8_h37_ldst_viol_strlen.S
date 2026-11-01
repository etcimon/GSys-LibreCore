// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// hyp8 H37: memory-order violation under a byte-walk strlen.
//
// An older store whose ADDRESS comes from a load that misses writes the
// 8th byte ('n') of "earlyco\0" while a younger strlen walks the string.
// The walk's lbu of byte 7 may execute before the store resolves and read
// the old NUL (length 7); the LSQ must then replay the load BEFORE anything
// younger retires. This smoke passed on the affected baseline; it tests
// ordering behavior, not the confirmed Zbb zero-count defect.
//
// tohost: 1 pass, 0x101.. fail codes.

  .macro FAIL n
    li   a0, 0x100 + \n
    la   t0, tohost
    sw   a0, 0(t0)
    j    done
  .endm

  .section .text.init
  .globl _start
_start:
  la   s0, buf
  la   s1, lens
  la   s3, ptrs
  li   s2, 16                      // 16 trials, each on a fresh pointer line
10:
  // string "earlyco\0" (byte 7 = NUL) and a clean NUL after it
  li   t0, 0x006f63796c726165
  sd   t0, 0(s0)
  sd   zero, 8(s0)
  // the pointer to the string lives on a line never touched before (miss)
  ld   t5, 0(s3)                   // t5 = buf (address producer, slow)
  li   t6, 0x6e
  sb   t6, 7(t5)                   // older store, address unknown until ld returns
  // younger strlen (kernel shape) — its lbu at byte 7 may run ahead
  mv   a0, s0
  mv   t4, a0
1:
  lbu  t0, 0(t4)
  beqz t0, 2f
  addi t4, t4, 1
  j    1b
2:
  sub  a0, t4, a0
  sd   a0, 0(s1)                   // length escapes to memory
  li   t1, 8
  bne  a0, t1, 90f
  ld   t2, 0(s1)
  bne  t2, t1, 91f
  addi s3, s3, 64                  // next pointer line
  addi s2, s2, -1
  bnez s2, 10b
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
done:
  j    done
90: FAIL 1                         // strlen returned != 8 (stale byte read, no replay)
91: FAIL 2                         // register repaired by replay but the escaped sd kept the wrong length

  .section .data
  .align 6
buf:
  .dword 0,0,0,0,0,0,0,0
  .align 6
lens:
  .dword 0,0,0,0,0,0,0,0
  .align 6
ptrs:                              // 16 pointer copies, one per 64-byte line
  .rept 16
  .dword buf, 0, 0, 0, 0, 0, 0, 0
  .endr

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost:
  .dword 0
