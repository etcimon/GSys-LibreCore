# r98 — LSQ credits and PMP write-bank reduction

Retained two latency-neutral changes. The MSHR experiment is archived and its
original RTL restored. No new state, clock, reset, pipeline cycle, CSR encoding,
or device-tree capability was introduced.

## Structural screening

Matched `sv-timing` 0.1.0 / ir-v6 / delay-v50 / fo4-v1, parser v0.13.5,
20 ps/FO4 and an eight-FO4 target:

| Caller binding | Before | After | Disposition |
|---|---:|---:|---|
| LSQ, eight load/eight store slots | 36.80 | 33.20 | Retained |
| CSR/PMP, scalar XLEN64/PLEN56/eight implemented entries | 59.47 | 52.60 | Retained |
| L2 MSHR, depth2/512-bit line/17-bit metadata | 26.85 | 29.80 | Rejected |
| L3 MSHR, depth4/512-bit line/17-bit metadata | 29.20 | 30.15 | Rejected |

These are structural screens, not clock limits or mapped timing gains. MSHR
paths additionally merge distinct entry updates and contain unresolved field
widths; the numbers cannot establish a physical regression either.

LSQ credits are population counts of packed free masks. Case equality preserves
the old conservative treatment of unknown valid bits; only registered occupancy
contributes credits. The old one-FO4 `$countones` fallback was rejected. Delay-v50
uses the existing width-scaled adder law across a balanced count reduction:
the eight-input/four-bit-output counts each cost 9.169925 FO4. No cost table or
load law was retuned. Ordinary expression/guard calls are covered; opaque
function-body/spine estimates and resize-cast geometry remain separate work.
Unknown input width uses the visible default 32, not a proven upper bound.

PMP rows now decode constant CSR addresses and use constant lock/neighbor indices.
RV32 maps four configuration bytes per CSR; RV64 maps eight bytes to even
configuration CSRs and retains odd-address exceptions. Entry63 explicitly has
no TOR neighbor; the retained simulation reference received the same bound.
The bank consumes the retained original CSR address: the inspected VS mapper
only maps100..105/140..180 into2xx and cannot intersect PMP3a0..3ef. RMW data,
request ownership, legality outside this bank, WARL/read-only/unimplemented
normalization, reset and architectural apply remain at their original boundaries.

The initial converted-address trial at 57.45 included an incompatible VS-remapping
dependency; it is archived in `pmp-converted-address.patch`. The final maximum
52.60 has an individual 64-bit `dpc_d` publication path as well as a region
aggregate. The final PMP address path is 52.15, with resolved 54-bit data and
3456-bit array widths. Noncritical CSR/byte aliases still expose width defaulting.
Wide publication/load-law calibration remains open; no further stage is implied.

## Functional and source evidence

- LSQ original/candidate: 252 focused credit checks and 2,826 full-leaf checks
  each on the final LF-byte sources. Focused tags
  `hyp8-r98-lsq-credit-before-c5b-lf2` and
  `hyp8-r98-lsq-credit-after-c5-lf2` print
  `HYP8_LSQ_CREDIT_PASS checked=252`; companion full-leaf tags ending `-lf`
  print `HYP8_LSQ_PASS checked=2826`. The full runs' runner status is a
  token mismatch solely because `+credit_only` was absent; simulation rc and
  full token are still recorded raw. Focused raw hashes: before
  `68a7890c04ddb2e025819024b684eaacbe3067494774a3f44e5282391a4ce2ff`, after
  `7bc8c4b798afa379b9accbb60e6148a7016f89fff8a851f1bb32121fb8a73939`; full raw
  hashes: before `9593bfc85ed92ef893303582ae3f4f80ac70848ac2ef273cd0b8ab40e213eeea`,
  after `4314b6f3219a0b92c966720291c133d6b097d261064cb52ad5424473e4376b95`.
  Earlier CRLF-byte `c5`/`c5b` receipts remain preserved and are superseded
  for final source-identity claims.
- PMP final `hyp8-r98-pmp-write-c2`: 73,746 RV32 and 73,747 RV64 checks pass.
  The fixture extracts the candidate bank and actual VS converter verbatim;
  the reference differs from the frozen old bank only by the entry63 bound.
  All 4,096 addresses, write enable 0/1, VS mode 0/1, three lock/mode patterns,
  directed byte/lock/TOR/boundary checks. Two `WIDTHCONCAT` diagnostics remain
  in fixture configuration assignment patterns; they are preserved, not waived.
  C1 zero-write negative control fails at the first unlocked PMP address write.
  This is bank-level evidence, not complete CSR permission/owner qualification.
- MSHR four depth/waiter configurations pass the directed/random miter.
  Passing baseline is **`hyp8-r98-mshr-before-c2b`**, not the earlier c2 compile
  failure; candidate `hyp8-r98-mshr-after-c2`, negative `hyp8-r98-mshr-neg-c2`.
  Negative primary-ID mutation fails. Baseline retains two TIMESCALEMOD and
  two UNSIGNED diagnostics. Live source is byte-equal to the before snapshot;
  rejected source matches both after timing manifests.
- Package tests: 275 passed, one ignored. Independence checker still fails on
  pre-existing host-name literals; no independence-clean claim.
- `audit.py` passed source/receipt identities, retained timing, syntax, scoped
  licensing and whitespace checks. `audit.json` records those frozen inputs.
  The later runner verdict fix is covered by `finalize.py` and
  `aggregate-review.json`, without repeating the unchanged workloads.

## Integration gate

Two old assembly inputs were restored byte-exact to tracked custom-test paths.
The closure no longer depends on the deleted generated test directory. The
smoke grader checks model/ELF hashes, build/input success, nonempty tests,
the ELF's tohost argument, exit0 and an uncontradicted success banner. Ten
controlled positive/negative grader checks passed without local RTL simulation.

First isolated 731-file gate `hyp8-r98-integration-final` passed scalar/SMT2
elaboration but failed MC: its flist omitted existing `g6lc_lu_result`. The
missing entry was added before `load_unit`; original failure receipts retained.
The corrected isolated run `hyp8-r98-integration-final2` built the scalar model,
verified its runtime dependencies and assembled all seven inputs. It used two
compiler jobs/one simulation thread alongside two existing protected models,
without killing them or syncing the shared checkout. Manifest SHA:
`226f960c85698a40e64cefc8923bb6b00dab59b5f1ff50e25157096da94301fa`.
Model SHA:
`cb359522a1c20a10aadd8250d102170840c2a98c95726aacedc232b1a65b1b58`.

`hyp8-r98-smokes-final2` passes all seven scalar simulations with exit0:

| Test | Cycles |
|---|---:|
| h34_shift_dep | 685 |
| h33_st_fwd | 1011 |
| hyp8_branch_cancel | 492 |
| hyp8_csr_flush_skip | 2364 |
| hyp8_amo_store_order | 2199 |
| hyp8_amo_ready_order | 1231 |
| hyp8_f14_store_offset | 671 |

Counts match the frozen r90 record; this is not a complete trace-equivalence
claim. Model, ELF, source and tohost identities were checked against the raw
receipts; `aggregate-review.json` records the assessment.

**Aggregate qualification remains open.** Compiler exits were zero, but scalar,
SMT2 and MC lint retain respectively 607, 628 and 695 warnings. Three latch
diagnostics in each profile refer to unchanged vendor AMO temporary variables.
The scalar build reports 115 warnings. No new warning waiver was introduced.
MC additionally raises an RTL `$error`: its eight-wide configuration derives
32 LSQ store entries while `ooo_spec_store_depth` is 8. Its rename consumer
also selects eight bits from a six-bit checkpoint record. MC is invalid under
these checks, despite Verilator returning zero.

The runner now rejects `%Warning-USERERROR` as a hard configuration failure,
alongside nonzero exit and `%Error`. Five controls using the captured results
and explicit error cases pass. The original run is retained as `build_complete`;
the separate review marks the aggregate unqualified. No RTL simulation was
repeated merely to reclassify these diagnostics.

## Review and remaining scope

No SRAM, DFT, CDC, scan, reset-delivery or discovery boundary changed. Existing
trace/debug ownership remains intact; no new PMU feature is introduced. Parallel
decode/reduction may trade area and routing for depth; area/power are unmeasured.
Upstream notices and inherited RTL offers are retained; tools/tests use MIT.
Production `core/` and `corev_apu/` remain the reference. Unrelated APU edits stay
outside this batch.

CSR-wide/boot integration remains paused as requested. The r96 module/window
queue remains open, including FMA register-boundary, generated-scope and guard
qualification, MSHR field/entry identity, cache admission/response separation
and AI arithmetic/control windows. No Linux/OpenSBI boot, physical STA,
repository-wide verification or eight-FO4 closure is claimed.

Follow-up tasks established by this gate:

- [ ] `g6lc64_hyp8_mc_config_pkg.sv`, `build_config_pkg.sv`,
  `g6lc_ooo_dispatch.sv` and store-queue callers: resolve derived 32-entry
  LSQ versus 8-entry reservation capacity as one contract. Do not suppress
  the guard or silently substitute a smaller profile.
- [ ] `g6lc_rename_read.sv`, `g6lc_ooo_pkg.sv`, `g6lc_rename.sv` and checkpoint
  callers: preserve the full 128-entry checkpoint domain through the retained
  operation record. Producer and oracle currently truncate to six bits;
  widening only the consumer cast cannot repair lost identity. Keep counter,
  index and sentinel widths distinct.
- [ ] Qualify remaining lint diagnostics, macro/register boundaries and
  generated-field widths before promoting a clean aggregate timing/boot claim.
