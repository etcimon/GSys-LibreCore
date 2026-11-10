# r96 — Worst-path strategy pass

The requested analysis pass is complete: **31 module tasks and six measurement
tasks** refine the existing 223-module queue. No RTL changed in r96. The user
paused the boot/CSR campaign to prioritize caller-aware worst-path strategies
and evaluation of prior solutions.

- [Module task cards](module-tasks.md): cones, callers, qualification, ranked
  transformations, complete operation ownership and minimal future checks.
- [Task index](tasks.json): parent H95 IDs, source hashes, per-path-kind maxima,
  card locations and report identities.
- [Captured cones](cones.json): four highest paths plus the maximum of every
  path kind for each selected module, node/width details and relocation cards.
- [Window contracts and deferred HPDCACHE audits](window-contracts.md):
  dependency, forwarding, ordering, publication, capacity and memory-port rules.

## Evidence and ranking corrections

Eleven analysis runs completed with unchanged **delay-v49, 20 ps/FO4,
margin 0.2 and an 8-FO4 budget**. Six replay the core, core-all, coherence,
L2, L3 and AI workbench bindings against current source. Five bind FMA,
tag and rename children explicitly. All have zero skipped files and matching
source/binary/flist/map hashes, checked again when exporting the task index.
Two analyzer workers run concurrently. No calibration change, RTL emission,
OpenROAD run or new timing exception occurred.

The broad screens reproduce their prior maxima, but caller/node audits expose
limits that change the optimization order:

- Generic FMA 101.32 used unresolved product width and default leaf parameters.
  Bound FP32/FP64 products now have the correct 48/106-bit widths, but the
  133.26/142.72 paths connect middle-pipeline element zero to element three
  across three FFL registers. These are diagnostic aggregates, not a hardware
  regression or combinational timing claim. Fix the register/array/macro
  boundary model before awarding timing credit.
- Explicit PF_TAG=0 still leaves disabled gen_pf writes in the tag maxima
  (36.34 L2 / 41.57 L3). Do not optimize this disabled path.
- Generic rename 51.00 omitted FP storage and used one bank/eight checkpoints.
  The scalar caller has 72 integer and 72 FP entries, two banks and 32
  checkpoints. Its 53.00 screen still needs generate/guard qualification:
  different-bank earlier picks cannot serialize.
- The L2 62.69 path connects an S_IDLE assignment to an S_BYPASS_B-only
  consumer. That particular dependency cannot execute together. Retain the
  real collector/admission cone and audit guard compatibility.
- Coherence 121.60 ends in the private counters rejected in r94; invalidation
  123.30 aggregates reset/NBA updates. Audit observable alternatives instead.
- HPDCACHE, merged ADDMUL and core CVXIF are not selected by the scalar caller.
  The old 75-key map is partial; all-module enumeration is not live hierarchy.

These are M96 measurement tasks, not claimed FO4 reductions.

## Implementation order

| Order | Modules | First strategy | Prior mechanism |
|---|---|---|---|
| 1 | g6lc_flu_reserve | Static class/offset masks and parallel earlier-offer conflicts; state changes only on final accept | r94 age-column selection; A118 |
| 1 | csr_regfile PMP writes | Constant-entry decode and parallel row-local lock/update logic | A134/A135 |
| 1 | g6lc_lsq | Balanced, correctly sized valid-vector popcounts for real admission credits | Exact parallel reductions |
| 1 | g6lc_l2_mshr | Per-entry pop/attach/complete equations with parallel free/merge selection | A135; stable owner state |
| 2 | decode_s3, AI descriptor/GEMM control | Priority-preserving legality selection; span and terminal facts in existing windows | r90-r93; r21; r94; A134 |
| 3 | L2/L3 and arithmetic helpers | Retained collector ownership; product/shift preparation; coupled carry-save rows; rebalance S1/S2 | A132/A134/A141; r92/r94 |

These are prospective transformations, not measured savings. Detailed cards
also cover store alignment, divider recurrence, rename picks, load publication,
loop-buffer matching, write-buffer fixups, IQ selection, AI register reads,
cluster dispatch, CMO and snoop filtering.

The first batch favors bounded changes with no new externally visible cycle.
Later file splits should follow real purposes: FMA product/align, represented
sum and normalize/round; cache admission, lookup/MSHR decision and retained
response; GEMM compute/store retirement; coherence slot, response and applied
invalidation ownership. File separation alone creates no timing slack.

## Conditional transfer from prior solutions

The full `sv-timing/architecture/PIPELINING-RT-LEARNING.md` was read in addition
to the r95 methodology ledger. Its lessons are applied with their countercases:

- A132 tile/reduce/finalize requires both carry-save rows and every alternate
  result/control path to reach the same consumer at the same age.
- A134 state-only precompute must still compare against the current request.
  Registering the whole request-dependent predicate would use stale work.
- A135 per-row preparation applies to small register tables, not automatically
  to SRAMs or updates involving several independent indices.
- A136-A140 absolute-slot search helps only when the consumer wants the slot;
  later offset reconstruction can erase the gain.
- A138 blanket input staging can leave the internal worst path unchanged.
  A137's rejected cached-address mux is another timing/area counterexample.
- Prefix isolation, banked rename, absolute-slot fixup search, Baugh-Wooley
  DOT arithmetic and grouped exponent minima already exist in Hyp. The cards
  do not propose those prior changes as new work.

Actual relocation cards are retained in cones.json. Generic multi-cycle opcode
suggestions do not directly apply to MSHR/coherence/APB protocols; projected
8-FO4 results are not emitted evidence. P10 handshake/index locks and unsupported
representation forms remain constraints. No pragma grants a missing lifetime
mechanism or backpressure contract.

## Validation and limits

This pass uses pinned analysis, source tracing and narrow Python syntax/diff
checks. It starts no new simulator campaign. For the future RTL batch, use one
faithful discriminator per changed invariant, review every changed caller and
path class, compare matched source/candidate timing, then run the required
consolidated integration gate. Firmware remains a separate retirement/protocol
gate. New cycles must state dependency latency, service interval, occupancy,
completion-port conflicts and downstream reconvergence.

No Linux boot, physical timing, eight-FO4 closure or performance gain is claimed.
The current unbuffered load law can itself price wide selection above eight;
changing its calibration is a separate evidence-backed task.

## Paused CSR checkpoint

R95 evidence remains intact. The strict nine-source leaf passes 1/2/3/4/8 ports
with zero diagnostics under `hyp8-r95-csr-73e4d2d277-current`. The archived
six-file preimage passes the one-/two-port baseline. Narrow-credit and old-prefix
controls fail at the intended simulation checks with clean compilation:
`ports=8 credit=0 expected=8` and `g6lc_t1_csra_eq: equiv alloc`.
Control tags share `hyp8-r95-csr-controls-07566f829c-{baseline,narrow,prefix}`.
No leaf process remains active. Full caller elaboration and boot validation
are paused following the user's redirection.

## Reproduction and scope

`reboard.py` replays six frozen bindings; `bind_fma.py` and `bind_callers.py`
create five child bindings. `extract_cones.py` captures node/relocation evidence.
`export_tasks.py` joins the authored cards to frozen evidence and checks input
identities. Scripts refuse evidence overwrite. Use a new versioned directory
for new measurements; presentation changes consume captured results.

New scripts are MIT tooling attributed to Etienne Cimon. No RTL, clock/reset,
ISA/DTS, configuration policy or licensing tier changed in r96.
