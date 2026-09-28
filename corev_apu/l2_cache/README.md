# CVA6 L2 cache (U6.0)

Memory-side AXI-to-AXI L2 under `corev_apu/l2_cache/`. Does **not** edit `core/cache_subsystem`.

## Contention optimisations
- **Multi-MSHR + line-merge** (`g6lc_l2_mshr.sv`): secondary miss to an in-flight line does not open a new AXI transaction.
- **Multi-waiter attach (U6.2)**: up to `MAX_WAITERS` ids per line so multi-core same-line misses share one fill.
- **Banked data array** (`g6lc_l2_data.sv`, default 4 banks via `tc_sram`): hit read and fill write proceed in parallel when banks differ.
- **Non-cacheable bypass**: `ax.cache[1]==0` skips tags (MMIO never pollutes L2).
- **Exclusive AR bypass**: `AR.lock` is captured and forwarded on the memory-side AR. A locked read never takes the tag-hit path (that would return OKAY and leave `g6lc_axi_lrsc` unarmed). `AW.lock` / ATOP were already preserved for AMOCAS/STEX.
- **Write-through + read-allocate**: matches CVA6 WT L1; writes push through to memory.
- **Parallel tag compare**: single-cycle SET_ASSOC hit path.

## Write-update policy (`WRITE_UPDATE` / `CVA6Cfg.L2WriteUpdateEn`)

Default off; when enabled, a write-through to a **resident** line merges the W
beats into that line instead of invalidating the tag. Motivation (T8e,
measured on `mc_l2_write_read` and the four-hart OpenSBI boot): ~6,060 of
8,192 stores purged a resident L2 line and ~90k of ~100k boot L2 misses
followed a purge.

**Ordering argument.** A write is globally ordered by its B response: the
coherence hub drops the writer's L1 copy at B, so a reader served *before* B
may legally observe pre-write data, while any reader served *after* B must see
the new bytes. Merging keeps the same bound as purging — the FSM stays in the
write bypass sequence until B lands (`S_BYPASS_AW → S_BYPASS_W → S_BYPASS_B`),
so no read can be served the merged line before memory acknowledged the write;
the composed bench's `late_ar_cycle >= mem_b_cycle` admission contract holds
under both settings.

**Eligibility** (evaluated once, at AW acceptance, on registered fields —
`wu_eligible`): cacheable write, `atop == '0`, not locked, the whole burst
inside the addressed line (`len==0` of any size, or a full-width multi-beat
INCR run ending inside the line), and no in-flight fill for the same line.
Anything else — atomics, locked accesses, non-cacheable writes,
same-line-fill races, tag-miss writes — keeps the invalidate-and-kill path,
including the fill-kill (`kill_match` fires on every write either way) and the
deferred self-invalidation retry.

**Collision rules.** A back-invalidation colliding with a merge arms the
deferred match port and conservatively clears the merged line. An install
that would claim the merge's way mid-write is stalled (`wu_install_stall`)
until the write drains into `S_BYPASS_B`; a tag `write_i` landing on the
match-read edge exempts that way from the deferred inval-match compare (the
tag replacement itself retires the invalidation). `l2_wupdate_o` pulses once
per merged write (last forwarded beat).

**Timing impact:** the merge adds a byte-enable shifter plus a data-port-A
write mux in the bypass states only — no path into the `S_TAG` hit compare;
the eligibility compare is on registered request fields.
- **Pairs with** `corev_apu/coherence/` split AR‖AW hub under multi-core.

## Posted writes (`POSTED_WRITES` / `CVA6Cfg.L2PostedWriteEn`, T9b)

Default off; when enabled the write bypass posts the write instead of
blocking on memory's B. Every accepted write carries an entry in the
write tracker (`g6lc_l2_wtrk.sv`, `L2WriteTrackDepth` entries: valid,
slave id, downstream id, line address, blocking flag, in AW-issue
order). A write is *postable* iff `atop=='0 && !lock && id != FILL_ID`;
postable writes are forwarded on one reserved downstream write id
(`WR_ID = '1 - 1`, T9e) and return to `S_IDLE` after the last forwarded
W beat, so hits and misses are served while the write is in flight.
ATOP, locked and FILL_ID-alias writes stay on the blocking
`S_BYPASS_B` path with their original id but still hold an entry, so B
routing is uniform: a memory B is absorbed by the oldest tracker entry
of its *downstream* id (AXI orders B per id) and the slave B is
presented, with the recorded slave id, when that entry pops. Since all
posted writes share `WR_ID`, memory applies them in the L2's acceptance
order — including same-line pairs — with no L2-side serialization and
no integration assumption. `l2_write_idle_o` = tracker empty and no
write state, which is what `cbo.clean`/`cbo.flush` wait on.

NC/lock bypass reads are posted the same way: the AR forwards and the
FSM returns to `S_IDLE` with an entry in the read tracker
(`L2ReadTrackDepth` entries). Memory R beats for a tracked id go to the
slave through an R arbiter that keeps a burst atomic until `last`.

**Ordering rules** (the eWT doc's 1-6, enforced by two small CAMs): a
cacheable read *miss* to a tracked-write line holds until that B (R1);
a write to a tracked line holds only when the two *downstream* ids
differ — posted-vs-posted never holds, posted-vs-blocking and
blocking-vs-posted still hold (R2, T9e); a same-line fill still kills
the write's update eligibility (R3); B is routed per downstream id to
the oldest entry and returned with the slave id (R4); a slave-side hit
or fill serve whose id has a live read-tracker entry holds (R5); the
hub `CohMaxOutstanding` credit bound covers fills + write tracker +
read tracker (R6).

**Observability:** `l2_wtrk_full_o` (AW held, tracker full),
`l2_wtrk_line_hold_o` (any R1/R2 hold), `l2_hold_r1_o` (read miss
behind a tracked write), `l2_hold_r1_wu_o` (R1 behind a write-update
hit — expected ~0), `l2_hold_r2_o` (different-downstream-id same-line
AW), `l2_posted_o`, `l2_rdtrk_o` feed the `[mc_cache]` counters
`l2_wtrk_full`, `l2_line_hold`, `l2_hold_r1`, `l2_hold_r1_wu`,
`l2_hold_r2`, `l2_posted`, `l2_rdtrk`; the hub adds
`hub_aw_sc_collide` (same-core same-line AW slot collide) and
`hub_ar_hold` (AR offered but held behind a same-line live AW);
`l2_posted_hold_o`/`l3_posted_hold_o` feed PMU group-2 events 7/8
(posted-write hold cycles).

**Timing impact:** the CAMs are DEPTH-entry compares on registered
request fields (line-address CAM over the write tracker, id CAM over
both); the R arbiter adds one mux level on the slave R data path;
nothing enters the `S_TAG` hit-compare path. Structural FO4 on
`g6lc_l2_top` stays 28.5 (T9b/T9e screens).

## Config (`cva6_cfg_t`)
| Knob | Meaning |
|------|---------|
| `L2En` | Wire L2 in SoC (e.g. `ariane_testharness`) |
| `L2ByteSize` | Capacity (e.g. 262144) |
| `L2SetAssoc` | Ways (e.g. 8) |
| `L2LineWidth` | Bits; must match D$ / 512 for 64 B |
| `L2MshrDepth` | Outstanding misses (power of two) |
| `L2DataBanks` | Data banking factor |
| `NrHarts` | 1 baseline; 2 reserved for U6.1/U6.2 |
| `L2PostedWriteEn` | Posted writes + bypass-read tracking (T9b) |
| `L2WriteTrackDepth` | Write-tracker entries (pow2, 2..8, default 4) |
| `L2ReadTrackDepth` | Read-tracker entries (default 4) |

## Files
- `g6lc_l2_pkg.sv` — geometry helpers
- `g6lc_l2_mshr.sv` — MSHR + merge
- `g6lc_l2_tag.sv` — tag array
- `g6lc_l2_data.sv` — banked data (`tc_sram`)
- `g6lc_l2_wtrk.sv` — posted-write tracker (B routing, per-id order)
- `g6lc_l2_top.sv` — AXI slave/master controller

## U6.1 / U6.2 scaffold
`NrHarts` is config-gated (1|2). SMT thread-tag and dual-core snoop filter land in later sub-phases; L2 MSHR depth and banking are sized to absorb dual-hart MLP.
