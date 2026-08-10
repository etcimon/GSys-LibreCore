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
| `g6lc_ai_desc_engine.sv` | validate version/op + AI-3 + `ST_GEMM` handoff | **landed** |
| `g6lc_ai_desc_fetch.sv` | AXI read-only 64 B descriptor fetch | **landed** |
| `g6lc_ai_mem_store.sv` | AXI single-beat store (completion word) | **landed** |
| `g6lc_ai_tile_sram.sv` | dual-port Latency=0 `tc_sram` tile bank (A/B int8, C int32) | **landed** |
| `g6lc_ai_pe_dot.sv` | multi-lane INT8 MAC slice (PeLanes products/cycle) | **landed** |
| `g6lc_ai_gemm_seq.sv` | I1 GEMM: banked A/B + multi-bank C + dual-i32 store + PE | **landed** |

Capability window (`AiIslandLatencyDefault`) advertises **MacsPerCycle=128**,
**AccTileM/N/K=256** (SKU AccTile* live). C is multi-banked (`j % PeLanes`) so
each `tc_sram` is `MaxDim*ceil(MaxDim/PeLanes)` words (512xi32 @256/128).
PeLanes growth cuts MAC steps; A/B load still AXI-beat limited (I3).
| `g6lc_ai_island_top.sv` | reg map + IRQ sticky + fetch/store/gemm AXI mux | **landed** |
| `g6lc_ai_cluster.sv` | PE array + `tc_sram` + sequencer | I1 (next) |
| AXI/DMA master + xbar attach | fabric citizen | **wired** (`NrSlaves=3`, slave[2]) |

## SoC map (Variane)

When `CVA6Cfg.AiCfg.MatrixEn`, the island sits on the **GPIO window**:

| Base | Length | Path |
|---|---|---|
| `0x4000_0000` (`ariane_soc::GPIOBase` / `AiIslandBase`) | 4 KiB | AXI → `axi2apb_64_32` → `g6lc_ai_island_apb` → `g6lc_ai_island_top` |

Non-AI packages keep the GPIO error slave. Island `irq_o` is sticky on
`desc.flags[2]`; in Variane it is **PLIC source ID 8** (`irq_sources[7]`).

Control `0x100`: bit0 = enable, bit1 = `wr_cpl_en` (completion-word DMA after
a successful job when the DMA master is present). Default after reset is
`wr_cpl_en = EnableDmaFetch`. Directed tests that need the write use `CTL=3`;
PLIC-IRQ soak uses `CTL=1` (enable only) so the claim path is not mixed with
the completion store.
Clear level source (`AI_DONE`) **before** PLIC complete, or level-set re-arms IP.

## Verification

```bash
bash verif/regress/ai-island-veri.sh          # standalone spine
bash verif/regress/ai-matrix-veri.sh          # g6lc64_ai directed suite
```

Standalone smoke: cap, good desc, AI-3 OOR/perm, bad version, disabled.  
SoC: MMIO doorbell + AI-3; sideband enq/poll; **PLIC-8 IRQ**; **DMA desc fetch + ptr_done write**
(`desc_ptr` @ `0x118/11C`, doorbell bit[31]=fetch → `ai_desc_fetch_smoke`);
**I1-lite GEMM** (`ai_gemm_s8_smoke` — 2×2×2 int8 golden). Spine tests use
`OP_LAYOUT` so they do not exercise compute.  
Sideband protocol: after any desc/region MMIO write, load a **different** island
reg before `ai.enq` (same-addr load-back can STLF; kick is a core wire).

## Ordering

1. **P3 spine** — descriptor engine + per-queue address check (**done**).
2. **AXI attach + PLIC-8 + DMA desc fetch** (**done**).
3. **I1-lite** — sequential GEMM over AXI (**done**); full PE cluster next.
4. **I3** — memory system measured.
5. **I2** — N clusters (must not change latency-SKU results).

## Licensing

Tier **R** (`CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial`). Do not place NDA PDK
views here — they go under gitignored `pd/pdk/`.
