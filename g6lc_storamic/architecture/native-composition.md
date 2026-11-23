# Native Checkpoint Composition (C3–C6): Design Of Record

Status: design settled 2026-11-13; implementation in progress. Native admission
stays refused (`STORAMIC_CHECKPOINT_NATIVE_BINDING_REQUIRED`) for every build
that does not bind **all** of the owners below.

## 1. Bounded profile

One hart, one core, in-order, WT cache (with or without L2/L3 and L2/L3
prefetchers; W1), no AI/APU, no `ServerPrefetchEn`,
`g6lc_storamic_origin_supported` true, harness define `G6LC_STORAMIC_CKPT`
(implies `G6LC_STORAMIC`, `G6LC_STORAMIC_MODEL`, `StoramicCheckpointEn`). Main
memory **is** the checkpointed model RAM. RAM size is reduced for simulation
(`G6LC_STORAMIC_CKPT_WORDS`, default 2**15 words = 256 KiB) because save and
restore are word-serial and `TimeoutCycles >= words*32+64`.

## 2. Structure

```
cluster ─ axi_gate(cpu) ─┐
debug   ─ axi_gate(dbg) ─┼─ xbar ─ DRAM port ─ lrsc ─ dram_backend ─ attach ─ native_ckpt
virtio DMA (port 2) ─────┘        └ Storamic window ─ checkpoint_route ─ ctrl page ─┘
```

- `g6lc_storamic_native_ckpt` (new, `corev_apu/storamic/`): instantiated by
  `g6lc_storamic_attach` when `CheckpointRequested && NativeBound`. Contains
  `g6lc_storamic_checkpoint_policy` (NumIngress=3, NumProviders=5) and
  `g6lc_storamic_checkpoint_endpoint` (NumProducers=3). The endpoint block
  store port (`st_*`) is tied idle: the harness VirtIO device keeps its own
  model-stick store and is bound here only as a RAM **writer**.
- Platform facts cross the backend/attach hierarchy as two packed structs in
  `g6lc_storamic_soc_cfg_pkg`: `ckpt_plat_in_t` (harness → composition) and
  `ckpt_plat_out_t` (composition → harness). No loose signal bundles.
- `g6lc_storamic_attach` keeps the fatal when `CheckpointRequested &&
  !NativeBound`. `NativeBound` is a parameter set only by the harness branch
  that wires every field of `ckpt_plat_in_t` from a real owner.
- `g6lc_storamic_native_providers` (new, `corev_apu/storamic/`): the C3 owner
  (section 4).

Producer/ingress index order (fixed): `0` CPU, `1` debug master, `2` VirtIO
writer (jobs + DMA + control seal).

## 3. C4: writer pause/drain owners

Pause request to all upstream writers:
`pause_req = !initialized || busy || policy_quiesce || boot_recovery_hold`.
It is **not** raised by `recovery_locked` alone: a run-time lock seals the RAM
(`axi_quiesce` stalls AW/AR at the ingress) and leaves the hart free for
platform fault handling. A lock found at boot on a valid checkpoint is owned by
the boot recovery agent (section 6.1), which holds the pause until the restore
has completed.

| Writer | Pause | Drain acknowledgement | Error |
|---|---|---|---|
| CPU (port 0) | `g6lc_storamic_cpu_pause` → `cluster.storamic_pause_i`, `g6lc_storamic_axi_gate` on the cluster AXI | sequencer `paused_o` (core drained and gate closed) | sequencer `error_o` |
| Debug master (port 1) | `g6lc_storamic_axi_gate` close | gate `closed_o` | gate overflow |
| VirtIO (port 2 DMA) | `virtio_dev.quiesce_i`, `ctrl_quiesce_i` | `quiesced_o && ctrl_quiesced_o` | `quiesce_error_o` |

Holds into the policy (`ingress_hold`): CPU gate `inflight_o`; debug gate
`inflight_o`; `virtio.inflight_o || dma_axi.inflight_o`. `route_hold` is the
route's `policy_hold_o`.

The command that starts a checkpoint is itself a CPU store: the service must
return its B response before the CPU can drain. The sequencer then halts the
core, closes the gate and reports paused; the endpoint proceeds only when all
three producers are paused and the ingress is sealed.

## 4. C3: platform-owned descriptor, identity and policy

`g6lc_storamic_native_providers` owns, from hardware state only:

- **Descriptor/identity**: `g6lc_storamic_discovery` slot FSM reading the
  stick descriptor over its descriptor bus from a stick-side responder
  (`g6lc_storamic_model_desc`, the model stick's descriptor ROM: identity, RAM
  bytes, flash bytes). The descriptor is captured once per Ready entry and is
  immutable until the slot leaves Ready.
- `module_id[159:0] = {identity[31:0], ram_bytes[63:0], flash_bytes[63:0]}`
  from the captured descriptor.
- `mapping_generation`: increments on every entry to Ready.
- `reset_generation`: increments on every `ndmreset`; reset only by
  power-on reset.
- `providers_ready[4:0]` (order fixed by the endpoint comment):
  - `[0]` transaction policy: origin profile supported and no CPU-pause or
    gate error latched.
  - `[1]` persistent identity: slot Ready with a captured descriptor.
  - `[2]` qualified protection: discovery `persist_ready` and power good.
  - `[3]` descriptor binding: captured RAM bytes equal `ModelBytes` and
    captured flash bytes cover `RawFlashBytes`.
  - `[4]` resume synchronization: resync-capable core profile, reservation
    clear wired, no pause error.
- `present`, `identity_valid`, `protection_ok`: live versions of the above.
- **Policy**: one policy update per mapping generation
  (`policy = mapping_generation`), issued after all providers are ready and
  held until `update_ready`. Loss of presence, identity or protection stops
  re-issue; the policy module revokes on its own rules.
- **Authorization**: `aw_authorized`/`ar_authorized`/`service_enable` come from
  `g6lc_storamic_checkpoint_route` (`Enable=1` only in this profile), fed
  `policy_ready`/`policy_epoch` from the composition. Only machine-mode CPU
  data accesses with the interconnect-inserted port-0 prefix are candidates.

Sim-only triggers for adversarial tests (bench page, like the existing
`+0x3000` set): presence drop, power-good drop, descriptor swap on next
discovery, power cut.

## 5. C5: resume synchronization

- Core: resync-on-release (`cpu-pause-provider.md`): every release from a
  storamic halt flushes D$ and I$ and refetches from the commit head.
- Reservation: `g6lc_axi_lrsc` gains a clear input; all reservations are
  cleared while the CPU is reported paused (a spurious SC failure is legal).
- `restore_resume_safe = cpu_paused && dbg_gate_closed && virtio_quiesced &&
  reservation_cleared_since_pause && !any_error`. Never a constant.

## 6. Boot and preload

After reset the endpoint is uninitialized: pause is requested, the boot power
cut clears the RAM, metadata is recovered, then the endpoint initializes
(unlocked when no checkpoint exists). The bench ELF preload therefore happens
when the model reports boot-memory ready (after the clear, before the CPU is
released), not at time 0. This is a bench loader detail, not a provider.

### 6.1 Cold recovery (C6b): boot recovery agent

After a power loss the endpoint comes out of reset locked on its published
checkpoint, and `g6lc_storamic_checkpoint_ctrl` accepts a `RESTORE` on a locked
endpoint only while every producer is already paused. The hart therefore
cannot issue it (a ROM stub would be refused with `CP_RECOVERY_REQUIRED`), and
without an owner the hart would be released into sealed RAM.

`g6lc_storamic_boot_recovery` (in `g6lc_storamic_native_ckpt`, parameter
`BootRecovery`, attach parameter `CkptBootRecovery`, default on) is that owner:

- Once per reset: wait for `initialized`; if `recovery_locked && checkpoint_valid`
  hold `pause_req`, otherwise retire.
- When every producer reports paused without error and the control service is
  usable (policy ready, command admitted, all provider facts), it becomes the
  only master of the endpoint's ordinary control port and writes `RESTORE`,
  polls `STATUS` for the result, reads the result code and writes `CONSUME`.
  The endpoint, its command checks and `restore_resume_safe` are unchanged;
  the agent's packets are authorized by construction (platform-owned), and the
  platform-side control port is held off while it owns the port.
- Any refused packet or non-OK result is terminal: `recovery_failed` stays set
  and the pause is held. No producer runs on RAM that was not restored.
- A lock taken at run time (power cut, withdrawal, swap) is never recovered
  automatically; that would silently roll back live state.

The hart then boots normally from the ROM into the restored image. Software
sees `ST_CP_VALID` at entry and no pending result.

## 7. Verification (`native-ckpt` remote stage)

Firmware `verif/tests/custom/storamic/storamic_ckpt.c`, bare metal, M-mode:
status check → pattern A in cacheable data and a patchable code word → `SAVE`
→ mutate to B and read B back (caches warm) → `LR` → `RESTORE` → data and code
must be A without any explicit flush, `SC` must fail, generation and result
codes checked. Post-`RESTORE` code must not depend on stack or global state
written after `SAVE` (the image rolls it back); command issue/poll runs from
registers only.

Evidence (`native-ckpt`, all on the remote testharness): positive flow at
RAM/flash response delays 0 and 2; negative firmware oracle (expects B, must
fail with its code); provider negatives (presence drop, power-good drop: sealed
and locked, never a fabricated result); hot swap to a different identity
(discovery re-qualifies it, mapping generation 2, endpoint stays locked); debug
SBA command to the control page refused at the route; cold recovery and its
negative oracle; a VirtIO job in flight across `SAVE`. Mutants, each killed by its named symptom:

| Mutant | Change | Symptom |
|---|---|---|
| n1 | `NativeBound` off | composition absent from the hierarchy |
| n2 | no D-cache resync | data not restored (16) |
| n3 | no I-cache resync | code not restored (17) |
| n4 | no reservation clear | SC succeeds (18) |
| n5 | CPU `paused` tied high | `STORAMIC_CKPT_VIOLATION` |
| n6 | provider facts and module identity synthetic | SAVE completes on a withdrawn stick (22) |
| n7 | no boot recovery agent | locked on a valid checkpoint after the power cycle, hart never runs |
| n8 | VirtIO `paused` tied high | `STORAMIC_CKPT_VIOLATION` with a job in flight |

VirtIO writer in flight (`storamic_ckpt_vio.c`, case `virtio-inflight`): a
virtio-blk OUT is notified and `SAVE` issued right behind it. The pause request
must find the writer busy (`vio_busy_pauses >= 1` in `STORAMIC_CKPT_STATE`),
the job retires exactly once before the RAM is sealed (one used-ring entry
after `SAVE` and in the restored image), and after `RESTORE` the driver
re-initializes the device, whose state is not part of the image, and reads the
block back.
`native-c2`, `native-c2-wide` and the default (non-checkpoint) harness are
unchanged.

## 8. Changes outside the Storamic folders (hyp8 ledger)

`corev_apu/tb/ariane_testharness.sv` (gates, sequencer, providers, struct
wiring, route enable), `corev_apu/src/g6lc_ai_dram_backend.sv` (struct
pass-through), `corev_apu/src/g6lc_axi_lrsc.sv` / `g6lc_axi_atomics_wrap.sv`
(clear input), `corev_apu/tb/g6lc_tb.cpp` (deferred preload path).
