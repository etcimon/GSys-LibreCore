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

## Pump RTL execution (implemented)

`g6lc_apu_vnpump.sv` now executes both commands. The mechanism mirrors
the native model and reuses the existing bounded park/resume machinery;
nothing is unbounded.

- **Ring resource id + cached tail**: `ring_t` gained `rid[31:0]` and a
  `tail[31:0]` cache. `rid` is stored at `vkCreateRingMESA` from the
  already-ObjTab-resolved `t_rid_q`; `tail` is refreshed in `StPollCap`
  on every successful guest-tail read (`if (!mp_err_i)
  ring_q[poll_q].tail <= mp_rd32`). The wait's pending predicate is
  combinational (`tail > head`), so the last-polled tail must live in a
  register — a not-yet-polled submission is correctly not yet visible.
  `DestroyRing` clears `live`, dropping dead rings from the scan.
- **Semaphore binding table**: bounded `sem_q[SEM_N=16]` of
  `{valid, handle[63:0], rid[31:0]}`. `sem_of` finds a live binding,
  `sem_slot` reuses a live handle's slot else claims the first free
  slot (−1 when full), `sem_rid_of` returns the bound rid. Import of a
  fresh handle into a full table faults.
- **`vkImportSemaphoreResourceMESA` (0xF6)**: `StTrExec` reads the sem
  handle and `resourceId` tail-relative to the decoded record
  (`sem = {w[-2], w[-3]}`, `rid = w[-1]`, `cmd_words_q` = full record
  length) and routes through `StOtReq`. `StOtCpl` `APU_OBJTAB_OK` proves
  the resource is a live mapped blob (the native `blob_of` check);
  `StOtDo` 0xF6 binds `{handle, rid}` and `StNext`. Null handle or ObjTab
  miss faults — mirrors native import refusal.
- **`vkWaitSemaphoreResourceMESA` (0xF5)**: `StTrExec` reads the sem
  handle at record words 4-5 → `StWaitSem` (no ObjTab needed). Unknown
  handle faults; `sem_wait_ready(rid)` scans rings for
  `live && rid==rid && !fatal && tail>head` (pending) plus any fatal —
  ready when `!pend || fat`. Pending parks the stream into `park_q`
  with `is_sem=1, srid=rid` (execbuf slot `Rings`, or the ring slot for
  ring streams) exactly like `StWaitR`, freeing the single FSM to keep
  draining rings; fatal routes to `StFatal`; drained `StNext`.
- **Park/resume extension**: `park_t` gained `is_sem` + `srid`; the two
  existing park literals (`StWaitVq`, `StWaitR`) were updated. The
  `park_take` scan adds the `is_sem` predicate. Because `is_sem` parks
  only ever occupy the execbuf slot (`Rings`), the resource scan is
  **hoisted** into a `sem_rdy` `always_comb` — nesting a `Rings`-loop
  inside `park_take`'s `Rings`-loop exhausted the Yosys 4000-unroll
  elaboration budget. On resume the saved `st_q`/`depth_q` restore and
  the wait re-runs through `StDecFire`→`StWaitSem`, re-validating
  (satisfied → `StNext`, fatal meanwhile → `StFatal`).
- **Directed tb** (`tb_g6lc_apu_vnpump.sv`): hand-encoded 0xF5/0xF6 wire
  vectors (`SEMIMP`, `SEMWAIT`, `SEMWAIT_UNK`, `SEMIMP_NULL`,
  `SEMIMP_BADRID`) plus `WAITVQ64`/`SUBVQ64` seqno vectors, covering
  import-ok (+`sem_q` white-box bind check), wait-before-import fault,
  null-handle fault, bad-rid ObjTab fault, wait-on-quiescent success,
  **park-then-drain-resume**, and fatal-ring fault. The pending case is
  built deterministically: ringA is parked on an unsubmitted vqueue
  seqno (cached `tail>head` while `parked`, FSM free) so the execbuf
  wait is accepted and parks in `park_q[Rings]`; ringB's `SUBVQ64`
  auto-drains (ring streams are not gated by `park_q[Rings]`), supplies
  the seqno, ringA drains, and the wait resumes. White-box probes use
  `dut.gen_on.*` (the `Enable` generate scope).
- **Verification** (remote `ovh_calltorch`, unit leaf
  `apu-leaf-20261107T074634-28482b5ab184`): `PASS
  tb_g6lc_apu_vnpump cases=102 checks=308` — Verilator 5.008, `-Wall`,
  width-clean after narrowing the tail-relative `tbuf` indices to the
  6-bit `TBUF=40` index width. **Synth: `SYNTH OK Enable=0`.**
  `Enable=1` fails at a **pre-existing** SLANG elaboration-unroll limit
  (`tc_sram.sv:92` `proc_sram_init`, cumulative >4000) — reproduced
  identically on the pre-change HEAD source, so it is a tooling/resource
  ceiling of the full `vnpump_fixture` (front-end+objtab+mp_mem), not
  introduced by this increment.

## Boundaries

- Import does not validate that the VkSemaphore object exists (the
  transport layer does not own front-end objects) and does not bridge
  to generic Vulkan external-fence/semaphore fd paths — the protocol
  defines this as its own resource mechanism.
- "Pending work" is defined over ring submissions on the bound blob
  resource only, using the last-polled `tail` cache: a submission
  published but not yet polled is invisible until the next `StPollCap`
  refresh (bounded staleness, same window the ring scheduler itself
  sees). Command-stream executions not tied to a ring are not yet
  attributed to a semaphore resource.
- The `Enable=1` Yosys screen is blocked by the pre-existing
  `tc_sram` sim-init unroll ceiling described above; `Enable=0` passes.
  This is a fixture-level tooling limit to resolve separately (vendor
  `tc_sram` is tier-U and out of scope here).
- Remote unit/synth leaf evidence only. Zero capsets; no stock guest,
  CTS, physical or silicon claim.
