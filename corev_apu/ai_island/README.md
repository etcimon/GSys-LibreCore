# `corev_apu/ai_island` — Xg6lcai island plane (P3+)

**Status:** scaffold (not on any flist) · **Tier R** · **Config:**
`corev_apu/include/g6lc_ai_island_cfg_pkg.sv`

This directory is the **throughput / T2** plane of `Xg6lcai`. It is *not* part of
the core package (`cva6_cfg_t` / `ai_cfg_t`). See
`architecture/ai-matrix/scaling-100tops.md` §3 and §8.

| Plane | Home | Sized by |
|---|---|---|
| Core-attached T0/T1 | `core/cvxif_g6lc_ai/` | `config_pkg::ai_cfg_t` |
| Island T2 | **here** | `g6lc_ai_island_cfg_pkg::ai_island_cfg_t` + MMIO capability window |

## Planned modules (I1 / P3)

| Module | Role |
|---|---|
| `g6lc_ai_cap_window.sv` | read-only capability MMIO (BAR0 / fabric) |
| `g6lc_ai_desc_engine.sv` | descriptor ring walker + address check (AI-3) |
| `g6lc_ai_cluster.sv` | one PE array + local `tc_sram` banks + sequencer |
| `g6lc_ai_island_top.sv` | NoC endpoint, IRQ, DMA master, clock/reset/DFT |

## Ordering

1. **P3 spine** — descriptor engine + per-queue address check + IRQ (AI-3).
2. **I1** — one cluster + capability window; freeze `T` / DRAM class / NoC cut.
3. **I3** — memory system measured.
4. **I2** — N clusters (must not change latency-SKU results).

## Licensing

Tier **R** (`CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial`). Do not place NDA PDK
views here — they go under gitignored `pd/pdk/`.
