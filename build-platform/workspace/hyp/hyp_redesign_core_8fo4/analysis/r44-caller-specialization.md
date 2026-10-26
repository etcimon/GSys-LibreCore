# r44 — caller specialization and latency-preserving timing work

This is the design/evaluation record for the continuation after r43-T and
`hyp8-osbi-l3-r1`. Scope: the hypothetical core, its callers, and its existing
leaf verification flow. Production `core/`, firmware, timing cost tables and
physical constraints are not changed by this work.

The retained implementation is load publication, LSQ role specialization
and small-geometry stage alignment, and dispatch operand-class predecode.
The D-cache frontier experiment and LSQ compact-payload experiment were
implemented, checked and reverted after structural measurement. The
architectural candidates below remain subsequent work.

## 1. Correct the optimization target first

The r5 report is useful evidence about source cones, but its headline is not
a source-pinned clock qualification of the current scalar/L3 profile.

Findings checked directly against the current source:

| Evidence | Consequence |
|---|---|
| `inputs/param-map-hyp8-v2.json` pins `HypCfg.IqSpecWakeup=2`; `core/include/g6lc_hyp_pkg.sv` sets Hyp8 to 0 and requires 0 when `WbReserve` is enabled | Do not evaluate an added issue cycle as absorbed by speculative wakeup. The bank also has a literal-off speculative broadcast arm. |
| `g6lc64_hyp8_config_pkg.sv` has `UseSharedTlb=0`; `build_config_pkg.sv` carries that value through | The shared-TLB module remains instantiated as a miss/update router. Its optional table/flush path cannot be called the active core's limiter merely from its module score. |
| `g6lc_shared_tlb.sv:520` selects the bypass; `:986` gates flush-busy with `UseSharedTlb`; `:1055` gates the SRAMs | Do not exclude the entire module: the bypass still has a consumer. Specialize its two functions. |
| r5 PTW's critical `L759 -> L763` is the raw NAPOT branch inside the `!PDEC` alternative | With `PtwDecodeStage=1`, that particular source chain is not the active verdict. A procedural constant branch can remain in this structural report. |
| r5 rename stages report RR-a 12.1 and RR-b 15.75 FO4 | The earlier 3.5-FO4 register-only row does not describe the whole resolve kernel. |
| `g6lc_iq_arb.sv` declares `absorb ARB by=spec-wakeup`; current Hyp8 disables that mechanism | Carry-over records are obligations to verify, not evidence that latency disappeared. |
| `g6lc_lsq_verdict.sv` declares `window=3`, but publishes through its actual clocked logic | The window is not four free pipeline stages and cannot divide a single-cycle recurrence by four. |

`r44-param-map.json` preserves the v2 screening inputs while correcting
`IqSpecWakeup`, adding the checked issue count, shared-TLB selection,
Svnapot selection and write-buffer/fixup depths. It is a scalar core
screening map, not a complete elaborated parameter dump or an L2/L3 uncore
timing model. Generic child parameters still need per-instance resolution.
Do not overwrite the historical v2 input to manufacture a before/after.

Captured provenance:

- Working-tree base HEAD: `24a81edde4ebecb6152f3b3496229c2453fc4d68`;
  the tree contains extensive uncommitted changes.
- r5 JSON SHA-256:
  `5000230de36a0129dd373128f0f36604a176f2767ca196e12e933653439f6e74`.
- Historical v2 parameter-map SHA-256:
  `e30e2b7952ab5e37a67f63ef45416a353badbadac5b67662739709756112092d`.
- r44 analyzer executable SHA-256:
  `d837e8798a2b34800c2ec13abda21ee69e88d5558e57b9d1085c049057f08a91`.
- Instrument banner: `ir-v5`, `delay-v44`, `correction-v5`,
  parser `v0.13.5`. A matching banner alone does not pin a binary.

The fresh pre-edit screen is
`build-platform/workspace/build/sv-timing/hyp8-src/boards/hyp8-core/analyze-r44-before.json`.
The existing clock script now reports a 54.6-FO4 dispatch maximum, while
still counting the optional shared-TLB cone. That is **not** a measured
hardware regression or a replacement whole-core frequency claim. This
pass compares its own before/after with identical inputs and executable;
it does not subtract r5's headline from a different analysis envelope.

## 2. What carry-over must establish

Use `instances`, `stage_users`, `stage_bubbles`, and `cross_module_paths`
from the analysis JSON to locate a boundary, then inspect the actual ports
and sequential consumers. The historical `source-callers.json` explicitly
contains lexical candidates, including inactive paths; it is not an
elaborated graph. The earlier empty `carry_over.md` also does not account
for hand-written stages.

For each retained change, carry this tuple through every reader:

```
producer acceptance -> represented value + identity -> holding register
                    -> consumer acceptance -> release/cancel
```

Measure producer-to-register, register-to-register and
register-to-consumer separately. A file split provides useful hierarchy,
but only a real register or a different logic structure shortens a cone.

The r5 IQ-to-arbiter bridge, for example, adds child 33.5 to parent 100.7
FO4 across a list containing payload, take and acknowledgement ports.
That is a search lead, not proof that every listed output lies on one
134.2-FO4 combinational path. Trace the particular net to its sink; reject
double counting across a register or addition of unrelated maxima.

Current implementation boundaries:

| Kernel | Actual caller | Consumer contract |
|---|---|---|
| D-cache byte forwarding | `wt_dcache.sv:541`, `i_wt_dcache_mem`/memory instance | Registered hit/data/user/forward verdict reaches the matching read controller at the existing `DcacheHitExtra=2` response edge. |
| Load publication | `load_store_unit.sv:811`, `i_load_unit` | One selected TID/result/exception is published; slot release and tombstone draining retain their original cycle and priority. |
| LSQ forwarding reduction | `g6lc_lsq.sv:841,895`, `i_stl_red`, `i_q_red` | Data plus wait/data-wait mask pairs with the corresponding delayed load event. |
| LSQ violation reduction | `g6lc_lsq.sv:864`, `i_vio_red` | Oldest violating TID/distance/PC pairs with the store event; wait outputs are unconnected. |
| LSQ verdict | `g6lc_lsq.sv:955`, `i_verdict` | Cancellation, generation/lifetime and final-check bookkeeping remain authoritative before load publication. |

Line anchors refer to the start-of-pass source; use the named instances
after edits move lines.

## 3. Implemented experiments and retention decisions

### D-cache: capture a reduction frontier, not the fully merged word

The A140 left-valid-wins byte merge is associative, but not commutative.
The r38 repair established the important representation rule: data and
user bytes must cross T1 with the decision that selected them. Fixup
exports can pop or change position before T2.

Current shape:

```
T1: word comparisons -> complete ordered byte tree -> merged word register
T2: registered way/refill selection + byte overlay -> response register
```

Candidate implemented and then reverted in this batch:

```
T1: word comparisons -> lower byte-tree levels -> partial {valid,data,user}
T2: upper ordered tree + way/refill selection + overlay -> same response edge
```

Use `ceil(log2(padded_depth)/2)` lower levels and preserve contiguous
groups and left priority. The configured raw depth is 19
(`8+2+8+1`), padded to 32: five merge levels become three before T1 and
two after it. This is a structural partition count, not a predicted FO4.
The extra registers hold four partial byte tuples per lane instead of one
final tuple; assess the area/fanout tradeoff with the measured cones.

The experiment kept the `DcacheHitExtra=0` full reduction and existing mutants intact.
No new request latency, ready gate, ownership credit or global HypCfg
field is needed. The partial representation is entirely internal to the
existing +2 implementation.

Reject if the new T2 upper-tree/overlay exceeds the previous limiting
stage without a compensating reduction in the relevant caller path.
Never substitute an OR of possibly overlapping byte sources for the
priority rule. Check data **and user**, partial bytes, group boundaries,
T1 capture followed by export removal, and the original response edge.

**Result:** source-screen reg-to-reg 33.346 -> 34.046 FO4, with the
37.6-FO4 input path unchanged. The +2 leaf and full-T1 rollback control
passed, but the structural target did not improve. The original RTL is
restored exactly. The frontier implementation is archived with its
passing evidence; the new cross-group/data/user/reuse cases remain in
the existing bench.

### Load: select the publication record directly

The current L5 chain has a priority mask, serial index OR, indexed
metadata/response/forward reads, and then an overlay. This is avoidable
encode-then-decode work on a result publication path.

Prepare each slot's merged word locally. The first attempt carried
`{valid,index,metadata,merged_word}` through a first-valid heap. It passed
the leaf but raised the L5 screen from 34.65 to 38.3 FO4.

The retained form computes independent priority masks:

```systemverilog
first[j] = eligible[j] && !(|eligible[j-1:0]); // j==0 is eligible[0]
select[0] = first[0] || !(|eligible);
select[j] = first[j];                        // j>0
```

The publication index uses `first`; the payload uses `select`, preserving
the empty default. Balanced OR trees gather the gated indices and
`{metadata,merged_word}` leaves. Therefore:

- lowest eligible slot wins;
- no eligible slot preserves slot 0's default payload/index;
- payload and index are selected together;
- no pipeline cycle is added.

The separate drain mask/gather carries only the selected index. Leave the existing
exception, speculative-miss and direct store-forward overrides in their
original order. In particular, an override of writeback does not grant
permission to change an independently computed buffer-release side effect.

**Result:** L5 reg-to-output 34.65 -> 30.25 FO4. The 36.15-FO4 request
path into L2 and the 19.35-FO4 ordinary reg-to-reg path are unchanged.
There is no additional publication cycle and no module-maximum claim.

### LSQ: specialize by role and carry local winners

Forwarding and violation selection share an ordering primitive but have
different output obligations. Add a default-on `TRACK_WAIT` leaf parameter;
disable it only on `i_vio_red`, whose wait/data-wait outputs are unconnected.
In the forwarding specialization, compute each destination wait-mask bit
as a reduction of matching input TIDs, rather than a sequence of dynamic
bit writes. Duplicate TIDs must still set exactly one mask bit.

The first timing experiment captured one payload/ID per lower-tree
subtree at R1. R2 gathers among those frontier winners rather than all
original leaf payloads. Payload selection inside R1 must use a bounded
local array, not a global index whose constant high bits are merely assumed
to fold. Valid, distance, full slot identity, wait and event alignment
travel with the same edge.

This differs from the earlier full payload-carry tournament: wide data
does not traverse every comparison node. The trade is one local gather
before R1 against a smaller gather and fewer payload registers after R1.
The measured trade was unfavorable: input-to-register 22.1 -> 37.2,
reg-to-reg 29.9 -> 62.65 FO4. The compact payload gather is reverted;
R1 again snapshots every leaf's payload/ID. The retained wait
specialization and row-local decoder leave the reducer maximum at 29.9.
No tournament timing improvement is claimed.

Fix the adjacent geometry contract while changing the frontier:
`LsqReduceStages=2` must mean two output edges even for one, two or three
leaves. The old reducer disabled its second stage when `FBASE<2`, while
the wrapper extended event context based on the configuration alone.
Use a nonzero slot width and an explicit singleton frontier. The wrapper
must never pair a one-edge result with a two-edge event.

### Dispatch: cache operand classes with the held issue record

The corrected pre-edit screen exposed a 54.6-FO4 ISS path in
`g6lc_ooo_dispatch::gen_op_asm`. The FP/integer selection re-evaluated
`is_rs1_fpr`/`is_rs2_fpr` from the registered operation in front of the
operand mux; the third operand had the analogous `is_imm_fpr` predicate.

Capture three exact predicates with `iss_sbe_q` and `iss_fpsel_q` on
`iqi_take`, in the same existing register stage:

```systemverilog
iss_fpa_q[p] <= G6LCCfg.FpPresent && fp_port_sel[p] &&
                iqi_sbe[p].ooo_renamed && is_rs1_fpr(iqi_sbe[p].op);
```

The other two use `is_rs2_fpr` and `is_imm_fpr`. They hold whenever
the issue record holds, including a valid-only clear on pop, flush or
cancel. Operand-class selection reads these registered bits; live WB
matches, cancellation, acceptance and shared-FPRF ownership are unchanged.
An invariant compares all three bits against the original held-record
expressions every cycle, including invalid held records.

**Result:** reported module envelope 54.6 -> 48.3 FO4. The internal
ISS maximum falls 54.6 -> 27.0, but the new limiting into-ISS path is
48.3 (previously 24.15), so 27.0 is **not** the module result. Maximum
input-to-register rises 9.2 -> 9.55 and maximum reg-to-reg rises
22.3 -> 23.35. The change adds three bits per lane at an existing edge,
with zero added instruction cycles. This is the safe state-derived
predecode case; no predicate over a future live request is cached.

## 4. Subsequent specializations, in priority order

These designs remain candidates after the bounded batch above.
The r45 continuation implements the disabled shared-TLB router and
local TLB flush predicates, plus load PA-capture simplification;
its separate measurements and verification are recorded in
`r45-mmu-request-specialization.md`.

| Priority | Split / transformation | Expected latency effect | Decisive check |
|---|---|---|---|
| 1 | `g6lc_shared_tlb` wrapper selects a small `g6lc_tlb_miss_router` or the enabled table implementation with a generate condition | None for the bypass; no new field beyond `UseSharedTlb` | Same miss arbitration, captured owner, PTW-return routing and flush outputs. Show which logic is actually removed, rather than excluding the entire module from a report. |
| 2 | PTW separates raw response capture, S-mode PTE decode and optional H-extension step logic; place the `PtwDecodeStage` choice at a structural boundary | Keep present walk latency first; evaluate removal of the extra decode edge only after both implementations are measured | All fault priorities, leaf/superpage/NAPOT cases, context retention, late return after kill; prove the reported path belongs to the active specialization. |
| 3 | TLB separates row-local tag validity update/flush from lookup selection; predecode page-match geometry when installing an entry | No added lookup cycle | Same-edge fill/flush precedence, ASID/global rules and page-size/NAPOT matching. Do not cache a predicate involving the *live request* without that request's identity. |
| 4 | IQ real-writeback-only bank specialization, then separate candidate ordering from live acceptance/presentation | No added wakeup/issue cycle in the first pass | Preserve pending allocation wakeup, cancellation, owned-TID exclusion, ready/ack stability and FU reservations. Existing `cand_q`/`win_s` edges must not be counted twice. |
| 5 | Rename maps/checkpoints use row-local updates and late row selection; isolate normal publication from recovery | No added normal publication cycle | Preserve high-port WAW precedence, commit-before-flush architectural map, reserve/free/WB priority and per-hart repair. |
| 6 | FTQ provides a held-head identity token for loop-buffer revalidation, replacing a repeated full-PC comparison | No extra consume cycle if a token is already available at the head | Token changes on pop/reseed/flush/hart transition; bounded reuse/epoch wrap. An address comparator cannot be removed on faith that a head never changes. |
| 7 | ALU specializations follow `HasBranch` and caller-observable forwarding outputs; group operation families while keeping local exclusive muxes | Preserve low/full result distances and bypass availability | Primary versus secondary ALU, RV32/RV64, bit manipulation, stalled consumers and every exported partial-value tap. Do not repeat the flat all-operation AND-OR countercase. |

Use new files where they separate these functions and caller contracts.
For example, a shared-TLB router/table split is useful even when synthesis
already removes much of the table, because the active implementation and
measurement become explicit. File extraction alone earns no speed credit.
Any new file enters all three hyp8 core/APU/simulation manifests.

For an enabled shared TLB, an extra flush-match stage is a separate,
slow-operation design: READ -> MATCH -> APPLY, with a captured set index,
match bits and flush context, and busy held through the final write.
Its cost is more SFENCE service cycles rather than every load hit. The
current disabled-table profile should not pay that complexity.

## 5. Latency and windows are measured from an accepted event

For a dependent operation with latency `L` and clock period `T`, elapsed
latency is `L*T`. A stage addition is favorable for that chain only if

```
(L + added_cycles) * new_period < L * old_period.
```

For useful retirement throughput, compare `IPC * frequency`, and for
admission-limited paths also compare initiation interval. A local timing
improvement below the global limiting stage does not raise frequency.
With unchanged frequency, any added dependence cycle is a direct cost.

Rename currently serializes group admission with `grp_pend_q` plus the held
group's valid bits. Increasing resolve depth can therefore extend the
group initiation interval, not only an individual dependency. Two
alternatives deserve separate evaluation:

1. A serialized two-lane resolver specializing to the one in-group older
   producer, after proving that previous-group producers cannot be needed
   at capture in **all** recovery/stall cases.
2. A genuinely overlapped rename admission pipeline with explicit reserved
   output-group capacity and full producer-window coverage.

Do not combine them: the first exploits serialization to reduce depth;
the second removes serialization and requires the general bypass network.
The earlier zero-multihit mini census is useful evidence, not a universal
proof for wider issue or changed admission.

For loads, measure from the same accepted request:

```
publication_time =
  max(data_ready, forward_ready, final_order_verdict, permission_ready)
  + publication_service.
```

A later LSQ result is hidden only on transactions where some other term
still dominates. TLB hits, store-forward hits and fast cache hits may expose
it immediately. A declared stage window does not establish those arrival
times.

A longer protocol can permit a multi-cycle operation while each internal
recurrence still must meet one clock. Neither rare SFENCE execution nor
serialized AES issue permits dividing its combinational register path by
the instruction's total occupancy without an actual capture/hold contract.

## 6. Transfer working mechanisms, including their counterexamples

- A118/A120: prepare alternatives before a late select; preserve widths,
  priority and modulo arithmetic. Apply to selected payloads and local
  updates before adding a stage.
- A119/A140: stable tournaments and associative ordered reductions. Preserve
  tie order and carry the complete represented value at a cut.
- A134/A135: row-local table update and state-derived predecode. The useful
  discriminator is removing an indexed read before a write decode, not
  merely changing a procedural block into assigns.
- A138: input staging did not improve a critical internal recurrence and
  added derived-view logic. Do not repeat it on the load-unit FSM.
- A141: stationary slots and age relationships removed a moving permutation.
  Hyp8 store buffering already uses this structure; another file split or
  input register does not repeat the original gain.
- A146/A148 and `PIPELINING-RT-LEARNING.md`: preserve dependencies, source
  specialization, representation lifetime and every consumer. Estimated cut
  counts and structural classifications are not physical timing closure.

Two additional deductions for this tree:

**Register the reduction frontier.** A compact tuple per subtree can retain
the information needed by the consumer while sharing work across an existing
edge. This is the D-cache and LSQ experiment, with explicit area and opposite-
stage timing checks. Both r44 frontier variants passed their targeted
functional checks but lost the structural comparison; neither is enabled.

**Specialize by output obligation.** A violation detector needs identity/PC;
a forwarding detector needs bytes and wait masks; a disabled shared TLB needs
request/return routing. Use those differences to remove unnecessary live
work. Check the actual caller before assuming an output is unused.

## 7. Efficient acceptance procedure

One bounded batch, source snapshots before edits, one before/after analysis
recipe, and the narrow existing memory/D-cache/LSQ leaves. Extend those
benches with distinctive payloads, priority ties, flush and reuse cases.
Preserve the independent pre-change expression or scalar selection model;
a mismatch is investigated before a reference changes.

Check the public cycle count from the test input, not from the DUT's
internal stage-enable expression. This is what catches the small-N LSQ
alignment defect. Ensure valid antecedents actually occur.

Run full-top lint for scalar, SMT2 and L3 once for the accepted aggregate.
Broader compliance, synthesis/placement, firmware and Linux remain later
gates; this pass does not turn earlier failed boots into passing evidence.
The recent write-buffer diagnostic exemptions also mean the old count of
plain drops cannot be equated with a count of lost writes. The L3 store
liveness stop and a write-buffer cause need a causal discriminator.

Before retaining a timing candidate:

1. Compare its particular before/after boundaries under the same binary,
   inputs and analysis mode.
2. Inspect all changed consumers and the newly limiting stage.
3. Reject a measured regression on the relevant path, or label the result
   unresolved if model attribution cannot distinguish it.
4. Keep exact behavior/cycle evidence separate from screening and from
   eventual physical timing.

## 8. Execution results

Paired source screens use the same r44 input map, width map, executable
and `--all-modules --stages` mode; `fo4_ps=20`, margin `0.2`, target
5000 MHz. Numbers are structural, not calibrated/placed delay.

| Surface | Before | Retained | Interpretation |
|---|---:|---:|---|
| Dispatch module envelope | 54.60 | 48.30 | Lower maximum, work moved to the capture/entry cone; no new instruction cycle. |
| Dispatch in-stage ISS | 54.60 | 27.00 | Must be read with its 48.30 into-stage maximum. |
| Load L5 reg-to-output | 34.65 | 30.25 | Shorter publication; lowest-slot/default/override semantics preserved. |
| Load request into L2 | 36.15 | 36.15 | Still limits the load module. |
| LSQ reduce maximum | 29.90 | 29.90 | Retained for role specialization and the small-N alignment repair. |
| D-cache memory reg-to-reg | 33.346 | 33.346 | Original RTL restored after the failed frontier timing experiment. |

Artifacts beneath `build-platform/workspace/build/sv-timing/hyp8-src/`:

- `boards/hyp8-core/analyze-r44-before.{json,log}`: pre-edit source.
- `boards/hyp8-core/analyze-r44-after.{json,log}`: rejected first aggregate.
- `boards/hyp8-core/analyze-r44-refined.{json,log}`: refined load/LSQ,
  original D-cache and dispatch.
- `boards/hyp8-core/analyze-r44-dispatch.{json,log}`: retained functional
  aggregate including dispatch class capture.

Frozen pre-edit sources and rejected candidates are under
`C:/Users/etcim/cva6-artifacts/r44/{pre,candidates}/`; tests and closures are
identified in `implementation-log.md`. No new RTL files or manifest entries
were needed for the retained batch.

Final refined-source verification through the remote hyp8 leaf runner:

| Leaf / gate | Result | Scope |
|---|---|---|
| Memory | `HYP8_MEMORY_PASS checked=120` | Publication order, next-cycle successor, default slot, partial forwarding, tombstone draining and existing exception cases. |
| LSQ | `HYP8_LSQ_PASS checked=2018` | Existing integration cases plus ten selected reducer configurations; this is not a Cartesian sweep of all parameters. |
| D-cache +2 | `HYP8_DCACHE_PASS checked=290` | Restored memory implementation plus cross-group priority, data/user overlay and snapshot/reuse cases. |
| Dispatch | `HYP8_DISPATCH_PASS checked=115 pop_take_same=0` | Integer/FP operands, held class predicates, partial-flush reoffer and full-flush kill. |
| Full-top lint | Scalar/SMT2/L3: rc=0, zero `%Error` | Existing vendor latch warnings remain; this is not synthesis or physical closure. |

Run tags are `hyp8-r44f-memory`, `hyp8-r44f-lsq`,
`hyp8-r44f-dcache`, `hyp8-r44f-dispatch-r2`, and `hyp8-r44f-lint`.
The dispatch r1 result is superseded: review found raw test TIDs beyond
the 32-entry scoreboard while the DUT used truncated five-bit IDs. The
test now uses legal IDs and range-checks the oracle's array index.
The check count includes those new range assertions; it is not a count
of retired instructions or unique scenarios.

Simultaneous same-lane pop/take was not observed in the dispatch leaf;
no coverage claim is made for that coincidence. The local state-cache
invariant remains active across every sampled lane record.

The earlier live-T2 payload mutation failed the existing fixup-window
check. The +0 D-cache leaf fails `D_NO_PMU_PULSE` with both the candidate
and pre-edit memory module; that pre-existing failure is retained as
incomplete +0 qualification and was not repeatedly rerun.

The final diff was reviewed against frozen pre-r44 copies, not just
repository HEAD. Existing per-file licensing and notices are preserved.
No OpenSBI/Linux witness, synthesis, OpenROAD or physical-frequency claim
is part of this pass.
