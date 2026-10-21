# Pipeline pragma applicability and physical validation (A132)

The 10 adjusted-FO4 objective is **0.214 ns** at the recorded Nangate45
calibration of 21.398 ps/FO4. A pragma, a projected cut count, and a successful
reparse do not establish that delay. The required comparison is source RTL
versus emitted RTL with matching specialization, functional observations,
mapping recipe, loading and timing constraints.

The census below ("zero enabled cut anchors") is the A132 audit. A147
below is the delay-v44 rungs (reaching definitions, `MultStages` 4, the
rename repair, the TAGE row-local directive). Current cut permission is
A148: a `cycle` line on an over-budget `q`→`d` cone allows intermediate
cuts, `cut-ok` overrides `no-cut` on the same name, and
`--real-cut-feeds` writes those stages into corrected SV. Structural FO4
on the reparse can fall. Adjusted FO4 does not move until that board is
rerun. A `P10` handshake on that step still does not take `InsertReg`.

The A128 annotations mostly prohibit unsafe cuts. They do not specify
implementable pipelines. `require-contract` plus `no-cut` is a guard;
`protocol` without an accepted cut and consumer alignment is also not a
pipeline implementation.

## Findings corrected in this pass

* An explicit `cut-ok absent` could resolve to `Allowed(None)`, permitting an
  uncarried register. Rejected contract facts now forbid cuts, and a required
  contract needs a resolved, unambiguous domain.
* A vector valid could be truncated into the emitter's scalar valid flop.
  Admission now requires resolved one-bit input/result valids and resolved
  carried widths. This matters to the LSQ's multi-port AGU declaration:
  `addr_valid_i` is a vector, not one operation. No cut is enabled there.
  `ready=` is rejected explicitly; it is not silently ignored.
* `latency Cfg.Stages base=Cfg.Stages` has no spare stage under any value.
  Increasing the parameter increases both sides. The old suggestion to
  “set the parameter to base+1” could never authorize that contract.
  Diagnostics now say an RTL boundary and consumer-depth change are needed.
  Qualified names require exact parameter-map keys, without a final-member
  fallback to an unrelated parameter.
* Safe conditional integer localparams now participate in generate
  reachability. For example, `SB = Cfg.Stages > 2 ? 8 : 16` can prove which
  sum branch is live. Both arms must remain in the bounded nonnegative int
  subset; unresolved conditions, truncation and overflow still refuse pruning.
  This is measurement correction (`delay-v42`), not hardware timing credit.
* The old board's `start_net`, `end_net` and trace describe **reg→reg**,
  while `worst_any_ns` can describe another boundary. Those fields cannot
  identify the worst input cone. The isolated review now reports each of
  in→reg, reg→reg and reg→out separately, with full path reports.
* Three `no-cut` targets were not signals: `gen_cmo_local` is a scope label,
  and `wt_dcache_mem` has no `wbuffer_data_o`. The comments now identify
  `cmo_req_done` and `rd_data_o`; `fpu_gen` is replaced by `result_o`.
  The write-buffer comment distinguishes
  its exported registered entries from the load-byte merge in dcache memory.

Analyze JSON now includes `pipeline_contracts` regardless of whether the
worklist attempts InsertReg. It reports the resolved facts, bundle-shape
issues, and unbound `no-cut` targets. Counting refusal events was not a valid
coverage census: several annotated modules had no attempted cut and were
incorrectly shown as having no contract.

The audit finds **53 annotated modules among the 56 measured over budget,
12 declared domains, and zero enabled cut anchors**. The three unannotated
modules are `exp_backoff`, `rr_arb_tree` and `fpnew_top`. The LSQ AGU,
checkpoint-stack pushes and instruction-queue input valids are vector
bundles; their current declarations do not qualify for scalar-stage emission.
The remaining queue and execution changes in the table are implementation
work, not latent improvements waiting for a flag.

## Highest measured cones: the implementation each boundary requires

These are the historical A130/A131 live module study readings, not new
paired measurements or post-route closure. They prioritize work; comments
alone do not change the readings.

| Module | Adjusted FO4 | Required implementation before a new cut is meaningful |
|---|---:|---|
| `store_buffer` | 173.0 | Split accepted-request processing from queue permutation; reserve capacity on acceptance, retain pending stores in forwarding, and apply commit/cancel/flush to both pending and resident entries. |
| `wt_dcache_wbuffer` | 132.3 | Capture a complete deferred-write/forward bundle; preserve same-cycle byte supersession against younger stores before retiring a fixup. ACK, tag lookup, invalidation and response state must agree. |
| `frontend` | 128.2 | Separate prediction from fetch redirection with a predicted next-line request and later correction. Carry PC, hart, prediction metadata and redirect epoch; replay/kill must invalidate outstanding requests. |
| `g6lc_rename` | 125.9 | Reserve free tags/checkpoints when accepting a group; carry intra-group dependencies into map-write/bypass. Restore and committed-map updates must cover pending allocations. |
| `instr_realign` | 119.0 | Stage a complete output packet with hart, PCs, instruction/valid vectors and leftover state. The scalar input valid alone does not describe the vector output or its downstream acceptance. |
| `multiplier` | 118.3 | Split arithmetic inside the existing stages, including the CLMUL and operation/ID paths. Carry-save rows are one bundle; the last addition and output select remain separate physical limits. |
| `g6lc_iq` | 112.3 | Reserve selected entries while a registered issue packet awaits ACK. Wakeup, cancellation, slot reuse and count updates must operate on reserved as well as unselected entries. |
| `g6lc_ooo_dispatch` | 100.8 | Capture accepted lane records including struct-member transaction IDs and register tags; side-table installation must precede any consumer that reads them. |
| `wt_dcache_mem` | 96.6 | Stage per-byte forwarding selection together with the matching cache response, address, validity and exceptions. A late fixup cannot overwrite bytes superseded by a younger store. |
| `scoreboard` | 93.7 | Stage complete writeback events or issue packets while preserving ownership through cancel/flush and ID reuse. Delaying the owner's state array alone is unsafe. |
| `g6lc_lsq` | 91.6 | Independent AGU lane bundles and capacity reservations; pending addresses must participate in forwarding, violation/replay, completion and commit decisions. |
| `issue_read_operands` | 90.8 | Capture the accepted FU bundle and reserve its resource/writeback slot; operand bypass and ACK must use the same instruction age. |
| `alu` / `aes` / `branch_unit` | 90.5 / 83.7 / 67.7 | Pipeline at the owning execute-stage protocol, with writeback arbitration and branch-resolution latency represented explicitly. These datapaths do not expose an independent result handshake. |

The remaining counters, predictor tables, FIFOs, TLBs and cache state machines
need the same distinction between an operation boundary and a recurrence.
`stage-input` remains reserved, not implemented. Renaming `no-cut` to
`cut-ok` cannot supply reservation, backpressure or replay semantics.

## Arithmetic experiment and acceptance criteria

The multiplier experiment keeps the public three-cycle interface. It
registers smaller unsigned product tiles, compresses the aligned rows plus
the two's-complement correction in the middle stage, and performs one final
carry-propagate addition. The companion operation, valid, ID and carry-less
results retain their existing stages.

The compressor identity is
`a+b+c = (a^b^c) + (((a&b)|(a&c)|(b&c)) << 1)` modulo the result width.
The existing sign correction is included as `~corr_sh + 1`, avoiding a
second wide carry-propagate operation after the register.

The isolated runner compares `b7e9615a0` and the candidate on the **same**
configuration and recipe. It also accepts `multiplier__svt.sv` as a third
variant, measuring and simulating the actual emitted file. Tests compare
all supported operations against the one-stage multiplier and exercise
cancellation at every pipeline age, mask removal and transaction-ID reuse.
Source-only surface variants cover RV32, RVB disabled, and two stages.

Final validation is `fo4-a132-emitted`, pulled to
`build-platform/workspace/build/sv-timing/precompute-a132/emitted/`.
The intermediate `pair-c`, `pair-d` and `tile-place` records retain the
rejected candidates and the initial placement discriminator.

| Paired Nangate45 placement/repair | Original three-stage | Tiled RTL | Actual corrected SV |
|---|---:|---:|---:|
| Worst data arrival (ns) | 2.634 | **2.215** | **2.298** |
| Adjusted FO4, recorded 21.398 ps calibration | 123.1 | **103.5** | **107.4** |
| Worst reg→reg arrival (ns) | 2.139 | 2.145 | 2.125 |
| Repaired area (µm²) | 52,164.730 | 52,886.117 | 52,884.793 |
| Repair buffers | 2,385 | 2,404 | 2,400 |
| Disabled arcs | 0 | 0 | 0 |

The tiled RTL is retained: **15.9% lower worst arrival at +1.4% area**,
with unchanged cycle count and interface. Corrected SV preserves behavior
and retains a **12.8%** placed gain over the same baseline; it is 3.7% slower
than the direct source in this placement. The tool made one latency-neutral
SplitAssign and no InsertReg. Reparse, joint elaboration, mapping and both
runtime witnesses pass. This validates the emitted file, not a predicted
IR gain. Source and emit both still estimate 59.0 structural FO4 in the
isolated analysis; neither metric closes 10.

All three placement runs report no slew/capacitance/fanout violations.
They are pre-CTS, unrouted module studies and still have negative WNS at
the requested clock. Unbuffered timing was worse for the tiled candidate
(3.343 versus 2.655 ns worst); the favorable decision depends on the paired
placement/repair evidence. This is not a whole-core timing improvement.

The final run covers six arithmetic configurations/variants at 300,000
cycles each, all with nonzero output counts and zero errors. The baseline,
tiled source and emitted multiplier each pass 39 lifetime checks, including
cancellation at every pipeline age and subsequent TID reuse. Package tests:
373 pass. The independence scanner still reports existing host references
in unchanged test/tool content.

The host's live-RTL run refreshed widths but left `MultStages=2` in the old
parameter map. The isolated review explicitly binds the measured three-stage
configuration and peels the known `dut` prefix from elaborated wrapper widths.
Reusing a stale global parameter map is not valid pipeline evidence.

An operand-capture fourth-stage trial was rejected: it moved the product
cone behind a register without partitioning it, increasing the filtered
reg→reg delay to 2.532 ns. It is not exposed as a supported configuration.

Timing/SoC note: the retained RTL uses the existing `MultStages=3` option,
same clock and asynchronous active-low reset, and carries the same operation
identity and CLMUL state. There are no ISA, DTS, port, trace-latency or PMU-event
changes. The extra arithmetic state and buffers cost area and clock activity;
power, full-core regression and routed sign-off were not measured in this
surface review. Upstream notices and contributor attribution are preserved.

## Reproduction

From the host repository:

```text
python verif/regress/remote/run_fo4_control_review.py --snapshot <snapshot> --baseline b7e9615a0 --profile multiplier
```

Run that snapshot through the existing testharness proxy with
`CONTROL_MODE=mult-pipeline`; `CONTROL_PLACE=1` adds paired Nangate45
placement/repair with no disabled timing arcs. The runner preserves source
hashes, mapping recipes, separate path reports, mapped area and witnesses.

Then run `--analyze-results <pulled-result-directory>`. This corrects the
captured multiplier using its elaborated widths, exact three-stage parameter,
and the normal package parser. Upload the emitted multiplier along with the
same source snapshot for the third comparison. An emitted reparse or a
structural reduction alone is not the acceptance condition.

## A150 — the hyp8 redesign trees (8 FO4 per cycle, 5 GHz nameplate), draft

Scope: a hypothetical redesign of the whole core and its SoC plane under
`build-platform/workspace/hyp/` (gitignored workspace; nothing under `core/`
or `corev_apu/` changed). Target of record for the program:
`AGENTS-configuration.md` §1.0/§1.0c — **8 FO4 per cycle = 5 GHz nameplate at
`fo4_ps = 20`, margin 0.2** (`--target-mhz 5000 --fo4-ps 20 --budget-margin 0.2`).

Method, in order:

1. Fresh whole-core and APU-closure `correct --emit` at the 8 budget (the
   provenance side: `build-platform/workspace/build/sv-timing/hyp8-src/`
   — emits, boards, cut-surface / bottleneck / carry-over / propagation
   reports, the 52 `svt-plan` blocks, origin map). Core: 108 instantiated
   modules, 237 edits (annotate 221, balancemux 10, …), no InsertReg at 8;
   calibration refused (delay-v43 profile vs delay-v44 CLI), so the deciding
   value D is the measured adjusted FO4 where the Nangate45 board has the
   module, else structural.
2. Redesign set = every module in the elaborated cone with D > 8: core
   COPY 32 / T3 16 / T2 15 / T1 45; SoC cone (root `g6lc_soc`) COPY 124 /
   T3 41 / T2 39 / T1 56. Modules at ≤ 8 are the emitted files copied.
3. Per-module execution-path/caller analyses (`hyp_core_ws/analysis/`) and
   the **cut-minimization protocol** (`cut_minimization.md`: restructure →
   move the decision earlier → retime an existing register → overlap with
   gated publication → cut on a value path → cut on a dependent path,
   recorded). Held dependent latencies: ALU add/logic → ALU 1 cycle
   (staggered halves), issue → operand read +0, store→load forward hidden
   under load-use, commit +0 on the common path; the D$ hit +2 is the one
   accepted rank-5 class.
4. Rewrite in ten groups: configuration seam (`g6lc_hyp_pkg`,
   `g6lc64_hyp8_config_pkg`) + hyp cells; frontend (untagged next-line
   kernel, BTB check and predictor verdicts as epoch-killed overrides,
   elastic instruction queue); decode (three combinational stages, registers
   in `id_stage`); rename R1/R2/R3 + banked free list + late-write RAT;
   banked issue queue with speculative wakeup/replay; scoreboard lifecycle /
   cancel / 2-step head / commit bundle; execute (staggered 2-stage ALU,
   B1/B2 branch, per-FU writeback lanes with a reservation table, 8-stage
   multiplier); LSU (LSQ event → CAM → reduce → verdict, `ld_checked`,
   3-cycle store forward, load unit L1–L5); caches/MMU (write buffer W1/W2
   with the pending-record export, D$ +2, 3-stage TLBs); CSR file C1–C3,
   controller counted drain (5 cycles), observability, top wiring; then the
   SoC top `g6lc_soc` with an `axi_cdc` seam and the peripherals adapted.
   Provenance per file: REWRITTEN 25 / ADAPTED 50 / AS-IS 36 (plus the SoC
   section) — `hyp_core_ws/analysis/coverage.md`, `notes/decisions.md`
   (130 rows incl. every rank-5 cut), `notes/boot-hazards.md` (H1–H28).
5. The trees carry no upstream identity token (a new design: `g6lc_core`,
   `g6lc_hart`, `g6lc_soc`, `G6LCCfg`, `G6LC_MARCHID/MIMPID/MVENDORID = 0`);
   upstream licence headers of copied files are verbatim.

Status: **a correctness-seeking draft. No lint, simulation, STA, synthesis
or boot has been run on it; no closure or IPC claim may cite it.** The
bring-up track starts from `notes/boot-hazards.md`; the tool-side follow-ups
(port-stage emission at whole-core scale, calibration refit under delay-v44,
`throughput`/`async`/`replicate` declarations on the new seams) are in
`AGENTS-todo.md` A150.

### A150b — tool follow-ups closed: port stage at whole-core scale; delay-v44 calibration

**Port stage never attempted at `--all-modules` (root cause, fixed).** The
worklist builder ranks a legal port stage first (A149 M12), but the S4 pass
re-sorts the work list "resilient exceptions, then shallow, then slack"
(`pass.rs`), which dropped the port stage behind a prefix longer than the
idle limit (41 at this design size): three S4 passes, zero attempts, while the
5-module probe landed it. Fix: the S4 sort keeps port stages first. Re-run of
the identical hyp8 whole-core command (`hyp8-src/emit/core-8fo4-ps/`): the
`t2_port_stage` item heads the pass-4 worklist and lands —
`wt_dcache_missunit` `mem_data_o` as `pipe_svt_p1` with the `_en` chain and
the `miss_ack_o` consumers rewired; `edits 238` (237 + 1 `insertreg`),
`unemitted_stages []`, `unverified_stages 0`, `bottlenecks []` (the adapter
absorbs the wait by protocol). The hyp8 trees were materialized from the
earlier emit; the miss unit there was REWRITTEN around the same packetized
request, so nothing in the trees changes.

**Calibration refit under delay-v44** (`sv-timing adjusted --board
sta-rtl/g6lc64_ooo/module-board.tsv --report hyp8-src/emit/core-8fo4/correct.json
--platform-fo4-ps 21.398 --budget-fo4 8 --calibration-out
hyp8-src/inputs/fo4-calibration-v44.json`): 65 measured modules,
`calibrated = 0.992 × structural + 12.0 FO4 when launched at a register`,
residual median 1.00 (p25 0.73, p75 1.40), rank correlation 0.78. The
register-launch intercept is the finding: **12 FO4 ≈ 0.26 ns on this board,
larger than the whole 8-FO4 cycle (0.171 ns at 21.4 ps)** — on Nangate45 no
reg→reg path can close the budget whatever its logic, which is the measured
form of the A145 note (flop overhead 0.13–0.18 ns). The 5 GHz nameplate
therefore presumes a process whose flop overhead is a small fraction of the
cycle; the structural budget remains the design rule, the board decides.
Per-module adjusted/structural ratio median 1.18 (p25 0.84, p75 1.49); the
largest under-reads remain `g6lc_ooo_dispatch` (3.05×) and `alu` (2.45×).

## A149 — cut surface, carry-over, and the experimental dial

**The ask.** Broaden the cut surface (loops, combs, generates, `always_ff`),
adapt the other modules a stage touches, keep contracts unlocked and weaken
acceptance toward flexibility, reasoning about an OpenSBI-valid boot and
Verilator lint rather than testing, until the cut count brings the board
under 10 FO4 with stages.

**What was built.**

- `--cycle-cuts experimental` (`PassPolicy::cycle_cuts_experimental`): the
  capacity refusal of A148b becomes a label. The stage lands, its rationale
  carries `[UNVERIFIED: …]`, the trace records `pipe_contract.unverified`,
  and `correct.json` reports `boot_validity.unverified_stages`. The default
  stays `refuse`. Nothing about an unverified stage is weakened silently: a
  tree with one is a research artifact, named as such.
- `carry_over.rs`: for every emitted stage on an output port, the instance
  graph names the parent-side readers of the connected net (flop capture,
  combinational, or a parent output), whether a combinational parent net
  derived from it drives an input of the same instance (`feeds_back`), and
  whether a parent output is written from it (`propagates_up`). The verdict
  is the adaptation the consumers need: delay flop readers with the stage's
  valid; stage combinational readers before their captures; propagate up;
  or, on feedback, a protocol decision. `correct.json` → `carry_over`.
  `bottlenecks[]` (`carry_over::bottleneck_trace`, PIPELINE-PRAGMAS §18.7)
  lists only the callers that must wait more than one cycle for those
  stages: a combinational use of two or more cuts, a flop that cannot
  absorb more than one cut, or a recurrence whose loop becomes
  `cuts + 1` cycles. `correct` prints the same lines. The list is feedback
  on bubbling. It does not refuse the cut. A replica of the callee does
  not hide a caller in that list; the caller still needs this result.
- `cut_surface.rs`: for every procedural loop that holds part of an
  over-budget cone, the block-locals a per-iteration stage would hoist, the
  roots written under the loop index, the loop-carried names (read or
  written across iterations), and the indexed roots also written outside the
  loop. Verdict: `expandable`, `expandable with hoisting: …`, `loop-carried:
  …`, `default outside the loop: …`, or `no per-iteration write`.
  `correct.json` → `cut_surface`.

**What the probe says (`a149-probe-exp`, ten modules, experimental).** With
capacity unlocked, 13 plans pass as unverified and every one is then
refused by the A123 alignment rule (a tail or later stage reads a signal
that is neither its chain predecessor, a carried signal nor protocol state
— `resolved_branch_o.cf_type` reads `branch_predict_i`; `flu_result_o`
reads `alu_result`, `alu_valid_i`, `branch_valid_i`; memdep stage 2 reads
`enable_i`, `train_pc_i`, `train_valid_i`), by the area gate, or by the
block-local anchor. No stage lands; `unverified_stages = 0`. The alignment
rule is the next criterion a weaker acceptance would have to drop, and it is
the one that keeps parallel paths on the same cycle (A126's merge finding).

**The loops.** 153 procedural loops hold over-budget cones. For the five
cones that set the clock the report reads: `g6lc_lsq` 544–637 — no
per-iteration write or `viol_cand`/`phys_alias_cand` defaulted outside the
loop, `phys_replay_o` loop-carried; `wt_dcache_wbuffer` 610–668 — one loop
`expandable with hoisting` (`push_match`), the others `fixup_d` defaulted
outside the loop; the issue-queue and scoreboard select loops are the same
shape (priority chains with defaults before the loop). A loop-to-generate
rewrite there would need each iteration to own its element's default (a
second `always_comb` driver of `fixup_d` is illegal) and would still place
the flop inside a single-cycle recurrence. So the SystemVerilog refactors
asked for were not applied: where the report says `expandable`, the stage's
home becomes legal but its boot validity does not change; where it says
`loop-carried` or `default outside the loop`, the rewrite is not
equivalence-preserving as a mechanical transform.

**A149b — loosening by purpose, and what it found.** The alignment rule's
purpose is that every input a stage reads has the age of its chain. That is
served by a balance register as well as by a refusal, so `insert_register`
now carries a side read whose sources are stable (an input, a register, or a
net derived only from those off the plan's path) instead of refusing the
plan; a typed port keeps its type on the stage copies so members stay
selectable. Trying this on the twelve-module probe showed two gaps the old
refusals had been covering by accident: `res_d` in the `pipe_contract_side`
fixture reads `s1` and `s2` past their stages and nothing had checked it
(the refusal was an uncarried `c_q`); and expression-spine nodes keep only
RHS text, so their reads were invisible to every alignment check. Both are
closed: off-path readers of a cut net are refused with the balance count
they would need, the last net may be read off-path only through the result
rewiring or with constants, and the checks parse RHS text. With that, the
unlocked plans on `branch_unit`, `ex_stage`, `g6lc_memdep`, `store_buffer`
carry their inputs and registers and are then refused where the design
really reconverges (`spec_ins_oh` read by the write pointer, `jump_base` by
`target_address`, `alu_result` by `flu_result_o`). The emit is valid and
carries no register. Before these checks the same probe had emitted six
`UNVERIFIED` stages and a `branch_unit` file that did not parse.

`correct.json → propagation[]` is the cross-module half of the reference
search: for a stage on an output port, the readers in every parent are
walked — `delay-capture` (a flop samples a cycle later; its other reads are
its balance), `stage-comb` (a combinational reader is re-staged, its readers
follow), `propagate-port` (a parent output moves; the walk enters the
grandparent), `blocked-feedback` (the net re-enters an instance it left).
`valid` is true only when every frontier settled at a capture. It is the
plan a cross-module adaptation would execute; the tool does not apply it.

**A149c — M13 observers and M1 balance lines from any stage.** Two of the
mechanisms from the loosening plan are in. An *observer* (`observer_only`:
not an output, not a flop, not wired into an instance, no functional reader
within four combinational hops) may read a cut net a stage late; the probe
accepts `store_buffer`'s `speculative_write_pointer_q` that way
(`pipe_contract.observer`). A *balance line* (`PipeDomain::carry_from`,
`alignment_balance`) carries an earlier stage's net from the stage after its
cut, so a reader *i − j* stages later gets a copy of its own age; the
`pipe_contract_side` fixture, whose `res_d` reads `s1` and `s2` past their
stages, now lands as three stages with `pipe_svt_p2_c_s1 <= s1`,
`pipe_svt_p3_c_s1 <= pipe_svt_p2_c_s1`, `pipe_svt_p3_c_s2 <= s2` and the
consumer rewired to the stage-3 copies; Verilator lint of that emit is
clean. On the twelve-module probe (`a149-probe-m1`, experimental) the
balance lines fire on `branch_unit` (`resolved_branch_o` from stage 2) and
`store_buffer` (`live_after` from stage 3); the plans then stop at the next
real obstacle — `branch_unit`'s stage 2 reads the block-local `instr_pc`
(no module-level copy exists for an `automatic`), `store_buffer`'s
`spec_ins_oh` is read by the queue write itself (`speculative_queue_n[i]`,
the loop), `ex_stage`'s `rs2_forwarding` by `asid_to_be_flushed`. One stage
lands (`g6lc_memdep` line 92, `UNVERIFIED`), and the emitter could not
rewrite its procedural indexed origin, so the register is fed `svt_zero`
and unread: the whole-core lint passes (270 warnings) but the stage is a
sidecar, not a cut. The reparse is the reading that counts; the IR credit
for an unresolved feed should not be booked (open).

**A149d — the rest of the slice: hint domains, retimable frontiers, no dead
sidecars.** `hint <dom> verified-by=<sig>` (M7) declares an advisory domain;
its cycle cone takes stages without the capacity rule and the stage is
labelled `[HINT …]`, not `UNVERIFIED`. `g6lc_memdep` carries the word (the
LSQ's violation report `train_valid_i` is the verifier, as its own plan lines
said). `propagation[]` records capture guards and a `retimable` verdict (M4
as a plan): a frontier of pure captures in one guard class means the parent
flops can move into the child with no added latency. The emitter no longer
writes a stage whose origin it cannot rewrite; the CLI lists them in
`boot_validity.unemitted_stages`. On the probe (`a149-probe-m7`) the memdep
plan is admitted as a hint, the emitter declines its procedural indexed
origin, the JSON says so, the whole-core lint passes (269 warnings), and no
register lands. Core 259 / emit 71 / transform 35 pass.

**A149e — elastic stages and the latency plan.** `protocol … ready=<sig>`
(M12) makes a domain's stages elastic: `en_k = ~v_k | en_{k+1}`, the last
draining into the consumer's ready; captures only when enabled; flush
clears, a held operation is still killed; the producer's reads of the ready
— including the guard of its own capture, which the consumer rewiring now
reaches through the enclosing `if` header — move to the first stage's
enable. The `pipe_elastic` fixture lands two stages with the input
register's enable and `ready_o` on `pipe_svt_p1_en`; Verilator lint is
clean (test `elastic_domain_rewires_the_producer_ready_and_chains_enables`).
This is the one class of register that changes the machine's timing and is
valid by construction, because the protocol was already insensitive to it.
None of the twelve probe modules declares a ready today; the dcache/icache
request ports and the frontend–instruction-queue boundary are the
candidates. M6 is a plan: `latency_update` → `boot_validity.latency_updates`.

**Not done, in the order of the plan.** M2 (moving an off-path reader after
the stage and following its readers inside the module), applying the M4
move across files (delete the parent flops, stage the child; reset shadow,
carried enable), M5 (issue-side slot reservation co-emitted into
`issue_read_operands`/the IQ), the M6 co-emission itself, M8 (`checked` bit
before commit), M9 (`conservative <sig> safe=` with the one-sided bypass),
and the registered-ready skid variant of M12. Each needs cross-file emission
or a checker the IR does not yet have; none changes the finding that the
cones setting the clock are single-cycle recurrences.

**Where this leaves 10 FO4.** No contract word and no source refactor turns
a single-cycle recurrence into a pipeline. The routes remain the RTL ones
(A145, RTL-PIPELINE-PLANS); the carry-over report is the reference search
they need when a stage moves a module output, and the cut-surface report is
the checklist for the loop bodies they must restructure.

## A148b — boot validity of a cut on a `cycle` cone

**The question.** A148 lets a `cycle` line authorize budget-fit registers
along an over-budget `q`→`d` cone and writes them into corrected SV. The
remote OpenSBI route for such a tree exists (`soft-ladder-build-harness.sh`
with `SOFT_LADDER_ISOLATED=1 SOFT_LADDER_EMIT_FLIST=…`, the emit copied under
`build-platform/workspace/build/sta-rtl/` so the proxy syncs it, then
`soak`). The only cookie pass so far is `a147c`, a tree with no tool
register. This pass asks what a register on a cycle cone does to the
machine before asking the harness.

**What the stage does.** With `--real-cut-feeds` a carried stage is
`pipe_svt_pN_c = <origin RHS>` sampled into `pipe_svt_pN` with a chained
`_v`; the origin assign reads the register. On a feed-forward datapath
whose consumers wait on the domain's valid (the multiplier), that is a
pipeline. On a cycle cone `q → f → d → q` it is not: the launch `q` keeps
updating every cycle while `d` arrives `k` cycles late, so `q` captures
`f(q_{t-k})` instead of `f(q_t)`. The recurrence is a different machine.
The one register that landed on the whole core (`a148`, `branch_unit`
line 75) is the degenerate case: the planner cut the procedural default
`resolved_branch_o.target_address = '0` — a registered constant, zero gain,
harmless only because it is a constant. On any node that carries state it
is a boot failure, and the remote would be another boot of a broken core.

**What the `cycle` line can honestly cover.** `steps=S` with `hold` is the
multicycle exception: `q` is held for `S` cycles, so the cone may take up
to `S − 1` registers (or none — STA simply relaxes the path) *if* `hold`
really gates every update of `q` and the cone's other inputs are stable
over the window. `steps=1` covers nothing: it is a statement that the step
is single-cycle. Of the 51 `cycle` lines now in `core/`, 49 say `steps=1`
and two say `CVA6Cfg.MultStages`; 27 name a `q`→`d` pair the model never
measures (`q=mem`, `q=lsu_req_i`, …), and several name a `hold` that is a
flush or an unrelated valid.

**Guards added.** `pipe_contract::cycle_capacity_refusal`: a plan on a
cycle domain is refused when `steps` does not resolve to an integer, when
`hold` does not gate the launch register (`hold_gates_launch`: every
non-reset non-blocking write of `q` is under `hold`, or `q <= q_d` with
every non-copy writer of `q_d` under `hold`), or when the stages already
placed plus the plan exceed `steps − 1`. `insert_register` applies it after
the area gate, before any IR rewire; the trace shows
`pipe_contract.refuse … absorbs 0 register(s)` for every `steps=1` cone.
Second, `apply_cycle_contracts` no longer takes other paths off the board
when a declared step is within budget. On `a148` that exclusion had hidden
210 over-budget paths — all 121 failing paths of `wt_dcache_wbuffer` (the
160.6 FO4 worst, hidden by `cycle wb q=wbuffer_q d=wbuffer_data_o`, a
register read), 84 of `cva6_shared_tlb`, 5 of `g6lc_way_predictor` — and
reported `g6lc_iq` 156 as the worst. A declared step is a fact about that
step; the other single-cycle paths of the module stay measured.

**Evidence (`a148f-ooo-fo4-10`, the same command with the guards).** Every
cycle-cone plan is refused with its reason in the trace (`branch_unit`:
`branch_valid_i` does not gate `target_address`; `ex_stage`, `frontend`,
`g6lc_memdep`, `store_buffer` likewise; `g6lc_bp_ittage`/`g6lc_bp_loop`:
`steps=1 absorbs 0 register(s)`). No register lands; 238 latency-neutral
edits do (11 BalanceMux, SelectIncrement, LoopRewrite, RebalanceAssoc,
three SplitAssign, the TAGE row-local preparation). Nothing is excluded by
declaration, so the board reads `wt_dcache_wbuffer` 160.6 reg→reg (closure
249 MHz at this model), `g6lc_lsq` 216.9 reg→out, `g6lc_iq` 156.0,
`scoreboard` 145.8, `g6lc_rename` 130.4 — the `a148` run had reported
`g6lc_iq` 156 / 256 MHz with the write buffer hidden. Post-analysis is
valid; Verilator lint of the 264-file emit passes (290 warnings; slang 2).
The emit was copied to `sta-rtl/g6lc64_ooo/emit-a148f/` and the remote
g6lc64_ooo harness built it through the emit overlay
(`work-ver-ooo-a148f-emit`, 160 s); the OpenSBI soak was refused by the
overlap guard (foreign soaks on the builder), so the cookie for this tree
is owed — like `a147c`, it carries no tool register, so it is a boot of the
uncut core's latency-neutral rewrites.

**What the budget-fit cut cannot reach, and why.** The cones that set the
clock are the issue queue's select loop (156 FO4), the LSQ (217), the write
buffer (161), the scoreboard (146) and the rename repair (130). They are
procedural `for` loops in `always_comb` with block-local `automatic`s and
loop-carried priority chains (`slot`, `q_chain`, `older_d`). The planner's
"every budget-fit cut names a block-local" is not the obstacle; rewriting
those loops as labeled generate-fors would only give the flop a legal home,
and the flop would still sit inside a single-cycle recurrence. The RTL
routes (A145, RTL-PIPELINE-PLANS) remain the only boot-valid ones:
registered candidates with speculative wakeup and replay in the IQ, the
rename group publication, the LSQ age matrix split with replay, the write
buffer's deferred fixup bundle — each an IPC decision measured by the soak.

**What a stage *can* legitimately cover with a pragma.** A feed-forward
domain whose consumers wait on its valid (`protocol … valid= id=` with a
`result` line rewired at the consumer), or a genuine multicycle step
(`steps ≥ 2`, `hold` gating `q`, cone inputs stable) — the serial divider
and the PTW/cache FSM waits are candidates, the OoO loops are not.

## A147 — three rungs toward the delay-v44 worst, over the preprocessed pipelining

**The model first.** Under delay-v43 the structural worst was `g6lc_rename`
234.9 FO4: allocation picks → … following the mispredict repair of `free_d`.
That chain is not in the RTL — the picks read `free_d` *before* the repair
writes it in the same `always_comb`; compose linked every read to the
block's last write. delay-v44 links reaching definitions (the latest write
before the read inside a procedural block; another region's last write):
rename 234.9 → 130.4 (the repair chain itself, in→out), while modules whose
writers are spread over several regions read higher where the old single
"last def" had hidden real fan-in (`rr_arb_tree` 25.6 → 38.4, `scoreboard`
86.1 → 145.8, `g6lc_lsq` 181.2 → 216.9). New worst: `wt_dcache_wbuffer`
160.6 reg→reg (`g6lc_lsq` 216.9 is reg→out).

**Multiplier: `MultStages = 4` segments the final add.** The board's
multiplier reg→reg worst was the final carry-propagate add
(`prod_sum_q[5] → mult_result_d[126]`, 1.563 ns / 33 cells). `gen_four_stage`
adds the low halves of the carry-save rows in stage 3 and registers their
carry-out with the upper rows; stage 4 adds the upper halves with that
carry. Valid, trans_id, operator and both CLMUL results take the same stage
(the A126 merge rule); `mult.sv` tracks `MultStages` cycles unchanged;
`check_cfg` admits 4; `g6lc64_ooo` sets 4 (+1 multiply latency). The
rejected A132 operand-capture fourth stage is not this: that moved the tile
cone behind a register without dividing it.

| evidence | result |
|---|---|
| split identity, RW = 128 (yosys SAT) | proven |
| sequential miter: 4-stage vs 3-stage delayed one cycle, all ops, valid, tid (k-induction, shared stages merged) | proven; negative (high half without the carry) fails at the base case |
| `tb_mul_sbs` `SVT_MUL_STAGES=4 +lag=3`, 300k cycles | 234 213 results, 0 errors |
| `tb_mul_lifetime` at 4 stages | PASS, 54 checks |
| same source at 3 stages vs baseline | identical maps and placement (the branch is inactive) |
| unplaced Nangate45, fanout 0 / 64 | reg→reg 1.662 → **1.366 ns**; in→reg 3.343 → 3.338 / 2.144 → 2.088 |
| placed + repaired, no disabled arcs | any 2.215 → **2.114 ns**, reg→reg 2.145 → **1.679 ns**, area 52 886 → 55 146 µm² (+4.3 %) |

Run `fo4-a147-mul` (`CONTROL_MODE=mult-pipeline CONTROL_MUL_STAGES=3,4
CONTROL_PLACE=1`). The module's worst is now the in→reg tile cone from the
operand inputs, which the module board reads with ideal drivers. The
structural model reads stage 4's `hi_s + hi_c + cout` as two adds (16.0 vs
14.0 FO4 reg→reg): a 1-bit carry-in is not yet recognised as one adder.

**Rename: the mispredict repair no longer waits on the allocation.** The
squash set is now taken against the free list before this cycle's
allocations (`free_q` plus commit frees) instead of `free_d` after the picks.
That is the same set because a mispredict cycle never allocates: the
controller raises `flush_unissued` on every mispredict and dispatch's
`can_go` (rename's `enable_i`) excludes it, in every legal OoO configuration
(`check_cfg` refuses OoO with `NrHarts > 1`; with fetch B the controller sees
the same `resolved_branch`). A fenced `$error` asserts it. Matched-state
equivalence with `enable_i` masked by `mispredict_i` in both copies: proven
at 1 hart/40, 1/64, 2/80 entries; the unmasked negative leaves 158
unproven cells — the invariant is necessary and the check discriminates.
The board's rename worst (`free_q → owner_d → free_d`) runs through the
per-hart flush reclaim, whose `flush_hart_i` the core ties to `'0`: a
module-board artifact, not this chain. Physical evidence is owed.

**TAGE tables: a row-local directive the preprocessor applies.**
`g6lc_bp_tage_table` carries `svt-pipe: row-local train index=update_index_i
rows=NR_ENTRIES banks=mem_q:mem_d max-rows=64` on its update. `correct`
prepares it, reparses, then runs the worklist over the prepared program
(“pragma preprocessing: 1 source edit(s), reparsed before correction”).
Emitted vs source matched-state equivalence: proven at 64/6, 16/4 and 48/6
entries/index bits (an out-of-range index writes no row in either form).
Structural 10.6 → 12.0 (as A135: this rule is judged on the placed pair,
which is owed).

**Preprocessing under the new model.** The representation fixture's emit is
byte-identical to A133's measured file; the row-local fixture prepares and
reparses (structural emission needs `--real-cut-feeds` or
`--emit-balance-mux-rtl`). The whole-core run prepares the TAGE table and
transforms the reparsed design.

**The corrected g6lc64_ooo.** `correct --all-modules` at 10 FO4 (`-O3
--opt-max-passes 6 --allow-latency --assume-clk --real-cut-feeds
--contracts-only`, dial 11 at 48, live params with `MultStages = 4`, the
elaborated width map; run `a147c-ooo-fo4-10`): one preprocessing edit,
then the worklist over the reparsed program — 22 BalanceMux, SelectIncrement
(`g6lc_ftq`), LoopRewrite (`scoreboard`), RebalanceAssoc (`g6lc_bp_ckpt`),
three SplitAssign (`g6lc_freelist`), all latency-neutral; post-analysis
valid (reparse, structural, joint). Without `--contracts-only` the planner
had landed 11 bare registers in modules that declare no protocol
(`wt_dcache_ctrl` ×4, `acc_dispatcher` ×4, `hpdcache_cmo`, `instr_scan`,
vendored `exp_backoff`) — the review-only cuts A127 named, which would
change control-path latency; the flag refuses them (11 refusals logged).
The structural worst does not move (`wt_dcache_wbuffer` 160.6 reg→reg,
`g6lc_lsq` 216.9 reg→out): the top cones are next-state functions under
`no-cut`, and the moves above are the hand rungs.

**Verilator.** Lint of the live tree: PASS (269 warnings, unchanged count;
slang 2). Lint of the 264-file corrected tree (`verify --lint --from-timing
… --use-emit`): PASS (276 warnings; slang 2). The first corrected emit had
failed: `g6lc_ftq`'s select rewrite read candidates that were never
declared. `snippet_refs_late_declared_local` took `logic [PTR_W:0] c;` (a
block-local sized by `PTR_W`) for a late declaration of `PTR_W`, so the
candidate snippet was refused at module scope, sent "in process", dropped,
and the RHS rewrite still landed. Names inside a dimension are uses now, and
a generate-loop snippet is never in-process; the ftq emit is matched-state
equivalent to its source. Remote: the g6lc64_ooo Verilator harness of the
live RTL builds (137 s, `work-ver-ooo-a147`); the DI minis were refused by
the overlap guard (two foreign soaks), so core-level function and IPC
evidence for `MultStages = 4` and the rename change is owed.

## A145 — IQ protocol stage, first rung: the staged store-age gate (built, measured, not retained)

**The ask and its physical bound.** The request was to turn the pipeline
plans into RTL stages under 10 adjusted FO4. On this calibration that is
0.214 ns, of which the flop itself (clk→Q 0.09–0.14 ns, setup ≈0.04) is
0.13–0.18 ns: one or two gates per stage. No cut of the OoO loops reaches it;
the agreed target became ~1.0 ns (47 FO4) with IPC cost measured by the soak
and recorded.

**What was built (`trials/a145-iq-staged-store-gate.patch`).** A config bit
`IqStagedStoreGate` (all 20 target packages, on in g6lc64_ooo) under which
the issue queue evaluates the load's store-age gate one cycle ahead: a
registered per-slot verdict computed for the entry that will occupy the slot
(the A112 shape), completed in the select by the stores still queued ahead
of the load — the only unresolved stores a one-cycle-old mask can miss are
last cycle's dispatches, and those are queue entries. Conservative by
construction; a load blocked by an older unresolved store is released one
cycle after the resolution. Witness `tb_g6lc_iq_stgate`: random ALU/LOAD/STORE
dispatch with in-order ids, a model LSQ, producers, commit pointer, acks and
stalls; every issued load is checked against the *exact* current-cycle rule,
operands and store order are checked for every issue, and the oldest
exact-rule-issuable op must issue within 3 acked cycles. 3 seeds × 200k
cycles (≈95k loads, 47k stores per seed) pass; the negative (DUT blind to the
mask) trips `IQ_STGATE_SAFETY` at cycle 8. The store-age leaf still passes;
the gate-off module equivalence is inconclusive (equivalence-engine budget,
as for the write buffer) — the gate-off path is the original code under a
generate-time constant.

**Measurement — neutral, so not retained.** Whole-core split pair of the IQ:
mapped area 180062 → 176570 µm², unbuffered reg→reg clk_i → clk_i ns,
placed worst 2.806 → 2.779 ns, reg→reg 2.525 → 2.768 ns, area
194951 → 190315 µm². The board's worst path moved from
`count_d → issue_valid_o → q_after_issue` to `older_unres_d → q_d → …` at the
same length: the unfiltered path report's 6.2 ns cone from `commit_ptr_i` was
the *input* cone (fanout-heavy), while the loop the board measures —
wake CAM → ready → any/many rank trees → grant → one-hot select → clear →
next state, ≈32 cells — is 2.40 ns on its own and untouched by staging a
term that feeds `ready`. The RTL and config are reverted; the witness, the
`iqgate` review profile and the result stay as the harness for the real
stage.

**What the real stage is, and what it now needs.** Only a register *inside*
the loop moves it: registered candidates (readiness and age rank computed
one cycle ahead) with the select and grant on the registered vector, and
dependent issue kept at one cycle by speculative wakeup from the selected
producer's tag (fixed-latency FUs) with replay on a load miss. That is an
IPC change measured at the core: the g6lc64_ooo baseline harness is built
(`/opt/testharness/work/work-ver-ooo-a145-base`, 171 s with the cache); the
DI minis and the OpenSBI soak (`[cookie-exit] t=` cycle count) against it
could not run in this pass — the remote's overlap guard refused them while
two long-running soaks from other tracks (`ooocoh-t38`, 3.2 days;
`ooocoh-t52`) occupy the machine, and those are not mine to stop. Commands:
`testharness_proxy.py soak --flavour B --verlib work-ver-ooo-a145-base --skip-build`
and `di --flavour B --verlib work-ver-ooo-a145-base`, then the same for the
candidate library.

## A144 — path reports on the top four, and the write buffer's fixup queue

**Path reports.** The module board gives start/end nets only; the full
cell-by-cell reports of the mapped per-module netlists (`path_report.py`,
fanout>64 drivers disabled as on the board, reset recovery excluded) say what
the remaining top cones actually are:

| Module | Critical cone, from the report | Nature |
|---|---|---|
| `wt_dcache_wbuffer` | flop → 3 MUX2 (head-relative read of a fixup entry) → tag compare → a Depth-deep AOI/OAI priority chain → merge → flop | logic depth; latency-neutral fix (this entry) |
| `frontend` | flop → OR4 → **OAI33 with 64 loads (1.04 ns)** → MUX → two chained address compares (XNOR/OR4/NOR4 trees) → **OAI21 with 64 loads (0.45 ns)** → compare → flop | 1.5 of 4.1 ns is two broadcast control nets at the fanout limit; the logic is two serial 64-bit compares on the next-PC select |
| `g6lc_iq` | `commit_ptr_i` → age compares (XNOR, 50 loads) → NOR4 trees with 51/59 loads (0.94 + 1.11 ns) → select → XOR chains → flop | fanout-dominated age/oldest broadcast off the commit pointer, then the select |
| `g6lc_ooo_dispatch` | `wb_id_i` → 3 MUX2 (table read) → OR4 → NOR2 (0.45 ns) → 4 MUX2 → `issue_op_a_o` | the writeback-id table read feeding the operand output — not the `can_go` write cone the module board's trace suggested |

The rename and store-buffer cones that led the board were logic depth and
were removed (A141, A143). The frontend and IQ cones are dominated by
broadcast nets a real flow buffers; their logic depth (two serial compares;
age compare → select) is what a protocol change would address.

**Write buffer (`fo4-a144-wbuf4`, retained).** The fixup queue's push
coalesce and returning-word match walked `(head + k) % Depth` entries
serially. Slots are now tested in parallel (occupied = ring distance below
the count) and the first match in FIFO order is the lowest matching slot at
or above the head, else below it (two prefix-OR isolates) — the selection is
SAT-equal to the ring walk (merge one-hot, coalesced, active-head, any-match)
at depths 2/4/8/16 for every head, count and address pattern. The
whole-module matched-state proof did not finish within 600 s per depth
(recorded inconclusive; it stalls on one `$equiv` cell after proving the
outputs through `wr_user_o`). Directed fixup regressions
(`run_wt_fixup_review.py`): NC 24/24 and INV 38/38 expected outcomes; the
retained-copy regression's scenario 3 (`d2-s3`) fails identically on the
unchanged baseline — a stale expectation since T46/T47, recorded, not a
difference.

| `wt_dcache_wbuffer` (isolated pair, OoO configuration) | Before | **After** |
|---|---:|---:|
| Mapped area | 65760 µm² | **54739 µm²** (-16.8%) |
| Unbuffered reg→reg / cells | 3.166 ns / 26 | **1.932 ns / 21** |
| Placed worst arrival | 5.344 ns | **4.853 ns** (-9.2%) |
| Repaired area / buffers | 70548 µm² / 4879 | **57834 µm²** / 3505 |
| Whole-core board | 2.831 ns / 132.3 | 2.934 ns (inside the re-map band; the board's worst cone for this module is now the bypass-slot merge/supersede path, `fixup_bypass_d` → `wbuffer_data_o`, a different cone from the FIFO walk this entry removed — next step-1 item: compare the pre-push addresses in parallel and select by the allocation instead of comparing the post-push mux output) |

**Protocol-level changes — explored, specified, not landed.** With the path
reports in hand the step-2/3 items read as follows. Each changes an
interface latency and therefore needs the core-level route, which exists:
`testharness_proxy.py build --flavour B --target g6lc64_ooo` (Verilator
harness, ~1 h), `di --flavour B` (the directed minis, including
`mini_stq_flush_fwd`), `soak` (the OpenSBI cookie soak — the IPC reading,
by cycle count against the baseline harness). None of that was run in this
pass; the remote has no g6lc64_ooo harness at HEAD yet.

* **Frontend, early next-line prediction with late correction.** The cone
  is the next-PC select comparing the resolved/predicted targets twice in
  series. Design: select the next fetch address from a small next-line
  table indexed by the current fetch address (one cycle early), issue the
  fetch, and let the full predictor's result one cycle later *correct* it
  with a token (fetch epoch + slot) — a correction squashes the one
  speculative fetch, costing a bubble only when the next-line guess and
  the full prediction disagree. Carried bundle: epoch, FTQ slot, RAS/ckpt
  identity, the alternative target. Cost: the extra bubble on disagreement
  (BTB/next-line agreement is typically >90 %), one more recovery case in
  FTQ/realigner/queue. Validation: DI + soak cycle count; the realigner
  and queue side-by-side benches extended with the epoch.
* **Issue queue, pipelined select with speculative wakeup.** The cone is the
  age/oldest broadcast off the commit pointer feeding the select. Design:
  compute readiness and age one cycle ahead into a registered candidate
  vector; select from registered candidates; keep one-cycle dependent
  issue through speculative wakeup (a selected producer wakes consumers
  the same cycle for fixed-latency FUs, with replay on a load miss).
  Carried: candidate bits, age rows, producer tags per lane, the replay
  mask. Cost: a replay path and its IPC on load misses; the age matrix read
  moves to the candidate stage. Validation: `tb_g6lc_iq_store_age`
  extended with wakeup/replay, DI, soak.
* **LSQ AGU input staging** (`protocol agu` already declared): capture the
  AGU update one cycle before the CAM write with full bypass to the same-
  cycle readers; +1 load-to-use latency unless bypassed into issue. The
  placed reg→reg of 1.89 ns against 2.23 any bounds the gain to ~15 % for
  that latency — the weakest trade of the four; recorded as such.
* **Dispatch record staging.** The report shows the module's worst path is
  the writeback-id table read to the operand output, not the write cone;
  staging the writes would not touch it. Dropped from the candidate list;
  the read path is a table-indexing shape (A140 lesson: a direct per-entry
  compare against the id, AND-OR, instead of a mux tree).

## A142/A143 — the isolate sweep on the new worst module; a tile trial rejected

**A143 (`fo4-a143-isolate`).** With the store buffer off the top, `g6lc_rename`
led the board (2.954 ns). Its free-register picks — integer and FP pools, low
and high picks, the two-port capacity test — were all `x & (~x+1)` /
`x & (x-1)` isolates over PRF_ENTRIES-wide vectors, the form the A140
scoreboard experiment showed the live board maps as a carry chain. Every one
is now the explicit log-depth prefix OR (`lowest_set` / `flowest_set`;
"at least two" = "something set besides the lowest"). The scoreboard's
MixedSmt reclaim scan takes the same absolute-order form as its head scan
(inactive in g6lc64_ooo: identical mapped area, SMT configurations only).

Proofs: the isolate identities (lowest, highest-via-reverse, at-least-two) by
SAT at 16/32/40/64/80/96/128 bits; the reclaim scan against the rotated form
at 16/32/64 entries; rename matched-state equivalence at 1h/40, 2h/80 and
1h/64 entries; the IQ store-age leaf with its oracle negative.

| Rename (whole-core-split netlist, standalone placement) | Before | **After** |
|---|---:|---:|
| Placed worst arrival | 3.131 ns | **2.833 ns** (-9.5%) |
| Placed reg→reg | 3.131 ns | **2.785 ns** (-11.1%) |
| Repaired area | 241421 µm² | 243082 µm² (+0.7%) |
| Whole-core board | 2.954 ns / 138.1 | **2.462 ns / 115.1** |

The same rewrite in the issue queue's slot allocation measured **worse**
(placed 2.806 → 3.086 ns, reg→reg 2.525 → 2.681): its allocation isolate is not on
the wake→select→grant cone, so the change only perturbed a 190 k µm² mapping.
Not retained — the lesson is that an isolate rewrite pays only on the module's
critical cone, and that a large module's pair moves by several percent on any
RTL perturbation (the same caution as the board's re-map noise).

**A142 (`fo4-a142-mul8`, rejected).** 8×8 instead of 16×8 multiplier tiles at
three stages: the unbuffered in→reg cone barely moved (2.144 → 2.076 ns)
while placement worsened (2.215 → 2.549 ns, area +5.9%): the tile
product's own depth is not what bounds stage 1 — operand fan-out into more
tiles is. The witnesses (sbs 3 seeds, lifetime, RV32, no-RVB, two-stage) all
passed; the RTL is unchanged.

**Board after A143** (budget-equivalent **283 MHz**, from 216 at the start of
A140; 56/73 modules still over budget):

| Module | worst arrival | adjusted FO4 |
|---|---:|---:|
| `wt_dcache_wbuffer` | 2.831 ns | 132.3 |
| `frontend` | 2.744 ns | 128.2 |
| `g6lc_rename` | 2.462 ns | 115.1 |
| `g6lc_iq` | 2.403 ns | 112.3 |
| `g6lc_lsq` | 2.229 ns | 104.2 |
| `multiplier` | 2.181 ns | 101.9 |
| `scoreboard` | 2.165 ns | 101.2 |
| `g6lc_ooo_dispatch` | 2.157 ns | 100.8 |

## A141 — step 3, the store buffer: stationary slots and an age matrix

The first recurrence redesign of `architecture/RTL-PIPELINE-PLANS.md` step 3,
on the module that topped every board since A128. The speculative queue was a
dense ring kept in program order by one permutation per cycle (arrival rank
by popcount of age verdicts, survivor ranks by popcount of keep verdicts, a
DEPTH² gather of every payload field). It is now a set of **stationary
slots**:

* a store takes the lowest free slot (prefix-OR isolate) and never moves;
* program order is a DEPTH×DEPTH **age matrix**, written once at insertion
  from the arrival's circular age against every live entry (arrival order
  when not OoO) and cleared with the entry — the IQ's stationary pattern;
* the commit head is the live entry no live entry is older than (one-hot),
  gathered into the commit queue by AND-OR;
* forwarding takes, per byte, the candidate (older than the load, same hart,
  lane or cbo.zero match, byte written) that no younger candidate also
  writes — the same last-writer-wins the ordered walk implemented;
* cancel and flush clear valid bits in place; the count is the popcount of
  the live slots; `ready_o`, `commit_ready_o`, RVFI and the legacy SMT keep
  path are unchanged in meaning.

The ring pointers survive only as debug aliases (`speculative_read_pointer_q`
= head slot, `speculative_write_pointer_q` = next free slot) for the census
and the T35 leaf, which now checks `count == popcount(valid)` and a
stale-age-bit mutation (`G6LC_MUT_STQ_FLUSH_WP_Q`, caught by
`spec_order_cleared`).

**Precondition made explicit.** The matrix is the program order only while
the age anchor (`oldest_live_tid_i`, the scoreboard's reclaim pointer) never
passes a live store. That holds by construction in the core; the module now
asserts it (`spec_order_matches_anchor`), and the side-by-side harness, which
used to drive the anchor at random — making the *ring's* insertion ranks just
as arbitrary — drives the first live tid in ring order.

**Evidence (`fo4-a141-stq3b`).** Cycle-exact side-by-side against the ring,
every output every cycle, 4 seeds × 400k cycles (≈211k pushes, 85k commits,
78k cancel cycles, 9.3k flushes per seed), all internal assertions on
(order total/irreflexive/cleared, one head, anchor agreement, OoO commit
handoff, liveness): **0 mismatches**. T35 leaf positive, oracle negative,
mutation caught. Whole-core slang elaboration and the selected-target lint
pass.

| Store buffer (g6lc64_ooo, Nangate45, isolated pair) | Ring | **Stationary** |
|---|---:|---:|
| Mapped area | 70417 µm² | **45486 µm²** (-35.4%) |
| Unbuffered worst arrival / reg→reg cells | 3.766 ns / 36 | **1.293 ns / 11** |
| Placed worst arrival | 4.159 ns | **2.811 ns** (-32.4%) |
| Placed reg→reg | 4.159 ns | **2.148 ns** (-48.4%) |
| Repaired area / buffers | 75335 µm² / 4773 | **48169 µm²** / 2278 |

**Whole-core board** (streamed recipe): `store_buffer` 3.958 → **1.929 ns**
(90.1 adjusted FO4; reg→reg 1.250 ns), every other module
bit-identical. The core's worst module is now `g6lc_rename`; the
budget-equivalent frequency moved from 216 to **271 MHz** on this platform.

| Module (board after A141) | worst arrival | adjusted FO4 |
|---|---:|---:|
| `g6lc_rename` | 2.954 ns | 138.1 |
| `wt_dcache_wbuffer` | 2.831 ns | 132.3 |
| `frontend` | 2.744 ns | 128.2 |
| `g6lc_iq` | 2.403 ns | 112.3 |
| `g6lc_lsq` | 2.229 ns | 104.2 |
| `multiplier` | 2.181 ns | 101.9 |
| `scoreboard` | 2.165 ns | 101.2 |
| `g6lc_ooo_dispatch` | 2.157 ns | 100.8 |

**Steps 2 and 3 — status.** Done: the store-buffer recurrence (this entry) and
the step-1 rewrites (A140). Not done, each a producer/consumer redesign with
an IPC decision: rename read/write group publication (+1 dispatch cycle;
checkpoints and the inter-group bypass), banked IQ selection (exact
multi-issue ordering across banks or a documented policy change; speculative
wakeup for load-use), frontend next-line prediction with late correction
(epoch recovery across FTQ/realigner/queue), and the step-2 ownership items
(ex_stage completion reservations, D$ miss-unit install descriptors, MMU
response context, dispatch record staging). The dispatch record staging was
examined and set aside: its write cone is dominated by the `can_go` chain
that staging does not shorten, the bypass touches every table read, and the
composite module has no standalone harness for a cycle-exact witness.

## A140 — step 1 of the A139 plans: three latency-neutral rewrites landed

The first rung of `architecture/RTL-PIPELINE-PLANS.md` (remove avoidable logic
depth before adding protocols). Three `svt-plan: reshape` items became RTL,
each proven against the previous revision and measured in one paired run
(`fo4-a140-step1h`; the forwarding alternative in `fo4-a140-step1g`):

* **`core/cache_subsystem/wt_dcache_mem.sv`** — the per-byte "lowest matching
  entry wins" forwarding scan over `WbufferAllDepth` entries is a balanced
  tree of the same associative merge; data and user bytes travel in the leaf
  tuple. Proof: the live block is extracted by text into a standalone module
  and proven combinationally equivalent to the previous serial scan (SAT
  miter) at five geometries (depth 16/8/4/2/1, 8- and 4-byte lanes, 8/4/1
  user bytes). The prefix-one-hot + AND-OR form was measured as well; it is
  area-neutral but gains far less, so the tree is retained with its area cost
  recorded.
* **`core/frontend/g6lc_bp_loop.sv`** — the row-local training the A135 emit
  proved is now the shipped RTL (`row-local-applied`). Matched-state
  equivalence with the indexed form at 16×4, 8×1 and 32×2; the independent
  per-row model passes (2 seeds, 240k checks each) and its negative control
  still fails.
* **`core/frontend/g6lc_loop_buffer.sv`** — `base + (cursor << ALIGN)` only
  carries into the high slice as +0/+1, so the +1 alternative is registered at
  arm and both high compares run beside a `IDX_W+ALIGN`-bit add; the carry
  picks the compare. Exact modulo 2^VLEN (wrap included), two invariant
  assertions (registered increment; split compare == reference) on in the
  witness. Six cycle-exact side-by-side runs (3 geometries × 2 seeds, 300k
  cycles) and the 6-step output miter pass. Unlike A136, no wide select is
  added to the hit path — the registered value feeds a compare, not a mux.

| Module (isolated, Nangate45, paired placement/repair, no disabled arcs) | Worst arrival | Reg→reg | Repaired area | Buffers |
|---|---:|---:|---:|---:|
| `wt_dcache_mem` forwarding tree (retained) | 3.154 → **2.333 ns** (-26.0%) | 0.425 → 0.660 ns | 8861 → 11610 µm² (+31.0%) | 994 → 1057 |
| `wt_dcache_mem` prefix one-hot + AND-OR (alternative, not retained) | 3.154 → **2.937 ns** (-6.9%) | 0.425 → 0.490 ns | 8861 → 8458 µm² (-4.5%) | 994 → 1012 |
| `g6lc_bp_loop` row-local training | 1.911 → **1.459 ns** (-23.7%) | 1.353 → 0.961 ns | 17777 → 15595 µm² (-12.3%) | 759 → 499 |
| `g6lc_loop_buffer` bounded address add | 1.824 → **1.507 ns** (-17.4%) | 1.824 → 1.507 ns | 7412 → 7807 µm² (+5.3%) | 185 → 197 |

* **`core/scoreboard.sv`** (`fo4-a140-sbhead3`) — the per-hart head scan
  takes the A136 ROB form: candidates in absolute slot order split by a
  thermometer mask at the commit pointer, two lowest-set isolations, direct
  slot encode; the rotation crossbar and the pointer add are gone (hdist still
  subtracts, as before). The scan block is extracted by text from both
  revisions into standalone modules and proven combinationally equivalent on
  (slot under head_valid, validity, PC) at 32×2, 16×1, 8×2, 64×4 and 32×1
  entries×harts (the 64×4 problem: 14 M variables). The serial T6b-1
  reference assertion stays on. Isolated placement is not available for this
  module (type-parameter heavy); it is read on the whole-core board.

* **`core/branch_unit.sv`** (`fo4-a140-sumeq`) — the JAL/JALR target check
  `jump_base + imm != predict_address` is a carry-free test: `a + b == c`
  iff `a ^ b ^ c == ((a & b) | ((a ^ b) & ~c)) << 1` (the carry each bit
  would need must reproduce the majority recurrence), with the JALR LSB
  clear handled by comparing bits [VLEN-1:1] with the real carry `a0 & b0`
  into bit 1 and requiring `c[0] == 0`. The adder still produces the
  redirect address; only the mispredict decision loses the carry chain.
  SAT-proven against the adder compare at 64 and 32 bits, both LSB modes;
  a translate_off witness compares both forms every cycle.

**Whole-core board readings (streamed recipe, Nangate45, `timings sta-rtl
--remote --fo4 0 --platform nangate45 --map-recipe streamed`; the route now
takes ~6 minutes):**

| Module | A137 board | first A140 board | after the scoreboard prefix-OR fix |
|---|---:|---:|---:|
| `wt_dcache_mem` | 2.068 ns / 96.6 | **1.315 ns / 61.5** | 1.315 ns / 61.5 |
| `g6lc_bp_loop` | 1.202 ns / 56.2 | 1.123 ns / 52.5 | 1.123 ns / 52.5 |
| `g6lc_loop_buffer` | 1.548 ns / 72.3 | 1.618 ns / 75.6 | 1.618 ns / 75.6 |
| `scoreboard` | 2.006 ns / 93.7 | 2.623 ns / 122.6 (`x & (~x+1)` isolate) | 2.165 ns / 101.2 (prefix-OR isolate) |
| `branch_unit` | 1.448 ns / 67.7 | 1.461 ns / 68.3 | 1.461 ns / 68.3 |
| whole core | 216 MHz budget-equivalent | 215 MHz | 215 MHz |

**Measurement finding — the module board is noisy for re-mapped modules.**
Between the A137 board and the first A140 board, four modules whose source
did not change moved: `issue_read_operands` 1.943 → 1.430 ns (−26%),
`cva6_tlb` 1.478 → 1.152 (−22%), `g6lc_rename` 2.693 → 2.954 (+9.7%),
`multiplier` +2%; the other 47 unchanged modules were bit-identical (cache
hits). Between the two A140 boards (only `scoreboard.sv` changed)
`store_buffer` moved +6.4%, `g6lc_lsq` +13.7%, `multiplier` +2.8%,
`cva6_tlb` −2.2%. A same-source repeat of a board is bit-identical because
every module hits the content cache — so a repeat does not measure this
noise; a re-map does. The isolated paired flow, by contrast, reproduced its
baselines exactly across sessions (loop buffer 1.824 ns in A136 and twice
today; D$ forwarding 3.154 twice; loop predictor 1.911 twice). Consequence
for acceptance: a board delta inside the observed re-map band (here up to
±26% on an unchanged module) is not a verdict; the deterministic isolated
pair decides, and the board guards against gross whole-core regressions.
The A136 loop-buffer rejection (isolated −18%, board +31%) was taken under
the assumption that the board was deterministic; it should be re-measured
with a pair before that candidate is considered closed.

**Retention decisions.**

* `wt_dcache_mem` tree — retained: −26% isolated placed, −36% on the board.
* `g6lc_bp_loop` row-local — retained: −24% isolated placed, −7% board.
* `g6lc_loop_buffer` bounded add — retained: −17% isolated placed (both
  isolated views improve); the board's +4.5% is inside the re-map band.
* `scoreboard` head scan — retained in the **prefix-OR** form: the first
  form used `x & (~x + 1)` for the lowest-set isolate and the board mapped it
  as a carry chain (2.006 → 2.623 ns, +31%); with the A136 ROB's log-depth
  prefix OR (`sb_lowest_set`) the board reads 2.165 ns / 101.2 and the
  isolated pair of exactly the changed cone (registered in/out, 32 entries ×
  2 harts, `fo4-a140-sbhead5`) reads unbuffered 2.233 → 0.643 ns
  and placed 2.655 → 2.552 ns at area 21300 → 20595 µm².
  Equivalence re-proven for the prefix form at the five geometries.
* `branch_unit` carry-free target check — **not retained**: SAT-equal and
  sound, but the module's worst path is the redirect address through the
  adder, so the board is neutral (+0.9%) and there is no isolated pair; the
  RTL is reverted and the change kept as
  `trials/a140-branch-unit-carry-free-target-check.patch` for the frontend's
  late-correction design, where a target compare without the adder's carry
  chain is the point.

Proof record: `dmem-fwd-eq-16-8-8`, `dmem-fwd-eq-8-8-4`, `dmem-fwd-eq-4-4-1`, `dmem-fwd-eq-2-8-8`, `dmem-fwd-eq-1-8-8`, `loop-eq-16-4-1`, `loop-eq-8-1-0`, `loop-eq-32-2-1`, `loop-model-candidate-1`, `loop-model-candidate-17`, `loop-negative`, `lbuf-sbs-8x64-1`, `lbuf-sbs-8x64-17`, `lbuf-sbs-4x32-1`, `lbuf-sbs-4x32-17`, `lbuf-sbs-6x128-1`, `lbuf-sbs-6x128-17`, `lbuf-miter-6`. Whole-core board after
landing: re-measured below when the route completes (the A136 loop-buffer
candidate improved in isolation and lost on the board; this one must be read
there before the gain is claimed for the core).

## A138 — store buffer input stage: functionally proven, rejected on timing

The first true pipeline stage attempted on the board's worst cone
(`core/store_buffer.sv`, 173.0 adjusted FO4), as a config gate
(`CVA6Cfg.StqInputStage`, default 0): the store request, the commit pulse, the
flush, the cancel mask and the program-age anchor captured one cycle before the
speculative-queue permutation, which then reads registers only. The core state
is the unstaged design's state delayed by one cycle; the current cycle's
outputs are derived from the registers — the staged store forwards at its
program-age position, the head a staged commit pops is architectural, entries
the staged flush / cancel remove are masked, `ready_o` / `commit_ready_o` /
`no_st_pending_o` / `store_buffer_empty_o` count the staged items, the RVFI
address and the commit-head assertion follow the head the commit port sees
(the slot after a staged pop or the staged store, whichever is older, skipping
entries the staged mask squashes).

**Functional evidence (`fo4-a138-stq18`)** — a three-instance shift witness
(`tb_sb_stage`: staged RTL; previous RTL fed the staged inputs one cycle late;
previous RTL live), g6lc64_ooo geometry, 300k cycles each:

| run | pushes | commits | cancel cycles | flushes | forwarded bytes | errors |
|---|---:|---:|---:|---:|---:|---:|
| plain seed 1 | 172,439 | 74,442 | 40,308 | 7,005 | 88,348 | **0** |
| plain seed 17 | 172,373 | 74,354 | 40,143 | 6,988 | 89,588 | **0** |
| cbo seed 1 / 5 | 166k | 54k | 41k | 7k | 118k | **0** |

Checked every cycle: queue / pointer / count / commit-queue state equal to the
delayed reference; `req_port_o` identical; every reference-forwarded byte
forwarded with the same value (plain mode: no stall substitution at all);
extra bytes only from the committing head, a commit-queue entry the reference
had already drained, or the cycle after a cancel / flush; the live page-offset
match a superset; readiness and pending flags conservative; the RVFI address
names the entry popped next cycle. A mutant that drops the staged store from
forwarding is caught. With the gate off the live RTL is cycle-exact against the
previous revision (`tb_sb_sbs`, 2 × 400k cycles, 0 mismatches). Six witness
and head-view defects were found and fixed on the way (the commit port can
retire a store that is still staged; squashed entries must not be the head; a
shared random memory handshake let a CBO response coincide with a grant; the
R3a sticky terms are not comparable across the two timings).

**Physical evidence (same Nangate45 flow, no disabled arcs) — rejected:**

| Store buffer (g6lc64_ooo, isolated) | Stage off | Stage on |
|---|---:|---:|
| Placed worst arrival | 3.964 ns | **4.316 ns** (+8.9%) |
| Placed reg→reg | 3.964 ns | 4.316 ns |
| Repaired area | 75340.5 µm² | 81456.1 µm² (+8.1%) |
| Filtered module study | 3.242 ns | 3.655 ns |

The isolated placed baseline shows the worst path was already register-to-
register (the permutation itself), not the input cone the module board's
`any` figure pointed at. Input staging cannot shorten that, and the derived
current-cycle views (two-pass forwarding with age compares against the staged
store, the squash-aware head) add to the paths that remain. The RTL and the
config field are reverted; the complete trial (RTL, config plumbing, witness)
is kept as `trials/a138-store-buffer-input-stage.patch`, and the `stq` review
profile remains in the runner. Lesson recorded in PIPELINING-RT-LEARNING §4a:
measure the *placed* split of the target before choosing an input stage.

## A137 — checkpoint stack: slot-order search rejected; live board flow fix

**Live board after A134–A136 (`timings sta-rtl --remote --map-recipe
streamed`, Nangate45, fanout-filtered unplaced module study, per-module map
content-hashed):** `instr_realign` 119.0 → **50.8** adjusted FO4 (2.547 →
1.088 ns), `g6lc_bp_statcor` 83.7 → **33.7** (1.791 → 0.721 ns), `g6lc_rob`
82.4 → **69.8** (1.764 → 1.493 ns), `multiplier` 118.3 → **97.3** (2.531 →
2.081 ns). The top of the list is unchanged (`store_buffer` 173.0,
`wt_dcache_wbuffer` 132.3, `frontend` 128.2, `g6lc_rename` 125.9); 56 of 73
measured modules remain over budget; budget-equivalent 216 MHz.

**Loop buffer reverted.** The A136 registered-expectation form improved the
placed/repaired pair (1.824 → 1.493 ns) but read **worse on the live board**:
72.3 → 94.9 adjusted FO4 (1.548 → 2.030 ns, 9 cells, ending at the new
expectation register). The new form moves the critical path onto late mux
selects with 64-bit fanout; `repair_design` buffers them in the placed flow,
the unbuffered board does not. The two views disagree, the board is the
acceptance metric, so the RTL is restored to its A135 state and the result
is recorded as a flow-disagreement counterexample: retention needs both the
paired placement and the live board to improve.

The A136 ROB form was carried to `g6lc_bp_ckpt`'s oldest-live search (the
same rotate → lzc → `head + off` shape). Functionally it held: matched-state
equivalence at 1×32×4 (shipped), 2×8×2 and 2×16×4 (2×64×4 did not finish in
15 minutes — inconclusive), the seven directed scenarios and seven randomized
model runs (20k cycles each) with the rotated-reference assertion on, and a
reference mutant reported. Equivalence first exposed that the lzc-based form
reads `head + DEPTH-1` on an empty bank; the candidate reproduced that so the
unused clear-side payload ports stayed identical.

Placement rejected it (`fo4-a137-ckpt5`, same flow, no disabled arcs):

| Checkpoint stack (1×32×4) | Baseline | Candidate |
|---|---:|---:|
| Placed worst arrival | 3.410 ns | 3.348 ns |
| Placed reg→reg | 2.334 ns | **2.715 ns** (+16.3%) |
| Repaired area | 29262.7 µm² | 29070.3 µm² |
| Filtered module study | 2.356 ns | 2.241 ns |

The consumer here needs both the slot (clear-side read) and the ring offset
(`head_d = head_q + off`), so the slot-order form adds a subtraction before
the pointer add and gives back what the removed rotate saved. The ROB only
needed the slot. The file is restored; the profile stays as the counterexample.

The whole-core live board re-measure after A134–A136 first failed in the
flow: the remote yosys script is a bash double-quoted word, and the lean and
hierarchical recipes' `async2sync t:$aldff t:$aldffe` was expanded by the
shell (`set -u`: "aldff: unbound variable"). `bashDoubleQuoted` now escapes
only `<attr>:$<type>` selectors (shell paths such as `$RUN` must still
expand); `test/bash-quoted.test.ts` pins both directions.

## A136 — further worst-arrival modules without interface cycles

The three highest measured cones (`store_buffer` 3.702 ns, `wt_dcache_wbuffer`
2.831 ns, `frontend` 2.744 ns) still need the stateful boundaries of §A132
(input staging with acceptance accounting; a next-line prediction change).
Their earlier bypass trials lost placed timing and remain rejected. This batch
continues down the list with two latency-neutral changes, paired against
`2a5ee192b` on the same Nangate45 flow with no disabled arcs
(`fo4-a136-pair3`, `fo4-a136-rob3`).

**`g6lc_loop_buffer`: registered expectation address.** The lookup and fill
compares read `base_q + cursor<<ALIGN` through a 64-bit adder every cycle.
One register now tracks that sum for the active cursor (capturing and armed
are mutually exclusive; every return to armed passes through the close, which
resets replay), updated from one candidate sum formed off registers in
parallel with the compares. Evidence: six cycle-exact side-by-side runs
(8×64, 4×32, 6×128; 300k cycles each; hits, fills, arms, wraps and flushes
all exercised; the new invariant assertions on), a 6-step output miter from
reset (a 12-step bound did not finish in 25 minutes and is recorded as
inconclusive, not as a pass). A first two-register form failed the fill
invariant in the arm+consume corner and was corrected before measurement.

| Loop buffer | Baseline | Candidate |
|---|---:|---:|
| Placed worst arrival | 1.824 ns | **1.493 ns** (−18.1%) |
| Repaired area | 7411.6 µm² | 8309.6 µm² (+12.1%) |
| Buffers | 185 | 251 |

**`g6lc_rob`: head re-anchor in absolute slot order.** The post-free valid
vector was rotated by the head (a dynamic barrel shift) before an
incrementer-based find-first and a final add. The stops are now formed in slot
order, split at the registered head into two log-depth lowest-set searches,
and the found slot is the head. Exact for power-of-two depth; the rotated walk
stays under `translate_off` as a per-cycle reference assertion. Evidence:
matched-state equivalence at 8/16/32 entries, both directed `tb_g6lc_rob`
scenarios with the reference assertion quiet, and a textual mutant of the
reference that the assertion reports.

| ROB (32 entries, isolated) | Baseline | Candidate |
|---|---:|---:|
| Placed reg→reg | 2.049 ns | **1.568 ns** (−23.5%) |
| Placed worst arrival | 2.049 ns | 1.994 ns (−2.7%; input tid-compare cone remains) |
| Repaired area | 33524.0 µm² | **32855.8 µm²** (−2.0%) |
| Filtered module study | 1.852 ns | 1.301 ns |

Whole-core slang elaboration of the retained RTL passes
(`fo4-a136-final-elab`); both modules' pragma audits have no rejected or
unbound targets. These are pre-CTS module results on an isolated flow; the
whole-core board is not re-measured here and 10 adjusted FO4 remains open.

## A135 — pragma-driven row-local emission on the loop predictor

`core/frontend/g6lc_bp_loop.sv` now carries only a comment:
`// svt-pipe: row-local train index=uidx rows=NR_ENTRIES banks=mem_q:mem_d max-rows=32`.
`sv-timing correct --emit --real-cut-feeds` prepares the per-row form,
reparses it and emits it as `g6lc_bp_loop__svt.sv`; production RTL is unchanged.

| Loop predictor, Nangate45 | Source | sv-timing emitted |
|---|---:|---:|
| Placed worst arrival | 1.911 ns | **1.410 ns** (−26.2%) |
| Placed reg→reg | 1.353 ns | **1.066 ns** |
| Repaired area | 17776.779 µm² | **16551.320 µm²** (−6.9%) |
| Filtered module study | 1.743 ns | 0.856 ns |

Three matched-state equivalence geometries pass; the new independent model
(`verif/tb/core/tb_g6lc_bp_loop_emit.sv`) passes seeds 1/17 on both variants
with identical coverage counts and fails under `+oracle_negative`. Placement
reports no electrical violations and no disabled arcs. At 21.398 ps/FO4 the
emitted placed worst is ~65.9 adjusted FO4: better, not closed. The structural
IR headline stayed at 18.6 FO4 — the gain is visible only in the reparsed emit
and the physical comparison, which is why the tool reports the prepared source
separately from the correction ledger.

## A134 — further control/state files

This batch compares immutable snapshots against `62c00081a`. It retains two
implementations and rejects two others after placement. Interfaces and cycle
latencies are unchanged; the new realigner state is a redundant representation
of an existing carry entry.

### Retained: realigner continuation state

In `core/fetch_B/instr_realign.sv`, an accepted split instruction can start
only at the last available halfword. For the supported power-of-two RVC
geometry its PC is the incoming window's upper address bits concatenated
with the last-halfword offset and the original bit 0. This replaces a late
selected address sum at carry capture.

The same accepted event records `carry_pc + 2` in a per-hart continuation
bank. The next window compares its address against this registered value,
removing the increment from the carry-state feedback path. The invariant is:

```text
carry_valid[h] => carry_next[h] == uint64(carry_pc[h]) + uint64(2)
```

Kill and flush remain inert on both banks. The 64-bit successor preserves the
old distinction between full-width wrap and VLEN<64 overflow; it must not be
truncated back to VLEN. Other geometries and RVC-off use the original path.
The companion bank has a no-cut guard and a simulation-only invariant.

Five surface configurations cover 32/64/128-bit fetch windows, 1/2/4 harts,
32/64-bit virtual addresses, reduced output-slot capacity and RVC disabled.
Each runs 500,000 cycles with no mismatches. The witness now compares the
packet **at the consuming edge**, as well as settled outputs after the edge.
A deliberately truncated successor fails that interface witness even with
RTL assertions disabled (`fo4-a134-realign-final`).

### Retained: statistical-corrector row-local training

`core/frontend/g6lc_bp_statcor.sv` previously selected a counter/tag/valid row,
computed its update, then decoded a write back into the table. Each row now
prepares its own next value and is selected by the update index. This removes
the read-mux → train → write-decode feedback chain. Prediction lookup latency,
tag ownership, saturation, weak-row takeover, strong-owner decay and flush
priority are unchanged.

Matched-state equivalence passes for 64 entries/4 slots/RVC, 8 entries/1 slot/
no RVC, and 24 entries/4 slots (including out-of-range index encodings).
The existing independent counter model passes both slot/RVC variants and its
negative controls. The isolated timing wrapper uses the production geometry:
64 entries, four slots, eight tag bits, VLEN=64 and RVC enabled.

### Physical decisions

Nangate45 paired placement/repair, identical constraints per pair, no disabled
timing arcs, and no reported slew/capacitance/fanout violations:

| Candidate | Worst arrival, ns | Reg→reg, ns | Repaired area, µm² | Decision |
|---|---:|---:|---:|---|
| Realigner continuation state | **2.977 → 2.257** | **2.357 → 1.717** | **3348.940 → 2771.986** | Retain: −24.2% delay, −17.2% area |
| Statistical corrector row-local training | **1.622 → 1.095** | **1.178 → 0.578** | 9543.017 → 10749.061 | Retain: −32.5% delay, +12.6% area |
| Rename indexed map-read bypass | 2.964 → 3.105 | 2.964 → 3.105 | 241050.000 → 241028.453 | Rejected; RTL restored |
| Store-buffer snapshot bypass | 4.086 → 4.801 | 4.086 → 4.801 | 76140.633 → 76630.344 | Rejected; RTL restored |

Using the recorded 21.398 ps calibration, the retained **placed** worst delays
are approximately **105.5 adjusted FO4** for realign and **51.2** for statcor.
These remain pre-CTS, unrouted module studies with negative WNS at the requested
clock, not whole-core timing closure.

The historical fanout-filtered module reading also improves: realign
2.547 → 1.088 ns (119.0 → 50.8 adjusted FO4), and the isolated statcor wrapper
1.548 → 0.773 ns (72.3 → 36.1). Do not substitute those filtered figures for
the placed figures. Rename and store buffer looked better under that filter
but worsened after placement; four rename equivalence configurations and a
400,000-cycle store-buffer comparison passed, so they were rejected for
physical timing, not functionality.

Artifacts are under `build-platform/workspace/build/sv-timing/precompute-a134/`:
`map-a`, `surface-a`, `realign-final`, `place-realign`, `place-rename`,
`place-store`, and `statcor/result`. Replay the archived `inputs.tar.gz` for
the rejected trials; current production RTL intentionally no longer contains
them. The runner's `boundary` and `statcor` profiles capture sources, tests,
recipes, netlist hashes and results.

The pragma audit resolves all three initially changed modules with no unbound
targets. The new cached-state representation is implemented directly in RTL;
it is not a carry-save pair and is not falsely declared as one. The A133
preprocessor still requires a dedicated, validated rule before it can infer
this state transformation automatically.
Whole-core slang elaboration/hierarchy checking of the final retained RTL
passes (`fo4-a134-final-elab`).
The standard `verify --lint --target g6lc64_ooo` gate also passes both checks.
The broader local `verify --lint --synth` attempts (selected OoO target and
default targets) were stopped after their synthesis phase did not finish
within this surface review. They are incomplete, not passes. The configured
`opt -fast` smoke has documented scaling problems on large cores; the isolated
paired synthesis/STA/placement results above completed and are retained separately.

SoC/validation scope: retained behavior is gated by the existing RVC/geometry
and predictor configuration. No new interface, clock, reset, ISA, DTS,
trace-latency or PMU event is introduced. The continuation flops use the existing
clock and asynchronous active-low reset; no RAM was converted to flops.
Power and full-core software regression are outside this surface review.
