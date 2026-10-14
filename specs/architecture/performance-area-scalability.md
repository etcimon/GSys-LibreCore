# Performance, area and scalability — the program that follows correctness

Companion to the `cts-*.md` cards. Each card's `COST` line names what a throughput change
touches and its `FORBIDS` line bounds what the change may do; this file defines how the
APU's geometry is chosen: **measure the serial engine on checked work, parameterize before
scaling, scale only behind the CTS fence.** Method: `AGENTS-coding-philosophy.md` §2.1
(correctness before performance, never silently traded), §2.2/§3 (timing first-class, the
timing-impact note), §2.3 (configuration seams), and `AGENTS-rt-learning-philosophy-AGI.md`
RT-T5 (compare local and aggregate benefit on fixed checked work), RT-P8 (a capability
claim needs an external test and a retained baseline), CTS-P3 (reorder, never drop).

## 1. What "correctness-preserving" means here

A performance change is admissible when, on the same configuration product:

1. every CTS caselist that was green stays green (the ledger diff is empty in the
   `fail/crash/timeout/other` columns) — including the *fails-if-removed controls*:
   `memory.pipeline_barrier.*`, `synchronization.op.single_queue.*`,
   `memory_model.message_passing.core11.*`, `fragment_operations.*`, `reconvergence.*`
   once advertised;
2. engine Gate 1 (RTL ≡ model) stays bit-exact for every shader vector at every lane/
   wave geometry variant (the model has no geometry — that is the point);
3. no card's `FORBIDS` line is crossed (value-based suppression, test-shape special cases,
   dropped required work, ordering points moved);
4. the checked work is identical: same number of invocations, samples, texels, atomics
   (the pipeline-statistics counters of §2 make this auditable).

A change that improves a component metric by removing work the spec requires is a
regression, not an optimization (RT-T5: what work moved elsewhere or disappeared?).

## 2. Instrumentation first (plan W1.5): counters that make the roofline measurable

Low-cost, PMU-style counters behind one `ApuCfg.PerfCountersEn` knob (default on in
development presets, off in minimal), read through the profile-ROM-adjacent debug window
(dev-only) and, where a Vulkan query type exists, through it (pipeline statistics,
timestamps — QP-L2/L3):

| counter | unit | what it bounds |
|---|---|---|
| `sh_issue`, `sh_stall_{lsu,fpu,sfu,tex,barrier,sched}` | per core, per cycle | instruction issue rate and the dominant stall (W3.3 target: 1 issue/cycle for eligible ops) |
| `sh_lanes_active / sh_lanes_issued` | per wave | divergence loss (§7c) |
| `rf_bank_conflicts` | per core | RF banking need (W3.3) |
| `lsu_req`, `lsu_bytes`, `lsu_coalesced`, `lsu_wait_cycles` | per core | memory concurrency (W5.1) |
| `tex_req`, `tex_texels`, `tex_cache_hit/miss`, `tex_wait` | per sampler | texel rate and cache sizing (TEX, PIPE-L1) |
| `desc_fetch`, `desc_cache_hit/miss` | per core | descriptor path (BM-L1) |
| `rast_prims_in/culled/clipped`, `rast_quads`, `rast_frags`, `rast_helper_frags`, `rast_early_z_kill`, `rast_setup_cycles`, `rast_scan_cycles` | per draw | pixel pipeline (RAST, DRAW) |
| `rop_writes`, `rop_blend`, `rop_depth_rw` | per draw | ROP and tile-buffer need (§9) |
| `xfer_bytes_rd/wr`, `xfer_beats`, `xfer_wait` | per engine | copy/clear bandwidth (API-L5) |
| `apmem_outstanding_max`, `apmem_wait`, `axi_rd/wr_bytes` | per adapter | fabric concurrency (W5.1) |
| `cmd_records`, `cmd_submit_latency`, `fence_latency`, `ring_poll_cycles` | per queue | CPU-side submission cost and control-plane overhead (W2) |
| `wave_switches`, `park_cycles` | per core | scheduling (W3.6) |

Counters are *not* performance claims; they are the denominators RT-T5 asks for.

## 3. Baseline (plan W1.6 first half): the serial engine on checked work

Before any geometry change, record on the current engine (one core, 8 lanes, one LSU,
serial sampler, micro-sequenced rast):

- the CTS families that run (ledger) with wall time per case class, and the counter
  dump per class — `compute.pipeline.basic`, `glsl.operator/builtin`, `texture.filtering.2d`,
  `pipeline.monolithic.{blend,depth,stencil,sampler}`, `draw.renderpass.*`,
  `api.copy_and_blit.core.*` are the representative classes;
- the engine vectors' cycle counts (already recorded per session: e.g. `ue_gpos_tri_1`
  286 k cycles, `loopfor_1` 34,694, `barrier_reduce_1` 63,576) — these become the frozen
  baseline numbers;
- the guest scenes' wall time per scene (vkcmp table) with the counters.

The baseline is frozen in `architecture/uncore/apu-cts-ledger.md`'s companion
`apu-perf-baseline.json` (generated; never hand-edited) with source identity, so later
comparisons are against a recorded artefact (RT-P8: retain a baseline; RT-P7: versioned).

## 4. Parameterize before scaling (plan W1.3/W1.4)

Every card's knob is a configuration variable before it is a bigger number:

| area | knobs (card) | legality/derivation |
|---|---|---|
| Shader | `ShaderCores`, `Lanes` (physical), `MaxWaves`, `RfBanks`, `RfBytes`, issue width, `SfuUnits`, `SlabBytes`, `ScratchBytes`, `CallDepth`, `CfDepth` (COMPUTE, GLSL, SG) | advertised limits derive from the elaborated values (`maxComputeWorkGroupInvocations = Lanes × MaxWaves_per_wg`, subgroup size, shared memory) — never typed in the TOML independently |
| Descriptors/objects | `MaxSets`, binding rows, `ShaderSlots`, `CbBufs`, ObjTab slots/directory, private arena bytes, descriptor page granularity (API-L2, BM-L3, CTS-P2) | after G3b they are cache sizes; `maxBoundDescriptorSets` etc. follow |
| Texture | `TexCacheLines`, associativity, sampler units, `MaxAniso`, BC decoder presence (TEX, PIPE-L1) | `samplerAnisotropy`/`textureCompressionBC` follow the elaborated units |
| Raster/ROP | `VsBatch`, `FsBatch`, setup units, tile size, tile MRT/sample capacity, bin budget, ROP lanes, `MaxSamples` (RAST, PIPE-L4, RP, §9) | `framebuffer*SampleCounts`, `maxColorAttachments`, `maxFramebuffer*` follow |
| Memory | aperture bytes, page size, `MaxOut` per adapter, burst length, MSHRs, `DramChannels`, L2 geometry (MEM, API-L5, W5) | heap sizes follow |
| Scheduling | queues, in-flight batches, park depth, preemption state (SYNC, W8.7) | queue family properties follow |

Rule: a knob's legal range is checked in `apu_cfg_legal`; the profile generator reads the
elaborated SKU (plan W1.4) so TOML and SV cannot disagree.

## 5. Scale behind the fence (plan W1.6 second half, W3.3, W4.5, W5)

Order, each step a Pareto comparison at equal budget with §1's admissibility and §3's
baseline:

1. **Shader issue** — scheduler/scoreboard, banked RF, pipelined ALU, shared SFU
   (W3.3): the `glsl`/`compute` families are the checked work; Gate 1 across geometries
   is the equivalence proof; measure `sh_issue` and stalls.
2. **Memory concurrency** — coalescing LSU, multiple outstanding, descriptor/UBO
   broadcast (W3.3/W5.1): `memory.*`, `ssbo/ubo`, `memory_model.core11` are the fence;
   per-lane bounds and atomic serialization are kept (ROB, IMG-L2).
3. **Texel path** — quad-parallel sampler, larger texel cache, BC decode on miss, format
   decoders shared with Xfer (W4.5): `texture.*`, `pipeline.monolithic.sampler/image` are
   the fence; λ precision truthfully advertised (TEX-X2).
4. **Pixel pipeline** — stamp rasterizer, parallel setup, vertex-fetch streams, then the
   tile engine of §9 with per-pixel primitive order (CTS-P3, W8-H1 — the one mechanism
   that also serves interlock, ordered attachment access and VRS replication), DONT_CARE
   elision, BY_REGION subpass merging: `draw`, `rasterization`, `fragment_operations`,
   `renderpasses`, `pipeline.*.{blend,depth,stencil,multisample}` are the fence.
5. **Cores and queues** — `ShaderCores > 1` via the cluster-dispatch pattern (§12.2),
   async queues (W8.7), L2/L3 (W5.6) with the ordering-point map (MM-L1): `synchronization`,
   `memory_model.ext`, `subgroups`, `reconvergence` are the fence.
6. **Discretionary engines** — ray tracing (RT), mesh/VRS/interlock/barycentrics (W8),
   sparse/VM (SPARSE), matrix helper (W6): each with its own card families as the
   fence and its own equal-budget comparison (plan W1.6: "preserve Pareto alternatives
   until the graphics process/power/bandwidth budget is approved").

No FPS claim follows from FMA count (plan F7). The SKU is selected from measured points
on real workloads (UE/CS2 captures, plan E) with the full release profile enabled.

## 6. Area and timing accounting

Per step: the synth screens already in the runner (Enable=0 inert / Enable=1 cells, FFs,
latches per engine; retained `$mem_v2` for SRAM macros) extended with the structural
FO4 soak (`AGENTS-coding-philosophy.md` §2.8) on the touched module, and a timing-impact
note (§3.7) in the increment record. Memory macros are counted as bits in `tc_sram`, not
as flop-mapped cells. Power: clock-gate every engine's idle state (`tc_clk_gating`) and
report toggle-rate proxies from the counters; a dedicated power model is a later gate.

## 7. Status

2026-10-14: no counters yet beyond the shwave `insns/wsw/robust` statistics and the
`vkcmp` wall times; the serial-engine numbers in the increment records are the only
baseline. First actions: §2 counters behind `PerfCountersEn` (with their own Enable=0
inertness screen), the §3 baseline capture on the CTS-1 caselists once they run, and the
§4 knob audit (which "constants" in the packages are really configuration).
