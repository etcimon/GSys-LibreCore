# Checkpoint Writer Model

## Scope And Configuration

This is an unqualified, default-off, same-clock non-hyp8 model composition of
the checkpoint endpoint, real VirtIO writer and scalar-DMA/AXI bridge. It is
not a native attachment or an authorization/cache-coherence provider.
Implementation: `corev_apu/storamic/g6lc_storamic_checkpoint_writer_model.sv`.
Selected model/component validation passes on frozen snapshot
`storamic-all-f8d457c509b4`; native and system qualification remain open.

The existing `storamic_cfg_t` derived from `CVA6Cfg` remains the configuration
seam. Default is `StoramicOff`; enabled operation requires legal `ProfileModel`,
RAM/window geometry, structural types, flash layout and timeout. Native
profiles remain rejected. No new `CVA6Cfg` default, instruction, CSR, PMA/PMP
permission, DTS/ISA string or Linux capability changes.

The inactive/illegal generate branch instantiates neither the VirtIO engines
nor the bridge. AXI remains on the endpoint's refuse path; device MMIO packets
retire with explicit denial and retained response ownership. It never fabricates
a writer/control quiescence acknowledgement.

## Real Producer Binding

The endpoint has two producer slots: external upstream and actual VirtIO.
The first acknowledgement/error stays public; the second comes from the
device's existing job-level quiesced/error outputs. No fixture ACK is wired
into the product. Provider readiness, protection, identity, generations and
restore-resume safety also remain external.

Checkpoint producer pause fans out to the external upstream pause request and
the writer's DMA/job pause. The existing DMA bridge shares external upstream
AXI with actual writer beats into the endpoint RAM. The endpoint seals RAM
admission only after producer drain, allowing an accepted descriptor/job to
finish data, status and used-ring writes. The bridge preserves accepted
upstream responses before reusing its fixed DMA ID.

Writer block requests/FLUSH connect directly to the endpoint's actual user-store
ports. Producer quiescence is not a durable flush: the coordinator subsequently
owns and acknowledges the real media flush. There is no fabricated/per-writer
flush-before-pause acknowledgement.

Device capacity derives from the endpoint's user-sector layout. Media usability
is observed from initialized/metadata/lock/presence/identity/protection/provider
state; it is not tied high. The model-backed durable hint is scoped to the
explicit model, not physical flash. Its DMA bridge uses `InvalEn=0` and is
uncached-model-only; this does not qualify real CPU cache or CMO behavior.

## Ownership And Control

`policy_hold_o` composes endpoint ownership, real writer ownership, DMA bridge
ownership and refused device-control packet ownership in the off branch.
The ring now exposes true job-idle, not only DMA-beat-idle: `SHandoff` still
owns a chain even when no DMA beat is outstanding. The device observes both
engines, the shared DMA port and MMIO. The bridge observes its phase and
upstream outstanding counts.

These observations are not authorizations. Unaccepted upstream offers, other
fabric queues, CPU caches/reservations, device state and synchronization remain
external obligations. Provider loss may retain admitted work; it must not
produce a false completion.

The independent MMIO control seal remains independent. DMA pause must continue
to permit QueueNotify, status polling and reset; do not auto-wire control seal
to producer pause or add a backend pause that strands an accepted handoff.

## Implementation Review

The composition adds no custom state/array/clock/reset; it instantiates existing
engines on one clock and asynchronous-active-low reset. `testmode_i` reaches the
endpoint SRAM boundary; existing arrays stay at `tc_sram`. Scan/ATPG, clock and
power-domain behavior of those engines is not newly qualified here.

The datapath adds the existing registered DMA sharing FSM, not a new wide
combinational arbiter. Cold ownership reductions and media-usable fanout are
explicit. Target context remains 8 FO4 / 5-GHz nameplate; generic synthesis does
not establish technology timing/area/power/DFT closure. Issue/refuse/revoke/
done/error events and writer/DMA observations remain externally visible; no
pipeline/RVFI or new PMU capability is admitted.

## Verification

The new directed bench uses real AXI guest-memory initialization, modern VirtIO
MMIO setup, descriptor fetch, OUT/IN, store data, status and used-ring traffic.
It requests save with a job active, tests upstream and writer acknowledgement
ordering separately, and restores through an external resume-safe hold.
Default-off denial and rejecting oracles are included. All six profiles pass:
response delay0/4/16, early-upstream acknowledgement, short deadline and disabled.
Every profile retains its rejecting plusarg oracle. The short profile requires
`CP_TIMEOUT`, retained recovery lock and generation1, followed by real busy drain.

The first snapshot `storamic-all-218ba7c2ead7` times out in phase0 before a
checkpoint command. It is retained as a failed run, not credited. Section/state
diagnostics distinguish boot, CPU initialization and writer/DMA progress. Boot
requires a real external idle acknowledgement; the corrected fixture issues it
only after asserting no upstream traffic exists. The off endpoint deliberately
requests fail-closed pause, without fabricating writer/control acknowledgement.

The original 8192-cycle restore budget also fails and stays archived. With
1024 bytes, two 32-cycle/word CRC passes alone need8192 cycles, before I/O.
Measured response-delay0 save/restore take7355/9863 cycles. The new composed-model
default is32768; the controller's timeout/error logic and proof depths are
unchanged. The explicit8192 regression preserves the original timeout contract.
The initial IN fixture incorrectly reused an OUT read-only data descriptor;
its corrected IN descriptor sets WRITE. Backend direction checks remain strict.

All ten selected stages pass with matching post-run source hashes, using the
repository PGO/loop-unroll Verilator and separate generated-simulator PGO,
and repository Yosys. Five depth12 refusal/cover/oracle goals pass, as do the
unchanged legacy endpoint/ring proof obligations and new ring job-idle checks.
Generic active synthesis has3044 cells and four SRAM-model memories; off and
invalid-layout each have93 cells/no memories. All have zero latches and SCCs.
These are generic counts, not technology-mapped PPA.

Two isolated synthetic producer-ACK mutants fail their intended assertions:
upstream fake acknowledgement and writer fake acknowledgement. Their failed
stages are rejecting evidence, never positive passes. The writer mutant selects
the existing early-upstream profile first; bench assertions are unchanged.
Compact results and source identity live in the `storamic-policy-19` workspace
receipt `FINAL-SV-24.md`. Earlier failed snapshots are not relabeled.

Disabled/illegal-profile bounded refusal proofs, explicit SRAM/no-memory
synthesis cases and legacy writer/ring/DMA regressions are registered. Active
composition evidence is directed simulation, not a native liveness proof.
Power-cut/device-queue replay is not newly qualified by this immediate restore:
the fixture does not reset the device and keeps its queue indices consistent.
The subsequent [checkpoint-writer-reset.md](checkpoint-writer-reset.md) adds
an explicit MMIO-reset/error/recovery profile with driver-managed ring
reinitialization and a true post-copy resume hold. It is still not automatic
device-state checkpointing or power-cut qualification.
Full aggregate/compliance/default-netlist, native binding, physical persistence,
PPA/DFT, strict CPU scheduling and Linux gates remain open.
