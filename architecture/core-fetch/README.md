# Instruction supply plane (`core/fetch_B/`)

**Two phases.** Handoff first: fetch was B against the g1\* frontend. **After** that frontend was
retired to **`smt_legacy`**, applied fetch in `core/frontend` is frozen **A**. New capabilities are
A/B on **`core/fetch_B`** with the **same peels and hold-soak** as soft-ladder (P1 mini → P2 one
class → P3 OpenSBI → P4 retire soft).

Normative why: [`../firmware-boot-principles.md`](../firmware-boot-principles.md).

| File | Role |
|---|---|
| [`SPEC.md`](SPEC.md) | Geometry, four layers, A→B migration, flist swap |
| [`VALUES.md`](VALUES.md) | Value reference table (present/keep/kill/rewrite → B combos) + `fetch_geo_t` / `fetch_en_t` / sim debug |
| [`LEDGER.md`](LEDGER.md) | Every kept increment: subsumed into a B combo, or frozen in `smt_legacy` |
| [`NEGATIVE.md`](NEGATIVE.md) | **Read first.** Mechanisms that failed; do not port into B |
| [`SMT-LEGACY.md`](SMT-LEGACY.md) | What default B still compiles from `smt_legacy` vs recover vs oracle frontend |

## The rule

> The decode of an instruction is a function of its bytes and its address alone.

`SPEC.md` `A_decode_pure` / `A_no_fabricate`. L2/L3 may **drop**, never modify. Only L1 produces bytes.

## Continuation qualification correction

The later overlap-v8 “24/24 matched” record below does **not** establish full
architectural preservation: its PC/multiset and duplicate-collapsing operand
comparators admit instruction reordering or loss. Fault checks reproduce those
oracle holes. The raw run is retained as a diagnostic; the stronger qualification
claim is superseded by `../remaining-upgrade-sequence.md`'s continuation review.
The comparator now requires ordered nonempty retirement identity (only cycle
stamps removed) and exact captured operand traces. Timing-dependent differences
need an independent reference; they are neither automatic PASS nor proof of an
RTL defect. Reuse the earlier independent analyses only for their exact traces.
The retained IQ/corrector evidence below keeps its original scope. Warm-overlap
conservation, SMT2/reference revalidation and fixed-useful-work measurement remain
open; no new speedup or physical timing claim is made here.

## Predictor lookup/corrector follow-up retained (2026-09-16)

The working tree now contains the previously isolated response-PC and absolute
corrector fixes. ASIC `vpc_bht`/`vpc_btb` in `frontend.sv` follow the transaction
being realigned instead of the preceding response register. FPGA selector phase
is unchanged. The separate PH_BHT port still uses its legacy registered path;
this pass does not claim to repair that provider's timing. Saved carry prediction
and resolution ownership are unchanged.

`g6lc_bp_statcor` still has the same three-bit counters and training rule. It
interprets the learned absolute outcome consistently: 0/1 selects not-taken,
6/7 selects taken, 2..5 defers, and invalid input predictions remain invalid.
It remains gated by the existing `BPStatCorEn`/predictor configuration. Counters
are shared by index; no per-PC or per-hart isolation guarantee is added.

T18 (2026-10-06) changed the *lookup* index only: slot `i` of the fetch window at
`vpc` now reads row `{vpc[OFFSET+ROW_W +: IDX_W-ROW_W], i}` (`ROW_W = $clog2(INSTR_PER_FETCH)`),
i.e. the slot's own address bits — the same bits the resolving branch trains with —
instead of the window base for every slot. Before, a hot taken branch whose
`pc[OFFSET+:IDX_W]` matched a window base forced "taken" onto every valid-predicted
branch of that window (server boot: `fdt_next_node+0x5a` → `fdt_offset_ptr+0x6c`,
8–16-cycle refetch per libfdt call), and the victim's own training never reached that
row. A generate-time guard requires `NR_ENTRIES > INSTR_PER_FETCH`. The leaf
`verif/tb/core/tb_g6lc_bp_statcor.sv` models the per-slot row and carries two directed
aliasing shapes (`t18-window-base`, `t18-redirect-base`) that the pre-T18 RTL fails.

| Check | Result / scope |
|---|---|
| Independent corrector contract | Original RTL fails by inverting a correct not-taken input at counter 1. Candidate passes six geometries (1/2/4/8 slots, RVC on/off, 4/64 entries), each with a detected injected error; covers saturation, alternating/bursty outcomes, aliasing, simultaneous lookup/update, reset and flush priority |
| Live-port corrector synthesis | 1,261 → 1,360 generic cells (+99); 192 state bits unchanged; zero check problems/latches. Leaf screening, not whole-core mapped area |
| Extracted PC selector contract | SAT PASS over symbolic 64-bit PCs and FPGA/Altera/valid inputs; wrong-PC negative fails. Proves ASIC current-transaction selection and preservation of prior FPGA selector expressions, not full FPGA timing or frontend proof |
| Fresh SMT2 integer integration | All 13 execution records pass. RVI/mixed C/I references check 13,699/14,203 retirements, 25,774 operands and 1,025 known loads each; no skipped checks. One peer-flag value remains unchecked. Observer controls, mutated operands, redirect chain and both 48 KiB/hart workloads pass |
| Broader stream8 controls | 8 positive records and one expected-negative record pass; checked-work poll unchanged. Hot-scan 275,593 → 262,740 ROI cycles (-4.66%) with cache policy unchanged; 1/8/64 KiB locality gains remain about 30.77%. These are distinct measurement windows, not physical-time qualification |
| Full-core synthesis smoke | SMT2 and stream8 report zero check problems; no physical STA/power claim |
| Retained-source verification | Non-comment source matches tested model `48038fd4…`; only explanatory comments differ. Default `verify --lint` passes 32/64-bit minimal targets; explicit SMT2/stream8 lint and strict elaboration also pass |

Artifacts are `review-statcor-contract-v2-20260916`, `review-predictor-smt2-20260916`,
`review-predictor-work-20260916`, `review-predictor-synth-20260916`,
`review-predictor-pc-proof-20260916` and `review-predictor-promotion-20260916`.
`review-statcor-retained-20260916` repeats the leaf gate on the retained source;
`verif/tb/core/tb_g6lc_bp_statcor.sv` remains the independent oracle.
The original selector proof launch required `$check` lowering for SAT; assertions
were preserved, and successful full-core synthesis was reused rather than rerun.

**Carry-over:** no stage, clock, reset, memory, scan interface, CSR, ISA encoding or
DTS change. Existing predictor and FPGA gates apply. The ASIC response-PC mux and
corrector output decode require mapped timing/power assessment; no area-neutral
claim. Architectural resolve still wins unconditionally, and I-cache kill/refill,
PMA/execute regions, cacheability and RR defaults are untouched. Physical inputs,
full firmware/ISA/FP/ordering qualification and broader IQ geometry qualification
remain open. Licensing/attribution were reviewed manually using the recorded tier-R
authorization; the documented licensing diagnostic is not registered, so no
automated licensing PASS is claimed.

## Next performance discriminator: warm-fetch service (2026-09-16)

Scoped promotion is reaffirmed: IQ/frontend/corrector hashes match the recorded
validated versions. The later depth-two L2 sizing promotion changes only the
named packages' MSHR fields; its tested package identities and matched dual-hart
results are recorded in `architecture/l2-l3-cache/README.md`. This review
adds no fresh performance measurement or functional RTL change.

`g6lc_icache` accepts in IDLE and returns hits in READ, with no new request
accepted in READ. Stream8 has one issue port, a derived 32-bit fetch window and
FTQ/FDIP/loop buffer disabled. Its uncompressed nine-instruction checked loop
measures `9 × 2 × 8192 + 14 = 147470` cycles. The agreement identifies a useful
supply-ceiling discriminator, not a guaranteed 2× core speedup.

The saved observer trace has now been analyzed without a new model run:
`review-fetch-supply-analysis-20260916` covers ticks [5182, 29986), bounded by
loop-head transfers after ROI-call retirement. All 24,804 cycle rows are present;
1,378 complete loop intervals contain 12,402 accepted I-cache requests, responses,
IQ transfers, decoded allocations and committed retirements. Request spacing is
uniformly two cycles; accepted-request-to-response latency is one cycle. Requests
are offered on every cycle, with 12,402 not-ready cycles. There are no misses,
memory requests, mispredictions or architectural flush/control events in this
interval. The 1,378 `kill_s2` cycles are not mispredictions; they coexist with
correct loop-branch prediction and no instruction refills in this window.

Input/model/ELF hashes and observer off/on/repeat identities are checked. Dropping
a cycle row and corrupting a fetch PC are rejected by the analysis controls.
This is a bounded core-0 observation, not a new whole-ROI or multicore measurement.
The earlier observer did not expose cycle-level IQ-empty/readiness or backend
stall reasons. `g6lc_fetch_dbg` now carries a neutral `+fetch_supply`
observer (translate_off; no feedback into any ready/valid path): per-cycle
`[fetch_supply]` rows export req/rdy/rsp/take, `instr_queue_ready`, per-FIFO
full/empty/usage, issue-port valid/ready, demand/FTQ/loop-buffer state and the
redirect/kill/halt set; a cumulative `[fetch_supply_sum]` classifies every
cycle once in priority order (redirect, take, refused×IQ-ready, iq_stall,
halt, be_stall, empty, idle), so a supply-vs-demand bound is measured rather
than assumed. `fetch_window_metrics` consumes the rows when a capture
provides them and reports `iqEmptyCycles`/`backendStallCycles`/
`refusedWhileIqReadyCycles`/`refusedWhileIqFullCycles`; captures without the
rows still report `None` (missing, not zero). Reproduction uses
`REVIEW_FETCH_SUPPLY=1` with `REVIEW_FETCH_INPUTS`, `REVIEW_FETCH_CONTROLS`
and `TH_OUT_DIR` in `run_checked_work_review.py`; this mode performs
host-side analysis only.

## Warm-fetch overlap: measured, then implemented (2026-09-17)

The `+fetch_supply` capture (`supply-cap-v2`, locality-1024, stream8) settled the
supply-vs-demand question before any RTL change: on the active hart, **19791 of
19791** response (`take`) cycles carried a refused request, every refusal with
`instr_queue_ready=1` and 19788/19791 with `iquse=0` (IQ empty and ready); the
accept-to-accept interval was 2 cycles for 19751/19801 accepts — the machine ran
at its structural II=2 ceiling while the pipeline starved. Whole-run split:
`iq_stall=7`, `empty=13`, `be_stall=5`, `halt=0` — the backend essentially never
binds; supply did.

`g6lc_icache` now implements the registered request/response overlap (tag `W1`):
the READ hit-response cycle asserts `dreq_o.ready` and remains in READ when
`dreq_i.req` is offered. `cl_index` already keys off `vaddr_d` (the arriving
address while `ready & req`), so the accepted request's tag/data/valid read is
launched in the same cycle and its response returns one cycle later — a warm
initiation interval of one cycle with hit latency (accept→response) unchanged
at two cycles. `ready` is a function of `cl_hit` and FSM state only; every
`cl_hit` input (`cl_tag_rdata`/`vld_rdata`/`cl_rdata` SRAM read registers,
`cl_tag_d` from the `areq_i` translation of the registered `vaddr_q`) is a
registered-state cone, so the I4xi/I4xj convergence loop
(`vaddr_d`/`cl_index` → tag compare → `ready` → `vaddr_d`) cannot re-form —
that loop needed the arriving address to feed the compare cone, and those paths
stay cut at `vaddr_q`/`cl_index_q`. Verilator reports no convergence warning.

Kill (`kill_s1`/`kill_s2`), flush, invalidation, translation-wait and all miss
paths stay serialized exactly as before — the offer is simply re-made in IDLE,
so transaction ownership and the single-outstanding-miss property are
preserved. Way prediction is unaffected on the hit path: every accept-cycle
launch is an all-ways read (`way_pred_use` is already low under `ready & req`),
and the `force_all_ways` re-read keeps working through the `r_addr_q`
same-index invariant; a way mispredict still costs the pre-existing +1 re-read
cycle. Downstream, the frontend's staged response (`icache_valid_q`) remains a
one-cycle register, so two-in-flight response arrivals are bounded by the
existing IQ-overflow replay machinery rather than lost.

Historical verification record (2026-09-17; preservation claim withdrawn by the
continuation qualification correction above): the 24-record dual-config integration suite
(`review-int-overlap-v8`) is **24/24 matched** against the immutable qualified
depth-two models — every record `timingLegibleDivergence`, zero
`timingIdentical`, as expected when fetch resolves faster on both configs. The
comparator binds architecture at three levels: (a) PC+encoding sequence
(`archpc`) for ordered streams; (b) the `(pc, priv, encoding)` multiset
(`archms`) for `trace_hart_*.dasm` on multi-hart models, which is a **merged**
retire stream whose cross-hart interleave has no architectural order — a fetch
change legitimately reshuffles the merge and re-counts peer-flag polls while
each hart still retires its own program in order; (c) the operand-trace
`ot-retire drop=0` outcome stream split per committing hart (`h` field), with
timing/allocation stamps (`t`/`gen`/`tid`/`p`) stripped and consecutive
identical records collapsed — this absorbs timing-bounded loops (terminal
`jal x0,0` spins, `rdcycle` polls, `wait_workers` flag spins) that run more
iterations in the same window. Cookie *values* (tohost pass/fail) are bound
exactly; cookie *timestamps* are cycle-counted and timing-legible. The audit
did not establish detection of every wrong-path retire, dropped instruction,
reordering or result corruption; its normalization predicates are now diagnostic only. `supply-cap-v3`
re-measurement of the same workload is in flight (early rows already show
`req&rdy&rsp&take` coincidence and `iquse`≈9–10 vs the old ceiling ~4).
Residuals documented: `dreq_i.spec` attribution during READ describes the
offered (next) request — pre-existing, unchanged; FDIP prefetches may now be
accepted on response cycles; replays bound IQ-pressure arrival.

### Recovered supply-cap-v3 artifact

`review-supply-recovery-v1` retrieves the existing root-level `run.log` without
rerunning the workload; the original `output/` directory is empty. Its SHA-256 is
`5b233d3afd47baad1956cf83fc77d7af139af252b4ac73a41ddb9df7715d734b`.
The tail contains cookie `[1000]=1` at t=159744 and two final supply summaries.
The harness's separate `tohost=0` banner is not the pass criterion. Late captured
rows directly show simultaneous req/ready/response/take and IQ occupancy up to 11.

Neither `model.json` nor `inputs.json` exists in that capture directory. Rows and
summaries also omit explicit core/hart identity; activity filtering is not a
substitute for ownership. Therefore this is recovered diagnostic evidence, not a
source-bound fixed-work performance or SMT2-preservation result. Do not derive a
speedup from its cookie timestamp versus the old capture. P1 still needs model/
ELF/runtime binding, independent architectural checks and a declared useful-work
ROI comparison.

## IQ ordering: unbounded safety in the formal envelope (2026-09-16)

The live IQ now passes two-state temporal induction at length two, following an
explicit four-frame base check. This discharges the ordering/conservation safety
contract for the stated formal envelope, rather than merely extending BMC depth.
All original assertions and the two input assumptions remain: legal hart IDs and
supported control-flow metadata. The new storage relations are assertions, not
assumptions. No DUT timestamp or numerical PC ordering supplies the oracle.
The claim is order/conservation after `consumed_o` acceptance and across prefix
fires between flushes; upstream instruction completeness and the full ready/replay
protocol retain their separate checks.

**Envelope:** four FIFOs of depth eight (32 instructions), a two-entry target
FIFO, two issue ports, two hart tags, 64-bit fetch windows with RVC, 32-bit
XLEN/VLEN/GPLEN, ASIC/non-fall-through storage, FTQ off and non-hypervisor exception
handling. This is not a proof of all production widths, all parameter tuples,
FPGA RAM timing, hypervisor metadata or the whole SMT pipeline. It is not an
X-propagation/metastability proof or an unconditional progress claim under a
consumer that never becomes ready.

The independent accepted-entry watcher retains its logical rank and input bytes,
PC, hart, exception and predicted target. Additional inductive assertions relate:

- bank occupancy, read/write pointer spans and circular head position, including
  the empty state;
- the watched entry's logical rank to its stored payload;
- the count of live predicted control-flow entries to target-FIFO occupancy;
- the watched CF entry's prefix-CF rank to its stored target.

The two CF counts use six bits, sufficient for every sum of at most 32 terms.
This is a lossless proof-model sizing change, not an input restriction.

| Check | Recorded result |
|---|---|
| `review-iq-sat-binary-20260916` | Four-frame base PASS; induction length two PASS, about 226 seconds including preparation |
| `review-iq-sat-binary-negative-20260916` | One-bit corruption of the emitted instruction is detected in the base check; only the copied negative RTL is changed |
| `review-iq-cover-binary-20260916` | All 12 clocked cover predicates reached within 28 steps; constant-false negative stays unreachable; about 359 seconds total |
| Witness inspection | No-flush full-drain trace reaches count 32 / all banks full at step 11, then count 0 / all banks empty at step 27, with no intervening flush |
| Earlier twelve-frame BMC | Preserved as historical bounded evidence; not relabeled as unbounded proof |

Covers include watched retirement, hart-1 retirement, sparse acceptance, dual
pop, full capacity, historical full-to-empty, **full drain without flush**, target
pressure, reuse after flush, partial carry, exception and predicted-target cases.
The old full-to-empty cover could be met by a flush, so a separate no-flush
predicate was necessary. The horizon grows from 20 to 28 for fill-plus-drain;
no old cover predicate is removed. Each goal has its own witness; this does not
claim all goals occur in one execution.

**Execution:** `run_fetch_formal.py` retains the default mode order, snapshot
hashing, incremental results and 120..600-second timeout controls. Explicit
`REVIEW_FORMAL_TASK=g6lc_fetch_iq_order`, `REVIEW_FORMAL_MODES=prove`,
`REVIEW_FORMAL_SAT_PROVE=1`, `REVIEW_FORMAL_TIMEOUT=600` selects the proven SAT
route. Add `REVIEW_FORMAL_NEGATIVE=1` for the copied instruction-bit fault. For
reachability use `REVIEW_FORMAL_MODES=cover` and `REVIEW_FORMAL_SAT_COVER=1` instead.
Upload the files listed by the SBY task through the existing credential-cache
proxy gateway. Generated Yosys scripts, input hashes and witnesses are retained.
SAT modes reject altered SBY preprocessing/parameter overrides and unsupported
formal geometries rather than silently ignoring them.

The cover route replaces each clocked cover with an initialized sticky observation
under the same guard, removes safety assertions only for reachability (as SBY
cover does), retains assumptions, and searches for each observation. A per-goal
SAT counterexample to `reach=0` means the goal is reachable, not a DUT safety
failure; the constant-false control must instead prove unreachable. Safety uses
all assertions and a separate base-plus-induction run. The default SBY PDR/SMT
routes remain exploratory; their timeout records are not converted to PASS.

The first direct-SAT attempt accidentally enabled X-state induction via
`-set-def-inputs`; its inductive counterexamples included undefined proof-state
flags and were not reachable RTL counterexamples. The successful binary-state
route matches the SBY bit-state domain and retains the reset base check. Earlier
solver timeouts, declaration-order and `$check` lowering errors remain archived.

Proof input identities: IQ `7fba053f…` (unchanged), properties `d2aee4ce…`, SBY
`861e4de3…`. Existing instruction, metadata and predictor RTL is untouched by this
proof-only follow-up. The older depth-four FIFO BMC helper is not used as a
substitute for this live depth-eight IQ proof.

## Circular IQ efficiency follow-up (2026-09-16)

The E1 candidate replaces greedy timestamp arbitration with circular selection
from the existing registered drain head. Compacted insertion and prefix removal
keep logical positions consecutive; the head advances by actual fired count,
not ready count or numerical PC order. Queue depth, ports, normal-fetch latency,
replay, control-flow throttling, scheduler and configuration are unchanged.
`push_seq` is retained for diagnostic trace compatibility but no longer drives
selection; synthesis removes its now-unobserved functional storage and logic.

| Check | Result | Limit |
|---|---|---|
| Independent acceptance/retirement bench, BEFORE and AFTER | Five configurations PASS: 4/I2/H2/C, 2/I1/H1/C, 8/I2/H2/C, 2/I1/H1/no-C, 2/I2/H2/no-C; each rejects the injected output error | Leaf geometry/metadata envelope, not all ISA/control-flow opcodes or FPGA memory implementations |
| Extended directed/randomized controls | Partial carry acceptance, target FIFO full, exception metadata, arbitrary ready, flush, simultaneous pop/push and 70,000 accepted no-flush iterations per configuration | Exceptions are non-hypervisor; runtime checks are not a proof |
| Matched four-slot/I2/H2 generic synthesis | 22,354 to 20,085 cells; 5,954 to 5,426 sequential cells; zero check problems/latches | Same live-port fixture with exceptions/carry tied off. Saves 2,269 generic cells and 528 sequential cells, not physical area or full-core area |
| Fresh isolated SMT2 observer-capable model | `255cda29…`, built directly with private runtime `dfbc2c4a…`; all 13 run records PASS | Reuses the validated source snapshot plus current IQ, not unrelated concurrent worktree changes |
| RVI / mixed C/I independent references | 13,696 / 14,202 retirements; each 25,774 operand checks and 1,025 known loads; both positive/mutated-operand controls PASS | One peer-flag load per witness remains outside the local memory-value assertion |
| Observer controls | Off/on retirement and cookie fingerprints match; repeated enabled traces identical; witness trace hashes match the prior corrected-runtime references | This pass builds one observer-capable model, not a new observer-absent executable |
| Redirect-chain and byte-identical 48 KiB/hart RVI/RVC | PASS; cookie polls unchanged at 10,240 / 282,624 / 270,336 | No throughput improvement inferred from cookie polling |
| Current SMT2 lint and strict elaboration | PASS; 256 warnings at the recorded baseline level | No new full-core synthesis, STA or physical power measurement in this pass |
| Expanded independent IQ formal | Historical twelve-frame BMC PASS; subsequently base-plus-two-step induction PASS and all 12 covers reached via the explicit binary SAT route above | Reduced formal envelope only; no production-width/FPGA/hypervisor or full-SMT closure. Original assumptions retained; storage invariants are asserted, not assumed |

The independent formal oracle no longer relies on DUT sequence stamps or
ordinary unsigned sequence monotonicity across wrap. It watches arbitrary
accepted PC/bytes/hart/exception/prediction and asserts per-bank occupancy from
logical stream counters. The unchanged twelve-frame safety task passed
(`review-iq-ring-order600-20260916`, ABC solver 376.32 seconds); that run's cover
timeout remains recorded. The later storage-invariant/SAT follow-up above closes
unbounded safety and the expanded cover set within the same reduced envelope.
`run_fetch_formal.py` records the task-file hash and each mode's result before
starting the next mode. `REVIEW_FORMAL_TIMEOUT=600` changes the deadline only;
the default remains 120 seconds. Raw-opcode non-interference remains a separate
contract conflict, not waived. The simplification is supported by bounded
safety plus directed/runtime and synthesis evidence, not represented as fully
formally closed or release-qualified.

Artifacts are `review-iq-ring-{before,after,synth-before,synth-after,order,core}-20260916`
under `/opt/testharness/runs/`, copied to the approved C: artifact directory.
`run_fetch_queue.py` uses the pinned private runtime and checks actual compiler
dependencies; `run_fetch_queue_synth.py` retains the matched fixture contract.
`run_restart_review.py` with `REVIEW_IQ_RING=1` builds the isolated integration
and checks `analysis.json` results, not only process return codes. Source
manifests include submodule source files and generated bootrom inputs by the
runner's declared file-extension set; strict qualification remains false.
Use fresh run tags; do not overwrite previous source/results to retry a run.
The remote login PATH needed explicit Verilator/formal toolchain prefixes for
proxy `py` leaf/proof calls; no installed toolchain was modified.

Timing/DFT/ecosystem: the wide age subtract/compare/select cone is removed and
the existing one-hot head now advances on the accepted output prefix. No added
pipeline stage, clock/reset domain or storage capacity; existing FIFO/test-mode
seams remain. The 528 sequential-cell reduction is observed only in the generic
fixture. ISA/DTS/config discovery is unchanged. Actual mapped slack, SRAM
binding, scan/MBIST and power remain unmeasured. Next performance investigation
is cacheability, not RR enablement; see `../l2-l3-cache/README.md`.

## Current correctness/efficiency review (2026-09-15)

The active implementation order is the 2026-09-16 E1–E6 effort-ranked section
in `../../AGENTS-todo.md`; F0–F5 remain completion/qualification gates.
Historical handoff/firmware successes below are scoped observations, not a
current SMT2 qualification. The current implementation was reviewed against
accepted-stream order, not the minimum-PC selector from an obsolete bisect
snapshot.

**Reproduced defect and repair:** sparse input slots were mapped by their
original slot indices but `idx_is_q` advanced by accepted-count. Consecutive
accepted instructions could therefore enter the same FIFO while another FIFO
held a younger head. Greedy dual-issue could pop the older head plus that
unrelated younger instruction, skipping the next instruction hidden inside
the first FIFO. A two-packet independent test fails at t=35 on unchanged
4-slot/I2/H2 and 8-slot/I2/H2 RTL; the single-issue control passes.

`instr_queue.sv` now compacts valid slots before FIFO placement and maps
consumption back to the input slots. Rank is accepted slot order within a
packet, not a PC comparison. This preserves ordered packets across backward
control flow and removes VLEN-wide rank comparisons. Branch-target, replay,
FIFO/reset and output interfaces are retained; no new state, pipeline cycle,
clock/reset or top-level configuration is introduced. Correctness is not
optional. Existing geometry remains governed by `CVA6Cfg`.

| Evidence | Result | Limit |
|---|---|---|
| Independent queue reference, remote Verilator 5.008 VT1 | 2/I1/H1: 548 accepted; 4/I2/H2: 1,103; 8/I2/H2: 1,462. Exact retired+flush-discard accounting; sparse masks/stalls/flush/CF metadata PASS | Reduced leaf envelope; not frontend exceptions, partial-leftover replay, all legal geometries or SMT execution |
| Identical 4/I2/H2 live-port generic synthesis | 25,618→22,354 cells (−12.7%); 5,954 sequential cells unchanged; zero latches/check problems | Exception inputs tied off; generic gates, not SRAM-macro area or STA |
| Full SMT2 lint and strict elaboration | 256 warnings within existing budget; strict elaboration clean | Not simulation or physical qualification |
| Fresh isolated full core with compaction | Historical ELF SHA256 `f14a140c…` FAIL `3` twice at 131,072 | Not fixed by this queue correction |
| Fresh encoding-checked 48 KiB payloads, compaction only | RVC/N1 PASS `1` at 131,072; norvc/N1 FAIL `3` at 137,216; N2 both no verdict at 500k | Single-worker success is not a two-active-hart gate |
| Plus same-cycle expected-PC correction | RVC/N1 PASS `1` at 131,072; norvc/N1 PASS `1` at 137,216; N2 both still no verdict at 500k | Fixes the observed PASS-path fall-through, not all SMT2 progress |

Artifacts: `remote-runs/review-iq-{before2,compact,synth-before,synth-after}-20260915/`,
`remote-runs/review-20260915/review-current-3aeb7e2603aa/` and
`remote-runs/review-fresh-checked-20260915/`. Runners live under
`verif/regress/remote/run_{fetch_queue,fetch_queue_synth,checked_work_review}.py`;
execute through proxy `py` with explicit `--data` files. The queue bench is
`verif/tb/core/tb_g6lc_fetch_queue.sv`. They emit diagnostic records, not strict
`G6LC_EVIDENCE`.

**Formal methodology repair:** the live IQ/realigner harnesses narrowed the
NH=2 bound to zero and declared undriven internal stimulus. They now expose
stimulus as top-level ports, widen the bound, and separate `bmc`/`cover` tasks.
The initial repaired run passed realigner covers but realigner BMC, IQ cover
and IQ BMC exceeded the 120-second per-task budget; realigner BMC is closed
within its reduced envelope by the follow-up below. The IQ ABC engine reports a frame-3 counterexample
before witness reconstruction times out. No assertion was waived. The IQ
contract must distinguish raw-opcode port throttling from age selection; the
separate order proof's prefix-input assumption is not valid for the connected
prefix filter. Broader proof/envelope closure remains open.

**Same-cycle prefix repair:** the failing norvc run had already completed
verification with both checksums `0xc000`, set `a0=1`, then retired the
fall-through `a0=3` after a jump over the FAIL block. Current-cycle response
bytes were filtered with the previous response's `present_exp_q`. The filter
now takes `present_expected(bp_pend_q, bp_tgt_q, realigner_vaddr)` from the
current transaction; a same-window sequential return cannot admit an ordinary
instruction before the pending target. This is not a forced JAL mispredict,
extra flush, opcode rewrite or address-specific exception. It adds no state
or cycle; the old expected-PC register becomes unused by this control path.

Byte-identical replay compares models `0993083d…` (compaction only) and
`44096c6f…` (plus prefix repair): historical ELF `f14a140c…` FAIL→PASS at
131,072, fresh norvc `baad8f97…` FAIL→PASS at 137,216, fresh RVC
`555f7c14…` PASS→PASS at 131,072. Full source snapshots and generated bootrom
are retained; changed ELF filenames/metadata are not the A/B explanation.
See `remote-runs/review-identical-serial-20260915/`. Two-worker progress still
has no verdict and remains a separate gate.

**Remaining integration review:** the frontend still supplies registered
exception/replay metadata to the IQ; verify transaction association there
independently of the now-repaired expected-PC path. Current SMT2 WT fixup depth is two,
not the zero asserted during the earlier bisect. C++ commit tracing assumes
16 scoreboard entries while this model has eight, so do not use its decoded PC
as an ordering oracle until corrected. The historical skew and sparse-queue defect are distinct from the
confirmed PASS-path prefix failure; neither establishes the remaining
N=2 progress root cause.

Timing-impact review: compaction adds a bounded geometry-sized placement mux
and replaces address comparisons with slot-rank logic; no latency or state
increase. Generic cell screening supports lower logic cost but does not prove
critical-path improvement at the inferred 1.25 GHz target. Existing DFT/SRAM
seams and ISA/DTS discovery are unchanged. Partial replay, long-run wrap,
end-to-end bytes/metadata conservation, two-active-hart progress, natural
OpenSBI, full synthesis and physical gates remain mandatory.

## Dual-hart and closure follow-up (2026-09-15)

The no-IPI N2 payload never activates hart 1 under the current unseen-hart
readiness mask. SHA-bound replay shows hart 1's RF remains zero and the done
pair is `1,0`; this is not a two-active-hart test. The existing
`mini_ipi_hart1_sp.S` starts hart 1 and passes. An explicitly IPI-started 4 KiB
checked-work diagnostic starts both harts but is still failing; no firmware,
boot hold, scheduler policy or production configuration was changed.

Two further transaction-boundary repairs are retained in `frontend.sv`:

- Register IQ retry feedback and its address before feeding cache kill and
  fetch retry. Current response acceptance remains combinational. This removes
  three synthesis loops through replay, realignment and cache response-valid.
  Replay adds VLEN+1 bits of state and one recovery cycle, not a normal-fetch
  pipeline stage. IQ replay/exception metadata now comes from the same current
  response as its bytes, with exception-valid qualification.
- Complete an architectural redirect on current response/IQ acceptance, not
  the registered response-valid bit that a new prediction clears. At t=135592,
  the branch at `0x800000dc` was accepted and predicted `0x800000b8`, but the
  stale completion path subsequently reissued `0x800000dc` and filtered all
  later returns. `mini_fetch_redirect_chain.S` is the short failing witness:
  byte-identical ELF `829fbeaa…` changes no-verdict at 500k to cookie 1 at 10,240
  on model `44096c6f…` versus `3aa9014d…`.

Full SMT2 lint/strict elaboration pass. Final full-core Yosys smoke reports
zero check problems (`build-platform/workspace/build/verify/review-smt2-synth-redirect.log`).
Its 32,487 RTLIL cells are heterogeneous coarse cells, not comparable to the
22,354 mapped generic gates of the IQ-only area screen. No physical result is
implied. N1 RVC/norvc still pass at the same cookie polling observations.

Realigner BMC now passes eight frames and all five covers, including hart-1
carry completion and switching harts with a live carry. The checker bounds its
halfword index using the existing `off < FW/8` guard; this is equivalent within
the checked range, avoids out-of-range symbolic selection, and enables ABC.
The aligned-input, FW64/H2/VLEN32 envelope and low-halfword scope still apply.
No assumptions were added to obtain that pass. The IQ order harness now has
explicit free inputs and a separate watched accepted-entry/occupancy oracle;
its old prefix-valid and numeric-PC-order assumptions are removed. IQ order
and raw-opcode non-interference remain separate open gates. Independent IQ
cover and ten-frame BMC both timed out at 120 seconds in
`review-iq-independent-order-20260915`; no final safety verdict is claimed.

The IPI-started ELF `b9ef2895…` changes no-verdict to cookie 3 after redirect
repair, not PASS. A check of the complete RF trace finds no pointer/count
imbalance at completed count-decrement points; individual intermediate RF
snapshots are not an operand or retirement oracle. Operand/address/retirement
tracing must distinguish data response, forwarding and switch-conservation
hypotheses before attributing the activated checker failure. Artifacts:
`review-dual-progress`, `review-dual-ipi-mini`, `review-dual-window-reduction`,
`review-dual-checker-tail`, `review-redirect-chain-{before,after}`,
`review-redirect-accept`, and `review-realign-bounded-index`, all suffixed
`-20260915` under `remote-runs/`.

Physical qualification is blocked: `tech status/check` reports optimization
off, PDK omitted, no active technology or tech-spec, and `physicalDesign.flow`
is `none`. Library/SRAM views, sign-off corners and constraints must be supplied;
neither inferred 1.25 GHz nor this synthesis smoke closes STA/DFT/P&R/power.

## Typed trace and restart ownership (2026-09-15)

**F0 runtime audit:** subsequent stream8 RR-on startup crashes exposed a
Verilator 5.008 wide-constant helper writing beyond a configuration temporary
into the host environment. The earlier native runs below remain historical;
matched revalidation now passes with the user-approved private runtime correction.
The guarded-buffer canary reports 18 mismatches on the original header and
zero on the corrected copy. Installed tools, RTL and workloads are unchanged
by this runtime repair; formal and Yosys synthesis are independent of it.
Corrected baseline `5a10acc1…` and observer `528b720c…` reproduce the RVI and
mixed C/I reference passes and the byte-identical 48 KiB/hart results. Actual
compiler dependencies point to corrected header `dfbc2c4a…`, not the installed
original. See `review-private-runtime-rebuild`, `review-runtime-operand-model`,
`review-runtime-{rvi,rvc}-{trace,analysis}` (suffix `-20260915`) under the remote
run root and approved C: artifact directory.

Method: the reasoning workflow's T2/T3/T9 and heuristics H3/H4/H5 are applied
at accepted issue, actual post-bypass ALU operands, LSU enqueue, cache grant/tag/
response, writeback and hart-tagged retirement. `g6lc_operand_trace.svh` is
observation-only and injected only into isolated diagnostic snapshots by
`run_operand_trace.py`. It uses RTL types and allocation generations, not the
old C++ sixteen-entry scoreboard extraction. Nine serial witness runs across
baseline/observer-off/observer-on have matching retirement fingerprints; enabled
traces repeat byte-identically. A separate positive control and an in-memory
mutated-operand negative control validate `run_operand_analysis.py`.

The first validated violation is upstream of the eventual checker failure:
at t=726, H0 checkpoints transport PC `0x80000070` while IQ entries at `0x68`
and `0x6c` are discarded without issue allocation. Its last issued `0x64`
drains. H0 restores `0x70` at t=1304 and retires it at t=1310, skipping a store
and checksum update. The single-worker reference passes 7,002 retirements,
513 known loads and 12,892 operand checks with no skipped instructions.

**Contract:** a switch preserves the earliest unissued instruction belonging
to the outgoing hart; a resolved redirect changes only its owner's continuation.
`restart_frontier` selects owning architectural redirect, then decode, then IQ,
then the transport fallback, using stage/slot order and valid/hart metadata.
`cva6.sv` supplies those existing boundaries to `g6lc_smt_pc_bank`. No queue is
preserved across switches, no PC minimum/offset guess is used, and switch/boot
policy is unchanged. The bank uses explicit validity, including a legitimate
zero PC, and exposes its existing outgoing-hart state. No bank state is added.
The top's flist entry follows the fetch package to satisfy Verilator 5.008's
package declaration order. The obsolete generated-alias C++ ID/SB printer is
now opt-in via `G6LC_TRACE_LEGACY_IDSB`; no RTL assertion is disabled.

The frontier-only model `7b3bbc7b…` makes the byte-identical 4 KiB witness and
48 KiB uncompressed workload write PASS, but that is NOT architectural closure:
the independent trace finds another H1 sequence violation at t=9181 (`0x94`
expected, `0xa8` retired). At t=9169, H1 restores `0x94` while H0 resolves a
misprediction to `0x7c`; the unqualified recovery filter takes the foreign
redirect ahead of flush. Owner routing is therefore added to frontend recovery
and controller flush requests; inactive-hart redirects update the owning PC
bank, including outside a switch. Scoreboard/LSU resolution and predictor
training retain the original event. The subsequent RVI reference trace passes
13,696 retirements, 25,774 operand checks and 1,025 known load values; one
cross-hart flag value is deliberately outside the memory-order oracle.

The mixed C/I witness then reveals a third loss at t=1276: after a correct
restart at split RVI PC `0x56`, a taken branch to `0x52` is followed by another
`0x56`. A window probe with identical operand/retirement fingerprints shows
response `0x56` has no complete instruction, response `0x58` completes the
target, then the next prediction is followed by requests for `0x56` again.
The response-window comparison never marked the original redirect complete.
`accepted_target` instead checks current, non-flushed IQ consumption of the
requested instruction PC, including carry completion from a different window.
It is proved over 1..8 slots with covers for split, sparse, flushed and
non-matching acceptance. The cold `mini_fetch_split_redirect.S` passes on the
pre-fix model and is retained as a control, not claimed as a negative witness.

Model `7037f685…` changes the byte-identical 48 KiB/hart RVC workload from cookie
3 at 94,208 to cookie 1 at 270,336. The RVI leg remains cookie 1 at 282,624.
Final independent post-fix traces pass: 13,696 RVI and 14,202 mixed C/I
retirements, each with 25,774 operand checks and 1,025 known load comparisons.
One cross-hart flag value is outside the local memory-order oracle. Both
encodings have nine matching baseline/off/on witness fingerprints and a
single-worker positive plus injected-operand negative checker control. This
closes the demonstrated integer witnesses, not all ISA/firmware/SMT contracts.

Selector/routing proofs and reachability covers pass with SMT unrolling;
`tb_g6lc_restart.sv` passes ownership, invalid source, valid zero PC, reset,
NH1 inactivity and inactive/coincident redirect cases. These are component
contracts, not an end-to-end SMT proof. The independent IQ proof subsequently
passes induction in its reduced formal envelope, as recorded above. Raw cookie
PASS alone must not promote any of these configurations.

Visibility audit: channels 1/2 (required/forbidden writes) are checked by the
reference retirement model; 3/4 (state kept or killed) motivate restart and
redirect ownership; 5 introduces no data-value control predicate; 6 is checked
through hart identity, without imposing global commit order on cross-hart loads.
Natural firmware, traps/WFI/atomics, broader geometries and physical gates remain.
Timing/area note: these three follow-up repairs add no pipeline stage, clock,
reset domain or PC-bank state. They add metadata-selected PC muxing, owner
comparisons and a parallel target-PC equality/reduction over the configured
fetch slots. Full-core synthesis is clean, but their incremental mapped area,
critical-path slack and physical power are not measured. The earlier IQ-only
−12.7% generic-cell screen must not be reused as this integration's area delta.
Existing DFT/PMU paths and ISA/DTS/config discovery are unchanged; these are
correctness repairs under existing SMT/RVC geometry, not new ISA features.

Evidence: `review-operand-trace-final`, `review-operand-controls`,
`review-operand-analysis2`, `review-restart-frontier-unroll`,
`review-restart-bank`, `review-restart-core-clean`, `review-restart-operand-proof`,
`review-restart-operand-analysis`, and `review-redirect-owner-formal`, each with
suffix `-20260915`. The remote originals remain under `/opt/testharness/runs/`.
After E: filled, new local artifacts go to the user-approved
`C:/Users/etcim/AppData/Local/Temp/cva6-artifacts/`; the interrupted E: pull is
not a complete log copy. Proxy `py --pull --dest` and `pull --tag --dest` support
this without rerunning simulations, and failed transfers now propagate failure.

## Handoff sizes (g1\* vs fetch)

| | g1\* `core/smt_legacy` + recover | `core/fetch_B` (workspace B; frozen A is `core/frontend`) |
|--|--|--|
| Lines | ~10236 | **3832** (37%) |
| `frontend.sv` | 4082 | **905** |
| `g1*` in frontend | 1065 | 0 |
| Predictors | identical | identical (`core/frontend` still compiled) |

## Layout after retirement + duplicate drop

| Path | Role |
|---|---|
| `core/frontend/` + `core/instr_realign.sv` | Frozen **A** (applied fetch at `3745cfb06`). Predictors still compiled from here |
| `core/smt/` | **pkg + dbg only** (`g6lc_fetch_{pkg,dbg}`). Not compiled while `Flist.fetch_B` is default |
| `core/smt_legacy/` | g1\* oracle frontend + recover packages + SMT banks |
| `core/fetch_B/` | **R6–R11 workspace** (`Flist.fetch_B`): supply + pkg/dbg. Default compile. Do not compile with `core/frontend` supply. **Duplicate drop landed** — the directory now holds exactly the six compiled files; if a file is here it is on the flist |

Default `Flist.cva6`: `+define+G6LC_FETCH_B` and `-f Flist.fetch_B`; predictors stay in
`core/frontend`. Frozen A: drop that include, restore `core/smt` pkg/dbg + `core/instr_realign`
+ `core/frontend/{frontend,instr_queue,instr_scan}` (`Flist.fetch`). Oracle: drop the define
and `Flist.fetch_B`, `-f Flist.smt_legacy`. Do not compile both frontends.

## Status

| Step | State |
|------|--------|
| Drop-in B (same module names, no g1 ports) | **landed** (`work-ver-smt2-fetchb`) |
| `_fw_start` 0x2a…0x5e identical to A | **yes** |
| OpenSBI `mtvec=_trap_handler` | **yes** |
| Hold cookie | **yes** fetchb `ec1239ef` `[1000]=51b1babe` cave WFI `@0xef98` `plat_hc=2` BANR |
| Peel cookie | **yes** `[1000]=51b1babe` `[1008]=51b1d000` |
| Nat (pin `bc7ed11d`) | **R4 walk started.** Keep-skip fetchb: `a0=-11` / `0x82200000` **gone**. `fdt_path_offset` of ELF FDT returns 0 to `fw_platform_init`. Residual: `fdt_get_property_by_offset_` `sw a0,0(s2)` mepc=`0x12eb2` mcause=6 mtval=`0x12b2a` hang WFI `@0x2d38`. Not leftover-keep |
| Split B into `g6lc_fetch_{align,window,order,redirect}` | after that pin; bit-identical extract |
| g1\* frontend → `smt_legacy` | **retired**: `core/smt_legacy/` (oracle + recover + banks); `core/smt/` is pkg/dbg only; frozen A in `core/frontend`; workspace is `core/fetch_B` |
| Capability A/B (peels + soak on fetch) | **after** that retirement; see principles §0.2 |
| `g6lc_fetch_pkg.sv` + `g6lc_fetch_dbg.sv` | **landed** (kill + leftover + L2 `window_accept`; snap for n-wide/SMT/spec; `+fetch_snap`) |
| `instr_realign` leftover | **landed** (`leftover_complete` / `leftover_next` / `rvi_prefix`; `start_hw0=1`) |
| L2 redirect window | **landed** (`redirect_hit` / `redirect_accept` = `window_accept` + `same_win`) |
| `icache_ret_ok` inflight same_win | **reverted** (MINI-FAIL stock hang / bnez_jal_split tohost=12) |
| `bp_pend` / `bp_ret_ok` | **landed** (filter sequential return only while predicted redirect pending) |
| I4 per-hart leftover | **landed** (`instr_realign` carry banks `[hart_i]`; kill inert) |
| I8 restore vs trap | **landed** (`arch_src_sel` + `fetch_address = arch_pc`; no restore-first I$ mux) |
| I7 all-or-nothing IQ | **landed** (`packet_accept`; no partial enqueue) |
| I19 predict-only PMA | **landed** (`bp_fire = bp_valid && predict_fetchable && cf_consumed`; never on resolve) |
| I3 leftover pending | **landed** (`leftover_pending_o` / snap; drop on valid non-next) |
| `+fetch_snap_lo/hi` | **landed** (allowlisted in `g6lc_tb.cpp`; snap prints `rpc`/`tgt`) |
| L1 `hw_off` | **landed** (realign cursor start from pkg) |
| I14 EX identity | **landed** (`g6lc_ex_id`; IRO/EX pick PC+bp+fu_data from the CF port; no G1p/G1r/G1u; scoreboard keep list not extended) |
| Slot snap / I1 SVA | **landed** (`[fetch_slot]` pc/hw/cf/ilen; bytes-vs-I$ ; n-wide `geo.slots`; no frontend combo) |
| I1 ID identity | **landed** (`G6LC_FETCH_B`: no G1gw/gy JALR expand, no sib_cjalr `decoded_hd`; A keeps recover) |
| I6 ID splice | **landed** (`G6LC_FETCH_B`: no G1be/cy/em/ev insert-older-at-port-0) |
| I3 leftover keep | **reverted** (`plat_hc=80` `coldboot_done=0` `mepc=0x12584` mcause=2 — I4az class) |
| `and`@`8cae` leftover | **holds** (commits; tickets match). Hang is hart0 ticket wait + hart1 `8df0`/`4` |
| leftover_drop snap | **landed** (`leftover_drop` + `h=` in `[fetch_snap]`; no frontend combo) |
| L3 `packet_hart` | **landed** (IQ stamp; B decode from `fetch_entry.hart_id`; one `.hart_i` line) |
| I10 B no t0 rewind | **landed** (`G6LC_FETCH_B`: `npc_alt` tied off; A keeps I4bl) |
| I8 `commit_for_hart` | **landed** (PC_COMMIT only if commit hart == active; one `commit_hart_i`) |
| R5 jalr always `JumpR` | **reverted** (`sp1=0` `mepc1=0x348` mcause=2 — JumpR with target 0) |
| Kill-inert leftover | **landed** (`leftover_update`: `kill_s2` does not consume carry) |
| Spec leftover hold | **reverted** (`plat_hc=80` `coldboot_done=0` `npc0=0x10050` `mtvec=0x10040` — I4az / I3 keep: `spec_req` is high on sequential fetch) |
| Flush-inert leftover | **landed** (`leftover_update` ignores `flush_i`; hang **unchanged** `768`/`47f48`) |
| I10 snap in-flight | **landed** (`snap_pc`; hold **cookie** `51b1babe`; peel `51b1babe`+`51b1d000`) |
| I13 same-cycle CSR | **landed** (`stall_csr_older` in `g6lc_issue_barrier`; fetchb `856d8292`; hold **cookie**; nat tselect handler now `mret`s; still no `ret@cd22`) |
| L3 `packet_upto_cf` / L4 `redirect_rehold` | **landed** fetchb `63fa23a9` (IQ + one frontend assign). Hold **cookie**. Dbg: `window_expected`/`wr=`/`age=`/`hm=` (n-wide/spec observe; live not an IQ drop) |
| `Flist.smt_legacy` | **landed** (opt-in A oracle; do not compile with `Flist.fetch` / `Flist.fetch_B`) |
| `core/smt/` duplicate drop | **landed** (20 supply/predictor copies removed; pkg+dbg remain) |
| `core/fetch_B/` duplicate drop | **landed** (16 uncompiled predictor copies removed, 2043 L; they were byte-identical to `core/frontend` apart from CRLF + mojibake, on no flist, and a silent wrong-copy trap). Compiled B plane is now **2364 L** across the six `Flist.fetch_B` files. Predictors stay in `core/frontend` |
| `Flist.fetch_B` default | **landed** (R6–R11 workspace; predictors stay in `core/frontend`). Include **after** `config_pkg`/`ariane_pkg` (top-of-file `-f` is PKGNODECL on a clean parse) |
| B skip recover on shared ID/EX | **landed** (`G6LC_FETCH_B`: no mash, no resolve `jalr_usable`, no `cf_unissued`, no G1gg/G1gq, no SB unusable-bmiss drop). A unchanged. Next pin still R4 FDT walk |
| B skip sib_cjalr arm + I$ user half | **landed** (ID `g1lo`/`g1hx`/`g1mf` capture; `g6lc_icache` G1iw/jl). Rewrite was already off; capture was still live |
| B skip SB keep on younger-cancel | **landed** (I13; both sticky and same-cycle mask). A keeps E0 list. Next pin still R4 FDT walk |
| B skip IRO value-inspect forwards | **landed** (I17: I4by / G1k / G1h / G1gg). A keeps. Next pin still R4 FDT walk |
| B skip G1v/w/x jal-link alloc/keep | **landed** (I14; flu writes `ra`). A keeps |
| B skip leftover jal-x0 issue gates | **landed** (I6: G1dt / G1gh in `g6lc_issue_barrier`). A keeps |
| B skip G1fh sticky a0-Branch stall | **landed** (`stall_branch_csr_a0_seen`) |
| B issue gate = CF/CSR/I13 only | **landed** (drop sp / store-ra / a0-Branch / prefix / leftover-jal) |
| B skip G1t jal flush spare | **landed** (SB alloc `!flush_unissued`; IRO `branch_valid='0`) |
| B skip IRO G1o/ai | **landed**. G1an/G1ea stay |
| Recover strip (shared ID/EX/issue/SB) | **done** for B. Remaining live: G1an, G1ea, I13 CF/CSR barriers, SMT banks |
| B hide G1gq issue ports | **landed** (I8: `cva6.sv` dropped `npc_i`/`g1gq_*` at `3745cfb06`; PINMISSING on clean parse) |
| `+fetch_snap` HTIF allowlist | **landed** (`g6lc_tb.cpp`) |
| R4 FDT TRACE (keep-skip) | **`a0=-11` / `0x82200000` gone.** path_offset of `0x8001e000` returns 0. Residual was getprop `sw` misalign: 2nd `fdt_next_tag` `ld s2/s3` saw stale stack (`0` / `0x12b2a`) |
| B STQ flush keeps older stores | **landed** (`G6LC_FETCH_B`: spec queue on flush keeps `!cancelled` + `fwd_keep`; A still flush→fwd_keep only). Not leftover-keep |

`smt_legacy` is the opt-in oracle. Do not start stream I=2 / n-wide / `RVH` as fetch-A experiments
until the R4 FDT walk / R6–R11 pin on `fetch_B` is cookie-green. Envelope tweaks go through
`fetch_geo_t` / `fetch_en_t`. `NrCores`, RVV, Ara, L2 do not add fetch ports.
