# Executable-model interface decision

This is the implementation design for ST-005/ST-006/ST-007. The standalone
component (ST-007A) and the typed top profile slice now exist with scoped leaf
evidence (`storamic-7eea26e38385`, `storamic-3c25eee4aaa3`); native model
exposure and aggregate gates remain open as recorded in the task backlog.

## Profile and geometry

Contract revision 2 uses one `profile_t` enumeration: `ProfileOff`,
`ProfileRefuse`, `ProfileModel`. The old `Skeleton` boolean is replaced in the
standalone configuration rather than adding an independently selectable model
boolean. Keep the named `StoramicOff` and `StoramicSkeleton` configurations.
`Enable` remains the projection of the sole native `StoramicEn` flag; a disabled
native projection selects `ProfileOff`. Unknown or contradictory selections fail.
Standalone instances select their own `Cfg` constants instead.

Reviewed limits: burst/extent arithmetic uses 65-bit intermediate values and
elastic per-beat registers; generic synthesis is a structural check, not target
STA. The top glue adds no state, clock or array; asynchronous active-low reset
and `testmode_i` propagation are preserved. Physical macro and DFT integration
stay target-owned, and there is no ISA/DTS/host-model grant. Bound model
readiness is distinct from physical readiness and from sequence exhaustion;
quiescent sequence renewal is required before any long-running native use, as
ST-032 records.

The model configuration adds `ModelBase` and `ModelBytes`, both 64-bit byte
quantities. The first model is one region and one slot, initially at
`0x80000000` with a 64-KiB default size. Bench fixtures may select smaller sizes.
Base and size must align to the data-bus word, size must be nonzero, and the
65-bit exclusive upper bound must not exceed 2^64. Exactly 2^64 is a valid
exclusive upper bound. No high address truncation is allowed. A model profile
with more than one slot remains unsupported until ST-008.

The frontend supports power-of-two data widths from 8 through 1024 bits and
1..16-bit AXI IDs in the initial model profile. Native addresses must fit the
64-bit standalone address contract. Unsupported widths fail explicitly.
Physical `ImplementedMediaCaps` remains zero. Modeled RAM readiness is distinct
from physical media readiness and all pad outputs remain safe.

The native host configuration must not accept `profile: "model"` until its
selected-backend binding exists. No missing physical binding falls back to the
model. The first implementation may be qualified as a standalone model before
native model attachment and boot are qualified.

## Memory boundary

Portable RTL exposes a scalar memory command/completion seam. It contains no
behavioral RAM array. A first-party SRAM model belongs under
`verif/tb/storamic/`; a real SRAM binding belongs at the technology boundary.
The verification model is excluded from production/standalone RTL file lists.

The seam carries:

- `mem_ready_i`: the binding is initialized and can eventually service commands.
- `mem_req_o`, `mem_gnt_i`: command valid/acceptance.
- `mem_we_o`, `mem_addr_o`, `mem_wdata_o`, `mem_be_o`: operation, 64-bit
  word-aligned byte offset within the region, data and byte enables.
- `mem_tag_o`: command identity.
- `mem_rvalid_i`, `mem_rdata_i`, `mem_error_i`, `mem_tag_i`: completion.

There is at most one accepted memory command awaiting a completion. Every
accepted read **and write** returns exactly one completion, at least one clock
after acceptance. No completion backpressure is needed because the frontend
reserves its destination before issuing the command. Command fields remain
stable until acceptance. A macro wrapper generates write completion and echoes
identity even if the physical macro has no such pins.

Use a first-party packed `txn_id_t` with `reset_generation[31:0]`,
`seq[31:0]`, `axi_id[15:0]`, `source[7:0]`, and `beat[7:0]`.
`source_i` and `reset_generation_i` are explicit frontend inputs. Sequence
identifies each dispatched memory command, with the original AXI ID and beat
also retained. Reserve LEN+1 sequence values for a valid request at admission,
AW before AR if both arrive together; unused values are not recycled. Refuse a
request if its entire reservation does not fit. A 33-bit allocation cursor can
represent exhaustion of the 32-bit sequence space without wrapping. Already
reserved work can finish. A small sequence-width parameter, bounded by 32,
permits a directed exhaustion test.

Only a matching completion for the current command may affect AXI state.
Unexpected or stale completions are discarded and reported. An asynchronous
binding that can retain responses across reset must supply a new reset
generation before new traffic. A synchronous binding sharing the entire
frontend reset must discard all old completion metadata. RAM contents need not
be cleared by a controller reset. This model protocol does not implement
active-link replay or claim exactly-once behavior across power loss.

## AXI behavior

One read burst and one write burst may be accepted independently. AW acceptance
does not depend on WVALID. Read responses, B responses and any stalled command
are held stable. Response IDs and original burst shape are preserved.

Support AXI4 FIXED, INCR and WRAP according to their encoding rules:

- Transfer size cannot exceed the data bus.
- FIXED accepts at most 16 beats; INCR accepts 1..256.
- WRAP accepts 2/4/8/16 beats and requires transfer-size-aligned start addresses.
- A request crossing an AXI 4-KiB boundary is invalid; it is not legalized by
  internal splitting.
- Exclusive requests are refused by this standalone profile. Native atomics and
  reservations remain above the attachment and require their own qualification.
  ATOP is not part of the standalone AXI4 contract.

Compute the entire addressed byte extent using widened arithmetic at AW/AR
acceptance. Validate geometry, burst encoding and region permissions before any
memory command. Invalid requests return SLVERR with no memory side effects.
Writes still consume their declared LEN+1 beats; rejected reads retain LEN+1
responses and RLAST. Absent/unready memory at admission causes refusal, even if
the binding subsequently becomes ready.

For an unaligned INCR start, the first beat covers bytes from the requested
address through the end of its size-aligned transfer; subsequent addresses
advance from that aligned transfer boundary. FIXED repeats its address/mask.
WRAP traverses its aligned wrap window with the original starting beat first.
Read data outside the active byte lanes is zero. Legal WSTRB selects a subset
of those lanes; a zero strobe is a legal no-op.

Per-beat malformed WSTRB/WLAST and runtime media faults set a sticky write error,
suppress that beat and further unsafe commands, and drain the remaining declared
data. Earlier completed beats can remain visible: AXI error completion is not a
whole-burst rollback guarantee. Missing write beats violate the master contract;
there is no invented timeout that silently resynchronizes malformed traffic.

The model region permits reads, writes and instruction fetches; it is not an
additional security boundary. CACHE/PROT/QOS/REGION remain legal AXI attributes
without additional policy in this single-region model. AWUSER and ARUSER are
opaque response cookies returned on BUSER and RUSER respectively. WUSER must be
zero; stored per-byte user metadata is not implemented. Native configurations
requiring stored AXI user data cannot use this model binding.

There is no implicit ordering between independent read and write channels.
Software or a test requiring read-after-write visibility waits for B completion
before submitting AR. Concurrent accesses use the memory-command arbitration
order. A binding that fails during a held or accepted command must complete it
with an error or participate in reset; changing readiness alone does not cancel
a valid command. Physical removal and replacement remain ST-009 work.

## Bounded implementation

Use separate read/write contexts, a one-beat read response register, a one-beat
write holding register, a B response register, and one shared memory-command
state machine. These are bounded elastic registers, not a large flop-backed
payload array. Write holding state is retained until its completion so another
write beat cannot overwrite it.

The command state machine has idle, waiting-for-grant and waiting-for-completion
states. Capture the selected command once; arbitration cannot rewrite a stalled
offer. Alternate read/write priority when both need the memory port. Stalled
read responses do not block unrelated write work, and a stalled B response does
not block reads. Error-only responses need no memory command.

A read context advances after its R handshake. A write context advances after
its accepted data beat and retains that beat's address/mask while it waits for
memory completion. The final write completion produces B. No read success or
write success is fabricated when the binding is absent.

Publish basic acceptance/completion/error events with this implementation.
Counter semantics must distinguish AXI acceptance, successful memory completion
and upstream response retirement. Counter values do not establish physical
bandwidth. Width conversion and larger outstanding windows remain later work.

## Verification and integration gates

Use an independent byte-address oracle with initialized fixture data. Cover
partial/narrow/unaligned transfers, all supported burst forms, 4-KiB and region
ends, address overflow, invalid encodings, missing media, zero strobes, response
backpressure, simultaneous read/write, reset, stale identities, sequence exhaustion
and injected memory errors. Retain the existing off/refusal matrix and the
joined-path old-readiness negative control.

The memory model checks its own full offset bounds before indexing an array.
It supports delayed grant/completion and fault injection for the bench. Its
data initialization is an explicit simulation fixture, not fabricated hardware
initialization. Formal assertions cover stability, bounded state/credit use,
identity matching and refusal side effects; assumptions about eventual acceptance
or completion must be stated.

The native attachment must carry complete address/data/strobe/attribute payloads
and the memory boundary before enabling its model profile. Initial native data
tests precede CPU boot. Existing ELF loaders address legacy hierarchies; they
must be replaced or explicitly refused for Storamic rather than preload a shadow
buffer. All writers must participate in the native reservation/coherence policy
before shared CPU/DMA model use is qualified.

AXI-Lite remains an explicit refusal interface until the ST-010 register contract,
address/IRQ allocation and cross-interface drain semantics are frozen and tested.
No control write implicitly orders the independent AXI data path. QEMU consumers
remain exclusively under `g6lc_qemu/` and may ingest only published, implemented
fields through an explicit contract pin.
