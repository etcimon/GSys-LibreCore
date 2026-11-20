# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Zawrs liveness probe (hyp8). WRS ops are SYSTEM funct3=000:
#   WRS.NTO funct12=0x00d, WRS.STO funct12=0x01d, opcode=0x73.
#   .word (funct12<<20)|(rs1<<15)|(funct3<<12)|(rd<<7)|0x73
#
# v1: lr.d sets a reservation, then WRS.STO waits on it and wakes on the
#     short-timeout counter (~8 cycles) -> must complete (no wedge).
# v2: lr.d then a same-word store clears the reservation replica, fence,
#     then WRS.NTO sees no valid reservation -> must not stall -> complete.
# tohost = 1 on success; (2*k+1) names the first failing variant.
.option norvc
.section .text.init
.globl _start
_start:
  li    s7, 0

# v1: reservation valid -> WRS.STO times out and resumes
v1:
  la    a5, lockd
  li    a4, 0x11
  lr.d  a3, (a5)
  # wrs.sto x0, a5   (funct12=0x01d, rs1=a5, rd=x0)
  .word (0x01d<<20)|(15<<15)|(0<<12)|(0<<7)|0x73
  fence
  j     v2

# v2: reservation cleared by a store -> WRS.NTO does not wait
v2:
  la    a5, lockq
  li    t0, 0x22
  lr.d  a3, (a5)
  sd    t0, 0(a5)          # same-word store clears the reservation
  fence
  # wrs.nto x0, a5   (funct12=0x00d, rs1=a5, rd=x0)
  .word (0x00d<<20)|(15<<15)|(0<<12)|(0<<7)|0x73
  fence
  j     report

report:
  beqz  s7, pass
  slli  t0, s7, 1
  addi  t0, t0, 1
  la    t1, tohost
  sw    t0, 0(t1)
  j     done
pass:
  li    t0, 1
  la    t1, tohost
  sw    t0, 0(t1)
done:
  j     done

.section .data
.align 6
lockd: .dword 0
.align 6
lockq: .dword 0

.section .tohost,"aw",@progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
