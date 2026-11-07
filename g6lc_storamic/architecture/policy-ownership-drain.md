# Checkpoint Policy Ownership And Model Drain

## Scope

This C3/C4 implementation slice exposes existing owners in the non-hyp8 model
endpoint. It does not bind native providers, pause producers, authorize a
request, publish a policy, request a flush or activate native persistence.

The earlier endpoint hold covered control AW/W, B/R, queued commands,
maintenance and held results. That did not cover ordinary accepted RAM traffic
or the block word port. In particular, the durable store intentionally reports
idle while dirty write-back entries remain. Idle is not a drain acknowledgement.

## Implemented Observation

- `g6lc_storamic_durable_store.drained_o` requires common reset released,
  existing idle and the actual staging count equal to zero. It is false while
  powered off, servicing a response, committing, flushing, saving or replaying.
- `g6lc_storamic_checkpoint_model.media_hold_o` covers metadata/maintenance,
  the word guard, undrained store state and every captured/offered flush owner.
  Existing coordinator use of `flash_idle` is unchanged: it must still be able
  to request the flush that empties staging.
- `g6lc_storamic_checkpoint_endpoint.policy_hold_o` combines control ownership,
  the actual AXI frontend's inflight state and model media ownership. AW owns
  through W/B; AR owns through final R consumption.

There is no shadow dirty bit, timeout-based release or fabricated completion.
Dirty staging retains ownership until actual commit/recovery resolves it;
obtaining a successful flush completion requires a real held flush request.
Power-cut model semantics still distinguish discarded
uncommitted entries from committed backing-array data; this observation does
not turn an empty buffer into evidence of successful physical persistence.

## Remaining Integration Contract

An absent hold is not a producer-pause, fabric-drain or resume-sync
acknowledgement. The endpoint cannot see accepted work still buffered upstream.
In particular, a fresh RAM handshake can create an owner on the publication
edge if the purported ingress quiescence was false. Genuine producer/fabric
quiescence remains mandatory before policy replacement.

Provider-loss revocation, metadata/identity rediscovery, writer error handling
and cache/reservation/device synchronization remain independent requirements.
Returning a provider or observing an empty store does not reauthorize an old
transaction or unlock a recovered image. No constant-ready binding is added.

## Configuration And Silicon Impact

The existing `Cfg.Enable`/model-profile legality gates remain authoritative.
This is a correctness/observability extension, not a new native capability or
optional software feature, so it introduces no new `CVA6Cfg` feature field.
The disabled endpoint retains its refusal behavior and control ownership;
unused new model/store outputs are explicitly connected at existing callers.

No state, clock, reset, array, SRAM macro or pipeline stage is added. The new
logic is a staging-count zero reduction and cold ownership ORs; it does not
feed CPU data/ready paths. Existing asynchronous-active-low reset, SRAM swap
seams, testmode and scan state are unchanged. The new outputs provide direct
debug/integration observation; no instruction, CSR, PMU capability, discovery
bit, PMA/PMP region, DTS entry or Linux ABI is added.

Review checklist: synthesizable combinational taps; common clock/reset;
structural request/response type injection preserved; no new clock-domain or
power-domain crossing; no authority inferred from `AWPROT`/`ARPROT`. Generic
synthesis is not STA, scan/ATPG, power, physical-media or tape-out closure.

Trade-off: retaining dirty ownership can intentionally stall policy replacement
until the genuine writer flushes or qualified recovery resolves its work.
Publishing anyway, silently dropping the owner or manufacturing a flush
acknowledgement would violate the replacement contract.

## Verification Boundary

The extended endpoint fixture checks ordinary block responses, dirty staging,
flush completion/release, accepted RAM AW before W, held B and accepted reads
before maintenance. The store fixture distinguishes idle-dirty from drained
and denies drain during power cut. Existing refusal, save/restore, failure,
delayed-response and rejecting tests remain enabled.

The source-frozen ten-stage follow-up is `storamic-all-36b9e93a1ff1`.
All ten stages pass with matching post-run source hashes. Two separately
frozen hardware mutants reject omitted RAM hold and idle-only drain at their
intended assertions, also with matching hashes. Expected aborts remain failed
stages used only as rejecting-oracle evidence.

The added store-drain formal fixture tracks interface writes, not internal
staging count. Its first unconstrained-flush run
`storamic-all-264bb5e41c89` fails: a withdrawn flush still commits the word but
does not produce a success acknowledgement for its absent requester. That
counterexample remains archived; no production logic is changed for it.
The protocol-valid proof now drives a held-until-ACK requester from arbitrary
offers, rather than asserting that the external offer remains held. An
independent endpoint test intentionally abandons flush and checks that its
captured owner stays held after raw media drains. This follow-up,
`storamic-all-99a609fc3407`, passes with matching post-run source hashes:
depth-16 safety and all three covers, a depth-8 rejecting assertion oracle,
and fresh endpoint simulations. Existing query assumptions/depths are unchanged.
These are bounded protocol-valid store observations, not a proof over arbitrary
malformed flush waveforms or whole-endpoint liveness.

Receipts are recorded in
`build-platform/workspace/build/storamic-policy-19/REMOTE-RESULTS.md`.
Inactive-profile formal and generic synthesis do not constitute an enabled
endpoint ownership liveness proof.

Native admission, strict configured-CPU scheduling, genuine owner/provider
binding, aggregate/compliance, physical media and Linux qualification remain
open. No model or component result closes those gates.
