# Discovery and lifecycle — ST-009 implementation design

This design covers per-slot discovery, validation and lifecycle state. It does
not cover the physical descriptor bus, an electrical profile or a vendor
identity scheme. The descriptor format below is a **synthetic fixture format
(v1)**: it lets the digital state machine and its tests exist before ST-014
selects a real descriptor device. It is not a published ABI.

## Per-slot state machine

```text
ABSENT -> PRESENT -> POWER_CHECK -> POWER_WAIT -> IDENTIFY -> VALIDATE
       -> INITIALIZE -> READY -> QUIESCE -> QUIESCED -> (absent) ABSENT
any powered state + presence loss          -> FAULT (removed live)
strap/descriptor/init/timeouts failures    -> FAULT
FAULT --(presence absent and fault_clear)-> ABSENT
```

- **Presence.** `presence_i` is asynchronous. A first-party two-flop
  synchronizer (`g6lc_storamic_sync`) feeds a debounce counter. Presence
  changes only after `DebounceCycles` consecutive stable samples. This is the
  only new CDC path. The synchronizer is a dedicated module, so CDC review and
  constraints can find it. No other pad input reaches state without passing it.
- **Profile before power.** In `POWER_CHECK` the latched, synchronized
  `profile_strap_i` must equal the `SupportedProfile` parameter. On a mismatch
  the slot goes to `FAULT` (`FaultProfile`) and `power_en_o` is never asserted.
  An unknown voltage profile therefore never powers the slot or probes it.
- **Power.** `power_en_o` is high only from `POWER_WAIT` through `QUIESCE`.
  If `power_good_i` (synchronized) does not arrive within `PowerTimeout` cycles,
  the result is `FaultPowerTimeout` and power is removed.
- **Identify.** The slot reads the descriptor, read-only. There is no write
  port, so nothing can probe by writing. `desc_req_o`/`desc_addr_o` issue one
  word read at a time and wait for `desc_valid_i` (or `desc_error_i` →
  `FaultDescRead`), with a `DescTimeout` bound.
- **Validate.** See the rules below. A failure maps to a specific fault code.
  A matching checksum does not make descriptor data trusted: every field is
  still bounds-checked.
- **Initialize.** `init_req_o` is held until `init_done_i` or `init_error_i`
  (`FaultInit`), with an `InitTimeout` bound. This is the hook for media
  training (ST-015/ST-016). The model fixture acknowledges it.
- **Ready.** The slot publishes a `g6lc_storamic_region_pkg::slot_desc_t`
  (`present`, `identity`, `ram_bytes`, `reserved_bytes`) and separate
  `ram_ready_o`/`flash_ready_o`. `persist_ready_o` stays 0 because persistence
  is not implemented; the descriptor's persistence flag is reported only as a
  capability bit.
- **Quiesce.** `quiesce_req_i` moves `READY` to `QUIESCE`. The slot stays there
  until `drain_i` reports no outstanding traffic for this slot, then enters
  `QUIESCED`, where power is removed. Leaving requires presence loss. A live
  presence loss in any powered state is `FaultRemoved`; power drops at once and
  any published descriptor is withdrawn. The slot never re-enters `READY` on
  its own.
- **Fault** is sticky. It clears only when presence is absent and
  `fault_clear_i` is asserted, so a faulted stick must be removed first.

Initial insertion and removal are power-off only. `FaultRemoved` reports a
contract violation; it is not hot-plug support.

## Synthetic descriptor v1 (32-bit words)

| Word | Field |
| --- | --- |
| 0 | magic `0x5354_524D` ("STRM") |
| 1 | `[31:16]` version = 1, `[15:0]` length in words (`12`..`DescMaxWords`) |
| 2 | identity (nonzero) |
| 3 | flags: `[0]` RAM, `[1]` flash, `[2]` persistence-capable, `[11:8]` profile (must equal strap), rest zero |
| 4, 5 | RAM bytes, low and high |
| 6, 7 | RAM reserved bytes, low and high |
| 8, 9 | flash bytes, low and high |
| 10 | flash erase block bytes (power of two, or 0 when there is no flash) |
| 11 .. length-1 | reserved words, which must be zero; the last word is the checksum |

The checksum is chosen so the 32-bit wrapping sum of all `length` words is 0.

Validation, with faults reported in this order:

1. magic (`FaultMagic`);
2. version and length range (`FaultVersion`, `FaultLength`);
3. checksum (`FaultChecksum`);
4. zero identity (`FaultIdentity`);
5. no RAM or flash flag, unknown flag bits, or a profile that differs from the
   strap (`FaultFlags`);
6. capacity (`FaultCapacity`): RAM above `MaxRamBytes`, reserved above RAM,
   flash above `MaxFlashBytes`, a RAM flag with zero RAM bytes, or RAM bytes
   without the RAM flag; the same RAM/flag rules apply to flash;
7. flash geometry (`FaultGeometry`): a non-power-of-two erase block, or an
   erase block that is zero with flash present or nonzero without it;
8. nonzero reserved words (`FaultReserved`).

## Slot set

`g6lc_storamic_discovery_set` instantiates `Slots` slot machines. It also
registers a duplicate-identity check over the published `READY` identities.
Duplicates are reported through `dup_o` and both are withdrawn from
`slot_map_o`; neither slot faults, because identity ownership is a provisioning
policy. `slot_map_o` (`slot_map_t`) is the input that the ST-010 map commit
validates with `map_check`. Discovery never builds or changes an address map.

## Implementation constraints

- Async active-low reset; `testmode_i` passed to the synchronizer instances;
  no latches; no arrays; one registered state per slot plus counters.
- `Debounce`, `PowerTimeout`, `DescTimeout`, `InitTimeout`, `DescMaxWords`,
  `MaxRamBytes`, `MaxFlashBytes` and `SupportedProfile` are parameters, with
  legality checked at elaboration.
- Observability: state, fault code, sticky event pulses (`fault_event_o`,
  `ready_event_o`) for later counters/IRQ (ST-010).

## Delivery and evidence

- ST-009A: the slot machine, synchronizer and slot set, with a directed bench
  driven by synthetic descriptor fixtures:
  - empty, RAM-only, flash-only and mixed sticks;
  - an unknown profile, which must never assert power;
  - each validation fault;
  - power-good, descriptor and init timeouts, and a descriptor read error;
  - a debounce glitch;
  - live removal in every powered state, and clean quiesce/removal;
  - duplicate identities, and fault clear only while absent.
  The bench also has a negative oracle and checks synthesis for no latches or
  combinational loops.
- ST-009B: bounded formal safety:
  - `power_en_o` implies an accepted strap and stable presence;
  - `desc_req_o` implies `power_en_o`;
  - a published `present` slot implies `READY`;
  - a fault is sticky until it is cleared while absent.
  Covers: `READY`, `FaultChecksum`, a clean `QUIESCED`.

Native pad binding, real descriptor devices and electrical qualification stay
with ST-014; map publication and interrupts stay with ST-010.
