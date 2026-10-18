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
              serialized executor guarantees it today); today refused UNSUPPORTED.
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
  NEXT ARTIFACT   COMPUTE-H1 spec constants (gates 27 NS + 3 Fails),
                  image texel-pointer + atomics (2 Fails), COMPUTE-H3
                  128-inv groups (1 Fail), G3b-iii DispatchIndirect +
                  rerun for the 3 unrecorded cases.
```

## Performance / area / scalability

Compute is the roofline baseline (W1.5/W1.6): instructions per cycle per wave, LSU
occupancy, barrier stalls. Knobs: `ShaderCores`, `MaxWaves`, lanes per wave, RF banks,
slab bytes, texel/record cache sizes. Correctness-preserving: any multi-core split of a
dispatch must keep workgroup-local shared memory and barriers on one core (or a shared
slab with the same ordering); atomics across cores need a single point of serialization
or a coherent L2 (W5.6).
