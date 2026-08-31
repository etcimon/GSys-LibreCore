# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# ORACLE CONTROL (negative) - heuristic H3 "Oracle Validity First".
# architecture/AGENTS-g6lc-opensbi-dev-heuristics.md s5 M1.
#
# NEGATIVE CONTROL. Expected verdict is FAIL. If the suite reports this as
# PASS, the classifier is pass-biased (the 2026-08-31 class) and every recorded
# PASS is void.
#
# On 2026-08-31 the DI classifier was found to accept the harness timeout line
# "*** SUCCESS *** (tohost = 0)" as a pass. A broken-in-one-direction oracle is
# invisible without a control that must come back FAIL, which is what this is:
# park every hart but 0, write tohost = 3 (the repo FAIL code), spin. Nothing
# here can succeed, so any PASS verdict is a defect in the classifier, not in
# the core.
#
# NOT a suite member. verif/regress/soft-ladder-di-regress.sh and
# verif/regress/remote/testharness_proxy.py run it as a preflight gate ahead of
# the DI list and abort the run if it gives the wrong answer.
#
# Gate: Variane/g6lc64_smt2 DI; tohost=1 pass, 3 fail. Expected verdict: FAIL.

  .section .text.init
  .globl _start
_start:
  # SMT2 both harts fetch reset. Spike is one hart. Park non-zero
  # mhartid before touching the shared tohost.
  csrr t0, mhartid
  bnez t0, .Lpark

  # FAIL, unconditionally.
  li   t0, 3
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
