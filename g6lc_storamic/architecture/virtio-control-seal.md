# VirtIO Control Seal

## Scope

This non-hyp8 component adds an independent AXI-Lite control admission seal.
It does not change the existing VirtIO writer/DMA pause contract, bind native
checkpoint producers or authorize policy publication.

`g6lc_storamic_virtio_dev` already pauses new ring chains and drains accepted
jobs through the backend, shared DMA grant owner, status and used-ring writes.
Its `quiesce_i`/`quiesced_o` deliberately permit MMIO notifications, status reads
and reset while DMA is paused. Those operations remain supported.

The new `ctrl_quiesce_i`/`ctrl_quiesced_o` pair is separate. Legacy integration
ties the request low and leaves its acknowledgement unused. The standalone
MMIO module's corresponding `quiesce_i` seals control, not DMA.

## Ownership And Admission

- With control seal requested, no new AW/W pair or AR is accepted.
- An AW-first or W-first write accepted before sealing may receive its missing
  half. Neither sealing nor backpressure discards the accepted payload.
- B and R remain valid/stable until the requester consumes them.
- The acknowledgement requires reset released, seal requested and no AW, W,
  B, R or device-reset ownership remaining.
- Write execution and channel capture use actual handshakes. Masking READY
  alone must not let unaccepted raw VALID signals mutate registers.
- Unaccepted offers remain owned upstream. This local acknowledgement says
  nothing about accepted upstream fabric queues, CPU/cache state or providers.

The ring/backend DMA quiesce predicate remains unchanged. Media facts and IRQ
events can still change independently; control sealing is not a snapshot of
all device state. A future native composition must separately account for
both ownership domains, queue/resume state, upstream transactions, protection,
provider identity and real synchronization. Producer pause precedes the
coordinator's real store flush; no per-writer synthetic flush ACK is added.

## Analysis And Rejected Variant

The first probe (`storamic-all-5693e548db3c`) asks the old DMA acknowledgement
to include MMIO ownership and fails `mmio-owned-before-pause-ack`. That alone
does not establish a bug: it tests an expanded contract.

The combined-pause prototype (`storamic-all-b923928665f8`) freezes MMIO on DMA
pause. Existing tests intentionally issue QueueNotify, status reads and reset
while paused, rejecting that variant. Its source snapshot/results remain
archived, not credited as passing evidence. The implementation therefore
separates control sealing from DMA quiescence instead of removing those tests.

The intermediate separate-control run `storamic-all-bc59f0c3b286` passes its
device simulation but fails standalone transport synthesis: that test wrapper
does not yet bind the newly added port. The final wrapper exposes both seal
input and inflight output, and the strict synthesis check is retained. Failed
runner/packing attempts and all earlier frozen verdicts remain separate.

## Implementation Review

This is a component interface/admission extension under existing Storamic
configuration, not a new ISA or native capability. No `CVA6Cfg` defaults,
encodings, DTS, PMA/PMP permissions or Linux feature advertisements change.
All legacy control-seal bindings are explicitly off. Native checkpoint
requests still refuse missing providers and bindings.

No new state, array, clock, reset or scan structure is introduced. Existing
asynchronous-active-low reset and SRAM/technology boundaries remain unchanged.
Two small ready predicates and a handshake-qualified write predicate extend
the cold MMIO control cone; a five-term ownership reduction drives control
acknowledgement, not DMA data. Existing DMA mux and response latency are
unchanged. Target context remains 8 FO4 / 5-GHz nameplate; generic synthesis
and lint are not technology timing, power, DFT or PPA closure. Trace now reports
only accepted reads; ownership and acknowledgement are observable at ports.
No new pipeline unit or PMU capability is admitted.

## Verification

The directed device bench checks AW-first, W-first and simultaneous writes,
held B/R, sealed new offers and resume. It retains all earlier DMA-pause,
queued notification, handoff, reset and data-integrity checks unchanged.
Legacy transport/bridge benches tie control seal low.

A separate formal fixture tracks accepted interface debt independently of
the transport's channel flags. It checks ownership, blocked new admission and
availability of a missing write half under arbitrary offers. Depth-12 goals
include safety, AW/W/B/R/released covers and a rejecting assertion oracle.
The four original transport SAT queries and their depths/assumptions remain
unchanged. This is bounded component evidence, not whole-system liveness.

Frozen `storamic-all-d280ef9520f8` passes all eight selected stages: device and
transport simulation/synthesis, transport formal, control simulation/synthesis
and integration. Post-run source hashes match. Simulation uses the repository
Verilator PGO/unroll runtime and separate generated-simulator PGO. Formal and
synthesis use the repaired repository Yosys fork with full optimization.

All eleven formal goals pass: the four original goals plus the seven new
depth-12 goals. Device/transport generic synthesis reports 1407/279 cells,
respectively, with zero latches and zero SCCs. These are generic cell counts,
not technology area estimates or physical closure.

Two separately frozen hardware mutants fail their intended assertions:
`storamic-mmio-mutant-ack-69a044c3` omits inflight ownership from control ACK;
`storamic-mmio-mutant-raw-valid-6517b2bb` executes an unaccepted raw-valid write.
Both source post checks match. Failed stages remain failed; only their
rejecting-oracle observations pass.

The local 111 Python tests, seven scoped platform tests, typecheck, configured
lint/elaboration (four checks/two targets) and scoped licensing/source audit
pass. Configured lint does not resolve strict CPU scheduling or whole-system
aggregate/compliance/DFT/PPA gates.

Compact receipts: `storamic-policy-19/mmio-status-23-r1.json` and
`mmio-final-23-r1.json`. Prior 56-stage and ownership-22 results apply only to
their recorded source versions. Native admission remains disabled.
