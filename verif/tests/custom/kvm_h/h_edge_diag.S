# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# H-edge directed diagnostics (AGENTS-todo §3):
#   1. hedeleg WARL — only legal exception bits stick
#   2. VTSR  → SRET under VS → virtual-instruction (cause 22)
#   3. VTVM  → satp write under VS → cause 22
#   4. VTW   → WFI under VS → cause 22
#   5. MPV after VS→M ecall trap (mstatus.MPV set)
#
# Target: g6lc64_server_math (RVH=1). Self-skip pass if H absent.
# FAIL codes (a0): 0=pass, 1=generic/cause, 2=hedeleg, 3=vtsr, 4=vtvm, 5=vtw, 6=mpv
#
# Spike note: default PMP regions deny S/U/VS fetches until programmed (or
# --pmpregions=0). Open an all-memory TOR entry before any mret out of M.

  .globl main
main:
  la   t0, skip_no_h
  csrw mtvec, t0
  csrr t1, 0x600              # hstatus — illegal if no H
  j    have_h
skip_no_h:
  li   a0, 0
  jal  exit

have_h:
  li   s10, 0                 # expected cause (0 = ecall path)
  li   s11, 0                 # phase id for trap handler

  # ---- PMP: permit all modes to access DRAM ----
  # Spike default implements PMP; with no matching entry, S/U/VS fetch faults.
  # If PMP CSRs are absent (illegal), swallow and continue (bare allow).
  la   t0, pmp_done
  csrw mtvec, t0
  li   t0, -1
  csrw pmpaddr0, t0
  li   t0, 0x0F               # TOR | R | W | X
  csrw pmpcfg0, t0
  .align 2
pmp_done:
  la   t0, m_trap
  csrw mtvec, t0
  csrw satp, x0
  csrw 0x280, x0              # vsatp
  csrw 0x680, x0              # hgatp
  sfence.vma

  # ========== 1. hedeleg WARL ==========
  # Legal mask matches csr_regfile.sv CSR_HEDELEG (not VS-ecall 10, not 22).
  # bits: 0,1,2,3,4,5,6,7,8,12,13,15
  li   t0, -1
  csrw 0x602, t0              # hedeleg
  csrr t1, 0x602
  li   t2, 0xB1FF             # 0b1011_0001_1111_1111 = bits 0-8,12,13,15
  and  t3, t1, t2
  bne  t1, t3, fail_hedeleg
  # illegal bits must be zero
  not  t4, t2
  and  t5, t1, t4
  bnez t5, fail_hedeleg
  # clear hedeleg for later tests
  csrw 0x602, x0

  # ========== 2. VTSR → SRET under VS → cause 22 ==========
  # hstatus.VTSR = bit 22
  li   t0, (1 << 22)
  csrs 0x600, t0
  li   s10, 22
  li   s11, 2
  la   t0, vs_sret
  jal  enter_vs
  j    fail_vtsr              # must not return normally

  .align 2
vs_sret:
  sret                        # should virtual-instr trap
  j    fail_vtsr

  # ========== 3. VTVM → satp CSR under VS → cause 22 ==========
  .align 2
phase_vtvm:
  # clear VTSR, set VTVM (bit 20)
  li   t0, (1 << 22)
  csrc 0x600, t0
  li   t0, (1 << 20)
  csrs 0x600, t0
  li   s10, 22
  li   s11, 3
  la   t0, vs_satp
  jal  enter_vs
  j    fail_vtvm

  .align 2
vs_satp:
  li   t0, 0
  csrw 0x180, t0              # satp → vsatp under V; VTVM intercept
  j    fail_vtvm

  # ========== 4. VTW → WFI under VS → cause 22 ==========
  .align 2
phase_vtw:
  li   t0, (1 << 20)
  csrc 0x600, t0
  li   t0, (1 << 21)          # VTW
  csrs 0x600, t0
  li   s10, 22
  li   s11, 4
  la   t0, vs_wfi
  jal  enter_vs
  j    fail_vtw

  .align 2
vs_wfi:
  wfi
  j    fail_vtw

  # ========== 5. VS ecall → M, MPV set ==========
  .align 2
phase_mpv:
  # clear VTW
  li   t0, (1 << 21)
  csrc 0x600, t0
  li   s10, 10                # ENV_CALL_VSMODE
  li   s11, 5
  la   t0, vs_ecall
  jal  enter_vs
  j    fail_mpv

  .align 2
vs_ecall:
  ecall
  j    fail_mpv

# ---------- enter VS: t0 = guest PC ----------
# Uses t0 as entry PC. Clobbers t1,t2. Returns via mret (no ret).
  .align 2
enter_vs:
  csrw mepc, t0
  csrr t1, mstatus
  # MPP = S (01)
  li   t2, (3 << 11)
  not  t2, t2
  and  t1, t1, t2
  li   t2, (1 << 11)
  or   t1, t1, t2
  # MPV = 1 (bit 39)
  li   t2, 1
  slli t2, t2, 39
  or   t1, t1, t2
  csrw mstatus, t1
  mret

# ---------- M-mode trap (must be 4-byte aligned for mtvec) ----------
  .align 2
m_trap:
  csrr t0, mcause
  bne  t0, s10, fail_cause
  # dispatch by phase
  li   t1, 2
  beq  s11, t1, after_vtsr
  li   t1, 3
  beq  s11, t1, after_vtvm
  li   t1, 4
  beq  s11, t1, after_vtw
  li   t1, 5
  beq  s11, t1, after_mpv
  j    fail_generic

after_vtsr:
  j    phase_vtvm
after_vtvm:
  j    phase_vtw
after_vtw:
  j    phase_mpv
after_mpv:
  # mstatus.MPV must be 1 after trap from VS
  csrr t0, mstatus
  li   t1, 1
  slli t1, t1, 39
  and  t2, t0, t1
  beqz t2, fail_mpv
  j    pass

fail_cause:
  li   a0, 1
  jal  exit
fail_hedeleg:
  li   a0, 2
  jal  exit
fail_vtsr:
  li   a0, 3
  jal  exit
fail_vtvm:
  li   a0, 4
  jal  exit
fail_vtw:
  li   a0, 5
  jal  exit
fail_mpv:
  li   a0, 6
  jal  exit
fail_generic:
  li   a0, 1
  jal  exit
pass:
  li   a0, 0
  jal  exit
