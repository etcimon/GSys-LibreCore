# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Directed smoke for U9.0/U9.1/U9.2 Sstc × H (needs RVH+Sstc package):
#   1. htimedelta R/W (0x605)
#   2. vstimecmp R/W (0x24D) with menvcfg.STCE + henvcfg.STCE
#   3. VSTIP pending in mip/hip when guest_time >= vstimecmp
#   4. Enter VS (mstatus.MPV=1, MPP=S, mret); stimecmp aliases vstimecmp
#   5. ecall from VS → M (cause ENV_CALL_VSMODE=10)
#
# Self-skips (exit 0) if H is not present.

  .globl main
main:
  # ---- detect H; trap → skip ----
  la   t0, skip_no_h
  csrw mtvec, t0
  csrr t1, 0x600             # hstatus
  j    have_h
skip_no_h:
  li   a0, 0
  jal  exit

have_h:
  la   t0, m_trap
  csrw mtvec, t0

  # Enable menvcfg.STCE / henvcfg.STCE (bit 63)
  li   t0, 1
  slli t0, t0, 63
  csrrs x0, 0x30A, t0
  csrrs x0, 0x60A, t0

  # ---- htimedelta ----
  li   t2, 0x0000000012345678
  csrw 0x605, t2
  csrr t3, 0x605
  bne  t2, t3, fail
  li   t2, 0x100
  csrw 0x605, t2             # small guest delta for TIME under V

  # ---- vstimecmp R/W ----
  li   t2, 0x00000000DEADBEEF
  csrw 0x24D, t2
  csrr t3, 0x24D
  bne  t2, t3, fail

  # Force VSTIP: vstimecmp = 0 ⇒ guest_time >= 0
  csrw 0x24D, x0

  # Delegate VS-timer to S (mideleg.VSTI); leave hideleg.VSTI=0 (HS-visible)
  li   t2, (1 << 6)
  csrrs x0, mideleg, t2
  csrc 0x603, t2             # hideleg clear VSTI

  # Enable VSTIE so mip&mie can show the condition; check mip before taking it
  csrrs x0, mie, t2

  csrr t3, mip
  and  t3, t3, t2
  beqz t3, fail              # mip.VSTIP must be set

  csrr t3, 0x644             # hip
  and  t3, t3, t2
  beqz t3, fail              # hip.VSTIP

  # Disarm timer + clear VSTIE so VS entry is not immediately interrupted
  li   t2, -1
  csrw 0x24D, t2
  li   t2, (1 << 6)
  csrc mie, t2

  # ---- VS entry: mepc=vs_entry, MPP=S, MPV=1, mret ----
  la   t0, vs_entry
  csrw mepc, t0
  csrr t1, mstatus
  li   t2, (3 << 11)
  not  t2, t2
  and  t1, t1, t2            # clear MPP
  li   t2, (1 << 11)
  or   t1, t1, t2            # MPP = S
  li   t2, 1
  slli t2, t2, 39            # MPV
  or   t1, t1, t2
  csrw mstatus, t1
  mret
  j    fail

# VS-mode (priv=S, V=1)
vs_entry:
  # stimecmp (0x14D) is alias of vstimecmp under V when STCE pair is set
  li   t2, 0x55AA55AA
  csrw 0x14D, t2
  csrr t3, 0x14D
  bne  t2, t3, vs_fail

  # Leave vstimecmp far future
  li   t2, -1
  csrw 0x14D, t2

  # ecall from VS → M (default medeleg=0): cause ENV_CALL_VSMODE = 10
  ecall
  j    vs_fail

vs_fail:
  ecall
  j    fail

# M-mode trap handler
m_trap:
  csrr t0, mcause
  li   t1, 10                # ENV_CALL_VSMODE
  beq  t0, t1, pass
  li   t1, 9                 # ENV_CALL_SMODE (if V not sticky)
  beq  t0, t1, pass
  j    fail

pass:
  li   a0, 0
  jal  exit

fail:
  li   a0, 1
  jal  exit
