# Native External Semaphore Resource Binding

GSys LibreCore admits the Venus-native external semaphore mechanism —
`vkImportSemaphoreResourceMESA` / `vkWaitSemaphoreResourceMESA` — as
TRANSPORT-class wire commands. This is host-model evidence only: decoder
table admission plus both native transport models. It is not RTL pump
execution, stock-software, capset, CTS, physical or silicon qualification.

## Wire Admission

- `vn_command_set.txt` gains both commands; `gen_vn_tables.py`
  `act_class` classifies them TRANSPORT (the pump executes them, not
  vnfront). `g6lc_apu_vn_pkg.sv` regenerates additively — two new command
  type ids (245 wait, 246 import) and their decode-ROM entries; every
  pre-existing decode is bit-identical.
- `emit_handle` learned the transport HANDLE rule: TRANSPORT commands
  discard q slots (`_alloc` returns DISCARD), and a HANDLE op always
  stores into a q slot in the decoder — there is no discard encoding —
  so transport handle operands now emit a discarded U64 (same two-word
  consumption, no slot write, no HANDLE_ZERO check). This is the first
  transport command carrying standard Vulkan handle operands
  (`VkDevice`, `VkSemaphore`); earlier transport operands were MESA
  u64 scalars.

## Wire Layout

`VkImportSemaphoreResourceInfoMESA` serializes inline after the device
operand: presence u64, sType, the pNext chain (headers then bodies),
then the struct's own members — `semaphore` u64 and `resourceId` u32
always close the command because they follow the chain in wire order.
Both models read them from the tail (`u64(len-3)`, `words[-1]`) so a
non-empty pNext chain cannot shift the operands. `vkWaitSemaphoreResourceMESA`
is `device` u64 then `semaphore` u64 at fixed offsets.

## Bounded Semantics

A semaphore bound to `resourceId` tracks completion of work submitted
through the blob resource it names — the same completion domain the
ring commands already use.

- **Import** binds `semaphore -> resourceId`. The resource must resolve
  to a live mapped blob (`blob_of` / `BlobStore.mapping`); a null
  semaphore or unknown/unmapped resource is a fatal stream error. A
  re-import of a live handle rebinds it. The binding table is
  device-global transport state (`TransportModel.sem_res`,
  `RingStore.sem_res`); object lifecycle stays with the front end, so a
  binding outlives its VkSemaphore until process end — bounded and
  documented, not a leak the model pretends to collect.
- **Wait** requires a prior import (stale/never-imported token is
  fatal). It reports pending while any live ring created on the bound
  resource still holds unconsumed submissions (`tail > head`) or is
  fatal; once drained it succeeds. On the §6b pump path pending is a
  fatal return (the fixture never blocks); on the LinearExecution path
  pending raises `RingBlocked`, parking the stream task at the command
  — the same would-block contract `vkWaitRingSeqnoMESA` already uses.

## Verification

- Remote `native-semres-02` on `ovh_calltorch`: **714 checks PASS in
  18.2s**, `sources_unchanged: true`, cohort
  `native-execution.dddc4uyh` (+12 over the 702 `native-pipesub-01`
  cohort — exactly the new cases). `test_vn_semaphore_resource` was
  added to the `apu_native_verify.py` MODULES list so the cohort runs it.
- Local `test_vn_semaphore_resource`: 12 tests — import+wait success,
  wait-without-import, unknown/unmapped resource, null semaphore,
  pending/drained/fatal ring on the bound resource, ring on a different
  resource not blocking, and the LinearExecution park-then-complete
  path.
- Full local `test_vn_*` sweep: only the known Windows `socket.AF_UNIX`
  bridge failures (remote authoritative).

## Pump RTL design (queued increment)

Concrete mechanism derived from the `g6lc_apu_vnpump.sv` structure for the
next turn. All pieces reuse existing bounded machinery; nothing unbounded.

- **Ring resource id**: `ring_t` currently stores no resource id — add a
  `rid` field populated at `vkCreateRingMESA` from `t_rid_q` (already
  resolved through `StOtReq`/`StOtCpl`/`StOtDo` into
  `blob_base_w_q`/`blob_size_q`). `DestroyRing` clears `live` so dead
  rings drop out of the wait scan for free.
- **Semaphore binding table**: bounded `sem_tab[SEM_N]` of
  `{valid, handle[63:0], rid[31:0]}` (SEM_N ~8-16, matching ring/handle
  table scale). Import writes it; a live re-import rebinds; no eviction
  policy needed at this bound (import of a fresh handle when full faults).
- **`vkImportSemaphoreResourceMESA` (0xF6)**: stage the sem handle into
  `t_hnd_q` and the trailing `resourceId` into `t_rid_q`, route through
  the existing `StOtReq` ObjTab LOOKUP. `StOtCpl` `APU_OBJTAB_OK` already
  proves the resource is a live mapped blob (the native `blob_of` check);
  `StOtDo` 0xF6 then stores `{handle, rid}` in `sem_tab` and `StNext`.
  Null handle or ObjTab miss faults — mirrors native import refusal.
- **`vkWaitSemaphoreResourceMESA` (0xF5)**: no ObjTab needed. Resolve
  `t_hnd_q` through `sem_tab` → `rid`; unknown/stale handle faults.
  Evaluate `sem_pending(rid)` = any `ring_q[i].live && ring_q[i].rid==rid
  && (ring_q[i].fatal || ring head<tail pending)`. Clear → `StNext`.
  Pending → park like `StWaitR`: the same FSM must keep draining rings,
  so lift the stream into `park_q` with a new `is_sem` entry carrying the
  rid, restore on resume, re-run the wait state.
- **Park/resume extension**: `park_t` gains `is_sem` + `srid`; the
  `park_take` scan adds a third predicate — `is_sem` resumes when
  `!sem_pending(srid)` (bounded loop over `Rings`). `is_vq`/`wring` cases
  unchanged. On resume the saved `st_q`/`depth_q` restore and the wait
  state re-evaluates (satisfied → `StNext`, fatal ring seen meanwhile →
  `StFatal`).
- **Wire offsets**: confirm against `vn_golden.py::TransportModel.t_cmd`
  and the generated `g6lc_apu_vn_pkg.sv` decode — import reads sem from
  the tail u64 and `rid` as the last word; wait reads sem at record
  words 4-5. Map these onto `tbuf[depth_q][...]` indices exactly as the
  native model does (do not assume symmetric layout).
- **Directed tb** (`tb_g6lc_apu_vnpump.sv`): hand-encode 0xF5/0xF6 wire
  vectors beside the existing CRING* vectors; cover import-ok,
  import-null-handle, import-bad-rid (ObjTab miss), wait-before-import,
  wait-on-quiescent-resource, wait-blocked-then-drain, fatal-ring.
- **Verification gate**: remote `ovh_calltorch` `tb_g6lc_apu_vnpump` +
  synth leaf before claiming RTL evidence; record PASS/INCOMPLETE
  honestly (simulator-PGO infra timeouts ≠ implementation failure).

## Boundaries

- The §6b pump RTL (`g6lc_apu_vnpump.sv`) still refuses both commands —
  its `unique case` dispatch has no 0xF5/0xF6 arm and falls to
  `StFatal`. That is the honest current state: wire admits, native
  models, pump refuses pending the RTL increment. A semaphore binding
  table plus ring-scan wait state in the pump is the queued follow-on.
- Import does not validate that the VkSemaphore object exists (the
  transport layer does not own front-end objects) and does not bridge
  to generic Vulkan external-fence/semaphore fd paths — the protocol
  defines this as its own resource mechanism.
- "Pending work" is defined over ring submissions on the bound blob
  resource only; command-stream executions not tied to a ring are not
  yet attributed to a semaphore resource.
- Host-model evidence only. Zero capsets; no stock guest, CTS,
  physical or silicon claim.
