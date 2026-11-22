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

2026-11-12: wave-engine counters exist (`g6lc_apu_shwave.perf_o`: texture, arithmetic-unit
and load/store cycles, memory requests, instructions, busy cycles) and the bench prints
them. The rasteriser has `stat_o` and `qry_stat_o`. Seven control-path changes took the
516-case suite from 5,839,342 to 5,022,047 cycles (−14.0%) with identical results. Not
done: the counters are not readable at device level (`g6lc_apu_shcore` leaves `perf_o`
open; `g6lc_apu_vgtop` builds the core with `PerfCountersEn = 0` and leaves the
rasteriser's `stat_o` open), and `apu-perf-baseline.json` (§3) has never been generated.
§8 is the program from here.

2026-11-13: TP0 and FP0 are done as bench-read counters (§11.1): the wave-engine classes
are corrected, the rasteriser has stage classes, `g6lc_apu_vgtop` has engine and
memory-port counters behind `PerfCountersEn`, and the origin capture
`verif/tb/apu/apu-perf-baseline.json` exists with a one-command gate
(`run-apu-perf.sh`). Exposure of the counters to software (a device register block) is
still open. The first admitted passes and the execution order are in §11; where §11
differs from the order in §8.2 or §9.4, §11 is current.

2026-11-13 (later): every simulation and synthesis run moved to the remote testharness
(§11.8). The loop is the `perf` stage of `run-apu-regress.sh`; the decoded-row cache
(SP1) is admitted from a remote capture on the pinned compiler.

2026-11-15: evidence review. The last remote leaf before today was
`apu-leaf-20261114T112821-7d61c828d186`; eighteen APU RTL commits followed it with local
evidence only (rasteriser FP0e and FP0f, the five RP3 fusions, the storage re-banking of
TP3a-1, the second register-file port of TP3a-2). Leaf
`apu-leaf-20261115T060601-bec7c93d610b` (`unit,top,perf`, snapshot of `c6cf6705b`) covers
them. At the time of writing: unit stage 17 of 17 suites with exit code 0, `vgtop` exit
code 0, both control arms pass, the shader suite is cycle-identical, and every graphics
session of the loop checks the same work in fewer cycles than the admitted capture
(deriv2 −45.1%, inst −34.7%, persp −22.2%, tri −20.0%, blend −19.2%, dtest −19.0%,
mrt4 −8.5%, line −0.8%). `vgsys` was still running. The loop itself exits 1 on that leaf:
its `rast` run compares the 42-case origin cohort with a bench that had grown to 56
cases, so it reports a work difference, not a regression. The bench now takes
`+perf_cohort` (origin cases only) and `run-apu-perf.sh` passes it; locally the cohort
checks the capture's exact work (42 cases, 15,605 checks, 159,527 port requests,
564,743 float jobs) in 1,066,697 cycles against 1,397,345 admitted (−23.7%). Nothing is
admitted until a leaf on the current tree reports it.

2026-11-15 (later): admitted. Leaf `apu-leaf-20261115T091322-cf0d5473a41a` (snapshot of
`a7b895783`: the fusions, the three rasteriser fixes and the cohort switch) ran the loop
to "OK same checked work; no cycle regression", and its capture is now
`apu-perf-current.json`. Against the previous admitted state: rasteriser cohort
1,397,345 → 1,066,697 cycles (−23.7%; −70.8% from the origin), the fourteen graphics
sessions 3,238,455 → 2,501,368 cycles in total (−22.8%), shader suite unchanged at
3,666,123. On that leaf the unit stage (17 suites) and `vgtop` exit 0. `vgsys` did not
finish on either leaf: it stopped at the 7,200 s suite limit with 235 of 240 sessions
passed and none failed (218 on the first leaf), on a builder shared with other jobs.
That is an incomplete run, not a pass and not a failure. With `--suite-timeout 14400`
leaf `apu-leaf-20261115T130136-4f069406f630` (snapshot of `14e2e0f96`, the
depth-stencil clear tree) completed: `APU-REGRESS PASS` for `unit,top` — 17 unit
suites, `vgtop`, `vgsys` (7,611 s) and `sys-venus` all exit 0. That is the first
complete `vgsys` run on the trees of this review.

The same review found three rasteriser defects by reading the RTL against the model and
the specification. Each was reproduced by a failing bench case before the fix (commits
`913238cb2`, `4b59ae70d`; local evidence until the next leaf):

| Defect | Effect | Why no vector saw it |
|---|---|---|
| The colour write mask was used directly as byte strobes | On B8G8R8A8 an R-only mask wrote the B byte and a B-only mask the R byte | the one masked device vector uses RGB (R/B symmetric); the model maps mask bits to channel bytes |
| The UNORM16 scale constant was `32'h38008001` (1/32640) instead of `32'h37800080` (1/65535), at four sites | sRGB destination decode for blending, UNORM16 vertex attributes and D16 depth readback (early and late) were about 2.008 times too large | vertex cases fed 65535 only, which clamps; no bench case used D16 depth or blended on sRGB, and the model refuses blend on sRGB |
| `VkLogicOp` was applied to every colour format | sRGB attachments got the logic op instead of the plain source colour | the model refuses logic op on sRGB; the bench only used UNORM |

The method (read one engine's datapath against the model's handling of the same field,
then look for inputs the vectors never use) is cheap. It applies unchanged to the
transfer engine, the sampler and the vertex fetch.

## 8. Throughput closure program (2026-11-12)

Written from the RTL at HEAD `f694ad11a` plus the working tree, and from the counter
numbers in `release-contract-architecture.md` §4. Nothing in this section has been built or
run. Line numbers are as read on that date and will drift. Every gain below is a projection
from five bench vectors on one 8-lane core; each is to be replaced by a counter delta when
its pass lands. All figures are per clock. No frequency or frame-rate claim follows.

### 8.1 Where the cycles go today

One instruction of one wave, traced through `g6lc_apu_shwave.sv` for a two-operand
register op such as `OpFAdd` (word count 5):

| Phase | States | Cycles |
|---|---|---:|
| Wave pick | `W_SCHED` (8093) | 1 |
| Opcode word | `W_F0`, `W_F1` (3564) | 2 |
| Operand words, one per cycle | `W_LD0`, `W_LD1` × 4 (3580) | 5 |
| Result type row | `W_TY0A`, then `W_TY0`/`W_TY1` unless the type repeats (3590) | 1–3 |
| Operand id → register row, then the row itself | `W_RMI`, (`W_RMC`, `W_RV0`, `W_RV1`) per operand (3632) | 8 |
| Result id → register row, pre-execute | `W_RW1`, `W_PRE` (3643, 3693) | 2 |
| Execute | `W_EX`, `W_FU0`, `W_FU1` (3752, 4998) | 3 |
| Retire | `W_WB`, `W_NEXT` (7639, 8128) | 2 |
| **Total** | | **24–26** |

Fourteen to sixteen of those cycles re-derive facts that are constant for the module: the
opcode and operand words, the result type, and which register row each id maps to. Five
more are the wave pick and the two register-file reads. The 32 FMAs are busy for one cycle.
This matches the measured fixed cost of 20–25 cycles per instruction.

One device-memory word costs `W_LS0` → (`W_DS0` on a new descriptor key) → `W_LSC` →
`W_LS1` → `W_LS2` (5446, 7038, 7065) per lane and per component, and each request then
crosses `g6lc_apu_apmem`, which is one global state machine: `StIdle` → `StRdIssue` →
`StRdR` → `StDone`, AXI ID 0, `len = 0`. That is at least four cycles per 8-byte beat with
an ideal slave, for every requester in the device together. Measured: 23 cycles per request
on `vec4arith_1`, and 25–59% of all cycles on the five vectors.

Other structural facts that bound the later passes:

- The scheduler returns to `W_SCHED` after every instruction and round-robins the waves at
  instruction granularity. The reference model runs each invocation sequentially to the
  next barrier, so this interleaving is not required for results.
- The register file is `MaxWaves × ShaderRegs` rows of `ShaderLanes × ShaderVec × 32` bits:
  16,384 × 1,024 b = 2 MiB per core at the `vgtop` defaults, as two single-port
  `tc_sram` halves (2067). `g6lc_apu_shmod` holds about 1.2 MiB more per 8 slots, in tables
  8,192 and 65,536 words deep and up to 512 bits wide (965–1013). Both are outside the SRAM
  envelope in `AGENTS-configuration.md` (single-port, depth 64–4096, width 32–128, read
  pipelined over at least two cycles at 8 FO4; dual-port only for the register file).
- Graphics waves exchange VS-in, VS-out, FS-in and FS-out records with the rasteriser
  through a 64 KiB scratch ring in DRAM (`APU_RAST_SCRATCH_BYTES`). The rasteriser writes
  it one beat at a time through `S_MPW` (two beats per attribute at `S_GA_W0`/`S_GA_W1`,
  1704); the wave engine reads it back word by word on the `ls_rec_q` path of the load/store
  unit. A 144-byte record is 18 beats each way.
- The rasteriser has one FMA, one divider and one converter (header, 46–61), and issues one
  vertex-shader invocation per index (`S_VS_ISS`, 1752). It has no post-transform reuse:
  the CTS grid draw of 50,784 indices over 8,649 vertices ran 50,784 invocations.
- `g6lc_apu_vgtop` instantiates one `g6lc_apu_shcore` (736). Raster and compute share it
  through one ownership mux (`rast_sh_own`, 766–773), and the descriptor sideband
  (about 5.3 kbit) is read live, not latched.

### 8.2 Passes

Order is fixed by dependency and by what one core can prove before it is replicated. Each
pass is admitted by §1 and carries the `AGENTS.md` §0.2 checklist; the notes below list
only what is specific to the pass.

**TP0 — baseline and counter completion (tooling plus small RTL; first).**
- Generate `architecture/uncore/apu-perf-baseline.json` from the bench `PERF` lines for all
  516 cases with source identity, and freeze it. Every later pass reports against it.
- Split the non-load/store time. Add a front-end class (`W_SCHED` through `W_PRE`), a
  descriptor-resolve class separate from the data access, and wait-for-ready versus
  wait-for-response on the memory port.
- Correct the existing classes: the load/store set omits `W_DS9`; the texture set omits
  `W_TXP`, `W_TXA2`–`W_TXA4`, `W_TXC0A`, `W_TXC1B`, the `W_TXL*` chain and the
  `W_TXJ*`/`W_TXS*`/`W_TXG*`/`W_TXQ0`/`W_TXQ1` tails (777–796).
- Add a classify-only counter that changes no behaviour: per load or store instruction,
  whether all active lanes carry the same pointer, a constant stride, or neither. This is
  the eligible share that sizes TP2 and is unknown today.
- Wire `perf_o` and `stat_o` through `shcore` and `vgtop` to the dev-only debug window, and
  add per-port accepted-request and wait counters in `apmem`. Move `PerfCountersEn` from
  per-module parameters into `apu_cfg_t` with a legality check, as §2 intended.
- Check: `PerfCountersEn = 0` netlists unchanged; bench results unchanged.

**TP1 — predecoded instruction rows (multiplier M1).**
- `g6lc_apu_shmod` gains a predecode step after `S_RES` (2318) that writes one row per
  instruction into a new `tc_sram`: opcode class, result register row, result type shape
  (the fields `W_TY1` captures), operand count, and per operand the tag, register row,
  component count and type id that `W_RMC` reads today, plus the operand type that `W_PRE`
  fetches for the opcodes that need it.
- `g6lc_apu_shwave` replaces `W_F0` … `W_PRE` with a row read for row-eligible
  instructions. Instructions that do not fit the row (long access chains, composite
  construct, calls, phi, switch, extended-instruction sequences) set a long-form flag and
  keep the present word walk. The retained walk is also the differential control: a
  parameter selects it for the whole module.
- The row format is a generated column of `tools/shader/sh_opcodes.py`
  (`gen_sh_opcodes.py` emits the package), and `spirv_scan.py` builds the same rows so
  the `shmod` bench compares them table for table, as it does every other table.
- Size the row at 256 bits or less and the store at 4,096 rows per bank or less, so it is
  two 128-bit macros inside the SRAM envelope. Treat the read as two cycles and prefetch
  the next sequential row during execute.
- Fold the wave pick and the program-counter advance into the retire cycle, and run a wave
  until it reaches a barrier, its end, or a quantum (TP1b). The bench's "every multi-wave
  case switches" check has to be restated as "switches at a barrier"; the atomic vectors
  are the fails-if-wrong control for the reordering.
- Expected: 7–10 cycles for a simple instruction against 24–26 today, still serial (row
  read, two register-file reads, execute, write-back). The projection table in §8.3 uses
  14 cycles saved per instruction, which gives 1.2–2.1× on the five vectors.
- Area: a new store of `ShaderSlots × rows × 256` bits (512 KiB at 8 × 2,048) against a
  smaller control cone. Record both from a synthesis leaf; the staged `area-attr.sh` run
  is the baseline.

**TP2 — lane-vector memory and a concurrent memory port (M2, first step of M6).**
- Wave engine: before `W_LS0`, classify the active lanes' pointers. Same pointer (uniform
  buffers, push constants): one access, broadcast. Constant contiguous stride: one burst.
  Otherwise the present per-lane path.
- Bounds stay exact. Check the whole range once; if any word is out of range, take the
  per-lane path so the robust-access count and the zero/dropped results are unchanged.
  A per-lane dynamic descriptor index also takes the per-lane path.
- `apu_mp_req_t` (`g6lc_apu_mp_pkg.sv`) gains a beat count; a burst returns one response
  per beat with a last flag. Requesters that leave it zero see today's behaviour.
- `g6lc_apu_apmem` becomes one transaction slot per port with AXI ID = port index
  (`apu_dma_id_t` is 4 bits and there are 8 ports). The per-port contract — at most one
  outstanding, exactly one response per request, flush drops only unissued requests — is
  unchanged; only the global serialisation goes. Register the window classification, which
  is combinational on the request today.
- The same burst serves the 64-byte texel-cache fill (eight single beats in
  `W_TXF0`/`W_TXF1` today), the four-beat descriptor-record fetch (`W_DS1` onward), and the
  object-table cache fills.
- Downstream of the port: `g6lc_apu_tdma`, the bench AXI slave models, the bridge DRAM
  model and the testharness join must accept several outstanding IDs.
- Ordering argument to prove, not assume: order within a port is kept; the used-ring
  publication chain is on one port; work completion precedes the fence by state-machine
  sequencing, not by arbitration. The existing address-channel order checks in the
  `sys-venus` and `cva6-venus` benches and `memory.pipeline_barrier.*` are the controls.
- Expected: the memory share divided by about 8 on eligible accesses. With TP1, up to
  2.8–3.9× on the five vectors if every access is eligible; TP0's counter replaces that
  assumption.

**TP3 — pipelined issue (plan W3.3).** Needs TP1.
- Stages: row read, operand read, execute, write-back, with a write-back-to-operand
  forward and a stall for multi-cycle units. In order, single issue; no scoreboard beyond
  that until measured.
- TP3a, precondition: bring the register file inside the SRAM envelope and give it two
  read ports. Bank the 1,024-bit row into 128-bit macros and bound the depth with a new
  `RfRows` parameter. Rows in use are waves × the module's register count, which commit
  already knows. `maxComputeWorkGroupInvocations` and the fragment batch size are then
  derived from the elaborated depth (pattern CTS-P2), not typed in the profile.
- Dispatch on the row's opcode class replaces the `unique case (opc_q)` selection in
  `W_EX`. Whether the long micro-sequences (texture, transcendental, aggregate, matrix)
  move to a generated micro-code ROM is decided by the area attribution, not here.
- Target: 2–4 cycles per wave-instruction on arithmetic-bound vectors, i.e. 16–32 FP32
  operations per clock per core, a 25–50% duty on the FMAs against 1–4% today.
- **TP3a-3 design note (2026-11-15, measured).** The operand stream
  `W_LD0`/`W_LD1` is the largest per-instruction cost (~449k of 3.67M bench cycles,
  ~12%) and is **fetch-width-bound, not RF-latency-bound**: `prog_addr_o`/
  `prog_data_i` move one 32-bit program word per cycle and the operand-value RF read
  (`rf_addr={wave_q,oidx_q[rc_ik]}`) is already issued one stream-cycle early. The
  dual RF port (TP3a-2, landed + cycle-exact) therefore does not shorten the stream.
  `ops_q[]` raw operand words are consumed throughout execute, so the stream cannot
  be skipped even on a decoded-row-cache hit. Two levers: (a) wider fetch —
  `prog_data_i` 32→64 needs `i_prog` dual-read, but `i_prog` also serves shmod's own
  decode/validation reads so the port budget needs care; (b) **instruction-interleave
  decode-ahead** — a lookahead that runs fetch/decode/operand-prefetch ≥1 instruction
  ahead so N+1's operand stream overlaps N's execute, the real G-T2 lever. Phased:
  3a decode-ahead for the row-cache-hit path only (no operand prefetch, no hazard),
  3b RF port-1 operand prefetch into a shadow `va_q` + RAW check vs the retiring
  instruction's write rows, 3c wider fetch if still wanted. Hazards: same-wave RAW
  (N writes a reg N+1 reads → forward `wb_q` or stall), taken-branch invalidation of
  the shadow, multi-row write-back, row-cache writeback timing. Full analysis in
  `.cache/apu-perf/tp3a-brief.md` §5a/§7a. Row-cache *capacity* is not a lever:
  a `RowCacheEntries=4096` corpus arm saved only 1,536 of 3,666,123 cycles (0.04%)
  — the 61.5% hit rate is compulsory/conflict-bound, so 1024 stays. `W_IDLE`
  (~35% of cycles) is dispatch-bound and belongs to TP6/TP7 parallelism, not
  per-instruction pipelining.

**TP4 — on-chip record store for graphics waves.** Independent of TP1–TP3.
- Move the VS/FS record rings from the DRAM scratch ring to a `tc_sram` record store with
  a native port to the rasteriser and to the wave engine's record path. This removes two
  trips through the memory port per record word. The fragment side follows the same
  pattern (`S_F_W0`/`S_F_W1` and `S_F_VW0`/`S_F_VW1`, two beats per record slot; confirmed
  in §9).
- The relocation drain no longer has to cover the scratch ring. Scan and MBIST go through
  the `tc_sram` test path.

**TP5 — vertex reuse on indexed draws.**
- A direct-mapped post-transform cache keyed by vertex index (tags in SRAM, records in the
  record store), so the batch builder shades only missing indices.
- Design brief `.cache/apu-perf/tp5-brief.md` (2026-11-14, finalized): **scatter-v1** —
  the VS wave is dispatched unchanged on a dense `nmiss` batch (`gcnt=nmiss`, packed
  `vsi`/compacted `vso_c`); a rasteriser post-wave scatter writes each miss to its dense
  `vso[out_slot]` while cache hits copy the stored record to `vso[batch_pos]`.  This
  avoids any `shwave` change (the wave sees an ordinary dense batch).  Two traced facts
  shrink the work: (a) `VertexIndex`/`InstanceIndex` need **no** indirection — VS-in
  record slot 8 already carries the resolved index (`S_GA_S8A` writes `ib_i`; the wave
  reads builtins from slot 8 via LSU, `vbase+dense_inv` is only a fallback); (b) the
  64 KiB `isrec` carve is fully allocated to the six batch rings, so reuse records need
  **dedicated** cache SRAM (+~64-96 KiB tc_sram for 256-512 entries) plus a ~9 KiB
  compacted `vso_c` region, not the existing window.  `VtxCacheEntries` is a module
  parameter (Step-0 landed, `vgsys→vgtop→rast`, default 0 = bit-identical).
- Before enabling: read the 480 `query_pool.statistics_query.vertex_shader_invocations`
  cases for the invocation count they accept under reuse (dEQP source already traced:
  non-indexed `cmdDraw` + lower-bound check → reuse-safe).
- Expected on the CTS grid: 5.9× fewer vertex-shader invocations.

**TP6 — raster datapath width (M5).** After TP4.
- Detailed and superseded by §9 (passes FP5, FP6, FP8, FP10): stepped edge functions and
  span traversal, interpolation moved onto the shader core's lanes, a depth store, and a
  write-combining output merge.
- Control: pixel-exact against the present rasteriser on the twelve `vkcmp` scenes, then
  `rasterization.*` and `draw.*`.

**TP7 — shader cores (M4).** Needs TP1–TP3 measured on one core, and TP3a.
- Split `shcore` into one shared `shmod` and N wave engines. Give each engine a small row
  cache filled from the shared store through an arbitrated port; measure the row-reuse
  rate under TP0 first.
- A dispatcher after the pattern of `g6lc_ai_cluster_dispatch` (N engines, port-prefixed
  IDs, completion = all done, error = any). Units of work: a range of compute workgroups;
  a vertex batch; a fragment batch whose output merge commits in issue order (CTS-P3).
- `vgtop`: per-core ownership in place of `rast_sh_own`; the descriptor sideband latched
  per core at dispatch; the done queue sized from N; one memory port and one object-table
  requester per core, so `apu_dma_id_t` widens with the port count.
- `ShaderCores` defaults to 1. Advertised limits do not change with N.

**TP8 — fabric (M6 remainder).** DRAM channels, a data/texel cache behind the port, and
the shared L2 of plan W5 — when TP0's port counters show the port, not the core, as the
limit.

**TP9 — control plane.** The DRAM-backed object table costs about 3,000 cycles per host
command. Its cache-line fills become bursts under TP2; `cmd_submit_latency` from §2 is the
measure. This matters for CTS wall time on the `api` group, not for shading.

### 8.3 Projection and gates

Cycles per wave-instruction. "Non-memory" is total × (1 − load/store share) from the
counters. TP1 subtracts 14; TP2 divides the memory part by 8 and assumes every access is
eligible, so the last column is an upper bound.

| Vector | Now | Non-memory now | After TP1 | After TP1 + TP2 |
|---|---:|---:|---:|---:|
| `bufcopy_1` | 37 | 26 | 23 | 13 |
| `vec4arith_1` | 66 | 29 | 52 | 20 |
| `math450_1` | 47 | 29 | 33 | 17 |
| `agg_local_1` | 81 | 33 | 67 | 25 |
| `cts_b2b_1` | 27 | 20 | 13 | 7 |

Per core, counting a wave-instruction as 64 FP32 operations (32 FMAs × 2):

| State | Cycles per wave-instruction | FP32 operations per clock | Against today |
|---|---:|---:|---:|
| Today | 27–81 | 0.8–2.4 | 1× |
| TP1 + TP2 | 7–25 | 2.6–9 | up to 2.8–3.9× |
| TP3 | 2–4 | 16–32 | 7–40× |
| Ceiling (one instruction per cycle) | 1 | 64 | 27–81× |

Gates, attached to the existing ladder:

| Gate | When | Threshold | Evidence |
|---|---|---|---|
| G-T1 | pulled forward into CTS-1/CTS-2 work, as the plan already allows when wall time blocks a group | suite cycles at or below 40% of the frozen baseline with identical checks; the three wall-time blockers finish inside a leaf budget (`ssbo` 2- and 3-level arrays, `texture.*.sampler2d_fixed_vertex`, `compute.pipeline.basic` `max_local_size`) | baseline diff, leaf `.qpa` |
| G-T2 | before CTS-3 | 4 cycles or fewer per wave-instruction on arithmetic-bound vectors; per-core cells and SRAM bits from a synthesis leaf; register file and row store inside the SRAM envelope | counters, synthesis leaf |
| G-T3 | the plan's Pareto study, before workloads | same results at 1, 2, 4 and 8 cores; scaling measured to the memory limit; candidate geometries compared at equal budget | counters, group reruns |

G-T1's 40% is provisional: reset it from TP0's eligible-share counter before TP2 starts.

Candidate geometries for G-T3, by FMA count only: 8 cores (256 units), 24 (768), 96
(3,072). At today's per-core state — 2 MiB of register file and a 2.34 M-cell control
screen — the larger two are not credible; TP3a and the area attribution decide which
survive.

### 8.4 Relation to the timing program

`core/` and `corev_apu/` are the functional drafts and the 8-FO4 carry into `out_rtl/` is
deferred while a CTS group is open (`AGENTS-configuration.md` §1.0c). These passes change
cycle counts and structure in the draft. Each carries a timing-impact note and places its
stage boundaries assuming two-cycle SRAM reads, so the structure can be carried later.
None of them retunes FO4, and none supports a frequency claim.

## 9. Frame pipeline breakdown and closure program (2026-11-12)

§8 covers the shader core. This section covers everything else a Vulkan frame crosses:
submission, state resolution, render-pass load and store, vertex fetch, primitive setup,
rasterisation, texturing, output merge, transfers, completion and presentation. Same
evidence rules as §8: written from the RTL in the working tree, nothing built or run,
per-clock figures only, cycle costs marked "estimate" are counted from state lists and are
not measurements.

### 9.1 What is measured

| Observation | Value | Source |
|---|---|---|
| Rasteriser bench, 42 cases, shader core replaced by the bench's stand-in | 3,656,558 busy cycles, 263 primitives, 14,514 pixel writes: about 250 cycles per pixel written | `tb_g6lc_apu_rast` `STAT` line |
| Graphics sessions through the whole device, small fragment shaders, session overhead included | 1.97 M and 2.12 M cycles for 4,096 pixels (`deriv2`, `demdrv`): 480–520 cycles per pixel; 0.75 M for 943 pixels (`persp`): about 800 | `tb_g6lc_apu_vgtop` session cycles |
| First triangle, 512 pixels, whole session | 286 k cycles | G1 record |
| One host command on the DRAM-backed object path | about 3,000 cycles | CTS `execute_large_primary` |
| One indexed draw of 50,784 indices over 8,649 vertices | outlasts Mesa's fence patience in simulation | CTS `sampler2d_fixed_vertex` |

For scale, published fixed-function rates are one pixel per output unit and one bilinear
sample per texture unit per clock: Imagination BXE-2-32 2 pixels per clock; Intel UHD 770
8 and 16; Radeon 780M 32 and 48; RTX 4060 48 and 96. The device today writes 0.002–0.004
pixels per clock, which is 500–1,000× below the smallest of those and 12,000–24,000×
below the largest. A bilinear sample costs at least 20 cycles for its four texel reads on
cache hits, so the texture path is at most 0.05 samples per clock before coordinate, level
and result steps: at least 320× below 16 and 1,900× below 96.

### 9.2 Stage by stage

Each row: what the RTL does now, what it costs, what limits it, and the pass that
addresses it.

**S1 Submission and decode** (`g6lc_apu_vqwalk`, `g6lc_apu_vgctl`, `g6lc_apu_vnpump`,
`g6lc_apu_vndec`, `g6lc_apu_vnfront`).
- The pump decodes every command twice: once in its own decoder for type, length and
  fault, then again inside `vnfront` on the same stream window. Stream words come from the
  aperture one word per micro-step through the memory port.
- The decoder ROM (1,648 × 48 bits) and chain table are combinational localparam muxes.
- Rings are polled with back-off; a liveness heartbeat rewrites every ring's status word.
- Limit: two port round trips per command word. Pass FP1.

**S2 Object and record state** (`g6lc_apu_objtab`, `g6lc_apu_objmem`, `g6lc_apu_objpay`,
`g6lc_apu_cmdrec`).
- Objects, the id directory, payloads and command-buffer records all live in DRAM behind
  one memory-port requester with one beat outstanding. On-chip: a 256-set, 4-way directory
  cache, 64 entry lines, 32 payload lines, a 4-entry open-buffer cache and a 2-record
  prefetch.
- Every operation is serialised across those round trips by design; this is the
  3,000 cycles per command.
- Limit: line fills are eight single beats; one requester for table and payload. Pass
  FP2 (with TP2 and TP9).

**S3 Execution and draw assembly** (`g6lc_apu_cmdexec`).
- Each record is read back and every stored handle re-resolved by generation.
- Every draw repeats the full assembly: pipeline lookup, pipeline-layout lookup, per
  bound set a set, layout and pool lookup plus its binding rows, the 57-word pipeline state
  block read one word per request (`StDrPay`), then a buffer lookup and a memory lookup
  per vertex binding and for the index buffer. There is no reuse between consecutive draws
  that share state.
- One raster work item is in flight at a time; compute and raster share the single shader
  core.
- Not measured separately. Pass FP2.

**S4 Render-pass begin and end.**
- Attachment resolve walks render pass → framebuffer → view → image → memory at
  `vkCmdBeginRenderPass`.
- `loadOp` CLEAR and `vkCmdClearAttachments` run in the rasteriser as 8-byte single beats
  (`S_CLR_X`), each a full port round trip. `vkCmdClearColorImage` runs in the transfer
  engine, whose write leg is also one beat of at most 8 bytes per round trip.
- There is no store or resolve step: pixels are written straight to the attachment as they
  are shaded. `vkCmdResolveImage` and `vkCmdClearDepthStencilImage` are classified as work
  but no engine accepts them.
- Pass FP3.

**S5 Index and vertex fetch** (`g6lc_apu_rast`, `S_GA_*`).
- Per vertex: one index read, then per attribute a windowed read of one to three beats, a
  serial conversion (normalised integers take two float operations per component on the
  one converter and one FMA), and two record writes; then two more writes for the built-in
  slot. A three-attribute vertex is 12–18 single beats before shading (estimate).
- Batches are 63 vertices. Strips and fans longer than one batch are refused.
- Pass FP4 (with TP4, TP5).

**S6 Vertex shading.** §8. One invocation per index today.

**S7 Primitive assembly, clipping, setup** (`S_PR_*`, `S_OC*`, `S_CP_*`, `S_T*`).
- Positions are read back from the record ring (six beats per triangle). The viewport
  transform is recomputed per triangle corner, not per vertex, so shared vertices are
  transformed again.
- Setup is about 45 float operations in series on one FMA, one divider and one converter,
  four of them divides, plus six beats per interpolated location to fetch varyings. At
  three or more cycles per operation that is upwards of 250 cycles per triangle (estimate).
- Clipping is Sutherland–Hodgman through two DRAM rings.
- Pass FP5.

**S8 Rasterisation and interpolation** (`S_SCAN`, `S_F_*`).
- The scan walks the scissored bounding box in 2×2 blocks, one block per cycle when empty.
  Coverage is evaluated combinationally from six 64-bit products per cycle.
- Every lane of a hit block, helpers included, then runs 19 float operations in series
  (one divide) for barycentrics, 1/w, depth and the pixel centre, 16 more per interpolated
  location, and writes 2 + 2 per location beats to the fragment record ring.
- Early depth and stencil are one DRAM read and one write per fragment, with two more
  float operations for 16- and 24-bit formats.
- This stage, not the shader, is most of the 250 cycles per pixel in the rasteriser bench.
  Passes FP5, FP6, FP7.

**S9 Fragment shading and texturing** (`g6lc_apu_shwave`, `W_TX*`).
- Batches are 64 fragments (8 waves). Every batch is a separate dispatch that clears the
  descriptor-record cache and the texel cache, re-initialises each wave and clears lane
  scratch.
- The sampler is part of the wave state machine and runs one lane at a time: record
  fetch, a mip-layout walk of up to 13 steps, coordinates and level through unit jobs, then
  per texel address → probe → read → decode → accumulate. Float formats take three unit
  jobs per texel to accumulate.
- The texel cache is 16 lines of 64 bytes, direct tags in flops, filled by eight single
  beats.
- A fixed list of uncompressed formats decodes (the `W_TXD` case list). No
  block-compressed formats, no anisotropy. The engine document records 1D, 3D and cube
  sampling as faulting.
- Passes FP8, FP9.

**S10 Output merge** (`S_ROP_*`, `S_BL_*`).
- Per fragment, per attachment: two beats to read the shader's output record; with
  blending one destination read, nine float operations to decode it and up to five per
  channel to blend; one 8-byte write with strobes. Late depth adds a read and a write.
- Fragments are merged one at a time in batch order. Adjacent pixels are not combined, so
  an RGBA8 row costs one round trip per pixel although a beat holds two.
- Four colour attachments, processed in series.
- Pass FP10.

**S11 Transfers** (`g6lc_apu_xfer`, `g6lc_apu_dma_read`, `g6lc_apu_dma_write`).
- Reads are checked bursts of up to 16 beats split at 4 KiB; writes are one narrow
  transaction per step; one read and one write outstanding.
- Image addressing shares one iterative multiplier. sRGB clear encode is a serial search.
- Scaled blits are limited to exact 2× nearest on 4-byte texels at mip 0; other scaled
  blits are refused.
- Pass FP11.

**S12 Completion** (`g6lc_apu_cmdexec`, `g6lc_apu_doneq`).
- Sixteen fence slots; barriers and submit end drain outstanding work; events are polled
  every 64 cycles. One executor serves every queue family.
- Pass FP12.

**S13 Presentation.**
- None. The control queue decodes no scanout, flush, display-info or EDID command and the
  Venus configuration requires zero scanouts.
- Pass FP13 (plan W9).

### 9.3 Passes

All passes keep results identical unless stated. Where a pass changes arithmetic order it
says so, and the model and vectors change first.

**FP0 — frame counters and baseline.** Extends TP0.
- Rasteriser cycle classes: gather, vertex wait, setup, clip, scan, interpolation, depth,
  fragment wait, merge, clear. Executor: assembly versus waiting on work. Pump: decode,
  poll, parked. Transfer: read leg, write leg.
- A `frame` section in `apu-perf-baseline.json` from the existing `ue_gpos_*` sessions,
  with pixels, primitives and vertices per session, so cycles per pixel, per primitive and
  per vertex are recorded numbers.
- Nothing below is admitted without its class moving in this file.

**FP1 — single-pass command front.**
- Keep the sizing decode's result and let the front consume it, or let the front decode
  first and report length and fault; one decode per command.
- Fetch stream words through a small on-chip window filled by bursts (TP2), so a word
  crosses the port once.
- Move the decoder ROM and chain table behind the SRAM seam or a synthesised ROM macro;
  the engine document already lists this as a follow-up.
- Control: the Mesa encode and reply differentials and the `vnpump`, `vnfront` benches.

**FP2 — draw-state reuse and burst object access.**
- `objtab` exports a mutation epoch that advances on any retire, context reset or bind
  change. `cmdexec` keeps the last resolved pipeline block, set rows and buffer bases with
  the handles and epoch they were resolved under, and skips re-resolution when both match.
  Lifetime safety is unchanged: any destroy moves the epoch.
- Read the pipeline state block with the existing burst read (`READN`), not one word per
  request.
- Separate object-table and payload requesters on the port (two slots under TP2).
- Control: the negative sessions that destroy an object between record and submit, and
  `api.object_management`, `api.command_buffers`.

**FP3 — attachment load, clear and store.**
- Clears as fill bursts of whole 64-byte lines with strobed head and tail.
- The transfer write leg issues aligned bodies as bursts and keeps narrow transactions for
  unaligned ends; two transactions outstanding.
- A depth-stencil clear route and a resolve route (functional gaps; resolve needs FP9's
  sampler or a box filter and arrives with multisampling).
- With the tile engine (FP10 stage B) a clear becomes tile initialisation and `storeOp`
  DONT_CARE skips the write-out; both are tile-engine exits, not this pass.

**FP4 — vertex fetch.**
- Read a batch's indices as one burst. For non-indexed and instance-rate bindings read
  each binding's stream as bursts; for indexed draws keep the per-vertex window.
- Convert four components in parallel with the same operations per component as today.
  Generate the format cases from the format table (plan pass P3).
- Write records to the on-chip record store (TP4).
- Carry the last two vertices of a strip, or the anchor and last vertex of a fan, across
  batches so long strips and fans are legal.
- Control: `pipeline.monolithic.vertex_input`, `draw.*`, the restart vectors.

**FP5 — per-vertex screen cache and parallel setup.**
- Compute screen x, y, z and 1/w once per shaded vertex, when the vertex batch returns,
  and keep them beside the vertex record. Setup then reads three cached corners.
- Give setup three lanes (one per corner) so the remaining operations run in parallel; or
  run it as a generated preamble on the shader core. Either keeps the per-corner operation
  order, so results are unchanged.
- Varyings are fetched from the record store, not DRAM.

**FP6 — span traversal and interpolation on the core's lanes.**
- Step the three edge functions by addition along rows and columns; derive each row's
  span from the edges and skip empty blocks. The six-product combinational cone goes away,
  which the 8-FO4 structure needs regardless.
- The rasteriser emits per fragment only integers: pixel position, the three edge values,
  a helper flag and a primitive index. The per-primitive constants (reciprocal area, 1/w
  per corner, depth per corner, the varying corners) go into a primitive record.
- Barycentrics, 1/w, depth and varyings are computed by a generated preamble of the
  fragment wave, in today's operation order, on 8 lanes × 4 components. The serial
  19 + 16-per-location sequence becomes the same number of wave steps for 8 fragments, and
  bit-identical results follow from the unchanged order.
- Early depth needs depth before shading: the preamble runs to depth, the depth test
  masks lanes, and the rest of the preamble and the shader body run under that mask.
- Control: the perspective, derivative and helper-lane sessions (bit-exact today) and
  `rasterization.*`.

**FP7 — depth and stencil store.**
- A row or tile depth buffer in SRAM in front of DRAM, loaded and flushed in bursts, so a
  depth test is an SRAM access. Stage B replaces it with the tile's depth plane.
- Hierarchical depth is a later, optional step and must stay conservative (plan W8).

**FP8 — fragment dispatch overhead.**
- Keep the descriptor-record cache and the texel cache across batches of one draw.
  Invalidate on a new draw, on a barrier, on any image store by the wave, and on a write
  to an attachment that is also bound for sampling.
- Skip scratch clear for modules that declare no scratch, and per-wave initialisation that
  repeats the previous batch's.
- Size the fragment batch from the elaborated wave count (128 invocations at the defaults
  against 64 today). The helper mask in the dispatch record is 64 bits and the
  rasteriser's per-fragment tables are sized to the batch, so both widen with it.

**FP9 — texture unit.**
- Factor the sampler out of the wave state machine into `g6lc_apu_tex`, with one request
  per quad and one response per quad. The transfer engine's blit uses the same unit.
- Cache the per-image mip layout (offset, pitch, extent per level) beside the descriptor
  record so the walk runs once per image, not once per lane per sample.
- Compute the level once per quad where the specification defines it per quad; the
  present per-lane sequence was not traced far enough to say whether it already does.
- Read a whole cache line per access and extract the four footprint texels in one step;
  filter the four channels in parallel.
- A larger set-associative cache with tags in SRAM, filled by bursts, persistent across
  batches (FP8).
- Generate decode and encode from the format table. Cube, 3D and 1D addressing come from
  the one address function of the engine document's §9a.
- Block-compressed decode on fill and anisotropic filtering stay unadvertised until the
  plan's per-codec decision.
- Control: the texture corpus bit-exact, then `texture.*` and `pipeline.monolithic.sampler`.

**FP10 — output merge.**
- Stage A, immediate mode. Read shader outputs from the record store. Decode, blend and
  encode the four channels in parallel with the per-channel operation order unchanged.
  Combine adjacent pixels of a batch into full beats and rows into bursts; read
  destination lines once per run. Write through a pixel-store interface.
- Stage B, the tile engine of the engine document's §9. The same merge datapath writes a
  tile's colour and depth planes in SRAM; binning, per-tile primitive order, load and
  store bursts are the new parts. Clears, DONT_CARE elision, multisample storage and
  resolve, and the ordering needed for interlock and programmable blending attach here.
- Building stage A against the pixel-store interface is what keeps it from being thrown
  away by stage B.
- Control: the blend, depth, stencil and logic-op vectors; `pipeline.monolithic.blend`,
  `fragment_operations.*`, `renderpasses.*`.

**FP11 — transfers.**
- Burst writes and deeper outstanding (with FP3). General scaled blit through FP9's unit.
  Resolve and depth-stencil clear routes. The fill pattern is generated once per record.
- Control: `api.copy_and_blit.core`, `api.image_clearing.core`.

**FP12 — completion and queues.**
- Counters for submit-to-first-work and work-done-to-fence. Replace the 64-cycle event
  poll by a wake on the event write. A second executor for an asynchronous compute and
  transfer queue belongs with TP7 and plan W8.

**FP13 — presentation.** Plan W9: scanout, flush, display-info and EDID on the control
queue, blob-backed scanout so present is a pointer flip with no copy, the external
synchronisation Venus requires, and the display consumer. No render-path cost is expected
per frame beyond the flush; that is the acceptance criterion.

### 9.4 Order, dependencies and gates

Superseded for execution by §11.4 (2026-11-13): measurement moved FP6 behind TP3 and put
sequencing passes inside the rasteriser first. The dependencies and gates below stand.

| Step | Passes | Needs | Why here |
|---|---|---|---|
| 1 | FP0 | TP0 | every later pass is admitted by its counter |
| 2 | FP2, FP4, FP8 | TP2, TP4 | remove repeated work with unchanged datapaths |
| 3 | FP5, FP6 | TP4 | the rasteriser's serial float sequence is the largest fixed-function cost |
| 4 | FP3, FP7, FP10 stage A, FP11 | TP2 | memory traffic of the pixel path |
| 5 | FP9 | TP2, FP8 | texture rate, and unblocks blit and resolve |
| 6 | FP1, FP12 | TP2 | control-plane latency |
| 7 | FP10 stage B | steps 3–5 | tile engine; also carries multisampling and ordering features |
| 8 | FP13 | plan W9 | presentation |

Gates, beside G-T1…G-T3:

| Gate | When | Threshold (provisional until FP0) | Evidence |
|---|---|---|---|
| G-F1 | with G-T1 | graphics-session cycles at or below 25% of the frozen frame baseline, pixel-identical; a draw with unchanged state re-resolves nothing; the 50,784-index draw finishes inside Mesa's fence patience | baseline diff, leaf |
| G-F2 | with G-T2 | fixed function is no longer the limit: flat-shaded fill at 1 pixel per clock or better, 4 bilinear samples per clock or better on cache hits, both from counters | counters |
| G-F3 | with G-T3 | tile geometry, texture-unit count and core count chosen together at equal budget, with fill and sample rates measured against the per-clock reference points of §9.1 | Pareto study |

The 25% in G-F1 rests on two expectations: interpolation moving from one serial unit to
8 lanes (FP6), and record traffic leaving DRAM (TP4). Neither is measured.

### 9.5 Functional gaps found on the way

These are completeness items, not throughput. Each already has an owner in the plan; they
are listed here because the stage reading surfaced them.

| Stage | Gap | Plan owner |
|---|---|---|
| S4 | no resolve or depth-stencil clear engine; no store step | W4.6, C |
| S5 | strips and fans limited to one 63-vertex batch | C |
| S8 | no multisampling, single viewport, one-pixel points and lines | C |
| S9 | 1D, 3D, cube sampling; block-compressed formats; anisotropy | B, W4.4 |
| S10 | four colour attachments (1.4 needs eight); attachments merged in series | W10.2 |
| S11 | general scaled and filtered blit | W4.6 |
| S12 | one executor; no timeline semaphores | W2.4, W8 |
| S13 | no scanout or window-system path | W9 |

## 10. Vulkan 1.4 capacity in the frame path (2026-11-12)

§8 and §9 are about rate. This section is about width: where a Vulkan 1.4 minimum or
required feature meets a fixed field, array or index in the frame path. The 1.4 values
are from the Khronos `VK_VERSION_1_4` reference page read on this date; the RTL values
are as read in the working tree. Pattern CTS-P2 applies: each is a structure change with
its own vector, never a profile edit. `limits-ledger.md` holds the CTS-0 view of the
1.0/1.1 minima and is older than the tree in places (it lists 4 vertex bindings; the
profile and the draw record now carry 16).

### 10.1 Widths that bind

| 1.4 requirement | Today | Where it is fixed | Change |
|---|---|---|---|
| `maxBoundDescriptorSets` 7 (UE RT wants 9) | 4 | `APU_DESC_SETS = 4`; the wave engine indexes sets with two bits (`dsc_set_q[1:0]` into `set_base` and the record cache); `apu_cmdexec_state_t.dset[3:0]` and `.dyn[3:0]` | make the set count a package parameter that sizes the sideband, the executor snapshot and the index width together. The descriptor sideband is about 5.3 kbit at 4 sets; at 9 it should become a small SRAM or be fetched per set, not widened in flops |
| `maxPushConstantsSize` 256 | 128 | `push_q[32]`, `push_i[1023:0]`, 6-bit `push_n` in `shwave`, `shcore`, `rast`, `cmdexec` | 64 words; move the block to the record store (TP4) so it stops being a 1,024-bit bus replicated per engine |
| `maxColorAttachments` 8, `maxFragmentCombinedOutputResources` 16 | 4 | `apu_rast_draw_t.ca[3:0]`, `.blend[3:0]`, 2-bit `at_q`, FS-out record locations | 8 entries; FP10's merge iterates attachments, so the count becomes a loop bound. FS-out record stride grows with it |
| `maxVertexInputAttributes` 16 | 8 | `apu_rast_draw_t.attr[7:0]`, 3-bit `a_q`, 3-bit `loc` | 16; done with FP4's generated gather |
| `maxVertexOutputComponents` / `maxFragmentInputComponents` 64 | 32 | `APU_SH_VARY_LOCS = 8`, hence the 144-byte record stride, the 8-bit `fs_in_mask`, and the rasteriser's 3 × 8 × vec4 varying cache in flops | 16 locations; the record stride becomes a parameter (the ledger already says so). FP6 moves the varying corners into the primitive record, which removes the flop cache |
| `maxComputeWorkGroupInvocations` 256, size (256, 256, 64) | 128 | `MaxWaves = 16` × 8 lanes; register file depth | TP3a: the depth policy must allow 32 waves, or 16 lanes × 16 waves |
| `maxImageArrayLayers` 2048 | 256 advertised | object-table image entry carries layers in 9 bits (`aux[53:45]`); `apu_xfer_img_t.layers` is 10 bits | widen both to 12 bits; the entry layout moves, so the golden model and every image vector regenerate |
| `maxImageDimension2D` / `Cube` 8192, `3D` 512, framebuffer and viewport 7680 | 4096 / 4096 / 256 / 4096 | coordinate fields are 16-bit and the scan is 16.8 fixed point, so the arithmetic already fits; the limit is storage: the aperture is 128 MiB (`APU_SHM_BYTES`), of which 64 MiB is guest-visible, and one 7680 × 7680 RGBA8 attachment is 225 MiB | aperture and heap sizing is an SoC decision (plan W5); the profile value follows the elaborated aperture |
| `maxPerStageResources` 200, per-set limits 90 / 96 / 144 | 16 | `APU_DESC_BND = 16` binding rows per set held as a CAM in the sideband | rows move to memory with a per-set lookup; same change as the set count |
| `sampleRateShading`, `standardSampleLocations`, sample counts 1 and 4 | single sample | no sample dimension anywhere in scan, depth, merge or image layout | multisampling arrives with the tile stage of FP10: coverage mask per fragment, per-sample depth and colour in the tile, resolve on store; sample-rate shading issues one lane per sample |
| `samplerAnisotropy`, `imageCubeArray`, `samplerMirrorClampToEdge`, `shaderImageGatherExtended`, `samplerYcbcrConversion` | not advertised | sampler in the wave state machine | FP9; YCbCr conversion is a format-table row plus a 3 × 3 matrix step after filtering |
| `largePoints`, point size to 256, wide and Bresenham lines, `depthClamp`, `depthBiasClamp` | one-pixel points and lines; clamp implemented but unadvertised | rasteriser line and point paths | points and wide lines as two-triangle quads through the triangle path (FP5/FP6), which also gives them interpolation and clipping |
| `shaderInt8`, `shaderInt16`, 8- and 16-bit storage, `scalarBlockLayout`, `variablePointers`, clustered and rotate subgroups | not advertised | wave engine load/store is 32-bit words with half-beat strobes | §8 scope: narrow strobes in the lane-vector load/store (TP2), type rows in the predecode (TP1) |
| Queues: every graphics or compute queue also transfer; `hostImageCopy` or an extra transfer queue; `timestampComputeAndGraphics` | two families on one executor; timestamps report zero valid bits | `cmdexec`, profile | a real free-running timestamp counter with a truthful period (needs the clock), and the host-image-copy or transfer-queue choice from plan W10.2 |
| Entry forms required by 1.3/1.4: dynamic rendering and local read, `synchronization2`, extended dynamic state, push descriptors, `*2` bind and copy commands, line stipple | absent from `vn_command_set.txt` (48 `vkCmd*`/`vkQueue*` entries, none of these) | generated decode tables | plan pass P4: one per-draw state record that every entry form writes. Each addition regenerates the decoder and every front-end vector, so they should land in few, large table revisions |

### 10.2 A reference frame in cycles

For sizing only. The frame is hypothetical, not a captured workload: 1920 × 1080, two
full-screen clears (colour and depth), 2.5× overdraw, 500,000 triangles from 1,000,000
shaded vertices, 2,000 draws, one bilinear sample per fragment. Shader time is excluded
(§8). "Today" uses the measured rasteriser-bench figure for pixels and state-list
estimates elsewhere; the estimates are lower bounds because they assume an ideal memory
slave.

| Term | Count | Today, cycles each | Today, total | At G-F2 |
|---|---:|---:|---:|---:|
| Clears | 2 × 1.04 M beats | ≥ 4 per 8 bytes | ≥ 8 M | about 2 M (one beat per cycle in bursts on a 64-bit port) |
| Draw assembly | 2,000 | unmeasured (tens of object lookups plus 57 single reads) | — | reuse on unchanged state |
| Vertex fetch | 1,000,000 | ≥ 60 (12–18 beats) | ≥ 60 M | burst-bound |
| Setup | 500,000 | ≥ 250 | ≥ 125 M | parallel lanes |
| Scan, interpolation, merge | 5.2 M fragments | about 250 (measured) | about 1,300 M | 5.2 M at 1 pixel per clock |
| Texture | 5.2 M samples | ≥ 20 | ≥ 104 M | 1.3 M at 4 per clock |
| Present | 1 | no path | — | flush only |
| **Fixed function total** | | | **≥ 1,600 M** | **about 9 M plus vertex and setup** |

A 60 Hz frame is 16.7 M cycles per GHz of clock. Two things follow, neither a frame-rate
claim. First, pixel work is four fifths of today's fixed-function total, which is why FP6
and FP10 are ordered ahead of the control plane. Second, at the G-F2 rates the
fixed-function cost of this frame is of the same order as one frame's cycles at a
gigahertz-class clock, so G-F2 is the smallest target at which shader throughput, not
fixed function, decides the outcome; anything beyond it is the Pareto study's business
(G-F3).

### 10.3 Order

The width changes ride the passes that already touch the same structures, so no field is
widened twice:

| Change | Rides |
|---|---|
| attribute count, vertex formats | FP4 |
| varying locations, record stride, primitive record | TP4, FP6 |
| push block to the record store | TP4 |
| colour attachments, sample dimension | FP10 (A for the count, B for samples) |
| descriptor sets and binding rows to memory | FP2 and plan pass P7 |
| work-group invocations | TP3a |
| array layers | plan pass P3 (format and image table regeneration) |
| entry forms | plan pass P4 |
| aperture and heaps | plan W5, with the SoC memory decision |

## 11. Execution model and measured passes (2026-11-13)

§8–§10 say what to change. This section says how the work is run so that each change is
small, admitted by a number, and not repeated. It also records what the first
measurements changed in the order. Unlike §8–§10, the figures here are measured on the
working tree. RP1 and RP2 were measured with the local benches (system Verilator 5.020);
from SP1 on, every figure comes from the remote testharness on the pinned compiler
(§11.8). The rasteriser and shader suites give the same cycle counts on both.

### 11.1 The loop

One command decides whether a throughput pass is admitted:

```
APU_LEAF_STAGES=perf bash verif/tb/apu/run-apu-remote-leaf.sh    # run and gate, remotely
bash verif/tb/apu/run-apu-perf.sh --admit-from <collected capture.json>   # record it
```

The first line pushes a snapshot of the working tree to the remote builder and runs
`run-apu-perf.sh` there as the `perf` stage of `run-apu-regress.sh`; the second gates the
collected capture again and records it, without simulating anything. Running
`run-apu-perf.sh` directly still works for reading the script's behaviour, but its
results are not evidence (§11.8).

- It builds three benches (`tb_g6lc_apu_rast`, `tb_g6lc_apu_shwave`, `tb_g6lc_apu_vgtop`),
  runs a fixed cohort (the 42-case rasteriser suite, the 548-case shader suite, 14
  graphics and 4 compute/transfer device sessions) and collects the benches' counter lines
  with `verif/tb/apu/apu_perf.py`.
- A pass is admitted only on `OK same checked work; no cycle regression`. "Same checked
  work" is mechanical: cases, checks, primitive, pixel, query and per-vector instruction
  counts must be equal; only cycles may move.
- Two captures are kept in the tree. `apu-perf-baseline.json` is the origin that gates
  G-T1 and G-F1 are measured from; it is written once. `apu-perf-current.json` is the last
  admitted state.
- Two control arms are part of the full cohort. `rc0` rebuilds the shader suite with
  `RowCacheEntries=0`: it must check the same work, report no row hit, and is captured as
  run `shwave-rc0`, so the long decode path is gated too. `jitter` reruns the 18 device
  sessions with `+mp_lat_min=1 +mp_lat_max=20 +mp_ready_pct=60` and requires the same
  cases and checks.
- Turnaround on the shared remote builder is about 19 minutes (rast 2 min, shader suite
  with its control arm 5 min, device sessions with the jitter arm 12 min). Every snapshot
  has a new source identity, so every bench rebuilds.
- The loop builds without simulator PGO. A PGO build costs 5–6.5 minutes per bench and its
  source-drift guard aborts whenever any file in the tree changes during the build, which
  is the normal state of a shared working tree. Results are byte-identical with and
  without PGO; PGO stays for long guest runs.
- The memory slave is the ideal one (three cycles per request, always ready), so cycle
  totals are lower bounds. A jitter arm (`+mp_lat_min=1 +mp_lat_max=20 +mp_ready_pct=60`)
  on the graphics cohort guards handshake changes.

Evidence tiers, cheapest first; each pass runs only what its tier needs:

| Tier | What | When | Cost |
|---|---|---|---|
| T0 | remote `perf` stage (the loop, with both control arms) | every pass | 19 min |
| T1 | remote `top` stage (transport, all 222 device sessions, the jitter steps, the small-geometry arms, `vgsys`, `sys-venus`); remote `synth` stage (yosys screens, now including `synth-rast` and `synth-shwave`) | every pass that touches `g6lc_apu_rast.sv`, the shader core or the device path | about 1 h each under load |
| T2 | remote `unit` stage | every rung | about 1 h |
| T3 | remote `soc,bridge` and guest leaves, CTS batch | every gate | — |

Counters added for this (all behind parameters that default to no cells, read
hierarchically by the benches, no ports):

- `g6lc_apu_rast` `PerfClassEn`: eleven busy-cycle classes that partition busy time
  (control, clear, gather, vertex wait, setup, clip, scan, interpolation, depth, fragment
  wait, merge), plus memory-wait cycles, memory requests, float-sequencer wait cycles and
  float jobs. The bench checks that the classes sum to the busy count.
- `g6lc_apu_vgtop` `PerfCountersEn`: busy cycles per engine (control queue, ring pump,
  executor, shader core, rasteriser, transfer) and, per memory-port requester, requests
  and cycles with a request pending or in flight.
- `g6lc_apu_shwave`: the load/store class now includes `W_DS9`; the texture class now
  includes the derivative, projection, compare, gather, query-level, probe and accumulate
  states it had missed.

Two things the first runs exposed in the benches themselves:

- Nine shader vector families named by the shader bench (`texbuf*`, `imgarr*`) had no
  vector files in the tree, so the bench failed 27 cases. They were regenerated with the
  existing generators; the suite is 548 cases, 100,832 checks.
- Every device session cold-booted the object table. The directory zero sweep is 131,072
  single beats, about 394,000 cycles, which was 70–85% of a small session. It is a
  once-per-power-on cost in a system. The bench now preloads the warm-boot marker (cold
  boot stays covered by the transport session, `+objmem_cold`), with a bench assertion
  that fails if a warm run ever enters the sweep. The origin's session totals were
  rebased by the measured constant (392,855 cycles per session; identical work on both
  sides). The 126-session graphics sweep went from 84.2 M to 34.7 M simulated cycles and
  from 1,136 s to 257 s of wall time. `tb_g6lc_apu_vgsys` still cold-boots.

### 11.2 Origin

| Bench | Checked work | Cycles | Reading |
|---|---|---:|---|
| Rasteriser suite | 42 cases, 15,605 checks, 263 primitives, 17,446 fragments, 14,514 pixel writes | 3,656,558 busy | 252 per pixel written, 210 per fragment |
| Shader suite | 548 cases, 100,832 checks, 111,622 wave-instructions | 3,908,903 busy | 35.0 per wave-instruction; load/store 31%, arithmetic units 4%, texture 1% |
| Device sessions | 18 sessions | see the capture | rasteriser busy 286–593 cycles per pixel on the full-screen cases |

Where the rasteriser's cycles went at the origin:

| Class | Share of busy |
|---|---:|
| Interpolation (per fragment) | 82.3% |
| Output merge | 9.5% |
| Clear | 4.0% |
| Depth | 1.6% |
| Setup, clip, scan, gather, waits | 2.6% |

On the other axis: 633,063 float jobs took 3.13 sequencer cycles each plus one caller
cycle, which is 54% of busy in the sequencer alone; 159,527 memory requests took 3.0
cycles each plus a caller cycle, 13%. A clear costs exactly five cycles per 8-byte beat
(10,240 cycles for a 64×64 RGBA8 target).

Synthesis screen (yosys generic cells, same recipe as `run-apu-rast.sh`): the rasteriser
is 239,107 cells and 23,871 flops at HEAD. One `fpnew_fma` is 7,475 cells, the divider
6,583, the converter 3,278: the three arithmetic units are 7% of the module. The rest is
the state machine's operand and next-state fabric.

### 11.3 What the measurements changed

1. **The cost was sequencing, not arithmetic.** Each float job spent two of its four
   cycles in hand-off states. Removing them (RP1, §11.5) is worth more than any datapath
   widening at this point, costs no area, and changes no result.
2. **Interpolation on the shader core (FP6) moves behind TP3.** At 35 cycles per
   wave-instruction and 8 lanes, the 19 + 16-per-location interpolation steps would cost
   about 150 cycles per fragment as wave instructions, against 131 in the rasteriser after
   RP1. FP6 only pays once the core is at G-T2 (4 cycles or fewer per instruction, about
   18 cycles per fragment). Until then the rasteriser keeps the chain and schedules it
   better (RP2). §9.4's order and plan §5b's "largest lever" statement are superseded on
   this point.
3. **More arithmetic units are cheap, but not needed yet.** A second FMA would add 3% to
   the module. Interleaving independent jobs on the existing units gets most of the same
   gain first.
4. **Small-session time is not the control plane.** After the cold-boot constant is
   removed, the object path is a few hundred requests per session. The 3,000 cycles per
   host command quoted in §8 and §9.1 came from one CTS case on the guest and is not
   reproduced by these sessions; it needs its own measurement on the guest path before
   FP1/FP2/TP9 are sized.
5. **Transfers are write-leg bound.** The large-copy session spends 59% of its cycles in
   the transfer engine; FP3/FP11's burst write leg is confirmed as the lever.
6. **Texture-heavy sessions are shader-bound.** With RP1 in, fragment-shader wait is
   60–64% of rasteriser busy on the sampled sessions and 19–33% elsewhere, so the shader
   core (§8) is now the larger term on anything that samples.

A defect found while reading — FIX IMPLEMENTED AND BENCH-VERIFIED 2026-11-14:
the late depth test (`S_ROP_LC` → `S_DB0`) computes
depth bias from the rasteriser's current primitive registers after the fragment
batch returns. Traced mechanism: adjacent same-facing primitives merge into one FS
batch (`bat_front_q`, ~line 833), `vz_q[0..2]` and `span_w` are single per-primitive
registers holding only the last-scanned primitive's values, and `db_bias_q` is one
value = `slopeFactor·max|dz|/span` added to every fragment's z; `db_done_q` resets
per-fragment (`S_ROP_R0`) but the slope registers do not. `S_FS_WAIT` serializes the
rasteriser (no scan-ahead), so the registers are stable but wrong for earlier
primitives. With `fs_late` + nonzero `depth_bias_slope` + `(depth_test||
depth_write)`, earlier primitives' fragments take the last primitive's slope. Fix:
`slope_bias_late` flushes the FS batch at every primitive boundary under that
condition → single-primitive batches → correct slope; early-Z and constant-only
bias unaffected (early-Z already recomputed per fragment during scan). Directed
vector `tb_g6lc_apu_rast` case 43 (flat + tilted same-facing tris, `fs_late` +
`FragDepth`, slope bias): flat tri's depth == `FragDepth` exactly, tilted tri's
differs — discriminating the bug. Evidence: `rast` bench `PASS cases=43
checks=15606` on the fix+vector source; all-stages leaf `rast` suite `PASS
cases=42 checks=15605` on the fix-only source (no regression); local Verilator
lint clean. Residuals: `poly_mode=LINE/POINT` wireframe-rendered triangles take
the parallel `S_LN_*` path (bypass `S_PR_AREA`) and clip-fan sub-pieces — rare
configs, documented in `.cache/apu-perf/dbslope-brief.md`. Formal all-stages leaf
verdict pending collection; the affected module is otherwise fully covered.

### 11.4 The ladder

This replaces the order tables of §8.2 and §9.4 for execution. A rung is one shared
enabler plus the passes that consume it, so no enabler is built twice and every pass has
its counter before it starts.

| Rung | Enabler | Passes | State |
|---|---|---|---|
| R0 | counters, loop, origin (TP0, FP0) | — | done |
| R1 | none: sequencing inside one module, results unchanged | RP1 float-job hand-off; RP2 interleaved issue in the per-fragment chains; RP3 merge and blend chains on the same pattern; SP1 decoded-row cache in the shader core (TP1 delivered lazily, see below) | RP1, RP2, RP4, SP1, SP2, SP3 done; SP4 done; RP3 partial 2026-11-15: five capture+issue fusions landed — four in the blend chain (`S_BL_F2B`→`S_BL_M1`, `S_BL_F1B`→`S_BL_F2`, `S_BL_F2`-else inlining `S_BL_M1`, `S_BL_F1`-else inlining `S_BL_F2`'s dst-dispatch; `S_BL_M1`/`S_BL_F2` unreachable+removed, `S_BL_F1`/`F1B` symmetric → blend chain 5 states/component, was 7) plus `S_DB1`→`S_DB1B` depth-bias clamp-select (`S_DB1B`+`db_bias_q` flop removed). Bit-exact; rast merge −19.3k cy + depth −1.1k cy local. Bench coverage hardened first: cases 6b–6h add ONE_MINUS-src, all five blend ops, `SRC_ALPHA_SATURATE`, `CONST_COLOR` — 53 cases / 22,784 checks; cases 47–55 (2026-11-15) add two-attachment draws, per-attachment blend, a sparse attachment mask, the colour write mask on BGRA, logic op and blend on sRGB, a mid-scale UNORM16 vertex colour and D16 depth (early and late) — 62 cases / 31,749 checks. `S_BL_ST`/`S_BL_MM` advance fusion + read-overlap + scoreboard-scale pipelining analysed in `.cache/apu-perf/rp3-brief.md`, pending remote `perf`-leaf admission. 2026-11-15 exhaustive sweep: no remaining pure-NOP states, dead regs, or operand-stable capture→issue candidates in any rast path (blend/depth/vertex/gather/ROP/clip) — the bounded sequencing surface is exhausted; next gains need R2 (memory port) or the TP/FP features |
| R2 | memory port with one slot per requester and bursts (TP2b) | clears as bursts (FP3), transfer write leg (FP11), object and texel line fills (TP9, FP9 fill), stream window (FP1), pipeline block read (FP2), lane-vector load/store (TP2a) | not started; sized 2026-11-14 from the existing counters: device-memory accept is 2.3% of shader busy in aggregate and at most about 15% on the memory-stress vectors, and the path is serial end to end (`apmem`, `tdma`, the bench slave), so this is a multi-module rework with a small measured return on the present corpus. Deferred behind the fragment path (interpolation, shader wait, merge) |
| R3 | on-chip record store (TP4) | vertex and fragment records, primitive record, push block; vertex reuse (TP5); burst vertex fetch (FP4); screen cache (FP5) | TP4 core ADMITTED 2026-11-14: apmem serves the record/clip carve from 2x4096x64b tc_sram (dynamic ALLOC_PRIV base plumbed rast->vgtop->vgsys->apmem); remote top leaf PASS (vgtop/vgsys/sys-venus, every ue_gpos_* bit-exact through SRAM) + perf leaf PASS, capture bit-identical to SP5 on the apmem-bypassing cohort -> apu-perf-current.json=R3. sys-venus A/B: six ue_gpos_* vecs uniformly -4567 cy (-0.55%, ~254 record beats x ~18 cy/access, AXI ~20->SRAM ~2 cy), all ue_cpos_* bit-identical. TP5 built 2026-11-14 behind `VtxCacheEntries` (default 0, results identical; rast cases 44–46): vertex-shader invocations −90% on the ten-batch probe, but cycles +0.7% to +2.0%, because the 18-word hit copy costs more than the bench's stub vertex shader — left off, not admitted. FP4/FP5 + primitive/push consumers open |
| R4 | format table generator (plan P3) | vertex convert (FP4), texel decode (FP9), attachment encode and decode (FP10) | not started |
| R5 | pipelined issue and banked register file (TP3) | interpolation preamble (FP6), then G-T2 | not started |
| R6 | texture unit, tile store, shader cores (FP9, FP10 stage B, TP7) | the Pareto study, G-T3 and G-F3 | not started |

SP1 is TP1 reshaped for risk. TP1 as written moves decode to module commit, which
changes the module store, the commit path and the model's view of it at once. A
decoded-row cache inside the wave engine gives the same fast path without touching
commit: the first execution of an instruction walks the long path and stores the decoded
facts (opcode class, result type shape, operand register indices and tags, result
register); every later execution of that program counter, by any wave, batch or
workgroup, restores them and goes straight to operand reads. Instructions that do not
fit the row keep the long path. The row store is a direct-mapped `tc_sram` inside the
SRAM envelope, invalidated by a generation tag on commit. Expected from the state walk:
about 10 of 24 cycles on a two-operand instruction. Commit-time rows (TP1 proper) remain
the end state if the row-reuse counter shows first-touch cost matters.

### 11.5 Pass contract

Every pass is written and reviewed against the same five lines, so it fits one hand-off:

1. **Counter.** The class or ratio that is expected to move, and by about how much.
2. **Equality argument.** Why results cannot change (same operations and operands; or the
   model and vectors change first and say so).
3. **Blast radius.** Files touched; state names removed or added; state numbers pinned by
   a bench stay put.
4. **Timing note.** No new combinational path, or the new path and why it is acceptable
   in the functional draft.
5. **Admission.** T0, plus T1 if it touches the rasteriser or device path; cells and
   flops against the previous screen.

Two rules keep the tree cheap to work in. No dual paths: a pass replaces the old
sequence and the old arms are deleted, unless results can legitimately differ (then a
parameter, default off, and both sides in the loop). No refactor rides a pass: a
sequencing pass does not rename, reorder or extract.

### 11.6 Defaults taken

The owner decisions listed in plan §5a and §5b are taken as follows so work is not
blocked; each is reversible.

| Decision | Default | Reversal cost |
|---|---|---|
| Start G-T1/G-F1 work before CTS-1 closes | yes; R1 passes change no result and shorten CTS wall time | none |
| Run-to-barrier scheduling | not yet; SP1 keeps per-instruction round-robin | none |
| Register-file depth policy | derive limits from the elaborated depth when TP3a starts | parameter |
| Interpolation in a fragment-wave preamble (FP6) | after TP3; rasteriser keeps it until then | none |
| Depth store and stage-A merge before the tile engine | yes, behind the pixel-store interface | interface kept |
| Draw-state reuse key | one global object-table epoch first | counter shows reuse rate |

### 11.7 Results log

| Pass | Change | Rasteriser suite busy | Per pixel | Shader suite | Cells / flops | Evidence |
|---|---|---:|---:|---:|---|---|
| origin | — | 3,656,558 | 252 | 35.0 per instruction | 239,107 / 23,871 | `apu-perf-baseline.json` |
| RP1 | float jobs issue in one step, FMA and converter without the redundant input register; pixel centre formed exactly without float jobs | 2,288,911 (−37.4%) | 158 | unchanged | 238,874 / 23,733 | T0; T1: 126 of 126 sessions identical work, total 91.8 M → 84.2 M cycles; jitter arm 14 of 14; no latches |
| RP2 | the per-fragment chain (3 converts, 11 FMA jobs, 1 divide) and the per-location chain (16 FMA jobs) issue one job per cycle, result captured the next cycle; same operations, operands and dependent order | 1,718,683 (−24.9%; −53.0% from origin) | 118 | unchanged | 240,483 / 23,739 | T0; T1: 126 of 126 identical work, 34.7 M → 31.6 M cycles; jitter arm 14 of 14; no latches |
| SP1 | decoded-row cache in the wave engine: the first execution of a program counter stores the decode facts (result-type shape, three operand rows, result row) in a 1,024-row `tc_sram`; later executions restore them and read operand values while the operand words stream | unchanged | unchanged | 4,663,675 suite cycles (−10.6%); 30.1 per instruction (−14.1%) | pending the remote `synth` stage | remote `perf` leaf `apu-leaf-20261113T080312-af48ed889927`: same checked work, no regression; `RowCacheEntries=0` arm equal to the pre-SP1 state on all 474 vectors and every counter; jitter arm 18 of 18. Remote `top` leaf `apu-leaf-20261113T081358-423bd6ab0621`: `vgtop` passed (transport, 222 sessions, jitter steps, small-geometry arms) |
| RP4 | write-behind queue on the rasteriser memory port: eleven record, depth, clear and pixel write states push into a two-entry queue and move on; reads and wave launches wait for it to drain; one request outstanding as before | 1,397,098 (−18.7%; −61.8% from origin) | 96 | unchanged | 247,744 / 23,988, no latches (remote `synth-rast`, leaf `apu-leaf-20261113T130512-03c430a0c479`) | remote `perf` leaf `apu-leaf-20261113T090422-135fc1b6be53`: same checked work, 159,527 port requests before and after; remote `top` leaf `apu-leaf-20261113T092742-b102c2e1e4e7`: `vgtop`, `vgsys`, `sys-venus` passed |
| SP2 | three sequencing merges in the wave engine: the scheduler pick moves into the instruction-advance state; skipped load/store words advance from the decode state; scratch and slab accesses are issued from the decode state | unchanged | unchanged | 4,256,518 suite cycles (−8.7%); 26.4 per instruction (−12.1%) | pending the remote `synth` stage | remote `perf` leaf `apu-leaf-20261113T122138-e42b5fbd2a9a`; remote `unit` leaf `apu-leaf-20261113T130024-8880e43b51ed` on the RP4+SP2 tree: all 17 suites passed |
| SP3 | lane-parallel scratch: one scratch bank per lane instead of one memory for all; the per-wave scratch clear writes all lanes at once; a plain Function/Private word is read or written for all active lanes in one access | unchanged | unchanged | 3,789,570 suite cycles (−11.0%; −27.3% from origin); 22.3 per instruction | pending the remote `synth` stage | remote `perf` leaf `apu-leaf-20261113T133943-8d72a644d21d`; remote `unit` leaf `apu-leaf-20261113T141037-8921c58a507c`: 17 of 17 suites; remote `top` leaf `apu-leaf-20261113T141214-c0992acd34a9`: `vgtop` passed |
| SP4 | beat pairing: two adjacent 32-bit words of one lane travel in one 64-bit request on the record and buffer load/store path (plain mode) | unchanged | unchanged | 3,720,154 suite cycles (−1.8%; −28.7% from origin); 21.6 per instruction | pending the remote `synth` stage | remote `perf` leaf `apu-leaf-20261113T150217-b67263b6c73c`; remote `unit` leaf `apu-leaf-20261113T153547-33e72f20377f`: 17 of 17 suites; remote `top` leaf `apu-leaf-20261113T154059-bf59548a9bd5`: `vgtop`, `vgsys`, `sys-venus` passed |
| SP5 | classify-time issue: the common non-atomic device-memory request is driven on the port during `W_LSC`, and a same-cycle `mem_ready_i` accept advances straight to `W_LS2`; `W_LS1` stays as the wait/reissue state under back-pressure | unchanged | unchanged | 3,666,123 suite cycles (−1.5%; −29.7% from origin); 21.3 per instruction | pending the remote `synth` stage | remote `perf` leaf `apu-leaf-20261113T221053-697f433fb222`: same checked work, no regression; remote `unit` leaf `apu-leaf-20261113T215524-ac642f3a31f0`: 17 of 17 suites; remote `top` leaf `apu-leaf-20261113T224328-a88ebc9ef07f`: running at admission |
| R3 | on-chip record store (TP4 core): `g6lc_apu_apmem` serves `dom=1` requests inside the rasteriser record/clip carve (`[vsi_q, +APU_REC_CARVE_BYTES)` 64 KiB `ALLOC_PRIV`) from two `4096x64b` `tc_sram` banks via `StSramWr`/`StSramRd`/`StSramCap`; the dynamic carve base is plumbed `rast`→`vgtop`→`vgsys`→`apmem.rec_base_i`/`rec_en_i`; all non-record traffic keeps the AXI path | unchanged — the suite benches bypass `apmem` (`tb_apu_mp_mem`), so the admitted cohort cannot see the store; verified bit-identical | unchanged | unchanged | +64 KiB `tc_sram` (2×4096×64b); `synth` of the `apmem`/`vgsys` level pending | remote `perf` leaf `apu-leaf-20261113T233316-ff869e167b24`: `perf` PASS checks=570416, capture bit-identical to SP5 (+0.00% every run) → `--admit-from` "same checked work; no cycle regression"; remote `top` leaf `apu-leaf-20261113T232236-ecd2fa5a3e48`: `vgtop`/`vgsys`/`sys-venus` PASS, every `ue_gpos_*` bit-exact through SRAM; inert `unit` leaf `apu-leaf-20261113T230233-c81ffdcedc34`: 17 of 17. Real benefit is sys-venus-level: six `ue_gpos_*` vecs uniformly −4,567 cy (−0.55%, ~254 record beats × ~18 cy/access, AXI ~20 cy → SRAM ~2 cy), all `ue_cpos_*` bit-identical |

Device sessions, RP1 and RP2 together against the rebased origin: rasteriser busy falls
40–46% on the full-screen cases and 18–26% on the sampled and four-attachment cases,
where the shader wait dominates; whole-session cycles fall 27–44% and 12–20%.

Where the rasteriser suite's 98.5 cycles per fragment go after RP2:

| Term (across all classes) | Cycles per fragment | Next lever |
|---|---:|---|
| Memory requests: 9.1 per fragment, 3 cycles each plus the issuing state | about 37 | record store (R3) removes the record beats; port bursts (R2) the rest |
| Float jobs: 32.4 per fragment, now about one cycle each | about 34 | a second FMA or FP6; neither before R3 |
| Remaining sequencing (scan, control and capture states) | about 28 | RP3 for the merge and blend chains; FP3, FP7 for clear and depth |

By class the same total is interpolation 64.7, output merge 17.8, clear 8.4, depth 3.0
and everything else 4.6 cycles per fragment. Without blending the merge is three memory
requests per attachment (two record beats and the pixel write) and little else, so RP3
only helps blending draws; for the rest the merge waits on R3 like the record writes.

The float sequencer is drained (0.06 wait cycles per job). Memory traffic is now the
largest single term in the rasteriser, which is what R2 and R3 address.

What SP1 showed. 68,648 of 111,622 instruction executions hit a row (61.5%), and a hit
saves 8.0 cycles. Device sessions fall 1–6% in total cycles, most on the shader-heavy
ones (derivative chain −5.6%, four attachments −4.5%, compute math −4.5%). The misses
are first executions, instructions with more than three operand rows, and opcodes whose
operand layout depends on the word count. After SP1 the shader suite's 30.1 cycles per
instruction split as load/store 11.0, arithmetic units 1.5, texture 0.4 and 17.2 for
decode, execute control and write-back. Load/store is now the largest named class; its
states need a per-path count (record, descriptor, scratch, device memory) before a pass
is sized.

The per-path count. `tb_g6lc_apu_shwave` now prints a state histogram (`HIST st=<code>
cyc=<n>`, codes are positions in the engine's state type). After SP1, of 3,362,158 busy
cycles:

| Path | Cycles | Share | What it is |
|---|---:|---:|---|
| Scratch and slab words | 691,221 | 20.6% | 230,407 words at three states each |
| Operand stream | 448,762 | 13.3% | one state per instruction word after the opcode |
| Device-memory words | about 306,000 | 9.1% | 85,572 words; 66,871 port requests |
| Fetch, hit check, pre-execute | 335,337 | 10.0% | three states per instruction |
| Skipped words | 195,326 | 5.8% | inactive lanes, built-ins, push constants |
| Per-lane scratch clear | 137,616 | 4.1% | once per wave of every workgroup |
| Scheduler | 112,846 | 3.4% | one state per instruction |

SP2 took the three terms that were pure sequencing: the scheduler state after an
instruction (81,329), the advance state after a skipped word (95,421) and the issue
state of a scratch or slab word (230,407). The histogram after SP2 shows exactly those
three differences and no other, and the suite fell by their sum, 407,157 cycles.

What RP4 showed. The rasteriser suite's memory-wait cycles fell from 478,581 to 124,107
with the same 159,527 requests. Clears fell 40%, vertex gather 28%, interpolation 18%
(its record writes now overlap the float chains), merge 14%. The fourteen graphics
sessions of the loop total 4,004,618 cycles after RP2, 3,894,973 after SP1, 3,574,148
after RP4 and 3,545,204 after SP2.

What SP3 showed. The scratch clear fell to exactly one eighth (137,616 to 17,202
cycles) and the two load/store states it shares with other paths fell by 346,534; the
suite fell by the sum, 466,948 cycles. Aggregate, matrix and strided accesses still
take the serial path through the banks. The shader-core bench's check count moves with
these passes (1,487 after SP2, 1,207 after SP3): one of its checks runs every cycle of a
held dispatch, so the count follows the dispatch length. It is not part of the loop's
identity fields.

What SP2 did not move. The graphics sessions fell under 1% with SP2: their fragment
wait is not in scratch or scheduling. On the single-triangle session the fragment wait
is 30,711 of 75,740 rasteriser busy cycles (40.5%), and on the sampled one 113,194 of
158,078 (71.6%). A fragment wave reads its inputs and writes its outputs through the
record path, one 32-bit word per lane per request. That path, not the engine's local
storage, is the graphics lever: it is what the record store (R3) and lane-vector record
access replace.

The device bench now prints the same state histogram per session. On the SP3 tree the
wave engine's busy cycles in four graphics sessions split as follows:

| Session | Wave busy | Device-memory load/store states | Fetch, stream, pre-execute | Arithmetic and texture |
|---|---:|---:|---:|---:|
| single triangle | 30,830 | 19,857 (64%) | 5,463 (18%) | small |
| four attachments | 112,449 | 60,177 (54%) | 23,556 (21%) | small |
| derivative chain | 246,975 | 131,396 (53%) | 55,385 (22%) | 3% |
| sampled | 113,176 | 19,806 (18%) | 3,990 (4%) | about 60% |

A request on that path costs five states and carries one 32-bit word, although the port
carries 64-bit beats: a four-component store is four requests per lane. SP4 pairs two
adjacent words of a lane into one request. The sampled session is a different problem:
its time is in the lane-serial sampler and its arithmetic jobs (FP9).

What SP4 showed. Shader-port requests fell by a third on every graphics session (3,492
to 2,328 on the single triangle) and fragment wait fell 20–34% on the twelve non-sampled
sessions and 6–7% on the two sampled ones. Whole-session cycles fell 4–9%. The fourteen
graphics sessions of the loop now total 3,300,122 cycles, against 4,004,618 after RP2
(−17.6%). What remains on that path is one request per lane per beat at five states
each, two of them waiting on the port; removing those needs more than one request in
flight (R2) or the record store (R3).

What SP5 showed. Issuing the common non-atomic request from `W_LSC` and accepting it
straight into `W_LS2` removes one wait state per device-memory access on the accepted
path. The shader suite fell 1.45% (3,720,154 to 3,666,123 cycles; `perf.busy` −2.24%)
and the graphics sessions fell 0.2–2.8% on `pass.cycles` and 1.4–3.9% on `stat.busy`;
the clear and transfer sessions are unchanged because they do not take the shader
load/store path. The gain is small because `W_LSC`→`W_LS1`→`W_LS2` was already only
one state inside a roughly five-state request, and the bench accepts every request in
the same cycle; the term that still dominates is the port wait itself and the
per-lane serial issue, which are R2 and R3, not more sequencing.

### 11.8 Harness of record

From 2026-11-13 every simulation and synthesis run that counts as evidence goes through
`verif/regress/remote/testharness_proxy.py apu-leaf` on an isolated snapshot, built with
the repository Verilator 5.008 (mod). Local runs on the development host used the
system Verilator 5.020; they agree on cycle counts but hid four problems that the pinned
compiler exposed on the first remote runs:

| Finding | Effect | Resolution |
|---|---|---|
| The repository compiler's unroll policy (256 iterations, 131,072 statements) reached `tb_g6lc_apu_rast` through the environment | one 344 MB translation unit; the bench had not built remotely since at least 2026-11-11 | `run-apu-rast.sh` unsets the policy; the bench builds and passes in under 3 minutes with the same PASS line |
| The same policy expanded an 80-iteration stress loop in `tb_g6lc_apu_objtab` | one 245 MB translation unit; the `unit` and `synth` stages stalled on it | the loop bound is a run-time value (`+ks_iters`, default 80); the stress case's model now snapshots the list it kills from; the bench passes (17 cases, 102,092 checks) |
| `RowCacheEntries=0` did not lint: constant row fields made four selects out of range | the long-decode arm did not build | the hit branch reads operand fields formed inside the generate arms |
| `maxStorageBufferRange` was raised to 128 MiB in the profile and tables without regenerating the reply goldens | transport, reply and session vectors expected the old value; `vgtop` stopped at its first step | goldens regenerated with `vn_golden.py` (transport, core, reply, session) |

| The simulator-PGO launcher appends the unroll policy as flags, so unsetting the environment was not enough once `tb_g6lc_apu_rast` ran in the `unit` stage | the same 344 MB unit, under PGO | `run-apu-rast.sh` calls the compiler behind the launcher; the suite passes in the `unit` stage in under 3 minutes |
| `tb_g6lc_apu_cmdexec` case 5 dispatched from a second primary buffer without binding a pipeline; the executor clears bound state per primary buffer | three failed checks (`two-buf`) on both compilers | the bench binds a pipeline in that buffer; 171 checks pass |

Stage additions made for this: `perf` (the loop, §11.1) and `synth-shwave` in the `synth`
stage. Admission reads a collected capture (`--admit-from`).

With these, the `unit` stage is green on the pinned compiler for the first time since
2026-11-06: leaf `apu-leaf-20261113T130024-8880e43b51ed`, 17 of 17 suites.

Rules that follow from a shared builder:

- A leaf snapshots the working tree. Edits made while a set of leaves is being launched
  give the leaves different source identities; record which files differ.
- Run at most two leaves at a time. Under load the simulator-PGO defaults (build 600 s,
  training 60 s) time out and the stage reports INCOMPLETE; raise them with
  `--env APU_SIM_BUILD_TIMEOUT=5400 --env APU_SIM_TRAIN_TIMEOUT=600
  --env APU_SIM_PGO_TIMEOUT=10800`.
- A bench whose testbench loops have constant bounds is a build-time risk under the
  unroll policy. New stress loops take their bound from a plusarg.

Open on the harness: the `soc` stage (`cva6-venus`) stops in simulator-PGO training on
the bench's idle-fixture check ("Venus fixture driving DMA during VenusOff arm"). It last
passed on 2026-10-13. No file of this program is on that path; the cause is not
established. The first DMA beat of the enabled fixture in the `+venusoff` arm names the
requester and settles it.

The `synth` stage on the RP4+SP2 tree (leaf `apu-leaf-20261113T130512-03c430a0c479`):
`synth-vgpages`, `synth-objtab` (48,764 cells / 5,457 flops; object memory 75,101 /
17,021), `synth-cmdexec` (152,261 / 23,062), `synth-vgctl` and `synth-rast` (247,744 /
23,988) passed with no latches. Three screens did not:

- `synth-vnpump` and `synth-vnfront` fail their enabled screen in the slang front end
  ("unroll limit of 4000 exhausted" on the front end's 32,768-word staging memory). The
  pump now passes a `PayStageWords` parameter through and both enabled screens size the
  staging memory at 64 words, as the front end's small screen already did. That removes
  the front-end error, but the screens are still too slow to be a gate: at the default
  64 rings the pump's process passes did not finish in 57 minutes, and with 4 rings the
  run is still in the optimisation passes after two hours. The screens need a small
  ring and fence geometry; not done.
- `synth-shwave` (new in the stage) timed out at four hours in the first process pass
  of its small screen. Root cause found 2026-11-14: the wall is not the script's
  `proc` but `read_slang`'s own process lowering — slang runs `proc_clean`,
  `proc_rmdead` and `proc_prune` as sub-passes of the frontend (log prefix `1.x`),
  and `proc_prune` on the ~56k-process flattened fixture had not finished after
  1 h 45 min at 100% CPU on both the pre-SP1 file and the 16-row-cache file, so
  SP1–SP4 are exonerated. `read_slang --no-proc` skips that lowering; the script
  then runs the `proc` sub-pass sequence itself, where `proc_prune` can be
  omitted (it only deletes overwritten assignments — an upper-bound cell count,
  acceptable for a screen). Ad-hoc runs of that flow (`/tmp/g6lc-shsyn/noproc*.ys`)
  got past `proc_mux` but then stalled in `proc_dff` (~619/10,475 state-DFF items
  after ~22 min, killed 2026-11-14) — so the intractability is not only
  `proc_prune`; the process passes as a whole do not converge on this fixture at any
  tested parameterisation (reduced geometry `ShaderRegs=16 MaxWaves=1 …` included).
  Working position: the `Enable=0` inert screen plus the functional `unit`/`top`/
  `perf` evidence carry correctness; a default-geometry `Enable=1` cell/flop figure
  for shwave/vnpump/vnfront is recorded as an open synthesis limitation, not a pass.
  The two surviving reduced-geometry screens (`vnfront-small`, `vnpump-r1`,
  `PayStageWords=64`) were still inside `synth -noabc`/`opt` loops at last check —
  diagnostic only, no verdict claimed. Until a screen completes, SP1–SP5 have no
  cell or flop figure.

## 12. Frame-path reconciliation and next-rung detail (2026-11-21)

§9's stage costs and §10.2's reference frame were written before RP1–RP4, SP1–SP5 and
the R3 record store landed. This section restates the frame breakdown against the
measured frontier and gives the module-level detail for the rungs that are now the
binding constraints. Same evidence rules as §8–§11: per-clock figures only, "measured"
is a counter or bench line, "estimate" is a state-list count, and no frequency or
frame-rate claim follows.

### 12.1 Where the frame's cycles go now

The landed sequencing passes moved both engines off their decode/control overhead.
Measured deltas from §11.7:

| Engine | Origin | Now | Driver |
|---|---:|---:|---|
| Rasteriser, cycles per pixel written | 252 | 96 | RP1–RP4 (sequencing + write-behind) |
| Shader, cycles per wave-instruction | 35.0 | 21.3 | SP1–SP5 (row cache + sequencing) |

The bottleneck has therefore **shifted from control to data movement**, in three
places that are now the binding constraints:

1. **The device-memory port is the shared serializer.** `g6lc_apu_apmem` is still one
   global FSM, `MaxOut=1`, one beat in flight for every requester in the device,
   granted by fixed port-index priority across the eight `APU_MP_N` requesters
   (`PUB/VQ/CTL/OBJ/PUMP/SH/RAST/EXEC`). Post-SP5 the shader's device-memory
   load/store states
   are 53–64% of wave busy on the graphics sessions (single triangle 64%, four
   attachments 54%, derivative chain 53%; only the sampled session is lower at 18%
   because its time is in the sampler). On the rasteriser side memory requests are the
   largest single term at ~37 cycles per fragment. R2 was deferred on 2026-11-14 when
   the aggregate shader-busy share read 2.3%; that figure was dominated by non-graphics
   vectors and is superseded — on the frame path the port is the limit, not a corner.
2. **The record path is on-chip but still port-serialized and narrow.** The record
   store (R3) already serves the wave engine's record traffic: `ls_rec_q` record
   accesses are `dom=1` aperture requests inside `[rec_base_i, +APU_REC_CARVE_BYTES)`,
   the same 64 KiB scratch carve `isrec_w` answers from `tc_sram`. So records no
   longer cross DRAM — but every beat still transits the single-outstanding `apmem`
   FSM, and the issue width is still one 32-bit word per lane per request (~5 states,
   two port waits; a four-component store is four requests per lane). SP4 paired two
   adjacent words and SP5 removed one wait state; what is left is apmem's global
   serialization (NR1) plus the per-lane issue width (NR2).
3. **Interpolation and output merge remain serial float chains on the rasteriser.**
   Interpolation is still ~64.7 cycles per fragment (the largest rasteriser class after
   RP2), merge ~17.8. FP6 (move interpolation onto the fragment wave's lanes) is gated
   on TP3/G-T2; FP10 stage A (parallel merge) is independent and unstarted.

The sampled/texture session is the exception: ~60% of its wave busy is arithmetic and
texture (lane-serial sampler in the wave FSM), which is FP9's target, not the port's.

### 12.2 Restated reference frame

Recomputing §10.2's hypothetical 1080p frame with the measured rates (still lower
bounds; shader time excluded; "today" is the post-R3 state):

| Term | §10.2 (pre-pass) | Now | Note |
|---|---:|---:|---|
| Scan, interpolation, merge | ~1,300 M (250/pix) | ~500 M (96/pix) | RP1–RP4; interpolation still dominant |
| Vertex fetch + setup | ~185 M | ~185 M | untouched; FP4/FP5 pending |
| Clears | ≥ 8 M | ~5 M | RP4 write-behind cut the wait ~40%; FP3 burst clears not landed |
| Texture | ≥ 104 M | ≥ 104 M | unchanged; FP9 not started |
| **Fixed-function total** | **≥ 1,600 M** | **~790 M** | roughly halved, still pixel-bound |

Pixel work remains the dominant term. The G-F2 targets (1 pixel/clock fill, 4 bilinear
samples/clock) are unchanged and still the smallest point at which shader throughput,
not fixed function, decides the frame — but the distance to them is now ~100× on fill
(96 cy/pix → 1) rather than ~250×.

### 12.3 Next-rung implementation detail

The rungs below are ordered by measured leverage on the frame path, not by the §11.4
table's original deferral. Each carries the §11.5 pass contract implicitly: the counter
that must move, the equality argument, the blast radius, the timing note, and the
admission tier.

**NR1 — memory port: per-requester slots and bursts (R2 / TP2b, pulled forward).**
The single largest measured term on both engines. Concretely:

- `apu_mp_req_t` (`corev_apu/apu/include/g6lc_apu_mp_pkg.sv`) gains a beat count
  `beats[3:0]`
  and the response gains a per-beat `last` flag; requesters leaving `beats==0` see
  today's single-beat behaviour. A burst is one request returning N responses.
- `g6lc_apu_apmem` moves from one global FSM to **one transaction slot per port**
  across the eight `APU_MP_N` requesters (`PUB/VQ/CTL/OBJ/PUMP/SH/RAST/EXEC`,
  `g6lc_apu_mp_pkg.sv`). AXI ID = port index; `apu_dma_id_t` is 4 bits and already
  covers 8 ports. The per-port contract — at most one outstanding per port, exactly
  one response per request, `flush_i` drops only unissued requests — is unchanged;
  only the *global* serialization goes. Window classification, currently
  combinational on the request, is registered so it does not lengthen the accept path.
- The burst immediately serves: the 64-byte texel-cache fill (eight single beats in
  `W_TXF0`/`W_TXF1` today), the four-beat descriptor-record fetch (`W_DS1` onward),
  object-table/objpay line fills, and the record beats — the four consumers §8 TP2
  already enumerated.
- Downstream must accept several outstanding IDs: `g6lc_apu_tdma` (the 2:1 join), the
  bench AXI slave models, the bridge DRAM model, and the testharness join.
- Ordering argument to prove, not assume: order within a port is kept; the used-ring
  publication chain is on one port; work completion precedes the fence by state-machine
  sequencing, not by arbitration. Controls: the address-channel order checks in
  `sys-venus`/`cva6-venus`, and `memory.pipeline_barrier.*`.
- Expected: the memory share divided by ~8 on eligible accesses; on the rasteriser the
  ~37 cy/fragment request term and on the shader the 53–64% device-memory state share
  are the counters that must move. Blast radius: `apmem`, `mp_pkg`, `tdma`, the wave
  LSU request path, the rasteriser `S_MPW`/record writes, xfer legs, and every AXI
  slave model. This is a multi-module rework — the largest single structural change
  since the record store.

**NR2 — wave-engine record issue width (extends SP4/SP5, needs NR1).**
Records are already on `tc_sram` (R3); what remains is that the wave LSU still issues
them one 32-bit word per lane per request — ~5 states and two `apmem` waits per beat,
four requests for a four-component store. Two separable widenings:

- (a) **Lane-vector record access.** Records are per-invocation contiguous (152 B each,
  the six `OFF_*` carve buffers), so lane *l*'s word-*w* sits at
  `base + l·record_stride + w·8` — a **cross-lane strided gather**, not a contiguous
  vector. One request can still carry every active lane's same-word via a stride
  parameter: classify active lanes, issue one strided access, demux on return. This is
  the §8 TP2a lane-vector load/store applied to the `ls_rec_q` path and removes the
  per-lane serial issue that SP4 only halved. Bounds and the dead/helper-lane Output
  store rule are unchanged — the mask is applied to the same lane set.
- (b) **Multi-word record beats.** Where consecutive record words are contiguous
  (the 18-beat FS-in record, the FS-out write), issue them as the NR1 burst so one
  request returns the run instead of one beat per request. This is the same burst
  mechanism NR1 adds to `apu_mp_req_t`, applied to the record stream.
- Both need NR1's per-port slots to pay off — a wider request still serialises behind
  the one-in-flight FSM today. Sequence after NR1.
- Control: every `ue_gpos_*`/`ue_cpos_*` session bit-exact (the R3/SP4 admission
  pattern), plus `pipeline.monolithic.vertex_input` and the FS-in varyings vectors.
  The atomic/robust-access vectors are the fails-if-wrong control for the lane-set
  masking.

**NR3 — fragment-wave preamble for interpolation (FP6, still gated on TP3).**
Unchanged from §9.3 FP6 and §11.3 point 2: at 21.3 cy/insn the preamble would cost
~18 cy/fragment only after G-T2 (≤4 cy/insn). Do **not** pull this forward — the
rasteriser keeps the chain and schedules it (RP2) until TP3 lands. The dependency is
recorded so FP6 is not mis-scheduled.

**NR4 — output merge stage A (FP10-A).**
Independent of the port and of TP3; can run in parallel with NR1/NR2. Read shader
outputs from the record store (already `tc_sram` via R3 — FS-out records are the
wave's `ls_rec_q` writes), decode/blend/encode the four channels in
parallel with per-channel operation order unchanged, combine adjacent pixels into full
64-bit beats and rows into bursts, read destination lines once per run, and write
through a pixel-store interface. The interface is what keeps stage A from being
discarded when the tile engine (FP10-B) lands. Control: the blend/depth/stencil/
logic-op vectors; `pipeline.monolithic.blend`, `fragment_operations.*`.

**NR5 — pipelined issue and banked RF (R5 / TP3).**
The shader's 21.3 cy/insn is now the largest *compute* term and the gate for FP6 and
TP7. Per §8 TP3/TP3a-3: bank the register file into 128-bit `tc_sram` macros bounded by
a new `RfRows` parameter (today 2 MiB/core of flop RF is outside the SRAM envelope),
give it two read ports, then pipeline row-read → operand-read → execute → write-back
with write-back-to-operand forward and a stall for multi-cycle units, dispatching on
the row's opcode class instead of `unique case (opc_q)` in `W_EX`. Target 2–4
cy/wave-instruction = 16–32 FP32 ops/clock/core. The TP3a-3 measurement stands: the
operand stream is fetch-width-bound (~12% of bench cycles), so the real lever inside
TP3 is decode-ahead/lookahead (3a row-cache-hit path, then 3b RF port-1 prefetch with
RAW check, then 3c wider fetch) — not the dual RF port alone, which is already landed
and cycle-exact.

**NR6 — texture unit (R6 / FP9).**
For the sampled session (~60% arithmetic+texture). Factor the lane-serial sampler out
of the wave FSM into `g6lc_apu_tex`, one request/response per quad; cache the per-image
mip layout beside the descriptor record; read a whole cache line per access and
extract/filter the four footprint texels in parallel; a larger set-associative cache
with SRAM tags, burst fill, persistent across batches (FP8). Generate decode/encode
from the format table; cube/3D/1D from the §9a address function. Control: the texture
corpus bit-exact, then `texture.*` and `pipeline.monolithic.sampler`.

### 12.4 What this means for the gate ladder

- **G-T1 / G-F1 (wall-time)**: NR1 is the highest-leverage single change for CTS wall
  time — it attacks the port wait that dominates both the rasteriser's request term
  and the shader's device-memory states, which are what make the `texture.*`,
  `sampler2d_fixed_vertex` and `compute.pipeline.basic` groups run long. It should be
  pulled forward alongside B/C exactly as the plan already allows when wall time
  blocks a group.
- **G-T2**: unchanged — NR5/TP3 is the path; nothing in NR1–NR4 substitutes for it.
- **G-T3 / G-F3 (Pareto)**: still gated on TP3a + the `area-attr.sh` attribution. The
  candidate core counts (8/24/96) remain not credible at today's per-core state.
- **CTS mapping**: NR1+NR2 serve `draw.*`, `rasterization.*`, `pipeline.monolithic.*`,
  `texture.*` wall time; NR4 serves `fragment_operations.*`, `renderpasses.*`;
  NR6 serves `texture.*`, `image.*`; NR5 serves every shader group's throughput and is
  the prerequisite for FP6/TP7. None of these is a conformance fix — they shorten wall
  time on groups whose *results* are already correct or already failing for named
  functional reasons. Conformance remains workstreams A/B/C/E; this section is the D
  (throughput) track made concrete.

### 12.5 Standing caveats

- All figures are per clock on the ideal memory slave (three cycles per request,
  always ready); real DRAM latency widens every memory term above.
- "Now" column in §12.2 uses post-R3 measured rates; sessions that bypass `apmem`
  (`tb_apu_mp_mem`) cannot see the record store, so NR1/NR2 gains must be admitted on
  the `sys-venus`/`top`/`perf` cohort, not the unit benches alone — the R3 precedent.
- SP1–SP5 and the shwave/vnpump/vnfront enabled screens still have no cell/flop figure
  (§11.8 open limitation); NR1's multi-slot `apmem` will need its own `synth` screen
  before area claims are made.

## 13. Vulkan 1.4 frame aspect matrix (2026-11-21)

§8–§12 are the throughput view. This section is the complementary **capability**
view: every aspect a Vulkan 1.4 frame crosses, its current implementation, the gap to
the 1.4 contract, and the workstream/pass that closes it. It consolidates
`apu-vulkan-engine.md`, `apu-graphics.md`, the plan's workstreams A–F and §9.5/§10.1
rather than restating them. "Status" is honest: landed-and-verified, partial, or
absent — never an advertised-bit claim. Profile values are from
`corev_apu/apu/tools/vn_device_profile.toml`; where the profile and the elaborated RTL
width disagree, the row says "verify", because capability honesty is workstream A.

| # | Frame aspect | Current implementation | Status | Gap to Vulkan 1.4 | Closes via |
|---|---|---|---|---|---|
| 1 | Host app → loader → ICD | Stock Mesa `libvulkan_virtio` is the target; Venus serialises commands onto a host-visible blob ring; SPIR-V via `vkCreateShaderModule` | partial | diagnostic `virtio-mmio`, not x86 `virtio-pci`; SHM LEN/BASE returns all-ones (no host-visible region); capset support partial | W9, plan F |
| 2 | Instance/device truth | `vn_device_profile.toml` apiVersion **1.1.0**; audit reports 19 findings / 29 rules | partial | not 1.4; several limits below core minima; feature bits exceed implementation | W1, plan E (per-apiVersion ladder) |
| 3 | Command buffers & queues | `vnfront/vndec/vnrep/vnpump` decode; `cmdrec`/`cmdexec` G3b-iii chunk chains; `vqwalk` rings 0/1; `doneq` 16 fence slots | partial | secondary CBs, pool reset/trim, `READN` bursts landed; indirect+`DispatchBase` landed; one executor serves all families | A, plan C |
| 4 | Synchronisation | fences, events, barriers; `CmdSet/Reset/WaitEvents` | partial | timeline semaphores, `synchronization2`, external sync, per-queue families | W2, plan E |
| 5 | Descriptors | F5 memory-resident 32 B records; pool/layout/set/update; dynamic-index LSU fetch + cache | partial | `maxBoundDescriptorSets` **4** (need 7, UE wants 9); binding rows in CAM; descriptor-indexing/bindless/descriptor-buffers/push-descriptors partial | plan P7, B, E |
| 6 | Memory / VM / residency | `objtab/objmem/objpay`; `vgpages` aperture allocator; `apmem` single-outstanding; 3d-d host-visible backing | partial | no GPU VM/page tables/BDA/sparse/coherent L2; `apmem` one beat device-wide (NR1); residency = 8-slot module LRU | W5, NR1 |
| 7 | Shader modules / SPIR-V | `shmod` commit scanner + `shwave`/`shcore`; compute model 5; `MaxWaves=16`×8 lanes | partial | workgroup invocations **128** (need 256); operand-complete ISA growing (functions/discard/FragDepth/atomics/pack/SFU landed per G3a); no geometry/task/mesh/tess | B, TP3a, NR5 |
| 8 | Vertex fetch / assembly | `rast` `S_GA_*`: index+attr windowed reads, serial convert, record writes; 63-vertex batches | partial | strips/fans >1 batch refused (FP4 carry-last-two); vertex-format table partial (integer 8/16/32 landed); no post-transform reuse admitted (TP5 off) | C, FP4, TP5 |
| 9 | Clipping / setup / cull | `S_PR_*`/`S_OC*`/`S_CP_*`/`S_T*`; Sutherland–Hodgman; ~45 serial float ops/tri | partial | viewport transform recomputed per corner (FP5 screen cache); setup on one FMA/div/converter | C, FP5 |
| 10 | Rasterisation / interpolation | `S_SCAN` 2×2 blocks, six-product coverage, perspective-correct varyings, helper lanes | landed-basic | interpolation ~64.7 cy/frag is top rasteriser class; moves to wave preamble only after TP3 (NR3/FP6); no MSAA | C, FP6, FP10-B |
| 11 | Depth / stencil / blend / ROP | early-Z D32/D16; late-Z; stencil compare; blend/logicOp; `S_ROP_*`/`S_BL_*` | landed-basic | `maxColorAttachments` **4** (need 8); merge one-fragment-at-a-time (~17.8 cy/frag); no store/resolve step; depth-bias slope bug fixed (`slope_bias_late`) | C, NR4 (FP10-A), FP10-B |
| 12 | Textures / images / sampler | implicit-LOD trilinear; format table + sRGB LUT; `W_TX*` in wave FSM; 16-line 64 B texel cache | partial | 1D/3D/cube/array/shadow fault; no BC1–7, compare, gather, aniso; lane-serial sampler (~60% of sampled session) | B, NR6 (FP9), FP8 |
| 13 | Compute dispatch | `shcore`/`shwave` workgroups; `DispatchIndirect`+`DispatchBase` | partial | workgroup size/count/invocations below 1.4; subgroup ops basic; shared-memory slab/barriers partial | B, CTS-1/2 |
| 14 | Geometry / task / mesh | none | absent | all of it; mesh/task are 1.4-relevant for UE/Source2-class workloads | W8, plan E |
| 15 | Ray tracing | none | absent | RT pipelines, accel structures, SBT, traversal, compaction — not started | W7 |
| 16 | Advanced / GPU-driven | descriptor sets 4 (need 9); bindless partial; indirect draw landed; VRS none; transform feedback none | partial | bindless descriptor-indexing, mesh/task amplification, `VK_EXT_device_generated_commands`, conditional rendering | W8, plan E |
| 17 | Fragment / vertex completeness (G3c) | points/lines/restart/strips, stencil, depth bias/clamp, input attachments, secondary CBs, indirect, clear/blit/resolve, occlusion/timestamp queries, MSAA 4× — per plan C, largely landed or in flight | partial→landed | MSAA needs tile engine (FP10-B); 8th attachment needs NR4/FP10-A width; full format table (R4) | C, R4, FP10 |
| 18 | Queries | `vkGetQueryPoolResults` truthful readback; occlusion/timestamp/pipeline-stat | partial | timestamp period needs a real clock; pipeline-statistics counters partial | C, FP12 |
| 19 | WSI / presentation | **none** — control queue decodes no scanout/flush/display/EDID; `num_scanouts=0` | absent | entire path: scanout, blob-backed present (pointer flip), external sync, DRM/KMS, virtio-pci transport | W9, FP13, plan F |
| 20 | CTS / release | CTS-0…5 ladder; `vk-default.txt` must-pass; groups currently fail/abort for named reasons | in-progress | full conformant pass; x86-64 UE/CS2 qualification; physical synth/timing/FPGA | W10, plan F |

### 13.1 Reading the matrix

- **Two tracks, one frame.** Rows 1–6 and 19 are the *host/transport/memory* track
  (workstreams W1/W2/W5/W9); rows 7–18 are the *device pipeline* track (W3/W4/W7/W8).
  They meet at the `apmem` port and the record store — which is why NR1 (§12) is on the
  critical path for both.
- **Honest breadth vs depth.** Rows 8–12, 17 are the most complete (real vertex/
  fragment shading verified against Mesa/llvmpipe); rows 14–16, 19 are absent or
  near-absent. The release contract is "all of them," so the absent rows are the long
  pole, not the polished ones.
- **Profile-vs-RTL is a live check.** `maxPushConstantsSize` now reads 256 in the
  profile while §10.1 recorded an RTL `push_q[32]`=128 B width — either the RTL was
  widened (the `pushwide`/`fs_push` work) or the profile over-advertises. Every such
  pair is a workstream-A audit item; the matrix marks them "verify" rather than
  asserting.
- **Performance and conformance are orthogonal gates.** A row can be functionally
  complete (17) and still miss its throughput target (11 merge serial, 12 sampler
  serial); §12's NR passes address the latter without changing the former's results.

### 13.2 The frame's two hard walls

Two aspects bound everything else and are worth naming as the frame's structural
ceilings until they move:

1. **`apmem` single-outstanding** (row 6/NR1) — one beat in flight for the whole
   device caps every stage that touches memory: vertex fetch, record traffic, texture
   fills, descriptor reads, ROP writes, transfers. It is the shared serializer §12.1
   identified; no per-stage pass substitutes for it.
2. **The serial wave/raster micro-sequencer** (rows 9–12) — even with the port fixed,
   interpolation, merge and sampling run as one-operation-in-flight chains until TP3
   (NR5) and the tile/texture units (NR4/NR6/FP10-B) land. These are the G-T2/G-F2/G-F3
   gates.

Everything else — descriptors to memory, sync2, WSI, RT, mesh — is breadth that can
be built on top once these two walls have a scalable shape, because they determine
whether the added features have somewhere fast to run.

## 14. NR1 implementation contract — multi-outstanding memory port (2026-11-21)

§12.3 NR1 and §13.2 wall 1 name `apmem` the top structural constraint. This section is
the implementable contract for it — the interface delta, the slot design, the ordering
and reset semantics, and the verification gates — specific enough to start RTL against.
It changes cycle counts and port concurrency only; no requester's visible results may
change (§1 correctness-preserving). Line numbers drift; names are the contract.

### 14.1 Interface delta (`g6lc_apu_mp_pkg.sv`)

- `apu_mp_req_t` gains `beats[3:0]` (burst length in 8-byte beats; `0` = one beat,
  today's behaviour) and, for writes, the beat data already streams on `wdata` per
  beat as today — a burst read returns `beats` responses.
- `apu_mp_rsp_t` gains `last` (set on the final beat of a burst) alongside `rdata`,
  `err`. A burst of N beats produces exactly N `rsp_valid` pulses, the last flagged.
- `beats` is sampled at accept; a requester may not change it mid-transaction. The
  per-port contract is preserved: **at most one transaction per port, exactly one
  response stream per accepted request, `flush_i` drops only un-issued work.**

### 14.2 Slot design (`g6lc_apu_apmem`)

Replace the single global FSM with **one transaction slot per port** (8 slots,
`APU_MP_N`). Each slot is a small FSM:

```
IDLE -> CLASSIFY -> ISSUE -> WAIT -> CAPTURE -> RESP -> IDLE
        (registered)  (AW/W/AR)      (per beat)   (rsp pulses)
```

- **Grant** is still fixed port-index priority (`PUB>VQ>CTL>OBJ>PUMP>SH>RAST>EXEC`),
  but now arbitrates *slot launch*, not the whole device: a granted port launches its
  slot; up to 8 transactions are then in flight concurrently (one per port).
- **AXI ID = port index.** `apu_dma_id_t` is 4 bits and already covers 8 ports, so
  each slot drives its own ID; the AXI interleaving rules then give per-ID ordering
  for free. No new ID space.
- **Window classification moves into the slot.** `dom`, the aperture/guest window
  compares, `isrec_w` (record carve) and `isvtx_w` (vertex cache) are evaluated once
  at `CLASSIFY` and registered into the slot, so the accept path stays
  non-blocking and the carve hit never reaches AXI. A carve hit completes in-slot
  with SRAM-latency responses and no AXI beat.
- **Burst assembly.** For `beats>0`, the slot issues one AR/AW and captures N beats;
  for carve hits it reads the `tc_sram` banks N times. Writes keep the existing
  narrow-strobe head/tail handling per beat.

### 14.3 Ordering, fence and reset semantics (the proof obligations)

These are the parts that must be *argued and controlled*, not assumed:

- **Per-port order is kept.** A slot retires its beats in address order and returns
  responses in order; a port never sees a later beat's response before an earlier
  one's. Cross-port responses may interleave — no requester may depend on
  cross-port ordering (today none does; the used-ring publication chain is a single
  port's stream).
- **Fence correctness is by sequencing, not arbitration.** Work completion precedes
  the fence because the executor/rasteriser state machines only advance a fence after
  their work item's `done` — which is downstream of response delivery, not of grant
  order. Controls: `memory.pipeline_barrier.*`, the `sys-venus`/`cva6-venus`
  address-channel order checks.
- **`flush_i`** drops, per slot, requests not yet issued to AXI (same semantic as
  today, now per-slot). A transaction whose AW/W/AR beat is being accepted runs to
  completion — `outstanding_o` is the OR of all slots' in-flight state, and the
  `vgsys` reset sequencer still waits `!outstanding` before `eng_rst_n`.
- **`idle_o`** = no slot busy and no AXI transaction in flight (was: the one FSM
  idle). Used by the same reset/idle observers.

### 14.4 Downstream and blast radius

- `g6lc_apu_tdma` (the 2:1 AXI join), the bench AXI slave models, the bridge DRAM
  model and the testharness join must accept **several outstanding AXI IDs** — today
  they see one. This is the widest blast radius: every memory slave in the verify
  path.
- Requesters that issue bursts: the wave LSU record/buffer path (NR2), the texel-cache
  fill (8 beats), the descriptor-record fetch (4 beats), objtab/objpay line fills,
  rasteriser `S_MPW`/record writes, xfer legs, and the `READN` payload reads. Each is
  a separate small change gated on this contract.
- Files: `g6lc_apu_mp_pkg.sv` (interface), `g6lc_apu_apmem.sv` (slots), `tdma`,
  `vgsys` (reset/idle aggregation unchanged), the AXI slave/DRM models, and every
  requester that opts into `beats>0`.

### 14.5 Timing, area, verification

- **Timing:** per-slot classification is registered; the grant mux is the same
  priority encoder, now feeding 8 slot-launch enables instead of one FSM. No new long
  combinational path; the widest cone is unchanged (the 8:1 request mux). 8 slots ≈
  8× the FSM state but each is small — record cells/flops from a `synth` screen
  before any area claim (the §11.8 open limitation applies: shwave/vnpump/vnfront
  lack an enabled screen; `apmem`/`vgsys` do have one).
- **DFT/power:** slots are flop state behind `tc_clk_gating` on the engine idle;
  `testmode_i`/`test_en_i` observability preserved per slot.
- **Verification gates (in order):** (1) `apmem`/`mp` unit bench — per-port ordering,
  burst last-flag, flush-drops-unissued, carve hits never reaching AXI, `beats=0`
  equivalence; (2) `sys-venus`/`cva6-venus` address-channel order checks unchanged;
  (3) `memory.pipeline_barrier.*` and the jitter arm (`+mp_lat_min=1 +mp_lat_max=20
  +mp_ready_pct=60`) for handshake safety; (4) remote `perf` leaf — same checked work,
  the §12.1 counters (rasteriser ~37 cy/fragment request term; shader 53–64%
  device-memory state share) must fall; (5) `synth` screen for cells/flops.
- **Admission:** T0 `perf` leaf always; T1 `top`/`synth` because it touches the device
  path; the counter that must move is port wait / device-memory state share, not a
  result. Expected direction per §8 TP2: memory share ÷~8 on eligible accesses —
  replaced by the measured counter delta on admission, not asserted here.

### 14.6 Ordering precondition — what the global serializer actually guarantees (2026-11-21)

Before NR1 is implementable, one correctness question must be answered, and a first
RTL audit (this section) shows it is *mostly already satisfied by design* — which
lowers NR1's risk from "semantic redesign" to "mechanical change + bounded audit."

**The hidden guarantee.** Today `apmem`'s single FSM serialises *every* port's
accesses into one total order. That is far stronger than the `apu_mp` contract
requires ("at most one outstanding *per requester*"): it also gives a **cross-port
total order** for free. NR1's per-port slots remove that — two ports' transactions
can now be in flight at once and complete out of order on the AXI fabric (AXI does
not order across IDs). Whether that is safe is a *memory-ordering* question, not a
throughput one.

**Engines already run concurrently.** `g6lc_apu_vgtop` runs rasteriser (`rs_done`),
shader (`sh_done`, split VS/FS via `work_id`), xfer (`xf_done`) and cmdexec
(`work_done_i`) as independent engines feeding one `doneq`; the `doneq` comment
states it outright — "engines run concurrently." So cross-port accesses *can*
overlap today only because the serializer forces them to. NR1 makes that overlap
real.

**The saving grace: drain-before-done is already the discipline.** Every engine
holds `done_o` until its memory is committed, not merely issued:

- `g6lc_apu_rast`: `done_o` requires `!wq_v_q[0]` — RP4's posted-write queue is
  fully drained (each entry popped only on its `mp_rsp_valid_i`), so done ⇒ every
  raster write has received its response. Comment: "drain before wave launch / done."
- `g6lc_apu_cmdexec`: "submit end drain[s] outstanding work via `work_done_i`."
- `g6lc_apu_xfer`, `g6lc_apu_vqwalk`, `g6lc_apu_objmem`: each tracks its
  single-outstanding beat(s) and drains to idle before completion.
- `g6lc_apu_shwave`: one outstanding access per wave, `wave_q` advances only in
  `W_SCHED`; done follows wave retirement, which follows LSU response.

So `done_o ⇒ memory-commit` holds per engine, and every producer→consumer edge that
crosses ports (shader writes FS-out record → raster reads it for blend; raster writes
vertex/primitive record → shader/assembly reads it; objtab write → shader/assembly
read) is separated by a done-barrier at work-item granularity (`sh_done_i(gfx_done)`
feeds `i_rast`; `work_id` routes VS vs FS dones). **If every such edge is
barrier-separated and every engine drains before done, NR1 preserves the only
ordering that matters** — the barriers still order the data, they just no longer
rely on the serializer for the in-flight overlap.

**The residual audit NR1 still owes** (do before merge, not after):

1. **Per-port, not just per-engine, drain.** `done_o` is per engine, but a port can
   carry accesses for more than one logical stream (e.g. `mp_req_o[2]`/SH serves
   shader record + descriptor + buffer traffic). Confirm no producer stream's last
   write can still be in `apmem` when a *different* consumer on the same port (or a
   done-barrier peer) reads it — i.e. the barrier implies *that port's* queue empty,
   not just the engine's FSM idle.
2. **Pipelined-draw overlap.** Vertex shader batch N+1 can be in flight while the
   rasteriser consumes batch N's records. If they share a record-carve region, a
   batch-N read could race a batch-N+1 write on the *same* port/region. Confirm
   record slots are per-batch-disjoint or that VS-done for batch N+1 cannot be
   issued until raster has consumed batch N (the `MaxWaves`/batch accounting).
3. **`flush_i`/reset during overlap.** With N slots, a flush must drop each port's
   *unissued* request independently and still run every *issued* AXI transaction to
   B/R — the §14.3 rule applied per slot, plus the used-ring/fence publication order
   (`doneq` → `work_done_i` → fence) must be re-proven under interleaved completion.

**Why this is safe, not just hopeful.** NR1 keeps "at most one outstanding *per
port*" (§14.1), so *within* a port request order is preserved exactly as today.
The only new degree of freedom is *across* ports — and every cross-port
producer→consumer data edge is already separated by a done-barrier whose
`done_o ⇒ memory-commit` (drain-before-done, above). A consumer therefore cannot
issue a dependent read until the producer's writes have returned their responses,
regardless of how the fabric interleaved the two ports' other traffic. Record-slot
reuse safety is likewise unaffected: whether a carve slot may be rewritten before it
is consumed is enforced by the allocator's logical free/used tracking, not by
memory ordering — NR1 changes transaction *timing*, never allocation. The one
pattern that *would* break this is a consumer that polls or lockstep-reads producer
data without a done-barrier; the engine set uses done-pulses throughout, so the audit
item is to *confirm no such edge exists*, not to add fencing.

**Conclusion for the landing order (§19).** NR1 is *not* blocked on a memory-model
redesign — the engine-level ordering discipline already provides the barriers NR1
needs. It is blocked on (a) the mechanical slot+ID+burst implementation, (b) the
three-point audit above, and (c) downstream multi-ID support in `tdma`/slaves/DRM.
Item (b) is a read-only RTL audit that can run *before* any NR1 RTL lands and is the
cheapest way to retire the ordering risk. Recommend it as NR1 step 0.

## 15. NR5/TP3 implementation contract — pipelined issue and banked register file (2026-11-21)

§13.2 wall 2 and §12.3 NR5 name the serial wave micro-sequencer the second structural
wall and the G-T2 gate (≤4 cy/wave-instruction). This is its implementable contract —
the pipeline, the register-file re-banking that is its precondition, the hazard and
decode-ahead rules measured in TP3a-3, and the verification gates. Like §14 it is
correctness-preserving: same operations, operands and order per invocation; only issue
width and overlap change. The reference for arithmetic legality stays §1 and the
Gate-1 bit-exact shader vectors.

### 15.1 Why the precondition is the register file, not the pipeline

The wave engine today reads its register file as `MaxWaves × ShaderRegs` rows of
`ShaderLanes × ShaderVec × 32` bits — 16,384 × 1,024 b ≈ 2 MiB per core at the `vgtop`
defaults, as two single-port `tc_sram` halves. That geometry is **outside the SRAM
envelope** (`AGENTS-configuration.md`: single-port, depth 64–4096, width 32–128, read
pipelined ≥2 cycles at 8 FO4; dual-port only for the register file). A pipelined issue
needs two operand reads and one write-back per cycle — impossible against a
single-ported 1,024-bit row. So TP3a (bank the RF) is not optional packaging; it is the
enabling structure.

### 15.2 TP3a — bank the register file (`g6lc_apu_shwave`)

- Re-express the RF as `RfRows`-bounded banks of 128-bit `tc_sram` macros: the
  1,024-bit architectural row becomes 8×128-bit banks (or 16×64-bit if the macro
  granularity favours it — decided by the macro leaf, not here). Rows in use are
  `waves_in_flight × ShaderRegs`; commit already knows the bound, so `RfRows` is a
  parameter sized from it, not a new limit.
- **Two read ports + one write port** on the banked RF (the envelope's dual-port RF
  exception). TP3a-2 (the dual port) is already landed and cycle-exact — it did not
  shorten the operand *stream*, which is fetch-width-bound (§15.4), but it is the port
  budget TP3's operand stage needs.
- `maxComputeWorkGroupInvocations` and the fragment batch size become **derived from
  the elaborated `RfRows`** (pattern CTS-P2), not typed into the profile — this is also
  the §10.1 path to the 256-invocation 1.4 minimum.
- Blast radius: `shwave` RF arrays, `shcore` slot/commit geometry, the `vgtop`
  `MaxWaves`/`ShaderRegs` defaults, `g6lc_apu_sh_pkg` row-width constants, every
  `shwave`/`shcore`/`vgtop` bench that binds the RF geometry, and the generated
  `sh_opcodes.py`/`spirv_scan.py` row tables if the row format moves (§15.3).

### 15.3 TP3 — the pipeline (`g6lc_apu_shwave`)

Replace the fetch/decode/read/execute/writeback FSM's serial walk with an in-order,
single-issue pipeline for row-eligible instructions:

```
ROW_RD -> OP_RD -> EX -> WB -> (forward to OP_RD)
```

- **ROW_RD** reads the predecoded row (SP1's `RowCacheEntries` store, or the TP1
  commit-time row once it lands) — opcode class, result row, type shape, operand
  rows/tags.
- **OP_RD** reads the operand values from the banked RF (two ports). A
  write-back-to-operand **forward** covers the adjacent-instruction RAW; a same-wave
  RAW beyond one stage stalls.
- **EX** dispatches on the row's opcode *class* instead of `unique case (opc_q)` in
  `W_EX`. Multi-cycle units (divide, sqrt, transcendental, texture, aggregate,
  matrix, calls/phi/switch) either stall the pipe or move to a generated micro-code
  ROM — the §8 decision deferred to the `area-attr.sh` attribution, not assumed here.
- **WB** writes the result row; the wave pick and PC advance fold into retire (the
  SP2 pattern), and a wave runs to its next barrier/end/quantum rather than
  round-robining per instruction (the §11.6 run-to-barrier default stays reversible).
- **Long-form fallback.** Instructions that do not fit the row keep the present word
  walk behind a flag — the retained walk is also the differential control (a parameter
  selects it module-wide), exactly as SP1's `RowCacheEntries=0` arm does today.
- Target: **2–4 cy/wave-instruction** = 16–32 FP32 ops/clock/core (G-T2), vs 21.3
  today. The pipeline is in-order and single-issue — no scoreboard — until measured
  otherwise.

### 15.4 The decode-ahead sub-passes (TP3a-3, measured — do not skip)

TP3a-3 established the operand stream `W_LD0`/`W_LD1` is the largest per-instruction
cost (~449k of 3.67M bench cycles, ~12%) and is **fetch-width-bound, not
RF-latency-bound**: `prog_addr_o`/`prog_data_i` move one 32-bit program word per cycle,
and the operand-value RF read is already issued one stream-cycle early. The dual RF
port therefore does not shorten the stream. The real G-T2 lever is overlap:

- **3a — decode-ahead on the row-cache-hit path only.** A lookahead runs
  fetch/decode/operand-prefetch ≥1 instruction ahead so N+1's operand stream overlaps
  N's execute. No operand prefetch, no hazard — the safe first cut.
- **3b — RF port-1 operand prefetch into a shadow `va_q`.** Prefetches N+1's operand
  values on the second read port; needs a RAW check against the retiring
  instruction's write rows (forward `wb_q` or stall on a same-wave hit).
- **3c — wider fetch.** `prog_data_i` 32→64 needs `i_prog` dual-read, but `i_prog`
  also serves `shmod`'s own decode/validation reads — the port budget needs care
  before this is chosen over 3a/3b.
- Hazards to hold constant: same-wave RAW (N writes a reg N+1 reads), taken-branch
  invalidation of the shadow, multi-row write-back, row-cache write-back timing.
  `W_IDLE` (~35% of cycles) is dispatch-bound and belongs to TP6/TP7 parallelism, not
  per-instruction pipelining — do not size TP3 against it.
- Row-cache *capacity* is not a lever: `RowCacheEntries=4096` saved only 0.04%; the
  61.5% hit rate is compulsory/conflict-bound, so 1024 stays.

### 15.5 Verification and gates

- **Gate 1 bit-exact** on every shader vector at every lane/wave geometry variant —
  the model has no geometry, which is the point (§1). The atomic vectors are the
  fails-if-wrong control for the run-to-barrier reordering; the `RowCacheEntries=0`
  long-decode arm and the `unique case`→class dispatch both keep a differential path.
- **G-T2 threshold:** ≤4 cy/wave-instruction on arithmetic-bound vectors, per-core
  cells and SRAM bits from a synthesis leaf, RF + row store inside the SRAM envelope.
- **Admission:** T0 `perf` leaf (same checked work, suite cycles fall); T1 `unit` +
  `top` because it touches `shwave`/`shcore`/`vgtop`; `synth` for the banked-RF cell/
  flop figure — noting the §11.8 open limitation that `synth-shwave` has no completed
  enabled screen, so the RF banking may be the first geometry that forces one.
- **Sequencing:** TP3a (banked RF + `RfRows`) is a hard precondition and lands alone
  first (cycle-exact, results identical); TP3's pipeline and the 3a→3b→3c decode-ahead
  then land as separate admitted passes so each counter delta is attributable.

## 16. NR4/FP10-A implementation contract — output merge stage A (2026-11-21)

§12.3 NR4 and §9.3 FP10 stage A: the output merge is the rasteriser's second-largest
class (~17.8 cy/fragment after interpolation) and the only NR rung fully independent
of NR1 and TP3 — it can land in parallel with both. This is its implementable contract.
It also carries the §10.1 `maxColorAttachments` 4→8 width, so it is a throughput pass
and a 1.4-capacity change in one. Stage A is immediate-mode only; the tile engine
(FP10-B) is a later, separate contract that reuses the same merge datapath and
pixel-store interface — building A against that interface is what keeps it from being
discarded.

### 16.1 What the merge does today (`g6lc_apu_rast`, `S_ROP_*`/`S_BL_*`/`S_DB*`)

Per fragment, per attachment (`at_q` cursor, already 3 bits = 0..7):

- read the fragment's FS-out record — two 8-byte beats (`S_ROP_R*`/`S_MPW`);
- with blending, read the destination pixel once (`S_BL_*` dst fetch);
- decode the shader output and destination through ~9 float ops, blend up to ~5 ops
  per channel (`S_BL_F1/F1B/F2B/M2/OP/ST`), encode back;
- write one 8-byte pixel with byte strobes (`S_ROP_WR`/`S_ROP_NX`); late depth adds a
  depth read+write (`S_DB*`/`S_ROP_L*`).

Three serial costs bound it: (a) fragments merge **one at a time in batch order** —
adjacent pixels are not combined, so an RGBA8 row costs one memory round trip per
pixel although a beat holds two; (b) the four attachments are processed **in series**,
each re-walking the read/blend/write chain; (c) FS-out records come from DRAM beats,
not the record store. RP4's write-behind queue already overlaps the *write* leg; what
remains is the read/compute/issue serialization above.

### 16.2 The stage-A datapath

- **FS-out from the record store.** The wave's FS-out writes are already `dom=1`
  `ls_rec_q` beats into the `[rec_base_i, +APU_REC_CARVE_BYTES)` `tc_sram` carve
  (§12.1 item 2). The merge reads the same window — no DRAM round trip per record
  word. This is a read-port addition on the carve, not new storage.
- **Parallel channel merge.** Decode, blend and encode the four channels in parallel,
  keeping the **per-channel operation order unchanged** — the same operations and
  operands, issued four-at-a-time instead of serially. UNORM/sRGB decode/encode use
  the generated format table (R4) where it exists; where it does not, the present
  per-format case list stays.
- **Pixel combining.** Adjacent fragments of a batch that land in the same 8-byte beat
  (two RGBA8 pixels, or the matching packing for the format) merge into **one write
  beat**; consecutive beats in a row merge into a **burst** on the NR1 port (§14).
  Where fragments are non-adjacent (overdraw, discard, helper lanes) the merge falls
  back to per-pixel beats — correctness never depends on adjacency.
- **Destination read once per run.** For a blend run covering a contiguous span, the
  destination line is read once into a small line buffer and reused across the run's
  fragments, instead of one read per fragment. The line buffer is `tc_sram`, sized to
  the widest attachment row the batch can touch (parameter, not a fixed 4).
- **Pixel-store interface.** All merged pixels leave through one `pixel_store` port
  contract (address, beat data, strobes, byte enables) that FP10-B's tile writeback
  will also drive. Stage A implements it as bursts to `apmem`; stage B re-targets it
  at tile SRAM without changing the merge math.

### 16.3 The 4→8 attachment width (§10.1, rides this pass)

- `apu_rast_draw_t.ca[3:0]`→`ca[7:0]`, `.blend[3:0]`→`.blend[7:0]`; `at_q` is already
  3 bits so the cursor needs no widening — the loop bound becomes 8.
- FS-out record locations and stride grow with the count (§10.1 varying/record row);
  the record stride is already a parameter per the ledger.
- `maxFragmentCombinedOutputResources` 16 is the real 1.4 bound, not just 8 colours —
  the merge's per-fragment resource accounting must count combined outputs, so the
  width change and the resource table land together or the profile over-advertises.

### 16.4 Ordering and correctness obligations

- **Per-pixel order is unchanged.** Merging adjacent pixels into one beat does not
  reorder fragments — each pixel's blend still sees the same destination value it
  would have seen serially, because the line buffer holds the pre-run destination and
  each pixel updates only its own bytes. Overlapping fragments in one beat are
  impossible by construction (one fragment owns a pixel).
- **Late-Z interaction.** `S_ROP_LC`/`S_DB*` depth bias uses per-primitive slope
  registers; the `slope_bias_late` flush (§11.3 defect fix) already forces
  single-primitive batches where needed. Stage A must not merge across that boundary —
  the batch boundary is the existing correctness seam, preserved.
- **Blend/logicOp/depth/stencil vectors are the fails-if-wrong control** — every
  `S_BL_*` op, `SRC_ALPHA_SATURATE`, `CONST_COLOR`, logic op on sRGB, per-attachment
  blend under MRT (the 62-case/31,749-check rast suite §11.7 hardened is the gate).

### 16.5 Verification and gates

- **Equality:** pixel-identical against the present merge on the full rast suite plus
  the blend/depth/stencil/logic-op vectors; the `jitter` arm for the port handshake.
- **G-F1-adjacent:** graphics-session cycles fall; the merge class (~17.8 cy/fragment)
  and the per-fragment memory-request count are the counters that must move — admitted
  on the `perf` leaf's frame section, not asserted.
- **G-F2 direction:** combining adjacent pixels + row bursts + record-store FS-out is
  the path toward 1 pixel/clock fill; the measured delta replaces the projection.
- **Admission:** T0 `perf` leaf; T1 `unit`+`top`+`synth` (touches `rast`, the device
  path, and adds `tc_sram` line buffer + read port); the `synth-rast` screen (which
  exists and passes, unlike `synth-shwave`) gives the cell/flop figure.
- **Sequencing:** independent of NR1/NR5 — land whenever its counter justifies; the
  pixel-store interface is the only forward commitment (FP10-B depends on it). The
  4→8 width rides it per §10.3 so no field is widened twice.

## 17. NR6/FP9 implementation contract — texture unit (2026-11-21)

§12.3 NR6 and §9.3 FP9: the sampled session is the one frame path whose bottleneck is
**not** the port — ~60% of its wave busy is arithmetic and the lane-serial sampler.
This is its implementable contract: factor the sampler out of the wave state machine
into a dedicated unit. It is also the path that unblocks general sampling breadth
(§13 rows 12/16) and the `texture.*`/`image.*` CTS groups, so it is simultaneously a
throughput pass and a feature enabler.

### 17.1 What the sampler is today (`g6lc_apu_shwave`, the `W_TX*` chain)

The sampler is ~40 states embedded in the wave FSM, run **one lane at a time**:

```
W_TX0..4  sampler/image record fetch (DS path)
W_TXM     per-mip layout walk (iterator, up to ~13 steps)
W_TXL0..C level + coordinate setup; W_TXC*/W_TXJ*/W_TXS*/W_TXG*/W_TXQ* compare,
          gather, projection and query-LOD tails
W_TXB/TXT texel address -> probe -> words; W_TXF0/F1 the 64 B cache-line fill
W_TXD     decode texel -> channels; W_TXA/A2..A4 accumulate the filtered weight
W_TXR0/R1 finalize lane result; W_TXN next lane / wave done
W_TXW/E/Q image-store beats, encode + sRGB search, query results
```

State held per sample: the gather list (up to 8 `{mip,border,iu,iv}` points),
`tx_mof0/1` mip offsets, `tx_acc1_q[4]` for the second mip level (trilinear),
`tx_bpp_q`/`tx_td_q` raw texel beats. The texel cache is **dispatch-scoped** —
`TexCacheLines × 64 B` `tc_sram`, direct tags in flops, invalidated per batch, filled
by eight single beats. A bilinear sample costs ≥20 cycles for its four texel reads on
cache hits (§9.1), so the path is ≤0.05 samples/clock — 320–1,900× below the
published fixed-function reference points.

### 17.2 The `g6lc_apu_tex` unit

- **One request / one response per quad.** The wave issues a sampling request for a
  2×2 quad (position, gradients or implicit-LOD inputs, descriptor record, sampler
  state) and gets back four filtered texel results. The unit owns the entire
  `W_TX*` chain internally; the wave sees a single multi-cycle op, like a texture
  "instruction" — this is what removes it from the per-lane serial FSM.
- **Per-image mip layout cached beside the descriptor record.** Today `W_TXM` walks
  the mip layout *per lane per sample*; the unit caches `{offset,pitch,extent}` per
  mip once per image (keyed like the descriptor-record cache) so the walk runs once
  per image, not per lane.
- **Level computed once per quad where the spec defines it per quad.** Implicit-LOD
  derivatives are quad-uniform; the present per-lane sequence did not need to
  recompute per lane. Where the spec makes LOD lane-dependent (explicit gradients,
  per-sample), the unit keeps per-lane level — the contract is spec-driven, not a
  blanket quad assumption.
- **Whole-line fetch, parallel footprint.** One cache-line read returns all four
  bilinear footprint texels; decode and the four-channel filter run in parallel
  (per-channel order unchanged). This replaces the per-texel `address→probe→read→
  decode→accumulate` serial loop and the eight-single-beat line fill (which also
  becomes an NR1 burst).
- **Persistent set-associative cache.** Larger than the 16-line direct-mapped flop
  cache: tags in `tc_sram`, filled by bursts (NR1), **persistent across batches of a
  draw** (FP8 invalidation: new draw, barrier, image store by the wave, or a write to
  an attachment also bound for sampling). This is the hit-rate fix the dispatch-scoped
  cache cannot give.
- **Format table decode/encode.** Decode and encode are generated from the format
  table (R4), replacing the fixed `W_TXD` case list; sRGB stays a LUT. Cube, 3D and
  1D addressing come from the §9a single address function — they fault today and are
  a 1.4/CTS requirement (`texture.*`, `pipeline.monolithic.sampler`).
- **BC decode and anisotropy stay unadvertised** until the per-codec decision —
  decode-on-fill is the mechanism, but no format bit flips before its vector passes.

### 17.3 Interface and blast radius

- New `g6lc_apu_tex` module + a request/response port pair on `shcore`/`shwave`
  (the wave's `W_TX*` chain becomes the request driver and result consumer). The
  transfer engine's blit path (§9.2 S11 scaled blits) reuses the same unit — one
  sampler, two clients.
- The descriptor record's sampler words (filters/mipmap/address/border/compare/
  LOD/bias, bytes 20–27 per §11 F5/5b) become the unit's input contract — already
  memory-resident, so no new descriptor plumbing.
- Blast radius: `shwave` `W_TX*` states (deleted or reduced to the request driver),
  `shcore`/`vgtop` port wiring, `g6lc_apu_xfer` blit reuse, the texel-cache `tc_sram`
  (moves/replaces the dispatch-scoped one), `g6lc_apu_mp_pkg` if the unit has its own
  memory port (it should share `apmem` via a port or ride the SH port's bursts).

### 17.4 Ordering and correctness obligations

- **Quad-uniform vs per-lane results must match the spec bit-for-bit.** The fails-if-
  wrong controls are the texture corpus (bit-exact today), the derivative/projection/
  gather/query sessions, and then `texture.*` + `pipeline.monolithic.sampler`. The
  `RowCacheEntries=0`-style differential arm applies: a parameter selects the
  in-FSM sampler vs `g6lc_apu_tex` for the whole module during bring-up.
- **Image store / atomic path stays in the wave** (`W_TXW/E/Q`) — the unit is a
  *sampling* unit; stores and atomics keep their existing memory ordering through the
  LSU. The cache invalidation rules above are what keep a store-then-sample sequence
  correct.
- **robustBufferAccess / out-of-bounds** texel fetches return the spec'd border/zero —
  the unit inherits the present bounds logic (`W_TXB`), not a new one.

### 17.5 Verification and gates

- **Equality:** texture corpus bit-exact, then the `texture.*`/`sampler` CTS groups;
  the sampled-session counter (arithmetic+texture share of wave busy) must fall on the
  `perf` leaf.
- **G-F2 direction:** ≥4 bilinear samples/clock on cache hits is the target (§9.4);
  measured samples/clock replaces the ≤0.05 today.
- **Admission:** T0 `perf` leaf; T1 `unit`+`top` (touches `shwave`/`xfer`); `synth`
  for the new unit's cells/flops — same §11.8 `synth-shwave` caveat applies to the
  wave-side change, but `g6lc_apu_tex` itself gets its own screen.
- **Sequencing:** needs NR1's burst fill for the line fills to pay off and FP8's
  persistence rules; the per-quad request interface is the forward commitment (the
  blit client and any future bindless path depend on it). Cube/3D/1D and BC/aniso are
  *feature* gates behind this unit, landed per-format with their own vectors — the
  unit's structure must not pre-judge which codecs ship.

## 18. NR2 implementation contract — wave record issue width (2026-11-21)

§12.3 NR2 and §12.1 item 2: the record store (R3) already serves the wave's
`ls_rec_q` traffic from `tc_sram`, so records no longer cross DRAM — but the LSU
still issues them **one 32-bit word per lane per request**, ~5 states and two `apmem`
port waits per beat, four requests for a four-component store. On graphics sessions
this is 53–64% of wave busy (§11.7). This contract widens the issue without changing
what any lane reads or writes. It is gated on NR1 (§14): a wider request still
serialises behind the one-in-flight FSM until per-port slots land.

### 18.1 The access geometry (corrected)

Records are **per-invocation contiguous**, 152 B each (`VSTR+8`), in the six `OFF_*`
carve buffers (`vsi/vso/fsi/fso/clip_out/clip_tmp`) inside `[rec_base_i,
+APU_REC_CARVE_BYTES)`. Two distinct patterns fall out:

- **Within one record — contiguous.** A record is 18–19 eight-byte beats sequential.
  Reading or writing a whole record (VS-in gather, FS-in varyings, FS-out store) is a
  **burst** candidate: one request, N beats (§14 `beats[3:0]`).
- **Across lanes at one word offset — strided gather.** Lane *l*'s word-*w* is at
  `base + l·record_stride + w·8`; for fixed *w* across lanes the stride is
  `record_stride` (~152 B), not contiguous. This is a **strided vector** access, the
  §8 TP2a lane-vector load/store shape — one request carries every active lane's
  same-offset word, demuxed on return.

These are complementary, not alternatives: bursts serve the per-record sequential
stream; the strided vector serves the per-word-across-lanes fan-out. Which dominates
depends on the access — FS-in varying reads are strided-gather-heavy (each lane reads
its own record's varying slots), FS-out stores are per-record contiguous.

### 18.2 The LSU change (`g6lc_apu_shwave`, `ls_rec_q` path)

- **Record-burst mode.** When `ls_rec_q` targets a contiguous run inside one record
  (the compiler/runtime already knows the record extent from the slot map), issue the
  run as one NR1 burst instead of N single beats. The demux writes each returned beat
  to its lane's destination — for a per-lane record this is still one lane's stream,
  so the burst is *per lane*, collapsing the 18 sequential waits into one transaction.
- **Strided lane-vector mode.** For the fixed-offset-across-lanes case, classify the
  active lane set (the same `act_w`/`dead_q`/`hlp_w` mask the LSU already computes)
  and issue one strided request `{base, stride=record_stride, lanes=popcount(mask)}`;
  on return, demux beat *i* to lane *i*-th-set-bit. This removes the per-lane serial
  issue SP4 only halved.
- **Interface.** Both ride the NR1 `apu_mp_req_t` extension: `beats` for the burst,
  and a new `stride`/`lanes` field (or a `vec` qualifier) for the gather — the §14
  contract's "requesters leaving `beats==0` see today's behaviour" extends to "leaving
  the vector qualifier clear sees today's per-lane path." The SH port (`mp_req_o[2]`,
  `dom=1`) already reaches `apmem`'s carve window.
- **Dead/helper Output-store rule preserved.** The present rule (dead/helper lanes
  lose device-memory stores but keep Output record stores, ~line 3667) is applied to
  the *lane mask* before the vector is issued — the mask, not the request shape,
  carries the semantics. Robust/bounds (`ls_bok_q`) and atomic serialization are
  unchanged; an out-of-range lane falls back to the per-lane path so
  `robustBufferAccess` counts stay exact.

### 18.3 What it does NOT do

- It does not widen the record store or move records — R3 already did that.
- It does not touch non-record device memory (buffers/images/descriptors) — that is
  TP2a's general lane-vector load/store, a separate consumer of the same NR1
  mechanism; NR2 is scoped to `ls_rec_q` only so its blast radius stays the record
  path.
- It does not change record *content* or layout — the 152 B stride and slot map are
  fixed by the carve; only the issue width changes.

### 18.4 Verification and gates

- **Equality:** every `ue_gpos_*`/`ue_cpos_*` session bit-exact through the carve
  (the R3/SP4 admission pattern), plus `pipeline.monolithic.vertex_input` and the
  FS-in varyings vectors; the atomic/robust-access vectors are the fails-if-wrong
  control for the lane-mask and bounds fallback.
- **Counters:** the §11.7 device-session table's "device-memory load/store states"
  share (53–64% on graphics sessions) and the per-request state count (~5 → fewer)
  are what must fall on the `perf` leaf; the record beats/request ratio is the direct
  measure.
- **Admission:** gated on NR1 (§14) — without per-port slots the wider request still
  serialises. T0 `perf` leaf; T1 `unit`+`top` (touches `shwave`/`shcore`/`vgtop`);
  `synth` subject to the §11.8 `synth-shwave` open limitation.
- **Sequencing:** after NR1 lands and its counter delta is admitted; the vector/burst
  qualifier is the forward commitment (TP2a's general lane-vector load/store and any
  gather/scatter-capable memory path build on the same `apu_mp_req_t` fields).

## 19. Landing order and critical path (2026-11-21)

§12–§18 give every actionable rung a contract. This is the dependency-ordered landing
sequence — what unblocks what, and the single critical path. Gates are the §11.4/§12.4
ladder; "blocked-by" is a hard RTL dependency, not a preference.

| Order | Pass | Contract | Blocked by | Unblocks | Gate |
|---|---|---|---|---|---|
| 1 | **NR1** `apmem` slots+bursts | §14 | — | NR2, FP9 fill, FP3 clears, FP1 window, FP2 `READN`, TP2a | G-T1 wall-time |
| 2 | **NR4** FP10-A merge | §16 | — (parallel) | FP10-B tile engine, 8-attachment width | G-F1/G-F2 |
| 3 | **NR6** FP9 texture unit | §17 | NR1 (burst fill), FP8 rules | `texture.*`/`image.*`, blit/resolve, cube/3D/BC | G-F2 samples |
| 4 | **TP3a** banked RF | §15.2 | — | TP3 pipeline, 256-invocation width | — |
| 5 | **TP3** pipelined issue | §15.3–15.4 | TP3a | G-T2, FP6 interpolation, TP7 cores | G-T2 |
| 6 | **NR2** record issue width | §18 | NR1 | record-path state share (53–64%) | G-F1 |
| 7 | **FP6** interp→wave preamble | §9.3/§15 | TP3 (G-T2) | interpolation off rasteriser | G-F2 |
| 8 | **FP10-B** tile engine | §9.3 | FP10-A, FP9, MSAA need | tile residency, resolve, ordering | G-F3 |
| 9 | **TP7** shader cores | §8 | TP3 measured, TP3a | multi-core scaling | G-T3 |

**Critical path:** NR1 → (NR2 ∥ FP9 ∥ FP3 ∥ FP1/FP2) and TP3a → TP3 → (FP6 ∥ TP7). The
memory port (NR1) is the widest unblock — six consumers wait on it — so it is the
first land even though TP3a has no dependency and could start in parallel on a second
front. FP10-A (NR4) is the only pass with no inbound dependency and the only one that
also carries a 1.4 capacity width (8 attachments), so it is the best *parallel* slot.

**What is deliberately not contracted here:** NR3/FP6 (§ gated on TP3 — spec'ing it
now would guess at the post-TP3 wave interface); FP10-B tile engine (needs FP10-A's
pixel-store interface and FP9's sampler to exist first); TP7 multi-core (needs TP3's
per-core numbers); WSI/transport (a platform track, §13 rows 1/2/19 — different doc).

**Honest bottom line:** the frame's two structural walls (§13.2) are NR1 and TP3 —
both now have contracts (§14, §15). Everything else is either parallelizable
(NR4/NR6/NR2), gated (FP6/TP7/FP10-B), or breadth that rides on top (descriptors to
memory, sync2, WSI, RT, mesh). The device-pipeline throughput analysis is complete;
the next evidence needed is the first admitted NR1 counter delta, which re-sizes
every downstream projection.

## 20. Frame boundary — host ingress and presentation egress (2026-11-21)

§9's S1–S13 covers the device stages. This section covers the two segments that
bookend them and that no device-side pass reaches: how a frame's commands and pixels
cross the **host↔device boundary**. Ingress is host→device (app to engine); egress is
device→screen (engine to display). Both are currently the least-complete parts of the
frame and both are hard release requirements (stock Ubuntu/Mesa/loader, real WSI).
Detail on the stock-software contract lives in `apu-graphics.md`; this section is the
frame-lifecycle view and the performance/cost angle.

### 20.1 Ingress — host app to engine (S0)

The path a `vkQueueSubmit` takes before §9 S1 (`vqwalk`) begins:

```
app vkQueueSubmit
  → Mesa Venus vn_physical_device (libvulkan_virtio, the stock ICD)
  → virtio_gpu execbuffer commands (CREATE_BLOB/MAP_BLOB/TRANSFER/WAIT/...) on the
    host-visible blob ring  [host side, kernel virtio-gpu + DRM]
  → guest virtqueues (q0 control, q1 Venus)  [transport: virtio-mmio today]
  → vqwalk descriptor walk → vnpump/vndec decode → vnfront → cmdrec → cmdexec
  → the engines of §9
```

Current state and cost:

- **Transport is diagnostic `virtio-mmio`, not a qualified endpoint.**
  `g6lc_apu_virtio_mmio.sv` returns all-ones SHM length/base (~lines 202–203), which
  the driver reads as *no host-visible region* — so the blob ring the Venus path
  needs is not actually mapped today. `APU_IMPL_FEATURES` carries `VERSION_1` +
  `RING_RESET`; Venus capset (id 4) support is partial. x86 physical use needs a
  stock-compatible **virtio-pci** (BAR/MSI-X/DMA/reset); RISC-V stays virtio-mmio.
- **The blob ring is the command/pixel transport.** Venus serialises Vulkan commands
  and reads back results through a host-visible blob region; SPIR-V arrives via
  `vkCreateShaderModule`. Until SHM mapping is real, this path is exercised only in
  the QEMU/bridge harness, not a stock guest.
- **Per-command host cost is already measured and large.** The DRAM-backed ObjTab
  path costs ~3,000 cycles per host command (`execute_large_primary`, §9.1) — that is
  *inside* the device (S2/S3), but it sits on the ingress critical path: every
  `vkCmd*` the driver emits pays it before any engine work. FP1/FP2/TP9 (§9.3) are the
  device-side reducers; the transport side adds its own per-command virtqueue +
  doorbell + used-ring round trip on top.
- **Synchronization crosses the boundary twice per frame.** Fences/semaphores are
  raised in-device (`doneq`, 16 slots) and must be signalled back through the
  virtqueue used-ring interrupt (`g6lc_apu_uir`) to the host driver, which the guest
  ICD polls or sleeps on. Timeline semaphores and external sync (the WSI requirement)
  are not yet present (§13 rows 4/19).

### 20.2 Egress — engine to screen (S13, currently none)

§9.2 S13 records the honest state: **there is no presentation path.** The control
queue decodes no scanout, flush, display-info or EDID command; the Venus config
requires `num_scanouts=0`; pixels reach the host today only by CPU readback
(`vkMapMemory` of a host-visible image). What a real frame needs:

- **A scanout resource.** A guest image the display scans out directly — today every
  "present" is a readback copy, which is why G2's matched-llvmpipe evidence is
  smoke/milestone, not presentation.
- **`RESOURCE_FLUSH` / cache maintenance** so the device's rendered pixels are visible
  to the host scanout (the aperture is device-coherent only where the memory type
  says so; the flush is the explicit hand-off).
- **External synchronisation.** WSI acquire/present needs `sync_file`/semaphore-fd
  export/import — the same external-sync path `VK_KHR_external_memory_fd`/semaphore
  already started for images must extend to swapchain images. Without it there is no
  tear-free present and no correct acquire.
- **Blob-backed present = pointer flip, no copy.** The acceptance shape (plan W9 /
  FP13): the scanout resource is a `RESOURCE_BLOB` the host maps once; present is a
  flush + a host-side buffer-index flip, so the per-frame egress cost is the flush
  only — "no render-path cost per frame beyond the flush" is the stated criterion.
- ** virtio-gpu scanout commands** (`SET_SCANOUT`, `TRANSFER_TO_HOST_2D` only as a
  fallback, `GET_DISPLAY_INFO`, `GET_EDID`) decoded on the **control queue** — a new
  command class the current decoder does not have.

### 20.3 The transport contract to qualify against

Both ends must match stock behaviour with no custom ICD/firmware/daemon:

- **virtio-mmio (RISC-V lane):** real SHM LEN/BASE discovery (fix the all-ones),
  queue notify/used-ring/ISR (`uir`), capset `GET_CAPSET_INFO`/`GET_CAPSET` for Venus
  id 4, `RESOURCE_CREATE_BLOB`/`MAP_BLOB`/`context_init`, feature words
  `{0,3,4}`+`{32=VERSION_1,40=RING_RESET}` written back exactly (the probe already
  does this register-for-register).
- **virtio-pci (x86 lane):** the same virtio-gpu protocol over a modern PCI
  transport — BARs, MSI-X, DMA, reset — so the *same* Venus command stream runs on a
  PC. This is a transport swap, not a protocol change; the device-side Venus engines
  are transport-agnostic behind `vgsys`.
- **Honesty rule (unchanged):** an official Ubuntu baseline that cannot expose a
  required feature stays BLOCKED — no cap masking, no SkipVulkanProfileCheck, no
  custom ICD to make an app start.

### 20.4 Performance notes on the boundary

- **Ingress overhead is per-command, not per-pixel.** A frame's cost is dominated by
  device work (§12), but the *fixed* per-submit overhead (virtqueue post, doorbell,
  used-ring poll, ObjTab resolution ~3,000 cy/command) is what makes small draws and
  the `api.*` CTS groups slow in wall time — FP1/FP2/TP9 and the transport doorbell
  path are the reducers. For large frames it amortises to noise.
- **Egress must be O(1) per frame.** The blob-backed pointer flip makes present
  constant-cost; anything that copies the framebuffer per frame (a `TRANSFER_TO_HOST`
  fallback) reintroduces a full-frame memory pass and breaks the §12.2 budget. The
  flush is the only unavoidable per-frame egress cost.
- **Fence/semaphore round-trips are latency, not throughput.** They gate CPU/GPU
  overlap; timeline semaphores (plan E, 1.2) and a real free-running timestamp
  counter (FP12) reduce the poll/serialisation stalls on both sides of the boundary.

### 20.5 Gates and verification

- **Ingress gate:** a stock guest (Ubuntu kernel/Mesa/loader, no custom ICD)
  enumerates Venus, negotiates the capset and SHM region, and runs `vkcompute` +
  `vkQueueSubmit`→fence→`vkQueueWaitIdle` end-to-end — the `sys-venus`/`cva6-venus`
  benches cover the device side; the missing evidence is the *stock transport* arm.
- **Egress gate (W9/FP13):** `wsi.*` CTS groups on x86-64 virtio-pci — acquire,
  present, resize, external sync — with the blob-backed pointer flip measured at
  flush-only cost. Offscreen output is qualified separately from visible
  resize/present (the `apu-graphics.md` deployment matrix already separates these).
- **Ordering:** ingress transport qualification (SHM mapping, capset, blob) is a
  *prerequisite* for meaningful guest CTS runs — it is upstream of every device
  group. Egress/presentation is downstream of raster correctness and can trail it,
  but both are release blockers, not optional.

## 21. Memory subsystem — device VA space, BDA and the GPU-VM decision (2026-11-21)

§13 row 6 flags the largest *architectural* gap that is not a throughput rung: the
device has **no GPU virtual memory**. This section records what exists, what Vulkan
1.4 actually requires, and a phased path — because "scalable memory/VM/cache
infrastructure" is an explicit goal and the answer is *not* "build a full MMU now."

### 21.1 What exists today (verified in RTL)

The memory model is **physical aperture, no translation:**

- `g6lc_apu_vgpages` is a first-fit **physical** page allocator over the blob-SHM
  aperture window (`ALLOC`/`ALLOC_AT`/`ALLOC_HI`/`FREE`, window-relative byte
  offsets). It backs both virtio-gpu blobs (`vgctl`) and `vkAllocateMemory` device
  memory (`vnfront`) — one pool, physical offsets only.
- Descriptor records are 32-byte aperture records; a buffer descriptor's `base` is
  the **physical aperture offset** of the bound memory (`abs base = resolved
  mem.base + off`, `g6lc_apu_sh_pkg`). Images carry the same physical base + a
  per-mip layout the texture walk recomputes.
- `g6lc_apu_apmem` classifies `dom=0` (absolute guest byte address — virtqueue
  control) vs `dom=1` (aperture-relative offset → `ap_base + offset` → AXI). There
  is no third domain and no VA→PA step anywhere on the path.
- On-chip carve-outs (R3 record store 64 KiB, TP5 vertex cache) are `tc_sram`
  windows inside the same aperture address space, served before AXI.

Net: a "device address" *is* a physical aperture offset. The guest driver places
memory and the device dereferences it directly. This is a legitimate *simplified*
Vulkan memory model — it is why bounded Venus compute and the current graphics
vectors pass without any MMU.

### 21.2 What Vulkan 1.4 requires vs. what is deferrable

| Requirement | Needs a GPU-VM? | Honest near-term answer |
|---|---|---|
| `vkAllocateMemory`/`vkBind*Memory`, host-visible + device-local heaps | No — physical aperture allocation already models this | Works today within the aperture |
| `bufferDeviceAddress` (BDA) for SSBO/UBO/descriptor-buffer/bindless-by-address | No — BDA can *be* the aperture offset | Cheap; expose the existing base |
| Descriptor indexing / `VK_EXT_descriptor_indexing` | No — descriptors already live in aperture memory; indexing is a lookup, not a VA | Width/binding work (§10.1), not VM |
| Sparse residency (`VK_EXT_sparse_*`, `VK_KHR_maintenance*`) | **Yes** — unbound VA regions need a page table | Deferrable; not a 1.4 *required* feature |
| Driver-chosen device VAs, aliasing, remap | **Yes** | Deferrable for CTS; needed for real drivers that assume VA |
| Heap > aperture (real games need GB) | Effectively yes — or a much larger aperture | **The real driver** — see §21.4 |
| Coherent/host-visible caching | No — needs defined flush/invalidate, not VA | Cache-op contract, orthogonal to VM |

The decisive point: **nothing in Vulkan 1.4 *requires* a GPU-VM.** Sparse and
maintainance are extensions; core bind semantics map onto physical allocation. The
VM becomes necessary for *scale* (heap larger than the aperture) and for drivers
that assume a VA space — both real, but neither blocks the near-term CTS ladder.

### 21.3 Phased path

- **M0 — honest physical model (now).** Keep aperture-offset addressing. Make the
  aperture/heap sizing an explicit SoC decision (plan W5) and stop advertising
  `maxMemoryAllocationCount`/heap sizes the 128 MiB window cannot honour. This is
  capability honesty (workstream A), not a perf change.
- **M1 — BDA (cheap, high value).** Expose `bufferDeviceAddress` = the aperture
  offset the descriptor already stores. Enables SSBO/UBO, descriptor buffers and
  bindless-by-address *without* any MMU — the address is already unique and stable.
  Locus: the descriptor-record `base` field + a `VkPhysicalDeviceBufferDeviceAddress`
  feature bit + the shader `OpAccessChain`/load path that already resolves
  `mem.base`. Small, verifiable, unblocks a real feature family.
- **M2 — GPU-VM (the big one, gated).** A real VA→PA translation for the case the
  aperture cannot serve. Design sketch, not a commitment:
  - *Translation point:* the cleanest seam is a new `dom=2` (device-VA) in
    `apmem`'s classifier, OR a dedicated `g6lc_apu_mmu` the requesters consult
    before issuing `dom=1`. Per-access page-table walks are too slow for the LSU
    hot path, so a **TLB in `tc_sram`** (tag → aperture offset, ~4 KiB pages) is
    mandatory; misses walk the guest-owned page table through a low-priority
    memory port.
  - *Descriptor format:* buffer/image descriptors would carry a device-VA instead
    of a physical base; every consumer (shwave LSU, texture, xfer, rast vertex/
    index fetch, FP9 sampler) translates. This is the wide blast radius — the same
    records §10.1 already touches for width.
  - *Page-table storage:* guest physical memory owned by the driver; the walker
    reads it via `apmem` (recursive) or a dedicated port. Invalidation on
    `vkQueueSubmit`/memory-bind/barrier.
  - *Coherence:* VM and caching are orthogonal — host-visible cache ops
    (flush/invalidate) are needed regardless and should land with M1, not wait for M2.
- **M3 — coherent L2 / larger heaps.** Only if profiling shows the flat aperture +
  AXI path is the wall. The `tc_sram` carve-outs already prove the on-chip-window
  pattern; a coherent L2 is a separate scalability study.

### 21.4 The real driver is aperture size, not the MMU

The single hardest constraint is not virtualisation — it is that **`APU_SHM_BYTES`
is 128 MiB (64 MiB guest-visible)** while a single 7680×7680 RGBA8 attachment is
225 MiB (§10.1). No amount of VA translation fixes a framebuffer that does not fit.
So the *ordering* inside the memory track should be:

1. **W5 aperture/heap sizing** (SoC decision) — raise the mappable window or adopt
   a tiled/host-backed framebuffer model. This gates *any* real-resolution frame.
2. **M1 BDA** — cheap feature unlock, independent of aperture size.
3. **M2 GPU-VM** — when sparse/aliasing/driver-VA or heap-beyond-aperture is
   actually required by a target workload, designed against the then-current
   aperture model.
4. **M3 coherent L2** — profiling-driven, last.

### 21.5 Gates and verification

- **M0:** profile `maxMemoryAllocationCount`/heap fields match the elaborated
  aperture; a vector that allocates past the window returns `VK_ERROR_OUT_OF_DEVICE_MEMORY`
  cleanly (no wrap).
- **M1:** a `bufferDeviceAddress` vector — SSBO store→load through the BDA equals
  the descriptor path bit-exact; descriptor-buffer and one bindless-by-address case.
- **M2:** before any RTL — a written page-table format + TLB hit/miss budget +
  invalidation rules reviewed against `vkBind*Memory`/sparse/`memoryBarrier` CTS
  groups; then `sparse.*`/`descriptorBuffer`/`maintenance` vectors.
- **Honesty rule (unchanged):** do not advertise sparse/BDA/large-heap features the
  elaborated aperture and descriptor format cannot honour; capability honesty is
  workstream A and precedes every width here.

**Bottom line:** the memory subsystem is a *decision*, not a missing block. The
physical-aperture model is correct for the current scope; BDA is the cheap next
unlock; the GPU-VM is real but gated on aperture scale and driver-VA needs, and the
aperture-size decision (W5) is the true first domino.

## 22. Synchronization — fences, events, timeline semaphores and sparse (2026-11-21)

§13 row 4 flags sync as "partial." Verified against `vn_command_set.txt` (157
entries) and the engine RTL, the picture is sharper than "partial": **Vulkan 1.1
synchronization is substantially implemented; what is missing is the 1.2+
timeline/semaphore2 surface, sparse binding, and a truthful timestamp.** A frame
cannot retire or order work correctly without this, so it is correctness, not
throughput — but it shares machinery with the performance path (`doneq`, fences).

### 22.1 What exists (verified)

- **Submission/completion:** `vkQueueSubmit`, `vkQueueWaitIdle`,
  `vkDeviceWaitIdle`; the device tracks outstanding work in `outst_q` decremented
  per `work_done_i` (cmdexec), completions queued through `g6lc_apu_doneq` because
  engine `done_o` pulses are single-cycle and concurrent.
- **Fences:** full 1.1 API (`vkCreateFence`/`ResetFences`/`GetFenceStatus`/
  `WaitForFences`/`DestroyFence`); device side `fence_pulse_o`/`fence_id_o`/
  `fence_ring_o` from the chain-completion path, 16-slot done queue.
- **Events:** `vkCreateEvent`/`SetEvent`/`ResetEvent`/`GetEventStatus` +
  `vkCmdSetEvent`/`ResetEvent`/`WaitEvents`; device side writes ObjTab event-state
  bit 0, and `WaitEvents` drains then polls `state[0]` every 64 cycles.
- **Barriers:** `vkCmdPipelineBarrier`; cmdexec has barrier-drain and
  SETSTATE/WaitEvents states.
- **Timestamps (form only):** `vkCmdWriteTimestamp` + `vkCmdWriteTimestamp2` decode,
  but §10.1/§13 record the value path reports **zero valid bits** — no real counter.
- **External sync queries:** `vkGetPhysicalDeviceExternalFenceProperties` /
  `…SemaphoreProperties` present (needed for WSI, §20.2).

### 22.2 What is absent (verified absent from the decoder)

- **Timeline semaphores:** `vkSignalSemaphore`, `vkWaitSemaphores`,
  `vkGetSemaphoreCounterValue` — none present. A timeline semaphore is a
  monotonic 64-bit counter the device increments on signal and the host polls;
  it needs (a) a device-side counter value per semaphore and (b) the signal/wait
  submission ops.
- **synchronization2** (`VK_KHR_synchronization2`, core in 1.3): `vkQueueSubmit2`,
  `vkCmdPipelineBarrier2`, `vkCmdSetEvent2`, `vkCmdWaitEvents2`,
  `vkCmdResetEvent2` — all absent (only `vkCmdWriteTimestamp2` exists). These are
  the entry forms modern drivers/Mesa emit.
- **Sparse binding:** `vkQueueBindSparse`, `vkCmdBindSparse*` — absent. Sparse
  residency needs the GPU-VM page-table update path (§21 M2), so it is gated on
  that, not independent.
- **Real timestamp:** a free-running counter with a truthful
  `timestampPeriod` (FP12) — currently the decode exists but reports no valid
  bits.

### 22.3 Implementation contracts

- **S-TL — timeline semaphores.** A monotonic `timeline_cnt` (the same free-running
  counter FP12 needs — share it). Device state: per-semaphore `{counter, wait_mask}`
  in ObjTab or a small table; `vkSignalSemaphore`/`vkWaitSemaphores` are *submission*
  ops that enqueue a signal/wait against the counter, resolved through the existing
  `doneq`/`outst_q` completion path (a signal fires when its batch drains; a wait
  blocks until `counter >= value`). `vkGetSemaphoreCounterValue` reads the counter.
  Depends on FP12's clock; gate on `timelineSemaphore` feature + `*2` submit.
- **S-S2 — synchronization2 entry forms.** The `*2` commands carry
  `Vk*Synchronization2` structs (semaphore/fence/event payloads with stage/access
  masks). Per plan P4 they are *entry forms* that write the same per-draw/per-submit
  state record the 1.1 forms already write — so this is decoder-table + payload
  decode work (`vn_command_set.txt` regeneration, §10.1 entry-forms row), reusing
  the existing barrier/event/fence device states. Land in few large table revisions.
- **S-SP — sparse binding.** `vkQueueBindSparse` enqueues page-bind/unbind ops that
  update the GPU-VM page table (§21 M2) and invalidate the TLB. Hard-gated on M2 —
  without a VA space there is nothing to sparsely bind. Do not advertise
  `sparseBinding`/`sparseResidency*` until M2 + this land together.
- **S-TS — timestamp counter.** A real free-running counter clocked at a known
  rate; `timestampPeriod` reported truthfully; `vkCmdWriteTimestamp`/`2` sample it
  into the query pool. Needs the device clock (FP12); the query-pool readback path
  (`vkGetQueryPoolResults`) already exists.

### 22.4 Ordering and dependencies

```
FP12 clock ──► S-TS timestamp counter ──► S-TL timeline value source
                                        ▲
S-S2 entry forms (decoder) ─────────────┤  (independent of VM)
                                        │
§21 M2 GPU-VM ──► TLB/page-table ──► S-SP sparse bind
```

- S-TS and S-TL share the counter — land the clock/counter once.
- S-S2 is decoder-surface work, independent of the VM; it unblocks modern drivers
  emitting `*2`/`Submit2` even before timeline semaphores function.
- S-SP is strictly downstream of §21 M2 — sequence it there, not here.
- All are *correctness/feature* work (plan E/C), not the §19 throughput critical
  path — they ride alongside, gated on their own vectors (`synchronization2.*`,
  `semaphore.*`, `sparse.*`, `query.timestamp.*` CTS groups).

**Bottom line:** 1.1 synchronization is done; the gap is a bounded, well-defined
set — a shared timestamp/timeline counter (FP12), the `*2`/Submit2 decoder surface
(P4), and sparse (gated on the §21 VM). None is on the §19 throughput critical
path, but all are required for "fully featured" 1.3/1.4 and for the CTS groups that
exercise them.

## 23. Descriptors — sets, bindings, indexing and push descriptors (2026-11-21)

§13 row 5 flags descriptors as "partial." Verified against `g6lc_apu_sh_pkg` and
`vn_command_set.txt`: the F5 **memory-resident descriptor model is already the
right architecture** — 32-byte records in aperture memory resolved through a
per-set binding-row CAM plus dynamic offsets. What is missing is *width* (set and
binding counts) and *indexing features* (descriptor indexing/bindless, push
descriptors, descriptor buffers). This is the last major feature aspect without a
contract; it completes §13's coverage alongside §21 (memory) and §22 (sync).

### 23.1 What exists (verified)

- **Memory-resident records:** one descriptor = `APU_DESC_BYTES`=32 aperture bytes
  at `set_base[s] + off32*32 + array_index*32`. Buffer/image/sampler records carry
  resolved aperture bases — the same physical-address model as §21.
- **Resolution path:** `(set,binding,idx)` → `boff` binding-row CAM → fetch record
  → `APU_DESC_CACHE`=8-entry dispatch-scoped LSU record cache. Dynamic offsets via
  `dyn_off[set][dynbase+idx]`.
- **Constants:** `APU_DESC_SETS`=4, `APU_DESC_BND`=16 binding rows/set (CAM),
  `APU_DESC_DYN`=16 dynamic slots/set.
- **API surface (decoder):** `vkCreate/Destroy/ResetDescriptorPool`,
  `Allocate/FreeDescriptorSets`, `UpdateDescriptorSets`,
  `Create/DestroyDescriptorSetLayout`, `vkCmdBindDescriptorSets`,
  `vkCmdPushConstants` — the 1.1 descriptor path is complete.

### 23.2 What is absent or width-bound

- **`maxBoundDescriptorSets` 4 → 7 (UE RT wants 9).** `APU_DESC_SETS`=4 sizes
  `set_base`, `dyn_off`, `boff`, the wave `dsc_set_q[1:0]` and cmdexec's
  `dset[3:0]`/`dyn[3:0]` snapshot together. §10.1: at 9 sets the ~5.3 kbit sideband
  should become a small SRAM or per-set fetch, not widened flops.
- **`maxPerStageResources` 200 / per-set 90·96·144 vs `APU_DESC_BND`=16.** The
  binding-row CAM holds only 16 rows/set; real descriptor-set layouts have far
  more bindings. Rows must move to memory with a per-set lookup (same change as the
  set count — one binding-table redesign serves both).
- **Descriptor indexing / bindless** (`VK_EXT_descriptor_indexing`,
  `runtimeDescriptorArray`, `updateAfterBind`, non-uniform indexing): the
  `(set,binding,idx)` resolution already indexes `array_index`; the gaps are
  *feature flags + legality* (which types may be runtime-indexed, update-after-bind
  ordering vs. in-flight draws) and **descriptor buffers** — descriptors addressed
  by `bufferDeviceAddress`, which needs §21 M1 BDA.
- **Push descriptors** (`vkCmdPushDescriptorSet*` KHR/META): absent from the
  decoder. They are *entry forms* writing the same bound-set state `CmdBind…`
  writes — plan P4 decoder-table work plus a push-block path (the push-constant
  block already exists as the model).
- **Push-constant width** 128→256 B: `vkCmdPushConstants` decodes, but
  `push_q[32]`/`push_i[1023:0]` is 128 B; §10.1 moves it to the record store (TP4)
  as 64 words — a width change riding TP4, not a new feature.

### 23.3 Implementation contracts

- **D-SETS — set-count widening.** Make `APU_DESC_SETS` a package parameter that
  sizes `set_base`/`dyn_off`/`boff`/`dsc_set_q`/`dset`/`dyn` *together* (never
  independently — §10.1's warning). At ≤8 sets keep the flop sideband; at 9 move
  `boff`+`set_base` to a `tc_sram` table fetched per set. Gate: a vector binding
  7 then 9 sets with per-set distinct records, bit-exact vs. the 4-set golden.
- **D-BIND — memory-backed binding table.** Replace the 16-entry `boff` CAM with a
  memory-resident per-set binding directory (the same aperture record space
  descriptors already use), so `maxPerStageResources`=200 and per-set limits are
  honoured. This is the prerequisite for descriptor indexing at scale and for UE-
  class layouts. Locus: `g6lc_apu_sh_pkg` `apu_sh_bindrow_t`/`boff` → a table the
  LSU walks; keep the 8-entry record cache as the hot path.
- **D-IDX — descriptor indexing/bindless.** Advertise only after D-BIND: nonuniform
  indexing is already expressible through `array_index`; add the feature bits
  (`runtimeDescriptorArray`, `descriptorBindingPartiallyBound`,
  `updateAfterBind`), the legality checks in `vkCreateDescriptorSetLayout`, and —
  for `updateAfterBind` — the ordering rule that an update cannot race an in-flight
  draw reading the same set (needs the §22 fence/event machinery). **Descriptor
  buffers** (`VK_EXT_descriptor_buffer`) additionally need §21 M1 BDA — gate that
  sub-feature on M1, not on D-IDX.
- **D-PUSH — push descriptors.** Add `vkCmdPushDescriptorSet*` to
  `vn_command_set.txt`; the device path reuses the bound-set record `CmdBind…`
  produces (a push writes a transient overlay the next draw consumes, scoped to
  the command buffer). Decoder-table regen per plan P4; small device state.
- **D-PC — push-constant width.** Ride TP4: `push_q`/`push_i`→64 words in the
  record store; profile `maxPushConstantsSize`=256 follows the elaborated width.

### 23.4 Ordering and dependencies

```
D-BIND (binding table→memory) ──► D-SETS can widen sideband cheaply
        │                              │
        └──► D-IDX (indexing/bindless)  └──► UE-class layouts unblocked
                     │
        §21 M1 BDA ─┴──► descriptor_buffer sub-feature only
D-PUSH (decoder) and D-PC (TP4) are independent entry-form/width riders.
```

- D-BIND is the keystone: it unblocks both the set-count sideband and indexing at
  scale, and it is pure descriptor-table work (no VM, no new engine).
- D-IDX's `updateAfterBind` correctness leans on §22 fences/events — sequence the
  legality+ordering proof with S-TL/S-S2, not before.
- None of D-* is on the §19 throughput critical path; they are feature/width work
  (plan B/P7) that determines whether real descriptor-heavy shaders (UE RT) run.

**Bottom line:** the descriptor *architecture* is already right (memory-resident
records + CAM resolution). The gap is width (sets 4→9, bindings 16→memory) and the
indexing/push-descriptor feature surface. D-BIND is the keystone contract; D-IDX
partially waits on §21 M1 (descriptor buffers) and §22 (update-after-bind ordering);
D-PUSH/D-PC are independent decoder/width riders. With §21 and §22, every major
Vulkan 1.4 frame aspect now has an implementation contract or decision.
