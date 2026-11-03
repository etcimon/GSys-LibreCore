# Media and persistence

Keep volatile RAM, protected PMEM and block capacity distinct. Flash capacity
behind a small RAM cache is not continuously accessible DDR-like memory.

## Media engines

SRAM: bank selection, byte-write merging, ECC and MBIST through physical macros.
HyperBus-style RAM: command encoding, burst/latency handling, DQ/RWDS turnaround,
clock stopping only where supported, and target-bound sampling delays.
DDR: bank/rank state, timing, refresh, initialization/training and a physical PHY.
Flash: page programming, erasure, device ECC/bad blocks and error status.

A usable NAND block device additionally requires wear leveling, mapping metadata,
garbage collection, reserved space and interrupted-update recovery. A raw command
bridge is not an SSD. NOR prototypes and high-capacity NAND have distinct profiles.
No first-party implementation may import a vendored media/controller feature.

## PMEM qualification

The initial proposed PMEM design is a fully resident RAM window backed by flash
save/restore, not transparent oversubscription. Declare the protected domain:
carrier/link queues, stick SRAM/RAM, flash buffers and all recovery metadata.
CPU caches are outside it unless explicitly protected and drained.

Persistent completion requires every covered preceding write to be recoverable
after external-power loss. Cache clean/fence completion, AXI B, virtio-pmem
flush acknowledgment and virtio-blk FLUSH must agree with that domain; they are
distinct acknowledgment boundaries. An AXI-Lite doorbell cannot
implicitly order a separate AXI data path.

Size hold-up energy for the maximum permitted dirty state, guaranteed backup
bandwidth, power, temperature, aging and conversion losses:

```text
save_time >= worst_case_dirty_bytes / guaranteed_backup_write_bandwidth
energy >= protected_power * save_time + control/recovery_margin
usable_capacitor_energy = C * (Vhigh^2 - Vlow^2) * efficiency / 2
```

Pre-erased backup space and continuous checkpointing reduce typical save work;
they do not excuse insufficient worst-case protection. Degraded protection must
prevent new persistence promises rather than silently downgrade them.

## Journal/recovery

Publish data and metadata before committing a generation. Retain the last valid
checkpoint until replacement is recoverable. Include checksums, sequence numbers,
mapping generation and persistent module identity. Test power loss during save,
during restore, again during recovery, at a full journal and with bad blocks.

Recovery space is excluded from exposed block capacity. ECC corrects a bounded
class of media errors; transport CRC and journals solve different problems.
Do not infer cache-line power-fail atomicity from a 64-byte transfer. Continuous
flash journaling has bounded buffering and eventually flash-limited durable write
bandwidth/endurance. Advertise only established atomicity and durability.
