# `compute` — compute pipelines, indirect dispatch, workgroup memory, cooperative matrices (60,838 cases)

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/compute.txt`; tests in
`external/vulkancts/modules/vulkan/compute/vktCompute*.cpp`. Owner W3 (ShaderCore) with W6
for cooperative matrices. Gates CTS-1 (`compute.pipeline.basic`, `indirect_dispatch`),
CTS-3 (`zero_initialize_workgroup_memory` at 1.3), CTS-4 (`cooperative_matrix`).

## Inventory (`cts_ledger.py tree --group compute --depth 3 --min-cases 20`)

| prefix (`dEQP-VK.`…) | cases |
|---|---:|
| `compute` | 60838 |
| &nbsp;&nbsp;`compute.pipeline` | 20294 |
| &nbsp;&nbsp;&nbsp;&nbsp;`compute.pipeline.basic` | 80 |
| &nbsp;&nbsp;&nbsp;&nbsp;`compute.pipeline.cooperative_matrix` | 15677 |
| &nbsp;&nbsp;&nbsp;&nbsp;`compute.pipeline.indirect_dispatch` | 45 |
| &nbsp;&nbsp;&nbsp;&nbsp;`compute.pipeline.workgroup_memory_explicit_layout` | 3827 |
| &nbsp;&nbsp;&nbsp;&nbsp;`compute.pipeline.zero_initialize_workgroup_memory` | 646 |
| &nbsp;&nbsp;`compute.shader_object_binary` | 20272 (same five families) |
| &nbsp;&nbsp;`compute.shader_object_spirv` | 20272 (same five families) |
| **total** | 60838 |

The three top-level variants run the same tests through a VkPipeline, a linked
VK_EXT_shader_object binary and an unlinked SPIR-V shader object; only `pipeline.*` is
core.

## Architectural logic

```text
LOGIC COMPUTE-L1 · Core compute semantics
  CLAIM       Dispatches of any legal (x,y,z) up to maxComputeWorkGroupCount with local
              sizes up to maxComputeWorkGroupSize/Invocations execute every invocation
              once; builtins (gl_GlobalInvocationID, LocalInvocationID/Index,
              WorkGroupID, NumWorkGroups) are exact; shared memory up to
              maxComputeSharedMemorySize with barriers; SSBO/UBO/image access; push
              constants; specialization constants (including local-size specialization
              via WorkgroupSize decoration / LocalSizeId); copy/ssbo-to-image round trips;
              empty dispatches and dispatches with zero workgroups; device-local and
              host-visible buffers; concurrent compute with graphics.
  SOURCE      dEQP-VK.compute.pipeline.basic.* (80: empty_shader, ubo_to_ssbo_*,
              copy_ssbo_*, shared_var_*, atomic_op_*, image_*, ssbo_rw_*, write_to_
              multiple_*, concurrent_compute, empty_workgroup_*, max_local_size_*,
              zero/max dispatch counts, …); vktComputeBasicComputeShaderTests.cpp.
  MECHANISM   shmod/shwave/shcore (§7) + cmdexec dispatch assembly. Known gaps from the
              corpus: specialization constants are refused (`pSpecializationInfo` →
              VK_ERROR_UNKNOWN, 5a-ii) — required here; maxComputeWorkGroupInvocations is
              64 against the 1.0 minimum 128 (and 256 at 1.4) — the wave count per
              workgroup (`MaxWaves`) must cover the advertised value; image load/store
              in compute (5b) present; atomics (G3a-i) present.
  REQUIRES    Specialization: shmod resolves OpSpecConstant* from VkSpecializationInfo at
              commit (a per-pipeline constant override table keyed by SpecId — the module
              bytes stay shared; the pipeline, not the module, owns the resolved values →
              G3b residency must key pipelines by {module, spec data}). Local-size
              specialization changes the dispatch geometry.
  FORBIDS     Pre-resolving specialization by patching module bytes in place (two
              pipelines from one module with different constants must coexist).
  CHECK       compute.pipeline.basic.* (CTS-1); engine corpus already covers most ops.
  COST        A spec-constant override table per pipeline slot (small); `MaxWaves` × RF
              rows is the area driver for 128/256 invocations per workgroup.
  FEEDS       GLSL-L*, SSBO/UBO; CTS-1.
  STATUS      not-run

LOGIC COMPUTE-L2 · Indirect dispatch reads its arguments from device memory
  CLAIM       vkCmdDispatchIndirect(buffer, offset) reads {x,y,z} at execution time from
              a buffer the GPU may have written earlier in the same submission, at any
              multiple-of-4 offset, including zero counts and the maximum counts.
  SOURCE      dEQP-VK.compute.pipeline.indirect_dispatch.* (45),
              api.command_buffers.indirect_compute_dispatch_offsets_* (64);
              vktComputeIndirectComputeDispatchTests.cpp.
  MECHANISM   cmdexec: before issuing the work, fetch 3 words through the resolved buffer
              (LOOKUP → bind memory → aperture read) with the submission's ordering (a
              prior copy/shader write to the argument buffer must be complete — the
              serialized executor guarantees it today).  Implemented (G3b-iii):
              cmdexec fetches the 12-byte operand via aligned aperture beats into
              `rec_q.imm[0..2]`, then issues the same `StDsPipeReq` path as direct
              dispatch; `shcore` treats `DISPATCH_INDIRECT_EXT` as `is_dispatch`.
              Proven end-to-end: `ue_cpos_dispind_1` (2× `vkCmdDispatchIndirect`)
              PASS-COMPUTE g1=48 g2=48 `XF_FAULTS 0` in `tb_g6lc_apu_vgtop`.
  REQUIRES    The fetch happens after the preceding commands' completion (barrier
              semantics, W2.4); robust: offset+12 > buffer size is invalid usage (no
              check needed, but no wild read either — clamp to the buffer).
  FORBIDS     Capturing the arguments at record time.
  CHECK       compute.pipeline.indirect_dispatch.*, api.command_buffers.indirect_*
              (CTS-1); engine vector: args written by a prior dispatch.
  COST        one 16-byte read per indirect dispatch.
  FEEDS       DRAW-L* (indirect draws share the fetch); CTS-1.
  STATUS      not-run

LOGIC COMPUTE-L3 · Workgroup memory semantics beyond 1.0
  CLAIM       (1.3 core) shaderZeroInitializeWorkgroupMemory: Workgroup variables
              declared with the ZeroInitializeWorkgroupMemory capability read as zero
              before any write; (KHR_workgroup_memory_explicit_layout) explicit layouts
              and aliasing of shared memory blocks (optional extension).
  SOURCE      compute.pipeline.zero_initialize_workgroup_memory.* (646),
              compute.pipeline.workgroup_memory_explicit_layout.* (3827).
  MECHANISM   Zero-init: clear the workgroup slab (16 KiB tc_sram) for the dispatch when
              the module declares the capability (a 1-cycle-per-word clear or a valid
              bitmap); explicit layout: shmod accepts Block-decorated Workgroup
              variables with Offsets and aliasing — the slab addressing already uses
              byte offsets.
  REQUIRES    1.3 ladder (zero-init is mandatory at 1.3).
  FORBIDS     Zeroing on every dispatch regardless of the capability (performance) or
              never zeroing (correctness).
  CHECK       the two families (CTS-3).
  COST        slab clear cycles proportional to the declared shared size.
  FEEDS       INFO-L2 ladder; CTS-3.
  STATUS      not-run

LOGIC COMPUTE-L4 · Cooperative matrices
  CLAIM       VK_KHR_cooperative_matrix: matrix load/store/mul-add over the advertised
              {M,N,K,A/B/C/Result types, scope} combinations with the spec's
              accumulation semantics; subgroup scope.
  SOURCE      compute.pipeline.cooperative_matrix.* (15,677) — see W6 and §8.
  MECHANISM   W6 MatHelper (the AI dot PE behind a graphics-owned port) or FPnew
              sequences; the advertised shapes come from the elaborated helper.
  REQUIRES    Flexible subgroups (SUBGROUPS-L*) first — cooperative matrices are
              subgroup-scoped.
  FORBIDS     Advertising shapes the helper does not execute exactly as specified
              (NoContraction/rounding rules per §8).
  CHECK       the family, per advertised shape (CTS-4).
  COST        the W6 Pareto item.
  FEEDS       W6; CTS-4.
  STATUS      not-run
```

## Exceptions

```text
EXCEPTION COMPUTE-X1 · NotSupported by truthful absence
  CONDITION   shader_object_binary.* / shader_object_spirv.* (VK_EXT_shader_object),
              workgroup_memory_explicit_layout.* (KHR extension), cooperative_matrix.*
              (until W6), zero_initialize_workgroup_memory.* while at 1.1/1.2.
  RESULT      NotSupported.
  TRUTH       Profile lines; zero-init becomes required at 1.3 (COMPUTE-L3).
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     Keeping maxComputeWorkGroupInvocations at 64 (it is below the 1.0 minimum
              128 — a required fix, not an exception).

EXCEPTION COMPUTE-X2 · Specialization constants (current refusal)
  CONDITION   pSpecializationInfo non-null.
  RESULT      Today VK_ERROR_UNKNOWN + null handle (documented 5a-ii); the CTS expects
              success → Fail until COMPUTE-L1's override table lands.
  TRUTH       A truthful refusal of an unimplemented required mechanism; recorded red.
  MECHANISM   vnfront vkCreate*Pipelines.
  CHECK       compute.pipeline.basic.* cases using specialization; glsl.*.
  FORBIDS     Ignoring the specialization data and compiling the defaults.
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| COMPUTE-H1 Spec constants | CTS-1 | high | per-pipeline SpecId override table consulted by shmod at commit; local-size specialization | — |
| COMPUTE-H2 Indirect | CTS-1 | high | 3-word operand fetch in cmdexec (shared with indirect draws) | — |
| COMPUTE-H3 128/256 invocations | 1.0 minimum | high | `MaxWaves` ≥ 16 (8 lanes) or wider waves; measure RF area | the RF banking (W3.3) is not yet parameterized — do it there |
| COMPUTE-H4 Zero-init | 1.3 ladder | medium | capability-gated slab clear | — |

## Segment card (current)

```text
SEGMENT G3b-ii/compute
  QUESTION        Does compute.pipeline.basic pass on the post-G3b-ii device —
                  the first broad compute-semantics probe through real Mesa
                  submissions (not golden tapes)?
  OBJECTIVE       Classified verdicts for the 80-case compute.pipeline.basic
                  set under the residency pipeline (module FILL→dispatch).
  ENVELOPE        as cts-info.md; bridge `bridge-g3bii` /
                  `bridge-g3bii-cpb`, runs `g3bii-2026-10-17` (two chunks)
                  and `g3bii-cpb-2026-10-18` (post-fix rerun;
                  `.cache/cts/runs/*/NOTES.md`).
  INPUTS          caselist `cts-g3bii-objmgmt-compute.txt` + remainder
                  list; rerun: `cts-compute-basic.txt` (80 cases).
  CONTRACT        Pass or truthfully-unadvertised NotSupported; faults must
                  land in `device_faults` and never hang the fence wait.
  OBSERVATIONS    Run `g3bii-2026-10-17` (pre-lifecycle-fix): 2 Pass /
                  48 Fail / 29 NS / 1 Crash.  Rerun `g3bii-cpb-2026-10-18`
                  after the command-buffer lifecycle fix (BEGIN implicit
                  reset on EXECUTABLE/drained-PENDING, `StCbPendW` wait,
                  `StElemSubW` submit-element PEND relookup, CB_RESET /
                  pool-reset drain guards; model updated first):
                  **44 Pass / 27 NotSupported / 6 Fail of 77 recorded**,
                  `device_faults=0`.  Absent: `indirect_after_base_dispatch`
                  (DispatchIndirect unimplemented → vnfront record reject →
                  ring FATAL → Mesa `vn_relax` abort at iter 1024 —
                  contract path, not a hang; G3b-iii) plus `pkadd_immediate`
                  and `undefined_values` (never reached).
  ROOT CAUSES     C1 `empty_workgroup_*` fixed by the lifecycle work
                  (zero-dim dispatch + implicit-reset resubmit); C2
                  Workgroup slab/barriers/shared-atomics all PASS; C3 SSBO
                  robustness/arrays all PASS (descriptor zeroing + LSU
                  valid bit); C4 image↔SSBO copies and `*_barrier_*` PASS.
                  The residual mass decomposes into three feature gaps,
                  each confirmed to mechanism with `G6LC_APU_DEBUG=1`:
                  (a) `max_local_size_{x,y,z}` — pipefail `spec=1`:
                  pipeline create refuses staged specialization data
                  (`StPipeLay0`) → null pipeline → `cmdexec lost` → SSBO
                  stays 0. COMPUTE-H1, not geometry — `cts_mls64`
                  (64-inv workgroup, 8 waves) passes tb_g6lc_apu_shwave
                  (3/10 checks, 12051 cy). (b) `image_atomic_op_
                  local_size_{1,8}` — commit scan rejects the
                  `OpTypePointer Image`/`OpImageTexelPointer` idiom
                  (`COMMIT FAULT STORAGE opcode=32` locally on an
                  equivalent glslang compile) → module RETIRE at create →
                  pipe LOOKUP miss → `cmdexec lost`. (c)
                  `branch_past_barrier` — shader is `local_size_x=128` >
                  advertised 64 (COMPUTE-H3 capability gap).
  RESULT          compute.basic is 44/80 green (77 recorded); every
                  remaining defect is a named feature item, none is a
                  residency or fault-contract regression.
  LIMITS          `image_atomic_op_local_size_1` recorded Pass in
                  `g3bii-2026-10-17` on the same bridge binary; A/B now
                  fails deterministically solo — unexplained
                  ordering/state dependence, flagged for a dedicated pass.
                  3 cases unrecorded due to the abort (above).
  NEXT ARTIFACT   image texel-pointer + atomics (2 Fails), rerun for
                  the 3 unrecorded cases.  ~~COMPUTE-H1 spec constants~~
                  closed 2026-11-07 (`specconst` corpus +
                  `specconst_{1,2,3}` decoupled vectors +
                  `apu-vn-specok2` override→41 PASS both latencies;
                  first-class `spec` DESC field in `shader_vectors.py`);
                  ~~G3b-iii DispatchIndirect~~ implemented —
                  `ue_cpos_dispind_1` PASS-COMPUTE g1=48; ~~COMPUTE-H3
                  128-inv groups~~ closed 2026-11-07 — `localsize128`
                  (16 waves × 8 lanes = MaxWaves) + `barrier_reduce128`
                  (cross-wave `OpControlBarrier` tree-reduce, the
                  branch_past_barrier/max_local_size shape) both
                  PASS-COMPUTE under zero-jitter AND randomized
                  memory latency; `maxComputeWorkGroupInvocations=128`
                  was already advertised (e1a3e3c4e).
```

Root-cause note (2026-11-07, COMPUTE-H1 / COMPUTE-X2): the spec-constant
path is decoded end-to-end; the constant *application* is now modelled on
the golden side and remains RTL-side.  **Model/golden:**
`vn_specialization.specialize()` folds scalar/default-composite spec
constants and replays correctly (`vn_native_pipelines`/`vn_graphics_
pipelines` call it at pipeline create; `test_wire_submit_executes_
specialized_pipeline` green).  `vn_golden` now mirrors the RTL
`StPipeSp*` wire decode — it parses the staged `{constantID,offset,
size}` map entries + `dataSize` blob into `(constantID, value-bytes)`
exactly as `read_specialization` does, applies `specialize()` to the
pinned module words, and parks the folded module on `pipe_spec[h]` for
provenance (compute dispatch is structural; `vn_native_*` executes the
folded code).  The former
`NotImplementedError('golden: non-empty specialization')` is gone: nmap>0
now specializes, nmap=0 folds defaults, and size=8 still returns
`VK_ERROR_FEATURE_NOT_PRESENT`.  No golden session yet carries a *valid*
spec override (the `spec` variant exercises the FNP reject), so the new
path is verified by contract, not yet by a live vector.  A `specok`
compute-session variant now emits a live 4-byte override (constantID 0
-> 41): `specialize()` is invoked with the module + `(0, 41)` on both
the dry and real `FrontModel.step` passes and `apu-vn-specok` generates
— the directed RTL create-path reproducer (not in `regen_vectors`).
**RTL:**
`g6lc_apu_vnfront` `StPipeH4`/`StPipeSp{Id,Off,Sz0,Sz1,Ds0,Ds1,Dat,Wn,
Wp,End}` fully parse `VkSpecializationInfo` into `pl_{sn,sid,soff,ssz,
sval}_q`, ObjPay-ALLOC a `{count,{sid,sval}*}` block (`pl_specb_q =
base|0x8000_0000` into pipeline ObjPay w2), and `g6lc_apu_shmod` admits
opcodes 48-52 with `OpSpecConstant` decode + `const_data_o`.  The CTS
`pipefail spec=1`->`StPipeFail`->null-pipeline is therefore localized to
the vnfront spec-block *creation* sequence (StPipeSpAlc..StPipeAuxHiC),
*not* yet pinned to a sub-state — the existing `G6LC_APU_DBG_LOST`
watcher (`dbg_{frm,sfrm,ofrm}_q` + `ot/op cpl` status prints) already
attributes the failing ObjTab/ObjPay op.  **Reproduced + fixed
(2026-11-07):** the `specok` compute-session vector `apu-vn-specok`
failed `tb_g6lc_apu_vgtop` (`+vec=apu-vn-specok`) with a single error —
`FAIL objpay chunks drained` — and *no* record mismatch or dispatch
fault, so the spec pipeline **created successfully** in RTL.  Root
cause was the **retire path**, not create: create makes two ObjPay
allocations — the spec block (`1+2*sn` words at `spec_base`, key
`pl_specb_q = base|0x8000_0000` parked in pipeline ObjPay w2) and the
3-word pipeline block (`{mhnd,mpark,specb}` at `pipe_base`, parked in
aux).  Pipeline retire (`StRetPBR`→`StRetPipeC`→`StRetUnp`→`StRetPNext`
→`StRetPFree`) read only the module handle(s) and freed `ret_payb_q`
(the pipeline block); nothing read w2/`specb` or freed the spec block,
so its chunk leaked.  `ue_cneg_spec_1` escaped because size=8 faults at
`StPipeSpSz0` *before* `StPipeSpAlc` ever allocates the block.

**Fix (vnfront retire):** the compute retire now reads pipeline w2
(`StRetPBR`→`StRetPSW` captures `ret_specb_q`), and `StRetPNext` routes
through `StRetPSChk`/`StRetPSRd` — when w2 bit31 marks a parked spec
block it READs the block's w0 entry-count and `OBJPAY_OP_FREE`s
`spec_base` for `1+2*count` words before `StRetPFree` releases the
pipeline block.  Verified: `+vec=apu-vn-specok` PASS (step-1 and
randomized-latency step-2, 866 checks) plus 22-session regression
sample (compute pos/neg, graphics, multiset/descarr/modres/rerec)
all PASS.  **Spec-value path confirmed already wired (2026-11-07):**
dispatch reads pipeline w2 into `rs_spec_q` (`g6lc_apu_cmdexec`
StDsModR2), feeds `spec:` into the shcore module-load request;
`g6lc_apu_shcore` `f_spec_q`/`F_SP0` reads the parked ObjPay spec block
into `f_spid_q`/`f_spv_q` -> packed `spec_id_i`/`spec_val_i`/`spec_n_i`;
`g6lc_apu_shmod` `f_spec` resolves `OpSpecConstant` (opcode 50) against
those, last-match-wins, literal default on miss.  `specok` exercises
the spec-block *read* (bufcopy has no `OpSpecConstant`, so values are
unconsumed).  **Deeper gap found (2026-11-07):** proving the override
reaches the *output buffer* is blocked less by RTL than by the
expected-output infrastructure.  Every oracle/model/class artifact is
baked at **default** specialization: the lavapipe oracle
(`vk_compute_oracle.c`) builds its pipeline with no
`pSpecializationInfo`, `spirv_model` does not fold overrides, and the
normal-dispatch check (`build_transport` ~L9424) emits
`o['model']/o['oracle']/o['cls']` straight from the shvec `.exp`.  The
model-side `pipe_spec[h]` folded module is stored for provenance only —
compute dispatch is structural and never re-executes it for the output
gate.  So a correct RTL producing the override (e.g. 41) would
*mis*-match an `.exp` expecting the default (7).  None of the 484
`sh_vectors` carry `OpSpecConstant` (opcodes 48-52 absent).

**RESOLVED end-to-end (2026-11-07, directed RTL sim):** the
specialization-constant path is now proven from `OpSpecConstant` to the
output buffer.  `corpus/specconst.{comp,spv}` is a minimal compute
shader — `layout(constant_id=0) const uint K=7;` storing `K` to all
four words of one SSBO (explicit stores, so every output word carries
the constant).  `specialize()` folds `(0→41)`, rewriting opcode 50
`OpSpecConstant`→opcode 43 `OpConstant`.

The shvec `sh_vectors/specconst_1` is **decoupled** exactly as required:
`.hex` keeps the *original* `OpSpecConstant` words (so RTL still
exercises the spec-block path) while `.exp` oracle/model/class are
generated from the *folded* module (=41).  This was achieved **without
modifying `shader_vectors.py::emit`** — `emit()` already accepts
`oracle_out`/`model_cache` overrides, so a driver runs `model_run()` on
a folded `hexw` and the lavapipe oracle on a folded `.spv`, then
re-emits with the original words.  Both oracle (lavapipe) and
`spirv_model` independently produce `[41,41,41,41]` (class `i`,
bit-exact).

Session vector `vn_vectors/apu-vn-specok2` (`--compute-session …
specconst_1 --variant specok`) creates the pipeline with
`pSpecializationInfo` `constantID=0→41`, binds, dispatches, and checks
4 output words.  `tb_g6lc_apu_vgtop +vec=apu-vn-specok2`:
`PASS-COMPUTE g1=12 g2=12 ulp1=0 ulp2=0`, `XF_FAULTS 0`, under **both**
the zero-jitter reference and the randomized memory-latency step
(`+mp_lat_min=1 +mp_lat_max=20 +mp_ready_pct=60`).  An 11-session
regression (specok, specok2, `ue_cneg_spec_1` reject, bufcopy/bufscale/
loopfor/barrier/arrlen/vec4arith compute, `ue_gpos_fsubo_1` graphics,
`ue_cneg_baddesc_1`) is all PASS.  This closes the COMPUTE-H1
spec-constant mechanism at the directed-sim level: `OpSpecConstant` →
ObjPay spec block → `rs_spec_q` → shcore `F_SP0` → shmod `f_spec` →
constant 41 → SSBO write → checked output.

**Still owed (not qualification):** real CTS `compute.pipeline.specialization.*`
runs.  The `spec` field is now first-class in `shader_vectors.py` `DESC`
(`spec={constantID: value}` → `specialize()` fold for `.exp`, original
`OpSpecConstant` words kept in `.hex`), so `specconst_{1,2,3}` regenerate
reproducibly through the standard generator — `specconst.tab` (shmod
scanner table) is emitted too.  `specconst` sets `mut=False` (mutation
is meaningless on an override vector).

**Create-failure unwind gap (documented, fault-injection-only):** the
success create+retire path is clean, but *post-allocation* create
faults unwind incompletely — a coherent redesign, not a one-line leak.
After `StPipeSpAlc` commits the spec extent (`pl_specb_q`,
`1+2·pl_sn_q` words), later faults strand resources: `StPipeAlcP`
(ObjPay ALLOC) fail → `StPipeFail` frees nothing ObjPay-side;
`StPipeAuxC` (ObjTab ALLOC) fail → `StPipeFaux` frees the 3-word
pipeline block but not the spec extent; `StPipeAuxCpl` (SETAUX) fail →
`StPipeFail` frees neither block nor the ObjTab object; and the
aux-high SETAUX completion `StAuxHiCpl` routes straight to `StRep`,
bypassing `StPipeFail` and stranding spec extent + pipeline block +
ObjTab object + module pins together.  Reachable only on ObjPay/ObjTab
exhaustion or SETAUX failure — never in normal CTS — and bounded (small
extents, table-sized objects).  Fix needs a unified per-element
cleanup (free spec-if-owned → free pipeline block → destroy ObjTab
object → unpin modules) gated by an ownership flag cleared at
`StPipeAuxHiC`; tracked as a dedicated task.  Evidence remains
host-native model + directed Verilator sim — **no capsets, CTS,
stock-Mesa, physical, or silicon qualification**.

## Performance / area / scalability

Compute is the roofline baseline (W1.5/W1.6): instructions per cycle per wave, LSU
occupancy, barrier stalls. Knobs: `ShaderCores`, `MaxWaves`, lanes per wave, RF banks,
slab bytes, texel/record cache sizes. Correctness-preserving: any multi-core split of a
dispatch must keep workgroup-local shared memory and barriers on one core (or a shared
slab with the same ordering); atomics across cores need a single point of serialization
or a coherent L2 (W5.6).
