# Storamic Completion Plan

## Objective And Completion Boundary

Complete the non-hyp8 reduced-ball RAM/flash subsystem for GSys LibreCore:
one coherent system memory map, ordinary RAM access, durable block storage,
and independently qualified protected checkpoint/persistent-memory behavior.
The removable-stick/parallel-to-PCIe physical concept is not a reason to infer
a qualified PHY, flash adapter or power-fail protection system.

Portable implementation, component evidence, native integration and product
qualification are separate milestones. ST-025 is not closed by a component
simulation, a preparatory manifest, a dry run or a model checkpoint round trip.
Native requests must retain explicit refusal while required owners are absent.

Planning is complete when the remaining work has explicit dependencies,
verifiable exit criteria and approval boundaries. That does not close the
engineering work packages below or authorize native activation.

## Verified Starting Point

- The composed endpoint contains AXI ingress, policy-bound control and real
  reserved-word-media record discovery/copy/restore. It remains a model backend.
- Optional scalar origin transport exists through LSU acceptance, store queues,
  WT cache and AXI. Unsupported classes must remain untrusted.
- Route/service components capture authorization and policy ownership, including
  sticky revocation. The route is not instantiated as native authority.
- Real mux and protected-target crossbar component lanes exist. The three-source,
  two-target crossbar profile passes 669 checks in each enable/request-cut mode
  (`storamic-crossbar-09/xbar-r5`); the unused target is a monitored decoy, not
  an atomic-response qualification.
- Configured full CPU off/on hierarchy elaboration passes on frozen sources
  (`storamic-cpu-07`). This does not execute a CPU program or prove default
  netlist/architectural behavior.
- Configured full-CPU instruction execution now passes independently through
  the two-state RTLIL interpreter: origin off/on, response delays 0/16, four
  positive cases and two rejecting origin oracles. The actual scalar LSU,
  queues, WT cache and configured FPU are retained. Each positive completes
  five writes/four reads across M/S/U and MPRV with MPP=S. The receipt is
  `storamic-cpu-interpreter-13/configured-execution-r1`. Strict Verilator
  scheduling remains unresolved; this execution lane does not replace C0.
- The additional `storamic-cpu-schedule-14/extended-execution-r1` matrix passes
  the same six case shapes with seven writes/six reads per positive, adding
  MPRV with MPP=U and MPP=M to the existing MPP=S execution. It reuses the
  identity-checked configured CPU models; its host and firmware are separate
  test inputs. Broader debug and queued-transition qualification remain open.
- Configured M-mode external-debug entry/exit now passes its six-case matrix
  (`storamic-cpu-debug-15/debug-execution-r1`): real request, DCSR/DPC checks,
  unknown debug-issued origins, architectural DRET and resumed M origins.
  It exposed and fixes the frontend selector choosing the normal trap vector
  over the debug halt vector. Broader debug contexts and queued transitions
  remain unqualified; native admission is unchanged.
- Supervisor and user external-debug round trips also pass independent
  six-case matrices (`storamic-cpu-debug-privilege-16/collected-s-r1` and
  `collected-u-r1`). Firmware configures test PMP and uses MRET to enter S/U;
  DCSR/DPC and post-DRET S/U tags are checked architecturally. Default M ROMs
  remain byte-identical. Debug/MPRV combinations, queued transitions and
  other debug mechanisms remain open.
- The `storamic-cpu-debug-queue-17/collected-r1` corpus adds actual pending
  firmware traffic across debug entry: delayed-response M AW/W holds and
  M/S/U B holds cross mode entry while retaining their issuing origin.
  Zero-delay M AW/W holds instead finish before entry. Fourteen complete
  programs, six named RTL origin oracles and independent temporal checks
  pass. This is stage/profile-specific evidence, not universal drain order
  or complete queue/provider qualification.
- The independent seven-write `storamic-cpu-debug-return-18/collected-r1`
  corpus completes the B-response return direction in M/S/U: 12 full
  programs and six named origin oracles pass at origin off/on and read
  delays 0/16. Each positive executes DRET while a debug-issued write
  response is pending, retains its unknown origin and resumes with the
  proper firmware origin. This is one response-ownership boundary, not all
  queue classes or complete debug qualification.
- Debug-mode issue is now explicitly unknown at LSU descriptor capture using
  the existing execute-stage debug signal. Queued origins remain unchanged by
  later mode transitions. `storamic-debug-12/origin-r1` passes 54 positives and
  55 rejecting oracles, including all 16 privilege/virtual/debug combinations
  and 76 queue checks. A semantic mutant that ignores debug is rejected.
  `storamic-cpu-07/elab-r5` repeats configured off/on hierarchy elaboration
  with the actual internal debug binding; it does not execute debug entry/exit.
- The standalone/testharness source lists now agree at 23 entries, with
  checkpoint dependencies registered and packages before modules. Seven
  Storamic platform checks and typechecking pass. The wider platform unit run
  has 291 passes, one skip and one unrelated AI-overlay package/DTS failure;
  this is not an all-green platform result.

## Execution Status At Planning Cutoff

Evidence cutoff: 2026-11-05. Receipt names below refer to contained directories
under `build-platform/workspace/build/`. A running command is not a verdict.

| Work | Current Status | Next Closure Action |
| --- | --- | --- |
| C0 | Open. CPU28 on the pinned repository fork exposes commit assignment incompleteness and packed-FP representation limits. Commit29 fixes the four latch errors with selected typed simulation/formal/synthesis regressions. The isolated FP/defaults probe still reports 28 unwaived scheduling errors in each origin mode. Older local-tool 11/12 counts remain historical, not directly comparable. | Separate actual feedback from aggregate/compiler artifacts without warning suppression or FP disabling; preserve current source/tool identities and rejecting regressions. No native qualification follows from the component defaults fix. |
| C1 | Original/extended interpreter matrices, M/S/U external-debug round trips, scoped AW/W/B pending-entry checks and debug-issued B responses across DRET pass. MPRV covers supported MPP values S/U/M, but not combined debug/MPRV. | Complete remaining queue classes/directions, debug/MPRV and other debug mechanisms/privilege corners; retain independent C0. |
| C2 | Direct/mux/protected-target crossbar component receipts pass; actual native-top authority binding remains open. | Freeze native topology, widths, source identities and adapter ownership. |
| C3-C6 | Model components exist; real policy/descriptor/writer/synchronization bindings are incomplete. Native refusal remains in place. | Supply and qualify the platform owners, then compose them; do not substitute fixture acknowledgements. |
| P0-P1 | Physical media/protection qualification is open. | Establish actual media/PHY/technology contracts and measured fault/energy evidence. |
| V0 | Local nonsimulation invocations were interrupted, with partial formal evidence only. Full aggregate/compliance and approved remote binding remain open. | Complete fresh per-stage gates, then run the approved isolated simulation/remote gates. |
| L0-L1 | Not qualified. L1 is optional and independent. | Finish lower system gates before advertising Linux persistent-memory capabilities. |

The local invocations `storamic-profile-10/verify-nonsim-r1` (configured
lint/formal/synthesis) and `verify-nonsim-r2` (post-debug lint/synthesis) were
interrupted without final invocation receipts. Eleven individual formal task
statuses are PASS; that does not close the 17-task suite or aggregate gate.
Neither invocation ran the shared-cleanup simulation smoke. The independent
CPU interpreter attempt `storamic-cpu-interpreter-13/exec-r4` also remains
incomplete. Earlier failed/incomplete attempts stay archived and do not
become positive evidence.

The explicit integer-only interpreter diagnostic
`storamic-cpu-interpreter-13/startup-int-r1` advances 33 post-reset cycles in
both origin modes without an assertion failure. RVF/RVD are disabled through
the test wrapper's default-off diagnostic parameter; the real CPU/LSU/cache
path is retained. The receipt remains incomplete for qualification and reports
startup success separately. This is not full program execution or configured
floating-point target qualification. RTLIL reuse now requires its recorded
artifact hash, matching source closure and matching diagnostic profile.

The later configured execution receipt collects only successful full-target
program cases with identical source/tool/program identities. It verifies source,
ROM, RTLIL, generation-script, simulation-script and log artifacts; requires
both full-profile model generation receipts; and rejects incomplete, startup
or integer-profile inputs and missing cases. Recorded zero initialization is
not four-state/reset/physical qualification. The FPU remains configured but
the program does not exercise floating-point instructions. CPU AXI delay 16
is not the separate native `FLASH_RSP=16` recovery gate.

## Failed-Gate Follow-Up

The original isolated 56-stage matrix remains 40 pass/14 fail/two incomplete.
Frozen `storamic-all-4aed2cd2cc55` passes thirteen original failed stages with
the repaired repository Yosys fork and unchanged PGO/unroll Verilator runtime.
Register safety and four covers pass; repeated preparation exhausts its
whole-stage deadline during the last cover. This does not close V0.

The follow-up isolates two fork mapping defects rather than weakening the
correct CRC assertion or repacking otherwise valid register/discovery/bridge
SV bundles. The standard kernel executable passes all 126 tests. One of 96
optimization scripts fails identically on old and repaired tools.
Fixed-unit backend slicing and whole-vector descriptor fixtures are the only
corresponding production/fixture SV corrections; they add no timing stage,
clock/reset, memory macro, capability, configuration or software encoding.

The register runner now prepares one hash-guarded lowered model for its six
unchanged SAT goals. The standalone frozen run passes all six, including the
last cover, in 1001 seconds with matching post-run source/model hashes. The
distinct pre-ownership `storamic-all-5267d4deeb38` matrix passes all 56 stages
with matching post-run source hashes. This closes the failed leaf-gate work,
not V0/native/aggregate qualification or a latest-ownership-SV full sweep.
Source/tool/runner identities,
native refusal and the C0/C1/provider/
physical/aggregate/compliance/Linux boundaries remain mandatory regardless
of component progress. The contained remote Python snapshot passes 111 tests;
local disk-full attempts stay archived, not relabeled.

## Dependency-Ordered Work Packages

| ID | Implementation Work | Evidence Required To Close |
| --- | --- | --- |
| C0 | Resolve the full-CPU dependency cones without warning suppression or speculative unrelated RTL rewrites. Separate compiler aggregate artifacts from real feedback. | Configured-tool off/on strict compile; independent source-cone analysis; regression for each actual RTL correction. Coarse SCCs alone are not bit-level proof. |
| C1 | Execute genuine scalar instructions through the actual LSU, queues, WT cache and AXI. Test effective privilege, not live privilege sampled at the end; qualify or deny debug-mode issue separately from machine firmware. | M/S/U and MPRV load/store tags, queued mode changes, backpressure, flush/slot reuse, default-off behavior, rejecting origin oracles. Unsupported AMO/hart/virtualization/debug sources cannot acquire authority. |
| C2 | Bind the actual SoC crossbar dimensions, physical source identities and every intervening adapter to the route/service sidebands. | Full native-top source closure, source-prefix isolation, independent AW/W ownership, responses to the original source, all configured latency cuts. Component 3x2 results do not qualify a different native topology. |
| C3 | Implement the platform-owned policy/descriptor/identity binding. Capture immutable descriptor, module identity, mapping generation and policy epoch; reject inconsistent/revoked providers. | Hardware-owned provenance, adversarial source/policy tests, epoch/readiness ABA tests and reset/hot-replacement rediscovery. No requester key or constant-ready stand-in. |
| C4 | Bind every enabled writer's real pause/drain protocol. Include CPU, DMA, accepted VirtIO jobs, debug and any accelerator/device writer. | Accepted work finishes exactly once; queued notifications remain owned; no false idle acknowledgement; every actual writer accounted for. |
| C5 | Implement CPU/cache/reservation/device resume synchronization around RAM replacement. | Dirty/queued state drained before save; caches and reservation state cannot expose stale restored data; devices synchronize before admission reopens. Missing acknowledgement remains fail-closed. |
| C6 | Compose native control, endpoint and all owners. Replace refusal only after the complete provider set and topology qualify. | No volatile fallback, no synthetic acknowledgements, legal configuration checks, native failure/recovery/response-delay sweep. |
| P0 | Bind the actual non-hyp8 PHY, SRAM/pad/clock/technology seams and physical flash adapter. Specify logical ordering and durability at the physical boundary. | Real timing/CDC/reset review, physical-media ordering/program/erase tests, erase-block isolation and separately qualified ECC. Word-model CRC is not physical ECC. |
| P1 | Bind protection/energy budget, hold-up, recovery spares, degraded admission and module replacement behavior. | Measured worst-case protected operations, power/fault injection, interrupted replacement fallback, authoritative admission thresholds and safe degraded behavior. |
| V0 | Restore an approved isolated tool/runtime binding; register/run complete default/enabled integration gates. | Source/tool/runner identities; actual native FLASH_RSP=16 reinitialization; aggregate/compliance; default-netlist identity; PMU/debug, scan/ATPG, timing and power reports. No shared cleanup. |
| L0 | Integrate the qualified RAM/block map and standard Linux device interfaces. | PMA/PMP/DTS consistency, genuine VirtIO-MMIO/virtio-blk DMA behavior, CPU/DMA/atomic/system tests and Linux recovery. |
| L1 | Independently evaluate optional DAX, virtio-pmem and virtio-mem semantics. | Independent persistence/coherence/hotplug/security qualifications; no capability inherited from model saves or ordinary virtio-blk support. |

C0 precedes C1. C2 can progress independently but cannot establish authority
without C1/C3. C3, C4 and C5 must compose before C6 admission. P0/P1 and V0
are independent of portable-model success and must close before a protected
native/product capability is advertised. L0 follows the lower system gates;
L1 remains separately optional, never an implicit consequence of L0.

## Delivery Milestones

1. **Source qualification:** close C0/C1 and the actual native topology portion
   of C2. A passing isolated bridge or encoded tag alone is insufficient.
2. **Native orchestration:** close C3-C6 with real ownership, drains and resume
   synchronization. Activation remains refused until the complete composition
   qualifies; implementation progress does not remove this interlock.
3. **Protected system qualification:** close P0/P1 and V0, including physical
   failure behavior, native delayed-flash recovery, compliance, DFT and PPA.
4. **Linux delivery:** close L0 on that qualified system. Evaluate L1 separately;
   optional PMEM/hotplug/DAX features are not prerequisites for ordinary block
   delivery and are never inherited capabilities.

No calendar estimate is asserted before native provider, physical-media and
approved tool/runtime inputs are available. Scope closure is evidence-based.

## Next Session Order

1. Resolve the remaining C0 scheduling diagnostics and C1 debug/queued-transition
   coverage, preserving the passing independent instruction matrix and all
   earlier failures. Complete fresh nonsimulation gates rather than promoting
   partial interrupted results. Avoid another blind pragma sweep.
2. Inventory actual native sources and all upstream queues. Specify C3 policy
   replacement against producer, fabric, route, active-operation and held-result
   ownership; then implement C4/C5 against genuine writer/synchronization ports.
3. Qualify the complete C6 composition before any native admission change.
   Obtain the missing physical/runtime inputs and explicit remote/network or
   cleanup approvals for P0/P1/V0. Proceed to Linux only after those gates.

## Policy Ownership Must Cover The Whole Path

The next implemented observation slice extends endpoint hold through real RAM
and media owners and distinguishes idle from empty durable-store staging.
It supplies no producer/fabric acknowledgement and performs no automatic flush.
See [policy-ownership-drain.md](policy-ownership-drain.md). Ten separate frozen
SV stages and two hardware-mutant rejections pass. The protocol-valid formal/
abandoned-flush follow-up also passes with matching source post hashes. This is
a bounded observation slice; native C3/C4/C5 remains unqualified.

The next control-seal interface is deliberately independent of VirtIO DMA
pause. It prevents fresh MMIO admission while accepted partial writes and B/R
responses drain, without changing queued-notify/reset semantics under DMA
pause. Legacy integration leaves the control seal off; its frozen validation
is separately recorded in [virtio-control-seal.md](virtio-control-seal.md).
This supplies neither native provider bindings nor a CPU/fabric acknowledgement.

The model-only next composition connects the real VirtIO job acknowledgement/
error and DMA bridge to the checkpoint endpoint while retaining external
upstream and resume providers. Ten selected frozen stages and both rejecting
producer-ACK mutants pass their scoped oracles; this is not native binding.
See [checkpoint-writer-model.md](checkpoint-writer-model.md).

The next C4/C5 component slice validates real MMIO reset during an accepted
OUT/save, propagated producer error, unchanged prior checkpoint generation,
post-copy resume hold and explicit queue reinitialization. Eleven selected
stages, a separate coordinator-proof/reset follow-up and both hardware mutants
pass with source identity. No production RTL correction was warranted.
This narrows model failure/recovery uncertainty; it does not close native
C4/C5 or supply CPU/cache/fabric providers. See
[checkpoint-writer-reset.md](checkpoint-writer-reset.md).

The C4 shared-adapter follow-up fixes a trace-confirmed upstream-W/DMA-AW
misassociation, stalled address withdrawal and outstanding-credit wraparound.
Thirteen selected stages and exact-fixture rejecting original-RTL replay pass
their intended criteria; generic active model costs 41 additional cells and
no memories/latches/SCCs. This closes those component protocol defects, not
native source/topology/provider qualification. See
[dma-ownership.md](dma-ownership.md).

The next C3/C4 composition binds policy publication to the real model writer's
job/DMA pause, separate control seal and full endpoint ownership. Ten selected
stages and both rejecting wiring mutants validate old-epoch retention, held
results/responses, external ownership/ACKs, provider ABA and explicit common
reset/rediscovery. This does not supply native descriptor/authority facts or
automatic active-provider-loss recovery. See [policy-writer-model.md](policy-writer-model.md)
and [native-provider-inventory.md](native-provider-inventory.md).

The C0 follow-up restores complete combinational retirement defaults without
adding state or changing the CPU/software interface. Seven selected stages
pass on the promoted snapshot, including the public component proof and
original-RTL compile rejection. This is not the remaining full-CPU scheduling
gate: 28 off/on diagnostics persist in the isolated unwaived representation
probe. See [cpu-commit-defaults.md](cpu-commit-defaults.md).

The route holds policy from its own AW/AR acceptance until local B/final R
consumption. The endpoint owns partial control AW/W pairs, stalled B/R responses,
queued commands, active maintenance, held results and their consumption pulse.
Neither owner can see requests still buffered upstream in the
crossbar/cluster/adapter path.

Policy replacement therefore needs genuine producer pause plus upstream
fabric drain, not just the OR of route and endpoint holds. On provider loss,
seal admission and retain revocation. Returning providers do not authorize
old buffered work, imply durable metadata readiness or auto-open a locked image.
Re-arm only after upstream accepted work has retired/refused, identities and
metadata have been rediscovered, and resume synchronization has completed.

The default-off `g6lc_storamic_checkpoint_policy` candidate implements the local
publication mechanism: immutable offered snapshot, old epoch while owners drain,
explicit ingress acknowledgements, sticky active/offer revocation and refusal
on epoch exhaustion. Captured AW command admission permits old work and result
acknowledgement to drain without admitting new commands during the freeze.
Component/formal fixtures exercise the ownership contract; they do not supply
genuine native providers. C3 remains open until real producer, fabric,
route/endpoint and maintenance owners are bound and independently qualified.
The isolated remote suite uses the hashed `tools/verilator` worktree, compiler
PGO and unroll budgets, then generated-model profile training and fresh final
executions. Failed/incomplete matrices remain distinct from successful subtasks
and never imply aggregate, physical or Linux qualification.

The first complete corrected remote matrix (`storamic-policy-19/REMOTE-RESULTS.md`)
attempts all 56 stages: 40 pass, 14 fail, two incomplete. Its source-frozen
incomplete verdict is retained. Separate component reruns recover all 26 model
profiles/two corruption oracles and standalone flush-formal safety/coverage;
the three policy semantic mutants reject remotely. Remaining codec/cover,
undriven-output synthesis and VirtIO-block status failures keep qualification
open. Compiler/model PGO does not waive those failures or any native gate.

The physical cluster port may also carry an attached accelerator's requests.
Do not equate its prefix with scalar-CPU origin. The optional scalar support
predicate must reject unqualified accelerator/coprocessor configurations.
SoC multi-core/shared-master composition still needs its own explicit check;
one hart per CPU does not imply one writer behind the physical cluster port.

## Native Writer Inventory And Drain Order

For each enabled physical/logical writer, record its upstream master, trusted
origin encoding, queue boundaries, pause owner, accepted-work counters and
resume action. Unsupported or unlisted writers keep admission disabled.

1. Stop new producer jobs while allowing already accepted jobs to finish.
2. Finish VirtIO data and used-ring writes before pausing the word-DMA adapter.
3. Pause CPU/device/debug/accelerator issue at their real architectural boundary.
4. Drain their queues and the fabric while honoring accepted AXI W/B/R work.
5. Seal RAM ingress only after every enabled writer acknowledges drain.
6. Prepare the inactive image, copy/flush reserved physical media and publish
   durable identity/map-bound metadata in the specified order.
7. Restore/recover only from a selected valid record; propagate all errors.
8. Complete cache/reservation/device synchronization before releasing writers.

An idle bubble, a port-valid snapshot or an unused testbench fixture is not
an acknowledgement for these steps.

## Required Platform Inputs

Do not invent these to unblock a simulation:

- The actual enabled-writer/topology inventory, including shared cluster paths.
- The authoritative descriptor/identity/protection owner and access policy.
- Native cache/reservation/device synchronization interfaces and semantics.
- Physical module/media geometry, durability/erase/ECC contract, protection and
  energy measurements, and actual technology/PHY bindings.
- Approved remote runtime/tool identity and permission to access it. Current
  local diagnostics do not restore that binding or authorize network/cleanup.

These are integration/qualification inputs, not values to tie high or replace
with a new capability flag.

## Development And Acceptance Method

Keep implementation and validation as separate lanes. For each bounded change,
freeze a complete source closure, record configuration/tool/runner hashes,
preserve failures, then run directed positives, rejecting oracles and relevant
formal/synthesis checks. Source provenance must include generated wrappers.
Synthesis/DFT/timing impact and PMA/DTS/config alignment must be explicit.

Use the build platform's resolved context, target and manifest rather than
hand-maintained core lists. Aggregate simulation can clean shared files:
run it only in an isolated approved workspace or obtain specific approval.
Dry-run planning executes nothing. Infrastructure failure is not an RTL pass.
No latch/scalar-feedback diagnostics may be hidden to promote a gate.

Review completion against the work-package acceptance column, not a count of
new modules or passing leaf tests. Update `development-status.md`,
`AGENTS-todo.md`, the memory guide and the source-to-test record when a gate
actually closes. Preserve unrelated APU/hyp work and its evidence boundaries.
