# r96 — Caller-qualified module tasks

These 31 cards refine the corresponding H95 entries; the other entries in the
223-module queue remain open. This is an analysis pass, not accepted RTL or
timing closure. `cones.json` retains the four highest paths plus the maximum
of **every path kind** for each selected module, node costs, source locations,
width/defaulting flags, and the analyzer's relocation cards.

Paths below are relative to the Hyp trees: **C** =
`hyp_redesign_core_8fo4/core/`, **A** =
`hyp_redesign_corev_apu_8fo4/corev_apu/`. Numbers are the unchanged delay-v49
screen (20 ps/FO4, margin 0.2, budget 8), with qualification limits stated
per card. An inactive or misrepresented path does not receive RTL priority.

## Execution order and decision rules

1. Repair/qualify measurement boundaries in M96 below. This can run beside
   design work on clearly identifiable control cones.
2. First prospective RTL batch: FLU admission, PMP write decode, LSQ credit
   reductions, and MSHR per-entry updates. These offer bounded transformations
   without a new external cycle. Implement one coherent batch only after
   the exact owner equations and all connecting widths are settled.
3. Next: decoder legality selection and AI span completion/terminal facts.
   These have existing records/windows but nontrivial priority or join rules.
4. Then: cache collector/admission separation, FMA arithmetic stages,
   GEMM normalization, and the residual floating-dot reduction.
5. New architectural cycles come last. State both dependency latency and
   service interval, occupancy, completion-port conflicts and reconvergence.
   Do not derive an implementation by dividing a raw FO4 row by eight.

Use source/IR comparison and one focused discriminator for each changed
invariant before a consolidated integration gate. No new regression campaign
was started for these cards. New stages require actual state, full operation
records and caller integration; file extraction by itself creates no slack.

Prior pattern basis:

- **A20/A33:** dependency-based parallel timing and relocation alternatives.
  T0 qualification precedes T1 restructuring and any architectural retiming.
- **r94:** parallel age-column selection; grouped exponent minima moved
  into an existing product window. Rejected sinkless coherence counters.
- **r90–r93:** exact signed arithmetic, width proofs, publication factoring,
  and rejected wide publication/slice variants. Do not repeat them blindly.
- **A132:** tile → carry-save reduction → final addition, preserving both
  rows and all reconverging results/metadata. Its physical results belong
  to the recorded production multiplier experiment, not these Hyp paths.
- **A134/A135:** cache state-derived facts at their update edge; compute
  small per-row updates before late selection. The automatic row-local
  pragma has a narrower envelope than several tasks below.
- **A136–A140:** absolute-slot search and prefix-OR isolation; rejected
  address-caching and offset-reconstruction variants are counterexamples.
- **A138/A141:** a whole-input shift can leave an internal permutation
  unchanged; stationary slots/age matrices help only with stable ordering
  and complete removal/forwarding rules.

The full `sv-timing/architecture/PIPELINING-RT-LEARNING.md` was read for this
pass. Supported representation pragmas do not automatically handle these
arrays, state machines, local functions or backpressured interfaces.

## M96 — Measurement tasks before timing credit

- [ ] **M96-FMA-REG:** the explicitly bound FMA reports contain
  `sum -> mid_pipe_sum_q[0] -> sum_q` in one dependency path, although
  `NUM_MID_REGS=3` and FFL macros capture elements 1–3. Preserve element
  identity and macro-expanded sequential boundaries in initial IR. Start
  with a package-local fixture contrasting zero and three middle registers.
  The 133.26/142.72 FP32/FP64 rows are **not** combinational timing claims.
  Their product widths are now correctly 48/106; the old generic row had
  width=1/defaulted and a 56-FO4 product estimate.
- [ ] **M96-GEN:** explicit PF_TAG=0 still leaves the disabled `gen_pf`
  update in the L3 tag maximum. Audit generate-arm reachability before
  optimizing it. Also audit rename's two-bank, two-port exclusion: different
  banks cannot contribute `taken_lt` to one another, regardless of a raw
  module path through the common procedural loop.
- [ ] **M96-GUARD:** audit guard compatibility and NBA/reset scope on
  FLU, L2 state-update and invalidation paths. The L2 maximum crosses a
  `wr_b_done_d=0` write in S_IDLE into a consumer gated by S_BYPASS_B.
  That particular assignment-to-consumer chain is not sensitizable.
- [ ] **M96-BIND:** maintain separate child-instance maps. The old
  core-all map is a 75-key partial map, not hierarchical elaboration.
  FMA format/pipe parameters, rename FP/bank/checkpoint dimensions and
  tag geometry required additional caller bindings. Extend this audit to
  the remaining parameter-only leaves before calling them clock limiters.
- [ ] **M96-SINK:** exclude reset aggregates, reference arithmetic and
  sinkless counters from optimization priority while retaining their raw
  evidence. Find the largest *observable* alternative path.
- [ ] **M96-LOAD:** retain the current load law for comparable screens.
  Wide select/broadcast costs can exceed eight by themselves. A repaired
  fanout model needs independent calibration evidence; never tune it to
  make this worklist green.

The analyzer's cards are suggestions. In particular, a generic
`t3_hot_arm_multicycle` / “opcode arm” card on an MSHR, coherence hub or APB
read mux is not a valid protocol redesign. `expected_fo4_after=8` is not
emitted evidence. P10 same-edge handshake/index locks must survive review.

## H96-fpnew_fma

State: measurement-blocked; concrete arithmetic strategy available.

**File/callers:** C `cvfpu/src/fpnew_fma.sv`; fpu_wrap → fpnew_top →
opgroup_block → fmt_slice. RVF/RVD and PARALLEL ADDMUL select FP32/FP64;
NumPipeRegs=8, DISTRIBUTED. See M96-FMA-REG before using any maximum.

**Cone/strategy:** product(:482), aligned addend, sum(:525–534), followed
by the existing middle-pipeline boundary. First evaluate capturing the
2p-bit product in `p_fma_exp_mant`, instead of two p-bit operands, while
the exponent stage computes its independent result. Capture bounded
addend shift amount there if that stage still has room. This transfers
r94's existing-window precompute without adding a cycle. If multiplication
alone dominates, use A132 partial tiles and coupled sum/carry rows across
the existing middle-stage capacity; mere operand-capture registers do not
divide the multiply.

**Owner/exit:** exp/raw ready-valid enables, flush, reg_ena, tag, mask,
aux, special result/status, sign/subtraction, rounding and sticky data must
travel together. Count actual edges in this already-rewritten Hyp FMA,
not just NumPipeRegs. Possible functional files are product/align,
sum representation, and normalize/round, with the current wrapper retaining
protocol ownership. Check both formats, special values and blocked output;
require lower maximum across pre/post-boundary paths, not a renamed path.

## H96-fpnew_fma_multi

State: inactive for scalar Hyp ADDMUL; defer RTL.

**File/caller:** C `cvfpu/src/fpnew_fma_multi.sv`, multifmt_slice. The raw
72.50 row is not selected by fpu_wrap's PARALLEL ADDMUL policy.
Retain an alternate MERGED-format task only for a caller that enables it.
Its product/shift/sum can reuse the FMA arithmetic mechanism after format
mask, widening, tag and vector-lane contracts are bound. No scalar timing
credit follows from changing this module.

## H96-norm_div_sqrt_mvp

State: conditional live DIVSQRT path; binding/boundary audit first.

**File/caller:** C `cvfpu/src/fpu_div_sqrt_mvp/hdl/norm_div_sqrt_mvp.sv`,
through div_sqrt_top_mvp. Reported 60.30 follows normalization shift
(:353) → upper mantissa → rounding → format/result selection(:460).

Prepare rounding/format alternatives independently, then select late;
separate normalization from rounding only at the divider's existing
terminal-result window. Carry format, exponent, sign, rounding mode,
exceptions and owning tag through that window. A stage inside an iterative
digit recurrence changes iteration time and unit occupancy; it is not an
ordinary feed-forward cut. Minimal future check: format-boundary and
subnormal results with held completion, plus exact done/ready behavior.

## H96-g6lc_flu_reserve

State: first control-restructure candidate.

**File/caller:** C `ooo/g6lc_flu_reserve.sv:80–160`,
issue_read_operands:1699–1750. Raw 67.45 follows ALU2 classification →
latency selection → divider classification → serial port admission.
ALU and MULT predicates on part of that path are mutually exclusive.

Replace dynamic integer offsets with elaboration-constant class masks.
For each fixed offer, test registered occupancy independently; remove
earlier eligible same-offset offers with a parallel conflict matrix.
A divider is eligible only with no live divider/occupied window and no
earlier eligible resource claimant; a winning divider excludes later fixed
offers. An earlier rejected offer must not block a later eligible one.
This transfers r94's “independent candidate + older mask” mechanism,
not its numeric result. Direct opcode classification also removes the
ALU2-to-divider dependency.

Only **final accepts** update reservations. Preserve offset
`1 + ooo_flu_cycles` (IRO capture plus execution/publication distance),
WbCaptureStages, matching-TID divider release and cancel/reclaim.
Do not add accept→admit feedback or reclaim on speculative ready.
Check ALU2 capability versus NrALUs/SuperscalarEn for every supported width.
Future discriminator: exhaustive small-window priority decisions against
the original scan, then existing held-IRO acceptance/ownership coverage.

## H96-csr_regfile

State: first control-restructure candidate.

**File/caller:** C `csr_regfile.sv:3018–3022,3517,6592`, smt_csr_bank.
59.47 follows address conversion → pmp_index subtraction → dynamic
current/next-entry lock lookup → selected PMP write → next-state mux.
This is synthesizable code; the reference block starts at :3980.
Scalar target implements eight PMP entries.

Use bounded per-entry address decode and constant-index lock predicates,
then parallel row-local updates. A135's “compute before late selection”
applies to this small register table; its automatic single-index pragma
does not cover the neighbor read without additional design work.
Do not naively replace subtraction by low address bits: the architectural
PMPADDR base is not aligned to a 64-entry low-bit slice.

Keep CSRRW/RS/RC data, request owner/hart, legality, readonly entries,
granularity and reset constants. Handle the final-entry TOR neighbor
explicitly and preserve unimplemented-entry behavior. No cycle is added
before the architectural apply event. A later extracted PMP write helper
is a purpose boundary, not permission to delay protection changes.

## H96-store_unit

State: exact wiring candidate before any new stage.

**File/caller:** C `store_unit.sv:544–575`, load_store_unit.
58.00 is endian selection followed by data_align and AMO/CBO selection.
r42 already identified alignment as the residual; repeating a cosmetic
case rewrite is not a strategy.

Evaluate per-byte static source selection combining endian permutation
with the eight legal byte offsets, avoiding two serial wide selects.
Keep byte enables, transfer size, AMO passthrough and CBO.ZERO distinct.
If a cut is still needed, align from the retained accepted store record
in an existing translation/queue window; inspect every downstream store,
cancel and exception consumer before moving it. Preserve data/BE/op/VA/
TID/hart/epoch and post-commit lifetime. A138 warns that staging all inputs
can leave the true internal path unchanged. Check sizes/endian/offsets and
cancel-before-grant; do not infer an RV32 result from the RV64-only merge.

## H96-serdiv

State: recurrence-sensitive; prioritize state-specific factoring.

**File/caller:** C `serdiv.sv:188–205,311`, mult.
55.30 includes extended subtract, NORM-versus-DIVIDE selection and
remainder update. r90 already replaced the carry-select implementation
with one WIDTH+1 subtract and fixed the high-divisor bug.

Separate initial sign normalization from the steady digit-update
expression; prepare the initial negation from the captured operand in its
existing normalization window. Keep the borrow/zero facts from the same
extended subtract. Do not retry the rejected two-subtract/borrow-mux form.
Registering inside the digit recurrence changes quotient progression and
divider occupancy; any radix/lookahead alternative is a separate
architectural task. Preserve signed overflow, divide-by-zero, high-bit
unsigned divisors, word operations, cancel and held result identity.

## H96-g6lc_decode_s3

State: parallel legality-selection candidate.

**File/callers:** C `g6lc_decode_s3.sv:161–299,392`, decoder/id_stage.
51.97 traverses sys_f000 → MRET legality → illA/B/C/D → final exception.

Derive mutually exclusive opcode-class results in parallel and choose
the final legality once. Preserve the SFENCE/HFENCE **replace/clear**
semantics before later set-only conditions; replacing illA…illD by an
unconditional OR would be wrong. Treat virtual traps, CBO demotion,
pre-existing exception priority and opfix as one result tuple.
Move only static instruction classification into D1/D2; privilege,
virtualization and CSR context must still belong to the same instruction.
Use existing source/reference decode comparison for the relevant legality
truth table, including feature-off and scalar/SMT contexts.

## H96-g6lc_rename_read

State: caller-bound screen obtained; generate/width audit remains.

**File/callers:** C `ooo/g6lc_rename_read.sv:112–285`, rename → dispatch.
Generic 51.00 omitted FP storage and used FL_BANKS=1/CKPT_DEPTH=8.
The scalar caller has 72 integer and 72 FP entries, 7-bit tags, two banks,
two ports, one hart and 32 checkpoints; its screen is 53.00.

Prefix-OR isolation and low/high picks already exist. Do not propose
replacing a carry-chain isolate that is no longer present. For two ports
on two banks, prior-lane exclusion is zero. Evaluate compact per-bank
vectors and elaborated low/high direction, then retain one-hot picks until
the actual tag consumer. For wider issue, derive independent kth-free
choices per bank instead of repeatedly clearing a shared bitmap; preserve
the established low/high tie policy and bank-starvation behavior.

Reservations happen at R1 capture and return once on kill. R2/R3 bypass,
checkpoint ownership, recovery, FP x0 distinction and current-busy lookup
at IQ allocation remain mandatory. A137 warns against reconstructing an
offset after searching if the consumer still needs that offset.

## H96-load_unit

State: cancellation/publication composition audit before retiming.

**File/caller:** C `load_unit.sv:973–979,1462–1587,486`, load_store_unit.
47.05 is kill_send → kill_req_w → exception publication → arbitration →
selected slot valid update. The r90 live-slot rewrite is already present.

Separate per-slot completion eligibility from a single owner-preserving
publication election; retain a one-hot selected slot for slot updates
where it avoids encode/decode. Reuse the existing pending publication and
StoreFwdCycles windows before adding another response stage.
Every killed/exception/data/drain alternative must preserve slot generation,
transaction ID, cache-response ownership and LSQ checked/forward facts.
r30/r84/r90 demonstrate why a fault must not await faulting data and why a
new-slot allocator must not contaminate an older exception slot's liveness.
Future discriminator is the existing cancel/fault memory leaf plus one
new invariant, not another unrelated firmware run.

## H96-g6lc_loop_buffer

State: input-dependent fill-match candidate; prior address cache already exists.

**File/caller:** C `frontend/g6lc_loop_buffer.sv:209–324`, frontend.
46.91 follows fill-low carry → fill_accept → capturing state.
pc_cur_q already accelerates replay lookup; do not rediscover it.

Review the fill cursor's state-only next address/high-carry facts at each
cursor update, keeping the *current* fill address/epoch comparison late.
Compare narrow carry/high alternatives against a full cached address.
A134 supports state-only precompute; A137's reverted full-address scheme
shows that a late wide mux can erase the gain. Preserve same-cycle arm/
consume, reseed, wrap and held-hit identity. No extra lookup bubble or
stale block injection is acceptable.

## H96-g6lc_ai_exec

State: alternate enabled-CVXIF task; excluded from scalar core priority.

**File/caller:** C `cvxif_g6lc_ai/g6lc_ai_exec.sv`, ai_coprocessor.
45.60 one-cycle workbench path: partial-product rows → per-byte product →
DOT4A sum → publication. r92 Baugh–Wooley/narrow-sum and r93 static
publication choices are already applied.

Trial a global carry-save reduction that combines lane rows and the
DOT4A accumulator before final carry propagation, with the exact opcode
signedness/range and 32-bit wrap contract. A132 is an arithmetic analogue,
not permission to change one-cycle DOT4. The analyzer already models
multi-operand addition as reduction plus final add; an explicit compressor
tree must beat that baseline, not its algorithm name. Preserve all result
alternatives, metadata and consecutive mixed-opcode throughput. Do not
assume the coprocessor wrapper implements general result backpressure.

## H96-wt_dcache_wbuffer

State: lifetime-sensitive fixup update candidate.

**File/callers:** C `cache_subsystem/wt_dcache_wbuffer.sv:774–1084`,
WT cache/miss/AXI paths. 44.89 crosses occupancy, first matching snapshot,
coalescence/allocation and per-entry byte update.

Absolute-slot search and prefix isolation are already present (A144
comments). Start from their selected one-hot mask and parallel per-slot
update predicates instead of re-encoding/re-decoding selection. A135/A141
can inform state layout, but the pending-byte snapshot is part of the
accepted write's lifetime. Late old returns must not clear new bytes;
popped fixups must not be read later to reconstruct merged data.
Preserve held AXI payload, version/BE/data identity and drain visibility.
Do not repeat A138's rejected blanket input-stage approach.

## H96-g6lc_lsq

State: first credit-reduction candidate.

**File/callers:** C `ooo/g6lc_lsq.sv:343–355`, dispatch.
36.80 is an independent bundle containing load/store free-count loops;
the two counts are parallel, not a serial sum of their maxima.

Use exact balanced popcounts of valid vectors at the required
`clog2(capacity+1)` widths, then derive credits/full flags. Preserve the
existing event/slot/reduce/verdict ownership and include in-transit
dispatch reservations at the caller. Unlike r94's private coherence
counter, these outputs feed admission and are observable.
No extra cycle is needed. Check empty/full/simultaneous allocation-release
and odd capacities; do not reopen r90 byte-enable-table work.

## H96-g6lc_iq

State: slot-selection candidate with consumer-shape check.

**File/callers:** C `ooo/g6lc_iq.sv:238–254,390`, dispatch and bank helpers.
36.02 follows bank use/eligibility → rotate → pick → unrotate/assignment →
dispatch acknowledgement.

Evaluate two absolute-order searches (at/above rotation origin, below it)
when the consumer wants the bank/slot itself. A136/A140 transfer only if
no later offset reconstruction reintroduces the lost arithmetic.
Retain group-wide acceptance, bank capacity and intra-group allocation
order. Any selection/payload split must hold the winning entry plus its
identity through backpressure, wakeup, cancel and ready requalification;
do not create a grant without retained payload.

## H96-g6lc_l2_top

State: live cache control candidate; raw maximum requires guard audit.

**File/callers:** A `l2_cache/g6lc_l2_top.sv`, cluster and l3_top.
59.85/62.69 workbench rows begin with collector position/index/active →
fill-beat classification → read-tracker demand/admission. Their continuation
through an S_IDLE write into S_BYPASS_B must be removed from timing ranking
by M96-GUARD, not by changing cache behavior.

Cache the state-only collector owner or one-hot selection at FIFO/counter
updates, preserving simultaneous serve-pop/fill-complete/new allocation.
Separate request arbitration, tag/MSHR decision, and retained response
publication into purpose-specific helpers. Keep the existing SRAM row
window and write completion events explicit; avoid feeding unrelated
write-update cleanup through the entire next-state bus.

Owner tuple includes AXI ID, address/beat/len/size, ATOP/lock, fill/MSHR
slot and generation, per-ID order, pending B/R and posted-write tracker.
No “ready” may release capacity before the corresponding owner is retained.
No new stage until all AR/AW/W/R/B bypass, miss, hit and error paths are
included. Both cache geometries must improve; wrapper L3 is the same engine.

## H96-g6lc_l2_tag

State: disabled-path measurement blocker; do not optimize the reported PF maximum.

**File/caller:** A `l2_cache/g6lc_l2_tag.sv:392–437`, l2_top:588–596.
The parent passes PF_TAG=PF_EN=0. Explicit caller-bound maps still report
36.34/41.57 through `pf_d[index_i]` inside `if (PF_TAG)`, so these maxima
are not active paths. L2 geometry is 512 sets/49 tag bits; L3 is
1024 sets/48 tag bits, with 9/10 index bits.

After M96-GEN, inspect actual forwarded-row compare, way encoding and
invalidation metadata. Preserve launch-cycle forwarding only, row_valid,
read-port arbitration and use-cycle write exclusion. The current SRAM
window is the natural boundary; a fresh way stage must carry launched set/
tag/valid/forward ownership. If prefetch is enabled in another profile,
its consume-on-first-demand metadata becomes a separate valid task.

## H96-g6lc_l2_mshr

State: first small-table restructuring candidate.

**File/caller:** A `l2_cache/g6lc_l2_mshr.sv:140–202`, l2_top.
39.75 links lowest-free selection, allocation update, completion test
and occupancy. Some array-wide dependencies may alias different entries;
inspect them before credit.

Keep free and merge eligibility parallel. Compute per-entry pop/attach/
complete updates from registered state, then select the affected entries.
For each entry, post-pop/post-attach waiter count decides whether complete
frees it. A same-cycle attach must prevent premature free. Preserve lowest
free and existing merge tie rules; do not suddenly allocate a completing
slot that the old interface did not advertise.
Owner includes line, primary ID, waiter metadata/order and merge block.
A135 informs the manual update form, but its restricted pragma does not
automatically handle these multiple indices/loops.

## H96-g6lc_l2_wtrk

State: residual one-hot state-update candidate.

**File/caller:** A `l2_cache/g6lc_l2_wtrk.sv:273–367`, l2_top.
27.90 now follows match/age-column select → binary index → age update.
r94's 119.9→27.9 transformation is already present.

Keep p_sel one-hot through pop and age row/column updates; encode only for
an actual scalar-index consumer. Inspect all push/B/pop/probe views, not
only the pop path. Preserve concurrent events, delayed B, order by
acceptance and retained backpressure payload. A141's stationary storage
preconditions apply; no core speculative kill may erase an accepted AXI
write owner. Reuse the existing age-model and posted-write seam checks.

## H96-g6lc_l2_rdtrk

State: sibling one-hot state-update candidate.

**File/caller:** A `l2_cache/g6lc_l2_wtrk.sv:520–559` (second module),
l2_top. 18.55 follows oldest matching read → h_idx → age update.
Apply the write-tracker mechanism only after preserving read burst/last
and per-ID response order. Clear both age dimensions on removal; do not
equate ID equality with transaction age. Keep this as a separate module
task even though it shares a source file.

## H96-g6lc_ai_gemm_seq

State: terminal-fact/window candidate.

**File/callers:** A `ai_island/g6lc_ai_gemm_seq.sv:3164,3340–3387`,
island_top or cluster_dispatch. 52.00 follows store_reset's pipeline-empty
join into job state; the load phases already use registered completion.

Derive retained last-issue/last-commit/store-response facts from their real
accept/retire events, then simplify the terminal join. A134 and this
module's r21 load_complete_q/mac_last_q are the closest precedents.
Do not use a delayed whole predicate containing the current AXI handshake.
If ordered last-token completion implies older compute tokens drained,
prove that implication before removing any busy term.

Keep job/context, i/j/k cursors, accumulator mode, pending dot/read/sum/
commit records, AW/W/B state, errors and final completion coupled.
Dedicated store drain and overlapping MAC/store mode differ. Extract
compute-retirement and store-retirement helpers only around these owners;
completion waits for the final architectural memory response.

## H96-g6lc_ai_desc_engine

State: span completion-window candidate.

**File/caller:** A `ai_island/g6lc_ai_desc_engine.sv:263–301`, island_top.
46.54 is 65-bit product+tail addition → overflow/zero → saturated span.
sp_tail_q is already prepared at multiply kick; do not repeat that work.

Precompute empty/format predicates from the held descriptor and evaluate
sum/carry/saturation preparation in the existing multiply-completion join.
Keep empty dimensions returning one ahead of overflow/zero handling.
If a registered unsaturated-span record is introduced, spa/spb/spc done/
seen and final descriptor readiness must wait for that same owner.
Preserve upper-product overflow bits and all three spans, permissions,
context flush, backpressure and completion; no early “descriptor ready.”

## H96-g6lc_ai_gemm_fp32_norm

State: exact arithmetic candidate; recurrence constrains extra latency.

**File/callers:** A `ai_island/g6lc_ai_gemm_fp32_add.sv:85–191`,
fp32_add/fp32_add_p2 → GEMM. 44.10 follows correction → opposite-sign
sum/carry → magnitude → subnormal shift → final fraction/exception select.

The source already computes parallel magnitude candidates and one-hot
leading positions. Evaluate moving x/y complement and correction
preparation into the p2 align record, or a shared exact signed reduction
with late sign selection. Preserve carry conventions and all 37 result/
status bits; do not count one staged row as a represented value.
Adding a normalization stage affects accumulator recurrence and every
pending token in the sequencer. Keep the combinational caller distinct
from p2, and preserve zero/subnormal/cancellation/NaN behavior.

## H96-g6lc_ai_gemm_fp32_align

State: sibling early-preparation candidate.

**File/callers:** same source file, :37–79, fp32_add/fp32_add_p2.
36.70 follows zero classification → exponent selection → swap/delta →
alignment shift. Prepare both operand-order candidates in parallel only
if the late selection and extra area are favorable. An alternate split
stores the exact align tuple at the existing p2 edge. Include sign,
sticky/correction, exponent and special flags; never use the next operands
to finish an older addition. Review norm and both callers as one change.

## H96-g6lc_ai_island_top

State: control-plane task; separate from compute throughput.

**File/caller:** A `ai_island/g6lc_ai_island_top.sv:2177–2243`,
island_apb. 43.95 is register-class decode and read-data selection.
It is not the GEMM MAC datapath.

Separate small read classes and form bank-local candidates in parallel,
then publish one response at the current APB acceptance boundary.
Preserve address, byte strobes, side-effect reads, ticket/status snapshots
and APB wait-state behavior. P10's handshake/index lock prevents an
unowned extra read-data register. A new wait state is an explicit interface
choice, not a free timing stage. Do not move policy authorization into
this mux or enable default-off features to justify a timing row.

## H96-g6lc_ai_pe_dot_float_pipe

State: rebalance existing S1/S2 reduction window.

**File/caller:** A `ai_island/g6lc_ai_pe_dot_float_pipe.sv:537–595`,
gemm_seq:1470. 38.75 is the residual group-minimum tree in S2; the
NaN/Inf/finite reductions in the bundle are parallel.

r94 already moved groups of eight into S1. Compare groups of 16/32
against both S1 and S2 maxima; larger groups trade earlier-stage work for
a shallower remaining tree and fewer summary registers. This is an
existing-window experiment, not another external DOT stage.
Eligibility, NO_EXP padding, start/bubble/reset and products/format/flags
must remain equal-age. One transaction per cycle and the original
ceil(log2(Lanes))+5 edge distance must remain unchanged. A new stage is
only useful if the whole module maximum and caller pending capacity move
together. No array throughput claim follows from a module-local reduction.

## H96-g6lc_ai_cluster_dispatch

State: cluster-specific binding/selection candidate.

**File/caller:** A `ai_island/g6lc_ai_cluster_dispatch.sv:445–448`,
island_top. 34.30 is per-cluster active/dimension assignment under a case.
Bind NrClusters/channel partitioning to the selected caller first.

Precompute bounded split dimensions at accepted-command capture and keep
per-cluster descriptor records stable. Parallelize candidate geometry,
then select one authorized owner. Preserve tails, zero work, context,
response matching, errors and aggregate completion. Prior broadcast-skid
ownership failures prohibit separate request and response elections.
File separation may isolate geometry from dispatch/retirement, but no
latency credit is given for moving the same expression.

## H96-g6lc_coherence_hub

State: raw-maximum excluded; active slot/response audit.

**File/caller:** A `coherence/g6lc_coherence_hub.sv:652–937`, cluster.
121.60 ends in aw_ot_cnt_d, the sinkless counter rejected in r94.
Do not revive that candidate.

Find observable slot-valid admission, oldest held B/R presentation and
invalidation-applied dependencies. Consider parallel per-slot eligibility
and one-hot owner masks; divide request admission, retained response
publication and invalidation ownership into functional helpers.
The slot must retain original core/ID, B and ATOP-R obligations,
invalidation sequence and payload until all required events finish.
Queue enqueue is not applied acknowledgement. Separate filtered four-slot
workbench geometry from MC auto-sized slots and COH_OOO.

## H96-g6lc_inval_bus

State: measurement-blocked; semantic queue task retained.

**File/caller:** A `coherence/g6lc_inval_bus.sv:126–162`, coherence_hub.
123.30 includes reset head/tail/count/FIFO writes and independent NBA
updates in one chain. M96-GUARD must establish the active paths first.

After that, evaluate per-target retained queue records and independent
push/pop/coalesce eligibility. Preserve monotonic enqueue/dequeue sequence,
target masks, same-cycle coalescing/pop, queue capacity and applied ACK.
Do not replace enqueue acknowledgement with visibility. A queue stage
must reserve capacity before any upstream acceptance and include pending
work in every credit/visibility query.

## H96-g6lc_cmo_engine

State: selected-request capture candidate.

**File/caller:** A `coherence/g6lc_cmo_engine.sv:190–281`, cluster.
29.50 is an independent bundle whose largest node captures selected
address; it is not the serial sum of all FSM assignments.

Evaluate one-hot request selection and narrow op/target preparation before
the existing captured command. Preserve arbiter fairness, selection
identity, all L1/L2/L3 completion bits and write-idle prerequisites.
Splitting target dispatch from completion join is useful hierarchy only
when the same retained command owns both. No early CMO completion.

## H96-g6lc_snoop_filter

State: row-local update candidate.

**File/caller:** A `coherence/g6lc_snoop_filter.sv:134–171`,
filtered coherence_hub. 26.58 includes selected clear index, presence
update and valid reduction.

Prepare per-entry presence/valid updates from registered state, with
constant local indexing, then select the write. Preserve allocation-before-
clear priority when both address the same entry, clear_all, tag collision
policy and conservative sharer coverage. A135 is the closest small-table
analogue; its automatic form cannot silently handle two independent
indices. False positives may cost traffic; false negatives break coherence.
