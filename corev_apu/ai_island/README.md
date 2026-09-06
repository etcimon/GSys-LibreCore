# `corev_apu/ai_island` — Xg6lcai island plane (P3+)

**Status:** P3/AXI integration and INT8/INT4 GEMM in the Variane AI testharness;
policy/FP compartments remain isolated; first policy consumer observable in
`g6lc_ai_island_top`; production SoC closure pending · **Tier R**
**Config:** `corev_apu/include/g6lc_ai_island_cfg_pkg.sv`

This directory is the **throughput / T2** plane of `Xg6lcai`, separate from the
core-attached T0/T1 datapath. Island geometry and capabilities come from the island
package; `CVA6Cfg.AiCfg` gates the optional attachment and development compartments.
See `architecture/ai-matrix/scaling-100tops.md` §3 and §8.

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
| `g6lc_ai_pe_dot.sv` | signed INT8/packed-INT4 dot-product reducer; accumulation owned by sequencer | **landed** |
| `g6lc_ai_gemm_seq.sv` | I1 GEMM: banked A/B + multi-bank C + dual-i32 store + PE | **landed** |
| `g6lc_ai_dram_timing.sv` | I3 island-DMA DDR4 page-command delay (Cas=0 bypass) | **landed** |
| `g6lc_ai_cpl_fifo.sv` | completion FIFO (DONE claim = pop head) | **landed** |
| `g6lc_ai_island_top.sv` | reg map + CPL FIFO + IRQ + fetch/store/gemm AXI mux | **landed** |
| `g6lc_ai_cluster.sv` | PE array + `tc_sram` + sequencer | I1 (next) |
| AXI/DMA master + xbar attach | fabric citizen | **wired** (`NrSlaves=3`, slave[2]) |
| `include/g6lc_ai_policy_pkg.sv`, `g6lc_ai_policy_codec.sv` | frozen eight-state policy, hysteresis and successor hints | **verified compartment**, instantiated by `g6lc_ai_island_top`; no traversal control yet |
| `g6lc_ai_policy_steer.sv` | format-aware benefit gate and fixed-budget topology | **verified compartment**, first consumer is an observable island PMU at `0x0190..0x019C`; no GEMM traversal change |
| `include/g6lc_ai_fp_pkg.sv`, `g6lc_ai_fp_mac.sv` | exact widening and separate FP32 RNE multiply/add | **verified scalar primitive**, not integrated floating GEMM |
| `include/g6lc_ai_fp_pkg.sv`, `g6lc_ai_pe_dot_float.sv` | FP8/FP16/BF16/FP32 block-floating dot product with 640-bit reduction and RNE FP32 conversion | **verified Lanes=4/8 unit and GEMM integration**: combinational `pe_dot_float` 5,018 checks; pipelined `pe_dot_float_pipe` 5,028 checks for Lanes=4 and Lanes=8 (back-to-back different `numfmt`/data, half/alt valid masks) with Verilator; Yosys `read_slang`, `check -assert`, `synth -noabc -top g6lc_ai_pe_dot_float -flatten` and `synth -noabc -top g6lc_ai_pe_dot_float_pipe -flatten` all report zero problems. Mantissa product is explicitly 24×24; pipelined dot-pipe generic cells are ~115k (Lanes=4). Pipelined dot is integrated into `g6lc_ai_gemm_seq` behind `DotPipeFloat` and passes `run-gemm-backend.sh` nch={1,2,4,8} `dpf=0,1` across INT4/INT8/FP8/FP16/BF16/FP32; Lanes=256 / timing / full SoC next |

Capability window (`AiIslandLatencyDefault`) advertises **MacsPerCycle=256**,
**AccTileM/N/K=256** (SKU AccTile* live; 1 MAC cycle per C). C multi-banked
(`j % PeLanes`) → each `tc_sram` is `MaxDim*1` words (256xi32 @256/256).
I3-lite: B oct-drain + multi-beat AR/AW + dual-bank C-read + trail C-store
during MAC + **multi-outstanding AR (`MaxAROut=2`, CAP `0x40`)** + PMU @0x180;
CAP DRAM; NoC 64b. **DramClass=0** (testharness SRAM via xbar slave[2] →
`g6lc_ai_dram_backend`); nameplate **8 GB/s**. 256³ directed: **83,705 cy**
(zero-latency TB). **DRAM I3** (`DramClass=1` LiteDRAM, package
`AiIslandDdr4Bringup` nameplate 19 GB/s / `MaxAROut=8`) is not instantiated —
the class-1 generate `$error`s rather than silently using SRAM. Island-DMA
CAP `0x48` `DRAM_STATUS`: bit0 `init_done` (class 0 = 1), bit1 `timing_en`.
SoC occupancy (cores + L2 + island) is CAP `0x50`/`0x70` (`CAP_OFF_DRAM_CH_{R,W}`);
GEMM PMU at `0x18`/`0x2C`/`0x180` stays aggregate.
DRAM **channel count** (`DramChannels` 1/2/4/8) is a **SoC DRAM-slave** knob
(cores + L2 + `NrCores` + island DMA share `g6lc_ai_dram_backend`). Each class-1
channel is one LiteDRAM `--sim` core, striped at `DramChanShift` (default 6).
Class 0 N>1 uses the same demux with SRAM (`G6LC_AI_DRAM_SIM_CHANS_2`). GEMM
INCR is capped to the stripe when N>1 so it cannot disagree with L2 fills.
Nameplate is `N × 19` GB/s on class 1. Live N=1. `g6lc_ai_dram_timing` is a page-command delay (live Cas=0 bypass). Opt-in
`+define+G6LC_AI_DRAM_TIMING` selects `AiIslandDdr4TimingSim` (class 0, Cas=14,
MaxAROut=8) — still SRAM backing, still 8 GB/s nameplate, not LiteDRAM. Do not
start I2 on this fixture. F12 tiling: `ai_gemm_tile_2x2_smoke`.

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
# Host package lab bridge (soft / hard):
bash monorepo-soak/run-ai-tensor.sh rtl
bash monorepo-soak/run-ai-tensor-rtl-hard.sh  # mmio + gemm_s8 on work-ver-ai
```

Standalone smoke: cap, good desc, AI-3 OOR/perm, bad version, disabled, CPL FIFO multi-claim — all PASS.  
SoC: MMIO doorbell + AI-3; sideband enq/poll; **PLIC-8 IRQ**; **DMA desc fetch + ptr_done write**; **policy PMU DMA smoke**
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

## Policy codec development compartment

`include/g6lc_ai_policy_pkg.sv` and `g6lc_ai_policy_codec.sv` implement the
GSys LibreCore frozen eight-class policy encoder, hysteretic commit, current and
repeat/successor decode, and discardable address/bank hints. The control gate is
`CVA6Cfg.AiCfg.PolicyCodecEn` (all production targets off); the independent
verification wrapper enables it. **Instantiated in `g6lc_ai_island_top` as an
observable-only PMU consumer** (sticky policy words at `0x0190..0x019C`), but not
yet steering the GEMM datapath. It is not a Desc64/QoS/ISA change or a measured
throughput improvement.

`g6lc_ai_policy_steer.sv` adds the default-off `AiCfg.PolicyBenefitEn` wrapper:
native-format zero metadata, format epochs, full 16-bit retained `m/n/k` metadata,
and a benefit-gated balanced row/column/reduction allocation using
`(m+n)*rowbytes(active_k) >= read_bytes` as the refinement guard. INT4/INT8/FP8/
FP16/BF16/FP32 scheduling support is not an arithmetic capability grant; no
floating-point skip or silent format conversion is permitted. The efficiency
suite checks an equal-resource ticking scheduling model and emits per-format,
per-state and balanced-mix percentages in `steering-*/efficiency.json`, including
negative results and a best-fixed-code comparator. None are production speedups.

`g6lc_ai_policy_subcode.sv` adds a separately gated `AiCfg.PolicySubcodeEn`
shadow evaluator in steering: eight candidates per bulk/decode/routed/sparse
class, a 3-bit candidate index, format service/reduction parameters and four
registered stages per candidate. It cancels on newer metadata and publishes
separate result/cost observation ports; it does not replace the primary topology
or feed the live GEMM. Defaults remain off, and no numerical or MMIO ABI changes.
`python verif/regress/ai-policy-subcode.py --parameters extremes` runs the remote
scoreboard plus steering equivalence and explicit MAC/cycle comparisons.
`--synth-only --yosys <existing-yosys> --formal required` runs local generic
synthesis and fixed-fixture bounded control checks only. Named tile fixtures
currently show no incremental improvement over the existing allocator after
charging the 32-cycle evaluation tax; see §11.6 before enabling or promoting it.
The optional `PolicySubcodeCacheEn` exact-result cache reduces a completed-key
repeat to one cycle; misses remain 32 cycles and batch/format epochs flush reuse.
It adds no group-policy mux, arithmetic or address-generation behavior. Generic
cache off/on results are 4,880/5,473 cells and 340/342 sequential cells, zero
latches, with scoped cache-control proof and hit reachability through 72 steps.
This is evaluator latency evidence, not measured GEMM throughput.
`policy_motifs.py` analyzes ordered host captures and exports nested parameter
proposals with warm-up and paired-evidence rejection windows. Structural motif
matches never replace exact topology/format guards or authorize sparse skips.
Current held-out template coverage is low and no real array timing was supplied;
see architecture §11.9. All production gates stay off.

Architecture and integration contract: `architecture/ai-matrix/README.md` §10–§11.
Verification: `bun build-platform/src/cli/index.ts test ai-policy-codec` uses the
remote proxy. For local synthesis only (never local Verilator), use
`python verif/regress/ai-policy-codec.py --synth-only --yosys <existing-yosys>`;
this checks enabled/disabled synthesis and 12-step bounded safety with reachable
events. A live Verilator DMA smoke, `verif/regress/ai-island-dma.sh`, fetches a v2
GEMM descriptor into `g6lc_ai_island_top` with `EnableDmaFetch=1` and policy
enabled, then checks that the sticky policy PMU words at `0x0190..0x019C` are
non-zero after a successful `ST_OK` completion. Numerical tests use a software
tuple consumer, not the live array.

## Native formats and floating arithmetic status

The live island advertises **INT8 and INT4 only**: `AiIslandDtypeMask` and
`AiIslandPeImplMask` remain `16'h0003`. Descriptor v2 uses A `[m][k]`, B `[n][k]`,
and element-count K strides, with per-row byte rounding for packed INT4.
`DESC_B_K_MAJOR` publishes the layout for model ingestion. Native T2 arithmetic
is signed and overwrite-only; unsupported dtype/accmode/EW/sparse combinations
return `ST_BAD_FMT`. Legacy INT/EW1 resolves to INT4 for both the grant check and
GEMM handoff. This changes neither the descriptor size nor the raw format field.

The optional `AiCfg.IslandFpEn` scalar primitive widens FP8 E4M3/E5M2, FP16, BF16
or FP32, then performs separate FP32 RNE MUL and ADD. It preserves subnormals and
signed zero, reports local exception flags, holds responses under backpressure,
and cancels work on reset/flush/disable. It is **off by default** and does not
connect floating operands to the live integer GEMM reducer or expand any grant.

A standalone FP dot-product primitive, `g6lc_ai_pe_dot_float`, is verified at
`Lanes=4` with 5,018 Verilator checks against a `double` oracle. It decodes
FP8 E4M3/E5M2, FP16, BF16 and FP32, forms per-lane products, aligns to a common
block exponent, reduces in a 640-bit balanced tree and converts to RNE FP32 once.
A pipelined variant, `g6lc_ai_pe_dot_float_pipe`, issues one dot per cycle and
passes 5,028 checks for `Lanes=4` and `Lanes=8` including back-to-back issue with
different `numfmt`/data and half/alternating valid masks. The pipelined dot is
integrated into `g6lc_ai_gemm_seq` behind `DotPipeFloat` and `run-gemm-backend.sh`
passes for nch={1,2,4,8} with `dpf=0,1` across INT4/INT8/FP8/FP16/BF16/FP32.
Yosys `read_slang`, `check -assert` and `synth -top g6lc_ai_pe_dot_float -flatten`
all report zero problems. It does not change the live `AiIslandDtypeMask` /
`AiIslandPeImplMask` by default; it is not floating GEMM production support or
ISA F/D conformance.

| Pipeline registers | Accepted request to visible result | Scalar initiation interval |
|---|---:|---:|
| 1 | 4 cycles | 6 cycles |
| 2 | 6 cycles | 8 cycles |
| 3 (default) | 8 cycles | 10 cycles |
| 5 | 12 cycles | 14 cycles |

Remote arithmetic/flag tests pass all four variants, including 141,587 widening
probes per variant. Isolated synthesis reports zero latches and a zero-cell
disabled implementation; bounded control/widening checks are not PDK timing or
DFT sign-off. The default is one **scalar** MAC per ten cycles, not the full-array
service rate used by the policy scheduling model.

## Optimization path and next integration gates

1. **Native correctness first — available.** Independent ai-tensor and B3
   descriptor execution compare packed descriptors and C32 bytes. Live grants
   execute 16 of 84 jobs and reject 68; the named software-only `0x00fb` fixture
   executes 82 and rejects two. This is not a QEMU guest or RTL datapath run.
2. **Policy evaluation — available in isolation.** Closed, validated traces of
   successful jobs feed the remote RTL policy wrapper. Samples carry no exact-zero
   proof; no DMA address hint is materialized. Per-format/code usage and signed
   cycle-model comparisons remain explicitly labeled future-array hypotheses.
3. **Guarded integer consumer — in progress.** Metadata is produced from the
   descriptor/GEMM job (m/n/k/numfmt) in `g6lc_ai_island_top`; the first consumer
   is the observable island PMU (`0x0190..0x019C`) with per-context `gemm_err` flush
   and format-known gating. Tile/order/bank/prefetch consumers remain open;
   preserve dense fallback, tail/storage/address guards and precise completions;
   prove each consumer separately before reporting application rates.
4. **Floating GEMM — open.** Integrate native byte gathering, scalar or replicated
   arithmetic, ordered accumulation and C32 stores. Test real memory stalls and
   rejected formats end to end before changing capability/implementation masks.
5. **Measured optimization — open.** Compare identical work and formats on the
   integrated RTL, including switching/misprediction tax, contention and held-out
   framework traces. I3 memory characterization remains ahead of I2 clustering.
   DFT/testmode semantics, PDK STA, physical area/power and full compliance remain gates.

From the repository root, the optional registered suites are:

```text
bun build-platform/src/cli/index.ts test ai-policy-codec
bun build-platform/src/cli/index.ts test ai-desc-formats
bun build-platform/src/cli/index.ts test ai-fp-mac
bun build-platform/src/cli/index.ts test ai-native-eval
bash verif/regress/ai-island-dma.sh
python verif/regress/ai-native-eval.py --binary <host-native-g6lc-qemu> --replay-policy
```

The first three use the remote testharness proxy; the native evaluator requires a
binary built for its executing host (Linux for the WSL regression engine).
Descriptor-mode coverage exercises 3,072 helper combinations and 1,024 engine
cases, including refusal and effective-format handoff. Full architecture,
metric definitions and reproduction details are in
[`architecture/ai-matrix/README.md`](../../architecture/ai-matrix/README.md) §10–§12.
Existing full-core synthesis and branding failures remain tracked in `AGENTS-todo.md`;
these compartment results do not waive them.

## Licensing

Tier **R** (`CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial`). Do not place NDA PDK
views here — they go under gitignored `pd/pdk/`.
