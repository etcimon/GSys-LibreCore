// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// hyp8_raw_window -- rename producer-window direction discriminator.
// Settles whether the shipped g6lc_rename_resolve gather (hi_last =
// LOWEST-set = oldest producer wins) is observably wrong, or whether
// the two-writer window never materializes for source fields.
//
// Each variant builds a two/three-writer window on one rd and a
// consumer whose architecturally-correct input is the NEWEST writer's
// value.  The observed consumer result is packed as a 4-bit nibble in
// s11 (variant order V0=MSN .. V7=LSN).  The final tohost write is
// 1 (SUCCESS) iff every variant observed the newest value, else
// (sig<<1)|1 -- the FAILED line's tohost value IS the signature.
//
// Expected all-newest signature: V0..V7 = 7 a 9 7 7 7 3 9
//   -> 0x7a977739.  An oldest-wins nibble shows the OLD writer's value.

  .macro OBS reg
    andi t6, \reg, 0xF
    slli s11, s11, 4
    or   s11, s11, t6
  .endm

  .section .text.init
  .globl _start
_start:
  // Enable FP state (mstatus.FS=11) so the V5 FP WAW pair executes.
  li   t0, 0x6000
  csrs mstatus, t0
  li   s11, 0

  // V0: adjacent WAW pair + consumer (packs [li,li]/[add] or straddled).
  li   a5, 0x05
  li   a5, 0x07
  add  a0, x0, a5
  OBS  a0                        // newest 7 / oldest 5

  // V1: same pattern, one lead-in filler shifts the group parity.
  mv   a6, x0
  li   a4, 0x04
  li   a4, 0x0a
  add  a0, x0, a4
  OBS  a0                        // newest a / oldest 4

  // V2: independent op between the second writer and the consumer.
  li   a5, 0x05
  li   a5, 0x09
  ori  a7, x0, 1
  add  a0, x0, a5
  OBS  a0                        // newest 9 / oldest 5

  // V3: dependent WAW pair (RAW between writers, then consumer).
  li   a5, 0x05
  addi a5, a5, 2
  add  a0, x0, a5
  OBS  a0                        // newest 7 / oldest 5

  // V4: three writers in the window -- oldest/middle/newest distinct.
  li   a5, 0x05
  li   a5, 0x06
  li   a5, 0x07
  add  a0, x0, a5
  OBS  a0                        // newest 7 / oldest 5

  // V5: FP register pair -- exercises the do_falloc/h_f* vectors.
  li   t0, 0x05
  fmv.w.x f5, t0
  li   t1, 0x07
  fmv.w.x f5, t1
  fmv.x.w a0, f5
  OBS  a0                        // newest 7 / oldest 5

  // V6: positive control -- single producer, always correct.
  li   a5, 0x03
  add  a0, x0, a5
  OBS  a0                        // always 3

  // V7: spaced writers -- published-map path control (window closed).
  li   a5, 0x05
  li   a5, 0x09
  nop
  nop
  nop
  add  a0, x0, a5
  OBS  a0                        // always 9

  // Verdict: all-newest => SUCCESS (tohost=1); else emit signature.
  li   s0, 0x7a977739
  bne  s11, s0, 1f
  li   a0, 1
  j    2f
1:
  slli a0, s11, 1
  ori  a0, a0, 1
2:
  la   t0, tohost
  sw   a0, 0(t0)
done:
  j    done

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost:   .dword 0
  .align 6
