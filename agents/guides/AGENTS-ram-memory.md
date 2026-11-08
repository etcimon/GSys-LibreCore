# Guide: RAM / Memory (PMA, MMU, PMP, AXI)

Feature-addition playbook for the memory system. Read `../../AGENTS.md` first. Spec summaries live in
`../spec/` (see `../spec/INDEX.md`).

## Table of contents
1. Spec grounding
2. Code map (`file:line`)
3. Config knobs
4. Feature-addition playbook
5. `.dts` linkage
6. Invariants and pitfalls

## 1. Spec grounding
The memory system is heavily normative: `specs/riscv-spec.html#sec:intro-memory` (1.4 — the single
byte-addressable `2^XLEN` space), `#pma` (3.6 — Physical Memory Attributes: cacheability, coherence,
idempotency, atomicity, alignment per region), `#pmp` (3.7 — Physical Memory Protection),
`#sv39` (4.4 — 39-bit paging; siblings `#sv32`, `#sv48`, `#sv57`), plus the `Sv` extensions
`#ext:svadu` (HW A/D), `#ext:svinval` (fine-grained TLB invalidation), `#ext:svnapot`,
`#ext:svpbmt`, and misaligned/fetch rules `#ext:zicclsm`, `#ext:ziccif`.
Sub-files: `../spec/riscv-spec-II-3.6-pma.html`, `-II-3.7-pmp.html`, `-II-4.4-sv39.html`, `-I-1.4-memory.html`.

## 2. Code map
- LSU top: `core/load_store_unit.sv`; loads `core/load_unit.sv`; stores `core/store_unit.sv`; store queue `core/store_buffer.sv`; AMOs `core/amo_buffer.sv`; bypass `core/lsu_bypass.sv`.
- MMU / translation: `core/cva6_mmu/` (page-table walker, I/D TLBs, Sv modes); see `docs/06_cv64a6_mmu/` and `docs/03_cva6_design/MMU.rst`.
- Protection: `core/pmp/` (PMP entry matching and checks).
- Memory-side bus: `core/cache_subsystem/axi_adapter.sv`, `wt_axi_adapter.sv`; SoC RAM `corev_apu/axi_mem_if/`; boot `corev_apu/bootrom/`.

## 3. Config knobs (`core/include/config_pkg.sv`)
- Virtual-memory mode `vm_mode_t` enum `45-52` (`ModeSv32/39/48/57`); TLB sizing `InstrTlbEntries` `257`, `DataTlbEntries` `258`.
- Memory bus `Axi{Addr,Data,Id,User}Width` `168-176`, `AxiBurstWriteEn` `176`.
- Region rules used by PMA/decoding, validated in `check_cfg` `451-453`: `NrCachedRegionRules`, `NrExecuteRegionRules`, `NrNonIdempotentRules` (each <= `NrMaxRules`=16 at `60`).
- Widths `XLEN`/`VLEN` and paging depend on the target package (`core/include/cv*_config_pkg.sv`).

## 4. Feature-addition playbook
Adding or resizing a RAM region is config-first. Set the physical base/size through the target
package's region rules and mark it cacheable/executable/idempotent as appropriate; a device (MMIO)
region must instead be added to the non-idempotent, non-cacheable set so it is neither speculated
nor cached. Match `Axi*Width` to the SoC interconnect and the memory in `corev_apu/axi_mem_if/`.
Selecting a different paging mode is a change of `vm_mode_t` plus the MMU elaboration in
`core/cva6_mmu/`; enabling hardware A/D or fine-grained invalidation pulls in `Svadu`/`Svinval` and
their CSR plumbing. PMP entries are configured through the machine CSRs and checked in `core/pmp/`.
Every change must be reflected in the device tree so Linux sees the same map (below).

## 5. `.dts` linkage
The physical RAM is a `memory@<base> { device_type = "memory"; reg = <hi lo size>; }` node whose
base/size must lie within `AxiAddrWidth` and match the cacheable region rules. The CPU node carries
`mmu-type = "riscv,sv39"` (etc.) mirroring `vm_mode_t`, and `riscv,isa` must list the enabled `Sv`
extensions. MMIO peripherals appear under the `soc` node with `ranges`/`reg` matching the
non-idempotent regions; `clint@`/`plic@` map to `corev_apu/clint` and `corev_apu/rv_plic`.

## 6. Invariants and pitfalls
Non-idempotent (MMIO) regions must never be cached or speculatively accessed — mis-tagging a region
cacheable is the classic bug that breaks device I/O. PMA (`#pma`) is checked before PMP (`#pmp`);
both must agree with the `.dts`. Misaligned accesses depend on `Zicclsm` (`#ext:zicclsm`); if absent,
the LSU traps. TLB reach and `*TlbEntries` must suit the page sizes of the chosen `Sv` mode, and the
`.dts` `mmu-type` must equal `vm_mode_t` or Linux will fault during early paging.

## 7. Storamic protected-window model

The current model boundary is documented in
`../../docs/03_cva6_design/storamic_checkpoint_model.md` and
`../../g6lc_storamic/architecture/checkpoint-record-model.md`.
Reserved-media records and backup copies are not a Linux PMEM capability.
Native activation requires optional `CVA6Cfg` legality, an authoritative module
identity/mapping generation, real enabled-writer acknowledgements, reserved
capacity enforcement and cache/reservation/device synchronization.

Keep ordinary RAM, block storage and a qualified protected window in one
consistent PMA/PMP/device-tree map. Do not relabel volatile RAM as persistent
or publish a DAX/virtio-pmem node based on model-only save/restore tests.
The physical flash adapter must provide the logical ordering/durability
contract, including erase-block isolation and ECC; word-model CRC is not a
substitute. Full-width layout proofs, bounded protocol proofs, physical
hold-up qualification and Linux qualification remain distinct evidence.

The policy-bound control component is documented in
`../../docs/03_cva6_design/storamic_checkpoint_service.md`. It pairs AW/W and
captures transaction authorization rather than using a requester-written key.
Its enable/authorization/epoch signals still need real platform providers.
Do not treat a component-level authorization proof as PMP/interconnect or Linux
qualification. Native configuration and active-operation policy synchronization
remain open before this service can be advertised as a protected ABI.

The default-off checkpoint endpoint now composes control, AXI ingress and real
reserved-media recovery. Provider return is not metadata readiness: wait for
rediscovery before restore and never auto-open a locked image. Its five
provider-availability bits and writer/resume acknowledgements are external
contracts; fixtures are not native providers. When wiring VirtIO, finish its
accepted job before pausing the word-DMA adapter, then seal RAM only after
every enabled writer drains. Keep this candidate outside native activation
until the `CVA6Cfg` and platform permission/synchronization bindings qualify.
`StoramicCheckpointEn` is now a default-off request with a normalized-role
legality check, not a capability bit. Unbound native requests must retain the
explicit refusal interlock; do not remove it because the model endpoint passes.

Optional CPU origin transport is described in
`../../docs/03_cva6_design/storamic_transaction_origin.md`. It captures effective
data privilege before LSU queueing and preserves WUSER as payload metadata.
Only the supported scalar WT/PMA-I/O path can carry a nonzero source tag.
Queue/cache/adapter component checks now pass, including response-forwarding
assertions, origin rejection, formal reachability and an invalid-pointer oracle.
The native candidate remains unqualified: full CPU and platform bindings are
still open. Never
wire raw PROT directly as native authority or advertise a protected capability
on the basis of shim-only passes. Require trusted-master routing, all actual
writers, descriptors and synchronization, then qualify CPU/DMA/atomic/Linux.

The checkpoint-service guide also documents the inactive
`g6lc_storamic_checkpoint_route` candidate. Preserve its captured upstream
authorization/epoch through bridge latency, not a later raw PROT or live header.
Master identity must be the crossbar-inserted prefix with exact width binding;
debug/DMA/local-ID aliases are not CPU authority. Combine route ownership with
endpoint ownership before policy updates. Component proofs assume downstream
AXI-Lite B response holding; they do not qualify the native master path, other
writers, policy/descriptor owners or physical persistence.

The real mux/prefix/AW-owner FIFO lane now uses `run_route.py --interconnect`.
It tests peer W without AW and request spill as well as physical source and
response identities. Its 669 checks per off/on profile are still isolated
interconnect component evidence, not the complete CPU/crossbar path.
Observe real handshakes in early-W fixtures; a spill may accept W while the
driver waits for downstream AW ownership. Never wait for a second transfer
or suppress scalar dependency diagnostics to make that fixture pass.

Configured full-CPU off/on elaboration now passes on the source-frozen
`storamic-cpu-07` diagnostic, including unsupported-profile rejection.
Do not promote a bare-port hierarchy check into executed privilege traffic,
netlist/default behavior, native composition, synthesis or system admission.
The existing refusal and all writer/protection/synchronization gates remain.

The scalar origin predicate also requires the I/O role, no accelerator and
`COPRO_NONE`: an attached accelerator can share the physical cluster port.
Do not infer a single trusted writer from that prefix or from one hart per CPU.
The added profile regression rejects the prior shared-writer predicate.
`storamic-profile-10/origin-r2` passes 54 positive profiles and 54 rejecting
oracles; fresh configured off/on hierarchy elaboration passes separately.

`run_route.py --crossbar` now exercises a three-source/two-target real crossbar
protected-target fixture (669 checks per four enable/request-cut profiles).
Its second target is a monitored, unselected decoy, not an atomic responder.
Strict event-driven CPU compilation remains blocked by scheduling diagnostics.
Two coarse CPU SCCs disappear after mapping just those cones; this is
diagnostic evidence for aggregate scheduling, not mapped timing closure.
Do not turn warnings off to promote that lane. Independent instruction
execution is recorded separately below.

Policy replacement must also drain upstream accepted crossbar/cluster/adapter
work. Route/endpoint holds cannot report transactions not yet delivered there.
Use the completion plan at `../../g6lc_storamic/architecture/completion-plan.md`;
real writer, descriptor, protection and resume owners still gate native use.

Debug issue is now explicitly denied a nonzero scalar origin. The actual
execute-stage debug signal enters the LSU descriptor encoder, not the later
AXI header. Do not add an implicit trusted debug default to that API. Preserve
tags of already accepted firmware/debug requests across later mode changes.
`storamic-debug-12` passes 54 positive profiles/55 rejecting oracles, including
all 16 privilege/virtual/debug contexts, queued retention and semantic mutation
rejection of an encoder that ignores debug. Configured full hierarchy off/on
elaboration passes at `storamic-cpu-07/elab-r5`; CPU debug execution and native
debug/policy synchronization are still unqualified.

The standalone 23-entry source list and testharness Makefile now both register
checkpoint dependencies with packages before modules. Keep that equality and
duplicate-source test; adding an unselected library module does not enable
native checkpoint capability or establish PPA.

`storamic-cpu-interpreter-13/configured-execution-r1` now passes configured
CPU instruction execution through the independent two-state RTLIL interpreter:
off/on, AXI response delays 0/16, four complete programs and two rejecting origin
oracles. Each positive completes five writes/four reads across M/S/U and
MPRV/MPP=S through the real CSR/LSU/queues/WT cache with the configured FPU
retained. The collector requires matching source/tool/program identity and
source/ROM/model/script/log artifacts, including both full-profile generation
receipts. Startup/integer/partial matrices cannot satisfy that collection.

The additional `storamic-cpu-schedule-14/extended-execution-r1` matrix covers
MPRV with MPP=S/U/M: four complete seven-write/six-read programs and two
rejecting oracles across the same off/on, delay-0/16 settings. The optional
test mode does not change CPU RTL; reused models require matching original
full-profile generation identities. The default ROM is byte-identical and
the original five-write/four-read gate is retained. Six firmware tests and
nine collector tests pass.

`storamic-cpu-debug-15/debug-execution-r1` additionally passes the six-case
configured M-mode external-debug matrix: real request, DCSR/DPC checks,
three debug writes/two debug reads with unknown origins, DRET and resumed
M origins. The failing baseline reveals normal trap selection overriding
debug entry; the corrected selector gives the architectural debug redirect
precedence. Unrestricted non-debug equivalence and formal safety/covers
pass. No new native provider/config/CSR/DTS capability is introduced.

`storamic-cpu-debug-privilege-16/collected-s-r1` and `collected-u-r1` extend
that evidence to S/U external debug: actual PMP/MPP/MEPC/MRET setup, saved
S/U DCSR/DPC, unknown debug traffic and same-privilege DRET origins. Each
independent matrix passes four complete programs and two rejecting oracles
at origin off/on and delays 0/16. Default M ROMs remain identical. Forty-one
Python tests, seven platform checks, typechecking and scoped source/license
checks pass. Short/timeout runs remain archived, not promoted.

`storamic-cpu-debug-queue-17/collected-r1` adds 14 complete programs and six
RTL origin oracles under 192-cycle AW/W/B holds. Read-only actual CPU mode
observation confirms delayed M AW/W and M/S/U B entry crossings; four
zero-delay M AW/W cases instead complete B first. Do not generalize either
observation into a universal drain/queue rule. The captured firmware origin
does not change with live debug state. Exact read-only script/artifact
identity checks, 57 Python tests, seven platform checks and scoped MIT/source
audits pass. Debug-pending DRET and other queue classes remain unqualified.

The later `storamic-cpu-debug-return-18/collected-r1` adds the independent
seven-write debug-response return boundary: 12 full M/S/U programs and six
named RTL origin oracles at origin off/on and read delays 0/16. A debug
store after the last load/fence has B withheld for 384 cycles; actual DRET
occurs while it is pending in every positive case. Its bound origin stays
unknown and resumed traffic has the correct M/S/U tag. Earlier six-write
gates remain unchanged. Seventy-six Python tests, seven platform checks,
typechecking and scoped MIT/source identities pass. This does not qualify
other queues, combined MPRV/debug, strict scheduling or native providers.

The next standalone control-plane candidate is
`g6lc_storamic_checkpoint_policy`. Preserve service ownership through partial
AW/W, held B/R, commands, maintenance and result consumption; endpoint ownership
exports that complete hold. During replacement, use captured AW command
admission to let accepted work and result acknowledgement drain under the old
epoch while refusing new commands. Only explicit producer/fabric quiescence and
all owner holds clearing may publish a captured offer. Provider/offer revocation
must remain sticky across readiness return, and epoch exhaustion must refuse
instead of wrap. Component fixtures do not supply native acknowledgements.
The design contract and cold-control timing/DFT limitations are in
`storamic_checkpoint_service.md`; remote PGO training is not final test evidence
and isolated leaf passes never close aggregate, physical or Linux gates.

The frozen remote receipt at `storamic-policy-19/REMOTE-RESULTS.md` records all
56 stage attempts (40 pass/14 fail/two incomplete), plus separate successful
model/flush-formal completion and policy semantic rejecting oracles. Keep the
base verdict intact. The frozen repaired-tool follow-up passes thirteen of the
fourteen failed stages. Register-formal safety/four covers pass, but its final
cover is interrupted by repeated preparation exhausting the stage deadline;
the follow-up stays incomplete. A fresh run prepares one hashed lowered model
for all six unchanged SAT queries. The standard fork kernel suite passes 126
tests and the frozen Python snapshot passes 111. Full-suite reruns remain
separate verdicts; do not promote PGO training, component reruns or fixture
acknowledgements into native qualification.

The later shared-preparation `storamic-all-362bed6ed20d` passes all six original
register SAT queries in 1001 seconds, including commit-failure cover, with
matching source/model post hashes. The distinct pre-ownership full run
`storamic-all-5267d4deeb38` passes all 56 stages with matching source post
hashes. It cannot qualify the later ownership SV by retroactive relabeling,
and no leaf sweep establishes native/system/physical/Linux qualification.

The C3/C4 observation follow-up additionally includes RAM inflight and actual
media/flush ownership in endpoint hold. New `drained_o` distinguishes empty
staging from idle-dirty; it is not authority, a producer ACK or physical
persistence evidence. See
`../../g6lc_storamic/architecture/policy-ownership-drain.md` for implementation,
timing/config review, frozen tests and remaining native binding requirements.

VirtIO's `ctrl_quiesce_i`/`ctrl_quiesced_o` independently seal and drain MMIO.
Do not infer control closure from the existing DMA-only `quiesced_o`: queued
notifications, status reads and reset remain supported during DMA pause.
Legacy control-seal inputs stay low. Actual upstream queues, cache/device
synchronization and provider qualification remain external obligations.
See `../../g6lc_storamic/architecture/virtio-control-seal.md`.

This does not resolve strict Verilator scheduling or qualify all debug mechanisms,
adversarial queued-mode changes, all MPRV corner cases, FPU instructions,
default-netlist identity or native authority. AXI delay 16 is not the native
flash recovery gate. Keep all existing refusal, topology, policy/writer/
synchronization, physical, aggregate/compliance and Linux gates.

The writer-model reset follow-up covers genuine MMIO Status=0 while an
accepted OUT/save owns work, real producer-error propagation, prior-generation
restore and explicit guest/device ring reinitialization. Resume permission
is withheld at the actual post-copy synchronization phase. This narrows the
C4/C5 component gap without manufacturing native CPU/cache/fabric facts.
It is not power-cut or automatic device-state replay. See
`../../g6lc_storamic/architecture/checkpoint-writer-reset.md`.

Shared AXI arbitration must account for channels, not only AW/B counts.
The DMA ownership26 correction prevents unowned upstream W from pairing with
DMA AW, retains already-visible stalled AW/AR, and backpressures full
outstanding counters rather than wrapping to idle. Do not gate WVALID on
AWREADY: a compliant slave may wait for WVALID first. The signed offered-AW
credit and `inflight_o` observation fix this component path; they are not
native policy authority or a CPU/cache/fabric drain provider. See
`../../g6lc_storamic/architecture/dma-ownership.md`.

Policy/writer27 validates the combined manager/real writer seam. Retain old
epoch through accepted job/save/flush, held result and split/held control
traffic; require actual job pause AND separate control seal. Do not turn local
idle into upstream ACK or auto-flush dirty data on replacement. Provider loss
can retain a real DMA owner; explicit reset/rediscovery is distinct from
automatic revival. See `../../g6lc_storamic/architecture/policy-writer-model.md`.

The ST-036 block seam has 64-bit sector and capacity fields but a 64-bit byte
address. Validate the full sector range before multiplying by 512/narrowing:
capacity alone cannot prevent aliasing with oversized inputs. Keep the final
legal sector accepted, and reject invalid table counts or empty status buffers
before DMA. The existing block fixture and formal wrapper now exercise this
boundary; native/physical qualification stays separate. See
`../../g6lc_storamic/architecture/block-address-validation.md`.

For a short complete block proof, establish the twenty metadata/ownership
invariants from reset and by unrestricted one-step induction before assuming
them in the window consequence. Keep the other eleven original assertions at
depth14 and run covers on the concrete model. Query/stage budgets are 30/180
seconds; missing inventory, tampering, timeouts and failed prerequisites cannot
become a pass. The six-stage remote profile completes in about 130 seconds
with two workers and verified source/model/PGO identities. Its 62 omitted stages
and the remaining native/physical gates stay explicit.

Load translation must not depend on a store-hazard verdict computed from the
same load's PA. Keep translation admission separate from request/forward
arbitration while preserving cancellation, miss/hit and grant timing. The C0
load-unit split is control-equivalent and has an actual PA/hazard feedback
test, original-RTL rejection and a negative real-loop canary. Generic synthesis
retains the FF count and removes two cells; no STA or service-latency improvement
is inferred. Full CPU scheduling still has 27 captured off/on diagnostics.
See `../../g6lc_storamic/architecture/cpu-load-translation.md`.
