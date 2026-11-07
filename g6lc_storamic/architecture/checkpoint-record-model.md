# Checkpoint Record Model Follow-On

This is the ST-025D model implementation boundary, not a frozen production
media ABI, physical protection claim, or user-block version map. ST-025C2's
controller requires a separate durable metadata participant.

The record codec/layout, owned word sequencer, reserved-media copy/recovery
engine and untrusted word-port guard now exist as separate first-party leaves.
The current source is under local validation; native activation remains off.

## Replace the fixture, not the qualification boundary

The C2 bench uses retained selector registers only as a participant fixture.
Replace them with records in the flash model's committed SRAM-backed media.
Reset must clear controller caches and rediscover records by reading media;
`journal_id_o`/`journal_gen_o` remain unrelated debug telemetry.

Actual protected-mode backup must copy data into the reserved flash extent.
Do not claim that the C1 checkpoint SRAM banks themselves are nonvolatile.
While C2 has sealed and drained AXI, a maintenance DMA can read the frozen live
RAM image through the existing `mem_*` seam and write the inactive backup bank.
In C1 external mode, allow prepared-image reads only under a trusted internal
maintenance-owner qualifier; host admission stays sealed, and prepared writes
remain forbidden. Retain tags/one-response ownership across the RAM mux.
`ExternalFlashCheckpoint` makes C1 preparation a drain/freeze operation and
elides both local shadow SRAM banks. It requires external commit ownership.
The legacy mode remains the default. A trusted owner's already-offered work
may drain while abort is asserted; new host traffic cannot use that qualifier.

For a fully flash-backed restore, route C2's restore request to the media copy
engine, not the C1 shadow-array restore. Read/validate backup CRC before exposure,
copy flash to live RAM through the same command seam, and verify the copied
stream again before done. C2 keeps a failed/partial restore locked. The old
backup image is never overwritten by restore.

## Candidate Model Record

Two slots, each eight 64-bit words, paired with two backup image banks:

| Word | Candidate content |
| --- | --- |
| 0 | Magic/version, e.g. `64'h47364c43504d3031` (`G6LCPM01`) |
| 1 | Stable module identity bits 63:0 |
| 2 | Stable module identity bits 127:64 |
| 3 | Mapping generation 32 bits, module identity bits 159:128 |
| 4 | Nonzero unsigned 64-bit checkpoint generation |
| 5 | Exact protected-image size in bytes |
| 6 | Image CRC32C, record CRC32C |
| 7 | Last-written commit marker bound to generation/checksums |

The slot/image bank equals generation bit zero. First generation is one;
generation zero is uncommitted. Exhaustion refuses save, never wraps. This
matches C1 preparing the inactive bank and C2 rejecting generation exhaustion.
The metadata owner must validate the requested new generation/bank and the
identity/map/image-size binding before touching media.
The marker has a fixed `8'hC5` prefix and a 56-bit generation/checksum binding.
It can never equal zero (the invalidation word) or the supported all-ones erase
pattern. An unrestricted XOR marker would permit zero for some valid inputs,
making a prepared body look committed before the final marker write.

CRC proposal: reflected CRC32C (`32'h82f63b78`), initial all ones, final
complement, least-significant bits/bytes first. Record CRC covers words 0..5
plus `{32'd0, image_crc}` (not its own field). A serial two-bit step avoids a
large combinational CRC cone; account for its real cycles in the backup budget.
CRC is integrity detection, not ECC, authentication, or physical qualification.

## Publication and Recovery

1. Invalidate the inactive slot's commit word and flush it before overwriting
   that bank's data.
2. Copy the frozen RAM image to its backup bank, compute its CRC and flush.
3. Write record body words 0..6, then flush.
4. Write the bound commit word last, then flush. Only now acknowledge publication
   and update the volatile selected-generation cache.
5. On reset, obtain exclusive all-writer ownership, flush/drain any retained
   staging, then scan both records and validate their backup data before selection.
   Choose the newest complete, valid image, retaining the older valid image if
   a replacement is torn or corrupt. A valid newer foreign identity/map must
   not silently trigger rollback into another configuration.

Every accepted RAM/flash command owns a completion, including abort/cut paths.
Do not withdraw an offered command or reuse the shared port before retirement.
Flush acknowledgement/error are paired; a held interrupted flush now retires
once with error and cannot become success after power returns.

After uncertain publication/cut, retire the control request with error, wait
for its level to drop, then rescan media before reporting metadata idle/ready.
A marker might have committed despite an error response; an old cached selector
must not let the next save reuse a generation or overwrite the wrong bank.
C2 already waits for metadata idle during cleanup and stays recovery-locked.

An owner-only reset need not reset the flash staging controller. A plain read
can therefore return a staged, not-yet-durable marker. Recovery flushes first
and never reports readiness after a failed recovery flush. It may roll forward
an unacknowledged but complete record only after this durability boundary.
`exclusive_i` must be a real ingress/all-writer acknowledgement, not a presence
flag. `media_owned_o` distinguishes waiting for that permission from owning the
physical command seam, so recovery cannot steal a port needed to drain writers.

Restore performs a verification pass before RAM writes, then a copy pass with
another complete CRC and terminal-write response check. Partial restore stays
locked. The word sequencer keeps stalled offers and matches complete RAM tags;
its finite namespace saturates rather than wrapping and only renews under an
increased authoritative reset generation. Common peer reset/cancellation is
still an explicit integration contract, not a claim about an unqualified PHY.

## Capacity and Integration

Reserve `2 * image_bytes + 2 * record_bytes`, rounded up to 512 bytes, at the top
of raw flash. Exposed virtio-blk capacity is the remaining full sectors, never
the raw chip size. Enforce the user-port bound independently of the block
descriptor checks; the maintenance owner alone may access reserved offsets.
Refuse protection on overflow, insufficient space or unsupported layout.
The record slots have fixed addresses at raw flash end minus 128/64 bytes;
the images start at the reserved extent's beginning. Changing image size or
spare reservation must not move the slots and hide a foreign-map record as
apparently blank media. Extra recovery reservation is independently budgeted.

Blank media must have a specified model/adapter erase pattern (zero for a
zero-initialized fixture, usually ones for physical flash). Nonblank invalid
records with no valid fallback are not silently treated as factory empty.
No automatic erase/format of a real device is authorized by this document.

The user-port guard captures each accepted command and its bound, checks word
indexes in two stages without an overflowing byte-address addition, and never
forwards rejected traffic. Disabling admission does not discard owned work.
It must be used alongside actual producer/job and flush ownership; word-port
idle alone does not acknowledge an entire VirtIO job.

These records back the selected resident RAM window. They do not roll back
ordinary block sectors, CPU caches, reservations or device queues, and do not
constitute whole-SoC hibernation. CRC is not authentication or ECC. Software
must not infer Linux PMEM/DAX readiness from these model primitives.

## Current Validation Boundary

`checkpoint-record` selects codec/guard positive and negative tests plus the
media copy/recovery bench at delays 0/1/4/16. `checkpoint-record-synth` selects
the media, word-sequencer and guard leaves. `checkpoint-record-formal` selects
combinational codec/layout checks and bounded word-sequencer safety/reachability
with a shortened finite namespace and rejecting oracles. It is not a full
formal proof of the backup FSM, native coherence, or physical retention.

The model bench has no retained selector fixture and, in flash-backed mode,
no local checkpoint SRAM. It covers torn data/body writes, cut-before-marker,
owner-only reset with retained staging, restore interruption, foreign identity,
map and image size, generation exhaustion, degraded refusal and CRC fallback.
Prepared manifests bind selected stages as well as sources; unknown, duplicate
or mismatched stages cannot be promoted to a successful empty leaf.

Native activation still requires legal optional configuration, privileged
control, a real acknowledgement for every writer, reset/coherence/reservation
synchronization, CDC bindings, and the ST-024/E protection budget. Real flash
program/erase/ECC and hold-up guarantees remain separate qualification gates.
