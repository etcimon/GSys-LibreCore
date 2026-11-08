# Storamic development and qualification lanes

Latest C1 follow-up (CPU47): the new `cpu-debug` stage (`run_cpu_debug.py`)
runs real external-debug entry, CSR checks and DRET through the CPU.
- **Positives (20):** entry U/S/M, plus M with MPRV=1/MPP=U and
  `dcsr.mprven` 0 or 1, each at both origin settings and response delays 0
  and 16.
- **Negatives (5):** two bench negatives, plus three runs of an LSU mutant
  that ignores debug mode. All five reject with `debug-origin-failed`.
- **Result:** passes in 358 s (`storamic-34a969bd68a9`); the mprv=0 images are
  byte-identical to HEAD.
- **Bench patch:** the interpreter does not forward `OriginEnabled` to the CPU
  wrapper (`tb_g6lc_storamic_cpu_debug_interpreter.sv:95`), so the stage
  applies a recorded patch to the remote tree. The older Yosys two-step flow
  passed the parameter separately.

Latest C0 follow-up (CPU47): the documented interface-level next step was
implemented and *disproven*, then the residual was fully characterised.
- **I-cache `ready` split.** `ready` moved out of `icache_drsp_t` onto a
  scalar `icache_ready_*`/`dreq_ready_o` path across `cva6.sv`,
  `g6lc_icache`, the AXI wrapper, all three cache subsystems and every
  frontend variant. Both `verify --lint` targets elaborate cleanly, and
  the exact CPU46 strict diagnostic was reproduced locally with the
  forked `g6lc-fork-native` Verilator (`vlt-8c69f`, WSL) over the same
  242-file closure. Result: **zero delta** — `both-origin0-fields` stays
  at 9 identities, `dreq_o[366]`→`[365]` is only the struct renumber.
  Full write-up: `cpu-icache-ready-interface.md`.
- **`kill_s2` accept-guard cut.** The cone dump showed
  `dreq_ready_o`'s READ hit-accept guard reading `dreq_i.kill_s2`
  (`bp_fire`-carrying). Removing `~kill_s2` (keeping `~kill_s1`, the
  I4xj pattern) gave **zero delta** and was reverted.
- **Diagnosis.** All nine remaining identities are `svt-pipe`
  `no-cut`/`cycle`/`require-contract`-annotated deliberate same-cycle
  recurrences: the fetch/commit/CSR megaphase (`dreq_o`, `flush_ctrl_id`,
  `update_access_exception` via frontend `kill`/`bp_fire`/`predict`) and
  the D-cache request-port loop (`load_unit`→`lsu`→`cva6`→`ex_stage`,
  A128; `wt_dcache_mem` `rd_data_o`/`rd_hit_oh_o`). No unintentional
  residue remains to cut. C0 resolution is the **svt-plan predictor/
  load-unit re-architecture** (A124/A128/A139) — a coordinated multi-
  module redesign — not a module-local edit; per status policy no
  diagnostic is waived.

Latest C0 follow-up (CPU45–46): two structural edits, both behaviour-preserving.
- **Scoreboard.** `issue_pointer[i]` is now `issue_pointer_q + i`, replacing a
  chained self-read of one packed var. A cone-scoped SAT proof
  (`sb_issue_ptr_equiv.sv`, P 1–4 × B 1–6) proves all 24 cases, and the
  off-by-one mutant fails all 24 (`storamic-cpu46-f3e8943f`). Full-module
  equivalence exceeded its 7,500 s budget. Synthesis shows 0 SCCs and 0
  latches.
- **I-cache.** `flush_d`, `areq_o.fetch_req` and `dreq_o.valid` (new
  `p_response_valid`) are computed outside `p_fsm`, which reads `kill_s2`.
  Full-module equivalence passes for imafdc, NonIdemPotence and WayPred
  (imafdch). Three mutants are caught in every config. Synthesis shows 0
  SCCs and 0 latches (`storamic-cpu45-97fb4382`).
- **Diagnostics.** Strict full-core diagnostics go from 6→4 (fields) and
  23→21 (FP), both origins, with no additions. Only `issue_pointer` and
  `adapter_icache_data_ack` are removed (`storamic-cpu45core-bfa95a0d`).
- **Regressions.** cpu-origin, fetch-queue, sbcommit and fp-lifetime pass.

Remaining four identities: `flush_ctrl_id`, `update_access_exception` and
I-cache `dreq_o[366]` (`ready`) all route through the frontend kill_s2/bp_fire
loop, and the fourth is load_unit `req_port_o` through the D-cache port arrays.
Diagnostic `split_var` on every I-cache response alias is inert. Splitting the
D-cache port arrays exposes finer var-level identities (4→9), so it is not a
fix. The gate-level full-core check still has 0 SCCs, so these are
representation artifacts. Removing them needs an interface-level change, such
as carrying I-cache `ready` outside the response struct, and a design decision
(`storamic-cpu46core-f62bf710`).

Latest C0 follow-up (CPU40–43): a bit-level gate-netlist SCC check ran on the
full CPU wrapper (`g6lc_cpu40_top`, OriginEnabled=1, owned Yosys/slang,
`proc; flatten; techmap; scc`, no abc, 5.85M gate cells, ~36 min, ~10 GB).
The live tree had 65 real combinational SCCs (`storamic-cpu40-ccc97174`).
All of them were in `csr_regfile.sv` `csr_update`: the never-defaulted `mask`
temporary (64 bits) and the static block-local `DirVecOnly` (MTVEC), both held
by the always_comb. CPU41 defaults `mask = '0` and makes `DirVecOnly`
`automatic`. This is behaviour-preserving because every read follows a write in
the same arm. The full-core netlist then has 0 SCCs and 0 latches
(`storamic-cpu41-9d4ea06e`). All 57,397 `$_ALDFF_PN_` are `rst_ni` async-reset
flops, and only the I-cache `vaddr_q` has a non-constant (boot address) reset.

The check found no gate-level SCC in the scoreboard, commit, load-unit,
frontend/I-cache or adapter regions. The six remaining UNOPTFLAT identities are
therefore Verilator representation artifacts, not real feedback. This corrects
the earlier CPU39b reading of the I-cache/frontend path as a genuine cycle.
Strict CPU diagnostics are unchanged at 6/23 in both origins, including
`update_access_exception`, and all 9 real-loop canaries still fail
(`storamic-cpu41core-b4246064`).

The cpu-origin bench required `aw/ar.cache == 0`. The core intentionally emits
`axi_pkg::CACHE_MODIFIABLE` (`wt_axi_adapter.sv`, `axi_shim.sv`), so this bench
could never pass, including at committed HEAD (`storamic-cpu42-2454a09b`). The
bench now expects `CACHE_MODIFIABLE` and prints the fields on failure. Both
origins pass (`CPU_ORIGIN_PASS`, 5 writes/4 reads, delay 0 and 16), and the
aw-prot negatives still reject. Results are bit-identical on pristine HEAD and
the live tree (`storamic-cpu43-333f05a1`).

Two remote stages are now registered (CPU44):
- `cpu-origin` (`run_cpu_origin.py`): runs both origins with delays 0/16 plus
  an aw-prot negative. Positive cases need exactly one PASS with 5 writes and
  4 reads. It passed as `storamic-8b77a9525b3e` in 94 s.
- `csr-scc` (`run_csr_scc.py`): a synthesis-only gate-level check of
  `csr_regfile` that needs 0 SCCs and 0 latches. A copy with the fix textually
  reverted must show SCCs (130 found). It passed as `storamic-958e2705836e` in
  118 s.

Latest C0 follow-up (CPU38): `wt_dcache_missunit` aligns `mem_req_c.paddr`
with a separate `mem_req_size` net instead of reading back `mem_req_c.size`
from the same packed packet. Full-module combinational equivalence passes for
imafdc (RVA+Zacas), imafdch and a derived `StoramicCheckpointEn=1` config; a
paddr mutant is caught in all three. Synthesis 11,575 cells before and after,
zero latches/SCCs. Strict CPU diagnostics in both origins: 7→6 (diagnostic
representation) and 24→23 (FP controls), removing only `mem_req_c`. Six cones
remain. Remote runs `storamic-cpu38-e9ef7236`, `storamic-cpu38core-add2ce84`.

Latest C0 follow-up (CPU37): `core/cva6_mmu/cva6_ptw.sv` computes
`shared_tlb_update_valid`/`is_napot_64k` in a separate `ptw_leaf_update`
process from shared leaf predicates. With `UseSharedTlb=0` the shared TLB
returns `update.valid` as `shared_tlb_hit_d`, which the walker reads only in
IDLE; the single walker process made that a false loop. Full-module
combinational equivalence against the frozen original (registers matched as
cut points) is proved for imafdc, imafdch (H on) and stream8 (RVH+Svnapot);
four mutants are each caught. Strict `cva6_mmu` lint names the loop on the
original and is clean on the candidate; synthesis is 7,499→7,497 cells with
zero latches/SCCs. Strict CPU diagnostics in both origins: 8→7 (diagnostic
representation) and 25→24 (FP controls), removing exactly `shared_tlb_hit_d`
with nothing added. No PTW-level simulation exists; the evidence is formal
equivalence plus lint/synthesis. Seven cones remain; native admission remains
disabled. All runs are remote (`storamic-cpu37-ecd824fd`,
`storamic-cpu37core-01db33b0`, under `build-platform/workspace/build/storamic-cpu-37/`).
The `fetch-queue`/`fetch-queue-synth` leaf stages are now registered and pass
remotely (`storamic-e7ccb487a7dc`, `storamic-5fbcd93abe66`).

Latest C0 follow-up (CPU36): instruction-queue address admission now reads the
selected slot's control-flow type directly instead of the checkpoint-carrying
FIFO payload, which is allocated from `consumed_o`. Proof across six queue
geometries passes with every predicate mutant rejected. The actual queue passes
five geometries with checkpoint feedback, and its checkpoint and PC oracles
reject. Synthesis gives 56,651 cells before and after, with identical flops and
zero latches/SCCs. A freshly built PGO compiler from the current
`tools/verilator` (`bc8d406c3`) gives strict CPU diagnostics in both origin
modes: 10→8 with the diagnostic representation and 27→25 with FP controls
only. `ckpt_slot_v` and `push_cf` are removed, with no new reports. Full C0
remains open: 8 cross-module cones are left, and native admission remains
disabled. Evidence: `build-platform/workspace/build/storamic-cpu-36/` and
`storamic-tools-35/`.

Latest C0 follow-up: the independent load translation process passes control
equivalence and the two registered actual-module stages on promoted sources.
The captured strict off/on CPU diagnostics drop from 28 to 27, with no new
named error. The selected profile runs in about 53 seconds; native admission
and full C0 qualification remain open. See
[cpu-load-translation.md](cpu-load-translation.md) for source/runtime identities,
31 scenarios, five negative checks and the synthesis/timing limits.

## Evidence boundary

This source audit supersedes earlier claims that ST-025 was complete at model
level merely because a last-address register and magic-key latch were added.
ST-025 remains **open** against its acceptance criteria in
`implementation-tasks.md`. A prepared build, an inspected RTL change, a selected
leaf pass and aggregate qualification are four different states.

The architecture still has the intended seams: primary RAM traffic through
`g6lc_storamic_attach` / `mem_*`, flash through the transport-neutral `st_*`
backend, and VirtIO-MMIO/virtio-blk as the flash software interface. Independent
RAM response, flash response and flash commit delays are useful service-model
controls, not physical bandwidth guarantees. Keep these interfaces stable while
repairing their lifetime and recovery semantics; do not add another transport
to work around backend bugs.

## Current review

Use [completion-plan.md](completion-plan.md) for the current dependency order.
The later endpoint, real VirtIO writer/DMA composition, independent MMIO seal,
policy replacement and reset/rediscovery evidence supersede the historical
record-engine checkpoint below. They validate model ownership; they do not
supply native descriptor/identity/protection providers or CPU/cache/fabric
synchronization.

The source review also found that a passing small-capacity block model had not
covered the full backend address contract. IN/OUT truncated high sector bits
before issuing byte-addressed storage commands. A large capacity could admit
aliased or wrapping accesses; an empty status descriptor and one oversized
segment-count encoding could also cause side effects. The bounded correction
and its original-RTL rejecting checks are recorded in
[block-address-validation.md](block-address-validation.md).

The final block/device profile now passes six selected remote stages in about
130 seconds, with 119 matching packaged source hashes and two verified simulator
PGO builds. Both formal modes close every original obligation: the window is
proved by twenty independently established inductive invariants and a pointwise
consequence; the other assertions and concrete covers retain their old bounds.
Original RTL still rejects in six named reproductions and the final proof flow.
The 62 omitted stages are explicit. This closes the bounded backend repair and
verification bottleneck, not the native or physical completion gates.

## Earlier record-engine checkpoint

The ST-025D reserved-media implementation is now under immutable local
validation. See `checkpoint-record-model.md`: actual alternating flash copies,
fixed-location identity/map/image-bound records, nonzero commit markers,
reset recovery with a retained-staging flush, freeze-only RAM preparation and
an independent untrusted word-port guard replace the retained-selector
approach at component scope. No native binding or persistence capability has
been enabled. Current launch plan: `storamic-489af3c88a3e`; local artifacts:
`build-platform/workspace/build/storamic-checkpoint-record-01/`.
The aggregate dry-run plans 25 steps and executes none; it is not a gate pass.
At that checkpoint the local run was still in progress, including the C2 idle-context
loss fix and maintenance-drain/C1/dstore regressions. Earlier receipts do not
qualify source changes made after their snapshots.

| Track | Source/evidence available | Qualification still needed |
| --- | --- | --- |
| ST-011B/ST-012 primary ownership | Real primary-role atomic failure traced to nonzero WUSER rejection; frontend fix in working tree | Fresh primary positive/negative/hello, IO regression, competing writer, fences and reset |
| ST-013 measured service | RAM/flash commit sweeps recorded; response/readback leaf passes at delays 0/1/4/16 | Re-run native reinit/service measurements; old cycle baselines do not qualify the changed backend |
| ST-018/ST-025 flash model | Boundary/repeated-cut/save/flush and response/readback leaf passes on pinned runtime | Integration, aggregate and remaining checkpoint/protection acceptance criteria |
| ST-025 RAM checkpoint model | Two tc_sram checkpoint banks, response-drained scans, last-valid retention and interruption leaf cases pass | Stick-wide coordination, durable identity/map-bound metadata and reset/physical recovery |
| ST-024/ST-025 physical persistence | Architectural requirements only | Protection budget, retained metadata/data ordering, identity/map generation, reserved backup region, degraded admission, torn/bad-block recovery |
| ST-026/ST-038/ST-040 Linux | Standard transport direction is established | Stock Linux payload qualification; PMEM/DAX/virtio-pmem remain disabled until their own gates pass |

`journal_id_o` and `journal_gen_o` are debug telemetry. They reset with the
controller, have no valid bit, contain neither a replay payload nor a checksum,
and do not constitute a persistent version map. Comparing the two generation
counters cannot prove a recoverable checkpoint.

`unlock_key_i` is an accidental-trigger interlock, not privilege enforcement.
The RAM triggers are not gated by that key; the testbench AW/W monitor also lacks
a complete transaction scoreboard (same-cycle AW/W and preceding outstanding
writes matter). Do not publish these offsets as a protected software ABI.
Flash `restore_done_o` is now tied low: the flash model has no rollback engine.
RAM restore completion is a separate seam.

## Bounded implementation slice

### Failed Remote Gates Follow-Up

The earlier 56-stage receipt remains 40 pass/14 fail/two incomplete. The frozen
`storamic-all-4aed2cd2cc55` follow-up passes thirteen original failed stages.
Register safety and four covers pass; its last cover is interrupted by the
whole-stage deadline after five identical expensive preparations. This is
incomplete evidence, not a failing assertion or a completed aggregate run.

Trace-backed production edits are limited to equivalent fixed-unit bit
extractions in the AXI and block backends. Descriptor-vector publication is a
fixture correction. Remaining register/discovery/bridge driver loss and CRC
proof corruption were reproduced in the repository Yosys fork's alias mapping
and representative cache. Those tool fixes preserve full optimization and all
original properties. The standard kernel executable passes all 126 tests;
one of 96 optimization scripts fails on both old and repaired tools.

The register runner now prepares one lowered RTLIL model, records its hash,
and checks it before and after each unchanged SAT query. The standalone frozen
run passes all six original goals in 1001 seconds, including the last cover;
source/model post hashes match. The pre-ownership frozen full matrix
`storamic-all-5267d4deeb38` now passes all 56 stages with matching source post
hashes. It closes the prior failed leaf gates, not whole-system qualification
or a full sweep of the later ownership SV.
The maximum-width model alone gets
the previously demonstrated larger PGO compilation budget; simulation checks
and other compile budgets are unchanged. A frozen, contained remote snapshot
passes all 111 Python tests; local disk-full attempts remain archived.

Timing/config/backend impact: fixed wiring replaces fixed shifts; no new
sequential stage, reset/clock, SRAM macro, scan boundary, PMU event or software
encoding is introduced. No generic synthesis result is timing/DFT/PPA closure.
Native guards, provider dependencies, PMA/PMP/DTS semantics and Linux capability
refusals remain unchanged. Receipt: `storamic-policy-19/REMOTE-RESULTS.md`.

The next bounded SV slice extends endpoint hold through actual RAM inflight,
word/media/flush ownership and empty-staging observation. Ten frozen stages,
two hardware-mutant rejections and a subsequent protocol-valid formal/
abandoned-flush simulation follow-up pass. The first withdrawn-flush fixture
counterexample remains archived. This supplies no native producer/fabric ACK
or automatic flush; see `policy-ownership-drain.md`.

An independent VirtIO control seal now drains MMIO ownership without changing
DMA-only pause. Legacy integration leaves it off. Eight frozen stages, eleven
formal goals and two rejecting hardware mutants pass their scoped checks with
matching source post hashes; original DMA pause/notification/reset coverage
remains intact. The combined-pause prototype stays failed/archived. This does
not bind native producers, providers or CPU/cache/fabric synchronization.
See `virtio-control-seal.md`.

The commit/replay source slice changes the flash model; selected-leaf validation
is now recorded in the response-ownership section below, not full qualification:

- Write SRAM only on the powered commit-retirement edge, not throughout the
  `CommitCycles` delay or on a power-cut edge.
- Retain the modeled journal head across a held power cut and a second cut
  before replay retires. Clear journal ownership when a spill stops, so a
  subsequent staged tail is not misclassified as journaled.
- Close admission during save/replay and while a flush request is asserted.
  Empty and nonempty saves complete after drain; a cut cancels the save.
- Count/acknowledge a held flush request once, until the requester drops it.
- Reject zero/overflowing commit-cycle parameters in simulation checks and
  avoid a zero-width word index at `NumWords=1`.

The directed bench now connects the save seam, has a bounded watchdog, and
checks early SRAM writes, held/repeated cuts, empty/locked/nonempty saves,
post-save survival and held flush acknowledgement. The historical 30-check
result predates these changes; the new selected-leaf evidence is separate.

Timing/config review: this is confined to the existing optional model binding;
there is no ISA, DTS or public register-layout change and no new clock/reset.
SRAM remains behind `tc_sram`. Added control gates and the commit countdown
zero-test need lint/synthesis/STA review; no 8-FO4 closure is claimed. No new
physical retention, power isolation, scan qualification or PMU capability is
inferred from behavioral power-cut retention. Existing contributor/SPDX headers
are preserved (RTL tier R; verification/tooling tier T).

## Audit-time remote observation

Read-only inspection before the authorized response-leaf run found:

- `/opt/testharness`: 878 GB filesystem, 767 GB used, 67 GB available (93%).
- Gate-v3 `aggregate-result.json`: `aggregate-fail`, 20 pass / 5 fail.
- V6's locally collected result: `aggregate-fail`, 22 pass / 3 fail. Its remote
  output directory is absent; do not treat it as a currently progressing gate.
- Two long-lived Spike processes still consume approximately one CPU each:
  PIDs 3073699 and 3455651, referencing the v3 and v6 snapshots, respectively.
  Their presence does not mean a fresh aggregate is running successfully.
- `storamic-dstore-abi`: `status=incomplete`,
  `error=STORAMIC_SOURCE_IDENTITY`, `qualification=false`. This is a malformed
  source-manifest handoff, not a DUT failure or a DUT pass.

No process was cancelled, no artifact was deleted, and no remote test was
launched during that audit. Disk exhaustion was observed earlier, but it alone
does not prove why each historical build stopped. Preserve that distinction.

Local checks for the audit: four offline preparation tests pass and both Python
files parse. `verify --dry-run` plans 25 aggregate steps and executes none; its
simulation preflight reports the local Verilator as missing two required patch
lines. This is a host-toolchain blocker, not a new DUT failure, and says nothing
about the separately validated remote private runtime. Full RTL lint, simulation,
formal, synthesis and timing checks remain pending. Tier/header inspection passed
for the changed first-party RTL and MIT tooling; the installed CLI has no
`diag run licensing` diagnostic, so no automated licensing verdict is claimed.

## Response ownership -- implemented and leaf-validated

The next bounded item is complete at selected-leaf scope:

- `rsp_pending_q` plus the response pulse own the interface until completion;
  held requests cannot be granted again while a reply is pending or visible.
- Error status and staged data/byte enables are captured at grant. A one-cycle
  SRAM read supplies committed bytes, overlaid only by valid staged lanes.
  Delayed responses use a captured merged word, not live request fields or a
  changing SRAM output.
- An accepted delayed access interrupted by power loss emits exactly one error
  response, even if power loss is held. Ungranted commands owe no response.
- Save completion and flash drain/flush completion wait for response retirement,
  not just an empty staging FIFO. No response is overwritten by a new grant.

The existing ports and configuration seam are unchanged. `RspCycles` adds delay
to the default response; the single-outstanding implementation also reserves the
response cycle, giving a minimum accepted-command interval of `RspCycles + 2`
clocks. This changes the service baseline and must be measured again rather than
compared as if the older implementation had identical admission behavior.

Timing impact: one additional retained 64-bit staged value, its byte mask and
response-ownership state; the default response path merges byte-masked SRAM
data, while delayed responses capture that merge. No clock/reset/domain changes,
new memory array, production ABI, ISA/DTS or feature-advertisement changes.
Compilation uses fatal latch/combinational-loop diagnostics, but synthesis/STA,
physical DFT and full aggregate coverage remain separate pending checks.

Evidence:

- Local WSL Verilator 5.020: delay 0 passes 51 checks; delay 16 passes 87.
  Logs: `build-platform/workspace/build/storamic-response-pass/`.
- Validated private Verilator 5.008 runtime recreated using the existing
  refuse-to-overwrite recipe in `storamic-response-runtime-r1`: original canary
  fails (18 mismatches), repaired canary passes (zero). Fixed-header SHA-256:
  `dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166`.
- Remote run `storamic-555acfbc60e9`: source/runner/runtime/compiler identity
  checked by the existing orchestrator; **selected stages pass**,
  `qualification=false`. Delay 0/1/4/16 passes 51/57/63/87 checks, respectively.
  All four deliberate negative-oracle runs return failure, contain the
  intentional check failure and contain no `DSTORE_PASS`.
  Receipt: `remote-runs/storamic-555acfbc60e9/output/leaf-result.json`.
- The `dstore` stage now runs these four delay profiles and their negative
  oracles by default. The bench includes partial/zero/complementary byte masks,
  changed live inputs after grant, one-reply accounting, response-before-flush,
  delayed-read interruption and held-cut no-repeat, plus the earlier save/replay
  and RAM-model cases.
- Four offline preparation tests still pass. Aggregate dry-run still plans 25
  steps and reports the local Verilator patch prerequisite missing; no full
  aggregate was executed, and the pinned remote runtime is independently checked.

No existing remote process was cancelled or artifact removed. The runtime
canaries and isolated dstore run were explicitly authorized. Native VirtIO reinit
at `FLASH_RSP=16`, primary AMOs and physical persistence are **not** qualified by
this leaf result; the backend response bugs were real but their relationship to
the native reinit failure still needs integration evidence.

## RAM checkpoint prerequisites -- implemented and leaf-validated

The source trace identified three concrete failures in the previous RAM model:
save startup could race a pending response, scan-save inherited live `mem_we_i`,
and an interrupted replacement invalidated/overwrote the only saved image.
These prerequisites are now repaired without changing the public ports:

- A control pulse is retained while the current memory response drains;
  memory admission closes immediately on the pulse and stays closed while the
  operation is pending or scanning. Simultaneous save/restore requests select
  save; requests during an active save/restore scan are not queued.
- Two images live behind one `tc_sram` boundary (twice the live RAM depth).
  Save writes only the inactive image. The retained selector and valid flag
  publish it on the final powered write edge. A cut at that edge suppresses
  both the write and publication; the old completed image remains selected.
- Restore pipelines checkpoint reads into live SRAM writes and signals
  completion only after the last write. No scan writes are permitted during a
  cut, and a partial restore cannot invalidate its retained source image.
- A power cut triggers a powered live-array clear scan before reopening
  admission. Previously a global zero-read mask hid newly written data after a
  cut while stale physical bytes could still be snapshotted. Clear now gives
  post-cut writes real volatile semantics and prevents stale bytes resurfacing.
  Restore/save pulses can wait behind clear; a further cut cancels them and
  restarts clear. This adds `NumWords` recovery clocks, not a free instant erase.
- A pending delayed memory response interrupted by a cut emits one error with
  its original tag. The response countdown width is now explicit at delay zero,
  and range checking includes the actual backing depth as well as ModelBytes.

Evidence: `storamic-7cd4d99acf53` passes the pinned remote dstore leaf at delays
0/1/4/16 with **73/79/85/109 checks**, including all four rejecting negative
oracles. The expanded profiles apply the selected delay to both RAM and flash;
they are not an independent cross-product bandwidth sweep. Source identities
match the current RAM RTL and bench. Local Verilator 5.020 passes delay 16 with
109 checks; four offline preparation tests pass. Compile diagnostics make latch
and combinational-loop warnings fatal. Receipt:
`remote-runs/storamic-7cd4d99acf53/output/leaf-result.json` (`qualification=false`).

New cases exercise no-checkpoint restore refusal, partial replacement save,
partial restore and retry, a cut immediately before final save publication,
save behind a pending write, live WE held high while saving, and complete
16-word image readback after replacement/restore. The earlier flash cases remain
in every profile. The source passes the manual tier/header check (RTL R, bench T).

Integration limits: the retained valid/selector bits survive only the model's
`power_cut_i`; controller reset clears them. These are not durable recovery
records, checksums, module identities or mapping generations. No production
NVM/health/energy capability or protected ABI is added. RAM and flash still have
separate scan/drain completions; neither proves that AXI/frontend queues have
quiesced. Full stick-wide coordination and reset/physical recovery remain open.

Timing/config note: this stays in the optional simulation memory binding,
with no ISA/DTS/config-layout changes, clock, reset or voltage-domain crossing.
The old raw shadow is replaced by a macro-bound two-image memory plus pipelined
scan control. It costs two RAM-sized checkpoint banks and a scan address mux/
bank-offset adder. It is not a silicon area, retention, DFT or 8-FO4 sign-off.
The full aggregate remains unexecuted: the dry-run plans 25 steps and still
reports missing local Verilator patches independently of the validated remote
runtime. No existing remote job was cancelled or artifact deleted.

## Development efficiency protocol

### AXI checkpoint admission prerequisite

ST-025A is now implemented: `quiesce_i` suppresses only new AW/AR admission;
accepted W beats, memory offers and B/R responses still drain. `quiesced_o`
requires the accepted contexts and memory owner to retire, not merely empty
backend ports. Current top bindings tie the request low pending coordinator
integration; this is no new native capability or software ABI.

Local checks pass the 29-check directed quiesce bench, its negative oracle,
six representative model profiles (64/512/8-bit, top 64/1024-bit and sequence),
two corruption oracles, standalone/top synthesis (zero latches/SCC), and
depth-12 model safety plus read/write/stale reachability. A focused quiesce
proof separately passes safety and successful paused read/write drain covers.
The formal-only leaf also passes with no Verilator/runtime present and rejects
a separately tampered source snapshot. Six offline runner tests pass.

The broader model checks exposed two stale oracles: WUSER must be legal, and
exhaustion refuses while accepted work remains but renews epoch after drain.
Their tests now assert those existing implementation contracts, including data
readback and epoch transition; malformed WLAST/strobe negatives remain.

Remote `storamic-ff64d04c5285` stopped on the old WUSER oracle; retry
`storamic-cd8cf2d11ad4` is incomplete after the shared Verilator prefix vanished.
The cache/toolchains roots were subsequently absent too. No cleanup/cancellation
was performed here. Local evidence is not a pinned remote or aggregate pass.
The aggregate dry-run still only plans 25 steps and executes none.

See [coordination work packages and receipts](checkpoint-coordination.md).

1. **Implementation lane:** work on a bounded module/contract slice. Name the
   accepted command, retained state, retirement edge and interruption behavior
   before editing. Add directed cases alongside the change, but do not wait on
   an unrelated full-core gate to continue source analysis.
2. **Offline handoff lane:** use the existing local orchestrator, not a hand-made
   tar manifest or `remote py run_remote.py`. Prepare and inspect the exact
   source hashes, runner hash, stages and runtime prerequisites:

   ```sh
   python verif/tb/storamic/run_remote.py --stages dstore --prepare-only
   python -m unittest discover -s verif/tb/storamic -p test_run_remote.py -v
   ```

   Preparation writes `storamic-run-manifest.json` and `launch-plan.json` under
   a new `remote-runs/storamic-<id>/`. Missing runtime arguments are recorded as
   launch blockers. `status=prepared` always has `qualification=false`.
   The plan references live source paths, not an immutable source archive.
   Re-prepare after edits; do not reuse an old plan as snapshot evidence.
3. **Validation lane:** launch only after authorization/resource preflight and
   with a validated private runtime record/header digest. The remote leaf checks
   runtime/canary/compiler/source identity; preparation never bypasses it.

   ```sh
   python verif/tb/storamic/run_remote.py --stages dstore \
     --runtime-record <local-runtime.json> --runtime-header-sha256 <sha256>
   ```

   `--runtime-record` requires the filename `runtime.json` and a sibling
   `canaries.json`. Alternatively use `--runtime-json` for an existing remote
   record. Do not guess either its path or its digest.
4. **Promotion lane:** retain result status, source/runner/tool identities and
   limitations together. Start with the affected leaf, then primary/IO integration,
   then aggregate lint/formal/sim/synth in an isolated checkout. Never run shared
   `make clean` from another development lane. Old green results cannot qualify
   changed source hashes; infrastructure-incomplete is not a code verdict.
5. **Resource discipline:** query a running job once for PID/parent, stage,
   heartbeat, result and disk status before polling it again. Use bounded waits
   and process-group timeouts in the runner; a timeout must not leave a Spike
   child consuming a core indefinitely. Do not relaunch byte-identical stalled
   builds without checking their child process, stderr and disk status.
   Disk cleanup, cancellation and retention changes require explicit approval.

## Next implementation order

The implementation work packages and cross-transport publication/drain contract
are now explicit in [`checkpoint-coordination.md`](checkpoint-coordination.md).
In particular, producer jobs must drain before RAM ingress is sealed, and RAM
image preparation must be separated from publication before stick completion.

1. Response ownership and partial-write readback are implemented and selected-
   leaf validated as described above. Promote this snapshot through native
   reinit/service integration and the isolated aggregate; do not infer that
   `FLASH_RSP=16` reinit is fixed solely from the passing leaf.
2. Specify a stick-wide quiesce/save/restore coordinator: drain accepted AXI,
   memory and store responses; freeze writes; complete RAM image plus flash
   drain; publish one completion. Restore must not expose a partial RAM image.
   Keep any injection-only testbench controls separate from the production ABI.
3. The RAM model now retains the previous image while writing an inactive bank.
   Still implement verified persistent metadata/commit records bound to module
   identity and map generation, including controller-reset recovery. Model
   bank selection is not that recovery protocol. Test each production boundary
   before admitting concurrent commits.
4. Define health/energy admission from ST-024 before advertising protection.
   Reserve backup space independently of virtio-blk capacity. Bad-block, full
   journal, reset, repeated save/restore interruption and degraded-protection
   refusal are ST-025 acceptance requirements, not optional future enhancements.
5. Resume primary atomic qualification and then Linux qualification as separate
   promotion gates. Do not expand into hyp RTL, optional virtio-mem/pmem, or a
   multi-entry journal simply to increase apparent task completion.

## ST-025 producer and RAM phase split (2026-11-05)

- VirtIO can pause new chains without resetting epochs or withdrawing accepted
  DMA/store offers. It completes active jobs through used-index publication,
  preserves paused notifications and reports reset/dead-engine errors. Device
  acknowledgement includes actual job state, not just transient port idle.
  The expanded device bench passes 137 checks; standalone ring/block/device
  positive and rejecting negative simulations pass on the frozen local snapshot.
- RAM external-commit mode prepares only an inactive image, latches bank choice,
  freezes admission until publish/abort and accepts recovered bank/validity from
  a metadata owner. It defaults off; current native bindings remain legacy.
  The final-restore-edge abort falsely signalled completion; the new regression
  exposed it and the completion is now masked/cleared.
- RAM component evidence: 139 checks at each delay 0/1/4/16, four negative oracles,
  external-mode synthesis with zero SCC/latches and legacy dstore delay-16 109
  checks pass locally. Seven offline preparation tests pass. The new
  `checkpoint-ram` stage preserves the existing runtime/source identity policy.
  Receipt: `build-platform/workspace/build/storamic-checkpoint-prepare-01/result.json`.
- No clock/reset domain, raw array, ISA, CSR or DTS capability was added. The
  producer pause gates registered job-start decisions; RAM adds prepared/bank
  state and admission/scan controls, not a CPU data-return pipeline stage.
  Existing SRAM boundaries remain. Status outputs expose the added state;
  scan/ATPG, physical timing/power and production observability remain unqualified.
- The native producer pause stays tied low; RAM external commit is not selected
  by an enabled SoC capability. C2 activation must add legal optional config,
  authorized control, explicit CDC where applicable and maintenance telemetry.
  No software persistence promise is enabled by these component primitives.
- Frozen producer synthesis/formal collection is independent of implementation.
  Aggregate `verify --dry-run` plans 25 steps and executes none. Shared smoke
  cleanup was not authorized/run. Licensing/header/upstream-notice audit passes
  for 16 touched code files; the documented licensing diagnostic is absent from
  this checkout's configured diagnostic list, so the audit is explicitly manual.

Next implementation is C2: pause every enabled writer before sealing RAM,
prepare/flush, commit validated metadata last and hold recovery locked after a
cut or failed restore. D must replace the external-selector fixture with actual
reset-recoverable identity/map-bound records and reserved backup accounting.
E/ST-024 must enforce qualified protection health/energy. ST-025 remains open.

### ST-025D Reserved Media and Composed Model Update

- The reset-recoverable reserved-flash owner, full-width codec/layout functions,
  freeze-only RAM mode and user word-capacity guard are implemented. Native
  protected capability remains unadvertised.
- Frozen component simulation passes 17 profiles and 17 rejecting oracles:
  codec 659 checks, guard 54, media 336 at 0/1/4/16, RAM 139 at 0/1/4/16,
  dstore 85/91/97/121 and coordinator 115 at 0/4/16.
- Generic primitive synthesis passes with no latches/SCCs. Full-width
  combinational codec/layout SMT safety and its negative oracle pass.
  Independent coordinator safety/reachability/oracle and synthesis pass.
  I/O safety/oracle pass at depth 12 with full namespace inputs and a shortened
  lease model. Full depth-24 safety times out under SAT and SMT and remains open;
  neither timeout is a pass or replaced by the shorter receipt.
- The new `g6lc_storamic_checkpoint_model` composes real record/copy ownership,
  RAM/flash grant-owned response muxing, retained flush ownership, reserved
  user capacity, all-writer/ingress exclusivity and explicit resume. It requires
  providers as inputs and does not introduce a magic-key software ABI.
- Final composed snapshot `storamic-8e7f649ed1eb` passes 85 checks at each
  response delay 0/4/16 plus three rejecting oracles. Separate
  `checkpoint-model-synth` passes with 1,360 generic cells, four model memories,
  zero latches/SCCs. Strict synthesis required moving durable-store declarations
  before use; no commit/replay logic changed.
- Eleven offline preparation tests pass. Scoped manual header audit covers
  20 checkpoint code files. Owner exception remains documented; no CLA is
  created/signed. Full aggregate dry-run plans 25 steps and executes none.
- Receipts are local-only, source-hashed and `qualification=false` under
  `build-platform/workspace/build/storamic-checkpoint-record-01/`.
  Remote tools/runs were not changed or promoted.

Next: resolve the deep I/O obligation independently, then add legal optional
native configuration and real per-writer, authorization, cache/reservation and
device synchronization bindings. Do not activate native protection merely
because the composed model passes. Raw-NOR geometry/ECC, energy, degraded
admission, physical faults, native stretched-response and Linux gates remain
separate. See `docs/03_cva6_design/storamic_checkpoint_model.md`.

### ST-025 I/O Proof Closure and Policy-Bound Control Increment

The previously timed-out combined I/O query is now partitioned without removing
assertions or restricting inputs. Transport safety passes at depth 24. Nonce
safety passes an 8-step reset base and temporal induction (successful at step 6),
with asserted allocation/accepted-tag invariants. Namespace inputs remain full
32-bit and arbitrary; the lease remains the original shortened 1+1-bit model.
All four response/stale/exhaustion/renewal covers and both rejecting oracles pass.
Old SAT/SMT timeouts are preserved and are not relabeled as passes.

`g6lc_storamic_checkpoint_service` implements paired AW/W ownership, captured
address authorization, sticky pending-command policy revocation, attributable
cookie-based result acknowledgement, backpressured responses and coherent
generation reads. It is an uninstantiated model component, not native privilege
enforcement. An accepted controller command retains its admission; platform
policy changes must synchronize/drain active operations.

Directed service simulation passes 53 checks and a rejecting oracle. Separate
formal safety depth 16, command/revocation/ack covers 10/12/10 and a rejecting
oracle pass. Generic synthesis reports 132 cells with no latches/SCCs.
Twelve offline preparation tests pass. Proof collection now writes selected-check
progress before later checks, while retaining the final failed/incomplete verdict.
Receipts are local-only under
`build-platform/workspace/build/storamic-checkpoint-next-02/`, qualification=false.

Next native implementation still requires `CVA6Cfg` gating/legality, a genuine
transaction protection-domain provider, real writer acknowledgements, descriptor
and reserved-capacity binding, and cache/reservation/device synchronization.
No CPU config, native activation, PMEM/DAX capability or Linux ABI is changed.
Physical flash/ECC/protection/energy, remote native stretched-response, aggregate
and Linux qualification remain open. See
`docs/03_cva6_design/storamic_checkpoint_service.md`.

### ST-025 Composed Control/Memory Endpoint

The new default-off endpoint composes the policy-bound control service, AXI
memory ingress and real reserved-media checkpoint backend. Its static
configuration/type/layout checks also choose a synthesized refuse-only branch
for unsupported configurations; inactive or illegal layouts instantiate no
model memories. Runtime policy/identity/protection/descriptor/synchronization
availability is explicit and cannot be replaced by an endpoint-generated
acknowledgement. Writer/job and resume acknowledgements remain separate inputs.

The integration lane exercises MMIO-triggered publication/restore, protected
result consumption, accepted-response draining, real writer/resume waits,
controller-reset discovery, active/idle provider loss, explicit recovery and
interrupted MMIO saves. A premature restore after provider return was refused:
metadata rediscovery readiness must be polled, not inferred from four elapsed
cycles. This is an updated driver/test obligation, not a weakened RTL check.

The component is not instantiated in the native backend. The new default-off
`CVA6Cfg.StoramicCheckpointEn` request is propagated through the builder and
native harness, with explicit defaults in all 37 tracked target packages and a
normalized-primary-role legality check. An unbound native request rejects at
elaboration and synthesizes the existing off/refusal profile, never legacy
volatile RAM. CPU permissions, maps, DTS/ISA discovery and native capability
advertisement remain unchanged. The next native increment must select the
endpoint through a legal optional configuration and connect genuinely qualified
privilege, persistent identity, protected capacity, health, all-writer and
cache/reservation/device providers. A qualified service input is not AXI PROT
alone. Preserve the VirtIO-job-before-DMA-adapter drain ordering.

The shim retains zero AWPROT/ARPROT in the default-off profile. Optional
transaction-carried origin now has an implementation through the scalar LSU,
store/WT queues and adapter; it is not qualified or bound as service authority.
The CPU's live privilege level at AXI remains insufficient. Next implementation
tasks must qualify that transport and establish a trusted-master route, then
bind CPU/job pause, cache/reservation/device synchronization and
descriptor/protection providers. Do not replace these dependencies with a new
flag or idle-only ACK.

The endpoint leaf passes 1,229/1,370/1,802 checks at 0/4/16-cycle response delay,
four rejecting oracles and disabled/illegal-layout cases. Inactive/illegal
formal safety and their oracles pass independently. The native configuration
lane passes 37 elaborations and six directed configuration/integration cases.
These are local source-frozen component results, not native system qualification.

Receipts and implementation/validation lanes remain separate under
`build-platform/workspace/build/storamic-checkpoint-endpoint-03/`.
No remote runtime, active run, shared cleanup or physical qualification is
changed by this integration candidate.

### ST-025C2B2 Origin Transport Candidate

`docs/03_cva6_design/storamic_transaction_origin.md` records the source, lifetime,
SoC encoding and remaining admission boundary. New behavior is requested only
by the existing default-off checkpoint flag. Unsupported CPU profiles, implicit
writers, cacheable traffic and atomics cannot acquire machine authority.
WUSER remains payload/AMO metadata.

Frozen component checks pass: shim 36 each off/on; LSU/store queue 52; complete
WT cache 88 each off/on; adapter 48 cases across origin/allocate profiles.
Rejecting oracles accompany each. A corrected direct-buffer formal harness
passes depth-8 safety, reaches two retirements and rejects the wrong pointer
assertion. Early cache synthesis has no latches or SCCs; 37 default-off target
packages elaborate. Earlier driver/harness failures are superseded, not promoted.
All attempts are retained under
`build-platform/workspace/build/storamic-origin-04/`.

Full-core configuration/default-netlist, synthesis, timing, compliance,
observability/DFT, remote/native and Linux gates remain open for this candidate.
No remote query/run, installation, shared cleanup or native activation occurs.

### ST-025C2B2C Route Preservation Candidate

The native route audit identifies crossbar-added master prefixes, but the
existing AXI-to-Lite bridge drops PROT. The new default-off
`g6lc_storamic_checkpoint_route` preserves a captured master/origin/shape/policy
decision and sticky epoch/readiness revocation across that real bridge.
It composes with the real checkpoint service in component tests; it is not
wired into the native harness or advertised as a protected software ABI.
The attach interlock and production defaults are unchanged.

Local `storamic-route-05/sim-r2` passes 837 checks each off/on, both rejecting
oracles and illegal ID-geometry rejection. `checks-r2` passes depth-16 safety,
four covers and an invalid-assertion oracle. Its only responder assumption is
the downstream AXI-Lite B hold contract; identities/origins/epochs/readiness
remain unrestricted. Coarse synthesis off/on is 220/291 RTLIL cells without
latches/SCCs. Four offline containment/evidence-preservation tests pass.
The interrupted `sim-release` and earlier unconstrained-responder proof attempt
remain incomplete/failed, not passing evidence.

See `docs/03_cva6_design/storamic_checkpoint_service.md` for port wiring,
policy ownership, clock/scan/timing notes and reproducible local commands.
Next dependencies remain full-CPU qualification, actual native service/master
binding and enabled-writer/descriptor/cache-reservation-device providers.
Physical, approved remote/aggregate/compliance and Linux gates remain pending.

### Real Mux Boundary Follow-Up

The isolated `storamic-interconnect-06/mux-r4` snapshot exercises the real
Pulp mux, physical ID insertion, AW-owner W FIFO and optional request spill
before the real route/service. Four off/on authorization/request-spill
profiles pass 669 checks each, including peer W without AW and response
ownership assertions, with four rejecting oracles and invalid-geometry refusal.
The updated direct route baseline and route-only depth-16 proofs/coarse
synthesis pass separately. Those proofs do not cover the mux or full CPU.
Earlier macro-closure, aggregate scheduling and W-first fixture failures are
retained. The fixture now tracks early accepted W beats instead of assuming
acceptance waits for its task to return.

This pass changes verification/tooling only: no production RTL timing, reset,
DFT, PMA/DTS/config or native capability change. Next is full-CPU source-frozen
default/enabled elaboration using the platform's existing resolved manifest
and tool context; do not hardcode a new target/tool selection or promote
preparation into execution. Actual policy/provider/writer bindings and all
remote/aggregate/physical/Linux dependencies remain open.

### Configured Full CPU Elaboration Diagnostic

The next lane reuses the platform's resolved target and canonical manifest.
`storamic-cpu-07/snapshot-r3` freezes 264 files / 276 hashed inputs for
`cv64a6_imafdc_sv39`. Local full-CPU hierarchy elaboration passes with origin
transport disabled/enabled; a deliberately unsupported enabled profile rejects
by its named wrapper assertion. Frozen/live identity and scoped tooling license
checks pass. No production RTL change is made.

This is elaboration, not CPU execution, default-netlist identity, native
crossbar composition, timing/DFT, aggregate or Linux qualification. Bare external
CPU ports are intentional and cannot establish runtime correctness. Next work
must execute privilege/provenance traffic and qualify the complete crossbar
path before native service/policy/provider admission changes.

### Protected-Target Crossbar And Profile Follow-Up

`storamic-crossbar-09/xbar-r5` passes 669 checks in each of four real-crossbar
authorization/request-cut profiles, four rejecting oracles and invalid-ID
geometry refusal. This is the protected target of a three-source/two-target
fixture. Its unused target is monitored never to be selected; neither its
atomic responses nor arbitrary native topology are qualified.

The scalar support predicate now also requires the I/O role, no accelerator
and `COPRO_NONE`. The actual Ara attachment can share the physical cluster
upstream path: that prefix alone is not scalar provenance. Native multi-core
and shared-master composition remain separately unqualified. This tightening
is compile-time-only, behind existing optional configuration, with no new
state, clocks, resets, runtime latency, ISA/CSR, PMA/DTS or Linux capability.
It has no new scan/PMU storage to bind; default-netlist identity, technology
timing/power, aggregate/compliance and physical gates are not inferred.

`storamic-profile-10/origin-r2` passes 54 positives and 54 rejecting oracles,
including 12 profile checks. The new regression rejects the prior predicate
on an attached accelerator. Queue/cache fixtures now state the legal scalar
I/O role explicitly. Fresh `storamic-cpu-07/elab-r4` repeats off/on full hierarchy
elaboration and unsupported-profile rejection; the scoped source/license audit
retains the upstream header. These results do not establish CPU execution.

The new real-CPU M/S/U/MPRV program fixture remains unexecuted. Configured
Verilator strict diagnostics stop compilation in both origin profiles.
Independent Yosys analysis finds two coarse cell-level SCCs; after mapping
only their cones and optimizing, zero SCCs remain. Full bit-blasting timed
out without a verdict. No scalar-feedback diagnostic is waived and no
functional CPU refactor is justified solely by the coarse report.

The dependency-ordered completion plan is `completion-plan.md`. In particular,
native policy lifetime must include upstream fabric ownership, not only the
route and endpoint holds. Genuine producer pause/drain, descriptors,
cache/reservation/device synchronization, physical protection, approved remote
integration and Linux gates remain open. Native activation remains refused.

### Debug-Issue Source Exclusion And Registration

The source audit found that debug-mode issue was not distinguished at LSU
capture. The existing `ex_stage` debug signal now reaches the LSU encoder;
debug-issued operations receive unknown origin irrespective of effective
privilege. The context is explicit in the encoder API, with no implicit trusted
debug default. Existing queued origins do not change on later debug transitions.
No native service binding or activation is added.

`storamic-debug-12/origin-r1` passes 54 positives and 55 rejecting oracles:
28 profile checks (all 16 privilege/virtual/debug combinations), shim 37
checks each off/on, queue 76, plus existing cache/adapter cases.
Fresh `storamic-cpu-07/elab-r5` passes off/on full hierarchy and unsupported
profile rejection. Runtime CPU/debug and configured strict scheduling gates
remain open.

The platform tests also exposed missing checkpoint sources in the testharness
Makefile and a package-after-module order in `Flist.storamic`. The two lists now
match at 23 entries with packages first. Seven Storamic platform tests and
typechecking pass. The full platform unit run records 291 passes, one skip and
one unrelated AI-overlay package/DTS consistency failure; no user-owned AI
artifacts are regenerated.

Debug exclusion adds only one local encoder qualifier in the existing
configuration-constant origin branch. There is no new state, tag width, clock,
reset, memory, pipeline stage, ISA/CSR, DTS range or Linux capability.
Default-off netlist equivalence, mapped timing/power, DFT and native debug/
policy synchronization remain unqualified. Actual configured nonsimulation
gates were interrupted without final invocation receipts. Eleven formal tasks
have individual PASS statuses; the complete 17-task suite and synthesis have
no final verdict. They did not execute the unsafe shared-cleanup simulation
smoke and do not qualify full aggregate/compliance.

### CPU Interpreter Diagnostic Follow-Up

The full-configured CPU interpreter attempt `storamic-cpu-interpreter-13/exec-r4`
remains incomplete, alongside the archived CXXRTL compilation timeouts. No
configured CPU instruction/debug execution qualification is claimed.

The test-only netlist wrapper now has a default-off `IntegerDiagnostic`
parameter that disables RVF/RVD through the existing user configuration builder.
It does not replace the actual CPU, scalar LSU, queues or cache with a shim.
`startup-int-r1` completes 40 interpreter cycles, including 33 post-reset
cycles, in each origin mode without an assertion failure. Its overall receipt
remains incomplete for qualification, with startup success reported separately;
it has not established full program completion or configured FPU behavior.

Generated RTLIL reuse now requires a recorded artifact digest and matching
source/wrapper/profile identity. Legacy receipts without that digest cause
regeneration rather than unverified reuse. The startup probe cannot satisfy the
normal program gate: that still requires completion, all five writes/four reads
and the rejecting origin oracle. These changes are MIT test/helper changes
only; no production state, timing path, PMA/PMP, DTS or capability changes.

### Configured CPU Instruction Execution

`storamic-cpu-interpreter-13/configured-execution-r1` passes the complete
six-case configured-target interpreter matrix: origin transport off/on,
response delays 0/16, four successful programs and two rejecting origin
oracles. The real configured `cv64a6_imafdc_sv39` CPU, CSR, scalar LSU, queues,
WT cache and FPU are retained. Each positive reaches software completion with
all five writes/four reads, including M/S/U and MPRV with MPP=S. No CPU
privilege or LSU/cache implementation is substituted by the host fixture.

The collector verifies source/ROM/model/script/log artifacts and consistent
source/tool/program identities, and requires full-profile generation receipts
for both CPU models. Four rejecting collector checks refuse partial, startup,
integer-only and out-of-workspace inputs. A separately altered RTLIL copy is
rejected before tool invocation; the original model remains unchanged.

Earlier interrupted/full-C++ attempts and the insufficient 1,000-cycle delayed
integer run remain archived. The configured delayed cases use the original
5,000-cycle budget and complete. Zero-initialized two-state interpretation does
not qualify four-state reset behavior, the FPU instruction set, default-netlist
identity or the unresolved strict Verilator scheduling gate. Real CPU debug
entry/exit and adversarial queued mode transitions remain open. Additional
MPRV coverage is recorded below. CPU AXI response delay is not native flash recovery qualification.
Native checkpoint admission remains refused.

### Extended MPRV Instruction Execution

`storamic-cpu-schedule-14/extended-execution-r1` passes six configured CPU
cases: origin off/on at response delays 0/16, with four successful programs
and two rejecting origin oracles. Every positive completes seven writes/six
reads. The added phases execute in M while MPRV selects MPP=U and MPP=M;
the earlier MPP=S phase remains. The same genuine configured CPU models are
reused with verified source, wrapper, RTLIL and tool identities.

The optional test-only host mode and firmware metadata require the extended
counts and all expected data bytes. The original default firmware is
byte-identical, its five-write/four-read gate remains separate, and a current
default-host execution passes. Six generator tests and nine collector tests
pass; the latter reject old counts, missing cases/model origins, disabled
extended checks, integer diagnostics and mismatched model sources.
A separate wrong-MPP=U oracle also rejects at the named third-write/two-read
observer. Its two complementary assertions retain the original `!failed`
contract while identifying that phase. An earlier collection attempt could
not obtain counters from the assertion-aborted VCD and remains archived,
not promoted.

These are two-state instruction/provenance results, not complete MPRV,
four-state reset, FPU ISA, debug, native, physical or Linux qualification.
Fresh strict Verilator diagnostics on frozen `snapshot-r6` still fail with
11 errors off and 12 on. A narrow workspace-only CSR isolation experiment
does not change those counts and supplies no basis for a production RTL fix.
That MPRV extension makes no production RTL, clock, reset, timing path, config,
DTS or capability changes.

### Configured M-Mode Debug Round Trip

`storamic-cpu-debug-15/debug-execution-r1` collects four full configured CPU
programs and two rejecting debug-origin oracles, origin off/on and response
delays 0/16. Each positive completes six writes/four reads, including three
debug writes/two debug reads and two CSR-value checks. Firmware reads the real
DCSR/DPC, updates DPC architecturally and executes DRET; post-return traffic
must carry the M origin. No CPU state is forced by the fixture.

The failing frozen baseline enters debug and saves DPC but fetches mtvec
instead of the halt vector. A workspace-only priority correction predicts
and restores the debug fetch and full round trip, then lands in
`core/fetch_B/g6lc_fetch_pkg.sv`. Debug redirect now wins its simultaneous
exception. Other non-debug priority behavior is exhaustively unchanged.
The corrected formal contract passes safety/induction and all nine covers;
the original selector rejects the new unrestricted combinatorial proof.

The first off/zero execution and the platform lint/synthesis invocation were
interrupted without final verdicts. A fresh off/zero retry completes; its
successfully generated, identity-pinned CPU model is linked separately by the
collector. The incomplete execution is not counted as a successful case.
The platform invocation is not an aggregate pass. Fresh strict scheduling
still fails with 11 errors off/12 on.

Scope is two-state M-mode external-request debug only. S/U/debug-MPRV,
single-step/breakpoint, virtualization/SMT and adversarial queued transitions
remain unqualified. No new state/clock/reset, native provider, PMA/PMP rule,
CSR encoding, DTS or capability is added. The existing selector priority
changes; physical timing/PPA and full aggregate/compliance remain open.

### Supervisor/User Debug Round Trips

`storamic-cpu-debug-privilege-16/collected-s-r1` and `collected-u-r1` pass
independent origin off/on, delay 0/16 matrices: eight complete programs and
four rejecting debug-origin oracles in total. Each positive retains all six
writes/four reads, debug three/two and two CSR checks. Test firmware installs
an unlocked all-address PMP entry, sets MPP/MEPC and executes real MRET into
S/U before requesting debug. DCSR must save S/U, DPC must point into that
entry, debug data remains unknown and post-DRET data must regain S/U tags.
No internal CPU state is forced; the configured FPU remains present.

The 2,000-cycle delay runs stop short, with two CSR checks and all debug data
checks complete. Their checkpoints trail the prior M run by about 536
cycles, matching added PMP/MRET setup. Unchanged 3,000-cycle retries pass.
The S origin-off zero-delay run hits its wall-time limit; complete
1,000-cycle zero retries pass for both S/U. Initial receipts remain archived;
failed/timeout cases are not counted.

Default M ROM bytes remain identical; the new host's M regression and the
legacy six-case collector both pass. Forty-one Python tests, seven platform
checks, typechecking and the ten-file MIT/source audit pass. All CPU inputs
and the full-CPU wrapper match the prior frozen identities.

This pass changes verification only: no production RTL/config/protection,
clock/reset/state, CSR/DTS capability, PMU/scan or silicon timing/PPA change.
PMP setup belongs to the fixture, not a production permission relaxation.
Evidence remains two-state external-request debug, not complete debug/ISA
qualification. Queued transitions, combined debug/MPRV, breakpoint/step,
virtualization/SMT, strict scheduling (11/12), native providers, physical,
aggregate/compliance and Linux gates remain open.

### Pending Firmware Traffic Across Debug Entry

`storamic-cpu-debug-queue-17/collected-r1` passes 20 configured CPU cases:
14 full six-write/four-read programs and six rejecting debug-origin oracles.
M covers AW/W/B holds, origin off/on and read delays 0/16; S/U add the
origin-enabled B boundary at delay 16. Each hold lasts 192 cycles, triggered
by actual offered/accepted firmware traffic. DCSR/DPC, unknown debug traffic,
DRET, resumed origins and all original counters remain checked.

Read-only Yosys output aliases expose actual CPU debug mode and protocol
signals after flattening the pinned CPU and verification host. They do not
drive stimulus, privilege or authorization. The collector permits the exact
instrumentation command list only, rejects forcing commands even with a
recomputed script digest, verifies all artifacts and samples pre-edge
handshakes against post-edge debug transitions.

Four zero-delay M AW/W cases complete the original response before entering
debug. Delayed-read M AW/W cases instead enter with the original address/data
still held, retaining firmware origin. All M/S/U B cases enter before the
firmware response. Total: ten actual pending-entry crossings, four observed
drain-order cases. The zero-delay observation is not a universal pipeline
drain rule. No RTL change follows from this interleaving difference.

Six named RTL origin oracles reject; six enabled-crossing trace oracles also
reject the false rule that live debug state relabels the prior transaction.
The latter are trace predicates, not RTL semantic mutants. Fifty-seven
Python tests, seven platform checks, typechecking and the nine-file MIT/
identity audit pass. CPU inputs, models, original host and wrapper remain
unchanged. No new production state, clock/reset, timing/PPA, scan/PMU,
PMA/PMP/config/CSR/DTS capability or native provider is introduced.

This remains two-state, tested-stage/profile entry evidence only. Debug
transactions pending across DRET, combined debug/MPRV, other queue classes,
breakpoint/step, virtualization/SMT, strict scheduling (11/12), native policy/
writer/synchronization, physical, aggregate and Linux gates remain open.

### Debug-Issued Response Across DRET

`storamic-cpu-debug-return-18/collected-r1` passes 18 configured CPU cases:
12 complete programs and six rejecting named debug-origin oracles. All M/S/U
profiles cover origin off/on and read delays 0/16. A separate firmware/host
gate requires seven writes/four reads, debug four/two and two CSR checks;
none of the earlier six-write gates or images changes.

The new debug write is issued after the final verification load/fence and
before DPC update/DRET, avoiding a test-created same-address read dependency.
Its response is withheld for 384 cycles. Actual read-only CPU-mode observation
confirms DRET occurs between that write's W handshake and B handshake in
every positive case. Its captured debug origin stays unknown; resumed traffic
has the expected M/S/U origin. Six enabled false-live-return trace oracles
reject relabeling that prior debug transaction as trusted firmware.

The collector checks firmware-generation metadata, exact seven-write counts,
complete profile coverage, canonical read-only scripts, original CPU model/
generation/source/tool identities and instrumented-netlist/VCD hashes. The
six RTL origin oracles reject the deliberate wrong expectation at the target
debug AW; the return-direction trace oracles are separate counterfactual
checks, not RTL semantic mutants. Seventy-six Python tests, seven platform
checks, typechecking and a scoped 12-file MIT/source audit pass. The preceding
queue corpus, original CPU inputs/models, hosts and wrapper are unchanged.

No production RTL/config/state/clock/reset, timing/PPA, scan/PMU, PMA/PMP,
ISA/CSR/DTS or native provider changes. This is two-state response-ownership
evidence, not a physical timeout, universal drain rule, privileged/debug ISA
compliance, FPU instruction test or complete queue qualification. Combined
debug/MPRV, remaining queue classes, breakpoint/step, virtualization/SMT,
strict scheduling (11/12), native owners/providers, physical, aggregate and
Linux gates remain open.

### Checkpoint Writer Model24

Default-off model composition now binds the endpoint to the actual VirtIO
writer and DMA bridge, retaining external upstream/resume/provider facts.
Ten selected frozen stages pass at `storamic-all-f8d457c509b4`, including six
simulation profiles and strict synthesis/refusal proofs; both synthetic-ACK
hardware mutants reject. The original boot-fixture, off-property, deadline and
IN-direction failures stay archived. The composed default32768 deadline covers
two CRC passes; the explicit8192 timeout still requires lock and real drain.
This does not change the native/system gates above. See
[checkpoint-writer-model.md](checkpoint-writer-model.md).

### Writer Reset/Error Model25

Eleven selected stages pass at `storamic-all-208113170860`; independent
`storamic-all-3eb75e609eb6` repeats reset profiles and the original coordinator
safety/covers/oracle. At response delays 0/4/16, a real MMIO reset during
accepted OUT/save propagates one producer error without checkpoint publication,
preserves the old generation and supports explicit restore/ring reinitialization.
CSync holds for 500 cycles after copy completion until external permission.
Both dropped-error and forged-resume hardware mutants reject; source-post and
live source identities match. No production RTL correction was justified.
This is a bounded C4/C5 component advance, not native owner/cache/fabric,
power-cut, physical, aggregate/compliance or Linux qualification. See
[checkpoint-writer-reset.md](checkpoint-writer-reset.md).

### Shared DMA Ownership26

Implemented trace-backed W/address ownership, stalled AW/AR retention and
bounded credit admission in the existing shared adapter. Original RTL puts
upstream payload at DMA address 0x9000; the fix rejects unowned W while
allowing W against a visible AW without waiting for AWREADY. A signed credit
tracks WLAST preceding its offered AW. Thirteen selected stages pass at
`storamic-all-ad66348d684f`, including all six new formal queries and
composed save/restore/reset. Exact-fixture original replay rejects all seven
profiles and produces a SAT counterexample. Generic active composition is
3085 cells (+41), four memories; off/invalid remain 93/no memories, all zero
latches/SCCs. No native/provider, CPU/cache/fabric, physical or aggregate
qualification follows. See [dma-ownership.md](dma-ownership.md).

### Policy Writer27

Default-off model composition now binds the manager to actual writer pause,
MMIO seal and endpoint/DMA ownership, while upstream queue/route/maintenance
holds and all authority/provider/resume facts remain external. Ten selected
stages pass at `storamic-all-518de1685e41`; both exact-fixture wiring mutants
reject, all source/post and 22 simulator PGO identities verify. Active
composition3156 cells (+71 over writer), four memories; off/invalid93/no
memories, all zero latch/SCC. Active provider loss retains the owner and
requires explicit common reset/rediscovery in the tested recovery path;
there is no automatic provider/queue revival. See
[policy-writer-model.md](policy-writer-model.md) and the bounded
[native inventory](native-provider-inventory.md). Native C3-C6 remain open.

### CPU Retirement Defaults29

Fresh CPU28 diagnostics with the pinned repository compiler distinguish a
packed-FP representation limit from four two-port retirement latch errors.
The minimal assignment-completeness correction now passes public one-/two-port
simulation, nine formal queries and strict generic synthesis in the seven-stage
snapshot `storamic-all-c9e274ae2823`. Generic cell counts are 797/1231, with
zero memories/latches/SCCs. Original RTL rejects the unchanged public fixture
at the expected four latch errors. All 157 source identities match; nine
simulator profile-use builds verify, while two intentionally illegal config
models retain explicit no-profile refusal evidence.

The full-type prototype remains separate from the public minimal-type fixture.
The configuration sweep covers 37 packages, not 37 executing/synthesized CPUs.
No new state, clock/reset, permission or software ABI is added. The unwaived
FP-representation/defaults probe still reports 28 scheduling errors off/on;
older local-tool 11/12 counts are historical. No vendor waiver or FP disabling
is introduced. C0, native providers/cache/fabric, physical, aggregate/compliance
and Linux gates remain open. See [cpu-commit-defaults.md](cpu-commit-defaults.md).
