# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Xg6lcai mini (WP4, SMT2+AI): the CVXIF port-0 steering contract under a
# dual-issue host. Two facts, each with its own distinct fail code:
#
#   1. An AI op placed as the SECOND instruction of an aligned pair (behind an
#      independent ALU op) still executes with the right result: on a dual-issue
#      core it is held busy on port 1 and offered to the coprocessor on port 0.
#      Repeated in a tight loop so the pairing is exercised many times.
#   2. An ILLEGAL custom-2 encoding in the same slot traps precisely: mcause=2,
#      mepc = its own address, and the handler resumes after it.
#
# On a single-issue package both facts hold trivially (the mini is then a
# positive control for the AI op and the trap path). Hart 0 only. Failure words
# carry the exit bit ((code << 1) | 1) so a failing mini stops the harness at once
# instead of running to the cycle cap (the even code 2 of the older minis does that).
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  beqz t0, 1f
2: wfi
  j    2b
1:
  li   sp, 0x80008000
  la   t0, trap_vec
  csrw mtvec, t0

  # ais: Initial so the unit is not Off.
  csrr t0, 0x802
  li   t1, ~(0x3 << 6)
  and  t0, t0, t1
  li   t1, (0x1 << 6)
  or   t0, t0, t1
  csrw 0x802, t0

  li   a1, 0x05040302
  li   a2, 0x09080706
  li   t3, 64                   # iterations
  li   t4, 0                    # ALU partner accumulator
  .align 3
loop:
  addi t4, t4, 3                # slot 0: ALU
  .word 0x00C5B55B              # slot 1: ai.dot4.s8 a0, a1, a2  (= 110)
  li   t0, 110
  bne  a0, t0, fail_exec
  li   a0, 0
  addi t3, t3, -1
  bnez t3, loop
  li   t0, 192                  # 64 * 3
  bne  t4, t0, fail_exec

  # 2. Illegal custom-2 encoding as the second instruction of a pair.
  li   t5, 0                    # trap seen flag
  la   t6, illegal_pc
  .align 3
  addi t4, t4, 1                # slot 0: ALU
illegal_pc:
  .word 0x0000755B              # slot 1: custom-2 funct3=111 (reserved, must trap)
  beqz t5, fail_notrap
  li   t0, 193
  bne  t4, t0, fail_exec        # the ALU partner committed exactly once

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j 1b

fail_exec:                      # AI op result or partner wrong: exit code 1 (tohost 3)
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
2: j 2b

fail_notrap:                    # illegal encoding did not trap: exit code 2 (tohost 5)
  li   a0, 5
  la   t0, tohost
  sw   a0, 0(t0)
3: j 3b

trap_vec:
  csrr t0, mcause
  li   t1, 2
  bne  t0, t1, fail_exec        # a trap that is not illegal-instruction
  csrr t0, mepc
  bne  t0, t6, fail_exec        # imprecise mepc
  li   t5, 1
  addi t0, t0, 4
  csrw mepc, t0
  mret

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
