# Heterogeneous region routing — next implementation slice

This is the ST-008 implementation design. It is not an implemented profile,
configuration flag, native memory grant or discovery ABI. Contract-v2 off,
refuse and single-region model behavior remains the delivered interface.

## Reuse the existing transaction owner

`g6lc_storamic_axi_memory` already owns one independent read and write context,
checks the original burst, reserves identities and emits one memory command per
data beat. Preserve that ownership. Routing should translate those commands to
their selected slot; creating another AXI frontend per slot would duplicate
burst accounting and complicate response ordering.

There are two distinct checks:

1. Validate the entire original addressed extent before issuing any command.
   A denied later region, hole or invalid slot must prevent earlier writes.
2. Translate each issued beat against the same immutable map and retain its
   slot, byte offset and transaction identity until completion.

FIXED checks its repeated beat extent, INCR its complete addressed span, and
WRAP its complete wrap window. Preserve the existing encoding, alignment and
4-KiB rules. Internal region crossings never legalize an AXI-illegal crossing.
Zero write strobes cannot bypass the address/permission check performed before
the write data is available.

The first mapped model keeps all slot memory ports at the frontend data width.
System region bases, lengths and backing offsets align to that bus word.
Consequently a region boundary falls between beats, including narrow transfers,
and translation preserves byte lanes without a width converter. This is a
model geometry rule, not a physical capacity or Linux page-size claim.

## Capacity and map validation

Separate normalized RAM accounting from system address placement. Slot metadata
must distinguish RAM bytes before reservation, reserved RAM bytes and usable RAM
bytes. Reject reservation underflow; never sum flash bytes into the RAM aperture.
These are synthetic fixture inputs until ST-009 validates actual discovery.

Use 65-bit intermediate values for each base-plus-length and offset-plus-length.
A system exclusive endpoint equal to 2^64 is valid; a larger endpoint is not.
Aggregate slot capacity needs at least `64 + ceil(log2(MaxSticks + 1))` bits.
Do not truncate installed/usable totals to a 64-bit software field. Published
mapped capacity and installed capacity are different quantities.

Require nonempty, ordered, non-overlapping system regions. Holes are permitted.
Each region names a bounded slot index, an expected slot identity, a backing
offset, a nonzero length and explicit read/write permissions. Check the index
before narrowing it to a port-select vector, including non-power-of-two slot
counts. A mapped region must fit the slot's usable RAM extent. Disjoint system
regions may not overlap backing bytes on the same slot: otherwise apparent
capacity would double-count aliases.

Present slot identities must be nonzero and unique in the model fixture.
Identity here identifies a mapping owner; it is not a fabricated vendor/device
identifier or a physical discovery protocol. Instructions are still read
transactions at this boundary. Region permissions do not replace native PMP,
PMA, cacheability, execute permission or DMA isolation.

The first table is fixed for the model's lifetime. ST-010 will own staged map
publication and its control contract. No live compaction, implicit replacement,
capacity growth or map mutation is granted by this slice.

## Scheduling, failure and timing

Register admission before scanning affected regions. A bounded sequential
validator avoids putting a chain of all region comparators on AXI READY.
AW and AR retain separate contexts; a write beat may wait in the existing
bounded buffer while validation proceeds. Arbitration must give both validation
contexts progress. No backend command is eligible until its validation succeeds.

Register the selected slot and translated command before offering it. A stalled
offer cannot be retargeted when another context becomes eligible. Only the
selected slot may supply grant/completion, and a completion must match the
existing source/reset-generation/sequence/beat identity. A matching tag on an
unselected slot is not a valid completion.

Read beats retire in the original burst order. One final B response still covers
the write transaction. Validation prevents known-invalid extents from receiving
any writes; it does not make a multi-slot write atomic against later media
failure. Earlier successful beats may remain visible after an error. A dropped
ready signal cannot cancel an offered or accepted command. Removal, replacement,
drain and sequence renewal remain ST-009 lifecycle work.

A committed map is not sufficient for readiness: the selected binding must be
available, and service readiness must still permit bounded refusal. Physical
pads and media readiness retain their existing safe behavior.

The intended hardware adds control state and address decode, not a RAM data
array, new clock or reset domain. Keep asynchronous active-low reset and
`testmode_i` propagation. Measure generic area and decode/admission latency
before adding concurrency; target STA, macro/DFT and floorplan qualification
remain separate. No DTS, ISA, interrupt or VirtIO interface is added here.

## Delivery and independent evidence

- ST-008A: normalized capacity/region types and bounded map validation. Cover
  reservation arithmetic, slot bounds and identities, sorted system ranges,
  backing alias rejection, top-of-address-space endpoints and wide totals.
- ST-008B: complete-burst admission plus per-beat slot routing through the
  existing frontend ownership model. Cover all supported burst forms,
  different permissions, holes, backpressure and wrong-slot completions.
- ST-008C: explicit standalone profile integration and 1/2/3/4/8-slot sweeps
  with unequal capacities, independent per-slot byte oracles, corruption
  controls, synthesis and bounded formal. Off/refuse/single-region behavior
  must retain its own evidence.

Freeze the actual typed interface and configuration version with implementation;
do not publish speculative fields to native host tooling or `g6lc_qemu`.
Native attachment, CPU/DMA ownership and boot still require ST-011B/ST-012.
