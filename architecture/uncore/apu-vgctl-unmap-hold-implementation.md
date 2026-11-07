# vgctl retained-unmap owner-hold

Status: implemented, directed RTL leaf evidence only.  This is a
control-plane safety transaction inside `g6lc_apu_vgctl`; it is not CTS,
device, firmware or physical qualification, and it does not by itself
close the full retained-unmap contract evaluated in
`apu-native-compute-foundation.md` (alias accounting, owner-generation
acquisition, private retained bytes and remap-move-back remain open).

## Scope

`corev_apu/apu/g6lc_apu_vgctl.sv` (tier R) - `UNMAP_BLOB` on a
memory-backed blob (`aux[0]` set, backing `VkDeviceMemory` resolved via
`map_memh_q`) previously took the same immediate `StPgReq` free path as a
first map: the guest extent returned to vgpages in the same evaluation
that published `APU_MEM_UNBACKED`, with no proof that engines or queued
submissions had stopped referencing it.

The change adds a retained-unmap branch in `StMapMemCpl`:

- Condition: `map_unmap_q` set and the memory's `aux[63:32]` base is not
  the `APU_MEM_UNBACKED` sentinel (a backed extent exists to release).
- Action: latch the extent into `map_oldb_q`, assert `map_hold_q`
  (`hold_o` - cmdexec submission hold, the same mechanism the §12.3 3d-d
  DEVBACKED relocation uses), and enter `StMapDrain`.
- `StMapDrain` waits for `drain_idle_i` engine quiescence, then - because
  `map_unmap_q` is set - diverts to the new `StUnmapFree` instead of the
  relocation squatter scan (`StMapScan`).
- `StUnmapFree` issues `APU_VGPAGES_OP_FREE` on `map_oldb_q`/
  `map_size_q[31:0]` and returns to `StUnmapPriv`, which publishes
  `APU_MEM_UNBACKED` through the objtab aux write
  (`StMapAuxReq`/`StMapAuxCpl`/`StBindReq`/`StBindCpl`).
- `StWrPrep` clears `map_hold_q` on every exit, success or refusal, so
  submissions resume only after the UNBACKED publish completes.

Ordering is the safety property: the extent cannot return to the
allocator while `hold_o` still blocks new submissions and
`drain_idle_i` has not yet reported quiescence; `UNBACKED` is published
only after the free, so a racing engine use fails truthfully on the
sentinel rather than touching freed pages.

## Preserved behavior

- Unbacked-memory unmap cannot reach this branch (`bind_offset == 0`
  guard); if it ever did, the immediate path's FREE of the UNBACKED
  sentinel is BOUNDS-ignored and still publishes UNBACKED.
- `MAP_BLOB` is unchanged: `map_unmap_q <= 0`, DEVBACKED relocation and
  plain free+`ALLOC_AT` paths are untouched - the new branch is guarded
  by `map_unmap_q`, which only `UNMAP_BLOB` sets.
- DEVBACKED (`aux[0]`) survives the hi-word publish; a later `MAP_BLOB`
  on that memory still takes the relocation path truthfully.
- Blob-owned (non-memory-backed) unmap keeps its existing immediate
  `StPgReq`/`StBindReq` path.

## Alias accounting (UNMAP_BLOB, §12.3 C)

A `VkDeviceMemory` extent is shared by every live `APU_BLOB_SHMEM`
entry whose `aux[63:32]` names its `{gen,slot}` handle and whose
`aux[0]` memory-backed flag is set — the same alias model
`vn_memory_blobs.py` implements host-side (`owner` shared by
`create_blob_mem(rid, size, mem_id)` aliases; the extent relocates or
frees only when the last mapped alias unmaps).

Before the retained-unmap owner-hold engages, the backed-`UNMAP_BLOB`
path now probes for surviving aliases:

- `StMapMemCpl` (unmap, memory backed) latches `map_oldb_q` (the
  extent base, kept for the resume), `unmap_self_q` (the unmapping
  blob's `{gen,slot}`, latched at the `StOtCpl` dispatch LOOKUP), and
  enters `StAliasScan` instead of `StMapDrain` directly.
- `StAliasScan`/`StAliasScanC` issue `APU_OBJTAB_OP_SCAN_BIND` — a new
  read-only objtab walk of `req.ctx`'s context list — first over ctx 0
  (where `APU_BLOB_SHMEM` entries live), then over the request ctx
  when `rctx_q != 0`.
- The scan matches the FIRST live entry with `kind ==
  APU_VN_KIND_APU_BLOB_SHMEM`, `aux[0]` set, `aux[63:32] ==
  map_memh_q`, `bind_offset != 0` (still mapped), and `{gen,slot} !=
  unmap_self_q` (the requester is not its own alias).  It completes
  `APU_OBJTAB_OK` + handle + entry snapshot on a match, `MISS` on
  exhaustion — one completion, no SWEEP stream, and `StScanDone`
  treats it like `SCAN_OVL` (no destructive list repair).
- On `OK`: the extent stays — this blob alone rebinds to
  `bind_offset = 0` through the normal `StBindReq` tail and the
  memory keeps its base; no hold, no drain, no free, no UNBACKED.
- On double `MISS`: this was the last mapped alias — `map_hold_q`
  rises and the FSM resumes `StMapDrain` exactly where the pre-scan
  code entered it (`map_oldb_q` already latched, submissions still
  free), so quiescence → free → UNBACKED ordering is unchanged.

Bound-but-unmapped aliases (`bind_offset == 0`) correctly do not
count: they hold no live window, and a later `MAP_BLOB` on them
re-resolves the memory — which by then reports `UNBACKED` and takes
its normal lazy path.  `VkBuffer`/`VkImage` objects bound via
`SETBIND` are not blob aliases and are out of this probe's scope; an
access through them after the last alias unmaps is invalid-use
either way (the memory is `UNBACKED`).

## Map-side alias admission (MAP_BLOB, §12.3 C)

`vn_memory_blobs.map` requires every *mapped* alias of one owner to
share the same guest base (`simultaneous aliases require the same
guest base`) and relocates the whole owner extent on a non-matching
map.  Before this change every memory-backed `MAP_BLOB` on a backed
memory ran FREE+`ALLOC_AT` unconditionally — a second alias mapping
at a different offset would strand the first alias's window, and
even a same-base map thrashed the shared extent.

`StMapMemCpl` now routes a backed non-DEVBACKED `MAP_BLOB` through
the same `StAliasScan`/`StAliasScanC` probe (`map_unmap_q == 0`
discriminates; `map_oldb_q` keeps the published base, `unmap_self_q`
the mapping blob's `{gen,slot}` — both latched for MAP as well as
UNMAP).  `StAliasScanC` then decides:

- **hit + same base** (`{req_ram[9],req_ram[8]} == map_oldb_q`):
  `StMapBind` binds this blob into the shared window — no free, no
  realloc, no drain; the aux publish that follows is an idempotent
  CAS of the unchanged base.
- **hit + different base**: `APU_VG_ERR_PARAM` — the same refusal
  `vn_memory_blobs.map` raises; the mapped aliases' windows are
  never stranded.
- **double MISS**: no surviving mapped aliases — the map is an
  `owner.relocate`: FREE `map_oldb_q`, `ALLOC_AT` the requested
  base, bind, publish (the pre-change path, now reached only when
  it is actually safe).

The dispatch-time idempotent shortcut (re-map at the blob's own
current `bind_offset`) still answers before the probe — an
already-mapped blob remapping at its own offset never re-enters
the memory path.

DEVBACKED (`aux[0]`) memories still take the relocation path before
this probe — a multi-alias DEVBACKED re-base at a different offset
remains an open hazard of the same class (the word-mover publishes
the new base but mapped blob aliases keep absolute
`SHM_BASE+oldbase` windows; reconciling them needs a scan+SETBIND
sweep, not just detection).

## VkBuffer/VkImage bindings — verified non-issue

`SETBIND`-bound `VkBuffer`/`VkImage` entries store `bind_off` = the
*memoryOffset within* the memory plus `bind_mgen` = the memory's
generation at bind time — not an absolute window address.
`g6lc_apu_cmdexec`'s `StXfMemCpl` resolves the bound memory per use
and computes `aux[63:32] + bind_off` against the *current* published
base, checking `entry.gen == bind_mgen` (recycled slot → lost) and
`aux[63:32] != APU_MEM_UNBACKED` (unbacked → `lost_q`
DEVICE_LOST) — mirroring `vn_golden._xfer_extent`.  Re-base, full
unmap, and slot recycle are therefore all handled at use time; no
SETBIND invalidation pass is needed or wanted (bindings must survive
`vkUnmapMemory` per Vulkan semantics and follow the next map).

## Verification

Remote `ovh_calltorch`, Verilator 5.008 (`apu-repo-verilator` PGO
build), Yosys `storamic-sigmap-repair-20-r3`.  Evidence tags
`vgctl-alias-01`, `objtab-alias-01`, `vgctl-synth-01` — targeted
remote runs on pushed snapshot `apu-leaf-20261106T201151-66f9d3fa1cac`
(the full `apu-leaf` launcher was blocked twice by checksum races
against a concurrent storamic session writing `verif/tb/storamic/*`
mid-push; the APU source surface itself pushed clean):

- `run-apu-vgctl.sh`: `VERILATOR BUILD OK`,
  `PASS tb_g6lc_apu_vgctl cases=41 checks=332 cycles=12847` — D1
  retained-unmap, D2 unmap-side, and D3 map-side alias cases:
  - D1a: idle engines - hold observed (`hold_edges` delta), chain
    completes, memory publishes UNBACKED.
  - D1b: `drain_idle_i` held low - `hold_o` rises, the chain stalls in
    `StMapDrain` for 2000+ cycles with no done pulse, then completes
    after drain release; UNBACKED published, DEVBACKED retained.  A
    DEVBACKED memory takes this owner-hold path, never relocation.
  - D2a: two memory-backed blobs (rid 40/41) share one
    `VkDeviceMemory`; unmapping rid 40 finds the surviving mapped
    alias — `hold_edges` unchanged (no owner-hold), the memory stays
    backed at `0x4000`, and rid 40's `bind_offset` reads back 0.
  - D2b: unmapping rid 41 (last mapped alias) resumes the
    owner-hold and publishes `APU_MEM_UNBACKED`.
  - D3a: blob 51 `MAP_BLOB` at the same base `0x4000` while blob 50
    is mapped — admitted through `StMapBind`, memory base unchanged.
  - D3b: blob 52 `MAP_BLOB` at `0x8000` while aliases are mapped at
    `0x4000` — `APU_VG_ERR_PARAM`, extent untouched.
  - D3c: with blob 51 unmapped, blob 50 (sole mapped alias) remaps
    at `0x8000` — probe MISS, owner.relocate publishes base `0x8000`.
- `run-apu-objtab.sh`: `VERILATOR BUILD OK`,
  `PASS tb_g6lc_apu_objtab cases=16 checks=101566 cycles=6963392` —
  the new `SCAN_BIND` op disturbs no existing objtab behavior.
- `VGCTL_SYNTH=1`: `SYNTH OK Enable=0` and `SYNTH OK Enable=1`
  (16426 cells / 2531 flops; `select -assert-none` confirms no
  latches) — +348 cells / +41 flops over the pre-alias screen.

Testbench note: hold observability uses an NBA-only `hold_edges`
counter - the file's existing rule against mixed blocking/nonblocking
writes on one variable (the fence monitor documents the same constraint);
an earlier blocking-clear flag raced and was replaced.  The D2 blob
LOOKUP uses the `APU_VG_ID_TAG`-tagged client id form; a first draft
with an unsized concat literal hit WIDTHCONCAT under -Wall and was
corrected before the recorded runs.

## Not claimed

Explicit owner-generation acquisition versus concurrent objtab
mutation, private retained bytes for blob-owned unmap, allocator
capacity accounting, remap-move-back of retained bytes, engine-side
lease integration beyond the `drain_idle_i` quiescence contract,
DEVBACKED multi-alias re-base at a different offset (same hazard
class on the relocation path — needs a scan+SETBIND sweep to re-base
mapped blob windows), CTS/device/physical qualification, and any
capability or stock-software advertisement.
The full contract remains as evaluated in
`apu-native-compute-foundation.md` §RTL Unmap Evaluation.
