# Storamic implementation task backlog

This execution queue follows the approved M0 foundation plan. Progress below is
scoped to recorded source/configuration/tool snapshots and does not authorize
artifact recovery or shared cleanup. ST-002 is complete; ST-001, ST-003 and ST-004
have verified implementation slices with remaining qualification gates. Later
capabilities remain open unless explicitly marked otherwise.

Normative inputs: [configuration](configuration.md), [transactions](contracts.md),
[discovery/pins](discovery-and-pins.md), [media/persistence](media-and-persistence.md),
[host interfaces](host-interfaces.md), [verification](verification.md), and the
[system architecture](../../architecture/storamic/README.md).

## Current execution checkpoint

Artifact root for these checkpoints is `%LOCALAPPDATA%/Temp/cva6-artifacts`.

- `storamic-af46decd087b/output/leaf-result.json`: selected protocol, configuration,
  integration, synthesis and depth-12 formal pass; all 37 retained configurations
  compile. The previous five initializer failures are repaired, with Storamic off.
- `storamic-001e186eaa74/output/leaf-result.json`: 10 protocol cases and 13 native
  integration cases pass, including four real joined-path cases and the expected
  timeout with the former readiness wiring. Synthesis remains 59 generic cells,
  without latches or combinational SCC. These are not physical timing results.
- The latest isolated snapshots include dirty/untracked selected sources, validated runtime
  records, compiler tools, generated inputs and actual C++ dependency hashes,
  including system headers. Windows/WSL upload and collection paths are converted
  at the build-platform boundary. Failed/incomplete attempts remain retained.
- TypeScript and focused configuration/Storamic tests pass. The AI pin drift and
  L2 proxy import fixture failures were repaired; focused shell/qualification
  tests pass 31 cases. This does not replace the pending isolated aggregate gate.
- `storamic-96013e94fdae/output/leaf-result.json`: the first executable frontend
  component failed a write-response oracle check (`STORAMIC_MODEL_WRITE_RESPONSE`,
  expected `OKAY`, observed `SLVERR`). This is component evidence only — it is
  not a completed ST-005..ST-007 gate and grants no model capability.
- `storamic-969942d0eec0/output/leaf-result.json`: all ten model cases pass —
  five positive profiles plus five expected `STORAMIC_MODEL_CONFIG_ILLEGAL`
  configurations — with a passing corrupted-data negative oracle and captured
  concurrent AW/W/memory/B activity in the concurrent window. The earlier failures
  were a Verilator `fork/join` lowering artifact (timed task calls flattened
  into sibling branches so the assert ran before waits), not a DUT defect;
  the testbench workaround is a component checkpoint under ST-007A, not ST-007
  completion.
- `storamic-7eea26e38385/output/leaf-result.json` (model only) and
  `storamic-3c25eee4aaa3/output/leaf-result.json` (protocol, config,
  integration, synth, formal, model-synth, model-formal): contract-v2 typed
  off/refuse/model profile integrated behind the top with an explicit external
  memory seam; all 26 model cases and both corruption controls, 14 native
  cases, M0/native/component/selected-top synthesis and depth-12 formal pass.
  The one-region standalone model slice (ST-007A plus its top-profile binding)
  is delivered; native model projection, regions, discovery, aggregate and
  technology gates remain open.

ST-032 decomposition: ST-001A (leaf provenance) and ST-004A (service readiness)
are complete. ST-001B (safe aggregate recipe/verdict), ST-004B (native atomic and
exclusive refusal), ST-004C (explicit native preload/build rejection) and
ST-004D (board elaboration where bindings exist) remain open. Standalone model
implementation can use the settled service contract, while full native promotion
remains gated by those checks and ST-012. The next design is
[model-interface](model-interface.md); its existence does not grant model support.

## Implementation findings that determine the order

| Current source | Consequence for the next increment |
| --- | --- |
| `g6lc_storamic/rtl/g6lc_storamic_top.sv` selects off/refuse or the explicit external-memory model, holds physical media readiness low and keeps pads safe | Standalone model binding is verified; native mapping, ownership and physical bindings remain separate gates |
| `corev_apu/storamic/g6lc_storamic_attach.sv` now preserves the full AW/W/AR payload (addresses, size/burst/lock/cache/prot/qos/region, ATOP, data/strb/last, user) with interface-shape guards; carrying ATOP is not implementing its atomic protocol and controls/health remain untracked | Successful memory still requires a real control/health path; payload preservation alone grants no capability |
| `corev_apu/tb/ariane_testharness.sv` connects `dram_service_ready` to the optional AI join; `corev_apu/src/g6lc_ai_dram_join.sv` gates requests with it | Joined-path refusal/readiness is covered by directed cases plus the former wiring's expected timeout; atomic/exclusive and preload ownership remain open |
| Native ELF helpers in `corev_apu/tb/{ariane_tb.cpp,g6lc_tb.cpp}` address legacy memory hierarchies | Enabled CPU simulation needs an explicit initialization path through the selected backend |
| `ImplementedMediaCaps` is zero; standalone configuration supports off/refuse/model while the native projection supports off/refuse | Physical media, native memory, block, persistence and VirtIO grants still require their own tested promotion rules |
| `verif/tb/storamic/run_leaf.py` records sources, validated runtime record, compiler tools, generated inputs and system/C++ dependency hashes | Evidence reuse relies on this identity; record new dependencies as stages gain them |
| Existing native atomics/coherence precede some ingress paths; optional DMA joins have their own attribute handling | Prove ownership and reservation behavior for each writer; do not infer it from the backend error tests |

Source paths in task cards are repository-relative. Paths marked **proposed** do
not exist yet and are created only when their task is implemented. Keep all QEMU
models, reference profiles, emission, launch and remote execution in `g6lc_qemu/`.
The simulator-side peer remains under `verif/tb/storamic/`. Standalone digital RTL
remains first-party; inherited SoC types stay outside its closure.

## Ordering and work packages

| Wave | Tasks | Exit |
| --- | --- | --- |
| M0 closure | ST-001..ST-004 | Safe reproducible validation, explicit baseline verdicts, native refusal/readiness contract |
| M1 executable model | ST-005..ST-012 | Data really traverses Storamic, validated mappings and native ownership/boot evidence |
| Scaling foundation | ST-013 | Measured service/credit behavior without starving maintenance |
| M2 passive media | ST-014..ST-017 | One selected physical profile with identified media, timing and fault evidence |
| M3 block storage | ST-018..ST-023 | One chosen standard transport and durable per-stick drives with stock Linux |
| M4 persistence | ST-024..ST-026 | Protected domain, interrupted recovery and qualified Linux PMEM behavior |
| M5 active sticks | ST-027..ST-028 | Separately keyed serial profile with replay/credit and physical-link evidence |
| M6 VirtIO-MMIO host stack | ST-033..ST-041 | First-party modern MMIO transport, split-ring/DMA/IRQ and Linux evidence |
| Profile release | ST-031 | Physical and software qualification for the explicitly selected capability set |
| Reassessment | ST-032 | Evidence-backed next child tasks after each gate |

These are capability gates, not a mandatory serial schedule. ST-014 component
research can begin alongside M1. ST-019 reference work should precede block
frontend software experiments. The host transport is resolved by the
[VirtIO-MMIO decision](virtio-mmio.md): modern VirtIO-MMIO plus native AXI RAM
replaces the retired PCIe/CXL and NVMe-versus-virtio candidates; the retired
ST-029/ST-030 transport epics are not prerequisites for native block or RAM.
Active-stick transport remains a separate link.

Recommended first implementation batch: ST-001, scoped decisions for ST-002 and
ST-003, ST-004, then ST-005. The first data milestone is ST-006/ST-007: one explicit
model region, one outstanding read and write, no interleaving and no physical
media claim. Add regions/discovery/controls before widening concurrency.

## M0 closure tasks

### ST-001 — Isolate validation and complete evidence identity

**Owner / files:** verification and host tooling; `verif/tb/storamic/run_remote.py`,
`verif/tb/storamic/run_leaf.py`, existing `verif/regress/remote/testharness_proxy.py`
transport and build-platform test/verify gateways. **Depends:** none. **State:** leaf provenance complete; isolated aggregate gate open. The simulation runtime
preflight now checks the exact `VERILATOR_INSTALL_DIR` selected for the child —
including the OSS CAD fallback prefix — and rejects missing verilator patches;
native runtime validation and the owned aggregate snapshot/execution remain open.

Create an owned snapshot containing the selected dirty/untracked source closure,
fixtures and dependency identities; keep build outputs separate. Inspect the
aggregate cleanup path before execution. Never run shared `make clean`, restore
removed artifacts, or delete existing evidence as a side effect. Use existing
proxy lifecycle/resource controls and configured artifact destinations. Record
actual compiler, runtime headers, generated inputs, compile flags, tool binaries,
and selected stages; use the validated private runtime required by repository
rules. Add detach/collect/resume by reusing the proxy when needed, not new SSH.

**Done when:** interrupted/pull-failed/missing-summary/drift cases remain incomplete;
source/runtime changes invalidate reuse; snapshots include local deltas; the
aggregate recipe cannot mutate shared outputs. Resource preflight accounts for
other jobs. Required aggregate verification remains a gate, not a waived test.

### ST-002 — Resolve the five configuration baseline failures

**Owner / files:** `core/include/cv64a60ax_config_pkg.sv` and
`core/include/deprecated_packages/{cv32a6_imac_sv0_config_pkg.sv,cv32a6_imafc_sv32_config_pkg.sv,cv64a6_imadfcv_sv39_polara_config_pkg.sv,cv64a6_mmu_config_pkg.sv}`;
`verif/tb/storamic/tb_g6lc_storamic_config.sv`. **Depends:** ST-001 for execution.
**State:** complete for the retained configuration sweep.

Reconfirm the recorded CBO and old-schema initializer failures. Derive each
missing value from the target's intended configuration and maintained peers;
do not use a blanket zero/default initializer to hide missing fields. Preserve
upstream notices and the default-off Storamic field.

**Done when:** every retained target compiles, relevant legality checks execute,
Storamic-off/overlay behavior is tested, and baseline versus new failures are
reported separately. Target retirement, if proposed, is an explicit separate
repository decision, not a test skip used to make this task green.

### ST-003 — Close host typecheck and selection validation

**Owner / files:** `build-platform/src/tooling/timings.ts` (recorded error near
line 1216), `build-platform/src/tooling/storamic.ts`,
`build-platform/src/config/{schema,defaults,load}.ts`,
`build-platform/test/storamic.test.ts` and the suitable existing timing tests. **Depends:** ST-001
for safe aggregate execution. **State:** repairs and focused checks pass; aggregate qualification open.

Reproduce the optional-string type error and repair its actual guard/contract;
do not suppress strict checking. Preserve one resolved Storamic selection across
test/verify/remote entrypoints and reject conflicting raw/environment flags.

**Done when:** targeted tests and `bunx tsc --noEmit` pass, followed by one required
`bun test` gate with opt-in/remote suites handled by the established runner. Missing
optional tools or skipped suites remain visible; no new runtime dependency.

### ST-004 — Prove M0 through the real native admission path

**Owner / files:** `corev_apu/src/g6lc_ai_dram_backend.sv`,
`corev_apu/src/g6lc_ai_dram_join.sv`, `corev_apu/tb/ariane_testharness.sv`,
`corev_apu/storamic/g6lc_storamic_attach.sv`, existing Storamic SoC bench;
board rejection guards in Xilinx/Altera/OpenPiton wrappers.
**Depends:** ST-001. **State:** service-readiness slice complete; native atomic/preload/board gates open.

Reproduce the optional joined path with Storamic enabled and readiness low.
Define request-service readiness separately from RAM/media initialization so a
refusal-capable endpoint can answer requests without advertising initialized RAM.
Carry that distinction through the join and consumers. Verify where ATOP and
exclusive operations are consumed; unsupported operations cannot disappear or
leave a required response outstanding. Check enabled native build/preload failure
behavior explicitly instead of relying on missing generated C++ members.

**Done when:** joined and direct requests reach a bounded refusal path, reset and
stalled-response tests pass, media-ready remains false, and off-path behavior is
preserved. Unsupported board selections reject through executable elaboration
checks where tool bindings permit; unavailable board checks remain incomplete.
M0 closure also needs ST-002/ST-003 and the isolated aggregate verdict.

## M1 executable model and native integration

### ST-005 — Freeze the executable-model interface contract

**Owner / files:** current configuration/transaction documents;
`g6lc_storamic/rtl/include/g6lc_storamic_cfg_pkg.sv`,
`g6lc_storamic/rtl/include/g6lc_storamic_pkg.sv`,
`g6lc_storamic/rtl/include/g6lc_storamic_pad_pkg.sv`, SoC config projection and
typed host config.
**Depends:** ST-004 readiness contract. **State:** contract v2 frozen and
integrated for the one-region standalone model (typed off/refuse/model profiles).
The separate VirtIO transport/role profile remains ST-033.

Publish one versioned profile selection preserving off/skeleton names and adding
an explicit model profile. Freeze full AXI payload/attribute types, supported
burst/alignment rules, normalized media request/response ownership, source/ID/
sequence/reset generation, region records, descriptor fields, error taxonomy,
and readiness/capability separation. Fix control register semantics before their
implementation; SoC addresses/IRQs are allocated by ST-010, not invented here.
Start with one outstanding read and write, bounded parameterized storage and no
interleaving. Physical and persistence grants remain absent for model-only builds.

**Done when:** producer/consumer field tables, reset lifetimes, response reservation,
byte-address rules, full-span validation and unsupported-operation behavior are
unambiguous; RTL/host fixtures agree. Unknown profiles/capabilities reject. Model
selection never becomes an automatic fallback for an absent physical backend.

### ST-006 — Establish first-party memory and technology boundaries

**Owner / files:** **proposed** `g6lc_storamic/rtl/tech/` boundary modules;
first-party behavioral bindings under `verif/tb/storamic/`; package flists;
qualified native bindings outside the standalone closure. **Depends:** ST-005.

Define read/write/mask/latency/error/testmode interfaces compatible with the
repository SRAM/clock/power discipline. Keep behavioral arrays out of production
flists and large payload arrays out of raw flop implementations. Existing
`tc_sram` technology integration stays an explicit external binding, not imported
third-party digital RTL inside Storamic. Missing physical bindings fail clearly.

**Done when:** byte masks, reset, read latency and test hooks match both model and
boundary contracts; source-closure checks distinguish first-party control,
verification models and technology cells. No hidden digital controller in a macro.

### ST-007 — Implement a single-region executable AXI path

**Owner / files:** `g6lc_storamic/rtl/g6lc_storamic_top.sv`, existing refusal frontend;
**proposed** `g6lc_storamic/rtl/frontend/g6lc_storamic_axi_frontend.sv` and
`verif/tb/storamic/tb_g6lc_storamic_model.sv`. **Depends:** ST-005, ST-006.

Two slices: **ST-007A** is the component byte oracle plus handshake coverage over
the `g6lc_storamic_axi_memory` frontend — delivered (`storamic-969942d0eec0`;
the earlier failures were a Verilator `fork/join` lowering artifact, not a DUT
defect). **ST-007B** is the standalone executable profile plus synthesis and
formal — delivered: contract-v2 top binding with the explicit external memory
seam, 26 model cases and both negative oracles (`storamic-7eea26e38385`),
component/selected-top synthesis and depth-12 safety plus reachability
(`storamic-3c25eee4aaa3`). Open follow-on work is distinct: ST-008 heterogeneous
routing, ST-009 discovery/lifecycle, ST-011B native attachment, ST-012
ownership/boot, aggregate and technology/physical gates.

Keep M0 refusal as its own branch. Add the model-profile data path using the frozen
contract, accepting real addresses/data/strobes and preserving IDs and response
shape. Validate the complete request before side effects. Reserve completion
storage before admission and retain AW/W independence. Add basic acceptance,
completion, refusal and error observability with the feature, not afterward.

**Done when:** an independent byte-address reference checks read-after-write,
partial/narrow writes, supported bursts, alignment/boundary errors, overflow/high
address aliasing, simultaneous read/write, backpressure and reset. Unsupported
requests have no media side effects. All M0 negative controls still fail correctly.

### ST-008 — Add validated heterogeneous regions and burst routing

**Owner / files:** **proposed** `g6lc_storamic/rtl/fabric/g6lc_storamic_region_table.sv`
and `g6lc_storamic/rtl/fabric/g6lc_storamic_router.sv`; shared model bench. **Depends:** ST-007.

Validate base/length/permissions/slot/media identity, address overflow and overlap;
commit an immutable boot map before service. Split supported transactions at
internal region/media boundaries and reassemble the original response. Validate
all affected extents before writes. Reject AXI-illegal requests such as 4-KiB
crossings rather than treating them as legal split requests. Begin without
interleaving; later equal-extent interleaving needs separate evidence.

**Done when:** 1/2/3/4/8 slots, unequal capacities, holes, top-of-address-space
ranges, denied second extents and response ordering pass independent checks.
Removal faults the original mapping and never compacts live addresses.

### ST-009 — Implement discovery validation and lifecycle state

**Owner / files:** **proposed** `g6lc_storamic/rtl/discovery/g6lc_storamic_discovery.sv`,
descriptor package additions, pad input/status boundaries and fault fixtures.
**Depends:** ST-005, ST-008; physical access also depends on ST-014.

Implement absent/present/power-check/identify/validate/initialize/ready/quiesce/
fault transitions. Model fixtures supply explicitly synthetic identities first.
Validate version/length/checksum, capacity bounds, media geometry and electrical
profile; synchronize/debounce physical presence only through reviewed CDC.
Keep RAM, flash, persistence and request-service readiness independent.

**Done when:** empty, RAM-only, flash-only, mixed, unknown, corrupt, duplicate-identity
and removed modules behave safely. Unknown voltage/profile never triggers probing
writes or power enable. Initial insertion/removal remains power-off only.

### ST-010 — Implement controls, health, interrupts and map publication

**Owner / files:** **proposed** `g6lc_storamic/rtl/frontend/g6lc_storamic_regs.sv`
and register package; `corev_apu/storamic/` control adapter;
`corev_apu/tb/ariane_soc_pkg.sv`
map owner and applicable IRQ/DTS/firmware consumers. **Depends:** ST-005, ST-009.

Allocate non-overlapping SoC control addresses and IRQs through the existing map
owner. Implement version/profile/readiness/capacity/error reporting, bounded
region commit, status clearing and interrupt acknowledgment. Define an explicit
cross-interface drain token; an AXI-Lite write does not order AXI data by itself.
Expose only supported readback and actual counters.

**Done when:** decode, byte enables, RO/W1C behavior, simultaneous event/clear,
IRQ level/deassertion, reset, permission checks and immutable-map rules pass.
DTS/config/register views agree; no guessed address or fabricated capability.

### ST-011 — Extend the native adapter to the complete data/control boundary

**Owner / files:** `corev_apu/storamic/g6lc_storamic_attach.sv`,
`corev_apu/include/g6lc_storamic_soc_cfg_pkg.sv`,
`corev_apu/src/g6lc_ai_dram_backend.sv`, testharness and both Storamic flists.
**Depends:** ST-004, ST-007, ST-008, ST-009, ST-010.

Two slices: **ST-011A** is the bounded wire/shape slice delivered in this batch —
parameterized `AddrWidth`, full AW/W/AR payload preservation and the
`STORAMIC_INTERFACE_SHAPE` guard — which does not need functional region/media
completion. **ST-011B** implements the functional attachment after
ST-007/ST-008/ST-009/ST-010; ST-012 subsequently qualifies CPU/DMA/atomic
ownership and boot.

Carry addresses, sizes, burst types, data, strobes, last, IDs and relevant user/
protection/ordering attributes through parameterized types. Resolve atomic and
exclusive semantics at the existing native boundary; do not silently drop them.
Route control/IRQ/health and selected pad/technology signals through thin glue.
Keep placement, clock/reset and media engines in their proper owners.

**Done when:** 64/512-bit and ID-width variation tests exercise payload integrity,
not just response tags. M0/off still work and legacy hierarchy stays intact.
Flash-only native-primary configurations require independent boot RAM or reject;
no synthetic successful RAM is inserted to make boot possible.

### ST-012 — Qualify CPU, DMA ownership and native model boot

**Owner / files:** native harness and ELF helpers under `corev_apu/tb/`, actual
atomic/coherence and AI/APU ingress seams, Storamic integration tests and optional
build-platform suites. **Depends:** ST-011; M0 promotion also requires ST-002/ST-003.

Initialize through the selected modeled backend with an explicit boot contract;
never preload a shadow host buffer while bypassing Storamic traffic. Test CPU
fetch/load/store faults, page-table access, byte stores, LR/SC and AMOs with competing
writers, fences and reset. Establish DMA permissions and cache maintenance or
ownership transfer before claiming shared-memory coherence.

**Done when:** a minimal native program proves the path and reservation behavior,
then the applicable existing boot/regression gates run remotely in isolation.
A model Linux boot is labeled as such. QEMU reference boots cannot substitute for
native atomic/coherence evidence, and a UART banner alone is not boot completion.

### ST-013 — Measure service, then add bounded concurrency and QoS

**Owner / files:** first-party fabric/scheduler/credit control and telemetry;
native event projection where applicable. **Depends:** ST-012.

Use captured occupancy/stall/latency evidence to justify more outstanding work,
credits and interleaving. Reserve response capacity independently from request
queues. Bound CPU demand service and guarantee refresh, recovery and storage
maintenance progress; do not create permanent CPU-priority starvation. Keep
clock enables initially; qualified gating needs technology and testmode bindings.

**Done when:** adversarial mixed traffic has no loss, duplication or credit leak;
bounds state fairness/ready assumptions explicitly. Publish clocks, useful bytes,
workloads and distributions, separating model throughput from physical throughput.
Only compatible equal extents interleave, with no address-map change on removal.

## Passive media and block storage

### ST-014 — Select and pin the first passive electrical/media profile

**Owner / files:** discovery/media architecture and future qualified `corev-mb/`
profile/board records. **Depends:** none for research; ST-005 for contract freeze.

Choose actual RAM and flash parts, identification mechanism, voltage, bus sharing,
connector/keying, chip selects and target pad/sampling interfaces from datasheets.
Decide NOR prototype versus NAND production scope. Publish signal/ball/contact
budgets including power/ground, management, isolation and test. A chip without a
unique ID needs a provisioned identity policy. No destructive discovery or guessed
voltage. Keep active serial electrically distinct.

**Done when:** a revisioned profile specifies timing/geometry/ECC requirements,
physical macro ownership, power sequencing and mechanical/SI/PI constraints.
No exact routed pinout or sustained bandwidth is claimed from an illustrative budget.

### ST-015 — Implement the selected passive RAM controller and binding

**Owner / files:** **proposed** `g6lc_storamic/rtl/media/` RAM engine and
`g6lc_storamic/rtl/tech/` pad/sampling
boundaries; selected `corev_apu` board binding and constraints.
**Depends:** ST-006, ST-007, ST-009, ST-014.

Implement the selected device's command/address, bank/rank/chip selection, burst,
latency, refresh and initialization/training rules where applicable. Respect DQ/
RWDS direction and turnaround; bind sampling/clock/pads explicitly. Remove an
unsupported-board guard only for a fully described binding.

**Done when:** device timing/error models cover reads/writes, turnaround, refresh,
reset and contention; CDC/reset analysis and IO timing constraints accompany the
binding. Model success alone does not qualify physical memory or DDR4-like rates.

### ST-016 — Implement raw flash operations for the selected profile

**Owner / files:** **proposed** first-party `g6lc_storamic/rtl/media/` flash engine, device model
and native physical binding. **Depends:** ST-009, ST-014.

Implement identification, read/program/erase, busy/status/timeouts, alignment and
error handling from the chosen device specification. Handle NAND parameter/ECC/
bad-block facts only for an explicitly selected NAND profile; do not treat NOR and
NAND as interchangeable.

**Done when:** page/erase boundaries, illegal operations, program/erase failures,
reset and power interruption are tested. Raw flash is not yet a block drive, SSD
or PMEM capability.

### ST-017 — Add media-appropriate ECC, MBIST and fault reporting

**Owner / files:** **proposed** first-party ECC/BIST control, media error paths,
CSR/RAS telemetry and test bindings. **Depends:** ST-006 and ST-014 plus the
corresponding ST-015 or ST-016 media slice.

Select protection strength from real device requirements. Define data+ECC atomic
updates for narrow writes, correction/scrub policy, uncorrectable error/poison and
maintenance ownership. Preserve MBIST/scan/testmode access and keep destructive
BIST away from live allocations. Transport CRC is not media ECC.

**Done when:** injected faults cover correctable/uncorrectable classes, metadata,
partial writes and scrub/BIST conflicts; errors propagate to the real requester
and health counters. Qualification remains per media/profile, not blanket immunity.

### ST-018 — Implement a durable transport-neutral block backend

**Owner / files:** **proposed** `g6lc_storamic/rtl/media/` block/media-management and
`g6lc_storamic/rtl/persistence/` mapping/journal control; versioned block contract.
**Depends:** ST-016, ST-017.

Two ordered slices with different prerequisites. **ST-018A** defines the
transport-neutral block contract — bounded read/write/flush/FUA/error
operations, stable per-stick identity, sector/offset units and error taxonomy —
plus a clearly labeled volatile verification binding. ST-018A depends on
ST-005/ST-007 and does not inherit the parent's physical ST-016/ST-017 gates;
model paths may depend on ST-018A alone. **ST-018B** depends on ST-018A plus
those physical gates; it adds the durable physical implementation and
interrupted recovery: persistent identity, reserved metadata/recovery space and,
for NAND, bad-block management, ECC integration, wear leveling, garbage
collection, crash-consistent mapping and exhaustion handling. Physical writable
promotion requires ST-018B; a bounded NOR prototype must be labeled and cannot
stand in for NAND qualification.

**Done when:** power cuts at metadata/data/commit boundaries, repeated recovery,
full journals, bad blocks, wear/space exhaustion and reset preserve the declared
durability/atomicity contract. Acknowledged durable data is recoverable; capacity
never double-counts PMEM backup or recovery space. This durable gate governs the
parent task; ST-018A alone does not close it.

### ST-019 — Add the published Storamic contract to g6lc_qemu

**Owner / files:** exclusively `g6lc_qemu/` pins, `g6q-svcfg`, `g6q-core`,
`g6q-ingest`, schemas, fixtures and existing package tools.
**Depends:** ST-005; further fields only after their owning contract freezes.

Consume published enable/profile/geometry/capability names by a deliberate pin.
Add reader, IR, schema, conformance and name-set tests together. Missing values
remain unresolved. Reject unsupported selected profiles instead of silently
providing generic RAM. Preserve package independence and text-out-only GPL emission.

**Done when:** present/absent/unknown fixtures pass package `check`, no design
constant is invented in an emitter, and reference versus RTL-backed modes are
visibly different. Existing owner queue: `g6lc_qemu/architecture/RTL_FEEDBACK.md` §6.

### ST-020 — Select and qualify the VirtIO-MMIO block profile

**Owner / files:** `g6lc_storamic/architecture/virtio-mmio.md` and
`host-interfaces.md`; all QEMU stock reference profiles and runs under
`g6lc_qemu/`. **Depends:** none for the architectural choice; consumed artifacts are handled by ST-019. **State:** ADR resolved; detailed implementation profile in ST-033 and empirical software qualification in ST-038 remain pending.

The transport is decided: modern VirtIO-MMIO pinned to VIRTIO 1.4 CS01 with
`Version` = 2 and a first split-ring virtio-blk subset, per the linked decision
with its sources and tradeoffs. The detailed negotiated bit/register
implementation profile belongs to ST-033; empirical stock-software qualification
is ST-038's gate after the block implementation exists. virtio-PCI is a
different transport and is not implied.

**Done when:** the recorded ADR selects the transport, cites its sources and
tradeoffs, and lists the capability gates that still apply.

### ST-021 — Implement the VirtIO-MMIO block frontend

**Owner / files:** **proposed** `g6lc_storamic/rtl/host/` VirtIO-MMIO frontend, native
control/DMA/IRQ glue and its protocol benches. **Depends:** ST-010, ST-018A,
ST-020, ST-034, ST-035, ST-036; physical writable drives additionally need
ST-018B and the ST-015/ST-016 media gates.

Implement the pinned profile's negotiation, queues/descriptors, DMA bounds,
completion ordering, interrupts, reset, identity and durability — IN/OUT/GET_ID
and the specified FLUSH/cache-mode semantics; do not invent a virtio-blk FUA
opcode. Expose one drive per flash-bearing stick. Keep the block backend neutral
and enforce native/external address ownership and DMA permissions.

**Done when:** malformed queues/pointers, full queues, reset races, duplicate/stale
completion and FLUSH failures are checked independently. Advertise only tested
features; no filesystem/RAID implementation or shared writable cross-host image.

### ST-022 — Emit an actual RTL-in-the-loop bridge through g6lc_qemu

**Owner / files:** `g6lc_qemu/` emitters/tools and **proposed** simulator-side peer
under `verif/tb/storamic/`. **Depends:** ST-019 and the tested path (ST-011 for
native controls/data, ST-021 for block, optionally ST-039/ST-040 for
virtio-mem/pmem device behavior).

Version the transport and forward accesses at a declared cut into RTL, including
required MMIO/configuration plus descriptor, data and status DMA, IRQ and reset
events. Tag transaction/reset identity and bound outstanding work. Host RAM
backing the tested aperture must not bypass the controller — no shadow-memory
substitution for ring, payload or status traffic. Reuse existing package/proxy
lifecycle support.

**Done when:** a deliberate RTL fault changes the observed guest outcome, all
operations have correlated completion/error records, and disconnect/reset cannot
replay a write or accept stale results. This does not prove physical timing or
native cache coherence.

### ST-023 — Qualify stock-Linux block behavior and software aggregation

**Owner / files:** tests/payloads under verification; QEMU profiles/launch under
`g6lc_qemu/`; native SoC map/config documentation.
**Depends:** ST-021; RTL-backed QEMU evidence needs ST-022; native boot needs
ST-012; physical claims need ST-015/ST-016 and applicable ST-031 gates.

Use the unmodified selected Linux driver for enumeration, capacity, stable identity,
read/write/flush/reset and fault recovery. Exercise multiple flash-bearing sticks
and normal md/LVM or supported multi-device filesystem aggregation in software.
Keep RAM-only slots absent from block enumeration and recovery capacity hidden.

**Done when:** guest IO is correlated to the declared RTL/media path, data survives
qualified fault cuts, drive identity survives permitted relocation/reboot, and
software-only, native-model and physical results remain separately labeled.

## Persistence and active links

### ST-024 — Freeze the persistence domain and worst-case protection budget

**Owner / files:** persistence architecture, selected board power/hold-up design
and media contract. **Depends:** ST-014, ST-018.

Specify a fully resident RAM window and every protected queue/data/metadata state.
Derive admission limits from maximum dirty bytes and guaranteed backup throughput,
power, voltage, aging and temperature. Define cache clean/fence, AXI completion,
block FLUSH/cache-mode and virtio-pmem flush relationships — these are distinct
acknowledgment boundaries. CPU caches are not implicitly
protected. Reserve backup/recovery capacity and define degraded-protection refusal.

**Done when:** independently reviewable worst-case energy/time bounds and fault
assumptions exist; model throughput is not used as guaranteed physical bandwidth.
Do not advertise persistence based on typical save times or a checksum alone.

### ST-025 — Implement protected save/restore and interrupted recovery

**Owner / files:** **proposed** `g6lc_storamic/rtl/persistence/` journal/checkpoint/recovery
engines and health/admission controls. **Depends:** ST-008, ST-009, ST-017,
ST-018, ST-024.

Commit data and metadata generations in a defined order, retain the last valid
checkpoint, and recover with persistent module identity and mapping generation.
Drain all relevant interfaces explicitly. Refuse new durability promises when
protection is degraded; do not silently turn PMEM into volatile memory.

**Done when:** repeated power loss during save, restore and recovery, torn records,
full journals, bad blocks, resets and degraded energy satisfy the declared contract.
Recovery never exposes ambiguous generations or aliases block backup space.

### ST-026 — Qualify Linux PMEM, LIBNVDIMM and DAX behavior

**Owner / files:** native firmware/DTS integration and stock-Linux tests; all QEMU
firmware/discovery generation and launches under `g6lc_qemu/`.
**Depends:** ST-025, ST-012, ST-019; virtio-pmem additionally needs ST-040.

Expose only qualified protected ranges through supported native or virtio-pmem
discovery. Test LIBNVDIMM, Device DAX and Filesystem DAX with actual ordering and
crash recovery semantics — Device DAX and filesystem DAX are separate
compatibility gates. DAX is an access mechanism, not proof of durability or
application transaction atomicity, and never a generic durability claim.

**Done when:** cache-to-protected-domain flush/fence behavior and interrupted
recovery are proven at the declared boundary; volatile RAM, PMEM and block
capacity remain disjoint and accurately advertised.

### ST-027 — Freeze a separately keyed active-stick protocol

**Owner / files:** link/discovery architecture and **proposed** first-party link
contract package. **Depends:** ST-005, ST-013, ST-014.

Specify framing, CRC, credits, transaction/reset epochs, response reservation,
replay limits, timeout/error semantics and management. Set local stick controller
ownership and physical SerDes/clock boundaries. Use measured latency-bandwidth
requirements to size buffers; passive connector similarity is not qualification.

**Done when:** both endpoint contracts and negative/replay scenarios are complete;
a reset/retry cannot duplicate a committed operation. Pin geometry and electrical
keying stay elaboration/board properties, not runtime reallocations.

### ST-028 — Implement and qualify active carrier/stick endpoints

**Owner / files:** **proposed** `g6lc_storamic/rtl/link/` first-party endpoints and stick-side
composition of existing media engines; target SerDes bindings.
**Depends:** ST-006, ST-017, ST-027 and the selected ST-015/ST-016 media engines.

Reuse media and discovery contracts rather than duplicating controllers. Implement
credit/replay state, CDC/reset handling, errors and diagnostic counters; bind the
physical link separately. Reserve progress for responses and maintenance.

**Done when:** corruption, loss, replay, reconnect, asymmetric reset and saturated
traffic are tested; physical link training/BER/SI and measured service claims use
separate evidence. No automatic live hotplug or new persistence guarantee.

### ST-029 — Retired PCIe foundation target

Retired by the VirtIO-MMIO architecture decision. The former PCIe/CXL transport
work is not an active Storamic prerequisite. Replacement implementation is
ST-033..ST-041. Independent LibreCore PCIe users are unaffected.

### ST-030 — Retired CXL Type-3 target

Retired by the VirtIO-MMIO architecture decision. The former PCIe/CXL transport
work is not an active Storamic prerequisite. Replacement implementation is
ST-033..ST-041. Independent LibreCore PCIe users are unaffected.

### ST-031 — Close physical integration and capability release per profile

**Owner / files:** qualified `corev_apu`/`corev-mb` bindings, constraints, technology
artifacts, source/licensing closure, software manifests and capability grants.
**Depends:** the complete task/evidence chain for the selected released profile,
not every optional feature in this backlog.

Close target synthesis, STA/IO timing, CDC/reset, SRAM/macro mapping, scan/MBIST,
power/hold-up and SI/PI/connector requirements. Check configured slot/package
variants, default-off identity, and the required isolated aggregate regression.
Include FPGA/ASIC distinctions and any physically unavailable gates explicitly.

**Done when:** each advertised capability has an implementation, configuration,
software view, fault test, exact evidence identity and applicable physical result.
Unresolved black boxes/assumptions cannot count as qualified digital behavior;
qualified technology macros retain their actual views and boundaries. No model
or generic-cell area result becomes a fabricated-process or transport compliance claim.

### ST-032 — Re-evaluate after every milestone and create the next child tasks

**Owner / files:** this backlog, normative architecture, root traceability/todo,
and owner-specific queues such as `g6lc_qemu/AGENTS-todo.md`.
**Depends:** each milestone's captured results; repeats rather than waiting until M6.

Compare delivered behavior with the profile ledger and dependencies. Record
actual blockers, source/configuration/tool drift and remaining uncertainty. Split
the next epic into bounded child tasks with exact interfaces/files and independent
oracles before implementing it. Update this record rather than maintaining
competing task lists. Reuse frozen evidence for analysis; rerun only when a relevant
input changed or a required gate has not been executed.

**Done for each checkpoint when:** completed tasks cite their artifacts and limits,
failed/incomplete tasks stay open, the next small implementation batch is chosen,
and any new architecture decision is explicit. A roadmap checkbox is never evidence
that media, Linux durability, physical timing or transport compliance exists.
The current reassessed transport plan is ST-033..ST-041 below; the retired
ST-029/ST-030 epics are not prerequisites. The ten items in
`general-purpose-review.md` map onto existing owners — capacity/config
(ST-003/ST-033), payload/native (ST-011/ST-037), media (ST-018), queues/service
(ST-041), verification (ST-001/ST-032) and the VirtIO follow-ups — rather than
duplicating ten new epics.

## Modern VirtIO-MMIO transport and host tasks

These tasks are planned, not completed. They follow the settled
[VirtIO-MMIO decision](virtio-mmio.md): VIRTIO 1.4 CS01, modern `Version` = 2,
per-device MMIO apertures, split-ring DMA and native AXI RAM. No MMIO address,
IRQ, feature bit or boot support is granted by their presence.

### ST-033 — Pin the modern VirtIO-MMIO profile and role/config contract

**Owner / files:** `g6lc_storamic/architecture/virtio-mmio.md` normative contract;
**proposed** `core/` and `corev_apu` config projections plus the package-consumed
ABI. **Depends:** ST-005, ST-020.

Pin the 1.4 CS01 feature-negotiation set, modern `Version` = 2 transport, the
primary/peripheral role legality (proposed `StoramicIoEn`), aperture/IRQ
ownership, ring and resource limits, the DMA/protection/cache contract and reset
scope. Every mandatory/optional bit gets an implementation owner and tests;
unimplemented bits stay off. Invent no platform addresses or device IDs.

**Done when:** the profile and role contract is recorded, each negotiated bit
maps to an implementation owner plus negative tests, and the actual config
schema/default-off propagation is tested before any field is accepted.

### ST-034 — Implement modern MMIO transport state

**Owner / files:** **proposed** `g6lc_storamic/rtl/host/virtio/` register module and
its protocol benches. **Depends:** ST-033.

Implement AW/W-independent AXI-Lite register service, the feature/status
sequence (reset, ACKNOWLEDGE, DRIVER, FEATURES_OK, queue setup, DRIVER_OK),
feature selector banks, queue geometry/64-bit address registers, ConfigGeneration,
interrupt status/ACK races and reset quiescence. A register-only leaf advertises
no DMA and no usable device.

**Done when:** normative register/negative/reset tests pass with synthesis and
bounded safety evidence; inconsistent feature negotiation cannot start work and
reset cannot leak stale completions into reused queue state.

### ST-035 — Implement split-ring execution and bounded AXI DMA

**Owner / files:** **proposed** first-party ring and DMA modules under
`g6lc_storamic/rtl/host/virtio/`. **Depends:** ST-006, ST-010, ST-033, ST-034.

First profile: one queue, one request in flight, queue maximum 128, split
virtqueues. Descriptor tables and buffers live in external shared RAM through
the explicit memory seam — never truncated into local SRAM. Enforce chain
bounds/cycle detection, direction/length/address-range validation including
full-width overflow, reserved completion/status storage before side effects, and
payload/status/used/IRQ ordering with reset epochs.

**Done when:** an independent DMA/byte oracle plus malicious descriptors, stalls,
index wrap and reset tests show zero unsafe memory accesses, with synthesis and
bounded safety/formal evidence. Unimplemented optional ring features stay off.

### ST-036 — Bind the virtio-blk request engine

**Owner / files:** **proposed** first-party block frontend/backend and model under
`g6lc_storamic/rtl/host/virtio/` and media path. **Depends:** ST-007, ST-018A,
ST-020, ST-035.

512-byte sector units for capacity and request offsets; IN, OUT, GET_ID and the
qualified FLUSH/cache-mode contract; stable per-stick identity across allowed
relocation; specified IOERR/UNSUPP status without capacity aliasing. The model
binds to ST-018A's volatile verification contract — physical flash need not
exist yet — while a labeled model media stays distinguished from qualified
physical media promoted only through ST-018B.

**Done when:** byte/block oracle, geometry/overflow/error/flush cuts and
one-drive-per-flash-stick evidence pass. No invented FUA opcode and no hardware
filesystem or automatic RAID.

### ST-037 — Integrate native MMIO, DMA, IRQ and role selection

**Owner / files:** `corev_apu/storamic/` attachment plus SoC map/config/DTS
projection. **Depends:** ST-011, ST-012, ST-034, ST-035; the full block path
additionally needs ST-036.

Wire the MMIO transport, DMA master, interrupts, configuration projection and
reset-domain integration natively. The proposed `StoramicIoEn` peripheral role
must not relax `StoramicEn` primary-memory conflicts; one shared controller owns
the slots when both roles are enabled. Establish a coherent DMA path or a proven
DMA-API/cache-maintenance path and enforce the DMA domain — no `dma-coherent`
DTS on an unproven path.

**Done when:** full native data movement, IRQ/reset/config propagation and
default-off preservation are shown; no fake DTS device or capacity is emitted.

### ST-038 — Qualify stock Linux and package-owned RTL block bridge

**Owner / files:** `g6lc_qemu/` exclusively for generation/launch/reference;
`verif/` simulator-side peer. **Depends:** ST-019, ST-022, ST-023, ST-036, ST-037.

Use stock `virtio_mmio`/`virtio_blk` for enumeration, IO, FLUSH, configuration
changes and multi-drive software aggregation against the RTL bridge. A deliberate
injected RTL fault must change the guest result. Record exact kernel/QEMU/SBI/
profile/bridge identities per run.

**Done when:** guest results correlate to the declared RTL/media path with
fault-cut evidence; model and reference results stay distinctly labeled and never
establish physical media or coherence.

### ST-039 — Implement optional virtio-mem lifecycle

**Owner / files:** **proposed** region lifecycle manager under
`g6lc_storamic/rtl/host/virtio/` plus native integration. **Depends:** ST-008,
ST-009, ST-012, ST-033, ST-035, ST-037.

Reserved address windows only, with actual RAM backing and ordinary RAM
semantics. Implement PLUG/UNPLUG/UNPLUG_ALL/STATE over the control queue with
page/block alignment and OS offline cooperation. No duplicate boot-RAM
publication, no live remap or forced shrink; a device control reset is distinct
from system reset and must not destroy live RAM. `g6lc_qemu/` owns any missing
MMIO memory-device proxy for the pinned QEMU.

**Done when:** source-pinned kernel/platform support plus failed/offline/
pinned-page/removal tests pass — not merely a `requested_size` register.

### ST-040 — Implement optional virtio-pmem persistence interface

**Owner / files:** **proposed** virtio-pmem device under
`g6lc_storamic/rtl/host/virtio/` plus persistence integration. **Depends:**
ST-024, ST-025, ST-033, ST-035, ST-037.

Expose a genuinely byte-addressable mapped range and an asynchronous flush queue;
completion must mean preceding writes reached the declared persistence domain
across reset and power failure. No raw-NAND-as-RAM fiction. Separately qualify
LIBNVDIMM, filesystem DAX and Device DAX against the kernel and transport. The
missing QEMU MMIO memory-device support is an explicit `g6lc_qemu/`-owned gap.

**Done when:** power/reset recovery and flush cuts plus software mappings are
proven at the declared boundaries; DAX alone establishes none of them.

### ST-041 — Scale queues, channels and measured service

**Owner / files:** queue/channel resource design plus measured evidence.
**Depends:** ST-013, ST-036, ST-037; Linux results additionally need ST-038.

Separate `MaxMediaChannels`/channel allocation from
`MaxQueuesPerDrive`/`QueueSizeMax`/in-flight/DMA-credit controls. Add fairness,
completion-progress guarantees, capacity-grow notifications via
ConfigGeneration, no live remap and no initial online shrink.

**Done when:** same-workload bytes/latency/occupancy/errors/fairness evidence
plus synthesis/resource and applicable physical results exist; queue count is
never reported as a bandwidth claim.

## Common completion rule and development efficiency

Every RTL task carries config legality/default-off checks, first-party dependency
closure and licensing/attribution, synthesizability/timing/CDC notes, bounded
ownership/reset/error tests, testmode/DFT hooks, observable events/counters and
software/map alignment where applicable. Keep first-party portable digital RTL
separate from physical macros and from verification-only behavioral models.

Use the smallest faithful leaf first, then its native integration seam, then stock
software and physical gates. Reuse the existing benches/runner and add a shared
model bench rather than a file per test case. Keep independent reference models
and mechanism-specific negative controls; a scoreboard must not simply copy the
RTL routing implementation. Expand burst/width/slot/fault coverage at the stage
where the behavior first exists. Do not defer all verification until integration.

Parallelize disjoint work after contracts freeze: baseline fixes versus contract
writing; physical profile research versus model RTL; QEMU reference/ADR work versus
media engines. Serialize edits to shared packages/top/flists and budget all remote
workers against available resources. Cache only with complete dependency identity;
reuse binaries for runtime-only cases, never across changed elaboration geometry.
Avoid broad cleanup-prone regressions on each edit, but execute required aggregate
gates in isolated snapshots before milestone promotion. Preserve failed evidence
and collect existing jobs instead of retrying or launching duplicates.

## Evaluation of the original plan

The original layering and M0 refusal-first choice remain sound. The next useful
increment is a real one-region model through a complete adapter, not transport
registers or successful responses backed by a shadow host buffer. Preserve the skeleton
regression as a separate profile while growing the executable path.

Four refinements are required: split request-service readiness from media readiness;
make native preload/atomic/DMA ownership a concrete gate; strengthen runtime and
dependency identity; and decide the block transport early — now resolved by the
VirtIO-MMIO decision rather than a PCIe dependency.
The model and physical SRAM seams must be explicit so M1 does not become a silent
production fallback. Map/discovery/control contracts must precede Linux-facing
capacity publication. Persistence and the host transport remain independent
advertised capability gates, not consequences of having RAM plus flash or an
MMIO aperture.

M0 is not retrospectively marked fully qualified: the five configuration
failures, the timing-tool type error and selected ST-001..ST-004 gates now have
current evidence, but the interrupted aggregate run remains open. ST-029/ST-030
are retired by the VirtIO-MMIO decision rather than decomposed.
ST-032 is the mechanism for creating further tasks from measured outcomes rather
than pretending today can fix every future queue size, register or PHY detail.
Sequence exhaustion in the model profile is intentionally fail-safe; before
long-running native RAM, ST-009/ST-012 must define and prove quiescent sequence
renewal — stop admission, drain contexts and binding, advance the reset
generation, then reuse sequence space without clearing RAM. Widening or silently
wrapping the counter is not the lifecycle protocol.
