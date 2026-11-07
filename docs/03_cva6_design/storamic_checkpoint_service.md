# GSys LibreCore Storamic Checkpoint Control Service

## Scope

`g6lc_storamic_checkpoint_service` is a same-clock, AXI-Lite model control
component. It is not instantiated in the native profile, does not advertise
PMEM capabilities and does not establish CPU privilege enforcement by itself.
Native activation still requires optional `CVA6Cfg` legality and qualified
interconnect, identity, protection, writer and synchronization providers.

The AXI structural request/response types are parameter-injected. This component
uses 32-bit register data, full-word command writes and up to 64-bit addresses.
It defaults to no native instance; its enable and authorization inputs must
come from trusted providers, not requester-controlled registers or AXI PROT
alone. There is no unlock key.

## Ownership and Authorization

The model endpoint now composes control ownership with real RAM inflight and
media/flush ownership. Store `drained_o` additionally requires empty staging;
`idle_o` alone deliberately permits dirty data. These are observed owners,
not authorization or upstream pause acknowledgements. The implementation,
configuration/timing review and remaining integration obligations are recorded
in `g6lc_storamic/architecture/policy-ownership-drain.md`.

VirtIO control sealing is independent of writer/DMA pause. Its new
`ctrl_quiesce_i`/`ctrl_quiesced_o` pair drains accepted MMIO halves and B/R
responses before acknowledging; legacy bindings explicitly leave it off.
The existing DMA-pause path still permits notifications, status reads and
reset. Neither acknowledgement is policy authority or a whole-system drain.
See `g6lc_storamic/architecture/virtio-control-seal.md`.

- AW and W may arrive independently, including W first. One buffered pair is
  executed once, and its B response remains stable until accepted.
- Authorization, enable and policy epoch are captured with the AW handshake.
  A later unrelated AW authorization cannot authorize or deny that packet.
- Policy change or disable revokes a pending address/queued command. Revocation
  is sticky, including an observed epoch ABA. A stalled command retains its
  cookie/type/valid offer and reaches the coordinator with authorization false.
- Controller acceptance is the command admission boundary. The platform must
  serialize policy changes against already accepted maintenance; this component
  does not cancel an active coordinator operation or revoke an already offered
  read response retroactively.
- AR authorization controls its captured read response. R data/status remain
  stable under backpressure; denied reads return zero and SLVERR.
- The service is the sole command/result consumer for its coordinator. Result
  consumption requires an authorized write of the matching result cookie.
  A successful B response acknowledges queueing/consumption, not durability.

The interconnect must preserve same-master AW/W association and supply
transaction-aligned authorization. Partial AXI transactions retain ownership
until completion/reset; firewall isolation/fairness against partial-transaction
denial of service remains a platform obligation.

## Model Register Contract

These offsets are for component verification, not a frozen protected software
ABI or Linux interface. All offsets are relative to `BaseAddr`.

| Offset | Operation |
| --- | --- |
| `0x00` / `0x04` | Write cookie to queue save / restore when coordinator ready |
| `0x08` | Write matching completed cookie to consume its result |
| `0x10` | Read readiness, result, busy, recovery, initialization and media status |
| `0x14` / `0x18` | Read result cookie / result code |
| `0x20` / `0x24` | Read generation low, then the high half of the same snapshot |

Unknown/misaligned/partial writes have no control side effects and return
SLVERR. High-generation reads without a valid same-policy low snapshot also
return zero/SLVERR. Reading a new low half replaces that snapshot.

## Review and Evidence

The component adds small control registers, not arrays, clocks or clock gates.
Plain registers remain scan-insertable. Issue/refusal/revocation strobes are
available; native PMU/debug routing and physical scan/ATPG are still pending.
The registered address/cookie/epoch decode is a cold control path. No CPU RAM
data path changes, physical timing closure or 5 GHz claim follow.

Local source/tool-hashed tests pass 53 checks and a rejecting oracle, covering
AW-first/W-first/simultaneous requests, B/R backpressure, authorization capture,
policy ABA/disable, matching result consumption and coherent generation reads.
Separate source-identified leaf checks pass depth-16 safety, command/revocation/
ack reachability at 10/12/10, a rejecting formal oracle and generic synthesis:
132 cells, no latches/SCCs. No compliance, whole-SoC or physical claim follows.

Receipts: `build-platform/workspace/build/storamic-checkpoint-next-02/`.
`checkpoint-service` needs a validated simulation runtime for remote launch;
`checkpoint-service-synth` and `checkpoint-service-formal` do not.

## Composed Model Endpoint

### Failed-Gate Tool And Fixture Boundary

The frozen repaired-tool follow-up passes thirteen of fourteen originally
failed component stages, including both original codec/record proof stages
and all seven strict synthesis stages. Register safety and four covers pass;
the last cover is interrupted by a stage deadline after repeated identical
preparation. A fresh runner prepares one hashed lowered design and applies all
six original SAT goals with unchanged reset, assumptions and depths.

The CRC algorithm and assertions are unchanged. Reproduced compound-alias and
stale canonical-cache defects are repaired in the repository Yosys fork; the
standard kernel executable passes 126 tests. The VirtIO descriptor fixture
publishes complete vectors and verifies propagation at request acceptance.
Fixed AXI-page/sector bit extraction adds no state, clock, scan or ABI change.
It is fixed protocol wiring, not a new configurable memory geometry or
permission decision. No timing, whole-SoC, physical or Linux qualification
follows. The historical incomplete matrices and original traces remain
preserved in `storamic-policy-19/REMOTE-RESULTS.md`.

`corev_apu/storamic/g6lc_storamic_checkpoint_endpoint.sv` joins this service,
the AXI memory frontend and the real checkpoint model backend. Its existing
`storamic_cfg_t` seam defaults to `StoramicOff`. This is an integration
candidate, not an enabled native profile. `CVA6Cfg.StoramicCheckpointEn` now
records a request, defaults off in all 37 tracked target packages, and requires
the normalized primary/I/O role. The builder and native harness propagate it.
Because real native providers are not bound, the attach rejects such a request
at elaboration and selects `StoramicOff` in hardware rather than silently
falling back to the legacy volatile model. Qualified platform binding is still
required before that interlock can be replaced by functional native selection.

Enabled configurations require a legal single-stick model extent, aligned
64-bit RAM/32-bit control structural interfaces, legal reserved-flash capacity,
one to eight writer providers and a sufficient controller timeout. Invalid
configuration elaboration rejects, and the synthesized inactive branch refuses
AXI/control requests without instantiating model arrays. No illegal-layout
fallback to ordinary unprotected memory is provided.

The five mandatory runtime provider-ready bits are:

| Bit | Provider contract |
| --- | --- |
| 0 | Transaction-aligned privileged policy and policy epoch |
| 1 | Persistent module identity |
| 2 | Independently qualified protection/health source, not an unlock bit |
| 3 | Current descriptor, map and reserved-capacity binding |
| 4 | Cache/reservation/device resume-synchronization owner |

These bits declare availability, not evidence that a provider is qualified.
All are external; none is generated by a constant tie-high in the endpoint.
The actual writer pause/error vector and resume acknowledgement are separate
mandatory inputs. Tests supply fixtures, not silicon-ready providers.

Loss of any provider immediately seals new AW/AR admission while accepted
traffic can retire. It invalidates coordinator admission and forces recovery.
Provider return does not mean record rediscovery is finished: software must
wait for metadata readiness, and a locked system still requires explicit restore.
`policy_hold_o` covers partial AW/W pairs, stalled B/R responses, queued
commands, active maintenance, held results and the result-consumption pulse.
The endpoint exports this complete service ownership directly. An empty
command queue is not sufficient evidence that the control interface is idle.
The trusted policy manager must serialize updates against that ownership.

### Policy Publication Candidate

`g6lc_storamic_checkpoint_policy` is a default-off, standalone control-plane
candidate, not a native authorization provider. It captures an offered policy
and uses a nonzero, nonwrapping epoch. An update blocks new command admission,
requests quiescence and leaves the old policy/epoch visible while accepted
ingress, route, endpoint and maintenance work drains. Publication additionally
requires the explicit acknowledgements of all declared ingress owners and
qualified providers. Owner presence is an integration contract, not an idle
guess; the manager cannot manufacture pause/drain acknowledgements.

`command_admit_i` is captured with AW. An AW accepted before the freeze can
complete its owned command; an AW accepted during the freeze cannot become a
new command. The old policy remains available for draining and explicit result
acknowledgement. Blocking every control write during quiescence would strand a
held result and deadlock publication.

Provider loss revokes admission immediately and is sticky for both the active
snapshot and a captured offer. A provider returning to ready cannot revive a
stale offer or transaction. Exhaustion refuses publication rather than wrapping
the epoch. Disabled/illegal configurations expose zero policy and epoch.
Commit/revoke/reject/exhaustion event outputs are observability seams; native
PMU/debug routing and scan/ATPG qualification are still required.

Local component checks cover partial AW/W, held B/R, upstream owner presence,
maintenance ownership, provider loss/return, result acknowledgement, replacement
and exhaustion. The directed fixture has 83 checks; three semantic mutants
reject incomplete ownership, live-provider revival and epoch wrap. These
fixtures and the bounded formal model do not qualify the native provider
topology. Remote execution and generated-simulator PGO receipts are recorded
separately under `build-platform/workspace/build/storamic-policy-19/`.

The corrected frozen remote matrix completes 56 stage attempts with 40 pass,
14 fail and two incomplete. Policy simulation/semantic rejecting mutants pass.
Separate unchanged-RTL model completion recovers all 26 profiles and two
corruption oracles; corrected standalone flush-formal setup passes safety and
reachability. These receipts never overwrite the original failed/incomplete
matrix. Codec/cover, synthesis and VirtIO-block status failures remain open;
see `storamic-policy-19/REMOTE-RESULTS.md` for identities and scope.

Timing/physical impact: all new state uses the existing asynchronous-low reset
and clock. The ownership reduction and provider/quiescence reduction are cold
control paths; the accepted-AW command-admission bit adds control state, not a
RAM/DQ data-path stage. There is no new memory macro or clock domain. Epoch
increment and policy fanout still need native STA, power and DFT review; coarse
cell counts are not timing closure. No ISA encoding, DTS capability or Linux ABI
changes, and native checkpoint admission remains refused.

Native binding must preserve producer ordering: pause VirtIO at its job boundary
while its DMA adapter can still execute remaining descriptor/data/status/used
accesses. Only then pause/drain the word adapter and seal RAM after all enabled
writers acknowledge. Simultaneously stopping both can strand an accepted job.
CPU and other enabled writers need their own genuine providers, not port-idle
bubbles or a testbench acknowledgement.

Endpoint tests and inactive/illegal-layout formal checks are registered as
`checkpoint-endpoint`, `checkpoint-endpoint-synth` and
`checkpoint-endpoint-formal`. Outputs are contained under
`build-platform/workspace/build/storamic-checkpoint-endpoint-03/`.
No new clock/reset domain, ISA encoding, DTS capability or Linux ABI is added.
The new runtime timing cone is the five-provider reduction into cold control
admission and AW/AR quiescence; the RAM return path is unchanged. Existing
`tc_sram` boundaries and plain control-register scan insertion remain; native
PMU/debug routing, physical timing, power, scan and ATPG qualification are open.

Local component evidence (not remote/native/Linux qualification):

- Endpoint simulation: 1,229 / 1,370 / 1,802 checks at response delays 0 / 4 / 16;
  inactive profile: three checks. All four rejecting oracles and the illegal
  reserved-layout elaboration oracle pass.
- Endpoint synthesis: 1,896 generic cells, four model memories; inactive and
  illegal-layout branches: 59 cells and no model memories. No latches or SCCs.
- Inactive and illegal-layout formal safety: depth 12 with unrestricted policy,
  provider and request inputs; both deliberate negative assertions reject.
- Native configuration lane: 37 target-package elaborations, four configuration
  simulations and existing-model/unbound-request native leaf cases pass.

Frozen receipts are in `sim-release/local-result.json`,
`native-final/local-result.json` and `complete-checks/output/leaf-result.json`
under the endpoint workspace. Earlier interrupted receipts remain archived;
they are not promoted to passing results. Aggregate dry-run plans 25 steps and
executes none. Full aggregate/compliance, remote/native stretched response,
physical qualification and Linux remain pending.

The initial privilege-source audit found `core/axi_shim.sv` drove AWPROT/ARPROT
to zero. An optional descriptor transport is now implemented, with the original
zero tags retained when disabled. Focused queue/cache/adapter checks now pass,
but native authority and full CPU integration remain unqualified. See
`storamic_transaction_origin.md`. Neither raw PROT bits nor live CSR privilege
alone authenticates a command; trusted-master and genuine provider bindings
remain required before allowing native commands.

The native request interlock synthesizes to the 32-cell off/refusal profile
with no memories, latches or SCCs. The broad leaf synthesis run also retains
the full default RAM geometry: its Slang unroll budget is raised to 65,536 to
cover the existing SRAM initialization loops, rather than shrinking the model.
Timing/area figures here are generic component evidence, not physical closure.

## Transaction-Aligned Route Candidate

`corev_apu/storamic/g6lc_storamic_checkpoint_route.sv` composes the existing
native control bridge with a default-off authorization sideband. It is not
instantiated in the native harness and does not remove the attach refusal.
Its service-facing outputs are tested against the real checkpoint service,
not a requester-written key or a synthetic command acknowledgement.

The route audit establishes this source contract:

- `ariane_testharness` connects the cluster, debug master and shared DMA to
  crossbar slave ports 0, 1 and 2. `ariane_axi_soc::IdWidthSlave` includes the
  crossbar's high source bits.
- `axi_mux` binds each `axi_id_prepend.pre_id_i` to the physical port index.
  `axi_id_prepend` concatenates that prefix above the requester's local ID.
  Local transaction IDs alone never identify an authorized master.
- The candidate requires the exact configured ID geometry and trusted prefix,
  `PROT=001`, uncached/nonexclusive ordinary word shape, no ATOP, aligned page-0
  address and a ready policy provider. Cacheable, subword, instruction, atomic,
  unallocated-prefix and other-master packets cannot become commands.
- This still depends on the CPU origin transport and its supported profile.
  A future native instance must derive its enable from the existing
  `CVA6Cfg` request/support checks, bind actual crossbar dimensions, and qualify
  every intervening adapter. A parameter or master-prefix comparison does not
  establish provider qualification or justify native activation.

The existing bridge drops raw PROT while translating AXI to AXI-Lite.
The wrapper therefore captures the authorization decision and policy epoch at
the upstream AW/AR handshake, before that translation. Each sideband slot stays
owned through upstream B/final R consumption, matching the bridge's independent
one-write/one-read contract. A new live header cannot promote or revoke an owned
packet. Policy loss or an observed epoch change poisons its slot permanently
until retirement, including ABA and loss/recovery before downstream acceptance.
Unknown qualification values are not emitted as an X authorization.

Connect `ctrl_req_o`/response to the checkpoint service or endpoint, and connect
`service_enable_o`, `aw_authorized_o`, `ar_authorized_o` and the same live policy
epoch to that consumer. These sidebands must not be ignored by a legacy register
block. Page 1 remains the legacy VirtIO transport; it gains no protected control
authority. The trusted policy manager must combine the route's `policy_hold_o`
with the endpoint's ownership of queued commands, active maintenance and held
results. Neither hold substitutes for CPU/cache/reservation/device draining.

Local receipts: `build-platform/workspace/build/storamic-route-05/`.
The `sim-r2` snapshot passes 837 checks each off/on, two rejecting oracles and
invalid-master-geometry elaboration rejection. `checks-r2` passes depth-16
safety in both profiles, four covers at steps 3/4, and a deliberately false
authorization assertion rejected at step 3. The proof assumes only the
downstream AXI-Lite B-response hold contract needed by the pass-through bridge;
request identities, origin, policy readiness and 32-bit epochs stay unrestricted.
The earlier unconstrained-responder failure and interrupted release remain
archived, not promoted.

Coarse synthesis reports 220 / 291 RTLIL cells off/on, no arrays, latches or
combinational SCCs. These are pre-mapping component figures. The new cold
control cones are source/shape qualification and epoch equality into small
asynchronously reset control registers; no CPU data latency, new clock/reset
domain, ISA encoding, DTS capability or Linux ABI is introduced. Existing
service event strobes remain the observation seam; native PMU/debug mapping,
scan/ATPG, power and timing closure remain open.

Reproduce the isolated checks without network or cleanup:

```sh
python verif/tb/storamic/run_route.py --output-root build-platform/workspace/build/route-new
python verif/tb/storamic/check_route.py --snapshot build-platform/workspace/build/route-new --output-root build-platform/workspace/build/route-check-new
```

Use fresh output directories; existing evidence is never overwritten. Native
composition, full-CPU/default behavior, approved aggregate/compliance gates,
all enabled writers, authoritative descriptors, qualified protection and
physical/Linux persistence remain independent, pending dependencies.

### Real Interconnect Component Lane

`run_route.py --interconnect` now places the real Pulp `axi_mux`,
`axi_id_prepend`, AW-owner W FIFO and arbitration before the route/service.
Three physical masters supply only local four-bit IDs; the interconnect adds
the two-bit prefix. A peer continuously offers W without AW. Assertions check
physical prefix insertion, response isolation, W ownership and command-cookie
integrity. Request spill off/on covers the native NO_LATENCY baseline and
additional AW/W/AR buffering; B/R spill is not part of this profile.

`storamic-interconnect-06/mux-r4` passes 669 checks in each of four
enable/request-spill profiles, four rejecting oracles and illegal-ID-geometry
rejection. The updated direct lane also passes; route-only depth-16 proofs and
coarse synthesis pass again on the new frozen closure. These proofs do not
prove the mux or replace full crossbar/CPU qualification. Scoped MIT header and
live/frozen identity checks pass. Earlier build/fixture failures remain archived.

The W-first fixture now observes an actual early W transfer into a spill
register rather than waiting for a second acceptance. No production RTL,
native guard, master policy or provider binding changes in this pass.

### Full Crossbar Protected-Target Component Lane

`run_route.py --crossbar` places the real `axi_xbar`, address decode, demux,
ID counters and output mux before the route/service. Three physical sources
offer four-bit local IDs; the selected output retains the six-bit prefixed ID.
The two-target fixture monitors that its unused second target is never selected.
It does not qualify that target's responses, atomics or arbitrary unmapped access.

`storamic-crossbar-09/xbar-r5` passes 669 checks in each off/on authorization
and `NO_LATENCY`/`CUT_ALL_AX` profile, four rejecting oracles and illegal-ID
geometry rejection. The direct/mux/crossbar lanes remain component evidence:
the native topology, executing CPU and genuine policy/writer providers are
not qualified by these results. Vendor RTL is unchanged.

The route's ownership starts at its own AW/AR handshake. Upstream crossbar,
cluster or adapter buffers can still own accepted requests while both route
and endpoint holds are low. Before replacing policy or re-arming providers,
pause real producers and drain/refuse their accepted upstream work as well.
The OR of route and endpoint holds alone is insufficient. Preserve revocation
through provider loss; provider return cannot reauthorize stale buffered work.
See `../../g6lc_storamic/architecture/completion-plan.md` for the dependency
order and required platform contracts.

## Default-Off Writer Model

`corev_apu/storamic/g6lc_storamic_checkpoint_writer_model.sv` is an optional
model-only composition, not a native testharness attachment. It reuses the
existing `storamic_cfg_t`/ProfileModel gate and structural types. Real VirtIO
pause/error and DMA ownership are observed; upstream/fabric acknowledgement,
provider identity/protection and restore safety remain external.
Producer pause allows accepted jobs to finish before coordinator flush/copy.
Independent MMIO sealing is not tied to job pause. The uncached bridge disables
invalidation; model durable hints do not imply physical persistence.

Ten selected frozen stages and two rejecting ACK mutants validate component
scope. Default deadline32768 budgets the1024-byte model's two CRC passes;
explicit8192 timeout remains a lock/drain regression. Queue/device power-cut
replay, cache coherence, native/aggregate/compliance, DFT/PPA and Linux remain
unqualified. Timing/config/scan/event details and exact evidence are in
`../../g6lc_storamic/architecture/checkpoint-writer-model.md`.

The subsequent `checkpoint-writer-reset` leaf stage exercises real Status=0
during an accepted job/save, prior-generation preservation and explicit
restore with a post-copy CSync hold. Reset drops internal queue indices, so
the fixture rebuilds guest rings and reconfigures the driver before resuming;
it does not assert automatic queue-state checkpointing or block-write rollback.
Error suppression and forged-resume hardware mutants reject. Existing RTL
already satisfies this bounded contract, so no timing/state workaround is
added. See `../../g6lc_storamic/architecture/checkpoint-writer-reset.md`.

The shared DMA adapter now retains stalled AW/AR offers and bounds outstanding
credits; W requires an accepted or currently visible AW. This prevents an
upstream W beat from pairing with DMA AW after arbitration changes masters.
An offered AW can admit W without depending on AWREADY, preserving progress
with legal independent-channel slaves. `inflight_o` includes that ownership.
Thirteen selected stages and exact-fixture original-RTL rejection validate
this component correction, not native authority or physical persistence.
See `../../g6lc_storamic/architecture/dma-ownership.md`.

The default-off policy/writer composition connects real writer pause and its
separate control seal to policy replacement, retaining old epoch until accepted
work, results and responses retire. Upstream holds/ACKs, authorization, native
identity facts and resume safety remain external. Provider ABA cannot revive
an old policy; tested active-loss recovery uses explicit common reset and
rediscovery. See `../../g6lc_storamic/architecture/policy-writer-model.md`
and `../../g6lc_storamic/architecture/native-provider-inventory.md`.
