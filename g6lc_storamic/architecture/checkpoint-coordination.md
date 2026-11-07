# Checkpoint coordination: next implementation sequence

Status: implementation contract, not an advertised capability. ST-025 stays open.
The leaf results in `development-status.md` validate component behavior only.

## Architecture inference

The native RAM and virtio-blk transports should remain separate views of one
stick, not be replaced by a new transport. Their durability boundaries must be
coordinated explicitly:

- The RAM model now retains an inactive/active image pair, but automatically
  selects the new image at the end of its own scan.
- The flash model drains staging independently; the stick wrapper's save
  completion refers only to that drain.
- Native integration discards RAM busy/restore completion and flash save
  completion. Its testbench triggers are not a coordinated software ABI.
- The AXI frontend already tracks accepted work through final B/R retirement in
  `inflight_o`. The device already owns ring/backend/shared-DMA state. Its
  existing reset-idle outputs only describe live port work, not the entire job:
  they can be true between beats or during descriptor handoff. Derive explicit
  job-paused acknowledgements from these state owners, not competing counters
  or the old port-idle signals alone.
- Neither transport exposes a non-reset persistence quiesce handshake today.
  Reset is not a safe substitute: it changes epochs and queue ownership.

A combined `done = ram_done && flash_done` is insufficient: RAM must not replace
the selected checkpoint before the whole declared checkpoint is recoverable.
Split RAM prepare from publish/abort before declaring coordinated completion.

## Ordered operation

1. Validate operation, permissions, protection health, identity/map generation
   and backup capacity. Serialize maintenance operations.
2. Pause new work at every producer/job boundary; existing DMA jobs retain
   access to RAM until they finish. Include AI and other enabled writers, not
   just virtio-blk.
3. Once producers drain, seal new RAM AW/AR admission. Continue accepted W beats,
   memory commands and B/R responses until final retirement. Do not lower the
   backend's static readiness to represent a temporary pause.
4. Freeze the drained RAM image and map. Prepare the inactive image, drain the
   relevant flash writes, and validate both results without publishing a new
   recoverable checkpoint.
5. Write verified metadata and publish a final commit record last. Only then
   change the selected generation and emit one sticky, attributable completion.
   Abort retains the previous valid checkpoint.
6. For restore, hold admission closed throughout metadata validation and image
   reconstruction. Resume only after the last write and required cache/
   reservation synchronization. A cut returns to recovery, not normal service.

Cache clean/fence and producer ordering are explicit caller/platform obligations
until their hardware protection domain is implemented. An AXI-Lite doorbell does
not order independent data writes. Do not seal RAM before draining a DMA job
that still needs RAM to finish: that ordering deadlocks.

Pause a VirtIO producer at the ring's new-chain boundary, not at the backend's
handoff: a descriptor chain already being fetched must still enter the block
engine and complete its status/used-ring writes. Preserve pending notifications
and queue epochs while paused. A port-idle bubble is not permission to snapshot.

Restoring RAM is not CPU hibernation. Queue indices in a restored image cannot
be combined with newer volatile VirtIO cursors. Either exclude transient
queue/driver state from the protected persistence contract or explicitly
reset/rebind it before software resumes; persisting a whole machine's device/
CPU state is a separate contract. Apply the same ownership rule to caches and
LR/SC reservations.

## Session work packages

| Package | Deliverable | Completion boundary |
| --- | --- | --- |
| ST-025A | AXI frontend `quiesce_i`/`quiesced_o`; suppress only new AW/AR, keep accepted W/B/R live | Directed admission, held-grant, burst, response-backpressure, simultaneous-read/write and error-drain cases; production tie-off until coordinator integration |
| ST-025B | Non-reset producer pause/drain for VirtIO and each enabled DMA source | No new job starts after pause; accepted job finishes with unchanged queue/reset epoch; no early RAM seal |
| ST-025C | RAM prepare/publish/abort and one stick-level maintenance coordinator | No partial cross-chip publication; completion after both participants and the selected commit record; timeout/error/cut preserve old checkpoint |
| ST-025D | Reset-recoverable checkpoint metadata and backup accounting | Version, persistent module identity, map generation, sequence, image extent/length, integrity and final validity record; no alias with exposed block capacity |
| ST-024 / ST-025E | Protection-domain, health and energy admission | Worst-case dirty state fits guaranteed backup time/energy; degraded/full/bad-block cases refuse new durability promises |

ST-025A is a foundational frontend interface, not a claim of native stick-wide
quiescence. Its initial top-level bindings keep the request tied low, preserving
existing behavior while later packages own the integration.

Metadata must be recoverable after controller reset, not just retained across
the model's `power_cut_i`. A checksum alone does not provide atomic publication;
select between independently valid records and define ambiguous/corrupt-record
refusal and sequence exhaustion explicitly.

## Promotion and completion

Keep implementation and validation lanes independent using frozen source/runner/
runtime identities. Validate affected components first; then the coordinated
native CPU/DMA path, native response-delay reinit, isolated aggregate gates,
stock Linux block, and finally protected PMEM/DAX. Optional virtio-mem/pmem and
multi-queue scaling stay behind their own gates.

Physical completion also requires the selected electrical/media profile, RAM
and flash engines, ECC/MBIST, reserved backup capacity and hold-up design.
There is no defensible percentage-to-tapeout from the current model passes.
No physical media, Linux persistence, DFT or 8-FO4 sign-off is inferred here.

## ST-025A session checkpoint

The frontend now has quiesce/ack ports: only new AW/AR admission is suppressed;
existing memory offers, W beats and B/R responses continue. All current top
bindings tie quiesce low. Local Verilator 5.020 passes the new 29-check bench.
The formal model now allows arbitrary quiesce requests and checks acknowledgement
against its independent accepted-work scoreboard; depth-12 safety and existing
read/write and stale-response reachability pass locally.

The new provenance-aware `quiesce` leaf stage runs positive/negative oracles.
Six offline runner tests pass. The first pinned selected-stage run
`storamic-ff64d04c5285` exercised quiesce successfully, then found the historical
model oracle still requiring SLVERR for legal nonzero WUSER. That test now
requires successful write/readback; malformed WLAST/strobe negative cases remain.
A debug print also referenced optional AW.atop absent from the reference type;
that diagnostic field was removed without changing datapath behavior.

Retry `storamic-cd8cf2d11ad4` passed quiesce (29 checks) and model-narrow, then
became **incomplete** when `/opt/testharness/toolchains/verilator-v5.008/bin/
verilator_bin` disappeared between builds. Its receipt is not a selected-stage
pass. Synthesis and bounded formal stages were not reached. Subsequent read-only
inspection found the entire old tool prefix and cached v3 Verilator absent;
the alternative `/root/tools/...` is permission-denied on the remote host.
Do not retry the same binding, bypass identity checks, or use elevated access.
Resolve a stable approved tool binding (or available local tools) first.
No existing run was cancelled and no artifact or tool was deleted by this pass.

Local fallback completed without tool installation: Verilator 5.020 and Yosys
0.68+1 pass the quiesce bench/negative oracle, model profiles narrow/wide/byte/
top-narrow/top-maximum/sequence, both model corruption oracles, standalone/top
synthesis and the full model depth-12 safety and reachability checks. Synthesis
reports 579/938 generic cells, zero latches and zero combinational SCC; these
are not physical area/timing estimates. Receipt:
`build-platform/workspace/build/storamic-quiesce-01/local-checks-r2/result.json`.
The sequence oracle now explicitly tests refusal while an accepted read remains
outstanding, then successful epoch renewal after drain, matching the already
implemented frontend behavior rather than expecting permanent exhaustion.

A focused `quiesce-formal` stage supplements, not replaces, the full model proof.
It checks independent AW/AR/memory ownership and reaches successful read and
write completion during continuous pause. All three depth-12 checks pass
locally; no fairness or universal bounded liveness is claimed. Focused safety
takes about 9 seconds versus about 226 seconds for full model safety on this
local run. These are development iteration observations, not service benchmarks.

Pure Yosys stages no longer require or hash an unused Verilator/C++ runtime.
Simulation/lint stages retain their existing tool/runtime identity checks, and
every used tool/source is still checked before and after execution. The actual
formal-only leaf passes locally with VERILATOR deliberately absent, without
runtime credentials; a separate tampered-source snapshot returns incomplete
before proof execution. Receipt:
`build-platform/workspace/build/storamic-quiesce-01/local-formal-leaf/output/leaf-result.json`
with a sibling `../local-origin.json` identifying local WSL execution.
None of these local receipts is remote or aggregate qualification.

Implementation impact: ST-025A adds no state, memory, clock/reset, instruction,
register or DTS change. The new input adds an AND condition on AW/AR ready; ack
reduces existing context/memory-state bits. It never gates the active W/B/R or
memory-command path. Existing testmode/scan behavior and accepted/retired event
counters are unchanged. The optional platform profiles keep quiesce tied low,
so no new SoC capability/config field is advertised. Coordinator activation
must add the appropriate config legality, authorized control and observability.
Synthesis/logic-cone evidence is not physical timing or DFT sign-off.

## ST-025B implementation checkpoint

The ring now pauses before a new descriptor chain, retains queued notifications,
and finishes already offered DMA and accepted backend jobs through used-index
publication. The block engine exports job idle separately from per-port idle.
Device quiescence combines ring job pause, block job idle and shared-port drain;
reset/epoch change or a dead ring reports pause error instead of clean completion.
The optional native harness keeps the new request tied low pending coordination.

The device bench passes 137 local checks, including a held store offer, notify
during pause, a stalled avail-index poll, a pause at backend handoff (both old
port-idle signals are true there), resume without a new kick and reset error.
Standalone ring/block/device positive and negative simulation also pass on a
frozen snapshot. Frozen synthesis and formal stages are running independently
under `build-platform/workspace/build/storamic-producer-pause-01/`.
Other enabled writer integrations still need their own real pause acknowledgements.

## RAM preparation and coordinator follow-on

Preserve legacy RAM auto-publication by default. Add an externally committed
model mode: save prepares the inactive bank and freezes admission until a
separate publish/abort. Latch the bank when the control pulse is accepted,
including pulses waiting behind a response/clear scan; do not follow live bank
inputs during a scan. Cut/abort must suppress publication and retain the old
image. A premature publish request cannot select an incomplete bank.

The metadata owner, not ordinary RAM-controller reset flops, must supply active
bank and validity in external mode. Checkpoint arrays already retain bytes across
controller reset in the model; reset-recoverable metadata remains ST-025D.
Do not mistake this SRAM-backed model for physical flash persistence.

The coordinator must pause producer jobs while RAM remains accessible, then
seal AXI admission and drain accepted W/B/R. Prepare RAM and flush flash, commit
verified metadata last, release the prepared bank, then reopen safe admission.
Keep a sticky command result/cookie, but do not keep successful normal RAM
service sealed merely until software polls the result: that can prevent the
caller from fetching its polling code.

A cut or failed/interrupted restore must hold the window locked, not reopen
partially reconstructed memory. Only successful recovery plus explicit platform
cache/reservation/device-state synchronization may resume it. Queue/device reset
may be required before a retry if old producers cannot drain; do not allow a
new save to overwrite the old checkpoint in that locked state. Validate/latch
identity and mapping generation and abort on changes or degraded protection.

Expose explicit acknowledgement/error inputs for every enabled external writer.
Do not tie an unimplemented writer off as safely paused. Privileged command
authorization, protection health/budget and reserved recovery capacity are
separate obligations, not the model magic key or telemetry counters.

ST-025C1 is implemented in `g6lc_storamic_sim_mem.sv`:
`ExternalCheckpointCommit` defaults off; external mode accepts active bank/
validity from its metadata owner, latches the scan bank at control acceptance,
exposes prepared bank/valid, and holds admission until commit/abort. Cuts abort
preparation and abort cannot cancel the required volatile clear scan. Legacy
attach/dstore instances explicitly tie the new inputs off. The new bench passes
139 checks at each response delay 0/1/4/16, with four rejecting negative oracles.
It also checks response ownership and that abort cannot stop a volatile clear.
Legacy delay-16 dstore still passes 109 checks. External-mode SRAM-bound
synthesis (8 words) passes check, zero-SCC and latch rejection. Seven offline
runner tests pass; the new provenance-aware `checkpoint-ram` stage is prepared
but not remotely launched. Receipt:
`build-platform/workspace/build/storamic-checkpoint-prepare-01/result.json`.

Directed C1 coverage: refused restore without validity; premature commit;
prepared-image freeze and abort; last-valid retention across cut before publish;
mid-save abort; selected-bank latching on restore; external validity/bank supplied
after controller reset; interrupted restore/retry; full-image replacement only
after publish. Sweep response delays 0/1/4/16 and rejecting negative oracles.
The test's retained external selector is only a metadata-owner fixture, not
ST-025D implementation.
The final-edge abort case found and fixed false restore completion when the
final SRAM write was suppressed. Abort now masks and clears that completion.

C2 sequencing: pause every producer before sealing RAM; prepare RAM and flush
flash; commit the metadata record last; release preparation and reopen safe
admission without waiting for software result polling. Hold a sticky result and
cookie. Cut/restore failure must leave a recovery lock; require successful
restore plus platform cache/reservation/device-cursor synchronization before
reopening. Producer reset/error, identity/map change, degraded protection or a
participant timeout must abort/refuse, not publish. A locked retry may require
the platform to reset old producers first; never overwrite the old checkpoint
with a new save while recovery is required.

## C2 Implementation In Progress

`rtl/fabric/g6lc_storamic_checkpoint_ctrl.sv` now implements ordered producer
pause, AXI seal/drain, RAM prepare plus flash flush, external durable metadata
publication, preparation release and explicit restore synchronization. Results
and cookies remain stable while backpressured; a successful result does not
keep normal RAM sealed until software polls it. Cuts, context changes, deadline
expiry and ambiguous publication fail locked. Outstanding flush/publication
requests are not withdrawn on abort. A silent participant remains busy/locked.

Blank-media boot needs initialized RAM plus recovered/valid metadata context;
an existing checkpoint remains locked until explicit restore. Restore is
permitted with degraded save protection, because it does not create a new
persistence promise. Device reinitialization is allowed during the final sealed
restore-sync phase, but resume still requires every producer, AXI drain and the
explicit platform synchronization acknowledgement.

The initial integrated AXI/RAM/flash bench passes 102 checks with retained
metadata fixtures. New 0/4/16 RAM/flash delay profiles and rejecting oracles are
running in `build-platform/workspace/build/storamic-coordinator-01/`.
`checkpoint-synth` and `checkpoint-formal` are separate pure-Yosys stages;
the latter checks control ownership, publication ordering, result stability and
recovery lock, with save/restore/error reachability and a rejecting assertion.
Their actual local leaf is running; do not claim a proof verdict before its receipt.
Native controller activation/wiring remains open pending the real metadata owner.

C2 integration audit also reproduced a flush-cut bug (four failing checks):
the old store cleared its held-request marker on every cut, then could return
success for dropped staging after power returned. It now returns one error,
retains that request marker until deassertion and does not advance a successful
generation. New regressions include mid-flush loss, completed requests held
across cut and a request first offered during a held cut. Local dstore delay-16
now passes 121 checks; the 0/1/4/16 sweep and negative oracles also completed.
The store exports actual command/commit idle for maintenance arbitration.

The earlier frozen producer sweep is **incomplete**, not an RTL failure:
three synthesis stages finished, then the full vblk safety SAT solve timed out
at its existing 1800-second budget (about 1.23M variables/3.39M clauses).
Its receipt is under `storamic-producer-pause-01/local-yosys-leaf/output/`.
Run the independent ring/focused-control proof lanes rather than letting this
large unchanged block proof serialize implementation or weakening its properties.

ST-025D's proposed actual reserved-flash data/record path is documented in
`checkpoint-record-model.md`. The current C2 fixture is not that implementation.
