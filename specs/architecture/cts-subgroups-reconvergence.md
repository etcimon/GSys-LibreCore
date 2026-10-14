# `subgroups` (48,621) and `reconvergence` (6,253) — subgroup operations, sizes, uniform control flow, maximal reconvergence

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/subgroups.txt`,
`vk-default/reconvergence.txt`; tests in `external/vulkancts/modules/vulkan/subgroups/
vktSubgroups*.cpp`, `reconvergence/vktReconvergenceTests.cpp`. Owner W3 (plan W3.4 flexible
subgroups: "decouple architectural subgroup size from physical lanes"). Gate CTS-3.
**Vulkan 1.1 requires subgroup support in compute with at least the BASIC operation
class** (subgroupSupportedStages ⊇ COMPUTE, subgroupSupportedOperations ⊇ BASIC) — so
`subgroups.basic.*` and `builtin_var.*` in compute are 1.1 obligations, not optional.

## Inventory

| `dEQP-VK.subgroups.` | cases | class |
|---|---:|---|
| `arithmetic` | 12087 | ARITHMETIC: add/mul/min/max/and/or/xor reductions, inclusive/exclusive scans, all types |
| `partitioned` | 12087 | NV partitioned (NotSupported) |
| `shuffle` | 9562 | SHUFFLE / SHUFFLE_RELATIVE: shuffle, xor, up, down |
| `ballot_broadcast` | 6117 | BALLOT: broadcast, broadcastFirst |
| `clustered` | 4029 | CLUSTERED reductions |
| `quad` | 3415 | QUAD: quadBroadcast, quadSwap* (in fragment and compute) |
| `vote` | 805 | VOTE: all/any/allEqual |
| `ballot_mask`, `ballot_other`, `ballot`, `builtin_mask_var`, `builtin_var`, `basic`, `shape`, `size_control`, `subgroup_uniform_control_flow`, `shader_quad_control`, `uniform_descriptor_indexing`, `multiple_dispatches` | 60, 84, 23, 60, 36, 70, 24, 63, 85, 4, 9, 1 | BASIC + builtins (gl_SubgroupSize/ID/Invocation, masks), subgroup size control (1.3), uniform control flow (KHR) |
| `reconvergence.*` | 6253 | `maximal` 1449 (KHR_shader_maximal_reconvergence), `subgroup_uniform_control_flow_{ballot,elect}` 2400, `workgroup_uniform_control_flow_*` 2400, `terminate_invocation` 4 |

## Architectural logic

```text
LOGIC SG-L1 · A subgroup is a well-defined set of invocations with the BASIC operations
  CLAIM       gl_SubgroupSize (uniform, 1–128, = subgroupSize property unless size
              control), gl_NumSubgroups, gl_SubgroupID, gl_SubgroupInvocationID, the Eq/
              Ge/Gt/Le/Lt masks; subgroupElect, subgroupBarrier, subgroupMemoryBarrier*;
              workgroups are partitioned into subgroups deterministically (full
              subgroups when the workgroup size is a multiple); in fragment shaders,
              helper invocations are part of the subgroup (and excluded from ballots per
              the rules).
  SOURCE      subgroups.basic.*, builtin_var.*, builtin_mask_var.*, shape.*,
              multiple_dispatches, size_control.* (1.3).
  MECHANISM   The wave (8 lanes × vec4 lockstep) is the natural subgroup of size 8;
              plan W3.4 decouples the *architectural* subgroup size (advertise 8, 16, 32
              — the property is one value; subgroupSizeControl allows a range) from the
              physical lanes by executing a logical subgroup as k consecutive wave
              passes with a shared mask/ballot register. Required now: the builtins,
              elect (lowest active lane), barriers (a wave is already lockstep —
              subgroupBarrier is a no-op within a wave, and the k-pass scheme must make
              it a pass-join).
  REQUIRES    A decision on the advertised subgroupSize (8 is legal; UE/CS2 shaders
              assume 32/64 is common but may not require it; some algorithms use
              gl_SubgroupSize generically); `subgroupSupportedStages` must include
              COMPUTE (1.1) and should include FRAGMENT (quad ops) when done.
  FORBIDS     A subgroup size that varies between dispatches of the same pipeline
              without size control; counting helper invocations in subgroupBallot
              results as active.
  CHECK       subgroups.basic.*, builtin_var.compute.* (CTS-1 — these are 1.1
              obligations), shape.*.
  COST        none for size 8; the k-pass scheme costs a mask register per wave.
  FEEDS       GLSL-L4 (dfdxsubgroup), MM-L1 (subgroup scope), W6 (cooperative matrices);
              CTS-1/3.
  STATUS      not-run (no subgroup ops accepted today — shmod faults OpGroupNonUniform*)

LOGIC SG-L2 · Vote, ballot, broadcast, shuffle, arithmetic, clustered, quad
  CLAIM       The non-uniform group operations (SPIR-V OpGroupNonUniform{All,Any,
              AllEqual,Broadcast,BroadcastFirst,Ballot,InverseBallot,BallotBitExtract,
              BallotBitCount,BallotFindLSB/MSB,Shuffle,ShuffleXor,ShuffleUp/Down,IAdd…
              FMax (reduce/inclusive/exclusive scans),Clustered variants,QuadBroadcast,
              QuadSwap}) over bool/int/uint/float/double(opt)/16-bit(opt) scalars and
              vectors, in compute and (where advertised) graphics stages, respecting the
              active mask under divergence and the fragment helper rules; subgroup
              uniform control flow (KHR) semantics; rotate (1.4 core shaderSubgroupRotate).
  SOURCE      subgroups.{vote,ballot*,shuffle,arithmetic,clustered,quad,
              subgroup_uniform_control_flow,uniform_descriptor_indexing}.*.
  MECHANISM   Cross-lane network in shwave: a wave-wide reduce/scan/shuffle unit over
              the 8 lanes (log-step network) with the active mask; ballots are 8-bit
              (zero-extended to the 128-bit result layout); the k-pass logical subgroup
              composes partial results through the shared register (scans need a carry
              between passes; shuffles across passes go through a wave-local slab —
              W3.4's design).
  REQUIRES    SG-L1; the reconvergence model (§7c) defines "active" per instruction —
              these ops read the current mask (lockstep makes this exact).
  FORBIDS     Executing a group op with a lane set that differs from the SPIR-V
              structured-control-flow active set (e.g. a parked `continue` lane counted
              active); approximate float reductions in a different association than the
              one the test tolerates (the CTS checks arithmetic within a tolerance for
              floats and exactly for ints).
  CHECK       vote.*, ballot_broadcast.*, shuffle.*, arithmetic.* in compute (CTS-3);
              quad.* in fragment after SG-L3.
  COST        the cross-lane network (8-lane butterfly: small); k-pass carries.
  FEEDS       COMPUTE-L4, W6; CTS-3.
  STATUS      not-run

LOGIC SG-L3 · Fragment subgroups and quads; maximal reconvergence
  CLAIM       In fragment shaders quads are the 2×2 derivative groups; quad operations
              and helper invocations follow the spec; subgroup ops in fragment/vertex
              stages when those stages are advertised; shaderQuadControl (1.4-era) and
              maximal reconvergence (KHR: invocations reconverge at the earliest point
              the structured control flow allows — the `maximal` 1449 and the
              `*_uniform_control_flow_*` families check ballots/elects at each
              reconvergence point against the model).
  SOURCE      subgroups.quad.*, shader_quad_control.*, reconvergence.*.
  MECHANISM   §7c lockstep reconvergence already reconverges at merge labels (the
              structured points) — maximal reconvergence is *stricter*: lanes must
              reconverge at merge blocks and must not be split by the implementation's
              scheduling (the §7c pending-lane rule splits a divergent branch into target
              groups and rejoins at the merge — that is exactly maximal reconvergence for
              if/switch; loops: all lanes that exit in iteration i and j must rejoin at
              the merge — true). The CTS compares against its own simulator with
              ballot snapshots per point.
  REQUIRES    The 2×2 quad = lanes {4k..4k+3} (G2b) exposed as the subgroup quad;
              fragment stage in subgroupSupportedStages.
  FORBIDS     Reordering lanes between quads; executing quad ops with helpers excluded
              (helpers participate in quad ops).
  CHECK       quad.graphics.*, reconvergence.maximal.* (CTS-3; the maximal family also
              validates §7c's model independently — a high-value transfer test, RT-P8).
  COST        none.
  FEEDS       §7c verification; CTS-3.
  STATUS      not-run
```

## Exceptions

```text
EXCEPTION SG-X1 · NotSupported by truthful absence
  CONDITION   partitioned.* (NV), 64-bit/16-bit/fp64 type variants, stages not in
              subgroupSupportedStages, operation classes not in
              subgroupSupportedOperations, size_control (1.3), shader_quad_control,
              maximal reconvergence (KHR), subgroup_uniform_control_flow (KHR).
  RESULT      NotSupported.
  TRUTH       profile; BASIC+COMPUTE are *required at 1.1* (no exception); the
              subgroupSupportedOperations mask must list exactly the implemented
              classes (CTS-P1).
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     Advertising a class partially (e.g. ARITHMETIC without scans).
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| SG-H1 BASIC at size 8 | 1.1 obligation | high | builtins + elect + barrier within the wave; advertise 8 | — |
| SG-H2 Vote/ballot/broadcast/shuffle | CTS-3 | high | the 8-lane cross-lane network | — |
| SG-H3 Arithmetic/clustered | CTS-3 | medium | reduce/scan network with ordered float association | — |
| SG-H4 Logical sizes 16/32 | W3.4 | later | k-pass composition; measure whether 32 is worth it for content | — |

## Performance / area / scalability

Subgroup width is a first-order architecture choice (occupancy, divergence cost, RF
banking). The plan's W3.4 decoupling lets the Pareto study pick physical lanes
independently of the advertised size. Correctness-preserving: the active mask semantics
of §7c are the contract; `reconvergence.*` is the external check of it.
