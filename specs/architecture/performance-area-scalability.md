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
