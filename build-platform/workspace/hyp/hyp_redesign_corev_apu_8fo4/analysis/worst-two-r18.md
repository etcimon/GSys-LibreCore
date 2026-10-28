# r18 — GEMM seed retiming and owned cluster preparation

Implemented in the hyp APU overlay, 2026-10-27. The fresh pre-edit board
`analyze-ai-hyp-r18-before` selected `g6lc_ai_gemm_seq` and
`g6lc_ai_cluster_dispatch`: 172.2 and 150.5 structural FO4 respectively.
Selection used the maxima of paths not marked multi-cycle, rather than
assuming the recently rewritten policy modules were still the leaders.

## Measurement and caller references

Both boards use sv-timing 0.1.0, ir-v5, delay-v44, parser v0.13.5,
5,000 MHz / 20 ps per FO4 / 0.2 margin (8.0-FO4 screening budget).
These are emitted RTL structural measurements, not physical STA.

| Module | Before | r18 | Remaining maximum |
|---|---:|---:|---|
| `g6lc_ai_gemm_seq` | 172.2 | 119.5 | C-store burst/stripe arithmetic |
| `g6lc_ai_cluster_dispatch` | 150.5 | 34.3 | Registered slice-length selection |

The final board is `build-platform/workspace/build/sv-timing/hyp8-src/boards/
ai-island/analyze-ai-hyp-r18.json`. Its `.cmd` records the full invocation;
the adjacent `.manifest.json` records selected source/input hashes and the
caller paths. `analyze-ai-hyp-r18-first` is an intermediate measurement.

Caller analysis followed the board's `cross_module_paths` references, including
instance names, bridge nets, ports and parent/child path IDs, back into
`g6lc_ai_island_top.sv` and `g6lc_ai_cluster_dispatch.sv`. The single-cluster
island arm instantiates GEMM directly; the other arm passes an accepted job
to dispatch, which supplies per-engine N, B/C pointers and the original N as
the C row pitch. Dispatch rejoins completion and errors and routes AXI
responses using cluster-prefixed IDs.

| Structural caller stitch | Before | r18 |
|---|---:|---:|
| dispatch → GEMM | 270.0 | 153.8 |
| island top → dispatch | 188.05 | 71.85 |
| island top → direct GEMM | 157.05 | 157.05 |

The direct GEMM caller stitch did not improve: its presentation cone still
contains the store arithmetic. A local register-to-register improvement is
not evidence that every caller path improved.

## GEMM: move the seed read into the existing partial-sum window

The leading dependency was C-bank address/decode/read feeding FP addition.
The C seed is now read one edge earlier and captured with the incoming
partial sum. Pipelined dots use the **returning** i/j/first tag; combinational
dots use the incoming sum tag. The seed, sum, first/last and output coordinates
therefore belong to the same element. A concurrent assertion checks this
alignment.

The accumulator recurrence, dot latency and C-write edge are unchanged.
The read port is available because accumulate jobs do not use the MAC trail
store. This follows the relocation / existing-window approach in
`sv-timing/ALGORITHMS-EXPERTS.md` A33; it is an actual register cut, with no
pragma-based timing credit. FP addition remains 118.1 FO4, and the residency
span calculations remain 114.6 FO4. These are still substantial open cones.

The stronger gates also repaired existing ownership and addressing defects:

- Seed multiplication completion was a pulse. A long A/B load could miss it.
  Completion is now retained for the accepted job; multiplication launches
  once for a checked accumulate job, rather than for every descriptor.
- A short load could complete before that multiplication. The load-completion
  event is also retained, with further AR issue inhibited until the state
  advances. The two completion orderings now both reach the seed loader.
- `c_bank_addr` computed `i << (row_shift + column_word)` because of operator
  precedence. It now computes `(i << row_shift) + column_word`. This was the
  previously recorded integer column-slice failure, and also corrupted the
  single-engine reference on sufficiently wide rows.
- Cursor strides now use the incoming format at job capture. MAC cursor
  increments and their reference checks use bytes; MAC loop t remains in
  elements. Reference comparisons apply in each cursor's owning phase,
  rather than comparing an idle B cursor against A's progressing t.

## Dispatch: prepare the whole descriptor before launch

Dispatch now owns capture, rounding, offsets, multiplication, address
publication, launch and completion as explicit phases. The asserted
power-of-two cluster division becomes a constant shift; alignment occurs on
the next edge. Per-cluster column offsets are registered before a bounded
32×18 shift-add product using the existing `g6lc_ai_mul_seq`. All 50 product
bits survive until the address-width cast. Pointer addition and slice-length
selection consume completed registers, rather than sharing the product cone.

Each engine's dimensions, active bit and B/C pointers are registered before
its start pulse. Reuse requests and epochs are captured with the descriptor;
invalidation remains live. Admission remains closed throughout preparation
and execution. Pending-engine state is installed at launch, so its initial
zero value cannot produce early completion during preparation. Errors are
joined only from engines owed a completion.

The bounded setup window costs capture/rounding/offset/address/launch cycles
and up to 18 product steps. Engine PMU cycles still report engine execution,
excluding dispatcher preparation; the numerical PMU comparisons below must
not be read as end-to-end latency measurements.

No new RTL leaf or external port was introduced. The multiplier already
appears in the hyp flist, timing closure and focused bench closures.

## Validation and counterexamples

Reproduce under WSL, from the repository root:

```sh
bash build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/analysis/tools/run_ai_r18.sh gemm
bash build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/analysis/tools/run_ai_r18.sh cluster
```

The helper selects the hyp sources and `/usr/bin/verilator`, with `--assert`.
The GEMM run selects NCH=1 and DPF=0/2 (both combinational, or pipelined float
and integer). It runs the existing backend golden and `+review_accumulate`:

- Backend golden PASS in both profiles, 1048 / 1126 bench cycles.
- `PASS ACCUMULATE checks=112` in **each** profile: INT8, INT4 and all five
  floating formats, odd-width and one-column shapes, K-split accumulation
  and overwrite negative controls.
- Cluster PASS for 2×32×16, 3×48×8 and 1×16×64, comparing single, two and four
  engines to an independent signed-integer GEMM oracle. This includes empty
  slices, strided C stores and sentinel preservation.
- Engine PMU cycles for those shapes: single/two/four = 354/210/210,
  470/337/229 and 313/316/316.

Final logs are `build-platform/workspace/build/ai-gemm/
r18-gemm-joined.log` and `r18-cluster-qualified.log`.
Verilator still reports existing latch warnings in the unchanged combinational
`g6lc_ai_pe_dot` leaf; this is not a claim of warning-free whole-island lint.

Recorded failures were diagnostic evidence:

- Assertion-enabled initial runs exposed inactive-cursor comparisons and a
  posedge testbench start race. Start is now driven between clock edges.
- Cluster C[0][0..] differed (`000001dd0000033f` versus
  `fffff98800000518`) before the bank-index fix. Neither value was a trustworthy
  reference, so the bench gained the independent mathematical oracle.
- Accumulate initially timed out when the multiplication pulse preceded load
  completion, then at 2×1×9/INT8 when the opposite completion order occurred.
  Both pass after the retained-completion join.

`./build.sh verify --lint --sim --synth --target g6lc64_hyp8` was attempted.
It failed: lint/synth looked for the absent production-path
`core/include/g6lc64_hyp8_config_pkg.sv`, while the configured production smoke
suites failed on host setup (missing GNU Make in one wrapper; the other
returned 130). This aggregate run does not qualify the hyp overlay.

## Scope and remaining work

The RTL uses existing parameters, clock, asynchronous active-low reset,
testmode propagation and SRAM wrappers. No ISA, DTS, configuration surface or
software ABI changed. Additional preparation registers and iterative
multiplier state trade setup latency and area for shorter combinational paths;
placement, power, scan and physical STA remain unmeasured.

The modified code's SPDX headers, contributor attribution and tier mappings
were checked. The cluster testbench's existing dual license is preserved,
with its previously inconsistent tier/REUSE metadata aligned to that license.

Pre-edit snapshots are `analysis/tools/zips/{gemm_seq,cluster_dispatch}-pre-r18.sv`.
Production RTL and the user's F14 tracing changes were not modified.

This completes the measured reduction of the two selected modules. It does
not close the 8-FO4 objective. The final module census still includes
`pe_dot` 128.37, GEMM 119.5, codec 85.8, subcode 80.26 and descriptor engine
63.35 FO4. This pass does not qualify multichannel traffic, multicluster
floating/accumulate modes, reset/error injection, full-island formal,
OpenSBI/Linux boot or physical timing.
