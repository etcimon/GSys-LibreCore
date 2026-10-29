# r94: Hyp OoO, coherence/L3 and AI-island path audit

Baseline commit: `4b060f9c2`. Accepted changes are confined to three Hyp RTL
files, plus verification support. No production RTL changes.

## Instrument and scope

sv-timing-core 0.1.0, ir-v6, delay-v49, correction-v5, parser v0.13.5;
5000 MHz, 20 ps/FO4, margin 0.2, budget 8 FO4. No calibration change,
OpenROAD run, physical timing claim, or new timing exception.

`measure.py before` and `measure.py final` run five matched profiles with
two concurrent analyzer processes. They retain commands, return codes, source,
binary, flist and parameter hashes. Full report/IR/logs remain in `boards/`.
The same materialized closure is expanded for APU profiles, including later
AI helper extractions missing from the original materialization flist.
Every measured file exists and all ten final/baseline reports have zero skips.
All path classes, including soft multi-cycle labels, contribute to maxima.
Labels do not authorize multicycle constraints. Results are module-local,
not complete cross-module arrivals or clock-frequency signoff.

Bindings:

- Core: the existing elaborated `r88-param-map.json` scalar Hyp8 profile
  (RV64, two issue ports, one hart). This is not an eight-issue MC-core board.
- Coherence: four cores, filtered policy, four outstanding slots, 128 snoop
  entries, four-entry invalidation queues, 64-bit AXI.
- L2: 256 KiB, 8 ways, 512-bit lines, two MSHRs, four data banks.
- L3 engine: 1 MiB, 16 ways, 512-bit lines, four MSHRs, four banks.
  Both cache profiles enable SRAM tags, write update and posted writes,
  with four-entry read/write trackers and prefetch disabled. L3 wraps the
  same `g6lc_l2_top` implementation.
- AI: 512 lanes, 1024x512x512 panel bounds, 64-bit DMA, one cluster/channel,
  both integer and floating dot pipelines enabled; policy/reuse options off.
  These follow `AiCfgIsland`, `AiIslandLatencyDefault`, and the bindings in
  `g6lc_ai_island_top`. A profile inventory still includes disconnected or
  inactive module definitions; caller qualification below is essential.

## Accepted results and contracts

| Module | Before | After FO4 | Mechanism |
|---|---:|---:|---|
| `mult_clmul` | 200.10 | 14.40 | Static slice wiring and balanced XOR rows |
| `g6lc_l2_wtrk`, both cache geometries | 119.90 | 27.90 | Parallel age-column mask/reduction |
| `g6lc_ai_pe_dot_float_pipe`, 512 lanes | 62.55 | 38.75 | Group minima captured in existing S1 window |

The first two changes make static arithmetic and parallelism explicit to
the structural analyzer. The original CLMUL function had constant slice
arguments, and synthesis can already unroll/fold those shifts; similarly,
the old oldest-selection function contains independent candidate rows.
Consequently these deltas do **not** prove corresponding mapped delay gains.
The AI change actually moves part of the exponent reduction across an
existing register boundary, without adding an externally visible cycle.

`multiplier.sv` instantiates `mult_clmul` for the staged RV64 multiplier.
The six S2-S7 captures, operation/TID track, flush behavior and operand
lifetimes are unchanged. Each slice now has eight wired AND rows and a
balanced XOR tree, then the original accumulator XOR. The complete measured
path includes operand binding, rows, slice reduction and accumulator input.
The original function is a simulation-only per-slice identity oracle.
The pre-existing slice schedule is RV64-specific; RV32 qualification is
not claimed.

The cache parent instantiates the write tracker when posted writes are
enabled. For candidate entry e, the selector is exactly
`match[e] && !(|(match & age_column[e]))`, where
`age_column[e][j] = older_q[j][e]`. No age-state, priority encoder,
allocation, response ownership, pop ordering, backpressure or latency changed.
The three index ports now have a minimum width of one, consistent with the
existing internal IDX_W, so DEPTH=1 has legal ranges. Oldest and one-hot
assertions are fenced from synthesis.

The floating dot is live through GEMM's pipelined dot binding. S1 now captures
the minimum exponent of each group of up to eight lanes. Eligibility is
computed from registered decoded operands (finite, nonzero, enabled lane,
supported format), independently of mantissa multiplication, matching
`fp_dot_product`. S2 reduces only the group roots. Padded/invalid lanes use
NO_EXP. Group records reset to NO_EXP and load only on s0_start_q, exactly
with their S1 products; they hold during bubbles. The group records do not
survive reset as valid transactions. The primitive has no flush/backpressure
input; its original start/valid pipeline remains the owner.

Latency remains ceil(log2(Lanes))+6 sampled edges counting acceptance as
edge one, with one transaction per cycle. This is an edge distance of
ceil(log2(Lanes))+5. At 512 lanes the new group record has 64x16=1024 bits
before synthesis optimization; unused duplicate exponent storage may be
removed. No mapped area/power measurement is claimed.

All new state uses the existing clock, asynchronous active-low reset and
capture enable. No clock, CDC boundary, SRAM interface, architectural feature,
PMU event, ISA/DTS/CSR encoding, or configuration policy was added. Scan uses
the existing register flow. Functional transformations retain parameterization.
No new module boundary was needed: the useful cut was the existing S1 record.

## Ranking corrections and rejected work

The raw AI maxima `g6lc_ai_fp_dot` (271.5), `g6lc_ai_gemm_arplan` (149.0)
and `g6lc_ai_cluster_set` (71.5) are not this profile's active compute path.
The first is a simulation reference; reference search found no live caller
for the extracted AR planner or cluster-set implementation. Combinational
integer/floating dot oracles are also not the selected GEMM cells.

The coherence census has two important exclusions:

1. `g6lc_inval_bus` 123.3 includes reset/NBA assignments and independent
   updates in a purported combinational chain. That aggregate is not an
   established execution path. The separate 34.9 dependency path deserves
   further review; changing the FIFO to game the aggregate is inappropriate.
2. `g6lc_coherence_hub` 121.6 follows private AW occupancy counters.
   Full use-chain search shows these counters only feed their own updates.
   Admission uses the shared slot-valid table, not the counters.
   An event-vector/popcount trial reported 93.6 but was not functionally
   qualified and is **rejected**, with no active-path credit. The hub is
   restored byte-exact to the baseline; `coh-rejected.patch` preserves the
   discarded source experiment. Candidate/reviewed boards are exploratory.

These findings belong in an observable-sink and sequential-region audit of
the analyzer. This round does not change its measurement semantics.

Strategy basis: ALGORITHMS-EXPERTS A20 (dependency-based parallel timing),
A33 (relocation T0-T3), A118 (remove serial control dependencies first),
and the existing pipeline lifetime rules. Relocation cards are suggestions:
same-edge handshake/index paths do not authorize blanket InsertReg.

## Verification

`verify.sh` uses Verilator with assertions and fatal latch/multiple-driver
diagnostics. Builds and pinned references stay under workspace/build/r94-local.
Positive runs require their explicit success marker and reject failure/skip
diagnostics. The original RTL references are pinned to commit `4b060f9c2`.

- CLMUL: candidate and original each PASS 3759 checks on the same independent
  polynomial oracle. Covers 1000 distinct-input steps, bubbles, exact six-edge
  timing, operation/TID, reverse result, in-flight flush/reset and throughput.
  Deliberately corrupting the expectation fails the checker as required.
- Write tracker: independent software transaction-age model, DEPTH=1/3/4/8,
  respectively PASS 24963/30604/31616/33307 checks. Same-ID and out-of-order
  returns, retained responses, marks/probes, reset and concurrent push/B/pop.
  Simultaneous push/B/pop occurs 349/551/739 times at depths 3/4/8.
  Original DEPTH=4 also passes exactly the same 31616 checks.
- Floating dot: pinned old/new RTL miter compares every valid cycle, all
  result bits and flags, plus an independent exact-latency token register.
  Existing numerical oracle remains. Lanes=1/3/16/64 pass
  5033/5033/5039/5039 transactions, including pending reset, group-boundary
  minima, disabled lanes, specials, changing formats and continuous issue.
  The measured 512-lane binding also passes assertion-enabled elaboration/lint;
  it is not simulated in this round.
- Parent cache: 4 KiB posted-write/write-update/SRAM-tag integration passes.
  Initial stimulus used the engine's reserved WR_ID as an ordinary client ID
  and tripped the unchanged parent's admission assertion. The bench now
  avoids that ID for ordinary posted writes, preserving lock/ATOP and
  FILL_ID-alias coverage; the corrected run reports `[L2TB] RESULT pass`.
- Required aggregate command:
  `./build.sh verify --lint --sim --synth --target g6lc64_hyp8`
  exits 1, with all five steps failed: missing production-path Hyp8 config
  for lint/synthesis, CV64 simulation failure, CV32 Spike timeout. Logs/status
  retained. No full-core, Linux boot, or physical closure claim.

Existing CRLF formatting is preserved in the two changed APU RTL files,
avoiding whole-file churn; other authored files use LF. `eol-identity.json`
records byte and normalized identities. Hygiene uses git diff --check with
`core.whitespace=blank-at-eol,blank-at-eof,space-before-tab,cr-at-eol`.
Existing RTL license headers are retained; new tests/tooling are MIT with
Etienne Cimon attribution.
The licensing pass resolves tiers, checks exactly one SPDX identifier in
every staged code file, preserves all existing identifiers, and verifies
MIT on new tier-T files. CONTRIBUTORS identifies the active contributor
as the project rights holder; no outside-contributor grant is introduced.
No GPL source enters the new verification closures.
Raw logs and the archived rejected patch are byte-preserved; their
pre-existing/format-required whitespace is excluded from source hygiene.

## Remaining worklist

- Audit observable sinks and reset/NBA aggregation before ranking coherence
  as a clock limiter. The rejected counter experiment must not be revived
  as a performance win.
- Core: `g6lc_flu_reserve` 67.45 is the next scalar-profile candidate.
  Its caller consumes same-edge admission; investigate independent opcode
  classification/parallel conflicts before any stage insertion.
- L3: `g6lc_l2_top` 62.69 (L2 geometry 59.85), then tag 41.57 and MSHR 39.75.
  Trace request/response ownership and SRAM windows before choosing a cut.
- Live AI: GEMM sequencer 52.00, descriptor engine 46.54, FP normalization
  44.10. Reuse the r31-r41 countercase ledger rather than repeating extraction
  or seed-capture experiments. These candidate rows still need sink/path audits.

The 8-FO4 target remains open.
