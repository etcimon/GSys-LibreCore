# wt_dcache_wbuffer — analysis (T1, loop + latency)

<!-- hyp8-status -->
> **Status: indicative, subject to further information.** Goal: **8 FO4 per
> cycle (5 GHz nameplate at `fo4_ps = 20`, margin 0.2)**. Every FO4 figure,
> stage count and kernel size here is a hypothesis read from the original RTL,
> the prior boards and the sv-timing reports (`reports/board.md`,
> `cut_surface.md`, `bottlenecks.md`, `carry_over.md`, `propagation.md`,
> `refusals.md`); the fresh 8-FO4 board's deciding value `D` is in
> `analysis/cut-ledger.md` and `analysis/coverage.md`. The cut-minimization
> protocol (`analysis/cut_minimization.md`) takes precedence over any planned
> cut listed below. Nothing here has been linted, simulated or measured on a
> board; a rewritten file may follow this analysis, the emitted sv-timing file
> (as-is or adapted), or the original RTL, as `coverage.md` records.


Source of logic: `core/cache_subsystem/wt_dcache_wbuffer.sv` (1611 lines; A128/A144 history in the svt-plan block lines 140–171). Board: 160.6 structural (reg→out `wbuffer_q → wbuffer_data_o`) / 137.1 adjusted — the worst *measured* module of the core. Role: write-through store coalescing buffer between the store unit / commit and the miss unit; exports `wbuffer_data_o` (the buffer contents) to `wt_dcache_mem` for load byte selection (store-to-load forwarding at the cache), owns the "fixup" write of a hit line (`fixup_d`, `fixup_bypass_d`) and the miss-unit handshake (`miss_req_o`).

## 1. State and writers (from the file's own contract)

| State | Writers |
|---|---|
| `wbuffer_q[DEPTH]` (pa, data, be, valid, dirty/txn flags, way/hit info) | accepted store push (coalesce into a matching entry or allocate a free one — `push_match` loop), T47 byte clearing at acceptance, miss-unit transaction progress (sent/ack/`txn` bits), invalidation, fixup write acknowledgement (bytes retired), flush/drain |
| `fixup_d` / `fixup_bypass_d` (the deferred hit-line write descriptor and its bypass copy) | prepared after tag lookup (`rd_hit_oh`), superseded by a newer store to the same bytes, retired on the array grant, invalidated on invalidation/`wr_cl` |
| `miss_req_o` packet and tx state | the oldest sendable entry selection (age/`txn` priority) |
| `wbuffer_data_o` | = `wbuffer_q` (export) |

Loop-carried (per `cut_surface`): one `expandable with hoisting` loop (`push_match`), three loops where `fixup_d` is defaulted outside and written inside (default-outside recurrence); push → bypass-allocate → post-push supersede composes in one cycle ("the next-state bundle billed a push → bypass-allocate → post-push supersede chain as its widest single field").

## 2. Execution paths

| Event | Chain | Reaches |
|---|---|---|
| store accepted (`req_port_i.data_req & we` from the store unit via `wt_dcache_ctrl`) | pa compare against every entry (DEPTH tag compares) → coalesce/allocate → byte mask merge → T47 clear → `wbuffer_d`; same cycle: supersede the pending fixup descriptor bytes | `wbuffer_data_o` → `wt_dcache_mem` load byte select (same cycle, through the export) |
| tag lookup result (`rd_hit_oh`) for a buffered store | prepare fixup descriptor (way, bytes) → array write request → grant → retire bytes | `wt_dcache_mem` write port |
| miss-unit ack / write-through progress | tx bits, free the entry when written through and fixed up | `miss_req_o` next entry |
| invalidation / `wr_cl` from the miss unit | invalidate descriptor and hit info | — |
| load (in `wt_dcache_mem`) | reads `wbuffer_data_o` for forwarding: per-byte youngest-writer merge over DEPTH entries (that merge is in `wt_dcache_mem`, fed by this export) | load data |

## 3. Callers and callees

| Port | Reader | Kind | Kill | Tolerance |
|---|---|---|---|---|
| `wbuffer_data_o` | `wt_dcache_mem` (load forwarding merge, same cycle), `wt_dcache_ctrl` (hazard: a load hitting a pending store) | comb | — | the cache hit path gains +2 in hyp8 anyway; a registered export means a load sees stores accepted up to one cycle earlier — safe only if the *acceptance* of a store and the *issue* of a younger load to the cache keep their order (the store unit issues stores to the cache only after commit → a younger load that issued before the store's acceptance is older in the pipeline than the store's visibility; this is the existing WT ordering: committed stores are visible to later loads through the buffer, and the LSQ/store_buffer own the speculative forward). The checked bit / `stl` verdict in the LSQ, not this export, orders speculative loads. Hence +1 on the export is tolerable **for loads issued after the store's acceptance**; the one-cycle window is covered by the `wt_dcache_ctrl` hazard check on the registered copy (it must compare against the pending push as well — see block `wb_pending_export`). |
| `miss_req_o/miss_ack_i` packet | `wt_dcache_missunit` (elastic request stage already landed) | valid/ready | — | elastic |
| `wr_*` (fixup write) → `wt_dcache_mem` | grant handshake | — | — | handshake |
| `req_port_i`/`req_port_o` (store accept) | `wt_dcache_ctrl` / store unit | valid/ready (`data_gnt`) | — | the grant may be registered (one cycle later) — the store unit already waits for `data_gnt` |
| `empty_o`, `not_ni_o` | `load_unit` (non-idempotent head rule), controller | comb on registered | — | one cycle late is conservative |

## 4. Functional separation

| Block | In | Out | State | Kernel / stage | Cost |
|---|---|---|---|---|---|
| `wb_match` (stage W1) | accepted store pa, `wbuffer_q` tags | DEPTH match bits + free-slot one-hot (registered) | — | stage: 8 × pa compare (≈4 FO4) + lowest-free (3 FO4) | ≤ 8 FO4 |
| `wb_alloc` (stage W2) | W1 result + the store's data/be | entry write (coalesce or allocate), T47 byte clear, `pending_export` record | `wbuffer_q` | stage: byte-mask merge (2 FO4) + entry write mux (3 FO4) | 6 FO4 |
| `wb_pending_export` | W1/W2 in-flight store | `wbuffer_data_o` = `wbuffer_q` **plus** the in-flight pending record as a (DEPTH+1)-th virtual entry, so a reader sees the accepted store the same cycle as today's acceptance *semantics* (the data is exported from the pipeline register, not recomputed) | pending record | stage | 3 FO4 |
| `wb_fixup_prepare` | `rd_hit_oh` (tag lookup), entry bytes | fixup descriptor (way, pa, bytes, version) | descriptor regs (2) | stage | 5 FO4 |
| `wb_fixup_supersede` | descriptor vs W2 accepted store (same line/bytes) | masked descriptor, or replay with new payload | version counter | **kernel** (bounded local check: one pa compare + byte mask AND ≈ 5 FO4) | ≤ 6 FO4 |
| `wb_fixup_retire` | array grant | bytes retired, entry free check | — | stage | 3 FO4 |
| `wb_drain` | tx bits, age | `miss_req_o` oldest-sendable (8-way age select, 2 steps) | tx regs | stage | 6 FO4 |

Boundary moves: the per-byte youngest-writer forwarding merge stays in `wt_dcache_mem` (T2 row) but reads the exported pending record too; `wt_dcache_ctrl`'s hazard check compares against `wbuffer_data_o` including the pending record.

## 5. Latency and throughput target

- One accepted store per cycle sustained (W1/W2 pipeline; `data_gnt` registered); today the acceptance is same-cycle.
- Fixup write service gains a cycle and can replay (as the svt-plan says); write-through drain unchanged.
- Load forwarding from the buffer: +0 cycles relative to today's *visibility* (pending record exported), but the cache hit latency itself is +2 (D$ tag/data split, `DcacheHitExtra`).
- Cost: pending record (pa+data+be ≈ 64+64+8), descriptor versions, +1 `data_gnt`.

## 6. Decision

Files (new): `core/cache_subsystem/wt_dcache_wbuffer.sv` (ports unchanged except `wbuffer_data_o` gains one virtual entry: width DEPTH+1 — consumers `wt_dcache_mem`/`wt_dcache_ctrl` are rewritten in the same group), `wb_match.sv`, `wb_alloc.sv`, `wb_fixup.sv` (prepare/supersede/retire), `wb_drain.sv`. `HypCfg`: `WbufPipelined` (0 = today, 1 = W1/W2 + pending export).

Kill identities: none by tid (committed stores only); `flush`/drain semantics as today (a pending record is a committed store and must not be dropped by a flush — it is drained like an entry).

Expected `// hyp8:` departures: (1) `data_gnt` one cycle after the request; (2) `wbuffer_data_o` carries the pending entry; (3) fixup can replay.
