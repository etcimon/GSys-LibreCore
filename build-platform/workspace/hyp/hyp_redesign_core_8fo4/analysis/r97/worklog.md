# r97 — FLU reservation implementation

Status: retain the latency-neutral FLU rewrite after source review and
original/candidate functional comparison. The aggregate system gate failed;
this is not full-core elaboration, Linux boot or physical timing closure.

## Source and caller contract

Task: H96-g6lc_flu_reserve. Provider:
`core/ooo/g6lc_flu_reserve.sv`; caller:
`core/issue_read_operands.sv:1699–1743` in the Hyp core tree.
The caller is not in `core/ooo/`.

`res_offer` is pre-ack, valid, non-exception and non-flush. `res_accept` is
the final acknowledgement under the same qualification. Later CASQ/CVXIF/
LR-SC/prefix logic can withdraw acceptance. Admission must not read that
final accept vector, or its own earlier admit bits.

Fixed operations reserve offset `1 + ooo_flu_cycles`, including the existing
WbCaptureStages contribution. Only actually accepted operations change the
calendar. Nonzero-lane ALU-low keeps the existing secondary-ALU exception.
Divider ownership lasts until matching writeback, scoreboard reclamation,
or reset; a release observation does not permit an early same-cycle admit.
No new state, latency, clock, reset, permission or completion interface.

## Exact parallelization argument

Let Q be the old reservation word, D the old divider ownership bit, and
M[p] the zero/one-hot fixed-latency mask for lane p.

```text
F[p] = offer[p] && any(M[p]) && !D && !(M[p] intersects Q)
V[p] = offer[p] && divider[p] && !D && Q.empty
E[p] = F[p] || V[p]
W[p] = V[p] && no earlier E

fixed_admit[p] = F[p] &&
                no earlier (F[q] && M[q] intersects M[p]) &&
                no earlier W
admit[p] = !offer[p] || no_resource[p] || fixed_admit[p] || W[p]
```

This equals the original greedy scan:

1. If D is set, all FLU requests lose.
2. If Q is nonempty, no divider can win. For each available fixed slot,
   its first eligible offered lane wins; the other slots are independent.
3. If Q is empty, the first resource request either claims the divider,
   blocking all later FLU requests, or claims a fixed slot, making the
   working window nonempty and blocking all later dividers. Remaining
   fixed requests still compete only for their own slot.

An earlier winning offer can be withdrawn later. It still excludes a
conflicting later offer for that cycle, exactly as before, but it must
consume no persistent reservation. This conservative behavior is deliberate.

The update is independently parallel:

```text
Q_next = (Q OR union(M[p] for actually accepted p)) >> 1
div_accept = any(accept[p] && divider[p])
```

The owning divider TID and release equations retain their existing priority.
Direct opcode decoders are checked against the package helpers under
translate_off, so future classification changes cannot silently diverge.

## Before measurements

Pinned instrument: sv-timing 0.1.0, delay-v49, ir-v6, fo4-v1, parser
v0.13.5; target 5000 MHz, 20 ps/FO4, margin 0.2, budget 8 FO4.

| Binding | Input→output | Input→register | Register→register |
|---|---:|---:|---:|
| Scalar, 2 ports | 67.45 | 45.15 | 6.50 |
| 8-port leaf scaling | 106.45 | 45.15 | 6.50 |

The eight-port map changes only NrIssuePorts for the reservation leaf;
it is not a complete wide-core elaboration or performance qualification.
The old maxima include conservative guard composition; a lower structural
row is not an equivalent mapped physical gain. The actual serial working-
window dependency is removed by the proposed equations.

`measure.py before` freezes the original RTL in
`g6lc_flu_reserve.before.sv` and records both bindings. `after` requires
that only this RTL file changed among the recorded timing inputs.
All results are exclusive-create, source-hashed and version-checked.

## Measurement qualification and final screen

The initial candidate's 25.80 maximum is rejected as timing credit: RES_WIN
and TID/WB dimensions were unresolved, several masks defaulted to one bit,
and the literal-assignment opcode cases were charged zero despite live
selectors. Those exploratory reports remain under `boards/after-*`.

The final source uses explicit opcode membership predicates with
default-false semantics. `bound_measure.py` supplies the package-derived
RES_WIN=10, OFF_W=4, low/full/multiply cycles 2/3/8, their exact masks,
TRANS_ID_BITS=5 and NrWbPorts=4. Both original and candidate use the same
bound values and unchanged instrument. The original source is substituted
only through a separate absolute flist; other input hashes match.

| Binding | Original reported module maximum | Final reported maximum |
|---|---:|---:|
| 2 ports | 67.45 FO4 | 34.50 FO4 |
| 8-port leaf scaling | 106.45 FO4 | 34.50 FO4 |

Final `bound-after-p2/p8.ir.json` have no width-defaulted nodes. The opcode
predicate now occurs in the reported maximum before alu_mask, lane_mask,
fixed_eligible, resource_eligible, earlier_resource, div_winner, admit and
stall. The membership expression is still opaque to part of the analyzer;
the input-derived cone is incorrectly labelled reg-to-out/reg-to-reg.
Guard/index compatibility also remains incomplete, including composition
through divider eligibility when the old window must be empty. Consequently
these are **same-model structural screens**, not qualified stage delays or
proof that the eight-port hardware scales at constant physical delay.
Do not interpret the reported 20.50 reg-to-reg row as a new register stage.
No registers were added. Synthesis may already perform some of the old
constant-function simplifications; no mapped timing gain is established.

Final source SHA256:
`f2e97a5032227a49a9cadf9b57519a9470ed8084718fcc189c3d3a07e6b82c19`.
Original:
`25fa7edec94a8489a548ef6e3d142da0f9fa468f16386c154d0bad2778c4c154`.
Calibration, target, margin and cost-model version were not changed.

## Verification results

Use the existing control bench file with a standalone FLU top, eight
geometry/latency/enable cases, an independent greedy state model, directed
ownership cases and deterministic mixed traffic. Compare admission before
the edge and calendar/divider ownership after it. Check direct opcode
classification over the complete encoded FU/op space. Run that same
bench against the archived original and candidate in isolated snapshots.

The same bench passes against the original and final source:

- `hyp8-r97-flu-baseline-v1`: HYP8_FLU_PASS, eight cases, no compiler warnings.
- `hyp8-r97-flu-candidate-v1`: HYP8_FLU_PASS, eight cases, no compiler warnings.
- Every per-case activity summary matches exactly. Cases cover 1/2/3/4/8
  ports, WbCaptureStages 0/1, staggered/nonstaggered ALU, multiplier override
  and fallback, and WbReserve=0. Each runs 10,000 deterministic mixed cycles,
  the full 4096 encoded FU/op combinations, and directed ownership cases.
  Each completes 14,136–14,154 checks; every enabled case observes fixed
  acceptance, declined offers, withdrawn acceptance, WB release and reclaim.
- `hyp8-r97-issue-v1`: HYP8_ISSUE_PASS checked=99 plus
  IRO_LSU_SHADOW_OK checks=8. This is functional caller evidence, not a clean
  elaboration gate. Its existing bench/other modules report PINMISSING=3,
  WIDTHEXPAND=23, WIDTHTRUNC=3, SELRANGE=1, WIDTHCONCAT=4 and UNOPTFLAT=5.
  All five UNOPTFLAT locations are in the unchanged g6lc_iq_arb; the
  diagnosed locations do not name the modified FLU. No warnings were hidden.

The minimal FLU route has fatal width diagnostics and verifies the entire
source manifest. The legacy issue route does not verify that manifest, but
records hashes of every compiled source in its sources.json; these must be
matched against the final private snapshot. It does not inherit a clean
status merely because its legacy warnings list is empty.

The initial staging record `functional-inputs.json` is not evidence: it
contained an incomplete baseline manifest. The preparation was repaired in
new directories under workspace/build, every recorded file was verified,
and `functional-inputs-final.json` is the authoritative input receipt.
The frozen remote runner SHA is
`64a4fdfe98db62e313f2518e155a19ec8e44dd0e25963ce09274a75d5e4c529b`.
Verilator binary SHA:
`3e622e33b741d1b2ba6913e43158e2dba6aa9d2fd5e8e89ad2c978360426a254`;
the pre-existing private runtime and one simulation thread were retained.
Logs are in `remote-runs/<tag>/output/`.

### Aggregate gate and transport incident

Ran once:

```text
bun build-platform/src/cli/index.ts verify --lint --sim --synth --target g6lc64_hyp8 --remote
```

Result: exit 1, four failed steps and one skipped strict-elaboration step.
Lint and synthesis refer to the absent production-path
`core/include/g6lc64_hyp8_config_pkg.sv`; simulation launchers fail with
exit 127 because GNU Make is not on their Git Bash PATH. Standalone slang
is unavailable on the remote builder. Logs/argv are retained in
`aggregate-verify.{log,json}`. These are not successful checks of Hyp RTL.

The canonical remote gate's `runRemoteScript(sync=true)` also invokes the
proxy's shared `/opt/testharness/repo` sync before lint/synthesis. This crossed
the earlier isolated-validation restriction and was disclosed to the user.
No further use of this route or blind restoration is authorized; the
pre-sync shared state was not captured. Future Hyp aggregate validation
must use an isolated source closure. The three focused runs above did.
No OpenROAD, tool installation, firmware patch or remote process termination.

## Integration and backend review

No interface, configuration policy, state/reset/clock, DFT, RVFI/PMU or
ISA/DTS change. Existing WbReserve=0 passthrough and stall_o reporting remain.
Parallel prior-lane comparisons trade serial depth for more combinational
comparisons/fanout, approximately quadratic in issue width; mapped area,
power and placement remain unmeasured. Existing calendar and divider state
retain their clock/reset and ownership rules.

The obsolete disable-ALU2 proposal and the tentative-offer/final-accept
description in continuation-design.md are corrected to match the current
caller. Tooling/bench retain MIT and the existing RTL retains its dual
license. The byte-exact preimage receives matching tier/REUSE metadata.

`audit.py` passes: every private source hash, all three focused result/source
receipts, final timing identities, Python syntax, scoped licensing and diff
checks. `audit.json` retains the checks and the failed aggregate-gate status
separately. Existing mixed line endings in the package todo and implementation
log were preserved; only the intended entries changed. Nothing was staged or
committed in this pass.

## Next source-qualified candidate

H96-g6lc_lsq: registered-slot free counts at :343–355 increment a running
count once per invalid slot. The dispatch caller compares the resulting
credits to both incoming and retained-group demands at :312–313.
This is observable admission state, unlike the rejected coherence counters.
A packed validity projection and correctly sized population count can
replace the count recurrence without adding a cycle. Preserve the existing
full-flag semantics and do not change event/slot/cancel/release ownership.
Bind the caller's LsqLoadEntries/LsqStoreEntries before measuring this change;
the default leaf depths are not evidence of that caller's dimensions.
This is investigated, not implemented in the current FLU change.
