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

## SoC map (Variane)

When `CVA6Cfg.AiCfg.MatrixEn`, the island sits on the **GPIO window**:

| Base | Length | Path |
|---|---|---|
| `0x4000_0000` (`ariane_soc::GPIOBase` / `AiIslandBase`) | 4 KiB | AXI → `axi2apb_64_32` → `g6lc_ai_island_apb` → `g6lc_ai_island_top` |

Non-AI packages keep the GPIO error slave. IRQ sticky is MMIO-visible; PLIC wiring is next.

## Verification

```bash
bash verif/regress/ai-island-veri.sh          # standalone spine
bash verif/regress/ai-matrix-veri.sh          # includes ai_island_mmio_smoke on g6lc64_ai
```

Standalone smoke: cap, good desc, AI-3 OOR/perm, bad version, disabled.  
SoC smoke: MMIO at `0x40000000` — cap, doorbell, AI-3 reject.

## Ordering

1. **P3 spine** — descriptor engine + per-queue address check (**done**).
2. **AXI attach on testharness GPIO window** (**done**); PLIC + DMA master next.
3. **I1** — one cluster; freeze `T` / DRAM class / NoC cut.
4. **I3** — memory system measured.
5. **I2** — N clusters (must not change latency-SKU results).

## Licensing

Tier **R** (`CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial`). Do not place NDA PDK
views here — they go under gitignored `pd/pdk/`.
