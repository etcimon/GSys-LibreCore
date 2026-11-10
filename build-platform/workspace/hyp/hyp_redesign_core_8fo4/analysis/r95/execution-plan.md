# r95 execution-path and retirement plan

## Scope And Evidence

Production `core/` and `corev_apu/` remain the behavioral references and are
not edit targets. Their exact configuration and source identity, not an old
PASS label, determine the executable control. Preserve unrelated APU work.
Do not carry incomplete functional CTS groups into Hyp.

The current-source index is `start-sources.json`; `planned-sources.json`
adds stable C95 per-file review task IDs. Every source stays inventory-only
until its changed behavior and callers have actually been reviewed.
`planned-workqueue.json` supplies H95 per-module tasks for every module
exceeding 8 FO4 in the six screened bindings. It includes inactive and
measurement-questionable rows rather than silently deleting them.
`planned-analysis-index.json` indexes the historical analyses; indexing is
not a claim to have semantically read all 711-plus artifacts.

The r94 five-profile manifests match current source, maps and binary.
The additional r95 `baseline-core-all` covers 285 scalar-flist declarations.
Both use delay-v49, ir-v6, fo4-v1, 20 ps/FO4, 5000 MHz, margin 0.2.
These are module-local structural screens, not elaborated instance arrivals,
STA, achievable GHz, or proof that a reported cone is sensitizable.
No OpenROAD run is part of this pass.

## Order Of Work

1. Resolve source/input/configuration identity and the earliest demonstrated
   operation-lifetime defect. Establish scalar retirement as the control.
2. Repair complete caller families, with a small discriminator of the changed
   invariant. Keep latency-neutral and protocol-changing work separate.
3. Establish SMT2 drained operation, then separately mixed residency and
   multicore physical validation. Never promote one envelope as another.
4. Reduce surviving active cones, using existing state/windows before adding
   latency. Recheck consumers, reconvergence and capacities in the same batch.
5. Run source-pinned OpenSBI, then Linux when earlier milestones are real.
   Timeout, a banner, or zero-valued tohost without a handshake is not success.

The queue exists before implementation. Its first concrete correctness item
is wide-issue CSR capacity/counting; the first OoO timing experiment is
parallel FLU admission. Neither is asserted to explain a current scalar boot
failure without a source-matched trace.

## One Iteration Per File And Caller

For each C95/H95 item:

- Establish exact source, specialization, dimensions, active caller and
  observable sink; distinguish reset/NBA regions from combinational edges.
- List all outputs and follow each to a register, accepted external transfer
  or architectural effect. A module maximum is not a connected caller path.
- Walk reset/disabled mode, offer/accept, completion, held/backpressured work,
  allocate/free, WB/cancel, commit/flush, replay/refill and ID reuse.
- Record producer event, fields, owner, consumer event and stale-result rule
  for every moved register. Include tid, hart, generation, exception and
  permissions where applicable; a data-only stage is not a complete design.
- Check six visibility channels: wrong-path writes, missing surviving writes,
  state incorrectly retained/killed, value-derived control, cross-hart order.
- Compare the applicable prior solutions/counterexamples before coding.
  Rank zero: exact identities. Rank one: explicit lifetime/latency changes.
- Measure every relevant path kind and the actual upstream/downstream
  reconvergence. Cross-module sums are triage unless continuity is proven.
- Validate the smallest changed invariant with a useful negative control,
  then its caller/integration. Leave other unreviewed paths explicitly open.

An unchanged helper is still reviewed when its caller changes timing,
ownership, width or acceptance. Vendor code is not retiered or edited merely
because an unqualified raw row is large.

## Initial Caller-Qualified Batches

### A. Retirement, Admission And Recovery

| Task/family | Execution path and first strategy | Owner/exit requirement |
|---|---|---|
| H95-csr_buffer; g6lc_ooo_dispatch; ex_stage; issue_stage; g6lc_core; g6lc_ooo_pkg | CSR group count and credit are hard-coded to two bits; table has two slots. Derive capacity and credit/count widths from supported issue width, including all connecting ports and allocation prefix logic. | Dispatch owns the address before IQ issue; commit/drop releases exactly that tid. Three CSR lanes must not wait forever on an empty two-slot table; four must not alias count to zero. This is a source-level wide-profile defect, not an observed scalar boot cause. |
| H95-g6lc_flu_reserve | 67.45 input-to-output; trace IRO pre-ack through classification, tentative admission and final ack. Replace variable-index, lane-serial working-word updates with constant class slots and parallel predecessor conflicts if equivalent. | Same-cycle admission; state consumes final accepts only. Preserve divider tid/reclamation and the existing ALU2 exclusion. Do not add a stage or infer acceptance from an offer. |
| H95-commit_stage; scoreboard; sb_commit_bundle/head/lifecycle/cancel | Common retirement event, per-hart commit heads, drop/reclaim and same-edge flush. Separate selection from publication only with retained complete event ownership. | Architectural maps, CSR/store effects, instret, RVFI and debug consume the same instruction, not a delayed ack paired with a newly selected head. |
| H95-g6lc_rename_read/resolve/recover/publish; g6lc_rename; g6lc_rat/freelist/prf | Read-only map queries, bounded bypass selection, constant-width checkpoint arithmetic, free/busy repair. Inspect existing R1/RR/R3 windows before adding one. | No lost wakeup between rename capture and IQ allocation; repair preserves intervening WB/commit progress; kill releases each reservation once. |
| H95-g6lc_iq, bank, arb, legal, payload, xbar | Stationary entries/age matrices, parallel eligibility and bounded winner merge; separate ready selection from payload transport where existing records permit. | Age is transaction identity, not numeric PC. A held winner owns both its slot and registered payload. Same-cycle cancel cannot resurrect an accepted packet. |
| H95-g6lc_ooo_dispatch; issue_read_operands; lsu_bypass | Group resource accounting, actual-accept FU valids, LSU count plus in-transit grants, sparse-lane issue and replay. | No phantom acknowledgement, truncated count or unbounded hold. Treat ALU2/WB-lane capability independently from issue-width elaboration. |

### B. Memory, Translation And Fetch

| Task/family | First strategy | Owner/exit requirement |
|---|---|---|
| H95-load_unit; store_unit; load_store_unit | Per-slot publication and forward-coverage ownership; use the existing StoreFwdCycles/LoadPubStages windows. Inspect pre-grant cancel and exception bypass before a new cut. | Accepted cache tag/request stays owned until response/drain; a cancelled ungranted head must not wait for a grant or consume another request's response. Fault publication cannot depend on faulting data arriving. |
| H95-g6lc_lsq and event/slot/cam_bank/age/reduce/verdict/release | Parallel byte-enable/CAM banks and balanced verdict reduction; existing reduce record before another pipeline boundary. | ld_checked means every prior relevant verdict is incorporated, not just address-ready. Retain generation through cancellation, verdict latency and slot reuse. Physical checks retain accepted PA/tid/hart/access identity. |
| H95-store_buffer; stb_insert/commit/drain/fwd | Separate speculative reservation, committed-pending visibility, drain and per-byte source selection. | A store does not disappear between acceptance and installation. Same-hart order, cross-hart committed visibility and fences include every pending owner. |
| H95-wt_dcache_wbuffer and callers; wt_axi_adapter | Versioned pending-byte/fixup records, snapshot forward data at the consuming read edge, separate dispatch/return/admission. | A popped fixup cannot change a later merge's bytes; a late old return cannot clear a newer write. Preserve MMIO/AMO and exactly-once AXI transfer. |
| H95-g6lc_mmu/tlb/shared_tlb/ptw; pmp_data_if | Per-request context records, bounded tag/permission reductions, existing lookup/decode stages. | Late PTW fault belongs to its original access, not a newer hit. SATP/PMP/fences and privilege returns define subsequent translation epochs. UseSharedTlb=0 is not evidence for its enabled arm. |
| H95-frontend; instr_realign/queue; g6lc_fe_*/ftq/fdip/loop_buffer/bp_* | Break demonstrated combinational feedback structurally; separate bytes, windows, ordering and one architectural redirect encoder. | Only realignment creates instruction bytes. Adjacent RVI leftover completion only; drop on valid foreign window. Tokens/hart/epoch survive hold/replay; resolution is never filtered. |
| H95-g6lc_icache and invalidation retain helpers | Hit/refill response ownership and the existing two-cycle hit record before any further retiming. | Resolve checked-work regression with deterministic vt=1 control. Killed refill may install except a pending fence.i; queue acceptance is not applied invalidation. |
| H95-g6lc_decode_s1/s2/s3 and decoder callers | Classification parallel with bounded data selection; maintain captured input identity through all stages. | Legal scalar/RVC/RVH alternatives and every supported width remain meaningful; no opcode/PC-priority substitute for architectural order. |

### C. Coherence, L2 And L3

| Task/family | First strategy | Owner/exit requirement |
|---|---|---|
| H95-g6lc_coherence_hub; snoop filters; lr_sc_tracker | Audit observable sinks and real occupancy first; then parallel slot eligibility and conservative signatures. | Do not optimize sinkless private counters as execution paths. Credits cover concurrent fill lifetime; signatures may overapproximate sharers, never omit retained copies. |
| H95-g6lc_inval_bus; l1_inv_adapter; cmo_engine | Isolate reset/NBA aggregation from actual accept/apply/ack dependencies; consider retained per-target records. | Applied acknowledgement/visibility, not queue enqueue, releases permission. AW acceptance and delayed W/read/refill schedules require composed proof. |
| H95-g6lc_l2_top (59.85 L2 / 62.69 L3 geometry) | Separate request admission, SRAM lookup, miss/refill and response selection at existing state windows; retain parent ownership before splitting files. | AR/AW/W/B/R ids, order, backpressure, same-line hazards, ATOP/lock bypass and error responses survive every split. |
| H95-g6lc_l2_tag (41.57 L3 geometry) | Parallel way match/write selection using the tc_sram read window. | Captured tag/way/valid belong to the launched set; concurrent refill/write/invalidate cannot retag a response. |
| H95-g6lc_l2_mshr (39.75); rdtrk; data | Per-entry state and independent index gathers; bounded oldest selection and byte/beat merge. | Admission reserves real capacity; refill/error/cancel releases exactly once; per-id response order remains correct. |
| H95-g6lc_l2_wtrk (27.90) | Start from r94's stationary age-column form, not its rejected serial-selector rediscovery. | Concurrent push/B/pop and retained response ownership remain exact; posted-write integration is required. |
| H95-g6lc_l3_top; inclusive_inv; server_prefetcher | Trace wrapper bindings and bypass/disabled arms before proposing a stage. | Qualification L3 was non-inclusive with no measured boot hits. No performance or inclusive-coherence claim follows from engine timing alone. |

The r94 coherence binding has four outstanding slots. That is not automatically
the current MC auto-derived credit depth. Derive the real package before
calling it a composed MC timing baseline.

### D. AI Island And CVXIF

| Task/family | First strategy | Owner/exit requirement |
|---|---|---|
| H95-g6lc_ai_gemm_seq (52.00) | Separate descriptor interpretation, geometry/address recurrence, row scheduling and response merge; reuse existing accepted-command/state windows. | Request selection and response qualification elect the same owner. Preserve tails, error unwind, completion and byte strobes; reject old broadcast-skid theft. |
| H95-g6lc_ai_desc_engine (46.54); desc_fetch; cmd/cpl FIFOs; enq_arb | Bounded descriptor validation and credit accounting before address/owner publication. | Accepted descriptors persist through backpressure, context flush and completion. No default-on policy inferred from a standalone leaf. |
| H95-g6lc_ai_gemm_fp32_norm (44.10); fp32_add; float dot pipeline (38.75) | Bound normalization/rounding; move partial summaries only across the existing product/reduction window, carrying format/flags/valid. | Preserve exact bits, flags and initiation interval. r94 grouped minima at S1 is reusable only with the same eligibility and bubble/reset contract. |
| H95-g6lc_ai_policy_codec/steer/topology/publish | Review full caller and context/tuple authorization before local arithmetic rewrites; split topology from final owner publication. | Default-off production policy stays off; real producer/consumer, exact-zero authorization, limits and flush are prerequisites to promotion. |
| H95-g6lc_ai_mem_store; axi_cut; addr_check; cap_window; cluster_dispatch | Parallel bound checks plus retained accepted address/length/owner records. | AXI channels and response ids retain the same descriptor owner. SRAM/DRAM backend and DMA invalidation limits are explicit. |
| H95-g6lc_ai_exec (45.60 one-cycle scalar binding) | Compare global compressor representation with prior exact Baugh-Wooley/narrow-sum work; preserve result publication and issue contract. | Dot4Stages=1 remains one cycle; stage 2 is a distinct throughput/latency choice. Scalar Hyp has CvxifEn=0, so it is not its core clock limiter. |
| AI fp_dot/arplan/cluster_set reference rows | Establish an actual selected caller before optimization. | r94 simulation/disconnected exclusions remain; a large raw row is not a live accelerator datapath. |

No array MAC/s claim follows from scalar FP latency or isolated dot tests.
Any new split enters both materialized flists and the source-origin/licensing
records. File separation without a real register does not create timing slack.

## Configurations And Necessary Gates

Retain named, distinct envelopes: scalar Hyp8; G6LC_HYP8_SMT2 drained;
G6LC_HYP8_DEEP; G6LC_HYP8_L3; MC (four cores, two harts/core, eight issue
ports, 64-bit fetch); explicit mixed-residency and COH_OOO alternatives only
when their actual legality and physical-validation contracts are established.
The MC source currently selects filtered coherence, not an implied COH_OOO
qualification. Do not merge parameter maps from unrelated instances.

Check issue widths 1/2/4/8, small/odd legal bank capacities and enabled/disabled
features. Expected-illegal combinations need an elaboration rejection, not
truncation or a silently inactive datapath. RV32 AI leaf evidence is not
whole-Hyp RV32 evidence; the staged CLMUL schedule was RV64-specific.

Check software_harts = NrCores * NrHarts, CLINT/PLIC contexts, packet/CSR/MMU
hart context, DTB ISA/MMU/cache properties and every possible elected boot hart.
PMA review is mandatory: the current profile's zero-length non-idempotent
regions do not establish a valid device-access policy. Use platform region
contracts, never firmware addresses/symbols or data-value gates.

For a pipeline cut, document both dependence latency and service/capacity:
load publication >= max(data, forward, order, permission) + publication service;
window >= accepted_rate * lifetime is necessary, never sufficient. Include
completion-port collisions, SRAM availability and downstream reconvergence.
OoO/SMT cannot hide a dependent recurrence or an exhausted shared resource.

Use scoped remote elaboration, a discriminator per changed invariant, then
one source-pinned integration and firmware witness rather than a full test
matrix per edit. Preserve deterministic vt=1 and the validated runtime.
The full repository verification gate remains mandatory after an RTL batch;
pre-existing target-path/CV32/CV64 failures remain failures, not waived passes.

Finally, the unbuffered delay-v49 wide-select law already charges some 64-bit
selects more than 8 FO4. Do not retune it to make a target green. Unsupported
model floors are measurement/calibration tasks; useful structural partitions
still need functional, backend and ultimately physical evidence.
