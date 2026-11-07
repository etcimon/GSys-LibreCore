# GSys LibreCore Storamic Checkpoint Model

This is a portable model implementation, not a physical persistence or Linux
PMEM qualification. The native protected profile remains disabled.

## Ownership and Data

`g6lc_storamic_checkpoint_ctrl` pauses producers, seals/drains ingress and
coordinates preparation, publication, abort and explicitly synchronized restore.
`g6lc_storamic_checkpoint_media` owns alternating reserved-flash images and
identity/map/image-bound records. `g6lc_storamic_checkpoint_io` retains offered
commands and checks complete RAM transaction identities.

Records occupy fixed logical offsets at the end of raw flash. Publication
durably invalidates the destination marker before reusing its bank, copies and
checksums the frozen image, flushes the body, then writes and flushes the final
nonzero marker. Recovery flushes retained staging before scanning records;
otherwise an owner-only reset could mistake read-your-writes for durability.

`ExternalFlashCheckpoint` prepares RAM by draining and freezing, without the
two local shadow SRAM banks. Legacy shadow mode remains the default. Actual
backup and restore use the reserved media, not retained selector registers.
`g6lc_storamic_store_guard` bounds untrusted word traffic independently of
VirtIO descriptor validation. Only the trusted maintenance owner bypasses it.

## Timing and Backend Review

- CRC advances two bits per cycle; budget 32 cycles per 64-bit word for each
  pass, plus command/response, flush and worst-case program/replay delays.
  Restore verifies first, then copies and checks again.
- The guard registers its command and capacity and splits its word-index
  comparison into 32/29-bit stages. No overflowing `addr + 8` is required.
- There are no new clocks, asynchronous-reset conventions or gated clocks.
  Plain control registers remain scan-insertable. Phase, refusal, stale-tag,
  degraded and completion/error signals provide integration observability.
- Existing SRAMs use `tc_sram`. Generic synthesis reports 563 media cells,
  76 I/O cells and 52 guard cells, with 1,823/366/268 register bits respectively,
  no latches and no combinational SCCs. These are unmapped control estimates,
  not gate area, SRAM area, power, DFT insertion or 5 GHz timing closure.
- New definitions do not activate a native feature. Native integration must
  add its optional `CVA6Cfg` field and legality checks, preserve minimal targets,
  connect PMU/debug events and qualify the actual reset/coherence domains.
  No ISA, CSR, device-tree or Linux capability is added by these leaves.

The flash model provides a logical durable word-store contract. Fixed record
offsets are not a raw-NOR erase layout: physical adapters still need qualified
erase-block isolation, program ordering/atomicity, ECC, wear and bad-block
handling. Never erase one record's physical block over the last valid image.

## Evidence

Local immutable snapshot `storamic-489af3c88a3e` passes 17 directed profiles
and 17 rejecting simulation oracles:

| Leaf | Response delays | Positive checks |
| --- | --- | --- |
| Codec | n/a | 659 |
| User-port guard | n/a | 54 |
| Reserved media | 0/1/4/16 | 336 each |
| RAM | 0/1/4/16 | 139 each |
| Durable store | 0/1/4/16 | 85/91/97/121 |
| Coordinator | 0/4/16 | 115 each |

Full-width combinational codec/layout properties and a rejecting oracle pass
with SMTBMC/Yices. An independent coordinator leaf passes depth-16 safety,
save/restore/error reachability at 20/32/12 and its rejecting oracle; generic
controller synthesis has 328 cells, no latches and no SCCs.

The I/O helper's full-input depth-12 safety and rejecting oracle pass with a
shortened 2-bit lease model and arbitrary complete return tags. Depth-24 safety
times out under SAT and SMT and remains unresolved; the shorter receipt does
not replace it. No full media-FSM, whole-SoC, compliance, gate-level, physical or
Linux qualification follows from these results.

Receipts live under
`build-platform/workspace/build/storamic-checkpoint-record-01/`. They identify
local tools/sources and explicitly set `qualification=false`. Aggregate
`verify --dry-run` only plans 25 steps; it executes none.

## Next Integration Boundary

Legal native configuration must reserve both images, records and recovery
spares, export only remaining complete sectors, and bind the word-port guard.
It must reject insufficient capacity, unsupported bus/backend geometry,
missing enabled-writer acknowledgements and an inadequate service deadline.
The ordinary 64 KiB RAM/64 KiB flash model cannot fit two protected RAM images.

Recovery requires genuine all-writer/ingress exclusivity. Port ownership must
distinguish waiting for permission from holding accepted work. Bindings must
retain response ownership through abort/reset and provide real cache,
reservation and device-state synchronization before resume. A magic key is
not authorization; unqualified acknowledgements cannot be tied high.

Protection/energy admission, physical faults and Linux PMEM remain separate
gates. This is resident-window backup, not block-sector rollback, transparent
oversubscription or whole-SoC hibernation.

## Composed Model Binding

`corev_apu/storamic/g6lc_storamic_checkpoint_model.sv` now composes the real
controller, reserved-media owner, freeze-only RAM and user-capacity guard.
It requires external ingress/writer acknowledgements and explicit resume
synchronization; it does not fabricate them. RAM/flash response routing uses
owners captured at grant, and flush routing retains its requester until
completion. Restore errors propagate to the coordinator. The control input
is a trusted service seam, not a new authorized MMIO ABI.

`checkpoint-model` adds actual AXI/frontend-to-backend integration tests.
The final immutable snapshot `storamic-8e7f649ed1eb` passes 85 checks at response
delays 0/4/16 and all three rejecting oracles. Coverage includes delayed writer
pause, backpressured responses, guarded user capacity, real record publication,
explicit resume, common-peer reset and rediscovery, interrupted replacement,
missing-writer timeout and foreign/matching mapping transitions. Reset clears
the live model RAM; restore must therefore use flash, not a retained selector
or local shadow image. Ordinary block sectors are not rolled back.

`checkpoint-model-synth` passes independently with 1,360 generic cells, four
model memories, no latches and no SCCs. The SRAM models are not mapped physical
macros or a chip-area result. The binding adds command muxes and registered
response/flush ownership on the same clock; physical timing and DFT insertion
remain open. Synthesis also exposed forward variable declarations in the
existing durable store; declaration ordering is fixed without changing logic.

Native `CVA6Cfg` activation, real writer/coherence/privilege providers and
physical protection remain pending. Merely listing this uninstantiated model
in `Flist.storamic_soc` does not enable a protected native profile.
