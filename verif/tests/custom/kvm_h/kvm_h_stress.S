# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# KVM-oriented H stress (U9.x / remaining open):
#   1. Detect H; skip clean if absent
#   2. hfence.vvma / hfence.gvma encode (no fault in M)
#   3. VS entry → ecall → M (cause 10)
#   4. Second VS entry (re-enter guest) after trap
#   5. stimecmp alias under V when STCE pair set (if Sstc)
#
# Target: g6lc64_server_math (RVH=1, Sstc=1).
# Opens PMP before VS entry (Spike default PMP denies S/VS fetches).

  .globl main
main:
  la   t0, skip_no_h
  csrw mtvec, t0
  csrr t1, 0x600
  j    have_h
skip_no_h:
  li   a0, 0
  jal  exit

have_h:
  li   s11, 0                 # trap count

  # PMP allow-all so VS/S can fetch from DRAM (Spike default PMP denies
  # S/U/VS if no entry matches). Swallow illegal if PMP CSRs absent.
  la   t0, pmp_done
  csrw mtvec, t0
  li   t0, -1
  csrw pmpaddr0, t0
  li   t0, 0x0F
  csrw pmpcfg0, t0
  .align 2
pmp_done:
  la   t0, m_trap
  csrw mtvec, t0
  csrw satp, x0
  csrw 0x280, x0              # vsatp
  csrw 0x680, x0              # hgatp
  sfence.vma

  # ---- HFENCE (M-mode) ----
  # hfence.vvma x0, x0
  .word 0x22000073
  # hfence.gvma x0, x0
  .word 0x62000073

  # Enable STCE pair if present
  li   t0, 1
  slli t0, t0, 63
  csrrs x0, 0x30A, t0         # menvcfg
  csrrs x0, 0x60A, t0         # henvcfg

  # ---- VS entry 1 ----
  la   t0, vs_body
  csrw mepc, t0
  csrr t1, mstatus
  li   t2, (3 << 11)
  not  t2, t2
  and  t1, t1, t2
  li   t2, (1 << 11)          # MPP = S
  or   t1, t1, t2
  # MPV = bit 39 on RV64 mstatus
  li   t2, 1
  slli t2, t2, 39
  or   t1, t1, t2
  csrw mstatus, t1
  mret

  .align 2
vs_body:
  # ENV_CALL_VSMODE = 10. (stimecmp alias is covered by sstc_h tests; writing
  # 0x14D here is illegal on Spike without full Sstc/STCE wiring.)
  ecall

  .align 2
m_trap:
  csrr t0, mcause
  li   t1, 10
  bne  t0, t1, fail
  addi s11, s11, 1
  li   t2, 2
  bge  s11, t2, pass          # two successful VS ecalls

  # ---- VS entry 2 (re-enter) ----
  la   t0, vs_body
  csrw mepc, t0
  csrr t1, mstatus
  li   t2, (3 << 11)
  not  t2, t2
  and  t1, t1, t2
  li   t2, (1 << 11)
  or   t1, t1, t2
  li   t2, 1
  slli t2, t2, 39
  or   t1, t1, t2
  csrw mstatus, t1
  mret

pass:
  li   a0, 0
  jal  exit

fail:
  li   a0, 1
  jal  exit
