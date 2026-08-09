# `corev_apu/ai_island` — Xg6lcai island plane (P3+)

**Status:** P3 spine landed (standalone veri) · **not yet on SoC AXI flist** · **Tier R**  
**Config:** `corev_apu/include/g6lc_ai_island_cfg_pkg.sv`

This directory is the **throughput / T2** plane of `Xg6lcai`. It is *not* part of
the core package (`cva6_cfg_t` / `ai_cfg_t`). See
`architecture/ai-matrix/scaling-100tops.md` §3 and §8.

| Plane | Home | Sized by |
|---|---|---|
| Core-attached T0/T1 | `core/cvxif_g6lc_ai/` | `config_pkg::ai_cfg_t` |
| Island T2 | **here** | `g6lc_ai_island_cfg_pkg::ai_island_cfg_t` + MMIO capability window |

## Modules

| Module | Role | Status |
|---|---|---|
| `include/g6lc_ai_desc_pkg.sv` | 64-byte descriptor ABI + error codes | **landed** |
| `g6lc_ai_cap_window.sv` | read-only capability MMIO | **landed** |
| `g6lc_ai_addr_check.sv` | per-queue `[base,limit)` + R/W (AI-3) | **landed** |
| `g6lc_ai_desc_engine.sv` | validate version/op + check all ptrs + complete | **landed** (no GEMM yet) |
| `g6lc_ai_island_top.sv` | reg map + IRQ sticky | **landed** |
| `g6lc_ai_cluster.sv` | PE array + `tc_sram` + sequencer | I1 |
| AXI/DMA master + xbar attach | fabric citizen | next |

## Verification

```bash
bash verif/regress/ai-island-veri.sh
```

Smoke covers: cap version/clusters, good descriptor → `ST_OK`, out-of-range
pointer → `ST_BAD_PTR`, bad version, W-only region rejects reads, disabled engine.

## Ordering

1. **P3 spine** — descriptor engine + per-queue address check + IRQ (**this**).
2. AXI-lite slave + DMA master on the testharness map.
3. **I1** — one cluster; freeze `T` / DRAM class / NoC cut.
4. **I3** — memory system measured.
5. **I2** — N clusters (must not change latency-SKU results).

## Licensing

Tier **R** (`CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial`). Do not place NDA PDK
views here — they go under gitignored `pd/pdk/`.
