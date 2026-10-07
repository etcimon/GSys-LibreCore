// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// T19 defect 1, two-hart variant of verif/tests/custom/ooo/ooo_wrongpath_window.S
// for the SMT profiles (g6lc64_ooo_server / g6lc64_ooo_int2_l3 / g6lc64_smt2*:
// harts 0 and 1 share core 0 and one g6lc_icache).
//
// The ooocoh-t18 boot failure (T19-ANALYSIS §1): on cores 1 and 3 the first
// thread to run `aclint_mtimer_sync` mispredicted the cold `beqz` at +0x16,
// its killed wrong path installed the first I$ line of the not-taken-path
// callee (T17 KILL_MISS install) and was correctly squashed; the SECOND thread
// of the core, running the same code later while its sibling sat in WFI,
// mispredicted the same branch, its wrong path hit that pre-installed line,
// missed on the callee's second line, and the second 8-byte window of that
// line (`ld; amoswap` at 0x800086e8) was retired after the taken branch.
//
// Shape here: hart 1 runs pass A of every SHAPE (cold always-taken forward
// beqz, wrong-path filler + `jal victim_k`; victim_k = two 16 B I$ lines, the
// second one stores a sentinel into the probe word and `ret`s), publishes
// `flag`, then parks in WFI (default) or spins (-DSIBLING_SPIN, keeps the
// selector switching during hart 0's passes). Hart 0 waits for the flag and
// then runs pass B of every SHAPE: same victim, so its wrong path hits
// victim line 1 (installed by hart 1's killed stream) and misses line 2 while
// the branch resolves. Resolve delay, branch→jal distance and the sentinel's
// window inside line 2 are swept exactly as in the single-hart kernel (see
// the COND comment). Unless -DNO_BPFLUSH every pass starts with an ecall /
// mret pair so the branch is really cold.
//
// -DWP_LOADS: the wrong path starts with a cold load followed by two hot
// loads — OoO issues them before the branch resolves, the cold miss stalls
// the HPDCACHE pipeline (st1/st2 nops) while the hot loads wait in WAIT_GNT,
// and the mispredict cancel withdraws them un-granted (defect 2 stimulus;
// count with the [hpd-phantom] final line).
// tohost raw codes: 1 pass, 5 LEAK (sentinel in the probe word), 7 victim
// line-1 `addi` committed, 9 wrong-path filler committed, 11 taken-path count
// wrong, 13 stray wrong-path `ret`, 15 unexpected trap, 17 flag spin timeout,
// 3 ORACLE_NEGATIVE arm (hart 0 demands a wrong count).
// tohost sits past 0x80001000 (REVIEW_MC_DIRECTED_TOHOST_ADDR=auto); run with
// mask 00000011 on g6lc64_ooo_server (harts 2..7 park at once).

#ifndef SPIN_TO
#define SPIN_TO 2000000
#endif
#define SENTINEL 0x5e17

  .equ CLINT_MSIP, 0x02000000

// COND kind, n: leave t0 = 0 after a kind-specific, n-scaled latency.
//   0: `remu t0, 1<<n, 1` — lzc(b)-lzc(a) = n serial-divider steps, remainder
//      0: a one-instruction, fetch-independent ~n-cycle delay.
//   1: cached `ld` + n-deep dependent `addi` chain (n small)
//   2: `ld` from a cold data line (D$ miss) + n-deep chain (n small)
//   3: cold `ld` feeding a `remu` of ~n cycles (miss latency + n)
.macro COND kind, n
  .if \kind == 0
  slli t4, a6, \n
  remu t0, t4, a6
  .elseif \kind == 1
  ld   t0, 0(s10)
  .rept \n
  addi t0, t0, 0
  .endr
  .elseif \kind == 2
  ld   t0, 0(s2)
  addi s2, s2, 64
  .rept \n
  addi t0, t0, 0
  .endr
  .else
  slli t4, a6, \n
  ld   t3, 0(s2)
  addi s2, s2, 64
  or   t4, t4, t3
  remu t0, t4, a6
  .endif
.endm

.macro BPFLUSH
#ifndef NO_BPFLUSH
  ecall
#endif
.endm

// One pass of SHAPE id: cold always-taken beqz, wrong-path filler + jal
// victim, taken target does work and reads the probe word (sticky OR in s3).
.macro PASS id, kind, n, pre
  BPFLUSH
#ifdef SIBLING_IPI
  sw   a5, 0(a4)                // msip[1]: wake the parked sibling (it re-parks)
#endif
  COND \kind, \n
  beqz t0, 1f
#ifdef WP_LOADS
  ld   t3, 0(s2)                // wrong-path cold load (miss: st1/st2 nops)
  ld   t4, 0(s10)               // wrong-path hot load queued behind it (WAIT_GNT)
  ld   t3, 8(s10)
#endif
  .rept \pre
  addi t2, t2, 1
  .endr
  jal  victim_\id
  addi t2, t2, 1
  addi t2, t2, 1
1:
  addi s4, s4, 1
  sd   s4, 0(s9)
#ifdef WP_LOADS
  addi s2, s2, 64               // fresh cold line for the next wrong path
#endif
  xor  t3, s4, s8
  ld   t1, 0(s8)
  or   s3, s3, t1
.endm

.macro VICTIM id, vpad
  .balign 16
victim_\id:
  addi t5, t5, 1
  addi t6, t6, 1
  addi t5, t5, 2
  addi t6, t6, 2
  .if \vpad
  .half 0x0001
  .half 0x0001
  .half 0x0001
  .half 0x0001
  .endif
  sd   s11, 0(s8)
  .half 0x8082                  // c.jr ra
  .half 0x0001
  .if \vpad == 0
  .half 0x0001
  .half 0x0001
  .half 0x0001
  .half 0x0001
  .endif
.endm

// Per-hart setup of the kernel registers.
.macro SETUP
  la   ra, stray_ret
  la   s8, probe
  la   s9, work
  la   s10, zero_word
  la   s2, coldarea
  li   s11, SENTINEL
  li   s4, 0
  li   s3, 0
  li   t2, 0
  li   t5, 0
  li   t6, 0
  li   a6, 1
.endm

  .option norvc
  .section .text.init
  .globl _start
_start:
  .option push
  .option norelax
  la   gp, __global_pointer$
  .option pop
  la   t1, trap
  csrw mtvec, t1
  csrr a7, mhartid              // kept for the whole program
  // hart 0: msip[1] so the sibling is "seen" by the selector at once
  li   t0, CLINT_MSIP
  bnez a7, 2f
  li   t1, 1
  sw   t1, 4(t0)
2:
  slli t1, a7, 2
  add  t1, t0, t1
  sw   zero, 0(t1)              // clear our own msip
  csrw mie, zero
  li   t2, 2
  bge  a7, t2, park             // harts >= 2 park at once
  li   t2, 1
  beq  a7, t2, hart1
  // hart 1 uses a different cold-data stride base so the two harts' cold
  // loads never share a line: coldarea + 32 KiB
  j    hart0

// ---------------------------------------------------------------------------
hart1:
  SETUP
  li   t0, 32768
  add  s2, s2, t0
  PASS   0, 0,  1, 3
  PASS   1, 0,  2, 3
  PASS   2, 0,  3, 3
  PASS   3, 0,  4, 3
  PASS   4, 0,  5, 3
  PASS   5, 0,  6, 3
  PASS   6, 0,  7, 3
  PASS   7, 0,  8, 3
  PASS   8, 0,  9, 3
  PASS   9, 0, 10, 3
  PASS  10, 0, 11, 3
  PASS  11, 0, 12, 3
  PASS  12, 0, 13, 3
  PASS  13, 0, 14, 3
  PASS  14, 0, 15, 3
  PASS  15, 0, 16, 3
  PASS  16, 0, 17, 3
  PASS  17, 0, 18, 3
  PASS  18, 0, 19, 3
  PASS  19, 0, 20, 3
  PASS  20, 0, 21, 3
  PASS  21, 0, 22, 3
  PASS  22, 0, 23, 3
  PASS  23, 0, 24, 3
  PASS  24, 0, 25, 3
  PASS  25, 0, 26, 3
  PASS  26, 0, 27, 3
  PASS  27, 0, 28, 3
  PASS  28, 0, 29, 3
  PASS  29, 0, 30, 3
  PASS  30, 0, 31, 3
  PASS  31, 0, 32, 3
  PASS  32, 0, 33, 3
  PASS  33, 0, 34, 3
  PASS  34, 0, 35, 3
  PASS  35, 0, 36, 3
  PASS  36, 0, 37, 3
  PASS  37, 0, 38, 3
  PASS  38, 0, 39, 3
  PASS  39, 0, 40, 3
  PASS  40, 0, 41, 3
  PASS  41, 0, 42, 3
  PASS  42, 0, 43, 3
  PASS  43, 0, 44, 3
  PASS  44, 0, 45, 3
  PASS  45, 0, 46, 3
  PASS  46, 0, 47, 3
  PASS  47, 0, 48, 3
  PASS  48, 0, 49, 3
  PASS  49, 0, 50, 3
  PASS  50, 0, 51, 3
  PASS  51, 0, 52, 3
  PASS  52, 0, 53, 3
  PASS  53, 0, 54, 3
  PASS  54, 0, 55, 3
  PASS  55, 0, 56, 3
  PASS  56, 0, 57, 3
  PASS  57, 0, 58, 3
  PASS  58, 0, 59, 3
  PASS  59, 0, 60, 3
  PASS  60, 0, 61, 3
  PASS  61, 0, 62, 3
  PASS  62, 0, 63, 3
  PASS  63, 0,  4, 0
  PASS  64, 0,  8, 0
  PASS  65, 0, 12, 0
  PASS  66, 0, 16, 0
  PASS  67, 0, 20, 0
  PASS  68, 0, 24, 0
  PASS  69, 0, 28, 0
  PASS  70, 0, 32, 0
  PASS  71, 0, 36, 0
  PASS  72, 0, 40, 0
  PASS  73, 0, 44, 0
  PASS  74, 0, 48, 0
  PASS  75, 0, 52, 0
  PASS  76, 0, 56, 0
  PASS  77, 0, 60, 0
  PASS  78, 0,  4, 3
  PASS  79, 0,  8, 3
  PASS  80, 0, 12, 3
  PASS  81, 0, 16, 3
  PASS  82, 0, 20, 3
  PASS  83, 0, 24, 3
  PASS  84, 0, 28, 3
  PASS  85, 0, 32, 3
  PASS  86, 0, 36, 3
  PASS  87, 0, 40, 3
  PASS  88, 0, 44, 3
  PASS  89, 0, 48, 3
  PASS  90, 0, 52, 3
  PASS  91, 0, 56, 3
  PASS  92, 0, 60, 3
  PASS  93, 0,  4, 0
  PASS  94, 0,  8, 0
  PASS  95, 0, 12, 0
  PASS  96, 0, 16, 0
  PASS  97, 0, 20, 0
  PASS  98, 0, 24, 0
  PASS  99, 0, 28, 0
  PASS 100, 0, 32, 0
  PASS 101, 0, 36, 0
  PASS 102, 0, 40, 0
  PASS 103, 0, 44, 0
  PASS 104, 0, 48, 0
  PASS 105, 0, 52, 0
  PASS 106, 0, 56, 0
  PASS 107, 0, 60, 0
  PASS 108, 0,  4, 1
  PASS 109, 0,  8, 1
  PASS 110, 0, 12, 1
  PASS 111, 0, 16, 1
  PASS 112, 0, 20, 1
  PASS 113, 0, 24, 1
  PASS 114, 0, 28, 1
  PASS 115, 0, 32, 1
  PASS 116, 0, 36, 1
  PASS 117, 0, 40, 1
  PASS 118, 0, 44, 1
  PASS 119, 0, 48, 1
  PASS 120, 0, 52, 1
  PASS 121, 0, 56, 1
  PASS 122, 0, 60, 1
  PASS 123, 0,  4, 5
  PASS 124, 0,  8, 5
  PASS 125, 0, 12, 5
  PASS 126, 0, 16, 5
  PASS 127, 0, 20, 5
  PASS 128, 0, 24, 5
  PASS 129, 0, 28, 5
  PASS 130, 0, 32, 5
  PASS 131, 0, 36, 5
  PASS 132, 0, 40, 5
  PASS 133, 0, 44, 5
  PASS 134, 0, 48, 5
  PASS 135, 0, 52, 5
  PASS 136, 0, 56, 5
  PASS 137, 0, 60, 5
  PASS 138, 1,  0, 3
  PASS 139, 1,  2, 3
  PASS 140, 1,  4, 3
  PASS 141, 1,  6, 3
  PASS 142, 2,  0, 3
  PASS 143, 2,  2, 3
  PASS 144, 2,  4, 3
  PASS 145, 2,  6, 3
  PASS 146, 2,  8, 3
  PASS 147, 3,  0, 3
  PASS 148, 3,  8, 3
  PASS 149, 3, 16, 3
  PASS 150, 3, 24, 3
  PASS 151, 3, 32, 3
  PASS 152, 3, 40, 3
  PASS 153, 3, 48, 3
  PASS 154, 1,  0, 0
  PASS 155, 1,  2, 0
  PASS 156, 1,  4, 0
  PASS 157, 1,  6, 0
  PASS 158, 2,  0, 0
  PASS 159, 2,  2, 0
  PASS 160, 2,  4, 0
  PASS 161, 2,  6, 0
  PASS 162, 2,  8, 0
  PASS 163, 3,  0, 0
  PASS 164, 3,  8, 0
  PASS 165, 3, 16, 0
  PASS 166, 3, 24, 0
  PASS 167, 3, 32, 0
  PASS 168, 3, 40, 0
  PASS 169, 3, 48, 0
  PASS 170, 2,  0, 3
  PASS 171, 3,  0, 3
  PASS 172, 2,  4, 3
  PASS 173, 3, 16, 3

  la   t0, flag
  li   t1, 1
  sd   t1, 0(t0)
  fence rw, rw
#ifdef SIBLING_SPIN
  la   t0, done
1:ld   t1, 0(t0)
  addi t2, t2, 0
  beqz t1, 1b
#endif
#ifdef SIBLING_IPI
  // Park with MSIE enabled (mstatus.MIE stays 0: no trap): every msip[1]
  // from hart 0 wakes this hart, which clears it and goes back to sleep -
  // the WFI-parked sibling of the boot failure, woken by IPIs around the
  // active hart's mispredicts.
  li   t0, 8
  csrw mie, t0
  li   t1, CLINT_MSIP + 4
2:wfi
  sw   zero, 0(t1)
  j    2b
#endif
  j    park

// ---------------------------------------------------------------------------
hart0:
  SETUP
  li   a4, CLINT_MSIP + 4
  li   a5, 1
  la   t0, flag
  li   t3, SPIN_TO
1:ld   t1, 0(t0)
  bnez t1, 2f
  addi t3, t3, -1
  bnez t3, 1b
  j    fail_spin
2:
  PASS   0, 0,  1, 3
  PASS   1, 0,  2, 3
  PASS   2, 0,  3, 3
  PASS   3, 0,  4, 3
  PASS   4, 0,  5, 3
  PASS   5, 0,  6, 3
  PASS   6, 0,  7, 3
  PASS   7, 0,  8, 3
  PASS   8, 0,  9, 3
  PASS   9, 0, 10, 3
  PASS  10, 0, 11, 3
  PASS  11, 0, 12, 3
  PASS  12, 0, 13, 3
  PASS  13, 0, 14, 3
  PASS  14, 0, 15, 3
  PASS  15, 0, 16, 3
  PASS  16, 0, 17, 3
  PASS  17, 0, 18, 3
  PASS  18, 0, 19, 3
  PASS  19, 0, 20, 3
  PASS  20, 0, 21, 3
  PASS  21, 0, 22, 3
  PASS  22, 0, 23, 3
  PASS  23, 0, 24, 3
  PASS  24, 0, 25, 3
  PASS  25, 0, 26, 3
  PASS  26, 0, 27, 3
  PASS  27, 0, 28, 3
  PASS  28, 0, 29, 3
  PASS  29, 0, 30, 3
  PASS  30, 0, 31, 3
  PASS  31, 0, 32, 3
  PASS  32, 0, 33, 3
  PASS  33, 0, 34, 3
  PASS  34, 0, 35, 3
  PASS  35, 0, 36, 3
  PASS  36, 0, 37, 3
  PASS  37, 0, 38, 3
  PASS  38, 0, 39, 3
  PASS  39, 0, 40, 3
  PASS  40, 0, 41, 3
  PASS  41, 0, 42, 3
  PASS  42, 0, 43, 3
  PASS  43, 0, 44, 3
  PASS  44, 0, 45, 3
  PASS  45, 0, 46, 3
  PASS  46, 0, 47, 3
  PASS  47, 0, 48, 3
  PASS  48, 0, 49, 3
  PASS  49, 0, 50, 3
  PASS  50, 0, 51, 3
  PASS  51, 0, 52, 3
  PASS  52, 0, 53, 3
  PASS  53, 0, 54, 3
  PASS  54, 0, 55, 3
  PASS  55, 0, 56, 3
  PASS  56, 0, 57, 3
  PASS  57, 0, 58, 3
  PASS  58, 0, 59, 3
  PASS  59, 0, 60, 3
  PASS  60, 0, 61, 3
  PASS  61, 0, 62, 3
  PASS  62, 0, 63, 3
  PASS  63, 0,  4, 0
  PASS  64, 0,  8, 0
  PASS  65, 0, 12, 0
  PASS  66, 0, 16, 0
  PASS  67, 0, 20, 0
  PASS  68, 0, 24, 0
  PASS  69, 0, 28, 0
  PASS  70, 0, 32, 0
  PASS  71, 0, 36, 0
  PASS  72, 0, 40, 0
  PASS  73, 0, 44, 0
  PASS  74, 0, 48, 0
  PASS  75, 0, 52, 0
  PASS  76, 0, 56, 0
  PASS  77, 0, 60, 0
  PASS  78, 0,  4, 3
  PASS  79, 0,  8, 3
  PASS  80, 0, 12, 3
  PASS  81, 0, 16, 3
  PASS  82, 0, 20, 3
  PASS  83, 0, 24, 3
  PASS  84, 0, 28, 3
  PASS  85, 0, 32, 3
  PASS  86, 0, 36, 3
  PASS  87, 0, 40, 3
  PASS  88, 0, 44, 3
  PASS  89, 0, 48, 3
  PASS  90, 0, 52, 3
  PASS  91, 0, 56, 3
  PASS  92, 0, 60, 3
  PASS  93, 0,  4, 0
  PASS  94, 0,  8, 0
  PASS  95, 0, 12, 0
  PASS  96, 0, 16, 0
  PASS  97, 0, 20, 0
  PASS  98, 0, 24, 0
  PASS  99, 0, 28, 0
  PASS 100, 0, 32, 0
  PASS 101, 0, 36, 0
  PASS 102, 0, 40, 0
  PASS 103, 0, 44, 0
  PASS 104, 0, 48, 0
  PASS 105, 0, 52, 0
  PASS 106, 0, 56, 0
  PASS 107, 0, 60, 0
  PASS 108, 0,  4, 1
  PASS 109, 0,  8, 1
  PASS 110, 0, 12, 1
  PASS 111, 0, 16, 1
  PASS 112, 0, 20, 1
  PASS 113, 0, 24, 1
  PASS 114, 0, 28, 1
  PASS 115, 0, 32, 1
  PASS 116, 0, 36, 1
  PASS 117, 0, 40, 1
  PASS 118, 0, 44, 1
  PASS 119, 0, 48, 1
  PASS 120, 0, 52, 1
  PASS 121, 0, 56, 1
  PASS 122, 0, 60, 1
  PASS 123, 0,  4, 5
  PASS 124, 0,  8, 5
  PASS 125, 0, 12, 5
  PASS 126, 0, 16, 5
  PASS 127, 0, 20, 5
  PASS 128, 0, 24, 5
  PASS 129, 0, 28, 5
  PASS 130, 0, 32, 5
  PASS 131, 0, 36, 5
  PASS 132, 0, 40, 5
  PASS 133, 0, 44, 5
  PASS 134, 0, 48, 5
  PASS 135, 0, 52, 5
  PASS 136, 0, 56, 5
  PASS 137, 0, 60, 5
  PASS 138, 1,  0, 3
  PASS 139, 1,  2, 3
  PASS 140, 1,  4, 3
  PASS 141, 1,  6, 3
  PASS 142, 2,  0, 3
  PASS 143, 2,  2, 3
  PASS 144, 2,  4, 3
  PASS 145, 2,  6, 3
  PASS 146, 2,  8, 3
  PASS 147, 3,  0, 3
  PASS 148, 3,  8, 3
  PASS 149, 3, 16, 3
  PASS 150, 3, 24, 3
  PASS 151, 3, 32, 3
  PASS 152, 3, 40, 3
  PASS 153, 3, 48, 3
  PASS 154, 1,  0, 0
  PASS 155, 1,  2, 0
  PASS 156, 1,  4, 0
  PASS 157, 1,  6, 0
  PASS 158, 2,  0, 0
  PASS 159, 2,  2, 0
  PASS 160, 2,  4, 0
  PASS 161, 2,  6, 0
  PASS 162, 2,  8, 0
  PASS 163, 3,  0, 0
  PASS 164, 3,  8, 0
  PASS 165, 3, 16, 0
  PASS 166, 3, 24, 0
  PASS 167, 3, 32, 0
  PASS 168, 3, 40, 0
  PASS 169, 3, 48, 0
  PASS 170, 2,  0, 3
  PASS 171, 3,  0, 3
  PASS 172, 2,  4, 3
  PASS 173, 3, 16, 3

  // final checks (hart 0)
  ld   t1, 0(s8)
  or   s3, s3, t1
  bnez s3, fail_leak
  bnez t5, fail_victim
  bnez t6, fail_victim
  bnez t2, fail_filler
  li   t0, 174
#ifdef ORACLE_NEGATIVE
  addi t0, t0, 1
#endif
  bne  s4, t0, fail_count
  la   t0, done
  li   t1, 1
  sd   t1, 0(t0)
  li   a0, 1
  j    report

fail_leak:
  li   a0, 5
  j    report
fail_victim:
  li   a0, 7
  j    report
fail_filler:
  li   a0, 9
  j    report
fail_count:
#ifdef ORACLE_NEGATIVE
  li   a0, 3
#else
  li   a0, 11
#endif
  j    report
stray_ret:
  li   a0, 13
  j    report
fail_trap:
  li   a0, 15
  j    report
fail_spin:
  li   a0, 17
  j    report

park:
  wfi
  j    park

report:
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
  j    park

  // M-mode trap vector: ecall skips itself (BPFLUSH), anything else fails.
  .align 2
trap:
  csrr t0, mcause
  li   t1, 11
  bne  t0, t1, fail_trap
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  mret

  .section .text.victims, "ax", @progbits
  VICTIM   0, 8
  VICTIM   1, 8
  VICTIM   2, 8
  VICTIM   3, 8
  VICTIM   4, 8
  VICTIM   5, 8
  VICTIM   6, 8
  VICTIM   7, 8
  VICTIM   8, 8
  VICTIM   9, 8
  VICTIM  10, 8
  VICTIM  11, 8
  VICTIM  12, 8
  VICTIM  13, 8
  VICTIM  14, 8
  VICTIM  15, 8
  VICTIM  16, 8
  VICTIM  17, 8
  VICTIM  18, 8
  VICTIM  19, 8
  VICTIM  20, 8
  VICTIM  21, 8
  VICTIM  22, 8
  VICTIM  23, 8
  VICTIM  24, 8
  VICTIM  25, 8
  VICTIM  26, 8
  VICTIM  27, 8
  VICTIM  28, 8
  VICTIM  29, 8
  VICTIM  30, 8
  VICTIM  31, 8
  VICTIM  32, 8
  VICTIM  33, 8
  VICTIM  34, 8
  VICTIM  35, 8
  VICTIM  36, 8
  VICTIM  37, 8
  VICTIM  38, 8
  VICTIM  39, 8
  VICTIM  40, 8
  VICTIM  41, 8
  VICTIM  42, 8
  VICTIM  43, 8
  VICTIM  44, 8
  VICTIM  45, 8
  VICTIM  46, 8
  VICTIM  47, 8
  VICTIM  48, 8
  VICTIM  49, 8
  VICTIM  50, 8
  VICTIM  51, 8
  VICTIM  52, 8
  VICTIM  53, 8
  VICTIM  54, 8
  VICTIM  55, 8
  VICTIM  56, 8
  VICTIM  57, 8
  VICTIM  58, 8
  VICTIM  59, 8
  VICTIM  60, 8
  VICTIM  61, 8
  VICTIM  62, 8
  VICTIM  63, 8
  VICTIM  64, 8
  VICTIM  65, 8
  VICTIM  66, 8
  VICTIM  67, 8
  VICTIM  68, 8
  VICTIM  69, 8
  VICTIM  70, 8
  VICTIM  71, 8
  VICTIM  72, 8
  VICTIM  73, 8
  VICTIM  74, 8
  VICTIM  75, 8
  VICTIM  76, 8
  VICTIM  77, 8
  VICTIM  78, 0
  VICTIM  79, 0
  VICTIM  80, 0
  VICTIM  81, 0
  VICTIM  82, 0
  VICTIM  83, 0
  VICTIM  84, 0
  VICTIM  85, 0
  VICTIM  86, 0
  VICTIM  87, 0
  VICTIM  88, 0
  VICTIM  89, 0
  VICTIM  90, 0
  VICTIM  91, 0
  VICTIM  92, 0
  VICTIM  93, 0
  VICTIM  94, 0
  VICTIM  95, 0
  VICTIM  96, 0
  VICTIM  97, 0
  VICTIM  98, 0
  VICTIM  99, 0
  VICTIM 100, 0
  VICTIM 101, 0
  VICTIM 102, 0
  VICTIM 103, 0
  VICTIM 104, 0
  VICTIM 105, 0
  VICTIM 106, 0
  VICTIM 107, 0
  VICTIM 108, 8
  VICTIM 109, 8
  VICTIM 110, 8
  VICTIM 111, 8
  VICTIM 112, 8
  VICTIM 113, 8
  VICTIM 114, 8
  VICTIM 115, 8
  VICTIM 116, 8
  VICTIM 117, 8
  VICTIM 118, 8
  VICTIM 119, 8
  VICTIM 120, 8
  VICTIM 121, 8
  VICTIM 122, 8
  VICTIM 123, 8
  VICTIM 124, 8
  VICTIM 125, 8
  VICTIM 126, 8
  VICTIM 127, 8
  VICTIM 128, 8
  VICTIM 129, 8
  VICTIM 130, 8
  VICTIM 131, 8
  VICTIM 132, 8
  VICTIM 133, 8
  VICTIM 134, 8
  VICTIM 135, 8
  VICTIM 136, 8
  VICTIM 137, 8
  VICTIM 138, 8
  VICTIM 139, 8
  VICTIM 140, 8
  VICTIM 141, 8
  VICTIM 142, 8
  VICTIM 143, 8
  VICTIM 144, 8
  VICTIM 145, 8
  VICTIM 146, 8
  VICTIM 147, 8
  VICTIM 148, 8
  VICTIM 149, 8
  VICTIM 150, 8
  VICTIM 151, 8
  VICTIM 152, 8
  VICTIM 153, 8
  VICTIM 154, 8
  VICTIM 155, 8
  VICTIM 156, 8
  VICTIM 157, 8
  VICTIM 158, 8
  VICTIM 159, 8
  VICTIM 160, 8
  VICTIM 161, 8
  VICTIM 162, 8
  VICTIM 163, 8
  VICTIM 164, 8
  VICTIM 165, 8
  VICTIM 166, 8
  VICTIM 167, 8
  VICTIM 168, 8
  VICTIM 169, 8
  VICTIM 170, 0
  VICTIM 171, 0
  VICTIM 172, 0
  VICTIM 173, 0

  .data
  .balign 64
flag:      .dword 0
  .balign 64
done:      .dword 0
  .balign 64
probe:     .dword 0
  .balign 64
work:      .dword 0
  .balign 64
zero_word: .dword 0
  .balign 64
coldarea:  .skip 64*1024

.section ".tohost","aw",@progbits
  .balign 64
  .globl tohost
tohost: .dword 0
