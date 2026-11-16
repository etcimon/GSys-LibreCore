# r130 — SC-backoff pairing: only paired LR/SC failures grow the retry exponent

Scope: `core/cache_subsystem/wt_dcache_missunit.sv`,
`verif/tb/core/tb_g6lc_hyp8_control.sv`. Latency/liveness-motivated change to
the LR/SC exponential backoff; the architectural contract is unchanged —
paired SC failures still back off identically. The default binding is the
profile the Linux witnesses run.

## 1. Test data (r127m witness)

`hyp8-osbi-scalar-r127m` (closure-r127m, default binding) passed both Linux
markers (`G6LC_LINUX_INIT_UP`, `G6LC_LINUX_SHELL`, monitor exit 0) and ran its
full budget. Its stall census still showed two long commit-head stalls:

- ~396.95M cycles: 15,369-cycle gap, last commit `0xffffffff8011eb8a`, resume
  `0xffffffff8065b78e`.
- ~429.42M cycles: 34,889-cycle gap, same resume PC.

Hang-dump state at both: scoreboard head slot 7 `issued=1 valid=1 fu=2 op=62
pc=ffffffff8065b78e` (an `lr.d`), `issue_valid=00 issue_ack=00`, LSU units
idle, load buffer empty, frontend `cf_hold=1 bp_pend=1` — the head was an LR
waiting on the missunit AMO path, not a frontend or D$-miss stall.

LR/SC survey through ~1.56B cycles: 59,850 LR / 63,349 SC retired; **all
3,620 failing SCs at one PC `0xffffffff8065fe56`** (the kernel's deliberate
reservation clear after trap return); only **1** failing SC was paired with an
LR since the previous SC — 3,619 were unpaired.

## 2. Mechanism

`wt_dcache_missunit` feeds every SC failure (`sc_result_valid && result!=0`)
to `g6lc_hyp_exp_backoff.set_i`, which shifts the 16-bit mask left and reloads
the wait counter with `mask & lfsr`. The `AMO` state holds an LR request until
`sc_backoff_over`. Each unpaired kernel reservation-clear SC therefore grew
the exponent even though it is not a contention retry; ~16 of them saturated
the mask to 16 bits and parked the next real LR for tens of thousands of
cycles (observed 15k/35k).

The reservation itself lives in `hpdcache_uncached` (`lrsc_rsrv_*`); every SC
clears it unconditionally (`lrsc_uc_reset=1`), so an SC can only fail for two
reasons: no reservation was held (unpaired — kernel clear, buggy code), or a
held reservation was lost to a conflicting access (paired — genuine
contention). Only the second is a retry worth backing off for.

## 3. Fix

`lr_pending_q` tracks pairing exactly, using the missunit's depth-1 ordering:
set when an LR result is presented (`state_q==AMO_RESULT && amo_op==AMO_LR`),
cleared by the next SC result (`amo_op==AMO_SC`). `set_i` becomes
`sc_fail && lr_pending_q`; `clr_i` (`sc_pass`) is unchanged — a pass implies a
live reservation anyway.

Safety: a genuine LR/SC retry loop is `LR → SC(fail) → LR → SC(fail)…`; every
SC in it is preceded by an LR, so paired failures still grow the mask
identically. Under-counting cannot occur (flag=0 ⇒ no live reservation ⇒ the
SC was never a retry). Over-counting is bounded to one extra count if a
conflicting AMO cleared the reservation between LR and SC — the safe
direction. SMT2 is unaffected: the flag is per-missunit-instance.

## 4. Verification

- `sc-backoff` leaf (`G6LC_HYP8_SC_BACKOFF_ONLY`), pinned remote toolchain
  `verilator-v5.008-g6lc-44063db8-pgo` + runtime digest
  `e900ec45…`: **HYP8_SC_BACKOFF_PASS checked=55**. `sc_backoff_cases`
  rewritten for the pairing contract: unpaired SC fail → mask stays 0;
  LR → SC fail → mask=1; LR/ADD between → next SC still paired → mask=3;
  pass clears; SC→SC second failure unpaired → mask holds.
- `memory` leaf: **HYP8_MEMORY_PASS checked=176** (default).
- Local lint `lint_hyp8_core_local.sh`: clean of fatal classes, 0 open
  warnings.
- Remote gate `closure-r130` (`hyp8-remote-gate.sh r130`, fork PGO compiler +
  `--threads 4` + simulation PGO, `g6lc64_hyp8` harts=1): **build_complete**,
  lint scalar `(0,0)` / smt2 `(0,0)`, model `5408f87240f17255…`, simPgo=230,
  verilatorBin `d219b63fc4f8fcba`. **14/14 smokes pass at identical baseline
  cycles** — 685/1011/492/2364/2199/1231/671/3038/9095/5959/883/983/3893/6949
  (incl. `hyp8_lrsc_store`=983), so the pairing gate is latency-neutral on the
  qualified profile. (Aggregate proxy reported rc=255 after `build_complete`;
  `results.json` and the independent smoke run are the verdict.)

## 5. Open item — AXI `R Response Errored` bursts (not fixed)

r127m logged ~18,131 timestamped `R Response Errored` warnings
(`g6lc_testharness.sv:1508`) concentrated ~352.5–368.1M cycles, inside
OpenSBI's M-mode unaligned-access emulation (mtvec swap + `mstatus` MPRV
write). Errors repeat ~176 cycles apart. Hypothesis: younger loads reach the
AXI bus with a physical address formed under the pre-CSR-write translation
state and are squashed on the wrong path — harmless in sim, but a
speculative side-effect concern on non-idempotent hardware. The warning
prints no address/ID; confirming needs either an address-tagged warning or a
`+soc_trace`/`+trace_from` replay to ~352.5M. Non-fatal (boot passed), so it
is recorded here as a follow-up, not an opportunistic fix.
