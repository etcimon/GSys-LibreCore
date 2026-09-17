# AGENTS-specs-to-tests.md — RISC-V spec ⇄ CVA6 test-suite map

This is the **living cross-reference from the RISC-V specification to the tests that exercise it**. When
you add, remove, retarget, or re-scope a test suite (or a `verif/tests/testlist_*.yaml`), update the
matching row here so "which spec chapter is this test protecting?" stays answerable in one hop.

- Tests are catalogued and run through the **build-platform orchestrator** (`bun` from
  `build-platform/`). It is the single entry point; suite definitions live in
  `build-platform/src/config/defaults.ts` (`tests.suites`).
- Underlying content: shell runners in `verif/regress/*.sh` driving test lists in
  `verif/tests/testlist_*.yaml` over the `verif/` DV flow (`verif/sim`, `verif/tb`, `verif/core-v-verif`).
- Companion docs: `AGENTS-specs-to-impl.md` (spec→RTL) and `AGENTS-specs-coverage.md` (status-only).

> **This file is a standing discipline (see `AGENTS.md`).** Co-equal with keeping `agents/spec/INDEX.md`
> current: a change to any test suite/testlist is not "done" until its row here (and the derived
> `AGENTS-specs-coverage.md`) is updated.

---

## Instruction-supply review tests (2026-09-15)

| Contract | Test / execution | Scope and result |
|---|---|---|
| Accepted instruction order, bytes, hart and predicted target | `verif/tb/core/tb_g6lc_fetch_queue.sv`; proxy `py verif/regress/remote/run_fetch_queue.py` with explicit source files | Independent accepted-stream scoreboard. Before: sparse input skips an older entry at t=35 for 4/8 slots, dual issue. After compaction: 2-slot/I1/H1, 4-slot/I2/H2 and 8-slot/I2/H2 PASS, including stalls, flushes, backward packet PCs and CF target accounting. Leaf diagnostic, not two-active-core execution. |
| Implementation cost / synthesizability | Proxy `py verif/regress/remote/run_fetch_queue_synth.py` with the same copied sources | Four-slot/I2/H2 live-port generic fixture, exceptions tied off. 25,618→22,354 cells; sequential count unchanged; no latches/check errors. Not physical area, full-core synthesis or STA. |
| Live fetch assertions and non-vacuity | `g6lc_fetch_{iq,realign}.sby` now have separate `bmc` and `cover` tasks; proxy `py verif/regress/remote/run_fetch_formal.py` | Fixed impossible NH=2 bound and made free stimulus explicit top-level ports. Covers/assertions must pass independently; prior vacuous PASS withdrawn. IQ raw-opcode non-interference and reduced formal envelopes remain review gates, not program-order proof. |
| SMT2 checked-work witness | Proxy `py verif/regress/remote/run_checked_work_review.py`, model path+SHA and compiler prefix explicit | Rebuild source, record ELF/recipe/disassembly, verify zero compressed opcodes in norvc cases, VT1/model-bound cookie verdicts. With queue compaction alone, RVC N1 PASS and norvc N1 FAIL. After same-cycle expected-PC repair, both N1 variants PASS (131,072 / 137,216 cycles); both N2 still no verdict by 500k. `mini_fetch_target_prefix.S` is a short warmed same-window jump control, not a replacement for the full regression. No dual-active SMT2 qualification. |

Follow-up regressions: `mini_fetch_redirect_chain.S` is a byte-identical
no-verdict→PASS witness for an architectural redirect whose target is another
taken branch. Existing `mini_ipi_hart1_sp.S` passes; IPI-started checked-work
still fails and the original no-IPI N2 case remains a negative activation
control. Final SMT2 lint/elaboration and full-core synthesis pass. The
realigner's eight-frame BMC and five covers pass after an equivalent bounded
index rewrite; its assumptions still restrict input alignment and geometry.
`g6lc_fetch_iq_order_props.sv` now exposes free inputs, accepts sparse/arbitrary
PC packets and checks a watched accepted entry against independent occupancy
and output progress; it is not replaced by IQ self-composition. Both its cover
and ten-frame BMC timed out at 120 seconds; no final safety verdict is claimed.

Typed restart follow-up: `g6lc_operand_trace.svh`, `run_operand_trace.py` and
`run_operand_analysis.py` add allocation-generation/hart correlation, actual
execution/LSU events, observer-off/on fingerprints and an independent integer
retirement model with an injected-operand negative control. They expose missing
unissued instructions at switch and then a foreign-hart redirect despite a
cookie PASS. `tb_g6lc_restart.sv` / `run_restart_bank.py` exercise bank ownership,
valid-zero/invalid-source handling and redirect collisions. Selector/routing
proofs and covers in the already-listed `g6lc_fetch_smt.sby` pass. None of these
supersedes full SMT qualification or the still-open IQ proof.

Source/build/run snapshots are under `remote-runs/review-*20260915/` and
`remote-runs/review-20260915/`; these diagnostics do not emit strict
`G6LC_EVIDENCE`. No architectural coverage status is promoted.

### Circular IQ verification follow-up (2026-09-16)

`tb_g6lc_fetch_queue.sv` now independently predicts acceptance from logical
occupancy as well as checking emitted PC/bytes/hart/exception/prediction. Both
the timestamp baseline and circular-head candidate pass five C/no-C leaf
configurations, including carry-only partial acceptance, target FIFO pressure,
arbitrary ready, flush, concurrent pop/push and 70,000 accepted no-flush
iterations per configuration. Each rejects `+oracle_negative`. The runner
validates the private runtime header and compiler dependencies. Matched generic
synthesis is 22,354 to 20,085 cells and 5,954 to 5,426 sequential cells; the
fixture still ties exception/carry inputs off, unlike the simulation checker.

`run_restart_review.py` with `REVIEW_IQ_RING=1` builds one fresh observer-capable
SMT2 model from the validated snapshot plus candidate IQ, directly against the
corrected runtime. All thirteen run records pass: two encodings with off/on
positive and witness controls plus witness repeat, redirect-chain, and both
48 KiB/hart workloads. The independent reference checks 13,696 RVI / 14,202
mixed C/I retirements and 25,774 operands each; one peer-flag read per witness
is not covered by the local load-value oracle. Both injected-operand controls
are detected. Off/on fingerprints and repeated enabled traces match; witness
trace hashes also match the preceding corrected-runtime references. This is
not a newly built observer-absent control or a throughput benchmark.

The rewritten `g6lc_fetch_iq_order` checks watched accepted metadata and logical
bank occupancy without DUT age stamps. Both modes initially time out at 120
seconds. With `REVIEW_FORMAL_TIMEOUT=600`, unchanged twelve-frame BMC passes
(ABC: no asserted output through twelve frames); twenty-frame cover still
expires. Additional partial-carry reachability is logged, but its final witness
dump is interrupted. `review-iq-ring-order600-20260916` preserves separate mode
statuses and the task-file hash; the all-PASS runner correctly returns nonzero.
Partial reached covers are not a complete PASS, and BMC is not an unbounded proof.
Yices is absent remotely; no solver installed or assumption weakened. SMT2
lint/strict elaboration passes; physical/full-SMT qualification and raw-opcode
non-interference remain open. Artifacts: approved C: `review-iq-ring-*20260916`
with remote originals retained. No whole-ISA coverage status is promoted.

### Invalidation leaf and bounded fetch-supply observation (2026-09-16)

`tb_g6lc_inval_bus.sv` uses independent per-target queues to check global
admission, output order/flags and blocked/coalesced status. The original N3/D2
passes a basic control and fails mixed-target admission plus coalesce/sole-pop
preservation. The candidate passes N/D 1/1, 2/1, 3/2, 4/3 and 4/4 with directed,
wrap and 600-cycle deterministic streams; all ready-observation mutations fail.
`run_inval_review.py` runs through the credential-cache proxy with the pinned
corrected Verilator runtime. Its quality mode checks eight-step N3/D2 local
admission/status/departure safety, both covers and a checker negative; original
RTL fails. This is not unbounded full-FIFO/coherence qualification.

Artifacts: `review-inval-before-20260916`, `review-inval-after-20260916`,
`review-inval-quality-20260916`; `review-inval-clean-tb-20260916` repeats all
five positives/negatives warning-free after test-only width/loop cleanup.
Paired generic synthesis has 1900→1860 cells at
N3/D2 (372 state cells), 6528→6623 at N4/D4 (988), and zero at N1/D1. No new state
or physical claim. Full platform verify was dry-run only; its SKIPs and missing
remote build-platform CLI do not qualify the gate. Hub/inclusive integration
remains open; the protected one-core SMT2 path and core RTL are unchanged.

`REVIEW_FETCH_SUPPLY=1` in `run_checked_work_review.py` analyzes already captured
traces with source/model/ELF/observer identity checks. In [5182,29986), 24,804
complete clock rows contain 1,378 loop intervals and 12,402 requests/responses,
IQ transfers, decoded allocations and retirements. Request interval is two
cycles; response latency after acceptance is one. No misses or mispredictions
occur in that interval. Missing-row and wrong-PC negatives are rejected.
`review-fetch-supply-analysis-20260916` is bounded core-0 analysis, not a new
model run, full-ROI measurement or multicore speedup. IQ-empty and backend-stall
cycle counts are not observed and remain explicitly unavailable.

### Hub transaction-lifetime baseline (2026-09-16)

`tb_g6lc_coherence_hub.sv` and `REVIEW_HUB_BASELINE=1` reuse the exact L2 bench
AXI types and private runtime. The N2/OT4/invalidation-depth2 broadcast fixture
passes its basic response-owner/ID/data control and catches an observed-data
mutation. Five separate scenarios fail: held AR payload, held AW payload, held
AR ID after an old response frees a lower slot, AW eligibility with a single
free slot/no AR, and accepted-write invalidation retention (3 accepted/completed,
2 delivered). The memory responder completes AW+W before B; consumer readiness
resumes at cycle 32, with a 128-cycle delivery bound.

`review-hub-before-20260916` records these as expected baseline failures, never
hardware qualification. Hub RTL is unchanged. Existing LR width/block-local latch
warnings are recorded; no mapped hub synthesis or full coherence claim follows.
See `architecture/multi-core/README.md` for the transaction-reservation boundary
and why the current `aw_fire`-activated invalidation ready cannot be fed directly
back into AW grant.

### Hub held-address reservation follow-up (2026-09-16)

`REVIEW_HUB_RESERVATIONS=1` checks the retained owner/slot hold repair. Twelve
positives pass across N2 with OT4 and OT1: prior address/ID/credit failures,
simultaneous held channels, filling other slots without stealing a reservation,
stalled B/R response ownership, one-slot operation and reset while held. Both
response-data oracle negatives are caught. The separate invalidation retention
case remains failed (3 accepted/completed writes, 2 deliveries).

`REVIEW_HUB_QUALITY=1` passes eight-step binary hold/routing/ID-exclusion/credit
checks at N2/OT4, N2/OT1 and N1 identity. It assumes only the relevant AXI producer
contract for AR/AW stability while not accepted; it does not prove full response,
ATOP or coherence ordering. Both covers are reached; old RTL and a checker
address mutation fail. Paired generic synthesis has zero latches/check problems;
N2/OT4 cells 2760→2808, state cells 326→342; N4/OT4 5981→6238, 607→625; N1 zero.
The old OT1 write path was disabled by phantom AR reservation, so its much smaller
netlist is not equal-capability area evidence. Physical and platform gates remain
open. Artifacts: `review-hub-reservations-20260916` and
`review-hub-reservation-quality-20260916`; `review-hub-hold-starve-20260916`
repeats the matrix with 20-cycle held-request checks. No protected SMT2 core/config change.

### L2 MSHR sizing comparison (2026-09-16)

`run_l2_size_review.py` snapshots the existing full L2 leaf and uses the corrected
private Verilator runtime. The bench adds opt-in live-MSHR accounting and full
accepted-port tracing; static fixture MSHR_DEPTH defaults to4 as before. Depths
16/8/4/2 have identical17 phase reports and timestamped transactions in service
profiles(6,0)/(24,3), totaling31108/61659 cycles. All have peak one,1348 allocations
and completions;24 positive observer controls and8 occupancy-error negatives
are checked. Existing data/ID/length, policy, bypass/ATOP and AMO checks remain.

`review-l2-size-20260916` stores the raw runs/synthesis;
`review-l2-size-assessment-20260916` excludes scope metadata and separately reports
fixed data macros. Depth16→2 removes874 sequential cells in both fixtures;
512 B/two-way generic23953→18913,4 KiB/four-way logic33647→28840 outside data RAM.
No physical/production-cache area or throughput gain is claimed.

`review-l2-occupancy-v2-20260916` proves one-live/slot-zero/no-waiter invariants
at depths16 and2 using a four-frame base and two-step binary induction, with no
input assumptions, live/completion covers within16 and a failing index mutation.
An earlier hierarchical-enum frontend error is retained; the workaround validates
source encodings. This is not all-geometry bus-data equivalence. Production
configuration, named SMT2 behavior and full platform/physical/coherence gates
are not promoted by these reduced leaf checks.

### Depth-two production-shaped integration and promotion (2026-09-16)

The real 256 KiB/eight-way/four-bank leaf passes depths 16/8/2 with identical
17-phase and timestamped-port results: 31,704 reads, 591 writes, 30,822 completed
miss allocations and 668,512 cycles. Nine positives and three occupancy negatives
are checked. The initial frontend unroll-limit failure occurs only in synthesis;
`review-l2-production-area-20260916` reuses the completed simulations and raises
the frontend limit. Its mapped controller/MSHR/bank portion excludes one tag
module and four unchanged data macros: 15,539/12,727/10,844 cells and 1,625/1,127/751
state cells for depths 16/8/2. This is not total-cache or physical area.

`review-l2-occupancy-production-v2-20260916` proves occupancy by two-step induction
at those dimensions with tag-hit/bank-conflict as arbitrary formal cutpoints.
Live/completion and checker controls pass. It proves control for arbitrary cache
outcomes, not correctness of the cut tag/data circuitry.

`review-l2-size-integrations-20260916` builds matched SMT2 16/2 and stream8 8/2
models with current IQ/predictor/hub/invalidation RTL on both sides. Elaboration
checks effective geometry/depth. SMT2 passes all 13 records per model with equal
cookies, retirement/operand traces and independent analyses; stream8 matches ten
positive records plus its expected negative, including ROI and retirement data.
Only the package depth and private observer/geometry-probe text differ, with
those exact differences normalized and checked. Child evidence is captured under
`review-l2-integration-evidence-20260916` without rerunning workloads.

The two named packages now explicitly select depth 2 and match the tested package
hashes exactly (`b61109d7…` SMT2, `f2c564c9…` stream8). Generic inference and other
packages remain unchanged. No new throughput, full-platform, physical, broad
ISA/FP or coherence sign-off follows; the hub's notification-loss case remains
open. Prior unchanged-default result flags are kept as historical run records.

### Broad RTL review component and preservation gates (2026-09-16)

`tb_g6lc_rtl_review.sv` and `run_rtl_audit_review.py` cover OoO IQ availability,
dispatch/WB coincidence and exact-capacity admission; MSHR merge capacity and
concurrent pop/complete; TAGE decay; and source-selected inclusive acknowledgments.
The repaired component matrix has54 positive/negative records. Baseline basic
controls pass while the authored defect scenarios fail. Earlier checker-container
initialization and indexed stimulus issues are retained as testbench attempts,
not hardware defect evidence. The L3 seam is extracted from live cluster source
and uses the real inclusive leaf, not a full-cluster simulation.

Quality evidence is separated: `review-rtl-audit-iq-proof-v5` has reset base plus
two-step watched-readiness/capacity induction, stable symbolic witness inputs,
live-TID uniqueness assumptions and wait/drain covers; rest-v3 has ten-step MSHR
admission/count/uniqueness plus three covers; tail-v7 has TAGE prediction-output
induction and the inclusive ready equation, with checker negatives. Earlier
watcher/lowering/induction/internal-equivalence attempts are not promoted as passes.
The TAGE miter asserts useful-state zero instead of assuming it or equating the
intentionally changed internal counter.

`review-rtl-audit-integrations-v1` builds fresh four-file-overlay candidates and
matches all24 prior depth-two SMT2/stream8 records byte-for-byte where applicable:
cookies/cycles, retirement/operand traces and ROI reports. Prior independent SMT2
reference analyses therefore remain bound to identical new traces. OoO is off in
these packages. `review-rtl-dispatch-contract-v1` separately reproduces an accepted
store that does not issue in eight cycles while ALU control passes; it remains
known-red. Full OoO/L3/nonblocking, broad ISA/FP/physical and platform claims are open.
See `architecture/remaining-upgrade-sequence.md` for the reviewed paths and costs.

### IQ induction and complete cover set (2026-09-16)

The later `g6lc_fetch_iq_order_props.sv` keeps all original safety assertions and
input assumptions, adding asserted bank/pointer and watched-storage invariants.
Live predicted-CF counts relate the instruction banks to the two-entry target
FIFO; the watched target is checked at its prefix-CF rank. The helper counts
fit 0..32 exactly in six bits. No production RTL changes are made by this pass.

`review-iq-sat-binary-20260916` passes a four-frame reset base check and temporal
induction at length two. This is unbounded safety for the existing reduced
four-slot/two-hart/two-issue/32-bit/ASIC/non-hypervisor envelope, not all product
geometries. `review-iq-sat-binary-negative-20260916` detects a copied-RTL one-bit
instruction-output error. `review-iq-cover-binary-20260916` reaches all 12 cover
predicates within 28 steps, with a constant-false negative kept unreachable.
The no-flush drain witness is full (count 32, all banks full) at step 11 and
empty at step 27 with no intervening flush. Existing full-to-empty coverage
alone could have used a flush, so both predicates remain explicit.

Runner flags: select `g6lc_fetch_iq_order` and `REVIEW_FORMAL_TIMEOUT=600`;
`REVIEW_FORMAL_MODES=prove` plus `REVIEW_FORMAL_SAT_PROVE=1` selects safety
(add `REVIEW_FORMAL_NEGATIVE=1` for the bit fault), while mode `cover` plus
`REVIEW_FORMAL_SAT_COVER=1` selects reachability. SAT preprocessing/geometry
validation rejects unsupported overrides. Default mode order, timeout limits,
source/task hashing and incremental results are preserved. Binary-state SAT
matches the SBY bit-state domain; the discarded X-state induction experiment
is not evidence of a reachable hardware failure. The prior BMC and timeout
records remain historical evidence, not relabeled passes. Wider/FPGA/RVH and
whole-SMT qualification remain separate obligations.

### Executable-data cacheability diagnostics (2026-09-16)

`run_checked_work_review.py` with `REVIEW_CACHEABILITY=1` builds an isolated
stream8 pair differing only in the HPDCACHE load adapter's executable-region
uncached exemption. The circular IQ, configuration and private runtime are
matched; production RTL is not changed. `mini_hpd_2jr.S`, its data/pad/fence.i
controls and observer off/on/repeat checks all pass (eighteen run records).
The original witness's second table load is a genuine candidate D-cache hit,
returns the linked table's sign-extended -10 and dispatches to the expected
second target. The baseline serves that read uncached. This is a scoped trace
and functional result, not full RVC/CSR reference-model validation or a speedup.
The short candidate's cold reads and PASS-store boundary are later despite the
warm-hit improvement. `REVIEW_CACHEABILITY_WORK=1` reuses these models for larger controls:
eight repeated run records pass, with matching per-case fingerprints. The
hot-scan reported warm+scan cycles rise 275,593 to 374,177 (+35.77%); L2/L1D
miss events are 4/0 versus 18,788/19,370. Reports exclude initial fill; neither
cookie polling nor event counts imply physical memory timing. This is a measured
regression, not a production-performance promotion. Artifacts:
`review-cacheability-pair-20260916` and `review-cacheability-work-20260916`.
No ISA or production cacheability coverage status is promoted. Broader
store/fence/error/invalidation/atomic and natural-firmware gates remain open.

### Checked locality and instruction-refill investigation (2026-09-16)

`mini_l2_hot_scan.S` has an optional `G6LC_LOCALITY_PROBE` path with power-of-two
`LOCAL_NODES`, a fully checked pointer ring and exactly 8,192 measured loads
following warm-up. The default hot-scan `.text` is byte-identical to HEAD under
the same local compiler/linker. `REVIEW_CACHEABILITY_LOCALITY=1` in
`run_checked_work_review.py` reuses the existing cacheability pair; twelve
positive trials pass across 1/8/64 KiB working sets and both negative controls
produce expected cookie 3. PMU endpoints are captured before report stores;
every positive report has 8,192 loads and zero stores. ROI times match between
policies (213,009 / 213,009 / 213,006 by working set), with roughly one I-cache
miss event per loop. This does not establish a data-cache speedup or a pure
load-latency result: validation arithmetic can hide short data latency.

Artifacts: `review-cache-locality-v2-20260916`; the first run's linker overlap is
retained as a tooling failure. `REVIEW_LOCALITY_ICACHE=1` adds observation-only
I-cache request/tag/refill/kill/install tracing in a copied model to distinguish
real refills from an event/measurement error. Its first control check falsely
failed on list-versus-tuple cookie comparison despite identical cookie and
byte-identical retirement traces; comparison normalization is corrected and
`REVIEW_ICACHE_MODEL` reuses the already-built model rather than rebuilding it.
The normalized observer check passes in `review-locality-icache-trace-v2-20260916`:
real misses target a wrong-path FAIL line that is killed and not installed after
correct not-taken resolution. Production I-cache/data-cache RTL stays unchanged.

`review-predictor-response-pc-20260916` tests ASIC response-aligned BHT/BTB lookup
without changing FPGA phase or storage: execution checks pass, but 213,012 ROI
cycles / 8,195 I-cache events show no steady-state gain. Adding an absolute
interpretation of the absolute-trained statistical-corrector counter in
`review-predictor-absolute-sc-20260916` gives 147,470 cycles / 3 I-cache events
on the same checked ELF, versus 213,009 / 8,195 baseline. The candidate passes
three observer controls, 8,192 checked loads, zero ROI stores and a baseline
instruction-prefix comparison with timestamps excluded. The prefix ends at the
workload exit routine; trailing polling spins are not compared. These are
initial isolated candidate results, not full-ISA or SMT2 release closure.

The maintained independent corrector test is
`verif/tb/core/tb_g6lc_bp_statcor.sv`, run through `REVIEW_PREDICTOR_LEAF=1` in
`verif/regress/remote/run_checked_work_review.py`. The retained-source rerun
`review-statcor-retained-20260916` also passes; the diagnostic runner preserves
its hashed legacy source when current RTL already contains the repair.

The fixes are now retained after `review-statcor-contract-v2-20260916` (original
inversion fails; six candidate geometries pass with negative controls and
learning/alias/reset/flush/concurrent-update coverage),
`review-predictor-pc-proof-20260916` (extracted ASIC/FPGA selector contract and
wrong-PC negative), `review-predictor-smt2-20260916` (13 passing execution records,
independent RVI/mixed-C references and negative checks), and
`review-predictor-work-20260916` (eight positives plus the expected failure).
The SMT2 references check 13,699/14,203 retirements and 25,774 operands each;
one peer-flag value remains unchecked. The broader hot-scan ROI is 262,740 versus
275,593 baseline, with unchanged cache policy; 8/64 KiB locality gives
147,470/147,467 cycles. Corrector leaf synthesis grows 1,261→1,360 generic cells,
with 192 state bits unchanged; full SMT2/stream8 synthesis smoke has zero check
problems. Retained-source identity and minimal/SMT2/stream8 lint/elaboration are
checked. These gates do not qualify mapped timing/power, PH_BHT's separate
registered port, full FPGA behavior, full ISA or natural firmware.

## Independent BIOS software verification

`g6lc_bios` B50–B52 tests are package-local, not ISA compliance suites:
`python tools/g6b.py check` runs independence, Bun UI tests/build, Rust fmt,
Clippy and workspace tests; `python tools/g6b.py regress` runs the separate
BIOS transport/boot regression. Coverage includes the Goja-shaped AOT subset,
lirx-style local DOM mutations, shared HolyC/browser menu rows and feature
gates, native browser WASM imports, malformed WASM rejection and differential
RV32/RV64 numeric JIT machine-word execution. Sources:
`g6lc_bios/crates/g6b-{js,dom,html,kernel,spec,wasm}/src`,
`g6lc_bios/browser-ui/compiler/compile.test.ts`.
These are host-model checks, not Variane, silicon timing or RISC-V architectural
conformance evidence; no ISA coverage status is changed in the derived map.

APU P0 adds seventeen `g6b-asm` `p0_` wire/model tests in
`g6lc_bios/crates/g6b-asm/src/{virgl,exec}.rs`: virtio feature bits, virgl bind
masks/color clear, TGSI-text termination/stage binding, state-object ordering,
capset-v1 layout/response capacity and ID/version rejection, 64-bit fence handling,
response bounds/cyclic descriptors, fragmented/truncated submissions, first-error
termination, RV32/RV64 u16 queue wrap and Y_0_TOP orientation. A separate
`cli.rs::picker_is_armed_only_after_initial_draw` test protects publication order. Run
`cargo test -p g6b-asm p0_` from `g6lc_bios`. References are pinned in its
`pins.toml [graphics_wire]`. External virglrenderer execution is a separate
reference diagnostic; none of these tests proves APU RTL or adds ISA coverage.

## Standalone APU transport verification (non-ISA)

`verif/tb/apu/run-virtio-mmio.sh` consumes `corev_apu/apu/Flist.apu` and runs
`tb_g6lc_apu_virtio_mmio.sv` through the remote testharness proxy. Virtio 1.3 CSD01
sections 2.1/2.6/4.2.2 are the register/status/split-queue references. The test first
reproduced 25 failing checks, then passed **4,240 checks / 636 clock cycles**, rc 0,
on remote Verilator 5.008 with assertions enabled. Coverage: discovery, unsupported
feature rejection, status-bit retention, queue stop/reset/re-enable, delayed backend
reset/stop acknowledgements, synchronized QueueReady reads, inactive/failed queue
completion refusal, notification/IRQ set-over-clear, 64-bit ring/fence and 32-bit
context retention, malformed MMIO accesses, 2,048 queue-size helper cases, 2,049
configured-depth cases and continuous ApuOff output checks. Configuration-helper
AI/issue-width independence is not a full SoC or real-DMA configuration matrix.

Strict RTL lint covers enabled AddrWidth=12/16/64 and disabled top. `APU_SYNTH=1`
adds remote Yosys/slang generic synthesis, structural checks, no-latch assertions
and a zero-cell assertion for the disabled top; enabled transport is 13,964 generic
cells / 819 sequential bits. No STA, formal proof, DMA, renderer or unchanged-driver
RTL evidence follows. This is a standalone runner, not yet a registered default
build-platform suite; the full SoC/formal gate remains open. Runtime sideband and
verification commands are recorded in `AGENTS-todo.md` under P1 transport review.

`APU_AXI=1` adds `Flist.apu_axi` and `tb_g6lc_apu_axi_lite.sv`: **318 checks /
1,601 clocks**, remote rc 0. Both real PULP AXI-Lite/register bridges are exercised:
private/public aperture separation, accepted-request authorization retention, stale
control epochs, snapshot consistency, 64 authorization/strobe/AW-W-skew cases,
R/B stability under stalls, hardware reset with pending responses, and control
progress while guest QueueReady reads wait for backend drain. Firmware ACK alone
cannot finish reset. Packed BFM bus arrays resolve the observed coroutine request
propagation skew; the stability assertions remain enabled. The fixture describes
only core geometry for admission checks, not an instantiated CPU/domain system.

With `APU_SYNTH=1`, enabled/disabled wrapper lint and flattened generic synthesis
pass: **19,944 cells / 2,287 sequential bits enabled; 522 / 162 disabled**, no
latches or structural errors. Disabled AXI retains response bookkeeping, not APU
state. File/rule-specific warnings in unchanged upstream dependencies are scoped
by `apu_axi.vlt`; first-party RTL width warnings are not waived. No actual DMA,
firmware-domain routing, epoch-exhaustion proof or renderer is covered.

`APU_DMA=1` adds `tb_g6lc_apu_dma_read.sv` and the actual standalone read master
against a backpressured AXI memory responder. Three remote profiles pass:

| Window base / burst cap | Cases | Checks | Clocks | Generic synthesis cells |
|---|---:|---:|---:|---:|
| 0x80000000 / 16 | 295 | 159,208 | 33,000 | 5,698 |
| 0x280000000 / 1 | 293 | 227,649 | 47,460 | 5,678 |
| 0x280000000 / 256 | 295 | 156,424 | 33,576 | 5,687 |

All report zero errors and exit 0. Checks include per-cycle invariants, byte-exact
stream comparisons, one outstanding burst, no AR extent outside the request,
4 KiB boundaries, every alignment with lengths 1..33, 64 KiB transfers, invalid
resource/context/permission/epoch/offset/length/mapping/root configurations,
request snapshots, cancellation under AR/R/data/completion stalls, SLVERR/DECERR
including an exact delivered prefix, runtime disable, and wrong-ID/early-or-missing
RLAST/unsolicited-response quarantine. The one-beat profile omits inapplicable
early-last and mid-burst-pause cases. SVA checks AR/data/completion stability and
successful completion counts. There is no time-out-to-success behavior.

`APU_SYNTH=1` adds strict first-party width lint plus flattened synthesis for all
three enabled profiles and the disabled leaf: 751 sequential bits enabled; zero
cells disabled (asserted); no latches or structural errors. Prior transport and
AXI suites still pass in the same invocation. These are AXI memory-model tests,
not protected-table lifecycle, SG/write DMA, cache coherence, SoC integration,
formal proof or graphics execution evidence. Handoff/cancellation obligations
are recorded in `AGENTS-todo.md` under P1 resource-checked DMA read leaf.

`APU_DMA_WRITE=1` adds `tb_g6lc_apu_dma_write.sv` and the actual standalone
writer against an independently backpressured AW/W/B memory model. Both profiles
pass 298 cases: window 0x80000000 with 8-byte input chunks (456,689 checks / 80,169
clocks) and 0x280000000 with 3-byte chunks (1,246,216 / 283,317). Checks include
per-cycle invariants, byte-exact memory/guard comparisons and every AW extent/WSTRB,
all alignments with lengths 1..33, 64 KiB, invalid mappings/permissions/epochs and
stream keep/offset/last, source starvation, independent AW-first/W-first progress,
WVALID-dependent AWREADY, cancellation and runtime disable under stalls, delayed B,
partial-error writes, and early/wrong-ID/unsolicited B quarantine. AW/W/completion
stability and success-byte accounting assertions remain active. No timeout implies
successful retirement, and errors do not imply rollback of written bytes.

Strict first-party width lint and flattened synthesis pass: enabled low/high
profiles 5,712/5,708 generic cells, 766 sequential bits; disabled zero cells asserted,
no latches/structural errors. The shared read/write admission checker is also
rechecked by the prior three read profiles and transport/control suites, unchanged.
These are standalone leaf tests, not SG, protected-table lifecycle, combined-copy,
coherence, rendered output or strict core qualification. The write completion/lifetime
contract and exact runner flags are in `AGENTS-todo.md` under P1 DMA write leaf.

`APU_SG=1` adds `tb_g6lc_apu_sg.sv` (Entries=64 and 128) against the list-walker
plus child read/write DMA. `APU_MEM=1` adds `tb_g6lc_apu_storage.sv` (mapping
table, immutable command snapshot, `apu_xfer_check`), `tb_g6lc_apu_queue.sv`
(used-ring elem-then-idx publication, idx wrap, cancelled idx not published)
and `tb_g6lc_apu_mem.sv` (firmware backend: map insert/lookup, used-ring,
command-DMA fill/release, SG list load and SG read transfer through one AXI
master). `APU_SOC=1` adds grant/soc/attach/th/xbar/th_load/fwram/domain.
`tb_g6lc_apu_fwram.sv` covers idx 12, hex load, cookie, size-3, a CVA6 I$
2-beat INCR fill of crt0 `auipc`/`spin`, and WRAP/oversize/window-cross
SLVERR. `tb_g6lc_apu_th_load.sv` AXI-reads the preloaded reset vector
through the compositor. `run-cva6-fetch.sh` adds `tb_g6lc_apu_cva6_fetch.sv`
(one CVA6 `hart_id=1` I$ fill + commit at `0x90000000`).
`run-cva6-dual-fetch.sh` adds `tb_g6lc_apu_cva6_dual_fetch.sv` (core 0 ROM
`0x10000`, core 1 firmware RAM). `run-cva6-cluster-fetch.sh` adds
`tb_g6lc_apu_cluster_fetch.sv` (`g6lc_cluster` PerCoreBoot, shared mem).
`run-cva6-th-fetch.sh` adds `tb_g6lc_apu_th_fetch.sv` (compositor last-match-wins
DRAM hole + RAM-port I$ fill). `run-dma-init.sh` adds `tb_g6lc_apu_dma_init.sv`
(DMA read through DRAM lo; firmware RAM is not DMA backing). `run-th-osbi.sh`
adds `tb_g6lc_apu_th_osbi.sv` (testharness 14-rule OpenSBI-visible last-match
+ host `osbi_check` for opt-in `ariane-g6lc-apu.dts`). `run-cva6-cookie.sh`
adds `tb_g6lc_apu_cva6_cookie.sv` (CVA6 hart 1 mailbox run to cookie
`0x600D000A`). `run-cva6-th-cookie.sh` adds `tb_g6lc_apu_cva6_th_cookie.sv`
(same cookie through compositor `th_load` `gen_exec`). `run-cva6-tgsi.sh`
adds `tb_g6lc_apu_cva6_tgsi.sv` (pre-encoded MOV job cookie `0x600D000B`).
`run-cva6-tgsi-cc.sh` reuses that TB with `apu_tgsi_cc.hex` (compiler +
job linked on CVA6; TEX fail then MOV; cookie `0x600D000B`). Directed
`tb_g6lc_apu_fwram.sv` case 6 covers size-0/1 and sign-ext PA.
`run-cva6-osbi-boot.sh` adds `tb_g6lc_apu_cva6_osbi_boot.sv` (hart 0
fetches DRAM lo `0x80000000`; hart 1 firmware RAM; not a real OpenSBI ELF).
`run-cva6-osbi-uart.sh` adds `tb_g6lc_apu_cva6_osbi_uart.sv` (DRAM-lo
payload stores `0x41` to UART `0x10000000` through compositor stub).
`run-cva6-osbi-clint.sh` adds `tb_g6lc_apu_cva6_osbi_clint.sv` (DRAM-lo
payload stores MSIP=1 to CLINT `0x02000000` through compositor stub).
`run-cva6-osbi-plic.sh` adds `tb_g6lc_apu_cva6_osbi_plic.sv` (DRAM-lo
payload stores priority=1 to PLIC `0x0C000004` through compositor stub).
`run-th-exec.sh` adds `tb_g6lc_apu_th_exec.sv` (compositor
AXI4 `ExecEn` bind, TID+IADD peek 10/11, shader MOV, shader `ST`+`DPEEK`
`1.0f`, scanline-fill DMEM[0..3], packed `size=3`). `APU_EXEC=1`
(`run-exec.sh`) adds native exec `LDC` plus host `tgsi_check` for `IMM[n]`/
`{0,0.5,1,2}`; TEX still fail-closed.
None of these tests is a full testharness OpenSBI firmware boot or a
stock-driver GLES2 proof.
Remote results are recorded in `AGENTS-todo.md` under P1 SG walker / storage /
used-ring and P2 testharness firmware RAM I$ fills. None of these tests is a stock-driver GLES2 or renderer proof.

### APU completion review regression (2026-09-15)

Against `d74010111`, added tests first reproduce twelve source-tag failures,
26 native decode failures and six firmware-RAM read failures. After corrections:

| Test | Cases | Checks | Clocks | New contract evidence |
|---|---:|---:|---:|---|
| `tb_g6lc_apu_th` | 12 | 60 | 221 | AW/AR acceptance source retained across live tag changes; delayed W; denied writes have no effect |
| `tb_g6lc_apu_exec` | 29 | 61 | 2,646 | BR/NOP/HALT shader privilege; undefined opcode and high-register-index rejection; RF preserved; next valid job works |
| `tb_g6lc_apu_fwram` | 49 | 5,699 | 5,372 | Read-drain/alignment plus AWLEN+1 rejected-write drain on/off, AW metadata retention, B stalls, lane strobes/guard bytes, WLAST quarantine and fabric-reset recovery |

Write follow-through initially reproduced 170 failed checks; the expanded RAM
suite above passes via `run-fwram-only.sh`. Enabled/disabled 4-KiB leaf lint and
generic synthesis pass, with exactly one pre-map `$mem_v2` enabled and zero
disabled. Missing W cannot complete; malformed WLAST blocks all channels until
coordinated fabric reset. No full-PA/source/atomic or control-bridge fix is implied.
The same focused run revalidated `run-cva6-cookie.sh`: 14 checks / 1,835 clocks,
`0x600D000A`, retaining the five known core SELRANGE warnings. Remote shell
`cf49f2` exited 0. Local log: `%LOCALAPPDATA%/Temp/devin.exe-overflows/`
`shell-cf49f2-9d95ba4a2eb780c4/content.txt`; RAM synthesis logs on the builder:
`/tmp/g6lc-apu-virtio-mmio/fwram/write-synth-{0,1}.log`. Tested RAM/TB Git blob
IDs: `5335eff6f97185ae20cb3667efff534a0eff4dd7` /
`bffa420cd3b7951d69513a6bb7b3e2305671e09c` (not a commit or full-source manifest).

The earlier review ran all directed suites in `APU_EXEC=1 APU_SOC=1 APU_AXI=1 APU_DMA=1
APU_DMA_WRITE=1 APU_SG=1 APU_MEM=1 APU_SYNTH=1 bash
verif/tb/apu/run-virtio-mmio.sh` through the remote testharness proxy, passing
before this write follow-through. The focused rerun is not a fresh full-suite pass.
The initial combined run stopped in SoC lint on upstream FPnew width warnings.
File/rule-scoped `fpnew_pkg.sv` exceptions cover LITENDIAN/WIDTHEXPAND;
no new first-party width exception is added. Remote rerun `5a1d1f` exited 0:
compositor 64 cases / 513 checks / 3,071 clocks and CVA6 cookie 14 checks /
1,835 clocks pass. Native/compositor lint and generic synthesis screens
completed; exact counts and log location are in `AGENTS-todo.md`. Existing
runner waivers remain. Five CVA6 SELRANGE warnings and upstream unreset-SRAM
read-data warnings remain visible; this is not warning-free full-core lint.
Firmware cross-compile is skipped without RISC-V gcc; the checked-in images are
bring-up inputs, not fresh compiler-parity or reproducible-image evidence.

Review narrows prior claims: the target TGSI cookie uses an opcode stub and
frozen MOV output, not host-equivalent compilation. Direct CVA6 reset does not
establish S-mode isolation. Exec local arrays are not SRAM macro proof; MemEn
and ExecEn are not combined; table simulation initialization does not prove
reset validity. Remaining source/RAM protection, full-PA/write-drain, epoch/
lease/cancel, actual OpenSBI/Linux, noncoherent DMA, formal and graphics gates
are enumerated in the APU architecture notes. No Linux/Mesa, BIOS boot-health,
rendering or physical qualification is promoted by these unit tests.

Build-platform `verify --lint --formal --sim --synth --target g6lc64_stream8
--dry-run` executes no verification; its success exit is not gate evidence.
It currently chooses local tools/core suites rather than the required APU
remote path. No BIOS source, Linux helper or journal-format changes were made.

## Running the suites (single orchestrator)

```sh
cd build-platform
bun run src/cli/index.ts test --list            # every suite + group + runnable status
bun run src/cli/index.ts test <id>              # one suite (e.g. riscv-arch-test)
bun run src/cli/index.ts test --group arch      # a whole family
bun run src/cli/index.ts test --open-source     # everything runnable on the OSS toolchain
```

Suites whose tools / submodule (`riscv-dv`) / UVM simulator are missing are **skipped, not failed**.
Groups: `smoke`, `arch`, `directed`, `benchmark`, `uvm`, `generated`, `pk`, `linux`.

---

## Suite → spec area (forward map)

| Suite id | Group | Backing test list(s) | Spec area exercised |
|---|---|---|---|
| `smoke-cv64a6` | smoke | compliance/tests/arch subset (`-cv64a6_imafdc_sv39`) | Part I base + M/A/F/D/C sanity on rv64 |
| `smoke-cv32a6` | smoke | subset (`-cv32a6_imac_sv32`) | Part I base + M/A/C sanity on rv32 |
| `smoke-cv32a65x` | smoke | hello-world | bring-up sanity (embedded target) |
| `riscv-tests` | arch | `testlist_riscv-tests-<target>-{p,v}.yaml` | Part I base RV32I/RV64I + M/A/F/D/C unit tests; `-v` = Sv paging (Part II 4.x) |
| `riscv-arch-test` | arch | `testlist_riscv-arch-test-<target>.yaml` | Part I architectural conformance (base + enabled extensions) |
| `riscv-compliance` | arch | `testlist_riscv-compliance-<target>.yaml` | Legacy ISA compliance (base + extensions) |
| `csr-access` | arch | `testlist_riscv-csr-access-test-<target>.yaml` | Zicsr + Part II ch2 CSR access/permissions |
| `mmu-sv32` | arch | `testlist_riscv-mmu-sv32-arch-test-cv32a6_imac_sv32.yaml` | Part II 4.3 Sv32 paging; PMA regions (3.6) |
| `iss-tests` | directed | ISS directed programs | Part I base semantics vs. Spike reference |
| `issue-tests` | directed | `testlist_issues.yaml` | regression for previously-filed ISA/pipeline bugs |
| `cv32a6-tests` / `cv64a6-tests` | directed | `cv32a6_tests.sh` / `cv64a6_imafdc_tests.sh` | per-target directed base/ext regressions |
| `ooo-l3-tests` | directed (optional/lengthy) | `testlist_ooo_l3.yaml` + `ooo-l3-tests.sh` | U5 4-issue OoO ILP/memdep + L2/L3 (`cv64a6_ooo_server`) |
| `mc-stream-tests` | directed (optional) | `testlist_mc_stream.yaml` + `mc-stream-tests.{sh,ps1}` | U6/p6 stream plane × multicore + Zacas/spo: multi-stream PF, thrash, inclusive L3→L2/L1, AMOCAS.W/D, store-fwd, fence drain, CAS lock handoff, CF×stream (`cv64a6_ooo_server` / `server_math`) |
| L2 RR-off equivalence | formal-equivalence diagnostic (small mapped fixtures + larger bbox) | `verif/tb/l2/run-l2-tb.sh` with `L2TB_MODE=equiv`; `L2TB_EQ_MEM=map\|collect\|bbox`; proxy `l2-equiv` | Pinned pre-RR Git blob plus only the bypass fix versus current RR-off. Mapped: 256 B/two-way 9,151; 512 B/four-way 11,675; 0 unproven. `bbox` keep-hierarchy blackboxes tag/data/mshr: 4 KiB 2054/0 (`run-ChPtb8Vc`); 16 KiB PASS; 256 KiB/8-way 2057/0 (`run-zisQrCl4`). Hit inversion leaves `hit_o` unproven. Mapped flop-tag: 1 KiB 16670/0, 2 KiB 26625/0, 4 KiB 46468/0 (300 s), 8 KiB 86023/0 (490 s). Collect 4 KiB 13828/0 (275 s). 1 KiB mapped hit-inversion leaves exactly `hit_o` unproven. Isolated proxy must point `YOSYS` at testharness formal/bin. Controller/port bbox is not a 256 KiB mapped tag-array netlist or ISA claim. |
| L2 replacement and bypass-R leaf diagnostic | directed (copied local/remote snapshots; not strict core qualification) | `verif/tb/l2/tb_g6lc_l2.sv`, `run-l2-tb.sh`; sim/config/synth modes; proxy `l2-leaf` | 17 phases + 3 synthetic ATOP schedules: independent data/traffic/completion and tag/next-victim model checks, including invalid-hole refill and every install/victim address. Four-way remote RR off/on check 1,484 lookups each with victim masks 1/f; eight-way stalled RR mask ff. Corrupted victim oracle fails. Earlier 16-phase records also cover held single/burst/error/exclusive R, ATOP R before/with/after B and short-last fill guard, invalid-first/reset/hits/WT masks/invalidation and opposing hot/scan traces. Baseline bypass R-hold fails; narrow handshake repair passes on four-way RR off/on locally and remote Verilator 5.008 (`l2-leaf-20260914T234313-4bd9099b1be4`, `...T234448-fec52bccce2d`), plus eight-way/stalled local fixture. Generic synth: 2/3 pre-map memories, no latches; correction adds 2 generic cells per policy. `+amo-arith` now computes ADD/SWAP/CAS.W and LR/SC reservation in the leaf memory model and checks WT self-inval readback; synthetic ATOP R/B forwarding remains. Cluster/SMT controls stay `qual-stream8-minis` and `qual-soft-ladder-osbi`. Isolated overlay + `mini_checked_work.S` are experimental N=1/N=2 envelopes, not Linux SKUs. Isolated RR-on candidate `iso-stream8-rr1` (exe `ec650f20…`) ran the same N=2 ELF to kernel `tohost=1` in 154,170 cycles — identical to the RR-off control, not a speedup. Cluster AMOCAS.W/D/Q + 512 B stream_plane also match RR-off cycle-for-cycle (550/704/998/2138). SMT2 I=2: uncompressed tohost RR-off PASS 129,455 cy; isolated `iso-smt2-rr1` RR-on livelocks in verify at 2M cy (fetch dual-issues the two loop addis, never the `bnez`) — not a pass. No RVWMO/CBO or physical qualification claimed. |
| L2 MSHR/bank-conflict units leaf | directed (copied remote snapshot; not core/SMT qualification) | `verif/tb/l2/tb_g6lc_l2_units.sv`; `L2TB_MODE=units`; proxy `l2-leaf --mode units` | Direct `g6lc_l2_mshr` (DEPTH=4, MAX_WAITERS=2) + `g6lc_l2_data` (2 banks). Remote Verilator 5.008 PASS `l2-leaf-20260915T020340-df5db8e21fd8`: merge, merge_full, MSHR full, waiter pop+complete, same-bank conflict and different-bank no-conflict. Serialized-top zero counts are still not passes. Top `merge_full_o` remains unconnected. |
| `mc-spo-soak` | directed (optional) | `mc-spo-soak.{sh,ps1}` + `testlist_mc_stream` artifacts | Assemble smoke + dual-target lint for stream×spo/CF/CAS narrow list (no full sim required) |
| `mc-spo-spike` | directed (optional) | `mc-spo-spike.sh` + `testlist_mc_stream` | Spike ISS soak of multicore spo/CF/Zacas narrow tests (`cv64a6_server_math`); **Spike has no zacas** — CAS paths may soft-skip; not a hard CAS golden |
| `mc-mini-veri` | directed (optional) | `mc-mini-veri.sh` + `verif/tests/custom/multicore/mini_*.S` | **Hard** Verilator bare-metal CAS golden: `mini_tohost` / `mini_jumps` / `mini_amocas_{w,d}` (+ Q via `zacas-policy`) on Variane (`cv64a6_imafdc_sv39`, `RVZacas`); no CRT |
| `zacas-policy` | directed (optional) | `verif/regress/zacas-policy.sh` + `software/zacas/` | §8: Q illegal trap; W/D hard mini; Spike ≠ golden |
| `mc-spo-veri` | directed (optional) | `mc-spo-veri.sh` + self-built CRT ELFs (`work-ver/mc_spo_elfs`) | CRT Variane smoke (**7/7** with `MC_SPO_VERI_FORCE_IMAFDC=1`, Verilator 5.008): AMOCAS.W/D, st-fwd, fence, cas_lock, cf/mispred stream. Residual hang/flake: `cas_stream`+`stream_plane` via `MC_SPO_VERI_FULL=1`. Prefer `mc-mini-veri` for hard bare CAS |
| `ara-vector-path` | directed (optional) | `ara-vector-path.{sh,ps1}` + `testlist_ara_vector.yaml` | U10ᵇ RVV (I ch9): Ara vendor + `Flist.ara` + `server_math_v` + DTS `v` + directed soft-skip/misa/LMUL memcpy + attach/lint gate (full RVV compliance cosim still open) |
| `ai-policy-codec` | directed (optional, remote) | `verif/regress/ai-policy-codec.{sh,py}`, `verif/tb/ai_island/tb_g6lc_ai_policy{,_steer,_resource}.sv`, `policy_main.cpp`, `policy_efficiency.cpp` | Eight-state control plus format-aware benefit steering: literal/randomized scoreboards, native zero/NaN/subnormal handling, format epochs, topology equivalence, 380 ticking scheduling-model fixtures per steering build, 28 matched-format workload pairs and native-trace replay; steering now uses full 16-bit `m/n/k` retention and a `(m+n)*rowbytes(active_k) >= read_bytes` benefit gate. Usage, signed improvements and fixed-code comparators are in `efficiency.json`; per-run synthesis/formal reports own their counts. Local `--synth-only --yosys <existing-yosys>` covers wrappers on/off + 12-step SAT safety/reachability (not induction). `g6lc_ai_island_top` now elaborates with `g6lc_ai_policy_steer` and observable PMU words, and the first safe downstream consumer (policy `prefetch_depth` -> `g6lc_ai_gemm_seq` `ar_max_i`) is wired and re-run through `ai-island-dma` and `ai-island-policy-walk`. `tb_g6lc_ai_gemm_backend` also checks consumer-off/consumer-on numerical equivalence by running the same INT8 GEMM with `ar_max=MaxAROut` and `ar_max=2` (policy `prefetch_depth=1`) and comparing C. No measured MAC/s or silicon throughput evidence. |
| `ai-gemm-reuse` / `gemm-concurrent` | directed (optional; remote runner + local sweep script) | `verif/regress/ai-gemm-reuse.py` (remote, source-hashed snapshot, `--assert`, preserved build/sim logs), `verif/tb/ai_island/run-gemm-concurrent.sh`, `verif/tb/ai_island/tb_g6lc_ai_gemm_concurrent.sv` | N `g6lc_ai_gemm_seq` engines through the real `axi_mux_intf` into ONE shared `g6lc_ai_dram_backend`, now also driving the real `va_turbo_select` recipe-16 consumer (mask `1<<16`, owner lease/epoch, exact-plan assertions). Every C element is checked against an independent integer reference, C is poisoned before each measured phase, and signed exactly-representable operands run in all seven formats alongside the original all-ones cases. Paired baseline (forced reload) versus resident reuse on the same physical engines, serial and concurrent, with cold priming reported separately and PMU read/write sums asserted. First signed run FAILED and caught a real harness bug (packed negative elements sign-extending across neighbours, `exp=0000000d got=ffffffff`); after the fix eng=1/nch=1/VA=1 PASSES (`ai-gemm-reuse-20260907T035117Z-6c1a1a1cf00c`): warm reuse 1.12x-1.18x with operand read beats exactly halved at m=n (INT8 378->328 cycles, r 64->32; FP32 1338->1192, r 256->128), and the 3-batch total including the cold prime still exceeds one baseline batch. 21 directed cases pass: cold/warm, epoch/pointer/stride/n/k/format mismatch, m-not-a-B-key, explicit invalidation, missing permission/lease, stale window, level 0, runtime disable, injected RRESP error recovery, INT4 odd n/k, and C/B alias refusal. Adds a `DECODE` residency experiment at m=1 alongside the square `DUAL` one so both appear in one run (remote `...T010220Z-bddf7872d7ad` PASS): FP32 158->85 resident-B = 1.859x and ->75 both = 2.107x against the square tile's 1.1225x/1.2792x, i.e. 1.53-1.66x larger, confirming a square tile is the least favourable shape for recipe 16. It corrected the model twice: the work terms must be CEIL'd (invisible on square tiles, where beta*beats is integral; at m=1 every fractional case landed on .125 and measured one cycle higher), and the decode gain SATURATES near 2x at 8 lanes with the cap being `steps + c` rather than traffic -- for INT4 the constant alone is 58% of resident-both, which is why INT4 has the worst decode ratio despite the same 8/9 B share. Reconciled in closed form by `1 + beta*(row_bytes/8)/ceil(row_bytes/lanes)`, which rises with lane provisioning. Asserts only invariants, never the speedup: bit-identical C across all four residency points, read beats equal to the per-lease expectation, both-resident reading zero operand beats, and the PMU hit flags. Also parameterises JOB_M/N/K, removes the m*n-even assumption, and guards a latent loader bug (INT4 at k=8 gets a 4-byte row stride the loader mis-reads; all-ones fixtures pass, the first signed tile fails). Adds a `LOSSLESS` paired measurement (harness consumer mask `1<<1`, recipe 1): each pair runs the same logical matrix twice on one engine, at the source format and at the target, with per-element exactness PROVEN on both tiles before either run, C poisoned between them and every C word compared. Remote `...T194820Z-3bf33be6b3dc` PASS: INT8->INT4 189->109 (1.733x), beats 32->16, max_diff=0 BIT-IDENTICAL in hardware; FP32->BF16 and FP32->FP16 669->349 (1.916x), beats 128->64, max_diff=0. The byte ratio is asserted rather than eyeballed. A second `wide_exponent` data class then WITNESSES the regrouping the first could not: `mantissa * 2^exponent` with positive exponents only is still integral (so no fractional operand path was needed), with the mantissa bounded by the target's explicit mantissa bits and `mantissa << max_exp` inside its finite range. Remote `...T202101Z-6f8842a4669a` PASS: FP32->BF16 32 ULP with 38/64 elements differing and FP32->FP16 5 ULP with 19/64, both `bit_identical=0`, while INT8->INT4 stays bit-identical at wide magnitudes (integer accumulation has no rounding site at any scale). 32 ULP is <= 3.8 ppm worst-element against the >= 16,384 ULP a single dropped BF16 mantissa bit would cost, so the 256 ULP bound separates regrouping from lost operand bits. Having no single golden (the two runs differ by design), that class asserts instead that neither run errored, that no C word is still the poison value, that the difference is bounded and that it is nonzero somewhere; the small-integer class is retained as the control with full golden checking. An assertion firing on the first run also corrected the selector model: equal-width refusal applies to the narrowing arm only, since recipe 1's integer repack arm still admits INT4->INT4 as an exact non-narrowing plan. Also asserts the operand-bank alias fix. eng={1,2,4} all PASS (`...T044438Z-6694e3e3bcc6`, `...T045844Z-2464ca922d94`) and show the two levers COMPOSE: reuse gain grows with contention (INT8 1.152x -> 1.255x -> 1.358x for 1/2/4 engines) and concurrency improves once reuse removes the weight traffic (4-engine INT8 2.077x -> 2.448x, FP16 2.374x -> 2.879x, FP32 2.433x -> 2.936x; efficiency 52-61% -> 61-73% of 4x), for a combined serial-cold to concurrent-warm 2.821x/3.262x/3.296x. Adds an OPPORTUNISTIC mixed-stream sweep: eight jobs where misses genuinely change B identity, asserting the hit count equals the intended count and re-checking C after every job. INT8 1.034x/1.070x/1.110x/1.130x at 2/4/6/7 hits of 8 with read beats falling exactly linearly (256 -> 144); FP32 1.028x -> 1.105x; measured speedup matches `1/(1-0.132h)` to three decimals, so the 1.36x headline needs both ~100% hits and multi-engine contention. Adds 32 directed resident-A cases (cold/warm, epoch/pointer/lda/m/k/format mismatch, `n` NOT part of the A key, explicit invalidation, missing lease, A/C alias, error and RRESP recovery) and a four-point `DUAL` experiment per format measuring none/A/B/both on the same engine with identical work: INT8 189/164/164/**139** cycles and 32/16/16/**0** read beats, FP32 669/596/596/**523** and 128/64/64/**0**, i.e. both resident issues NO operand reads. `VA_TURBO=0` reports 1.000x on all four points with no hits. Two RTL defects were caught here rather than in review: the A skip keyed off `cacheable_q` (still clear in ST_CHK where A decides, making the skip dead code while the PMU claimed a hit), and `pmu_reuse_b_hit_o` missing the ST_CHK -> ST_MAC both-resident path. Also refutes intra-engine lane grouping: INT8 k=16 at PE_LANES=16 and 32 is byte-identical (250/200/125), because one element is written per last reduction step so the engine is retire-bound exactly where lanes are idle. Build parallelism is now MEASURED, not assumed: the runner verilates and makes as separate steps under `/usr/bin/time`, passes `VM_PARALLEL_BUILDS=1` explicitly, and records CPU percent. That exposed a 101% CPU 3,712 s build whose cause was the testbench's single `--timing` coroutine (321,102 lines in one 27.4 MB TU); table-driving the experiments cut the four-engine build to 68 s at 168% and the whole run from 3,740 s to 100 s. `VA_TURBO=0` control (`...T043236Z-aca0f8a5fd4f`) reports identical warm cycles/beats and never a hit. Verilator cycles on the class-0 SRAM model: a traffic/latency answer for repeated same-weight jobs, not MAC/s, not silicon, not model inference, and not a measurement of intra-engine lane groups. |
| `ai-island-dma` | directed (optional) | `verif/regress/ai-island-dma.sh` + `verif/tb/ai_island/tb_g6lc_ai_island_dma.sv` + `ai_island_dma_main.cpp` | Live `EnableDmaFetch=1` Verilator smoke with an AXI stub memory: a v2 GEMM descriptor is DMA-fetched, the policy codec/steering are explicitly enabled in a test-local `ai_cfg_t`, and after `ST_OK` completion the sticky policy words at `0x0190..0x019C` are non-zero. First downstream consumer wired: `policy.prefetch_depth` drives `g6lc_ai_gemm_seq.ar_max_i` (clamped to `MaxAROut`), gated by `AiCfg.PolicyCodecEn` and off by default; dense GEMM numerical traversal is unchanged. |
| V/A-Turbo recipe calculations | directed (part of remote `ai-policy-subcode`) | `tb_g6lc_ai_policy_subcode.sv`: `va_heuristic_checks`, externally driven on/off synthesis wrappers; `ai-policy-subcode.py` requires the VA pass marker | 18,473 swept cases plus directed bounds/approval/consumer/window checks PASS in all five cache-off and five cache-on profiles (`ai-policy-subcode-20260907T012755Z-43d44da4f6cb`). Integer-zero proof required, no floating-zero shortcut, explicit conversion evidence, K=1..256 and capacity=0..8. Adds independent 64-bit rational oracles over every precision code and every Q8 kappa value plus 369 directed admission checks. The suite first FAILED at E4M3 (`got=128906 expected=128907`, `ai-policy-subcode-20260907T033251Z-f86e57c24c7e`) and then PASSED (`ai-policy-subcode-20260907T034054Z-8edb3d5bfd7c`, 13,574 controller cases / 6,246,546 checks; cache profile 1,606,960 checks). Now asserts: upward RNE ceilings including sub-ppm widths, a separate toward-zero truncation bound for recipes 21/25/30/31, recipe 26 refused as analytically unspecified, `20'hfffff` invalid/overflow sentinel that a waiver may NOT override, upward-rounded `(eps*kappa+255)>>8`, flatness that only tightens the FULL first term, `relative_domain_valid` required for REL, finite over-budget waivers still recorded as empirical, and exact recipes needing no evidence. Host side: `verif/tb/ai_island/test_policy_approx.py` adds 25 tests (10 stdlib + 15 torch) covering rational oracles, cancellation/zero references, subnormal-overflow refusal and strict JSON (`schema_version=2`, nonfinite -> null, `universal_proof=false`). Corrected sample validation (`policy-approx-corrected.json`): INT8 raw 311,550 ppm / RTL-matched **312,489 ppm** (level 13) replacing the non-matching 310,931; INT4 and 2-bit truncation now exceed 100% and are refused rather than clipped; FP16/FP8 are `unqualified_arithmetic_premises` because those tiles leave the normal-domain conversion range, so no empirical conclusion is drawn. 12 of 12 remain inadmissible at per-element granularity. Adds the moving-window bound: `VA_WINDOW_BOUND` (66,916 checks -- rounding sites `2*ceil(K/window)-1` for k=1..256, the accumulation term against a 64-bit rational oracle over kappa 0..1024, and 36 additive-total cases asserting a term can never REDUCE the bound) and `VA_WINDOW_ADMISSION` (the claimed window must equal `va_turbo_window_log2(numfmt, lanes)`, 8 mismatches charged nothing, sub-unity windowed kappa refused, floor added exactly and out-of-range floor ignored, and the subnormal admission that needs floor AND matched window). The window ADDS the post-reduction term and never replaces the per-product one, because substituting it is measurably unsound (INT8 6,419 ppm windowed vs 37,134 measured, 5.8x). Host side adds 25 more tests (41 total) including `test_windowed_bound_is_diagnostic_for_per_product_epsilon`, which locks that refusal in. FP16/FP8_E4M3/FP8_E5M2 move from refused to qualified at levels 5/13/13 via the absolute floor, and every previously admitted bound got slightly worse now that the FP32 accumulation term is counted. Adds `VA_STACK_REQUEST`: request-side composition (`va_turbo_stack_request`) folds a finished stage into the request so the next selection derives bound/window/budget at the final format, making narrowing-collapse, window-follows-endpoint and the residency/format hazard STRUCTURAL rather than checked (the transform clears `reuse_*_valid` on a format change exactly as the hardware key misses). Asserts the fold advances `numfmt`, clears reuse evidence unless `resident_at_target`, that re-narrowing to the same format is not a narrowing, that the window follows the advanced format, that an exact stage cannot erase a carried bound (kind promoted to REL so the admission gates apply to the stack), that a carried bound is re-gated against the budget, and that `prior_bound_ppm = 0` leaves selection bit-identical. Two measured reversals are recorded with it: carrying an EPSILON into the `eps * kappa` multiply both double-scaled the earlier stage and de-constanted the per-recipe multiply (ABC stalled >31 min at 0.1% CPU), fixed by carrying the BOUND and adding it after the multiply (+339 selector cells, synthesis back to 16s); and the request-side top still stalls ABC (>13 min vs 31s) because `select -> fold -> select` is one combinational cone of ~2x depth, so it is excluded from the synthesis gate by design and plan-side composition remains the combinational form. Adds `VA_COMPOSE`: plan composition (`va_turbo_compose`) checked as an algebra -- orthogonal resource fields union, conflicts are refused rather than silently resolved (two conversion targets, two group geometries), an unapplied input cannot be composed into permission, composition is order-insensitive, `compose(a,a) == a` (narrowing collapses), per-product error terms ADD so an approximate stage composed with an exact one still pays its own term, the budget is re-gated from the REQUEST rather than inherited from an input plan, the window is recomputed from the endpoint, and above all the ORDERING HAZARD is refused: both residency keys in `g6lc_ai_gemm_seq` include the format (lines 554/643), so a narrowing that changes `numfmt` is a residency miss by construction and composing them requires the caller to assert the resident tile is already at the target format. New synthesis top `tb_g6lc_ai_va_turbo_compose_on` makes its area measurable (a package function costs nothing until instantiated): one selector 4,567 cells, two selectors + compose 12,521, both 0 sequential and 0 latches. Composition also exposed a real error in the lossless classification -- exactness depends on the TARGET (an INT8 job accumulates in exact integers) not on both ends -- taking exact pairs from 1 to 9 of 17 and shrinking the selector by one comparison. Adds `VA_LOSSLESS_NARROW`: lossless narrowing (recipes 1/3/17) extended beyond the integer-only gate that had excluded FP32 from every exact optimisation. Sweeps all 64 (src,dst) format combinations and admits exactly the 17 strictly-narrower ordered pairs, asserting `VA_ARITH_EXACT`/eps=0 for the bit-identical integer-to-integer case (INT8->INT4) and `VA_ARITH_REL`/1 ppm accumulation epsilon wherever a float accumulator regroups, that `row_bytes` really shrinks, that equal-width pairs are refused, that `lossless_proven` is mandatory, that a float source without a narrow target still falls back to the integer-only rule, and that recipe 17 still needs its resident-B lease. Measured quality: FP32->BF16 5.803 ppm against the approximate twin's 7,828 (1,349x tighter), FP32->FP16 0.323 vs 977, FP16/BF16->FP8 exactly 0.000. Isolated selector synthesis 4,002 -> 4,619 cells (+617, +15.4%), 0 sequential, 0 latches, disabled wrapper still zero. Selector-only: no consumer mask bit and no `lossless_proven` producer yet, no execution consumer for approximate arithmetic, no universal proof, no STA. |
| `ai-policy-subcode` | directed (optional, remote) | `verif/regress/ai-policy-subcode.{sh,py}`, `verif/tb/ai_island/tb_g6lc_ai_policy_subcode.sv`, `policy_subcode_main.cpp`; `build-platform/test/config.test.ts` | Five parameter profiles PASS: 13,574 standalone cases each, exact 32-cycle completion, native rounding, cost/threshold boundaries, malformed geometry, busy-start rejection and reset/flush/disable. Actual steering on/off comparison covers all primary outputs: 1,172 accepts, 444 results, 712 cancellations per build. Separate handcrafted prefill/decode/routed/diffusion tile reports include external traffic and evaluator tax; all 105 named fixtures retain subcode 0 at read128/read512, so incremental modeled MAC/cycle regresses. Remote artifact `ai-policy-subcode-20260906T121408Z-82b41477e961`; feedback self-tests distinguish positive/tie/regression and reject invalid counts, and all five profiles explicitly report performance `NOT_QUALIFIED` independently of correctness PASS. Local `--synth-only --yosys PATH --formal required`: 4,881 generic cells / 340 sequential / zero latches; disabled zero; 36-step, four-assertion fixed-INT4-fixture control proof plus completion witness (not datapath/integration proof or STA), artifact `ai-policy-subcode-synth-20260906T115809Z-e9b58abe2d73`. Cache extension: five cache-on profiles PASS alongside cache-off profiles (`ai-policy-subcode-20260906T132220Z-e638dd091632`), each 1,556 hits/1,623 misses or rejections; full-key changes, 32-to-1 latency, cancelled-search exclusion and primary-output equivalence. Latest generic cache off/on: 4,880/5,473 cells, 340/342 sequential, no latches; 72-step fixed-fixture cache control/hit witness PASS, not numerical/full-key induction (`ai-policy-subcode-synth-20260906T132132Z-356d75ad3869`). |
| `ai-policy-calibration` | directed (optional, host metadata/model) | `verif/regress/ai-policy-calibration.sh`; `capture_policy_model.py`, `policy_calibration.py` and their tests under `verif/tb/ai_island`; subcode runner `--replay` | Remote provisioning basis (`verif/regress/ai-gemm-codec-basis.py`, proxy-only): six points x five shape classes x seven formats x every AR depth, 2,100 records, digests stable; best provisioning is format-dependent and shape-independent, FP32 reaching +320.0% at 64 lanes. Coarse generic area 383,575 -> 2,416,615 cells for 8 -> 64 lanes, so ganging buys 4.20x for 6.30x while four clusters reach 4x for 4.00x. Depth proxy 1493 -> 1626 levels is not a frequency claim (untechmapped, and pipelining the dot moves it four levels while adding +55% cells); no STA exists. After the constant-bound loop change, `run-gemm-stripe`, `run-gemm-channels`, `ai-island-dma` and the remote codec suite all PASS with byte-identical measured cycles. Measured AR-depth feedback: `tb_g6lc_ai_gemm_backend +measure` sweeps every legal AR depth per format with identical result digests, and `policy_measure.py` (35 tests PASS) emits `g6lc.policy-measure.v1` with exact-rational MAC/cycle; depth 2 beats depth 1 by `+5.263%` worst case. Default sweep-off directed run unchanged and passing. Local WSL dispatch, one small job per format, so diagnostic-grade and not silicon. 114 capture/calibration/motif host tests PASS (initial capture/calibration subset 57); structural templates, ordered epilogue recognition, exact evidence guards, normalized gain consistency, warm-up/hold/cooldown and rollback are host-only. Template transfer is limited and no actual array timing is admitted. Actual pinned pretrained SmolLM2/Pythia captures in FP32/BF16, prefill/decode and 63/64-token cases, disjoint model/weight holdout, native transposed linear weights, sample validation, exact tile/MAC conservation, signed gains and fixed-service 6x target bounds. 84 sampled metadata/cost cases PASS actual RTL replay at read128/read512 (`ai-policy-subcode-20260906T130005Z-fa2eef33ac8a`, `ai-policy-subcode-20260906T130006Z-3b1257758971`). Fitted parameters remain unchanged and do not improve throughput; masked-tail oracle is exploratory, not deployable. Not numerical tensor/AXI replay, QEMU inference, or live floating grants. |
| `ai-native-eval` | directed (optional, native model) | `verif/regress/ai-native-eval.{sh,py}` + `ai-tensor/python/ai_tensor/{c_abi,numfmt}.py` + `g6lc_qemu/tools/ai_tensor_bridge.py evaluate` | Descriptor-v2/k-major native-byte interop against live mask 3 and a software-only format fixture; canonical FP32 NaNs, grant/SP24 refusal and independently checked numerical outputs/negative controls. 84 requests per profile: live 16 executed/68 rejected; software fixture 82/2; 17 negative checks each. Requires a built native binary; neither QEMU guest execution nor RTL cycles/MAC/s. |
| `ai-desc-formats` | directed (optional, remote) | `verif/regress/ai-desc-formats.{sh,py}` + `verif/tb/ai_island/{tb_g6lc_ai_desc_formats.sv,desc_formats_main.cpp}` | Helper legality/grants plus actual descriptor-engine refusal/start/handoff: 3,072 helper checks, 1,024 wide-mask cases, 1,024 engine cases, 4 starts, live mask 3, all enum values 0..7. Effective legacy INT + EW=1 alias must grant and hand off as INT4; unsupported dtype/accmode/EW/SP24 combinations fail before operand fetch. Not full GEMM/SoC evidence. |
| `ai-fp-mac` | directed (optional, remote) | `verif/regress/ai-fp-mac.{sh,py}` + `verif/tb/ai_island/{tb_g6lc_ai_fp_mac.sv,fp_mac_main.cpp}` | Exact widening, separate RNE FP32 multiply/add, flags, held response and reset/flush/disable cancellation. FpPipeRegs 1/2/3/5: measured scalar latency 4/6/8/12 and II 6/8/10/14 cycles; 141,587 widening probes and about 40k scalar transactions per variant. Existing-vendor lint baseline is explicitly audited with negative controls. Standalone generic synthesis, widening properties and bounded control checks are separate evidence, not floating GEMM or ISA F/D conformance. |
|| `ai-pe-dot-float` (FP_DOT_MAXW invariant) | directed (remote) | `verif/regress/ai-pe-dot-float.sh` + `verif/tb/ai_island/pe_dot_float_main.cpp` | Adds the FP_DOT_MAXW sufficiency invariant: `fp_dot_product_aligned` silently zeroes a product whose alignment shift reaches 640, which would drop the LARGEST term in a window (a wrong answer, not a rounding). `block_exp` is the minimum lane exponent so the shift is non-negative, and the worst case is 506 spread + 48 product bits + 8 bits of 256-lane headroom = 562 of 640, so the arm is unreachable for every supported format -- but nothing checked it. Now asserted per cycle in `g6lc_ai_pe_dot_float` (translate_off) and exercised at the limit by directed max-spread vectors (max normal squared beside min subnormal squared in one window) for FP32/BF16/FP16/E4M3/E5M2. 5,024 checks PASS. An output-only check cannot catch a drop here: the dropped term is below the ULP of the surviving one, which is why the invariant is inside the DUT. |
| `ai-pe-dot-float` | directed (optional) | `verif/tb/ai_island/run-pe-dot-float.sh` + `verif/tb/ai_island/pe_dot_float_main.cpp` + `verif/tb/ai_island/run-gemm-backend.sh` + `corev_apu/ai_island/g6lc_ai_pe_dot_float.sv` + `corev_apu/ai_island/g6lc_ai_pe_dot_float_pipe.sv` + `corev_apu/ai_island/g6lc_ai_gemm_seq.sv` | FP8/FP16/BF16/FP32 block-floating dot product, Lanes=4/256; combinational `pe_dot_float` and pipelined `pe_dot_float_pipe` verified with Verilator. Pipelined variant stresses back-to-back issue with differing `numfmt` and per-lane valid masks; Lanes=4 and Lanes=8 PASS 5,028 checks each with 1-ULP tolerance for finite BFP-vs-float rounding. GEMM backend (`tb_g6lc_ai_gemm_backend`) PASS for nch={1,2,4,8}, `dpf=0,1`, across INT4/INT8/FP8/FP16/BF16/FP32. NaN/Inf/zero propagation, subnormals and signed zero. Yosys `read_slang`, `check -assert`, `synth -noabc -top g6lc_ai_pe_dot_float -flatten` and `synth -noabc -top g6lc_ai_pe_dot_float_pipe -flatten` all report zero errors/warnings and zero CHECK problems; mantissa product is now an explicit 24×24 multiplier. Live grant/PE masks still INT8/INT4 by default. Lanes=256 is an elaboration/lint gate, not a timing/performance claim; not an ISA F/D extension. |
| `ai-matrix-directed` | directed (optional) | `verif/regress/ai-matrix-directed.sh` + `testlist_ai_matrix.yaml` | Custom `Xg6lcai` contract files + island I3-lite CAP/DramClass; F12 tiling smoke present. CLI: `test --ai` |
| `ai-matrix-veri` | directed (optional) | `verif/regress/ai-matrix-veri.sh` + `testlist_ai_matrix.yaml` | Custom `Xg6lcai` Variane HARD GEMM/CAP/PMU; I3-lite 8 GB/s; F12 `ai_gemm_tile_2x2_smoke` |
| `ai-s4-mshr-xbar` | directed (optional, remote) | `verif/regress/remote/s4-mshr-xbar.sh` + `ai_s4_mshr_xbar_smoke.S` | I3 S4 testharness_proxy xbar×8 MSHR×MaxAROut. CLI: `test --ai-remote`. S4 parks hart 1: **`ai-dt` 2620 cy**, `ai-d1` 4246, `ai-d2` 4520, `ai-d4` 4553, `ai-d8` 4582. CLASS1 first-pass {1,2,4,8} 5363/5758/5762/5821 (two-hart). **Variane evidence** |
| `ai-dual-core-stripe` | directed (optional, remote) | `verif/regress/remote/ai-dual-core-stripe.sh` + `ai_dual_core_stripe_smoke.S` | S3 `NrCores=2` on striped CLASS1 slave (CAP 0x38 N>=2, consecutive 64 B lines, S5 `0x70`/`0x74`). Default `ai-d2`. **PASS 830/900/582 cy** on `ai-d2`/`ai-d8`/`ai-sc{2,4,8}`. Not OpenSBI. **Variane evidence** |
| `ai-nch-occupancy` | directed (optional, remote) | `verif/regress/remote/ai-nch-occupancy.sh` + `ai_nch_occupancy_smoke.S` | S5 all-N occupancy: CAP `0x38` N, `sd` cookie+i at LINE+i*64, CAP `0x70+4*i` nonzero for i<N. Hart 1 parks. Default `ai-d8`. **PASS 1328/889 cy** on `ai-d8`/`ai-sc8`. Not OpenSBI. **Variane evidence** |
| `ai-class1-amo-lrsc` | directed (optional, remote) | `verif/regress/remote/ai-class1-amo-lrsc.sh` + `ai_class1_amo_lrsc_smoke.S` | S4 exclusive `amoadd.d` + `lr.d`/`sc.d`. **PASS `ai-dt` 552** / CLASS1 **`ai-d1` 781** / **`ai-d2` 945** / **`ai-d4` 941** / **`ai-d8` 941 cy** / class-0 stripe **`ai-sc2` 620** / **`ai-sc4` 620 cy**. Isolated lrsc **130 cy**; wrap-stack **104 cy**. Not OpenSBI. **Variane evidence** |
| `ai-dual-core-excl` | directed (optional, remote) | `verif/regress/remote/ai-dual-core-excl.sh` + `ai_dual_core_excl_smoke.S` | NrCores=2 exclusive snoop: hart 1 store kills hart 0 `sc.d`. **PASS `ai-dt` 16667 cy** / CLASS1 **`ai-d1` 17137** / **`ai-d2` 17137** / **`ai-d4` 17163** / **`ai-d8` 17187 cy** / class-0 stripe **`ai-sc2` 16686** / **`ai-sc4` 16686 cy**. Not OpenSBI. **Variane evidence** |
| `ai-dual-core-lrsc-disjoint` | directed (optional, remote) | `verif/regress/remote/ai-dual-core-lrsc-disjoint.sh` + `ai_dual_core_lrsc_disjoint_smoke.S` | NrCores=2, **two different** reservation addresses, interleaved LR/SC: hart 0 `sc.d A` must succeed although hart 1 reserved B inside its window. The case `ai-dual-core-excl` structurally cannot see (one line in play ⇒ a single global reservation passes it). `tohost=9` **is** the single-reservation defect (AI-X1). Gates any multi-hart claim on a `G6LC_AI_EXCL_MULTI` build. **PASS `ai-dt` 16602 cy / `ai-sc2` 16617 cy** (class-0 stripe N=2, i.e. the demux path with `DRAM_EXCL_AW=8`). Oracle proven by negative control: the same ELF on a `+define+G6LC_AI_LRSC_SINGLE_RES` netlist (`NRes=1`, verlib `work-ver-ai-1res`) **FAILS `tohost=9` 16580 cy**, so this gate is not a vacuous pass. **Variane evidence** |
| `ai-numfmt-grant` | directed (optional, remote) | `verif/regress/remote/ai-numfmt-grant.sh` + `ai_numfmt_grant_smoke.S` | AI-X2 grant enforcement: descriptor `flags.numfmt` outside `CAP_OFF_DTYPE_MASK` must complete `ST_BAD_FMT`, never be demoted to INT8. Four steps, two-sided so the oracle is intrinsic: `AI_FMT_INT`→`ST_OK` (must not over-reject; `flags==0` is what every pre-`numfmt` image writes), `AI_FMT_BF16`→`ST_BAD_FMT`, `AI_FMT_FP32`→`ST_BAD_FMT`, then `AI_FMT_INT`→`ST_OK` (refusal not sticky). **PASS `ai-dt` 1310 cy / `ai-sc2` 1316 cy.** Oracle proven in **both** directions, so it cannot pass vacuously: on `+define+G6LC_AI_TB_OVERGRANT` (grant mask raised to INT8+BF16, a format the PE cannot execute; verlib `work-ver-ai-overgrant`) the same ELF **FAILS `tohost=5` 1109 cy** = "BF16 was not refused". Note this evidence is descriptor traffic, so it does **not** depend on SV assertions — which are dead in this flow, see AI-X5. Unlike `ai_island_mmio_smoke` it does **not** soft-pass on a trap (`tohost=13`), because a bus error would otherwise report SUCCESS having exercised nothing. Uses `OP_LAYOUT`, so no GEMM datapath and not a throughput number. **Variane evidence** |
| `ai-gemm-shape` (F1/AI-X8/X9/X10) | directed (optional, remote) | `verif/regress/remote/ai-gemm-asym.sh <test>` (one runner, test name as `$1`) + `ai_gemm_s4_smoke.S`, `ai_gemm_s4_oddk_smoke.S`, `ai_gemm_s8_{asym,astraddle,oddn,n1,m1n3}_smoke.S` | **The non-power-of-two suite.** Every AI GEMM fixture before this was a power of two in all dims, and that one property hid three defects: an odd-`n` C-store corruption (AI-X8), a multi-channel beat-straddle corruption (AI-X10), and the fact that the suite could not distinguish row-major from k-major B at all (AI-X9). Per-check exit codes (`3`=status, `5`=trap, `7`=ticket, `9+2e`=`C[e]`, `31`=timeout) localise a failure without a waveform. Each fixture is built so the wrong behaviour cannot coincide with the golden: `asym` gives `C[0][0]`=91 not 301 under the wrong layout; `s4_oddk` gives 47 not 5 if the pad nibble is not masked; `s4` puts operands on the INT4 endpoints (−8, 7) with `−8×−8=+64` and 3 of 4 C values negative; `astraddle` is the acquittal control that pads `ldb` so only A straddles. **PASS `ai-dt`**: s4 1230, s4_oddk 1230, asym 1375, oddn 1369, n1 1154, m1n3 1218, astraddle 1377 cy. **PASS `ai-sc2`**: s4 1146, s4_oddk 1146, asym 1276, oddn 1227, astraddle 1290 cy. **PASS `ai-d8`** (8-channel class-1 LiteDRAM, the widest `SplitArId` config): smoke 1738, asym 2092, astraddle 2093, oddn 1968, s4 1716, s4_oddk 1716, 4x4 2587, n1 1547 cy. Oracles proven non-vacuous by their own history — `oddn` failed `tohost=13` before AI-X8, and `asym` failed `tohost=13` on `ai-sc2` before AI-X10 while passing on `ai-dt`. **Variane evidence** |
| `ai-gemm-64x64` (format A/B) | directed (optional, remote) | `ai_gemm_s8_64x64_smoke.S` + `ai_gemm_s4_64x64_smoke.S` via the same runner | Byte-identical descriptors except `flags.numfmt`, same all-ones operands, same golden `C=64` over all 4096 elements, so the cycle delta is attributable to the format alone. **INT8 93,194 cy / INT4 93,177 cy — a 17-cycle, 0.02% difference.** Recorded as a *negative* result: INT4 buys ~nothing here because the MAC cost is identical at `k=64 ≤ PeLanes`, the load is AR-latency-bound rather than byte-bound at `MaxAROut=2`, and the wall clock is dominated by boot/poll/check. This is the evidence that §2's "INT4 = 2×" is a DRAM-bandwidth-regime claim and **must not** be quoted as a throughput number for these fixtures. 0 assertions. **Variane evidence** |
| `ai-gemm-fmt-pmu` | directed (optional, remote) | `ai_gemm_fmt_pmu_smoke.S` | Sharper INT4-vs-INT8 oracle: runs both formats in one ELF, reads the island's own per-job counter `AI_PMU_CY` (0x188) after each, and passes only if INT4 used **strictly fewer island cycles**. Self-contained (no hardcoded golden, cannot rot) and non-vacuous (equal times FAIL). Needs `S4_TIME_OUT=3000000` — the two 4096-word C clear/check loops, not the GEMMs, exceed the default 500k budget. Also documents that `AI_DONE` (0x10C) is **write-1-to-claim** (pops the CPL FIFO head), which any multi-job ELF must do or the second job hangs. **PASS `ai-dt` 50,953 cy** after in-lining the helper functions (removed `jal`/`ret`): the `jal`/`ret` form hung, the identical logic in-line completed, so this is recorded as a test/contract workaround, not an RTL second-doorbell bug. The 32×32 fixture keeps the `S4_TIME_OUT=100000` budget; the 64×64 twin still needs 3 M cycles. The `AI_PMU_CY` counter showed INT4 strictly faster than INT8, confirming the cycle-count oracle. `ai_gemm_two_s8_smoke.S` was similarly in-lined and also **PASSes `ai-dt` 50,948 cy**. Temporary diagnostic fixtures (`ai_gemm_s8_32x32_t51*`, `ai_gemm_two_s8_probe*`, `ai_gemm_two_s8_inline.S`, `ai_gemm_two_s8_nofn.S`) were removed after disambiguation.** |
| `ai-dram-atomics` | directed (optional) | `verif/regress/ai-dram-atomics.sh` → pulp wrap + `g6lc_axi_lrsc` + `g6lc_axi_atomics_wrap` | Cookie pulp = 1 write. S4 lrsc eight AR/AW + LR/SC. Wrap (AMO+cut+lrsc) eight AR/AW **50 cy**. CLI: `test --ai`. **STALE — cannot build on the pinned remote Verilator 5.008.** `#0` procedural delays are rejected (`%Error-ZERODLY: #0 delays do not schedule process resumption in the Inactive region`): 15 occurrences in `tb_g6lc_axi_lrsc.sv`, 5 in `tb_g6lc_ai_atomics_aw.sv`, 19 in `tb_g6lc_ai_litedram_wrap.sv`, all pre-existing. The cycle counts above must therefore have come from a different Verilator; they are not reproducible on the proxy. Fix is to replace the `#0` settle points, then re-measure — until then the *unit* TBs are unavailable and the harness-level gates (`ai-dual-core-excl`, `ai-dual-core-lrsc-disjoint`) are the only citable exclusive-monitor evidence |
| `ai-litedram-wrap` | directed (optional) | `verif/regress/ai-litedram-wrap.sh` → `tb_g6lc_ai_litedram_wrap` | Class-1 AXI→native wrap **NrArSlots/NrAwSlots=8** (1445 cy, 9th AR/AW backpressure, L1 16 B, WRAP SLVERR, AXI held until init_done). CLI: `test --ai --ai-dram 1` |
| `ai-dram-channels` | directed (optional) | `verif/regress/ai-dram-channels.sh` → `tb_g6lc_ai_dram_channels` | Class-1 LiteDRAM DramChannels N=1/2/4/8. CLI: `test --ai --channels 4 --ai-dram 1`. Honors `AI_ISLAND_DRAM_CHANNELS` |
| `ai-dram-stripe` | directed (optional) | `verif/regress/ai-dram-stripe.sh` → stripe helper + `tb_g6lc_ai_gemm_backend` | Class-0 SRAM stripe (cores+L2+island). CLI: `test --ai --channels 4` |
| `ai-dram-timing` | directed (optional) | `verif/regress/ai-dram-timing.sh` → `tb_g6lc_ai_dram_timing` | Class-0 Cas=14 page timing. CLI: `test --ai --ai-ghz 1.25` / `--from-timing`. Not STA |
| `ai-qemu-linux` | linux (optional, higher-level) | `verif/regress/ai-qemu-linux.sh` + `g6lc_qemu/tools/g6q.py` | g6lc_qemu doctor/bridge for `g6lc64_ai`. CLI: `test --ai-qemu` / `g6q --ai`. **Not Variane** |
| `diag run ai` | diagnostic (opt-in compartment) | `config.diagnostics` compartment `ai` | Paths for island/DRAM/tensor/QEMU; optional `g6lc64_ai` lint (like `diag run ooo`) |
| `ara-vector-cosim` | directed (optional) | `verif/regress/ara-vector-cosim.sh` + `software/vector/` | §7: OpenSBI VRF + Linux ISA_V contract; soft skip/misa cosim; live lmul opt |
| `timings-sta-handoff` | directed (optional) | `timings-sta-handoff.sh` | Host S0: timings package → review-only OpenSTA `seeds.sdc` + FO4 CSV + correlate scaffold (`architecture/build-platform-opensta-from-timing.md`) |
| `verify --formal` (not a suite) | formal | `core/ooo/formal/{cva6_ooo_freelist,cva6_ooo_rob,cva6_ooo_cancel,cva6_ooo_rename}.sby` via `verify.formalTasks` | U5: live freelist + ROB occupancy (slang BMC) + rename free/busy/bypass + cancel-mask policy model |
| `spec-deep-path` | directed (optional) | `spec-deep-path.{sh,ps1}` | FSE path/artifact gate + lint `cv64a6_spec_deep` / `cv64a6_ooo` |
| `spec-deep-tests` | directed (optional) | `testlist_spec_deep.yaml` + `spec-deep-tests.{sh,ps1}` | FSE S6: mispredict/STQ/fence + single-hart RVWMO/A litmus (`cv64a6_spec_deep`) |
| `server-math-tests` | directed (optional) | `testlist_server_math.yaml` | U10 C-light: misa B/H, cbo.zero, scalar memcpy (`cv64a6_server_math`) |
| `kvm-h-tests` | directed (optional) | `testlist_kvm_h.yaml` | H hfence + dual VS ecall + Sstc litmus (KVM-oriented) |
| `kvm-h-spike` | directed (optional, Spike+RTL green) | `verif/regress/kvm-h-spike.sh` + `kvm_h/*` + Variane | H-edge: hedeleg WARL, VT*→22, MPV, dual VS ecall (3/3 Spike+RTL) |
| `stability-regress` | directed (optional, composed) | `verif/regress/stability-regress.sh` + `AGENTS-regress-scripts.md` | §4 residual battery: H-edge Spike + mc-spo-spike + mini compile (`STABILITY_PROFILE`) |
| `dual-iss-regress` | directed (optional, dual-ISS) | `verif/regress/dual-iss-regress.sh` | Same ELF Spike+Variane tohost golden (mini_tohost/jumps; optional H-edge); not Zacas golden |
| `stream8-smoke` | directed (optional) | `stream8-smoke.sh` + `testlist_stream8.yaml` | stream8 package + live mini; full CRT via `mc-spo-veri` 9/9 |
| `kvm-h-veri` | directed (optional) | `kvm-h-veri.sh` | H-edge Variane 3/3 (prefers `work-ver-stream8`) |
| `dual-hart-ci` | directed (optional) | `dual-hart-ci.sh` | SMT2/NrHarts=2 artifact + checklist |
| `soft-ladder-di` | directed (optional residual) | `soft-ladder-di-regress.sh` + `verif/tests/custom/multicore/mini_*.{S,c}` | Soft-ladder **P1**: bare DI B1 minis (AMO/LRSC/CSR/c.mv; FDT shape + **`mini_fdt_a0_is_fdt`** P0–P11 / P9e / P3 `0x2a`–`0x3a` / P4 `0x3b`–`0x3e` / isolated P4 / P6 `0x40`–`0x6a` / G1am `0x69` / G1as/G1at/G1ax/G1bb/G1bd HOLD-FAIL / G1au–G1bf keep; sibling class **`mini_sib_cjalr`** P0–P3 752/766/7ba / `CONTRACT.md`; S1 **`mini_wt_delay_ld`** delayed same-PA PASS; S1 trampoline **`mini_fdt_nt_osbi_h0`** pin @10869; **`mini_fdt_nt_osbi_tight`** s3 at low VA (0 hang / 1–3 PASS / 4 hang / 5 s3); late L1 write after ACK still s3 (pending hung n3) — reverted; check-hit `wr_req` PASSed tight but hung h0/nl — reverted; keep-all-ACK'd wbuffer PASSed tight but hung h0 — reverted; last-ACK keep s3/sw hang — reverted; cap-5 clean-held s3 (prologue) — reverted; keep-all stock `empty_o` still hung h0 — reverted; cap-7 tight PASS/h0 hang, cap-6 sw hang — reverted; overlay-if-wbuffer-empty still s3 @11033 — reverted; hold-grant update s3 @10633 — reverted; **`mini_fdt_nt_osbi_bochk`** s3 dead at `jal by_offset`; stock-`namelen.bin` fence/truncate hang — no peel; **nackinv kept** (denied wr_ack invals hit way) + namelen/by_offset `addi sp` prologues: **h0/tight/nt-osbi PASS**; **`mini_stq_alias_jal` PASS @986** hart1 WFI park; S1 hold ecall **`mini_ecall_list_{init,one,walk}` PASS** @371/401/527 after `la`s retire before `sd`; **`mini_ecall_list_void` PASS @406** with VOID-keep `0x80040xxx`, was fail7). **Proxy B-harness 2026-08-31:** `work-ver-smt2-fw64-B` rebuild clean; `testharness_proxy.py di --flavour B` converted to **consecutive single-worker** mode with a `_no_overlap_guard` (pkill stale + pgrep live check) so multiple proxy invocations cannot start overlapping `Variane_testharness` or `soft-ladder` runs. **Oracle controls (H3, 2026-08-31):** the suite now runs `mini_must_pass` (writes `tohost=1`) and `mini_must_fail` (writes `tohost=3`) as a **preflight**, in both `soft-ladder-di-regress.sh` and `testharness_proxy.py di` (skip with `--no-oracle-check`). If the positive control does not pass or the negative control does not fail, the run aborts before any suite test, because a pass criterion satisfiable by *absence* makes every verdict void. They are controls, not suite members, and never enter the summary. This is the direct repayment for the classifier defect: `*** SUCCESS *** (tohost = 0)` (a timeout) had been read as PASS, so **every DI count recorded before 2026-08-31 was measured under a superseded verdict and must be re-measured or annotated before it is cited** — including the "16/16 PASS after `En.order`" and "12/16 flaky" claims and the per-mini tables in `linux-boot-scale.md` §5. Corrected classifier requires `tohost = 1`; corrected full-suite result is **0/16**, with `mini_fdt_lenp_sw` the only test reaching its own `fail:` path and the rest timing out at `tohost=0`. Prefers `work-ver-smt2-slfix` for hold/cookie. Map: `architecture/multi-threading/soft-ladder/README.md` · `COMPLETION.md` · `CONTRACT.md` · `linux-boot-scale.md` |
| `soft-ladder-osbi` | directed (optional residual) | `soft-ladder-opensbi-soak.sh` + oracle `software/smt2-linux/soft-ladder/` | Soft-ladder **P3**: OpenSBI DI cookie soak; **SUCCESS=`51b1babe` only** (not tohost). `PEEL_*` bisect; soft getprop may hold. 2026-08-31 (post I$ active-region + FDT-compensation commit filter): B-harness `work-ver-smt2-fw64-B` still `CLASSIFY=FAIL`, but the bootrom now completes (`s0=0x80000000`, `npc0=0x80000000`). OpenSBI now runs until `mepc0=0x8000a9a8`, `mcause0=0x2`, `mtval0=0x693af0f`, `wfi0=1`, not the earlier `_hang` at 0x1004c. `work-ver-smt2-slfix` and `work-ver-smt2-fw64-legacy` show similar post-bootrom illegal-trap signatures, so the residual is not B-frontend specific. |
| `verify --formal` (fetch) | formal (default) | `core/fetch_B/formal/g6lc_fetch_{align,order,redirect}.sby` | **L2 rung — 3/3 PASS by k-induction (2026-08-31); full gate 7/7 with `core/ooo`.** Provision with `tools install formal` (Yosys >= v0.67, integrated slang; WSL on Windows). Oracle checked in both directions: injecting one false property fails the gate 1/7. Engines are raced (`abc pdr` + `smtbmc z3`) — the packet-order proof is 0.27s under pdr and does not converge in 240s under z3. Bounded proofs over the pure functions of `g6lc_fetch_pkg`: I3/I5 leftover completion + drop (`align`, prove d=4), I2/I7 packet prefix/whole-packet (`order`), I8 redirect total order incl. "SMT restore never outranks a trap" (`redirect`). Self-contained — `config_pkg` + `g6lc_fetch_pkg` + props, no core elaboration, mirroring `core/ooo/formal/`. Replaces the soak route to `I4ad`/`I4ae`/`I4az`/`I4y`/`I12` (five families, previously three soaks and a HOLD-FAIL regression) with seconds-scale counterexamples. Path gate `diag-fetch-formal-paths` |
| `diag-isa-red-lines` | diagnostic (default, `core`) | `build-platform` `source-scan` over `core/**` | **H6 veto as code.** `firmware-boot-principles.md` §E five classes: commit value filter, cancelled writeback, forward-by-value, resolve-by-PMA, squash exemption list. Un-waived hit fails; recorded pre-existing debt (`core/smt_legacy/`, `core/scoreboard.sv`, `core/issue_read_operands.sv` under `ifndef G6LC_FETCH_B`) is warned + counted as the H7 ledger. Detector self-tested against a temporary all-five-violations fixture: 5/5 fired with correct line numbers, then 0 with it removed |
| `diag-fw-accommodation` | diagnostic (default, `core`) | `build-platform` `source-scan` over `corev_apu/bootrom/**`, `software/smt2-linux/**` | **H6 corollary.** Fails when a firmware/bootrom comment names an RTL mechanism — the cheapest red-line detector in the repo, because it catches "the firmware can just avoid it" at the commit that introduces it. Caught and reverted the bootrom `li s0,1` → `addi s0,x0,1` edit and the `nop`/`fence` pipeline-drain padding |
| `smt2-ai-tensor-track` | directed (optional residual) | `smt2-ai-tensor-track.sh` | **SMT2×ai-tensor staged track** (default **fast**). Profiles: `di`/`hold`/`peel`/`dual`/`tensor`/`mt-soft`/`hard`/`full`. Map: `architecture/multi-threading/smt2-ai-tensor-linux.md` |
| `g6q-vm island GEMM` | package unit (`g6lc_qemu`) | `crates/g6q-vm/src/{gemm,numfmt,exec}.rs` + `crates/g6q-cli/src/tensor_eval.rs` | **Q6 functional island.** Model-driven B3 descriptor-v2/k-major GEMM with native INT8/INT4 and software FP formats, canonical FP32 NaNs and strict grant/SP24 checks; live mask 3 still permits only INT8/INT4. Tests pin tile bounds, operand faults, invalid C/completion destinations, device overlays, sticky completion errors and no double completion. MMIO end-to-end `a_guest_can_drive_a_gemm_entirely_through_the_published_mmio_window` covers CTL → doorbell → C/status → completion → DONE claim. `python tools/g6q.py check`: 607 workspace tests (170 VM + 1 ignored), independence/fmt/clippy PASS. Native interop is separately exercised by `ai-native-eval`; **not Variane or floating GEMM hardware evidence** |
| `ai-tensor qemu-uio` | package unit (`ai-tensor`) | `python/tests/test_qemu_uio_backend.py` + `python/ai_tensor/qemu_uio.py` | **In-guest UIO protocol, 22 tests.** Drives a register-accurate fake island: CAP discovery (one binary reads a 16- and a 256-tile part differently), AI-3 region programmed *before* the doorbell, descriptor latched *before* the doorbell, **DONE claimed before the PLIC is completed** (level re-arm), completion word naming ticket+status, PMU sticky read, host tiling beyond AccTile (F12), and the refusals — oversize shape, undersized DMA window, disabled island, absent queue, `virt://` path, missing `AI_TENSOR_DMA_BASE`. Run: `PYTHONPATH=python python python/tests/test_qemu_uio_backend.py` |
| `smt-linux-boot-path` | directed (optional) | `smt-linux-boot-path.{sh,ps1}` | DTS vs sparse linux-dts + CLINT/PLIC per-hart gate (no full Linux image) |
| `smt-linux-rootfs` | linux (optional) | `smt-linux-rootfs.{sh,ps1}` + `testlist_smt_linux.yaml` + `software/smt2-linux/` | SMT OpenSBI R3a auto-build when toolchain present; sim if `CVA6_LINUX_PAYLOAD` / `fw_payload.elf` |
| `r3b-linux-image` | linux (optional) | `verif/regress/r3b-linux-image.sh` + `fetch-linux-image-hint.sh` | R3b: contract + soft-skip without Image; optional OpenSBI rebuild with LINUX_IMAGE |
| `iti` / `instr-tracing` | directed | ITI / trace directed | trace/observability (not ISA-normative) |
| `debug` | directed | debug-module test | Debug spec (external), triggers |
| `interrupt` | uvm | `testlist_interrupt.yaml` | Part II traps/interrupts, CLINT/PLIC delivery |
| `custom/sstc_h` | directed | `testlist_custom.yaml` → `vstimecmp_htimedelta` | Sstc×H U9.0–9.2: htimedelta, vstimecmp, VSTIP mip/hip, VS mret + stimecmp alias + ecall |
| `csr-embedded` | uvm | `testlist_csr_embedded.yaml` | Part II CSRs on embedded cv32a65x |
| `pmp` | uvm | `testlist_pmp-cv32a65x.yaml` | Part II 3.7 PMP (+ 6.3 Smepmp) |
| `hwconfig` | uvm | `testlist_hwconfig.yaml` | config/parameterization legality (`check_cfg` surface) |
| `cvxif` | uvm | `testlist_cvxif.yaml` | CVXIF coprocessor interface (microarch seam) |
| `smoke-gen` / `generated` | generated | riscv-dv generated | randomized base+ext stress; RVWMO/ordering breadth |
| `generated-xif` | generated | riscv-dv + CVXIF | randomized CVXIF stress |
| `pk-tests` | pk | proxy-kernel tests | S/U-mode + syscall path (Part II supervisor) |
| `dhrystone` / `dhrystone-smoke` / `coremark` / `benchmark` | benchmark | perf workloads | performance (not conformance) |
| `linux` | linux | Linux boot | full-system: paging, traps, CSRs, atomics end-to-end |
| (`testlist_isacov.yaml`) | (coverage) | functional coverage groups | ISA functional-coverage collection across suites |

---

### Recorded AI continuation evidence (2026-09-05; scoped, not fresh full-SoC)

- Native interop/replay: `build-platform/workspace/build/ai-native-eval-20260905T025618Z-5ab2c5772ab6/summary.json`
  is PASS. Replay sums are **future-array scheduling-model cycles**, not the
  scalar primitive's II or hardware MAC/s: live 14,588→9,420; software-fixture
  SRAM128 72,134→52,056 and SRAM512 59,846→45,912.
- Descriptor helpers + engine: `remote-runs/ai-desc-formats-20260905T035017Z-4ab85668b5b1/output/desc-formats-results-uhunc1qk/results.json`
  is PASS with the row's 3,072/1,024/1,024 checks and 4 starts. It does not execute
  a full GEMM array or SoC.
- Scalar simulation: `remote-runs/ai-fp-mac-20260905T023802Z-b1e25ff177c5/output/fp-mac-results-gj7ojrwu/results.json`
  records all four pipeline variants and the vendor lint baseline/negative
  controls. Separate local generic synthesis reports 8,234 cells / 428 sequential,
  zero latches and zero cells disabled; formal has 17 widening properties and
  8 control assertions (12-step control bound, not induction or full FP proof).
  See `architecture/ai-matrix/numeric-formats-datapath.md` for the per-run ladder.
- Package checks: full `g6q.py check` is PASS as recorded above; full `ait.py test`
  passes external cosim ping/job, 5 ABI + 10 IR + 48 RT tests, Python unittest
  Ran 16 (1 NumPy skip), 22 QEMU UIO tests and torch smoke. Build-platform
  typecheck and 13 focused tests pass; the two moved-core-type branding failures
  and prior full-core synthesis blockers remain open.

## Spec chapter → suites (reverse index)

| Spec chapter / feature | Suites that exercise it |
|---|---|
| Part I base RV32I / RV64I | `riscv-tests`, `riscv-arch-test`, `riscv-compliance`, `smoke-*`, `generated` |
| M (mul/div) | `riscv-tests` (`*um*`), `riscv-arch-test`, `generated` |
| A / Zalrsc (atomics, LR/SC) | `riscv-tests` (`*ua*`), `riscv-arch-test`, `linux`, **`soft-ladder-di`** (DI AMO/LRSC minis under smt2) |
| OpenSBI / FDT residual (DI) | **`soft-ladder-osbi`** (cookie), `soft-ladder-di` (FDT minis + `mini_must_pass`/`mini_must_fail` oracle controls), `smt-linux-*` (full stack) |
| Fetch invariants I2/I3/I5/I7/I8/I10/I12 + R1 | **`verify --formal`** `core/fetch_B/formal/*.sby` (bounded, exhaustive in envelope) — not `soft-ladder-di`, which can only sample them |
| Fetch geometry / configurability (SPEC §1, §F) | **`g6lc_fetch_geo.sby`** — 6-point sweep FW 32/64/128/256 × RVC on/off. Raising a width is a re-run in seconds, not a package re-soak |
| SMT fetch contracts (R1 provenance, I8 commit-hart, I10 switch progress) | **`g6lc_fetch_smt.sby`** — `en_restore`/`en_smt` free, so T=1 and T>1 are proven together |
| ISA red lines (§E) | **`diag-isa-red-lines`** + **`diag-fw-accommodation`** (mechanical; prose alone did not hold them) |
| Combinational loops (AGENTS.md §0.1) | **`diag-smt2-comb-loops`** (optional) — re-enables `UNOPTFLAT`, which `verify.lintArgs` waives project-wide. Currently **11 reports, 8 in `core/fetch_B`** (incl. `frontend.sv:153 fetch_address`, `g6lc_fetch_pkg.sv:167 kill_s2`). Not ratcheted: it is a report, and the rule is do not add a loop on top of it. Independently corroborated by yosys refusing to build an SMT model of `frontend.sv` |
| Formal gate (all planes) | **`verify --formal`** — 10 tasks, or `--formal-remote` for the builder (~11 s on 12 cores). **Any proof that reaches into a DUT must use `read_slang`:** `read -formal` silently invents dangling wires for `dut.<sig>` and reports PASS on assertions that touch nothing (found in `g6lc_ooo_{freelist,rename}`, both fixed) |
| Hart topology / `plat_hc` (R11, I25) | **`dts_to_dtb.py --check-all-harts`** (build-time DTS ↔ config pairing) + `check_cfg` product assert. Not a soak: `platform.hart_count` is a compile-time-decidable property of the DTS |
| Zacas AMOCAS.W/D/Q (I §5.9) | `mc-mini-veri` + **`zacas-policy`** (hard RTL W/D/Q + odd illegal), `mc-stream-tests` / `mc-spo-soak` / `mc-spo-spike` (directed/ISS), `mc-spo-veri` (CRT residual) |
| F / D (floating point) | `riscv-tests` (`*uf*`/`*ud*`), `riscv-arch-test` (rv64 targets) |
| C (compressed) | `riscv-tests` (`*uc*`), `riscv-arch-test`, `smoke-*` |
| Zicsr + Part II ch2 CSRs | `csr-access`, `csr-embedded`, `hwconfig` |
| L1 D$ write-through coherence (SL-W microarch) | `mini_fdt_next_tag_lbu` (PASS), `mini_fdt_lenp_sw` (PASS), `mini_csr_pmp_probe` (PASS), `mini_amoadd_w_spin` (PASS), `mini_csr_expected_trap` (PASS), `mini_dual_cmv_s3` (PASS); `mini_stq_flush_fwd` (FAIL exit-code) and several FDT/stq tests timeout/exit. Also `mini_wt_delay_ld`, `mini_fdt_nt_osbi_tight`, `mini_fdt_nt_osbi_h0`, **`soft-ladder-di`** gate 6 with `VoidKeepEn=0` + `WtDcacheFixupDepth>0`; PMU group 5 counters |
| Zifencei / fences (4.1) | `riscv-tests` (`fence_i`), `riscv-arch-test`, `spec-deep-tests` (`spec_fence_drain`) |
| RVWMO memory model (3.1) | `generated` (riscv-dv breadth); **`spec-deep-tests`** single-hart subset (`spec_rvwmo_litmus`) — multi-hart litmus still a gap |
| PMA regions (II-3.6) | `mmu-sv32`, `pmp` (indirect), `linux` |
| PMP (II-3.7) + Smepmp (6.3) | `pmp` |
| Sv32 (II-4.3) | `mmu-sv32` |
| Sv39 (II-4.4) | `riscv-tests` `-v` on `cv64a6_imafdc_sv39`, `linux` |
| Traps / interrupts (II ch3) | `interrupt`, `linux` |
| Supervisor / U-mode (II ch4) | `pk-tests`, `linux` |
| Bitmanip Zb* (I ch8) | `riscv-arch-test` (when `RVB`), `cv*-tests` |
| Vector V / RVV (I ch9) | `ara-vector-path` + `testlist_ara_vector.yaml` (attach/lint + directed; not full compliance cosim) |
| CVXIF coprocessor seam | `cvxif`, `generated-xif` (mutex with RVV accelerator path) |
| AI workload policy codec (microarchitecture, no normative chapter) | `ai-policy-codec` + `ai-island-dma` + `ai-island-policy-walk` + `ai-native-eval --replay-policy`; standalone control/native-trace replay and first safe GEMM consumer (`prefetch_depth` -> `ar_max_i`); modeled scheduling gains only, no production consumer or measured MAC/s; `g6lc_ai_island_top` elaborates with observable PMU and a live `EnableDmaFetch=1` smoke now checks the words at runtime |
| AI scalar floating arithmetic (not ISA F/D conformance) | `ai-fp-mac`; exact widening, serial RNE multiply/add, flags and handshake/cancellation; local synth/formal are separate scoped gates, no floating GEMM integration |
| AI descriptor-v2 native modes / software interop | `ai-desc-formats` (actual RTL engine legality and effective INT4 handoff); `ai-native-eval`, `g6q-vm island GEMM`, `ai-tensor qemu-uio` (software execution/safety only); live grant/PE masks remain 3 |
| Custom `Xg6lcai` island (CAP/GEMM/I3) | `ai-matrix-directed`, `ai-matrix-veri`, `ai-s4-mshr-xbar`, `ai-dual-core-stripe`, `ai-nch-occupancy`, `ai-class1-amo-lrsc`, `ai-litedram-wrap`, `ai-dram-channels`, `ai-dram-stripe`, `ai-dram-timing`, `ai-qemu-linux`, `diag run ai` (`test --ai` / `--ai-remote` / `--ai-qemu`) |
| Randomized / functional coverage | `generated`, `smoke-gen`, `testlist_isacov.yaml` |
| Full-system integration | `linux` (single-hart BBL), `smt-linux-rootfs` (SMT preflight + optional payload), `pk-tests` |

---

## Known coverage gaps (kept honest)

These spec areas are **not directly exercised** by a dedicated open-source suite here (they rely on
randomized `generated` breadth, a commercial UVM sim, or are `absent` in RTL so untested by design):

- **RVWMO multi-hart / remote ordering** — single-hart directed subset lives in `spec-deep-tests`
  (`spec_rvwmo_litmus.S`); multi-hart litmus and Ztso still absent. Broader ordering still relies on
  `generated` (riscv-dv) where a UVM/ISS path is available.
- **Hypervisor H, Sv48/Sv57, newer Ss*/Sm*/Sv* extensions** — no dedicated suite; add one when the RTL
  row in `AGENTS-specs-to-impl.md` moves off `absent`/`partial`.
- **CFI, Packed SIMD, Matrix, vector crypto (`zvk*`)** — `absent` in RTL, therefore untested by design.
- **Zacas (I §5.9)** — RTL **W/D/Q** config-gated via `RVZacas`; hard golden `mc-mini-veri` + `zacas-policy` (Spike never golden).
  Directed coverage: `testlist_mc_stream.yaml` (`zacas_*`, CAS lock, CF×stream) + suites
  `mc-stream-tests` / `mc-spo-soak` / `mc-spo-spike` (ISS; **not** hard CAS) /
  **`mc-mini-veri` (hard RTL golden)** / `mc-spo-veri` (CRT residual).
  Spike lacks zacas — never treat ISS skip as RTL pass. Sub-file:
  `agents/spec/riscv-spec-I-5.9-zacas.html`.
- **RVV / Vector (I ch9)** — RTL is **partial** (Ara attach live-lintable; purpose guide + DTS +
  directed `testlist_ara_vector.yaml` / suite `ara-vector-path`). Functional `v_memcpy_lmul`
  needs live Ara cosim; OpenSBI VRF save/restore + full RVV compliance / Spike cosim still open
  until `cva6.py` runs under that config. Sub-file: `agents/spec/riscv-spec-I-9-vector.html`.

When you close a gap, add/extend a `verif/tests/testlist_*.yaml`, register (or reuse) a suite in
`build-platform/src/config/defaults.ts`, and update the tables above + `AGENTS-specs-coverage.md`.

---

## Maintenance contract

When a test suite / testlist changes:
1. Update the forward and reverse rows here (suite id, backing list, spec area).
2. If the suite newly covers a previously-untested implemented chapter, update
   `AGENTS-specs-coverage.md` (it may move from *implemented* to *implemented & tested*).
3. Keep the suite catalog in `build-platform/src/config/defaults.ts` and this file in agreement
   (id, group, target, tools).
