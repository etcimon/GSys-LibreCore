# r40–r41: policy evaluator and GEMM receive/store cones

Baseline: frozen r20 executable, delay-v45, `analyze-ai-hyp-r39-owned-final`.
The two source files match that manifest. Before-edit capture:
`tools/zips/subcode-gemm-pre-r40-r41.zip`,
SHA256 `fd4adec14b5f823d1d52ba0b0441908a0eb494a15c6d8b6f0401c68a1fe9345d`.
The prior verification files are captured separately in
`subcode-gemm-pre-r40-verif.zip`.

## r40 — policy_subcode

Reported maximum 44.55 (43/67 paths over 8): winner selection before the
threshold comparison, followed by the 40.56 candidate-shape bundle. The sole
direct caller is `policy_steer.i_subcode`. The island top currently leaves the
subcode result ports unconnected; this evaluator is not on the GEMM issue path.

Use A20's independent-operation separation, A33's preparation window and
A134's retained facts: capture group shape at job acceptance; add SHAPE before
PREP to register row/column logs and their sum; perform geometry/validity from
those facts in PREP. Compute candidate/best threshold eligibility separately
in RANK, in parallel with `better_q`, then select the matching eligibility
with the winner in COMPARE. Split the combinational result assignments.

The complete eight-candidate evaluation gains eight clocks. Cache hits keep
their existing path. The fixed 32-cycle cost-model charge and published costs
stay unchanged; they are not measurements of evaluator elapsed time. Preserve
flush/disable/cancel semantics, including cache preservation on cancellation.
New state uses the existing clock, reset and Enabled seam.

Verification gap: the existing pipeline bench checks the subcode start
baseline, but never checks a completed evaluator winner/cost. Add a completed
result oracle to the existing test file, using matrix byte/service counts,
cache off/on, two read bandwidths, format/depth policies, ties, invalid jobs
and abort/restart boundaries. Run it against the untouched baseline before
the implementation, then against the new RTL, including a negative oracle.
Keep the existing policy caller bench as a separate integration check.

## r41 — gemm_seq

Reported maximum 46.95 (196/378 paths over 8): bundled receive metadata,
remaining-byte/room minimum and lane cap. Next: 45.74, store-read control
through the C-bank selection loop. Direct callers: `cluster_dispatch.i_eng`
and the single-engine branch of `island_top.i_gemm`.

Separate receive row/column/first/lane from bounded count arithmetic. Compute
`min(room, PeLanes)` first in beat-sized bits, then compare remaining bytes:
nonzero upper remaining bits necessarily select the bounded limit. On an
accepted beat, `lane < BytesPerBeat`, so the room and result fit that width.
Retain the full-width old expression as a simulation identity.

Replace serial C-bank selection loops with indexed muxes. Pad the input table
with bank zero to preserve the old default for any unused index encoding.
Keep request/address arbitration and SRAM latency unchanged. Remove the
redundant plan-valid test inside the store selection: `w_fetch_needed` already
implies plan validity. There is no new transaction stage or MAC/store cycle.

The generic frozen screen includes the `PeLanes < BytesPerBeat` cap, although
the RTL's runtime configuration assertion rejects that geometry. Retain its
arithmetic identity and label the screen's specialization limit; do not turn
this into a claim about physical timing of the default 512-lane island.

Verify backend DPF=0/2 with accumulation, signed traffic, stalls and reuse;
striped IDs/channels, wide stores and the corrected invalidating island caller.
Existing load, operand and store-ownership shadows remain enabled.

## Evidence and scope

Reference: `sv-timing/architecture/PIPELINING-RT-LEARNING.md`, especially
complete operation ownership, real register boundaries and distinguishing
representation changes from physical timing evidence. Measure both retained
implementations on the frozen board, without modifying the cost model.
Run the required aggregate verify once after the combined RTL edits and
report its actual status separately from focused gates. Update the design
note, readiness guide and status log. No ISA, DTS, clock, SRAM or production
configuration change; no physical/DFT/area/power closure without backend evidence.

## Implemented results

Final frozen report: `analyze-ai-hyp-r41-final`, with command, source/tool
hashes and parameter/file-list hashes in its manifest. The companion
`subcode-gemm-r40-r41-results.json` records the paths, limiting operators and
caller connections.

| Module | r39 FO4 | r40/r41 FO4 | Paths over 8 |
|---|---:|---:|---|
| policy_subcode | 44.55 | 30.40 | 43/67 → 31/81 |
| gemm_seq | 46.95 | 38.70 | 196/378 → 194/392 |

Subcode's remaining maximum is the PREP row-byte capture bundle. GEMM's
remaining reported maximum combines job validation and inflight/first-beat
updates. These retain the structural screen's independent-LHS and
specialization limitations; they are not complete physical arrivals.

The new oracle exposed a pre-existing cancellation defect before timing edits:
after aborting a 64×128 job, restarting a 32×16 job returned a baseline cost
of 8192 rather than 512. The shared multiplier has no cancellation input and
ignores starts while busy. The evaluator previously accepted its old completion
in the restarted COST state. The fix tracks physical outstanding work separately
from evaluation ownership, drains aborted work before relaunch, and qualifies
completion. The shared multiplier module is unchanged.

`r40-subcode-after.log` passes 300 completed-result checks, including 158
winners, 98 fallbacks, 56 cache hits and six abort/restart boundaries. The
negative oracle is detected. Its last restart reports 784 elapsed cycles;
the failed baseline cannot supply a matched elapsed-cycle comparison.
`r40-policy.log` separately passes the original caller pipeline check
(5568 topology checks, 23 publications, 29 cancellations).

`r41-remote` passes all 16 selected cases on the qualified private 5.008
runtime: backend0/backend2 and five review cases each, stripe1/stripe2, wide
stores and the invalidating small island. Golden backend cycles are 1401/2180;
the island completes at 446 cycles with its invalidation barrier checked.
Old load/operand/store shadows and the new count/C-bank identities remain active.
The lead reviewed the full source diff and removed one empty combinational
block left by the edit; that removal has no functional effect.

The first baseline build failed on explicit-width expressions in the new
oracle. Widening operands before shifts/division fixed the compile error;
the second baseline then exposed the cancellation failure above. Both logs
are retained as `r40-subcode-before.log` and `r40-subcode-before2.log`.
Aggregate `verify --lint --sim --synth --remote` finished rc=1: the
production-path hyp config package is absent from the remote snapshot
(the confirmed repeat blocker), the default CV64 directed smoke failed,
the CV32 Spike hello_world timed out and the synthesis stage reported
`Bad command`; only the hyp-package cause is proven pre-existing.
Focused passes do not qualify synthesis or the full core. Final source
archive `gemm-r41-final-closure.zip` sha256
`28bfd9fd75c19ac57bb5f117ae7754e8bd437b34d3837d733e05585768a4cd57`.

Reviewed scope: existing `Enabled`/geometry seams only; asynchronous
active-low reset and testmode conventions preserved; the C read table
is wire-only (no SRAM changes); no ISA/CSR/DTS or top-level interface
impact; r40 adds 21 evaluator state bits across geometry, threshold,
ownership and the wider state field (no area claim). Functional evidence is
simulation-only; timing evidence is structural. Aggregate verification remains
unqualified.

Final identity checks passed: all 67 analyzed source hashes match current
files; tool, file-list and parameter-map hashes match r39; report and IR hashes
match the manifest; the 85-file closure archive verifies internally and
contains both final RTL files. The only post-gate policy-source difference
is the removed empty block. The completed-result fixture, gate runner,
before/after logs and evidence metadata are retained in the r40/r41 evidence
archive indexed by `subcode-gemm-r40-r41-evidence.json`.
