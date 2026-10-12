# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Core sleep gate (CVA6Cfg.CoreSleepGate) wake-up witness.
#
# A core whose harts all sit in WFI loses its clock in g6lc_cluster; this test
# drives every ungated wake path of the gate from software and checks that the
# hart comes back and sees what it waited for:
#
#   step 1  hart 0: CLINT mtimecmp in the future, mie.MTIE, wfi  -> wakes, mtime >= mtimecmp
#   step 2  hart 0: Sstc stimecmp (menvcfg.STCE, mie.STIE), wfi  -> wakes, mtime >= stimecmp
#   step 3  hart 0 sends a CLINT IPI to hart 2 (another core, parked in wfi with
#           mie.MSIE); hart 2 wakes, clears msip, publishes a flag; hart 0 polls it
#
# mstatus.MIE stays 0 throughout: WFI must complete on a pending *enabled*
# interrupt without a trap being taken, so a trap of any kind is a failure.
# Every other hart parks in wfi with mie = 0 and never wakes (whole cores gated
# for the entire run on a 4-core server). Same program on a gate-less model is
# the exactness reference: the RVFI traces, including the mtime values read
# after each wake, must match byte for byte (the gate adds no wake latency).
#
# tohost: 1 pass; 3 timer wake observed mtime < mtimecmp; 5 IPI flag timeout;
# 7 Sstc wake observed mtime < stimecmp; 32 + ((mcause<<1)|1) trap.
# Needs NrCores >= 2, NrHarts >= 2 (hart 2 is core 1), SstcEn.

#define CLINT_BASE  0x02000000
#define CLINT_MSIP  0x0000
#define CLINT_CMP   0x4000
#define CLINT_MTIME 0xBFF8
#define CSR_STIMECMP 0x14D
#define CSR_MENVCFG  0x30A

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap_vec
  csrw mtvec, t1
  csrci mstatus, 0x8            # MIE = 0: wake without taking the trap
  li   s0, CLINT_BASE
  li   s1, CLINT_BASE + CLINT_CMP     # mtimecmp[0]
  li   s2, CLINT_BASE + CLINT_MTIME   # mtime
  beqz t0, hart0
  li   t1, 2
  beq  t0, t1, hart2
park:
  csrw mie, zero
0:
  wfi
  j    0b

  # ---------------------------------------------------------------- hart 2
hart2:
  li   t1, 0x8                  # mie.MSIE
  csrw mie, t1
1:
  wfi
  csrr t2, mip
  andi t2, t2, 0x8
  beqz t2, 1b
  sw   zero, CLINT_MSIP+8(s0)   # clear my msip
  fence rw, rw
  la   t3, flag
  li   t4, 1
  sw   t4, 0(t3)
  fence rw, rw
  j    park

  # ---------------------------------------------------------------- hart 0
hart0:
  # ---- step 1: M-mode timer ----
  li   t1, 0x80                 # mie.MTIE
  csrw mie, t1
  ld   t2, 0(s2)
  addi t2, t2, 2000
  sd   t2, 0(s1)                # mtimecmp[0]
  fence rw, rw
  wfi
  ld   t3, 0(s2)
  li   a0, 3
  bltu t3, t2, done             # woke before the compare matched
  li   t3, -1
  sd   t3, 0(s1)                # disarm
  fence rw, rw

  # ---- step 2: Sstc stimecmp ----
  li   t1, 1
  slli t1, t1, 63               # menvcfg.STCE
  csrs CSR_MENVCFG, t1
  li   t1, 0x20                 # mie.STIE
  csrw mie, t1
  ld   t2, 0(s2)
  addi t2, t2, 2000
  csrw CSR_STIMECMP, t2
  wfi
  ld   t3, 0(s2)
  li   a0, 7
  bltu t3, t2, done
  li   t3, -1
  csrw CSR_STIMECMP, t3         # disarm
  csrw mie, zero

  # ---- step 3: IPI wake of hart 2 (core 1) ----
  li   t1, 1
  sw   t1, CLINT_MSIP+8(s0)     # msip[2]
  fence rw, rw
  la   t3, flag
  li   t4, 200000
2:
  lw   t5, 0(t3)
  bnez t5, 3f
  addi t4, t4, -1
  bnez t4, 2b
  li   a0, 5
  j    done
3:
  li   a0, 1
done:
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
4:
  j    4b

trap_vec:
  csrr a0, mcause
  andi a0, a0, 0xff
  slli a0, a0, 1
  ori  a0, a0, 1
  addi a0, a0, 32
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
5:
  j    5b

  .section .data
  .align 6
flag: .dword 0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
