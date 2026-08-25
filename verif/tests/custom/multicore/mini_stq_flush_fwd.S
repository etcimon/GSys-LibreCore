# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# R4 residual shape (firmware-boot-principles.md s0.1): getprop s2/s3 clobber.
# f1 leaves a code address (its saved ra) in a stack slot; f2 reuses the same
# slot for its prologue `sd s3`, takes a data-dependent (mispredicting) branch
# between prologue and epilogue, then `ld s3` must see f2's own store, not the
# f1 ra residue. Catches an STQ-flush that drops a non-cancelled prologue
# store, or a load that bypasses the outstanding store after a squash (I16/I17).
# tohost=1 pass, 3 fail.
#

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  li   s5, 0                 # loop index (drives branch alternation)
  li   s4, 64                # iterations
1:
  # per-iteration distinct callee-saved values (defeat same-value masking)
  li   s3, 0x33330000
  add  s3, s3, s5
  li   s2, 0x22220000
  add  s2, s2, s5

  jal  f1                    # leaves ra residue at the shared slot
  jal  f2                    # prologue sd s3 -> same slot; branch; ld s3

  # s3 must be the per-iteration value, never a code address
  li   t0, 0x33330000
  add  t0, t0, s5
  bne  s3, t0, fail
  li   t1, 0x22220000
  add  t1, t1, s5
  bne  s2, t1, fail

  addi s5, s5, 1
  addi s4, s4, -1
  bnez s4, 1b

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

# f1: minimal frame, saves ra at 24(sp) -- the shared slot after return.
f1:
  addi sp, sp, -32
  sd   ra, 24(sp)
  # touch a couple of neighbours like fdt_check_node_offset_
  li   a5, 0x20
  add  a5, a5, sp
  ld   ra, 24(sp)
  addi sp, sp, 32
  ret

# f2: prologue stores s2/s3 over f1's residue, mispredicting branch in the
# shadow, epilogue reloads. next_tag shape.
f2:
  addi sp, sp, -32
  sd   s3, 24(sp)            # same address as f1's ra slot
  sd   s2, 16(sp)
  li   s3, 9                 # working clobber (tag)
  li   s2, 9
  # data-dependent alternating branch: BHT settles then mispredicts on the
  # period change; the squash lands between the sd above and the ld below.
  andi t0, s5, 3
  beqz t0, 3f
  # short not-taken arm: dual-issue-ish filler with a dependent load
  lw   t1, 16(sp)
  add  t1, t1, t0
3:
  # second flush source: alternating forward/back path via compressed jump
  andi t0, s5, 1
  bnez t0, 4f
  c.nop
4:
  ld   s3, 24(sp)            # must forward from f2's own prologue store
  ld   s2, 16(sp)
  addi sp, sp, 32
  ret

trap:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
5: j    5b

fail:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
6: j    6b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
