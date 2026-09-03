# Extension point: L2 / L3 cache + server prefetch

**RTL:** `../../corev_apu/l2_cache/`, `../../corev_apu/l3_cache/`. Playbook:
`../../agents/guides/AGENTS-l2l3-cache.md`.

## Intent
Cache levels below L1 to cut DRAM traffic for multi-core + speculative server workloads,
without editing L1 files or weakening RVWMO.

## Hierarchy

```
cores ──► coherence hub ──► L2 ──► L3 (opt) ──► server prefetcher (opt) ──► DRAM
                                                                      │
                         island GEMM DMA (xbar master) ───────────────┘
                                      DRAM = N-channel stripe (I3)
```

DRAM channels are **not** an L2 feature. The stripe (`DramChannels`, default 64 B =
L2 line) sits on the SoC DRAM slave so L2/L3 miss fills, the server prefetcher, and
the island DMA share one map. L2 default 4 banks on `addr[7:6]` already align with
that stripe (N=4 ⇒ one channel per bank). Do not let a line or AXI burst straddle
`2^DramChanShift`. Detail: [`../uncore/dram-channel-scaling.md`](../uncore/dram-channel-scaling.md).

| Level | Module | Config |
|-------|--------|--------|
| L2 | `g6lc_l2_top` | `L2En`, size/assoc/MSHR/banks |
| L3 | `g6lc_l3_top` (wraps L2 engine) | `L3En` (requires `L2En`) |
| Prefetch | `g6lc_server_prefetcher` | `ServerPrefetchEn`, streams, distance |

## Server-ready smart prefetch

`g6lc_server_prefetcher.sv` on the L3→DRAM (or L2→DRAM) AXI edge:

1. **Next-line** at `ServerPfDistance` on demand miss  
2. **Multi-stream stride** train (up to `ServerPfStreams`)  
3. **Demand always wins** AR arbitration; PF injects only when AR idle  

Complements L1 HPDCACHE stride (`HwPrefetchEn`) — L1 for tight loops, L3 edge for
LLC-friendly server streams (packet buffers, page copy, KVM guest memory).

## U6.0 L2 (implemented)
MSHR line-merge, banked data (`tc_sram`), NC bypass, WT+RA, parallel tags.
Exclusive `AR.lock` (LDEX) is captured and forwarded on the memory-side AR and
never takes the tag-hit path — otherwise `g6lc_axi_lrsc` never arms and
`sc.d` returns 1. `AW.lock` / ATOP were already preserved.

## Invariants
RVWMO; PMA (MMIO uncached via NC bypass); CBO end-to-end; 64 B lines with `Zic64b`
(equals default `DramChanShift=6`). Demand miss wins AR over prefetch **and** must
keep winning over island GEMM when both share the DRAM slave.

## Status
L2 **done**. L3 + server PF **done (config-gated)**. PMU group 2 **wired** (cluster → core).
Inclusive hierarchy **done (config-gated)**:
- L3 (or L2) victim → **L1** via `g6lc_l3_inclusive_inv` (`INCLUSIVE_L3`; TB sets it when `L3En`)
- L3 victim → **L2 tag match-inval** via `l2_back_inval_*` / `inval_match_*` on `g6lc_l2_tag`
DT: `dts-l3-prefetch.md`. Stream×multicore suite: `mc-stream-tests` (`g6lc64_ooo_server`).
Open: Ara live vector on sim flist (IP vendored + `Flist.ara` ready).
