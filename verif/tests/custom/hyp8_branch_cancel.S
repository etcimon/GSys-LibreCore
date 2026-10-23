# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# hyp8 branch-cancel program: two branches waiting on the same 8-stage
# multiply can issue adjacently when it completes; the taken branch is
# followed by a younger independent redirect. Prepared for the next
# full-model snapshot; not a current success gate.
.option norvc
.section .text.init
.globl _start
_start:
  li t0, 3
  li t1, 5
  mul t2, t0, t1
  beq t2, t2, good
  bne t2, zero, bad
  nop
  nop
good:
  li t0, 1
  la t1, tohost
  sw t0, 0(t1)
  j done
bad:
  li t0, 0x101
  la t1, tohost
  sw t0, 0(t1)
done:
  j done
.section .tohost,"aw",@progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
