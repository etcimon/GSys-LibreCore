// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Minimal cbo.zero discriminator for the T9a positive-arm timeout: hart 0
// dirties a line, issues cbo.zero, verifies, and writes step markers to
// MARKER (visible as `mem` records in the RVFI trace even when the hart
// hangs). No peer, no mem_poke, no other CBOs.
//
// tohost: 1 pass, 2 marker store after cbo.zero stalled (should not happen),
// 9 line not zeroed, 11 setup read-back wrong. Trap: 32+((mcause&0xff)<<1)|1.

  .equ LINE_Z,   0x80104080
  .equ MARKER,   0x80104300
  .equ PATTERN,  0x1122334455667788

.macro CBO_ZERO rs
  .4byte (4 << 20) | (\rs << 15) | (2 << 12) | 0x0f
.endm

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap
  csrw mtvec, t1
  bnez t0, park

  li   s3, LINE_Z
  li   s8, MARKER

  li   t0, PATTERN
  sd   t0, 0(s3)
  sd   t0, 8(s3)
  fence rw, rw
  ld   t0, 0(s3)
  li   t1, PATTERN
  bne  t0, t1, fail_setup

  li   t1, 0x11
  sd   t1, 0(s8)                // M1: pre-zero

  mv   a0, s3
  CBO_ZERO 10                   // cbo.zero (a0)

  li   t1, 0x22
  sd   t1, 8(s8)                // M2: cbo.zero retired

  fence rw, rw
  ld   t0, 0(s3)
  bnez t0, fail_zero
  ld   t0, 8(s3)
  bnez t0, fail_zero

  li   t1, 0x33
  sd   t1, 16(s8)               // M3: verified
  li   a0, 1
  j    done

park:
1:
  wfi
  j    1b

fail_setup:
  li   a0, 11
  j    done
fail_zero:
  li   a0, 9
  j    done

done:
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
1:
  wfi
  j    1b

trap:
  csrr a0, mcause
  andi a0, a0, 0xff
  slli a0, a0, 1
  ori  a0, a0, 1
  addi a0, a0, 32
  j    done

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .globl fromhost
fromhost: .dword 0
