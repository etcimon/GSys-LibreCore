# Decision register — Storamic inferred evaluations

Current persistence status and implementation/qualification boundaries are in
[`development-status.md`](development-status.md). In particular, a retained
model replay head, debug commit counters and a magic-key interlock do not close
ST-025 or establish physical persistence.

This document records the design decisions inferred from the architecture
while completing the RTL, each with its basis and evidence status. It is the
standing note for subsequent elaboration: entries marked **OPEN** need
external input (hardware, allocations, or a contract version bump); entries
marked **SETTLED** are implemented and verified to the stated depth. Nothing
here grants capability beyond the cited evidence.

## SETTLED — implemented

### D1 — Sequence exhaustion: fail-safe renewal (was a documented gap)

The pinned contract is: stop admission, drain contexts and binding, advance
reset generation, reuse the sequence space *without clearing RAM* — never a
silent wrap. In `g6lc_storamic_axi_memory.sv`:

- `q.allocated` still saturates at `SeqLimit`; `sequence_exhausted_o`
  reports the exhausted state (`STATUS[3]`) and admission refuses — this
  part already existed.
- **New:** when `allocated == SeqLimit && !inflight_o`, the space drains
  (all accepted transactions retired; pending responses imply their active
  bits) and the frontend clears `allocated` and advances `epoch`.
- **Tag aliasing:** seq numbers restart at zero, so `txn_id_t` gained an
  8-bit `epoch` field stamped per tag. A stale completion from an older
  epoch cannot alias a live tag; it falls to `stale_completion`. A dedicated
  field was chosen over folding the epoch into `reset_generation_i`
  arithmetic, because arithmetic could alias if the external generation ever
  changed mid-run. The tag is an internal contract (slot_mux passes it,
  bindings echo it) so widening is contained.
- **Fail-stop:** epoch saturation (`epoch == '1`) leaves the frontend
  exhausted permanently — the documented terminal state, never a wrap.
- `events_o.seq_renew` pulses on each renewal (observability; a renewal IRQ
  is a contract-v5 candidate, not part of the v4 bit map).
- Drain tokens issued before exhaustion still complete: `retire_total` is
  independent of the sequence space.

### D2 — Durable transport-neutral backend, first slice (ST-018)

`g6lc_storamic_durable_store.sv` (corev_apu/storamic/): a commit-boundary
model of the flash chip behind the `st_*` seam.

- Host writes land in an 8-entry write-back staging buffer; `st_flush_ack`
  asserts only after the buffer drains into the `tc_sram` backing array —
  the flush ordering contract: *ack ⇒ all earlier writes committed*.
- Reads check staging first (read-own-writes); a full buffer spills the
  oldest entry to the array on the next write request (a spill is itself a
  commit, so durability and order hold, and a driver that never flushes
  cannot deadlock the port).
- The store grants out-of-range accesses immediately (error completion),
  so the requester never waits on a grant that can't come.
- This is a *model of the semantics*, not physical persistence: no
  power-loss domain, journal replay or erase cycle (ST-024/025 own those).
  It lives in corev_apu/ with the other models; `g6lc_storamic/` keeps only
  the media-neutral seam — that is the transport-neutral part of ST-018.

### D3 — One stick, two chips, two transports

`g6lc_storamic_model_stick.sv` (corev_apu/storamic/) is the stick: it owns
the flash chip (`durable_store`) and publishes the single identity/geometry
both transports consume — `present`, `identity`, `ram_bytes`,
`flash_bytes`, `flash_sectors`, `durable`, `serial` — mirroring discovery
descriptor words 2/4/8. The RAM chip is `g6lc_storamic_sim_mem` inside
`g6lc_storamic_attach` behind the controller's `mem_*` seam (the
controller-to-stick memory interface; `RamWords` publishes its depth).

- `device_usable`, `capacity`, `serial`, `store_ready`, `st_durable` in the
  testbench all derive from the stick's outputs instead of literals.
- The VirtIO device now negotiates and honors FLUSH end-to-end through the
  CPU (`storamic_virtio_blk.c` negotiates bank-0 bit 9 and issues T_FLUSH).

## OPEN — needs external input (nothing internal is blocked on these)

- **VendorID** — "no copied ID" is deliberate. Either allocate one
  (OASIS/PCI-SIG) or pick a private value for internal-only use; Linux's
  virtio core does not validate it. `VendorId` stays a parameter, default 0.
- **Electrical/media profile (ST-014)** — descriptor bus, voltages, pinout.
  Blocks the pad binding, and therefore real `presence`, real `power_en`,
  and discovery-driven `device_usable` (today a model constant).
- **Physical media (ST-015/016/017)** — RAM controller binding, raw flash
  ops, ECC/MBIST. Blocked on the profile choice.
- **Persistence domain (ST-024/025/026)** — power-loss boundary, journal,
  interrupted recovery, and Linux PMEM/DAX qualification. The durable-store
  model provides the flush ordering contract only.
- **Stick→device binding via discovery** — `device_usable` from slot READY
  is pinned intent; needs ST-014's real discovery instance in the native
  path.
- **Multi-queue (ST-041)** — pinned one-queue profile; MQ needs per-queue
  register state, notify demux, a scheduler or replicated engines, plus
  `VIRTIO_BLK_F_MQ`. ST-013 orders it after a measured-service baseline.
- **Contract v5 candidates** — a `seq_renew`/drain IRQ bit, `CAPS` media
  bits, writable config fields. The v4 register map is frozen.
- **virtio-mem / virtio-pmem (ST-039/040)** — gated behind the persistence
  domain; unchanged.

## Media / persistence track — elaborated

The track decomposes into four independent slices. What exists today, what
each slice needs, and what remains external:

**Slice A — commit boundary (DONE, model).** The durability contract is a
*commit point*: a write completes to the host when staged; it is durable
only after it crosses into the committed store. `durable_store` models this
honestly (staging → array on flush or spill). Every later slice builds on
this contract, so it was implemented first.

**Slice B — bandwidth and media asymmetry (DONE, model knobs).** A stick is
two chips with different bandwidth: the RAM path (frontend `mem_*` seam,
sim_mem `RspDelay`: one beat per RspDelay+1 cycles) and the flash path
(`st_*` seam, `RspCycles` interface stretch + `CommitCycles` media program
time per staged entry). Both are independent elaboration parameters —
RAM and flash bandwidth never share a knob. ST-013's measured-service work
sweeps them.

**Slice C — power-loss domain (SEAM IN PLACE).** `power_cut_i` on the
durable store drops uncommitted staging and errors any in-flight
completion while committed contents survive. This is a model boundary, not
a physical persistence domain. ST-024 must budget every protected RAM byte,
accepted queue/command and metadata record against guaranteed backup bandwidth
and usable energy. Staging depth times model CommitCycles is not that bound.

**Slice D — recovery semantics (first step DONE).** The durable store now
marks an entry journal-backed the moment its commit begins (`jrnl_q`): a
power cut drops every *uncommitted* staged entry but keeps the in-commit
entry and replays it into the array on recovery (`replay_q`) — all-or-
nothing at the commit boundary, which is what an interrupted-program
journal approximates at this model seam. ST-025 still requires a coordinated
drain/prepare/publish protocol and reset-recoverable checkpoint metadata with
persistent identity, map generation and integrity, even with one commit in
flight. ST-026 separately qualifies Linux PMEM/LIBNVDIMM/DAX. ST-014–017 (electrical profile →
RAM binding → raw flash → ECC/MBIST) stay external: the profile choice
gates all real-media work and no internal decision can substitute for it.

Recovery surface (sim-observable): `cut_count_o` (power cuts seen) and
`commit_gen_o` (flushes completed = recovery epochs) export through the
stick as diagnostics. Counter comparison alone cannot prove which contents
were lost or identify a valid recoverable image. These are not persistent
records or a protected ABI. RAM now has two model checkpoint banks; it still
publishes independently of the flash drain. The ordered work packages in
`checkpoint-coordination.md` define the next implementation sequence.

## Verified-consistent — no change needed

- `media_ready_o` and `persist_ready_o` stay 0 — honest until ST-014/025.
- One `allocated` space shared by AW+AR prevents two-path seq aliasing.
- `dma-coherent` stays justified by the cluster CMO invalidation path; a
  write-back D-cache config would need a different property.
