# General-purpose Storamic review: ten caveats and selected improvements

Status: source-grounded design review, 2026-11-03. This extends the
[VirtIO-MMIO decision](virtio-mmio.md), rather than introducing another host
transport. The standalone owner is `g6lc_storamic/`; native attachment belongs
to `corev_apu/storamic/`. There is no new parallel `storamic/` implementation.

The objective is capacity, flexibility, performance, stability and scalability
through reusable first-party logic and explicit contracts. “IP-free” is not a
substantiated legal property of a microarchitecture. First-party authorship,
open specifications, patent-policy coverage, copyright licenses and technology
macro rights are separate questions. Keep public-source provenance and the
existing license boundaries; do not claim patent clearance or hide a digital
controller inside a PHY exemption. Native inherited infrastructure remains
outside the zero-third-party standalone RTL boundary.

The review below contains exactly ten conceptual caveats. Proposed configuration
names are design vocabulary, not accepted RTL/host fields or capability grants.

## 1. Enabling a controller conflates roles unless configuration is normalized

**Observed:** `core/include/config_pkg.sv` carries `StoramicEn`; native
`g6lc_storamic_soc_cfg_pkg.sv` separately projects skeleton and maximum-stick
defines. `g6lc_storamic_cfg_pkg.sv` accepts off/skeleton only and grants zero
implemented media capabilities. The backend selects Storamic at the primary
DRAM aperture.

**Caveat:** a single primary-memory enable cannot also express a flash-only
peripheral beside independent boot RAM. Adding independent model, RAM, flash,
PMEM and host booleans would create contradictory combinations and duplicate
controller ownership.

**Decision:** retain `StoramicEn` primary-backend exclusivity. Use the already
proposed `StoramicIoEn` for the independent peripheral role, normalized with the
primary role into one controller/slot owner. Replace the standalone skeleton
boolean with the planned typed off/refuse/model profile when ST-005/ST-007
integration is ready; keep media and host capability grants separate.

**Configuration and gate:** core-visible choices propagate through CVA6Cfg,
build_config, every retained target package, host validation and native
projection. Board geometry remains a board/package choice. Runtime capability
registers are derived from implemented and validated resources; software cannot
grant a feature by writing its requested bit. Check the full role/profile
legality matrix, including default-off identity, before accepting new fields.
Owners: ST-005, ST-011, ST-033, ST-037.

## 2. More installed capacity does not imply a larger safe address aperture

**Observed:** the executable frontend validates one 64-bit base/size region;
the native AI join's `addr_in_dram` uses a fixed aperture and a
`(len + 1) << size` footprint. CPU cacheability/executable/non-idempotent rules
are separate CVA6Cfg arrays. Maximum sticks are structural, not discovered RAM.

**Caveat:** summing chip labels can overcount recovery/FTL space, exceed physical
address limits or create aliases. A simple INCR-style footprint is not a
general FIXED/WRAP validator. Equal-size channel striping cannot silently absorb
heterogeneous sticks or change while pages are live.

**Decision:** validate immutable region records containing base, usable size,
media kind, owner/domain, attributes and generation. Check complete extents
with overflow-safe arithmetic, overlap, native physical-address limits, burst
semantics, and consistency with PMA/firmware before publication. Start with
non-interleaved extents; add compatible interleaving only at an explicit
quiescent reconfiguration boundary. RAM, block capacity and PMEM recovery space
must be disjoint.

**Configuration and gate:** proposed `MaxRegions`, per-region size limits and
interleave policy are independent of `MaxSticks` and `MaxMediaChannels`.
Validate upper-address, overflow, hole, mixed-size and boundary-crossing cases;
prove removal cannot compact live memory. Virtio-mem windows must not also
appear as ordinary boot RAM. Owners: ST-008, ST-009, ST-033, ST-039.

## 3. A response-correct refusal adapter is not a payload-complete memory adapter

**Observed:** the native adapter initially transported only IDs, lengths and
handshakes. The standalone memory model needs addresses, write data, byte
strobes and attributes. Its contract excludes ATOP and refuses exclusives.
The optional AI join forces island LOCK/ATOP to zero.

**Caveat:** dropping metadata can turn a future functional attachment into
silent address/data corruption. Carrying an ATOP bit is not implementing its
read/write responses; stripping it is not a general atomic-refusal policy.
Source-ID prefixing and width conversion also must not truncate ownership.

**Selected immediate improvement:** make the native request representation
payload-complete, preserve its address/data/user widths and all native AXI
attributes, and check its shape against the actual interface. Keep M0 refusal
behavior and all capability grants unchanged. Native tests compare the request
at the adapter boundary against the full bus using nonzero payload patterns.
This is ST-011A, not functional native RAM qualification.

**Configuration and gate:** derive interface geometry from the existing native
parameters. Do not add a feature switch for basic wire correctness. A future
functional profile must explicitly terminate/reject unsupported atomics before
the standalone AXI4 seam and test both required response channels. No
`AtomicEn` or exclusive-support grant is accepted without ST-004B/ST-012
evidence. Owners: ST-004B, ST-007, ST-011.

## 4. Shared addresses and invalidation flags do not establish shared ownership

**Observed:** in `ariane_testharness.sv`, the exclusive/atomic wrapper precedes
the optional `g6lc_ai_dram_join`. Wide island traffic enters that later join;
the narrow APU/AI route uses the crossbar through `g6lc_apu_tdma`. APU DMA
engines check mapping records. `AiCfg.DmaInvalEn` is a separate optional grant.

**Caveat:** the wide ingress bypasses the upstream exclusive monitor's normal
transaction path. This topology alone does not prove that an AI write
invalidates a CPU reservation or that dirty/stale CPU cache lines are handled.
An APU mapping check or CPU PMP does not constitute a system-wide DMA firewall.

**Decision:** publish a per-ingress ownership matrix: source-ID construction,
allowed regions and permissions, cache-maintenance/coherence path, reservation
invalidation, reset domain and completion boundary. All writers of shared
ordinary RAM must participate in the required visibility/reservation mechanism;
otherwise allocate exclusively owned regions and enforce handoff/drain rules.
Keep compute integration at existing CVXIF/AXI/APU boundaries; no Storamic
instruction or pipeline bypass is needed.

**Configuration and gate:** a proposed DMA-domain/coherence policy selects a
proven integration, never turns coherence on by assertion. Prove dirty-CPU-line
DMA reads, DMA-write/CPU-read visibility, instruction visibility where allowed,
LR/SC across writes from each ingress, denied extents and source-ID collision
cases. Keep `dma-coherent`, shared-memory atomics and unrestricted device DMA
unadvertised until these pass. Owners: ST-004B, ST-011, ST-012, ST-037.

## 5. More channels and queues can increase contention without improving service

**Observed:** the model has one read context, one write context and one memory
command in flight. The AI join gives cluster address requests priority; the
APU testharness join favors APU admission and holds ownership while work is
outstanding. Width converters do not increase upstream byte bandwidth.

**Caveat:** an AXI QoS field, larger queue or wider bus is not a fairness or
latency guarantee. Priority admission can starve a competing source under
sustained traffic. Extra outstanding requests can exhaust completion storage
or worsen head-of-line blocking.

**Decision:** retain the simple model as a correctness reference. Scale queue
contexts and media channels independently, reserve response/maintenance credits,
and use explicit bounded admission classes at the actual contention points.
Measure CPU tail latency, AI sustained throughput and APU service deadlines
together. Do not infer workload performance from peak width times clock.

**Configuration and gate:** proposed `MaxMediaChannels`, `MaxQueuesPerDrive`,
`MaxInFlightPerQueue`, `DmaCredits` and scheduling policy require implemented
storage and measured bounds. Initial VirtIO remains one split queue/request
with proposed maximum 128 entries. Saturation tests must cover all enabled
sources, backpressure and maintenance; a zero-grant peer is not a bounded
latency environment. Owners: ST-013, ST-035, ST-041.

## 6. Epoch tags detect stale completions but do not cancel physical side effects

**Observed:** the memory seam carries reset generation, sequence, AXI ID, source
and beat identity; commands remain stable until grant and complete no earlier
than the following clock. Sequence exhaustion and stale responses are explicit.
The verification SRAM shares reset with the frontend.

**Caveat:** a real memory/flash operation can survive a frontend reset.
Ignoring its late completion does not undo its write. Reusing a mapping or
slot before old operations drain can corrupt a replacement resource. A timeout
does not prove whether a write committed.

**Decision:** separate frontend/device reset, queue reset, media reset and system
reset. Stop admission, drain or obtain an explicit cancellation/quarantine
result, preserve uncertain-write status, then advance the ownership generation.
Never recycle live context solely because a timer expired. Virtual memory
control reset must not unplug live RAM.

**Configuration and gate:** proposed command/drain watchdogs are diagnostics or
fault transitions with specified semantics, not fake successful completions.
Generation/sequence widths and reuse rules are ABI properties. Test reset
before grant, after grant, after media side effect, during response stall and
at unplug/replacement; include independently resetting peers. Owners: ST-006,
ST-009, ST-010, ST-035, ST-039.

## 7. Flash capacity, RAM caching and persistence need separate accounting

**Observed:** physical media capabilities are zero. The architecture already
separates volatile RAM, logical block storage and protected mapped memory.
ST-018A's volatile binding is distinct from ST-018B's durable physical backend.

**Caveat:** a RAM cache can acknowledge data before flash persistence; raw NAND
needs erase/bad-block/ECC/mapping management and reserved space. Neither an AXI B
response nor DAX access establishes a persistence domain. Link CRC does not
replace media ECC.

**Decision:** use transport-neutral block operations and stable per-stick
identity; expose usable sectors after reserves. Keep FLUSH ordering across
queues, recovery metadata and cache-to-domain fences explicit. Do not invent
a virtio-blk FUA opcode. Virtio-pmem requires genuinely byte-addressable mapped
backing plus a proven asynchronous flush/recovery path.

**Configuration and gate:** proposed media kind, read-only mode, cache policy,
ECC profile and protected-domain selection are typed, mutually checked policies.
Durability cannot be a user-set capability override. Require power-cut,
exhaustion, bad-block, partial-update and repeated-recovery evidence before
physical writable or PMEM promotion. Owners: ST-016..ST-018, ST-024..ST-026,
ST-036, ST-040.

## 8. Digital modularity does not supply physical detection, timing or power safety

**Observed:** the current top exposes safe pad outputs only; the pad package
defines output-enable/data/control signals, not a complete input/discovery
binding. The executable frontend exposes an external memory seam; behavioral
bytes live in verification. M0 has no trained media or live insertion path.

**Caveat:** runtime capacity cannot change fabricated balls, voltage domains or
clock resources. Floating data pins are not reliable presence detection.
Choosing an open digital controller does not qualify chip timing, bidirectional
turnaround, signal integrity, hold-up power or technology licensing.

**Decision:** retain explicit pads/input sampling, clock/reset, SRAM, DFT and
physical-media boundaries. Add presence/debounce/power sequencing and bus
turnaround only for a selected board/chip contract. Keep arrays behind macro
seams, bounded placement regions and observable reset/clock-gating behavior.
Use public datasheets with provenance; do not label an unreviewed memory
protocol or PHY patent-free.

**Configuration and gate:** structural `MaxSticks`, data widths, channel
allocation and physical profile are elaboration/package properties. Runtime
presence and health remain validated state. Require board-specific electrical,
CDC/reset, STA, MBIST/scan and applicable power/SI evidence. Owners: ST-006,
ST-009, ST-014..ST-017, ST-027..ST-031 (excluding retired ST-029/ST-030).

## 9. Aggregate counters can conceal unavailable or failed service

**Observed:** the Storamic backend branch drives channel beat counters to zero;
the native adapter ties off controls and does not expose health. The executable
model already separates admission, refusal, memory completion bytes and response
retirement through `model_events_t`.

**Caveat:** zero can mean idle, unavailable, unimplemented or failed. Accepted
AXI bytes are not completed media bytes, and a completed volatile write is not
a durable write. Summing queues can hide source starvation.

**Decision:** define availability/validity alongside counters and preserve
per-source/channel attribution. Keep service-ready, media-ready, degraded,
faulted and quiescing states distinct. Specify counter width/wrap or saturation,
atomic snapshots, first-fault context and software clearing semantics.
Connect telemetry through the existing control/PMU/debug boundaries rather than
inventing CPU ISA encodings.

**Configuration and gate:** proposed counter presence/width and snapshot
controls must not affect transaction correctness. Test accounting under errors,
partial strobes, backpressure, reset and simultaneous sources. Performance
reports name the path, workload, clock and source/tool identity; no bandwidth
claim is inferred from QEMU or generic-cell area. Owners: ST-010, ST-013,
ST-033, ST-041.

## 10. Tool identity alone does not prove the intended test executed

**Observed:** the frozen model initially failed at the concurrent-write check.
The generated Verilator 5.008 code expanded two direct timed task calls into
82 fork siblings, so the response assertion executed at the fork's starting
timestamp. Explicit named begin/end branches restored sequential execution
inside each concurrent branch. Run `storamic-969942d0eec0` passed five positive
model profiles, five illegal-configuration cases and the negative byte oracle.
The production frontend was unchanged by that correction.

**Caveat:** a simulator exit code or a compiled trace string is not proof of
handshakes, coverage, native integration or physical behavior. A reference
emulator can also bypass the RTL being evaluated.

**Selected immediate improvement:** retain the independent byte oracle and
named fork branches; add explicit concurrent AW/W/AR/R/B and memory-command
accounting plus an elapsed-time guard. Make diagnostic traces opt-in and
flushed. Strengthen the existing native fixture with full-payload preservation
checks rather than creating another test framework.

**Configuration and gate:** keep source/runtime/compiler identities and
negative controls. Extend synthesis/formal coverage to the executable frontend
before declaring ST-007 complete; existing M0 synthesis/formal results do not
cover it. All QEMU generation/launch/reference/bridge work remains exclusively
under `g6lc_qemu/`, with actual MMIO/DMA/IRQ/reset forwarding for RTL tests.
Owners: ST-001, ST-005..ST-007, ST-011A, ST-019, ST-022, ST-032, ST-038.

## Configuration policy and implementation sequence

Prefer a small normalized configuration over dozens of freely combinable flags:
role, execution profile, geometry/resource limits, validated region/domain
records, selected media policy and derived capabilities. Existing defaults stay
off. Each new accepted field needs one authority, validation, native projection,
host/schema propagation, a test matrix and an advertisement rule. Candidate
names above must not leak into firmware or QEMU as invented defaults.

The immediate code batch addresses caveats 3 and 10: payload preservation and
interface-shape checks in the native adapter, plus stronger existing fixtures.
It adds no clock, stateful datapath, media array, runtime capacity, MMIO node,
IRQ, instruction or enabled device. Payload wiring should prune from the M0
refusal netlist; that is not a timing claim for a later functional profile.

Then finish executable-profile synthesis/formal and explicit selection, validate
mapping and source ownership, and build the pinned VirtIO transport in the
existing task order. Physical media, coherent sharing, persistence and scaling
remain separate evidence gates. ST-032 records each result and splits later
work from measured failures rather than expanding all proposed flags at once.

Review checklist for this slice: the native change remains behind `StoramicEn`;
the disabled backend hierarchy, clock/reset and testmode wiring are unchanged.
There is no new state, array, clock gate or power domain. Interface shape is
checked in simulation; the valid binding is separately synthesized. No new
PMU event, ISA encoding or DTS advertisement is needed for payload wiring.
RTL attribution and license headers are retained.

Evidence: `storamic-533be966b6d2` passed the model matrix and negative byte
oracle with explicit concurrent-traffic assertions. The subsequent
`storamic-c2d8ba58ad4b` passed all 14 native cases and both M0/native structural
synthesis checks after making the simulation guard portable. These are scoped
leaf results. Aggregate verification, executable-model synthesis/formal, full
CPU/DMA qualification and target timing/physical gates remain open.

## Follow-up (2026-11-03)

The ST-005/ST-007 standalone profile integration and its synthesis/formal
follow-up have since landed and passed as scoped leaf evidence:
`storamic-7eea26e38385` (model stage: 26 cases plus both corruption controls)
and `storamic-3c25eee4aaa3` (protocol/config/integration/synth/formal/
model-synth/model-formal). The ten caveats above were accurate for their
review date and remain the audit record; native model exposure, aggregate,
ownership and physical gates are unchanged and still open.
