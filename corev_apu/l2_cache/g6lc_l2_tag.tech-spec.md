# Technology spec — `g6lc_l2_tag` tag-row SRAM (`TAG_SRAM=1`)

Scope: the single `tc_sram` instance `i_tags` in
`corev_apu/l2_cache/g6lc_l2_tag.sv` (`gen_tag_sram`), `ImplKey = "g6lc_l2_tag"`. It exists
only when the containing cache is built with `TAG_SRAM=1`, which today means
`CVA6Cfg.L2TagSramEn` on `g6lc_l2_top`/`g6lc_l3_top` (qualification-only packages:
`g6lc64_ooo_int2_l3` and `g6lc64_smt2_l3`, both the shared L2 and the L3 slice).
This document is the macro-binding and DFT plan required by
`AGENTS-technology.md` §6 and `agents/guides/AGENTS-soc-readiness.md` ("plan MBIST for
any new SRAM instance"); it does not by itself arm the technology pass
(`technology.optimizationPass` stays `false`).

## Geometry (generic path)

| Parameter | Value | Derivation |
|---|---|---|
| Words | `NUM_SETS` | sets of the containing cache |
| Data width | `SET_ASSOC * TAG_WIDTH` bits | one full tag row per word |
| Byte width | `TAG_WIDTH` | each byte lane is exactly one way's tag — `be` is a one-hot way select |
| Ports | 2 | port 0 read-only, port 1 write-only (no read-during-write on one port) |
| Latency | 1 | the row is launched one cycle before the compare consumes it |
| Init | none (`SimInit="none"`) | tag contents are don't-care; the valid bits live in flops and clear at reset |

Package geometries: L2 in `g6lc64_ooo_int2_l3`/`g6lc64_smt2_l3` (and
`g6lc64_ooo_int2`) is 512 words × 392 bits (8 ways × 49-bit tag, 64 B lines,
256 KiB). The shared L3 is 1024 words × 768 bits (16 ways × 48-bit tag, 1 MiB).
Flop bits removed per instance: `NUM_SETS*SET_ASSOC*TAG_WIDTH` — 200,704 (L2) /
786,432 (L3); valid flops kept: 4,096 / 16,384.

## Binding rules

- Swap only at the `tc_sram` seam: a technology wrapper selected by `ImplKey`
  must be port- and latency-equivalent (2-port 1R1W, 1-cycle read,
  byte-write enables).
- Initialization contract: valid bits are the flop array (`valid_q`, async
  reset). The macro never needs clearing — a tag is only compared or probed
  for a way whose valid bit is set, and a set's row is rewritten on every
  install into it.
- Read/write collision: a write on port 1 to the address a port-0 read just
  sampled is repaired by the launch-cycle forward register (`fwd_*_q`), so a
  wrapper may return old or undefined data on that collision without changing
  observable behaviour. There is deliberately no use-cycle forward: the flop
  array's compare reads pre-write state, and a combinational replay into the
  compare closes a loop through the parent's data-bank-conflict term
  (`hit_way -> tag_way -> bank_conflict -> write_i -> row_tag`). A wrapper
  that changes the read latency, or that makes a read see a *partially*
  written row, breaks the contract.
- The deferred inval-match clear compares the raw row (no forwarding)
  against the match tag, and gates on the set's valid bits **snapshotted in
  the read cycle** (`inv_valid_q`) — both operands are cycle-1 state, exactly
  like the flop array's same-cycle match on `tags_q`. Comparing the row
  against *live* valids is observably wrong: a write landing between the two
  cycles would be cleared by a match on stale row contents (measured: the
  fresh install is dropped and the next access refetches — HUM scenario 41 /
  `L2TAG_MITER_CORNER`). A write landing in the deferred-compare cycle is
  newer than the match request and outranks the clear via the `valid_d`
  ordering. A wrapper must not reorder a read past a same-cycle write
  differently than "old data", matching the flop array's same-cycle match
  semantics.
- The snapshot also folds in the ways the *preceding* deferred compare is
  clearing this cycle (`inv_clr`, same set only): the flop array commits a
  match clear at the request edge, so a back-to-back inval-match already
  sees the dying bit as 0; without the fold the second compare would
  re-match a way revalidated between the two requests and kill its fresh
  install (`L2TAG_MITER_CORNER2`).
- `inval_match_hit_o` pulses once per deferred compare that actually clears
  a live way (one pulse regardless of how many ways match — a tag occupies
  at most one way per set in practice); the flop path pulses in the request
  cycle, the SRAM path one cycle later.

## Launched-read protocol

- `launch_i`/`launch_index_i` request the row needed next cycle; an
  `inval_match_i` read wins the port (the lookup re-launches), and
  `row_valid_o` is low exactly on the cycles where the presented row is not
  the launched one. The parent holds S_TAG while `row_valid_o` is low — one
  extra cycle per steal, no dropped lookups.
- `hit_o`/`probe_tag_o` are only meaningful with `row_valid_o` and
  `index_i == row_index_q` (checked by a sim-only `L2_TAG_ROW_INDEX` fatal).
- `way_valid_o`/`probe_valid_o` are pure flop reads and never stall.

## DFT / MBIST plan

- The macro is idle whenever no lookup is launched and no fill installs —
  the reset state and any quiescent point. BIST may own both ports through
  the wrapper while the cache is quiesced; no scrub pass is required on
  return since valid bits are the reset authority (a BIST that trashes tag
  contents is invisible until an install rewrites the row).
- Scan: the SRAM path adds registered state only (`valid_q`, `row_valid_q`,
  `inv_*_q`, `row_index_q`, `fwd_*_q`) on the existing async-active-low
  reset; no new clock, reset domain or latch; `test_en_i`/`testmode_i` paths
  in the cluster are unchanged.
- Observability: unchanged — `l2_hit_o`/`l2_miss_o`/`l3_hit_o`/`l3_miss_o`
  pulses and the evict/self-inval probes see identical timing in steady
  state (the launch is scheduled so the compare still completes on the
  first S_TAG cycle).

## Open

Foundry macro selection, MBIST controller instantiation, STA on the target
library and power characterization are physical-design deliverables under
`pd/pdk/<technology>/`; none is claimed here.
