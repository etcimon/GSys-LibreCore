# Enhanced write-through (eWT): the LibreCore cache model

LibreCore keeps every cache level — L1, L2 and the optional L3 — **write-through**.
Write-back is not a direction for this project. What makes the write-through
hierarchy competitive is a set of features that are usually the reason people
reach for write-back, applied at every level and to every configuration:

| Feature | Meaning | Where |
|---|---|---|
| **Hub-owned coherence** | Every store leaves the L1 as an AXI write. The coherence hub observes it at acceptance, records sharers (signature under `COH_OOO`, snoop filter under `COH_FILTERED`) and sends invalidations to every other L1 copy. There are no ownership states, no dirty-owner responses, no cache-to-cache transfers. | `corev_apu/coherence/` |
| **Read-allocate** | Cacheable reads install lines at L2 and L3 (`WtAxiAllocEn` for WT L1s — the shim used to emit modifiable-only attributes so the L2 was a bypass; HPDCACHE L1s always emitted allocate bits). | `wt_axi_adapter`, `hpdcache_mem_to_axi_*` |
| **Write-update** | A store that hits a resident L2/L3 line merges its bytes into the line instead of purging it (`L2WriteUpdateEn`). Stores to non-resident lines write around (no allocation, no fetch). | `g6lc_l2_top` (`WRITE_UPDATE`), `g6lc_l3_top` |
| **Posted writes** | The L2/L3 forward write-through and non-cacheable traffic through a tracker and return to servicing hits and misses immediately; the AXI B response still comes from memory, so software-visible ordering is unchanged. | `g6lc_l2_top` write tracker (M1) |
| **Propagated CBO** | `cbo.inval` invalidates every L1 copy (through the hub invalidation bus), the L2 and the L3; `cbo.clean`/`cbo.flush` complete once the issuing hart's write buffer and the L2/L3 write trackers hold no posted write; `cbo.zero` is an ordinary full-line store sequence. | WT/HPDCACHE subsystems → cluster CMO engine → hub / `l2_back_inval_*` (M1) |

The L1 write-through cache already updates a resident line on a store hit and
does not allocate on a store miss; the L2/L3 engine applies the same policy.

## Status (2026-09-27)

| Configuration | L1 | Allocate | Write-update | Posted writes | CBO | Coherence |
|---|---|---|---|---|---|---|
| `g6lc64_ooo_int2`, `g6lc64_ooo_int2_l3` | WT | on | on | on | on | `COH_OOO` (signature) |
| `g6lc64_smt2_l3` | WT | on | on | on | on | single core |
| `g6lc64_smt2`, `g6lc64_smt2_ooo_int` (anchors) | WT | on (anchors re-baselined) | on | on | on | single core |
| `g6lc64_stream8`, `server_math`, `server_math_v`, `ai`, `ooo_server` | HPDCACHE_WT | on (HPDCACHE) | on | on | on | `COH_FILTERED` |
| `g6lc64_ooo_int` | WT, no L2 | — | — | — | on (L1-local, `L2En=0`) | single core |

"M1a" (CBO end-to-end + write-update + allocation) is landed (T9a); "M1b" (posted
writes + bypass-read tracking, `L2PostedWriteEn`) is landed (T9b). Everything
marked "on" has strict OpenSBI evidence on the named package (T8a–T8f, T9a, T9b).

Measured on the four-hart OpenSBI boot of `g6lc64_ooo_int2` (DRAM latency 0,
`ooocoh-p5-osbi-int2-L0-r1`): allocation alone turned a 0-hit bypass into 110k L2
hits but left ~100k misses, ~90k of them following a write-through purge of a
resident line; write-update then cut the misses to **1,532** while merging **817,606**
stores into resident lines (`l2_selfinv` 189). Boot cycles: 17,777,964 (bypass) →
18,675,595 (allocate) → **17,993,674** (allocate + write-update). The remaining cost is
the L2 FSM blocking for each write's memory round trip (845k bypass transactions),
which posted writes remove; at DRAM latency 40 that round trip is what made the
allocating L2 boot take 46.9M cycles (measurement run, 60M cap). M1 still returns
the core's B from memory. Line drain and early completion, below, are the further
cut that takes that wait off the core.

## Why not write-back

| Concern | Write-back would need | eWT provides |
|---|---|---|
| Store latency to the core | Dirty lines absorb the store; B is local. | The WT L1 write buffer absorbs the store; the hart continues. The L2/L3 no longer block on the memory round trip (posted writes). |
| Memory write bandwidth | Only evictions reach DRAM. | Every store reaches DRAM. Mitigated by write-update (lines stay resident, no refetch) and posted writes (bandwidth is used, latency is hidden). A write-combining buffer at the DRAM boundary is a measured option, not a commitment. |
| Coherence protocol | Ownership states (M/E/S/I or richer), request-for-ownership and upgrade transactions, dirty-owner data responses, a hub directory that tracks owners, and a write-back L1 that asks permission before writing. | Invalidation-only: the hub sees every store as an AXI write and invalidates sharers. The signature filter (`g6lc_ooo_snoop_filter`) is a one-byte-per-core presence table. |
| Speculative OoO loads | Ownership transfers must be reconciled with accepted-physical-address validation. | Loads are validated against invalidation-apply events that already exist because stores are visible at the hub (`COH_OOO`). |
| Non-coherent agents (island DMA, harness backdoors, RVFI/ELF preload) | Software must flush dirty lines before a DMA read; the harness needs a hierarchical peek; memory is stale until flush. | **Memory is current after every B.** DMA reads need no flush; only DMA *writes* need `cbo.inval` so cached copies are refreshed. |
| Eviction | Dirty victims need a writeback engine, a victim buffer and ordering against the fill of the same set. | Eviction is a tag clear; no data movement, no victim buffer, deterministic. |
| Atomics / LR-SC / NC bypass | A dirty line must be flushed or the AMO executed in-cache before bypassing to memory. | Bypasses go to memory, which is current; the resident copy is invalidated (today) or kept coherent by the ATOP result path (measured option). |
| CBO semantics | `clean`/`flush` move data; `inval` may drop dirty data (spec permits, software must know). | `clean`/`flush` are completion-only waits; `inval` never loses data (there is none to lose). |
| Area | Dirty state per line (4k flops L2, 16k flops L3), victim buffer, writeback datapath, directory owner fields. | Valid bits and tags only; the write tracker is a 4-entry FIFO/CAM. |
| Verification | Dirty-lifetime invariants, owner/upgrade races, flush-before-bypass corners. | Same-line hazard (fill vs in-flight write) and per-id B/R ordering — two small CAMs with mutation controls. |

The trade is explicit: eWT spends DRAM write bandwidth to buy a protocol with no
ownership state and a memory image that is always current. For the SoC classes this
core targets (embedded application clusters with WT L1s and one memory channel) the
bandwidth is affordable and the simplicity is worth more than the last increment of
store throughput.

## Planned: line drain and early completion

M1 forwards the write and returns to hits and misses while it is in flight, but the
core's B is still memory's B. A fence, and any reader that needs the new line, waits
out that acknowledgement: 40 cycles after the last write beat at the latency used for
the L2 studies. The next cut keeps the store moving outward. It does not add a
private dirty record, a spill policy, or a private-versus-published state.

- The L1 write buffer keeps coalescing bytes, and it drains **one write per 64-byte
  line**. That is the buffer that already exists, held to a line boundary. There is
  no dirty bit and no copy that memory will not eventually receive.
- On a cacheable write the L2 merges the bytes into a resident line (write-update),
  enqueues the DRAM write, and **returns B at that acceptance**. The tag lookup is
  free while the queue drains. A store that misses still writes around: it does not
  read the rest of the line in.
- The hub invalidates, on that B, the other cores the snoop filter marks. The
  writer's own L1 line stays, because the write buffer has installed the same bytes
  there. The writer's next load hits its L1.
- A peer misses its L1 and hits the merged L2 line: `S_TAG`, `S_HIT_WAIT`,
  `S_HIT_RESP`, about 3 cycles to the first beat once the tag row is valid. It does
  not wait for DRAM and it does not read the writer's cache.
- Atomics, locked writes, and non-cacheable writes still complete on memory's B and
  still drop the resident copy.
- A cacheable read of a line with a posted write is served from the merged line, so
  it issues no AR and the same-line AR/AW hazard does not apply. `cbo.clean` /
  `cbo.flush`, and any order a non-coherent DMA read depends on, still wait until
  the posted queue has memory's B. DRAM is current before that reader.

A core running alone uses the same path. Its stores retire when the L2 accepts the
line write. Its fence waits for those acceptances. Nobody is invalidated, because
the filter marks no other core. DRAM takes the posted copy in the background.

## Cycles against write-back

No write-back configuration exists to subtract. The gaps below are the latencies
this cache already measures. The 98.5 % boot-miss cut (about 100k misses to 1,532,
with 817,606 merges) is the gain of write-update over a write-through purge. A
write-back L2 would have kept those same lines. It is not a gain over write-back.

| Path | Write-back | eWT with line drain and early completion |
|---|---|---|
| Contended read, line already at the L2 | L2 hit, about 3 cycles to the first beat | The same L2 hit, about 3 cycles |
| Contended read that today waits on DRAM | Served from the dirty line, with a snoop of the writer if the line is only in its L1 | Falls from the 40-cycle acknowledgement to that 3-cycle hit. About 40 cycles per published line versus today's write-through |
| Writer while another core reads the line | Stalls while the dirty line is taken from its L1 | Keeps its L1. The reader uses the L2. This hub has no data snoop, so that stall has no measured length |
| Streaming store that misses | Reads the 64-byte line in, then writes it back later | Writes the stored bytes outward and does not fill. The latency-40 write/read kernel spent 821,733 cycles against 195,760 at latency 0, about 100 cycles of exposed stall for each of its 6,060 missed lines; eWT does not pay that fill |
| Private stores and a private fence | Retires in the L1 | Retires when the L2 accepts the coalesced line write. A few cycles slower per line write. Loads still hit the L1 |

What eWT spends, against a dirty L1, is one L2 acceptance per coalesced line. What
it gets back is the DRAM acknowledgement off a shared read, the allocate-fill off a
streaming store, and a writer that keeps running while other cores hit the L2.

## Software-visible contract

- A store is globally visible to other harts once the hub has accepted its AXI write
  (peers are invalidated at acceptance and refetch through the L2, which merges the
  store into a resident line). Under M1 that acceptance waits for memory's B. After
  early completion, cacheable writes are accepted when the L2 merges them, and they
  reach DRAM when the posted queue's memory B returns. A hart's own loads see its
  stores through the L1 write buffer, and its L1 line is left in place.
- `fence` semantics are unchanged under M1: the WT L1 drains its write buffer (waits
  for memory's B) before the fence completes, so `fence`-ordered MMIO and release
  sequences hold with posted writes exactly as they did with the blocking L2. After
  early completion, a cacheable fence completes when the L2 has accepted those line
  writes; MMIO, atomics, and locked writes still wait for memory's B.
- Non-coherent DMA **reads** need no `cbo.clean`/`cbo.flush` (they complete
  immediately once posted writes drained). Non-coherent DMA **writes** require
  `cbo.inval` over the written range (or a coherent ingress) — the invalidation reaches
  every L1, the L2 and the L3.
- Since M1a, `cbo.inval/clean/flush` on a WT target travels the CMO sideband: the
  store-port request is intercepted in `wt_dcache`/`wt_cache_subsystem` (it never
  reaches the write buffer), the op is issued to `g6lc_cmo_engine` once the write
  buffer is empty, and the store buffer's `data_rvalid` is answered on `cmo_done_i`.
  The engine broadcasts the L1 invalidation to every core and match-invalidates L2/L3
  (`l2_back_inval_*`, `l3_back_inval_*`); `clean`/`flush` complete on
  `l2_write_idle_o`/`l3_write_idle_o`. On HPDCACHE targets the adapter's own CMO
  response is held until `cmo_done_i`, so the same contract reaches L2/L3. With
  `L2CmoEn=0` (e.g. `g6lc64_ooo_int`) the core completes the CBO locally: `inval`
  goes through the L1 `inval_addr` mux, `clean`/`flush` wait for write-buffer drain.
  Directed evidence: `mc_cbo_ewt` (hart-to-hart visibility behind a `+mem_poke`
  DRAM write) on int2, int2_l3, smt2, smt2_l3, smt2_ooo_int, stream8, server_math;
  negative arms corrupt the expected value and fail as designed.

## Ordering rules the RTL enforces (posted writes, M1)

1. A cacheable read miss to a line with a tracked (not yet B-acknowledged) write holds
   until that B — AXI does not order an AR against an earlier AW to the same address.
2. Two tracked writes to the same line must carry the same AXI id (AXI orders B per id);
   a second write to a tracked line under a different id holds until the first B.
3. A write to a line with an in-flight fill waits for the fill and then takes the
   write-update path (the fill-kill rule for self-invalidations is unchanged).
4. B responses are routed to the oldest tracker entry of their id; a blocking write
   (ATOP, lock) also occupies a tracker entry so the routing is uniform.
5. Non-cacheable reads are tracked the same way; a cacheable hit response with the same
   id as an in-flight bypass read waits (per-id ordering on the slave side).
6. The hub credit count (`CohMaxOutstanding`) bounds fills plus posted writes; the
   credits bench proves the bound.

## Evidence map

Leaf and composed benches: `verif/tb/l2/tb_g6lc_l2_hum.sv` (HUM, write-update cases
and fault controls), `tb_g6lc_coherence_hub.sv` (hub + real L2/L3, `late_ar ≥ mem_b`),
`tb_g6lc_coherence_credits.sv`, `verif/tb/uncore/tb_g6lc_wt_axi_attr.sv`. System runs:
`verif/regress/remote/run_opensbi_source_review.py` strict profiles (per-package
results in `core/ooo/AGENTS-ooo-plan.md` T8), `run_mc_int2_review.py` directed kernels
(`mc_l2_write_read.S`, `mc_l3_stride_scan.S`, `mc_pmu_l3.S`). Configuration legality:
`core/include/config_pkg.sv` `check_cfg`.
