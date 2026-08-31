# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# ORACLE CONTROL (positive) - heuristic H3 "Oracle Validity First".
# architecture/AGENTS-g6lc-opensbi-dev-heuristics.md s5 M1.
#
# POSITIVE CONTROL. If this fails, the oracle cannot say PASS and every other
# verdict in the run is void.
#
# The shortest possible directed mini: park every hart but 0, write tohost = 1,
# spin. No stack, no mtvec, no trap handler, no memory under test, no AMO. A
# failure here is a harness / toolchain / linker-script defect, never a core
# defect, so no per-test result collected alongside it can be believed.
#
# NOT a suite member. verif/regress/soft-ladder-di-regress.sh and
# verif/regress/remote/testharness_proxy.py run it as a preflight gate ahead of
# the DI list and abort the run if it gives the wrong answer.
#
# Gate: Variane/g6lc64_smt2 DI; tohost=1 pass, 3 fail. Expected verdict: PASS.

  .section .text.init
  .globl _start
_start:
  # SMT2 both harts fetch reset. Spike is one hart. Park non-zero
  # mhartid before touching the shared tohost.
  csrr t0, mhartid
  bnez t0, .Lpark

  # PASS, unconditionally.
  li   t0, 1
  la   t1, tohost
  sw   t0, 0(t1)
1: j    1b

.Lpark:
  wfi
  j    .Lpark

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
