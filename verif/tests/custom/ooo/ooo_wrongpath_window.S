# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# T19 defect 1 — wrong-path fetch window surviving a mispredict flush.
#
# Shape (from the ooocoh-t18 server boot, harts 3/7, T19-ANALYSIS §1/§5(f)):
# a cold, always-taken forward `beqz` is predicted not-taken; its fall-through
# `jal`s into a two-I$-line victim function whose second line stores a
# sentinel into a probe word and `ret`s.  The victim must never commit: the
# branch resolves taken, the taken target does real work and then checks the
# probe word.  Every shape is run twice (two branches, same victim): the first
# pass only warms the victim's first I$ line through the killed wrong path
# (the T17 KILL_MISS install), so the second pass's wrong path runs one line
# further and misses on the victim's second line right around the resolve.
# The resolve delay is swept (COND kinds: cached `ld` + dependent `addi` chain
# of N, `divu` with quotient 0, `ld` from a cold data line, `divu` feeding a
# cold `ld`), as is the distance between the branch and the `jal` (PRE filler
# words) and the position of the sentinel `sd` inside the victim's second
# I$ line 2 (VPAD 0 = first 8-byte window, 8 = second window — the leaked window
# of the boot was the second half of line 0x800086e0).
#
# Each copy has its own victim (both lines cold at first touch) and, unless
# -DNO_BPFLUSH, an `ecall`/`mret` pair in front of every pass so the branch
# is really cold (trap entry and eret both flush the predictors).
#
# Self-check only (no Spike/QEMU reference needed).  Exit codes (a0 → tohost
# = 2*a0+1):
#   0  pass
#   2  LEAK: the probe word carries the sentinel (wrong-path `sd` committed)
#   3  wrong-path victim line-1 `addi t5/t6` committed
#   4  wrong-path filler `addi t2` committed
#   5  taken-path counter wrong (a shape's taken target did not run)
#   7  a committed wrong-path `ret` returned into main's caller (a0 kept at 7)
#   8  a committed wrong-path `ret` landed on the stray pad
#   9  unexpected trap (handle_trap, non-ecall)
#   1  generic failure

#define SENTINEL 0x5e17

  .option push
  .option norvc                 # every fetch-side distance below is in whole words
  .globl main
main:
  la   ra, stray_ret            # any committed wrong-path `ret` lands here
  li   a0, 7                    # ...or in _init if ra was clobbered: exit 7
  la   s8, probe
  la   s9, work
  la   s10, zero_word
  la   s2, coldarea
  li   s11, SENTINEL
  li   s4, 0                    # taken-path counter
  li   t2, 0                    # wrong-path filler witness
  li   t5, 0                    # victim line-1 witnesses
  li   t6, 0
  li   s5, 0x7fffffffffffffff   # divu numerator
  li   s6, -1                   # divu denominator (> numerator → q = 0)
  li   s7, 0                    # expected count accumulator
  li   s3, 0                    # sticky OR of every probe read
  li   a6, 1                   # remu divisor / shift base

# ---------------------------------------------------------------------------
# COND kind, n: leave t0 = 0 after a kind-specific, n-scaled latency.
#   0: `remu t0, 1<<n, 1` — the serial divider iterates lzc(b)-lzc(a) = n
#      times (remainder 0): a one-instruction, fetch-independent delay of ~n
#      cycles (a dependent `addi` chain is fetch-bound on cold code: every
#      8-byte window of a never-executed line costs an I$ miss, so the fetch
#      never gets ahead of the branch).
#   1: cached `ld` + n-deep dependent `addi` chain (n small)
#   2: `ld` from a cold data line (D$ miss) + n-deep chain (n small)
#   3: cold `ld` feeding a `remu` of ~n cycles (miss latency + n)
# ---------------------------------------------------------------------------
.macro COND kind, n
  .if \kind == 0
  slli t4, a6, \n
  remu t0, t4, a6              # (1<<n) % 1 = 0 after ~n divider steps
  .elseif \kind == 1
  ld   t0, 0(s10)               # cached hit
  .rept \n
  addi t0, t0, 0
  .endr
  .elseif \kind == 2
  ld   t0, 0(s2)                # cold data line (D$ miss)
  addi s2, s2, 64
  .rept \n
  addi t0, t0, 0
  .endr
  .else
  slli t4, a6, \n
  ld   t3, 0(s2)                # cold data line (D$ miss), reads 0
  addi s2, s2, 64
  or   t4, t4, t3
  remu t0, t4, a6              # miss latency, then ~n divider steps
  .endif
.endm

.macro BPFLUSH
#ifndef NO_BPFLUSH
  ecall                         # trap + mret: flush_bp on both edges
#endif
.endm

# One pass: cold always-taken beqz, wrong-path filler + jal victim,
# taken target does work and reads the probe word.
.macro PASS id, kind, n, pre, tgt
  BPFLUSH
  COND \kind, \n
  beqz t0, \tgt\()f             # always taken; cold -> predicted not-taken
  .rept \pre
  addi t2, t2, 1                # wrong path
  .endr
  jal  victim_\id               # wrong path: into the two-line victim
  addi t2, t2, 1                # wrong path (victim's return point)
  addi t2, t2, 1
\tgt:
  addi s4, s4, 1                # real work on the taken path
  sd   s4, 0(s9)
  xor  t3, s4, s8
  ld   t1, 0(s8)                # the probe word must still be 0
  or   s3, s3, t1               # sticky; checked at the end (a `bnez leak`
                                # here would be one more cold taken branch)
.endm

.macro SHAPE id, kind, n, pre, vpad
  PASS \id, \kind, \n, \pre, 1
  PASS \id, \kind, \n, \pre, 2
  addi s7, s7, 2
  .pushsection .text.victims, "ax", @progbits
  .balign 16
victim_\id:
  addi t5, t5, 1                # line 1 (16 B): 4 full-width insns, no CF
  addi t6, t6, 1
  addi t5, t5, 2
  addi t6, t6, 2
  .if \vpad
  .half 0x0001                  # c.nop x4: line 2, first 8-byte window
  .half 0x0001
  .half 0x0001
  .half 0x0001
  .endif
  sd   s11, 0(s8)               # sentinel -> probe word (the leak witness)
  .half 0x8082                  # c.jr ra (ret)
  .half 0x0001                  # c.nop
  .if \vpad == 0
  .half 0x0001
  .half 0x0001
  .half 0x0001
  .half 0x0001
  .endif
  .popsection
.endm

# ---------------------------------------------------------------------------
# Sweep.  kind 0 n=1..63: dense resolve-delay scan with the boot's geometry
# (jal 3 words after the branch, sentinel in the second window of line 2),
# then coarser scans of the other geometries and kinds.
# ---------------------------------------------------------------------------
  SHAPE   0, 0,  1, 3, 8
  SHAPE   1, 0,  2, 3, 8
  SHAPE   2, 0,  3, 3, 8
  SHAPE   3, 0,  4, 3, 8
  SHAPE   4, 0,  5, 3, 8
  SHAPE   5, 0,  6, 3, 8
  SHAPE   6, 0,  7, 3, 8
  SHAPE   7, 0,  8, 3, 8
  SHAPE   8, 0,  9, 3, 8
  SHAPE   9, 0, 10, 3, 8
  SHAPE  10, 0, 11, 3, 8
  SHAPE  11, 0, 12, 3, 8
  SHAPE  12, 0, 13, 3, 8
  SHAPE  13, 0, 14, 3, 8
  SHAPE  14, 0, 15, 3, 8
  SHAPE  15, 0, 16, 3, 8
  SHAPE  16, 0, 17, 3, 8
  SHAPE  17, 0, 18, 3, 8
  SHAPE  18, 0, 19, 3, 8
  SHAPE  19, 0, 20, 3, 8
  SHAPE  20, 0, 21, 3, 8
  SHAPE  21, 0, 22, 3, 8
  SHAPE  22, 0, 23, 3, 8
  SHAPE  23, 0, 24, 3, 8
  SHAPE  24, 0, 25, 3, 8
  SHAPE  25, 0, 26, 3, 8
  SHAPE  26, 0, 27, 3, 8
  SHAPE  27, 0, 28, 3, 8
  SHAPE  28, 0, 29, 3, 8
  SHAPE  29, 0, 30, 3, 8
  SHAPE  30, 0, 31, 3, 8
  SHAPE  31, 0, 32, 3, 8
  SHAPE  32, 0, 33, 3, 8
  SHAPE  33, 0, 34, 3, 8
  SHAPE  34, 0, 35, 3, 8
  SHAPE  35, 0, 36, 3, 8
  SHAPE  36, 0, 37, 3, 8
  SHAPE  37, 0, 38, 3, 8
  SHAPE  38, 0, 39, 3, 8
  SHAPE  39, 0, 40, 3, 8
  SHAPE  40, 0, 41, 3, 8
  SHAPE  41, 0, 42, 3, 8
  SHAPE  42, 0, 43, 3, 8
  SHAPE  43, 0, 44, 3, 8
  SHAPE  44, 0, 45, 3, 8
  SHAPE  45, 0, 46, 3, 8
  SHAPE  46, 0, 47, 3, 8
  SHAPE  47, 0, 48, 3, 8
  SHAPE  48, 0, 49, 3, 8
  SHAPE  49, 0, 50, 3, 8
  SHAPE  50, 0, 51, 3, 8
  SHAPE  51, 0, 52, 3, 8
  SHAPE  52, 0, 53, 3, 8
  SHAPE  53, 0, 54, 3, 8
  SHAPE  54, 0, 55, 3, 8
  SHAPE  55, 0, 56, 3, 8
  SHAPE  56, 0, 57, 3, 8
  SHAPE  57, 0, 58, 3, 8
  SHAPE  58, 0, 59, 3, 8
  SHAPE  59, 0, 60, 3, 8
  SHAPE  60, 0, 61, 3, 8
  SHAPE  61, 0, 62, 3, 8
  SHAPE  62, 0, 63, 3, 8
  SHAPE  63, 0,  4, 0, 8
  SHAPE  64, 0,  8, 0, 8
  SHAPE  65, 0, 12, 0, 8
  SHAPE  66, 0, 16, 0, 8
  SHAPE  67, 0, 20, 0, 8
  SHAPE  68, 0, 24, 0, 8
  SHAPE  69, 0, 28, 0, 8
  SHAPE  70, 0, 32, 0, 8
  SHAPE  71, 0, 36, 0, 8
  SHAPE  72, 0, 40, 0, 8
  SHAPE  73, 0, 44, 0, 8
  SHAPE  74, 0, 48, 0, 8
  SHAPE  75, 0, 52, 0, 8
  SHAPE  76, 0, 56, 0, 8
  SHAPE  77, 0, 60, 0, 8
  SHAPE  78, 0,  4, 3, 0
  SHAPE  79, 0,  8, 3, 0
  SHAPE  80, 0, 12, 3, 0
  SHAPE  81, 0, 16, 3, 0
  SHAPE  82, 0, 20, 3, 0
  SHAPE  83, 0, 24, 3, 0
  SHAPE  84, 0, 28, 3, 0
  SHAPE  85, 0, 32, 3, 0
  SHAPE  86, 0, 36, 3, 0
  SHAPE  87, 0, 40, 3, 0
  SHAPE  88, 0, 44, 3, 0
  SHAPE  89, 0, 48, 3, 0
  SHAPE  90, 0, 52, 3, 0
  SHAPE  91, 0, 56, 3, 0
  SHAPE  92, 0, 60, 3, 0
  SHAPE  93, 0,  4, 0, 0
  SHAPE  94, 0,  8, 0, 0
  SHAPE  95, 0, 12, 0, 0
  SHAPE  96, 0, 16, 0, 0
  SHAPE  97, 0, 20, 0, 0
  SHAPE  98, 0, 24, 0, 0
  SHAPE  99, 0, 28, 0, 0
  SHAPE 100, 0, 32, 0, 0
  SHAPE 101, 0, 36, 0, 0
  SHAPE 102, 0, 40, 0, 0
  SHAPE 103, 0, 44, 0, 0
  SHAPE 104, 0, 48, 0, 0
  SHAPE 105, 0, 52, 0, 0
  SHAPE 106, 0, 56, 0, 0
  SHAPE 107, 0, 60, 0, 0
  SHAPE 108, 0,  4, 1, 8
  SHAPE 109, 0,  8, 1, 8
  SHAPE 110, 0, 12, 1, 8
  SHAPE 111, 0, 16, 1, 8
  SHAPE 112, 0, 20, 1, 8
  SHAPE 113, 0, 24, 1, 8
  SHAPE 114, 0, 28, 1, 8
  SHAPE 115, 0, 32, 1, 8
  SHAPE 116, 0, 36, 1, 8
  SHAPE 117, 0, 40, 1, 8
  SHAPE 118, 0, 44, 1, 8
  SHAPE 119, 0, 48, 1, 8
  SHAPE 120, 0, 52, 1, 8
  SHAPE 121, 0, 56, 1, 8
  SHAPE 122, 0, 60, 1, 8
  SHAPE 123, 0,  4, 5, 8
  SHAPE 124, 0,  8, 5, 8
  SHAPE 125, 0, 12, 5, 8
  SHAPE 126, 0, 16, 5, 8
  SHAPE 127, 0, 20, 5, 8
  SHAPE 128, 0, 24, 5, 8
  SHAPE 129, 0, 28, 5, 8
  SHAPE 130, 0, 32, 5, 8
  SHAPE 131, 0, 36, 5, 8
  SHAPE 132, 0, 40, 5, 8
  SHAPE 133, 0, 44, 5, 8
  SHAPE 134, 0, 48, 5, 8
  SHAPE 135, 0, 52, 5, 8
  SHAPE 136, 0, 56, 5, 8
  SHAPE 137, 0, 60, 5, 8
  SHAPE 138, 1,  0, 3, 8
  SHAPE 139, 1,  2, 3, 8
  SHAPE 140, 1,  4, 3, 8
  SHAPE 141, 1,  6, 3, 8
  SHAPE 142, 2,  0, 3, 8
  SHAPE 143, 2,  2, 3, 8
  SHAPE 144, 2,  4, 3, 8
  SHAPE 145, 2,  6, 3, 8
  SHAPE 146, 2,  8, 3, 8
  SHAPE 147, 3,  0, 3, 8
  SHAPE 148, 3,  8, 3, 8
  SHAPE 149, 3, 16, 3, 8
  SHAPE 150, 3, 24, 3, 8
  SHAPE 151, 3, 32, 3, 8
  SHAPE 152, 3, 40, 3, 8
  SHAPE 153, 3, 48, 3, 8
  SHAPE 154, 1,  0, 0, 8
  SHAPE 155, 1,  2, 0, 8
  SHAPE 156, 1,  4, 0, 8
  SHAPE 157, 1,  6, 0, 8
  SHAPE 158, 2,  0, 0, 8
  SHAPE 159, 2,  2, 0, 8
  SHAPE 160, 2,  4, 0, 8
  SHAPE 161, 2,  6, 0, 8
  SHAPE 162, 2,  8, 0, 8
  SHAPE 163, 3,  0, 0, 8
  SHAPE 164, 3,  8, 0, 8
  SHAPE 165, 3, 16, 0, 8
  SHAPE 166, 3, 24, 0, 8
  SHAPE 167, 3, 32, 0, 8
  SHAPE 168, 3, 40, 0, 8
  SHAPE 169, 3, 48, 0, 8
  SHAPE 170, 2,  0, 3, 0
  SHAPE 171, 3,  0, 3, 0
  SHAPE 172, 2,  4, 3, 0
  SHAPE 173, 3, 16, 3, 0

# ---------------------------------------------------------------------------
# Final checks
# ---------------------------------------------------------------------------
  ld   t1, 0(s8)
  or   s3, s3, t1
  bnez s3, leak
  bnez t5, victim_committed
  bnez t6, victim_committed
  bnez t2, filler_committed
  bne  s4, s7, count_wrong
  li   a0, 0
  jal  exit

leak:
  li   a0, 2
  jal  exit
victim_committed:
  li   a0, 3
  jal  exit
filler_committed:
  li   a0, 4
  jal  exit
count_wrong:
  li   a0, 5
  jal  exit
stray_ret:
  li   a0, 8
  jal  exit

# ecall → skip the ecall; any other trap → exit 9
  .globl handle_trap
handle_trap:
  li   t0, 11                   # mcause: environment call from M-mode
  bne  a0, t0, 1f
  addi a0, a1, 4
  ret
1:
  li   a0, 9
  j    _exit
  .option pop

  .data
  .balign 64
probe:     .dword 0
  .balign 64
work:      .dword 0
  .balign 64
zero_word: .dword 0

  .balign 64
coldarea:  .skip 64*256         # .data (not .bss): must read back as zero
