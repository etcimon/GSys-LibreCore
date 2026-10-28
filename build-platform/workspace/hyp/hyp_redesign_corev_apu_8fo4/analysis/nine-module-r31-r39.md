# r31–r39: nine AI-island timing tasks

RTL scope is the hyp overlay, not the production architectural reference.
The measurement executable remains `hyp8-src/inputs/r20-sv-timing.exe`,
SHA256 `6d3a2792857543be946a0d5c407a13a6574191d0d5b1b21f26e8c9b86ea21bc4`:
delay-v45, ir-v6, package 0.1.0, parser v0.13.5. Settings remain 5000 MHz,
20 ps/FO4, margin 0.2, with the existing APU parameter map.

The matched baseline is `analyze-ai-hyp-r31-before.json`; the final measured
source is `analyze-ai-hyp-r39-owned-final.json`, under
`build-platform/workspace/build/sv-timing/hyp8-src/boards/ai-island/`.
Each measurement has the command, file-list/parameter-map hashes, source hashes,
report/IR hashes and per-module metrics in its `.manifest.json`.
`analysis/tools/measure_nine.py` reproduces the measurement without overwriting
evidence. No cost-model changes or timing exceptions were used.
The final file-list and parameter-map hashes equal the baseline hashes, and
the final analyzer reports no skipped files. Eleven measured source files
changed: the ten implementation files plus the island response-owner fix.

## Measurements and direct callers

These are maxima across **all** reported module-local paths, including input
and output paths and atomic operators labelled soft `multi_cycle`. That label
does not establish a legal multicycle exception. The initial display excluded
those atomic paths and showed integer dot as 38.60; the captured baseline was
corrected from the same raw report, restoring 45.80.

| Task | Module suffix (`g6lc_ai_`) | Before | After FO4 | After >8 / paths | Direct callers in analyzed closure |
|---|---|---:|---:|---:|---|
| r31 | pe_dot_float_pipe | 50.77 | 37.25 | 28 / 43 | gemm_seq.i_pe_float_pipe |
| r32 | policy_subcode | 49.74 | 44.55 | 43 / 67 | policy_steer.i_subcode |
| r33 | gemm_seq | 48.70 | 46.95 | 196 / 378 | cluster_dispatch.i_eng; island_top.i_gemm |
| r34 | pe_dot_float | 47.14 | 30.27† | 6 / 18 | gemm_seq.i_pe_float |
| r35 | inval_queue | 46.54 | 26.30 | 9 / 27 | island_top.i_inval_queue |
| r36 | gemm_fp32_norm | 46.25 | 36.45 | 6 / 48 | gemm_fp32_add.i_norm; gemm_fp32_add_p2.i_norm |
| r37 | pe_dot | 45.80 | 11.00† | 1 / 26 | gemm_seq.i_pe_int |
| r38 | policy_codec | 39.40 | 36.90 | 39 / 101 | policy_steer.i_codec |
| r39 | desc_engine | 39.00 | 34.40 | 88 / 158 | island_top.i_engine |

† The frozen analyzer does not fully compose dependencies across generated
arithmetic levels. These two numbers rank local regions; they are **not**
complete operand-to-result arrivals. The integer product contains four
carry-save levels followed by a carry-propagate add, then a separate growing
sum tree. The floating reduction similarly retains its full compression tree.
Explicit assignments replaced wire declaration initializers after inspection
found those initializers missing from the timing IR; the final report includes
their operators, but the cross-generate composition limitation remains.
No physical timing reduction or 8-FO4 closure is inferred from these numbers.

`nine-module-r31-r39-results.json` contains the complete reported path lists
for these modules, the limiting path's nodes/expressions/widths, and every
direct caller record (including source locations and port connections).
Cross-module stitch totals retain the r19 connectivity qualification.

## r31 — decoded-operand window

Added an S0 register for both decoded operands, lane-valid and format-valid
facts. S1 multiplies only those registered operands and loads on the delayed
start token. Reset clears both token stages. Special-value metadata remains
in the original product bundle and output ordering is unchanged.

The integer pipe gains O2 and GEMM's shared tag/coordinate/phase pipeline
grows by one cycle. Both pipes return on sampled edge `ceil(log2(Lanes))+6`,
counting acceptance as edge one. Throughput remains one issue per cycle.
The remaining reported owner is the final block-exponent/conversion cone,
not the removed decode/product chain.

## r32 — ranking window and prepared facts

RANK registers the candidate-vs-best decision before COMPARE selects and
publishes the winner. Added captured M/N alignment facts, literal reuse-gain
values (including the original truncations for unused encodings), fixed
row-byte forms, and independent byte/service clamp cones.

This adds one evaluator cycle per candidate, eight for a full evaluation.
Published cycle estimates remain bit-identical. The fixed 32-cycle
`EvaluationCycles` term is a cost-model value; it does **not** compensate for
all actual evaluator latency, including the earlier r30 sequential multiplies.
The remaining owner is the winner/threshold/publication chain.

## r33 — seed capture at the bank boundary

Moved the seed response registers before the C-bank mux, with a captured
bank identity for each accumulator set. A first partial consumes its seed
on the next edge; subsequent partials use the accumulator, so bank storage
can be reused after that consumption edge.

This is a narrower cut than the initial proposal to retime every C-bank
read. Store reads retain their existing fetch/retirement contract, and the
MAC recurrence and issue latency are unchanged. Storage changes from two
32-bit seed registers to one per bank plus two small bank selectors.
The remaining reported maximum is the receive-row control cone.

## r34 — floating carry-save reduction

The DPF=0 combinational interface remains available. Complete signed
640-bit aligned products now reduce through explicit 3:2 compressors and
one final carry-propagate addition. The old in-place tree propagated carry
at each level. Padding and one-lane bypass remain parameterized.
No cycle is added and modulo-2^640 arithmetic is preserved exactly.
The reported local maximum moves to decode/product preparation; see †.

## r35 — AW skid and deferred B ownership

Two accepted-AW slots decouple `aw_hold_o` from last-byte arithmetic and
tail coalescing. Admission depends on skid occupancy. Descriptors transfer
in order into the existing queue, whose same-line coalescing is retained.
B credits received before descriptor allocation are retained and consumed
in order. Idle includes both skid occupancy and deferred B credits.

Capacity becomes Depth queue entries plus two admission descriptors.
Admission has an additional registered stage; hold-cycle PMU values reflect
the new buffering. Invalidation still follows completion of the owning
writes. The next timing owner is AW last-byte/line arithmetic into the skid.
The existing testbench gained immediate-B and unaligned-crossing-beat cases.
The island fixture also checks enabled invalidation end to end: it records
completed B responses by line and requires the last invalidation of each line
to cover its last completed write before publishing a completion.

## r36 — factored normalization

Leading detection uses constant suffix slices. Common sign, overflow and
subnormal data are selected once; only normal fraction/exponent candidates
use the balanced OR tree. The subnormal shift stays in this stage: relocation
into align was unnecessary for this reduction. The align record, two-stage
accumulator contract, flags and reference's non-IEEE corner semantics remain
unchanged. The residual path includes magnitude/subnormal processing.

## r37 — wired products and explicit sum levels

Replaced three context-widened multiplies per lane with signed byte rows
and carry-save compression. INT4 uses sign-extended nibbles. The negative
sign row is complemented and its +1 is a separate row. The lane sum grows
in width up to 32 bits; odd tails promote unchanged. No cycle is added.
The algebra is the r28 carry-save pattern; see † for measurement limits.

## r38 — parallel encode and per-field publication

Encoding runs beside signature comparison; evaluate selects its result
afterward. Publication fields have separate combinational cones, with
flush/disable applied at the state register. Idle f2 values cannot replay
pre-commit state while clearing the work-valid pulse.

An intermediate one-hot-encode/output-split candidate measured 46.97,
worse than 39.40. Removing the one-hot encoder alone retained that maximum:
the exposed path was predicted policy → warm enable/address → bundled state
publication. Per-field publication resolves it; the final implementation
keeps the package encoder and measures 36.90 without extra latency.

## r39 — span saturation in the existing multiply window

Capture the descriptor's row-byte tail at `sp_kick`, while the sequential
products are launched. Independent 65-bit adds provide result and overflow
carry; one-hot masks preserve empty-dimension and zero-span returns.
The C span uses constant wiring and an upper-bit overflow test. Each span
has its own capture process.

The first arithmetic rewrite measured 44.09 because live format/row-byte
functions still preceded the sum. Capturing the tail in the existing window
reduces the final maximum to 34.40, with no additional descriptor cycle.
An assertion checks the prepared tail against the live expression on done.
Check/request control is the remaining owner.

## Caller correction — responses must follow request ownership

The final island check exposed an existing integration defect beyond the
nine local cones. `island_top` broadcast its shared AXI response to inactive
clients, while the hyp GEMM response skids could accept whenever empty.
The retained counterexample in `r39-island-small-diagnostic` shows GEMM
consuming descriptor responses with ID 0 at cycles 113 and 114, before its
first actual ID-2 response at cycle 117. The unchanged r20 completion shadow
then fails: receive row 7, issue row 6, reference completion 1, new completion 0.
The default 512-lane configuration reproduces the same failure.

The hyp island now qualifies fetch, store and GEMM responses with the same
client selection as its request mux, covering both single and clustered GEMM
connections. This prevents inactive skids from accepting unrelated R/B traffic.
The request priority and selected client's latency are unchanged. The fix
retains the island's serialized-client contract; it is not an ID-routing
scheme for arbitrary concurrent masters.

The small counterexample passes after the fix, with GEMM's first R now ID 2.
Its warning-category counts are unchanged. The final island-top local maximum
remains 43.95 FO4, with 49 of 170 paths over 8 (previously 49 of 167).
The new response-selection fanout remains a physical-design review item.

## Verification and provenance

Known passing local evidence:

- Float pipeline: 5,028 transactions each at 1, 3 and 8 lanes. The old C++
  float test prints a drain-length hint as “latency”; it is not a latency
  assertion. Values/specials are checked against its existing mathematical
  reference (finite results permit one ULP); it does not validate all flags.
- Combinational float dot: 5,024 transactions/checks at four lanes against
  the existing C++ reference, with the same finite-result tolerance.
- Integer C++ oracle: combinational 75,536 / 12,000 / 12,000 checks at 1/3/8
  lanes; pipelined 73,008 / 8,995 / 9,015 checks, including exact valid timing,
  bubbles, format changes and reset with outstanding transactions.
  This replaces the unsuccessful old SV fixture as the leaf evidence:
  that fixture has a stale +5 latency expectation and returned stale zero
  operands under this tool. Its failed log is retained, not counted as pass.
- Policy pipeline after subcode and final codec changes:
  `PASS policy_pipeline topology=5568 publications=23 cancels=29 pmu_orders=3`.
- Invalidation: positive, oracle-negative and inval-at-AW mutation gates pass,
  including the added immediate-B and cross-line tests.
- Intermediate GEMM DPF=2: golden, accumulation 112 checks, signed 56 checks,
  protocol stalls, reuse slots 16 checks, and 100,000 FP32 value/flag checks.
  Its environment accidentally used the string `1,2`, interpreted by Bash
  arithmetic as profile 2; it is **not** evidence for a separate DPF=1 run.

Final combined local gates pass: `r39-gemm.log` covers DPF=0/1/2, including
accumulation, signed data, protocol stalls, reuse slots and the 100,000-vector
FP32 value/flag miter. `r39-wide.log` passes the 128/512-bit store fixture.
The explicit local profile list is `AI_GEMM_DPF_LIST="0 1 2"`.

Remote selected-case evidence:

| Source/run | Cases | Result |
|---|---|---|
| `r39-remote` | backend0/backend2 golden and five review cases each; stripe1/stripe2; cluster; wide | 16 PASS, rc 0 |
| `r39-island-owned` | small 8×8×8 hardware geometry, invalidation off/on | 2 PASS, rc 0; 442 / 446 cycles |
| `r39-island-full-owned` | default hardware geometry (512 lanes), invalidation on | PASS, rc 0; 452 cycles |

The island workload remains an 8×8×8 GEMM in both hardware geometries. Both
enabled cases report `PASS DMA_INVAL_INTEGRATION invalidations=8`. The default
case also records 32,768 r20 operand checks and 109 load checks. Normal
assertions, the legacy load shadow and the B/invalidation/completion scoreboard
remain enabled. These are selected simulation cases, not full-core qualification.
All three runs use Verilator 5.008 with the existing hash-qualified private
runtime repair and its negative/positive canaries.

The unmodified old local 512-lane island build was stopped after the ownership
counterexample made its source obsolete; it is not passing evidence. The
remote corrected default-geometry case above supplies that gate.

All local gate snapshots, source digests and logs live under
`build-platform/workspace/build/ai-gemm/r31-*` through `r39-*`.
`analysis/tools/run_nine_gate.sh` uses existing benches with immutable RTL
copies and preserves command failure status. Its only new arithmetic fixture
is `verif/tb/ai_island/pe_dot_int_main.cpp`, shared by both integer modules.

Final source captures under `analysis/tools/zips/`:

| Archive | Purpose | SHA256 |
|---|---|---|
| `gemm-r39-final-closure.zip` | 16-case GEMM source closure | `e92efd6756514b1aa150f2dde18f0b561c3330266304bfba7923817439debddc` |
| `island-r39-owned-closure.zip` | corrected island source closure, small and default geometry | `dff000487fd6bd8bb18ffdad3a39c2d806dbd12575693ca7cde91251d27bd16a` |
| `r31-r39-owned-rtl-evidence.zip` | eleven before/after RTL images and source hashes | `38b0205fbc5160d3661cc072ab0fa6bbaf47aa8ba42f9548f73ee631b0ff585b` |

`r31-r39-owned-rtl.diff` contains the reviewed source delta. The original
ten-file archive and all failed diagnostic runs remain available.
`analysis/tools/finalize_nine_evidence.py` derives the JSON/caller record from
the frozen reports and checks each captured final RTL hash against the final
measurement manifest. The manifests remain authoritative for measurement sources.

The aggregate lint/sim/synth attempt is recorded in `r39-generic-verify.log`:
four failed steps and one skip. Remote lint and synthesis cannot find the
production-path `core/include/g6lc64_hyp8_config_pkg.sv`; strict standalone
slang is skipped on that builder. The default cv64 smoke fails compiling
stale named register-bank probes in `ariane_tb.cpp`; the cv32 smoke exits 130.
Those gates remain unqualified. Leaf simulation elaboration is not synthesis
or full-core/Linux qualification.

Existing RTL licenses and asynchronous active-low reset were preserved.
The licensing pass checked the three policy files and active contributor.
Tier/REUSE metadata for the integer pipe and invalidation bench now agrees
with their existing CERN-OHL/Commercial declarations. The subcode reference
and hyp copy had no SPDX declaration and the hyp path resolves to U; its
original notice remains unchanged, with a Modified-by attribution added.
No new outbound license is asserted over that unclassified source.
New verification/tooling code is MIT; no GPL-only input joins its link set.
The advertised `diag run licensing` diagnostic is not registered in this
checkout (`Unknown: licensing`); this pass used a scoped header/tier review.
No ISA, CSR, DTS, clock-domain, memory-macro interface or production config
changed. Added control/data registers use the existing clock and reset;
there is no new architectural feature or discovery bit. Area/power effects
include the decode registers, distributed seed registers, skid/credit state
and wider parallel arithmetic. No area, power, DFT or physical closure is
claimed without synthesis/backend evidence.
The design note is `docs/03_cva6_design/ai_island_hyp_timing.md`; the SoC
readiness guide links its pipeline and ownership contracts.

The strategic basis is ALGORITHMS-EXPERTS A20 (real dependencies), A33
(relocation/window choice), A104 (exclusive masks), A134 (prepared facts),
and the previously verified wired-row/carry-save representation pattern.
After this batch, the leading local owners remain GEMM 46.95, subcode 44.55
and island_top 43.95; substantial work remains toward 8 FO4.


## Follow-up: r40/r41

Subcode and GEMM reductions (SHAPE + ranked choose; bounded receive
arithmetic + indexed C-bank mux) — see `subcode-gemm-r40-r41-plan.md`
and `subcode-gemm-r40-r41-results.json`; measurements here remain the
r31–r39 frozen record.
