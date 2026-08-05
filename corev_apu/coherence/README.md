# Coherence (U6.2) — multi-core 1…`CVA6_MAX_CORES`

Parameterized for **1–8 physical cores** (default max 8 via `config_pkg::CVA6_MAX_CORES`,
overridable with `` `define CVA6_MAX_CORES N ``).

| Module | Role |
|--------|------|
| `g6lc_coherence_pkg.sv` | Line-inv types / helpers |
| `g6lc_snoop_filter.sv` | Presence vector per line (filter useless snoops) |
| `g6lc_inval_bus.sv` | Per-core inv FIFO + line coalesce + RR drain |
| `g6lc_lr_sc_tracker.sv` | Per-core LR reservation; kill on remote store/AMO |
| `g6lc_coherence_hub.sv` | N×AXI → L2/mem + inv + LR/SC |

## Config (`cva6_cfg_t`)
| Knob | Meaning |
|------|---------|
| `NrCores` | 1 = identity; **2–8** = multi-core cluster |
| `CohPolicy` | `COH_WRITE_INVAL` / `COH_BROADCAST` / `COH_FILTERED` |
| `SnoopFilterEn` | Enable SF |
| `SnoopFilterEntries` | SF size (power of two) |
| `CohInvalDepth` | Per-core inv FIFO depth |
| `CohAxiStarveLimit` | Multi-master AXI anti-starve |

`NrHarts` = SMT threads **per core** (≤ 2). Total Linux harts ≈ `NrCores × NrHarts`.

## Aggressive contention optimisations
1. **Split AR ‖ AW** — address channels grant concurrently (not one serial FSM).
2. **Multi-outstanding** — core id folded into upper AXI ID bits; R/B demux by id.
3. **OT limit** (`MAX_OUTSTANDING`) — caps bus storms under multi-core MLP.
4. **W-owner lock** — new AW waits until prior W.last (AXI W has no id).
5. **Snoop filter** — invalidate only owners (over-approx on capacity miss).
6. **Inv coalesce** — same-line merges in per-core FIFOs.
7. **AXI RR + per-channel starve** — fair under hot shared lines.
8. **NC bypass** — non-cacheable AW skips SF/inv.
9. **LR/SC tracker** — remote store kills peer reservations (atomics contention).
10. **L2 multi-waiter MSHR** — same-line multi-core misses attach without new fill.
11. **N=1 identity** — combinational AXI pass-through.

## Status
RTL live; default `NrCores=1` (identity). Testharness instantiates `g6lc_cluster` with
`NR_CORES=CVA6Cfg.NrCores`, CLINT scaled, L1 inv into WT **and** HPDCACHE. Remaining:
multi-context PLIC, FPGA bring-up, `.dts` N×`cpu@`, SMP boot.
